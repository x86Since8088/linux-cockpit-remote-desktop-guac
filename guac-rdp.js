// SPDX-License-Identifier: BSD-3-Clause
//
// cockpit-guac-rdp frontend.
//
// Opens a Cockpit stream channel to the edy-rdp relay's AF_UNIX socket (NOT a
// TCP port — guacd is never on the host), speaks the Guacamole protocol to it,
// and renders with guacamole-common-js. The relay authenticates the peer
// (SO_PEERCRED), binds the session UUID to that user, enforces the console gate,
// and keepalives guacd. The browser never sees guacd, never sees a TCP port, and
// (in automatic mode) never sees the RDP gate key.
(function () {
    "use strict";

    var SOCK = "/run/edy-rdp/guacd.sock";     // relay ingress (bind-mounted)
    var RDP_HOST = "127.0.0.1"; // guacd runs in the host netns (nft-gated), so grd is on loopback

    // scenario -> { port, mode, admin } . The relay independently enforces the
    // admin gate; the marker below lets it identify the scenario authoritatively.
    var TARGETS = {
        isolated: { port: "3390", mode: null, managed: true,
            note: "Your own private desktop, separate from the console. Started on demand; the first connect can take ~20s." },
        virtual:  { port: "3389", mode: "extend",
            note: "A new virtual monitor inside your session — an empty desktop, not a copy of the screen." },
        console:  { port: "3389", mode: "mirror-primary", admin: true,
            note: "A live mirror of the physical screen. Requires administrative access." },
        greeter:  { port: "3390", mode: null, admin: true,
            note: "The GDM login screen, in a session of its own. Not affected by the console being locked \u2014 sign in here to reach your desktop." },
        "wayland-vnc": { port: "", mode: null, managed: true,
            note: "Your own headless Wayland desktop (sway), served over VNC. Unaffected by the console being locked, and it runs alongside a local login. Started on demand." },
        vnc:      { port: "5900", mode: null, remote: true, vnc: true,
            note: "A VNC server on the network. guacd speaks VNC natively, so this connects straight through \u2014 no RDP bridge in the path." },
        remote:   { port: "3389", mode: null, remote: true,
            note: "RDP into another host on the network. Enter its address and your RDP credentials for that host." }
    };
    var CONTROL = "/run/edy-rdp/control.sock";
    // grd refuses console/virtual outright while the seat is locked ("Session
    // creation inhibited"). Matching that refusal lets the panel explain what to
    // do about it. It deliberately does NOT redirect to the greeter: the greeter
    // starts a NEW session and cannot attach to the locked one, so it resets the
    // login rather than resuming it.
    var LOCKED_SEAT_RE = /physical screen is locked/i;
    var KEEPALIVE_MS = 4000;
    var currentUuid = null;

    // One request/response over the relay's control socket (newline-delimited JSON).
    function controlRequest(obj) {
        return new Promise(function (resolve, reject) {
            var ch, buf = "", done = false;
            try { ch = cockpit.channel({ payload: "stream", unix: CONTROL }); }
            catch (e) { reject(e); return; }
            function finish(v, err) { if (done) return; done = true; try { ch.close(); } catch (e) {} err ? reject(err) : resolve(v); }
            ch.addEventListener("message", function (ev, payload) {
                buf += (typeof payload === "string") ? payload : new TextDecoder("utf-8").decode(payload);
                var nl = buf.indexOf("\n");
                if (nl >= 0) { try { finish(JSON.parse(buf.slice(0, nl))); } catch (e) { finish(null, e); } }
            });
            ch.addEventListener("close", function (ev, options) {
                if (!done) { if (buf.trim()) { try { return finish(JSON.parse(buf.trim())); } catch (e) {} }
                             finish(null, (options && options.problem) || "control channel closed"); }
            });
            ch.send(JSON.stringify(obj) + "\n");
        });
    }

    function $(id) { return document.getElementById(id); }
    // guacd VNC parameters. Both the clipboard and the audio channels are ALWAYS
    // negotiated with guacd so the Clipboard/Sound toggles can gate them LIVE in
    // the browser -- with no reconnect -- rather than only at connect:
    //   * clipboard: client.onclipboard (remote->browser) and a focus reader
    //     (browser->remote) honour the live clipboardOn flag; the browser's own
    //     clipboard is only ever touched while the toggle is on.
    //   * sound: playback is gated by suspending/resuming the shared Guacamole
    //     AudioContext (instant, mid-stream). guacd simply produces silence when
    //     the deployment has no audio source, so always offering it is harmless.
    // We deliberately do NOT set disable-copy/disable-paste here: those are fixed
    // at connect and would defeat a live toggle. The gate lives in the browser.
    function guacdValues() {
        var v = {};
        // Negotiate the audio channel ONLY when Sound is on at connect. Forcing it
        // on unconditionally made guacd attempt (and log a failed) PulseAudio
        // connection on every session and was implicated in a login-screen
        // regression, so it is opt-in again. Live mute/unmute via the shared
        // AudioContext still applies while connected; turning Sound on from off
        // takes effect on the next connect.
        if ($("opt-audio") && $("opt-audio").checked) v["enable-audio"] = "true";
        return v;
    }

    // Live gate flags for the Sound/Clipboard toggles (mirrored from the checkboxes).
    var clipboardOn = true, soundOn = false, clipReadHandler = null;
    function syncPassthroughFlags() {
        clipboardOn = !$("opt-clipboard") || $("opt-clipboard").checked;
        soundOn = !!($("opt-audio") && $("opt-audio").checked);
    }
    // Sound gate: suspend/resume Guacamole's shared AudioContext. suspend() mutes
    // playback instantly, mid-stream; resume() is driven from the toggle's own
    // click (a user gesture), which satisfies browser autoplay policy.
    function applySoundGate() {
        try {
            var f = Guacamole.AudioContextFactory;
            var ctx = f && f.getAudioContext && f.getAudioContext();
            if (!ctx) return;
            if (soundOn) { if (ctx.state === "suspended" && ctx.resume) ctx.resume(); }
            else if (ctx.state === "running" && ctx.suspend) ctx.suspend();
        } catch (e) { /* no Web Audio in this context -> nothing to gate */ }
    }
    // Read and drop a text stream we will not use (clipboard toggled off).
    function discardTextStream(stream) {
        try { var r = new Guacamole.StringReader(stream); r.ontext = function () {}; r.onend = function () {}; }
        catch (e) { /* ignore */ }
    }

    // ---- "Add Monitor": a virtual monitor in its own chromeless window --------
    // Re-opens THIS Cockpit page in a minimal pop-up (no tabs, toolbar or address
    // bar) that auto-connects a fresh "virtual" monitor and fills the window. The
    // pop-up carries its OWN Cockpit transport (shared session cookie), so closing
    // it drops that transport -> the relay reaps the bridge and grd removes the
    // virtual (extend) monitor; an explicit terminate on close makes that instant.
    var MONITOR_MODE = /(?:^|[#&?])monitor\b/.test(location.hash);
    var monitorSeq = 0;
    function openMonitorWindow() {
        monitorSeq += 1;
        var suf = controlHashSuffix();   // inherit the current toggle/selector choices
        var url = location.href.split("#")[0] + "#monitor=" + monitorSeq + (suf ? "&" + suf : "");
        var feat = "popup=yes,menubar=no,toolbar=no,location=no,status=no,scrollbars=no,resizable=yes,width=1440,height=900";
        var w = window.open(url, "edy-monitor-" + monitorSeq + "-" + Date.now(), feat);
        if (!w) { setStatus("The browser blocked the monitor window — allow pop-ups for this site, then click Add Monitor again.", "err"); return; }
        try { w.focus(); } catch (e) { /* ignore */ }
    }
    function monitorTeardown() {
        // Close the virtual desktop when the window closes. The transport drop
        // reaps it on its own; terminate makes the removal immediate and explicit.
        try { if (currentUuid) controlRequest({ op: "terminate", uuid: currentUuid }); } catch (e) { /* best effort */ }
        try { teardown(true); } catch (e) { /* ignore */ }
    }
    // Move a control's whole .f wrapper out of the (hidden) main bar into the
    // chromeless top strip, so the pop-out windows can drive it. Each pop-out is
    // its own window/DOM, so this never affects the main window.
    function moveField(bar, id) {
        var el = $(id); if (!el || !bar) return;
        var f = (el.closest && el.closest(".f")) || el.parentNode;
        if (f) bar.appendChild(f);
    }
    function enterMonitorMode() {
        document.documentElement.classList.add("monitor");
        var m = location.hash.match(/monitor=(\d+)/);
        document.title = "Virtual Monitor" + (m ? " " + m[1] : "") + " — " + location.hostname;
        window.addEventListener("pagehide", monitorTeardown);
        window.addEventListener("beforeunload", monitorTeardown);
        // top control strip: Resolution + Sound (grd honours the resolution for a
        // virtual monitor). Moved out of the hidden main bar.
        var bar = document.createElement("div"); bar.id = "seatbar";
        document.body.appendChild(bar);
        moveField(bar, "resolution");
        moveField(bar, "opt-audio");
        $("target").value = "virtual";
        refreshUi();
        connect("virtual");
    }

    // ---- "Pop-out": the mirrored physical seat in its own chromeless window ----
    // Like Add Monitor, but for the CONSOLE mirror, with a picker of the seat's
    // physical monitors. Closing the window only DISCONNECTS this view; it never
    // terminates the physical desktop.
    var SEAT_MODE = /(?:^|[#&?])seat\b/.test(location.hash);
    function openSeatWindow() {
        var suf = controlHashSuffix();   // inherit the current toggle/selector choices
        var url = location.href.split("#")[0] + "#seat" + (suf ? "&" + suf : "");
        var feat = "popup=yes,menubar=no,toolbar=no,location=no,status=no,scrollbars=no,resizable=yes,width=1600,height=1000";
        var w = window.open(url, "edy-seat-" + Date.now(), feat);
        if (!w) { setStatus("The browser blocked the pop-out window — allow pop-ups for this site, then click Pop-out again.", "err"); return; }
        try { w.focus(); } catch (e) { /* ignore */ }
    }
    function seatTeardown() {
        // The mirror IS the physical seat: never terminate it, just drop this view.
        try { teardown(true); } catch (e) { /* ignore */ }
    }
    function populateSeatMonitors(sel) {
        if (!sel || typeof cockpit === "undefined") return;
        cockpit.spawn(["gdbus", "call", "--session", "--dest", "org.gnome.Mutter.DisplayConfig",
                       "--object-path", "/org/gnome/Mutter/DisplayConfig",
                       "--method", "org.gnome.Mutter.DisplayConfig.GetCurrentState"], { err: "message" })
        .then(function (out) {
            // Physical connectors read as 'HDMI-3' / 'DP-1' / 'eDP-1'; grd's own
            // outputs read as 'Virtual remote monitor' (spaces) and are skipped.
            var names = [], re = /'([A-Za-z]+-[0-9]+(?:-[0-9]+)?)'/g, m;
            while ((m = re.exec(out))) { if (names.indexOf(m[1]) < 0) names.push(m[1]); }
            sel.innerHTML = "";
            (names.length ? names : ["(single monitor)"]).forEach(function (n) {
                var o = document.createElement("option"); o.value = n; o.textContent = n; sel.appendChild(o);
            });
        }, function () {
            sel.innerHTML = ""; var o = document.createElement("option");
            o.textContent = "(monitor list unavailable)"; sel.appendChild(o);
        });
    }
    function enterSeatMode() {
        document.documentElement.classList.add("monitor", "seat");
        document.title = "Physical Monitor — " + location.hostname;
        window.addEventListener("pagehide", seatTeardown);
        window.addEventListener("beforeunload", seatTeardown);
        // a slim monitor picker overlaid on the mirror
        var bar = document.createElement("div"); bar.id = "seatbar";
        var lbl = document.createElement("span"); lbl.textContent = "Physical monitor:";
        var sel = document.createElement("select"); sel.id = "seatmon";
        var o0 = document.createElement("option"); o0.textContent = "Detecting…"; sel.appendChild(o0);
        bar.appendChild(lbl); bar.appendChild(sel); document.body.appendChild(bar);
        sel.addEventListener("change", function () {
            // grd mirrors the PRIMARY monitor, so reconnect to reflect the current
            // seat. (Mirroring a specific non-primary output needs a grd capability
            // that does not exist yet; the picker is here for when it does.)
            if (client) { setStatus("Switching monitor…"); teardown(true); window.setTimeout(function () { connect("console"); }, 80); }
        });
        populateSeatMonitors(sel);
        moveField(bar, "opt-audio");   // Sound control (resolution N/A: mirror is native)
        $("target").value = "console";
        refreshUi();
        connect("console");
    }

    // Display scale. "fit" recomputes on resize; a fixed factor does not, which is
    // the point -- an operator pinning 100% wants pixel-exact, not helpfully resized.
    var scaleMode = "fit";
    var activeKey = null;   // scenario of the live session, for reconnect-on-change
    // The factor currently applied via display.scale(). The bundled
    // Guacamole.Mouse maps pointer events through the display element's LAYOUT
    // box (offsetLeft/offsetParent) WITHOUT dividing by the scale, and
    // display.scale(f) sets that element's layout size to guest*f -- so the mouse
    // state arrives in RENDERED pixels (0..guest*f). We divide by curScale before
    // sendMouseState to get guest pixels, keeping the pointer aligned at any zoom
    // and after every resize. curScale MUST track exactly what we pass to scale().
    var curScale = 1;

    function applyScale() {
        if (!client) return;
        var d = client.getDisplay();
        if (!d || !d.getWidth()) return;
        var s;
        if (scaleMode === "fit") {
            var box = $("display");
            var w = box.clientWidth || d.getWidth();
            var h = box.clientHeight || d.getHeight();
            s = Math.min(w / d.getWidth(), h / d.getHeight()) || 1;
        } else {
            s = parseFloat(scaleMode) || 1;
        }
        curScale = s;
        d.scale(s);
    }

    // Translate a Guacamole.Mouse.State from rendered pixels to guest pixels using
    // the live scale, preserving buttons and scroll. See curScale above.
    function guestMouseState(st) {
        var s = curScale || 1;
        return new Guacamole.Mouse.State(
            Math.round(st.x / s), Math.round(st.y / s),
            st.left, st.middle, st.right, st.up, st.down);
    }

    // The native framebuffer resolution grd mirrors (mirror-primary = the primary
    // monitor's current mode). We request THIS as the RDP geometry for the mirror
    // so the whole internal path (grd -> xfreerdp -> Xvfb -> x11vnc -> guacd) runs
    // 1:1 at native resolution with NO server-side scaling, and the browser does
    // all the scaling. Resolves to {w,h}, or null (fall back to the window size)
    // if it cannot be determined -- so a parse miss never blocks a connect.
    function queryNativeGeom() {
        return cockpit.spawn(["gdbus", "call", "--session", "--dest", "org.gnome.Mutter.DisplayConfig",
                              "--object-path", "/org/gnome/Mutter/DisplayConfig",
                              "--method", "org.gnome.Mutter.DisplayConfig.GetCurrentState"], { err: "message" })
            .then(function (out) {
                // Mode ids read '1920x1080@60.000'; the active one is tagged
                // 'is-current': <true>. Take the last mode id before that marker.
                var cur = out.search(/'is-current':\s*<true>/);
                if (cur < 0) return null;
                var re = /'(\d+)x(\d+)@[\d.]+'/g, m, best = null;
                while ((m = re.exec(out)) && m.index < cur) best = m;
                return best ? { w: parseInt(best[1], 10), h: parseInt(best[2], 10) } : null;
            })
            .catch(function () { return null; });
    }

    // Resolution the session should render at, from the toolbar selector.
    //   "Window size" -> the mirror uses the native-capped policy (start() downscales
    //                    below native); other scenarios use the window size.
    //   a fixed WxH   -> pin the guest framebuffer to exactly that (browser scales it).
    function chosenGeom(key) {
        // grd's mirror-primary ALWAYS streams the primary at its native resolution
        // and ignores a smaller requested size, so the Xvfb must be native or the
        // frame is clipped (right/bottom cut off). The console mirror therefore
        // always requests native (exact) and the browser scales it. The Resolution
        // selector applies to the virtual monitor (grd honours it there) and remote.
        if (key === "console")
            return queryNativeGeom().then(function (g) { return g ? { w: g.w, h: g.h, exact: true } : null; });
        var sel = $("resolution"), m = /^(\d+)x(\d+)$/.exec(sel ? sel.value : "window");
        return cockpit.resolve(m ? { w: parseInt(m[1], 10), h: parseInt(m[2], 10), exact: true } : null);
    }

    function setStatus(msg, kind) { var e = $("status"); e.textContent = msg; e.className = "status" + (kind ? " " + kind : ""); }

    // Unlocking the seat is the ONLY way to resume the session the user left.
    // The greeter starts a new one; Wayland VNC and Isolated are separate
    // desktops; grd refuses console/virtual outright while locked. So when that
    // refusal appears, put the action next to the message instead of describing
    // a command and leaving the operator to go find a terminal.
    function offerUnlock(retryKey) {
        if (!isAdmin) return;                     // the relay refuses it anyway
        var bar = $("status");
        if (bar.querySelector(".unlock-retry")) return;   // one button, not one per failure
        var b = document.createElement("button");
        b.className = "unlock-retry";
        b.style.marginLeft = "0.6rem";
        b.textContent = "Unlock the physical session and retry";
        b.addEventListener("click", function () {
            b.disabled = true;
            setStatus("Unlocking the physical session\u2026");
            controlRequest({ op: "unlock" }).then(function (r) {
                if (r && r.ok) {
                    setStatus("Unlocked. Reconnecting\u2026");
                    window.setTimeout(function () { connect(retryKey); }, 500);
                } else {
                    var why = (r && (r.detail || r.error)) || "the server refused";
                    setStatus("Could not unlock: " + why, "err");
                }
            }, function (e) {
                setStatus("Could not unlock: " + e, "err");
            });
        });
        bar.appendChild(b);
    }
    var enc = GuacProto.enc, drain = GuacProto.drain;

    // ---- a Guacamole.Tunnel over a Cockpit unix stream channel --------------
    function CockpitRelayTunnel(params) {
        Guacamole.Tunnel.call(this);
        var self = this, channel = null, buffer = "", ready = false, keepalive = null;
        var decoder = new TextDecoder("utf-8");

        function raw(str) { if (channel) { try { channel.send(str); } catch (e) { /* closed */ } } }

        function handle(elements) {
            var op = elements[0];
            if (!ready) {
                if (op === "args") {
                    var names = elements.slice(1);
                    raw(enc("size", params.width, params.height, params.dpi));
                    raw(enc("audio")); raw(enc("video")); raw(enc("image"));
                    var vals = names.map(function (n) {
                        if (/^VERSION_/.test(n)) return n;
                        return params.values[n] !== undefined ? params.values[n] : "";
                    });
                    // Append the scenario marker (relay strips + gates on it) and,
                    // for non-managed scenarios, the RDP gate credential as rdpcred
                    // (relay strips it and hands it to the FreeRDP3 bridge, never guacd).
                    var extra = ["scenario=" + params.scenario];
                    if (params.rdpcred) extra.push("rdpcred=" + params.rdpcred);
                    if (params.remotehost) extra.push("remotehost=" + params.remotehost);
                    if (params.sessiontoken) extra.push("sessiontoken=" + params.sessiontoken);
                    raw(enc.apply(null, ["connect"].concat(vals).concat(extra)));
                    return;
                }
                if (op === "ready") {
                    ready = true; self.setUUID(elements[1]);
                    self.setState(Guacamole.Tunnel.State.OPEN);
                    keepalive = setInterval(function () { raw(enc("nop")); }, KEEPALIVE_MS);
                    return;
                }
            }
            if (op === "error") {
                if (self.onerror) self.onerror({ message: elements.slice(1).join(" "), code: 0 });
                self.setState(Guacamole.Tunnel.State.CLOSED);
                return;
            }
            if (self.oninstruction) self.oninstruction(op, elements.slice(1));
        }

        this.connect = function () {
            buffer = ""; ready = false;
            self.setState(Guacamole.Tunnel.State.CONNECTING);
            channel = cockpit.channel({ payload: "stream", unix: SOCK });  // text mode (NOT binary:"raw")
            channel.addEventListener("message", function (ev, payload) {
                buffer += (typeof payload === "string") ? payload : decoder.decode(payload);
                try { buffer = drain(buffer, handle); }
                catch (e) { if (self.onerror) self.onerror({ message: "protocol error: " + e, code: 0 }); }
            });
            channel.addEventListener("close", function (ev, options) {
                if (keepalive) { clearInterval(keepalive); keepalive = null; }
                if (options && options.problem && self.onerror)
                    self.onerror({ message: "relay channel closed (" + options.problem + ")", code: 0 });
                self.setState(Guacamole.Tunnel.State.CLOSED);
            });
            raw(enc("select", "vnc"));  // guacd VNC plugin -> the relay's FreeRDP3 bridge
        };
        this.sendMessage = function () { if (ready) raw(enc.apply(null, Array.prototype.slice.call(arguments))); };
        this.disconnect = function () {
            if (keepalive) { clearInterval(keepalive); keepalive = null; }
            try { if (channel) channel.close(); } catch (e) { /* gone */ }
            channel = null; self.setState(Guacamole.Tunnel.State.CLOSED);
        };
    }
    CockpitRelayTunnel.prototype = new Guacamole.Tunnel();

    // ---- credential fetch (server-side; never rendered) ---------------------
    function fetchGateKey(port) {
        if (port === "3389") {
            // 3389 lives in this user's own keyring; plain grdctl does NOT pkexec.
            return cockpit.spawn(["grdctl", "status", "--show-credentials"], { err: "message" })
                .then(function (out) {
                    var u = /^\s*Username:\s*(.+)$/m.exec(out), p = /^\s*Password:\s*(.+)$/m.exec(out);
                    if (!u || !p || u[1].trim() === "(null)" || p[1].trim() === "(null)")
                        throw new Error("no gate credential set for port 3389");
                    return { username: u[1].trim(), password: p[1].trim() };
                });
        }
        // 3390 gate key is root-owned; read the file via the privileged bridge
        // (deliberately NOT `grdctl --system`, which re-execs through pkexec).
        return cockpit.file("/var/lib/gnome-remote-desktop/.local/share/gnome-remote-desktop/credentials.ini",
                            { superuser: "require" }).read()
            .then(function (text) {
                var u = /'username':\s*<'([^']*)'>/.exec(text || ""), p = /'password':\s*<'([^']*)'>/.exec(text || "");
                if (!u || !p) throw new Error("could not read the stored gate credential");
                return { username: u[1], password: p[1] };
            });
    }

    // ---- connect flow -------------------------------------------------------
    var client = null, tunnel = null, keyboard = null, isAdmin = false;

    // Lock-key (NumLock/CapsLock/ScrollLock) sync state. remoteLocks models the
    // lock state the SESSION currently has (baseline all-off, a fresh bridge);
    // browserLocks is the last-seen browser state (null until first observed);
    // lockSyncHandler is the capture-phase keydown listener. See the keyboard
    // block for how they interact with the on-screen Num Lock toggle.
    var remoteLocks = null, browserLocks = null, lockSyncHandler = null;
    var LOCK_KEYSYM = { NumLock: 0xFF7F, CapsLock: 0xFFE5, ScrollLock: 0xFF14 };

    // Send a lock key (press+release) into the session. It rides the normal key
    // path (guacd -> x11vnc XTEST -> Xvfb -> xfreerdp3 -> grd), toggling the lock
    // at every hop, including grd's own RDP lock sync.
    function sendLockKeysym(name) {
        if (!client || !LOCK_KEYSYM[name]) return;
        client.sendKeyEvent(1, LOCK_KEYSYM[name]);
        client.sendKeyEvent(0, LOCK_KEYSYM[name]);
    }
    // Reflect the session's NumLock state on the on-screen toggle button.
    function updateLockButtons() {
        var b = $("numlock");
        if (!b) return;
        var on = !!(remoteLocks && remoteLocks.NumLock);
        b.classList.toggle("on", on);
        b.setAttribute("aria-pressed", on ? "true" : "false");
    }
    // Toggle a session lock from the on-screen control, independent of the
    // physical keyboard (for laptops/keyboards without a numpad, or browsers that
    // will not forward NumLock). It moves the SESSION but NOT browserLocks, and
    // the auto-sync only mirrors CHANGES to the browser's locks, so a manual
    // toggle is never reverted by the next keystroke.
    function toggleSessionLock(name) {
        if (!client || !remoteLocks) return;
        sendLockKeysym(name);
        remoteLocks[name] = !remoteLocks[name];
        updateLockButtons();
        try { $("display").focus(); } catch (e) {}   // keep typing landing in the session
    }

    var disposing = false;

    // Graceful: send the Guacamole "disconnect" to the backend (relay -> guacd ->
    // grd) and let it tear the RDP session down, THEN dispose the browser side.
    // immediate=true skips the wait (used when the backend already closed / errored).
    function teardown(immediate) {
        if (disposing) return;
        disposing = true;
        if (keyboard) { keyboard.onkeydown = keyboard.onkeyup = null; keyboard = null; }
        var lockBox = $("display");
        if (lockBox && lockSyncHandler) lockBox.removeEventListener("keydown", lockSyncHandler, true);
        if (lockBox && clipReadHandler) lockBox.removeEventListener("focus", clipReadHandler, true);
        lockSyncHandler = null; clipReadHandler = null; remoteLocks = null; browserLocks = null;
        if ($("numlock")) {
            $("numlock").disabled = true;
            $("numlock").classList.remove("on");
            $("numlock").setAttribute("aria-pressed", "false");
        }

        function dispose() {
            try { if (tunnel) tunnel.disconnect(); } catch (e) { /* ignore */ }
            client = null; tunnel = null; disposing = false; currentUuid = null;
            // Reload the guac web element: tear the old canvas out so a fresh
            // connect starts clean (the display is re-created on next connect).
            var box = $("display"); if (box) box.innerHTML = "";
            $("go").disabled = false; $("stop").disabled = true;
            if ($("pass")) $("pass").value = "";
        }

        if (immediate || !client) { dispose(); return; }

        // client.disconnect() emits the "disconnect" instruction to the backend.
        try { client.disconnect(); } catch (e) { /* ignore */ }
        // dispose once the tunnel confirms CLOSED, or after a short grace period.
        var done = false;
        function finish() { if (done) return; done = true; dispose(); }
        if (tunnel) tunnel.onstatechange = function (st) {
            if (st === Guacamole.Tunnel.State.CLOSED) finish();
        };
        setTimeout(finish, 800);
    }

    // Register into the relay's session table (SO_PEERCRED-bound). Returns a strong
    // desktop-session token that travels end-to-end (correlation id + gate). For an
    // admin scenario we PROVE administrator mode SERVER-SIDE: read a root-only
    // challenge over a superuser Cockpit channel (only an elevated session can) and
    // echo it back via "elevate" — closing the cosmetic client-check (I4).
    function registerSession(needAdmin) {
        return controlRequest({ op: "register" }).then(function (r) {
            if (!r || !r.ok || !r.token) return { token: null, admin: false };
            if (!needAdmin || !r.challenge_path) return { token: r.token, admin: false };
            return cockpit.file(r.challenge_path, { superuser: "require" }).read()
                .then(function (c) {
                    c = (c || "").trim();
                    if (!c) return { token: r.token, admin: false };
                    return controlRequest({ op: "elevate", token: r.token, challenge: c })
                        .then(function (e) { return { token: r.token, admin: !!(e && e.admin) }; });
                })
                .catch(function () { return { token: r.token, admin: false }; });  // not elevated
        }).catch(function () { return { token: null, admin: false }; });
    }

    function connect(forceKey) {
        var key = forceKey || $("target").value, t = TARGETS[key];
        // A user-initiated connect re-arms the one-shot locked-seat fallback; the
        // fallback itself passes forceKey, so it can never re-arm and loop.
        $("go").disabled = true;
        // Remote is admin-gated only if the server sets EDY_RDP_REMOTE_ADMIN_ONLY;
        // prove admin when the Cockpit session is already elevated (no polkit prompt
        // for non-admins), otherwise register a plain token and let the relay decide.
        var needAdmin = !!t.admin || (key === "remote" && isAdmin);
        setStatus(needAdmin ? "Proving administrator mode…" : "Registering session…");
        registerSession(needAdmin).then(function (reg) {
            if (t.admin && !reg.admin) {
                setStatus((key === "console" ? "Console" : "This session")
                    + " needs administrative access — turn on Administrative access "
                    + "in Cockpit's header, then retry.", "err");
                $("go").disabled = false;
                return;
            }
            var creds;
            if (t.managed) {
                // Isolated: the relay injects THIS user's own headless-session target
                // and an ephemeral credential from the SO_PEERCRED identity. The
                // browser supplies nothing and never sees a credential.
                setStatus("Starting your isolated session… (the first connect can take ~20s)");
                creds = cockpit.resolve({ username: "", password: "" });
            } else if (key === "vnc") {
                var vh = $("host").value.trim();
                var vp = ($("port").value || "").toString().trim();
                var vpw = $("pass").value;
                if (!/^\d{1,3}(\.\d{1,3}){3}$/.test(vh)) { setStatus("Enter the VNC host as an IPv4 address (e.g. 192.168.2.20).", "err"); $("go").disabled = false; return; }
                if (vp && !/^\d{1,5}$/.test(vp)) { setStatus("Port must be a number between 1 and 65535.", "err"); $("go").disabled = false; return; }
                // A password is optional: a VNC server may have auth disabled.
                creds = cockpit.resolve({ username: "", password: vpw });
            } else if (key === "remote") {
                // Remote host RDP: user supplies target + their own credential for that
                // host. Client-side validation is a hint; the relay authoritatively
                // validates the IPv4:port and enforces the remote allow-list.
                var rh = $("host").value.trim();
                var rp = ($("port").value || "").toString().trim();
                var ru = $("user").value.trim(), rpw = $("pass").value;
                if (!/^\d{1,3}(\.\d{1,3}){3}$/.test(rh)) { setStatus("Enter the remote host as an IPv4 address (e.g. 192.168.2.20).", "err"); $("go").disabled = false; return; }
                if (rp && !/^\d{1,5}$/.test(rp)) { setStatus("Port must be a number between 1 and 65535.", "err"); $("go").disabled = false; return; }
                if (!ru || !rpw) { setStatus("Enter the RDP username and password for the remote host.", "err"); $("go").disabled = false; return; }
                creds = cockpit.resolve({ username: ru, password: rpw });
            } else if ($("authmode").value === "manual") {
                var u = $("user").value.trim(), pw = $("pass").value;
                if (!u || !pw) { setStatus("Enter the RDP username and password, or switch to automatic sign-in.", "err"); $("go").disabled = false; return; }
                creds = cockpit.resolve({ username: u, password: pw });
            } else {
                setStatus("Fetching the session key from the server…");
                creds = fetchGateKey(t.port);
            }
            ensureMode(key).then(function () { return creds; })
                .then(function (cred) {
                    // Geometry from the Resolution selector (Window size vs a pinned
                    // resolution); the mirror's "Window size" is native-capped.
                    return chosenGeom(key)
                        .then(function (geom) { start(key, cred, reg.token, geom); });
                })
                .catch(function (e) {
                    var msg = (e && e.message) || String(e);
                    if (/not-authorized|access-denied|superuser|not permitted|permission denied/i.test(msg))
                        msg = "this key is held by the server and reading it needs administrative access. " +
                              "Turn on Administrative access, or sign in as a specific user.";
                    setStatus("Could not start: " + msg, "err"); $("go").disabled = false;
                });
        });
    }

    function ensureMode(key) {
        var want = TARGETS[key].mode;
        if (!want) return cockpit.resolve();
        return cockpit.spawn(["gsettings", "get", "org.gnome.desktop.remote-desktop.rdp", "screen-share-mode"],
                             { err: "message" })
            .then(function (out) {
                if (out.trim().replace(/^'|'$/g, "") === want) return null;
                setStatus("Switching port 3389 to '" + want + "'…");
                return cockpit.spawn(["gsettings", "set", "org.gnome.desktop.remote-desktop.rdp",
                                      "screen-share-mode", want], { err: "message" });
            });
    }

    function start(key, cred, sessiontoken, geomOverride) {
        activeKey = key;
        var t = TARGETS[key], box = $("display");
        var winW = Math.max(box.clientWidth, 640), winH = Math.max(box.clientHeight, 480);
        // Geometry sent to the backend; the browser always scales the result to the
        // window (display.onresize -> applyScale). geomOverride:
        //   .exact -> a PINNED resolution from the selector: send it verbatim, and
        //             let the browser up/downscale it to the window.
        //   else   -> a native cap (the mirror's "Window size"): send min(window,
        //             native), so the server downscales BELOW native to cut network
        //             traffic (aspect preserved) and never sends more than native.
        // No override -> size to the window.
        var w, h;
        if (geomOverride && geomOverride.w && geomOverride.h) {
            if (geomOverride.exact) {
                w = geomOverride.w; h = geomOverride.h;
            } else {
                var s = Math.min(1, winW / geomOverride.w, winH / geomOverride.h);
                w = Math.max(1, Math.round(geomOverride.w * s));
                h = Math.max(1, Math.round(geomOverride.h * s));
            }
        } else {
            w = winW; h = winH;
        }
        // The relay injects the VNC target (the per-connection FreeRDP3 bridge); the
        // browser sends no target values. For non-managed scenarios the fetched/entered
        // RDP gate credential travels as rdpcred (0x1f separates user/pass), which the
        // relay strips for the bridge — guacd only ever sees a loopback VNC target.
        var rdpcred = t.managed ? null
            : ((cred.username || "") + "" + (cred.password || ""));
        var remotehost = (key === "remote" || key === "vnc")
            ? ($("host").value.trim() + ":" +
               (($("port").value || "").toString().trim() || (key === "vnc" ? "5900" : "3389")))
            : null;
        tunnel = new CockpitRelayTunnel({
            width: w, height: h, dpi: 96, scenario: key,
            rdpcred: rdpcred,
            remotehost: remotehost,               // "ip:port" for the remote scenario (relay-validated)
            sessiontoken: sessiontoken || null,   // end-to-end correlation + gate token
            // guacd's own VNC parameters. The tunnel fills the connect args from
            // this map by name, so a toggle here reaches guacd directly and the
            // relay needs no say in it -- it only rewrites hostname/port/password.
            values: guacdValues()
        });
        client = new Guacamole.Client(tunnel);
        var display = client.getDisplay();
        box.innerHTML = ""; box.appendChild(display.getElement());
        // Re-fit whenever the guest framebuffer size becomes known or changes. With
        // a native-resolution session this is what scales it into the window.
        display.onresize = function () { applyScale(); };

        // Clipboard passthrough (remote -> browser), gated live by the Clipboard
        // toggle. Best-effort: the browser Clipboard API can be restricted inside a
        // Cockpit iframe, so every access is guarded -- a denial degrades to "no
        // sync", never an error, and the OS clipboard is only written while ON.
        syncPassthroughFlags();
        client.onclipboard = function (stream, mimetype) {
            if (!clipboardOn || !/^text\//.test(mimetype || "text/plain")) { discardTextStream(stream); return; }
            var reader = new Guacamole.StringReader(stream), text = "";
            reader.ontext = function (t) { text += t; };
            reader.onend = function () {
                if (!clipboardOn) return;
                try { if (navigator.clipboard && navigator.clipboard.writeText) navigator.clipboard.writeText(text); }
                catch (e) { /* clipboard-write blocked */ }
            };
        };
        // Sound is negotiated (enable-audio); start it gated to the toggle's state.
        applySoundGate();

        var errored = false;
        function explain(prefix, e) {
            errored = true;
            var lockedSeat = false;
            var msg = (e && e.message) || "unknown error";
            if (/auth|credential|logon/i.test(msg))
                msg += "  — this is the RDP gate key for port " + t.port + ", not your own login.";
            if (/not permitted|admin/i.test(msg) && key === "console")
                msg += "  Console (mirror) requires administrative access.";
            // Locked seat: retry on the greeter door instead of dead-ending. Only
            // console/virtual can hit this, and only once per user-initiated
            // connect. NOTE the relay applies its locked-screen label to ANY bridge
            // failure while the seat is locked, so a mistyped credential arrives
            // wearing this message too; the greeter attempt then reports the real
            // problem itself rather than silently retrying forever.
            if (LOCKED_SEAT_RE.test(msg) && (key === "console" || key === "virtual")) {
                lockedSeat = true;   // the button is added AFTER setStatus below,
                                     // which replaces the status text and would
                                     // otherwise remove it again immediately.
                // Deliberately NOT an automatic fallback to the greeter. The
                // greeter starts a NEW session; it cannot attach to the locked
                // one, so it does not get you back to the desktop you left --
                // you would be resetting your login rather than resuming it.
                // Say what actually works and let the operator choose.
                msg += "  The Login screen option opens a NEW session rather than "
                     + "unlocking this one. Unlock below to resume the session you "
                     + "left, or use Wayland VNC or Isolated session for a separate "
                     + "desktop the lock does not affect.";
            }
            setStatus(prefix + ": " + msg, "err");
            // Offer the one action that actually resumes THIS session.
            if (lockedSeat) offerUnlock(key);
            teardown(true);
        }
        tunnel.onerror = function (e) { explain("Relay error", e); };
        client.onerror = function (e) { explain("RDP error", e); };
        tunnel.onstatechange = function (s) {
            if (s === Guacamole.Tunnel.State.OPEN) setStatus("Relay accepted the connection, negotiating RDP…");
        };
        client.onstatechange = function (s) {
            if (s === 3) { currentUuid = (tunnel && tunnel.uuid ? String(tunnel.uuid) : "").replace(/^\$/, ""); }
            if (s === 3) applyScale();
            if (s === 3) setStatus(
                key === "isolated" ? "Connected to your isolated desktop."
                : key === "console" ? "Connected to the physical console."
                : key === "vnc"     ? ("Connected to VNC at " + $("host").value.trim() + ".")
            : key === "remote"  ? ("Connected to " + $("host").value.trim() + ".")
                : "Connected to your virtual monitor.", "ok");
            else if (s === 5) { if (!errored) setStatus("Disconnected."); teardown(true); }
        };

        setStatus("Opening a channel to the relay…");
        client.connect();

        var mouse = new Guacamole.Mouse(display.getElement());
        // Divide the mouse position by the live display scale (guestMouseState) so
        // clicks land on the right guest pixel at any zoom and after any resize.
        if (typeof mouse.onEach === "function")
            mouse.onEach(["mousedown", "mouseup", "mousemove"], function (e) { if (client) client.sendMouseState(guestMouseState(e.state)); });
        else
            mouse.onmousedown = mouse.onmouseup = mouse.onmousemove = function (st) { if (client) client.sendMouseState(guestMouseState(st)); };
        // Keyboard capture needs FOCUS. This plugin runs inside a Cockpit iframe,
        // and Guacamole.Keyboard only sees keydown/keyup while its target element
        // holds focus. It previously listened on `document` with nothing ever
        // focusing the iframe, so keystrokes went to the Cockpit page and never
        // into the RDP tunnel -- the relay saw mouse events but ZERO `key` events,
        // so no password field (lock screen, sudo/polkit, greeter, remote host)
        // ever received input. Bind the keyboard to the FOCUSABLE display element
        // and (re)focus it on connect and on any pointer press so typing lands in
        // the session. Binding to the display rather than `document` also keeps
        // keystrokes out of the remote while the user edits the plugin's own form
        // fields (host/port/credentials).
        box.tabIndex = 0;
        box.style.outline = "none";
        var refocusDisplay = function () { try { box.focus(); } catch (e) {} };
        display.getElement().addEventListener("mousedown", refocusDisplay, true);
        display.getElement().addEventListener("touchstart", refocusDisplay, true);
        refocusDisplay();
        // Clipboard passthrough (browser -> remote), gated live by the Clipboard
        // toggle: when the display takes focus and the toggle is on, push the local
        // clipboard into the session. Best-effort (readText may be blocked in the
        // iframe); failure is silent so it never disrupts the connection.
        if (clipReadHandler) box.removeEventListener("focus", clipReadHandler, true);
        clipReadHandler = function () {
            // Only push the local clipboard once the session is fully OPEN
            // (currentUuid is set on tunnel OPEN). Writing to the RDP clipboard
            // channel during connect/teardown raised cliprdr VirtualChannelWrite
            // errors and could disturb the connection.
            if (!client || !clipboardOn || !currentUuid) return;
            try {
                if (navigator.clipboard && navigator.clipboard.readText) {
                    navigator.clipboard.readText().then(function (text) {
                        if (!client || !clipboardOn || !text) return;
                        try {
                            var w = new Guacamole.StringWriter(client.createClipboardStream("text/plain"));
                            w.sendText(text); w.sendEnd();
                        } catch (e) { /* stream unavailable */ }
                    }).catch(function () { /* clipboard-read blocked */ });
                }
            } catch (e) { /* no Clipboard API */ }
        };
        box.addEventListener("focus", clipReadHandler, true);
        keyboard = new Guacamole.Keyboard(box);
        keyboard.onkeydown = function (k) { if (client) client.sendKeyEvent(1, k); };
        keyboard.onkeyup = function (k) { if (client) client.sendKeyEvent(0, k); };

        // NumLock/CapsLock/ScrollLock sync + on-screen toggle. Guacamole.Keyboard
        // forwards a lock KEY when it is pressed live, but never knew the browser's
        // CURRENT lock state -- so a session opened while the browser already holds
        // NumLock started inverted, and x11vnc then faked the missing modifier when
        // it XTEST-injected KP_* keysyms into the Xvfb and mis-typed the numpad
        // (End instead of 1, etc.). We ALIGN the session to the browser once (the
        // first keystroke), then MIRROR only later CHANGES to the browser's locks
        // -- edge-triggered, not level-forced -- so the on-screen "Num Lock" button
        // (toggleSessionLock, which moves the session but not browserLocks) is
        // never reverted by the next keystroke. Baseline is the fresh Xvfb's
        // all-off state, which xfreerdp3 syncs to grd on connect. The keysyms ride
        // the normal key path (guacd -> x11vnc XTEST -> Xvfb -> xfreerdp3 -> grd).
        remoteLocks  = { NumLock: false, CapsLock: false, ScrollLock: false };
        browserLocks = { NumLock: null,  CapsLock: null,  ScrollLock: null };
        if (lockSyncHandler) box.removeEventListener("keydown", lockSyncHandler, true);
        lockSyncHandler = function (e) {
            if (!client || !remoteLocks || typeof e.getModifierState !== "function") return;
            var lk = e.code || e.key;
            if (LOCK_KEYSYM.hasOwnProperty(lk)) {
                // Physical lock key: Guacamole.Keyboard forwards it (toggling the
                // session); track both models so we neither double-toggle nor
                // later mis-mirror it as a browser "change".
                remoteLocks[lk] = !remoteLocks[lk];
                if (browserLocks[lk] !== null) browserLocks[lk] = !browserLocks[lk];
                updateLockButtons();
                return;
            }
            // Any other key (CAPTURE phase, before Guacamole forwards it): align to
            // the browser on first sight, then mirror only subsequent changes.
            Object.keys(LOCK_KEYSYM).forEach(function (name) {
                var cur;
                try { cur = e.getModifierState(name); } catch (err) { return; }
                if (browserLocks[name] === null) {
                    if (cur !== remoteLocks[name]) { sendLockKeysym(name); remoteLocks[name] = cur; }
                    browserLocks[name] = cur;
                } else if (cur !== browserLocks[name]) {
                    sendLockKeysym(name); remoteLocks[name] = !remoteLocks[name];
                    browserLocks[name] = cur;
                }
            });
            updateLockButtons();
        };
        box.addEventListener("keydown", lockSyncHandler, true);
        $("stop").disabled = false;
        if ($("numlock")) $("numlock").disabled = false;
        updateLockButtons();
    }

    function refreshUi() {
        var key = $("target").value, manual = $("authmode").value === "manual", t = TARGETS[key];
        var managed = !!t.managed, remote = !!t.remote;
        // Isolated is relay-managed: no sign-in choice and no credential fields.
        // Remote: no gate-key chooser (always your own creds for that host) plus the
        // host/port fields; the relay enforces the admin-configured remote allow-list.
        $("authwrap").hidden = managed || remote;
        $("hostwrap").hidden = !remote;
        $("portwrap").hidden = !remote;
        var vnc = !!t.vnc;
        // VNC has no username in the protocol -- only a password. Showing a
        // username box would invite someone to type one that is then discarded.
        $("credwrap").hidden = vnc ? true : (remote ? false : (managed || !manual));
        $("passwrap").hidden = remote ? false : (managed || !manual);
        var extra = managed ? "  You reach your own session; no credentials needed."
                  : vnc ? "  Password only \u2014 VNC has no username. The relay only permits hosts an administrator has allow-listed."
                  : remote ? "  The relay only permits hosts an administrator has allow-listed."
                  : (t.admin && !isAdmin) ? "  ⚠ Needs administrative access."
                  : (manual ? "" : "  The gate key is read from the server; you never see or type it.");
        $("hint").textContent = t.note + extra;
    }

    function fmtAge(sec) {
        if (!sec && sec !== 0) return "";
        var s = Math.max(0, Math.floor(Date.now() / 1000 - sec));
        if (s < 60) return s + "s"; if (s < 3600) return Math.floor(s/60) + "m"; return Math.floor(s/3600) + "h";
    }

    // The table used to print the raw scenario key. Those keys are internal and
    // do not match anything the operator picked from the dropdown -- "wayland-vnc"
    // and "vnc" in particular read as near-duplicates while being very different
    // connections.
    var SCENARIO_LABELS = {
        isolated: "Isolated session",
        virtual: "Virtual monitor",
        console: "Console (mirror)",
        greeter: "Login screen (greeter)",
        remote: "Remote host (RDP)",
        vnc: "Remote host (VNC)",
        "wayland-vnc": "Wayland desktop (VNC)"
    };

    function scenarioLabel(key) {
        if (!key) return "";
        return SCENARIO_LABELS[key] || key;
    }

    function renderSessions() {
        var body = $("sessions-body");
        body.innerHTML = '<tr><td colspan="7" class="muted">Loading…</td></tr>';
        controlRequest({ op: "list" }).then(function (r) {
            if (!r || !r.ok) { body.innerHTML = '<tr><td colspan="7" class="muted">Could not list sessions.</td></tr>'; return; }
            $("sessions-note").textContent = r.admin ? "Administrator view: all users' sessions." : "Your sessions.";
            var rows = r.sessions || [];
            if (!rows.length) { body.innerHTML = '<tr><td colspan="7" class="muted">No active sessions.</td></tr>'; return; }
            body.innerHTML = "";
            rows.forEach(function (sn) {
                var tr = document.createElement("tr");
                function td(txt, cls) { var e = document.createElement("td"); e.textContent = txt; if (cls) e.className = cls; return e; }
                tr.appendChild(td((sn.uuid || "").slice(0, 8)));
                tr.appendChild(td(scenarioLabel(sn.scenario)));
                tr.appendChild(td(sn.state || ""));
                tr.appendChild(td(sn.live ? "yes" : "no", sn.live ? "live-yes" : "live-no"));
                tr.appendChild(td(String(sn.uid) + (sn.mine ? " (you)" : "")));
                tr.appendChild(td(fmtAge(sn.created)));
                var act = document.createElement("td");
                var b = document.createElement("button"); b.className = "term"; b.textContent = "Terminate";
                b.addEventListener("click", function () {
                    b.disabled = true; b.textContent = "…";
                    controlRequest({ op: "terminate", uuid: sn.uuid }).then(function () { renderSessions(); })
                        .catch(function () { b.disabled = false; b.textContent = "Terminate"; });
                });
                act.appendChild(b); tr.appendChild(act);
                body.appendChild(tr);
            });
        }).catch(function (e) {
            body.innerHTML = '<tr><td colspan="7" class="muted">Control API error: ' + e + '</td></tr>';
        });
    }

    /* ---------------------------------------------------------------- *
     * Self tests
     *
     * Read-only checks an operator can run from the panel itself. Nothing
     * here starts, stops or reconfigures anything: every check either reads
     * a listening socket, asks systemd for a unit's state, resolves a binary
     * on PATH, or fetches a file this page already depends on.
     *
     * The first two exist because of a real outage: a redeploy left
     * guacamole-common-js unreachable, the library never loaded, and the
     * only symptom in the panel was a bare "Guacamole is not defined" in the
     * browser console. A page that can test itself reports that in a word.
     *
     * guacd is deliberately NOT probed with `command -v`: it is started by
     * edy-rdp-guacd.service and need not be on PATH, so a binary probe would
     * report a healthy host as broken. Its unit and its listening socket are
     * the honest signals.
     * ---------------------------------------------------------------- */

    var ST_UNITS = ["edy-rdp-control.socket", "edy-rdp-relay.socket",
                    "edy-rdp-guacd.service", "edy-rdp-firewall.service"];
    // The RDP scenarios go through the FreeRDP3 bridge; the Wayland one does not
    // share a single binary with them, so they are checked separately -- a host
    // missing sway says nothing about whether Console works, and vice versa.
    var ST_BINS = ["xfreerdp3", "Xvfb", "x11vnc"];
    var ST_WL_BINS = ["sway", "wayvnc"];
    var ST_ASSETS = ["guac-rdp.css", "guac-proto.js", "guac-rdp.js",
                     "guacamole-common-js/all.min.js"];

    function stSpawn(argv) { return cockpit.spawn(argv, { err: "message" }); }
    // Some checks read container state, which is root-owned. superuser:"try"
    // degrades to a skip rather than failing the whole run for a non-admin.
    function stSpawn2(argv) { return cockpit.spawn(argv, { err: "message", superuser: "try" }); }

    // Resolve a name on PATH without a shell interpolation: the name is passed
    // as an argument, never spliced into the script text.
    function stWhich(name) {
        return stSpawn(["/bin/sh", "-c", 'command -v "$1"', "sh", name])
            .then(function (out) { return { name: name, path: out.trim() }; },
                  function () { return { name: name, path: "" }; });
    }

    function stUnit(unit) {
        return stSpawn(["systemctl", "is-active", unit])
            .then(function (out) { return { unit: unit, state: out.trim() }; },
                  // is-active exits non-zero for anything not active; the state
                  // is still what it printed, and a dead unit is a result, not
                  // an error to surface as a stack trace.
                  function (e) {
                      var s = (e && e.message ? String(e.message) : "").trim();
                      return { unit: unit, state: s || "inactive" };
                  });
    }

    var SELF_TESTS = [
        {
            name: "Guacamole client library loaded",
            run: function () {
                var ok = (typeof Guacamole !== "undefined") && !!Guacamole.Client;
                return cockpit.resolve(ok
                    ? { status: "pass", detail: "Guacamole.Client is available" }
                    : { status: "fail", detail: "guacamole-common-js/all.min.js did not load - this panel cannot connect" });
            }
        },
        {
            name: "Panel assets served by Cockpit",
            run: function () {
                return Promise.all(ST_ASSETS.map(function (f) {
                    return fetch(f, { cache: "no-store" }).then(
                        function (r) { return { f: f, ok: r.ok, code: r.status }; },
                        function () { return { f: f, ok: false, code: 0 }; });
                })).then(function (rs) {
                    var bad = rs.filter(function (r) { return !r.ok; });
                    if (!bad.length)
                        return { status: "pass", detail: rs.length + " files served" };
                    return { status: "fail", detail: bad.map(function (b) {
                        return b.f + " (" + (b.code || "no response") + ")";
                    }).join(", ") };
                });
            }
        },
        {
            name: "Control API reachable",
            run: function () {
                return controlRequest({ op: "list" }).then(function (r) {
                    if (!r || !r.ok) return { status: "fail", detail: "control API replied without ok" };
                    var n = (r.sessions || []).length;
                    return { status: "pass", detail: n + " session" + (n === 1 ? "" : "s") + " known" };
                }, function (e) {
                    return { status: "fail", detail: String(e) };
                });
            }
        },
        {
            name: "guacd listening on loopback only",
            run: function () {
                return stSpawn(["ss", "-tln"]).then(function (out) {
                    var lines = out.split("\n").filter(function (l) { return /:4822(\s|$)/.test(l); });
                    if (!lines.length)
                        return { status: "fail", detail: "nothing is listening on 4822" };
                    var bad = lines.filter(function (l) {
                        return !/(127\.0\.0\.1|\[::1\]):4822/.test(l);
                    });
                    if (bad.length)
                        return { status: "fail", detail: "non-loopback bind: " + bad[0].trim() };
                    return { status: "pass", detail: "127.0.0.1:4822 only" };
                }, function (e) {
                    return { status: "skip", detail: "ss unavailable: " + e };
                });
            }
        },
        {
            name: "Shipped units active",
            run: function () {
                return Promise.all(ST_UNITS.map(stUnit)).then(function (rs) {
                    var bad = rs.filter(function (r) { return r.state !== "active"; });
                    if (!bad.length)
                        return { status: "pass", detail: rs.length + " units active" };
                    return { status: "fail", detail: bad.map(function (b) {
                        return b.unit + " is " + b.state;
                    }).join(", ") };
                });
            }
        },
        {
            name: "guacd build (FreeRDP 3 needed for grd)",
            run: function () {
                // grd's 3389 NLA and 3390 RDSTLS both need FreeRDP 3; the stock
                // guacd ships FreeRDP 2, which is why the bridge exists.
                return stSpawn2(["podman", "ps", "--filter", "name=edy-rdp-guacd",
                                 "--format", "{{.Image}}"]).then(function (out) {
                    var img = (out || "").trim();
                    if (!img) return { status: "fail", detail: "guacd container is not running" };
                    var fr3 = /janua|fr3|freerdp3/i.test(img);
                    return { status: fr3 ? "pass" : "skip",
                             detail: img.slice(0, 90) + (fr3 ? "" : " \u2014 not recognisably a FreeRDP 3 build") };
                }, function (e) {
                    return { status: "skip", detail: "needs administrative access: " + e };
                });
            }
        },
        {
            name: "Wayland session tooling present",
            run: function () {
                return Promise.all(ST_WL_BINS.map(stWhich)).then(function (rs) {
                    var missing = rs.filter(function (r) { return !r.path; });
                    if (!missing.length)
                        return { status: "pass", detail: rs.map(function (r) { return r.name; }).join(", ") };
                    return { status: "fail", detail: "Wayland desktop (VNC) needs: " +
                             missing.map(function (m) { return m.name; }).join(", ") };
                });
            }
        },
        {
            name: "RDP bridge tooling present",
            run: function () {
                return Promise.all(ST_BINS.map(stWhich)).then(function (rs) {
                    var missing = rs.filter(function (r) { return !r.path; });
                    if (!missing.length)
                        return { status: "pass", detail: rs.map(function (r) { return r.name; }).join(", ") };
                    return { status: "fail", detail: "not on PATH: " + missing.map(function (m) {
                        return m.name;
                    }).join(", ") };
                });
            }
        }
    ];

    var stRunning = false;

    function runSelfTests() {
        if (stRunning) return;
        stRunning = true;
        var btn = $("run-tests"), body = $("selftests-body"), sum = $("selftests-summary");
        btn.disabled = true;
        sum.className = "status";
        sum.textContent = "Running " + SELF_TESTS.length + " checks...";
        body.innerHTML = "";

        var cells = SELF_TESTS.map(function (t) {
            var tr = document.createElement("tr");
            var name = document.createElement("td");
            name.textContent = t.name;
            var res = document.createElement("td");
            var pill = document.createElement("span");
            pill.className = "st-pill st-run";
            pill.textContent = "running";
            res.appendChild(pill);
            var detail = document.createElement("td");
            detail.className = "muted";
            detail.textContent = "";
            tr.appendChild(name); tr.appendChild(res); tr.appendChild(detail);
            body.appendChild(tr);
            return { pill: pill, detail: detail };
        });

        var tally = { pass: 0, fail: 0, skip: 0 };

        // Sequential, not parallel: these read shared host state, and a
        // predictable order makes a screenshot of this table diffable against
        // the last time someone ran it.
        var chain = cockpit.resolve();
        SELF_TESTS.forEach(function (t, i) {
            chain = chain.then(function () {
                return t.run().catch(function (e) {
                    return { status: "fail", detail: "check raised: " + e };
                }).then(function (r) {
                    var st = (r && r.status) || "fail";
                    tally[st] = (tally[st] || 0) + 1;
                    cells[i].pill.className = "st-pill st-" + st;
                    cells[i].pill.textContent = st;
                    cells[i].detail.textContent = (r && r.detail) || "";
                });
            });
        });

        chain.then(function () {
            var parts = [tally.pass + " passed"];
            if (tally.fail) parts.push(tally.fail + " failed");
            if (tally.skip) parts.push(tally.skip + " skipped");
            sum.textContent = parts.join(", ") + ".";
            sum.className = "status " + (tally.fail ? "err" : "ok");
            btn.disabled = false;
            stRunning = false;
        });
    }

    function selectTab(id) {
        ["connect", "sessions", "selftests"].forEach(function (n) {
            var t = $("tab-" + n), pan = $("panel-" + n);
            var on = ("tab-" + n) === id;
            t.classList.toggle("active", on); pan.hidden = !on;
        });
        if (id === "tab-sessions") renderSessions();
    }

    // ---- toggle/selector persistence -----------------------------------------
    // The connect-bar controls (Session, Resolution, Scale, Clipboard, Sound) are
    // written into the location hash on change and re-applied on load, so a browser
    // refresh -- and a freshly opened pop-out/monitor window -- keeps the chosen
    // settings instead of snapping back to defaults. Credentials (username/password/
    // host) are DELIBERATELY never persisted. The control params sit AFTER any mode
    // token (#seat / #monitor=N), which is preserved on every write, so the existing
    // mode detection still matches. We also mirror to localStorage: the plugin runs
    // inside Cockpit's shell iframe, where the raw hash may not survive a full-page
    // refresh, so localStorage is the guaranteed restore; the hash is what makes the
    // choice visible, shareable, and inheritable by the pop-out windows.
    var URL_CONTROLS = [
        { key: "target", id: "target",        kind: "select" },
        { key: "res",    id: "resolution",    kind: "select" },
        { key: "scale",  id: "scale",         kind: "select" },
        { key: "clip",   id: "opt-clipboard", kind: "check"  },
        { key: "audio",  id: "opt-audio",     kind: "check"  }
    ];
    var CONTROLS_LS_KEY = "edy-rdp-controls";
    function _hashSegments() {
        var h = location.hash.replace(/^#/, "");
        return h ? h.split("&") : [];
    }
    function _segKey(seg) { var i = seg.indexOf("="); return i < 0 ? seg : seg.slice(0, i); }
    function hashParam(key) {
        var segs = _hashSegments();
        for (var i = 0; i < segs.length; i++) {
            if (_segKey(segs[i]) === key) {
                var eq = segs[i].indexOf("=");
                return eq < 0 ? "" : decodeURIComponent(segs[i].slice(eq + 1));
            }
        }
        return null;
    }
    function _controlValue(c) {
        var el = $(c.id); if (!el) return null;
        return c.kind === "check" ? (el.checked ? "1" : "0") : el.value;
    }
    // "key=val&key=val" for the current controls -- used to seed a pop-out URL.
    function controlHashSuffix() {
        return URL_CONTROLS.map(function (c) {
            var v = _controlValue(c);
            return v === null ? null : c.key + "=" + encodeURIComponent(v);
        }).filter(Boolean).join("&");
    }
    function _applyControl(c, v) {
        if (v === null || v === undefined) return;
        var el = $(c.id); if (!el) return;
        if (c.kind === "check") { el.checked = (v === "1"); return; }
        for (var i = 0; i < el.options.length; i++) {   // only adopt an offered value
            if (el.options[i].value === v) { el.value = v; return; }
        }
    }
    // Restore controls: an explicit hash param (a shared link or a pop-out URL) wins;
    // otherwise fall back to the last localStorage snapshot.
    function loadControls() {
        var stored = {};
        try { stored = JSON.parse(localStorage.getItem(CONTROLS_LS_KEY) || "{}") || {}; }
        catch (e) { stored = {}; }
        URL_CONTROLS.forEach(function (c) {
            var v = hashParam(c.key);
            if (v === null && Object.prototype.hasOwnProperty.call(stored, c.key)) v = stored[c.key];
            _applyControl(c, v);
        });
        if ($("scale")) scaleMode = $("scale").value || "fit";
        syncPassthroughFlags();
    }
    // Persist controls on change: rewrite the hash (preserving any mode token) via
    // replaceState -- no reload, no history spam, no Cockpit-shell navigation side
    // effect -- and snapshot to localStorage.
    function saveControls() {
        var keep = [], controlKeys = URL_CONTROLS.map(function (c) { return c.key; }), vals = {};
        _hashSegments().forEach(function (seg) {
            if (controlKeys.indexOf(_segKey(seg)) < 0) keep.push(seg);   // keep mode token(s)
        });
        URL_CONTROLS.forEach(function (c) {
            var v = _controlValue(c); if (v === null) return;
            vals[c.key] = v;
            keep.push(c.key + "=" + encodeURIComponent(v));
        });
        var newHash = "#" + keep.join("&");
        try { history.replaceState(history.state, "", newHash); } catch (e) { /* ignore */ }
        try { localStorage.setItem(CONTROLS_LS_KEY, JSON.stringify(vals)); } catch (e) { /* ignore */ }
    }

    document.addEventListener("DOMContentLoaded", function () {
        $("tab-connect").addEventListener("click", function () { selectTab("tab-connect"); });
        $("tab-sessions").addEventListener("click", function () { selectTab("tab-sessions"); });
        $("tab-selftests").addEventListener("click", function () { selectTab("tab-selftests"); });
        $("run-tests").addEventListener("click", runSelfTests);
        $("refresh").addEventListener("click", renderSessions);
        var perm = cockpit.permission({ admin: true });
        perm.addEventListener("changed", function () { isAdmin = !!perm.allowed; refreshUi(); });
        isAdmin = !!perm.allowed;
        loadControls();   // restore persisted toggles/selectors BEFORE any auto-connect
        $("target").addEventListener("change", refreshUi);
        $("authmode").addEventListener("change", refreshUi);
        $("go").addEventListener("click", function () { connect(); });
        $("numlock").addEventListener("click", function () { toggleSessionLock("NumLock"); });
        // Sound / Clipboard passthrough toggles gate LIVE, during a session.
        $("opt-clipboard").addEventListener("change", function () {
            clipboardOn = $("opt-clipboard").checked;
            if (client) setStatus(clipboardOn ? "Clipboard passthrough on." : "Clipboard passthrough off.");
        });
        $("opt-audio").addEventListener("change", function () {
            soundOn = $("opt-audio").checked;
            applySoundGate();
            // enable-audio is negotiated at connect, so toggling Sound live
            // reconnects the same scenario to add/drop the audio channel.
            if (client && activeKey) {
                setStatus(soundOn ? "Enabling sound…" : "Muting sound…");
                teardown(true);
                window.setTimeout(function () { connect(activeKey); }, 80);
            }
        });
        syncPassthroughFlags();
        $("scale").addEventListener("change", function () {
            scaleMode = $("scale").value; applyScale();
        });
        // Resolution is fixed at connect, so changing it live reconnects the session
        // (same scenario) at the new geometry. Idle -> applies on the next connect.
        $("resolution").addEventListener("change", function () {
            if (client && activeKey) {
                setStatus("Applying resolution…");
                teardown(true);
                window.setTimeout(function () { connect(activeKey); }, 80);
            }
        });
        // Persist every toggle/selector to the URL hash + localStorage on change, so
        // a refresh (and any pop-out window) keeps the chosen settings.
        URL_CONTROLS.forEach(function (c) {
            var el = $(c.id); if (el) el.addEventListener("change", saveControls);
        });
        // On resize, re-fit and re-sync the pointer mapping. applyScale() recomputes
        // curScale (fit follows the window; a pinned factor stays put) and the mouse
        // handler divides by it, so the pointer stays aligned. Debounced so a drag-
        // resize does not thrash display.scale(). A trailing rAF settles the final
        // layout before the last recompute.
        var resizeTimer = null;
        window.addEventListener("resize", function () {
            if (resizeTimer) clearTimeout(resizeTimer);
            resizeTimer = setTimeout(function () {
                resizeTimer = null;
                applyScale();
                if (typeof requestAnimationFrame === "function") requestAnimationFrame(applyScale);
            }, 60);
        });
        $("stop").addEventListener("click", function () {
            // Disconnect ONLY. Do NOT send control "terminate": that deletes the
            // session's registry entry, so the reaper sees no isolated sessions and
            // tears the persistent desktop down within its next tick — which broke
            // the "reissue the same desktop on reconnect" contract. The graceful
            // guac disconnect (teardown) closes the CONNECTION; the desktop stays
            // reconnectable until the session TTL. Explicit desktop kill remains
            // available via the Sessions tab's Terminate button.
            setStatus("Disconnecting…");
            teardown(false);
        });
        $("addmon").addEventListener("click", openMonitorWindow);
        $("popout").addEventListener("click", openSeatWindow);
        refreshUi();
        setStatus("Idle. Choose a session and connect.");
        // Pop-up modes: #monitor = a fresh virtual monitor (closes with the window);
        // #seat = the physical-seat mirror with a monitor picker (disconnect only).
        if (MONITOR_MODE) enterMonitorMode();
        else if (SEAT_MODE) enterSeatMode();
    });
})();
