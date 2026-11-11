#!/usr/bin/env python3
"""Screenshot every page of the view-only dashboard. Buttons that change things live in LuCI and are tested on a router."""
import json, sys, subprocess, time
from playwright.sync_api import sync_playwright

import os
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import mksite

OUT = os.path.join(os.path.dirname(os.path.abspath(__file__)), "shots") + "/"
os.makedirs(OUT, exist_ok=True)
BASE = "http://127.0.0.1:8770/matchwatch/"
errs = []
with sync_playwright() as p:
    b = p.chromium.launch()
    ctx = b.new_context(viewport={"width": 1180, "height": 900}, color_scheme="dark")
    pg = ctx.new_page()
    pg.on("pageerror", lambda e: errs.append("pageerror: " + str(e)))
    pg.on("console", lambda m: errs.append("console: " + m.text) if m.type == "error" and "lobby.json" not in m.text and "404" not in m.text else None)

    def shot(name, full=True):
        pg.wait_for_timeout(700)
        pg.screenshot(path=OUT + name + ".png", full_page=full)

    mksite.live(True)
    pg.goto(BASE + "#/tools"); pg.wait_for_timeout(1200); shot("tools")

    pg.goto(BASE + "#/"); pg.wait_for_timeout(1500); shot("live")
    mksite.live(True, {"ip": "192.0.2.47", "port": 44998, "loc": "Paris, FR", "org": "Vultr Holdings LLC Paris", "ping": 10.2, "verdict": "far", "blocked": False,
                       "msg": "Heading to Paris, FR (Vultr Holdings LLC Paris), about 10.2 ms. This server rated 36/100 over 1 match(es). That is poor: consider backing out."})
    mksite.live(False, json.load(open(mksite.E + "/run/www/lobby.json")))
    pg.wait_for_timeout(2500); shot("live_lobby", full=False)
    mksite.live(True)

    pg.goto(BASE + "#/match/last"); pg.wait_for_timeout(1200); shot("match_good")
    hist = json.load(open(mksite.E + "/run/www/history.json"))
    bad = [m for m in hist if m["code"] == "server"][0]
    pg.goto(BASE + "#/match/" + str(bad["start"])); pg.wait_for_timeout(1200); shot("match_bad")
    pg.goto(BASE + "#/matches"); shot("matches")

    pg.goto(BASE + "#/servers"); pg.wait_for_timeout(900); shot("servers")

    # phone
    ph = b.new_context(viewport={"width": 390, "height": 844}, color_scheme="dark", device_scale_factor=2).new_page()
    ph.goto(BASE + "#/match/" + str(bad["start"])); ph.wait_for_timeout(1500); ph.screenshot(path=OUT + "phone_match.png", full_page=True)
    ph.goto(BASE + "#/"); ph.wait_for_timeout(1500); ph.screenshot(path=OUT + "phone_live.png", full_page=True)
    b.close()
print("errors:", errs)
