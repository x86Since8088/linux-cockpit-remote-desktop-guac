/* Guacamole wire-protocol codec. Shared by the Cockpit plugin (browser global)
 * and by the offline test harness (CommonJS), so what ships is what is tested.
 * Instruction form: LENGTH.VALUE,LENGTH.VALUE;  where LENGTH counts Unicode CODEPOINTS.
 */
(function (root, factory) {
    var api = factory();
    if (typeof module === "object" && module.exports) module.exports = api;
    else root.GuacProto = api;
})(typeof self !== "undefined" ? self : this, function () {
    "use strict";

    function cpLen(s) {
        var n = 0;
        for (var i = 0; i < s.length; i++) {
            n++;
            var c = s.charCodeAt(i);
            if (c >= 0xD800 && c <= 0xDBFF) i++;
        }
        return n;
    }

    function enc() {
        var out = [];
        for (var i = 0; i < arguments.length; i++) {
            var v = arguments[i];
            v = (v === undefined || v === null) ? "" : String(v);
            out.push(cpLen(v) + "." + v);
        }
        return out.join(",") + ";";
    }

    function advance(s, start, cps) {
        var i = start;
        while (cps > 0 && i < s.length) {
            var c = s.charCodeAt(i);
            i += (c >= 0xD800 && c <= 0xDBFF) ? 2 : 1;
            cps--;
        }
        return cps > 0 ? -1 : i;
    }

    function parseOne(buf, p) {
        var elems = [], i = p;
        for (;;) {
            var dot = buf.indexOf(".", i);
            if (dot < 0) return null;
            var len = parseInt(buf.substring(i, dot), 10);
            if (isNaN(len)) return null;
            var vs = dot + 1, ve = advance(buf, vs, len);
            if (ve < 0 || ve > buf.length) return null;
            elems.push(buf.substring(vs, ve));
            var sep = buf.charAt(ve);
            if (sep === ",") { i = ve + 1; continue; }
            if (sep === ";") return { elems: elems, next: ve + 1 };
            return null;
        }
    }

    function drain(buf, cb) {
        var p = 0, r;
        while ((r = parseOne(buf, p)) !== null) { cb(r.elems); p = r.next; }
        return buf.substring(p);
    }

    return { cpLen: cpLen, enc: enc, advance: advance, parseOne: parseOne, drain: drain };
});
