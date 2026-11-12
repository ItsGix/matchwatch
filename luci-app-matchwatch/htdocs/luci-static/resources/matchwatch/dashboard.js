// matchwatch dashboard. One copy serves two homes: the LuCI page (Services > MatchWatch)
// and the optional page that needs no login. Each home supplies T, how to talk to the router:
//   T.css       address of dashboard.css
//   T.get(file) promise of one parsed JSON data file (status.json, matches/<id>.json, ...)
//   T.act(p)    promise of {ok, out} for a button: p = {action, arg, region, name}
//   T.readonly  true = view only: buttons that change things are left out
//   T.dark()    optional: true when the surrounding page is dark (default: the device's setting)
//   T.settings  optional: address of the settings page
// It draws inside a shadow root, so its styling and the host page's cannot disturb each other.
window.MatchwatchDashboard = function (host, T) {
"use strict";
var shadow = host.attachShadow({ mode: "open" });
var sheet = document.createElement("link"); sheet.rel = "stylesheet"; sheet.href = T.css;
var wrap = document.createElement("div"); wrap.className = "mw" + (T.full ? " full" : " framed");
wrap.innerHTML = '<header class="top"><a class="brand" href="#/">matchwatch</a><nav aria-label="Pages">' +
	'<a href="#/" data-p="live">Live</a><a href="#/match/last" data-p="match">Last match</a><a href="#/matches" data-p="matches">Matches</a>' +
	'<a href="#/servers" data-p="servers">Servers</a><a href="#/tools" data-p="tools">Tools</a></nav>' +
	'<span id="state">Connecting to the router</span></header><main id="view"></main><div id="toast" role="status" aria-live="polite"></div>';
shadow.appendChild(sheet); shadow.appendChild(wrap);
var RO = !!T.readonly;
function setDark() { wrap.classList.toggle("dark", T.dark ? !!T.dark() : !!(window.matchMedia && matchMedia("(prefers-color-scheme: dark)").matches)); }
setDark(); sheet.addEventListener("load", function () { setDark(); updateLive(); });
var D = { st: null, hist: [], servers: [], dcs: [], blocks: [], info: {}, lobby: null, regions: [], favs: [], favInfo: {} };
var page = "", pageArg = "", armed = 0, view = shadow.getElementById("view");

// ---------- small helpers
function h(tag, props) {
	var e = document.createElement(tag), i, c;
	if (typeof props === "string") e.textContent = props;
	else if (props) for (i in props) { if (i === "text") e.textContent = props[i]; else if (i === "cls") e.className = props[i]; else e.setAttribute(i, props[i]); }
	for (i = 2; i < arguments.length; i++) { c = arguments[i]; if (c == null) continue; e.appendChild(typeof c === "string" ? document.createTextNode(c) : c); }
	return e;
}
function cls(s) { return s == null ? "na" : s >= 70 ? "ok" : s >= 50 ? "mid" : "low"; }
function grade(s) { return s == null ? "Not measured" : s >= 85 ? "Excellent" : s >= 70 ? "Good" : s >= 50 ? "Fair" : "Poor"; }
function fmt(x, d) { return x == null ? "n/a" : Number(x).toFixed(d == null ? 1 : d); }
function place(o) { var a = []; if (o.city && o.city !== "-") a.push(o.city); if (o.cc && o.cc !== "-") a.push(o.cc); return a.join(", "); }
function when(t) { var d = new Date(t * 1000); return d.toLocaleDateString(undefined, { day: "numeric", month: "short" }) + ", " + d.toLocaleTimeString(undefined, { hour: "2-digit", minute: "2-digit" }); }
function mins(s) { s = Math.round(s); var m = Math.floor(s / 60); return m + "m " + (s - m * 60) + "s"; }
function css(v) { return getComputedStyle(wrap).getPropertyValue(v).trim(); }
function get(file, cb) { T.get(file).then(cb, function () { cb(null); }); }
var FINDING = { clean: "Clean", server: "Server", route: "Route", line: "Your line", pc: "Your PC", server_or_route: "Server or route", ok_ping_rough: "Clean", short: "Too short to judge" };

var toastT;
function toast(msg, err) { var t = shadow.getElementById("toast"); t.textContent = msg; t.className = err ? "err" : ""; t.style.display = "block"; clearTimeout(toastT); toastT = setTimeout(function () { t.style.display = "none"; }, err ? 9000 : 6000); }

// ---------- talking to the router
function api(action, arg, extra) {
	var p = { action: action }, m = /region=([^&]*)/.exec(extra || "");
	if (arg != null) p.arg = String(arg);
	if (m) p.region = m[1].replace(/\+/g, " ");
	return T.act(p).then(function (j) { return j || {}; }, function () { return { ok: false, error: "Could not reach the router." }; });
}
// A button that runs a command. opts: confirm (label for the second press), danger, solid, done(text)
function act(label, action, arg, opts) {
	opts = opts || {};
	if (RO) return document.createElement("span");
	var b = h("button", { type: "button", text: label, cls: (opts.danger ? "danger" : "") + (opts.solid ? " solid" : "") + (opts.big ? " big" : "") });
	var t;
	b.addEventListener("click", function (ev) {
		ev.stopPropagation();
		if (opts.confirm && !b.classList.contains("arm")) {
			b.classList.add("arm"); b.textContent = opts.confirm; armed++;
			t = setTimeout(function () { b.classList.remove("arm"); b.textContent = label; armed--; }, 4500);
			return;
		}
		if (opts.confirm) { clearTimeout(t); armed--; }
		b.disabled = true; b.textContent = "Working...";
		api(action, arg, opts.extra).then(function (j) {
			b.disabled = false; b.classList.remove("arm"); b.textContent = label;
			if (!j.ok) { toast(j.out || j.error || "That did not work.", true); return; }
			if (opts.done) opts.done(j.out || ""); else toast(j.out || "Done.");
			refresh(true);
		});
	});
	return b;
}

// ---------- chart: ping line on top; below, how far each second strayed from the normal beat
function median(a) { var b = a.filter(function (x) { return x > 0; }).sort(function (x, y) { return x - y; }); return b.length ? b[Math.floor(b.length / 2)] : 0; }
function bucket(a, size, miss) {
	if (size <= 1) return a.slice();
	var out = [], i, j, m;
	for (i = 0; i < a.length; i += size) { m = miss; for (j = i; j < Math.min(a.length, i + size); j++) if (a[j] > m) m = a[j]; out.push(m); }
	return out;
}
// c: { d, u, p, dn, un, slots (fixed width in seconds, or 0 = fit all), marks: [seconds from left], minutes: bool }
function drawChart(cv, c) {
	var cx = cv.getContext("2d"), dpr = window.devicePixelRatio || 1, w = cv.clientWidth, hh = cv.clientHeight;
	if (cv.width !== Math.round(w * dpr)) { cv.width = Math.round(w * dpr); cv.height = Math.round(hh * dpr); }
	cx.setTransform(dpr, 0, 0, dpr, 0, 0); cx.clearRect(0, 0, w, hh);
	var grid = css("--grid"), muted = css("--muted"), ink = css("--ink"), bad = css("--bad"), pen = css("--pen"), pen2 = css("--pen2");
	var pTop = 18, pBot = hh * 0.42, base = hh * 0.72, band = hh - base - (c && c.minutes ? 20 : 6);
	cx.font = "11px system-ui, sans-serif"; cx.lineWidth = 1;
	var pings = c ? (c.p || []).filter(function (x) { return x >= 0; }) : [];
	var pmax = Math.max(10, Math.ceil(Math.max.apply(null, pings.concat([0])) * 1.4 / 5) * 5);
	[0, pmax / 2, pmax].forEach(function (v) {
		var y = pBot - (v / pmax) * (pBot - pTop);
		cx.strokeStyle = v === 0 ? ink : grid; cx.beginPath(); cx.moveTo(0, y + 0.5); cx.lineTo(w, y + 0.5); cx.stroke();
		cx.fillStyle = muted; cx.fillText("ping " + v + " ms", 6, y - 3);
	});
	function ls(ms) { return Math.sqrt(Math.min(Math.max(ms, 0), 200) / 200) * band; }
	[10, 50, 150].forEach(function (ms) {
		cx.strokeStyle = grid;
		[base - ls(ms), base + ls(ms)].forEach(function (y) { cx.beginPath(); cx.moveTo(0, y + 0.5); cx.lineTo(w, y + 0.5); cx.stroke(); });
		cx.fillStyle = muted; cx.fillText("+" + ms + " ms late", 6, base - ls(ms) - 3);
	});
	cx.strokeStyle = ink; cx.beginPath(); cx.moveTo(0, base + 0.5); cx.lineTo(w, base + 0.5); cx.stroke();
	if (!c || !c.d) return;
	var total = c.slots || c.d.length || 1, size = Math.max(1, Math.ceil(total / (w / 3)));
	var d = bucket(c.d, size, 0), u = bucket(c.u || [], size, 0), p = bucket(c.p || [], size, -1);
	var n = Math.ceil(total / size), bw = w / n, off = c.slots ? n - d.length : 0, i, x;
	var dn = c.dn || median(c.d), un = c.un || median(c.u || []);
	for (i = 0; i < d.length; i++) {
		x = (off + i) * bw;
		var late = d[i] - dn, pause = (u[i] || 0) - un, gap = bw > 4 ? 1 : 0;
		// Server and PC both silent for the whole second: the game stopped (match over, loading, alt-tab).
		// A real server freeze looks different, because your PC keeps sending through it.
		if (d[i] >= 1000 && (u[i] || 0) >= 1000) { cx.fillStyle = muted; cx.fillRect(x + gap, base - 2, Math.max(1, bw - 2 * gap), 5); continue; }
		cx.fillStyle = late > Math.max(30, dn) ? bad : pen;
		cx.fillRect(x + gap, base - Math.max(1, ls(late)), Math.max(1, bw - 2 * gap), Math.max(1, ls(late)));
		cx.fillStyle = pause > 100 ? bad : pen2;
		cx.fillRect(x + gap, base + 1, Math.max(1, bw - 2 * gap), Math.max(1, ls(pause)));
	}
	(c.marks || []).forEach(function (sec) {
		if (sec < 0 || sec >= total) return;
		var mx = (sec / size + 0.5) * bw;
		cx.fillStyle = ink; cx.beginPath(); cx.moveTo(mx - 6, pBot + 4); cx.lineTo(mx + 6, pBot + 4); cx.lineTo(mx, pBot + 14); cx.closePath(); cx.fill();
	});
	cx.strokeStyle = ink; cx.lineWidth = 2; cx.beginPath();
	var po = c.slots ? n - p.length : 0, on = false;
	for (i = 0; i < p.length; i++) {
		if (p[i] < 0) { on = false; continue; }
		var px = (po + i + 0.5) * bw, py = pBot - (Math.min(p[i], pmax) / pmax) * (pBot - pTop);
		if (on) cx.lineTo(px, py); else cx.moveTo(px, py);
		on = true;
	}
	cx.stroke(); cx.lineWidth = 1;
	if (c.minutes) {
		cx.fillStyle = muted;
		var step = total > 1500 ? 300 : total > 600 ? 120 : 60;
		for (i = step; i < total; i += step) cx.fillText(Math.round(i / 60) + " min", (i / size) * bw - 14, hh - 5);
	}
}
function legend() {
	var l = h("div", { cls: "legend" });
	[["--ink", "Ping to the server"], ["--pen", "Server: how late its slowest update was, each second"], ["--pen2", "Your PC: its longest pause, each second"], ["--bad", "Stutter or pause you would feel"], ["--muted", "No game traffic either way"]].forEach(function (p) {
		var s = h("span"), i = h("i"); i.style.background = "var(" + p[0] + ")"; s.appendChild(i); s.appendChild(document.createTextNode(p[1])); l.appendChild(s);
	});
	return l;
}
function fig(label, value, unit) { return h("div", null, h("dt", label), h("dd", null, value, unit ? h("small", unit) : null)); }
function table(heads) {
	var tr = h("tr"); heads.forEach(function (x) { tr.appendChild(h("th", { text: x[0], cls: x[1] || "" })); });
	return h("table", null, h("thead", null, tr), h("tbody"));
}
function row(cells) { var tr = h("tr"); cells.forEach(function (c) { tr.appendChild(c instanceof Node ? c : h("td", { text: c[0], cls: c[1] || "" })); }); return tr; }
function marksList(marks) {
	var ul = h("ul", { cls: "marks" });
	(marks || []).slice().reverse().forEach(function (m) {
		ul.appendChild(h("li", null, h("time", new Date(m.t * 1000).toLocaleTimeString()), m.x.charAt(0).toUpperCase() + m.x.slice(1) + "."));
	});
	return ul;
}
function session() {
	var st = D.st, s = st && st.sessions && st.sessions[0], i;
	for (i = 1; st && st.sessions && i < st.sessions.length; i++) if ((st.sessions[i].tick || 0) > (s.tick || 0)) s = st.sessions[i];
	return s || null;
}
function isBlocked(ip) { var s = D.servers.filter(function (x) { return x.ip === ip; })[0]; return !!(s && s.blocked) || D.blocks.some(function (b) { return b.ip === ip; }); }

// ---------- naming games. An unnamed game is rated but left alone by stay mode, the lobby alert and auto-block.
function unnamedPorts() {
	var seen = [], m;
	D.hist.forEach(function (x) { m = /^Game on port (\d+)$/.exec(x.game || ""); if (m && seen.indexOf(m[1]) < 0) seen.push(m[1]); });
	return seen;
}
// a name box and a button for one server port; label is the button's text
function nameForm(port, label, after) {
	var inp = h("input", { type: "text", cls: "keep", maxlength: "40", placeholder: "Name of the game", autocomplete: "off", "aria-label": "Name for the game on server port " + port });
	var btn = h("button", { type: "button", cls: "solid", text: label });
	var go = function () {
		var v = inp.value.replace(/[^A-Za-z0-9 .:-]/g, "").trim();
		if (!v) { inp.focus(); return; }
		btn.disabled = true;
		T.act({ action: "gamename", arg: String(port), name: v }).then(function (j) { return j || {}; }, function () { return { ok: false }; }).then(function (j) {
			btn.disabled = false; toast(j.out || "That did not work.", !j.ok);
			if (j.ok) { inp.value = ""; refresh(true); if (after) after(v); }
		});
	};
	btn.addEventListener("click", go);
	inp.addEventListener("keydown", function (e) { if (e.key === "Enter") go(); });
	return h("div", { cls: "stayform" }, inp, btn);
}
// shown on Live and Matches until every game on file has a name
// notices you have closed stay closed in this browser; the game can still be named on the Tools page
function hiddenPorts() { try { return JSON.parse(localStorage.getItem("mw-hide-ports") || "[]"); } catch (e) { return []; } }
function hidePort(port) { var a = hiddenPorts(); if (a.indexOf(port) < 0) a.push(port); try { localStorage.setItem("mw-hide-ports", JSON.stringify(a.slice(-50))); } catch (e) {} }
function namePrompt(redraw) {
	if (RO) return null;
	var gone = hiddenPorts(), ps = unnamedPorts().filter(function (p) { return gone.indexOf(p) < 0; });
	if (!ps.length) return null;
	var box = h("div");
	ps.forEach(function (port) {
		var not = h("button", { type: "button", text: "Not a game" }), x = h("button", { type: "button", cls: "close", title: "Hide this notice", "aria-label": "Hide the notice about server port " + port, text: "\u00d7" });
		var bn = h("div", { cls: "banner far" }, h("p", null, h("b", "New game on server port " + port + ". "), "Give it a name so that staying on places, the lobby alert and automatic blocking cover it. If it was a call or something else, choose Not a game and MatchWatch stops recording it."),
			nameForm(port, "Save name", function () { setTimeout(redraw, 1500); }), not, x);
		not.addEventListener("click", function () {
			not.disabled = true;
			T.act({ action: "gamename", arg: String(port), name: "Not a game", days: "1" }).then(function (j) { return j || {}; }, function () { return { ok: false }; }).then(function (j) {
				not.disabled = false; toast(j.out || "That did not work.", !j.ok);
				if (j.ok) { bn.remove(); refresh(true); }
			});
		});
		x.addEventListener("click", function () { hidePort(port); bn.remove(); });
		box.appendChild(bn);
	});
	return box;
}

// ---------- favourites: servers you want to find again, grouped by the game played on them
function setFavs(x) { D.favs = []; D.favInfo = {}; (x || []).forEach(function (o) { if (typeof o === "string") o = { ip: o }; D.favs.push(o.ip); D.favInfo[o.ip] = o; }); }
function isFav(ip) { return D.favs.indexOf(ip) >= 0; }
function gameOf(ip) { var m = D.hist.filter(function (x) { return x.ip === ip; })[0], f = D.favInfo[ip]; return (m && m.game) || (f && f.game) || "Other games"; }
// a star that adds or removes one server. wordy: a full button with its label, for pages about one server
function star(ip, wordy) {
	var on = isFav(ip);
	if (RO) return on ? h("span", { cls: "star on", title: "One of your favourites", text: "★" }) : document.createElement("span");
	var say = on ? "Remove from favourites" : "Add to favourites";
	var b = h("button", { type: "button", cls: wordy ? "" : "star" + (on ? " on" : ""), "aria-pressed": on ? "true" : "false", title: say, "aria-label": say + ": " + ip, text: (on ? "★" : "☆") + (wordy ? (on ? " Favourite" : " Add to favourites") : "") });
	b.addEventListener("click", function (e) {
		e.stopPropagation(); b.disabled = true;
		api(on ? "unfav" : "fav", ip).then(function (j) {
			b.disabled = false;
			if (!j.ok) { toast(j.out || j.error || "That did not work.", true); return; }
			if (on) D.favs = D.favs.filter(function (x) { return x !== ip; }); else { D.favs.push(ip); D.favInfo[ip] = D.favInfo[ip] || { ip: ip }; }
			toast(j.out || "Done.");
			var y = window.scrollY;
			if (page === "servers") { pageServers(); window.scrollTo(0, y); } else if (page === "live") { L.ip = null; updateLive(); } else if (page === "match") { route(true); }
		});
	});
	return b;
}
function favSection() {
	var box = h("div"), days = D.info.block_days || 14, groups = {}, order = [];
	box.appendChild(h("h2", "Favourites"));
	if (!D.favs.length) { box.appendChild(h("p", { cls: "empty", text: "No favourites yet. Press the star beside a server below to keep it here, grouped by game. A favourite is never blocked automatically." })); return box; }
	D.favs.forEach(function (ip) { var g = gameOf(ip); if (!groups[g]) { groups[g] = []; order.push(g); } groups[g].push(ip); });
	order.sort().forEach(function (g) {
		box.appendChild(h("h3", { cls: "favgame" }, g, h("small", groups[g].length + " server" + (groups[g].length === 1 ? "" : "s"))));
		var t = table([["Server"], ["Where"], ["Host"], ["Matches", "num"], ["Rating", "num"], ["Ping ms", "num"], ["Last played"], ["", ""]]);
		groups[g].map(function (ip) { return D.servers.filter(function (x) { return x.ip === ip; })[0] || D.favInfo[ip] || { ip: ip }; })
			.sort(function (a, b) { return (b.rating == null ? -1 : b.rating) - (a.rating == null ? -1 : a.rating); })
			.forEach(function (s) {
				var td = h("td", { cls: "act" });
				td.appendChild(star(s.ip));
				if (s.blocked || isBlocked(s.ip)) td.appendChild(h("span", { cls: "tag", text: "Blocked" }));
				t.lastChild.appendChild(row([[s.ip], [place(s)], [s.org && s.org !== "-" ? s.org : ""], [s.matches == null ? "" : String(s.matches), "num"], [s.rating == null ? "" : String(s.rating), "num s " + cls(s.rating)],
					[s.ping == null ? "" : fmt(s.ping, 1), "num"], [s.last ? when(s.last) : "Not played on yet"], td]));
			});
		box.appendChild(h("div", { cls: "tablewrap" }, t));
	});
	box.appendChild(h("p", { cls: "note", text: "Best rated first within each game. A favourite is never blocked automatically, and the lobby alert tells you when you land on one. The game still decides which server you get: a favourite cannot be requested." }));
	return box;
}

// ---------- Live
var L = {};
function pageLive() {
	view.textContent = "";
	L.banner = h("div"); L.title = h("h1", "No match in progress"); L.sub = h("p", { cls: "sub" });
	L.cv = h("canvas", { role: "img", "aria-label": "Ping to the server and timing of updates over the last two minutes" });
	L.figs = h("dl", { cls: "figs" });
	L.felt = h("button", { type: "button", cls: "solid big", text: "I felt that" });
	L.note = h("p", { cls: "note", text: "Press when something feels off, or tap the M key. A few seconds later this shows what the server, your ping and your PC were doing." });
	L.marks = h("div"); L.actions = h("div", { cls: "actions" }); L.last = h("div");
	L.felt.addEventListener("click", felt);
	var np = namePrompt(function () { if (page === "live") pageLive(); });
	if (np) view.appendChild(np);
	view.appendChild(L.banner); view.appendChild(L.title); view.appendChild(L.sub);
	view.appendChild(h("div", { cls: "strip" }, L.cv, legend()));
	view.appendChild(L.figs);
	view.appendChild(h("div", { cls: "actions" }, L.felt)); view.appendChild(L.note); view.appendChild(L.marks); view.appendChild(L.actions); view.appendChild(L.last);
	L.ip = null; updateLive();
}
function felt() {
	if (!session()) return;
	L.note.textContent = "Marked. Checking what was happening just before...";
	api("mark").then(function (j) { if (!j.ok) L.note.textContent = "The router did not record that. Is the matchwatch service running?"; });
}
document.addEventListener("keydown", function (e) { if (page === "live" && (e.key === "m" || e.key === "M") && !e.repeat && e.target === document.body) felt(); });
function updateLive() {
	if (page !== "live" || !L.title) return;
	var s = session(), now = D.st ? D.st.ts : 0, lb = D.lobby;
	// where the game is taking you
	L.banner.textContent = "";
	if (lb && now - lb.ts < 180 && (!s || (s.ip === lb.ip && s.age < 60))) {
		var bn = h("div", { cls: "banner " + (lb.verdict === "good" ? "" : lb.verdict) }, h("p", null, h("b", lb.blocked ? "Turned away. " : "Connecting. "), lb.msg));
		if (!lb.blocked && !isBlocked(lb.ip)) bn.appendChild(act("Block this server", "block", lb.ip, { danger: true, confirm: "Confirm: block it now" }));
		L.banner.appendChild(bn);
	}
	L.felt.disabled = !s;
	if (!s) {
		L.title.textContent = "No match in progress";
		L.sub.textContent = "Start a game and the server appears here within about ten seconds.";
		L.figs.textContent = ""; L.marks.textContent = ""; L.actions.textContent = ""; drawChart(L.cv, null);
		L.last.textContent = "";
		if (D.hist.length) {
			var m = D.hist[0];
			L.last.appendChild(h("h2", "Last match"));
			L.last.appendChild(h("p", { cls: "lede" }, when(m.start) + ", " + (place(m) || m.ip) + ": " + m.verdict + " "));
			L.last.appendChild(h("div", { cls: "actions" }, h("a", { href: "#/match/" + m.start, text: "See the full report" })));
		}
		return;
	}
	L.last.textContent = "";
	L.title.textContent = (s.loc || "Locating server") + (s.org ? " (" + s.org + ")" : "");
	L.sub.textContent = s.ip + ":" + s.port + (s.rep != null ? ". Rated " + s.rep + "/100 over " + s.repn + " earlier match" + (s.repn === 1 ? "" : "es") + "." : ". First time on this server.");
	L.figs.textContent = "";
	[["Ping", s.ping == null ? "n/a" : fmt(s.ping, 1), "ms"], ["Server update rate", fmt(s.tick, 0), "per second"], ["Timing jitter", fmt(s.jit, 2), "ms"], ["Late updates", fmt(s.late, 1), "%"],
	 ["Missing updates", fmt(s.s_lost, 2), "%"], ["Freezes", String(s.s_frz), "over 100 ms"], ["Your PC send rate", fmt(s.uprate, 0), "per second"], ["Your PC pauses", String(s.s_hitch), "over 100 ms"]]
		.forEach(function (f) { L.figs.appendChild(fig(f[0], f[1], f[2])); });
	L.marks.textContent = ""; L.marks.appendChild(marksList(s.marks));
	if (L.ip !== s.ip + isBlocked(s.ip) + isFav(s.ip)) {
		L.ip = s.ip + isBlocked(s.ip) + isFav(s.ip); L.actions.textContent = "";
		L.actions.appendChild(star(s.ip, true));
		if (!isBlocked(s.ip)) L.actions.appendChild(act("Block this server", "block", s.ip, { danger: true, confirm: "Confirm: block for " + (D.info.block_days || 14) + " days" }));
		if (D.info.qosmate !== false) L.actions.appendChild(act("Is my game prioritised?", "qos", null, { done: function (out) { toast(out.split("\n").slice(-1)[0]); } }));
	}
	drawChart(L.cv, { d: s.tl_d || [], u: s.tl_u || [], p: s.tl_p || [], dn: s.tick ? 1000 / s.tick : 0, un: s.uprate ? 1000 / s.uprate : 0, slots: 120,
		marks: (s.marks || []).map(function (m) { return 119 - (now - m.t); }) });
}

// ---------- one match in full
function chain(m) {
	var parts = [["Your PC", m.s_pc, m.pc_counted === 0 ? "Shown, not counted" : null], ["Your line", m.s_line, null], ["Route", m.s_route, m.route_ign ? "Shown, not counted" : null], ["Server", m.s_server, null]];
	var min = null; parts.forEach(function (p) { if (p[1] != null && !p[2] && (min == null || p[1] < min)) min = p[1]; });
	var c = h("div", { cls: "chain" });
	parts.forEach(function (p) {
		var weak = p[1] != null && !p[2] && p[1] === min && p[1] < 70;
		c.appendChild(h("div", { cls: "link " + cls(p[1]) }, h("div", { cls: "dot", text: p[1] == null ? "n/a" : String(p[1]) }), h("b", p[0]), h("span", p[2] || (weak ? "Weakest link" : grade(p[1])))));
	});
	return c;
}
function kv(pairs) {
	var dl = h("dl", { cls: "kv" });
	pairs.forEach(function (p) { if (!p) return; dl.appendChild(h("dt", null, p[0], p[2] ? h("small", p[2]) : null)); dl.appendChild(h("dd", p[1])); });
	return dl;
}
function pageMatch(id) {
	view.textContent = "";
	if (id === "last") { if (!D.hist.length) { view.appendChild(h("h1", "No match recorded yet")); view.appendChild(h("p", { cls: "sub", text: "Play a match and its report appears here." })); return; } id = String(D.hist[0].start); }
	var idx = -1; D.hist.forEach(function (x, i) { if (String(x.start) === id) idx = i; });
	var sum = idx >= 0 ? D.hist[idx] : null;
	view.appendChild(h("p", { cls: "empty", text: "Loading the report..." }));
	get("matches/" + id + ".json", function (m) {
		if (page !== "match") return;
		view.textContent = "";
		var full = !!m; m = m || sum;
		if (!m) { view.appendChild(h("h1", "That match is no longer on file")); return; }
		var where = place(m) || m.ip, sc = cls(m.overall);
		view.appendChild(h("div", { cls: "head" },
			h("div", null, h("h1", where), h("p", { cls: "sub", text: (sum && sum.game ? sum.game + ". " : "") + (m.org && m.org !== "-" ? m.org + ". " : "") + when(m.start) + ". " + mins(m.dur) + " played, " + mins(m.analysed) + " analysed. Server " + m.ip + ":" + m.port + "." })),
			h("div", { cls: "score" }, h("b", { cls: sc }, String(m.overall), h("small", "/100")), h("span", { cls: sc, text: grade(m.overall) }))));
		view.appendChild(h("p", { cls: "lede", text: m.verdict }));
		view.appendChild(chain(m));
		if (full && m.tl_d && m.tl_d.length) {
			var cv = h("canvas", { role: "img", "aria-label": "Ping and update timing across the whole match" });
			view.appendChild(h("div", { cls: "strip" }, cv, legend()));
			var paint = function () { drawChart(cv, { d: m.tl_d, u: m.tl_u, p: m.tl_p, dn: m.nom, un: m.upnom, slots: 0, minutes: true, marks: (m.marks || []).map(function (k) { return k.t - m.t0; }) }); };
			paint(); pageMatch.repaint = paint;
		} else { pageMatch.repaint = null; view.appendChild(h("p", { cls: "note", text: "The second-by-second chart is kept for matches recorded from version 0.4.0 onwards." })); }

		var a = h("div", { cls: "actions" });
		if (isBlocked(m.ip)) a.appendChild(h("span", { cls: "tag", text: "This server is blocked" }));
		else a.appendChild(act("Block this server", "block", m.ip, { danger: true, confirm: "Confirm: block for " + (D.info.block_days || 14) + " days" }));
		a.appendChild(star(m.ip, true));
		if (idx >= 0) a.appendChild(act("Remove this match", "forgetmatch", m.start, { confirm: "Confirm: remove this match", done: function (o) { toast(o); location.hash = "#/matches"; } }));
		if (idx >= 0 && idx < D.hist.length - 1) a.appendChild(h("a", { href: "#/match/" + D.hist[idx + 1].start, text: "Earlier match" }));
		if (idx > 0) a.appendChild(h("a", { href: "#/match/" + D.hist[idx - 1].start, text: "Later match" }));
		view.appendChild(a);

		if (m.marks && m.marks.length && typeof m.marks !== "number") { view.appendChild(h("h2", "Moments you flagged")); view.appendChild(marksList(m.marks)); }

		var cols = h("div", { cls: "cols" }), b;
		b = h("div", null, h("h2", "Server rhythm"));
		b.appendChild(kv([["Update rate", fmt(m.tick, 1) + " per second"], ["Timing jitter", fmt(m.jit, 2) + " ms", full ? fmt(m.jitpct, 1) + "% of one update" : null], ["Late updates", fmt(m.late, 2) + "%"],
			["Arrived in clumps", fmt(m.clump, 2) + "%", "Held up on the way, then delivered together"], ["Missing updates", fmt(m.lost, 2) + "%", "Lost in transit or never sent"],
			full ? ["Stutters over 50 ms", String(m.stut), m.worst ? "Worst gap " + m.worst + " ms" : null] : null, ["Freezes over 100 ms", String(m.freeze)], ["Rough stretches", fmt(m.rough, 0) + "% of the match"]]));
		cols.appendChild(b);
		b = h("div", null, h("h2", "Route"));
		if (m.ping == null) b.appendChild(h("p", { cls: "note", text: "Neither the server nor the hops before it answered probes, so the route could not be measured separately." }));
		else b.appendChild(kv([["Probed", m.farkind === "server" ? "The server itself" : m.farkind === "serverudp" ? "The server itself" : "Last hop that answers", m.farkind === "serverudp" ? "By traceroute-style probe: it ignores ping" : null],
			["Ping", fmt(m.ping, 1) + " ms", full && m.pingp95 != null ? "Worst 5%: " + fmt(m.pingp95, 1) + " ms" : null], ["Ping jitter", fmt(m.pingjit != null ? m.pingjit : null, 2) + " ms"],
			m.farkind === "serverudp" ? ["Probes answered", fmt(100 - (m.pingloss || 0), 0) + "%", "Servers ration these replies. Not packet loss in your game"] : ["Probe loss", fmt(m.pingloss, 1) + "%"], ["Hops", String(m.hops || "n/a")]]));
		if (full && m.trace && m.trace.length) { var ol = h("ol", { cls: "hops" }); m.trace.forEach(function (t) { ol.appendChild(h("li", t.trim().replace(/\s+/g, "  "))); }); b.appendChild(ol); }
		cols.appendChild(b);
		b = h("div", null, h("h2", "Your line"));
		if (m.nearping == null) b.appendChild(h("p", { cls: "note", text: "The first hop inside your ISP does not answer ping, so your line could not be measured separately." }));
		else b.appendChild(kv([full && m.nearip ? ["First ISP hop", m.nearip] : null, ["Ping", fmt(m.nearping, 1) + " ms"], ["Jitter", fmt(m.nearjit, 2) + " ms"], ["Loss", fmt(m.nearloss, 1) + "%"],
			full && m.wanavg != null ? ["Other traffic on your line", fmt(m.wanavg, 1) + " Mbit/s average", "Peak " + fmt(m.wanpeak, 0) + " down, " + fmt(m.wanuppeak, 0) + " up"] : null,
			full && m.qos ? ["QoSmate", m.qos === "top" ? "Game in the top queue" : m.qos === "low" ? "Game NOT in the top queue" : "Could not tell"] : null]));
		cols.appendChild(b);
		b = h("div", null, h("h2", "Your PC"));
		if (m.uprate == null) b.appendChild(h("p", { cls: "note", text: "Not enough outgoing traffic to judge." }));
		else b.appendChild(kv([["Send rate", fmt(m.uprate, 1) + " per second"], ["Send jitter", fmt(m.upjit, 2) + " ms", "Follows your frame rate. Not scored unless extreme"],
			["Pauses over 100 ms", String(full ? m.pauses : m.hitch), full && m.upworst ? "Worst " + m.upworst + " ms" : null], full && m.stalls != null ? ["Shorter pauses, 50 to 100 ms", String(Math.max(0, m.stalls - m.pauses)), "Not scored"] : null,
			m.lanping != null ? ["Router to PC", fmt(m.lanping, 2) + " ms"] : ["Router to PC", "n/a", "The PC does not answer ping"]]));
		cols.appendChild(b);
		view.appendChild(cols);
		view.appendChild(h("p", { cls: "note", text: (m.counted ? "This match counts towards the server's rating (" + m.rating + "/100 for this match)." : "This match does not count towards the server's rating: it was too short, or your own line was unstable.") }));
	});
}

// ---------- lists
var gameFilter = "", hourFilter = -1, regionsAll = false;
function hourOf(m) { return new Date(m.start * 1000).getHours(); }
function hh(i) { return (i < 10 ? "0" : "") + i + ":00"; }
function recap() {
	var hs = D.hist; if (!hs.length) return null;
	var last = 0, i;
	for (i = 0; i < hs.length - 1; i++) { if (hs[i].start - (hs[i + 1].start + hs[i + 1].dur) > 5400) break; last = i + 1; }
	var ses = hs.slice(0, last + 1), sum = 0, secs = 0, best = ses[0], worst = ses[0], find = {}, flags = 0, gm = {};
	ses.forEach(function (m) { var g = m.game || "Unknown game"; gm[g] = (gm[g] || 0) + 1; sum += m.overall; secs += m.dur; if (m.overall > best.overall) best = m; if (m.overall < worst.overall) worst = m; var f = FINDING[m.code] || m.code; find[f] = (find[f] || 0) + 1; flags += m.marks || 0; });
	var t0 = new Date(ses[ses.length - 1].start * 1000), t1 = new Date((ses[0].start + ses[0].dur) * 1000), tm = function (d) { return d.toLocaleTimeString(undefined, { hour: "2-digit", minute: "2-digit" }); };
	var gl = Object.keys(gm), played = gl.length === 1 ? " of " + gl[0] : "";
	var txt = ses.length + " match" + (ses.length === 1 ? "" : "es") + played + ", " + Math.round(secs / 60) + " minutes of play, " + t0.toLocaleDateString(undefined, { day: "numeric", month: "short" }) + " " + tm(t0) + " to " + tm(t1) + ". Average " + Math.round(sum / ses.length) + "/100.";
	if (ses.length > 1) txt += " Best: " + (place(best) || best.ip) + " (" + best.overall + "). Worst: " + (place(worst) || worst.ip) + " (" + worst.overall + ", " + (FINDING[worst.code] || worst.code).toLowerCase() + ").";
	if (gl.length > 1) txt += " Games: " + gl.map(function (g) { return g + " (" + gm[g] + ")"; }).join(", ") + ".";
	txt += " Findings: " + Object.keys(find).map(function (k) { return find[k] + " " + k.toLowerCase(); }).join(", ") + ".";
	if (flags) txt += " You flagged " + flags + " moment" + (flags === 1 ? "" : "s") + ".";
	return txt;
}
function hoursStrip() {
	var n = [], s = [], i;
	for (i = 0; i < 24; i++) { n.push(0); s.push(0); }
	D.hist.forEach(function (m) { if (!m.counted) return; var hr = new Date(m.start * 1000).getHours(); n[hr]++; s[hr] += m.rating; });
	if (!n.some(function (x) { return x > 0; })) return null;
	var wrap = h("div", { cls: "hours", role: "img", "aria-label": "Average server rating by hour of the day" }), best = -1, worst = -1;
	for (i = 0; i < 24; i++) {
		var avg = n[i] ? Math.round(s[i] / n[i]) : null, all = D.hist.filter(function (m) { return hourOf(m) === i; });
		var label = hh(i) + (n[i] ? ", " + n[i] + " rated match" + (n[i] === 1 ? "" : "es") + ", average " + avg : ", no rated matches");
		var cell = all.length ? h("button", { type: "button", cls: "hr" + (hourFilter === i ? " sel" : ""), title: label + ". Show " + (all.length === 1 ? "this match" : "these matches"), "aria-label": label }) : h("div", { cls: "hr", title: label });
		if (all.length) (function (hour, list) { cell.addEventListener("click", function () {
			if (list.length === 1) { hourFilter = -1; location.hash = "#/match/" + list[0].start; return; }
			hourFilter = (hourFilter === hour) ? -1 : hour; pageMatches();
			var t = shadow.getElementById("every"); if (t) t.scrollIntoView({ behavior: "smooth", block: "start" });
		}); })(i, all);
		var bar = h("i", { cls: avg == null ? "" : cls(avg) }); bar.style.height = (avg == null ? 3 : Math.max(8, avg * 0.6)) + "px";
		cell.appendChild(h("span", { cls: "v", text: avg == null ? "" : String(avg) })); cell.appendChild(bar); cell.appendChild(h("span", { text: i % 3 === 0 ? (i < 10 ? "0" : "") + i : "" }));
		wrap.appendChild(cell);
		if (n[i] >= 2) { if (best < 0 || s[i] / n[i] > s[best] / n[best]) best = i; if (worst < 0 || s[i] / n[i] < s[worst] / n[worst]) worst = i; }
	}
	var note = "Average server rating for matches starting in each hour, in your local time. Select a bar to see its matches. ";
	note += (best >= 0 && worst >= 0 && best !== worst) ? "Best so far: " + best + ":00 (" + Math.round(s[best] / n[best]) + " over " + n[best] + " matches). Worst: " + worst + ":00 (" + Math.round(s[worst] / n[worst]) + " over " + n[worst] + ")." : "It needs a few matches in several different hours before it can name a best and worst time.";
	return h("div", null, wrap, h("p", { cls: "note", text: note }));
}
function pageMatches() {
	view.textContent = ""; view.appendChild(h("h1", "Matches"));
	var np = namePrompt(function () { if (page === "matches") pageMatches(); });
	if (np) view.appendChild(np);
	if (!D.hist.length) { view.appendChild(h("p", { cls: "sub", text: "No matches recorded yet." })); return; }
	var rc = recap();
	if (rc) { view.appendChild(h("h2", "Latest session")); view.appendChild(h("p", { cls: "lede", text: rc })); }
	var hsx = hoursStrip();
	if (hsx) { view.appendChild(h("h2", "Best time to play")); view.appendChild(hsx); }
	var hd = h("h2", { id: "every", text: hourFilter >= 0 ? "Matches starting between " + hh(hourFilter) + " and " + hh((hourFilter + 1) % 24) : "Every match" });
	view.appendChild(hd);
	if (hourFilter >= 0) { var allb = h("button", { type: "button", text: "Show every match" }); allb.style.marginLeft = "0"; allb.addEventListener("click", function () { hourFilter = -1; pageMatches(); }); view.appendChild(h("div", { cls: "actions" }, allb)); }
	var games = []; D.hist.forEach(function (m) { if (m.game && games.indexOf(m.game) < 0) games.push(m.game); });
	if (games.length > 1) {
		var sel = h("select", { "aria-label": "Show one game" }); sel.appendChild(h("option", { value: "", text: "Every game" }));
		games.forEach(function (g) { var o = h("option", { value: g, text: g }); if (g === gameFilter) o.selected = true; sel.appendChild(o); });
		sel.addEventListener("change", function () { gameFilter = sel.value; pageMatches(); });
		view.appendChild(h("div", { cls: "stayform" }, sel));
	} else gameFilter = "";
	view.appendChild(h("p", { cls: "sub", text: "Select a match for its full report." }));
	var heads = [["When"], ["Where"], ["Server"], ["Length"], ["Ping ms", "num"], ["Jitter ms", "num"], ["Missing %", "num"], ["Overall", "num"], ["Finding"], ["You flagged"], ["", ""]];
	heads.splice(1, 0, ["Game"]);
	var t = table(heads);
	D.hist.forEach(function (m) {
		if (gameFilter && m.game !== gameFilter) return;
		if (hourFilter >= 0 && hourOf(m) !== hourFilter) return;
		var cells = [[when(m.start)], [place(m)], [m.ip], [mins(m.dur)], [m.ping == null ? "n/a" : fmt(m.ping, 1), "num"], [fmt(m.jit, 2), "num"], [fmt(m.lost, 2), "num"], [String(m.overall), "num s " + cls(m.overall)], [FINDING[m.code] || m.code], [m.marks ? m.marksum : ""]];
		cells.splice(1, 0, [m.game || ""]);
		var rm = h("td", { cls: "act" }); rm.appendChild(act("Remove", "forgetmatch", m.start, { confirm: "Confirm: remove this match" })); cells.push(rm);
		var tr = row(cells);
		tr.tabIndex = 0; tr.setAttribute("role", "link");
		var go = function () { location.hash = "#/match/" + m.start; };
		tr.addEventListener("click", go); tr.addEventListener("keydown", function (e) { if (e.key === "Enter") go(); });
		t.lastChild.appendChild(tr);
	});
	view.appendChild(h("div", { cls: "tablewrap" }, t));
}
function pageServers() {
	view.textContent = ""; view.appendChild(h("h1", "Servers"));
	var days = D.info.block_days || 14;
	var stays = D.info.stays || [];
	if (stays.length) {
		var bn = h("div", { cls: "banner" }, h("p", null, h("b", "Staying on " + stays.join(", ") + ". "), "A server in any of these is allowed. Servers anywhere else are turned away as the game tries them. A place is dropped if matches there start rating badly."), act("Stop staying", "stayoff", null, {}));
		view.appendChild(bn);
		if (stays.length > 1) {
			var rm = h("div", { cls: "actions" });
			stays.forEach(function (nm, i) { rm.appendChild(act("Remove " + nm, "stayrm", i + 1, {})); });
			view.appendChild(rm);
		}
	}
	// stay anywhere: cities, countries or wider areas, as one pool
	if (!RO) {
	view.appendChild(h("h2", stays.length ? "Change where you stay" : "Stay in one or more places"));
	var inp = h("input", { type: "text", id: "place", placeholder: "France, Germany, Spain", autocomplete: "off", "aria-label": "Places to stay on, separated by commas" });
	var send = function (action, btn, label) {
		var v = inp.value.trim().toLowerCase().replace(/[^a-z0-9 ,-]/g, "").replace(/ *, */g, ",").replace(/ +/g, "+");
		if (!v) { inp.focus(); return; }
		btn.disabled = true; btn.textContent = "Working...";
		api(action, null, "&region=" + v).then(function (j) {
			btn.disabled = false; btn.textContent = label;
			toast(j.out || j.error || "That did not work.", !j.ok);
			if (j.ok) { inp.value = ""; refresh(true); }
		});
	};
	var go = h("button", { type: "button", cls: "solid", text: stays.length ? "Replace the pool" : "Stay here" });
	go.addEventListener("click", function () { send("stay", go, stays.length ? "Replace the pool" : "Stay here"); });
	inp.addEventListener("keydown", function (e) { if (e.key === "Enter") (stays.length ? add : go).click(); });
	var add = h("button", { type: "button", text: "Add to the pool" });
	add.addEventListener("click", function () { send("stayadd", add, "Add to the pool"); });
	view.appendChild(h("div", { cls: "stayform" }, inp, stays.length ? add : null, go));
	view.appendChild(h("p", { cls: "note", text: "Type one place or several, separated by commas: cities, countries, or these areas: uk-ireland, western-europe, southern-europe, northern-europe, eastern-europe, europe, north-america, south-america, middle-east, asia, oceania. A city allows servers within about 150 km of it; a country or area allows any server located there. Several places make one pool, and the game picks among them, which keeps queues shorter than a single place." }));
	}
	view.appendChild(favSection());
	view.appendChild(h("h2", "Datacentres, worst first"));
	if (!D.dcs.length) view.appendChild(h("p", { cls: "empty", text: "No datacentres seen yet." }));
	else {
		var t = table([["Datacentre"], ["Matches", "num"], ["Servers", "num"], ["Rating", "num"], ["Worst", "num"], ["Ping ms", "num"], ["", ""]]);
		D.dcs.forEach(function (d) {
			var td = h("td", { cls: "act" });
			if (d.stay) { td.appendChild(h("span", { cls: "tag keep", text: "In the pool" })); }
			else if (d.blocked && D.info.stay) { td.appendChild(h("span", { cls: "tag", text: "Turned away" })); }
			else if (d.blocked) { td.appendChild(h("span", { cls: "tag", text: "Blocked" })); td.appendChild(act("Unblock", "unblockdc", d.n, {})); }
			else { td.appendChild(act("Stay here", "stay", d.n, { confirm: "Confirm: turn the others away" })); td.appendChild(act("Block", "blockdc", d.n, { danger: true, confirm: "Confirm: block for " + days + " days" })); }
			td.appendChild(act("Remove", "forgetdc", d.n, { confirm: "Confirm: remove it and its " + d.matches + " match" + (d.matches === 1 ? "" : "es") }));
			t.lastChild.appendChild(row([[d.name], [String(d.matches), "num"], [String(d.servers), "num"], [String(d.rating), "num s " + cls(d.rating)], [String(d.worst), "num"], [d.ping == null ? "n/a" : fmt(d.ping, 1), "num"], td]));
		});
		view.appendChild(h("div", { cls: "tablewrap" }, t));
		view.appendChild(h("p", { cls: "note", text: "A datacentre is one operator in one city. Ratings need a few matches each before they mean much. Blocking one only covers the address blocks you have been placed on there so far. Remove takes a datacentre, its servers and their matches out of MatchWatch altogether; it is refused while one of its servers is a favourite." }));
	}
	view.appendChild(h("h2", "Every region, nearest first"));
	var rg = D.regions || [];
	if (!rg.length) view.appendChild(h("p", { cls: "empty", text: "Not measured yet." }));
	else {
		var tr = table([["Region"], ["Area"], ["Ping ms", "num"], ["Jitter ms", "num"], ["Your matches there", "num"], ["Rating", "num"], ["Ping in matches", "num"], ["", ""]]);
		(regionsAll ? rg : rg.slice(0, 4)).forEach(function (r) {
			tr.lastChild.appendChild(row([[r.city + ", " + r.cc], [r.area], [r.ping == null ? "No reply" : fmt(r.ping, 1), "num s"], [r.jit == null ? "" : fmt(r.jit, 1), "num"],
				[r.matches ? String(r.matches) : "", "num"], [r.rating == null ? "" : String(r.rating), "num s " + cls(r.rating)], [r.matchping == null ? "" : fmt(r.matchping, 1), "num"],
				(function () { var td = h("td", { cls: "act" }); if (r.stay) td.appendChild(h("span", { cls: "tag keep", text: "In the pool" })); else if (r.ping != null && stays.length) td.appendChild(act("Add", "stayadd", null, { extra: "&region=" + r.code })); else if (r.ping != null) td.appendChild(act("Stay here", "stay", null, { extra: "&region=" + r.code, confirm: "Confirm: turn the others away" })); return td; })()]));
		});
		view.appendChild(h("div", { cls: "tablewrap" }, tr));
	}
	var more = null;
	if (rg.length > 4) {
		more = h("button", { type: "button", text: regionsAll ? "Show the nearest 4" : "Show all " + rg.length + " regions" });
		more.addEventListener("click", function () { var y = window.scrollY; regionsAll = !regionsAll; pageServers(); window.scrollTo(0, y); });
	}
	view.appendChild(h("div", { cls: "actions" }, more, act("Measure now", "regions", null, { done: function () { toast("Regions measured."); } })));
	view.appendChild(h("p", { cls: "note", text: "Ping from your router to the test server Vultr runs in each of its datacentres" + (rg.length ? ", measured " + when(rg[0].ts) : "") + ". Every Call of Duty server you have been placed on so far is hosted by Vultr, but the game is reported to use other hosts in some places, so this is not a complete list of where it has servers. Stay here on a row is the same as typing that city above: it allows servers within about 150 km of it, whoever hosts them. The game still decides which regions to offer you." }));
	view.appendChild(h("h2", "Servers, worst first"));
	if (!D.servers.length) view.appendChild(h("p", { cls: "empty", text: "No servers seen yet." }));
	else {
		var t2 = table([["Server"], ["Where"], ["Host"], ["Matches", "num"], ["Rating", "num"], ["Worst", "num"], ["Ping ms", "num"], ["", ""]]);
		D.servers.forEach(function (s) {
			var td = h("td", { cls: "act" });
			td.appendChild(star(s.ip));
			if (s.blocked) td.appendChild(h("span", { cls: "tag", text: "Blocked" })); else td.appendChild(act("Block", "block", s.ip, { danger: true, confirm: "Confirm: " + days + " days" }));
			if (!isFav(s.ip)) td.appendChild(act("Remove", "forgetserver", s.ip, { confirm: "Confirm: remove it and its " + s.matches + " match" + (s.matches === 1 ? "" : "es") }));
			else if (!RO) td.appendChild(h("span", { cls: "kept", title: "A favourite cannot be removed. Take its star off first.", text: "Kept" }));
			t2.lastChild.appendChild(row([[s.ip], [place(s)], [s.org === "-" ? "" : s.org], [String(s.matches), "num"], [String(s.rating), "num s " + cls(s.rating)], [String(s.worst), "num"], [s.ping == null ? "n/a" : fmt(s.ping, 1), "num"], td]));
		});
		view.appendChild(h("div", { cls: "tablewrap" }, t2));
	}
	view.appendChild(h("h2", "Blocked now"));
	if (!D.blocks.length) view.appendChild(h("p", { cls: "empty", text: "Nothing is blocked." }));
	else {
		var t3 = table([["Address"], ["Lifts in"], ["Why"], ["", ""]]);
		D.blocks.forEach(function (b) {
			var td = h("td", { cls: "act" }); td.appendChild(act("Unblock", "unblock", b.ip, {}));
			t3.lastChild.appendChild(row([[b.ip], [b.days == null ? "When you unblock it" : b.days + " day" + (b.days === 1 ? "" : "s")], [b.reason === "stay" ? "Staying on another datacentre" : b.reason === "manual" ? "Blocked by you" : b.reason], td]));
		});
		view.appendChild(h("div", { cls: "tablewrap" }, t3));
	}
}
// A slow tool: the router starts it and answers with a job number; the result lands in a data file a little later.
function job(btn, action, arg, file, done) {
	var label = btn.textContent, reset = function () { btn.disabled = false; btn.textContent = label; };
	btn.disabled = true; btn.textContent = "Working...";
	api(action, arg).then(function (j) {
		if (!j.ok) { reset(); toast(j.out || j.error || "That did not work.", true); return; }
		var id = String(j.out || "").trim(), tries = 0;
		var t = setInterval(function () {
			get(file, function (r) {
				if (r && r.state === "done" && r.id === id) { clearInterval(t); reset(); done(r); }
				else if (++tries > 45) { clearInterval(t); reset(); toast("That took too long. Try again.", true); }
			});
		}, 2000);
	});
}
function csvCell(v) { v = v == null ? "" : String(v); return /[",\n]/.test(v) ? '"' + v.replace(/"/g, '""') + '"' : v; }
function downloadHistory() {
	var cols = ["start", "game", "city", "cc", "ip", "port", "dur", "ping", "jit", "lost", "overall", "code", "verdict"];
	var lines = [["When", "Game", "City", "Country", "Server", "Port", "Seconds", "Ping ms", "Jitter ms", "Missing %", "Overall", "Finding", "Verdict"].join(",")];
	D.hist.forEach(function (m) { lines.push(cols.map(function (c) { return csvCell(c === "start" ? new Date(m.start * 1000).toISOString() : m[c]); }).join(",")); });
	var a = document.createElement("a");
	a.href = URL.createObjectURL(new Blob([lines.join("\r\n") + "\r\n"], { type: "text/csv" }));
	a.download = "matchwatch-history.csv";
	document.body.appendChild(a); a.click(); a.remove();
	setTimeout(function () { URL.revokeObjectURL(a.href); }, 5000);
}
// ---------- share files: game names, places, ratings, ping hosts and thresholds as a text file to pass on
var SHARE = [["games", "1", "Game names"], ["favourites", "6", "Favourite servers"], ["places", "3", "Places you stay on"], ["ratings", "4", "Network ratings"], ["regions", "2", "Ping hosts for the regions table"], ["settings", "5", "Thresholds"], ["favplaces", "7", "Stay near those servers"]];
function saveText(name, text) {
	var a = document.createElement("a");
	a.href = URL.createObjectURL(new Blob([text], { type: "text/plain" }));
	a.download = name;
	document.body.appendChild(a); a.click(); a.remove();
	setTimeout(function () { URL.revokeObjectURL(a.href); }, 5000);
}
function tick1(label, value, on) {
	var c = h("input", { type: "checkbox", value: value });
	c.checked = !!on;
	return { box: c, el: h("label", { cls: "tickbox" }, c, " " + label) };
}
function ticked(list) { return list.filter(function (t) { return t.box.checked; }).map(function (t) { return t.box.value; }).join(""); }
function send(p) { return T.act(p).then(function (j) { return j || {}; }, function () { return { ok: false, out: "Could not reach the router." }; }); }
var SETNAME = { min_down_pps: "A match needs this many packets a second down", min_up_pps: "And this many up", warn_score: "Warn below this rating", autoblock_score: "Automatic block below this rating",
	autoblock_matches: "Automatic block after this many matches", lobby_margin_ms: "\"Far\" means this many ms slower", stay_km: "A city reaches this many km", block_days: "Blocks last this many days" };
// what one line of a share file means, in words; for ratings also the facts the quick picks filter on
function shareItem(sec, line) {
	var f = line.split(sec === "settings" ? "=" : "|"), o = { line: line, text: line };
	if (sec === "games") o.text = f[0] + ": server port" + (/[,-]/.test(f[1]) ? "s " : " ") + f[1] + (f[2] === "voice" ? ", voice chat" : "") + (f[3] ? ", only when hosted by " + f[3].split(",").join(" or ") : "");
	else if (sec === "regions") o.text = f[1] + ", " + f[2] + ": " + f[6];
	else if (sec === "places") o.text = f[0] + (f[4] && f[4] !== "-" ? " (anywhere in " + f[4].split(",").join(", ") + ")" : " (within " + f[3] + " km)");
	else if (sec === "ratings") {
		o.n = +f[1]; o.avg = +f[2]; o.city = f[3] && f[3] !== "-" ? f[3] : ""; o.cc = f[4] && f[4] !== "-" ? f[4] : "";
		o.text = f[0] + (o.city || o.cc ? ", " + [o.city, o.cc].filter(Boolean).join(", ") : "") + (f[5] && f[5].trim() ? ", " + f[5].trim() : "") + ": rated " + o.avg + " over " + o.n + " match" + (o.n === 1 ? "" : "es");
		o.on = o.n >= 2;
	}
	else if (sec === "favourites") {
		// from the router this carries a tenth field: is it one of your favourites? It never goes into the file.
		o.fav = f[9] !== "0"; o.line = f.slice(0, 9).join("|"); o.game = f[1] || "Other games";
		o.avg = f[5] === "" ? null : +f[5]; o.n = +f[6] || 0; o.city = f[2] || ""; o.cc = f[3] && f[3] !== "-" ? f[3] : "";
		o.text = (o.fav ? "\u2605 " : "") + o.game + ": " + f[0] + (o.city || o.cc ? ", " + [o.city, o.cc].filter(Boolean).join(", ") : "") + (f[4] && f[4].trim() ? ", " + f[4].trim() : "") + (o.avg == null ? "" : ": rated " + o.avg + " over " + o.n + " match" + (o.n === 1 ? "" : "es"));
		o.on = o.fav;
	}
	else if (sec === "settings") { o.text = (SETNAME[f[0]] || f[0]) + ": " + f[1]; o.on = false; }
	return o;
}
// the picker: one block per section, a tick per item, quick picks, a note, and a preview that is exactly the file
var ONE = { games: "game name", favourites: "favourite server", regions: "ping host", places: "place", ratings: "network rating", settings: "threshold" };
function sharePicker(text, pickBox, made) {
	var head = [], notes = {}, items = {}, sec = "", total = 0;
	text.split("\n").forEach(function (l) {
		var m = /^\[([a-z]+)\]$/.exec(l);
		if (m) { sec = m[1]; items[sec] = []; notes[sec] = []; return; }
		if (!l.trim() || l === "matchwatch-share 1") return;
		if (l.charAt(0) === "#") { if (sec) notes[sec].push(l); else head.push(l); return; }
		if (sec) { items[sec].push(shareItem(sec, l)); total++; }
	});
	pickBox.textContent = ""; made.textContent = "";
	if (!total) { pickBox.appendChild(h("p", { cls: "empty", text: "There is nothing to share yet." })); return; }

	var note = h("input", { type: "text", maxlength: "200", placeholder: "For example: UK fibre, evenings, mostly Call of Duty", autocomplete: "off", "aria-label": "A note for whoever gets the file" });
	var ta = h("textarea", { cls: "sharetext", rows: "12", readonly: "readonly", "aria-label": "The share file" });
	var sum = h("p", { cls: "note" }), dl = h("button", { type: "button", cls: "solid", text: "Save as a file" }), cp = h("button", { type: "button", text: "Copy" });
	var counts = {};
	function build() {
		var out = head.slice(), said = [], n = note.value.replace(/[^A-Za-z0-9 .,:()+&-]/g, " ").trim();
		if (n) out.push("# Note: " + n);
		out.push("matchwatch-share 1");
		SHARE.forEach(function (x) {
			var its = (items[x[0]] || []).filter(function (i) { return i.box.checked; });
			if (counts[x[0]]) counts[x[0]].textContent = its.length + " of " + items[x[0]].length + " ticked";
			if (!its.length) return;
			out.push("", "[" + x[0] + "]"); out = out.concat(notes[x[0]], its.map(function (i) { return i.line; }));
			said.push(its.length + " " + ONE[x[0]] + (its.length === 1 ? "" : "s"));
		});
		ta.value = said.length ? out.join("\n") + "\n" : "";
		dl.disabled = cp.disabled = !said.length;
		sum.textContent = said.length ? "In the file: " + said.join(", ") + ". The box above is everything in it. Read it through before you pass it on." : "Nothing is ticked, so there is no file yet.";
	}
	SHARE.forEach(function (x) {
		var its = items[x[0]] || [];
		if (!its.length) return;
		var list = h("div", { cls: "picklist" });
		its.forEach(function (i) { var t = tick1(i.text, "", i.on !== false); i.box = t.box; i.el = t.el; t.box.addEventListener("change", build); list.appendChild(t.el); });
		var setAll = function (fn) { its.forEach(function (i) { if (i.el.style.display !== "none") i.box.checked = !!fn(i); }); build(); };   // only what is listed
		var all = h("button", { type: "button", text: "All" }), none = h("button", { type: "button", text: "None" });
		all.addEventListener("click", function () { setAll(function () { return true; }); });
		none.addEventListener("click", function () { setAll(function () { return false; }); });
		counts[x[0]] = h("span", { cls: "pickcount" });
		var inner = h("div"), blk = h("details", { cls: "pick" }, h("summary", { cls: "pickhead" }, h("b", x[2]), counts[x[0]]), inner);
		inner.appendChild(h("div", { cls: "quick" }, all, none));
		if ((x[0] === "ratings" || x[0] === "favourites") && its.length > 1) {
			// quick picks: tick by several things at once; single ticks can still be changed after
			var isFavs = x[0] === "favourites", sels = [];
			var mk = function (label, opts, val) { var s = h("select", { "aria-label": label }); opts.forEach(function (o) { s.appendChild(h("option", { value: o[0], text: o[1] })); }); s.value = val; sels.push(s); return s; };
			var uniq = function (key, pre, word) { var seen = []; its.forEach(function (i) { if (i[key] && seen.indexOf(i[key]) < 0) seen.push(i[key]); }); return seen.sort().map(function (v) { return [pre + v, word + v]; }); };
			var qf = isFavs ? mk("Pick favourites or every server", [["fav", "My favourites"], ["", "Every server I have played on"]], its.some(function (i) { return i.fav; }) ? "fav" : "") : null;
			var qg = isFavs ? mk("Pick by game", [["", "Any game"]].concat(uniq("game", "", "")), "") : null;
			var qr = mk("Pick by rating", [["", "Any rating"], ["poor", "Poor: under 50"], ["fair", "Fair or worse: under 70"], ["good", "Good: 70 or more"], ["great", "Excellent: 85 or more"]], "");
			var qp = mk("Pick by place", [["", "Anywhere"]].concat(uniq("cc", "c:", "Country: "), uniq("city", "t:", "City: ")), "");
			var qn = mk("Pick by number of matches", [["0", "Any number of matches"], ["2", "2 or more matches"], ["3", "3 or more"], ["5", "5 or more"], ["10", "10 or more"]], isFavs ? "0" : "2");
			var hid = h("p", { cls: "note" });
			var apply = function () {
				var out = 0, some = 0;
				its.forEach(function (i) { var s = (function (i) {
					var r = qr.value, p = qp.value;
					if (qf && qf.value === "fav" && !i.fav) return false;
					if (qg && qg.value && i.game !== qg.value) return false;
					if (r && (i.avg == null || r === "poor" && i.avg >= 50 || r === "fair" && i.avg >= 70 || r === "good" && i.avg < 70 || r === "great" && i.avg < 85)) return false;
					if (p && (p.charAt(0) === "c" ? i.cc !== p.slice(2) : i.city !== p.slice(2))) return false;
					return i.n >= +qn.value;
				})(i); i.el.style.display = s ? "" : "none"; if (s) some++; else if (i.box.checked) out++; });
				hid.textContent = (some ? "" : "Nothing matches. ") + (out ? out + " ticked " + (out === 1 ? "item is" : "items are") + " not listed here and " + (out === 1 ? "is" : "are") + " still in the file." : "");
			};
			var q = h("div", { cls: "quick" }, h("span", "Show only: "));
			sels.forEach(function (s) { s.addEventListener("change", apply); q.appendChild(s); });
			inner.appendChild(q); inner.appendChild(list); inner.appendChild(hid);
			apply();
		} else inner.appendChild(list);
		pickBox.appendChild(blk);
	});
	note.addEventListener("input", build);
	pickBox.appendChild(h("div", { cls: "pick" }, h("div", { cls: "pickhead" }, h("b", "A note for whoever gets it"), h("span", { cls: "pickcount", text: "optional" })), h("div", { cls: "stayform" }, note),
		h("p", { cls: "note", text: "Ratings mean most with some context: roughly where you are and what you play. Only write what you are happy for others to read." })));
	dl.addEventListener("click", function () { saveText("matchwatch-share.txt", ta.value); });
	cp.addEventListener("click", function () { ta.select(); try { document.execCommand("copy"); toast("Copied."); } catch (e) { toast("Select the text and copy it by hand.", true); } });
	made.appendChild(ta); made.appendChild(h("div", { cls: "actions" }, dl, cp)); made.appendChild(sum);
	build();
}
function shareSection() {
	var box = h("div");
	box.appendChild(h("p", { cls: "note", text: "A share file is a small text file holding things another MatchWatch user can use: the games you have named, your favourite servers for each game, the places you stay on, how servers have rated for you, extra ping hosts, and your thresholds. You pick what goes in, item by item. Nothing is ever sent anywhere: you make the file, and you choose who gets it. It never holds your device, your addresses or when you played." }));

	// ---- make a file: the router lists everything that could be shared, and every item gets its own tick
	box.appendChild(h("h3", "Make a share file"));
	var pickBox = h("div"), made = h("div");
	var mk = h("button", { type: "button", cls: "solid", text: "Choose what to share" });
	box.appendChild(h("div", { cls: "actions" }, mk)); box.appendChild(pickBox); box.appendChild(made);
	mk.addEventListener("click", function () {
		mk.disabled = true;
		send({ action: "shareexport", arg: "123458" }).then(function (j) {
			mk.disabled = false;
			if (!j.ok) { toast(j.out || "That did not work.", true); return; }
			mk.textContent = "Start again";
			sharePicker(String(j.out || ""), pickBox, made);
		});
	});

	// ---- take one in
	box.appendChild(h("h3", "Use a share file"));
	var pick = h("input", { type: "file", accept: ".txt,text/plain", "aria-label": "Choose a share file" });
	var paste = h("textarea", { cls: "sharetext keep", rows: "5", placeholder: "Choose a file above, or paste the text of one here", "aria-label": "Text of a share file" });
	var chk = h("button", { type: "button", cls: "solid", text: "Check this file" }), found = h("div");
	pick.addEventListener("change", function () {
		var f = pick.files && pick.files[0];
		if (!f) return;
		if (f.size > 65536) { toast("That is too big to be a share file.", true); pick.value = ""; return; }
		var r = new FileReader(); r.onload = function () { paste.value = String(r.result || ""); found.textContent = ""; }; r.readAsText(f);
	});
	box.appendChild(h("div", { cls: "filepick" }, pick)); box.appendChild(paste); box.appendChild(h("div", { cls: "actions" }, chk)); box.appendChild(found);
	box.appendChild(h("p", { cls: "note", text: "Checking changes nothing. It shows what the file holds, and you choose which parts to take. Every line is checked first and anything unsafe is left out. Ratings from someone else are only ever shown to you: MatchWatch never blocks a server because of them." }));
	chk.addEventListener("click", function () {
		var text = paste.value;
		if (!text.trim()) { toast("Choose a share file, or paste one in.", true); return; }
		chk.disabled = true; found.textContent = "";
		send({ action: "sharecheck", data: text }).then(function (j) {
			chk.disabled = false;
			if (!j.ok) { toast(j.out || "That did not work.", true); return; }
			var inList = [], rest = [];
			String(j.out || "").split("\n").forEach(function (line) {
				var m = /^([a-z]+): (.*)$/.exec(line), s = m && SHARE.filter(function (x) { return x[0] === m[1]; })[0];
				if (s) { var t = tick1(m[2], s[1], s[0] !== "places" && s[0] !== "settings" && s[0] !== "favplaces"); inList.push(t); found.appendChild(t.el); }
				else if (line) rest.push(line);
			});
			if (rest.length) found.appendChild(h("pre", rest.join("\n")));
			var go = h("button", { type: "button", cls: "solid", text: "Take in the ticked parts" }), res = h("pre"); res.style.display = "none";
			go.addEventListener("click", function () {
				var want = ticked(inList);
				if (!want) { toast("Tick at least one part.", true); return; }
				go.disabled = true;
				send({ action: "shareimport", arg: want, data: text }).then(function (k) {
					go.disabled = false;
					res.textContent = k.out || "That did not work."; res.style.display = "block";
					if (k.ok) { go.style.display = "none"; paste.value = ""; pick.value = ""; refresh(true); setTimeout(shared, 1500); }
				});
			});
			found.appendChild(h("div", { cls: "actions" }, go)); found.appendChild(res);
		});
	});

	// ---- what has been taken in
	var got = h("div");
	box.appendChild(got);
	function shared() {
		get("shared.json", function (s) {
			if (page !== "tools") return;
			s = s || { have: {}, ratings: [] };
			got.textContent = "";
			var rs = (s.ratings || []).slice().sort(function (a, b) { return a.avg - b.avg; });
			if (rs.length) {
				got.appendChild(h("h3", "Ratings shared with you"));
				var t = table([["Server network"], ["Where"], ["Hosted by"], ["Matches", "num"], ["Their rating", "num"], [""]]);
				rs.forEach(function (x) {
					var td = h("td", { cls: "act" });
					if (x.blocked) td.appendChild(h("span", { cls: "tag", text: "Blocked" }));
					else td.appendChild(act("Block", "block", x.p, { confirm: "Confirm block", done: function (o) { toast(o); td.textContent = "Blocked"; } }));
					td.appendChild(act("Remove", "shareforget", x.p, { done: function (o) { toast(o); setTimeout(shared, 800); } }));
					t.lastChild.appendChild(row([[x.p], [place(x)], [x.org || ""], [String(x.n), "num"], [String(x.avg), "num " + cls(x.avg)], td]));
				});
				got.appendChild(h("div", { cls: "tablewrap" }, t));
				got.appendChild(h("p", { cls: "note", text: "Worst first. These are someone else's matches, not yours: a server that is bad for them can be fine for you. The lobby alert mentions a shared rating when you land on one of these for the first time. Blocking is always your choice." }));
			}
			var after = function (o) { toast(o); setTimeout(shared, 1500); };
			var btns = h("div", { cls: "actions" });
			if (s.undo) btns.appendChild(act("Undo the last import", "shareundo", null, { confirm: "Confirm: put things back", done: after }));
			if (rs.length) btns.appendChild(act("Remove shared ratings", "shareforget", null, { danger: true, confirm: "Confirm: remove them", done: after }));
			if (btns.childNodes.length) got.appendChild(btns);
			if (s.undo) got.appendChild(h("p", { cls: "note", text: "Undo puts your game names, favourites, places, ping hosts, shared ratings and thresholds back to how they were just before the last import." }));
		});
	}
	shared();
	return box;
}

var TOOLTABS = [["checks", "Checks"], ["games", "Games"], ["share", "Share"], ["data", "Data and settings"]];
// one row on the Tools page: what the tool does on the left, its control and result on the right
function tool(title, desc) {
	var body = h("div", { cls: "toolbody" }), i;
	for (i = 2; i < arguments.length; i++) if (arguments[i]) body.appendChild(arguments[i]);
	return h("section", { cls: "tool" }, h("div", { cls: "toolhead" }, h("h3", title), desc ? h("p", { cls: "note", text: desc }) : null), body);
}
function outBox() { var p = h("pre"); p.style.display = "none"; p.show = function (text) { p.textContent = text; p.style.display = "block"; }; return p; }
function needQos() {
	return h("p", { cls: "note" }, "This needs QoSmate, a separate package that prioritises traffic on OpenWrt. It is not installed on this router. ",
		h("a", { href: "https://github.com/hudra0/qosmate", target: "_blank", rel: "noopener", text: "Get QoSmate" }), ". Everything else in MatchWatch works without it.");
}
function pageTools() {
	view.textContent = ""; view.appendChild(h("h1", "Tools"));
	var i = D.info, hasQos = i.qosmate !== false;
	// four short pages instead of one long one. The tab is part of the address, so it can be linked and reloaded.
	var tab = RO ? "data" : (TOOLTABS.some(function (t) { return t[0] === pageArg; }) ? pageArg : "checks");
	if (!RO) {
		var seg = h("div", { cls: "seg" });
		TOOLTABS.forEach(function (t) { var a = h("a", { href: "#/tools/" + t[0], text: t[1] }); if (t[0] === tab) a.setAttribute("aria-current", "page"); seg.appendChild(a); });
		view.appendChild(seg);
	}
	if (!RO && tab === "checks") {
		var docOut = outBox();
		view.appendChild(tool("Check MatchWatch is working", "Confirms MatchWatch can see your device's traffic. Takes five seconds and changes nothing.",
			h("div", { cls: "actions" }, act("Run the check", "doctor", null, { solid: true, done: docOut.show })), docOut));

		var lineOut = h("div"), lineBtn = h("button", { type: "button", cls: "solid", text: "Test my line" });
		lineBtn.addEventListener("click", function () {
			lineOut.textContent = "";
			job(lineBtn, "linetest", null, "linetest.json", function (r) {
				lineOut.appendChild(h("p", { cls: "lede " + (r.verdict === "good" ? "ok" : r.verdict === "fair" ? "mid" : r.verdict === "poor" ? "low" : ""), text: r.msg }));
				var t = table([["Target"], ["Address"], ["Ping ms", "num"], ["Slowest 5% ms", "num"], ["Jitter ms", "num"], ["Lost %", "num"]]);
				(r.rows || []).forEach(function (x) { t.lastChild.appendChild(row(x.answered ? [[x.name], [x.ip], [fmt(x.med, 1), "num s"], [fmt(x.p95, 1), "num"], [fmt(x.jit, 2), "num"], [fmt(x.loss, 0), "num"]] : [[x.name], [x.ip], ["Does not answer ping", "num"], ["", "num"], ["", "num"], ["", "num"]])); });
				lineOut.appendChild(h("div", { cls: "tablewrap" }, t));
			});
		});
		view.appendChild(tool("Test your line", "Twenty seconds of pings from the router to your provider and two public servers, with no game needed. Use it before you queue to see whether your connection is steady tonight. It changes nothing.",
			h("div", { cls: "actions" }, lineBtn), lineOut));

		if (!hasQos) view.appendChild(tool("Is my game prioritised?", "Looks at whether your game's traffic is in the top priority queue. Needs QoSmate.", needQos()));
		else {
			var qosOut = outBox();
			view.appendChild(tool("Is my game prioritised?", "Looks at whether your game's traffic is in the top priority queue of QoSmate, which is installed on this router. Needs a match in progress and changes nothing.",
				h("div", { cls: "actions" }, act("Check priority", "qos", null, { done: qosOut.show })), qosOut));
		}

		view.appendChild(tool("Phone alerts", i.notify ? "Sends one message to your phone, to prove the address in Settings works." : "No phone alerts address is set yet. Add one under Alerts on the Settings tab, then use this to prove it works.",
			h("div", { cls: "actions" }, act("Send a test alert", "testalert", null, {}))));

		if (D.servers.length) {
			var sel = h("select", { "aria-label": "Server to trace" });
			D.servers.slice().sort(function (a, b) { return b.last - a.last; }).forEach(function (s) { sel.appendChild(h("option", { value: s.ip, text: s.ip + (place(s) ? ", " + place(s) : "") + " (rated " + s.rating + ")" })); });
			var trOut = h("div"), trBtn = h("button", { type: "button", text: "Trace the route now" });
			trBtn.addEventListener("click", function () {
				trOut.textContent = "";
				job(trBtn, "trace", sel.value, "trace.json", function (r) {
					if (!r.hops || !r.hops.length) { trOut.appendChild(h("p", { cls: "note", text: "No hop answered." })); return; }
					var ol = h("ol", { cls: "hops" }); r.hops.forEach(function (x) { ol.appendChild(h("li", x)); }); trOut.appendChild(ol);
					trOut.appendChild(h("p", { cls: "note", text: "Each line is one stop between your router and the server, with how long it took to answer. A star means that stop did not answer, which is common and not a fault." }));
				});
			});
			view.appendChild(tool("Route to a server", "Traces the path from your router to a server you have played on. Compare it with the route in a match report to see whether the path has changed.",
				h("div", { cls: "stayform" }, sel, trBtn), trOut));
		}

	}
	if (!RO && tab === "games") {
		var ports = [], names = {};
		D.hist.forEach(function (m) { if (m.port && ports.indexOf(m.port) < 0) { ports.push(m.port); names[m.port] = m.game || ""; } });
		if (ports.length) {
			var gsel = h("select", { "aria-label": "Game to name" });
			ports.forEach(function (p) { gsel.appendChild(h("option", { value: String(p), text: (names[p] || "Unnamed game") + " (server port " + p + ")" })); });
			var ginp = h("input", { type: "text", maxlength: "40", placeholder: "Name to show", autocomplete: "off", "aria-label": "New name for the game" });
			var gbtn = h("button", { type: "button", text: "Save name" });
			gbtn.addEventListener("click", function () {
				var v = ginp.value.replace(/[^A-Za-z0-9 .:-]/g, "").trim();
				if (!v) { ginp.focus(); return; }
				gbtn.disabled = true;
				T.act({ action: "gamename", arg: gsel.value, name: v }).then(function (j) { return j || {}; }, function () { return { ok: false }; }).then(function (j) {
					gbtn.disabled = false; toast(j.out || "That did not work.", !j.ok);
					// relabel in place: redrawing the page would wipe the results of the other tools
					if (j.ok) { gsel.options[gsel.selectedIndex].textContent = v + " (server port " + gsel.value + ")"; ginp.value = ""; refresh(true); }
				});
			});
			view.appendChild(tool("Name a game", "Games are recognised by the port their servers use. Give an unrecognised one a name and every match on that port, past and future, shows it.",
				h("div", { cls: "stayform" }, gsel, ginp, gbtn)));
		}
		// add a game by its port, before or without ever playing a match on it
		var aPort = h("input", { type: "text", maxlength: "11", placeholder: "Port, or 7000-7100", autocomplete: "off", "aria-label": "Server port or range" });
		var aName = h("input", { type: "text", maxlength: "40", placeholder: "Name of the game", autocomplete: "off", "aria-label": "Name of the game" });
		var aHost = h("input", { type: "text", maxlength: "60", placeholder: "Hosted by (optional)", autocomplete: "off", "aria-label": "Words in the name of the company hosting the servers, optional" });
		var aKind = h("select", { "aria-label": "What this port carries" }); aKind.appendChild(h("option", { value: "", text: "A game" })); aKind.appendChild(h("option", { value: "1", text: "Not a game (voice chat, a call)" }));
		var aBtn = h("button", { type: "button", cls: "solid", text: "Add" }), mine = h("div");
		var drawMine = function () {
			get("mygames.json", function (g) {
				if (page !== "tools") return;
				mine.textContent = "";
				if (!g || !g.length) { mine.appendChild(h("p", { cls: "empty", text: "You have not added or named any yet." })); return; }
				var t = table([["Name"], ["Server ports", "num"], ["Treated as"], ["Only when hosted by"], ["", ""]]);
				g.forEach(function (x) {
					var td = h("td", { cls: "act" });
					td.appendChild(act("Remove", "gamedel", x.ports, { done: function (o) { toast(o); setTimeout(drawMine, 800); } }));
					t.lastChild.appendChild(row([[x.name], [x.ports, "num"], [x.kind === "voice" ? "Not a game" : "A game"], [x.hosts || ""], td]));
				});
				mine.appendChild(h("div", { cls: "tablewrap" }, t));
			});
		};
		aBtn.addEventListener("click", function () {
			var p = aPort.value.replace(/\s/g, ""), n = aName.value.replace(/[^A-Za-z0-9 .:-]/g, "").trim(), hs = aHost.value.toLowerCase().replace(/[^a-z0-9 ,-]/g, " ").trim();
			if (!/^\d{1,5}(-\d{1,5})?$/.test(p)) { toast("Type one server port, or a range like 7000-7100.", true); aPort.focus(); return; }
			if (!n) { aName.focus(); return; }
			aBtn.disabled = true;
			T.act({ action: "gamename", arg: p, name: n, region: hs, days: aKind.value }).then(function (j) { return j || {}; }, function () { return { ok: false }; }).then(function (j) {
				aBtn.disabled = false; toast(j.out || "That did not work.", !j.ok);
				if (j.ok) { aPort.value = ""; aName.value = ""; aHost.value = ""; refresh(true); setTimeout(drawMine, 800); }
			});
		});
		view.appendChild(tool("Add a game", "Know which port a game's servers use? Add it and MatchWatch recognises the game from its first match. Use one port or a range. If the range is shared with other things, add a word from the name of the company hosting the servers (shown on the Servers page); a range over 2000 ports wide must have one.",
			h("div", { cls: "stayform" }, aPort, aName), h("div", { cls: "stayform" }, aHost, aKind, aBtn)));
		view.appendChild(tool("Your games", "Everything you have added, named or taken from a share file. These are checked before the built-in list. Removing one puts the port back to how MatchWatch treats it by default.", mine));
		drawMine();
		var skBox = h("div");
		view.appendChild(tool("Skipped as voice chat", "Voice chat is not a match, so MatchWatch does not record it and can never block it. A few games use the same ports. If a game you play is listed here, name it and MatchWatch treats that port as a game from then on.", skBox));
		get("skipped.json", function (sk) {
			if (page !== "tools") return;
			sk = (sk || []).slice().sort(function (a, b) { return b.last - a.last; });
			if (!sk.length) { skBox.appendChild(h("p", { cls: "empty", text: "Nothing has been skipped in the last six hours." })); return; }
			var t = table([["Server"], ["Port", "num"], ["Last seen"], ["If this is a game, name it"]]);
			sk.forEach(function (x) {
				var td = h("td");
				td.appendChild(nameForm(x.port, "This is a game", function (v) { td.textContent = "Now treated as a game: " + v; }));
				t.lastChild.appendChild(row([[x.ip], [String(x.port), "num"], [when(x.last)], td]));
			});
			skBox.appendChild(h("div", { cls: "tablewrap" }, t));
		});

	}
	if (!RO && tab === "share") view.appendChild(shareSection());
	if (!RO && tab === "data") {
		var dl = h("button", { type: "button", text: "Download as a spreadsheet file" });
		dl.addEventListener("click", downloadHistory); dl.disabled = !D.hist.length;
		view.appendChild(tool("Match history", D.hist.length + " match" + (D.hist.length === 1 ? "" : "es") + " on file. The download is a CSV file that opens in any spreadsheet.", h("div", { cls: "actions" }, dl)));
		view.appendChild(tool("Clear all history", "Deletes every match and the server ratings built from them. It cannot be undone. Blocks, favourites, the places you stay on and your settings are kept. It restarts MatchWatch, so do it between matches.",
			h("div", { cls: "actions" }, act("Clear all history", "clearhistory", null, { danger: true, confirm: "Confirm: delete every recorded match", done: function (o) { toast(o); setTimeout(function () { refresh(true); if (page === "tools") pageTools(); }, 2500); } }))));
		var logOut = outBox();
		view.appendChild(tool("Recent activity", "The last things MatchWatch wrote to the router's log: matches judged, servers blocked, alerts sent.",
			h("div", { cls: "actions" }, act("Show recent activity", "log", null, { done: function (o) { logOut.show(o || "Nothing logged yet."); } })), logOut));

		view.appendChild(h("h2", "QoSmate priority"));
		if (!hasQos) view.appendChild(tool("Prioritise my game traffic", "Puts your gaming device's traffic in the top priority queue. Needs QoSmate.", needQos()));
		else {
			var fixOut = outBox();
			view.appendChild(tool("Prioritise my game traffic", "QoSmate is installed on this router. Use this if \"Is my game prioritised?\" says your game is not reaching the top queue. It adds two QoSmate rules that mark all UDP to and from your gaming device, except web ports, as top priority. It restarts QoSmate, which causes a brief blip, so do it between matches. Remove takes the two rules out again.",
				h("div", { cls: "actions" }, act("Add the rules", "qosfix", null, { confirm: "Confirm: add the rules and restart QoSmate", done: fixOut.show }), act("Remove the rules", "qosunfix", null, { confirm: "Confirm: remove and restart QoSmate", done: fixOut.show })), fixOut));
		}
	}
	if (tab !== "data") return;
	view.appendChild(h("h2", "Settings in use"));
	view.appendChild(kv([["Version", i.version || "n/a"], ["Watching", i.device || "Every device on the LAN"], ["Staying on", i.stay ? i.stay : "Nowhere in particular"],
		["Blocks last", (i.block_days || 14) + " days"], ["Automatic blocking", i.autoblock ? "On" : "Off"], ["Phone notifications", i.notify ? "On" : "Off"], ["Your PC counts towards scores", i.pc_score === false ? "No" : "Yes"], ["Server location lookups", i.geo === false ? "Off" : "On"],
		["This dashboard without login", i.web ? "On, view only" : "Off"]]));
	if (RO) view.appendChild(h("p", { cls: "note", text: "This page is view only. To block servers, run checks or change settings, log in to the router and open Services, then MatchWatch." }));
	else if (T.settings) view.appendChild(h("p", { cls: "note" }, "Change these, and the device to watch, on the ", h("a", { href: T.settings, text: "Settings tab" }), "."));
}

// ---------- routing and refresh
function route(keep) { // keep === true: a redraw with fresh data, so stay where the reader is
	var parts = (location.hash || "#/").replace(/^#\/?/, "").split("/");
	page = parts[0] || "live"; pageArg = parts[1] || "";
	if (["live", "match", "matches", "servers", "tools"].indexOf(page) < 0) page = "live";
	Array.prototype.forEach.call(shadow.querySelectorAll("nav a"), function (a) { if (a.getAttribute("data-p") === page) a.setAttribute("aria-current", "page"); else a.removeAttribute("aria-current"); });
	pageMatch.repaint = null;
	if (page === "live") pageLive(); else if (page === "match") pageMatch(pageArg || "last"); else if (page === "matches") pageMatches(); else if (page === "servers") pageServers(); else pageTools();
	if (keep !== true) window.scrollTo(0, 0);
}
function setState() {
	var e = shadow.getElementById("state"), st = D.st, s = session();
	if (!st) { e.className = ""; e.textContent = "Can't read data from the router"; }
	else if (!st.ts || Date.now() / 1000 - st.ts > 20) { e.className = ""; e.textContent = "The matchwatch service is not running"; }
	else if (s) { e.className = "on"; e.textContent = "In a match, " + mins(s.age); }
	else { e.className = ""; e.textContent = "Waiting for a match"; }
}
function tick() { get("status.json", function (st) { D.st = st; setState(); updateLive(); }); get("lobby.json", function (l) { D.lobby = l; }); }
// half-typed text in a box would be wiped by a redraw
function typing() { return Array.prototype.some.call(shadow.querySelectorAll("#place, input.keep, textarea.keep"), function (i) { return !!i.value; }); }
function refresh(force) {
	get("regions.json", function (x) { D.regions = x || []; });
	var left = 6, done = function () { if (--left === 0 && (force || (!armed && !typing())) && page !== "live" && page !== "match" && page !== "tools") route(true); else if (left === 0 && page === "live") { L.ip = null; updateLive(); } };
	get("history.json", function (x) { D.hist = x || []; done(); });
	get("servers.json", function (x) { D.servers = x || []; done(); });
	get("datacentres.json", function (x) { D.dcs = x || []; done(); });
	get("blocklist.json", function (x) { D.blocks = x || []; done(); });
	get("info.json", function (x) { D.info = x || {}; done(); });
	get("favourites.json", function (x) { setFavs(x); done(); });
}
window.addEventListener("hashchange", route);
window.addEventListener("resize", function () { updateLive(); if (page === "match" && pageMatch.repaint) pageMatch.repaint(); });
var first = 6, boot = function () { if (--first === 0) route(); };
get("history.json", function (x) { D.hist = x || []; boot(); }); get("servers.json", function (x) { D.servers = x || []; boot(); }); get("datacentres.json", function (x) { D.dcs = x || []; boot(); });
get("blocklist.json", function (x) { D.blocks = x || []; boot(); }); get("info.json", function (x) { D.info = x || {}; boot(); }); get("favourites.json", function (x) { setFavs(x); boot(); });
get("regions.json", function (x) { D.regions = x || []; });
tick(); setInterval(tick, 1000); setInterval(function () { setDark(); refresh(false); }, 15000);
};
