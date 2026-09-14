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
container's uid cannot traverse. The unit therefore bind-mounts the **socket file
itself** to a stable host path (`/run/edy-rdp-pulse.sock`) and passes that into
the container as `unix:/run/pulse.sock`. If the seat socket is absent, an empty
regular file is left at the target so the `-v` bind still resolves and guacd just
fails to connect audio (no audio, no crash).

## One-time seat setup

1. **Find the sink the desktop plays to** (as the seat user):

   ```
   pactl get-default-sink
   # e.g. alsa_output.pci-0000_01_00.1.hdmi-stereo
   ```

   The source to record is that name with `.monitor` appended.

2. **Point guacd at it.** In the install's `.env`, set:

   ```
   PULSE_SERVER=unix:/run/pulse.sock
   PULSE_SOURCE=alsa_output.pci-0000_01_00.1.hdmi-stereo.monitor
   ```

   If the seat user is not uid 1000, also set the socket the unit bind-mounts:

   ```
   EDY_RDP_PULSE_SEAT_SOCKET=/run/user/<uid>/pulse/native
   ```

   then `systemctl restart edy-rdp-guacd`. The unit passes `PULSE_SERVER` and
   `PULSE_SOURCE` into the container with `-e PULSE_SERVER -e PULSE_SOURCE`; when
   `PULSE_SOURCE` is unset the audio channel simply never connects (the prior
   behaviour).

## Notes

- A **suspended** sink (nothing playing) produces no samples; the monitor wakes
  and streams as soon as the desktop plays audio. There is a brief resume delay
  when the sink transitions `SUSPENDED → RUNNING`, so the first fraction of a
  second after playback starts can be silent — this is normal.
- Verify the path without a browser, from the host, against the bind-mounted
  socket (the exact endpoint guacd uses):

  ```
  PULSE_SERVER=unix:/run/edy-rdp-pulse.sock pactl info
  PULSE_SERVER=unix:/run/edy-rdp-pulse.sock parec -d <sink>.monitor >/dev/null
  # while something is playing, parec should stream bytes (Ctrl-C to stop)
  ```

- **Mute is per-viewer, at the browser.** Unchecking Sound stops playback for that
  viewer (and drops the audio channel on reconnect). It deliberately does **not**
  mute the seat's OS sink: muting the sink would also silence the `.monitor` guacd
  records, which would defeat the stream rather than just quiet the viewer.
