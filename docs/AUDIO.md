# Desktop audio streaming (the "Sound" toggle)

The browser mirror can stream the seat's **desktop audio** — what is playing on
the physical monitor's speakers — to the viewer. It is **off by default** and
gated by the plugin's **Sound** checkbox (check it *before* connecting).

## Path

```
desktop app → PipeWire/PulseAudio (default sink) → its .monitor source
           → guacd (records @DEFAULT_MONITOR@) → Guacamole audio stream
           → browser (Web Audio, gated live by the Sound toggle)
```

guacd runs in a container on the **host network**, so it reaches the seat's
PulseAudio over loopback. It records PulseAudio's *default source*; we point it at
`@DEFAULT_MONITOR@` (the **default sink's monitor**) so it captures desktop
**output**, not a microphone. There is **no** microphone/audio-input path — the
browser→session leg is VNC, which has no audio input.

## One-time seat setup

1. **Expose the seat's PipeWire-Pulse over loopback TCP.** As the seat user, drop
   in `~/.config/pipewire/pipewire-pulse.conf.d/20-edy-tcp.conf`:

   ```
   pulse.cmd = [
       { cmd = "load-module" args = "module-native-protocol-tcp listen=127.0.0.1 port=4713 auth-anonymous=true auth-ip-acl=127.0.0.1" }
   ]
   ```

   then `systemctl --user restart pipewire-pulse` and confirm
   `ss -tlnH | grep 127.0.0.1:4713`. Loopback-only + anonymous is safe on a
   trusted host: nothing off-box can reach `127.0.0.1:4713`.

2. **Point guacd at it.** In the install's `.env`, set:

   ```
   PULSE_SERVER=tcp:127.0.0.1:4713
   PULSE_SOURCE=@DEFAULT_MONITOR@
   ```

   then `systemctl restart edy-rdp-guacd`. The unit passes both into the
   container with `-e PULSE_SERVER -e PULSE_SOURCE`; when they are unset the audio
   channel simply never connects (the prior behaviour).

## Notes

- **TCP, not a bind-mounted socket, on purpose.** guacd is an always-on system
  service; a TCP endpoint keeps it independent of the user session's socket
  lifetime. If the seat's Pulse is down, guacd starts fine and audio just fails
  gracefully.
- A **suspended** sink (nothing playing) produces no samples; the monitor wakes
  and streams as soon as the desktop plays audio.
- Verify the path without a browser:
  `PULSE_SERVER=tcp:127.0.0.1:4713 pactl info` and
  `parec --server=tcp:127.0.0.1:4713 -d @DEFAULT_MONITOR@ out.wav`.
