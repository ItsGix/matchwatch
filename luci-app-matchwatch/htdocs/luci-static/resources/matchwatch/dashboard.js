// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 ItsGix and the MatchWatch contributors
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
	'<a id="upd" href="#/tools/data" style="display:none"></a><span id="state">Connecting to the router</span></header><main id="view"></main><div id="toast" role="status" aria-live="polite"></div>';
shadow.appendChild(sheet); shadow.appendChild(wrap);
var RO = !!T.readonly;
function setDark() { wrap.classList.toggle("dark", T.dark ? !!T.dark() : !!(window.matchMedia && matchMedia("(prefers-color-scheme: dark)").matches)); }
setDark(); sheet.addEventListener("load", function () { setDark(); updateLive(); });
var D = { st: null, hist: [], servers: [], dcs: [], blocks: [], info: {}, lobby: null, regions: [], favs: [], favInfo: {}, gp: [], cov: null, hold: [], mm: null };
var page = "", pageArg = "", armed = 0, view = shadow.getElementById("view");
// The version this file belongs to (build.py checks it matches the program's). When the router reports
// another, MatchWatch has been updated under this page: the browser's stored copies of the dashboard
// files are fetched afresh, which replaces them, and the page reloads itself. Without this an updated
// router kept showing the old dashboard until the browser happened to let go of it.
var BUILT = "0.31.1", reloading = false;
function freshReload() {
	var urls = {}, go = function () { location.reload(); };
	try { performance.getEntriesByType("resource").forEach(function (e) { if (/\/matchwatch\/[^?]*\.(js|css)(\?|$)/.test(e.name)) urls[e.name] = 1; }); } catch (e) {}
	setTimeout(go, 5000);
	Promise.all(Object.keys(urls).map(function (u) { return fetch(u, { cache: "reload", credentials: "same-origin" }).then(null, function () {}); })).then(go, go);
}
function versionSeen(v) {
	var done = null;
	if (!v || v === BUILT || reloading) return;
	try { done = sessionStorage.getItem("mw-reloaded"); } catch (e) {}
	if (done === v) return;                       // already tried once for this version: never loop
	try { sessionStorage.setItem("mw-reloaded", v); } catch (e) { return; }
	reloading = true;
	toast("MatchWatch was updated to " + v + ". Loading the new version.");
	setTimeout(freshReload, 1500);
}

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
	var p = { action: action }, m = /region=([^&]*)/.exec(extra || ""), nm = /name=([^&]*)/.exec(extra || "");
	if (arg != null) p.arg = String(arg);
	if (m) p.region = m[1].replace(/\+/g, " ");
	if (nm) p.name = nm[1];
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

// ---------- where each game plays: learned from your matches, from servers the game tried, and from share files
var gpGame = "", gpAll = false;
function gamePlacesSection() {
	var box = h("div");
	box.appendChild(h("h2", "Where each game plays"));
	var rows = D.gp || [];
	if (!rows.length) { box.appendChild(h("p", { cls: "empty", text: "Nothing learned yet. Each match, and each server a game tries, adds to this. Share files from other players add the rest of the world." })); return box; }
	var games = []; rows.forEach(function (r) { if (games.indexOf(r.game) < 0) games.push(r.game); }); games.sort();
	if (games.indexOf(gpGame) < 0) gpGame = "";
	var staying = (D.info.stays || []).length > 0;
	if (games.length > 1) {
		var sel = h("select", { "aria-label": "Show one game" }); sel.appendChild(h("option", { value: "", text: "Every game" }));
		games.forEach(function (g) { var o = h("option", { value: g, text: g }); if (g === gpGame) o.selected = true; sel.appendChild(o); });
		sel.addEventListener("change", function () { var y = window.scrollY; gpGame = sel.value; gpAll = false; pageServers(); window.scrollTo(0, y); });
		box.appendChild(h("div", { cls: "stayform" }, sel));
	}
	var list = rows.filter(function (r) { return !gpGame || r.game === gpGame; }).sort(function (a, b) { return a.game < b.game ? -1 : a.game > b.game ? 1 : (b.matches - a.matches) || (b.networks - a.networks); });
	var heads = [["Game"], ["Where"], ["Hosted by"], ["Server networks", "num"], ["Matches", "num"], ["Rating", "num"], ["Known from"]];
	if (staying) heads.push(["In your places"]);
	var t = table(heads);
	(gpAll ? list : list.slice(0, 12)).forEach(function (r) {
		var net = h("td", { cls: "num", text: String(r.networks) }); net.title = (r.nets || []).join(", ") + (r.networks > (r.nets || []).length ? " and more" : "");
		var cells = [[r.game], [place(r) || "Place not known"], [r.org || ""], net, [r.matches ? String(r.matches) : "", "num"], [r.rating == null ? "" : String(r.rating), "num s " + cls(r.rating)], [r.mine ? (r.matches ? "Your matches" : "Tried by the game") : "Shared with you"]];
		if (staying) cells.push([r.in == null ? "Not known" : r.in ? "Yes" : "No"]);
		t.lastChild.appendChild(row(cells));
	});
	box.appendChild(h("div", { cls: "tablewrap" }, t));
	var btns = h("div", { cls: "actions" });
	if (list.length > 12) { var more = h("button", { type: "button", text: gpAll ? "Show fewer" : "Show all " + list.length }); more.addEventListener("click", function () { var y = window.scrollY; gpAll = !gpAll; pageServers(); window.scrollTo(0, y); }); btns.appendChild(more); }
	if (rows.some(function (r) { return !r.mine; })) btns.appendChild(act("Remove what others shared", "shareforgetgs", null, { danger: true, confirm: "Confirm: remove shared game servers" }));
	if (btns.childNodes.length) box.appendChild(btns);
	box.appendChild(h("p", { cls: "note", text: "One row per game and place. A server network is a block of 256 addresses; hover the number to see them. Your own router only learns the places a game offers you, which are mostly near home. To learn the rest of the world, take in share files from players elsewhere, and pass yours on from Tools, Share." }));
	return box;
}
// for a game with no published host list: is anything known for it inside the places being stayed on?
function gameCoverNotes() {
	var by = {}, out = [];
	(D.gp || []).forEach(function (r) { var g = by[r.game] || (by[r.game] = { inn: 0, places: [] }); if (r.in) g.inn++; else { var p = place(r); if (p && g.places.indexOf(p) < 0) g.places.push(p); } });
	Object.keys(by).sort().forEach(function (g) { if (!by[g].inn && by[g].places.length) out.push(g + ": no server known in your places. Known in " + by[g].places.slice(0, 5).join("; ") + (by[g].places.length > 5 ? " and " + (by[g].places.length - 5) + " more" : "") + "."); });
	return out;
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
// One server let through the places being stayed on. Offered while staying; shown as a tag once it is in.
function isAllowed(ip) { return (D.info.allowed || []).indexOf(ip) >= 0; }
function allowBtn(ip) {
	if (isAllowed(ip)) return h("span", { cls: "tag keep", title: "Let through the places you stay on. Remove it under the places, at the top of the Servers page.", text: "In the pool" });
	if (RO || !(D.info.stays || []).length) return null;
	// already inside the places being stayed on: nothing to add, and a button that does nothing misleads
	var known = D.servers.filter(function (x) { return x.ip === ip; })[0];
	if (known && known["in"] === true) return h("span", { cls: "kept", title: "This server is inside the places you stay on, so it is already allowed.", text: "In your places" });
	var b = act("Add to pool", "allow", ip, {});
	b.title = "Let this one server through, whatever region it is in";
	return b;
}
function addIf(parent, el) { if (el) parent.appendChild(el); }
// ---------- the map: the places you stay on as circles you can draw and move, and every server by how it rated
// The map is built once and kept: a page redraw puts the same element back, so it keeps its zoom and does not flicker.
var MAP = { box: null, lf: null, map: null, layers: null, circles: {}, busy: false, loading: false, fitted: false, edit: [] };
function cssVar(n) { return getComputedStyle(wrap).getPropertyValue(n).trim() || "#888"; }
function getHome() { try { var v = (localStorage.getItem("mw-home") || "").split(","); if (v.length === 2 && !isNaN(+v[0]) && !isNaN(+v[1])) return [+v[0], +v[1]]; } catch (e) {} return null; }
function leaflet(then) {
	if (MAP.lf) { then(); return; }
	if (MAP.loading) return;
	MAP.loading = true;
	var base = String(T.css || ""), link = document.createElement("link");
	link.rel = "stylesheet"; link.href = base.replace("dashboard.css", "leaflet.css"); shadow.insertBefore(link, sheet);
	fetch(base.replace("dashboard.css", "leaflet.js"), { credentials: "same-origin" }).then(function (r) { if (!r.ok) throw 0; return r.text(); }).then(function (src) {
		// LuCI keeps its own code in a global called L, and Leaflet claims the same name. Run Leaflet, take what it made, and put LuCI's back at once.
		var had = Object.prototype.hasOwnProperty.call(window, "L"), keep = window.L, made = null;
		try { (new Function(src)).call(window); made = window.L; } finally { if (had) window.L = keep; else { try { delete window.L; } catch (e) { window.L = undefined; } } }
		if (!made || made === keep || !made.map || !made.tileLayer) throw 0;
		MAP.lf = made; MAP.loading = false; then();
	}).then(null, function () { MAP.loading = false; if (MAP.legend) MAP.legend.textContent = "The map could not be loaded. Everything on it is also in the tables below."; });
}
function mapSection() {
	if (!MAP.box) {
		MAP.el = h("div", { cls: "map" });
		MAP.tools = h("div", { cls: "maptools" });
		MAP.bar = h("div", { cls: "mapbar" }); MAP.bar.style.display = "none";
		MAP.legend = h("div", null, h("p", { cls: "note", text: "Loading the map..." }));
		MAP.box = h("div", { cls: "mapbox" }, MAP.tools, MAP.el, MAP.bar, MAP.legend);
	}
	leaflet(function () { setTimeout(mapSync, 0); });
	return MAP.box;
}
function mapBar(text, buttons) {
	MAP.bar.textContent = "";
	if (!text) { MAP.bar.style.display = "none"; return; }
	MAP.bar.style.display = "";
	MAP.barText = h("p", text); MAP.bar.appendChild(MAP.barText);
	(buttons || []).forEach(function (b) { var el = h("button", { type: "button", cls: b[1] || "", text: b[0] }); el.addEventListener("click", b[2]); MAP.bar.appendChild(el); });
}
function mapDone(again) {
	MAP.edit.forEach(function (l) { try { MAP.map.removeLayer(l); } catch (e) {} }); MAP.edit = [];
	MAP.map.dragging.enable(); MAP.el.classList.remove("drawing");
	MAP.busy = false; mapBar(null);
	if (again) refresh(true); else mapSync();
}
function mapSend(action, arg) {
	Array.prototype.forEach.call(MAP.bar.querySelectorAll("button"), function (b) { b.disabled = true; });
	api(action, arg).then(function (j) {
		toast(j.out || j.error || "That did not work.", !j.ok);
		mapDone(j.ok);
	});
}
function insideCount(c, km) { var n = 0, t = 0; D.servers.forEach(function (s) { if (s.lat == null) return; t++; if (c.distanceTo([s.lat, s.lon]) <= km * 1000) n++; }); return t ? n + " of the " + t + " server" + (t === 1 ? "" : "s") + " you have played on " + (n === 1 ? "is" : "are") + " inside." : ""; }
function geoArg(c, km) { c = c.wrap(); return c.lat.toFixed(3) + "/" + c.lng.toFixed(3) + "/" + km; }
function mapDraw() {
	var LF = MAP.lf, map = MAP.map, c0 = null, circ = null, pen = cssVar("--pen");
	if (MAP.busy) return;
	MAP.busy = true; map.dragging.disable(); map.closePopup(); MAP.el.classList.add("drawing");
	var touch = !!(window.matchMedia && matchMedia("(pointer: coarse)").matches);
	mapBar(touch ? "Tap where the middle of the circle should be, then tap where its edge should be." : "Press where the middle of the circle should be, drag outwards, and let go.", [["Cancel", "", function () { off(); mapDone(); }]]);
	if (touch) map.dragging.enable();
	function tap(e) { if (!circ) { down(e); return; } move(e); up(); }
	function down(e) { c0 = e.latlng; circ = LF.circle(c0, { radius: 25000, color: pen, weight: 2, dashArray: "6 6", fillColor: pen, fillOpacity: 0.15, interactive: false }).addTo(map); MAP.edit.push(circ); }
	function move(e) { if (circ) circ.setRadius(Math.max(25000, c0.distanceTo(e.latlng))); }
	function up() {
		if (!circ) return;
		off();
		var km = Math.min(3000, Math.max(25, Math.round(circ.getRadius() / 1000)));
		circ.setRadius(km * 1000); MAP.el.classList.remove("drawing"); map.dragging.enable();
		var some = (D.info.stays || []).length;
		mapBar("A circle of " + km + " km. " + insideCount(c0, km) + (some ? "" : " Staying inside it turns away game servers everywhere else."),
			[[some ? "Add to the pool" : "Stay inside this circle", "solid", function () { mapSend("staycircle", geoArg(c0, km)); }], ["Cancel", "", function () { mapDone(); }]]);
	}
	function off() { map.off("click", tap); map.off("mousedown", down); map.off("mousemove", move); map.off("mouseup", up); document.removeEventListener("mouseup", up); }
	if (touch) map.on("click", tap);
	else { map.on("mousedown", down); map.on("mousemove", move); map.on("mouseup", up); document.addEventListener("mouseup", up); }
}
// move or resize one circle of the pool: a grip in the middle and one on the edge
function mapEdit(p) {
	var LF = MAP.lf, map = MAP.map, pen = cssVar("--pen");
	if (MAP.busy || RO) return;
	MAP.busy = true; map.closePopup();
	if (MAP.circles[p.n]) MAP.layers.removeLayer(MAP.circles[p.n]);
	var c = LF.latLng(p.lat, p.lon), km = p.km;
	var edgeOf = function () { return LF.latLng(c.lat, c.lng + km / (111.32 * Math.max(0.2, Math.cos(c.lat * Math.PI / 180)))); };
	var circ = LF.circle(c, { radius: km * 1000, color: pen, weight: 2, dashArray: "6 6", fillColor: pen, fillOpacity: 0.15, interactive: false }).addTo(map);
	var grip = function (title) { return LF.divIcon({ className: "", html: '<span class="pin grip"></span>', iconSize: [18, 18], iconAnchor: [9, 9] }); };
	var mid = LF.marker(c, { icon: grip(), draggable: true, title: "Drag to move the circle", zIndexOffset: 1000 }).addTo(map);
	var edge = LF.marker(edgeOf(), { icon: grip(), draggable: true, title: "Drag to make the circle larger or smaller", zIndexOffset: 1000 }).addTo(map);
	MAP.edit.push(circ, mid, edge);
	var say = function () { if (MAP.barText) MAP.barText.textContent = p.name + ": now " + km + " km. " + insideCount(c, km) + " Drag the middle to move it, or the edge to resize it."; };
	mid.on("drag", function () { c = mid.getLatLng(); circ.setLatLng(c); edge.setLatLng(edgeOf()); say(); });
	edge.on("drag", function () { km = Math.min(3000, Math.max(25, Math.round(c.distanceTo(edge.getLatLng()) / 1000))); circ.setRadius(km * 1000); say(); });
	edge.on("dragend", function () { edge.setLatLng(edgeOf()); });
	mapBar(p.name, [["Save", "solid", function () { mapSend("stayset", p.n + "/" + geoArg(c, km)); }], ["Remove from the pool", "danger", function () { mapSend("stayrm", p.n); }], ["Cancel", "", function () { mapDone(); }]]);
	say();
}
function spotPopup(list) {
	var s0 = list[0], box = h("div", { cls: "spot" }, h("b", place(s0) || "Unknown place"), s0.org && s0.org !== "-" ? h("small", s0.org) : null);
	list.slice().sort(function (a, b) { return b.rating - a.rating; }).slice(0, 8).forEach(function (s) {
		var a = h("div", { cls: "actions" });
		a.appendChild(star(s.ip));
		if (s.blocked) a.appendChild(h("span", { cls: "tag", text: "Blocked" })); else { addIf(a, allowBtn(s.ip)); a.appendChild(act("Block", "block", s.ip, { danger: true, confirm: "Confirm: " + (D.info.block_days || 14) + " days" })); }
		box.appendChild(h("div", { cls: "spotrow" }, h("span", null, h("b", { cls: "s " + cls(s.rating), text: String(s.rating) }), " " + s.ip, h("small", s.matches + " match" + (s.matches === 1 ? "" : "es") + (s.ping == null ? "" : ", " + fmt(s.ping, 0) + " ms"))), a));
	});
	if (list.length > 8) box.appendChild(h("small", "And " + (list.length - 8) + " more, in the table below."));
	return box;
}
function mapSync() {
	var LF = MAP.lf;
	if (!LF || !MAP.box || !MAP.box.isConnected) return;
	if (!MAP.map) {
		MAP.map = LF.map(MAP.el, { worldCopyJump: true, minZoom: 2, zoomSnap: 0.5 });
		LF.tileLayer("https://tile.openstreetmap.org/{z}/{x}/{y}.png", { maxZoom: 12, attribution: '&copy; <a href="https://www.openstreetmap.org/copyright" target="_blank" rel="noopener">OpenStreetMap</a> contributors' }).addTo(MAP.map);
		MAP.map.setView([35, 5], 2);
		MAP.layers = LF.layerGroup().addTo(MAP.map);
		var fit = h("button", { type: "button", text: "Show everything" });
		fit.addEventListener("click", function () { MAP.fitted = false; mapSync(); });
		if (!RO) {
			var draw = h("button", { type: "button", cls: "solid", text: "Draw a circle" });
			draw.addEventListener("click", mapDraw);
			var home = h("button", { type: "button", text: "Set home" });
			home.addEventListener("click", function () {
				if (MAP.busy) return;
				MAP.busy = true; MAP.el.classList.add("drawing");
				var pick = function (e) { var c = e.latlng.wrap(); try { localStorage.setItem("mw-home", c.lat.toFixed(2) + "," + c.lng.toFixed(2)); } catch (x) {} mapDone(); };
				MAP.map.once("click", pick);
				mapBar("Press roughly where you are. It is only remembered by this browser, to draw you on the map.", [["Cancel", "", function () { MAP.map.off("click", pick); mapDone(); }]]);
			});
			MAP.tools.appendChild(draw); MAP.tools.appendChild(home);
		}
		MAP.tools.appendChild(fit);
	}
	MAP.map.invalidateSize();
	if (MAP.busy) return;
	var g = MAP.layers, ok = cssVar("--ok"), muted = cssVar("--muted"), pen = cssVar("--pen"), b = LF.latLngBounds([]), pool = D.info.pool || [], whole = [];
	g.clearLayers(); MAP.circles = {};
	pool.forEach(function (p) {
		if (p.lat == null) { whole.push(p.name); return; }
		var c = LF.circle([p.lat, p.lon], { radius: p.km * 1000, color: ok, weight: 2, fillColor: ok, fillOpacity: 0.16 }).addTo(g);
		c.bindTooltip(p.name + (RO ? "" : ". Press to move or resize"), { sticky: true });
		if (!RO) c.on("click", function (e) { LF.DomEvent.stop(e); mapEdit(p); });
		MAP.circles[p.n] = c; b.extend(c.getBounds());
	});
	(D.regions || []).forEach(function (r) {
		if (r.lat == null) return;
		LF.circleMarker([r.lat, r.lon], { radius: 4, color: muted, weight: 1.5, fillColor: muted, fillOpacity: 0.15 }).addTo(g)
			.bindTooltip(r.city + ", " + r.cc + (r.ping == null ? ": no reply" : ": " + fmt(r.ping, 0) + " ms, grade " + pingLetter(r.ping)));
	});
	(D.gp || []).forEach(function (x) {
		if (x.lat == null || x.mine) return;
		LF.circleMarker([x.lat, x.lon], { radius: 3, color: pen, weight: 1, fillColor: pen, fillOpacity: 0.7 }).addTo(g).bindTooltip("Shared with you: " + x.game + ", " + place(x));
	});
	var spots = {};
	D.servers.forEach(function (s) { if (s.lat == null || s.lon == null) return; var k = s.lat.toFixed(1) + "," + s.lon.toFixed(1); (spots[k] = spots[k] || []).push(s); });
	Object.keys(spots).forEach(function (k) {
		var list = spots[k], n = list.length, sum = 0, out = 0;
		list.forEach(function (s) { sum += s.rating; if (s["in"] === false && !isAllowed(s.ip)) out++; });
		var avg = Math.round(sum / n);
		var m = LF.marker([list[0].lat, list[0].lon], { title: (place(list[0]) || "Server") + ": rated " + avg + (n > 1 ? " over " + n + " servers" : ""),
			icon: LF.divIcon({ className: "", html: '<span class="pin ' + cls(avg) + (out === n ? " out" : "") + '">' + (n > 1 ? n : "") + "</span>", iconSize: [26, 26], iconAnchor: [13, 13] }) }).addTo(g);
		m.bindPopup(function () { return spotPopup(list); }, { maxWidth: 360, minWidth: 250 });
		b.extend(m.getLatLng());
	});
	var hm = getHome(), live = D.st && D.st.sessions && D.st.sessions[0];
	if (hm) {
		LF.marker(hm, { title: "Home", interactive: false, icon: LF.divIcon({ className: "", html: '<span class="pin home">⌂</span>', iconSize: [26, 26], iconAnchor: [13, 13] }) }).addTo(g);
		b.extend(hm);
		var ls = live && D.servers.filter(function (s) { return s.ip === live.ip && s.lat != null; })[0];
		if (ls) LF.polyline([hm, [ls.lat, ls.lon]], { color: pen, weight: 2, dashArray: "4 6" }).addTo(g).bindTooltip("The match in progress");
	}
	if (!MAP.fitted && b.isValid() && MAP.map.getSize().x > 50) { MAP.map.fitBounds(b.pad(0.2), { maxZoom: 6, animate: false }); MAP.fitted = true; }
	MAP.legend.textContent = ""; MAP.legend.appendChild(brief("Green circles are the places you stay on" + (RO ? "" : "; press one to move, resize or remove it") + ". Round markers are servers you have played on, coloured by how they rated; a number means several in one city, and a faded one is outside your places. Small hollow dots are datacentre regions with their ping."
		+ (whole.length ? " Also in the pool, but not drawn because they are whole countries or areas: " + whole.join(", ") + "." : "") + " The map pictures come from OpenStreetMap, fetched by your browser."));
}
// Strict, per game: hold every new server of a game until it has been placed. Offered for the games you have
// played, and only where the game's ports are not shared with voice chat.
var allGames = false;
function strictSection() {
	if (RO) return null;
	var played = {}, rows = [], more = 0;
	D.hist.forEach(function (m) { if (m.game) played[m.game] = 1; });
	(D.hold || []).forEach(function (g) { if (g.on || played[g.name] || allGames) rows.push(g); else more++; });
	if (!rows.length && !more) return null;
	var staying = (D.info.stays || []).length, box = h("div", null, h("h2", "How each game is filtered"));
	box.appendChild(brief("A game MatchWatch knows by its port and by who hosts it is filtered from the first server it tries. One it knows by port alone is only filtered on ports and address blocks where you have played a match, because other things use those ports too. Make a game strict and every new server on its ports is held for a moment and judged before it can connect, whichever kind it is. All of this applies to your gaming device only." + (staying ? "" : " It only does anything while you are staying on places.")));
	var t = table([["Game"], ["Server ports"], ["Servers outside your places"], ["", ""]]);
	rows.forEach(function (g) {
		var td = h("td", { cls: "act" });
		if (g.on) { td.appendChild(h("span", { cls: "tag keep", text: staying ? "Strict" : "Strict when you stay" })); td.appendChild(act("Stop", "holdoff", null, { extra: "&name=" + g.name })); }
		else if (!g.ok) td.appendChild(h("span", { cls: "kept", title: "Most of its ports are also used by voice chat, and holding them would hold the start of a call.", text: "Shares its ports with voice chat" }));
		else td.appendChild(act("Make strict", "holdon", null, { extra: "&name=" + g.name }));
		t.lastChild.appendChild(row([[g.name], [g.ports.replace(/ /g, ", ")], [g.on ? "Held, then turned away before they connect" : g.host ? "Turned away from the first one" : "Turned away once you have played a match there"], td]));
	});
	if (rows.length) box.appendChild(h("div", { cls: "tablewrap" }, t));
	// every other game MatchWatch recognises: worth a look before the first match of a new one
	if (more || allGames) {
		var tog = h("button", { type: "button", text: allGames ? "Show only games I have played" : "Show all " + (rows.length + more) + " games" });
		tog.addEventListener("click", function () { var y = window.scrollY; allGames = !allGames; pageServers(); window.scrollTo(0, y); });
		box.appendChild(h("div", { cls: "actions" }, tog));
		if (!allGames) box.appendChild(h("p", { cls: "note", text: (rows.length ? "These are the games you have played. " : "") + "About to play something new? Show all games to see how it will be filtered, and make it strict before your first match if it is one that needs a match first." }));
	}
	return box;
}
function waitWords(s) { return !s ? "as soon as a match ends" : (s < 90 ? s + " seconds" : Math.round(s / 60) + " minutes") + " after a match ends"; }
// Match mode in a sentence: what QoSmate's speed limit is doing right now
function mbit(k) { return k >= 1000 ? fmt(k / 1000, k % 1000 ? 1 : 0) + " Mbit" : k + " kbit"; }
function mmLine() {
	var m = D.mm;
	if (!m || !m.on) return "";
	if (m.state === "unsupported") return "Match mode is on but cannot work: it needs QoSmate switched on, in one of its cake modes.";
	var od = m.on_down || m.down, ou = m.on_up || m.up, lim = function (k) { return k ? mbit(k) : "no limit"; };
	if (m.state === "loose") return "Match mode: nothing is being played, so the between-matches speeds apply (" + (m.off_down || m.off_up ? lim(m.off_down) + " down, " + lim(m.off_up) + " up" : "no limit") + "). The speeds for playing come back the moment a match starts.";
	return "Match mode: the speeds for playing are on, " + mbit(od) + " down and " + mbit(ou) + " up, with QoSmate keeping your game ahead of everything else. The between-matches speeds apply " + waitWords(m.hold) + ".";
}
// The speeds match mode switches between: a box to type in and a slider for each, kept in step.
// A slider works in percent of QoSmate's own rate, which is the one figure both sides can be measured against.
function mmSpeeds(mm, again) {
	var own = { down: mm.down || 0, up: mm.up || 0 }, val = {}, box = h("div", { cls: "speeds" });
	if (!own.down || !own.up) { box.appendChild(h("p", { cls: "note", text: "QoSmate's own download and upload rates could not be read, so speeds cannot be chosen here yet." })); return box; }
	function one(key, dir, label, lo, hi, start) {
		var base = own[dir];
		var num = h("input", { type: "number", min: "0.1", step: "0.1", inputmode: "decimal", "aria-label": label + ", megabits per second" });
		var rng = h("input", { type: "range", min: String(lo), max: String(hi), step: "1", "aria-label": label + ", percent of QoSmate's rate" });
		var pct = h("small");
		var show = function (kbit, from) {
			val[key] = kbit;
			var p = Math.round(100 * kbit / base);
			if (from !== "num") num.value = kbit ? String(Math.round(kbit / 100) / 10) : "";
			if (from !== "rng") rng.value = String(Math.min(hi, Math.max(lo, p)));
			pct.textContent = kbit ? p + "% of QoSmate's " + mbit(base) : "Type a speed";
		};
		num.addEventListener("input", function () { var v = parseFloat(num.value); show(v > 0 ? Math.round(v * 1000) : 0, "num"); });
		rng.addEventListener("input", function () { show(Math.round(base * rng.value / 100), "rng"); });
		show(start);
		return h("div", { cls: "speed" }, h("span", { cls: "dir", text: label }), h("span", { cls: "numwrap" }, num, h("i", "Mbit")), rng, pct);
	}
	var play = h("div", { cls: "speedcard" }, h("b", "While you play"), h("small", "QoSmate holds your line to these and keeps the game in front."),
		one("on_down", "down", "Download", 5, 100, mm.on_down || own.down), one("on_up", "up", "Upload", 5, 100, mm.on_up || own.up));
	var limited = !!(mm.off_down || mm.off_up);
	var none = h("button", { type: "button", text: "No limit" }), some = h("button", { type: "button", text: "Choose speeds" });
	var rows = h("div", null, one("off_down", "down", "Download", 50, 200, mm.off_down || own.down), one("off_up", "up", "Upload", 50, 200, mm.off_up || own.up));
	var hint = h("small");
	var pick = function (lim) {
		limited = lim; rows.style.display = lim ? "" : "none";
		none.setAttribute("aria-pressed", lim ? "false" : "true"); some.setAttribute("aria-pressed", lim ? "true" : "false");
		hint.textContent = lim ? "Still limited, but at these speeds: a little under your line's real speed keeps downloads from making calls and video stutter." : "Your line runs flat out. The fastest downloads, with nothing held back.";
	};
	none.addEventListener("click", function () { pick(false); }); some.addEventListener("click", function () { pick(true); });
	// how soon after a match the between-matches speeds take over
	var hold = mm.hold == null ? 30 : mm.hold, waits = [[0, "At once"], [30, "30 seconds"], [120, "2 minutes"], [300, "5 minutes"]], wbox = h("div", { cls: "choice", role: "group", "aria-label": "How soon after a match" }), whint = h("small");
	if (!waits.some(function (w) { return w[0] === hold; })) waits.push([hold, waitWords(hold).replace(" after a match ends", "")]);
	var setWait = function (s) {
		hold = s;
		Array.prototype.forEach.call(wbox.children, function (b) { b.setAttribute("aria-pressed", +b.getAttribute("data-s") === s ? "true" : "false"); });
		whint.textContent = s === 0 ? "The moment MatchWatch sees the match has ended. If you queue again straight away, the speeds for playing come back as the next match starts." : (s <= 30 ? "A short wait, so a quick requeue does not flip the speeds back and forth." : "Long enough to cover the gap between matches, so a run of them stays at the speeds for playing.");
	};
	waits.forEach(function (w) { var b = h("button", { type: "button", text: w[1], "data-s": String(w[0]) }); b.addEventListener("click", function () { setWait(w[0]); }); wbox.appendChild(b); });
	var rest = h("div", { cls: "speedcard" }, h("b", "Between matches"), h("div", { cls: "choice", role: "group", "aria-label": "Between matches" }, none, some), hint, rows,
		h("span", { cls: "dir after", text: "Switch to these after a match" }), wbox, whint);
	setWait(hold);
	pick(limited);
	var save = h("button", { type: "button", cls: "solid", text: "Save these speeds" }), reset = h("button", { type: "button", text: "Back to QoSmate's own" });
	var send = function (arg, btn) {
		btn.disabled = true;
		api("matchmodeset", arg).then(function (j) { btn.disabled = false; if (!j.ok) { toast(j.out || j.error || "That did not work.", true); return; } again(j.out); });
	};
	save.addEventListener("click", function () {
		var k = function (key, dir) { var v = val[key] || 0; return v === own[dir] && key.indexOf("on_") === 0 ? 0 : v; };   // QoSmate's own rate is stored as "follow QoSmate"
		if (!val.on_down || !val.on_up || (limited && (!val.off_down || !val.off_up))) { toast("Type a speed in every box first.", true); return; }
		send([k("on_down", "down"), k("on_up", "up"), limited ? val.off_down : 0, limited ? val.off_up : 0, hold].join("/"), save);
	});
	reset.addEventListener("click", function () { send("0/0/0/0/30", reset); });
	box.appendChild(h("div", { cls: "speedgrid" }, play, rest));
	box.appendChild(h("div", { cls: "actions" }, save, reset));
	return box;
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
				if (s.blocked || isBlocked(s.ip)) td.appendChild(h("span", { cls: "tag", text: "Blocked" })); else addIf(td, allowBtn(s.ip));
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
	L.marks = h("div"); L.actions = h("div", { cls: "actions" }); L.last = h("div"); L.mm = h("p", { cls: "note" });
	L.felt.addEventListener("click", felt);
	var np = namePrompt(function () { if (page === "live") pageLive(); });
	if (np) view.appendChild(np);
	view.appendChild(L.banner); view.appendChild(L.title); view.appendChild(L.sub);
	view.appendChild(h("div", { cls: "strip" }, L.cv, legend()));
	view.appendChild(L.figs);
	view.appendChild(h("div", { cls: "actions" }, L.felt)); view.appendChild(L.note); view.appendChild(L.marks); view.appendChild(L.actions); view.appendChild(L.mm); view.appendChild(L.last);
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
		if (lb.strictname && /^[A-Za-z0-9 .:-]{1,40}$/.test(lb.strictname) && (D.hold || []).some(function (g) { return g.name === lb.strictname && g.ok && !g.on; })) bn.appendChild(act("Make " + lb.strictname + " strict", "holdon", null, { solid: true, extra: "&name=" + lb.strictname }));
		L.banner.appendChild(bn);
	}
	L.felt.disabled = !s;
	if (L.mm) L.mm.textContent = mmLine();
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
		} else if (!RO) {
			var dev = D.info.device, ol = h("ol", { cls: "steps" });
			ol.appendChild(h("li", null, h("b", dev ? "Your gaming device is chosen. " : "Choose your gaming device. "), dev ? "MatchWatch is watching " + dev + "." : "Until you do, MatchWatch watches every device on your network. ", dev || !T.settings ? null : h("a", { href: T.settings, text: "Open Settings" })));
			ol.appendChild(h("li", null, h("b", "Play a match. "), "It appears on this page within about ten seconds, and gets a full report when it ends."));
			ol.appendChild(h("li", null, h("b", "Choose where you play, if you want to. "), "Draw a circle on the map and servers outside it are turned away. ", h("a", { href: "#/servers", text: "Open the map" })));
			L.last.appendChild(h("h2", "Getting started")); L.last.appendChild(ol);
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

// Tests are graded A+ to F. A score out of 100 becomes a letter; a ping on its own is graded by how far away it is.
function letter(s) { return s == null ? null : s >= 97 ? "A+" : s >= 90 ? "A" : s >= 80 ? "B" : s >= 70 ? "C" : s >= 55 ? "D" : s >= 40 ? "E" : "F"; }
function pingLetter(ms) { return ms == null ? null : ms <= 15 ? "A+" : ms <= 30 ? "A" : ms <= 50 ? "B" : ms <= 80 ? "C" : ms <= 120 ? "D" : ms <= 180 ? "E" : "F"; }
function gradeCls(g) { return !g ? "" : g.charAt(0) === "A" || g === "B" ? "ok" : g === "C" || g === "D" ? "mid" : "low"; }
function gradeBox(g, text) { return h("div", { cls: "grade " + gradeCls(g) }, h("b", { text: g || "?", "aria-label": "Grade " + (g || "unknown") }), h("p", text)); }
// ---------- one match in full
function chain(m) {
	var why = m.why || {}, whys = [why.pc, why.line, why.route, why.server];
	var parts = [["Your PC", m.s_pc, m.pc_counted === 0 ? "Shown, not counted" : null], ["Your line", m.s_line, null], ["Route", m.s_route, m.route_ign ? "Shown, not counted" : null], ["Server", m.s_server, null]];
	var min = null; parts.forEach(function (p) { if (p[1] != null && !p[2] && (min == null || p[1] < min)) min = p[1]; });
	var c = h("div", { cls: "chain" });
	parts.forEach(function (p, i) {
		var weak = p[1] != null && !p[2] && p[1] === min && p[1] < 70;
		c.appendChild(h("div", { cls: "link " + cls(p[1]) }, h("div", { cls: "dot", text: p[1] == null ? "n/a" : String(p[1]) }), h("b", p[0]), h("span", p[2] || (weak ? "Weakest link" : grade(p[1]))), whys[i] ? h("small", whys[i]) : null));
	});
	return c;
}
function kv(pairs) {
	var dl = h("dl", { cls: "kv" });
	pairs.forEach(function (p) { if (!p) return; dl.appendChild(h("dt", null, p[0], p[2] ? h("small", p[2]) : null)); dl.appendChild(h("dd", p[1])); });
	return dl;
}
// what QoSmate's queues did during the match: the game's own queue, and everything else on the line
function qmBlock(m) {
	var q = m.qm;
	if (!q || !q.up) return null;
	var top = m.qos !== "low", d = q.down || null, b = h("div", null, h("h2", "QoSmate in this match"));
	var mine = function (s) { return top ? { pkts: s.pkts, drops: s.drops, peak: s.peak } : { pkts: s.rpkts, drops: s.rdrops, peak: s.rpeak }; };
	var gu = mine(q.up), gd = d ? mine(d) : null;
	var drops = gu.drops + (gd ? gd.drops : 0), peak = Math.max(gu.peak, gd ? gd.peak : 0);
	var held = top ? q.up.rdrops + q.up.rmarks + (d ? d.rdrops + d.rmarks : 0) : 0;
	var bad = drops > 0 || peak >= 10;
	b.appendChild(h("p", { cls: "lede " + (bad ? "low" : "ok"), text: bad
		? "QoSmate's queue held your game up: " + drops + " packet" + (drops === 1 ? "" : "s") + " dropped, longest wait " + fmt(peak, 1) + " ms. That happened on your router, not at the server."
		: "QoSmate did its job. Your game's queue dropped nothing, and its longest wait was " + fmt(peak, 1) + " ms." }));
	if (!top) b.appendChild(h("p", { cls: "note", text: "Your game was not in the top priority queue, so it shared a queue with everything else on your line. See QoSmate priority under Tools, Data and settings." }));
	else b.appendChild(h("p", { cls: "note", text: held ? "Other traffic was heavy enough to be held back " + held + " time" + (held === 1 ? "" : "s") + " while your game went ahead of it." : "Nothing else on your line needed holding back." }));
	var rows = [["Sent by your game's queue", gu.pkts + " packets", gu.drops + " dropped, longest wait " + fmt(gu.peak, 1) + " ms"]];
	if (gd) rows.push(["Received by your game's queue", gd.pkts + " packets", gd.drops + " dropped, longest wait " + fmt(gd.peak, 1) + " ms"]);
	if (top) {
		rows.push(["Other traffic, sent", q.up.rpkts + " packets", (q.up.rdrops + q.up.rmarks) + " held back, longest wait " + fmt(q.up.rpeak, 1) + " ms"]);
		if (d) rows.push(["Other traffic, received", d.rpkts + " packets", (d.rdrops + d.rmarks) + " held back, longest wait " + fmt(d.rpeak, 1) + " ms"]);
	}
	b.appendChild(kv(rows.map(function (r) { return [r[0], r[1], r[2]]; })));
	b.appendChild(h("p", { cls: "note", text: "Read from QoSmate's queue counters at the start and end of the match. Longest wait is the highest of readings taken every five seconds, so a very brief spike can be missed." }));
	return b;
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
		if (m.outside) {
			// this match was played on a server outside the places being stayed on: say so, and why it was not turned away
			var og = m.game || "this game", why = m.outside === "allowed" ? "You added this server to the pool yourself, so it is always let through."
				: m.outside === "port" ? og + " is known by its port alone, and no match had been played on this port or address block before, so MatchWatch could not be sure it was the game. Its address block is turned away from now on. Make " + og + " strict, on the Servers page, to stop the first one too."
				: m.outside === "host" ? "It connected in the moment before it could be looked up, or your places changed while you were playing. Its address block is turned away from now on. Make " + og + " strict, on the Servers page, to hold new servers until they have been placed."
				: "The game on this port has no name yet, and MatchWatch never turns an unnamed game away. Name it under Tools, Games.";
			view.appendChild(h("div", { cls: "banner far" }, h("p", null, h("b", "Played outside your places. "), "This server is in " + (place(m) || "a place") + ", outside the places you stay on. " + why)));
		}
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
		if (!isBlocked(m.ip)) addIf(a, allowBtn(m.ip));
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
		if (full && m.hopstats && m.hopstats.length) {
			// each stop on the way, pinged all through the match
			var worst = /starts at stop (\d+)/.exec(m.hopnote || ""), from = worst ? +worst[1] : 0;
			var ht = table([["Stop", "num"], ["Address"], ["Ping ms", "num"], ["Jitter ms", "num"], ["Lost %", "num"]]);
			m.hopstats.forEach(function (x) {
				var r = row([[String(x.n), "num"], [x.ip], [x.ping == null ? "No reply" : fmt(x.ping, 1), "num"], [x.jit == null ? "" : fmt(x.jit, 1), "num" + (from && x.n >= from && x.jit >= 4 ? " s low" : "")], [x.ping == null ? "" : String(x.loss), "num" + (from && x.n >= from && x.loss >= 5 ? " s low" : "")]]);
				if (from && x.n === from) r.className = "hopfrom";
				ht.lastChild.appendChild(r);
			});
			b.appendChild(h("p", { cls: "note" + (m.hopnote ? " low" : ""), text: m.hopnote || "Every stop on the way that answers was pinged through the match. Nothing on the way stood out: no stop was rough with every stop after it rough too." }));
			b.appendChild(h("div", { cls: "tablewrap" }, ht));
			b.appendChild(h("p", { cls: "note", text: "Routers answer pings when they have a moment, so one rough stop with steady stops after it means nothing. Trouble is only named when it starts at a stop and carries on to the end." }));
		} else if (full && m.trace && m.trace.length) { var ol = h("ol", { cls: "hops" }); m.trace.forEach(function (t) { ol.appendChild(h("li", t.trim().replace(/\s+/g, "  "))); }); b.appendChild(ol); }
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
		var qb = full ? qmBlock(m) : null; if (qb) view.appendChild(qb);
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
	view.appendChild(h("p", { cls: "sub", text: "Select a match for its full report. Flags is how many moments you marked with \"I felt that\"." }));
	var heads = [["When"], ["Where"], ["Server"], ["Length"], ["Ping ms", "num"], ["Jitter ms", "num"], ["Missing %", "num"], ["Overall", "num"], ["Finding"], ["Flags", "num"], ["", ""]];
	heads.splice(1, 0, ["Game"]);
	var t = table(heads);
	D.hist.forEach(function (m) {
		if (gameFilter && m.game !== gameFilter) return;
		if (hourFilter >= 0 && hourOf(m) !== hourFilter) return;
		var cells = [[when(m.start)], [place(m)], [m.ip], [mins(m.dur)], [m.ping == null ? "n/a" : fmt(m.ping, 1), "num"], [fmt(m.jit, 2), "num"], [fmt(m.lost, 2), "num"], [String(m.overall), "num s " + cls(m.overall)], [FINDING[m.code] || m.code], (function () { var td = h("td", { cls: "num", text: m.marks ? String(m.marks) : "" }); if (m.marks) td.title = "Moments you flagged: " + m.marksum + ". The match report has the detail."; return td; })()];
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
	var tab = SERVTABS.some(function (t) { return t[0] === pageArg; }) ? pageArg : "places";
	var seg = h("div", { cls: "seg" });
	SERVTABS.forEach(function (t) { var a = h("a", { href: "#/servers/" + t[0], text: t[1] }); if (t[0] === tab) a.setAttribute("aria-current", "page"); seg.appendChild(a); });
	view.appendChild(seg);
	if (tab === "places") {
	if (stays.length) {
		var bn = h("div", { cls: "banner" }, h("p", null, h("b", "Staying on " + stays.join(", ") + ". "), "A server in any of these is allowed. Servers anywhere else are turned away as the game tries them. " + "A place is dropped if matches there start rating badly."), act("Stop staying", "stayoff", null, {}));
		view.appendChild(bn);
		// which hosts the up-front refusal covers, and whether the places in the pool have any servers at all
		var cov = h("div"); view.appendChild(cov);
		(function (c) {
			if (!c || !c.known) return;
			var none = (c.places || []).filter(function (p) { return !p.ranges; }), all = none.length === (c.places || []).length;
			if (none.length) {
				var names = none.map(function (p) { return p.name; }).join(", ");
				var w = h("div", { cls: "banner bad" }, h("p", null, h("b", all ? "You will not find a match like this. " : "No servers found in " + names + ". "),
					(all ? "None of the places you are staying on has" : "That place has no") + " a server that MatchWatch knows of for " + c.hosts + "." + (all && c.refusing ? " Every region that does is being refused, so those games cannot connect." : "") + (c.suggest && c.suggest.length ? " The nearest places with servers:" : " Add a place that has servers, or stop staying.")));
				(c.suggest || []).forEach(function (s) { w.appendChild(act("Add " + s.name + " (about " + s.km + " km)", "staysuggest", s.n, { solid: true })); });
				cov.appendChild(w);
			}
			gameCoverNotes().forEach(function (s) { cov.appendChild(h("p", { cls: "note low", text: s })); });
			cov.appendChild(brief((c.refusing ? "Whole regions are refused ahead of time for games hosted by " + c.hosts + ": " + c.refused + " of its " + c.known + " address ranges, for your gaming device only. " : "MatchWatch knows where the servers are for games hosted by " + c.hosts + ". ") + "Servers of any other game are turned away one at a time, as the game tries them, and MatchWatch cannot tell in advance whether such a game has servers in your places."));
		})(D.cov);
	}
	view.appendChild(h("h2", "Map"));
	view.appendChild(mapSection());
	// everything that is let in, in one list beside the map: the places, then the single servers
	var lets = D.info.allowed || [];
	if ((stays.length || lets.length) && !RO) {
		view.appendChild(h("h2", "What is let in"));
		var pl = h("div", { cls: "actions" });
		stays.forEach(function (nm, i) { pl.appendChild(act("Remove " + nm, "stayrm", i + 1, stays.length === 1 ? { confirm: "Confirm: this stops staying" } : {})); });
		lets.forEach(function (ip) { var s = D.servers.filter(function (x) { return x.ip === ip; })[0] || D.favInfo[ip]; pl.appendChild(act("Remove server " + ip + (s && place(s) ? ", " + place(s) : ""), "unallow", ip, {})); });
		view.appendChild(pl);
		view.appendChild(brief(lets.length ? "Each button removes one place or one single server. A single server is let through even when it is outside your places. Only its exact address is allowed, so its neighbours in the same datacentre are still turned away, and the game still decides whether to offer it to you." + (stays.length ? "" : " Single servers only matter while you are staying on places.")
			: "Each button removes one place. To let one server through from outside your places, press Add to pool beside it under Favourites or Servers, on the map, or on a match report."));
	}
	// stay anywhere: cities, countries or wider areas, as one pool
	if (!RO) {
	view.appendChild(h("h2", stays.length ? "Add places by name" : "Or type where to stay"));
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
	view.appendChild(brief("Type one place or several, separated by commas: cities, countries, or these areas: uk-ireland, western-europe, southern-europe, northern-europe, eastern-europe, europe, north-america, south-america, middle-east, asia, oceania. A city allows servers within about 150 km of it; a country or area allows any server located there. Several places make one pool, and the game picks among them, which keeps queues shorter than a single place."));
	}
	addIf(view, strictSection());
	}
	if (tab === "favourites") {
	view.appendChild(favSection());
	}
	if (tab === "servers") {
	view.appendChild(h("h2", "Servers, worst first"));
	if (!D.servers.length) view.appendChild(h("p", { cls: "empty", text: "No servers seen yet." }));
	else {
		var t2 = table([["Server"], ["Where"], ["Host"], ["Matches", "num"], ["Rating", "num"], ["Worst", "num"], ["Ping ms", "num"], ["", ""]]);
		D.servers.forEach(function (s) {
			var td = h("td", { cls: "act" });
			td.appendChild(star(s.ip));
			if (s.blocked) td.appendChild(h("span", { cls: "tag", text: "Blocked" })); else { addIf(td, allowBtn(s.ip)); td.appendChild(act("Block", "block", s.ip, { danger: true, confirm: "Confirm: " + days + " days" })); }
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
		view.appendChild(brief("A datacentre is one operator in one city. Ratings need a few matches each before they mean much. Blocking one only covers the address blocks you have been placed on there so far. Remove takes a datacentre, its servers and their matches out of MatchWatch altogether; it is refused while one of its servers is a favourite."));
	}
	}
	if (tab === "regions") {
	view.appendChild(h("h2", "Every region, nearest first"));
	var rg = D.regions || [];
	if (!rg.length) view.appendChild(h("p", { cls: "empty", text: "Not measured yet." }));
	else {
		var tr = table([["Region"], ["Area"], ["Ping ms", "num"], ["Grade"], ["Jitter ms", "num"], ["Your matches there", "num"], ["Rating", "num"], ["Ping in matches", "num"], ["", ""]]);
		(regionsAll ? rg : rg.slice(0, 4)).forEach(function (r) {
			tr.lastChild.appendChild(row([[r.city + ", " + r.cc], [r.area], [r.ping == null ? "No reply" : fmt(r.ping, 1), "num s"], [pingLetter(r.ping) || "", "s " + gradeCls(pingLetter(r.ping))], [r.jit == null ? "" : fmt(r.jit, 1), "num"],
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
	view.appendChild(brief("Ping from your router to the test server Vultr runs in each of its datacentres" + (rg.length ? ", measured " + when(rg[0].ts) : "") + ". Every Call of Duty server you have been placed on so far is hosted by Vultr, but the game is reported to use other hosts in some places, so this is not a complete list of where it has servers. Stay here on a row is the same as typing that city above: it allows servers within about 150 km of it, whoever hosts them. The game still decides which regions to offer you."));
	view.appendChild(gamePlacesSection());
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
var SHARE = [["games", "1", "Game names"], ["favourites", "6", "Favourite servers"], ["places", "3", "Places you stay on"], ["gameservers", "9", "Game servers by place"], ["ratings", "4", "Network ratings"], ["regions", "2", "Ping hosts for the regions table"], ["settings", "5", "Thresholds"], ["favplaces", "7", "Stay near those servers"]];
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
	else if (sec === "gameservers") {
		o.game = f[0]; o.city = f[2] || ""; o.cc = f[3] && f[3] !== "-" ? f[3] : ""; o.n = +f[7] || 0; o.avg = f[8] === "" || f[8] == null ? null : +f[8];
		o.text = o.game + ": " + f[1] + (o.city || o.cc ? ", " + [o.city, o.cc].filter(Boolean).join(", ") : "") + (f[4] && f[4].trim() ? ", " + f[4].trim() : "") + (o.n ? ": " + o.n + " match" + (o.n === 1 ? "" : "es") + (o.avg == null ? "" : ", rated " + o.avg) : ": tried by the game, not played on");
	}
	else if (sec === "settings") { o.text = (SETNAME[f[0]] || f[0]) + ": " + f[1]; o.on = false; }
	return o;
}
// the picker: one block per section, a tick per item, quick picks, a note, and a preview that is exactly the file
var ONE = { games: "game name", gameservers: "game server network", favourites: "favourite server", regions: "ping host", places: "place", ratings: "network rating", settings: "threshold" };
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
		if ((x[0] === "ratings" || x[0] === "favourites" || x[0] === "gameservers") && its.length > 1) {
			// quick picks: tick by several things at once; single ticks can still be changed after
			var isFavs = x[0] === "favourites", byGame = isFavs || x[0] === "gameservers", sels = [];
			var mk = function (label, opts, val) { var s = h("select", { "aria-label": label }); opts.forEach(function (o) { s.appendChild(h("option", { value: o[0], text: o[1] })); }); s.value = val; sels.push(s); return s; };
			var uniq = function (key, pre, word) { var seen = []; its.forEach(function (i) { if (i[key] && seen.indexOf(i[key]) < 0) seen.push(i[key]); }); return seen.sort().map(function (v) { return [pre + v, word + v]; }); };
			var qf = isFavs ? mk("Pick favourites or every server", [["fav", "My favourites"], ["", "Every server I have played on"]], its.some(function (i) { return i.fav; }) ? "fav" : "") : null;
			var qg = byGame ? mk("Pick by game", [["", "Any game"]].concat(uniq("game", "", "")), "") : null;
			var qr = mk("Pick by rating", [["", "Any rating"], ["poor", "Poor: under 50"], ["fair", "Fair or worse: under 70"], ["good", "Good: 70 or more"], ["great", "Excellent: 85 or more"]], "");
			var qp = mk("Pick by place", [["", "Anywhere"]].concat(uniq("cc", "c:", "Country: "), uniq("city", "t:", "City: ")), "");
			var qn = mk("Pick by number of matches", [["0", "Any number of matches"], ["1", "Played on at least once"], ["2", "2 or more matches"], ["3", "3 or more"], ["5", "5 or more"], ["10", "10 or more"]], byGame ? "0" : "2");
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
	box.appendChild(h("p", { cls: "note", text: "A share file is a small text file holding things another MatchWatch user can use: the games you have named, where each game has servers, your favourite servers for each game, the places you stay on, how servers have rated for you, extra ping hosts, and your thresholds. You pick what goes in, item by item. Nothing is ever sent anywhere: you make the file, and you choose who gets it. It never holds your device, your addresses or when you played." }));

	// ---- make a file: the router lists everything that could be shared, and every item gets its own tick
	box.appendChild(h("h3", "Make a share file"));
	var pickBox = h("div"), made = h("div");
	var mk = h("button", { type: "button", cls: "solid", text: "Choose what to share" });
	box.appendChild(h("div", { cls: "actions" }, mk)); box.appendChild(pickBox); box.appendChild(made);
	mk.addEventListener("click", function () {
		mk.disabled = true;
		send({ action: "shareexport", arg: "1234589" }).then(function (j) {
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

var SERVTABS = [["places", "Where I play"], ["favourites", "Favourites"], ["servers", "Servers"], ["regions", "Regions and games"]];
// A long grey paragraph shown as its first sentence, with the rest one press away. Short ones are left whole.
function brief(text) {
	var k = text.indexOf(". "), p = h("div", { cls: "note" });
	if (k < 0 || text.length < 190) { p.textContent = text; return p; }
	p.appendChild(document.createTextNode(text.slice(0, k + 1) + " "));
	p.appendChild(h("details", { cls: "more" }, h("summary", "More"), h("span", text.slice(k + 2))));
	return p;
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
				if (r.score != null) lineOut.appendChild(gradeBox(letter(r.score), r.msg));
				else lineOut.appendChild(h("p", { cls: "lede " + (r.verdict === "good" ? "ok" : r.verdict === "fair" ? "mid" : r.verdict === "poor" ? "low" : ""), text: r.msg }));
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
					// the grade is for the last stop when that is the server itself: one trace shows distance, not steadiness
					var lastHop = r.hops[r.hops.length - 1].split(" "), ms = lastHop[1] === r.ip ? parseFloat(lastHop[2]) : NaN;
					if (!isNaN(ms)) trOut.appendChild(gradeBox(pingLetter(ms), "The server answered in " + fmt(ms, 0) + " ms over " + r.hops.length + " stops. This grades distance only: a single trace cannot show how steady the route is. A match report does that."));
					else trOut.appendChild(h("p", { cls: "note", text: "No grade: the server itself did not answer the trace, so there is no ping to it to judge. Many game servers do not." }));
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
		view.appendChild(tool("Skipped, not recorded", "Two kinds of stream are left out of your matches: voice chat, and anything on a port nobody has named that did not look like a game (under two minutes, or no steady update rate). If a game you play is listed here, name it and MatchWatch always records that port from then on.", skBox));
		get("skipped.json", function (sk) {
			if (page !== "tools") return;
			sk = (sk || []).slice().sort(function (a, b) { return b.last - a.last; });
			if (!sk.length) { skBox.appendChild(h("p", { cls: "empty", text: "Nothing has been skipped in the last six hours." })); return; }
			var t = table([["Server"], ["Port", "num"], ["Last seen"], ["Why it was skipped"], ["If this is a game, name it"]]);
			sk.forEach(function (x) {
				var td = h("td");
				td.appendChild(nameForm(x.port, "This is a game", function (v) { td.textContent = "Now treated as a game: " + v; }));
				t.lastChild.appendChild(row([[x.ip], [String(x.port), "num"], [when(x.last)], [x.why === "short" ? "Under two minutes" : x.why === "unsteady" ? "No steady update rate" : "Voice chat"], td]));
			});
			skBox.appendChild(h("div", { cls: "tablewrap" }, t));
		});

	}
	if (!RO && tab === "share") view.appendChild(shareSection());
	if (!RO && tab === "data") {
		var upOut = outBox(), upBtn = h("button", { type: "button", cls: "solid", text: "Update now" }), upAgain = h("button", { type: "button", text: "Reload this page" });
		upBtn.style.display = "none"; upAgain.style.display = "none";
		upAgain.addEventListener("click", freshReload);
		upBtn.addEventListener("click", function () {
			upOut.show("Downloading and installing. This takes about half a minute.");
			job(upBtn, "update", null, "update.json", function (r) {
				upOut.show(r.out || "");
				if (r.ok) { upBtn.style.display = "none"; upAgain.style.display = ""; upOut.show((r.out || "") + " This page reloads by itself in a moment."); setTimeout(function () { refresh(true); }, 2500); }
			});
		});
		view.appendChild(tool("Update MatchWatch", "You have version " + (D.info.version || "?") + ". Checking asks GitHub, where MatchWatch is published, for the newest version number. If there is one, Update now downloads the installer from there, checks it arrived whole and runs it. Your history and settings are kept, and this page reloads by itself when it is done. It restarts MatchWatch, so do it between matches.",
			h("div", { cls: "actions" }, act("Check for an update", "updatecheck", null, { done: function (o) { upOut.show(o); upBtn.style.display = /is available/.test(o || "") ? "" : "none"; } }), upBtn, upAgain), upOut));
		var dl = h("button", { type: "button", text: "Download as a spreadsheet file" });
		dl.addEventListener("click", downloadHistory); dl.disabled = !D.hist.length;
		view.appendChild(tool("Match history", D.hist.length + " match" + (D.hist.length === 1 ? "" : "es") + " on file. The download is a CSV file that opens in any spreadsheet.", h("div", { cls: "actions" }, dl)));
		view.appendChild(tool("Clear all history", "Deletes every match and the server ratings built from them. It cannot be undone. Blocks, favourites, the places you stay on and your settings are kept. It restarts MatchWatch, so do it between matches.",
			h("div", { cls: "actions" }, act("Clear all history", "clearhistory", null, { danger: true, confirm: "Confirm: delete every recorded match", done: function (o) { toast(o); setTimeout(function () { refresh(true); if (page === "tools") pageTools(); }, 2500); } }))));
		var logOut = outBox();
		view.appendChild(tool("Recent activity", "The last things MatchWatch wrote to the router's log: matches judged, servers blocked, alerts sent.",
			h("div", { cls: "actions" }, act("Show recent activity", "log", null, { done: function (o) { logOut.show(o || "Nothing logged yet."); } })), logOut));

		view.appendChild(h("h2", "QoSmate"));
		var mmDesc = "QoSmate keeps your game ahead of everything else by holding your line a little under its full speed. That limit also slows downloads when nobody is playing. With match mode on, MatchWatch lifts QoSmate's limit between matches and puts it back when a match starts, so you get QoSmate's low latency while you play and your line's full speed the rest of the time. You choose both sets of speeds. QoSmate does the prioritising; MatchWatch only switches its limit, and never changes QoSmate's settings.";
		if (!hasQos) view.appendChild(tool("Match mode", mmDesc, needQos()));
		else {
			var mm = D.mm || {}, again = function (o) { toast(o); setTimeout(function () { loadAll(function () { if (page === "tools") pageTools(); }); }, 1500); };
			view.appendChild(tool("Match mode", mmDesc,
				h("div", { cls: "actions" }, mm.on ? h("span", { cls: "tag keep", text: "On" }) : null,
					mm.on ? act("Turn match mode off", "matchmodeoff", null, { done: again }) : (mm.can === false ? null : act("Turn match mode on", "matchmodeon", null, { solid: true, done: again }))),
				h("p", { cls: "note", text: mm.on ? mmLine() : mm.can === false ? "It cannot be turned on yet: QoSmate must be switched on and in one of its cake modes." : "Off: QoSmate's limits are on all the time" + (mm.down ? ", " + mbit(mm.down) + " down and " + mbit(mm.up) + " up." : ".") }),
				mm.can === false ? null : mmSpeeds(mm, again)));
		}
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
// Fresh data every fifteen seconds. The page is only drawn again when something in it has changed:
// rebuilding it each time made it flicker, and anything filled in a moment later pushed the rest down.
var lastSig = "";
function loadAll(then) {
	var left = 11, done = function () { if (--left === 0) then(); };
	get("matchmode.json", function (x) { D.mm = x || null; done(); });
	get("hold.json", function (x) { D.hold = x || []; done(); });
	get("history.json", function (x) { D.hist = x || []; done(); });
	get("servers.json", function (x) { D.servers = x || []; done(); });
	get("datacentres.json", function (x) { D.dcs = x || []; done(); });
	get("blocklist.json", function (x) { D.blocks = x || []; done(); });
	get("info.json", function (x) { D.info = x || {}; versionSeen(D.info.version);
		var up = shadow.getElementById("upd"); if (up) { up.style.display = (D.info.latest && !RO) ? "" : "none"; up.textContent = D.info.latest ? "Update available: " + D.info.latest : ""; }
		done(); });
	get("favourites.json", function (x) { setFavs(x); done(); });
	get("regions.json", function (x) { D.regions = x || []; done(); });
	get("gameplaces.json", function (x) { D.gp = x || []; done(); });
	get("coverage.json", function (x) { D.cov = x || null; done(); });
}
function sigNow() { try { return JSON.stringify([D.hist, D.servers, D.dcs, D.blocks, D.info, D.favs, D.regions, D.gp, D.cov, D.hold, D.mm]); } catch (e) { return String(Date.now()); } }
function refresh(force) {
	loadAll(function () {
		var sig = sigNow(), changed = sig !== lastSig;
		lastSig = sig;
		if (page === "live") { if (changed || force) { L.ip = null; updateLive(); } return; }
		if (page === "match" || page === "tools") return;
		if (force || (changed && !armed && !typing())) route(true);
		else if (changed) lastSig = "";          // could not redraw just now (a button is armed, or a box has text in it): try again next time
	});
}
window.addEventListener("hashchange", route);
window.addEventListener("resize", function () { updateLive(); if (page === "match" && pageMatch.repaint) pageMatch.repaint(); });
loadAll(function () { lastSig = sigNow(); route(); });
tick(); setInterval(tick, 1000); setInterval(function () { setDark(); refresh(false); }, 15000);
};
