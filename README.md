# MatchWatch

**Judges every online match from your OpenWrt router — v0.10.1 (pre-release)**

> **OpenWrt only.** MatchWatch runs on a router with [OpenWrt](https://openwrt.org/) firmware and appears inside LuCI, OpenWrt's web interface. It does not run on Windows, macOS, a games console, or a router with its maker's stock firmware. Nothing is installed on your PC or console.

![Live dashboard](docs/live.png)

MatchWatch watches your game's traffic as it passes through an OpenWrt router and tells you where a bad match came from: the game server, the route to it, your own line, or your PC. It lives in LuCI under **Services → MatchWatch**.

It works from packet timing only. Game traffic is never decoded, changed, delayed or injected, so it has no effect on your ping and nothing for anti-cheat to object to. Blocking servers and changing QoSmate rules do change what the router does, and only happen when you press the button for them.

> **Status:** an early release, tested with one game on one router running OpenWrt 25.12. Capture, scoring, the dashboard and the commands behind every button have run on that router. The LuCI app is new in 0.10.0. Scores are a diagnostic estimate, not proof of a server's health. See [Limits](#limits).

## What it does

- Spots a match on its own: any steady two-way UDP stream from your gaming device.
- Measures how evenly the server's updates arrive: tick rate, jitter, late, clumped and missing updates, stutters and freezes.
- Pings the server, the first hop inside your ISP and your PC throughout the match, to split the blame.
- Gives each of the four links a score out of 100 and names the weakest.
- Keeps a history with a full report and chart for each match, and ratings per server and datacentre.
- Has an "I felt that" button: press it when something feels off and it shows what the network was doing.
- Can block bad servers or datacentres, or keep you to a pool of places you choose.
- Can alert your phone through ntfy, and check that QoSmate is prioritising your game.
- Needs no account and no cloud service. It is a shell script, two awk programs and a LuCI app.

| Live | Match report |
| --- | --- |
| ![Live](docs/live.png) | ![Match report](docs/match-report.png) |

| Matches | Servers |
| --- | --- |
| ![Matches](docs/matches.png) | ![Servers](docs/servers-pool.png) |

The screenshots are made from invented data (`test/mockshots.py`); the addresses and matches in them are not real.

## Install

MatchWatch only works on OpenWrt. You need:

- A router running OpenWrt 22.03 or newer, with LuCI. It must be the router your gaming device connects through, so it sees the game's traffic.
- SSH access to it as root.
- A few megabytes of free storage.

If your router runs its maker's own firmware, check whether OpenWrt supports it at [openwrt.org/toh](https://openwrt.org/toh/start) first.

1. SSH to the router and download the installer:

   ```sh
   uclient-fetch -O /tmp/matchwatch-install.sh https://raw.githubusercontent.com/ItsGix/matchwatch/main/dist/matchwatch-install.sh
   ```

2. Run it with your gaming PC's or console's IP address:

   ```sh
   sh /tmp/matchwatch-install.sh 192.168.1.50
   ```

   Leave the address off to watch every device, or choose the device later in LuCI.

3. Log out of LuCI and back in, then open **Services → MatchWatch**. The menu entry only appears after a fresh login.

4. Give your gaming device a fixed address in LuCI under Network → DHCP and DNS → Static Leases, so MatchWatch does not lose track of it.

Then play a match. It shows up on the Live page within about ten seconds.

If the router cannot download the file, fetch [`dist/matchwatch-install.sh`](dist/matchwatch-install.sh) on a computer and copy it over with `scp matchwatch-install.sh root@192.168.1.1:/tmp/`.

**What the installer does.** Read it before you run it: it runs as root. It installs `tcpdump` if missing, copies the program and the LuCI app into place, creates `/etc/config/matchwatch`, starts the service and runs a self-check. It works on both `apk` (OpenWrt 25.12) and `opkg` (older releases).

**Updating.** Run the new installer the same way. History and settings are kept. Settings from versions before 0.10.0 are carried over automatically.

**After a firmware upgrade.** History and settings survive, but the program is removed. Run the installer again.

**Removing.**

```sh
sh /tmp/matchwatch-install.sh remove
```

keeps your history and settings. Use `purge` instead of `remove` to delete those too.

## Use

**Services → MatchWatch** has two tabs.

### Dashboard

- **Live**: the match in progress, with ping, update rate, jitter, late and missing updates, freezes, your PC's send rate and pauses, a two-minute chart, and the "I felt that" button. When the game starts connecting you somewhere, a banner says where, how far, and how that server has rated.
- **Last match**: the full report for one match: verdict, the four links in the chain, a chart of the whole match, every figure, the route trace and your marks.
- **Matches**: every recorded match, your latest session in a sentence, and ratings by hour of the day.
- **Servers**: datacentres, regions and servers with their ratings, and buttons to block, unblock or stay on them.
- **Tools**: the QoSmate check, the self-check and the settings in use.

### Settings

The device to watch, phone alerts, blocking and staying, and the advanced capture options. Saving restarts MatchWatch, which ends the recording of a match in progress, so change settings between matches.

### The dashboard without login

Turn on "Dashboard without login" in Settings to also serve the dashboard at `http://<router address>/matchwatch/` to anyone on your network. It is meant for a phone or a second screen. That copy is view only: it shows everything, and its one button is "I felt that". Nothing can be blocked or changed from it. It is off by default.

### Commands

Everything is also available over SSH:

| Command | What it does |
|---|---|
| `matchwatch live` | The match in progress, updated every second |
| `matchwatch last` | Full report for the last match, with the route trace |
| `matchwatch history` | Recent matches. Add a number for more, or a server IP for one server |
| `matchwatch servers` / `datacentres` | Everything seen, worst first |
| `matchwatch block <ip> [days]` | Block a server (14 days by default, `0` = until unblocked) |
| `matchwatch unblock <ip>` or `all` | Remove a block |
| `matchwatch block-dc <n>` / `unblock-dc <n>` | Block or unblock the address blocks seen in datacentre n |
| `matchwatch stay <places>` / `stay off` | Keep to a pool of places, separated by commas |
| `matchwatch stay add <places>` / `stay remove <n>` | Change the pool |
| `matchwatch hours` / `recap` / `games` | Ratings by hour, the latest session, games seen |
| `matchwatch places` | The areas you can stay on |
| `matchwatch regions [measure]` | Ping every region, nearest first |
| `matchwatch blocklist` | What is blocked and for how long |
| `matchwatch mark` | Flag this moment, same as the "I felt that" button |
| `matchwatch qos` | During a match: is the game in QoSmate's top priority queue? |
| `matchwatch qos fix` / `qos unfix` | Add or remove QoSmate rules that prioritise your gaming device |
| `matchwatch device [<ip>\|all]` | List the devices on your network and choose which to watch |
| `matchwatch doctor` | Checks that capture works |

Settings live in `/etc/config/matchwatch`. To change one over SSH: `uci set matchwatch.main.<option>=<value>`, `uci commit matchwatch`, then `/etc/init.d/matchwatch restart`.

## What it measures

**Server rhythm.** A server sends updates on a fixed beat. MatchWatch measures how evenly they arrive:

- Update rate: the server's tick rate as seen on the wire.
- Timing jitter: average wobble around the beat.
- Late updates: arrived well after their slot.
- Arrived in clumps: held up somewhere, then delivered together. This points at the route.
- Missing updates: never arrived. Lost in transit or never sent.
- Stutters and freezes: gaps over 50 ms and 100 ms.

**Route.** One ping a second to the server during the match. If the server ignores ping but can be reached the way traceroute reaches it, it is probed that way every two seconds instead; servers ration those replies, so unanswered ones are not counted as loss. Failing that, the last hop that answers is used and judged more leniently. When the game's own traffic arrived cleanly, a rough-looking probe is shown but not counted.

**Your line.** One ping a second to the first hop inside your ISP.

**Your PC.** Whether your PC keeps sending without pauses, measured as its packets arrive at the router, plus a ping from router to PC if the PC answers. Only pauses over 100 ms are scored; they usually mean frame drops or a loading screen. Send jitter is shown but barely scored, because games tie their send rate to frame rate. Turn off "Count your PC towards scores" in Settings to leave your PC out of the overall score and verdict.

Each part gets a score out of 100. The verdict names the weakest part. Scoring starts when steady game traffic begins, so the wait before a match is not counted, and sessions with under a minute analysed are not judged.

## "I felt that"

Press the button on the Live page (or the M key with the page focused) when something feels off: a shot that should have hit, a rubber-band, a death behind cover. MatchWatch looks at the six seconds before the press and says whether the server stalled, your ping jumped, your PC stopped sending, or nothing showed on the network at all. Marks appear on the chart, in the match report and in the history.

## Lobby alert

When the game first contacts a server it recognises as a game server (same port or address block as an earlier match), MatchWatch looks up where it is, measures the ping and checks its history. The Live page shows the result, with a button to block the server before the match starts. With phone alerts set up, you are notified when the server is noticeably further than your best datacentre or has rated badly. It needs at least one recorded match before it can recognise game servers.

## Blocking

Blocks live in their own nftables table, so your firewall rules are untouched. A blocked server can't be reached, so the game has to place you elsewhere.

- Blocking takes effect on your next match. Never block the server you are playing on unless you want to be disconnected.
- Server addresses are reused, so blocks expire ("Blocks last" in Settings).
- Blocking many servers lengthens matchmaking.
- Automatic blocking is off by default. When on, a server is blocked after two counted matches averaging under 45.
- Individual addresses rotate, so ratings are also grouped by datacentre: one operator in one city. Blocking a datacentre blocks every /24 address block you have been placed on there. It can't know the datacentre's other blocks.

A match only counts towards a server's rating when it lasted at least a minute and your own line was stable.

## Staying in a pool of places

`matchwatch stay <places>`, the box on the Servers page, or a "Stay here" button keeps you to servers in the places you choose, whoever hosts them. Give one place or several, separated by commas:

- **A city**: `milan`, `helsinki`. Servers within 150 km of it are allowed. Cities in the regions table work offline; any other city name is looked up with the Open-Meteo geocoding service, which is sent only the name you typed.
- **A country**: `italy` or `it`.
- **An area**: `western-europe`. `matchwatch places` lists them.
- **A datacentre number** from `matchwatch datacentres`.

Several places make one pool, and the game picks among them. A bigger pool means shorter queues than a single place.

How it works: every address block you have played on outside the pool is blocked at once, and when the game starts connecting to any other server, MatchWatch looks up where it is and turns it away if it is outside the pool. The game then searches again.

What to expect:

- The game decides which regions to offer you. Places it already gives you work well. Far ones may take several failed connections, or never come up.
- It applies to servers MatchWatch recognises as game servers. Play one match of a new game first.
- Server locations come from a public lookup and are occasionally wrong.
- A place is dropped from the pool, and you are told, if its last three counted matches average under the warning rating. When the pool is empty stay mode ends.

## Every region

The table on the Servers page, or `matchwatch regions`, shows the ping from your router to about thirty datacentre regions worldwide. It pings the public test server that Vultr, the host of every Call of Duty server seen so far, runs in each of its datacentres. It refreshes every six hours and on "Measure now". It is not a complete list of where the game has servers.

## QoSmate check and fix

Once per match, and on demand, MatchWatch checks that the game's traffic is in QoSmate's top priority queue. It compares the packet count in the top queue with what the game is sending, and reads the priority mark on the game's packets.

If the game is not prioritised, "Prioritise my game traffic" on the Tools page (or `matchwatch qos fix`) adds two QoSmate rules, `matchwatch_out` and `matchwatch_in`. They mark all UDP to and from your gaming device, except web ports 80 and 443, as EF, which is top priority in every QoSmate mode. QoSmate is then restarted, which causes a brief blip, so do it between matches. "Remove those rules" takes them out again.

This only happens when you ask for it. If you already have rules named `Game_Outbound` and `Game_Inbound`, made from commands an older version printed, the fix adopts and renames them, and "Remove those rules" then deletes them.

## Phone alerts

Install the ntfy app, subscribe to a hard-to-guess topic, and put `https://ntfy.sh/<your topic>` under Alerts in Settings. You get an alert when you land on a server with a bad history, and after bad matches. Turn on "Alert when a match starts" to also be told the moment the game itself begins, which helps if you step away during a long queue.

## Privacy and security

- The dashboard and every button sit behind the LuCI login. Each action is checked against the logged-in account's permissions, with looking and changing granted separately.
- The optional dashboard without login is view only and off by default.
- Keep LuCI on a network you trust and never expose it through a public port forward.
- Server locations come from ip-api.com; only the server's IP address is sent. Turn off "Look up where servers are" to stop this (staying on places and the lobby alert need it on).
- Nothing else leaves your router unless you set up phone alerts.
- The project has not had a security audit.

## Limits

- Other steady two-way UDP streams, such as voice chat, are recorded as matches too. "Only look at this traffic" under Advanced narrows capture, for example `port 3074 or portrange 30000-45000` for Call of Duty.
- IPv4 only.
- When neither the server nor any hop near it answers ping, uneven delivery can't be split between server and route. The report says so.
- Scores were first calibrated from simulated traffic. Expect the thresholds to need tuning against real matches.
- Tested on one router and mostly one game. Not yet proven on a real router: the lobby alert, staying on places against real matchmaking, and the QoSmate fix buttons. [`CLAUDE.md`](CLAUDE.md) keeps the current list.

## For developers

| Path | Purpose |
| --- | --- |
| `files/matchwatch` | The service and CLI, including the actions the dashboard's buttons run (POSIX shell for BusyBox ash) |
| `files/analyze.awk` | Packet timing, flow detection and scoring |
| `files/report.awk` | Reports and JSON exports |
| `files/matchwatch.config` | Default settings, installed as `/etc/config/matchwatch` |
| `files/public.html` | Shell page for the dashboard without login |
| `files/*.list` | Region probes, places and game-port labels |
| `luci-app-matchwatch/htdocs/` | The dashboard, and the LuCI Dashboard and Settings pages |
| `luci-app-matchwatch/root/` | LuCI menu entry, permissions and the rpcd backend the buttons call |
| `build.py` | Builds the one-file installer |
| `dist/matchwatch-install.sh` | The installer |
| `test/` | Simulated traffic, stand-ins for router tools, a test site for the view-only dashboard, and `mockshots.py`, which makes the screenshots |

After changing anything in `files/` or `luci-app-matchwatch/`, rebuild the installer:

```sh
python3 build.py
```

Replay a simulated match through the engine (needs BusyBox):

```sh
python3 test/gen.py good | busybox awk -v REPLAY=1 -v DATA=/tmp/none -v RUN=/tmp/none -f files/analyze.awk
```

Scenarios: `good`, `badserver`, `clump`, `badpc`, `frag`, `lobby`, `noise`, `fps`, `handshake`, `short`. [`CLAUDE.md`](CLAUDE.md) has the developer notes and the list of what has been proven on a real router.

## Licence

This is an experimental personal project. Issues and feedback are welcome. **No open-source licence has been chosen yet**, so the source being public does not grant rights to reuse or redistribute it.
