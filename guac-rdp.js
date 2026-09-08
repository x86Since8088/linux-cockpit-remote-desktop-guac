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
        remote:   { port: "3389", mode: null, remote: true,
            note: "RDP into another host on the network. Enter its address and your RDP credentials for that host." }
    };
    var CONTROL = "/run/edy-rdp/control.sock";
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
    function setStatus(msg, kind) { var e = $("status"); e.textContent = msg; e.className = "status" + (kind ? " " + kind : ""); }
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

    var disposing = false;

    // Graceful: send the Guacamole "disconnect" to the backend (relay -> guacd ->
    // grd) and let it tear the RDP session down, THEN dispose the browser side.
    // immediate=true skips the wait (used when the backend already closed / errored).
    function teardown(immediate) {
        if (disposing) return;
        disposing = true;
        if (keyboard) { keyboard.onkeydown = keyboard.onkeyup = null; keyboard = null; }

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

    function connect() {
        var key = $("target").value, t = TARGETS[key];
        $("go").disabled = true;
        // Remote is admin-gated only if the server sets EDY_RDP_REMOTE_ADMIN_ONLY;
        // prove admin when the Cockpit session is already elevated (no polkit prompt
        // for non-admins), otherwise register a plain token and let the relay decide.
        var needAdmin = !!t.admin || (key === "remote" && isAdmin);
        setStatus(needAdmin ? "Proving administrator mode…" : "Registering session…");
        registerSession(needAdmin).then(function (reg) {
            if (t.admin && !reg.admin) {
                setStatus("Console needs administrative access — turn on Administrative access "
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
                .then(function (cred) { start(key, cred, reg.token); })
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

    function start(key, cred, sessiontoken) {
        var t = TARGETS[key], box = $("display");
        var w = Math.max(box.clientWidth, 640), h = Math.max(box.clientHeight, 480);
        // The relay injects the VNC target (the per-connection FreeRDP3 bridge); the
        // browser sends no target values. For non-managed scenarios the fetched/entered
        // RDP gate credential travels as rdpcred (0x1f separates user/pass), which the
        // relay strips for the bridge — guacd only ever sees a loopback VNC target.
        var rdpcred = t.managed ? null
            : ((cred.username || "") + "" + (cred.password || ""));
        var remotehost = (key === "remote")
            ? ($("host").value.trim() + ":" + (($("port").value || "").toString().trim() || "3389"))
            : null;
        tunnel = new CockpitRelayTunnel({
            width: w, height: h, dpi: 96, scenario: key,
            rdpcred: rdpcred,
            remotehost: remotehost,               // "ip:port" for the remote scenario (relay-validated)
            sessiontoken: sessiontoken || null,   // end-to-end correlation + gate token
            values: {}
        });
        client = new Guacamole.Client(tunnel);
        var display = client.getDisplay();
        box.innerHTML = ""; box.appendChild(display.getElement());

        var errored = false;
        function explain(prefix, e) {
            errored = true;
            var msg = (e && e.message) || "unknown error";
            if (/auth|credential|logon/i.test(msg))
                msg += "  — this is the RDP gate key for port " + t.port + ", not your own login.";
            if (/not permitted|admin/i.test(msg) && key === "console")
                msg += "  Console (mirror) requires administrative access.";
            setStatus(prefix + ": " + msg, "err"); teardown(true);
        }
        tunnel.onerror = function (e) { explain("Relay error", e); };
        client.onerror = function (e) { explain("RDP error", e); };
        tunnel.onstatechange = function (s) {
            if (s === Guacamole.Tunnel.State.OPEN) setStatus("Relay accepted the connection, negotiating RDP…");
        };
        client.onstatechange = function (s) {
            if (s === 3) { currentUuid = (tunnel && tunnel.uuid ? String(tunnel.uuid) : "").replace(/^\$/, ""); }
            if (s === 3) setStatus(
                key === "isolated" ? "Connected to your isolated desktop."
                : key === "console" ? "Connected to the physical console."
                : key === "remote"  ? ("Connected to " + $("host").value.trim() + ".")
                : "Connected to your virtual monitor.", "ok");
            else if (s === 5) { if (!errored) setStatus("Disconnected."); teardown(true); }
        };

        setStatus("Opening a channel to the relay…");
        client.connect();

        var mouse = new Guacamole.Mouse(display.getElement());
        if (typeof mouse.onEach === "function")
            mouse.onEach(["mousedown", "mouseup", "mousemove"], function (e) { if (client) client.sendMouseState(e.state); });
        else
            mouse.onmousedown = mouse.onmouseup = mouse.onmousemove = function (st) { if (client) client.sendMouseState(st); };
        keyboard = new Guacamole.Keyboard(document);
        keyboard.onkeydown = function (k) { if (client) client.sendKeyEvent(1, k); };
        keyboard.onkeyup = function (k) { if (client) client.sendKeyEvent(0, k); };
        $("stop").disabled = false;
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
        $("credwrap").hidden = remote ? false : (managed || !manual);
        $("passwrap").hidden = remote ? false : (managed || !manual);
        var extra = managed ? "  You reach your own session; no credentials needed."
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
                tr.appendChild(td(sn.scenario || ""));
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
    var ST_BINS = ["xfreerdp3", "Xvfb", "x11vnc"];
    var ST_ASSETS = ["guac-rdp.css", "guac-proto.js", "guac-rdp.js",
                     "guacamole-common-js/all.min.js"];

    function stSpawn(argv) { return cockpit.spawn(argv, { err: "message" }); }

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
            name: "Session tooling present",
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

    document.addEventListener("DOMContentLoaded", function () {
        $("tab-connect").addEventListener("click", function () { selectTab("tab-connect"); });
        $("tab-sessions").addEventListener("click", function () { selectTab("tab-sessions"); });
        $("tab-selftests").addEventListener("click", function () { selectTab("tab-selftests"); });
        $("run-tests").addEventListener("click", runSelfTests);
        $("refresh").addEventListener("click", renderSessions);
        var perm = cockpit.permission({ admin: true });
        perm.addEventListener("changed", function () { isAdmin = !!perm.allowed; refreshUi(); });
        isAdmin = !!perm.allowed;
        $("target").addEventListener("change", refreshUi);
        $("authmode").addEventListener("change", refreshUi);
        $("go").addEventListener("click", connect);
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
        refreshUi();
        setStatus("Idle. Choose a session and connect.");
    });
})();
