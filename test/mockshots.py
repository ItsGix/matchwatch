#!/usr/bin/env python3
"""Make the README screenshots (docs/*.png) from invented data.

Nothing here comes from a real network: addresses are from the ranges reserved for
documentation, and the matches are made up. Needs Pillow and Edge or Chrome; no router,
BusyBox or Playwright. Run from the repository root:  python3 test/mockshots.py"""
import functools, http.server, json, os, random, shutil, subprocess, sys, tempfile, threading, time
from PIL import Image

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
RES = "luci-static/resources/matchwatch"
PORT = 8772
NOW = int(time.time())
random.seed(7)

BROWSERS = [r"C:\Program Files (x86)\Microsoft\Edge\Application\msedge.exe", r"C:\Program Files\Microsoft\Edge\Application\msedge.exe",
            r"C:\Program Files\Google\Chrome\Application\chrome.exe", "/usr/bin/chromium", "/usr/bin/chromium-browser", "/usr/bin/google-chrome",
            "/Applications/Google Chrome.app/Contents/MacOS/Google Chrome"]

# (key, city, cc, country, org, ping, addresses)
DCS = {"fra": ("Frankfurt", "DE", "Germany", "Example Hosting Frankfurt", 6.1, ["203.0.113.21", "203.0.113.48", "203.0.113.77"]),
       "sto": ("Stockholm", "SE", "Sweden", "Example Hosting Stockholm", 14.8, ["198.51.100.12", "198.51.100.90"]),
       "mad": ("Madrid", "ES", "Spain", "Example Hosting Madrid", 27.4, ["192.0.2.33", "192.0.2.150"])}
VERDICT = {"clean": "Clean match. Nothing on your side, the route or the server stood out.",
           "server": "The server itself sent updates unevenly while the route to it was clean.",
           "route": "Updates arrived in clumps: they were held up on the route, not at the server.",
           "pc": "Your PC paused several times while the server and the route were steady."}
# hours ago, datacentre, server index, finding, overall, marks
PLAN = [(1.2, "fra", 0, "clean", 97, 0), (2.0, "fra", 1, "clean", 95, 1), (2.8, "sto", 0, "clean", 92, 0), (3.6, "fra", 2, "server", 24, 2),
        (22.5, "mad", 0, "route", 58, 1), (23.3, "fra", 0, "clean", 96, 0), (24.1, "sto", 1, "clean", 90, 0), (26.4, "fra", 1, "pc", 71, 1),
        (47.0, "mad", 1, "route", 61, 0), (48.2, "fra", 0, "clean", 98, 0), (49.5, "sto", 0, "clean", 93, 0), (71.0, "fra", 2, "server", 41, 1)]


def timeline(n, kind):
    d = [round(random.uniform(48, 53), 1) for _ in range(n)]
    u = [round(random.uniform(7, 14), 1) for _ in range(n)]
    for i in random.sample(range(5, n - 5), 3 if kind == "clean" else 9):
        if kind == "pc": u[i] = random.choice([140, 180, 230])
        else: d[i] = random.choice([110, 160, 250, 310]) if kind == "server" else random.choice([90, 120])
    return d, u


def build(site):
    data = site + "/matchwatch/data"
    os.makedirs(data + "/matches"); os.makedirs(site + "/" + RES)
    for f in ("dashboard.js", "dashboard.css"):
        shutil.copy(f"{ROOT}/luci-app-matchwatch/htdocs/{RES}/{f}", f"{site}/{RES}/{f}")
    hist, srv, dcs = [], {}, {}
    for hrs, key, si, code, overall, marks in PLAN:
        city, cc, country, org, ping, ips = DCS[key]
        ip, start, dur = ips[si], NOW - int(hrs * 3600), random.randint(600, 1500)
        bad = code != "clean"
        s = {"server": 100, "route": 100, "line": 100, "pc": 100}
        if code in s: s[code] = max(2, overall - 20)
        p = round(ping + random.uniform(-0.4, 0.4), 1)
        m = {"game": "Example Arena" if cc == "SE" else "Example Shooter", "start": start, "dur": dur, "analysed": dur - 6, "device": "192.168.1.50", "ip": ip, "port": 30120, "cc": cc, "city": city, "org": org, "asn": "AS64500",
             "tick": 20.1, "jit": 2.68 if code == "server" else round(random.uniform(0.2, 0.6), 2), "late": 2.78 if code == "server" else 0.03, "lost": 2.4 if code == "server" else round(random.uniform(0, 0.1), 2),
             "clump": 3.1 if code == "route" else 0.0, "freeze": 3 if code == "server" else 0, "rough": 51.0 if code == "server" else (18.0 if bad else 0.0), "uprate": 95.2, "upjit": 0.2,
             "hitch": 4 if code == "pc" else 0, "farkind": "server", "ping": p, "pingjit": 3.9 if code == "route" else 0.3, "pingloss": 1.5 if code == "route" else 0.0, "nearping": 3.7, "nearjit": 0.3, "nearloss": 0,
             "lanping": 0.2, "s_server": s["server"], "s_route": s["route"], "s_line": s["line"], "s_pc": s["pc"], "overall": overall, "rating": s["server"] if code == "server" else 100, "counted": 1,
             "code": code, "verdict": VERDICT[code], "hops": "9", "marks": marks, "marksum": ("server stalled" if code == "server" else "nothing on the network") if marks else "", "qos": "top"}
        hist.append(m)
        n = min(dur, 600)
        d, u = timeline(n, code)
        base = [round(p + random.uniform(-0.3, 0.3) + (8 if code == "route" and i % 97 == 40 else 0), 1) for i in range(n)]
        det = dict(m, id=str(start), t0=start, nom=49.8, upnom=10.5, jitpct=16.0 if code == "server" else 2.1, stut=4 if code == "server" else 0, worst=315 if code == "server" else 0,
                   upnom_=None, pauses=m["hitch"], stalls=m["hitch"] + 1, upworst=230 if code == "pc" else 0, farip=ip, pingp95=round(p + 1.3, 1), nearip="198.51.100.1",
                   wanavg=4.2, wanpeak=38, wanuppeak=6, route_ign=0, pc_counted=1, tl_d=d, tl_u=u, tl_p=base,
                   marks=[{"t": start + 74 + 90 * k, "k": "server", "x": "server updates stalled: one arrived 249 ms late" if code == "server" else "nothing showed on the network in the six seconds before"} for k in range(marks)],
                   trace=[" 1  198.51.100.1  3.2 ms", " 2  100.64.0.64  3.1 ms", " 3  100.64.0.74  3.7 ms", " 4  192.0.2.180  5.7 ms", " 5  192.0.2.36  5.9 ms", " 6  *", " 7  *", " 8  192.0.2.201  %.1f ms" % (p - 0.4), " 9  %s  %.1f ms" % (ip, p)])
        del det["upnom_"]
        json.dump(det, open(f"{data}/matches/{start}.json", "w"))
        e = srv.setdefault(ip, {"ip": ip, "cc": cc, "city": city, "org": org, "matches": 0, "counted": 0, "sum": 0, "worst": 100, "tick": 20.1, "ping": p, "last": start, "minutes": 0, "blocked": False})
        e["matches"] += 1; e["counted"] += 1; e["sum"] += m["rating"]; e["worst"] = min(e["worst"], m["rating"]); e["minutes"] += dur // 60
        g = dcs.setdefault(key, {"name": f"{city}, {cc} - {org}", "matches": 0, "counted": 0, "ips": set(), "sum": 0, "worst": 100, "ping": ping, "minutes": 0, "blocked": False, "stay": key in ("fra", "sto")})
        g["matches"] += 1; g["counted"] += 1; g["ips"].add(ip); g["sum"] += m["rating"]; g["worst"] = min(g["worst"], m["rating"]); g["minutes"] += dur // 60
    servers = sorted(({**{k: v for k, v in e.items() if k != "sum"}, "rating": round(e["sum"] / e["matches"])} for e in srv.values()), key=lambda x: x["rating"])
    dlist = sorted(({**{k: v for k, v in g.items() if k not in ("sum", "ips")}, "servers": len(g["ips"]), "rating": round(g["sum"] / g["matches"])} for g in dcs.values()), key=lambda x: x["rating"])
    for i, g in enumerate(dlist): g["n"] = i + 1
    dlist[-1]["blocked"] = not dlist[-1]["stay"]
    for g in dlist: g["blocked"] = not g["stay"]
    regions = [("fra-de", "Frankfurt", "DE", "Europe", 6.1, "fra"), ("ams-nl", "Amsterdam", "NL", "Europe", 9.8, None), ("par-fr", "Paris", "FR", "Europe", 11.9, None), ("sto-se", "Stockholm", "SE", "Europe", 14.8, "sto"),
               ("waw-pl", "Warsaw", "PL", "Europe", 19.5, None), ("lon-gb", "London", "GB", "Europe", 16.2, None), ("mad-es", "Madrid", "ES", "Europe", 27.4, "mad"), ("nyc-us", "New York", "US", "North America", 84.0, None),
               ("sgp-sg", "Singapore", "SG", "Asia", 168.3, None), ("syd-au", "Sydney", "AU", "Oceania", 251.7, None)]
    rj = []
    for code, city, cc, area, ping, key in sorted(regions, key=lambda r: r[4]):
        g = dcs.get(key)
        rj.append({"code": code, "city": city, "cc": cc, "area": area, "ping": ping, "jit": round(random.uniform(0.1, 0.9), 1), "ts": NOW - 1800, "matches": g["matches"] if g else 0,
                   "rating": round(g["sum"] / g["matches"]) if g else None, "matchping": g["ping"] if g else None, "stay": bool(g and g["stay"])})
    blocks = [{"ip": DCS["mad"][5][0].rsplit(".", 1)[0] + ".0/24", "days": None, "reason": "stay"}, {"ip": "203.0.113.77", "days": 12, "reason": "manual"}]
    for s in servers: s["blocked"] = s["ip"] == "203.0.113.77"
    out = {"history": hist, "servers": servers, "datacentres": dlist, "regions": rj, "blocklist": blocks,
           "info": {"version": "0.17.1", "device": "192.168.1.50", "stay": "Germany + Sweden", "autoblock": False, "notify": True, "pc_score": True, "geo": True, "block_days": 14, "stays": ["Germany", "Sweden"], "web": False, "qosmate": True}}
    out["favourites"] = [servers[-1]["ip"], servers[-2]["ip"], servers[-4]["ip"]]
    out["mygames"] = [{"name": "Example Arena", "ports": "7777-7800", "kind": "", "hosts": ""}, {"name": "Example Shooter", "ports": "20000-29000", "kind": "", "hosts": "examplehost,as64500"}, {"name": "Not a game", "ports": "19306", "kind": "voice", "hosts": ""}]
    out["shared"] = {"undo": True, "have": {"games": 3, "regions": 0, "places": 2, "ratings": 6},
                     "ratings": [{"p": "203.0.113.0/24", "n": 14, "avg": 38, "city": "Madrid", "cc": "ES", "org": "Example Hosting Madrid", "blocked": True},
                                 {"p": "198.51.100.0/24", "n": 9, "avg": 61, "city": "Paris", "cc": "FR", "org": "Example Hosting Paris", "blocked": False},
                                 {"p": "192.0.2.0/24", "n": 22, "avg": 93, "city": "Amsterdam", "cc": "NL", "org": "Example Hosting Amsterdam", "blocked": False}]}
    d, u = timeline(120, "clean"); d[40], d[41], d[95] = 265.3, 98, 150; u[70] = 166
    p = [round(random.uniform(5.8, 6.4), 1) for _ in range(120)]; p[40], p[41] = 14.5, 9.0
    out["status"] = {"ts": NOW + 3600, "candidates": 0, "flows": 3, "sessions": [{"ip": "203.0.113.21", "port": 30120, "device": "192.168.1.50", "age": 412, "start": NOW - 412, "loc": "Frankfurt, DE", "org": "Example Hosting Frankfurt",
                     "tick": 20.1, "jit": 0.41, "late": 0.02, "lost": 0, "uprate": 95.2, "upjit": 0.3, "s_lost": 0.04, "s_frz": 1, "s_hitch": 1, "rep": 97, "repn": 3, "ping": 6.1, "tl_d": d, "tl_u": u, "tl_p": p,
                     "marks": [{"t": NOW + 3600 - 76, "k": "server+ping", "x": "server updates stalled: one arrived 217 ms late; ping jumped to 14 ms (normally 6)"}]}]}
    for name, j in out.items(): json.dump(j, open(f"{data}/{name}.json", "w"))
    open(site + "/matchwatch/index.html", "w", encoding="utf-8", newline="\n").write("""<!DOCTYPE html><html lang="en"><head><meta charset="utf-8"><title>matchwatch</title>
<style>html, body { margin: 0; background: #0f2a2b; }</style></head><body><div id="mw"></div><script src="/%s/dashboard.js"></script><script>
MatchwatchDashboard(document.getElementById("mw"), { css: "/%s/dashboard.css", full: true, dark: function () { return true; }, settings: "#",
	get: function (f) { return fetch("data/" + f).then(function (r) { if (!r.ok) throw 0; return r.json(); }); },
	act: function (p) {
		var out = "";
		if (p.action === "shareexport") out = `# MatchWatch share file. Import it on the Tools page, or with: matchwatch share import <file>
# It holds nothing about the home it came from: no device, LAN or ISP address, and no match times.
matchwatch-share 1

[games]
# name|server ports|kind (empty = a game, voice = voice chat)|words in the name of the company hosting the servers
Example Arena|7777-7800||
Example Shooter|20000-29000||examplehost,as64500
Example Racing|8211||

[places]
# name|latitude|longitude|reach in km|country codes
Germany|-|-|0|DE
Stockholm, SE|59.33|18.07|150|-

[ratings]
# server network|matches|average rating out of 100|city|country code|host
203.0.113.0/24|14|38|Madrid|ES|Example Hosting Madrid
198.51.100.0/24|9|61|Paris|FR|Example Hosting Paris
192.0.2.0/24|22|93|Frankfurt|DE|Example Hosting Frankfurt
192.0.2.0/24|6|88|Stockholm|SE|Example Hosting Stockholm
198.51.100.0/24|1|72|Amsterdam|NL|Example Hosting Amsterdam

[favourites]
# server|game|city|country code|host|rating out of 100|matches|latitude|longitude
198.51.100.12|Example Arena|Stockholm|SE|Example Hosting Stockholm|100|2|59.33|18.07|1
198.51.100.90|Example Arena|Stockholm|SE|Example Hosting Stockholm|100|1|59.33|18.07|1
192.0.2.150|Example Shooter|Madrid|ES|Example Hosting Madrid|100|1|40.42|-3.70|1
203.0.113.21|Example Shooter|Frankfurt|DE|Example Hosting Frankfurt|100|3|50.11|8.68|0
203.0.113.77|Example Shooter|Frankfurt|DE|Example Hosting Frankfurt|12|2|50.11|8.68|0

[settings]
# the thresholds this copy of MatchWatch runs with
min_down_pps=15
min_up_pps=8
warn_score=55
autoblock_score=45
autoblock_matches=2
lobby_margin_ms=4
stay_km=150
block_days=14`;
		if (p.action === "sharecheck") out = `games: 2 game label(s): Example Game, Another Game. They go below the names you have given yourself, which always win.
favourites: 3 favourite server(s) for Example Arena (2), Example Shooter (1). They join your favourites under those games: never blocked automatically, and the lobby alert tells you when you land on one.
favplaces: Stay near those servers: adds Stockholm, SE, Madrid, ES to the places you stay on and turns staying on, so game servers elsewhere are blocked.
places: 1 place(s) to stay on: UK and Ireland. Importing these turns staying on, so game servers elsewhere are blocked.
ratings: 3 server rating(s) from someone else. They are shown to you and mentioned by the lobby alert, and never block anything by themselves.
1 line(s) were not accepted and are left out:
  line 9: a port that cannot be read`;
		if (p.action === "shareimport") out = `Added 2 game label(s). Ones for ports you had already named were left out.
Took in 3 server rating(s). They are listed on the Tools page.`;
		return Promise.resolve({ ok: true, out: out });
	} });
// for the Tools screenshot: open the picker, as a visitor would
setTimeout(function () { var b = Array.prototype.filter.call(document.getElementById("mw").shadowRoot.querySelectorAll("button"), function (x) { return x.textContent === "Choose what to share"; })[0]; if (b) b.click(); }, 3000);
</script></body></html>""" % (RES, RES))
    return [m for m in hist if m["code"] == "server"][0]["start"]


def shoot(browser, route, out, height):
    tmp = out + ".tmp.png"
    subprocess.run([browser, "--headless=new", "--disable-gpu", "--hide-scrollbars", "--force-device-scale-factor=1", f"--window-size=1180,{height}", "--virtual-time-budget=20000",
                    "--user-data-dir=" + tempfile.mkdtemp(), "--screenshot=" + tmp, f"http://127.0.0.1:{PORT}/matchwatch/{route}"], capture_output=True, timeout=120)
    im = Image.open(tmp).convert("RGB")
    bg, px, y = im.getpixel((2, im.height - 2)), im.load(), im.height - 1
    while y > 0 and all(px[x, y] == bg for x in range(0, im.width, 7)): y -= 1   # trim the empty page below the content
    im.crop((0, 0, im.width, min(im.height, y + 28))).save(out, optimize=True)
    os.remove(tmp)
    print(os.path.relpath(out, ROOT), Image.open(out).size)


if __name__ == "__main__":
    browser = next((b for b in BROWSERS if os.path.exists(b)), None) or sys.exit("No Edge or Chrome found.")
    site = tempfile.mkdtemp()
    bad = build(site)
    handler = functools.partial(http.server.SimpleHTTPRequestHandler, directory=site)
    handler.log_message = lambda *a: None
    srv = http.server.ThreadingHTTPServer(("127.0.0.1", PORT), handler)
    if sys.argv[1:] == ["serve"]:   # look at the mock dashboard by hand
        print(f"http://127.0.0.1:{PORT}/matchwatch/"); srv.serve_forever()
    threading.Thread(target=srv.serve_forever, daemon=True).start()
    os.makedirs(ROOT + "/docs", exist_ok=True)
    for route, name, h in (("#/", "live", 1400), (f"#/match/{bad}", "match-report", 2600), ("#/matches", "matches", 2600), ("#/servers", "servers-pool", 4600), ("#/tools", "tools", 2200), ("#/tools/share", "share", 4200)):
        shoot(browser, route, f"{ROOT}/docs/{name}.png", h)
    srv.shutdown()
    shutil.rmtree(site, ignore_errors=True)
