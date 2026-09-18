#!/bin/bash
# SPDX-License-Identifier: BSD-3-Clause
#
# edy-rdp-deskui <action> — enable / disable / start / stop this host's graphical
# desktop UI (the display manager + the default systemd target).
#
# This runs as root, started through the edy-rdp-deskui@<action> oneshot unit. The
# relay (edy-relay) is granted by polkit to START ONLY the edy-rdp-deskui@ unit
# family — nothing else — and <action> is the systemd instance name (%i), which is
# validated here against a FIXED enum. There is NO path in this helper that runs a
# caller-supplied unit name, systemctl verb or shell command: the only things it
# ever passes to systemctl are the literal targets/DM unit it discovers itself.
#
# Operation -> systemd mapping
#   enable       set-default graphical.target  + enable  <display-manager>
#   disable      set-default multi-user.target + disable <display-manager>
#   start        start <display-manager>        (no DM: isolate graphical.target)
#   stop         stop  <display-manager>        (no DM: isolate multi-user.target)
#   stop-force   as 'stop', but permitted even while a desktop is in use
#
# GUARDS (defence in depth — the relay enforces the same policy BEFORE it ever
# starts this unit; these run again here so the privilege is safe on its own):
#   1. Config opt-in, fail-closed. Refuses unless EDY_RDP_DESKUI_ENABLE=1, read
#      from the host .env via the unit's EnvironmentFile. A host that has not opted
#      in (an operator's own workstation, say) cannot have its desktop changed even
#      by root starting this unit by hand.
#   2. Action enum. Anything but the five tokens above is refused before systemctl
#      is touched — this is what makes "no arbitrary systemctl" literally true.
#   3. Live-console gate. Plain 'stop' refuses while any active, graphical, seated
#      session exists: you cannot cut the desktop out from under someone using it.
#      Only 'stop-force' overrides that, and the relay issues 'stop-force' solely
#      after the operator has typed this host's name to confirm.
set -uo pipefail

log() { printf '[deskui] %s\n' "$*"; }
die() { printf '[deskui] %s\n' "$*" >&2; exit "${2:-1}"; }

action="${1:?usage: edy-rdp-deskui <enable|disable|start|stop|stop-force>}"

# 1. config opt-in (fail closed) --------------------------------------------
case "${EDY_RDP_DESKUI_ENABLE:-0}" in
    1|true|TRUE|yes|on) ;;
    *) die "desktop UI control is disabled on this host (EDY_RDP_DESKUI_ENABLE is not 1)" 4 ;;
esac

# 2. validate the action against a FIXED enum -------------------------------
force=0
case "$action" in
    enable|disable|start|stop) ;;
    stop-force) action=stop; force=1 ;;
    *) die "unknown action: $action" 2 ;;
esac

# Detect the display manager the host ACTUALLY uses (never assume gdm). systemd
# maintains /etc/systemd/system/display-manager.service as an alias symlink to the
# active DM unit; trust that first, then probe the known names.
detect_dm() {
    local link base u
    link=$(readlink -f /etc/systemd/system/display-manager.service 2>/dev/null || true)
    base=$(basename -- "$link" 2>/dev/null)
    # Trust the alias ONLY when it resolves to a real unit file that is not the
    # alias name itself. `readlink -f` returns the path unchanged when the alias
    # has been removed (a disable does that), which would otherwise yield the
    # bogus "display-manager.service" -- a name you cannot enable/start.
    if [ -n "$link" ] && [ -f "$link" ] && [ "$base" != "display-manager.service" ]; then
        printf '%s\n' "$base"; return 0
    fi
    for u in gdm gdm3 lightdm sddm lxdm xdm nodm ly greetd; do
        if systemctl cat "$u.service" >/dev/null 2>&1; then
            printf '%s\n' "$u.service"; return 0
        fi
    done
    return 1
}
dm=$(detect_dm || true)

# Count active, graphical, SEATED user sessions (a desktop somebody is using now).
# A greeter (the DM's own login screen) is not counted — stopping the DM to replace
# a greeter is not "cutting someone off". Anything without a seat (TTY, remote,
# service) is not a physical console and is not counted either.
active_graphical_sessions() {
    local sid rest props n=0
    while read -r sid rest; do
        [ -n "$sid" ] || continue
        props=$(loginctl show-session "$sid" -p Type -p Active -p Seat -p Class 2>/dev/null) || continue
        get() { printf '%s\n' "$props" | sed -n "s/^$1=//p"; }
        [ -n "$(get Seat)" ]        || continue
        [ "$(get Active)" = "yes" ] || continue
        case "$(get Class)" in greeter) continue ;; esac
        case "$(get Type)" in wayland|x11) n=$((n + 1)) ;; esac
    done < <(loginctl list-sessions --no-legend 2>/dev/null)
    printf '%s\n' "$n"
}

case "$action" in
    enable)
        log "set-default graphical.target"
        systemctl set-default graphical.target >/dev/null \
            || die "set-default graphical.target failed"
        if [ -n "$dm" ]; then
            log "enable $dm"
            systemctl enable "$dm" >/dev/null 2>&1 || die "enable $dm failed"
        else
            log "no display manager detected; set graphical.target only (install a DM for a login screen)"
        fi
        ;;
    disable)
        log "set-default multi-user.target"
        systemctl set-default multi-user.target >/dev/null \
            || die "set-default multi-user.target failed"
        if [ -n "$dm" ]; then
            log "disable $dm"
            systemctl disable "$dm" >/dev/null 2>&1 || die "disable $dm failed"
        fi
        ;;
    start)
        if [ -n "$dm" ]; then
            log "start $dm"
            systemctl start "$dm" || die "start $dm failed"
        else
            log "no display manager; isolate graphical.target"
            systemctl isolate graphical.target || die "isolate graphical.target failed"
        fi
        ;;
    stop)
        if [ "$force" -ne 1 ]; then
            n=$(active_graphical_sessions)
            [ "$n" = 0 ] || die "refusing to stop the desktop: $n active graphical session(s) in use" 3
        fi
        if [ -n "$dm" ]; then
            [ "$force" -eq 1 ] && log "stop $dm (forced)" || log "stop $dm"
            systemctl stop "$dm" || die "stop $dm failed"
        else
            log "no display manager; isolate multi-user.target"
            systemctl isolate multi-user.target || die "isolate multi-user.target failed"
        fi
        ;;
esac

log "done: $action"
