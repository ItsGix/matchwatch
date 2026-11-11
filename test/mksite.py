#!/usr/bin/env python3
"""Build a realistic test site (history, match detail, live status) and serve the view-only dashboard page.
The buttons that change things run through LuCI and are tested on a router, not here."""
import json, os, random, subprocess, sys, time, http.server, socketserver

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
E = ROOT + "/test/site"
FILES = ROOT + "/files"
os.makedirs(E + "/data/matches", exist_ok=True)
os.makedirs(E + "/run/www", exist_ok=True)
os.makedirs(E + "/web/matchwatch", exist_ok=True)
RES = "/luci-static/resources/matchwatch"
os.makedirs(E + "/web" + RES, exist_ok=True)
ENV = dict(os.environ, PATH=ROOT + "/test/stub:" + os.environ["PATH"], MW_CONF=E + "/config", MW_LIB=FILES,
           MW_RUN=E + "/run", MW_DATA=E + "/data", MW_SELF="dash " + FILES + "/matchwatch")
MW = ["dash", FILES + "/matchwatch"]


def build():
    open(E + "/config", "w").write('DEVICE_IP="192.168.1.50"\nLAN_IF="br-lan"\nWEB=1\n')
    for f in ("sessions.tsv", "blocklist"):
        open(E + "/data/" + f, "w").close()
    src = open(FILES + "/analyze.awk").read().replace('if (!REPLAY) { print out >> HIST; close(HIST) }', 'print out >> HIST; close(HIST)')
    open("/tmp/an_site.awk", "w").write(src)
    geo = {"lon": ("London", "GB", "United Kingdom", "Vultr Holdings LLC London", 4.2, 51.51, -0.02),
           "ams": ("Amsterdam", "NL", "Netherlands", "Vultr Holdings LLC Amsterdam", 9.4, 52.37, 4.89),
           "par": ("Paris", "FR", "France", "Vultr Holdings LLC Paris", 10.3, 48.91, 2.38)}
    now = int(time.time())
    plan = [  # scenario, ip, place, hours ago, marks (seconds in), probe kind
        ("fps", "203.0.113.67", "lon", 30, [], "serverudp"), ("fps", "198.51.100.141", "ams", 28, [], "serverudp"),
        ("badserver", "203.0.113.99", "lon", 26, [42], "serverudp"), ("fps", "203.0.113.104", "lon", 6, [], "serverudp"),
        ("clump", "192.0.2.47", "par", 5, [61, 120], "server"), ("fps", "203.0.113.67", "lon", 4, [], "serverudp"),
        ("badpc", "198.51.100.236", "ams", 3, [30], "serverudp"), ("fps", "203.0.113.144", "lon", 1, [88], "serverudp")]
    T0 = 1794320000
    for sc, ip, g, hrs, marks, kind in plan:
        city, cc, country, org, ping, glat, glon = geo[g]
        off = now - hrs * 3600 - T0
        random.seed(hash((sc, ip, hrs)) & 0xffff)
        rough = sc == "clump"
        psum = f"""far_kind={kind}
far_ip={ip}
far_n=300
far_loss={48 if kind == 'serverudp' else (2.5 if rough else 0)}
far_med={ping + random.uniform(-0.3, 0.3):.1f}
far_p95={ping + 1:.1f}
far_jit={6.5 if rough else 0.3}
near_ip=198.51.100.1
near_n=300
near_loss=0
near_med=3.7
near_jit=0.3
lan_n=300
lan_loss=0
lan_med=0.2
lan_jit=0.05
cc={cc}
country={country}
city={city}
lat={glat}
lon={glon}
isp=Vultr
org={org}
asn=AS20473
hops=11
qos_state=top
qos_class=top-queue
"""
        open("/tmp/site_sum.txt", "w").write(psum)
        lines = subprocess.run(["python3", ROOT + "/test/gen.py", sc], capture_output=True, text=True).stdout.splitlines()
        out, ms = [], [T0 + m for m in marks]
        for l in lines:
            p = l.split(" ", 1)
            t = float(p[0])
            while ms and t >= ms[0] + 0.5:
                out.append(f"MARK {ms.pop(0) + off}")
            out.append(f"{t + off:.6f} {p[1]}".replace("203.0.113.128", ip).replace(".30120", ".44998"))
        subprocess.run(["busybox", "awk", "-v", "REPLAY=1", "-v", "PROBESUM=/tmp/site_sum.txt", "-v", "DATA=" + E + "/data", "-v", "RUN=/tmp/none",
                        "-v", "DETAILDIR=" + E + "/data/matches", "-f", "/tmp/an_site.awk"], input="\n".join(out) + "\n", capture_output=True, text=True)
    # add a fake route trace to each detail file (replay mode has none)
    for f in os.listdir(E + "/data/matches"):
        d = json.load(open(E + "/data/matches/" + f))
        d["trace"] = [" 1  198.51.100.1  3.2 ms", " 2  100.64.0.64  3.1 ms", " 3  100.64.0.74  3.7 ms", " 4  192.0.2.180  5.7 ms", " 5  192.0.2.36  3.9 ms",
                      " 6  192.0.2.32  8.6 ms", " 7  *", " 8  *", f" 9  {d['ip']}  {d['ping']} ms"]
        random.seed(d["id"])
        base = d["ping"] or 5
        d["tl_p"] = [round(base + random.uniform(-0.3, 0.4) + (9 if (i % 173) == 60 else 0), 1) for i in range(len(d["tl_d"]))]
        json.dump(d, open(E + "/data/matches/" + f, "w"))
    if not os.path.islink(E + "/run/www/matches"):
        os.symlink(E + "/data/matches", E + "/run/www/matches")
    subprocess.run(MW + ["_export"], env=ENV)
    open(E + "/web/matchwatch/index.html", "w").write(open(FILES + "/public.html").read())
    for f in ("dashboard.js", "dashboard.css"):
        open(E + "/web" + RES + "/" + f, "w").write(open(ROOT + "/luci-app-matchwatch/htdocs" + RES + "/" + f).read())
    if not os.path.islink(E + "/web/matchwatch/data"):
        os.symlink(E + "/run/www", E + "/web/matchwatch/data")


def live(on=True, lobby=None):
    now = int(time.time())
    random.seed(11)
    d = [round(random.uniform(48, 53), 1) for _ in range(120)]
    d[40], d[41], d[95] = 265.3, 98, 150
    u = [round(random.uniform(7, 14), 1) for _ in range(120)]
    u[70] = 166
    p = [round(random.uniform(4.0, 4.6), 1) for _ in range(120)]
    p[40], p[41] = 13.5, 8.0
    sess = [{"ip": "203.0.113.144", "port": 44998, "device": "192.168.1.50", "age": 412, "start": now - 412, "loc": "London, GB", "org": "Vultr Holdings LLC London",
             "tick": 20.9, "jit": 1.33, "late": 0.02, "lost": 0, "uprate": 150.4, "upjit": 3.5, "s_lost": 0.12, "s_frz": 1, "s_hitch": 1, "rep": 96, "repn": 1, "ping": 4.2,
             "tl_d": d, "tl_u": u, "tl_p": p, "marks": [{"t": now - 76, "k": "server+ping", "x": "server updates stalled: one arrived 217 ms late; ping jumped to 14 ms (normally 4)"}]}] if on else []
    json.dump({"ts": now, "sessions": sess, "candidates": 0, "flows": 3}, open(E + "/run/www/status.json", "w"))
    if lobby:
        json.dump(dict(lobby, ts=now - 5), open(E + "/run/www/lobby.json", "w"))
    elif os.path.exists(E + "/run/www/lobby.json"):
        os.remove(E + "/run/www/lobby.json")


class H(http.server.SimpleHTTPRequestHandler):
    def __init__(self, *a, **k):
        super().__init__(*a, directory=E + "/web", **k)

    def log_message(self, *a):
        pass

    def do_POST(self):
        # the one thing the view-only page can do: record an "I felt that" moment
        self.rfile.read(int(self.headers.get("Content-Length", 0)))
        ok = self.path == "/cgi-bin/matchwatch-mark" and subprocess.run(MW + ["mark"], env=ENV).returncode == 0
        payload = b'{"ok":true}' if ok else b'{"ok":false}'
        self.send_response(200)
        self.send_header("Content-Type", "application/json")
        self.end_headers()
        self.wfile.write(payload)


if __name__ == "__main__":
    if sys.argv[1] == "build":
        build()
        live(True)
        print("built", E)
    elif sys.argv[1] == "serve":
        socketserver.TCPServer.allow_reuse_address = True
        with socketserver.TCPServer(("127.0.0.1", 8770), H) as s:
            s.serve_forever()
