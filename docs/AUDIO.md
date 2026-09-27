# Desktop audio streaming (the "Sound" toggle)

The browser mirror can stream the seat's **desktop audio** — what is playing on
the physical monitor's speakers — to the viewer. It is **off by default** and
gated by the plugin's **Sound** checkbox (toggling it live reconnects to add or
drop the audio channel, because `enable-audio` is a connect-time parameter).

## Path

```
desktop app → PipeWire/PulseAudio (a sink) → that sink's .monitor source
           → guacd (records the named monitor) → Guacamole audio stream
           → browser (Web Audio, gated live by the Sound toggle)
```

guacd runs in a container on the **host network**. It reaches the seat's
PulseAudio through a **bind-mounted UNIX socket** (see below) and records the
**monitor** of the sink the desktop plays to, so it captures desktop **output**,
not a microphone. There is **no** microphone/audio-input path — the
browser→session leg is VNC, which has no audio input.

## Why a bind-mounted socket, and an explicit monitor name

Two dead ends were ruled out on this platform (pipewire-pulse), and the working
configuration avoids both:

- **TCP does not work.** `module-native-protocol-tcp` accepts the connection but
  delivers **zero** recording bytes; only the local UNIX socket carries audio.
  So the unit bind-mounts the socket rather than using `tcp:`.
- **`@DEFAULT_MONITOR@` does not resolve.** The alias yields **silence** here
  even when the default sink is active. You must name the monitor **explicitly**
  (`<sink-name>.monitor`).

The seat's pulse socket lives under its `XDG_RUNTIME_DIR` (mode `0700`), which the
container's uid cannot traverse, so the socket has to be bound somewhere the
container can reach.

### Why a SHARED directory, not a one-shot socket bind (KNOWN_ISSUES I42)

1.3.x bound the socket **file** onto `/run/edy-rdp-pulse.sock` once, at guacd
start, behind `ExecStartPre=-`. After a boot where guacd came up before the seat
logged in, the target stayed a 0-byte regular file, the `-` swallowed the error,
nothing ever retried, and the container's `-v` was `rprivate` — a bind done on
the host later could not reach the running container. Audio was dead until
someone restarted guacd.

Since 1.4.0 the bind root is a **directory**:

| Host | Container | Who makes it so |
|---|---|---|
| `/run/edy-rdp-pulse` — bind-mounted onto itself and marked **rshared** | `/run/pulse` (`-v /run/edy-rdp-pulse:/run/pulse:ro,rslave`) | `edy-rdp-pulse-bind`, as guacd's `ExecStartPre` (tmpfiles creates the directory at boot) |
| `/run/edy-rdp-pulse/native` — the seat socket bind-mounted **into** that directory | `/run/pulse/native` = `PULSE_SERVER=unix:/run/pulse/native` | `edy-rdp-pulse-bind` at guacd start if the seat is already logged in; `edy-rdp-pulse-seat@<uid>.path` → `edy-rdp-pulse-rebind@<uid>.service` at every login; `deploy.sh --with-units` starts the rebind service once for a seat logged in at deploy time |

A mount event under a shared source propagates into every slave of that mount,
including the one inside the running container, so a bind done **after** the
container started shows up inside it as `/run/pulse/native` with no restart:
audio works for the next session. `edy-rdp-pulse-bind` compares device:inode, so
the path unit firing more than once per login (it does — the pid file, the socket
and the cli socket are each a change) is a no-op, and a new login whose socket has
a new inode releases the stale bind and re-binds.

### Why `PathChanged=` on the directory, not `PathExists=` on the socket

`PathExists=` is re-evaluated the instant the triggered oneshot exits. While the
socket exists that is true again, so systemd starts the service again — five
starts in about 100 ms, `StartLimitBurst` is hit, and **the path unit itself
fails** (systemd.path(5), "protection against busy looping"). Enabling it while
the seat is logged in — the normal case for `deploy.sh --with-units` — killed the
watch within a second and nothing rebound at the next login, with the unit
looking enabled. `PathChanged=/run/user/<uid>/pulse` is an inotify watch: it fires
once per event, never for a state. systemd watches the nearest existing ancestor
while `/run/user/<uid>` is absent and re-arms as each component appears at login,
so the creation of `native` is always seen. The corollary is that a socket which
already exists when the watch starts never fires it; guacd's `ExecStartPre`
covers boot-with-seat-logged-in, and `deploy.sh --with-units` runs
`systemctl start edy-rdp-pulse-rebind@<uid>.service` once after enabling the
path unit.

### Why `ro,rslave`, and what `edy-rdp-pulse-bind` refuses

guacd is root inside a rootful container whose attack surface is every RDP/VNC
server it dials, including operator-chosen remote hosts. The container therefore
gets the directory **read-only** and as a **slave**: mounts flow host → container
and never back (`rshared` on the container side would have made the container's
mount a full peer of the host's), and a compromised guacd cannot write into the
host directory root's next bind reads from. `connect()` on a unix socket needs no
write permission on the *mount* — the kernel's read-only check exempts sockets,
which is why `docker.sock:ro` works — so audio loses nothing.

On the host side the script runs as root and mounts what it finds under a
directory the **seat user** owns. `-S`, `stat -L` and `mount --bind` all follow
symlinks, so before it binds anything it checks with `lstat` and refuses, naming
the path: `/run/user/<uid>`, `/run/user/<uid>/pulse` or the socket being a
symlink; the source not being a socket **owned by the seat uid** (the same rule
applies to an `EDY_RDP_PULSE_SEAT_SOCKET` override); the target `native` being a
symlink or anything other than a mountpoint or the empty root-owned file the
script itself creates. After the bind it re-reads the target and undoes the mount
if it is not the socket it vetted. `--check` applies the same vetting without
root, so `tests/installer_tests.sh` proves each refusal.

`edy-rdp-pulse-bind` is **not** `-`-prefixed in the guacd unit: an absent seat
socket is exit 0 ("no audio until login"); a refused source or target, or a real
mount failure, stops the unit. The propagation claim is a design argument until it
is re-tested live on edt1 (**live verification pending**, I42); the script's
one-line outcome in the journal is the diagnostic either way.

## One-time seat setup

1. **Find the sink the desktop plays to** (as the seat user):

   ```
   pactl get-default-sink
   # e.g. alsa_output.pci-0000_01_00.1.hdmi-stereo
   ```

   The source to record is that name with `.monitor` appended.

2. **Point guacd at it.** In the install's `.env`, set:

   ```
   PULSE_SERVER=unix:/run/pulse/native
   PULSE_SOURCE=alsa_output.pci-0000_01_00.1.hdmi-stereo.monitor
   ```

   then `systemctl restart edy-rdp-guacd`. The unit passes `PULSE_SERVER` and
   `PULSE_SOURCE` into the container with `-e PULSE_SERVER -e PULSE_SOURCE`; when
   `PULSE_SOURCE` is unset the audio channel simply never connects (the prior
   behaviour).

3. **Name the seat user.** `EDY_RDP_PULSE_SEAT_UID` (default `1000`) is the uid
   whose `/run/user/<uid>/pulse/native` carries the desktop audio. `deploy.sh
   --with-units` enables `edy-rdp-pulse-seat@<that uid>.path`; on a host you set
   up by hand:

   ```
   systemctl enable --now edy-rdp-pulse-seat@1000.path
   systemctl start edy-rdp-pulse-rebind@1000.service   # once: a seat already logged in
   systemctl status edy-rdp-pulse-seat@1000.path       # active (waiting)
   ```

   `EDY_RDP_PULSE_SEAT_SOCKET=/run/user/<uid>/pulse/native` is a full-path
   override that wins over the uid when set (a seat whose runtime dir is not
   under `/run/user`).

## Verifying

```
/usr/libexec/edy-rdp/edy-rdp-pulse-bind --check        # the plan, no root, no changes
mountpoint /run/edy-rdp-pulse/native                    # "is a mountpoint" once the seat is logged in
findmnt -o TARGET,PROPAGATION /run/edy-rdp-pulse        # must say shared
journalctl -t edy-rdp-pulse-bind                        # one line per outcome: bound / absent / FAIL
podman exec edy-rdp-guacd ls -l /run/pulse/native       # the socket, seen from inside
```

Verify the audio path without a browser, from the host, against the bound
socket (the exact endpoint guacd uses):

```
PULSE_SERVER=unix:/run/edy-rdp-pulse/native pactl info
PULSE_SERVER=unix:/run/edy-rdp-pulse/native parec -d <sink>.monitor >/dev/null
# while something is playing, parec should stream bytes (Ctrl-C to stop)
```

## Upgrading from 1.3.x

- `PULSE_SERVER=unix:/run/pulse.sock` is **refused** by `.env` validation as a
  stale 1.3.x value; change it to `unix:/run/pulse/native` **before** running
  `deploy.sh`: its pre-flight validates the present keys of the live `.env` and
  stops with `DEPLOY FAILED (pre-flight)` while the host is still untouched,
  rather than after the payload alias has swapped (I43).
- The old target `/run/edy-rdp-pulse.sock` (a 0-byte file on tmpfs) is left
  alone; it is gone at the next reboot.
- Remove the stale `~/.config/pipewire/pipewire-pulse.conf.d/20-edy-tcp.conf`
  in the seat user's home if it exists: it is the loopback TCP listener on 4713
  left by the earlier TCP attempt, superseded by the socket design, and it
  exposes pipewire-pulse to every local uid for no benefit (KNOWN_ISSUES I44).
  Then `systemctl --user restart pipewire-pulse` as the seat user.

## Notes

- A **suspended** sink (nothing playing) produces no samples; the monitor wakes
  and streams as soon as the desktop plays audio. There is a brief resume delay
  when the sink transitions `SUSPENDED → RUNNING`, so the first fraction of a
  second after playback starts can be silent — this is normal.
- **Mute is per-viewer, at the browser.** Unchecking Sound stops playback for that
  viewer (and drops the audio channel on reconnect). It deliberately does **not**
  mute the seat's OS sink: muting the sink would also silence the `.monitor` guacd
  records, which would defeat the stream rather than just quiet the viewer.
