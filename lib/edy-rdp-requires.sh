# lib/edy-rdp-requires.sh - the ONE reading of requires.txt.
#
# Sourced, never executed. requires.txt is THE prerequisite list: deploy.sh
# --with-deps installs from it, install.sh (check 8b) reports against it, and
# the relay's start-time bootstrap refuses to start without it. Before 1.4.0
# deploy.sh carried its own PREREQS=(...) array, its own package-name mapping
# and a presence-only probe, while requires.txt - with the minimum versions -
# was documentation nothing read. Two lists disagree eventually; this file is
# what makes there be one.
#
# Contract: bash 4+, safe under `set -Eeuo pipefail`; no side effect on source;
# every function returns; probes never fail the caller (a tool without a
# --version is "version not detectable", which is NOT a failure - only an
# absent tool or a version below the minimum is).
#
# Grammar of requires.txt ('#' to end of line is a comment; blank lines skipped):
#   NAME  >=MIN  [REFERENCE]           NAME is the canonical probe name below
#   guacd-image  REF  sha256:<64 hex>  the pinned container image
# Anything else is a parse error, reported as "<file>:N: unparsable line".

# --- parsing ---------------------------------------------------------------

# req_load FILE - fills REQ_NAMES (file order), REQ_MIN[name], REQ_IMAGE_REF and
# REQ_IMAGE_DIGEST. rc 1 on a parse error (message on stdout).
req_load() {
    local file=$1 n=0 raw line name min ref rc=0 base
    declare -g REQ_IMAGE_REF="" REQ_IMAGE_DIGEST=""
    declare -ga REQ_NAMES=()
    declare -gA REQ_MIN=()
    base="${file##*/}"
    [[ -r "$file" ]] || { printf '%s: missing or unreadable\n' "$file"; return 1; }
    while IFS= read -r raw || [[ -n "$raw" ]]; do
        n=$((n+1))
        line="${raw%%#*}"
        line="${line#"${line%%[![:space:]]*}"}"; line="${line%"${line##*[![:space:]]}"}"
        [[ -z "$line" ]] && continue
        # shellcheck disable=SC2086
        set -- $line
        if [[ "$1" == guacd-image ]]; then
            if [[ $# -eq 3 && "$3" =~ ^sha256:[0-9a-f]{64}$ ]]; then
                REQ_IMAGE_REF="$2"; REQ_IMAGE_DIGEST="$3"
            else printf '%s:%d: unparsable line\n' "$base" "$n"; rc=1; fi
            continue
        fi
        name="$1"; min="${2:-}"; ref="${3:-}"
        if [[ "$name" =~ ^[a-z][a-z0-9_.+-]*$ && "$min" =~ ^\>=[0-9][0-9.]*$ && $# -le 3 ]]; then
            REQ_NAMES+=("$name"); REQ_MIN["$name"]="${min#>=}"
        else printf '%s:%d: unparsable line\n' "$base" "$n"; rc=1; fi
    done < "$file"
    return $rc
}

req_list()         { local n; for n in "${REQ_NAMES[@]}"; do printf '%s %s\n' "$n" "${REQ_MIN[$n]}"; done; }
req_image_ref()    { printf '%s\n' "${REQ_IMAGE_REF:-}"; }
req_image_digest() { printf '%s\n' "${REQ_IMAGE_DIGEST:-}"; }

# --- versions --------------------------------------------------------------

# req_norm VERSION - the leading dotted-numeric part of a package version
# ("360-1" -> 360, "21.1.22-1ubuntu1" -> 21.1.22), which is what a minimum in
# requires.txt is compared against. A Debian epoch ("2:21.1.22-1ubuntu1", what
# dpkg-query prints for xvfb) is ordering metadata, not a version: dropped
# first, or Xvfb 21 would read as "2" and fail a ">=1.20" it satisfies.
# Empty when there is no numeric part at all.
req_norm() {
    local v="${1:-}"
    [[ "$v" =~ ^[0-9]+:(.*)$ ]] && v="${BASH_REMATCH[1]}"
    [[ "$v" =~ ^[0-9]+(\.[0-9]+)* ]] && printf '%s\n' "${BASH_REMATCH[0]}" || printf '\n'
    return 0
}

# req_version_ge HAVE MIN - rc 0 when norm(HAVE) >= MIN. sort -V knows that
# 3.31.0 is after 3.4 and 0.9.17 after 0.9.16, which a string compare does not.
req_version_ge() {
    local have min=$2 first
    have="$(req_norm "$1")"
    [[ -n "$have" ]] || return 1
    # Same number of components on both sides first: sort -V ranks '4' BELOW
    # '4.0', so a tool that reports a major-only version would fail a minimum
    # it meets, and the bootstrap would keep the relay down over it.
    local -a hc mc
    IFS=. read -ra hc <<<"$have"; IFS=. read -ra mc <<<"$min"
    while (( ${#hc[@]} < ${#mc[@]} )); do hc+=(0); done
    while (( ${#mc[@]} < ${#hc[@]} )); do mc+=(0); done
    have="$(IFS=.; printf '%s' "${hc[*]}")"; min="$(IFS=.; printf '%s' "${mc[*]}")"
    first="$(printf '%s\n%s\n' "$min" "$have" | sort -V | sed -n 1p)"
    [[ "$first" == "$min" ]]
}

# The FreeRDP 3 client is 'xfreerdp3' on Debian/Ubuntu and 'xfreerdp' (at v3)
# elsewhere; a FreeRDP 2 'xfreerdp' does not count (no RDSTLS - I26).
req_freerdp_bin() {
    command -v xfreerdp3 >/dev/null 2>&1 && { echo xfreerdp3; return 0; }
    command -v xfreerdp  >/dev/null 2>&1 \
        && xfreerdp /version 2>/dev/null | grep -qE 'version 3\.' && { echo xfreerdp; return 0; }
    return 1
}

# req_have NAME - presence probe by the binary the project actually calls, not
# the package name (a package can be installed with its binary elsewhere, and
# the reverse). rc only. cockpit needs the bridge AND the shell UI package:
# cockpit-system shipped /usr/share/cockpit/system up to ~cockpit 330 and
# /usr/share/cockpit/systemd since (edt1's 360 has only the latter), so either
# directory counts - the old probe called the reference host "missing".
req_have() {
    case "$1" in
      cockpit)  command -v cockpit-bridge >/dev/null 2>&1 \
                && [[ -d /usr/share/cockpit/system || -d /usr/share/cockpit/systemd ]] ;;
      freerdp)  req_freerdp_bin >/dev/null 2>&1 ;;
      xvfb)     command -v Xvfb >/dev/null 2>&1 ;;
      nftables) command -v nft >/dev/null 2>&1 ;;
      gnome-remote-desktop) command -v grdctl >/dev/null 2>&1 ;;
      dbus)     command -v dbus-send >/dev/null 2>&1 ;;
      *)        command -v "$1" >/dev/null 2>&1 ;;
    esac
}

# req_version NAME - the detected version, or "" when the tool has no flag for
# it (Xvfb has none: its version comes from the package manager; grdctl has
# none either, the daemon binary does). Every probe is wrapped so a tool that
# prints to stderr or exits non-zero on --version cannot fail the caller.
req_version() {
    local v="" fb
    case "$1" in
      cockpit)  v="$(cockpit-bridge --version 2>/dev/null | sed -n 's/^Version: *//p' || true)" ;;
      podman)   v="$(podman --version 2>/dev/null | awk '{print $3}' || true)" ;;
      python3)  v="$(python3 --version 2>/dev/null | awk '{print $2}' || true)" ;;
      freerdp)  fb="$(req_freerdp_bin 2>/dev/null || true)"
                [[ -n "$fb" ]] && v="$("$fb" /version 2>/dev/null | grep -o 'version [0-9.]*' | awk '{print $2}' || true)" ;;
      xvfb)     v="$(dpkg-query -W -f='${Version}' xvfb 2>/dev/null \
                     || rpm -q --qf '%{VERSION}' xorg-x11-server-Xvfb 2>/dev/null \
                     || pacman -Q xorg-server-xvfb 2>/dev/null | awk '{print $2}' || true)" ;;
      x11vnc)   v="$(x11vnc -version 2>/dev/null | awk '{print $2}' || true)" ;;
      nftables) v="$(nft --version 2>/dev/null | grep -o 'v[0-9.]*' | tr -d v || true)" ;;
      gnome-remote-desktop)
                v="$(/usr/libexec/gnome-remote-desktop-daemon --version 2>/dev/null | grep -o '[0-9][0-9.]*' | sed -n 1p || true)"
                [[ -n "$v" ]] || v="$(dpkg-query -W -f='${Version}' gnome-remote-desktop 2>/dev/null \
                                      || rpm -q --qf '%{VERSION}' gnome-remote-desktop 2>/dev/null || true)" ;;
      dbus)     v="$(dbus-daemon --version 2>/dev/null | grep -o '[0-9][0-9.]*' | sed -n 1p || true)" ;;
      *)        v="$("$1" --version 2>/dev/null | grep -o '[0-9][0-9.]*' | sed -n 1p || true)" ;;
    esac
    v="$(req_norm "${v%%$'\n'*}")"
    printf '%s\n' "$v"
    return 0
}

# req_check [--quiet] - presence AND minimum for every loaded requirement.
# Prints "  ok   name ver (>= min)" (not with --quiet), "  FAIL name missing"
# or "  FAIL name have < min"; fills REQ_MISSING, REQ_OUTDATED and REQ_HAVE[name]
# (the detected version, for a caller composing its own report). rc 1 if either
# list is non-empty.
req_check() {
    local quiet=0 n have min
    [[ "${1:-}" == --quiet ]] && quiet=1
    declare -ga REQ_MISSING=() REQ_OUTDATED=()
    declare -gA REQ_HAVE=()
    for n in "${REQ_NAMES[@]}"; do
        min="${REQ_MIN[$n]}"
        if ! req_have "$n"; then
            REQ_MISSING+=("$n"); printf '  FAIL %s missing\n' "$n"; continue
        fi
        have="$(req_version "$n")"; REQ_HAVE["$n"]="$have"
        if [[ -z "$have" ]]; then
            (( quiet )) || printf '  ok   %s (version not detectable) (>= %s)\n' "$n" "$min"
        elif req_version_ge "$have" "$min"; then
            (( quiet )) || printf '  ok   %s %s (>= %s)\n' "$n" "$have" "$min"
        else
            REQ_OUTDATED+=("$n"); printf '  FAIL %s %s < %s\n' "$n" "$have" "$min"
        fi
    done
    (( ${#REQ_MISSING[@]} == 0 && ${#REQ_OUTDATED[@]} == 0 ))
}

# --- the fix ---------------------------------------------------------------

req_detect_pm() { local pm; for pm in apt-get dnf yum pacman zypper; do
    command -v "$pm" >/dev/null 2>&1 && { echo "$pm"; return 0; }; done; echo ""; return 0; }

# req_pkg_for NAME PM - the distro package(s) behind a canonical name. Lives
# HERE, not in deploy.sh, because the bootstrap has to print the exact command
# that fixes a missing prerequisite and deploy.sh is not in the payload; a
# second copy of this table in deploy.sh would be the disagreement 1.4.0 removes.
req_pkg_for() { case "$2:$1" in
    apt-get:cockpit)  echo "cockpit cockpit-system" ;;
    apt-get:freerdp)  echo "freerdp3-x11" ;;
    apt-get:xvfb)     echo "xvfb" ;;
    apt-get:dbus)     echo "dbus-bin" ;;
    apt-get:*)        echo "$1" ;;
    dnf:cockpit|yum:cockpit) echo "cockpit cockpit-system" ;;
    dnf:freerdp|yum:freerdp) echo "freerdp" ;;
    dnf:xvfb|yum:xvfb)       echo "xorg-x11-server-Xvfb" ;;
    dnf:dbus|yum:dbus)       echo "dbus-tools" ;;
    dnf:*|yum:*)             echo "$1" ;;
    pacman:cockpit)  echo "cockpit" ;;   pacman:freerdp) echo "freerdp" ;;
    pacman:xvfb)     echo "xorg-server-xvfb" ;;  pacman:python3) echo "python" ;;
    pacman:dbus)     echo "dbus" ;;
    pacman:*)        echo "$1" ;;
    zypper:cockpit)  echo "cockpit cockpit-bridge" ;;  zypper:freerdp) echo "freerdp" ;;
    zypper:xvfb)     echo "xorg-x11-server-Xvfb" ;;
    zypper:dbus)     echo "dbus-1-tools" ;;
    zypper:*)        echo "$1" ;;
    *) echo "$1" ;;
  esac; }

# req_fix_command NAME... - ONE shell command line that installs them all on
# this host's package manager, or a plain instruction when there is none.
req_fix_command() {
    local pm n pkgs=()
    pm="$(req_detect_pm)"
    if [[ -z "$pm" ]]; then printf 'install manually (no supported package manager): %s\n' "$*"; return 0; fi
    for n in "$@"; do read -ra _p <<<"$(req_pkg_for "$n" "$pm")"; pkgs+=("${_p[@]}"); done
    case "$pm" in
      apt-get) printf 'apt-get update && apt-get install -y %s\n' "${pkgs[*]}" ;;
      dnf|yum) printf '%s install -y %s\n' "$pm" "${pkgs[*]}" ;;
      pacman)  printf 'pacman -Sy --noconfirm %s\n' "${pkgs[*]}" ;;
      zypper)  printf 'zypper --non-interactive install %s\n' "${pkgs[*]}" ;;
    esac
    return 0
}

# --- the pip side (requirements.txt) ---------------------------------------

# req_pip_count FILE - requirement lines (non-blank, non-comment). 0 when the
# file is missing: no file, no venv, same as an empty one.
req_pip_count() {
    [[ -r "${1:-}" ]] || { echo 0; return 0; }
    grep -cvE '^[[:space:]]*(#|$)' -- "$1" || true
}

# req_sha256 FILE - what the bootstrap compares against venv/.requirements.sha
# to know whether the venv it built is the one this requirements.txt describes.
req_sha256() {
    [[ -r "${1:-}" ]] || { echo none; return 0; }
    sha256sum -- "$1" | awk '{print $1}'
}
