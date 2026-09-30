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
        trace("sound", "connect: enable-audio=" + (v["enable-audio"] || "false"));
        return v;
    }

    // Live gate flags for the Sound/Clipboard toggles (mirrored from the checkboxes).
    var clipboardOn = true, soundOn = false, traceOn = false, clipReadHandler = null;
    var keyboardBlurHandler = null;   // releases stuck keys on focus loss -- see its own setup below
    var lastRemoteClip = null;   // newest text the session put on its clipboard (for the "Receive clipboard" button)
    function syncPassthroughFlags() {
        clipboardOn = !$("opt-clipboard") || $("opt-clipboard").checked;
        soundOn = !!($("opt-audio") && $("opt-audio").checked);
        traceOn = !!($("opt-trace") && $("opt-trace").checked);
    }
    // Opt-in diagnostic logging for clipboard and sound specifically -- the two
    // paths this project's own history shows get reported as "just doesn't
    // work" with nothing to go on (see docs/KNOWN_ISSUES.md's clipboard
    // investigation, root-caused only by adding ad hoc console.log calls by
    // hand). Every decision point these two features actually make --
    // negotiated at connect, gated on/off, blocked by the browser, byte counts
    // -- goes to the browser console under one prefix, off by default so it
    // adds zero console noise for anyone not actively debugging one of these
    // two things. Trace lines are diagnostic text only, never the clipboard
    // CONTENTS themselves (byte counts, not the text) -- this toggle is meant
    // to be left on during a support session without exposing what was copied.
    // Kept in memory (not just printed) so the "Logs…" viewer (see
    // addViewLogsButton() below) can show it as a filterable table, not just
    // whatever happens to still be in the DevTools console scrollback. Same
    // opt-in gate as the console line itself (traceOn) -- this project's own
    // stated policy is byte counts/categories only, never clipboard CONTENTS,
    // which trace()'s callers already honor; capturing to this array adds no
    // new exposure beyond what already goes to the console. Capped so a
    // long-running session's trace can't grow this without bound.
    var traceLog = [];
    var TRACE_LOG_MAX = 2000;
    function trace(category, msg) {
        if (!traceOn) return;
        try {
            traceLog.push({ time: Date.now(), category: category, message: String(msg) });
            if (traceLog.length > TRACE_LOG_MAX) traceLog.shift();
        } catch (e) { /* ignore */ }
        try {
            (console.debug || console.log).call(console, "[guac-rdp:" + category + "] " + msg);
        } catch (e) { /* no console in this context */ }
    }
    // Sound gate: suspend/resume Guacamole's shared AudioContext. suspend() mutes
    // playback instantly, mid-stream; resume() is driven from the toggle's own
    // click (a user gesture), which satisfies browser autoplay policy.
    function applySoundGate() {
        try {
            var f = Guacamole.AudioContextFactory;
            var ctx = f && f.getAudioContext && f.getAudioContext();
            if (!ctx) { trace("sound", "gate: no AudioContext in this browser/context"); return; }
            if (soundOn) {
                if (ctx.state === "suspended" && ctx.resume) { trace("sound", "gate: resuming (state was " + ctx.state + ")"); ctx.resume(); }
                else trace("sound", "gate: on, already " + ctx.state);
            } else if (ctx.state === "running" && ctx.suspend) { trace("sound", "gate: suspending"); ctx.suspend(); }
            else trace("sound", "gate: off, already " + ctx.state);
        } catch (e) { trace("sound", "gate: threw " + e); }
    }
    // Read and drop a text stream we will not use (clipboard toggled off).
    function discardTextStream(stream) {
        try { var r = new Guacamole.StringReader(stream); r.ontext = function () {}; r.onend = function () {}; }
        catch (e) { /* ignore */ }
    }
    // ---- explicit clipboard transfer -----------------------------------------
    // The Send/Receive buttons are the RELIABLE clipboard path: they run on a
    // click, so navigator.clipboard read/write rides the browser's transient user
    // activation (the checkbox's gesture-less auto-sync is often blocked). "Send"
    // pushes the local clipboard into the session; "Receive" pulls the session's
    // last clipboard into the browser.
    function sendClipboardToSession() {
        if (!client || !currentUuid) {
            trace("clipboard", "send: refused, no live session");
            setStatus("Connect a session first, then Send clipboard.", "err"); return;
        }
        if (!(navigator.clipboard && navigator.clipboard.readText)) {
            trace("clipboard", "send: no navigator.clipboard.readText in this browser/context");
            setStatus("This browser will not let the page read the clipboard.", "err"); return;
        }
        navigator.clipboard.readText().then(function (text) {
            if (!client) return;
            if (!text) { trace("clipboard", "send: local clipboard is empty"); setStatus("Your clipboard is empty."); return; }
            try {
                var w = new Guacamole.StringWriter(client.createClipboardStream("text/plain"));
                w.sendText(text); w.sendEnd();
                trace("clipboard", "send: wrote " + text.length + " chars to the session clipboard stream");
                setStatus("Sent " + text.length + " characters to the session clipboard — paste inside the session.");
            } catch (e) { trace("clipboard", "send: stream write threw " + e); setStatus("Could not reach the session clipboard.", "err"); }
        }).catch(function (e) {
            trace("clipboard", "send: readText() rejected " + e);
            setStatus("Clipboard read was blocked — click inside the page, then press Send clipboard again.", "err");
        });
    }
    function receiveClipboardFromSession() {
        if (lastRemoteClip == null) {
            trace("clipboard", "receive: nothing captured from the session yet");
            setStatus("Nothing captured yet — copy something INSIDE the session first, then Receive clipboard.", "err"); return;
        }
        if (!(navigator.clipboard && navigator.clipboard.writeText)) {
            trace("clipboard", "receive: no navigator.clipboard.writeText in this browser/context");
            setStatus("This browser will not let the page write the clipboard.", "err"); return;
        }
        navigator.clipboard.writeText(lastRemoteClip).then(function () {
            trace("clipboard", "receive: wrote " + lastRemoteClip.length + " chars to the OS clipboard");
            setStatus("Copied " + lastRemoteClip.length + " characters from the session — paste locally.");
        }).catch(function (e) {
            trace("clipboard", "receive: writeText() rejected " + e);
            setStatus("Clipboard write was blocked by the browser.", "err");
        });
    }
    // ---- "Type Clipboard": keystroke-injection clipboard workaround -----------
    // guacd/x11vnc's own VNC clipboard channel silently drops browser->remote
    // pushes on this bridge (confirmed upstream bug, not this project's --
    // see docs/KNOWN_ISSUES.md and memory cockpit-guac-rdp-send-clip-investigation):
    // the wire instruction is accepted with no error, but the guest's clipboard
    // never actually changes, so "Send clip" LOOKS like it worked (browser trace
    // shows bytes written to the stream) while nothing arrives. This button
    // sidesteps that whole path: instead of asking the guest to receive a
    // clipboard update, it TYPES the local clipboard's text into the session one
    // keysym at a time over the same key-event channel real keystrokes already
    // use reliably (sendGuestKeyEvent, with its existing KEYCODE_FIX/SHIFT_LEVEL
    // corrections applying identically to typed characters).
    //
    // Character -> keysym mirrors the vendored Guacamole.Keyboard's own (unused
    // here) codepoint-to-keysym function EXACTLY -- extracted from
    // guacamole-common-js/all.min.js and diffed against this implementation
    // over code points 0-0x400 before shipping, after an adversarial review
    // caught an earlier draft treating 0x7F-0x9F (DEL + the C1 control range --
    // easy to miss, and real: it's what a Windows-1252-as-Latin-1 mis-decode or
    // a terminal copy can leave behind) as direct-value keysyms instead of the
    // "function key" convention the vendored function actually uses for them.
    // ONE deliberate deviation from that vendored function, kept from the first
    // draft: LF and CR are forced to the real Return keysym (0xFF0D) instead of
    // Linefeed (0xFF0A, what the vendored function -- and its own built-in
    // .type() -- produces for "\n"), which has no key on the Xvfb "us" keymap
    // at all (verified with a standalone vm probe: typing a bare LF through it
    // silently does nothing). x11vnc's -add_keysyms (this build's own default
    // -- confirmed via `x11vnc -help`: "Default: -add_keysyms") dynamically
    // adds an unused keycode for any keysym -- including the Unicode-plane
    // ones below -- Xvfb's static "us" keymap doesn't already have one for.
    //
    // Note for anyone pasting TSV/spreadsheet data or indented code: an
    // embedded Tab/Backspace/Escape/etc. in the clipboard text becomes a REAL
    // guest keypress here (focus-next, delete-previous-char, ...), same as if
    // you had typed it yourself -- this button types the text, it doesn't
    // paste it as inert data. Not a bug, just a consequence of the approach.
    //
    // TESTHOOK:TYPECLIP:BEGIN -- tests/js/type_clipboard.test.js extracts this
    // exact block (verbatim) and exercises it standalone; keep it self-contained
    // (only `sendGuestKeyEvent` from the outer scope, stubbed in the test).
    function keysymForCodePoint(cp) {
        if (cp === 0x0A || cp === 0x0D) return 0xFF0D;                 // LF or CR -> Return
        if (cp <= 0x1F || (cp >= 0x7F && cp <= 0x9F)) return cp | 0xFF00;  // C0 + C1 controls
        if (cp <= 0xFF) return cp;                                     // Latin-1: direct
        return 0x01000000 | cp;                                        // Unicode keysym plane
    }
    // Presses and releases exactly one keysym via sendGuestKeyEvent directly --
    // deliberately NOT keyboard.press()/keyboard.release(). Those route through
    // the SAME Guacamole.Keyboard instance real physical keystrokes drive,
    // sharing its `pressed` map and a single (not per-keysym) key-repeat timer
    // pair: injecting a keysym that happens to collide with one the user is
    // physically holding (e.g. holding Enter while a newline in the pasted
    // text also wants Return) is silently swallowed on the injected press
    // (Guacamole.Keyboard.prototype.press no-ops when already pressed) while
    // the immediately-following injected release DOES fire and tells the
    // guest the physical key was released while the user is still holding it
    // -- confirmed against the real vendored library and reproduced live by
    // adversarial review, which also found it can permanently kill a real
    // key's auto-repeat-to-guest stream even with no keysym collision at all,
    // via the same shared timer. sendGuestKeyEvent(down, ks) called directly
    // -- exactly what the existing one-shot sendKeysymTap() helper already
    // does -- never touches keyboard.pressed or its repeat timers, so injected
    // typing cannot desync from concurrent real physical typing, while still
    // getting the same KEYCODE_FIX/SHIFT_LEVEL corrections (I45).
    function typeOneCodePoint(cp) {
        var ks = keysymForCodePoint(cp);
        sendGuestKeyEvent(true, ks);
        sendGuestKeyEvent(false, ks);
    }
    function typeTextIntoSession(text) {
        var i = 0, n = 0;
        while (i < text.length) {
            var cp = text.codePointAt(i);
            i += (cp > 0xFFFF) ? 2 : 1;                        // advance past a surrogate pair too
            if (cp === 0x0D && text.charCodeAt(i) === 0x0A) i += 1;   // CRLF: one Return, not two
            typeOneCodePoint(cp);
            n++;
        }
        return n;
    }
    // TESTHOOK:TYPECLIP:END
    var clipTypeBusy = false;
    var CLIP_TYPE_CHUNK = 200;   // characters per synchronous burst
    // Types `chars` (an ARRAY of code-point strings -- from Array.from(text), so
    // each element is already surrogate-pair-safe) CLIP_TYPE_CHUNK at a time,
    // yielding to the browser between chunks via setTimeout so a large
    // paste-by-typing (this feature's whole reason to exist is moving text the
    // broken native clipboard channel won't carry, which skews toward LARGER
    // payloads) cannot freeze the tab for the whole operation or block a
    // mid-paste disconnect from taking effect. If the chunk boundary would
    // split a CRLF pair, it is pushed one character later to keep the pair
    // together (typeTextIntoSession's own CRLF collapsing only looks within a
    // single call's text).
    function typeClipboardChunked(chars, doneCb) {
        var pos = 0, total = 0;
        function step() {
            if (!client || !keyboard) { doneCb(total, false); return; }
            var end = Math.min(pos + CLIP_TYPE_CHUNK, chars.length);
            if (end < chars.length && chars[end - 1] === "\r" && chars[end] === "\n") end += 1;
            total += typeTextIntoSession(chars.slice(pos, end).join(""));
            pos = end;
            if (pos < chars.length) {
                setStatus("Typing… " + pos + " of " + chars.length + " characters.");
                setTimeout(step, 0);
            } else { doneCb(total, true); }
        }
        step();
    }
    function typeClipboardIntoSession() {
        if (clipTypeBusy) {
            trace("clipboard", "type: refused, a previous Type Clipboard run is still in progress");
            setStatus("Still typing the last clipboard — wait for it to finish.", "err"); return;
        }
        if (!client || !currentUuid || !keyboard) {
            trace("clipboard", "type: refused, no live session");
            setStatus("Connect a session first, then Type clipboard.", "err"); return;
        }
        if (!(navigator.clipboard && navigator.clipboard.readText)) {
            trace("clipboard", "type: no navigator.clipboard.readText in this browser/context");
            setStatus("This browser will not let the page read the clipboard.", "err"); return;
        }
        clipTypeBusy = true;
        navigator.clipboard.readText().then(function (text) {
            if (!client || !keyboard) { clipTypeBusy = false; return; }
            if (!text) {
                trace("clipboard", "type: local clipboard is empty"); setStatus("Your clipboard is empty.");
                clipTypeBusy = false; return;
            }
            try {
                typeClipboardChunked(Array.from(text), function (n, completed) {
                    clipTypeBusy = false;
                    trace("clipboard", "type: injected " + n + " keystrokes for " + text.length + " chars"
                        + (completed ? "" : " (stopped early -- session ended)"));
                    if (completed) setStatus("Typed " + text.length + " characters into the session.");
                    else setStatus("Session ended before typing finished (" + n + " characters typed).", "err");
                });
            } catch (e) {
                clipTypeBusy = false;
                trace("clipboard", "type: threw " + e); setStatus("Could not type into the session.", "err");
            }
        }).catch(function (e) {
            clipTypeBusy = false;
            trace("clipboard", "type: readText() rejected " + e);
            setStatus("Clipboard read was blocked — click inside the page, then press Type clipboard again.", "err");
        });
    }
    // Append the "Send clipboard" / "Receive clipboard" / "Type clipboard" buttons
    // to a bar (the main connect bar and each pop-out's control strip). Pop-outs
    // are separate windows/documents, so the ids never collide across them.
    function addClipboardButtons(bar) {
        if (!bar) return;
        var mk = function (id, label, title, fn) {
            var b = document.createElement("button");
            b.id = id; b.type = "button"; b.className = "sec";
            b.textContent = label; b.title = title;
            b.addEventListener("click", fn);
            bar.appendChild(b);
        };
        mk("clip-send", "Send clip", "Send YOUR clipboard to the session (then paste inside the session).", sendClipboardToSession);
        mk("clip-recv", "Receive clip", "Copy the SESSION's clipboard into your browser (then paste locally).", receiveClipboardFromSession);
        mk("clip-type", "Type Clipboard", "Type YOUR clipboard into the session as keystrokes -- a workaround for when the session's own clipboard paste doesn't take. Embedded Tab/Backspace/etc. act as real keys, not literal text.", typeClipboardIntoSession);
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
    // ---- "Special keys" toggle (pop-out windows only) -------------------------
    // Route system/browser shortcuts -- Alt+Tab, Super/Win, Ctrl+W, Ctrl+T, Esc,
    // F11, etc. -- INTO the session instead of letting the local browser/OS eat
    // them. The web mechanism is the Keyboard Lock API, which only actually
    // captures the OS-reserved keys while the page is FULLSCREEN (and needs a
    // Chromium browser + secure context). Ctrl+Alt+Del is OS-level and can NEVER
    // be captured. Off by default: it grabs the WHOLE keyboard, and turning it on
    // needs the fullscreen user gesture, so it is not auto-restored on load.
    function specialKeysSupported() {
        return !!(navigator.keyboard && navigator.keyboard.lock);
    }
    function applySpecialKeys(on) {
        var el = document.documentElement;
        if (on) {
            var lock = function () {
                try { if (navigator.keyboard && navigator.keyboard.lock) navigator.keyboard.lock().catch(function () {}); }
                catch (e) { /* ignore */ }
            };
            // Fullscreen FIRST (rides the click gesture); lock once it settles.
            if (el.requestFullscreen) {
                var p; try { p = el.requestFullscreen(); } catch (e) { p = null; }
                if (p && p.then) p.then(lock, lock); else lock();
            } else { lock(); }
        } else {
            try { if (navigator.keyboard && navigator.keyboard.unlock) navigator.keyboard.unlock(); } catch (e) { /* ignore */ }
            try { if (document.fullscreenElement && document.exitFullscreen) document.exitFullscreen(); } catch (e) { /* ignore */ }
        }
    }
    function addSpecialKeysToggle(bar) {
        var wrap = document.createElement("div"); wrap.className = "f";
        var b = document.createElement("button");
        b.id = "specialkeys"; b.type = "button"; b.className = "sec toggle";
        b.textContent = "Special keys"; b.setAttribute("aria-pressed", "false");
        b.title = specialKeysSupported()
            ? "Send system shortcuts (Alt+Tab, Super, Ctrl+W, Esc, F11…) to the session. Goes fullscreen; Ctrl+Alt+Del stays local."
            : "This browser can only go fullscreen; capturing system keys needs a Chromium browser.";
        b.addEventListener("click", function () {
            var on = b.getAttribute("aria-pressed") !== "true";
            applySpecialKeys(on);
            b.setAttribute("aria-pressed", on ? "true" : "false");
            b.classList.toggle("on", on);
            try { $("display").focus(); } catch (e) { /* keep keys landing in the session */ }
        });
        wrap.appendChild(b); bar.appendChild(wrap);
        // If fullscreen is left by ANY route (Esc, F11, the WM), the browser auto-
        // releases the keyboard lock -- reflect that so the toggle never lies.
        document.addEventListener("fullscreenchange", function () {
            if (!document.fullscreenElement && b.getAttribute("aria-pressed") === "true") {
                try { if (navigator.keyboard && navigator.keyboard.unlock) navigator.keyboard.unlock(); } catch (e) { /* ignore */ }
                b.setAttribute("aria-pressed", "false"); b.classList.remove("on");
            }
        });
        return b;
    }
    // A plain Fullscreen toggle -- fill the screen WITHOUT grabbing the keyboard.
    // (System-key capture genuinely needs fullscreen, so "Special keys" still goes
    // fullscreen on its own; this is for people who just want the bigger picture and
    // keep their local shortcuts.) State is driven by fullscreenchange, so it also
    // lights up when Special keys takes the window fullscreen.
    function addFullscreenButton(bar) {
        var b = document.createElement("button");
        b.id = "fullscreen"; b.type = "button"; b.className = "sec toggle";
        b.textContent = "Fullscreen"; b.setAttribute("aria-pressed", "false");
        b.title = "Fill the screen (does NOT grab keys). 'Special keys' also goes fullscreen "
                + "because capturing system keys like Alt+Tab / Super requires it.";
        b.addEventListener("click", function () {
            if (!document.fullscreenElement) {
                try { var p = document.documentElement.requestFullscreen && document.documentElement.requestFullscreen();
                      if (p && p.catch) p.catch(function () {}); } catch (e) { /* ignore */ }
            } else {
                try { if (document.exitFullscreen) document.exitFullscreen(); } catch (e) { /* ignore */ }
            }
            try { $("display").focus(); } catch (e) { /* keep keys landing in the session */ }
        });
        bar.appendChild(b);
        document.addEventListener("fullscreenchange", function () {
            var fs = !!document.fullscreenElement;
            b.setAttribute("aria-pressed", fs ? "true" : "false"); b.classList.toggle("on", fs);
        });
        return b;
    }
    // A one-shot key TAP into the session (press then release), for keys the local
    // OS refuses to hand the browser -- above all the Windows/Super key, which
    // GNOME/Wayland (mutter) and Windows both reserve at the compositor/OS level
    // BELOW any web page, so the Keyboard Lock API cannot capture it. This injects
    // the keysym straight down the Guacamole channel, so the guest receives it no
    // matter what the local OS does with the physical key.
    function sendKeysymTap(keysym) {
        if (!client) return;
        try { client.sendKeyEvent(1, keysym); client.sendKeyEvent(0, keysym); } catch (e) { /* ignore */ }
        try { $("display").focus(); } catch (e) { /* keep focus in the session */ }
    }
    // Keysym fix-ups on the way to the guest. All are needed because the bridge
    // runs x11vnc in -nomodtweak (which preserves the modifiers the browser sends,
    // so Ctrl+Shift / Alt+Shift combos are not stripped -- x11vnc itself never adds
    // or removes a modifier, it just picks an Xvfb keycode for the keysym it's given
    // and trusts whatever is already held):
    //   * Windows/Super key: Guacamole maps keyCode 91/92 to Meta_L/Meta_R
    //     (0xFFE7/0xFFE8), but remotes want Super_L/R -- GNOME's overview overlay-key
    //     is Super_L and a Windows host's Start menu is LWin (= Super_L's scancode).
    //     Meta_L lands elsewhere (the guest sees an Alt-ish key) and opens neither.
    //   * Mac Option/Alt: the Guacamole bundle rewrites a Mac's Alt to
    //     ISO_Level3_Shift (0xFE03), which reaches the guest as AltGr -- so a Mac
    //     client can never send a plain Left Alt and Alt-combos break. On a Mac ONLY,
    //     send Alt_L instead. Genuine AltGr from a non-Mac international keyboard
    //     arrives by a different path and must keep flowing, so this is Mac-gated.
    // TESTHOOK:KEYREMAP:BEGIN -- tests/js/keyboard_remap.test.js extracts this
    // exact block (verbatim) and exercises it standalone; keep it self-contained
    // (only `client`, `keyboard`, `navigator` from the outer scope).
    var IS_MAC = /mac/i.test((typeof navigator !== "undefined" && (navigator.platform || navigator.userAgent)) || "");
    function remapKeysym(ks) {
        switch (ks) {
            case 0xFFE7: return 0xFFEB;                 // Meta_L     -> Super_L
            case 0xFFE8: return 0xFFEC;                 // Meta_R     -> Super_R
            case 0xFE03: return IS_MAC ? 0xFFE9 : ks;   // Mac Option: ISO_Level3_Shift -> Alt_L
            default:     return ks;
        }
    }
    // x11vnc (-nomodtweak) resolves a keysym to an Xvfb keycode the same way
    // Xlib's XKeysymToKeycode does: the LOWEST shift-level column that carries the
    // keysym, tie-broken by the LOWEST keycode number -- then presses that keycode
    // AS-IS, trusting whatever real modifier the browser already has held. That
    // is correct only when the browser's real modifier state happens to match
    // what THAT keycode's level needs. Two ways it doesn't:
    //   * KEYCODE_FIX -- the keysym itself is ambiguous and Xlib's rule picks the
    //     WRONG keycode outright: parenleft/parenright's lowest-column location is
    //     a phantom multimedia keycode (187/188) xfreerdp3 cannot scancode --
    //     dropped silently. less's lowest-column location is an ISO-only compat
    //     key (keycode 94, "less greater bar brokenbar", no physical key on a real
    //     US keyboard) at its UNSHIFTED level -- but a US client always holds real
    //     Shift to type "<", and Shift + that same keycode's level 1 is "greater",
    //     so "<" silently arrives as ">" (I45). All three have one other,
    //     unambiguous location (digit row 9/0, the comma key) that IS scancode-able.
    //   * SHIFT_LEVEL -- the resolved keycode is fine, but its needed Shift state
    //     doesn't match what produced the keysym on the CLIENT's layout. This cuts
    //     both ways and affects far more than five keys: a US client always holds
    //     Shift for "(" and never for ",", but French AZERTY holds Shift for NEITHER
    //     -- "(" is unshifted there -- and German holds Shift to type "." (it's an
    //     unshifted key on AZERTY, done via a different key with Shift on German).
    //     Trusting the client's real modifier is exactly backwards: what matters is
    //     what the FIXED Xvfb "us" keymap needs for the keysym Guacamole reports,
    //     which is layout-independent since it depends only on the keysym, not on
    //     how the client produced it. SHIFT_LEVEL is that lookup, computed once
    //     from the Xvfb "us" keymap for every digit/punctuation keysym that isn't
    //     ambiguous (letters are exempt: unshifted-lower/shifted-upper is universal
    //     across layouts, so they need no correction).
    // sendGuestKeyEvent applies KEYCODE_FIX first, then makes Shift match
    // SHIFT_LEVEL[target] -- adding a synthetic Shift when the client didn't hold
    // one but the keycode needs it, or SUPPRESSING the client's real Shift when the
    // keycode needs none -- and undoes exactly that adjustment on keyup, rechecked
    // against the CURRENT real Shift state (not the state at keydown) so a real
    // Shift press/release that happens to overlap a managed key is never clobbered.
    // A real Shift (or an unrelated modifier like AltGr) the user is genuinely
    // holding for something else is never touched. Only digits and ASCII
    // punctuation are managed -- Tab/arrows/F-keys/letters/modifiers all pass
    // through untouched, so this cannot reintroduce the Ctrl+Shift+Tab-style
    // breakage -nomodtweak (see above) was chosen to avoid. Verified with
    // x11vnc -debug_keyboard for the Shift-holding (US) and no-Shift
    // (international-layout) input shapes of parenleft/parenright/less/greater/bar.
    var KEYCODE_FIX = {
        0x28: 0x39,   // parenleft  -> 9      (ambiguous: phantom keycode 187)
        0x29: 0x30,   // parenright -> 0      (ambiguous: phantom keycode 188)
        0x3c: 0x2c    // less       -> comma  (ambiguous: ISO compat keycode 94)
    };
    var SHIFT_LEVEL = {   // needsShift, from the Xvfb "us" keymap; digits/punctuation only
        0x21: true,  0x22: true,  0x23: true,  0x24: true,  0x25: true,  0x26: true,
        0x27: false, /* apostrophe */          0x2a: true,  0x2b: true, /* *  + */
        0x2c: false, 0x2d: false, 0x2e: false, 0x2f: false, /* , - . / */
        0x30: false, 0x31: false, 0x32: false, 0x33: false, 0x34: false,
        0x35: false, 0x36: false, 0x37: false, 0x38: false, 0x39: false, /* 0-9 */
        0x3a: true,  0x3b: false, /* : ; */    0x3d: false, /* = */
        0x3e: true,  0x3f: true,  0x40: true,  /* > ? @ */
        0x5b: false, 0x5c: false, 0x5d: false, /* [ \ ] */
        0x5e: true,  0x5f: true,  0x60: false, /* ^ _ ` */
        0x7b: true,  0x7c: true,  0x7d: true,  0x7e: true  /* { | } ~ */
    };
    var GUAC_SHIFT_L = 0xFFE1, GUAC_SHIFT_R = 0xFFE2;
    var shiftAdjust = {};   // original keysym -> 'add' | 'remove' | null, while its press is active
    function realShiftDown() {
        return !!(keyboard && keyboard.pressed &&
                  (keyboard.pressed[GUAC_SHIFT_L] || keyboard.pressed[GUAC_SHIFT_R]));
    }
    function sendGuestKeyEvent(down, ks) {
        if (!client) return;
        var target = KEYCODE_FIX[ks];
        var needsShift;
        if (target !== undefined) {
            // A KEYCODE_FIX substitution always relies on the SUBSTITUTE's
            // shifted level by construction (9's Shift level is parenleft, not
            // 9's own unshifted meaning) -- this is NOT the substitute's own
            // natural SHIFT_LEVEL entry.
            needsShift = true;
        } else {
            target = ks;
            needsShift = SHIFT_LEVEL[ks];
        }
        if (needsShift === undefined) { client.sendKeyEvent(down ? 1 : 0, remapKeysym(ks)); return; }
        if (down) {
            if (!(ks in shiftAdjust)) {
                var shiftIsDown = realShiftDown();
                if (needsShift && !shiftIsDown) {
                    client.sendKeyEvent(1, GUAC_SHIFT_L); shiftAdjust[ks] = 'add';
                } else if (!needsShift && shiftIsDown) {
                    client.sendKeyEvent(0, GUAC_SHIFT_L); shiftAdjust[ks] = 'remove';
                } else {
                    shiftAdjust[ks] = null;
                }
            }
            client.sendKeyEvent(1, target);
        } else {
            client.sendKeyEvent(0, target);
            var adj = shiftAdjust[ks]; delete shiftAdjust[ks];
            // Recheck the REAL state now, not what it was at keydown: if a real
            // Shift press/release happened to overlap this key's hold, respect it
            // instead of fighting it.
            if (adj === 'add' && !realShiftDown()) client.sendKeyEvent(0, GUAC_SHIFT_L);
            else if (adj === 'remove' && realShiftDown()) client.sendKeyEvent(1, GUAC_SHIFT_L);
        }
    }
    function resetShiftAdjust() { shiftAdjust = {}; }
    // TESTHOOK:KEYREMAP:END
    function addWinKeyButton(bar) {
        var wrap = document.createElement("div"); wrap.className = "f";
        var b = document.createElement("button");
        b.type = "button"; b.className = "sec"; b.id = "winkey";
        b.textContent = "⊞ Win";   // squared-plus glyph
        b.title = "Send the Windows/Super key to the session. Use this for Super — the "
                + "local OS/compositor reserves the physical key and the browser cannot capture it.";
        b.addEventListener("click", function () { sendKeysymTap(0xFFEB); });   // Super_L
        wrap.appendChild(b); bar.appendChild(wrap);
        return b;
    }
    // ---- "Session…" modal -------------------------------------------------------
    // Packs the full connect controls (Session target, host/port, Sign-in +
    // credentials, Resolution, Scale, Clipboard, Sound, Connect/Disconnect) into
    // a modal dialog opened by a "Session…" button -- used on the main Connect
    // panel AND both pop-out types, so a pop-out (console mirror or virtual
    // monitor) can pick a DIFFERENT scenario and (re)connect entirely on its
    // own. Without this, a pop-out could only ever show the one scenario it
    // auto-connected to on open, with no way to recover if that session ended
    // except closing the window -- and since a pop-out is a fresh, independent
    // page load (window.open to the same URL, not a shared JS context with the
    // opener), it was never actually TIED to the opener tab except by this
    // missing UI. Every field here KEEPS its existing id and event listeners
    // (target/authmode change -> refreshUi; go/stop clicks ->
    // connect()/teardown(); URL_CONTROLS -> saveControls()) -- this only
    // reparents the existing DOM nodes, it does not rewire anything.
    // A native <dialog> IS the universal modal wrapper here (checked: this
    // project has no modal/overlay component of its own -- only ad hoc
    // hidden/shown fields like #deskui-confirm-wrap). showModal()/close() give
    // us backdrop dimming (::backdrop, styled in CSS), Escape-to-close, and
    // focus handling for free, so there is no hand-rolled backdrop element,
    // keydown listener, or open/closed class to maintain.
    function buildSessionCard() {
        var card = document.createElement("dialog"); card.id = "sessioncard";
        var head = document.createElement("div"); head.className = "row";
        var title = document.createElement("strong"); title.textContent = "Session";
        title.style.flex = "1";
        var closeBtn = document.createElement("button");
        closeBtn.type = "button"; closeBtn.id = "sessionclose"; closeBtn.className = "sec";
        closeBtn.textContent = "✕"; closeBtn.title = "Close";
        closeBtn.addEventListener("click", function () { card.close(); });
        head.appendChild(title); head.appendChild(closeBtn);
        card.appendChild(head);
        [ "target", "hostwrap", "portwrap", "authwrap", "credwrap", "passwrap",
          "resolution", "scale", "opt-clipboard", "opt-audio", "opt-trace" ].forEach(function (id) {
            moveField(card, id);
        });
        var btns = document.createElement("div"); btns.className = "row";
        btns.appendChild($("go")); btns.appendChild($("stop"));
        card.appendChild(btns);
        // Clicking the backdrop (a real <dialog>'s ::backdrop, which showModal()
        // creates): a click that lands on the <dialog> element itself rather
        // than any of its content is exactly that -- the standard idiom, since
        // ::backdrop isn't a separately targetable node.
        card.addEventListener("click", function (e) { if (e.target === card) card.close(); });
        document.body.appendChild(card);
        return card;
    }
    function addSessionButton(bar, card) {
        var b = document.createElement("button");
        b.id = "sessionbtn"; b.type = "button"; b.className = "sec";
        b.textContent = "Session…";
        b.title = "Choose a different session (Isolated / Console / Virtual monitor / "
                + "a remote host…), sign in, or change Resolution/Scale/Clipboard/Sound "
                + "— all without needing the tab this window was opened from.";
        b.addEventListener("click", function () { card.showModal(); });
        bar.appendChild(b);
        return b;
    }

    // ---- "Logs…": a fullscreen dialog over the browser trace log and the
    // server-side relay/guacd journal, filtered with selectable columns -----
    // Same <dialog> idiom as buildSessionCard() above (see its own comment for
    // why: no hand-rolled backdrop/Escape/focus handling needed), just sized
    // near-viewport instead of a fixed width, since a log table needs room.
    //
    // The server journal read reuses stSpawn2's superuser:"require" (defined
    // with the Self Tests below, hoisted so the declaration order here does
    // not matter): reading a root-run systemd unit's journal needs the SAME
    // PolicyKit elevation the Self Tests panel's own guacd checks already
    // require, for EITHER scope -- "this session" is not a lower privilege
    // tier than "all sessions", just a more heavily filtered result once
    // elevated, since journalctl itself gates read access to a root-run
    // unit's log the same way regardless of what the caller filters for
    // afterward. "All sessions" is additionally disabled in the UI for a
    // non-admin (cosmetic, matching this project's existing isAdmin-gated
    // UI elsewhere) -- the actual enforcement is superuser:"require" itself,
    // which Cockpit/PolicyKit refuses for a real non-admin regardless of
    // what the (bypassable) client-side option state says.
    var LOG_COLUMNS = {
        trace:  [ { key: "time", label: "Time" }, { key: "category", label: "Category" },
                  { key: "message", label: "Message" } ],
        server: [ { key: "time", label: "Time" }, { key: "unit", label: "Unit" },
                  { key: "message", label: "Message" } ]
    };
    var LOGS_LS_KEY = "edy-rdp-logs-columns";
    var logsColumns = {};   // {source: {key: bool}} -- which columns show, persisted
    function loadLogColumns() {
        var stored = {};
        try { stored = JSON.parse(localStorage.getItem(LOGS_LS_KEY) || "{}") || {}; }
        catch (e) { stored = {}; }
        Object.keys(LOG_COLUMNS).forEach(function (src) {
            if (!stored[src]) {
                stored[src] = {};
                LOG_COLUMNS[src].forEach(function (c) { stored[src][c.key] = true; });
            }
        });
        logsColumns = stored;
    }
    function saveLogColumns() {
        try { localStorage.setItem(LOGS_LS_KEY, JSON.stringify(logsColumns)); } catch (e) { /* ignore */ }
    }

    var logsDialog = null, logsData = [], logsSource = "trace";
    // journalctl's own --grep does the filtering server-side -- cockpit.spawn
    // execs an argv array (never a shell), so there is no pipeline to build and
    // no injection risk even though currentUuid ends up as one of that array's
    // elements. Because the relay mints the session uuid and hands it to guacd
    // as the connection id verbatim (both directions round-trip the same bare
    // hex string unchanged -- confirmed against edy_rdp_relay.py's own ready/
    // select handling), the SAME --grep value finds a session's lines in BOTH
    // the relay's own unit and guacd's container log.
    // "-6 hours" for "all sessions": journalctl with no --since would happily
    // return the ENTIRE unit history, which for a long-lived host is a lot to
    // pull through a privileged spawn and render in one table. The window is
    // disclosed in the scope <option>'s own label (buildLogsDialog(), below)
    // and in the status line whenever a fetch actually completes empty, so an
    // operator never has to guess whether "0 entries" means "nothing
    // happened" or "it happened outside the window" -- found missing (a
    // silent cap) by adversarial review; both disclosures were added because
    // of that finding, not just the CHANGELOG/KNOWN_ISSUES mention.
    function fetchServerLogs(scope) {
        var args = ["-o", "short-iso", "--no-pager"];
        if (scope === "all") {
            args = args.concat(["--since", "-6 hours"]);
        } else {
            if (!currentUuid) return Promise.reject("connect a session first");
            args = args.concat(["--grep", currentUuid]);
        }
        // Each unit's failure (most plausibly the superuser:"require"
        // elevation itself being refused) is captured, not discarded: a
        // caller-visible {rows, error} beats silently resolving to an empty
        // array, which would make a genuine auth/availability failure
        // indistinguishable from "this session really has no log lines" --
        // exactly the one piece of error-reporting an earlier draft of this
        // function lost, found by adversarial review.
        function tryUnit(spawnArgs, unit) {
            return stSpawn2(spawnArgs).then(
                function (out) { return { rows: parseJournal(out, unit), error: null }; },
                function (e) { return { rows: [], error: unit + ": " + e }; }
            );
        }
        return Promise.all([
            tryUnit(["journalctl", "-u", "edy-rdp-relay"].concat(args), "relay"),
            tryUnit(["journalctl", "CONTAINER_NAME=edy-rdp-guacd"].concat(args), "guacd")
        ]).then(function (parts) {
            var rows = parts[0].rows.concat(parts[1].rows);
            rows.sort(function (a, b) { return b.time - a.time; });   // newest first
            var errors = parts.map(function (p) { return p.error; }).filter(Boolean);
            return { rows: rows, error: errors.length ? errors.join("; ") : null };
        });
    }
    // TESTHOOK:PARSEJOURNAL:BEGIN -- tests/js/view_logs.test.js extracts this
    // exact block (verbatim) and exercises it standalone; keep it self-contained
    // (no outer-scope references at all).
    //
    // journalctl -o short-iso lines start "<iso-timestamp> host proc[pid]: rest",
    // but that timestamp is only printed once PER JOURNAL ENTRY -- an entry
    // whose own message contains a literal newline (e.g. a Python traceback
    // logged in one write) spans several physical lines, and only the first
    // carries a real timestamp. An earlier draft matched "the first
    // whitespace-delimited token" against EVERY split line indiscriminately,
    // which (found by adversarial review, reproduced) fragmented one entry
    // into several bogus, wrongly-time-sorted rows and silently swallowed a
    // continuation line's own leading word into the discarded "timestamp"
    // capture. Fixed by matching an ACTUAL ISO-8601-shaped prefix specifically
    // (not just any token), and appending any line that does not match one to
    // the PREVIOUS row's message instead of starting a new row for it. \r is
    // stripped up front so CRLF-style output (which made the old regex's `$`
    // fail to match at all, dumping the whole raw line including its real
    // timestamp into an unparsed, wrongly-sorted message) can't reach the
    // per-line regex in the first place.
    function parseJournal(out, unit) {
        var lines = String(out || "").replace(/\r/g, "").split("\n");
        var rows = [];
        lines.forEach(function (line) {
            if (!line) return;
            var m = /^(\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}[+-]\d{2}:?\d{2})\s(.*)$/.exec(line);
            if (m) {
                var t = Date.parse(m[1]);
                rows.push({ time: isNaN(t) ? 0 : t, unit: unit, message: m[2] });
            } else if (rows.length) {
                rows[rows.length - 1].message += "\n" + line;
            } else {
                // no timestamp match AND nothing yet to attach to (the very
                // first line itself is unparseable) -- keep the whole line
                // rather than silently dropping it.
                rows.push({ time: 0, unit: unit, message: line });
            }
        });
        return rows;
    }
    // TESTHOOK:PARSEJOURNAL:END

    function fmtLogCell(key, val) {
        if (key === "time") return val ? new Date(val).toLocaleString() : "";
        return val == null ? "" : String(val);
    }
    function renderLogsTable() {
        var cols = LOG_COLUMNS[logsSource].filter(function (c) { return logsColumns[logsSource][c.key]; });
        var thead = $("logs-thead"), tbody = $("logs-tbody");
        thead.innerHTML = "";
        var htr = document.createElement("tr");
        cols.forEach(function (c) { var th = document.createElement("th"); th.textContent = c.label; htr.appendChild(th); });
        thead.appendChild(htr);

        // Search matches against EVERY column this source has, not just the
        // ones currently checked visible -- otherwise toggling a column
        // checkbox silently changes which rows an unchanged query matches.
        var allCols = LOG_COLUMNS[logsSource];
        var q = ($("logs-search") ? $("logs-search").value : "").toLowerCase();
        tbody.innerHTML = "";
        var shown = 0;
        logsData.forEach(function (row) {
            if (q) {
                var searchText = allCols.map(function (c) { return fmtLogCell(c.key, row[c.key]); }).join(" ").toLowerCase();
                if (searchText.indexOf(q) < 0) return;
            }
            shown++;
            var tr = document.createElement("tr");
            cols.forEach(function (c) { var td = document.createElement("td"); td.textContent = fmtLogCell(c.key, row[c.key]); tr.appendChild(td); });
            tbody.appendChild(tr);
        });
        var sum = $("logs-summary");
        if (sum) sum.textContent = shown + " of " + logsData.length + " entries" + (q ? " (filtered)" : "");
    }
    function renderLogColumnPicker() {
        var wrap = $("logs-columns"); wrap.innerHTML = "";
        LOG_COLUMNS[logsSource].forEach(function (c) {
            var lbl = document.createElement("label"); lbl.className = "colpick";
            var cb = document.createElement("input"); cb.type = "checkbox";
            cb.checked = !!logsColumns[logsSource][c.key];
            cb.addEventListener("change", function () {
                logsColumns[logsSource][c.key] = cb.checked; saveLogColumns(); renderLogsTable();
            });
            lbl.appendChild(cb); lbl.appendChild(document.createTextNode(" " + c.label));
            wrap.appendChild(lbl);
        });
    }
    function refreshLogsData() {
        var status = $("logs-status");
        if (logsSource === "trace") {
            status.textContent = ""; status.className = "muted";
            logsData = traceLog.slice().reverse();   // newest first, matching the server view
            renderLogsTable();
            return;
        }
        var scope = $("logs-scope") ? $("logs-scope").value : "session";
        status.textContent = "Loading…"; status.className = "muted";
        fetchServerLogs(scope).then(function (result) {
            logsData = result.rows;
            if (result.error) {
                // A partial (one unit ok, one failed) or total failure is
                // shown even though rows may still be non-empty -- never
                // silently downgrade "could not read X" into a plain count.
                status.textContent = "Could not read the full journal (" + result.error + ")";
                status.className = "muted err-text";
            } else if (!result.rows.length && scope === "all") {
                status.textContent = "No matching entries in the last 6 hours.";
                status.className = "muted";
            } else {
                status.textContent = "";
                status.className = "muted";
            }
            renderLogsTable();
        }, function (e) {
            logsData = [];
            status.textContent = "Could not read the server journal: " + e;
            status.className = "muted err-text";
            renderLogsTable();
        });
    }
    function buildLogsDialog() {
        var dlg = document.createElement("dialog"); dlg.id = "logsdialog";
        var head = document.createElement("div"); head.className = "row";
        var title = document.createElement("strong"); title.textContent = "Logs"; title.style.flex = "1";
        var closeBtn = document.createElement("button");
        closeBtn.type = "button"; closeBtn.className = "sec"; closeBtn.textContent = "✕"; closeBtn.title = "Close";
        closeBtn.addEventListener("click", function () { dlg.close(); });
        head.appendChild(title); head.appendChild(closeBtn);
        dlg.appendChild(head);

        var controls = document.createElement("div"); controls.className = "row";
        var srcSel = document.createElement("select"); srcSel.id = "logs-source";
        [["trace", "Browser Trace"], ["server", "Server Journal"]].forEach(function (o) {
            var opt = document.createElement("option"); opt.value = o[0]; opt.textContent = o[1]; srcSel.appendChild(opt);
        });
        var scopeSel = document.createElement("select"); scopeSel.id = "logs-scope";
        scopeSel.style.display = "none";   // trace (the default source) has no scope
        [["session", "This session"], ["all", "All sessions (admin, last 6h)"]].forEach(function (o) {
            var opt = document.createElement("option"); opt.value = o[0]; opt.textContent = o[1]; scopeSel.appendChild(opt);
        });
        var refreshBtn = document.createElement("button");
        refreshBtn.type = "button"; refreshBtn.className = "sec"; refreshBtn.textContent = "Refresh";
        refreshBtn.addEventListener("click", refreshLogsData);
        controls.appendChild(srcSel); controls.appendChild(scopeSel); controls.appendChild(refreshBtn);
        dlg.appendChild(controls);

        var colsBar = document.createElement("div"); colsBar.className = "row"; colsBar.id = "logs-columns";
        dlg.appendChild(colsBar);

        var searchWrap = document.createElement("div"); searchWrap.className = "row";
        var search = document.createElement("input"); search.type = "search"; search.id = "logs-search";
        search.placeholder = "Filter…"; search.style.flex = "1";
        search.addEventListener("input", renderLogsTable);
        searchWrap.appendChild(search);
        dlg.appendChild(searchWrap);

        var tableWrap = document.createElement("div"); tableWrap.id = "logs-tablewrap";
        var table = document.createElement("table"); table.className = "sessions";
        var thead = document.createElement("thead"); thead.id = "logs-thead";
        var tbody = document.createElement("tbody"); tbody.id = "logs-tbody";
        table.appendChild(thead); table.appendChild(tbody);
        tableWrap.appendChild(table);
        dlg.appendChild(tableWrap);

        var footer = document.createElement("div"); footer.className = "row";
        var summary = document.createElement("span"); summary.id = "logs-summary"; summary.className = "muted";
        var status = document.createElement("span"); status.id = "logs-status"; status.className = "muted";
        footer.appendChild(summary); footer.appendChild(status);
        dlg.appendChild(footer);

        srcSel.addEventListener("change", function () {
            logsSource = srcSel.value;
            scopeSel.style.display = (logsSource === "server") ? "" : "none";
            renderLogColumnPicker();
            refreshLogsData();
        });
        scopeSel.addEventListener("change", refreshLogsData);
        dlg.addEventListener("click", function (e) { if (e.target === dlg) dlg.close(); });
        // isAdmin can change live (see the cockpit.permission "changed"
        // listener elsewhere in this file) while this dialog sits closed, so
        // re-sync the "All sessions" option's availability every time it
        // opens rather than only once at build time.
        dlg.syncAdminGating = function () {
            var allOpt = scopeSel.querySelector('option[value="all"]');
            if (allOpt) allOpt.disabled = !isAdmin;
            if (!isAdmin && scopeSel.value === "all") scopeSel.value = "session";
        };
        document.body.appendChild(dlg);
        return dlg;
    }
    function addViewLogsButton(bar) {
        var b = document.createElement("button");
        b.id = "viewlogs";
        b.type = "button"; b.className = "sec"; b.textContent = "Logs…";
        b.title = "View the browser's clipboard/sound/keyboard trace log, or the "
                + "server-side relay/guacd journal, in a filterable table.";
        b.addEventListener("click", function () {
            if (!logsDialog) { loadLogColumns(); logsDialog = buildLogsDialog(); renderLogColumnPicker(); }
            logsDialog.syncAdminGating();
            refreshLogsData();
            logsDialog.showModal();
        });
        bar.appendChild(b);
        return b;
    }

    function enterMonitorMode() {
        document.documentElement.classList.add("monitor");
        var m = location.hash.match(/monitor=(\d+)/);
        document.title = "Virtual Monitor" + (m ? " " + m[1] : "") + " — " + location.hostname;
        window.addEventListener("pagehide", monitorTeardown);
        window.addEventListener("beforeunload", monitorTeardown);
        // top control strip, moved out of the hidden main bar. The full connect
        // controls (Resolution/Scale/Sound included) live in the "Session…" card
        // so this pop-out can switch scenario and reconnect on its own.
        var bar = document.createElement("div"); bar.id = "seatbar";
        document.body.appendChild(bar);
        var card = buildSessionCard();
        addSessionButton(bar, card);
        addFullscreenButton(bar);
        addSpecialKeysToggle(bar);
        addWinKeyButton(bar);
        addClipboardButtons(bar);
        addViewLogsButton(bar);
        bar.appendChild($("numlock"));   // flip the REMOTE NumLock from the pop-out
        bar.appendChild($("addmon"));     // open another virtual monitor window
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
        // Full connect controls (Session/Sign-in/Resolution/Scale/Clipboard/Sound
        // + Connect/Disconnect) live in the "Session…" card -- see buildSessionCard
        // -- so this pop-out can pick a different scenario (e.g. Isolated, to reach
        // the GDM greeter, which the console mirror cannot show pre-login) and
        // reconnect without needing the tab it was opened from.
        var card = buildSessionCard();
        addSessionButton(bar, card);
        addFullscreenButton(bar);
        addSpecialKeysToggle(bar);
        addWinKeyButton(bar);
        addClipboardButtons(bar);
        addViewLogsButton(bar);
        bar.appendChild($("numlock"));   // flip the REMOTE NumLock from the pop-out
        bar.appendChild($("addmon"));     // open another virtual monitor window
        $("target").value = "console";
        refreshUi();
        connect("console");
    }

    // ---- the main Connect panel -------------------------------------------------
    // Same consolidation as the pop-outs: the full connect controls move into the
    // "Session…" modal, leaving the bar to just Session… + the quick-access
    // action buttons (Num Lock, Add Monitor, Pop-out, Send/Receive clip).
    function enterConnectMode() {
        var bar = document.querySelector("#panel-connect .bar");
        var card = buildSessionCard();
        var sessionBtn = addSessionButton(bar, card);
        bar.insertBefore(sessionBtn, bar.firstChild);   // the primary entry point now; lead with it
        addClipboardButtons(bar);
        addViewLogsButton(bar);
        // Restore the active tab from the URL (?tab=sessions etc.), same as a
        // shared/bookmarked link; default to Connect. Skipped by the pop-out
        // modes entirely -- they never show tabs and enterConnectMode() only
        // runs on the plain page.
        var wantTab = hashParam("tab");
        selectTab("tab-" + (TAB_NAMES.indexOf(wantTab) >= 0 ? wantTab : "connect"));
        // Seed the Update tab's badge on load -- a plain read of the cached
        // status, never a live GitHub call (see refreshUpdateBadge()) -- so an
        // available update is visible before the operator ever opens the tab.
        // Skipped in the pop-out modes entirely, same as the tab restore above:
        // they never show tabs (html.monitor .tabs is display:none).
        refreshUpdateBadge();
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

    // A transient notice for something the panel did ON ITS OWN (e.g. quietly
    // switching scenario), as distinct from setStatus(), the persistent
    // connection-state line: it fades out by itself and takes no pointer events,
    // so it can neither be missed as "the current state" nor get in the way of
    // a click. A second toast while one is showing restarts the clock.
    var TOAST_MS = 5000, toastTimer = null;
    function showToast(msg, kind) {
        var el = $("toast");
        if (!el) {
            el = document.createElement("div"); el.id = "toast";
            el.setAttribute("role", "status"); el.setAttribute("aria-live", "polite");
            document.body.appendChild(el);
            void el.offsetWidth;   // commit the initial (hidden) style BEFORE .show is ever
                                    // added, so the very first toast of a page load actually
                                    // transitions instead of just appearing at full opacity.
        }
        // A native <dialog> opened with showModal() (the Session… card) makes
        // everything OUTSIDE it inert -- removed from the accessibility tree, not
        // merely dimmed -- so a toast left parented to <body> while that dialog is
        // open would be both visually stuck under the backdrop AND silently
        // unannounced to assistive tech, exactly when this feature most needs to
        // say why the scenario changed. Reparent into whichever dialog is
        // currently open (or back to <body> once none is) so it stays live either
        // way -- position:fixed keeps it viewport-anchored regardless of parent.
        var host = document.querySelector("dialog[open]") || document.body;
        if (el.parentNode !== host) host.appendChild(el);
        el.removeAttribute("aria-hidden");
        el.textContent = msg;
        el.className = (kind ? kind + " " : "") + "show";
        if (toastTimer) clearTimeout(toastTimer);
        toastTimer = setTimeout(function () {
            toastTimer = null;
            el.classList.remove("show");
            // opacity:0 alone leaves the node (and its stale text) in the
            // accessibility tree indefinitely; aria-hidden actually removes it.
            el.setAttribute("aria-hidden", "true");
        }, TOAST_MS);
    }

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
        // reset() BEFORE nulling onkeyup/onkeydown, not after: it fires a real
        // onkeyup for every keysym still tracked as pressed (releasing them
        // properly, same as the focus-loss fix below) and -- load-bearing, not
        // just hygiene -- clears the vendored library's own internal key-repeat
        // timers. Without this, disconnecting while a key was mid-autorepeat
        // left that timer running against a keyboard whose onkeyup/onkeydown
        // had just been nulled, throwing "onkeyup is not a function" on every
        // tick, indefinitely (found while verifying the focus-loss fix below,
        // pre-existing, not introduced by it).
        if (keyboard) { keyboard.reset(); keyboard.onkeydown = keyboard.onkeyup = null; keyboard = null; }
        resetShiftAdjust();   // a mid-press disconnect must not leak a stale add/remove into the next session
        var lockBox = $("display");
        if (lockBox && lockSyncHandler) lockBox.removeEventListener("keydown", lockSyncHandler, true);
        if (lockBox && clipReadHandler) lockBox.removeEventListener("focus", clipReadHandler, true);
        // TESTHOOK:KEYBLUR_TEARDOWN:BEGIN -- tests/js/keyboard_blur.test.js
        // extracts this verbatim too, alongside TESTHOOK:KEYBLUR above.
        if (keyboardBlurHandler) {
            if (lockBox) lockBox.removeEventListener("blur", keyboardBlurHandler, true);
            window.removeEventListener("blur", keyboardBlurHandler);
            document.removeEventListener("visibilitychange", keyboardBlurHandler);
        }
        keyboardBlurHandler = null;
        // TESTHOOK:KEYBLUR_TEARDOWN:END
        lockSyncHandler = null; clipReadHandler = null;
        remoteLocks = null; browserLocks = null;
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

    // Pre-login there is no desktop for grd to mirror, so the console scenario
    // can only fail until someone signs in on the physical seat -- and the
    // greeter is the one thing that CAN render before that. When nobody is
    // logged in locally at all (zero active graphical seat sessions) there is
    // no session to preserve, so switching to the greeter loses nothing. This
    // is deliberately NOT the LOCKED_SEAT_RE case: a locked seat still holds a
    // session worth resuming, and that path stays a manual choice. Resolves to
    // the key to actually connect. Best-effort and FAIL-OPEN, like the relay's
    // physical_session_locked(): a probe error, non-answer or timeout means
    // "connect to console as asked" -- it never blocks a normal connect.
    var CONSOLE_PROBE_MS = 4000;
    function resolveConsoleFallback(key) {
        if (key !== "console") return cockpit.resolve(key);
        setStatus("Checking who is signed in on the physical console…");
        var timeout = new Promise(function (resolve) { setTimeout(function () { resolve(null); }, CONSOLE_PROBE_MS); });
        return Promise.race([controlRequest({ op: "deskui-status" }), timeout])
            .then(function (r) {
                if (!r || !r.ok || r.active_graphical_sessions !== 0) return key;
                $("target").value = "greeter";
                refreshUi();
                showToast("No one is signed in on the physical console — opening the sign-in screen instead.");
                return "greeter";
            })
            .catch(function () { return key; });
    }

    function connect(forceKey) {
        $("go").disabled = true;
        resolveConsoleFallback(forceKey || $("target").value).then(connectAs);
    }

    function connectAs(key) {
        var t = TARGETS[key];
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
            trace("clipboard", "remote->browser: stream opened, mimetype=" + mimetype);
            if (!/^text\//.test(mimetype || "text/plain")) {
                trace("clipboard", "remote->browser: non-text mimetype, discarding");
                discardTextStream(stream); return;
            }
            var reader = new Guacamole.StringReader(stream), text = "";
            reader.ontext = function (t) { text += t; };
            reader.onend = function () {
                lastRemoteClip = text;   // always captured, so "Receive clipboard" can hand it over
                trace("clipboard", "remote->browser: captured " + text.length + " chars (clipboardOn=" + clipboardOn + " focused=" + document.hasFocus() + ")");
                // Auto-sync to the OS clipboard only while the toggle is on AND this
                // document is focused -- writeText() REJECTS (async) when the window is
                // not focused, so guard on hasFocus() and swallow the promise rejection
                // (a try/catch does not catch an async reject). When unfocused the text
                // still sits in lastRemoteClip for the "Receive clip" button.
                if (!clipboardOn || !document.hasFocus()) {
                    trace("clipboard", "remote->browser: not auto-writing to OS clipboard (toggle off or unfocused)");
                    return;
                }
                try {
                    if (navigator.clipboard && navigator.clipboard.writeText) {
                        navigator.clipboard.writeText(text).then(function () {
                            trace("clipboard", "remote->browser: auto-wrote " + text.length + " chars to the OS clipboard");
                        }, function (e) { trace("clipboard", "remote->browser: OS clipboard write blocked: " + e); });
                    } else {
                        trace("clipboard", "remote->browser: no navigator.clipboard.writeText in this context");
                    }
                } catch (e) { trace("clipboard", "remote->browser: threw " + e); }
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
                : key === "greeter" ? "Connected to the sign-in screen."
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
            if (!client || !clipboardOn || !currentUuid) {
                trace("clipboard", "browser->remote: focus event ignored (client=" + !!client
                    + " clipboardOn=" + clipboardOn + " currentUuid=" + !!currentUuid + ")");
                return;
            }
            try {
                if (navigator.clipboard && navigator.clipboard.readText) {
                    navigator.clipboard.readText().then(function (text) {
                        if (!client || !clipboardOn || !text) {
                            trace("clipboard", "browser->remote: readText resolved but nothing to send (empty or state changed)");
                            return;
                        }
                        try {
                            var w = new Guacamole.StringWriter(client.createClipboardStream("text/plain"));
                            w.sendText(text); w.sendEnd();
                            trace("clipboard", "browser->remote: pushed " + text.length + " chars on focus");
                        } catch (e) { trace("clipboard", "browser->remote: stream unavailable: " + e); }
                    }).catch(function (e) { trace("clipboard", "browser->remote: readText() blocked: " + e); });
                }
            } catch (e) { /* no Clipboard API */ }
        };
        box.addEventListener("focus", clipReadHandler, true);
        keyboard = new Guacamole.Keyboard(box);
        keyboard.onkeydown = function (k) { sendGuestKeyEvent(true, k); };
        keyboard.onkeyup = function (k) { sendGuestKeyEvent(false, k); };
        // A keydown with no matching keyup is a real, live-reported bug (a held
        // modifier -- classically Alt, via Alt+Tab -- "sticks" on the GUEST for
        // as long as the session is unfocused: any mouse click/drag/scroll
        // during that window arrives there as an Alt-combo, not just whatever
        // the operator types on returning). The browser only delivers keyup to
        // whatever element currently holds DOM focus, and losing focus never
        // synthesizes one -- so the moment this element (or the whole browser
        // window) loses focus while a key is physically down, neither
        // Guacamole.Keyboard's own bookkeeping nor this file's own shiftAdjust
        // tracking ever hears about the release. Guacamole.Keyboard DOES
        // self-correct stale modifier state by comparing its tracked state
        // against the browser's live event.altKey/etc flags, but only
        // reactively, on the NEXT keyboard event it sees (correctly releasing
        // the stale modifier BEFORE that new key, verified against the real
        // vendored library -- this is not a same-keystroke misread) -- so
        // nothing corrects the guest for the whole time the operator is away.
        // keyboard.reset() (a real Guacamole.Keyboard API) walks every keysym
        // it still believes is pressed and fires a genuine onkeyup for each --
        // routing through sendGuestKeyEvent exactly like a real keyup, so the
        // GUEST is actually told to release them the moment focus is lost,
        // rather than waiting on that reactive correction. Cheap even when
        // nothing is pressed (the overwhelmingly common case, since most
        // blur/visibilitychange events happen mid-typing, not mid-keypress) --
        // measured at roughly 1 microsecond per no-op call against the real
        // library. resetShiftAdjust() is defence in depth on top of that:
        // reset() already clears any shiftAdjust entry for a keysym still in
        // keyboard.pressed (via that same onkeyup path), but this also covers
        // a keysym whose entry exists only in shiftAdjust with no matching
        // keyboard.pressed entry (see teardown()'s own identical pairing, and
        // the "client going null mid-press" test in
        // tests/js/keyboard_remap.test.js for why that gap matters). Known,
        // accepted trade-off (see tests/js/keyboard_blur.test.js's own header
        // for the reasoning): a modifier held THROUGH a focus round-trip
        // without ever being physically released gets spuriously released
        // here too, since the browser never re-fires a keydown for a key that
        // was never actually released -- the next physical press of that same
        // key restores it, and releasing a still-held key is far safer than
        // the original bug (indefinitely stuck down). Bound to THIS element's
        // own blur (focus moved to another in-page element, e.g. clicking a
        // different tab) AND window blur (real X11/browser testing found BOTH
        // often fire together for Alt+Tab in practice, not just window's, so
        // this is deliberately not relying on any one browser's exact
        // behavior) AND visibilitychange (the tab was backgrounded/minimized,
        // which does not always fire either blur) -- reset() firing more than
        // once for the same focus-loss event is harmless (idempotent; a no-op
        // once nothing is left pressed).
        // TESTHOOK:KEYBLUR:BEGIN -- tests/js/keyboard_blur.test.js extracts this
        // block verbatim and runs it standalone via vm, so that test exercises
        // the actual shipped wiring, not a reimplementation.
        if (keyboardBlurHandler) {
            box.removeEventListener("blur", keyboardBlurHandler, true);
            window.removeEventListener("blur", keyboardBlurHandler);
            document.removeEventListener("visibilitychange", keyboardBlurHandler);
        }
        keyboardBlurHandler = function () {
            if (!keyboard) return;
            trace("keyboard", "focus lost -- releasing any keys still held (keyboard.reset())");
            keyboard.reset();
            resetShiftAdjust();
        };
        box.addEventListener("blur", keyboardBlurHandler, true);
        window.addEventListener("blur", keyboardBlurHandler);
        document.addEventListener("visibilitychange", keyboardBlurHandler);
        // TESTHOOK:KEYBLUR:END

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

    // ---- Desktop UI control panel --------------------------------------------
    // Reads this host's desktop state (default target, display manager, sessions in
    // use) and, for an administrator on a host that has opted in, offers
    // enable/disable/start/stop. The relay is authoritative on every gate; this only
    // reflects it. Stop/Disable stay disabled until the operator types the host name
    // -- the client half of the "don't kill your own desktop" guard.
    var deskuiState = null;   // last status payload, for the button logic

    function deskuiRow(label, value, warn) {
        var tr = document.createElement("tr");
        var k = document.createElement("td"); k.textContent = label;
        var v = document.createElement("td"); v.textContent = value;
        if (warn) v.className = "warn";
        tr.appendChild(k); tr.appendChild(v);
        return tr;
    }

    // Enable the destructive buttons only while the typed host name matches, and
    // only when the host has opted in and the caller is an administrator.
    function deskuiSyncButtons() {
        var st = deskuiState || {};
        var canWrite = !!st.write_enabled && !!st.admin;
        var installed = st.desktop_installed !== false;
        var confirmEl = $("deskui-confirm");
        var confirmOk = canWrite && confirmEl && confirmEl.value === st.hostname && !!st.hostname;
        // constructive actions: available whenever the host opted in + caller is admin
        $("deskui-enable").disabled = !canWrite;
        $("deskui-start").disabled = !canWrite;
        // destructive actions: require the typed-host-name confirmation
        $("deskui-disable").disabled = !confirmOk;
        $("deskui-stop").disabled = !(confirmOk && installed);
        $("deskui-confirm-wrap").hidden = !canWrite;
    }

    function renderDeskUi() {
        var body = $("deskui-state-body");
        body.innerHTML = '<tr><td colspan="2" class="muted">Loading…</td></tr>';
        $("deskui-hostname").textContent = "";
        controlRequest({ op: "deskui-status" }).then(function (r) {
            deskuiState = r || {};
            if (!r || !r.ok) {
                body.innerHTML = '<tr><td colspan="2" class="muted">'
                    + ((r && r.error) || "Desktop UI control is not available on this host.")
                    + '</td></tr>';
                ["enable", "start", "disable", "stop"].forEach(function (a) { $("deskui-" + a).disabled = true; });
                $("deskui-confirm-wrap").hidden = true;
                return;
            }
            $("deskui-hostname").textContent = r.hostname || "";
            var live = r.active_graphical_sessions || 0;
            body.innerHTML = "";
            body.appendChild(deskuiRow("Boots to",
                r.boot_to_desktop ? "graphical desktop" : "console (" + (r.default_target || "multi-user.target") + ")"));
            body.appendChild(deskuiRow("Display manager", r.display_manager || "none detected",
                !r.display_manager));
            if (r.display_manager) {
                body.appendChild(deskuiRow("Running now", r.dm_active ? "yes" : "no"));
                body.appendChild(deskuiRow("Enabled at boot",
                    (r.dm_enabled === null || r.dm_enabled === undefined) ? "unknown" : String(r.dm_enabled)));
            }
            body.appendChild(deskuiRow("Desktop sessions in use", String(live), live > 0));
            body.appendChild(deskuiRow("Control on this host",
                r.write_enabled ? (r.admin ? "enabled (you are an administrator)" : "enabled (needs administrative access)")
                                : "read-only (not opted in on this host)"));
            $("deskui-note").textContent = r.write_enabled
                ? "Stop and Disable ask you to type the host name to confirm."
                : "Set EDY_RDP_DESKUI_ENABLE=1 in this host's .env to allow changes.";
            var s = $("deskui-status");
            if (live > 0) {
                s.textContent = live + " desktop session(s) are in use. Stopping the desktop now will end them.";
                s.className = "status err";
            } else {
                s.textContent = "Read-only view unless this host has opted in and you are an administrator.";
                s.className = "status";
            }
            deskuiSyncButtons();
        }).catch(function (e) {
            body.innerHTML = '<tr><td colspan="2" class="muted">Control API error: ' + e + '</td></tr>';
        });
    }

    // Run one write verb. For stop/disable, pass the typed confirmation; the relay
    // re-checks it (and the admin + opt-in gates) server-side regardless.
    function deskuiAction(action) {
        var st = deskuiState || {};
        var confirm = $("deskui-confirm") ? $("deskui-confirm").value : "";
        var destructive = (action === "stop" || action === "disable");
        var verb = { enable: "Enable at boot", disable: "Disable at boot",
                     start: "Start", stop: "Stop" }[action] || action;
        var s = $("deskui-status");
        s.textContent = verb + "…"; s.className = "status";
        ["enable", "start", "disable", "stop"].forEach(function (a) { $("deskui-" + a).disabled = true; });
        var req = { op: "deskui", action: action };
        if (destructive) req.confirm = confirm;
        controlRequest(req).then(function (r) {
            if (r && r.ok) {
                s.textContent = verb + " completed" + (r.forced ? " (forced — sessions were ended)" : "") + ".";
                s.className = "status ok";
                if ($("deskui-confirm")) $("deskui-confirm").value = "";
            } else {
                var why = (r && (r.detail || r.error)) || "refused";
                if (r && r.need_confirm) why = "type the host name (" + (r.hostname || st.hostname || "") + ") to confirm";
                s.textContent = verb + " failed: " + why; s.className = "status err";
            }
            renderDeskUi();
        }).catch(function (e) {
            s.textContent = verb + " error: " + e; s.className = "status err";
            renderDeskUi();
        });
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

    // ---- Self-update panel ---------------------------------------------------
    // Reads this host's cached update state (docs/SELFUPDATE.md's control-op
    // contract: update-status/-check/-apply/-rollback) and, for an
    // administrator, offers Update now (typed-hostname confirmation, exactly
    // like deskui's Stop/Disable) and Roll back (no confirmation -- the
    // recovery action stays low-friction, same asymmetry as deskui's plain
    // "start"). The relay is authoritative on every gate; this only reflects
    // and re-checks it.
    var updateState = null;      // last update-status/-check payload, for the button logic
    var updateHostname = null;   // this host's name, for the typed confirmation -- see below

    function updateRow(label, text, warn) {
        var tr = document.createElement("tr");
        var k = document.createElement("td"); k.textContent = label;
        var v = document.createElement("td"); v.textContent = text;
        if (warn) v.className = "warn";
        tr.appendChild(k); tr.appendChild(v);
        return tr;
    }
    function updateLinkRow(label, url) {
        var tr = document.createElement("tr");
        var k = document.createElement("td"); k.textContent = label;
        var v = document.createElement("td");
        var a = document.createElement("a");
        a.href = url; a.textContent = url; a.target = "_blank"; a.rel = "noopener noreferrer";
        v.appendChild(a);
        tr.appendChild(k); tr.appendChild(v);
        return tr;
    }
    // "not checked yet" (checked_at null, a host that has never run a check) is
    // distinct from a live check that came back with an error (e.g. this
    // repository has no GitHub Releases published yet) -- check_error already
    // reads as a full sentence ("no releases published yet for owner/repo"),
    // so it is shown verbatim rather than paraphrased. no_releases is its own
    // typed flag (not string-matched) precisely so THIS calm, expected, day-one
    // state can be told apart from a real outage -- found by review: both used
    // to share the untyped check_error field, so this project's own repo (which
    // has no Releases yet) rendered as a bold red error on a brand-new install.
    function latestVersionText(r) {
        if (!r.checked_at) return "not checked yet";
        if (r.no_releases) return "no releases published on this repository yet";
        if (r.check_error) return r.check_error;
        return r.latest_version || "unknown";
    }
    // last_apply is {from, to, result: "ok"|"rolled_back"|"rollback_failed",
    // detail, at} -- built fresh from from/to/result rather than echoing the
    // stored "detail" verbatim, since the two privileged scripts phrase detail
    // slightly differently for the same result (e.g. apply's "healthy" vs.
    // rollback's "manual rollback, healthy") and this is the one line an
    // operator reads to understand what just happened on this host.
    function describeLastApply(la) {
        if (!la) return null;
        var to = la.to || "an unknown version", from = la.from || "an earlier version";
        if (la.result === "ok") return "Update to " + to + " completed and is healthy.";
        if (la.result === "rolled_back")
            return "Update to " + to + " failed its health check and was automatically rolled back to " + from + ".";
        if (la.result === "rollback_failed")
            return "Update to " + to + " failed its health check AND the automatic rollback also failed — this host needs a human right now.";
        return la.detail || (from + " → " + to);
    }

    // Enable Update now / Roll back only for an administrator (the same
    // client-side reflection of the server's admin gate used throughout this
    // panel -- e.g. connectAs()'s console/remote checks; the relay re-checks
    // is_admin regardless of what this shows), and only once the typed host
    // name matches for Update now specifically (Roll back needs no typed
    // confirmation -- see the comment above the panel setup).
    function updateSyncButtons() {
        var st = updateState || {};
        var confirmEl = $("update-confirm");
        var confirmOk = isAdmin && !!updateHostname && confirmEl && confirmEl.value === updateHostname;
        $("update-apply").disabled = !(isAdmin && st.update_available && confirmOk);
        $("update-rollback").disabled = !(isAdmin && st.rollback_available);
        $("update-confirm-wrap").hidden = !(isAdmin && st.update_available);
    }

    function setUpdateBadge(on) {
        var dot = $("update-badge");
        if (dot) dot.hidden = !on;
    }

    function renderUpdate() {
        var body = $("update-state-body");
        body.innerHTML = '<tr><td colspan="2" class="muted">Loading…</td></tr>';
        // update-status/-check never carry this host's name (unlike
        // deskui-status, which does) -- SelfUpdate.hostname is only ever handed
        // back inside update-apply's need_confirm refusal. Both controllers
        // derive it the exact same way (socket.gethostname(), same relay
        // process -- see relay/selfupdate.py and relay/edy_rdp_relay.py), so
        // deskui-status's read-only, non-admin-gated hostname is a safe,
        // already-available stand-in for the confirmation label; the relay
        // re-derives and checks its OWN value regardless of what this shows.
        var hostReq = updateHostname ? cockpit.resolve(null)
            : controlRequest({ op: "deskui-status" }).catch(function () { return null; });
        Promise.all([controlRequest({ op: "update-status" }), hostReq]).then(function (results) {
            var r = results[0], hostR = results[1];
            if (hostR && hostR.ok && hostR.hostname) updateHostname = hostR.hostname;
            updateState = r || {};
            setUpdateBadge(!!(r && r.ok && r.update_available));
            if (!r || !r.ok) {
                body.innerHTML = '<tr><td colspan="2" class="muted">'
                    + ((r && r.error) || "Self-update is not available on this host.") + '</td></tr>';
                $("update-apply").disabled = true; $("update-rollback").disabled = true;
                $("update-confirm-wrap").hidden = true;
                $("update-note").textContent = "";
                return;
            }
            $("update-hostname").textContent = updateHostname || "";
            body.innerHTML = "";
            body.appendChild(updateRow("Current version", r.current_version || "unknown"));
            body.appendChild(updateRow("Latest known version", latestVersionText(r),
                !!r.check_error && !r.no_releases));
            if (r.release_name) body.appendChild(updateRow("Release", r.release_name));
            if (r.release_notes_url) body.appendChild(updateLinkRow("Release notes", r.release_notes_url));
            if (r.published_at) body.appendChild(updateRow("Published", r.published_at));
            body.appendChild(updateRow("Checked", fmtWhen(r.checked_at)));
            body.appendChild(updateRow("Roll back available", r.rollback_available
                ? ("yes, to " + (r.rollback_version || "an earlier version"))
                : "no earlier version on this host"));
            $("update-note").textContent = r.update_available
                ? "An update is available — type the host name below, then Update now."
                : "This host is on the latest known version.";
            var lastText = describeLastApply(r.last_apply);
            var la = $("update-last-apply");
            if (lastText) {
                la.hidden = false;
                la.textContent = lastText;
                la.className = "status" + (r.last_apply.result === "ok" ? " ok" : " err");
            } else {
                la.hidden = true;
            }
            updateSyncButtons();
        }).catch(function (e) {
            body.innerHTML = '<tr><td colspan="2" class="muted">Control API error: ' + e + '</td></tr>';
        });
    }

    function fmtWhen(ts) {
        if (!ts) return "never";
        return fmtAge(ts) + " ago";
    }

    // A read-only status poll, for the trigger points that just need the badge
    // (not the whole panel re-rendered): the initial page load. Opening the
    // Update tab itself goes through renderUpdate(), which sets the badge from
    // the SAME response it renders from rather than polling twice.
    function refreshUpdateBadge() {
        controlRequest({ op: "update-status" }).then(function (r) {
            setUpdateBadge(!!(r && r.ok && r.update_available));
        }).catch(function () { /* best effort -- leave the badge as it was */ });
    }

    function updateCheckAction() {
        var btn = $("update-check"), s = $("update-status");
        btn.disabled = true;
        s.textContent = "Checking GitHub…"; s.className = "status";
        controlRequest({ op: "update-check" }).then(function (r) {
            btn.disabled = false;
            if (r && r.ok) {
                s.textContent = r.rate_limited
                    ? "Checked less than a minute ago — showing the cached result."
                    : (r.update_available ? "An update is available." : "This host is on the latest known version.");
                s.className = "status ok";
            } else {
                s.textContent = "Check failed: " + ((r && r.error) || "unknown error");
                s.className = "status err";
            }
            renderUpdate();
        }).catch(function (e) {
            btn.disabled = false;
            s.textContent = "Check error: " + e; s.className = "status err";
            renderUpdate();
        });
    }

    function updateApplyAction() {
        var confirm = $("update-confirm") ? $("update-confirm").value : "";
        var s = $("update-status");
        s.textContent = "Updating…"; s.className = "status";
        $("update-apply").disabled = true; $("update-rollback").disabled = true;
        controlRequest({ op: "update-apply", confirm: confirm }).then(function (r) {
            if (r && r.ok) {
                s.textContent = r.detail || "Update completed.";
                s.className = "status ok";
                if ($("update-confirm")) $("update-confirm").value = "";
            } else {
                var why = (r && (r.detail || r.error)) || "refused";
                if (r && r.need_confirm) {
                    if (r.hostname) { updateHostname = r.hostname; $("update-hostname").textContent = updateHostname; }
                    why = "type the host name (" + (updateHostname || "") + ") to confirm";
                }
                s.textContent = "Update failed: " + why;
                s.className = "status err";
            }
            renderUpdate();
        }).catch(function (e) {
            s.textContent = "Update error: " + e; s.className = "status err";
            renderUpdate();
        });
    }

    function updateRollbackAction() {
        var s = $("update-status");
        s.textContent = "Rolling back…"; s.className = "status";
        $("update-apply").disabled = true; $("update-rollback").disabled = true;
        controlRequest({ op: "update-rollback" }).then(function (r) {
            if (r && r.ok) {
                s.textContent = r.detail || "Rolled back.";
                s.className = "status ok";
            } else {
                s.textContent = "Rollback failed: " + ((r && (r.detail || r.error)) || "refused");
                s.className = "status err";
            }
            renderUpdate();
        }).catch(function (e) {
            s.textContent = "Rollback error: " + e; s.className = "status err";
            renderUpdate();
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
    // Some checks read container state, which is root-owned -- specifically,
    // edy-rdp-guacd runs under ROOT's ROOTFUL podman, a separate scope from a
    // logged-in user's own rootless one (this project's own established
    // two-scope split). superuser:"try" does NOT reject for a non-admin
    // session; it silently runs the command AS THE PLAIN USER instead, so
    // "podman ps" for the guacd self-test queried the wrong scope entirely,
    // came back with empty (not missing) output, and was misread as "the
    // container is not running" -- a false FAIL, not the intended skip (found
    // live: passed in Administrative-access mode, failed in limited mode).
    // superuser:"require" actually rejects when the session is not already
    // elevated (same option this file's own admin-elevation challenge already
    // uses at cockpit.file(...) above), which is what lets the existing
    // catch handler below correctly degrade this to a skip.
    function stSpawn2(argv) { return cockpit.spawn(argv, { err: "message", superuser: "require" }); }

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
        },
        {
            name: "guacd image matches the pinned digest",
            // Live equivalent of install.sh --verify's own check 2 (same
            // INSTALL_PATH -> .env -> GUACD_IMAGE lookup, same `podman inspect
            // --format {{.ImageName}}`) -- exposed here so an operator can
            // check for drift anytime, not just at install/deploy time.
            // edy-rdp-guacd runs under ROOT's rootful podman (a separate scope
            // from a logged-in user's own rootless one -- see the guacd-build
            // check above), so this needs the same superuser:"require".
            run: function () {
                return stSpawn2(["/bin/sh", "-c",
                    'p=$(sed -n "s/^INSTALL_PATH=//p" /etc/cockpit-guac-rdp/install.conf | tr -d \'"\' | head -n1); ' +
                    'want=$(sed -n "s/^GUACD_IMAGE=//p" "$p/.env" 2>/dev/null | head -n1); ' +
                    'running=$(podman inspect edy-rdp-guacd --format "{{.ImageName}}" 2>/dev/null); ' +
                    'printf "WANT=%s\\nRUNNING=%s\\n" "$want" "$running"'
                ]).then(function (out) {
                    var want = (/^WANT=(.*)$/m.exec(out) || [])[1] || "";
                    var running = (/^RUNNING=(.*)$/m.exec(out) || [])[1] || "";
                    if (!running)
                        return { status: "skip", detail: "guacd container is not running" };
                    if (!want)
                        return { status: "fail", detail: "GUACD_IMAGE is not set in this host's .env" };
                    if (want !== running)
                        return { status: "fail", detail: "running '" + running + "', GUACD_IMAGE is '" + want +
                                 "' (systemctl restart edy-rdp-guacd.service)" };
                    return { status: "pass", detail: "running image matches GUACD_IMAGE (" + want + ")" };
                }, function (e) {
                    return { status: "skip", detail: "needs administrative access: " + e };
                });
            }
        },
        {
            name: "gnome-remote-desktop patch integrity",
            // Live equivalent of install.sh --verify's own check 3
            // (patches/README.md): the 3390 greeter handover needs a hand-
            // rebuilt daemon installed OVER the stock package path, protected
            // only by an apt hold -- an upgrade that gets through (a forced
            // reinstall, an OS version bump, the hold being lifted) silently
            // reverts it with nothing else noticing. Read-only (apt-mark
            // showhold, stat, cmp) -- no elevation needed on a normal host.
            run: function () {
                return stSpawn(["/bin/sh", "-c",
                    'if command -v apt-mark >/dev/null 2>&1; then aptmark=yes; ' +
                    'apt-mark showhold 2>/dev/null | grep -qx gnome-remote-desktop && held=yes || held=no; ' +
                    'else aptmark=no; held=n/a; fi; ' +
                    'daemon=/usr/libexec/gnome-remote-desktop-daemon; backup="$daemon.orig-edt1"; ' +
                    'if [ ! -e "$backup" ]; then state=no-backup; ' +
                    'elif cmp -s "$daemon" "$backup"; then state=stock; else state=patched; fi; ' +
                    'printf "APTMARK=%s\\nHELD=%s\\nSTATE=%s\\n" "$aptmark" "$held" "$state"'
                ]).then(function (out) {
                    var aptmark = (/^APTMARK=(.*)$/m.exec(out) || [])[1];
                    var held = (/^HELD=(.*)$/m.exec(out) || [])[1];
                    var state = (/^STATE=(.*)$/m.exec(out) || [])[1];
                    if (state === "no-backup")
                        return { status: "skip", detail: "no .orig-edt1 stock backup on this host -- " +
                                 "the handover patch was never applied here (patches/README.md)" };
                    if (state === "stock")
                        return { status: "fail", detail: "daemon is STOCK -- the 3390 greeter handover " +
                                 "will fail; re-apply patches/grd-handover-method-call.patch (see patches/README.md)" };
                    if (aptmark === "yes" && held !== "yes")
                        return { status: "fail", detail: "daemon is patched but gnome-remote-desktop is " +
                                 "NOT apt-mark held -- the next upgrade will silently revert it" };
                    return { status: "pass", detail: "daemon is patched" +
                             (aptmark === "yes" ? " and apt-mark held" : "") };
                }, function (e) {
                    return { status: "skip", detail: String(e) };
                });
            }
        },
        {
            name: "No anonymous PulseAudio TCP (4713)",
            // KNOWN_ISSUES I44: a stale ~/.config/pipewire/pipewire-pulse.conf.d
            // drop-in can leave an anonymous-auth TCP listener up although the
            // TCP approach was removed (CHANGELOG 1.2.9). Same ss-based pattern
            // as the guacd-loopback check above, inverted: here the only
            // correct state is nothing listening at all.
            run: function () {
                return stSpawn(["ss", "-tln"]).then(function (out) {
                    var lines = out.split("\n").filter(function (l) { return /:4713(\s|$)/.test(l); });
                    if (!lines.length)
                        return { status: "pass", detail: "nothing listening on 4713" };
                    return { status: "fail", detail: "PulseAudio TCP is exposed on 4713 (KNOWN_ISSUES I44): " +
                             lines[0].trim() };
                }, function (e) {
                    return { status: "skip", detail: "ss unavailable: " + e };
                });
            }
        },
        {
            name: "Vendored client library ownership matches served tree",
            // KNOWN_ISSUES / DEFENSE-LAYER D-13: guacamole-common-js/all.min.js
            // has been found owned differently from the rest of this plugin's
            // served files -- a provenance anomaly (an ad hoc placement outside
            // the normal install pipeline), not a content check. Compares
            // against manifest.json, shipped by the same install.sh PAGE
            // manifest entry, as the reference.
            run: function () {
                var dir = "/usr/share/cockpit/guac-rdp";
                return stSpawn(["/bin/sh", "-c",
                    'printf "LIB=%s\\nREF=%s\\n" ' +
                    '"$(stat -c %U:%G \'' + dir + '/guacamole-common-js/all.min.js\' 2>/dev/null)" ' +
                    '"$(stat -c %U:%G \'' + dir + '/manifest.json\' 2>/dev/null)"'
                ]).then(function (out) {
                    var lib = (/^LIB=(.*)$/m.exec(out) || [])[1] || "";
                    var ref = (/^REF=(.*)$/m.exec(out) || [])[1] || "";
                    if (!lib || !ref)
                        return { status: "skip", detail: "could not stat the served plugin files" };
                    if (lib !== ref)
                        return { status: "fail", detail: "guacamole-common-js/all.min.js is owned " + lib +
                                 ", the rest of the served tree is " + ref };
                    return { status: "pass", detail: "owned " + lib + ", matching the served tree" };
                }, function (e) {
                    return { status: "skip", detail: String(e) };
                });
            }
        },
        {
            name: "cockpit-guac-rdp group exists with expected membership",
            run: function () {
                return stSpawn(["/bin/sh", "-c",
                    'getent group cockpit-guac-rdp >/dev/null 2>&1 && exists=yes || exists=no; ' +
                    'printf "EXISTS=%s\\nGROUPS=%s\\n" "$exists" "$(id -nG edy-relay 2>/dev/null)"'
                ]).then(function (out) {
                    var exists = (/^EXISTS=(.*)$/m.exec(out) || [])[1];
                    var groups = (/^GROUPS=(.*)$/m.exec(out) || [])[1] || "";
                    if (exists !== "yes")
                        return { status: "fail", detail: "the cockpit-guac-rdp group does not exist" };
                    if ((" " + groups + " ").indexOf(" cockpit-guac-rdp ") === -1)
                        return { status: "fail", detail: "edy-relay is not a member of cockpit-guac-rdp " +
                                 "(has: " + (groups || "no groups -- user missing?") + ")" };
                    return { status: "pass", detail: "group exists; edy-relay is a member" };
                }, function (e) {
                    return { status: "skip", detail: String(e) };
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

    // Tab names as they appear in the URL hash (?tab=connect etc.) -- the main
    // page only; pop-outs never show tabs at all (html.monitor .tabs is
    // display:none), so this never runs there.
    var TAB_NAMES = ["connect", "sessions", "deskui", "update", "selftests"];
    function selectTab(id) {
        var name = id.replace(/^tab-/, "");
        TAB_NAMES.forEach(function (n) {
            var t = $("tab-" + n), pan = $("panel-" + n);
            if (!t || !pan) return;
            var on = n === name;
            t.classList.toggle("active", on); pan.hidden = !on;
        });
        if (id === "tab-sessions") renderSessions();
        if (id === "tab-deskui") renderDeskUi();
        if (id === "tab-update") renderUpdate();
        // Reflect the active tab in the URL, the same way URL_CONTROLS persists
        // Session/Resolution/etc: rewritten via writeHash() (replaceState, so no
        // navigation/history spam) so the tab survives a refresh and is
        // bookmarkable/shareable, preserving any other hash segment (mode
        // tokens, controls).
        var keep = [];
        _hashSegments().forEach(function (seg) { if (_segKey(seg) !== "tab") keep.push(seg); });
        keep.push("tab=" + name);
        writeHash("#" + keep.join("&"));
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
        { key: "audio",  id: "opt-audio",     kind: "check"  },
        { key: "trace",  id: "opt-trace",     kind: "check"  }
    ];
    var CONTROLS_LS_KEY = "edy-rdp-controls";
    // history.replaceState() changes location.hash but does NOT fire a
    // "hashchange" event -- only a real hash-navigation does (a bare
    // `location.hash = x` assignment, a same-page anchor click, back/forward).
    // Cockpit's OWN shell-sync depends entirely on that event: decompiling the
    // installed /usr/share/cockpit/base1/cockpit.js shows its `location`
    // getter/setter and a `window.addEventListener("hashchange", ...)` handler
    // that calls `cockpit.hint("location", {hash})` to tell the shell (over
    // the iframe<->parent "cockpit1" transport) what the embedded page's
    // current location is, which is what makes the shell mirror it into the
    // VISIBLE browser address bar. Without firing that event ourselves,
    // replaceState silently updates this document's own location.hash while
    // the address bar the user actually sees never moves -- exactly what was
    // reported ("the url stays on tab=connect"). replaceState is kept (a bare
    // assignment would push a new history entry per change, the "history
    // spam" the comment below used to warn against); we just also dispatch
    // the event by hand so Cockpit's listener notices.
    function writeHash(newHash) {
        try { history.replaceState(history.state, "", newHash); } catch (e) { /* ignore */ }
        try { window.dispatchEvent(new Event("hashchange")); } catch (e) { /* ignore */ }
    }
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
    // Persist controls on change: rewrite the hash (preserving any mode token)
    // via writeHash() -- no reload, no history spam, but the Cockpit shell
    // DOES see it (see writeHash's comment) -- and snapshot to localStorage.
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
        writeHash("#" + keep.join("&"));
        try { localStorage.setItem(CONTROLS_LS_KEY, JSON.stringify(vals)); } catch (e) { /* ignore */ }
    }

    document.addEventListener("DOMContentLoaded", function () {
        $("tab-connect").addEventListener("click", function () { selectTab("tab-connect"); });
        $("tab-sessions").addEventListener("click", function () { selectTab("tab-sessions"); });
        $("tab-deskui").addEventListener("click", function () { selectTab("tab-deskui"); });
        $("tab-update").addEventListener("click", function () { selectTab("tab-update"); });
        $("tab-selftests").addEventListener("click", function () { selectTab("tab-selftests"); });
        $("run-tests").addEventListener("click", runSelfTests);
        $("refresh").addEventListener("click", renderSessions);
        // Desktop UI panel
        $("deskui-refresh").addEventListener("click", renderDeskUi);
        $("deskui-confirm").addEventListener("input", deskuiSyncButtons);
        $("deskui-enable").addEventListener("click", function () { deskuiAction("enable"); });
        $("deskui-start").addEventListener("click", function () { deskuiAction("start"); });
        $("deskui-disable").addEventListener("click", function () { deskuiAction("disable"); });
        $("deskui-stop").addEventListener("click", function () { deskuiAction("stop"); });
        // Update panel
        $("update-check").addEventListener("click", updateCheckAction);
        $("update-confirm").addEventListener("input", updateSyncButtons);
        $("update-apply").addEventListener("click", updateApplyAction);
        $("update-rollback").addEventListener("click", updateRollbackAction);
        var perm = cockpit.permission({ admin: true });
        perm.addEventListener("changed", function () { isAdmin = !!perm.allowed; refreshUi(); updateSyncButtons(); });
        isAdmin = !!perm.allowed;
        loadControls();   // restore persisted toggles/selectors BEFORE any auto-connect
        $("target").addEventListener("change", refreshUi);
        $("authmode").addEventListener("change", refreshUi);
        $("go").addEventListener("click", function () { connect(); });
        $("numlock").addEventListener("click", function () { toggleSessionLock("NumLock"); });
        // Sound / Clipboard passthrough toggles gate LIVE, during a session.
        $("opt-clipboard").addEventListener("change", function () {
            clipboardOn = $("opt-clipboard").checked;
            trace("clipboard", "toggle -> " + (clipboardOn ? "on" : "off"));
            if (client) setStatus(clipboardOn ? "Clipboard passthrough on." : "Clipboard passthrough off.");
        });
        $("opt-audio").addEventListener("change", function () {
            soundOn = $("opt-audio").checked;
            trace("sound", "toggle -> " + (soundOn ? "on" : "off"));
            applySoundGate();
            // enable-audio is negotiated at connect, so toggling Sound live
            // reconnects the same scenario to add/drop the audio channel.
            if (client && activeKey) {
                setStatus(soundOn ? "Enabling sound…" : "Muting sound…");
                trace("sound", "toggle reconnect: dropping and re-establishing " + activeKey + " to renegotiate enable-audio");
                teardown(true);
                window.setTimeout(function () { connect(activeKey); }, 80);
            }
        });
        if ($("opt-trace")) {
            $("opt-trace").addEventListener("change", function () {
                traceOn = $("opt-trace").checked;
                // The one line that always prints regardless of the flag it is
                // about to flip, so turning tracing ON confirms it took effect and
                // turning it OFF leaves a clear "logging stops here" marker.
                (console.debug || console.log).call(console, "[guac-rdp:trace] " + (traceOn ? "enabled" : "disabled"));
            });
        }
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
        else enterConnectMode();
    });
})();
