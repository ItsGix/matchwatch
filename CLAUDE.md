# matchwatch: notes for whoever works on this next

matchwatch runs on an OpenWrt router and judges each online match: the game server, the route to it, the player's own line and their PC. It works from packet timing only and never alters game traffic. Version 0.19.1.

## Layout

- `files/matchwatch`: the CLI and service (POSIX sh for BusyBox ash). Capture, probes, blocking, stay mode, lobby alert, share files, QoSmate check and fix, and `_action`, which runs the dashboard's buttons.
- `files/analyze.awk`: the engine. Reads `tcpdump -tt -n -q -l` lines plus `TICK` heartbeats, tracks flows, scores sessions, writes history and per-match detail JSON.
- `files/report.awk`: every report and JSON export built from `sessions.tsv` (history, servers, datacentres, regions, stay lookups, hours, recap, games).
- `files/matchwatch.config`: default settings, installed as `/etc/config/matchwatch`. The script's own defaults cover anything missing.
- `files/public.html`: shell page for the optional dashboard without login.
- `files/*.list`: Vultr region ping hosts, countries and areas for stay mode, game labels by port.
- `luci-app-matchwatch/htdocs/luci-static/resources/matchwatch/dashboard.js` and `.css`: the dashboard, vanilla JS, hash routes (Live, Last match, Matches, Servers, Tools). One copy, two homes. Whoever hosts it passes in how to talk to the router (`T.get`, `T.act`), and it draws inside a shadow root so the LuCI theme and the dashboard cannot disturb each other's styling.
- `luci-app-matchwatch/htdocs/luci-static/resources/view/matchwatch/`: the LuCI pages. `dashboard.js` hosts the dashboard, reading data with `file.read` and running buttons through rpcd. `settings.js` is a native form on `/etc/config/matchwatch`.
- `luci-app-matchwatch/root/`: menu entry (Services, MatchWatch), permissions (`acl.d`), and the rpcd backend `luci.matchwatch` with two methods, `read` and `write`, so permissions can tell looking from changing. It calls `matchwatch _action`.
- `packs/`: community share files (game packs) and the format and acceptance rules for them. Not installed; people import what they choose.
- `build.py`: bundles both directories into `dist/matchwatch-install.sh` (heredocs). Run it after any change to either.
- `test/`: traffic generator, stand-ins for router tools, a test site serving the view-only dashboard, Playwright screenshots. `test/mockshots.py` makes `docs/*.png` from invented data with headless Edge or Chrome and Pillow; it needs no router or BusyBox.
- Privacy: the repository is public. Nothing from a real network goes in it: no real LAN, ISP or game server addresses, device names, match history or screenshots of real data. Tests and screenshots use the documentation ranges 192.0.2.0/24, 198.51.100.0/24 and 203.0.113.0/24. Commit with a GitHub no-reply address.

On the router: `/usr/bin/matchwatch`, `/usr/lib/matchwatch/`, `/etc/config/matchwatch` (settings), `/etc/matchwatch/` (`sessions.tsv`, `matches/*.json`, blocklist, stay, `games.local`, `regions.local`, `ratings.shared`, `favourites`, `share.undo/`), `/tmp/matchwatch/` (runtime; `www/` holds the JSON the dashboard reads), the LuCI files under `/www/luci-static/resources/` and `/usr/share/`. With the no-login page on, the service also creates `/www/matchwatch/` and `/www/cgi-bin/matchwatch-mark` at start, and removes them when it is off.

Settings: the script reads `/etc/config/matchwatch` through `config_get`. With `MW_CONF` set it sources that shell file instead, which is how the tests run it off-router. Versions before 0.10.0 kept settings in `/etc/matchwatch/config`; `matchwatch _migrate` (run by the init script) carries them over once and renames the file to `config.imported`. Saving in LuCI fires the init script's reload trigger, which restarts the service.

Slow tools: an rpcd call must answer within seconds, so the line test and route trace start in the background, print a job number, and write `linetest.json` or `trace.json` into `/tmp/matchwatch/www/`. The dashboard's `job()` polls that file until its `id` matches. Follow the same pattern for anything that takes more than a few seconds.

Share files (`matchwatch share export|check|import|undo|forget`, 0.14.0): one text file, first line `matchwatch-share 1`, sections `[games]` `[regions]` `[places]` `[ratings]` `[settings]` `[favourites]`. A favourites line is `server|game|city|cc|host|rating|matches|lat|lon`; `report.awk` MODE `share_servers` writes them. Two extra names are not sections: `allservers` (export every server as a candidate, with a tenth field marking favourites, for the dashboard's picker) and `favplaces` (import: add the cities of the file's favourite servers to the stay pool). `share_load` checks every line in one awk pass and writes the good ones to a temp folder; import then merges them into `games.local`, `regions.local`, `stay`, `ratings.shared` and the settings, after copying the old files to `share.undo/`. From the dashboard the file's text travels as the `data` argument of the rpcd `write` method and reaches `_action` on standard input. Unknown sections are skipped, so later versions can add some. Choosing single items to share is done in the dashboard only (`sharePicker`): it asks for the full export, shows a tick per line, and builds the file text in the browser.

Favourites (0.15.0): `/etc/matchwatch/favourites` holds one server per line: the address, then for ones taken from a share file the game, city, country and host, tab separated (`matchwatch fav add|remove`, actions `fav`/`unfav`). `cmd_block` refuses an automatic block of a favourite, and the lobby message names one. Grouping by game is done in the dashboard from the match history, falling back to the game stored with an imported favourite (`gameOf`).

Dashboard look (0.15.0): colours and radii are variables at the top of `dashboard.css`; the chart reads the same variables. Buttons are a quiet fill (`--soft`), `solid` for the main action, `danger` for destructive ones. The Tools page is four tabs (`TOOLTABS`, addresses `#/tools/<tab>`) of rows built by `tool(title, description, controls...)`: say what a tool does on the left, put its control and result on the right. Check both themes after a style change (`dark:` in the mock page of `test/mockshots.py`).

Removing (0.17.0): `cmd_forget match|server|dc` rewrites `sessions.tsv` without the chosen rows, deletes their `matches/<start>.json`, re-exports, and restarts the engine only when no match is in progress (its ratings live in memory). It refuses a favourite server, and a datacentre holding one. Actions `forgetmatch`, `forgetserver`, `forgetdc`.

QoSmate match record (0.18.0): `qm_loop` (started by `_probe_start`) saves cake's per-queue counters from `tc -s qdisc` for the WAN port and `ifb-<wan>` at match start and tracks the peak `pk_delay` every five seconds; `qm_sum` (in `_probe_stop`) writes the differences as one line of JSON, `qm.json`, which the engine copies into the match detail as `qm`. The last column of cake's table is taken as the top queue. Read only. Proven on cake diffserv3 only; nothing is written in HFSC mode.

Unnamed ports (0.18.0): a stream on a port with no label is kept only if at least 120 s were analysed and under 15% of updates were missing; otherwise it is dropped at `session_end`, logged, and listed in `skipped.json` with a reason. The 15% line comes from a single real example (a 42 s stream at 28%), so expect to tune it. No match-started alert is sent for an unnamed port.

## Rules that have bitten already

- Phone alerts are one short line with no addresses or host names; the full sentence goes to the log and the dashboard. The owner found five long turn-away alerts in a minute too much: a stay-mode turn-away only reaches the phone on `lobby_alert` 2, and lobby alerts are limited to one a minute.
- In `cmd_lobby` the stay decision comes before any ping or traceroute. Measuring first let the game join the server and then threw the player out.
- `stay_apply` keeps the stay blocks that are still outside the pool (placed by `geo.cache`). It once rebuilt them from the match history alone, which dropped every block made as the game tried a server never played on; changing the pool then let the game straight onto one of those.
- `stay_apply` never blocks the address block of a match in progress (read from `status.json`); `cmd_after` applies it once the match has ended.

- BusyBox awk only. No `cos`, `sqrt` or other maths functions (some builds lack them), no gawk extensions. Distances are compared squared with a cosine series.
- BusyBox ash only. No bashisms. Test with `busybox ash -n` and `busybox awk`.
- Game traffic is the ground truth. Probe results (ping, traceroute-style UDP) only split blame; they never lower a score when the game's own packets arrived cleanly. Servers ration UDP probe replies, so unanswered ones are not loss.
- Scoring starts when steady traffic begins (`session_start` resets the accumulators). Games often handshake, wait about 30 s, then start the stream.
- PC send rate follows frame rate, so only pauses over 100 ms are scored for the PC.
- tcpdump on the WAN port sees packets after the qdisc, so cake's `wash` shows DSCP 0. The QoSmate check relies on queue counters first.
- Voice chat must never be cut off. Stay mode, the lobby alert and auto-block act only on servers labelled as a game in `games.list` or `games.local` (`kindof`/`isgame` in the engine, `which_label`/`is_game_port` in reports). Voice streams (`kind` = `voice`) are not tracked at all: no session, no probes, no alerts. Unlabelled ports are tracked and rated but never blocked. `games.local` is read first, so naming a port or range makes it a game. The engine re-reads both files every 20 ticks.
- Labels are `name|ports|kind|hosts`, first match wins. `hosts` are words looked for in the server's isp, org and AS name; a label with hosts only matches once the lookup is in `geo.cache` (the engine asks with `matchwatch _geo <ip>`), and until then the stream falls through to later labels. This exists because ports overlap badly: Roblox and Discord voice share 50000-65535, Valorant sits inside Rocket League's range, Apex inside Call of Duty's. Reports only have org and the AS number, so give host-checked labels the AS number too (`roblox,as22697`). Put narrow and host-checked lines above wide ones. Never add a wide range without a host check: it turns every unknown stream in that range into a "game" that stay mode may block.
- Publishers' port lists mostly do not say whether a port is the server's or the player's, and many are missing. `games.list` marks lines without a publisher source as unconfirmed. Do not add a game from memory; find a source.
- The lobby alert needs both tests: a game-labelled port, and a port or /24 that carried an earlier match (`KPORT`, `K24`). A patch once dropped the second test; game port ranges are wide (30000-45000), and calls and peer-to-peer traffic use ports inside them, so with stay mode on that would have blocked non-game servers.
- Share files come from strangers. Import must never be able to block a server or widen what counts as a game without a check: ratings from others are display only (`ratings.shared` is never read by auto-block or stay mode), a game label over 2000 ports wide needs hosts, host words need three characters, settings are a fixed list of numeric keys with ranges (never `autoblock`, `ntfy_url`, `device_ip`, `only_filter`), and region hosts must be names, not addresses. Export must never include the device, LAN or ISP addresses, or match times.
- `matchwatch game name <port or lo-hi> <name> [hosts] [voice]` and `game remove` are the only writers of hand-made labels (actions `gamename`, where `region` carries the host words and `days` = 1 means not a game, and `gamedel`). They refuse a range over 2000 ports with no host words, the same rule as imports.
- A name given by hand goes at the top of `games.local` so it beats an imported label covering the same port; imported labels are appended.
- A patch script once emptied `files/matchwatch` by opening it for writing before reading. Check file sizes after scripted edits.
- Python run from a Git Bash heredoc turns `\\n` inside its strings into real newlines. Write patch scripts to a file and run the file.
- Unix line endings everywhere. On Windows, Python writes CRLF by default and Git for Windows checks files out with CRLF; either breaks every script on the router. `.gitattributes` forces LF and `build.py` writes LF. To count carriage returns in Git Bash use `tr -cd '\r' < file | wc -c`: `grep -c $'\r'` there matches every line, which once made clean files look broken.
- A LuCI session gets its permissions at login. After installing the app, an already logged-in browser must log out and in before Services, MatchWatch appears or its buttons work.
- The router's BusyBox `nc` has no `-l` or `-w`, and `uclient-fetch --post-data` sends chunked bodies. To exercise the backend from the router's shell use `ubus call luci.matchwatch read '{"action":"doctor"}'`.

## Testing

```
python3 test/gen.py good | busybox awk -v REPLAY=1 -v DATA=/tmp/none -v RUN=/tmp/none -f files/analyze.awk
```

Scenarios: good, badserver, clump, badpc, frag, lobby, noise, fps, handshake, short. `-v PROBESUM=test/sum_serverok.txt` supplies simulated probe results. `test/mksite.py build` then `serve` gives the view-only dashboard at `http://127.0.0.1:8770/matchwatch/`; `test/shots.py` screenshots it with Playwright. The buttons that change things run through LuCI and can only be tested on a router. Without BusyBox or dash to hand (a plain Windows machine, say), the shell files can still be syntax-checked by piping them to `ash -n /dev/stdin` on the router over SSH. Set `MW_CONF`, `MW_LIB`, `MW_RUN`, `MW_DATA`, `MW_SELF` to run the script off-router, with `test/stub` first on `PATH`.

## Proven on a real router (OpenWrt 25.12, QoSmate in cake diffserv3 mode)

Capture and scoring over several real matches, the UDP probe for servers that ignore ping, the live dashboard, the "I felt that" button, and the QoSmate queue-counter check.

The commands behind the dashboard buttons, each run and then undone: block and unblock (one address, a /24, until unblocked), refusal of bad and private addresses, datacentre block and unblock, stay mode with a city, a country, an area, a datacentre number and a city needing the online lookup, pool add, remove and replace, Measure now with real pings, the device picker with real DHCP leases and the service restart it triggers, the self-check. The nftables set is in its interval form.

0.10.0: the installer, the one-time settings import, the rpcd backend through `ubus call` (checks, block and unblock, stay on and off, refusal of a changing action through `read`, rejection of shell characters in arguments), `file.read` of the data files, and the no-login page.

Phone alerts through ntfy and the match-started alert were seen working on a real phone on 12 November 2026. The same night the engine's lobby check fired on a real Call of Duty lobby (a `LOBBY` line in `engine.log`, confirmed by the owner as a Call of Duty lobby). Stay mode turned away five real Call of Duty servers in a row on 12 November 2026 while the owner stayed on places abroad (whether the game then offers a server inside the pool is the game's choice and was not seen). The owner has used the LuCI dashboard pages daily since 0.15.0, including the Servers, Matches and Tools pages and their buttons.

## Not yet run on a real router

The Settings page's Save & Apply restarting the service. The lobby alert's message reaching the Live page or the phone (it only goes to the phone when the server is far or badly rated), the QoSmate check during a match on this version. From 0.18.0: the unnamed-port filter on a real stream, and the "QoSmate in this match" section as drawn in a browser (the match of 12 November 2026 has its `qm` record, and its alert read "Match started: United Kingdom, 4 ms.").

The QoSmate fix and unfix buttons. Note that fix adopts rules named `Game_Outbound` and `Game_Inbound` (made from commands an older version printed) by renaming them, so unfix afterwards deletes them and leaves the game unprioritised.

## Agreed next steps

1. Play a match on a real router to prove what is left in the list above.
2. Check the LuCI pages in a browser, then package the app (below).
3. Match mode for the house: hold back other devices' heavy traffic during a match.
4. Hop-by-hop blame when a route is bad.
5. A voice chat check (Discord, in-game voice) rated like matches. Discord voice is labelled and protected from blocking since 0.12.0; a verdict worded for calls rather than matches is still to do.
6. Share files exist since 0.14.0. Still to do: real game packs in `packs/` (each needs a source), a way to add a region ping host without editing `regions.local` by hand, and showing shared ratings on the Servers page beside your own.
7. Packaging and a write-up for the OpenWrt forum. The repository is public with no licence yet: choose one before packaging.

## Lines not to cross

No faking a bad connection or otherwise feeding false data to matchmaking to get easier opponents. Choosing or refusing servers by location and measured quality is fine; it is what a geo-filter does.
