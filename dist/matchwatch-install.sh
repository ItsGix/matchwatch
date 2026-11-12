#!/bin/sh
# matchwatch installer for OpenWrt. One file; contains everything, including the LuCI app.
#   sh matchwatch-install.sh [gaming-device-ip]   install or update
#   sh matchwatch-install.sh remove               uninstall (keeps your history and settings)
#   sh matchwatch-install.sh purge                uninstall and delete history and settings
R="${MW_ROOT:-}"

luci_refresh() {
	rm -f /tmp/luci-indexcache* 2>/dev/null
	[ -x /etc/init.d/rpcd ] && /etc/init.d/rpcd reload
}

if [ "$1" = remove ] || [ "$1" = purge ]; then
	[ -z "$R" ] && [ -x /etc/init.d/matchwatch ] && { /etc/init.d/matchwatch stop; /etc/init.d/matchwatch disable; }
	[ -z "$R" ] && nft delete table inet matchwatch 2>/dev/null
	rm -f "$R/usr/bin/matchwatch" "$R/usr/lib/matchwatch/analyze.awk" "$R/usr/lib/matchwatch/report.awk" "$R/usr/lib/matchwatch/public.html" "$R/usr/lib/matchwatch/config.uci" "$R/usr/lib/matchwatch/regions.list" "$R/usr/lib/matchwatch/geofeeds.list" "$R/usr/lib/matchwatch/countries.list" "$R/usr/lib/matchwatch/places.list" "$R/usr/lib/matchwatch/games.list" "$R/etc/init.d/matchwatch" "$R/usr/libexec/rpcd/luci.matchwatch" "$R/usr/share/luci/menu.d/luci-app-matchwatch.json" "$R/usr/share/rpcd/acl.d/luci-app-matchwatch.json" "$R/www/luci-static/resources/matchwatch/dashboard.js" "$R/www/luci-static/resources/matchwatch/dashboard.css" "$R/www/luci-static/resources/matchwatch/leaflet.js" "$R/www/luci-static/resources/matchwatch/leaflet.css" "$R/www/luci-static/resources/view/matchwatch/dashboard.js" "$R/www/luci-static/resources/view/matchwatch/settings.js"
	rm -f "$R/usr/lib/matchwatch/index.html" "$R/usr/lib/matchwatch/config.default" "$R/www/cgi-bin/matchwatch-api" "$R/www/matchwatch/index.html" "$R/www/matchwatch/data" "$R/www/cgi-bin/matchwatch-mark"
	rmdir "$R/usr/lib/matchwatch" "$R/www/matchwatch" "$R/www/luci-static/resources/matchwatch" "$R/www/luci-static/resources/view/matchwatch" 2>/dev/null
	[ -z "$R" ] && luci_refresh
	if [ "$1" = purge ]; then
		rm -f "$R/etc/config/matchwatch" "$R/etc/matchwatch/config" "$R/etc/matchwatch/config.imported" "$R/etc/matchwatch/sessions.tsv" "$R/etc/matchwatch/blocklist" "$R/etc/matchwatch/geo.cache" "$R/etc/matchwatch/last.txt" "$R/etc/matchwatch/token" "$R/etc/matchwatch/stay" "$R/etc/matchwatch/regions.tsv" "$R/etc/matchwatch/games.local" "$R/etc/matchwatch/regions.local" "$R/etc/matchwatch/ratings.shared" "$R/etc/matchwatch/favourites" "$R/etc/matchwatch/allow" "$R/etc/matchwatch/hold" "$R/etc/matchwatch/tried" "$R/etc/matchwatch/gameplaces.shared" "$R/etc/matchwatch/ranges.cache" "$R/etc/matchwatch/cities.cache" "$R/etc/matchwatch/geofeeds.local"
		rm -rf "$R/etc/matchwatch/share.undo"
		for f in "$R"/etc/matchwatch/matches/*.json; do [ -f "$f" ] && rm -f "$f"; done
		rmdir "$R/etc/matchwatch/matches" 2>/dev/null
		rmdir "$R/etc/matchwatch" 2>/dev/null
		echo "matchwatch removed, history and settings deleted."
	else
		echo "matchwatch removed. History kept in /etc/matchwatch, settings in /etc/config/matchwatch."
	fi
	exit 0
fi

[ -z "$R" ] && [ "$(id -u)" != 0 ] && { echo "Run this as root on the router."; exit 1; }
[ -z "$R" ] && [ ! -f /etc/openwrt_release ] && echo "Warning: this does not look like OpenWrt. Continuing anyway."
[ -z "$R" ] && [ ! -d /usr/share/luci/menu.d ] && echo "Warning: LuCI was not found. The dashboard lives in LuCI; without it only the commands work."

if [ -z "$R" ]; then
	for pkg in tcpdump traceroute; do
		command -v "$pkg" >/dev/null 2>&1 && continue
		[ "$pkg" = traceroute ] && continue
		echo "Installing $pkg..."
		if command -v apk >/dev/null 2>&1; then apk update >/dev/null 2>&1; apk add tcpdump || apk add tcpdump-mini
		elif command -v opkg >/dev/null 2>&1; then opkg update >/dev/null 2>&1; opkg install tcpdump || opkg install tcpdump-mini
		fi
	done
	command -v tcpdump >/dev/null 2>&1 || { echo "Could not install tcpdump. Install it by hand, then run this again."; exit 1; }
fi

mkdir -p "$R/etc/config" "$R/etc/init.d" "$R/etc/matchwatch" "$R/usr/bin" "$R/usr/lib/matchwatch" "$R/usr/libexec/rpcd" "$R/usr/share/luci/menu.d" "$R/usr/share/rpcd/acl.d" "$R/www/luci-static/resources/matchwatch" "$R/www/luci-static/resources/view/matchwatch"
cat > "$R/usr/bin/matchwatch.new" <<'MW_FILE_END_0'
#!/bin/sh
# matchwatch - judges game servers, the route to them, your line and your PC
# from packet timing, on an OpenWrt router. Passive: it never alters game traffic.

VERSION="0.25.0"
CONF="${MW_CONF:-}"	# tests point this at a shell file; on the router the settings are in /etc/config/matchwatch
LIB="${MW_LIB:-/usr/lib/matchwatch}"
RUN="${MW_RUN:-/tmp/matchwatch}"
SELF="${MW_SELF:-/usr/bin/matchwatch}"
TAB="$(printf '\t')"

# ---- defaults (change them in LuCI: Services, MatchWatch, Settings; or with uci)
DEVICE_IP=""
LAN_IF=""
WAN_IF=""
IGNORE_PORTS="53 67 68 123 443 1900 5353"
ONLY_FILTER=""
MIN_DOWN_PPS=15
MIN_UP_PPS=8
GEO=1
NTFY_URL=""
NOTIFY_EVERY_MATCH=0
NOTIFY_START=0
NOTIFY_NEWGAME=1
WARN_SCORE=55
PC_SCORE=1
AUTOBLOCK=0
AUTOBLOCK_SCORE=45
AUTOBLOCK_MATCHES=2
BLOCK_DAYS=14
LOBBY_ALERT=1
LOBBY_MARGIN_MS=4
STAY_STRICT=1
STAY_KM=150
STAY_RANGES=1
DATA_DIR="/etc/matchwatch"
WEB=0
if [ -n "$CONF" ]; then
	[ -f "$CONF" ] && . "$CONF"
elif [ -f /etc/config/matchwatch ] && [ -f /lib/functions.sh ]; then
	. /lib/functions.sh
	config_load matchwatch
	config_get DEVICE_IP main device_ip "$DEVICE_IP"
	config_get LAN_IF main lan_if "$LAN_IF"
	config_get WAN_IF main wan_if "$WAN_IF"
	config_get IGNORE_PORTS main ignore_ports "$IGNORE_PORTS"
	config_get ONLY_FILTER main only_filter "$ONLY_FILTER"
	config_get MIN_DOWN_PPS main min_down_pps "$MIN_DOWN_PPS"
	config_get MIN_UP_PPS main min_up_pps "$MIN_UP_PPS"
	config_get GEO main geo "$GEO"
	config_get NTFY_URL main ntfy_url "$NTFY_URL"
	config_get NOTIFY_EVERY_MATCH main notify_every_match "$NOTIFY_EVERY_MATCH"
	config_get NOTIFY_START main notify_start "$NOTIFY_START"
	config_get NOTIFY_NEWGAME main notify_newgame "$NOTIFY_NEWGAME"
	config_get WARN_SCORE main warn_score "$WARN_SCORE"
	config_get PC_SCORE main pc_score "$PC_SCORE"
	config_get AUTOBLOCK main autoblock "$AUTOBLOCK"
	config_get AUTOBLOCK_SCORE main autoblock_score "$AUTOBLOCK_SCORE"
	config_get AUTOBLOCK_MATCHES main autoblock_matches "$AUTOBLOCK_MATCHES"
	config_get BLOCK_DAYS main block_days "$BLOCK_DAYS"
	config_get LOBBY_ALERT main lobby_alert "$LOBBY_ALERT"
	config_get LOBBY_MARGIN_MS main lobby_margin_ms "$LOBBY_MARGIN_MS"
	config_get STAY_STRICT main stay_strict "$STAY_STRICT"
	config_get STAY_KM main stay_km "$STAY_KM"
	config_get STAY_RANGES main stay_ranges "$STAY_RANGES"
	config_get DATA_DIR main data_dir "$DATA_DIR"
	config_get WEB main web "$WEB"
fi
DATA="${MW_DATA:-$DATA_DIR}"

have() { command -v "$1" >/dev/null 2>&1; }
die() { echo "matchwatch: $*" >&2; exit 1; }

is_ipv4() {
	case "$1" in ""|*[!0-9.]*) return 1 ;; esac
	echo "$1" | awk -F. 'NF != 4 { exit 1 } { for (i = 1; i <= 4; i++) if ($i == "" || $i > 255) exit 1 }'
}
is_target() {
	case "$1" in
		*/*) is_ipv4 "${1%/*}" || return 1
			case "${1#*/}" in ""|*[!0-9]*) return 1 ;; esac
			[ "${1#*/}" -ge 16 ] && [ "${1#*/}" -le 32 ] ;;
		*) is_ipv4 "$1" ;;
	esac
}
is_private() {
	echo "$1" | awk -F. '{ exit !($1 == 10 || ($1 == 172 && $2 >= 16 && $2 <= 31) || ($1 == 192 && $2 == 168) || $1 == 127 || ($1 == 169 && $2 == 254)) }'
}

fetch() { # url [post-body]
	if have uclient-fetch; then
		if [ -n "$2" ]; then uclient-fetch -q -T 6 -O - --post-data="$2" "$1" 2>/dev/null
		else uclient-fetch -q -T 6 -O - "$1" 2>/dev/null; fi
	elif have curl; then
		if [ -n "$2" ]; then curl -fsS -m 6 -d "$2" "$1" 2>/dev/null
		else curl -fsS -m 6 "$1" 2>/dev/null; fi
	elif have wget; then
		if [ -n "$2" ]; then wget -q -T 6 -O - --post-data="$2" "$1" 2>/dev/null
		else wget -q -T 6 -O - "$1" 2>/dev/null; fi
	else return 1; fi
}

# ---- where is this server? prints: cc country city lat lon isp org asn (tab separated)
jstr() { echo "$1" | sed -n 's/.*"'"$2"'":"\([^"]*\)".*/\1/p'; }
jnum() { echo "$1" | sed -n 's/.*"'"$2"'":\(-\{0,1\}[0-9.]*\).*/\1/p'; }
geo_lookup() {
	local ip="$1" line json asn
	line="$(grep "^$ip$TAB" "$DATA/geo.cache" 2>/dev/null | tail -n 1)"
	if [ -n "$line" ]; then echo "$line" | cut -f2-; return 0; fi
	[ "$GEO" = 1 ] || return 1
	json="$(fetch "http://ip-api.com/json/$ip?fields=status,country,countryCode,city,lat,lon,isp,org,as")" || return 1
	[ "$(jstr "$json" status)" = success ] || return 1
	asn="$(jstr "$json" as)"; asn="${asn%% *}"
	line="$(printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s' "$(jstr "$json" countryCode)" "$(jstr "$json" country)" \
		"$(jstr "$json" city)" "$(jnum "$json" lat)" "$(jnum "$json" lon)" "$(jstr "$json" isp)" "$(jstr "$json" org)" "$asn")"
	printf '%s\t%s\n' "$ip" "$line" >> "$DATA/geo.cache"
	# the cache lives on flash: keep the newest 2000 servers once it passes 3000
	[ "$(awk 'END { print NR }' "$DATA/geo.cache")" -gt 3000 ] && tail -n 2000 "$DATA/geo.cache" > "$DATA/geo.cache.tmp" && mv -f "$DATA/geo.cache.tmp" "$DATA/geo.cache"
	echo "$line"
}

# ---- active probes that run alongside a match
ploop() { # name ip [hop] : one probe a second, a line per attempt (ms, or x for no reply)
	# with a hop number the server is probed the way traceroute does (UDP), every 2 s
	local d="$PD" r i=0
	while [ -d "$d" ] && [ ! -e "$d/stop" ] && [ "$i" -lt 14400 ]; do
		if [ -n "$3" ]; then
			r="$(traceroute -n -q 1 -w 1 -f "$3" -m "$3" "$2" 2>/dev/null | awk -v ip="$2" '$2 == ip && $3 ~ /^[0-9.]+$/ { print $3; exit }')"
			sleep 1
		else
			r="$(ping -c 1 -W 1 "$2" 2>/dev/null | sed -n 's/.*time=\([0-9.]*\).*/\1/p')"
		fi
		echo "${r:-x}" >> "$d/$1.ping"
		echo "${r:-x}" > "$d/$1.last"
		i=$((i + 1))
		sleep 1
	done
}
start_ping() { [ -e "$PD/stop" ] && return; ploop "$1" "$2" "$3" & echo $! > "$PD/$1.pid"; }

notify_start() { # server-ip : tell the phone a match has begun, for when you are away from the screen
	local g cc country city rest p="" loc i=0
	sleep 4
	# the ping can take a few seconds to arrive, longer when the server ignores ping and is probed another way
	while [ "$i" -lt 5 ]; do
		[ -d "$PD" ] || return 0
		p="$(cat "$PD/far.last" 2>/dev/null)"
		case "$p" in ""|x) p="" ;; *) break ;; esac
		sleep 2; i=$((i + 1))
	done
	[ -d "$PD" ] || return 0
	g="$(geo_lookup "$1")"
	IFS="$TAB" read -r cc country city rest <<EOF
$g
EOF
	loc="${country:-$cc}"
	[ -n "$p" ] && p="$(echo "$p" | awk '{ printf "%.0f", $1 }')"
	cmd_notify "Match started${loc:+: $loc}${p:+, $p ms}."
}
# ---- what QoSmate's shaper did during a match. Read only, and only in its cake modes.
# cake keeps counters for each of its queues. The last column is the top priority queue, where the
# game should be; the others are everything else on the line.
qm_tins() { # device -> packets, drops, marks and current worst delay (microseconds) for the top queue, then for the rest together
	tc -s qdisc show dev "$1" 2>/dev/null | awk '
		function us(x,   v) { v = x + 0; if (x ~ /us$/) return v; if (x ~ /ms$/) return v * 1000; if (x ~ /[0-9]s$/) return v * 1000000; return v }
		/^qdisc cake/ { c++ }
		c != 1 { next }
		$1 == "pkts" || $1 == "drops" || $1 == "marks" { top[$1] = $NF + 0; r = 0; for (i = 2; i < NF; i++) r += $i; rest[$1] = r; got = 1 }
		$1 == "pk_delay" { top["d"] = us($NF); m = 0; for (i = 2; i < NF; i++) if (us($i) > m) m = us($i); rest["d"] = m }
		END { if (got) printf "%d %d %d %d %d %d %d %d\n", top["pkts"], top["drops"], top["marks"], top["d"], rest["pkts"], rest["drops"], rest["marks"], rest["d"] }'
}
qm_loop() { # note where the counters stood at the start, then keep the longest delay seen: cake only shows the latest
	local d="$PD" a b i=0
	have tc || return 0
	find_ifaces
	[ -n "$WAN_IF" ] || return 0
	a="$(qm_tins "$WAN_IF")"
	[ -n "$a" ] || return 0
	echo "$a" > "$d/qm.up0"
	b="$(qm_tins "ifb-$WAN_IF")"; [ -n "$b" ] && echo "$b" > "$d/qm.dn0"
	echo "0 0 0 0" > "$d/qm.peak"
	while [ -d "$d" ] && [ ! -e "$d/stop" ] && [ "$i" -lt 2880 ]; do
		sleep 5; i=$((i + 1))
		a="$(qm_tins "$WAN_IF")"; b="$(qm_tins "ifb-$WAN_IF")"
		[ -d "$d" ] && [ ! -e "$d/stop" ] || break
		echo "${a:-0 0 0 0 0 0 0 0} ${b:-0 0 0 0 0 0 0 0}" | awk -v f="$d/qm.peak" '{
			getline p < f; split(p, m, " ")
			if ($4 > m[1]) m[1] = $4; if ($8 > m[2]) m[2] = $8; if ($12 > m[3]) m[3] = $12; if ($16 > m[4]) m[4] = $16
			printf "%d %d %d %d\n", m[1], m[2], m[3], m[4] > (f ".tmp") }' 2>/dev/null && mv -f "$d/qm.peak.tmp" "$d/qm.peak" 2>/dev/null
	done
}
qm_sum() { # the match is over: what each queue carried, dropped and slowed, as one line of JSON for the report
	local d="$PD" a b
	[ -f "$d/qm.up0" ] || return 0
	find_ifaces
	a="$(qm_tins "$WAN_IF")"; b="$(qm_tins "ifb-$WAN_IF")"
	[ -n "$a" ] || return 0
	awk -v a0="$(cat "$d/qm.up0")" -v a1="$a" -v b0="$(cat "$d/qm.dn0" 2>/dev/null)" -v b1="$b" -v pk="$(cat "$d/qm.peak" 2>/dev/null)" -v sch="$(qos_scheme)" '
		function side(name, s0, s1, p1, p2,   A, B) {
			split(s0, A, " "); split(s1, B, " ")
			if (B[1] < A[1] || B[5] < A[5]) return ""          # the counters went backwards: QoSmate restarted during the match
			return sprintf("\"%s\":{\"pkts\":%d,\"drops\":%d,\"marks\":%d,\"peak\":%.1f,\"rpkts\":%d,\"rdrops\":%d,\"rmarks\":%d,\"rpeak\":%.1f}", name, B[1] - A[1], B[2] - A[2], B[3] - A[3], p1 / 1000, B[5] - A[5], B[6] - A[6], B[7] - A[7], p2 / 1000)
		}
		BEGIN {
			split(pk, P, " ")
			u = side("up", a0, a1, P[1], P[2]); if (u == "") exit
			dn = (b0 != "" && b1 != "") ? side("down", b0, b1, P[3], P[4]) : ""
			printf "{\"scheme\":\"%s\",%s%s}\n", sch, u, (dn != "" ? "," dn : "")
		}' > "$d/qm.json"
	[ -s "$d/qm.json" ] || rm -f "$d/qm.json"
}
cmd_probe_start() {
	local sid="$1" rip="$2" lip="$3" near last hops reached
	is_ipv4 "$rip" || return 1
	PD="$RUN/probe.$sid"; mkdir -p "$PD"
	echo server > "$PD/far.kind"; echo "$rip" > "$PD/far.ip"
	start_ping far "$rip"
	# no match-started alert for a port nobody has named: it may well not be a game
	[ "$NOTIFY_START" = 1 ] && [ "$5" != unnamed ] && notify_start "$rip" &
	qm_loop &
	[ -n "$lip" ] && is_ipv4 "$lip" && start_ping lan "$lip"
	( geo_lookup "$rip" > "$PD/geo.tmp" 2>/dev/null && mv "$PD/geo.tmp" "$PD/geo" ) &
	[ -n "$4" ] && ( sleep 5; [ -d "$PD" ] && qos_probe "$rip" "$4" > "$PD/qos.tmp" 2>/dev/null && mv "$PD/qos.tmp" "$PD/qos" ) &
	have traceroute || return 0
	traceroute -n -w 1 -q 1 -m 24 "$rip" > "$PD/trace.tmp" 2>/dev/null
	[ -d "$PD" ] || return 0
	mv "$PD/trace.tmp" "$PD/trace"
	set -- $(awk -v rip="$rip" '
		$2 ~ /^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$/ {
			split($2, a, "."); pr = (a[1] == 10 || (a[1] == 172 && a[2] >= 16 && a[2] <= 31) || (a[1] == 192 && a[2] == 168))
			if (!pr && near == "") near = $2
			# hops past the first public one belong to the ISP or beyond, even if privately numbered
			if (near != "" && $2 != rip && $2 != near) last = $2
			if ($2 == rip && reached == "") reached = $1
		}
		$1 ~ /^[0-9]+$/ { n = $1 }
		END { print (near == "" ? "-" : near), (last == "" ? "-" : last), (reached != "" ? reached : n "+"), (reached != "" ? reached : "-") }' "$PD/trace")
	near="$1"; last="$2"; hops="$3"; reached="$4"
	echo "$hops" > "$PD/hops"
	if [ "$near" != "-" ]; then echo "$near" > "$PD/near.ip"; start_ping near "$near"; fi
	# server ignores ping? probe it by UDP if traceroute reached it, else use the last hop that answers
	if ! grep -q '^[0-9]' "$PD/far.ping" 2>/dev/null; then
		if [ "$reached" != "-" ]; then
			kill "$(cat "$PD/far.pid" 2>/dev/null)" 2>/dev/null
			rm -f "$PD/far.ping"
			echo serverudp > "$PD/far.kind"
			start_ping far "$rip" "$reached"
		elif [ "$last" != "-" ]; then
			kill "$(cat "$PD/far.pid" 2>/dev/null)" 2>/dev/null
			rm -f "$PD/far.ping"
			echo hop > "$PD/far.kind"; echo "$last" > "$PD/far.ip"
			start_ping far "$last"
		fi
	fi
}

pstats() { # file prefix
	[ -f "$1" ] || return 0
	awk -v p="$2" '
	{ att++ } $1 == "x" { next } { v[++n] = $1 + 0 }
	function pct(q,   b, c) { c = 0; for (b = 0; b <= 20000; b++) if (b in H) { c += H[b]; if (c >= q * hn) return b / 10 } return 0 }
	END {
		if (att == 0) exit
		printf "%s_n=%d\n%s_loss=%.1f\n", p, n, p, 100 * (att - n) / att
		if (n == 0) exit
		for (i = 1; i <= n; i++) { b = int(v[i] * 10 + 0.5); if (b > 20000) b = 20000; H[b]++ }
		hn = n; med = pct(0.5); p95 = pct(0.95)
		split("", H)
		for (i = 1; i <= n; i++) { d = v[i] - med; if (d < 0) d = -d; b = int(d * 10 + 0.5); if (b > 20000) b = 20000; H[b]++ }
		printf "%s_med=%.1f\n%s_p95=%.1f\n%s_jit=%.2f\n", p, med, p, p95, p, pct(0.5)
	}' "$1"
}

cmd_probe_stop() {
	local sid="$1" f cc country city lat lon isp org asn
	PD="$RUN/probe.$sid"
	[ -d "$PD" ] || return 0
	touch "$PD/stop"
	for f in "$PD"/*.pid; do [ -f "$f" ] && kill "$(cat "$f")" 2>/dev/null; done
	qm_sum 2>/dev/null
	{
		pstats "$PD/far.ping" far; pstats "$PD/near.ping" near; pstats "$PD/lan.ping" lan
		echo "far_kind=$(cat "$PD/far.kind" 2>/dev/null)"
		echo "far_ip=$(cat "$PD/far.ip" 2>/dev/null)"
		echo "near_ip=$(cat "$PD/near.ip" 2>/dev/null)"
		echo "hops=$(cat "$PD/hops" 2>/dev/null)"
		if [ -f "$PD/qos" ]; then read -r f cc country < "$PD/qos"; echo "qos_state=$f"; echo "qos_class=$cc"; fi
		if [ -f "$PD/geo" ]; then
			IFS="$TAB" read -r cc country city lat lon isp org asn < "$PD/geo"
			printf 'cc=%s\ncountry=%s\ncity=%s\nlat=%s\nlon=%s\nisp=%s\norg=%s\nasn=%s\n' "$cc" "$country" "$city" "$lat" "$lon" "$isp" "$org" "$asn"
		fi
	} > "$PD/sum"
}

cmd_notify() {
	logger -t matchwatch "$1" 2>/dev/null
	[ -n "$NTFY_URL" ] && fetch "$NTFY_URL" "$1" >/dev/null
	return 0
}

export_json() {
	[ -d "$RUN/www" ] || return 0
	touch "$DATA/sessions.tsv" "$DATA/blocklist"
	awk -v MODE=hist_json -v GAMES="$LIB/games.list" -v GAMESL="$DATA/games.local" -f "$LIB/report.awk" "$DATA/sessions.tsv" > "$RUN/www/history.json.tmp" && mv -f "$RUN/www/history.json.tmp" "$RUN/www/history.json"
	hold_list | awk -F'\t' 'BEGIN { printf "[" } { gsub(/["\\]/, " ", $1); printf "%s{\"name\":\"%s\",\"on\":%s,\"ok\":%s,\"ports\":\"%s\"}", (n++ ? "," : ""), $1, ($2 == 1 ? "true" : "false"), ($3 == 1 ? "true" : "false"), $4 } END { print "]" }' > "$RUN/www/hold.json.tmp" && mv -f "$RUN/www/hold.json.tmp" "$RUN/www/hold.json"
	awk -v MODE=srv_json -v BLOCK="$DATA/blocklist" $(stay_vars) -f "$LIB/report.awk" "$DATA/sessions.tsv" > "$RUN/www/servers.json.tmp" && mv -f "$RUN/www/servers.json.tmp" "$RUN/www/servers.json"
	awk -v MODE=dc_json -v BLOCK="$DATA/blocklist" $(stay_vars) -f "$LIB/report.awk" "$DATA/sessions.tsv" > "$RUN/www/datacentres.json.tmp" && mv -f "$RUN/www/datacentres.json.tmp" "$RUN/www/datacentres.json"
	awk -F'\t' -v now="$(date +%s)" 'BEGIN { printf "[" } $1 != "" { gsub(/["\\]/, " ", $4); printf "%s{\"ip\":\"%s\",\"days\":%s,\"reason\":\"%s\"}", (n++ ? "," : ""), $1, ($2 == 0 ? "null" : int(($2 - now + 86399) / 86400)), $4 } END { print "]" }' "$DATA/blocklist" > "$RUN/www/blocklist.json.tmp" && mv -f "$RUN/www/blocklist.json.tmp" "$RUN/www/blocklist.json"
	printf '{"version":"%s","device":"%s","stay":"%s","autoblock":%s,"notify":%s,"pc_score":%s,"geo":%s,"block_days":%s,"stays":[%s],"web":%s,"qosmate":%s,"away":%s,"allowed":[%s],"pool":[%s]}\n' "$VERSION" "$DEVICE_IP" "$(stay_names | sed 's/["\\]/ /g')" "$( [ "$AUTOBLOCK" = 1 ] && echo true || echo false )" "$( [ -n "$NTFY_URL" ] && echo true || echo false )" "$( [ "$PC_SCORE" = 0 ] && echo false || echo true )" "$( [ "$GEO" = 1 ] && echo true || echo false )" "${BLOCK_DAYS:-14}" "$(awk -F'\t' 'NF >= 4 { gsub(/["\\]/, " ", $1); printf "%s\"%s\"", (n++ ? "," : ""), $1 }' "$DATA/stay" 2>/dev/null)" "$( [ "$WEB" = 1 ] && echo true || echo false )" "$( [ -x /etc/init.d/qosmate ] && echo true || echo false )" "$(cat "$RUN/away.count" 2>/dev/null || echo 0)" "$(awk '$1 ~ /^[0-9.]+$/ { printf "%s\"%s\"", (n++ ? "," : ""), $1 }' "$DATA/allow" 2>/dev/null)" "$(awk -F'\t' 'NF >= 4 { gsub(/["\\]/, " ", $1); c = ($5 != "" && $5 != "-"); printf "%s{\"n\":%d,\"name\":\"%s\",\"lat\":%s,\"lon\":%s,\"km\":%d,\"cc\":\"%s\"}", (n++ ? "," : ""), NR, $1, (c || $2 !~ /^-?[0-9.]+$/ ? "null" : $2), (c || $3 !~ /^-?[0-9.]+$/ ? "null" : $3), $4 + 0, (c ? $5 : "") }' "$DATA/stay" 2>/dev/null)" > "$RUN/www/info.json"
	regions_export
	{ printf '['; [ -f "$DATA/favourites" ] && awk -F'\t' '$1 ~ /^[0-9.]+$/ { for (i = 2; i <= 5; i++) gsub(/["\\]/, " ", $i); printf "%s{\"ip\":\"%s\",\"game\":\"%s\",\"city\":\"%s\",\"cc\":\"%s\",\"org\":\"%s\"}", (n++ ? "," : ""), $1, $2, $3, $4, $5 }' "$DATA/favourites"; echo ']'; } > "$RUN/www/favourites.json.tmp" && mv -f "$RUN/www/favourites.json.tmp" "$RUN/www/favourites.json"
	{ printf '['; [ -f "$DATA/games.local" ] && awk -F'|' '!/^#/ && NF >= 2 { for (i = 1; i <= 4; i++) gsub(/["\\]/, " ", $i); printf "%s{\"name\":\"%s\",\"ports\":\"%s\",\"kind\":\"%s\",\"hosts\":\"%s\"}", (n++ ? "," : ""), $1, $2, $3, $4 }' "$DATA/games.local"; echo ']'; } > "$RUN/www/mygames.json.tmp" && mv -f "$RUN/www/mygames.json.tmp" "$RUN/www/mygames.json"
	gameplaces json > "$RUN/www/gameplaces.json.tmp" 2>/dev/null && mv -f "$RUN/www/gameplaces.json.tmp" "$RUN/www/gameplaces.json"
	share_json > "$RUN/www/shared.json.tmp" && mv -f "$RUN/www/shared.json.tmp" "$RUN/www/shared.json"
	# keep the sixty most recent match detail files
	if [ -d "$DATA/matches" ]; then
		ls -1 "$DATA/matches" 2>/dev/null | sort -r | awk 'NR > 60' | while read -r f; do rm -f "$DATA/matches/$f"; done
	fi
}

cmd_after() { # note overall
	local sname i
	regions_stale && ( cmd_regions measure >/dev/null 2>&1 & )
	[ -f "$RUN/last.txt" ] && cp "$RUN/last.txt" "$DATA/last.txt"
	if [ -s "$DATA/stay" ]; then
		i="$(wc -l < "$DATA/stay")"
		while [ "$i" -ge 1 ]; do
			set -- "$1" "$2" $(awk -v MODE=area_recent -v PLACE="$i" $(stay_vars) -f "$LIB/report.awk" "$DATA/sessions.tsv")
			if [ "${4:-0}" -ge 3 ] && [ "$3" != - ] && [ "$3" -lt "$WARN_SCORE" ]; then
				sname="$(sed -n "${i}p" "$DATA/stay" | cut -f1)"
				sed -i "${i}d" "$DATA/stay"
				cmd_notify "Dropped $sname from the places you stay on: its last three matches averaged $3/100."
			fi
			set -- "$1" "$2"
			i=$((i - 1))
		done
		sleep 2   # let the live status drop the match that has just ended, so its server is no longer spared
		if [ -s "$DATA/stay" ]; then stay_apply >/dev/null; else stay_off; cmd_notify "Stay mode is off: every place in the pool had gone bad."; fi
	fi
	export_json
	[ "$(cnt "$DATA/sessions.tsv")" -gt 5200 ] && tail -n 5000 "$DATA/sessions.tsv" > "$DATA/sessions.tsv.tmp" && mv -f "$DATA/sessions.tsv.tmp" "$DATA/sessions.tsv"
	logger -t matchwatch "$1" 2>/dev/null
	if [ "$NOTIFY_EVERY_MATCH" = 1 ] || [ "${2:-100}" -lt "$WARN_SCORE" ]; then [ -n "$NTFY_URL" ] && fetch "$NTFY_URL" "Match ended: $(echo "$1" | sed 's/^Match on [^:]*: //; s/^\([0-9]*\/100 [A-Za-z]*\)\..*/\1/')." >/dev/null; fi
	return 0
}

# ---- blocking (own nftables table; fw4 is left alone)
nft_ready() {
	local t ok=1
	have nft || { echo "matchwatch: nft not found (blocking needs OpenWrt 22.03 or newer)" >&2; return 1; }
	is_ipv4 "$DEVICE_IP" || DEVICE_IP=""
	t="$(nft list table inet matchwatch 2>/dev/null)"
	if [ -n "$t" ]; then
		echo "$t" | grep -q 'flags interval,timeout\|flags interval, timeout' || ok=0
		echo "$t" | grep -q 'set away' || ok=0
		echo "$t" | grep -q 'set allowed' || ok=0
		echo "$t" | grep -q 'set okay' || ok=0
		if [ -n "$DEVICE_IP" ]; then echo "$t" | grep -q "ip saddr $DEVICE_IP udp dport @hold_ports" || ok=0; fi
		# the rules for whole ranges name the gaming device, so they are rebuilt when it changes
		if [ -n "$DEVICE_IP" ]; then echo "$t" | grep -q "ip saddr $DEVICE_IP ip daddr @away" || ok=0
		else echo "$t" | grep -q '@away' && ok=0; fi
		[ "$ok" = 1 ] && return 0
		nft delete table inet matchwatch       # table from an older version, or for another device: rebuild it
	fi
	# blocked: single servers and their address blocks, for every device, as before.
	# away: whole ranges outside the places being stayed on. Only the gaming device's UDP is refused, so
	# web sites and other devices that happen to use the same hosting company are untouched.
	{
		printf 'table inet matchwatch {\n\tset blocked {\n\t\ttype ipv4_addr\n\t\tflags interval, timeout\n\t}\n\tset away {\n\t\ttype ipv4_addr\n\t\tflags interval\n\t\tauto-merge\n\t}\n\tset allowed {\n\t\ttype ipv4_addr\n\t}\n\tset hold_ports {\n\t\ttype inet_service\n\t\tflags interval\n\t\tauto-merge\n\t}\n\tset okay {\n\t\ttype ipv4_addr\n\t}\n'
		# allowed comes first: a server the owner let through is never refused by the two sets below
		printf '\tchain forward {\n\t\ttype filter hook forward priority -5; policy accept;\n\t\tip daddr @allowed accept\n\t\tip saddr @allowed accept\n\t\tip daddr @blocked counter drop\n\t\tip saddr @blocked counter drop\n'
		[ -n "$DEVICE_IP" ] && printf '\t\tip saddr %s ip daddr @away meta l4proto udp counter drop\n\t\tip daddr %s ip saddr @away meta l4proto udp counter drop\n' "$DEVICE_IP" "$DEVICE_IP"
		# strict games: the device's packets to a held port go nowhere until the server has a verdict
		[ -n "$DEVICE_IP" ] && printf '\t\tip saddr %s udp dport @hold_ports ip daddr != @okay counter drop\n' "$DEVICE_IP"
		printf '\t}\n}\n'
	} | nft -f - || return 1
	[ "$NFT_FILLING" = 1 ] || { NFT_FILLING=1; fill_blocklist; NFT_FILLING=0; }
	allow_fill
	[ "$HOLD_FILLING" = 1 ] || { HOLD_FILLING=1; MW_NOWAIT=1 hold_apply; HOLD_FILLING=0; }
	[ -s "$DATA/stay" ] && [ "$RANGES_RUNNING" != 1 ] && ( stay_ranges >/dev/null 2>&1 & )
	return 0
}
in_away() { nft get element inet matchwatch away "{ $1 }" >/dev/null 2>&1; }
nft_add() { # ip seconds(0 = permanent)
	nft delete element inet matchwatch blocked "{ $1 }" 2>/dev/null
	if [ "$2" -gt 0 ]; then nft add element inet matchwatch blocked "{ $1 timeout ${2}s }" 2>/dev/null
	else nft add element inet matchwatch blocked "{ $1 }" 2>/dev/null; fi
}
fill_blocklist() {
	local now ip exp added reason
	[ -s "$DATA/blocklist" ] || return 0
	now="$(date +%s)"
	awk -F'\t' -v now="$now" '$2 == 0 || $2 > now' "$DATA/blocklist" > "$DATA/blocklist.tmp" && mv -f "$DATA/blocklist.tmp" "$DATA/blocklist"
	while IFS="$TAB" read -r ip exp added reason; do
		is_target "$ip" || continue
		if [ "$exp" = 0 ]; then nft_add "$ip" 0; else nft_add "$ip" $((exp - now)); fi
	done < "$DATA/blocklist"
}
apply_blocklist() {
	[ -s "$DATA/blocklist" ] || return 0
	NFT_FILLING=1; nft_ready || { NFT_FILLING=0; return 1; }
	fill_blocklist; NFT_FILLING=0
}
cmd_block() { # ip [days|auto] [reason]
	local ip="$1" days="${2:-$BLOCK_DAYS}" reason="${3:-manual}" now exp
	is_target "$ip" || die "usage: matchwatch block <server-ip or block like 1.2.3.0/24> [days, 0 = until unblocked] [reason]"
	is_private "$ip" && die "refusing to block a private address"
	if is_allowed "$ip"; then
		# a server the owner let through is not blocked automatically; blocking it by hand takes it back out
		if [ "$days" = auto ]; then logger -t matchwatch "not blocking $ip automatically: you let it through" 2>/dev/null; return 0; fi
		[ "$reason" = stay ] || allow_drop "$ip"
	fi
	if [ "$days" = auto ]; then
		# a favourite is never blocked automatically
		if is_fav "$ip"; then logger -t matchwatch "not blocking $ip automatically: it is one of your favourites" 2>/dev/null; return 0; fi
		days="$BLOCK_DAYS"; reason="auto: $reason"
	fi
	case "$days" in ""|*[!0-9]*) die "days must be a number" ;; esac
	nft_ready || exit 1
	mkdir -p "$DATA"; touch "$DATA/blocklist"
	now="$(date +%s)"
	if [ "$days" -gt 0 ]; then exp=$((now + days * 86400)); else exp=0; fi
	grep -v "^$ip$TAB" "$DATA/blocklist" > "$DATA/blocklist.tmp"; mv -f "$DATA/blocklist.tmp" "$DATA/blocklist"
	printf '%s\t%s\t%s\t%s\n' "$ip" "$exp" "$now" "$reason" >> "$DATA/blocklist"
	if [ "$exp" = 0 ]; then nft_add "$ip" 0; else nft_add "$ip" $((exp - now)); fi
	export_json
	[ "$MW_QUIET" = 1 ] && return 0
	if [ "$days" -gt 0 ]; then echo "Blocked $ip for $days day(s)."; else echo "Blocked $ip until you unblock it."; fi
	logger -t matchwatch "blocked $ip ($reason)" 2>/dev/null
}
cmd_unblock() {
	local ip="$1"
	touch "$DATA/blocklist"
	if [ "$ip" = all ]; then
		: > "$DATA/blocklist"
		nft flush set inet matchwatch blocked 2>/dev/null
		export_json; echo "All blocks removed."; return 0
	fi
	is_target "$ip" || die "usage: matchwatch unblock <server-ip or block>|all"
	grep -v "^$ip$TAB" "$DATA/blocklist" > "$DATA/blocklist.tmp"; mv -f "$DATA/blocklist.tmp" "$DATA/blocklist"
	nft delete element inet matchwatch blocked "{ $ip }" 2>/dev/null
	export_json; echo "Unblocked $ip."
}
cmd_blocklist() {
	touch "$DATA/blocklist"
	[ -s "$DATA/blocklist" ] || { echo "Nothing is blocked."; return 0; }
	awk -F'\t' -v now="$(date +%s)" -v GEOF="$DATA/geo.cache" '
		BEGIN { while ((getline l < GEOF) > 0) { split(l, g, "\t"); G[g[1]] = g[4] ", " g[2] " - " g[8] }
			printf "%-16s %-12s %-34s %s\n", "Server", "Expires", "Where", "Reason" }
		{ left = ($2 == 0) ? "never" : (($2 > now) ? int(($2 - now + 86399) / 86400) " day(s)" : "expired")
		  printf "%-16s %-12s %-34s %s\n", $1, left, substr(G[$1], 1, 34), $4 }' "$DATA/blocklist"
}

cmd_block_dc() { # number [days]
	local n="$1" days="${2:-$BLOCK_DAYS}" name list p
	case "$n" in ""|*[!0-9]*) die "usage: matchwatch block-dc <number from 'matchwatch datacentres'> [days]" ;; esac
	touch "$DATA/sessions.tsv" "$DATA/blocklist"
	list="$(awk -v MODE=dc_prefixes -v ARG="$n" -v BLOCK="$DATA/blocklist" -f "$LIB/report.awk" "$DATA/sessions.tsv")"
	[ -n "$list" ] || die "no datacentre number $n"
	name="$(echo "$list" | head -n 1)"
	echo "Blocking the address blocks seen so far in: $name"
	echo "$list" | tail -n +2 | while read -r p; do cmd_block "$p" "$days" "datacentre: $name"; done
	echo "Only blocks you have already been placed on are covered. A big datacentre has more,"
	echo "and with it blocked the game will send you somewhere further away."
}

# ---- lobby: where is the game about to put me?
jesc() { printf '%s' "$1" | tr -d '\n\r\t' | sed 's/["\\]/ /g'; }
cmd_lobby() { # server-ip port device-ip
	local ip="$1" port="$2" g cc country city lat lon isp org asn key r i s="" ping="" k v
	local srv_n=0 srv_rating="" dc_name="" dc_ping="" best_key="" best_name="" best_ping="" verdict=good msg loc blocked=false
	local where short want=0 now last
	is_ipv4 "$ip" || return 1
	mkdir -p "$RUN/www"
	if [ -s "$DATA/stay" ] && ! is_allowed "$ip" && in_away "$ip"; then
		printf '{"ts":%s,"ip":"%s","port":%s,"loc":"","org":"","ping":null,"verdict":"good","blocked":true,"msg":"A server in a region outside the places you stay on. Its whole range is turned away, so the game should move on quickly."}\n' "$(date +%s)" "$ip" "${port:-0}" > "$RUN/www/lobby.json.tmp" && mv -f "$RUN/www/lobby.json.tmp" "$RUN/www/lobby.json"
		return 0
	fi
	g="$(geo_lookup "$ip")"
	IFS="$TAB" read -r cc country city lat lon isp org asn <<EOF
$g
EOF
	key="$asn|$city|$cc"
	tried_note "$ip" "${port:-0}" "$cc" "$city" "$org" "$asn" "$lat" "$lon"
	# Staying somewhere? Decide first. Every second spent measuring is a second the game spends joining
	# this server, and turning it away late throws the player out of a lobby they had already reached.
	if [ -s "$DATA/stay" ] && [ "$STAY_STRICT" = 1 ] && [ -n "$lat" ] && [ -n "$lon" ] && [ -n "$cc" ] && ! is_allowed "$ip"; then
		if outside_stay "$lat" "$lon" "$cc"; then MW_QUIET=1 cmd_block "${ip%.*}.0/24" 0 stay && blocked=true; fi
	fi
	if [ "$blocked" != true ]; then
		for i in 1 2 3; do
			r="$(ping -c 1 -W 1 "$ip" 2>/dev/null | sed -n 's/.*time=\([0-9.]*\).*/\1/p')"
			[ -n "$r" ] && s="$s $r"
		done
		if [ -z "$s" ] && have traceroute; then
			s="$(traceroute -n -q 1 -w 1 -m 20 "$ip" 2>/dev/null | awk -v ip="$ip" '$2 == ip && $3 ~ /^[0-9.]+$/ { print $3; exit }')"
		fi
		[ -n "$s" ] && ping="$(echo $s | awk '{ m = $1; for (i = 2; i <= NF; i++) if ($i < m) m = $i; printf "%.1f", m }')"
	fi
	touch "$DATA/sessions.tsv"
	while IFS="=" read -r k v; do
		case "$k" in
			srv_n) srv_n="$v" ;; srv_rating) srv_rating="$v" ;; dc_name) dc_name="$v" ;; dc_ping) dc_ping="$v" ;;
			best_key) best_key="$v" ;; best_name) best_name="$v" ;; best_ping) best_ping="$v" ;;
		esac
	done <<EOF
$(awk -v MODE=lobby -v ARG="$ip" -v KEY="$key" -f "$LIB/report.awk" "$DATA/sessions.tsv")
EOF
	loc="${city:+$city, }${cc:-unknown location}"
	where="${country:-${cc:-an unknown place}}"
	# the dashboard gets the whole story; the phone gets one short line
	msg="Heading to $loc${org:+ ($org)}"
	[ -n "$ping" ] && msg="$msg, about $ping ms"
	msg="$msg."
	short="Heading to $where${ping:+, ${ping%.*} ms}."
	is_fav "$ip" && msg="$msg One of your favourites."
	if [ "$srv_n" -ge 1 ] 2>/dev/null && [ -n "$srv_rating" ]; then
		msg="$msg This server rated $srv_rating/100 over $srv_n match(es)."
		if [ "$srv_rating" -lt "$WARN_SCORE" ]; then
			verdict=bad; msg="$msg That is poor: consider backing out."
			short="Poor server ahead: $where${ping:+, ${ping%.*} ms}. Rated $srv_rating/100 before."
		fi
	else
		msg="$msg First time on this server."
		r="$(awk -F'\t' -v p="${ip%.*}.0/24" '$1 == p { print $3 "/100 over " $2 " match(es)"; exit }' "$DATA/ratings.shared" 2>/dev/null)"
		[ -n "$r" ] && msg="$msg Someone who shared ratings with you scored its network $r."
	fi
	if [ "$verdict" = good ] && [ "$blocked" != true ] && [ -n "$ping" ] && [ -n "$best_ping" ] && [ "$best_key" != "$key" ]; then
		if awk -v a="$ping" -v b="$best_ping" -v m="$LOBBY_MARGIN_MS" 'BEGIN { exit !(a > b + m) }'; then
			verdict=far; msg="$msg ${best_name%% - *} is usually $best_ping ms."
			short="Far server ahead: $where, ${ping%.*} ms."
		fi
	fi
	if [ "$blocked" = true ]; then
		msg="$msg Turned away, because you are staying on $(stay_names). The game should search again."
		short="Turned away a server in $where."
	fi
	printf '{"ts":%s,"ip":"%s","port":%s,"loc":"%s","org":"%s","ping":%s,"verdict":"%s","blocked":%s,"msg":"%s"}\n' \
		"$(date +%s)" "$ip" "${port:-0}" "$(jesc "$loc")" "$(jesc "$org")" "${ping:-null}" "$verdict" "$blocked" "$(jesc "$msg")" > "$RUN/www/lobby.json.tmp" && mv -f "$RUN/www/lobby.json.tmp" "$RUN/www/lobby.json"
	logger -t matchwatch "$msg" 2>/dev/null
	# The phone: only a far or poor server, unless "always" is chosen. A server turned away is the router
	# doing what it was asked, and a game may try five in a minute, so that is not worth a buzz each time.
	[ "$LOBBY_ALERT" = 2 ] && want=1
	[ "$LOBBY_ALERT" = 1 ] && [ "$verdict" != good ] && [ "$blocked" != true ] && want=1
	now="$(date +%s)"; last="$(cat "$RUN/lobby.alert" 2>/dev/null)"
	[ "$want" = 1 ] && [ -n "$last" ] && [ $((now - last)) -lt 60 ] && want=0     # and never more than one a minute
	if [ "$want" = 1 ] && [ -n "$NTFY_URL" ]; then echo "$now" > "$RUN/lobby.alert"; fetch "$NTFY_URL" "$short" >/dev/null; fi
	return 0
}

# ---- ping every region the game's host has a datacentre in
regions_export() {
	[ -d "$RUN/www" ] || return 0
	touch "$DATA/sessions.tsv" "$DATA/regions.tsv"
	awk -v MODE=regions_json -v REG="$DATA/regions.tsv" $(stay_vars) -f "$LIB/report.awk" "$DATA/sessions.tsv" > "$RUN/www/regions.json.tmp" && mv -f "$RUN/www/regions.json.tmp" "$RUN/www/regions.json"
}
cmd_regions() { # measure | (nothing = show the last measurement)
	local tmp="$RUN/regions.$$" code city cc area lat lon host n=0
	touch "$DATA/sessions.tsv"
	if [ "$1" = measure ] || [ ! -s "$DATA/regions.tsv" ]; then
		[ -f "$LIB/regions.list" ] || die "missing $LIB/regions.list"
		mkdir -p "$tmp"
		while IFS="|" read -r code city cc area lat lon host; do
			case "$code" in ""|"#"*) continue ;; esac
			(
				out="$(ping -c 4 -W 1 "$host" 2>/dev/null)"
				ip="$(echo "$out" | sed -n '1s/.*(\([0-9.]*\)).*/\1/p')"
				echo "$out" | sed -n 's/.*time=\([0-9.]*\).*/\1/p' | awk -v c="$code" -v city="$city" -v cc="$cc" -v area="$area" -v lat="$lat" -v lon="$lon" -v ip="$ip" -v now="$(date +%s)" '
					{ n++; if (min == "" || $1 < min) min = $1; if ($1 > max) max = $1 }
					END { printf "%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%d\t%s\n", c, city, cc, area, lat, lon, (ip == "" ? "-" : ip), (n ? sprintf("%.1f", min) : "-"), (n ? sprintf("%.1f", max - min) : "-"), n, now }' > "$tmp/$code"
			) &
			n=$((n + 1))
			[ $((n % 12)) -eq 0 ] && wait
		done <<EOF
$(cat "$LIB/regions.list" "$DATA/regions.local" 2>/dev/null)
EOF
		wait
		cat "$tmp"/* > "$DATA/regions.tsv.tmp" 2>/dev/null && mv -f "$DATA/regions.tsv.tmp" "$DATA/regions.tsv"
		rm -f "$tmp"/*; rmdir "$tmp" 2>/dev/null
		regions_export
	fi
	awk -v MODE=regions_txt -v REG="$DATA/regions.tsv" $(stay_vars) -f "$LIB/report.awk" "$DATA/sessions.tsv"
}
regions_stale() { # true when there is no measurement, or it is over six hours old
	[ -s "$DATA/regions.tsv" ] || return 0
	[ $(( $(date +%s) - $(head -n 1 "$DATA/regions.tsv" | cut -f11) )) -gt 21600 ]
}

# ---- turn whole regions away ahead of time
# Learning servers one at a time is slow: the game tries one, waits, gives up, tries the next. Hosting
# companies publish which of their address ranges is in which city (a "geofeed", RFC 8805). With those
# lists every range outside the pool can be refused before the game ever tries it.
# Only the gaming device's UDP is refused, and a range whose place cannot be worked out is left alone.
feed_list() { cat "$LIB/geofeeds.list" "$DATA/geofeeds.local" 2>/dev/null | awk -F'|' '!/^#/ && $2 ~ /^https?:\/\/[A-Za-z0-9.\/?=_&%-]+$/ { gsub(/[^A-Za-z0-9 .-]/, "", $1); gsub(/[^A-Za-z0-9 .,:-]/, "", $3); print $1 "|" $2 "|" $3 }'; }
ranges_fetch() { # [force] : refresh the list of ranges when it is missing or over a week old. A failed download keeps the old one
	local name url games tmp="$RUN/ranges.$$" age=999999999
	[ -s "$DATA/ranges.cache" ] && age=$(( $(date +%s) - $(date -r "$DATA/ranges.cache" +%s 2>/dev/null || echo 0) ))
	if [ "$age" -ge 604800 ] || [ "$1" = force ]; then
		mkdir -p "$RUN"; : > "$tmp"
		feed_list | while IFS="|" read -r name url games; do
			fetch "$url" | awk -F',' -v h="$name" '
				/^#/ { next }
				$1 ~ /^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+\/[0-9]+$/ && $2 ~ /^[A-Z][A-Z]$/ {
					split($1, a, "/"); split(a[1], o, ".")
					if (a[2] + 0 < 12 || a[2] + 0 > 32) next          # nothing wider than a /12 is ever taken from a list
					if (o[1] == 10 || o[1] == 127 || o[1] == 0 || o[1] >= 224 || (o[1] == 172 && o[2] >= 16 && o[2] <= 31) || (o[1] == 192 && o[2] == 168) || (o[1] == 169 && o[2] == 254) || (o[1] == 100 && o[2] >= 64 && o[2] <= 127)) next
					c = $4; gsub(/[^A-Za-z .-]/, "", c)
					printf "%s\t%s\t%s\t%s\n", $1, $2, c, h
				}' >> "$tmp"
		done
		[ -s "$tmp" ] && head -n 20000 "$tmp" > "$DATA/ranges.cache.tmp" && mv -f "$DATA/ranges.cache.tmp" "$DATA/ranges.cache"
		rm -f "$tmp"
	fi
	[ -s "$DATA/ranges.cache" ]
}
ranges_cities() { # put every city named in the lists on the map, once: "city|CC <tab> lat <tab> lon", or "-" when it cannot be found
	local cc city q json lat lon got
	touch "$DATA/cities.cache"
	cut -f2,3 "$DATA/ranges.cache" | sort -u | while IFS="$TAB" read -r cc city; do
		[ -n "$city" ] || continue
		awk -F'\t' -v k="$city|$cc" '$1 == k { f = 1 } END { exit !f }' "$DATA/cities.cache" && continue
		lat=""; lon=""; got=0
		# the name as given, then without a suffix such as "-ku", then its first word
		for q in "$city" "${city%%-*}" "${city%% *}"; do
			json="$(fetch "https://geocoding-api.open-meteo.com/v1/search?name=$(printf '%s' "$q" | sed 's/ /%20/g')&count=1&language=en&format=json&countryCode=$cc")" || continue
			got=1
			lat="$(jnum "$json" latitude)"; lon="$(jnum "$json" longitude)"
			[ -n "$lat" ] && [ -n "$lon" ] && break
			lat=""; lon=""
		done
		[ "$got" = 1 ] && printf '%s|%s\t%s\t%s\n' "$city" "$cc" "${lat:--}" "${lon:--}" >> "$DATA/cities.cache"
	done
}
ranges_outside() { # addresses of matches in progress -> the ranges that lie outside every place in the pool
	awk -F'\t' -v LIVE="$1" '
		function ipn(s,   a) { split(s, a, "."); return ((a[1] * 256 + a[2]) * 256 + a[3]) * 256 + a[4] }
		BEGIN { nl = split(LIVE, L, " ") }
		FILENAME == ARGV[1] { if (NF >= 4) { n++; for (i = 1; i <= 5; i++) SP[n, i] = $i; if ($5 == "" || $5 == "-") hascity = 1 } next }
		FILENAME == ARGV[2] { C[$1] = $2 "\t" $3; next }
		{
			cc = $2; ok = 0; lat = "-"; lon = "-"
			if (($3 "|" cc) in C) { split(C[$3 "|" cc], q, "\t"); lat = q[1]; lon = q[2] }
			for (i = 1; i <= n; i++) {
				if (SP[i, 5] != "" && SP[i, 5] != "-") { if (index("," SP[i, 5] ",", "," cc ",") > 0) ok = 1; continue }
				if (lat == "-") continue
				x = (lat + SP[i, 2]) / 2 * 0.0174533; x2 = x * x; cs = 1 - x2 / 2 + x2 * x2 / 24 - x2 * x2 * x2 / 720
				dy = (lat - SP[i, 2]) * 111.2; dx = (lon - SP[i, 3]) * 111.2 * cs
				if (dx * dx + dy * dy <= SP[i, 4] * SP[i, 4]) ok = 1
			}
			if (ok || n == 0) next
			if (lat == "-" && hascity) next                    # could be inside a city in the pool: not known, so left alone
			split($1, pr, "/"); base = ipn(pr[1]); size = 2 ^ (32 - pr[2])
			for (i = 1; i <= nl; i++) { v = ipn(L[i]); if (v >= base && v < base + size) next }   # never cut off a match in progress
			print $1
		}' "$DATA/stay" "$DATA/cities.cache" "$DATA/ranges.cache"
}
stay_ranges() { # fill, or empty, the set of whole ranges. The first run looks cities up, so it is always started in the background
	local live n=0 f="$RUN/away.$$"
	RANGES_RUNNING=1
	mkdir -p "$RUN"
	# one at a time: two runs side by side would look the same cities up twice
	if [ -f "$RUN/away.lock" ] && [ $(( $(date +%s) - $(cat "$RUN/away.lock") )) -lt 180 ]; then return 0; fi
	date +%s > "$RUN/away.lock"
	stay_ranges_run; n=$?
	rm -f "$RUN/away.lock"
	return $n
}
stay_ranges_run() {
	local live n=0 f="$RUN/away.$$" refuse=1
	nft_ready || return 1
	if [ ! -s "$DATA/stay" ]; then
		nft flush set inet matchwatch away 2>/dev/null; rm -f "$RUN/away.count" "$RUN/www/coverage.json" "$RUN/coverage.sug"; export_json; return 0
	fi
	[ "$STAY_RANGES" = 1 ] && [ -n "$DEVICE_IP" ] || refuse=0
	if ! ranges_fetch; then nft flush set inet matchwatch away 2>/dev/null; rm -f "$RUN/away.count" "$RUN/www/coverage.json"; export_json; return 1; fi
	ranges_cities
	if [ "$refuse" = 1 ]; then
		live="$(grep -o '"ip":"[0-9.]*"' "$RUN/www/status.json" 2>/dev/null | sed 's/"ip":"//; s/"//' | tr '\n' ' ')"
		ranges_outside "$live" > "$f.list"
		n="$(cnt "$f.list")"
		{
			echo "flush set inet matchwatch away"
			if [ "$n" -gt 0 ]; then printf 'add element inet matchwatch away { '; tr '\n' ',' < "$f.list" | sed 's/,$//'; echo ' }'; fi
		} > "$f"
		nft -f "$f" 2>/dev/null || n=0
		rm -f "$f" "$f.list"
		echo "$n" > "$RUN/away.count"
		logger -t matchwatch "Turning away $n whole address range(s) outside the places you stay on, for the gaming device's game traffic" 2>/dev/null
	else
		nft flush set inet matchwatch away 2>/dev/null; rm -f "$RUN/away.count"
	fi
	ranges_cover "$n" "$refuse"
	export_json
}
# Which places in the pool have servers we know of? A place with none can never give a match from the
# hosts on the list, and the player should be told, with the nearest places that do have servers.
ranges_cover() { # ranges-refused refusing(1|0) -> coverage.json for the Servers page, and the suggestions the Add buttons use
	local hosts
	hosts="$(feed_list | awk -F'|' '{ printf "%s%s%s", (NR > 1 ? ", " : ""), $1, ($3 != "" ? " (" $3 ")" : "") }')"
	mkdir -p "$RUN/www"; touch "$DATA/cities.cache" "$LIB/countries.list" 2>/dev/null
	awk -F'\t' -v SUG="$RUN/coverage.sug" -v HOSTS="$hosts" -v REF="${1:-0}" -v ON="${2:-0}" '
		function d2(la1, lo1, la2, lo2,   x, x2, cs, dy, dx) {
			x = (la1 + la2) / 2 * 0.0174533; x2 = x * x; cs = 1 - x2 / 2 + x2 * x2 / 24 - x2 * x2 * x2 / 720
			dy = (la1 - la2) * 111.2; dx = (lo1 - lo2) * 111.2 * cs
			return dx * dx + dy * dy
		}
		function root(x,   g, k) { if (x <= 0) return 0; g = x; for (k = 0; k < 40; k++) g = (g + x / g) / 2; return g }   # some awk builds have no sqrt
		function q(s) { gsub(/["\\]/, " ", s); return "\"" s "\"" }
		FILENAME == ARGV[1] { if (NF >= 4) { n++; for (i = 1; i <= 5; i++) SP[n, i] = $i } next }
		FILENAME == ARGV[2] { if ($2 != "-") { CLA[$1] = $2; CLO[$1] = $3 } next }
		FILENAME == ARGV[3] { if (split($0, c, "|") == 3 && $0 !~ /^#/) { KLA[c[1]] = c[2]; KLO[c[1]] = c[3] } next }
		{
			known++; cc = $2; key = $3 "|" cc
			if (!(key in SEEN)) { SEEN[key] = 1; CITY[++nc] = key }
			for (i = 1; i <= n; i++) {
				if (SP[i, 5] != "" && SP[i, 5] != "-") { if (index("," SP[i, 5] ",", "," cc ",") > 0) { cnt[i]++; IN[key] = 1 } continue }
				if ((key in CLA) && d2(CLA[key], CLO[key], SP[i, 2], SP[i, 3]) <= SP[i, 4] * SP[i, 4]) { cnt[i]++; IN[key] = 1 }
			}
		}
		END {
			printf "" > SUG
			printf "{\"hosts\":%s,\"known\":%d,\"refusing\":%s,\"refused\":%d,\"places\":[", q(HOSTS), known, (ON == 1 ? "true" : "false"), REF
			for (i = 1; i <= n; i++) printf "%s{\"name\":%s,\"ranges\":%d}", (i > 1 ? "," : ""), q(SP[i, 1]), cnt[i]
			printf "],\"suggest\":["
			for (i = 1; i <= n && known > 0; i++) {
				if (cnt[i] > 0) continue
				# where is this place? a city has its own spot; a country or area takes the middle of its countries
				la = ""; lo = ""
				if (SP[i, 5] == "" || SP[i, 5] == "-") { la = SP[i, 2]; lo = SP[i, 3] }
				else { k = split(SP[i, 5], cs, ","); m = 0; sa = 0; so = 0; for (j = 1; j <= k; j++) if (cs[j] in KLA) { sa += KLA[cs[j]]; so += KLO[cs[j]]; m++ } if (m) { la = sa / m; lo = so / m } }
				if (la == "") continue
				for (pick = 1; pick <= 3; pick++) {
					best = ""; bd = 0
					for (j = 1; j <= nc; j++) {
						key = CITY[j]; if ((key in IN) || (key in USED) || !(key in CLA)) continue
						d = d2(la, lo, CLA[key], CLO[key]); if (best == "" || d < bd) { best = key; bd = d }
					}
					if (best == "") break
					USED[best] = 1; ns++
					split(best, b, "|"); nm = b[1] ", " b[2]
					printf "%s\t%s\t%s\n", nm, CLA[best], CLO[best] >> SUG
					printf "%s{\"n\":%d,\"name\":%s,\"km\":%d,\"near\":%s}", (ns > 1 ? "," : ""), ns, q(nm), int(root(bd) / 50 + 0.5) * 50, q(SP[i, 1])
				}
			}
			print "]}"
		}' "$DATA/stay" "$DATA/cities.cache" "$LIB/countries.list" "$DATA/ranges.cache" > "$RUN/www/coverage.json.tmp" && mv -f "$RUN/www/coverage.json.tmp" "$RUN/www/coverage.json"
}
cmd_stay_suggest() { # n : add one of the suggested places with servers to the pool
	local line
	case "$1" in ""|*[!0-9]*) die "choose one of the suggested places" ;; esac
	line="$(sed -n "${1}p" "$RUN/coverage.sug" 2>/dev/null)"
	[ -n "$line" ] || die "that suggestion is no longer on offer. Reload the page."
	touch "$DATA/stay" "$DATA/sessions.tsv" "$DATA/blocklist"
	awk -F'\t' -v p="$(echo "$line" | cut -f1)" '$1 == p { f = 1 } END { exit !f }' "$DATA/stay" || printf '%s\t%s\t-\n' "$line" "${STAY_KM:-150}" >> "$DATA/stay"
	stay_report "$(stay_apply)"
}
cmd_ranges() { # (nothing) = what is known | refresh
	touch "$DATA/ranges.cache"
	if [ "$1" = refresh ]; then ranges_fetch force || die "the lists could not be downloaded"; [ -s "$DATA/stay" ] && stay_ranges; fi
	if [ "$1" = list ]; then [ -s "$DATA/stay" ] || die "stay mode is off, so nothing is turned away"; touch "$DATA/cities.cache"; ranges_outside ""; return 0; fi
	echo "Lists of address ranges by city, from hosting companies:"
	feed_list | awk -F'|' '{ printf "  %s%s  %s\n", $1, ($3 != "" ? " (" $3 ")" : ""), $2 }'
	echo "Ranges known: $(cnt "$DATA/ranges.cache")$(awk -F'\t' '{ c[$4]++ } END { for (h in c) printf "  (%s: %d)", h, c[h] }' "$DATA/ranges.cache")"
	echo "Turned away now for the gaming device: $(cat "$RUN/away.count" 2>/dev/null || echo 0)"
	[ -n "$DEVICE_IP" ] || echo "No device is chosen to watch, so whole ranges are not turned away. Choose one in Settings."
	echo "Add a list of your own in $DATA/geofeeds.local, one per line: name|address of the list. Then: matchwatch ranges refresh"
}

# ---- where each game plays. Matches already say where you played; this adds the servers a game
# reached for without your playing on them. One line per server network and port, updated in place.
tried_note() { # ip port cc city org asn lat lon
	local f="$DATA/tried"
	[ -n "$3" ] || return 0
	touch "$f"
	awk -F'\t' -v OFS='\t' -v p="${1%.*}" -v port="$2" -v cc="$3" -v city="$4" -v org="$5" -v asn="$6" -v lat="$7" -v lon="$8" -v now="$(date +%s)" '
		$1 == p && $2 == port { $9 = $9 + 1; $10 = now; hit = 1 }
		{ L[++n] = $0 }
		END { if (!hit) L[++n] = p OFS port OFS city OFS cc OFS org OFS asn OFS (lat == "" ? "-" : lat) OFS (lon == "" ? "-" : lon) OFS 1 OFS now
			for (i = (n > 2000 ? n - 1999 : 1); i <= n; i++) print L[i] }' "$f" > "$f.tmp" && mv -f "$f.tmp" "$f"
}
gameplaces() { # share | json
	touch "$DATA/sessions.tsv"
	awk -v MODE=gameplaces -v ARG="$1" -v TRIED="$DATA/tried" -v SHARED="$DATA/gameplaces.shared" -v GAMES="$LIB/games.list" -v GAMESL="$DATA/games.local" $( [ -s "$DATA/stay" ] && echo "-v STAYF=$DATA/stay" ) -f "$LIB/report.awk" "$DATA/sessions.tsv"
}

# ---- stay on one datacentre
stay_off() {
	local ip
	touch "$DATA/blocklist"
	awk -F'\t' '$4 == "stay" { print $1 }' "$DATA/blocklist" | while read -r ip; do nft delete element inet matchwatch blocked "{ $ip }" 2>/dev/null; done
	awk -F'\t' '$4 != "stay"' "$DATA/blocklist" > "$DATA/blocklist.tmp" && mv -f "$DATA/blocklist.tmp" "$DATA/blocklist"
	rm -f "$DATA/stay"
	hold_apply
	nft flush set inet matchwatch away 2>/dev/null; rm -f "$RUN/away.count" "$RUN/www/coverage.json" "$RUN/coverage.sug"
	export_json
}
stay_vars() { # awk variable naming the file of places being kept to (nothing when stay mode is off)
	[ -s "$DATA/stay" ] && echo "-v STAYF=$DATA/stay -v GAMES=$LIB/games.list -v GAMESL=$DATA/games.local"
}
stay_names() { awk -F'\t' 'NF >= 4 { s = s (n++ ? " + " : "") $1 } END { printf "%s", s }' "$DATA/stay" 2>/dev/null; }
outside_stay() { # lat lon cc : true when a server is outside every place in the pool
	awk -F'\t' -v a="$1" -v b="$2" -v c="$3" '
		NF >= 4 {
			if ($5 != "" && $5 != "-") { if (index("," $5 ",", "," c ",") > 0) ok = 1; next }
			x = (a + $2) / 2 * 0.0174533; x2 = x * x; cs = 1 - x2 / 2 + x2 * x2 / 24 - x2 * x2 * x2 / 720
			dy = (a - $2) * 111.2; dx = (b - $3) * 111.2 * cs
			if (dx * dx + dy * dy <= $4 * $4) ok = 1
		}
		END { exit ok ? 1 : 0 }' "$DATA/stay"
}
# turn a city name into coordinates (Open-Meteo geocoding; sends only the name typed). prints: name, CC <tab> lat <tab> lon
geocode() {
	local q json name cc lat lon
	q="$(printf '%s' "$1" | tr -cd 'A-Za-z0-9 -' | sed 's/ /%20/g')"
	[ -n "$q" ] || return 1
	json="$(fetch "https://geocoding-api.open-meteo.com/v1/search?name=$q&count=1&language=en&format=json")" || return 1
	lat="$(jnum "$json" latitude)"; lon="$(jnum "$json" longitude)"
	name="$(jstr "$json" name)"; cc="$(jstr "$json" country_code)"
	[ -n "$lat" ] && [ -n "$lon" ] && [ -n "$name" ] || return 1
	printf '%s, %s\t%s\t%s\n' "$name" "$cc" "$lat" "$lon"
}
resolve_place() { # one place as typed -> a pool line: name, lat, lon, km, countries
	local want="$1" line
	case "$want" in
		*[!0-9]*)
			# 1. a named area or a country   2. a city in the regions table   3. any other city, looked up online
			line="$(awk -F'|' -v w="$want" 'BEGIN { w = tolower(w) } /^#/ { next } tolower($2) == w || tolower($3) == w { print $3 "\t-\t-\t0\t" $4; exit }' "$LIB/places.list" 2>/dev/null)"
			[ -n "$line" ] || line="$(awk -F'|' -v w="$want" -v k="${STAY_KM:-150}" 'BEGIN { w = tolower(w) } /^#/ { next } tolower($1) == w || tolower($2) == w { print $2 ", " $3 "\t" $5 "\t" $6 "\t" k "\t-"; exit }' "$LIB/regions.list" $( [ -f "$DATA/regions.local" ] && echo "$DATA/regions.local" ) 2>/dev/null)"
			if [ -z "$line" ]; then
				line="$(geocode "$want")" || { echo "matchwatch: could not find a place called '$want'. Try a city, a country, or an area from: matchwatch places" >&2; return 1; }
				line="$line$TAB${STAY_KM:-150}$TAB-"
			fi ;;
		*) line="$(awk -v MODE=dc_loc -v ARG="$want" -v BLOCK="$DATA/blocklist" -f "$LIB/report.awk" "$DATA/sessions.tsv")"
			[ -n "$line" ] || { echo "matchwatch: no datacentre number $want, or its location is unknown" >&2; return 1; }
			line="$line$TAB${STAY_KM:-150}$TAB-" ;;
	esac
	echo "$line"
}
add_places() { # comma separated list -> appended to the pool (skipping ones already in it); fails if any is unknown
	local list="$1" one line rest
	rest="$list"
	while [ -n "$rest" ]; do
		case "$rest" in *,*) one="${rest%%,*}"; rest="${rest#*,}" ;; *) one="$rest"; rest="" ;; esac
		one="$(echo "$one" | sed 's/^ *//; s/ *$//')"
		[ -n "$one" ] || continue
		line="$(resolve_place "$one")" || return 1
		grep -q "^$(echo "$line" | cut -f1)$TAB" "$DATA/stay" 2>/dev/null || echo "$line" >> "$DATA/stay"
	done
}
stay_apply() { # make the blocks match the pool. Prints how many address blocks are now turned away
	local ip p g cc lat lon live n=0
	touch "$DATA/blocklist" "$DATA/geo.cache"
	live="$(grep -o '"ip":"[0-9.]*"' "$RUN/www/status.json" 2>/dev/null | sed 's/"ip":"\([0-9]*\.[0-9]*\.[0-9]*\)\..*/ \1.0\/24 /' | tr -d '\n')"
	rm -f "$RUN/stay.spared"
	# Blocks already made for staying: keep each one that is still outside the pool. Many were made as the
	# game tried a server you have never played on, so the match history alone would not bring them back,
	# and dropping them lets the game straight in. Where a block's place is not known, it is let go.
	for ip in $(awk -F'\t' '$4 == "stay" { print $1 }' "$DATA/blocklist"); do
		p="${ip%.*}"
		g="$(awk -F'\t' -v p="$p." 'index($1, p) == 1 { l = $2 "\t" $5 "\t" $6 } END { print l }' "$DATA/geo.cache")"
		cc="$(echo "$g" | cut -f1)"; lat="$(echo "$g" | cut -f2)"; lon="$(echo "$g" | cut -f3)"
		if [ -n "$cc" ] && [ -n "$lat" ] && [ -n "$lon" ] && outside_stay "$lat" "$lon" "$cc"; then
			case "$live" in *" $ip "*) ;; *) n=$((n + 1)); continue ;; esac
		fi
		nft delete element inet matchwatch blocked "{ $ip }" 2>/dev/null
		awk -F'\t' -v ip="$ip" '!($1 == ip && $4 == "stay")' "$DATA/blocklist" > "$DATA/blocklist.tmp" && mv -f "$DATA/blocklist.tmp" "$DATA/blocklist"
	done
	# and every address block played on outside the pool
	for p in $(awk -v MODE=area_others $(stay_vars) -f "$LIB/report.awk" "$DATA/sessions.tsv"); do
		# the match being played right now is never cut off: its server is dealt with once the match has ended
		case "$live" in *" $p "*) echo "$p" > "$RUN/stay.spared"; continue ;; esac
		grep -q "^$p$TAB" "$DATA/blocklist" && continue
		MW_QUIET=1 cmd_block "$p" 0 stay; n=$((n + 1))
	done
	( stay_ranges >/dev/null 2>&1 & )
	MW_NOWAIT=1 hold_apply
	export_json
	echo "$n"
}
stay_report() {
	echo "Staying on: $(stay_names)"
	[ -f "$RUN/stay.spared" ] && echo "The match you are in now is on a server outside these places. It is left alone until the match ends."
	echo "Any server in any of these places is allowed, whoever hosts it. $1 address block(s) elsewhere are turned away now; others are turned away as the game tries them."
	if [ "$STAY_RANGES" != 1 ]; then :
	elif [ -z "$DEVICE_IP" ]; then echo "Whole regions cannot be turned away ahead of time until you choose a device to watch, in Settings."
	else echo "Whole regions outside these places are also being turned away ahead of time for your gaming device. This covers games hosted by: $(feed_list | awk -F'|' '{ printf "%s%s%s", (NR > 1 ? ", " : ""), $1, ($3 != "" ? " (" $3 ")" : "") }'). Other games are turned away one server at a time. The Servers page will say within a minute whether your places have servers at all."; fi
	echo "The game still decides which of them to offer you. A place is dropped from the pool if its last three matches average under $WARN_SCORE."
}
# ---- circles drawn on the dashboard's map. A circle is an ordinary pool entry (name, lat, lon, km, -),
# the same as a city; only its name is made up here, from the nearest city in the regions table.
circle_name() { # lat lon km [line-to-ignore] : a name not already in the pool
	local base n=1 name
	base="$(awk -F'|' -v a="$1" -v b="$2" -v k="$3" '
		/^#/ || NF < 6 { next }
		{ x = (a + $5) / 2 * 0.0174533; x2 = x * x; cs = 1 - x2 / 2 + x2 * x2 / 24 - x2 * x2 * x2 / 720
		  dy = (a - $5) * 111.2; dx = (b - $6) * 111.2 * cs; d = dx * dx + dy * dy
		  if (best == "" || d < bd) { bd = d; best = $2 } }
		END { if (best != "" && bd < 1000000) printf "Near %s %d km", best, k; else printf "Circle %d %d %d km", a, b, k }' "$LIB/regions.list" 2>/dev/null)"
	name="$base"
	while awk -F'\t' -v nm="$name" -v skip="${4:-0}" 'NR != skip && $1 == nm { f = 1 } END { exit !f }' "$DATA/stay" 2>/dev/null; do n=$((n + 1)); name="$base $n"; done
	echo "$name"
}
stay_circle() { # [n] lat lon km : add a circle to the pool, or move and resize circle n
	local n="" lat lon km name
	[ $# -ge 4 ] && { n="$1"; shift; }
	echo "$1 $2 $3" | awk '{ if ($1 !~ /^-?[0-9]+(\.[0-9]+)?$/ || $2 !~ /^-?[0-9]+(\.[0-9]+)?$/ || $3 !~ /^[0-9]+(\.[0-9]+)?$/) exit 1
		exit !($1 >= -85 && $1 <= 85 && $2 >= -180 && $2 <= 180 && $3 >= 25 && $3 <= 3000) }' || die "a circle needs a latitude, a longitude and a radius between 25 and 3000 km"
	lat="$(echo "$1" | awk '{ printf "%.3f", $1 }')"; lon="$(echo "$2" | awk '{ printf "%.3f", $1 }')"; km="$(echo "$3" | awk '{ printf "%d", $1 + 0.5 }')"
	touch "$DATA/stay"
	if [ -n "$n" ]; then
		case "$n" in *[!0-9]*) die "no such place in the pool" ;; esac
		awk -F'\t' -v n="$n" 'NR == n && NF >= 4 && $2 != "-" && ($5 == "-" || $5 == "") { f = 1 } END { exit !f }' "$DATA/stay" || die "place $n is a country or an area, which has no circle to move"
		name="$(circle_name "$lat" "$lon" "$km" "$n")"
		awk -F'\t' -v n="$n" -v l="$name$TAB$lat$TAB$lon$TAB$km$TAB-" 'NR == n { print l; next } { print }' "$DATA/stay" > "$DATA/stay.tmp" && mv -f "$DATA/stay.tmp" "$DATA/stay"
	else
		[ "$(wc -l < "$DATA/stay")" -lt 30 ] || die "the pool has 30 places already. Remove one first."
		name="$(circle_name "$lat" "$lon" "$km")"
		printf '%s\t%s\t%s\t%s\t-\n' "$name" "$lat" "$lon" "$km" >> "$DATA/stay"
	fi
	stay_report "$(stay_apply)"
}
cmd_stay() { # <places> | add <places> | remove <n> | circle <lat> <lon> <km> | set <n> <lat> <lon> <km> | off | (nothing = status)
	local n
	touch "$DATA/sessions.tsv" "$DATA/blocklist"
	case "$1" in
		off) if [ -s "$DATA/stay" ]; then stay_off; echo "No longer staying anywhere. The blocks it added are removed."; else echo "Stay mode was not on."; fi ;;
		""|status)
			if [ -s "$DATA/stay" ]; then echo "Staying on:"; awk -F'\t' '{ printf "  %d  %s  (%s)\n", NR, $1, ($5 != "" && $5 != "-" ? "anywhere in it" : "within " $4 " km") }' "$DATA/stay"
			else echo "Stay mode is off. Turn it on with: matchwatch stay <places, separated by commas>"; fi ;;
		circle) stay_circle "$2" "$3" "$4" ;;
		set) [ -n "$5" ] || die "usage: matchwatch stay set <number from 'matchwatch stay'> <lat> <lon> <km>"; stay_circle "$2" "$3" "$4" "$5" ;;
		add) [ -n "$2" ] || die "usage: matchwatch stay add <places, separated by commas>"
			cp "$DATA/stay" "$DATA/stay.bak" 2>/dev/null || : > "$DATA/stay.bak"
			if add_places "$2"; then rm -f "$DATA/stay.bak"; stay_report "$(stay_apply)"; else mv -f "$DATA/stay.bak" "$DATA/stay"; [ -s "$DATA/stay" ] || rm -f "$DATA/stay"; exit 1; fi ;;
		remove) case "$2" in ""|*[!0-9]*) die "usage: matchwatch stay remove <number from 'matchwatch stay'>" ;; esac
			[ -s "$DATA/stay" ] && [ "$2" -ge 1 ] && [ "$2" -le "$(wc -l < "$DATA/stay")" ] || die "no place number $2 in the pool"
			sed -i "${2}d" "$DATA/stay"
			if [ -s "$DATA/stay" ]; then stay_report "$(stay_apply)"; else stay_off; echo "That was the last place, so stay mode is off."; fi ;;
		*)  # replace the pool
			cp "$DATA/stay" "$DATA/stay.bak" 2>/dev/null || : > "$DATA/stay.bak"
			: > "$DATA/stay"
			if add_places "$1" && [ -s "$DATA/stay" ]; then rm -f "$DATA/stay.bak"; stay_report "$(stay_apply)"
			else mv -f "$DATA/stay.bak" "$DATA/stay"; [ -s "$DATA/stay" ] || rm -f "$DATA/stay"; exit 1; fi ;;
	esac
}
cmd_newgame() { # port : a match was just played on a server port nobody has named
	local msg="New game on server port $1. Name it in MatchWatch, or mark it as not a game."
	if [ "$NOTIFY_NEWGAME" = 1 ]; then cmd_notify "$msg"; else logger -t matchwatch "$msg" 2>/dev/null; fi
}
cmd_game() { # name <port or lo-hi> <name> [hosts] [voice] | remove <port or lo-hi>
	local use="usage: matchwatch game name <server port, or a range like 7000-7100> <name> [hosting company words] [voice]   |   matchwatch game remove <port or range>"
	local lo hi hosts kind=""
	case "$1" in name|remove) ;; *) die "$use" ;; esac
	case "$2" in ""|*[!0-9-]*|-*|*-|*-*-*) die "$use" ;; esac
	lo="${2%-*}"; hi="${2#*-}"
	[ "${#lo}" -le 5 ] && [ "${#hi}" -le 5 ] && [ "$lo" -ge 1 ] && [ "$hi" -le 65535 ] && [ "$lo" -le "$hi" ] || die "ports run from 1 to 65535, and a range goes from low to high"
	mkdir -p "$DATA"; touch "$DATA/games.local"
	if [ "$1" = remove ]; then
		awk -F'|' -v p="$2" '$2 != p' "$DATA/games.local" > "$DATA/games.local.tmp"; mv -f "$DATA/games.local.tmp" "$DATA/games.local"
		export_json
		echo "Removed your name for server port $2."
		return 0
	fi
	[ -n "$3" ] || die "$use"
	hosts="$(echo "$4" | tr 'A-Z' 'a-z' | tr -cd 'a-z0-9 ,.-' | sed 's/ *, */,/g; s/^[ ,]*//; s/[ ,]*$//')"
	[ "$5" = voice ] && kind=voice
	if [ -n "$hosts" ]; then echo "$hosts" | tr ',' '\n' | awk 'length($0) < 3 { bad = 1 } END { exit bad }' || die "each hosting company word needs three letters or more"; fi
	# a wide range with no host check would take every unknown stream in it for this game, and stay mode could then block it
	[ $((hi - lo)) -le 2000 ] || [ -n "$hosts" ] || die "a range over 2000 ports wide needs the name of the company hosting the servers"
	# a name you give goes first, so it wins over an imported label that covers the same port
	{ printf '%s|%s|%s|%s\n' "$(echo "$3" | tr -d '|"\\')" "$2" "$kind" "$hosts"; awk -F'|' -v p="$2" '$2 != p' "$DATA/games.local"; } > "$DATA/games.local.tmp"; mv -f "$DATA/games.local.tmp" "$DATA/games.local"
	export_json
	if [ "$kind" = voice ]; then echo "Server port $2 is now marked as not a game ($3). MatchWatch will stop recording it within twenty seconds."
	else echo "Matches on server port $2 are now labelled: $3. Staying on places, the lobby alert and automatic blocking now cover it."; fi
}
cmd_unblock_dc() { # number
	local list p
	case "$1" in ""|*[!0-9]*) die "usage: matchwatch unblock-dc <number>" ;; esac
	list="$(awk -v MODE=dc_prefixes -v ARG="$1" -v BLOCK="$DATA/blocklist" -f "$LIB/report.awk" "$DATA/sessions.tsv")"
	[ -n "$list" ] || die "no datacentre number $1"
	echo "$list" | tail -n +2 | while read -r p; do cmd_unblock "$p"; done
}

# ---- share files: things worth passing to other people, as one plain text file
# Sections: games (labels), regions (ping hosts), places (a pool to stay on), ratings (per server
# network), settings (thresholds), favourites (servers, each with its game).
# Two more names are not sections: favplaces (on import: stay near the file's favourite servers) and
# allservers (on export: every server as a candidate, for the dashboard's picker). A file is only ever made or read when asked; nothing is uploaded.
# Export leaves out everything about this home: no device, LAN or ISP address, and no match times.
# Import trusts nothing: every line is checked and bad ones are dropped. Ratings from someone else are
# shown and mentioned by the lobby alert, and never block anything by themselves.
SHARE_ALL="games regions places ratings settings favourites gameservers"
cnt() { [ -f "$1" ] || { echo 0; return; }; awk '!/^#/ && NF { n++ } END { print n + 0 }' "$1"; }
joined() { awk '{ s = s (NR > 1 ? ", " : "") $0 } END { printf "%s", s }'; }
share_sections() { # "all", nothing, names, or digits (1 games 2 regions 3 places 4 ratings 5 settings 6 favourites 7 favplaces 8 allservers 9 gameservers) -> names
	local s="$*" out="" c
	case "$s" in
		""|all) echo "$SHARE_ALL" ;;
		*[!0-9]*)
			for c in $s; do
				case " $SHARE_ALL favplaces allservers " in *" $c "*) out="$out $c" ;; *) echo "matchwatch: there is no section called '$c'. Sections: $SHARE_ALL" >&2; return 1 ;; esac
			done
			echo $out ;;
		*)
			case "$s" in *1*) out="$out games" ;; esac
			case "$s" in *2*) out="$out regions" ;; esac
			case "$s" in *3*) out="$out places" ;; esac
			case "$s" in *4*) out="$out ratings" ;; esac
			case "$s" in *5*) out="$out settings" ;; esac
			case "$s" in *6*) out="$out favourites" ;; esac
			case "$s" in *7*) out="$out favplaces" ;; esac
			case "$s" in *8*) out="$out allservers" ;; esac
			case "$s" in *9*) out="$out gameservers" ;; esac
			[ -n "$out" ] || { echo "matchwatch: choose at least one thing to share" >&2; return 1; }
			echo $out ;;
	esac
}
share_ratings() { # one line per server network with a counted match: network|matches|average|city|country|host
	touch "$DATA/sessions.tsv"
	awk -F'\t' '
		function clean(s) { gsub(/[^A-Za-z0-9 .,()&-]/, " ", s); return s }
		NF >= 39 && $37 == 1 { split($5, o, "."); p = o[1] "." o[2] "." o[3] ".0/24"; if (!(p in n)) ord[++k] = p; n[p]++; s[p] += $36; c[p] = $8; cc[p] = $7; g[p] = $9 }
		END { for (i = 1; i <= k; i++) { p = ord[i]; printf "%s|%d|%.0f|%s|%s|%s\n", p, n[p], s[p] / n[p], clean(c[p]), (cc[p] ~ /^[A-Z][A-Z]$/ ? cc[p] : "-"), clean(g[p]) } }' "$DATA/sessions.tsv"
}
share_servers() { # favourites | allservers -> server lines with the game each was played for
	touch "$DATA/sessions.tsv" "$DATA/favourites"
	awk -v MODE=share_servers -v ARG="$1" -v FAVF="$DATA/favourites" -v GAMES="$LIB/games.list" -v GAMESL="$DATA/games.local" -f "$LIB/report.awk" "$DATA/sessions.tsv"
}
share_favplaces() { # dir -> pool lines for the cities the file's favourite servers are in
	awk -F'\t' -v k="${STAY_KM:-150}" '$3 != "" && $6 != "-" && $7 != "-" { nm = $3 ($4 != "-" ? ", " $4 : ""); if (!(nm in s)) { s[nm] = 1; printf "%s\t%s\t%s\t%s\t-\n", nm, $6, $7, k } }' "$1/favourites"
}
cmd_share_export() { # [sections] -> the share file, on standard output
	local want sec
	want="$(share_sections "$@")" || exit 1
	echo "# MatchWatch share file. Import it on the Tools page, or with: matchwatch share import <file>"
	echo "# It holds nothing about the home it came from: no device, LAN or ISP address, and no match times."
	echo "matchwatch-share 1"
	for sec in $want; do
		[ "$sec" = favplaces ] && continue
		echo
		if [ "$sec" = allservers ]; then echo "[favourites]"; else echo "[$sec]"; fi
		case "$sec" in
			games) echo "# name|server ports|kind (empty = a game, voice = voice chat)|words in the name of the company hosting the servers"
				[ -f "$DATA/games.local" ] && awk -F'|' '/^#/ || NF < 2 { next } { printf "%s|%s|%s|%s\n", $1, $2, $3, $4 }' "$DATA/games.local" ;;
			regions) echo "# code|city|country code|area|latitude|longitude|ping host"
				[ -f "$DATA/regions.local" ] && awk '!/^#/ && NF' "$DATA/regions.local" ;;
			places) echo "# name|latitude|longitude|reach in km|country codes"
				[ -f "$DATA/stay" ] && awk -F'\t' 'NF >= 4 { gsub(/[^A-Za-z0-9 ,.()-]/, " ", $1); printf "%s|%s|%s|%s|%s\n", $1, $2, $3, $4, ($5 == "" ? "-" : $5) }' "$DATA/stay" ;;
			ratings) echo "# server network|matches|average rating out of 100|city|country code|host"
				echo "# These are one home's experience. They mean most to people nearby on a similar connection."
				share_ratings ;;
			gameservers) echo "# game|server network|city|country code|host|latitude|longitude|matches played there|rating out of 100"
				echo "# Where each game has put you, or tried to. Public game servers only."
				gameplaces share ;;
			favourites|allservers) echo "# server|game|city|country code|host|rating out of 100|matches|latitude|longitude"
				share_servers "$sec" ;;
			settings) echo "# the thresholds this copy of MatchWatch runs with"
				printf 'min_down_pps=%s\nmin_up_pps=%s\nwarn_score=%s\nautoblock_score=%s\nautoblock_matches=%s\nlobby_margin_ms=%s\nstay_km=%s\nblock_days=%s\n' \
					"$MIN_DOWN_PPS" "$MIN_UP_PPS" "$WARN_SCORE" "$AUTOBLOCK_SCORE" "$AUTOBLOCK_MATCHES" "$LOBBY_MARGIN_MS" "$STAY_KM" "$BLOCK_DAYS" ;;
		esac
	done
	return 0
}
share_load() { # file dir : check every line. The good ones land in dir/<section>, the verdicts in dir/summary
	local why
	[ -f "$1" ] || { echo "matchwatch: no such file: $1" >&2; return 1; }
	[ "$(wc -c < "$1")" -le 65536 ] || { echo "matchwatch: that is too big to be a share file" >&2; return 1; }
	mkdir -p "$2" || return 1
	awk -v OUT="$2" -v WIDE=2000 '
	function bad(why) { nbad++; if (nbad <= 8) printf "bad\t%d\t%s\n", NR, why }
	function num(x) { return x ~ /^-?[0-9]+(\.[0-9]+)?$/ && length(x) <= 12 }
	function whole(x, lo, hi) { return x ~ /^[0-9]+$/ && length(x) <= 6 && x + 0 >= lo && x + 0 <= hi }
	function ports(s,   a, k, i, r) {
		k = split(s, a, ","); if (k < 1 || k > 12) return "a port list that cannot be read"
		for (i = 1; i <= k; i++) {
			if (a[i] ~ /^[0-9]+-[0-9]+$/) {
				split(a[i], r, "-")
				if (!whole(r[1], 1, 65535) || !whole(r[2], 1, 65535) || r[1] + 0 > r[2] + 0) return "a port range that cannot be read"
				if (r[2] - r[1] > WIDE) wide = 1
			} else if (!whole(a[i], 1, 65535)) return "a port that cannot be read"
		}
		return ""
	}
	function hosts(s,   a, k, i) {
		if (s == "") return 1
		if (s !~ /^[a-z0-9 ,.-]+$/) return 0
		k = split(s, a, ",")
		for (i = 1; i <= k; i++) if (length(a[i]) < 3) return 0
		return 1
	}
	function keep(sec, line, max) { if (N[sec] >= max) { bad("more " sec " than one file may hold"); return } N[sec]++; print line > (OUT "/" sec) }
	BEGIN {
		ALL = " games regions places ratings settings favourites gameservers "
		R["min_down_pps"] = "1 1000"; R["min_up_pps"] = "1 1000"; R["warn_score"] = "0 100"; R["autoblock_score"] = "0 100"
		R["autoblock_matches"] = "1 50"; R["lobby_margin_ms"] = "0 500"; R["stay_km"] = "10 2000"; R["block_days"] = "1 365"
	}
	{ sub(/\r$/, "") }
	/^[ \t]*$/ || /^#/ { next }
	!head { if ($0 == "matchwatch-share 1") { head = 1; next } print "bad\t" NR "\tthis is not a MatchWatch share file"; exit }
	/^\[[a-z]+\]$/ { sec = substr($0, 2, length($0) - 2); if (index(ALL, " " sec " ") == 0) sec = "?"; next }
	sec == "?" { next }
	sec == "" { bad("a line before any section"); next }
	length($0) > 300 { bad("a line that is too long"); next }
	sec == "games" {
		n = split($0, f, "|"); wide = 0
		if (n < 2 || n > 4) { bad("a game needs a name and its server ports"); next }
		if (f[1] !~ /^[A-Za-z0-9 .:,()&+-]+$/ || length(f[1]) > 80) { bad("a game name with characters that are not allowed"); next }
		e = ports(f[2]); if (e != "") { bad(e); next }
		if (f[3] != "" && f[3] != "voice") { bad("a kind that is neither empty nor voice"); next }
		if (!hosts(f[4])) { bad("host words that cannot be used (lower case, three letters or more each)"); next }
		if (wide && f[4] == "") { bad("a range over " WIDE " ports wide with no host to check: it would take unrelated traffic for " f[1]); next }
		keep("games", f[1] "|" f[2] "|" f[3] "|" f[4], 200); next
	}
	sec == "regions" {
		n = split($0, f, "|")
		if (n != 7 || f[1] !~ /^[a-z0-9-]+$/ || length(f[1]) > 16 || f[2] !~ /^[A-Za-z .-]+$/ || length(f[2]) > 40 || f[3] !~ /^[A-Z][A-Z]$/ || f[4] !~ /^[A-Za-z ]+$/ || length(f[4]) > 30 \
			|| !num(f[5]) || f[5] < -90 || f[5] > 90 || !num(f[6]) || f[6] < -180 || f[6] > 180 \
			|| f[7] !~ /^[a-z0-9][a-z0-9.-]*\.[a-z]+$/ || f[7] ~ /\.\./ || length(f[7]) > 80) { bad("a region line that cannot be read"); next }
		keep("regions", $0, 80); next
	}
	sec == "places" {
		n = split($0, f, "|")
		if (n != 5 || f[1] !~ /^[A-Za-z0-9 ,.()-]+$/ || length(f[1]) > 60) { bad("a place line that cannot be read"); next }
		if (f[5] ~ /^[A-Z][A-Z](,[A-Z][A-Z])*$/ && f[4] == "0") { keep("places", f[1] "\t-\t-\t0\t" f[5], 20); next }
		if (f[5] == "-" && num(f[2]) && f[2] >= -90 && f[2] <= 90 && num(f[3]) && f[3] >= -180 && f[3] <= 180 && whole(f[4], 10, 2000)) { keep("places", f[1] "\t" f[2] "\t" f[3] "\t" f[4] "\t-", 20); next }
		bad("a place that is neither a set of countries nor a point with a reach"); next
	}
	sec == "ratings" {
		n = split($0, f, "|"); k = split(f[1], o, ".")
		if (n != 6 || f[1] !~ /^[0-9]+\.[0-9]+\.[0-9]+\.0\/24$/ || k != 4 || !whole(o[1], 1, 223) || !whole(o[2], 0, 255) || !whole(o[3], 0, 255) \
			|| o[1] == 10 || o[1] == 127 || (o[1] == 172 && o[2] >= 16 && o[2] <= 31) || (o[1] == 192 && o[2] == 168) || (o[1] == 169 && o[2] == 254) \
			|| !whole(f[2], 1, 9999) || !whole(f[3], 0, 100) || f[4] !~ /^[A-Za-z0-9 .,()&-]*$/ || f[5] !~ /^([A-Z][A-Z]|-)$/ || f[6] !~ /^[A-Za-z0-9 .,()&-]*$/) { bad("a rating line that cannot be read"); next }
		keep("ratings", f[1] "\t" f[2] "\t" f[3] "\t" f[4] "\t" f[5] "\t" f[6], 500); next
	}
	sec == "gameservers" {
		n = split($0, f, "|"); k = split(f[2], o, ".")
		if (n != 9 || f[1] !~ /^[A-Za-z0-9 .:,()&+-]+$/ || length(f[1]) > 80 || f[2] !~ /^[0-9]+\.[0-9]+\.[0-9]+\.0\/24$/ || k != 4 || !whole(o[1], 1, 223) || !whole(o[2], 0, 255) || !whole(o[3], 0, 255) \
			|| o[1] == 10 || o[1] == 127 || (o[1] == 172 && o[2] >= 16 && o[2] <= 31) || (o[1] == 192 && o[2] == 168) || (o[1] == 169 && o[2] == 254) \
			|| f[3] !~ /^[A-Za-z0-9 .,()&-]*$/ || f[4] !~ /^([A-Z][A-Z]|-)$/ || f[5] !~ /^[A-Za-z0-9 .:,()&+-]*$/ \
			|| !whole(f[8], 0, 99999) || (f[9] != "" && !whole(f[9], 0, 100))) { bad("a game server line that cannot be read"); next }
		la = (num(f[6]) && f[6] >= -90 && f[6] <= 90 && num(f[7]) && f[7] >= -180 && f[7] <= 180) ? f[6] "\t" f[7] : "-\t-"
		keep("gameservers", f[1] "\t" f[2] "\t" f[3] "\t" f[4] "\t" f[5] "\t" la "\t" f[8] "\t" f[9], 3000); next
	}
	sec == "favourites" {
		n = split($0, f, "|"); k = split(f[1], o, ".")
		if (n != 9 || f[1] !~ /^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$/ || k != 4 || !whole(o[1], 1, 223) || !whole(o[2], 0, 255) || !whole(o[3], 0, 255) || !whole(o[4], 0, 255) \
			|| o[1] == 10 || o[1] == 127 || (o[1] == 172 && o[2] >= 16 && o[2] <= 31) || (o[1] == 192 && o[2] == 168) || (o[1] == 169 && o[2] == 254) \
			|| f[2] !~ /^[A-Za-z0-9 .:,()&+-]*$/ || length(f[2]) > 80 || f[3] !~ /^[A-Za-z0-9 .,()&-]*$/ || f[4] !~ /^([A-Z][A-Z]|-)$/ || f[5] !~ /^[A-Za-z0-9 .:,()&+-]*$/ \
			|| (f[6] != "" && !whole(f[6], 0, 100)) || !whole(f[7], 0, 9999)) { bad("a favourite server line that cannot be read"); next }
		la = (num(f[8]) && f[8] >= -90 && f[8] <= 90 && num(f[9]) && f[9] >= -180 && f[9] <= 180) ? f[8] "\t" f[9] : "-\t-"
		keep("favourites", f[1] "\t" f[2] "\t" f[3] "\t" f[4] "\t" f[5] "\t" la "\t" f[6] "\t" f[7], 200); next
	}
	sec == "settings" {
		n = split($0, f, "=")
		if (n != 2 || !(f[1] in R)) { bad("a setting that share files may not change"); next }
		split(R[f[1]], lim, " ")
		if (!whole(f[2], lim[1], lim[2])) { bad(f[1] " must be between " lim[1] " and " lim[2]); next }
		if (f[1] in SEEN) next
		SEEN[f[1]] = 1; keep("settings", f[1] "=" (f[2] + 0), 20); next
	}
	END { for (s in N) printf "ok\t%s\t%d\n", s, N[s]; printf "rejected\t%d\n", nbad }' "$1" > "$2/summary"
	grep -q "^ok$TAB" "$2/summary" && return 0
	why="$(awk -F'\t' '$1 == "bad" { print $3; exit }' "$2/summary")"
	echo "matchwatch: nothing in that file can be imported${why:+: $why}" >&2
	return 1
}
share_count() { awk -F'\t' -v s="$2" '$1 == "ok" && $2 == s { n = $3 } END { print n + 0 }' "$1/summary"; }
share_describe() { # dir -> what the file holds and what importing each part would do, one line per section
	local d="$1" sec n more p
	for sec in $SHARE_ALL; do
		n="$(share_count "$d" "$sec")"
		[ "$n" -ge 1 ] || continue
		more=""; [ "$n" -gt 8 ] && more=" and more"
		case "$sec" in
			games) echo "games: $n game label(s): $(cut -d'|' -f1 "$d/games" | head -n 8 | joined)$more. They go below the names you have given yourself, which always win." ;;
			regions) echo "regions: $n ping host(s) for the regions table: $(cut -d'|' -f2 "$d/regions" | head -n 8 | joined)$more." ;;
			places) echo "places: $n place(s) to stay on: $(cut -f1 "$d/places" | head -n 8 | joined)$more. Importing these turns staying on, so game servers elsewhere are blocked." ;;
			ratings) echo "ratings: $n server rating(s) from someone else. They are shown to you and mentioned by the lobby alert, and never block anything by themselves." ;;
			gameservers) echo "gameservers: $n server network(s) for $(cut -f1 "$d/gameservers" | awk '{ if (!($0 in c)) o[++k] = $0; c[$0]++ } END { for (i = 1; i <= k && i <= 6; i++) printf "%s%s (%d)", (i > 1 ? ", " : ""), o[i], c[o[i]]; if (k > 6) printf " and %d more games", k - 6 }'). Countries covered: $(cut -f4 "$d/gameservers" | sort -u | grep -c '[A-Z]'). They add to what MatchWatch knows about where each game plays. They are shown to you; nothing is blocked or allowed because of them." ;;
			favourites) echo "favourites: $n favourite server(s) for $(cut -f2 "$d/favourites" | awk '{ g = ($0 == "" ? "other games" : $0); if (!(g in c)) o[++k] = g; c[g]++ } END { for (i = 1; i <= k; i++) printf "%s%s (%d)", (i > 1 ? ", " : ""), o[i], c[o[i]] }'). They join your favourites under those games: never blocked automatically, and the lobby alert tells you when you land on one."
				p="$(share_favplaces "$d" | cut -f1 | head -n 8 | joined)"
				[ -n "$p" ] && echo "favplaces: Stay near those servers: adds $p to the places you stay on and turns staying on, so game servers elsewhere are blocked." ;;
			settings) echo "settings: $n setting(s): $(joined < "$d/settings"). Importing these restarts MatchWatch, so do it between matches." ;;
		esac
	done
	awk -F'\t' '$1 == "rejected" && $2 > 0 { r = $2 } $1 == "bad" { b[++k] = "  line " $2 ": " $3 } END { if (r) { printf "%d line(s) were not accepted and are left out:\n", r; for (i = 1; i <= k; i++) print b[i] } }' "$d/summary"
}
cmd_share_check() { # file : say what is in it. Changes nothing
	local d="$RUN/share.$$" rc=0
	mkdir -p "$RUN"
	if share_load "$1" "$d"; then share_describe "$d"; else rc=1; fi
	rm -rf "$d"
	return $rc
}
share_set() { # file of key=value lines -> into the settings, then restart so they take effect
	local k v
	while IFS="=" read -r k v; do
		[ -n "$k" ] || continue
		if [ -n "$CONF" ]; then echo "$(echo "$k" | tr a-z A-Z)=$v" >> "$CONF"; else uci -q set "matchwatch.main.$k=$v"; fi
	done < "$1"
	[ -n "$CONF" ] && return 0
	uci -q commit matchwatch
	[ -x /etc/init.d/matchwatch ] && ( sleep 1; /etc/init.d/matchwatch restart ) >/dev/null 2>&1 &
}
share_keep() { # name : remember this data file as it is now, so the import can be undone
	[ -f "$DATA/share.undo/$1" ] || [ -f "$DATA/share.undo/$1.none" ] && return 0   # already kept by an earlier section of this import
	if [ -f "$DATA/$1" ]; then cp "$DATA/$1" "$DATA/share.undo/$1"; else : > "$DATA/share.undo/$1.none"; fi
}
cmd_share_import() { # file [sections] : take in the chosen sections of a share file
	local f="$1" d="$RUN/share.$$" want sec src n line p k v
	shift
	want="$(share_sections "$@")" || return 1
	mkdir -p "$RUN" "$DATA"
	share_load "$f" "$d" || { rm -rf "$d"; return 1; }
	rm -rf "$DATA/share.undo"; mkdir -p "$DATA/share.undo"
	for sec in $want; do
		src="$sec"; [ "$sec" = favplaces ] && src=favourites
		[ -s "$d/$src" ] || continue
		n=0
		case "$sec" in
			games) share_keep games.local; touch "$DATA/games.local"
				while IFS= read -r line; do
					p="$(echo "$line" | cut -d'|' -f2)"
					awk -F'|' -v p="$p" '$2 == p { f = 1 } END { exit !f }' "$DATA/games.local" && continue
					echo "$line" >> "$DATA/games.local"; n=$((n + 1))
				done < "$d/games"
				echo "Added $n game label(s). Ones for ports you had already named were left out." ;;
			regions) share_keep regions.local; touch "$DATA/regions.local"
				while IFS= read -r line; do
					p="${line%%|*}"
					grep -q "^$p|" "$LIB/regions.list" "$DATA/regions.local" 2>/dev/null && continue
					echo "$line" >> "$DATA/regions.local"; n=$((n + 1))
				done < "$d/regions"
				[ "$n" -ge 1 ] && ( cmd_regions measure >/dev/null 2>&1 & )
				echo "Added $n ping host(s) to the regions table. They are being measured now." ;;
			places) share_keep stay; touch "$DATA/stay" "$DATA/sessions.tsv"
				while IFS= read -r line; do
					p="$(echo "$line" | cut -f1)"
					awk -F'\t' -v p="$p" '$1 == p { f = 1 } END { exit !f }' "$DATA/stay" && continue
					echo "$line" >> "$DATA/stay"; n=$((n + 1))
				done < "$d/places"
				stay_apply >/dev/null
				echo "Added $n place(s). Staying on: $(stay_names)." ;;
			ratings) share_keep ratings.shared; touch "$DATA/ratings.shared"
				n="$(cnt "$d/ratings")"
				awk -F'\t' 'NR == FNR { seen[$1] = 1; print; next } !($1 in seen)' "$d/ratings" "$DATA/ratings.shared" | head -n 1000 > "$DATA/ratings.shared.tmp" && mv -f "$DATA/ratings.shared.tmp" "$DATA/ratings.shared"
				echo "Took in $n server rating(s). They are listed on the Tools page." ;;
			gameservers) share_keep gameplaces.shared; touch "$DATA/gameplaces.shared"
				n="$(cnt "$d/gameservers")"
				awk -F'\t' 'FILENAME == ARGV[1] { seen[$1 FS $2] = 1; print; next } !(($1 FS $2) in seen)' "$d/gameservers" "$DATA/gameplaces.shared" | head -n 5000 > "$DATA/gameplaces.shared.tmp" && mv -f "$DATA/gameplaces.shared.tmp" "$DATA/gameplaces.shared"
				echo "Took in $n game server network(s). They are under Where each game plays, on the Servers page." ;;
			favourites) share_keep favourites; touch "$DATA/favourites"
				n="$(awk -F'\t' -v OFS='\t' 'FILENAME == ARGV[1] { have[$1] = 1; c++; next } !($1 in have) && c < 200 { have[$1] = 1; c++; print $1, $2, $3, $4, $5 }' "$DATA/favourites" "$d/favourites" | tee -a "$DATA/favourites" | awk 'END { print NR + 0 }')"
				echo "Added $n favourite server(s). They are on the Servers page, grouped by game." ;;
			favplaces) share_favplaces "$d" > "$d/favplaces"
				[ -s "$d/favplaces" ] || { echo "The favourite servers in the file carry no locations, so there is nowhere to stay near."; continue; }
				share_keep stay; touch "$DATA/stay" "$DATA/sessions.tsv"
				while IFS= read -r line; do
					p="$(echo "$line" | cut -f1)"
					awk -F'\t' -v p="$p" '$1 == p { f = 1 } END { exit !f }' "$DATA/stay" && continue
					echo "$line" >> "$DATA/stay"; n=$((n + 1))
				done < "$d/favplaces"
				stay_apply >/dev/null
				echo "Added $n place(s) near those servers. Staying on: $(stay_names)." ;;
			settings) : > "$DATA/share.undo/settings"
				while IFS="=" read -r k v; do eval "p=\$$(echo "$k" | tr a-z A-Z)"; echo "$k=$p" >> "$DATA/share.undo/settings"; n=$((n + 1)); done < "$d/settings"
				share_set "$d/settings"
				echo "Changed $n setting(s). MatchWatch is restarting to use them." ;;
		esac
	done
	rm -rf "$d"
	if [ -z "$(ls "$DATA/share.undo")" ]; then rmdir "$DATA/share.undo"; echo "Nothing was imported: the file holds none of the things you chose."; return 0; fi
	export_json
	echo "To put things back as they were: matchwatch share undo, or the Undo button on the Tools page."
}
cmd_share_undo() { # put back what the last import changed
	local u="$DATA/share.undo" f
	[ -d "$u" ] || { echo "matchwatch: there is no import to undo" >&2; return 1; }
	for f in games.local regions.local stay ratings.shared favourites gameplaces.shared; do
		if [ -f "$u/$f" ]; then cp "$u/$f" "$DATA/$f"
		elif [ -f "$u/$f.none" ]; then rm -f "$DATA/$f"
		else continue; fi
		if [ "$f" = stay ]; then if [ -s "$DATA/stay" ]; then stay_apply >/dev/null; else stay_off; fi; fi
	done
	[ -f "$u/settings" ] && share_set "$u/settings"
	rm -rf "$u"
	export_json
	echo "The last import is undone. Game names, places, ping hosts, shared ratings, favourites and settings are as they were before it."
}
cmd_share_forget() { # [network] : every rating shared with you, or just one network's
	if [ -n "$1" ]; then
		[ -f "$DATA/ratings.shared" ] && awk -F'\t' -v p="$1" '$1 != p' "$DATA/ratings.shared" > "$DATA/ratings.shared.tmp" && mv -f "$DATA/ratings.shared.tmp" "$DATA/ratings.shared"
		export_json
		echo "Removed the shared rating for $1."
		return 0
	fi
	rm -f "$DATA/ratings.shared"
	export_json
	echo "Shared ratings removed. Your own ratings are untouched."
}
share_json() { # what the Tools page needs: how much there is to share, and the ratings shared with you
	local undo=false
	[ -d "$DATA/share.undo" ] && undo=true
	touch "$DATA/blocklist"
	printf '{"undo":%s,"have":{"games":%d,"regions":%d,"places":%d,"ratings":%d},"ratings":[' "$undo" \
		"$(cnt "$DATA/games.local")" "$(cnt "$DATA/regions.local")" "$(cnt "$DATA/stay")" "$(share_ratings | awk 'END { print NR + 0 }')"
	[ -f "$DATA/ratings.shared" ] && awk -F'\t' -v BL="$DATA/blocklist" 'BEGIN { while ((getline l < BL) > 0) { split(l, b, "\t"); B[b[1]] = 1 } close(BL) } NF >= 3 { printf "%s{\"p\":\"%s\",\"n\":%d,\"avg\":%d,\"city\":\"%s\",\"cc\":\"%s\",\"org\":\"%s\",\"blocked\":%s}", (k++ ? "," : ""), $1, $2, $3, $4, $5, $6, (($1 in B) ? "true" : "false") }' "$DATA/ratings.shared"
	echo "]}"
}
cmd_share() {
	local f
	case "$1" in
		export) shift; cmd_share_export "$@" ;;
		check) [ -n "$2" ] || die "usage: matchwatch share check <file>"; cmd_share_check "$2" || exit 1 ;;
		import) [ -n "$2" ] || die "usage: matchwatch share import <file> [$SHARE_ALL]"; f="$2"; shift 2; cmd_share_import "$f" "$@" || exit 1 ;;
		undo) cmd_share_undo || exit 1 ;;
		forget) cmd_share_forget "$2" ;;
		*) cat <<EOF
matchwatch share export [sections] > file    write a share file (nothing about your home goes in it)
matchwatch share check <file>                say what a share file holds; changes nothing
matchwatch share import <file> [sections]    take in a share file, or only some sections of it
matchwatch share undo                        put back what the last import changed
matchwatch share forget                      remove ratings other people shared with you
Sections: $SHARE_ALL (default: all)
On import, favplaces also stays near the file's favourite servers.
EOF
		;;
	esac
}

# ---- favourites: servers worth finding again. The dashboard groups them by game.
# A favourite is never blocked automatically, and the lobby alert says when you land on one.
is_fav() { [ -f "$DATA/favourites" ] && awk -v ip="$1" '$1 == ip { f = 1 } END { exit !f }' "$DATA/favourites"; }
# ---- single servers let through the places being stayed on. /etc/matchwatch/allow holds one address a
# line; the nftables set "allowed" is matched before anything is refused, so a server in it gets through
# whatever its region. Exact addresses only: nothing the owner did not choose is ever let in.
is_allowed() { [ -s "$DATA/allow" ] && grep -qxF "$1" "$DATA/allow"; }
allow_fill() {
	local ip
	[ -s "$DATA/allow" ] || return 0
	while read -r ip; do is_ipv4 "$ip" && nft add element inet matchwatch allowed "{ $ip }" 2>/dev/null; done < "$DATA/allow"
	return 0
}
allow_drop() { # ip : take one address back out, quietly
	[ -f "$DATA/allow" ] || return 0
	grep -vxF "$1" "$DATA/allow" > "$DATA/allow.tmp"; mv -f "$DATA/allow.tmp" "$DATA/allow"
	nft delete element inet matchwatch allowed "{ $1 }" 2>/dev/null
	return 0
}
cmd_allow() { # add <ip> | remove <ip> | (nothing = list)
	local ip="$2"
	mkdir -p "$DATA"; touch "$DATA/allow" "$DATA/blocklist"
	case "$1" in
		""|list) if [ -s "$DATA/allow" ]; then cat "$DATA/allow"; else echo "No single servers are let through. Add one with: matchwatch allow add <server-ip>"; fi; return 0 ;;
		add|remove) ;;
		*) die "usage: matchwatch allow [add|remove <server-ip>]" ;;
	esac
	is_ipv4 "$ip" || die "usage: matchwatch allow $1 <server-ip>"
	is_private "$ip" && die "that is not a game server"
	if [ "$1" = remove ]; then
		is_allowed "$ip" || die "$ip is not one of the servers you let through"
		allow_drop "$ip"; export_json
		echo "$ip is no longer let through. It is treated like any other server again."
		return 0
	fi
	is_allowed "$ip" && { echo "$ip is already let through."; return 0; }
	[ "$(wc -l < "$DATA/allow")" -lt 100 ] || die "100 servers are let through already. Remove one first."
	awk -F'\t' -v ip="$ip" '$1 == ip && $4 != "stay" { f = 1 } END { exit !f }' "$DATA/blocklist" && die "you have blocked $ip. Unblock it first."
	nft_ready || exit 1
	echo "$ip" >> "$DATA/allow"
	nft add element inet matchwatch allowed "{ $ip }" 2>/dev/null
	export_json
	if [ -s "$DATA/stay" ]; then echo "$ip is now let through, whatever region it is in. The game still decides whether to offer it to you."
	else echo "$ip will be let through when you stay on places. You are not staying anywhere at the moment."; fi
}

# ---- strict, per game. For a game the owner chose, every server on that game's ports is held back
# until MatchWatch has placed it: inside the places being stayed on (or not a game server at all) and it
# is let through, outside and its address block is turned away. Without this a new server gets its first
# packets through while it is being looked up. /etc/matchwatch/hold lists the games, one name a line.
# In nftables: hold_ports are those games' server ports, okay the servers with a verdict, and one rule
# drops the gaming device's UDP to a held port unless the server is in okay. The engine sees the device's
# packets before that rule (it listens on the LAN side) and asks for a verdict with _hold.
# Everything fails open: no stay pool, no device, a stopped service or a failed lookup all mean no holding.
label_kind() { # server-port "isp org asn" -> game | voice | nothing. First matching label wins, as in the engine
	touch "$DATA/games.local" 2>/dev/null
	awk -F'|' -v p="$1" -v info="$(echo "$2" | tr 'A-Z' 'a-z')" '
		/^#/ || $0 == "" { next }
		{ n = split($2, a, ","); hit = 0
		  for (i = 1; i <= n; i++) { lo = a[i]; hi = a[i]; if (a[i] ~ /-/) { split(a[i], r, "-"); lo = r[1]; hi = r[2] } if (p + 0 >= lo + 0 && p + 0 <= hi + 0) hit = 1 }
		  if (!hit) next
		  if ($4 != "") { m = 0; k = split(tolower($4), w, ","); for (i = 1; i <= k; i++) if (w[i] != "" && index(info, w[i]) > 0) m = 1; if (!m) next }
		  print ($3 == "voice" ? "voice" : "game"); exit }' "$DATA/games.local" "$LIB/games.list" 2>/dev/null
}
hold_list() { # every game name: name, held (0/1), can be held (0/1), its ports, the ports that would be held
	touch "$DATA/games.local" "$DATA/hold" 2>/dev/null
	awk -F'|' -v HF="$DATA/hold" '
		BEGIN { while ((getline l < HF) > 0) on[l] = 1; close(HF) }
		/^#/ || $0 == "" || NF < 2 { next }
		{ n = split($2, a, ",")
		  for (i = 1; i <= n; i++) { lo = a[i]; hi = a[i]; if (a[i] ~ /-/) { split(a[i], r, "-"); lo = r[1]; hi = r[2] } c++; L[c] = lo + 0; H[c] = hi + 0; N[c] = $1; V[c] = ($3 == "voice") }
		  if ($3 != "voice" && !($1 in seen)) { seen[$1] = 1; order[++k] = $1 } }
		END { for (j = 1; j <= k; j++) { nm = order[j]; ports = ""; held = ""; all = 0; kept = 0
			for (x = 1; x <= c; x++) if (N[x] == nm && !V[x] && !((nm, L[x], H[x]) in dup)) {
				dup[nm, L[x], H[x]] = 1
				ports = ports (ports == "" ? "" : " ") (L[x] == H[x] ? L[x] : L[x] "-" H[x]); all += H[x] - L[x] + 1
				# voice chat ports inside a game range are cut out of what is held, so the start of a call is never held
				ns = 1; SL[1] = L[x]; SH[1] = H[x]
				for (y = 1; y <= c; y++) if (V[y]) { m = ns; for (z = 1; z <= m; z++) {
					if (SL[z] > SH[z] || L[y] > SH[z] || H[y] < SL[z]) continue
					if (L[y] > SL[z] && H[y] < SH[z]) { ns++; SL[ns] = H[y] + 1; SH[ns] = SH[z]; SH[z] = L[y] - 1 }
					else if (L[y] <= SL[z]) SL[z] = H[y] + 1
					else SH[z] = L[y] - 1 } }
				for (z = 1; z <= ns; z++) if (SL[z] <= SH[z]) { held = held (held == "" ? "" : " ") (SL[z] == SH[z] ? SL[z] : SL[z] "-" SH[z]); kept += SH[z] - SL[z] + 1 }
			}
			# a game that keeps under half its ports after that mostly lives on voice chat ports: not offered
			printf "%s\t%d\t%d\t%s\t%s\n", nm, (nm in on), (all > 0 && kept * 2 >= all), ports, held } }' "$DATA/games.local" "$LIB/games.list" 2>/dev/null
}
hold_apply() { # make the firewall and the engine agree with the list of held games
	local r live ip
	rm -f "$RUN/hold.ports"
	have nft || return 0
	# first stop holding, then throw the old verdicts away: they were made for the pool as it was
	nft flush set inet matchwatch hold_ports 2>/dev/null
	nft flush set inet matchwatch okay 2>/dev/null
	[ -s "$DATA/stay" ] && [ -s "$DATA/hold" ] && is_ipv4 "$DEVICE_IP" || return 0
	nft list set inet matchwatch hold_ports >/dev/null 2>&1 || nft_ready || return 1
	# a match being played keeps its server, whatever the pool now says
	for ip in $(grep -o '"ip":"[0-9.]*"' "$RUN/www/status.json" 2>/dev/null | sed 's/"ip":"\([0-9.]*\)"/\1/'); do nft add element inet matchwatch okay "{ $ip }" 2>/dev/null; done
	# the engine learns the ports first, so nothing is held before it is ready to ask about it
	{ echo "# $(date +%s)"; hold_list | awk -F'\t' '$2 == 1 && $3 == 1 { n = split($5, a, " "); for (i = 1; i <= n; i++) { lo = a[i]; hi = a[i]; if (a[i] ~ /-/) { split(a[i], r, "-"); lo = r[1]; hi = r[2] } print lo, hi } }'; } > "$RUN/hold.ports.tmp"
	mv -f "$RUN/hold.ports.tmp" "$RUN/hold.ports"
	[ "$(wc -l < "$RUN/hold.ports")" -gt 1 ] || { rm -f "$RUN/hold.ports"; return 0; }
	[ "$MW_NOWAIT" = 1 ] || sleep 2
	awk '!/^#/ { print ($1 == $2 ? $1 : $1 "-" $2) }' "$RUN/hold.ports" | while read -r r; do nft add element inet matchwatch hold_ports "{ $r }" 2>/dev/null; done
	return 0
}
cmd_hold_check() { # server-ip port : the engine saw the device reach for a server on a held port. Decide
	local ip="$1" port="$2" g cc country city lat lon isp org asn
	is_ipv4 "$ip" || return 1
	[ -s "$DATA/stay" ] && [ -s "$RUN/hold.ports" ] || return 0
	nft get element inet matchwatch okay "{ $ip }" >/dev/null 2>&1 && return 0
	nft get element inet matchwatch blocked "{ $ip }" >/dev/null 2>&1 && return 0
	is_allowed "$ip" && return 0
	in_away "$ip" && return 0
	g="$(geo_lookup "$ip")"
	IFS="$TAB" read -r cc country city lat lon isp org asn <<EOF
$g
EOF
	# anything that cannot be placed, and anything that is not a game server, goes through
	if [ -n "$cc" ] && [ -n "$lat" ] && [ -n "$lon" ] && [ "$(label_kind "$port" "$isp $org $asn")" = game ] \
		&& ! grep -q "\"ip\":\"${ip%.*}\\." "$RUN/www/status.json" 2>/dev/null && outside_stay "$lat" "$lon" "$cc"; then
		tried_note "$ip" "${port:-0}" "$cc" "$city" "$org" "$asn" "$lat" "$lon"
		MW_QUIET=1 cmd_block "${ip%.*}.0/24" 0 stay
		logger -t matchwatch "strict: held a new server in ${city:+$city, }$cc and turned it away before it could connect" 2>/dev/null
	else
		nft add element inet matchwatch okay "{ $ip }" 2>/dev/null
	fi
	return 0
}
cmd_hold() { # on <game> | off <game> | (nothing = list)
	local name="$2" row
	mkdir -p "$DATA"; touch "$DATA/hold"
	case "$1" in
		""|list) hold_list | awk -F'\t' '{ printf "  %-28s %s\n", $1, ($2 == 1 ? "STRICT" : ($3 == 1 ? "-" : "cannot be strict: most of its ports are also used by voice chat")) }'; return 0 ;;
		on|off) ;;
		*) die "usage: matchwatch strict [on|off <game name>]" ;;
	esac
	[ -n "$name" ] || die "usage: matchwatch strict $1 <game name, as shown by 'matchwatch strict'>"
	row="$(hold_list | awk -F'\t' -v n="$name" 'tolower($1) == tolower(n) { print; exit }')"
	[ -n "$row" ] || die "no game called '$name'. Name it first, under Tools, Games."
	name="$(echo "$row" | cut -f1)"
	if [ "$1" = off ]; then
		grep -vxF "$name" "$DATA/hold" > "$DATA/hold.tmp"; mv -f "$DATA/hold.tmp" "$DATA/hold"
		hold_apply; export_json
		echo "$name is no longer strict. New servers are looked up as they connect, as before."
		return 0
	fi
	[ "$(echo "$row" | cut -f3)" = 1 ] || die "most of the ports $name uses are also used by voice chat, so it cannot be strict: the start of a call would be held too."
	is_ipv4 "$DEVICE_IP" || die "choose your gaming device first, in Settings. Strict only ever holds that one device."
	grep -qxF "$name" "$DATA/hold" || echo "$name" >> "$DATA/hold"
	hold_apply; export_json
	if [ -s "$DATA/stay" ]; then echo "$name is now strict: every new server on its ports ($(echo "$row" | cut -f4)) is held for a moment until MatchWatch has placed it. Servers outside your places never get a packet through."
	else echo "$name will be strict when you stay on places. You are not staying anywhere at the moment, so nothing is held."; fi
}

cmd_fav() { # add <ip> | remove <ip> | (nothing = list)
	local ip="$2"
	mkdir -p "$DATA"; touch "$DATA/favourites"
	case "$1" in
		""|list) if [ -s "$DATA/favourites" ]; then cat "$DATA/favourites"; else echo "No favourites yet. Add one with: matchwatch fav add <server-ip>"; fi; return 0 ;;
		add|remove) ;;
		*) die "usage: matchwatch fav [add|remove <server-ip>]" ;;
	esac
	is_ipv4 "$ip" || die "that is not a server address"
	is_private "$ip" && die "that is not a game server"
	awk -v ip="$ip" '$1 != ip' "$DATA/favourites" > "$DATA/favourites.tmp"; mv -f "$DATA/favourites.tmp" "$DATA/favourites"
	if [ "$1" = add ]; then
		[ "$(cnt "$DATA/favourites")" -lt 200 ] || die "that is the most favourites MatchWatch keeps (200). Remove one first."
		echo "$ip" >> "$DATA/favourites"
		echo "Added $ip to your favourites."
	else
		echo "Removed $ip from your favourites."
	fi
	export_json
}

# ---- remove things from the history: one match, every match on one server, or a whole datacentre.
# Whatever was built from them goes too: ratings, the datacentre and region figures, the hour chart.
# A favourite cannot be removed this way, so one cannot be lost by a slip: take its star off first.
cmd_forget() { # match <start time> | server <ip> | dc <number>
	local kind="$1" arg="$2" pfx="" name="" ip n id
	mkdir -p "$DATA"; touch "$DATA/sessions.tsv" "$DATA/favourites" "$DATA/blocklist"
	case "$kind" in
		match) case "$arg" in ""|*[!0-9]*) die "usage: matchwatch forget match <start time from the history>" ;; esac ;;
		server) is_ipv4 "$arg" || die "usage: matchwatch forget server <server-ip>"
			is_fav "$arg" && die "$arg is one of your favourites, so it is kept. Take its star off first if you want it gone." ;;
		dc) case "$arg" in ""|*[!0-9]*) die "usage: matchwatch forget dc <number from 'matchwatch datacentres'>" ;; esac
			pfx="$(awk -v MODE=dc_prefixes -v ARG="$arg" -v BLOCK="$DATA/blocklist" -f "$LIB/report.awk" "$DATA/sessions.tsv")"
			[ -n "$pfx" ] || die "no datacentre number $arg"
			name="$(echo "$pfx" | head -n 1)"; pfx="$(echo "$pfx" | tail -n +2 | tr '\n' ' ')"
			for ip in $(cut -f1 "$DATA/favourites"); do
				case " $pfx " in *" ${ip%.*}.0/24 "*) die "$ip in that datacentre is one of your favourites, so the datacentre is kept. Take its star off first, or remove the other servers one by one." ;; esac
			done ;;
		*) die "usage: matchwatch forget match <start time> | server <ip> | dc <number>" ;;
	esac
	awk -F'\t' -v K="$kind" -v A="$arg" -v P=" $pfx " -v KEEP="$DATA/sessions.tsv.tmp" -v GONE="$RUN/forget.$$" '
		BEGIN { printf "" > KEEP; printf "" > GONE }
		{
			split($5, o, "."); hit = (K == "match") ? ($1 == A) : (K == "server") ? ($5 == A) : (index(P, " " o[1] "." o[2] "." o[3] ".0/24 ") > 0)
			if (hit) print $1 > GONE; else print > KEEP
		}' "$DATA/sessions.tsv"
	n="$(cnt "$RUN/forget.$$")"
	if [ "$n" -lt 1 ]; then rm -f "$DATA/sessions.tsv.tmp" "$RUN/forget.$$"; die "there was nothing to remove"; fi
	while read -r id; do rm -f "$DATA/matches/$id.json"; done < "$RUN/forget.$$"
	rm -f "$RUN/forget.$$"
	mv -f "$DATA/sessions.tsv.tmp" "$DATA/sessions.tsv"
	export_json
	# the running engine still remembers the old ratings. Start it afresh, unless that would cut a match short
	if [ -z "$CONF" ] && [ -x /etc/init.d/matchwatch ] && grep -q '"sessions":\[\]' "$RUN/www/status.json" 2>/dev/null; then ( sleep 1; /etc/init.d/matchwatch restart ) >/dev/null 2>&1 & fi
	case "$kind" in
		match) echo "Removed that match." ;;
		server) echo "Removed $arg and its $n match(es) from MatchWatch." ;;
		dc) echo "Removed $name and its $n match(es) from MatchWatch." ;;
	esac
}

# ---- tools for the dashboard's Tools page
cmd_testalert() { # send one alert to the phone, to prove the address works
	[ -n "$NTFY_URL" ] || die "no phone alerts address is set. Add one under Settings, Alerts, and save."
	fetch "$NTFY_URL" "MatchWatch test alert. Phone alerts are working." >/dev/null || die "the alert could not be sent. Check the address, and that the router can reach the internet."
	echo "Sent. It should reach your phone within a few seconds."
}
cmd_log() { logread -e matchwatch 2>/dev/null | tail -n 25 | cut -c1-220; }
cmd_clear_history() { # forget every recorded match. Blocks, the stay pool and settings are kept
	local f n
	mkdir -p "$DATA"; touch "$DATA/sessions.tsv"
	n="$(wc -l < "$DATA/sessions.tsv")"
	: > "$DATA/sessions.tsv"
	for f in "$DATA"/matches/*.json; do [ -f "$f" ] && rm -f "$f"; done
	rm -f "$DATA/last.txt" "$RUN/last.txt"
	[ -d "$RUN/www" ] && export_json
	# the running engine still remembers the old ratings, so start it afresh
	[ -z "$CONF" ] && [ -x /etc/init.d/matchwatch ] && ( sleep 1; /etc/init.d/matchwatch restart ) >/dev/null 2>&1 &
	echo "Cleared $n match(es), and the server ratings built from them. Blocks, the places you stay on and your settings are kept."
}
# Two tools take longer than a web request should wait. They start in the background, print a job
# number straight away, and write their result to a file the dashboard reads once it is done.
cmd_trace() { # server-ip : trace the route to a server now
	local ip="$1" id f="$RUN/www/trace.json"
	is_ipv4 "$ip" || die "choose a server first"
	is_private "$ip" && die "that is not a game server"
	have traceroute || die "traceroute is not installed on this router"
	id="$(date +%s)$$"
	mkdir -p "$RUN/www"
	printf '{"id":"%s","state":"running"}\n' "$id" > "$f"
	( traceroute -n -w 1 -q 1 -m 20 "$ip" 2>/dev/null | awk -v id="$id" -v ip="$ip" -v now="$(date +%s)" '
		BEGIN { printf "{\"id\":\"%s\",\"state\":\"done\",\"ts\":%d,\"ip\":\"%s\",\"hops\":[", id, now, ip }
		$1 ~ /^[0-9]+$/ { gsub(/["\\]/, " "); gsub(/[ \t]+/, " "); sub(/^ /, ""); printf "%s\"%s\"", (n++ ? "," : ""), $0 }
		END { print "]}" }' > "$f.tmp" && mv -f "$f.tmp" "$f" ) >/dev/null 2>&1 &
	echo "$id"
}
cmd_linetest() { # twenty seconds of pings with no game needed: is the line itself steady?
	local id f="$RUN/www/linetest.json" busy="$RUN/linetest.busy"
	mkdir -p "$RUN/www"
	[ -f "$busy" ] && [ $(( $(date +%s) - $(cat "$busy") )) -lt 60 ] && die "a line test is already running"
	id="$(date +%s)$$"
	date +%s > "$busy"
	printf '{"id":"%s","state":"running"}\n' "$id" > "$f"
	( linetest_run "$id" > "$f.tmp" 2>/dev/null && mv -f "$f.tmp" "$f"; rm -f "$busy" ) >/dev/null 2>&1 &
	echo "$id"
}
linetest_run() { # job-id -> the result as JSON
	local d="$RUN/linetest.$$" near t list
	mkdir -p "$d"
	# the first hop inside the ISP: the nearest thing that is not this house
	near="$(traceroute -n -w 1 -q 1 -m 8 1.1.1.1 2>/dev/null | awk '$2 ~ /^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$/ { split($2, a, "."); if (!(a[1] == 10 || (a[1] == 172 && a[2] >= 16 && a[2] <= 31) || (a[1] == 192 && a[2] == 168))) { print $2; exit } }')"
	case "$near" in 1.1.1.1|9.9.9.9) near="" ;; esac
	list="${near:+$near }1.1.1.1 9.9.9.9"
	for t in $list; do
		ping -c 20 -W 1 "$t" 2>/dev/null | sed -n 's/.*time=\([0-9.]*\).*/\1/p' > "$d/$t" &
	done
	wait
	awk -v D="$d" -v T="$list" -v NEAR="$near" -v ID="$1" -v NOW="$(date +%s)" -v SENT=20 '
	BEGIN {
		nt = split(T, t, " ")
		printf "{\"id\":\"%s\",\"state\":\"done\",\"ts\":%d,\"rows\":[", ID, NOW
		for (k = 1; k <= nt; k++) {
			n = 0; f = D "/" t[k]
			while ((getline v < f) > 0) a[++n] = v + 0
			close(f)
			jit = 0
			for (i = 2; i <= n; i++) { x = a[i] - a[i - 1]; jit += (x < 0 ? -x : x) }
			if (n > 1) jit /= (n - 1)
			for (i = 2; i <= n; i++) { v = a[i]; for (j = i - 1; j >= 1 && a[j] > v; j--) a[j + 1] = a[j]; a[j + 1] = v }
			med = n ? a[int((n + 1) / 2)] : 0
			q = int(n * 0.95 + 0.5); if (q < 1) q = 1
			p95 = n ? a[q] : 0
			loss = 100 * (SENT - n) / SENT
			printf "%s{\"name\":\"%s\",\"ip\":\"%s\",\"answered\":%s,\"loss\":%.0f,\"med\":%.1f,\"p95\":%.1f,\"jit\":%.2f}", (k > 1 ? "," : ""), (t[k] == NEAR ? "Your provider, first hop" : "Public server"), t[k], (n ? "true" : "false"), loss, med, p95, jit
			if (n) {
				ans++
				# trouble shared by every target is the line; trouble with one target is that target
				if (ans == 1 || loss < bl) bl = loss
				if (ans == 1 || jit < bj) bj = jit
				if (ans == 1 || p95 - med < bs) bs = p95 - med
				if (ans == 1 || med < bm) bm = med
			}
		}
		if (!ans) { vd = "unknown"; msg = "Nothing answered. The router may be offline, or pings are blocked." }
		else if (bl >= 2) { vd = "poor"; msg = sprintf("Your line is losing packets: at least %d%% went missing to every target. Expect rubber-banding until that clears.", bl) }
		else if (bl > 0 || bj > 3 || bs > 10) { vd = "fair"; msg = sprintf("Your line is a little unsteady right now: jitter %.1f ms, slowest replies %.0f ms above normal%s.", bj, bs, (bl > 0 ? ", some loss" : "")) }
		else { vd = "good"; msg = sprintf("Your line is steady: about %.0f ms to the nearest target, no loss, jitter %.1f ms.", bm, bj) }
		# a score for the dashboard to grade A+ to F: shared loss costs most, then jitter, then slow replies
		sc = -1
		if (ans) {
			x = bl * 10; if (x > 60) x = 60; sc = 100 - x
			x = (bj - 0.5) * 6; if (x < 0) x = 0; if (x > 25) x = 25; sc -= x
			x = (bs - 3) * 1.5; if (x < 0) x = 0; if (x > 20) x = 20; sc -= x
			if (sc < 0) sc = 0
		}
		printf "],\"verdict\":\"%s\",\"score\":%s,\"msg\":\"%s\"}\n", vd, (sc < 0 ? "null" : int(sc + 0.5)), msg
	}'
	rm -f "$d"/*; rmdir "$d" 2>/dev/null
}

# ---- what the dashboard's buttons run (through LuCI's rpcd backend, /usr/libexec/rpcd/luci.matchwatch)
# ---- updating from the project's page on GitHub. Nothing is contacted until the owner asks.
# dist/version there holds one line: the version, then the SHA-256 of the installer beside it.
UPDATE_URL="${MW_UPDATE_URL:-https://raw.githubusercontent.com/ItsGix/matchwatch/main/dist}"
ver_newer() { # a b : true when a is a later version than b
	echo "$1 $2" | awk '{ split($1, a, "."); split($2, b, "."); for (i = 1; i <= 3; i++) { if (a[i] + 0 > b[i] + 0) exit 0; if (a[i] + 0 < b[i] + 0) exit 1 } exit 1 }'
}
update_latest() { # prints "version sha256" as published, or fails
	fetch "$UPDATE_URL/version" | tr -d '\r' | awk 'NR == 1 && $1 ~ /^[0-9]+\.[0-9]+\.[0-9]+$/ && $2 ~ /^[0-9a-f]+$/ && length($2) == 64 && NF == 2 { print $1, $2; ok = 1 } END { exit !ok }'
}
fetch_file() { # url file : a download that may take a while
	if have uclient-fetch; then uclient-fetch -q -T 30 -O "$2" "$1" 2>/dev/null
	elif have curl; then curl -fsS -m 60 -o "$2" "$1" 2>/dev/null
	elif have wget; then wget -q -T 30 -O "$2" "$1" 2>/dev/null
	else return 1; fi
}
update_done() { # job-id true|false text
	printf '{"id":"%s","state":"done","ok":%s,"out":"%s"}\n' "$1" "$2" "$3" > "$RUN/www/update.json.tmp" && mv -f "$RUN/www/update.json.tmp" "$RUN/www/update.json"
	logger -t matchwatch "update: $3" 2>/dev/null
}
update_run() { # job-id version sha256 : download the installer, check it is whole, run it
	local id="$1" want="$2" sum="$3" d="$RUN/update.$$" f got new
	mkdir -p "$d"; f="$d/matchwatch-install.sh"
	if ! fetch_file "$UPDATE_URL/matchwatch-install.sh" "$f"; then
		update_done "$id" false "The download failed. Nothing was changed."
	else
		got="$(sha256sum "$f" 2>/dev/null | cut -d' ' -f1)"
		if [ "$got" != "$sum" ] || [ "$(head -n 1 "$f")" != '#!/bin/sh' ] || ! grep -q "^VERSION=\"$want\"\$" "$f" || ! sh -n "$f" 2>/dev/null; then
			update_done "$id" false "The download did not match what was published, so nothing was changed. If a new version came out in the last few minutes, try again shortly."
		else
			sh "$f" > "$RUN/update.log" 2>&1
			new="$("${MW_ROOT:-}/usr/bin/matchwatch" version 2>/dev/null)"
			if [ "$new" = "$want" ]; then update_done "$id" true "Updated from $VERSION to $want. Your history and settings are kept."
			else update_done "$id" false "The installer ran but this router still has ${new:-no version}. The installer's output is in $RUN/update.log."; fi
		fi
	fi
	rm -rf "$d" "$RUN/update.busy"
}
cmd_update() { # [check|now]
	local l latest sum id busy="$RUN/update.busy"
	case "${1:-check}" in check|now) ;; *) die "use: matchwatch update [check|now]" ;; esac
	l="$(update_latest)" || die "could not get the latest version number from GitHub. Check the router is online and try again in a minute."
	latest="${l% *}"; sum="${l#* }"
	if [ "${1:-check}" = check ]; then
		if ver_newer "$latest" "$VERSION"; then echo "Version $latest is available. You have $VERSION."
		else echo "You have the latest version, $VERSION."; fi
		return 0
	fi
	ver_newer "$latest" "$VERSION" || die "you already have the latest version, $VERSION"
	have sha256sum || die "this router has no sha256sum, so the download could not be checked. Update with the installer instead."
	grep -q '"sessions":\[{' "$RUN/www/status.json" 2>/dev/null && die "a match is in progress. Updating restarts MatchWatch, so do it between matches."
	[ -f "$busy" ] && [ $(( $(date +%s) - $(cat "$busy") )) -lt 300 ] && die "an update is already running"
	mkdir -p "$RUN/www"
	id="$(date +%s)$$"
	date +%s > "$busy"
	printf '{"id":"%s","state":"running"}\n' "$id" > "$RUN/www/update.json"
	( update_run "$id" "$latest" "$sum" ) >/dev/null 2>&1 &
	echo "$id"
}

cmd_action() { # action [arg] [days] [place] [name] : prints the result; a non-zero exit means it did not work
	local action="$1" arg="$2" days="$3" region="$4" name="$5" f rc
	case "$name" in *[!A-Za-z0-9\ .:-]*) die "names may only use letters, numbers, spaces, dots, colons and hyphens" ;; esac
	[ "${#name}" -le 40 ] || die "that name is too long"
	case "$arg" in *[!0-9./-]*) die "that is not an address or a number" ;; esac
	case "$days" in *[!0-9]*) die "days must be a number" ;; esac
	case "$region" in *[!a-z0-9\ ,-]*) die "place names may only use letters, numbers, spaces, commas and hyphens" ;; esac
	case "$action" in
		hello) echo "ok" ;;
		mark) cmd_mark || die "could not record that" ;;
		block) cmd_block "$arg" ${days:+"$days"} ;;
		unblock) cmd_unblock "$arg" ;;
		blockdc) cmd_block_dc "$arg" ${days:+"$days"} ;;
		unblockdc) cmd_unblock_dc "$arg" ;;
		stay) cmd_stay "${region:-$arg}" ;;
		stayoff) cmd_stay off ;;
		stayadd) cmd_stay add "$region" ;;
		stayrm) cmd_stay remove "$arg" ;;
		# from the map: the numbers arrive as lat/lon/km, or n/lat/lon/km to move a circle
		staycircle) set -- $(echo "$arg" | tr '/' ' '); [ $# = 3 ] || die "that is not a circle"; cmd_stay circle "$1" "$2" "$3" ;;
		stayset) set -- $(echo "$arg" | tr '/' ' '); [ $# = 4 ] || die "that is not a circle"; cmd_stay set "$1" "$2" "$3" "$4" ;;
		staysuggest) cmd_stay_suggest "$arg" ;;
		qos) cmd_qos ;;
		qosfix) cmd_qos_fix ;;
		qosunfix) cmd_qos_unfix ;;
		devices) device_list ;;
		setdevice) [ -n "$arg" ] || die "no device given"; cmd_device "$arg" ;;
		setdeviceall) cmd_device all ;;
		doctor) cmd_doctor ;;
		regions) cmd_regions measure | head -n 6 ;;
		testalert) cmd_testalert ;;
		log) cmd_log ;;
		linetest) cmd_linetest ;;
		updatecheck) cmd_update check ;;
		update) cmd_update now ;;
		trace) cmd_trace "$arg" ;;
		gamename) [ -n "$arg" ] && [ -n "$name" ] || die "choose a game and type a name for it"; cmd_game name "$arg" "$name" "$region" "$( [ "$days" = 1 ] && echo voice )" ;;   # region carries the host words; days = 1 marks it as not a game
		gamedel) [ -n "$arg" ] || die "choose a name to remove"; cmd_game remove "$arg" ;;
		clearhistory) cmd_clear_history ;;
		shareexport) cmd_share_export $arg ;;
		# the share file itself arrives on standard input
		sharecheck|shareimport) f="$RUN/share.in.$$"; mkdir -p "$RUN"; head -c 70000 > "$f"
			if [ "$action" = sharecheck ]; then ( cmd_share_check "$f" ); else ( cmd_share_import "$f" $arg ); fi; rc=$?
			rm -f "$f"; return $rc ;;
		fav) cmd_fav add "$arg" ;;
		allow) cmd_allow add "$arg" ;;
		holdon) [ -n "$name" ] || die "choose a game"; cmd_hold on "$name" ;;
		holdoff) [ -n "$name" ] || die "choose a game"; cmd_hold off "$name" ;;
		unallow) cmd_allow remove "$arg" ;;
		unfav) cmd_fav remove "$arg" ;;
		shareundo) cmd_share_undo ;;
		shareforget) cmd_share_forget "$arg" ;;
		shareforgetgs) rm -f "$DATA/gameplaces.shared"; export_json; echo "Removed the game servers other people shared with you. What your own router has learned is kept." ;;
		forgetmatch) cmd_forget match "$arg" ;;
		forgetserver) cmd_forget server "$arg" ;;
		forgetdc) cmd_forget dc "$arg" ;;
		*) die "unknown action" ;;
	esac
}

# ---- one-time: carry settings from the shell file older versions used into /etc/config/matchwatch
cmd_migrate() {
	local old=/etc/matchwatch/config
	[ -z "$CONF" ] && [ -f "$old" ] && have uci || return 0
	[ -f /etc/config/matchwatch ] || : > /etc/config/matchwatch
	uci -q get matchwatch.main >/dev/null || uci set matchwatch.main=matchwatch
	(
		# what that file's own defaults were, for anything it does not mention
		DEVICE_IP=""; LAN_IF=""; WAN_IF=""; ONLY_FILTER=""; NTFY_URL=""; WEB=1; DATA_DIR="/etc/matchwatch"
		. "$old"
		put() { if [ -n "$2" ]; then uci set "matchwatch.main.$1=$2"; else uci -q delete "matchwatch.main.$1"; fi; }
		put device_ip "$DEVICE_IP"; put lan_if "$LAN_IF"; put wan_if "$WAN_IF"
		put ignore_ports "$IGNORE_PORTS"; put only_filter "$ONLY_FILTER"
		put min_down_pps "$MIN_DOWN_PPS"; put min_up_pps "$MIN_UP_PPS"
		put geo "$GEO"; put ntfy_url "$NTFY_URL"; put notify_every_match "$NOTIFY_EVERY_MATCH"
		put warn_score "$WARN_SCORE"; put pc_score "$PC_SCORE"
		put autoblock "$AUTOBLOCK"; put autoblock_score "$AUTOBLOCK_SCORE"; put autoblock_matches "$AUTOBLOCK_MATCHES"
		put block_days "$BLOCK_DAYS"; put lobby_alert "$LOBBY_ALERT"; put lobby_margin_ms "$LOBBY_MARGIN_MS"
		put stay_strict "$STAY_STRICT"; put stay_km "$STAY_KM"; put stay_ranges "$STAY_RANGES"; put data_dir "$DATA_DIR"; put web "$WEB"
		uci commit matchwatch
	) || return 1
	mv -f "$old" "$old.imported"
	rm -f /etc/matchwatch/token
	echo "Settings carried over from $old (kept as $old.imported). They are now in LuCI: Services, MatchWatch, Settings."
}

cmd_mark() { # record "I felt that" at this moment
	local now last
	mkdir -p "$RUN"
	now="$(date +%s)"
	last="$(tail -n 1 "$RUN/marks" 2>/dev/null)"
	[ -n "$last" ] && [ $((now - last)) -lt 2 ] && return 0
	[ -f "$RUN/marks" ] && [ "$(wc -l < "$RUN/marks")" -gt 2000 ] && return 1
	echo "$now" >> "$RUN/marks"
}

# ---- is the game's traffic in QoSmate's top class?
dscp_name() {
	case "$1" in
		0) echo CS0 ;; 8) echo CS1 ;; 16) echo CS2 ;; 24) echo CS3 ;; 32) echo CS4 ;; 40) echo CS5 ;; 48) echo CS6 ;; 56) echo CS7 ;;
		46) echo EF ;; 44) echo VA ;; 34) echo AF41 ;; 36) echo AF42 ;; 38) echo AF43 ;; 26) echo AF31 ;; 18) echo AF21 ;; 10) echo AF11 ;;
		*) echo "DSCP-$1" ;;
	esac
}
qos_scheme() { # which priority scheme is live on the WAN port: hfsc | diffserv3 | diffserv4 | diffserv8 | besteffort | unknown
	local q
	q="$(tc qdisc show dev "$WAN_IF" 2>/dev/null)"
	case "$q" in
		*"qdisc hfsc"*) echo hfsc ;;
		*diffserv3*) echo diffserv3 ;;
		*diffserv4*) echo diffserv4 ;;
		*diffserv8*) echo diffserv8 ;;
		*besteffort*) echo besteffort ;;
		*) echo unknown ;;
	esac
}
is_top() { # dscp scheme : does this mark land in the top queue under this scheme?
	case "$2" in
		diffserv3) case "$1" in 4|44|46|48|56) return 0 ;; esac ;;
		diffserv4) case "$1" in 32|40|44|46|48|56) return 0 ;; esac ;;
		*) case "$1" in 40|46|48|56) return 0 ;; esac ;;
	esac
	return 1
}
qos_probe() { # server-ip server-port -> prints: state class source   (state: top|low|unknown|absent)
	local ip="$1" port="$2" d="" tf="$RUN/qos.$$" cf="$RUN/qosc.$$" p p2 mark sch pk1 pk2 want got washed=0
	[ -x /etc/init.d/qosmate ] && [ "$(uci -q get qosmate.global.enabled)" = 1 ] || { echo "absent - -"; return 0; }
	find_ifaces
	[ -n "$WAN_IF" ] && have tcpdump || { echo "unknown - -"; return 0; }
	sch="$(qos_scheme)"
	[ "$sch" = besteffort ] && { echo "low none cake is in besteffort mode, which has no priority queue"; return 0; }
	# watch the game's outgoing packets for a few seconds: their mark, and how many there are
	tcpdump -i "$WAN_IF" -l -v -n -c 12 "udp and dst host $ip and dst port $port" > "$tf" 2>/dev/null &
	p=$!
	tcpdump -i "$WAN_IF" -l -n -q "udp and dst host $ip and dst port $port" > "$cf" 2>/dev/null &
	p2=$!
	pk1="$(rt_packets "$sch")"; sleep 2; pk2="$(rt_packets "$sch")"
	sleep 1; kill "$p" "$p2" 2>/dev/null
	d="$(tos_dscp "$tf")"; want=$(( $(wc -l < "$cf") / 3 ))
	rm -f "$tf" "$cf"
	# 1. is the top queue carrying about as many packets as the game sends? This is the direct test.
	if [ -n "$pk1" ] && [ -n "$pk2" ] && [ "$want" -ge 5 ]; then
		got=$(( (pk2 - pk1) / 2 ))
		if [ $((got * 10)) -ge $((want * 6)) ]; then echo "top top-queue the top queue's own counters ($got packets a second in it, the game sends $want)"; return 0; fi
		if [ $((got * 10)) -le $((want * 2)) ]; then echo "low not-in-top-queue the top queue's own counters ($got packets a second in it, the game sends $want; scheme $sch)"; return 0; fi
	fi
	# 2. the mark on the packets as they reach the queue. In HFSC modes QoSmate may wipe it first.
	# Packets are captured after the queue has handled them, so a queue that washes marks shows CS0 here.
	[ "$sch" = hfsc ] && [ "$(uci -q get qosmate.advanced.WASHDSCPUP)" != 0 ] && washed=1
	case "$(tc qdisc show dev "$WAN_IF" 2>/dev/null)" in *" wash"*) washed=1 ;; esac
	if [ -n "$d" ] && { [ "$d" != 0 ] || [ "$washed" = 0 ]; }; then
		if is_top "$d" "$sch"; then echo "top $(dscp_name "$d") packets leaving $WAN_IF (scheme $sch)"
		else echo "low $(dscp_name "$d") packets leaving $WAN_IF (scheme $sch)"; fi
		return 0
	fi
	# 3. the class QoSmate stored for the connection (a best guess at its bookkeeping, so reported as such)
	if [ -r /proc/net/nf_conntrack ]; then
		mark="$(grep "dst=$ip " /proc/net/nf_conntrack 2>/dev/null | grep "dport=$port " | sed -n 's/.* mark=\([0-9]*\).*/\1/p' | head -n 1)"
		if [ -n "$mark" ] && [ "$mark" -ge 128 ] 2>/dev/null; then
			d=$((mark & 63))
			if is_top "$d" "$sch"; then echo "top $(dscp_name "$d") connection table, less certain (raw mark $mark, scheme $sch)"
			else echo "low $(dscp_name "$d") connection table, less certain (raw mark $mark, scheme $sch)"; fi
			return 0
		fi
	fi
	if [ "$d" = 0 ]; then echo "unknown CS0 washed"; else echo "unknown - -"; fi
}
rt_packets() { # scheme -> packets sent so far through the top queue on the WAN port
	have tc || return 0
	case "$1" in
		hfsc) tc -s class show dev "$WAN_IF" 2>/dev/null | awk '/^class hfsc 1:11 / { f = 1; next } /^class / { f = 0 } f && $1 == "Sent" { print $4; exit }' ;;
		diffserv3|diffserv4) tc -s qdisc show dev "$WAN_IF" 2>/dev/null | awk '/^qdisc cake/ { c++ } c == 1 && $1 == "pkts" { print $NF; exit }' ;;
	esac
}
tos_dscp() { # file of "tcpdump -v" output -> most common DSCP value
	awk 'function hex(h,   i, c, v) { v = 0; h = tolower(h); for (i = 1; i <= length(h); i++) { c = index("0123456789abcdef", substr(h, i, 1)) - 1; if (c < 0) break; v = v * 16 + c } return v }
		match($0, /tos 0x[0-9a-fA-F]+/) { t = hex(substr($0, RSTART + 6, RLENGTH - 6)); n[int(t / 4)]++ }
		END { best = ""; for (k in n) if (best == "" || n[k] > n[best]) best = k; print best }' "$1"
}
# ---- which device to watch
device_list() { # prints: ip|name|mac|fixed(yes/no), one device per line, from the router's DHCP leases
	local lf="${MW_LEASES:-$(uci -q get dhcp.@dnsmasq[0].leasefile 2>/dev/null)}" fixed
	[ -n "$lf" ] || lf=/tmp/dhcp.leases
	fixed="$(uci -q show dhcp 2>/dev/null | sed -n "s/.*\.ip='\([0-9.]*\)'.*/\1/p" | tr '\n' ' ')"
	[ -r "$lf" ] || return 0
	awk -v fx=" $fixed" '$3 ~ /^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$/ { n = ($4 == "*" || $4 == "") ? "(no name)" : $4; gsub(/[|"\\]/, " ", n); print $3 "|" n "|" $2 "|" (index(fx, " " $3 " ") ? "yes" : "no") }' "$lf" | sort -t. -k1,1n -k2,2n -k3,3n -k4,4n
}
cmd_device() { # (nothing) = list | <ip> | all
	local want="$1"
	case "$want" in
		"") echo "Watching: ${DEVICE_IP:-every device on the LAN}"; echo
			device_list | awk -F'|' -v cur="$DEVICE_IP" 'BEGIN { printf "%-16s %-26s %-18s %s\n", "Address", "Name", "MAC", "" } { printf "%-16s %-26s %-18s %s%s\n", $1, substr($2, 1, 26), $3, ($4 == "yes" ? "fixed address" : "address may change"), ($1 == cur ? "  <- watching" : "") }'
			echo; echo "Choose one with: matchwatch device <address>     or watch everything: matchwatch device all"; return 0 ;;
		all) want="" ;;
		*) is_ipv4 "$want" || die "usage: matchwatch device [<address> | all]" ;;
	esac
	if [ -n "$CONF" ]; then
		touch "$CONF"
		if grep -q '^DEVICE_IP=' "$CONF"; then sed -i "s|^DEVICE_IP=.*|DEVICE_IP=\"$want\"|" "$CONF"; else echo "DEVICE_IP=\"$want\"" >> "$CONF"; fi
	else
		[ -f /etc/config/matchwatch ] || : > /etc/config/matchwatch
		uci -q get matchwatch.main >/dev/null || uci set matchwatch.main=matchwatch
		if [ -n "$want" ]; then uci set "matchwatch.main.device_ip=$want"; else uci -q delete matchwatch.main.device_ip; fi
		uci commit matchwatch || die "could not save the setting"
	fi
	DEVICE_IP="$want"
	[ -d "$RUN/www" ] && export_json
	[ -x /etc/init.d/matchwatch ] && ( sleep 1; /etc/init.d/matchwatch restart ) >/dev/null 2>&1 &
	echo "Now watching: ${want:-every device on the LAN}. The service is restarting."
	if [ -n "$want" ] && ! device_list | grep -q "^$want|.*|yes\$"; then echo "That device's address is handed out by the router and may change. Give it a fixed one in LuCI > Network > DHCP and DNS > Static Leases, or matchwatch will lose track of it."; fi
	if [ -n "$(qos_rule_section matchwatch_out 2>/dev/null)" ]; then echo "Your QoSmate rules still point at the previous device. Run 'matchwatch qos fix' (or the Tools page button) to move them."; fi
}

# ---- put the gaming device's UDP in QoSmate's top class (only ever run by hand)
qos_rule_section() { # rule name -> its uci section (qosmate.cfgXXXX), if it exists
	uci -q show qosmate 2>/dev/null | sed -n "s/^\(qosmate\.[^.]*\)\.name='$1'\$/\1/p" | head -n 1
}
qos_device() { # the device whose traffic should be prioritised: the configured one, else the one in a match right now
	local d="$DEVICE_IP"
	[ -n "$d" ] || d="$(sed -n 's/.*"sessions":\[{"ip":"[0-9.]*","port":[0-9]*,"device":"\([0-9.]*\)".*/\1/p' "$RUN/www/status.json" 2>/dev/null)"
	echo "$d"
}
qos_set_rule() { # name direction(src|dest) device
	local sec other
	[ "$2" = src ] && other=dest || other=src
	sec="$(qos_rule_section "$1")"
	if [ -z "$sec" ]; then
		sec="qosmate.$(uci add qosmate rule)" || return 1
		uci set "$sec.name=$1"
	fi
	uci set "$sec.proto=udp"
	uci -q delete "$sec.src_ip"; uci -q delete "$sec.dest_ip"; uci -q delete "$sec.src_port"; uci -q delete "$sec.dest_port"
	uci add_list "$sec.${2}_ip=$3"
	uci add_list "$sec.${other}_port=!=80"
	uci add_list "$sec.${other}_port=!=443"
	uci set "$sec.class=ef"
	uci set "$sec.counter=1"
	uci set "$sec.enabled=1"
}
cmd_qos_fix() {
	local dev old1 old2
	[ -x /etc/init.d/qosmate ] || die "QoSmate is not installed on this router."
	dev="$(qos_device)"
	is_ipv4 "$dev" || die "no gaming device known. Choose one in LuCI (Services, MatchWatch, Settings) or with 'matchwatch device <address>', or run this during a match."
	# rules made from the commands an older version printed are reused, not duplicated
	old1="$(qos_rule_section Game_Outbound)"; old2="$(qos_rule_section Game_Inbound)"
	[ -n "$old1" ] && uci set "$old1.name=matchwatch_out"
	[ -n "$old2" ] && uci set "$old2.name=matchwatch_in"
	qos_set_rule matchwatch_out src "$dev" && qos_set_rule matchwatch_in dest "$dev" || die "could not write the QoSmate rules"
	uci commit qosmate
	/etc/init.d/qosmate restart >/dev/null 2>&1
	echo "Done. All UDP to and from $dev, except web ports 80 and 443, is now marked EF: top priority in every QoSmate mode."
	echo "The rules are called matchwatch_out and matchwatch_in (LuCI > QoSmate > Rules). QoSmate was restarted."
	echo "Check it during a match with: matchwatch qos"
}
cmd_qos_unfix() {
	local s n=0
	[ -x /etc/init.d/qosmate ] || die "QoSmate is not installed on this router."
	for s in matchwatch_out matchwatch_in; do
		s="$(qos_rule_section "$s")"
		[ -n "$s" ] && uci delete "$s" && n=$((n + 1))
	done
	if [ "$n" -gt 0 ]; then uci commit qosmate; /etc/init.d/qosmate restart >/dev/null 2>&1; echo "Removed $n rule(s) and restarted QoSmate. Your own QoSmate rules were not touched."
	else echo "There were no matchwatch rules in QoSmate to remove."; fi
}
cmd_qos() {
	local st ip port dev state class src qd
	case "$1" in fix) cmd_qos_fix; return ;; unfix) cmd_qos_unfix; return ;; esac
	if [ ! -x /etc/init.d/qosmate ]; then echo "QoSmate is not installed on this router."; return 0; fi
	qd="$(uci -q get qosmate.settings.ROOT_QDISC)"
	find_ifaces
	echo "QoSmate: $( [ "$(uci -q get qosmate.global.enabled)" = 1 ] && echo enabled || echo DISABLED ), queue type ${qd:-unknown} ($(qos_scheme) live on $WAN_IF), $(uci -q get qosmate.settings.DOWNRATE) kbit down / $(uci -q get qosmate.settings.UPRATE) kbit up"
	st="$(cat "$RUN/www/status.json" 2>/dev/null)"
	ip="$(echo "$st" | sed -n 's/.*"sessions":\[{"ip":"\([0-9.]*\)".*/\1/p')"
	port="$(echo "$st" | sed -n 's/.*"sessions":\[{"ip":"[0-9.]*","port":\([0-9]*\).*/\1/p')"
	dev="$(echo "$st" | sed -n 's/.*"sessions":\[{"ip":"[0-9.]*","port":[0-9]*,"device":"\([0-9.]*\)".*/\1/p')"
	if [ -z "$ip" ]; then echo "No match in progress. Start a match, then run this again while you are in it."; return 0; fi
	echo "Checking game traffic to $ip:$port from ${dev:-your device} ..."
	set -- $(qos_probe "$ip" "$port"); state="$1"; class="$2"; shift 2; src="$*"
	case "$state" in
		top) if [ "$class" = top-queue ]; then echo "OK: game traffic is going through the top priority queue. Source: $src."
			else echo "OK: game traffic is in the top priority class ($class). Source: $src."; fi ;;
		low) echo "NOT prioritised: game traffic is not reaching the top queue. Source: $src."
			case "$src" in *diffserv3*) echo "Your cake queue runs in diffserv3 mode, where EF, VA, CS6 and CS7 reach the top (Voice) queue." ;; esac
			echo "To fix it, run: matchwatch qos fix   (or press Prioritise my game traffic on the dashboard's Tools page in LuCI)."
			echo "That adds two QoSmate rules marking all UDP to and from your gaming device, except web ports, as EF,"
			echo "which is top priority in every QoSmate mode, and restarts QoSmate. matchwatch qos unfix removes them."
			echo "Nothing has been changed yet." ;;
		unknown) if [ "$src" = washed ]; then echo "Can't tell: QoSmate clears marks on packets leaving the router (WASHDSCPUP), and neither its queue counters nor the connection table settled it."
			else echo "Can't tell: no mark could be read for this connection."; fi
			echo "Check LuCI > QoSmate > Connections for the row to $ip and see which class it shows." ;;
		*) echo "QoSmate is installed but disabled, so nothing is being prioritised." ;;
	esac
}

# ---- service
find_ifaces() {
	if [ -z "$LAN_IF" ] || [ -z "$WAN_IF" ]; then
		if [ -f /lib/functions/network.sh ]; then
			. /lib/functions/network.sh
			[ -z "$LAN_IF" ] && network_get_device LAN_IF lan
			if [ -z "$WAN_IF" ]; then local w; network_find_wan w && network_get_device WAN_IF "$w"; fi
		fi
	fi
	[ -n "$LAN_IF" ] || LAN_IF="br-lan"
}
build_filter() {
	local p
	FILTER="ip and udp and not ether multicast"
	[ -n "$DEVICE_IP" ] && FILTER="$FILTER and host $DEVICE_IP"
	for p in $IGNORE_PORTS; do FILTER="$FILTER and not port $p"; done
	[ -n "$ONLY_FILTER" ] && FILTER="$FILTER and ( $ONLY_FILTER )"
}
web_setup() { # the dashboard without login (WEB=1): view only, plus the "I felt that" button
	[ -d /www ] || return 0
	rm -f /www/cgi-bin/matchwatch-api
	if [ "$WEB" = 1 ] && [ -f "$LIB/public.html" ] && [ -f /www/luci-static/resources/matchwatch/dashboard.js ]; then
		mkdir -p /www/matchwatch
		# the two dashboard files are asked for by version, so a browser drops its old copies after an update
		sed -e "s|dashboard\.js\"|dashboard.js?v=$VERSION\"|" -e "s|dashboard\.css\"|dashboard.css?v=$VERSION\"|" "$LIB/public.html" > /www/matchwatch/index.html
		ln -sfn "$RUN/www" /www/matchwatch/data
		if [ -d /www/cgi-bin ]; then
			cat > /www/cgi-bin/matchwatch-mark <<'CGI'
#!/bin/sh
# matchwatch: records the moment the "I felt that" button was pressed. Nothing else.
echo "Content-Type: application/json"
echo "Cache-Control: no-store"
echo
if [ "$REQUEST_METHOD" = POST ] && /usr/bin/matchwatch mark; then echo '{"ok":true}'; else echo '{"ok":false}'; fi
CGI
			chmod 755 /www/cgi-bin/matchwatch-mark
		fi
	else
		rm -f /www/matchwatch/index.html /www/matchwatch/data /www/cgi-bin/matchwatch-mark
		rmdir /www/matchwatch 2>/dev/null
	fi
	return 0
}
stop_children() {
	local d f
	kill $TPID $HPID $APID 2>/dev/null
	for d in "$RUN"/probe.*; do
		[ -d "$d" ] || continue
		touch "$d/stop"
		for f in "$d"/*.pid; do [ -f "$f" ] && kill "$(cat "$f")" 2>/dev/null; done
		rm -rf "$d"
	done
	rm -f "$RUN/pipe" "$RUN/pid"
}
cmd_run() {
	local imm=""
	have tcpdump || die "tcpdump is not installed (opkg install tcpdump, or apk add tcpdump)"
	[ -f "$LIB/analyze.awk" ] || die "missing $LIB/analyze.awk"
	[ -n "$DEVICE_IP" ] && { is_ipv4 "$DEVICE_IP" || die "the device to watch ($DEVICE_IP) is not a valid IPv4 address"; }
	mkdir -p "$RUN/www" "$DATA/matches"
	ln -sfn "$DATA/matches" "$RUN/www/matches"
	[ -s "$DATA/stay" ] && [ -z "$(cut -f3 "$DATA/stay")" ] && stay_off
	rm -f "$RUN/www/lobby.json"
	rm -rf "$RUN"/probe.* "$RUN/pipe"
	: > "$RUN/marks"
	touch "$DATA/sessions.tsv" "$DATA/blocklist"
	find_ifaces; build_filter
	apply_blocklist
	# strict games are switched on a few seconds after the engine is listening, never before
	rm -f "$RUN/hold.ports"; nft flush set inet matchwatch hold_ports 2>/dev/null
	[ -s "$DATA/hold" ] && [ -s "$DATA/stay" ] && ( sleep 6; pgrep -f analyze.awk >/dev/null 2>&1 && hold_apply >/dev/null 2>&1 ) &
	[ -s "$DATA/stay" ] && ( sleep 3; stay_ranges >/dev/null 2>&1 ) &
	web_setup; export_json
	echo '{"ts":0,"sessions":[],"candidates":0,"flows":0}' > "$RUN/www/status.json"
	echo "Starting up..." > "$RUN/status.txt"
	mkfifo "$RUN/pipe" || die "cannot create $RUN/pipe"
	tcpdump --help 2>&1 | grep -q immediate-mode && imm="--immediate-mode"
	awk -v SELF="$SELF" -v RUN="$RUN" -v DATA="$DATA" -v WANDEV="$WAN_IF" -v GAMES="$LIB/games.list" -v GAMESL="$DATA/games.local" -v HOLDF="$RUN/hold.ports" \
		-v MINDN="$MIN_DOWN_PPS" -v MINUP="$MIN_UP_PPS" -v WARNSCORE="$WARN_SCORE" \
		-v PCSCORE="$PC_SCORE" -v AUTOBLOCK="$AUTOBLOCK" -v ABSCORE="$AUTOBLOCK_SCORE" -v ABMATCHES="$AUTOBLOCK_MATCHES" \
		-f "$LIB/analyze.awk" < "$RUN/pipe" >> "$RUN/engine.log" 2>&1 &
	APID=$!
	# shellcheck disable=SC2086
	tcpdump -i "$LAN_IF" -tt -n -q -l -s 96 $imm $FILTER > "$RUN/pipe" 2> "$RUN/tcpdump.err" &
	TPID=$!
	( while :; do echo TICK; sleep 1; done ) > "$RUN/pipe" 2>/dev/null &
	HPID=$!
	echo $$ > "$RUN/pid"
	trap 'stop_children; exit 0' INT TERM
	( sleep 20; regions_stale && cmd_regions measure >/dev/null 2>&1 ) &
	logger -t matchwatch "watching $LAN_IF${DEVICE_IP:+ (device $DEVICE_IP)}" 2>/dev/null
	wait $TPID
	logger -t matchwatch "capture stopped: $(tail -n 1 "$RUN/tcpdump.err" 2>/dev/null)" 2>/dev/null
	stop_children
	exit 1
}

cmd_live() {
	[ -f "$RUN/status.txt" ] || die "not running. Start it with: /etc/init.d/matchwatch start"
	while :; do
		clear 2>/dev/null
		echo "matchwatch $VERSION - live (Ctrl+C to leave)"; echo
		cat "$RUN/status.txt" 2>/dev/null
		sleep 1
	done
}
cmd_last() {
	if [ -f "$RUN/last.txt" ]; then cat "$RUN/last.txt"
	elif [ -f "$DATA/last.txt" ]; then cat "$DATA/last.txt"
	else echo "No match recorded yet."; fi
}
cmd_doctor() {
	local ok=1 c n
	echo "matchwatch $VERSION"
	for c in tcpdump awk ping mkfifo; do
		if have "$c"; then echo "  ok       $c"; else echo "  MISSING  $c (required)"; ok=0; fi
	done
	for c in nft traceroute; do
		if have "$c"; then echo "  ok       $c"; else echo "  missing  $c (optional: $( [ "$c" = nft ] && echo blocking || echo route tracing ))"; fi
	done
	if have uclient-fetch || have curl || have wget; then echo "  ok       web fetch (location lookups, notifications)"; else echo "  missing  uclient-fetch/curl/wget (optional)"; fi
	find_ifaces; build_filter
	echo "  LAN interface: $LAN_IF    WAN interface: ${WAN_IF:-not found}"
	echo "  Watching: ${DEVICE_IP:-every device on the LAN}"
	if [ -f "$RUN/pid" ] && kill -0 "$(cat "$RUN/pid")" 2>/dev/null; then echo "  Service: running"; else echo "  Service: not running"; fi
	if [ "$ok" = 1 ]; then
		echo "  Listening for 5 seconds..."
		# shellcheck disable=SC2086
		n="$( (tcpdump -i "$LAN_IF" -n -q -l -s 96 $FILTER 2>/dev/null & p=$!; sleep 5; kill $p 2>/dev/null) | wc -l)"
		echo "  Saw $n matching UDP packets. $( [ "$n" -gt 0 ] && echo "Capture works." || echo "Nothing seen: start a game, or check DEVICE_IP and LAN_IF." )"
	fi
}
usage() {
	cat <<EOF
matchwatch $VERSION - game server and connection judge

  matchwatch live              live view of the match in progress
  matchwatch last              full report for the last match
  matchwatch history [n|ip]    recent matches (or every match on one server)
  matchwatch servers           every server seen, worst first
  matchwatch datacentres       servers grouped by datacentre, worst first
  matchwatch block-dc <n>      block the address blocks seen in datacentre number n
  matchwatch unblock-dc <n>    undo that
  matchwatch stay <places>     keep to a pool of places, separated by commas: cities (milan),
                               countries (france, germany, spain), areas (see 'matchwatch places')
  matchwatch stay add <places> | remove <n> | off     change or end the pool
  matchwatch ranges [refresh]  the hosting companies' address lists used to turn whole regions away
  matchwatch hours             how your matches rate at each hour of the day
  matchwatch recap             summary of your latest session
  matchwatch games             games seen; 'matchwatch game name <port or lo-hi> <name>' adds or names one,
                               'matchwatch game remove <port or lo-hi>' takes your name off again
  matchwatch regions [measure] ping every region the game's host has a datacentre in
  matchwatch mark              flag this moment ("I felt that"); same as the dashboard button
  matchwatch qos               check the game is in QoSmate's top class (run during a match)
  matchwatch device [<ip>|all] show the devices on your network and choose which one to watch
  matchwatch qos fix | unfix   add (or remove) QoSmate rules that put your gaming device's UDP in the top class
  matchwatch block <ip> [days] block a server (default $BLOCK_DAYS days, 0 = until unblocked)
  matchwatch unblock <ip>|all  remove a block
  matchwatch blocklist         show blocked servers
  matchwatch fav [add|remove <ip>]   your favourite servers; a favourite is never blocked automatically
  matchwatch allow [add|remove <ip>] single servers let through the places you stay on, whatever their region
  matchwatch strict [on|off <game>]  hold every new server of a game until it has been placed
  matchwatch doctor            check that everything needed is in place (changes nothing)
  matchwatch clear-history     forget every recorded match (blocks and settings are kept)
  matchwatch update [now]      is there a newer version on GitHub? With now: download and install it
  matchwatch forget match <start> | server <ip> | dc <n>   remove one match, one server or one datacentre
                               and everything built from them. Favourites are kept.
  matchwatch share             make, check or import a share file: game labels, ping hosts,
                               places to stay on, server ratings and thresholds
  /etc/init.d/matchwatch start|stop|restart|enable

Dashboard and settings: LuCI, under Services, MatchWatch
EOF
}

case "$1" in
	run) cmd_run ;;
	live) cmd_live ;;
	last) cmd_last ;;
	history) touch "$DATA/sessions.tsv" 2>/dev/null; awk -v MODE=hist_txt -v ARG="$2" -v GAMES="$LIB/games.list" -v GAMESL="$DATA/games.local" -f "$LIB/report.awk" "$DATA/sessions.tsv" ;;
	servers) touch "$DATA/sessions.tsv" "$DATA/blocklist" 2>/dev/null; awk -v MODE=srv_txt -v BLOCK="$DATA/blocklist" -f "$LIB/report.awk" "$DATA/sessions.tsv" ;;
	datacentres|datacenters|dcs) touch "$DATA/sessions.tsv" "$DATA/blocklist" 2>/dev/null; awk -v MODE=dc_txt -v BLOCK="$DATA/blocklist" $(stay_vars) -f "$LIB/report.awk" "$DATA/sessions.tsv" ;;
	block-dc) cmd_block_dc "$2" "$3" ;;
	unblock-dc) cmd_unblock_dc "$2" ;;
	stay) shift; case "$1" in add|remove) c="$1"; shift; cmd_stay "$c" "$*" ;; circle|set) cmd_stay "$@" ;; *) cmd_stay "$*" ;; esac ;;
	hours) touch "$DATA/sessions.tsv"; awk -v MODE=hours_txt -f "$LIB/report.awk" "$DATA/sessions.tsv" ;;
	recap) touch "$DATA/sessions.tsv"; awk -v MODE=recap_txt -v GAMES="$LIB/games.list" -v GAMESL="$DATA/games.local" -f "$LIB/report.awk" "$DATA/sessions.tsv" ;;
	games) touch "$DATA/sessions.tsv"; awk -v MODE=games_txt -v GAMES="$LIB/games.list" -v GAMESL="$DATA/games.local" -f "$LIB/report.awk" "$DATA/sessions.tsv" ;;
	game) cmd_game "$2" "$3" "$4" "$5" "$6" ;;
	device) cmd_device "$2" ;;
	regions) cmd_regions "$2" ;;
	places) awk -F'|' '/^area/ { printf "%-18s %-18s %s\n", $2, $3, $4 }' "$LIB/places.list"; echo; echo "Also any country by name or two-letter code, and any city by name." ;;
	_lobby) cmd_lobby "$2" "$3" "$4" ;;
	_action) shift; cmd_action "$@" ;;
	_migrate) cmd_migrate ;;
	mark) cmd_mark ;;
	qos) cmd_qos "$2" ;;
	block) shift; cmd_block "$@" ;;
	unblock) cmd_unblock "$2" ;;
	blocklist) cmd_blocklist ;;
	fav) cmd_fav "$2" "$3" ;;
	allow) cmd_allow "$2" "$3" ;;
	strict) c="$2"; if [ $# -ge 2 ]; then shift 2; else shift; fi; cmd_hold "$c" "$*" ;;
	_hold) cmd_hold_check "$2" "$3" ;;
	ranges) cmd_ranges "$2" ;;
	doctor) cmd_doctor ;;
	clear-history) cmd_clear_history ;;
	forget) cmd_forget "$2" "$3" ;;
	share) shift; cmd_share "$@" ;;
	version) echo "$VERSION" ;;
	update) cmd_update "$2" ;;
	_probe_start) shift; cmd_probe_start "$@" ;;
	_probe_stop) cmd_probe_stop "$2" ;;
	_notify) cmd_notify "$2" ;;
	_geo) is_ipv4 "$2" && geo_lookup "$2" >/dev/null ;;
	_newgame) case "$2" in ""|*[!0-9]*) ;; *) cmd_newgame "$2" ;; esac ;;
	_after) cmd_after "$2" "$3" ;;
	_export) mkdir -p "$RUN/www"; export_json ;;
	_stop) [ -f "$RUN/pid" ] && kill "$(cat "$RUN/pid")" 2>/dev/null ;;
	*) usage ;;
esac
MW_FILE_END_0
chmod 755 "$R/usr/bin/matchwatch.new"
mv -f "$R/usr/bin/matchwatch.new" "$R/usr/bin/matchwatch"
cat > "$R/usr/lib/matchwatch/analyze.awk.new" <<'MW_FILE_END_1'
# matchwatch analysis engine
# Reads "tcpdump -tt -n -q -l" lines for UDP traffic seen on the LAN side,
# plus "TICK" heartbeat lines, and judges each game session.
#
# Works on packet TIMING and SIZE only. Game traffic is encrypted and is never
# decoded, modified, delayed or injected.
#
# Variables (-v): SELF RUN DATA WIN MINDN MINUP WANDEV WARNSCORE
#                 AUTOBLOCK ABSCORE ABMATCHES REPLAY PROBESUM

function abs(x) { return x < 0 ? -x : x }
function clamp(x, lo, hi) { return x < lo ? lo : (x > hi ? hi : x) }
function r1(x) { return int(x * 10 + 0.5) / 10 }
function r2(x) { return int(x * 100 + 0.5) / 100 }
function num(x) { return (x == "" || x == "-") ? "-" : x }
function grade(s) {
	if (s == "-") return "n/a"
	if (s >= 85) return "Excellent"
	if (s >= 70) return "Good"
	if (s >= 50) return "Fair"
	return "Poor"
}
# Why a score is what it is: every deduction is noted as it is made, and the largest (with the next,
# when that one cost two points or more) becomes one short line shown under the score.
function why_add(pts, text) { if (pts >= 0.5) { WN++; WP[WN] = pts; WT[WN] = text } }
function why_out(score, none,    i, a, b, t) {
	a = 0; b = 0
	for (i = 1; i <= WN; i++) if (!a || WP[i] > WP[a]) a = i
	for (i = 1; i <= WN; i++) if (i != a && WP[i] >= 2 && (!b || WP[i] > WP[b])) b = i
	t = a ? WT[a] (b ? "; " tolower(substr(WT[b], 1, 1)) substr(WT[b], 2) : "") : "Nothing to fault"
	WN = 0
	return (score == "-") ? none : t
}
function plural(n, word) { return n " " word (n == 1 ? "" : "s") }
function clean(s) { gsub(/[\t\r\n"\\]/, " ", s); return s }
function priv(a, b) {
	return (a == 10 || (a == 172 && b >= 16 && b <= 31) || (a == 192 && b == 168) || (a == 169 && b == 254))
}
function read_num(file,   v) {
	v = 0
	if ((getline v < file) <= 0) v = 0
	close(file)
	return v + 0
}
function pfx(ip,   q) { split(ip, q, "."); return q[1] "." q[2] "." q[3] }
function fmtdur(s,   m) { s = int(s); m = int(s / 60); return m "m " (s - m * 60) "s" }

BEGIN {
	if (WIN == "") WIN = 5
	if (MINDN == "") MINDN = 15
	if (MINUP == "") MINUP = 8
	if (WARNSCORE == "") WARNSCORE = 55
	if (ABSCORE == "") ABSCORE = 45
	if (ABMATCHES == "") ABMATCHES = 2
	if (MARKS == "" && RUN != "" && !REPLAY) MARKS = RUN "/marks"
	if (PCSCORE == "") PCSCORE = 1
	PCSCORE += 0
	WIN += 0; MINDN += 0; MINUP += 0; AUTOBLOCK += 0; REPLAY += 0
	QUALIFY = 8; ENDIDLE = 10; DROPIDLE = 30; TL = 120; MAXFLOWS = 200
	HIST = DATA "/sessions.tsv"
	if (GEOF == "") GEOF = DATA "/geo.cache"
	while ((getline line < HIST) > 0) {
		n = split(line, c, "\t")
		if (n >= 6) { if (c[6] + 0 >= 1024) KPORT[c[6]] = 1; K24[pfx(c[5])] = 1 }
		if (n >= 37 && c[37] == 1 && c[36] != "-") { REP_n[c[5]]++; REP_sum[c[5]] += c[36]; p24 = pfx(c[5]); R24_n[p24]++; R24_sum[p24] += c[36] }
	}
	close(HIST)
	cursec = 0; NFLOW = 0; SIDN = 0; FTMAX = 5400
	reload_games()
	DD = (DETAILDIR != "") ? DETAILDIR : DATA "/matches"
}

# ---------------------------------------------------------------- input

$1 == "TICK" {
	now = ($2 != "") ? $2 + 0 : systime()
	# packets are delivered slightly behind real time, so trail by 2 s
	advance(now - 2)
	if (!REPLAY) { read_marks(); wan_sample(); write_status(now) }
	# names can change while running (the Tools page, matchwatch game name), so look again now and then
	if (++TICKS % 20 == 0) { reload_games(); if (!REPLAY) write_skipped(now) }
	if (HOLDF != "") load_hold()
	next
}

$1 == "MARK" { PEND[++PENDN] = $2 + 0; next }

$2 == "IP" && $4 == ">" {
	if (index($0, "UDP, length") == 0) next
	t = $1 + 0
	len = $NF + 0
	src = $3; dst = $5
	sub(/:$/, "", dst)
	if (split(src, a, ".") != 5 || split(dst, b, ".") != 5) next
	if (a[1] >= 224 || b[1] >= 224) next
	sp = priv(a[1] + 0, a[2] + 0); dp = priv(b[1] + 0, b[2] + 0)
	if (sp && !dp) {
		dir = "U"
		lip = a[1] "." a[2] "." a[3] "." a[4]; lport = a[5]
		rip = b[1] "." b[2] "." b[3] "." b[4]; rport = b[5]
	} else if (dp && !sp) {
		dir = "D"
		lip = b[1] "." b[2] "." b[3] "." b[4]; lport = b[5]
		rip = a[1] "." a[2] "." a[3] "." a[4]; rport = a[5]
	} else next
	advance(int(t))
	if (NHP > 0) hold_seen(dir, rip, rport)
	f = lip ":" lport ">" rip ":" rport
	if (!(f in F_seen)) {
		if (kindof(rport, rip) == "voice") { skip_note(rip, rport, t); next }
		if (NFLOW >= MAXFLOWS) next
		F_seen[f] = 1; NFLOW++
		F_lip[f] = lip; F_lport[f] = lport; F_rip[f] = rip; F_rport[f] = rport
		F_first[f] = t; F_pk[f] = 0; F_good[f] = 0; F_idle[f] = 0; F_active[f] = 0; F_wsec[f] = 0
	}
	packet(f, dir, t, len)
	next
}

END {
	if (REPLAY) {
		for (f in F_seen) if (F_active[f]) {
			window_end(f, "D"); window_end(f, "U")
			session_end(f, cursec)
		}
	}
}

# ---------------------------------------------------------------- packets

function packet(f, d, t, len,    k, gap, thr, n, avg) {
	k = f SUBSEP d
	F_pk[f]++; F_last[f] = t
	Q_cnt[k]++
	S_bytes[k] += len; S_pk[k]++
	if (F_pk[f] == 4 && !F_lobby[f]) lobby_check(f)
	if (F_pk[f] == 20 && !F_warned[f]) early_check(f)
	if (!(k in P_last)) { P_last[k] = t; P_tick[k] = t; return }
	gap = (t - P_last[k]) * 1000
	P_last[k] = t
	if (gap > Q_max[k]) Q_max[k] = gap
	# packets that arrive almost together belong to the same update ("tick")
	thr = (P_nom[k] > 0) ? P_nom[k] * 0.25 : 1.0
	if (thr > 3) thr = 3
	if (thr < 0.3) thr = 0.3
	if (gap < thr) { n = W_n[k] + 0; W_tg[k, n]++; W_tight[k]++; return }
	n = ++W_n[k]
	W_iv[k, n] = (t - P_tick[k]) * 1000
	P_tick[k] = t
}

function early_check(f,    ip, avg, p) {
	F_warned[f] = 1
	ip = F_rip[f]
	if (!(ip in REP_n) || REP_n[ip] < 1) {
		p = pfx(ip)
		if ((p in R24_n) && R24_n[p] >= 2 && R24_sum[p] / R24_n[p] < WARNSCORE) {
			print "WARN bad neighbourhood " ip
			if (!REPLAY) system(SELF " _notify 'New server, but its neighbours rate " int(R24_sum[p] / R24_n[p]) "/100 over " R24_n[p] " matches.' &")
		}
		return
	}
	avg = REP_sum[ip] / REP_n[ip]
	if (avg < WARNSCORE) {
		print "WARN known bad server " ip " (rating " int(avg) " over " REP_n[ip] " matches)"
		if (!REPLAY) system(SELF " _notify 'Poor server: rated " int(avg) "/100 over " REP_n[ip] " matches.' &")
	}
}

# Labels: name|ports|kind|hosts, your own (games.local) before the built-in list, first match wins.
# A port alone often cannot tell two games apart, or a game from voice chat, so a label may also name
# the company that hosts its servers (hosts: words looked for in the server's isp, org and AS name).
# Such a label only matches once the host is known, and the lookup takes a second or two; until then
# the stream falls through to whatever label comes next.
# kindof() answers "game", "voice" or "" (nobody has named it).
#   game   tracked, and the only kind ever alerted on, turned away or blocked automatically
#   voice  not tracked at all: voice chat is not a match, and must never be cut off
#   ""     tracked and rated, but left alone until it has a name
function load_games(file,    l, g, k, a, i, r) {
	if (file == "") return
	while ((getline l < file) > 0) {
		if (l ~ /^#/ || l == "") continue
		split(l, g, "|"); k = split(g[2], a, ",")
		for (i = 1; i <= k; i++) {
			NGP++
			if (a[i] ~ /-/) { split(a[i], r, "-"); GP_lo[NGP] = r[1] + 0; GP_hi[NGP] = r[2] + 0 } else { GP_lo[NGP] = a[i] + 0; GP_hi[NGP] = a[i] + 0 }
			GP_kind[NGP] = (g[3] == "voice") ? "voice" : "game"; GP_host[NGP] = tolower(g[4])
		}
	}
	close(file)
}
# Strict games. HOLDF lists the server ports being held (first line: a serial that changes whenever the
# verdicts were thrown away). The firewall drops the device's packets to such a port until the server has
# a verdict, so the engine asks for one the moment it sees a packet go out, and keeps asking, slowly, for
# as long as nothing comes back. A reply means the server is through and needs no more asking.
function load_hold(    l, a, n, ser) {
	n = 0; ser = ""
	while ((getline l < HOLDF) > 0) { if (l ~ /^#/) { ser = l; continue } if (split(l, a, " ") == 2) { n++; HP_lo[n] = a[1] + 0; HP_hi[n] = a[2] + 0 } }
	close(HOLDF)
	NHP = n
	if (ser != HOLD_ser || HO_c > 4000) { HOLD_ser = ser; HO_c = 0; split("", HO_ok); split("", HO_t); split("", HO_n) }
}
function hold_seen(dir, ip, port,    i, hit) {
	if (ip in HO_ok) return
	hit = 0
	for (i = 1; i <= NHP; i++) if (port + 0 >= HP_lo[i] && port + 0 <= HP_hi[i]) { hit = 1; break }
	if (!hit) return
	if (dir == "D") { HO_ok[ip] = 1; HO_c++; return }
	if ((ip in HO_t) && cursec - HO_t[ip] < (HO_n[ip] > 5 ? 60 : 4)) return
	if (!(ip in HO_t)) HO_c++
	HO_t[ip] = cursec; HO_n[ip]++
	if (!REPLAY) system(SELF " _hold " ip " " (port + 0) " >/dev/null 2>&1 &")
	else print "HOLD " ip ":" port
}
function reload_games() { NGP = 0; load_games(GAMESL); load_games(GAMES) }
# who hosts this server: "isp org as" in lower case, or "" while that is not known
function hostinfo(ip,    l, c) {
	if (ip in HOST) return HOST[ip]
	if (GEOF == "") return ""
	# not known yet: ask once, then watch the lookup cache for half a minute
	if (!(ip in HOSTASK)) { HOSTASK[ip] = cursec; GEO_read = -1; if (!REPLAY) system(SELF " _geo " ip " >/dev/null 2>&1 &") }
	if (cursec - HOSTASK[ip] > 30 || cursec == GEO_read) return ""
	GEO_read = cursec
	while ((getline l < GEOF) > 0) if (split(l, c, "\t") >= 9) HOST[c[1]] = tolower(c[7] " " c[8] " " c[9])
	close(GEOF)
	return (ip in HOST) ? HOST[ip] : ""
}
function hostmatch(words, info,    w, n, i) {
	if (info == "") return 0
	n = split(words, w, ",")
	for (i = 1; i <= n; i++) if (w[i] != "" && index(info, w[i]) > 0) return 1
	return 0
}
function kindof(port, ip,    i) {
	for (i = 1; i <= NGP; i++) {
		if (port + 0 < GP_lo[i] || port + 0 > GP_hi[i]) continue
		if (GP_host[i] != "" && !hostmatch(GP_host[i], hostinfo(ip))) continue
		return GP_kind[i]
	}
	return ""
}
function isgame(port, ip) { return kindof(port, ip) == "game" }

# A stream left alone as voice chat is still counted, so the Tools page can show what was skipped
# and the owner can say "that one is a game".
function skip_note(ip, port, t,    k) {
	k = ip ":" port
	if (!(k in SK_n)) { if (SKN >= 100) return; SKN++; SK_ip[k] = ip; SK_port[k] = port }
	SK_n[k]++; SK_last[k] = t
}
function write_skipped(now,    k, s, n, file) {
	s = "["
	for (k in SK_n) {
		if (now - SK_last[k] > 21600) { delete SK_n[k]; delete SK_last[k]; delete SK_ip[k]; delete SK_port[k]; delete SK_why[k]; SKN--; continue }
		if (SK_n[k] < 300 || n >= 12) continue          # a real stream, not a few stray packets
		s = s (n++ ? "," : "") "{\"ip\":\"" SK_ip[k] "\",\"port\":" SK_port[k] ",\"packets\":" SK_n[k] ",\"last\":" int(SK_last[k]) ",\"why\":\"" ((k in SK_why) ? SK_why[k] : "voice") "\"}"
	}
	file = RUN "/www/skipped.json"
	print s "]" > file; close(file)
}

# first packets to a server that looks like a game server: tell the player where they are headed.
# Two tests, both needed. The port must be labelled as a game, so voice chat is left alone. And the
# port or address block must have carried an earlier match, because game port ranges are wide and
# plenty of other traffic (calls, peer-to-peer) uses ports inside them.
function lobby_check(f,    ip) {
	F_lobby[f] = 1
	ip = F_rip[f]
	if (!isgame(F_rport[f], ip)) return
	if (!((F_rport[f] in KPORT) || (pfx(ip) in K24))) return
	if ((ip in LOB_t) && cursec - LOB_t[ip] < 120) return
	LOB_t[ip] = cursec
	print "LOBBY " ip ":" F_rport[f]
	if (!REPLAY) system(SELF " _lobby " ip " " F_rport[f] " " F_lip[f] " >/dev/null 2>&1 &")
}

# ---------------------------------------------------------------- clock

function advance(sec,    guard) {
	if (cursec == 0) { cursec = sec; return }
	guard = 0
	while (cursec < sec && guard < 6) { cursec++; second_end(cursec); guard++ }
	if (cursec < sec) cursec = sec
}

function wan_sample(    rx, tx) {
	if (WANDEV == "") return
	rx = read_num("/sys/class/net/" WANDEV "/statistics/rx_bytes")
	tx = read_num("/sys/class/net/" WANDEV "/statistics/tx_bytes")
	if (W_prx > 0 && rx >= W_prx) { WAN_dn = (rx - W_prx) * 8 / 1000000; WAN_up = (tx - W_ptx) * 8 / 1000000 }
	W_prx = rx; W_ptx = tx
	for (f in F_seen) if (F_active[f]) {
		F_wsum[f] += WAN_dn; F_wn[f]++
		if (WAN_dn > F_wpk[f]) F_wpk[f] = WAN_dn
		if (WAN_up > F_wupk[f]) F_wupk[f] = WAN_up
	}
}

function second_end(sec,    f, kd, ku, dn, up, i, nd, ne, v) {
	nd = 0; ne = 0
	for (f in F_seen) {
		kd = f SUBSEP "D"; ku = f SUBSEP "U"
		dn = Q_cnt[kd] + 0; up = Q_cnt[ku] + 0
		# timeline: worst gap between packets in this second (ms)
		i = (F_tln[f] % TL); F_tln[f]++; F_tlsec[f] = sec
		v = Q_max[kd] + 0
		if (dn == 0 && (kd in P_last)) v = (sec - P_last[kd]) * 1000
		TL_d[f, i] = (v > 0) ? int(v * 10) / 10 : 0
		v = Q_max[ku] + 0
		if (up == 0 && (ku in P_last)) v = (sec - P_last[ku]) * 1000
		TL_u[f, i] = (v > 0) ? int(v * 10) / 10 : 0
		if (F_active[f] && FT_n[f] < FTMAX) { v = ++FT_n[f]; FT_d[f, v] = TL_d[f, i]; FT_u[f, v] = TL_u[f, i] }
		Q_cnt[kd] = 0; Q_cnt[ku] = 0; Q_max[kd] = 0; Q_max[ku] = 0

		if (dn >= MINDN && up >= MINUP) { if (F_good[f] < 30) F_good[f]++ }
		else if (F_good[f] > 0) F_good[f]--
		if (dn + up == 0) F_idle[f]++; else F_idle[f] = 0

		if (!F_active[f] && F_good[f] >= QUALIFY) session_start(f, sec)
		F_wsec[f]++
		if (F_wsec[f] >= WIN) { window_end(f, "D"); window_end(f, "U"); F_wsec[f] = 0 }

		if (F_active[f] && F_idle[f] >= ENDIDLE) END_list[++ne] = f
		else if (!F_active[f] && F_idle[f] >= DROPIDLE) DROP_list[++nd] = f
	}
	process_marks(sec)
	for (i = 1; i <= ne; i++) { session_end(END_list[i], sec); drop_flow(END_list[i]) }
	for (i = 1; i <= nd; i++) drop_flow(DROP_list[i])
}

function drop_flow(f,    d, k, i, di) {
	for (di = 1; di <= 2; di++) {
		d = (di == 1) ? "D" : "U"; k = f SUBSEP d
		for (i = 0; i <= W_n[k] + 0; i++) { delete W_iv[k, i]; delete W_tg[k, i] }
		for (i = 1; i <= S_rn[k] + 0; i++) delete S_rate[k, i]
		delete W_n[k]; delete W_tight[k]; delete P_last[k]; delete P_tick[k]; delete P_nom[k]
		delete Q_cnt[k]; delete Q_max[k]; delete S_bytes[k]; delete S_pk[k]
		delete S_ticks[k]; delete S_late[k]; delete S_lost[k]; delete S_dly[k]; delete S_gaps[k]
		delete S_frz[k]; delete S_stut[k]; delete S_dev[k]; delete S_devn[k]; delete S_win[k]; delete S_bad[k]
		delete S_worst[k]; delete S_rn[k]
		delete L_rate[k]; delete L_jit[k]; delete L_late[k]; delete L_lost[k]
	}
	for (i = 0; i < TL; i++) { delete TL_d[f, i]; delete TL_u[f, i]; delete TP[f, i] }
	delete F_ping[f]; delete F_tpn[f]; delete F_pavg[f]; delete F_tlsec[f]
	for (i = 1; i <= M_n[f] + 0; i++) { delete M_c[f, M_kind[f, i]]; delete M_t[f, i]; delete M_kind[f, i]; delete M_txt[f, i] }
	delete M_n[f]
	for (i = 1; i <= FT_n[f] + 0; i++) { delete FT_d[f, i]; delete FT_u[f, i] }
	for (i = 1; i <= FTP_n[f] + 0; i++) delete FT_p[f, i]
	delete FT_n[f]; delete FTP_n[f]; delete F_ft0[f]; delete F_lobby[f]
	delete F_seen[f]; delete F_lip[f]; delete F_lport[f]; delete F_rip[f]; delete F_rport[f]
	delete F_first[f]; delete F_last[f]; delete F_pk[f]; delete F_good[f]; delete F_idle[f]
	delete F_active[f]; delete F_wsec[f]; delete F_tln[f]; delete F_sid[f]; delete F_warned[f]
	delete F_geo[f]; delete F_wsum[f]; delete F_wn[f]; delete F_wpk[f]; delete F_wupk[f]
	NFLOW--
}

# ---------------------------------------------------------------- marks

function read_marks(    line, n) {
	if (MARKS == "") return
	n = 0
	while ((getline line < MARKS) > 0) { n++; if (n > MARKN) { MARKN = n; PEND[++PENDN] = line + 0 } }
	close(MARKS)
}

function process_marks(sec,    i, f, tm) {
	for (i = PENDI + 1; i <= PENDN; i++) {
		tm = PEND[i]
		if (sec < tm + 2) break
		for (f in F_seen) if (F_active[f]) judge_mark(f, tm, sec)
		PENDI = i; delete PEND[i]
	}
}

# what was happening in the six seconds before the player pressed the button?
function judge_mark(f, tm, sec,    kd, ku, dn, s, off, idx, dv, uv, pv, late, mlate, mpause, mping, kind, txt, n, have) {
	kd = f SUBSEP "D"; ku = f SUBSEP "U"
	dn = P_nom[kd] + 0
	mlate = 0; mpause = 0; mping = -1; have = 0
	for (s = tm - 6; s <= tm + 1; s++) {
		off = F_tlsec[f] - s
		if (off >= 0 && off < TL && off < F_tln[f]) {
			idx = (F_tln[f] - 1 - off) % TL
			dv = TL_d[f, idx] + 0; uv = TL_u[f, idx] + 0; have = 1
			late = dv - dn
			if (late > mlate) mlate = late
			if (uv > mpause) mpause = uv
		}
		off = (sec + 2) - s
		if (off >= 0 && off < TL && off < F_tpn[f]) {
			idx = (F_tpn[f] - 1 - off) % TL
			pv = TP[f, idx] + 0
			if (pv > mping) mping = pv
		}
	}
	if (!have) return
	kind = ""; txt = ""
	if (dn > 0 && mlate > (dn > 30 ? dn : 30)) { kind = "server"; txt = sprintf("server updates stalled: one arrived %.0f ms late", mlate) }
	if (mping > 0 && F_pavg[f] > 0 && mping > F_pavg[f] * 1.5 + 5) {
		kind = (kind != "" ? kind "+" : "") "ping"
		txt = (txt != "" ? txt "; " : "") sprintf("ping jumped to %.0f ms (normally %.0f)", mping, F_pavg[f])
	}
	if (mpause > 100) {
		kind = (kind != "" ? kind "+" : "") "pc"
		txt = (txt != "" ? txt "; " : "") sprintf("your PC stopped sending for %.0f ms", mpause)
	}
	if (kind == "") { kind = "none"; txt = "nothing unusual on the network just before: more likely the game itself or your frame rate" }
	n = ++M_n[f]
	M_t[f, n] = tm; M_kind[f, n] = kind; M_txt[f, n] = txt
	M_c[f, kind]++
	print "MARK " F_rip[f] " " kind
}

# ---------------------------------------------------------------- windows

function median_iv(k, n,    i, b, c, half) {
	split("", H)
	for (i = 1; i <= n; i++) { b = int(W_iv[k, i] * 10); if (b > 3000) b = 3000; H[b]++ }
	half = n / 2; c = 0
	for (b = 0; b <= 3000; b++) if (b in H) { c += H[b]; if (c >= half) return (b + 0.5) / 10 }
	return 0
}

function window_end(f, d,    k, n, i, x, nom, base, late, lost, dly, gaps, frz, dev, devn, miss, rec, minr, rate, trans, wworst, stut) {
	k = f SUBSEP d
	n = W_n[k] + 0
	rate = n / WIN
	minr = (d == "D") ? MINDN : MINUP
	nom = (n >= 3) ? median_iv(k, n) : 0
	L_rate[k] = (nom > 0) ? 1000 / nom : 0
	L_jit[k] = "-"; L_late[k] = "-"; L_lost[k] = "-"
	if (rate >= minr && nom > 0) {
		# skip the window where the rate changes (lobby to match). The PC's rate follows frame rate,
		# so only a doubling or halving counts as a change there
		trans = (P_nom[k] > 0 && abs(nom - P_nom[k]) / P_nom[k] > ((d == "D") ? 0.2 : 1.0))
		if (d == "U" && P_nom[k] > 0 && nom < P_nom[k] / 2) trans = 1
		base = W_tight[k] / n
		base = (base > 0.2) ? int(base + 0.999) : 0
		late = 0; lost = 0; dly = 0; gaps = 0; frz = 0; stut = 0; dev = 0; devn = 0
		wworst = 0
		for (i = 1; i <= n; i++) {
			x = W_iv[k, i]
			if ((d == "D" && x > 1.75 * nom) || (d == "U" && x > 50 && x > 3 * nom)) {
				rec = W_tg[k, i] - base
				if (rec < 0) rec = 0
				# a clump after the gap means packets were held up, not lost
				miss = (rec > 0) ? int(x / nom) - 1 : int(x / nom + 0.5) - 1
				if (miss < 1) miss = 1
				if (rec > miss) rec = miss
				lost += miss - rec; dly += rec; gaps++
				if (x > 100 && x > 3 * nom) frz++
				if (x > 50 && x > 3 * nom) stut++
				if (x > wworst) wworst = x
			} else {
				if (d == "D" && x > 1.4 * nom) late++
				dev += abs(x - nom); devn++
			}
		}
		L_jit[k] = (devn > 0) ? dev / devn : 0
		L_late[k] = 100 * (late + dly) / (n + lost)
		L_lost[k] = 100 * lost / (n + lost)
		if (!trans) {
			S_ticks[k] += n; S_late[k] += late; S_lost[k] += lost; S_dly[k] += dly
			S_gaps[k] += gaps; S_frz[k] += frz; S_stut[k] += stut; S_dev[k] += dev; S_devn[k] += devn
			S_win[k]++
			if (wworst > S_worst[k]) S_worst[k] = wworst
			if (stut > 0 || (late + lost + dly) / (n + lost) > 0.05) S_bad[k]++
			S_rate[k, ++S_rn[k]] = 1000 / nom
		}
	}
	if (nom > 0) P_nom[k] = nom
	for (i = 0; i <= n; i++) { delete W_iv[k, i]; delete W_tg[k, i] }
	W_n[k] = 0; W_tight[k] = 0
}

function median_rate(k,    n, i, j, v, A) {
	n = S_rn[k] + 0
	if (n == 0) return 0
	for (i = 1; i <= n; i++) A[i] = S_rate[k, i]
	for (i = 2; i <= n; i++) { v = A[i]; for (j = i - 1; j >= 1 && A[j] > v; j--) A[j + 1] = A[j]; A[j + 1] = v }
	return A[int((n + 1) / 2)]
}

# ---------------------------------------------------------------- sessions

function session_start(f, sec,    d, k, i, di) {
	F_active[f] = 1
	# Score only from the point steady traffic began. Games often exchange a few packets with the
	# server, wait (matchmaking, loading), then start the real stream; that wait is not a stutter.
	for (di = 1; di <= 2; di++) {
		d = (di == 1) ? "D" : "U"; k = f SUBSEP d
		for (i = 1; i <= S_rn[k] + 0; i++) delete S_rate[k, i]
		S_rn[k] = 0; S_ticks[k] = 0; S_late[k] = 0; S_lost[k] = 0; S_dly[k] = 0; S_gaps[k] = 0
		S_frz[k] = 0; S_stut[k] = 0; S_dev[k] = 0; S_devn[k] = 0; S_win[k] = 0; S_bad[k] = 0; S_worst[k] = 0
	}
	if (sec - QUALIFY - 2 > F_first[f]) F_first[f] = sec - QUALIFY - 2
	FT_n[f] = 0; FTP_n[f] = 0; F_ft0[f] = sec
	F_sid[f] = sec "_" (++SIDN)
	print "START " F_sid[f] " " F_lip[f] " -> " F_rip[f] ":" F_rport[f]
	if (!REPLAY) system(SELF " _probe_start " F_sid[f] " " F_rip[f] " " F_lip[f] " " F_rport[f] " " (kindof(F_rport[f], F_rip[f]) == "" ? "unnamed" : "named") " >/dev/null 2>&1 &")
}

function load_sum(file,    line, p) {
	split("", PS)
	while ((getline line < file) > 0) {
		p = index(line, "=")
		if (p > 0) PS[substr(line, 1, p - 1)] = substr(line, p + 1)
	}
	close(file)
}

function probe_score(pfx, kind,    n, jit, loss, med, A, B, L, s) {
	PD_j = 0; PD_l = 0; PD_m = 0
	n = PS[pfx "_n"] + 0
	if (n < 10) return "-"
	jit = PS[pfx "_jit"] + 0; loss = PS[pfx "_loss"] + 0; med = PS[pfx "_med"] + 0
	if (kind == "server") { A = 1; B = 6; L = 12 }
	else if (kind == "serverudp") { A = 1; B = 6; L = 0 }   # servers ration replies to these probes, so unanswered ones say nothing about the route
	else if (kind == "lan") { A = 0.5; B = 10; L = 15 }
	else { A = 3; B = 3; L = 6 }          # router hops answer ping lazily: be lenient
	PD_j = clamp((jit - A) * B, 0, 35); PD_l = clamp(loss * L, 0, 45); PV_j = jit; PV_l = loss; PV_m = med
	s = 100 - PD_j - PD_l
	if (pfx == "far") { PD_m = clamp((med - 40) / 2, 0, 20); s -= PD_m }
	return int(clamp(s, 0, 100) + 0.5)
}

function session_end(f, sec,    kd, ku, dur, dsec, usec, tick, dnom, djit, djrel, dlate, dlost, dclump, dfrz, dstut, dbad, p10,
		uhz, unom, ujit, ujrel, ustall, uhitch, upp, s_srv, s_route, s_line, s_pc, s_lan, overall, rating, reliable,
		wsum, w, i, kk, mk, msum, dj, df, trl, code, vtext, farkind, route_ign, s_route_shown, s_pc_shown, pc_low, loc, rep, out, ip, when, note, avg, sumfile, wan_avg,
		y_srv, y_route, y_line, y_pc) {
	kd = f SUBSEP "D"; ku = f SUBSEP "U"
	ip = F_rip[f]
	dur = F_last[f] - F_first[f]
	dsec = (S_win[kd] + 0) * WIN; usec = (S_win[ku] + 0) * WIN

	split("", PS)
	if (!REPLAY) {
		system(SELF " _probe_stop " F_sid[f])
		sumfile = RUN "/probe." F_sid[f] "/sum"
		load_sum(sumfile)
		QM = ""; if ((getline QM < (RUN "/probe." F_sid[f] "/qm.json")) <= 0) QM = ""
		close(RUN "/probe." F_sid[f] "/qm.json")
		TRN = 0
		while ((getline trl < (RUN "/probe." F_sid[f] "/trace")) > 0) if (trl ~ /^ *[0-9]+ /) TR[++TRN] = clean(trl)
		close(RUN "/probe." F_sid[f] "/trace")
	} else { TRN = 0; QM = ""; if (PROBESUM != "") load_sum(PROBESUM) }

	if (dsec < 20 || S_ticks[kd] + 0 == 0) {
		print "END " F_sid[f] " " ip " too short to judge (" int(dur) "s)"
		if (!REPLAY) system("rm -rf " RUN "/probe." F_sid[f])
		return
	}

	# --- server rhythm (downstream)
	tick = median_rate(kd); dnom = 1000 / tick
	djit = (S_devn[kd] > 0) ? S_dev[kd] / S_devn[kd] : 0
	djrel = 100 * djit / dnom
	dlate = 100 * S_late[kd] / (S_ticks[kd] + S_lost[kd])
	dclump = 100 * S_dly[kd] / (S_ticks[kd] + S_lost[kd])
	dlost = 100 * S_lost[kd] / (S_ticks[kd] + S_lost[kd])

	# A port nobody has named has to look like a game before it is kept: two minutes of play, and a
	# steady stream of updates. Calls and launchers use unknown ports too; they come in short bursts,
	# or at a rate that keeps changing, which shows here as missing updates. A game on the built-in
	# list, or one the owner has named or added, is always kept. (NGP is 0 only in tests run without
	# the label files.)
	if (NGP > 0 && kindof(F_rport[f], ip) == "" && (dsec < 120 || dlost >= 15)) {
		kk = (dsec < 120) ? "short" : "unsteady"
		print "END " F_sid[f] " " ip " not kept: unnamed port " F_rport[f] ", " kk
		skip_note(ip, F_rport[f], sec); SK_n[ip ":" F_rport[f]] += 300; SK_why[ip ":" F_rport[f]] = kk
		if (!REPLAY) {
			system("rm -rf " RUN "/probe." F_sid[f])
			system("logger -t matchwatch 'Not recorded: a stream on unnamed port " (F_rport[f] + 0) " (" (kk == "short" ? "under two minutes" : "no steady update rate") "). If it was a game, add it under Tools, Games.'")
		}
		return
	}
	dfrz = S_frz[kd] + 0; dstut = S_stut[kd] + 0
	dbad = 100 * S_bad[kd] / S_win[kd]
	p10 = 600 / dsec
	s_srv = 100 - clamp((djrel - 5) * 1.5, 0, 30) - clamp((dlate + dclump) * 4, 0, 25) - clamp(dlost * 12, 0, 35) - clamp(dstut * p10 / 10 * 2, 0, 30) - clamp(dfrz * p10 * 5, 0, 20) - clamp((dbad - 5) * 0.4, 0, 20)
	s_srv = int(clamp(s_srv, 0, 100) + 0.5)
	WN = 0
	why_add(clamp((djrel - 5) * 1.5, 0, 30), sprintf("Uneven timing: jitter was %.0f%% of one update", djrel))
	why_add(clamp((dlate + dclump) * 4, 0, 25), sprintf("%.1f%% of updates came late or in clumps", dlate + dclump))
	why_add(clamp(dlost * 12, 0, 35), sprintf("%.2f%% of updates went missing", dlost))
	why_add(clamp(dstut * p10 / 10 * 2, 0, 30), plural(dstut, "stutter") " over 50 ms")
	why_add(clamp(dfrz * p10 * 5, 0, 20), plural(dfrz, "freeze") " over 100 ms")
	why_add(clamp((dbad - 5) * 0.4, 0, 20), sprintf("Rough for %.0f%% of the match", dbad))
	y_srv = why_out(s_srv, "")

	# --- your PC (upstream cadence + LAN)
	if (usec >= 10 && S_ticks[ku] > 0) {
		uhz = median_rate(ku); unom = 1000 / uhz
		ujit = (S_devn[ku] > 0) ? S_dev[ku] / S_devn[ku] : 0
		ujrel = 100 * ujit / unom
		ustall = S_gaps[ku] + 0; uhitch = S_frz[ku] + 0
		# rate per ten minutes; short sessions are not scaled up, a couple of pauses while joining is normal
		upp = 600 / (usec < 300 ? 300 : usec)
		s_pc = 100 - clamp((ujrel - 60) * 0.3, 0, 10) - clamp(uhitch * upp * 2, 0, 45)
		s_lan = probe_score("lan", "lan")
		if (s_lan != "-") s_pc -= (100 - s_lan)
		s_pc = int(clamp(s_pc, 0, 100) + 0.5)
		why_add(clamp((ujrel - 60) * 0.3, 0, 10), sprintf("Uneven sending: jitter was %.0f%% of one update", ujrel))
		why_add(clamp(uhitch * upp * 2, 0, 45), plural(uhitch, "pause") " over 100 ms in what it sent")
		why_add(PD_j, sprintf("Router to PC jitter %.1f ms", PV_j)); why_add(PD_l, sprintf("%.1f%% loss between router and PC", PV_l))
	} else { uhz = "-"; ujit = "-"; ustall = "-"; uhitch = "-"; s_pc = "-" }
	y_pc = why_out(s_pc, "Too little was sent to judge")

	s_pc_shown = s_pc
	if (PCSCORE == 0) s_pc = "-"       # shown in the report, left out of the overall score and verdict

	# --- route and line (active probes, if they answered)
	farkind = (PS["far_kind"] != "") ? PS["far_kind"] : "-"
	s_route = probe_score("far", farkind)
	why_add(PD_m, sprintf("Ping %.0f ms: a long way to the server", PV_m))
	why_add(PD_j, sprintf("Ping jitter %.1f ms", PV_j)); why_add(PD_l, sprintf("%.1f%% of pings lost", PV_l))
	y_route = why_out(s_route, "Nothing on the way answered probes")
	s_line = probe_score("near", "hop")
	why_add(PD_j, sprintf("Jitter %.1f ms to your provider", PV_j)); why_add(PD_l, sprintf("%.1f%% loss to your provider", PV_l))
	y_line = why_out(s_line, "Your provider's first hop did not answer")

	# --- game traffic is the ground truth: when it arrived cleanly, a rougher-looking
	# probe (servers rate-limit and deprioritise probe replies) must not drag scores down
	route_ign = 0; s_route_shown = s_route
	if (s_route != "-" && s_srv >= 80 && s_route < s_srv) { route_ign = 1; s_route = "-" }

	# --- overall
	wsum = 0; overall = 0
	overall += s_srv * 0.45; wsum += 0.45
	if (s_route != "-") { overall += s_route * 0.25; wsum += 0.25 }
	if (s_line != "-") { overall += s_line * 0.15; wsum += 0.15 }
	if (s_pc != "-") { overall += s_pc * 0.15; wsum += 0.15 }
	overall = overall / wsum
	# a match is only as good as its weakest part
	w = s_srv
	if (s_route != "-" && s_route < w) w = s_route
	if (s_line != "-" && s_line < w) w = s_line
	if (s_pc != "-" && s_pc < w) w = s_pc
	overall = int(0.6 * w + 0.4 * overall + 0.5)
	if (s_route != "-") {
		rating = s_srv * 0.65 + s_route * 0.35
		rating = int(0.7 * (s_srv < s_route ? s_srv : s_route) + 0.3 * rating + 0.5)
	} else rating = s_srv
	s_route = s_route_shown; s_pc = s_pc_shown
	pc_low = (PCSCORE != 0 && s_pc != "-" && s_pc < 65)
	reliable = ((s_line == "-" || s_line >= 70) && dsec >= 60) ? 1 : 0

	# --- verdict
	if (dsec < 60) {
		code = "short"
		vtext = "Under a minute of play was analysed, which is too little to judge fairly. The figures are for information only."
	} else if (s_line != "-" && s_line < 70) {
		code = "line"
		vtext = "Your own line was unstable (first ISP hop). The server can't be judged fairly from this match."
	} else if (pc_low && s_srv >= 70) {
		code = "pc"
		vtext = "Your PC sent its updates unevenly (stalls or hitches). Check for frame drops; the server looked fine."
	} else if (s_srv < 70) {
		if (s_route != "-" && farkind ~ /^server/) {
			if (s_route < 70) { code = "route"; vtext = "The route to this server was unstable (ping to it showed jitter or loss)." }
			else { code = "server"; vtext = "The server itself sent updates unevenly while the route to it was clean." }
		} else if (s_route != "-" && s_route < 60) {
			code = "route"; vtext = "The route towards this server was unstable (last hop that answers ping showed jitter or loss)."
		} else if (s_route != "-") {
			code = "server"; vtext = "Updates arrived unevenly while the route looked clean as far as it can be probed: most likely the server."
		} else {
			code = "server_or_route"; vtext = "Updates arrived unevenly. Nothing along the path answers ping, so server and route can't be told apart."
		}
	} else if (route_ign && s_route < 70) {
		code = "ok_ping_rough"; vtext = "Clean match. Game traffic arrived steadily; probes to the server looked rougher, which usually means it limits probe replies, so that is ignored."
	} else {
		code = "clean"; vtext = "Clean match. Nothing on your side, the route or the server stood out."
	}
	if (code != "pc" && code != "short" && pc_low) vtext = vtext " Your PC also sent unevenly."

	loc = ""
	if (PS["city"] != "") loc = PS["city"]
	if (PS["cc"] != "") loc = (loc != "" ? loc ", " : "") PS["cc"]
	wan_avg = (F_wn[f] > 0) ? F_wsum[f] / F_wn[f] : "-"

	# --- reputation
	if (reliable) { REP_n[ip]++; REP_sum[ip] += rating; R24_n[pfx(ip)]++; R24_sum[pfx(ip)] += rating }

	# --- report
	when = strftime("%Y-%m-%d %H:%M", int(F_first[f]))
	rep = "==================== matchwatch ====================\n"
	rep = rep "Match    " when "  (" fmtdur(dur) ", " fmtdur(dsec) " analysed)\n"
	rep = rep "Server   " ip ":" F_rport[f] (loc != "" ? "  " loc : "") (PS["org"] != "" ? "  -  " PS["org"] : "") (PS["asn"] != "" ? " (" PS["asn"] ")" : "") "\n"
	rep = rep "Device   " F_lip[f] "\n\n"
	rep = rep "OVERALL  " overall "/100  " grade(overall) "        Server rating " rating "/100" (reliable ? "" : "  (not counted: " (dsec < 60 ? "match too short" : "your line was unstable") ")") "\n"
	rep = rep "Verdict  " vtext "\n\n"
	rep = rep "SERVER RHYTHM   " s_srv "/100  " grade(s_srv) "\n"
	rep = rep sprintf("  Update rate          %.1f per second\n", tick)
	rep = rep sprintf("  Timing jitter        %.2f ms  (%.1f%% of one update)\n", djit, djrel)
	rep = rep sprintf("  Late updates         %.2f%%\n", dlate)
	rep = rep sprintf("  Arrived in clumps    %.2f%%  (held up on the way, then delivered together)\n", dclump)
	rep = rep sprintf("  Missing updates      %.2f%%  (lost in transit or never sent)\n", dlost)
	rep = rep sprintf("  Stutters over 50 ms  %d   (%d of them over 100 ms, worst gap %.0f ms)\n", dstut, dfrz, S_worst[kd] + 0)
	rep = rep sprintf("  Rough stretches      %.0f%% of the match\n", dbad)
	rep = rep "ROUTE           " (s_route == "-" ? "n/a  (neither the server nor the hops before it answer probes)" : s_route "/100  " grade(s_route) (route_ign ? "  (not counted: game traffic itself arrived cleanly)" : "")) "\n"
	if (s_route != "-") {
		rep = rep "  Probed               " (farkind == "server" ? "the server itself" : (farkind == "serverudp" ? "the server itself (by UDP probe; it ignores ping)" : "last hop that answers, " PS["far_ip"])) "\n"
		if (farkind == "serverudp") rep = rep sprintf("  Ping                 %.1f ms typical, %.1f ms worst 5%%, jitter %.2f ms\n  Probes answered      %.0f%%  (servers ration these replies; this is not packet loss in your game)\n", PS["far_med"], PS["far_p95"], PS["far_jit"], 100 - PS["far_loss"])
		else rep = rep sprintf("  Ping                 %.1f ms typical, %.1f ms worst 5%%, jitter %.2f ms, loss %.1f%%\n", PS["far_med"], PS["far_p95"], PS["far_jit"], PS["far_loss"])
	}
	if (PS["hops"] != "") rep = rep "  Hops                 " PS["hops"] "\n"
	rep = rep "YOUR LINE       " (s_line == "-" ? "n/a  (first ISP hop does not answer ping)" : s_line "/100  " grade(s_line)) "\n"
	if (s_line != "-") rep = rep sprintf("  First ISP hop        %s: %.1f ms typical, jitter %.2f ms, loss %.1f%%\n", PS["near_ip"], PS["near_med"], PS["near_jit"], PS["near_loss"])
	if (wan_avg != "-") rep = rep sprintf("  Other traffic        average %.1f Mbit/s down, peak %.1f down / %.1f up\n", wan_avg, F_wpk[f], F_wupk[f])
	rep = rep "YOUR PC         " (s_pc == "-" ? "n/a" : s_pc "/100  " grade(s_pc) (PCSCORE == 0 ? "  (not counted: PC_SCORE=0)" : "")) "\n"
	if (s_pc != "-") {
		rep = rep sprintf("  Send rate            %.1f per second\n", uhz)
		rep = rep sprintf("  Send jitter          %.2f ms  (follows your frame rate; not scored unless extreme)\n", ujit)
		rep = rep sprintf("  Pauses over 100 ms   %d   (worst %.0f ms; %d shorter ones over 50 ms are not scored)\n", uhitch, S_worst[ku] + 0, ustall - uhitch)
		if (PS["lan_n"] + 0 >= 10) rep = rep sprintf("  Router to PC         %.2f ms typical, jitter %.2f ms, loss %.1f%%\n", PS["lan_med"], PS["lan_jit"], PS["lan_loss"])
		else rep = rep "  Router to PC         n/a (PC does not answer ping; allow ICMP echo in its firewall to enable)\n"
	}
	msum = "-"
	if (M_n[f] > 0) {
		rep = rep "YOUR MARKS      " M_n[f] " moment" (M_n[f] == 1 ? "" : "s") " you flagged\n"
		msum = ""
		for (i = 1; i <= M_n[f]; i++) rep = rep sprintf("  %s into the match  %s\n", fmtdur(M_t[f, i] - F_first[f]), M_txt[f, i])
		for (kk in M_c) { split(kk, mk, SUBSEP); if (mk[1] == f && M_c[kk] > 0) msum = msum (msum != "" ? ", " : "") M_c[kk] " " (mk[2] == "none" ? "nothing on the network" : mk[2]) }
	}
	if (PS["qos_state"] == "top") rep = rep "QOSMATE         game traffic is going through the top priority queue\n"
	else if (PS["qos_state"] == "low") rep = rep "QOSMATE         game traffic is NOT reaching the top priority queue. Run during a match: matchwatch qos\n"
	else if (PS["qos_state"] == "unknown") rep = rep "QOSMATE         could not read how game traffic is marked. Run: matchwatch qos\n"
	if ((ip in REP_n) && REP_n[ip] > 0) rep = rep sprintf("\nThis server so far: average rating %d/100 over %d counted match(es)\n", REP_sum[ip] / REP_n[ip], REP_n[ip])
	rep = rep "====================================================\n"
	# --- history line (tab separated, 48 columns)
	out = int(F_first[f]) "\t" int(dur) "\t" dsec "\t" F_lip[f] "\t" ip "\t" F_rport[f] "\t" num(clean(PS["cc"])) "\t" num(clean(PS["city"])) "\t" num(clean(PS["org"])) "\t" num(clean(PS["asn"]))
	out = out "\t" r1(tick) "\t" r2(djit) "\t" r2(dlate) "\t" r2(dlost) "\t" r2(dclump) "\t" dfrz "\t" r1(dbad)
	out = out "\t" (uhz == "-" ? "-" : r1(uhz)) "\t" (ujit == "-" ? "-" : r2(ujit)) "\t" uhitch
	out = out "\t" farkind "\t" num(PS["far_med"]) "\t" num(PS["far_jit"]) "\t" num(PS["far_loss"])
	out = out "\t" num(PS["near_med"]) "\t" num(PS["near_jit"]) "\t" num(PS["near_loss"])
	out = out "\t" num(PS["lan_med"]) "\t" num(PS["lan_jit"]) "\t" num(PS["lan_loss"])
	out = out "\t" s_srv "\t" s_route "\t" s_line "\t" s_pc "\t" overall "\t" rating "\t" reliable "\t" code "\t" vtext
	out = out "\t" num(PS["lat"]) "\t" num(PS["lon"]) "\t" num(clean(PS["country"])) "\t" (wan_avg == "-" ? "-" : r1(wan_avg)) "\t" r1(F_wpk[f] + 0) "\t" num(PS["hops"])
	out = out "\t" (M_n[f] + 0) "\t" msum "\t" num(PS["qos_class"])
	if (!REPLAY) { print out >> HIST; close(HIST) }
	# the first proper match on a port nobody has named: say so once, because until it has a name
	# staying on places, the lobby alert and automatic blocking all leave it alone
	if (reliable && kindof(F_rport[f], ip) == "" && !(F_rport[f] in KPORT)) {
		print "NEWGAME " F_rport[f]
		if (!REPLAY) system(SELF " _newgame " (F_rport[f] + 0) " &")
	}
	KPORT[F_rport[f]] = 1; K24[pfx(ip)] = 1

	# --- full detail for the dashboard's match page
	if (!REPLAY || DETAILDIR != "") {
		dj = "{\"id\":" int(F_first[f]) ",\"start\":" int(F_first[f]) ",\"dur\":" int(dur) ",\"analysed\":" dsec
		dj = dj ",\"device\":" js(F_lip[f]) ",\"ip\":" js(ip) ",\"port\":" (F_rport[f] + 0)
		dj = dj ",\"cc\":" js(PS["cc"]) ",\"city\":" js(PS["city"]) ",\"country\":" js(PS["country"]) ",\"org\":" js(PS["org"]) ",\"asn\":" js(PS["asn"])
		dj = dj ",\"tick\":" jn2(tick) ",\"nom\":" jn2(dnom) ",\"jit\":" jn2(djit) ",\"jitpct\":" jn2(djrel) ",\"late\":" jn2(dlate) ",\"clump\":" jn2(dclump) ",\"lost\":" jn2(dlost)
		dj = dj ",\"stut\":" dstut ",\"freeze\":" dfrz ",\"worst\":" int(S_worst[kd] + 0) ",\"rough\":" jn2(dbad)
		dj = dj ",\"uprate\":" jn2(uhz) ",\"upnom\":" (uhz == "-" ? "null" : jn2(unom)) ",\"upjit\":" jn2(ujit) ",\"pauses\":" jn2(uhitch) ",\"stalls\":" jn2(ustall) ",\"upworst\":" int(S_worst[ku] + 0)
		dj = dj ",\"farkind\":" js(farkind) ",\"farip\":" js(PS["far_ip"]) ",\"ping\":" jn2(PS["far_med"]) ",\"pingp95\":" jn2(PS["far_p95"]) ",\"pingjit\":" jn2(PS["far_jit"]) ",\"pingloss\":" jn2(PS["far_loss"])
		dj = dj ",\"nearip\":" js(PS["near_ip"]) ",\"nearping\":" jn2(PS["near_med"]) ",\"nearjit\":" jn2(PS["near_jit"]) ",\"nearloss\":" jn2(PS["near_loss"])
		dj = dj ",\"lanping\":" jn2(PS["lan_med"]) ",\"lanjit\":" jn2(PS["lan_jit"]) ",\"lanloss\":" jn2(PS["lan_loss"])
		dj = dj ",\"wanavg\":" jn2(wan_avg) ",\"wanpeak\":" jn2(F_wpk[f] + 0) ",\"wanuppeak\":" jn2(F_wupk[f] + 0) ",\"hops\":" js(PS["hops"])
		dj = dj ",\"s_server\":" jn2(s_srv) ",\"s_route\":" jn2(s_route) ",\"s_line\":" jn2(s_line) ",\"s_pc\":" jn2(s_pc) ",\"overall\":" overall ",\"rating\":" rating
		dj = dj ",\"counted\":" reliable ",\"route_ign\":" (route_ign + 0) ",\"pc_counted\":" (PCSCORE != 0 ? 1 : 0) ",\"code\":" js(code) ",\"verdict\":" js(vtext) ",\"qos\":" js(PS["qos_state"])
		dj = dj ",\"why\":{\"server\":" js(y_srv) ",\"route\":" js(y_route) ",\"line\":" js(y_line) ",\"pc\":" js(y_pc) "}"
		if (QM != "") dj = dj ",\"qm\":" QM
		dj = dj ",\"marks\":["
		for (i = 1; i <= M_n[f] + 0; i++) dj = dj (i > 1 ? "," : "") "{\"t\":" M_t[f, i] ",\"k\":" js(M_kind[f, i]) ",\"x\":" js(M_txt[f, i]) "}"
		dj = dj "],\"trace\":["
		for (i = 1; i <= TRN; i++) dj = dj (i > 1 ? "," : "") js(TR[i])
		dj = dj "],\"t0\":" (F_ft0[f] + 0) ",\"tl_d\":["
		for (i = 1; i <= FT_n[f] + 0; i++) dj = dj (i > 1 ? "," : "") (FT_d[f, i] + 0)
		dj = dj "],\"tl_u\":["
		for (i = 1; i <= FT_n[f] + 0; i++) dj = dj (i > 1 ? "," : "") (FT_u[f, i] + 0)
		dj = dj "],\"tl_p\":["
		for (i = 1; i <= FTP_n[f] + 0; i++) dj = dj (i > 1 ? "," : "") (FT_p[f, i] + 0)
		dj = dj "]}"
		df = DD "/" int(F_first[f]) ".json"
		print dj > df; close(df)
	}

	if (REPLAY) printf "%s", rep
	else {
		printf "%s", rep > (RUN "/last.txt"); close(RUN "/last.txt")
		system("cat " RUN "/probe." F_sid[f] "/trace >> " RUN "/last.txt 2>/dev/null")
	}
	print "END " F_sid[f] " " ip " overall=" overall " rating=" rating " code=" code

	# --- follow-up actions
	if (!REPLAY) {
		note = "Match on " ip (loc != "" ? " (" loc ")" : "") ": " overall "/100 " grade(overall) ". " vtext
		gsub(/'/, "", note)
		system("rm -rf " RUN "/probe." F_sid[f])
		system(SELF " _after '" note "' " overall " &")
	}
	if (AUTOBLOCK && reliable && isgame(F_rport[f], ip) && (ip in REP_n) && REP_n[ip] >= ABMATCHES) {
		avg = REP_sum[ip] / REP_n[ip]
		if (avg < ABSCORE) {
			print "AUTOBLOCK " ip " avg=" int(avg)
			if (!REPLAY) system(SELF " block " ip " auto 'rated " int(avg) " over " REP_n[ip] " matches' >/dev/null 2>&1 &")
		}
	}
}

# ---------------------------------------------------------------- live status

function jnum(x) { return (x == "-" || x == "") ? "null" : r2(x) }
function jn2(x) { return (x == "-" || x == "") ? "null" : r2(x) }
function js(x) { return "\"" clean(x) "\"" }

function write_status(now,    f, kd, ku, first, n, i, j, s, txt, sf, tf, g, line, ga, loc, cand, ip, start, cnt, pf, pv) {
	sf = RUN "/www/status.json.tmp"; tf = RUN "/status.txt.tmp"
	first = 1; cand = 0; txt = ""
	s = "{\"ts\":" now ",\"sessions\":["
	for (f in F_seen) {
		if (!F_active[f]) { if (F_good[f] > 0) cand++; continue }
		kd = f SUBSEP "D"; ku = f SUBSEP "U"; ip = F_rip[f]
		if (F_geo[f] == "") {
			g = RUN "/probe." F_sid[f] "/geo"
			if ((getline line < g) > 0) F_geo[f] = line
			close(g)
		}
		pf = RUN "/probe." F_sid[f] "/far.last"; pv = ""
		if ((getline pv < pf) > 0) F_ping[f] = pv
		close(pf)
		if (F_ping[f] != "" && F_ping[f] != "x") F_pavg[f] = (F_pavg[f] > 0) ? F_pavg[f] * 0.97 + F_ping[f] * 0.03 : F_ping[f] + 0
		i = (F_tpn[f] % TL); F_tpn[f]++
		TP[f, i] = (F_ping[f] == "" || F_ping[f] == "x") ? -1 : F_ping[f] + 0
		if (FTP_n[f] < FTMAX) FT_p[f, ++FTP_n[f]] = TP[f, i]
		loc = ""; split("", ga)
		if (F_geo[f] != "") { split(F_geo[f], ga, "\t"); loc = clean(ga[3]) (ga[1] != "" ? ", " ga[1] : "") }
		if (!first) s = s ","
		first = 0
		s = s "{\"ip\":\"" ip "\",\"port\":" F_rport[f] ",\"device\":\"" F_lip[f] "\",\"age\":" int(now - F_first[f]) ",\"start\":" int(F_first[f])
		s = s ",\"loc\":\"" loc "\",\"org\":\"" clean(ga[7]) "\""
		s = s ",\"tick\":" jnum(L_rate[kd]) ",\"jit\":" jnum(L_jit[kd]) ",\"late\":" jnum(L_late[kd]) ",\"lost\":" jnum(L_lost[kd])
		s = s ",\"uprate\":" jnum(L_rate[ku]) ",\"upjit\":" jnum(L_jit[ku])
		s = s ",\"s_lost\":" (S_ticks[kd] > 0 ? r2(100 * S_lost[kd] / (S_ticks[kd] + S_lost[kd])) : "null")
		s = s ",\"s_frz\":" (S_frz[kd] + 0) ",\"s_hitch\":" (S_frz[ku] + 0)
		s = s ",\"rep\":" (((ip in REP_n) && REP_n[ip] > 0) ? int(REP_sum[ip] / REP_n[ip]) : "null") ",\"repn\":" ((ip in REP_n) ? REP_n[ip] : 0)
		n = F_tln[f] + 0; cnt = (n < TL) ? n : TL; start = (n < TL) ? 0 : n % TL
		s = s ",\"tl_d\":["
		for (j = 0; j < cnt; j++) { i = (start + j) % TL; s = s (j ? "," : "") (TL_d[f, i] + 0) }
		s = s "],\"tl_u\":["
		for (j = 0; j < cnt; j++) { i = (start + j) % TL; s = s (j ? "," : "") (TL_u[f, i] + 0) }
		s = s "],\"ping\":" ((F_ping[f] == "" || F_ping[f] == "x") ? "null" : F_ping[f] + 0) ",\"tl_p\":["
		n = F_tpn[f] + 0; cnt = (n < TL) ? n : TL; start = (n < TL) ? 0 : n % TL
		for (j = 0; j < cnt; j++) { i = (start + j) % TL; s = s (j ? "," : "") (TP[f, i] + 0) }
		s = s "],\"marks\":["
		start = (M_n[f] > 8) ? M_n[f] - 7 : 1
		for (j = start; j <= M_n[f] + 0; j++) s = s (j > start ? "," : "") "{\"t\":" M_t[f, j] ",\"k\":\"" M_kind[f, j] "\",\"x\":\"" clean(M_txt[f, j]) "\"}"
		s = s "]}"
		txt = txt sprintf("LIVE  %s:%s  %s  %s\n", ip, F_rport[f], loc, clean(ga[7]))
		txt = txt sprintf("  in match %s   device %s   ping %s ms\n", fmtdur(now - F_first[f]), F_lip[f], ((F_ping[f] == "" || F_ping[f] == "x") ? "n/a" : F_ping[f]))
		txt = txt sprintf("  server: %s updates/s, jitter %s ms, late %s%%, missing %s%%, freezes %d\n", jnum(L_rate[kd]), jnum(L_jit[kd]), jnum(L_late[kd]), jnum(L_lost[kd]), S_frz[kd] + 0)
		txt = txt sprintf("  your PC: %s sends/s, jitter %s ms, hitches %d\n", jnum(L_rate[ku]), jnum(L_jit[ku]), S_frz[ku] + 0)
		if ((ip in REP_n) && REP_n[ip] > 0) txt = txt sprintf("  seen before: rated %d/100 over %d match(es)\n", REP_sum[ip] / REP_n[ip], REP_n[ip])
	}
	s = s "],\"candidates\":" cand ",\"flows\":" NFLOW "}"
	if (txt == "") txt = "No match in progress. Watching " NFLOW " UDP flow(s).\n"
	# with nothing to show, refresh the files every five seconds, not every one: each refresh starts a shell.
	# The dashboard calls the service stopped only after twenty seconds of silence.
	if (first && cand == 0) { if (ST_idle && now - ST_last < 5) return; ST_idle = 1 } else ST_idle = 0
	ST_last = now
	print s > sf; close(sf)
	printf "%s", txt > tf; close(tf)
	system("mv -f " sf " " RUN "/www/status.json; mv -f " tf " " RUN "/status.txt")
}
MW_FILE_END_1
chmod 644 "$R/usr/lib/matchwatch/analyze.awk.new"
mv -f "$R/usr/lib/matchwatch/analyze.awk.new" "$R/usr/lib/matchwatch/analyze.awk"
cat > "$R/usr/lib/matchwatch/report.awk.new" <<'MW_FILE_END_2'
# matchwatch history reports. Input: sessions.tsv
# MODE = hist_txt | srv_txt | dc_txt | hist_json | srv_json | dc_json | dc_prefixes
#        | dc_key | dc_others | dc_recent | dc_last | lobby     (KEY = datacentre key, STAY = key being kept to)
#        | regions_txt | regions_json                             (REG = measured regions file)
#        | dc_loc | area_others | area_recent      (STAYF = file of places being kept to; PLACE = one of them)
#        | hours_txt | recap_txt | games_txt        (GAMES, GAMESL = game label files)
# ARG = count, server ip, or datacentre number ; BLOCK = blocklist file
#
# columns: 1 start 2 dur 3 analysed 4 device 5 ip 6 port 7 cc 8 city 9 org 10 asn
# 11 tick 12 d_jit 13 d_late 14 d_lost 15 d_clump 16 d_freeze 17 d_rough
# 18 up_rate 19 up_jit 20 up_hitch 21 far_kind 22 far_med 23 far_jit 24 far_loss
# 25 near_med 26 near_jit 27 near_loss 28 lan_med 29 lan_jit 30 lan_loss
# 31 s_server 32 s_route 33 s_line 34 s_pc 35 overall 36 rating 37 counted
# 38 code 39 verdict 40 lat 41 lon 42 country 43 wan_avg 44 wan_peak 45 hops
# 46 marks 47 marks_summary 48 qos_class

function q(s) { gsub(/["\\]/, " ", s); return "\"" s "\"" }
function jn(x) { return (x == "-" || x == "") ? "null" : x + 0 }
function where(i,   s) { s = (CITY[i] != "-" ? CITY[i] : ""); if (CC[i] != "-") s = s (s != "" ? ", " : "") CC[i]; return s }

BEGIN {
	FS = "\t"
	if (STAYF != "") { while ((getline l < STAYF) > 0) { if (split(l, rr, "\t") >= 4) { nsp++; for (j = 1; j <= 5; j++) SP[nsp, j] = rr[j] } } close(STAYF) }
	load_games(GAMESL); load_games(GAMES)
	if (REG != "") { while ((getline l < REG) > 0) { nreg++; split(l, rr, "\t"); for (j = 1; j <= 11; j++) RG[nreg, j] = rr[j] } close(REG) }
	if (BLOCK != "") {
		while ((getline l < BLOCK) > 0) {
			split(l, b, "\t"); BLK[b[1]] = 1
			if (b[1] ~ /\/24$/) { split(b[1], o, "."); BLKP[o[1] "." o[2] "." o[3]] = 1 }
		}
		close(BLOCK)
	}
}
NF >= 39 {
	n++
	for (i = 1; i <= NF; i++) R[n, i] = $i
	CC[n] = $7; CITY[n] = $8
	ip = $5
	if (!(ip in S_n)) { order[++ns] = ip; S_n[ip] = 0 }
	S_n[ip]++; S_last[ip] = $1; S_cc[ip] = $7; S_city[ip] = $8; S_org[ip] = $9
	S_port[ip] = $6; S_asn[ip] = $10; if (known($40) && known($41)) { S_lat[ip] = $40; S_lon[ip] = $41 }
	S_tick[ip] += $11; S_secs[ip] += $2
	if ($22 != "-") { S_ping[ip] += $22; S_pingn[ip]++ }
	if ($37 == 1) { S_rn[ip]++; S_rsum[ip] += $36 }
	S_all[ip] += $36
	if (!(ip in S_worst) || $36 < S_worst[ip]) S_worst[ip] = $36
	# datacentre = same network operator in the same city (or the /24 when the location is unknown)
	dk = ($8 != "-" && $10 != "-") ? $10 "|" $8 "|" $7 : p24(ip)
	if (!(dk in D_n)) { dorder[++nd] = dk; D_n[dk] = 0; D_name[dk] = ($8 != "-" ? $8 ", " $7 " - " $9 : p24(ip) ".0/24") }
	D_n[dk]++; D_secs[dk] += $2; D_all[dk] += $36
	if ($37 == 1) { D_rn[dk]++; D_rsum[dk] += $36; D_hist[dk, D_rn[dk]] = $36 }
	LASTDK = dk; LASTPFX = p24(ip)
	if (known($40) && known($41)) { D_lat[dk] += $40; D_lon[dk] += $41; D_ln[dk]++ }
	pl = place_of($40, $41, $7); io = (pl == "") ? "" : (pl > 0 ? 1 : 0); D_cc[dk] = $7
	if (pl > 0 && $37 == 1) PH[pl, ++PN[pl]] = $36
	if (io == 0 && is_game_port($6, $9 " " $10) && !(p24(ip) in OUT_seen)) { OUT_seen[p24(ip)] = 1; OUT[++nout] = p24(ip) ".0/24" }
	if (io == 1 && $37 == 1) IN_hist[++nin] = $36
	if ($37 == 1) { hh = strftime("%H", $1) + 0; HR_n[hh]++; HR_s[hh] += $36 }
	g = game_of($6, $9 " " $10); if (!(g in G_n)) gorder[++ngs] = g; G_n[g]++; G_secs[g] += $2; G_port[g] = $6
	if (nreg > 0) { rc = region_of($40, $41); if (rc != "") { RP_n[rc]++; if ($37 == 1) { RP_rn[rc]++; RP_rs[rc] += $36 } if ($22 != "-") { RP_p[rc] += $22; RP_pn[rc]++ } } }
	if ($22 != "-") { D_ping[dk] += $22; D_pingn[dk]++ }
	if (!((dk, ip) in D_hasip)) { D_hasip[dk, ip] = 1; D_srv[dk]++ }
	if (!((dk, p24(ip)) in D_haspfx)) { D_haspfx[dk, p24(ip)] = 1; D_pfx[dk, ++D_npfx[dk]] = p24(ip) }
	if (!(dk in D_worst) || $36 < D_worst[dk]) D_worst[dk] = $36
}
function dstay(k) { return (D_ln[k] > 0 && inside(D_lat[k] / D_ln[k], D_lon[k] / D_ln[k], D_cc[k]) == 1) }
function dblocked(k,   i) { for (i = 1; i <= D_npfx[k]; i++) if (!(D_pfx[k, i] in BLKP)) return 0; return 1 }
function p24(ip,   o) { split(ip, o, "."); return o[1] "." o[2] "." o[3] }
function blocked(ip) { return ((ip in BLK) || (p24(ip) in BLKP)) }
function drating(k) { return (D_rn[k] > 0) ? int(D_rsum[k] / D_rn[k] + 0.5) : int(D_all[k] / D_n[k] + 0.5) }
# Distances are compared squared, and cosine is a short series, because BusyBox awk is often built without maths functions.
function cosd(deg,   x, x2) { x = deg * 0.0174533; x2 = x * x; return 1 - x2 / 2 + x2 * x2 / 24 - x2 * x2 * x2 / 720 }
function km2(lat1, lon1, lat2, lon2,   dx, dy) { dy = (lat2 - lat1) * 111.2; dx = (lon2 - lon1) * 111.2 * cosd((lat1 + lat2) / 2); return dx * dx + dy * dy }
function sc(s) { gsub(/[^A-Za-z0-9 .:,()&+-]/, " ", s); return (s == "-" ? "" : s) }
function known(x) { return (x != "" && x != "-") }
# is this point inside the place being kept to? "" when stay mode is off or the point is unknown
# The pool is a list of places. Each is a circle (lat, lon, km) or a set of countries ("GB,IE").
# place_of: which place a point falls in (0 = none, "" = can't tell, or stay mode is off)
function place_of(lat, lon, cc,   i, unk) {
	if (nsp == 0) return ""
	unk = 0
	for (i = 1; i <= nsp; i++) {
		if (SP[i, 5] != "" && SP[i, 5] != "-") { if (!known(cc)) unk = 1; else if (index("," SP[i, 5] ",", "," cc ",") > 0) return i }
		else if (!known(lat) || !known(lon)) unk = 1
		else if (km2(lat, lon, SP[i, 2], SP[i, 3]) <= SP[i, 4] * SP[i, 4]) return i
	}
	return unk ? "" : 0
}
function inside(lat, lon, cc,   p) { p = place_of(lat, lon, cc); return (p == "") ? "" : (p > 0 ? 1 : 0) }
# Labels: name|ports|kind|hosts (see games.list). which_label() gives the first label whose port range
# holds this port and, where the label names hosts, whose words appear in this server's org or AS.
function which_label(port, host,   i, k, a, lo, r, w, n, j, ok) {
	host = tolower(host)
	for (i = 1; i <= ngame; i++) {
		if (GM[i, 4] != "") {
			ok = 0; n = split(tolower(GM[i, 4]), w, ",")
			for (j = 1; j <= n; j++) if (w[j] != "" && index(host, w[j]) > 0) ok = 1
			if (!ok) continue
		}
		k = split(GM[i, 2], a, ",")
		for (lo = 1; lo <= k; lo++) { if (a[lo] ~ /-/) { split(a[lo], r, "-"); if (port + 0 >= r[1] + 0 && port + 0 <= r[2] + 0) return i } else if (a[lo] + 0 == port + 0) return i }
	}
	return 0
}
function game_of(port, host,   i) { i = which_label(port, host); return i ? GM[i, 1] : "Game on port " port }
function load_games(file,   l, g) { if (file == "") return; while ((getline l < file) > 0) { if (l ~ /^#/ || l == "") continue; split(l, g, "|"); ngame++; GM[ngame, 1] = g[1]; GM[ngame, 2] = g[2]; GM[ngame, 3] = g[3]; GM[ngame, 4] = g[4] } close(file) }
# is this server labelled as a game (not voice chat, not unlabelled)? Only those are ever blocked by stay mode.
function is_game_port(port, host,   i) { i = which_label(port, host); return i ? (GM[i, 3] != "voice") : 0 }
# which measured region is this match's server in? nearest, within 150 km
function region_of(lat, lon,   i, best, bd, d) {
	if (!known(lat) || !known(lon)) return ""
	best = ""; bd = 150 * 150
	for (i = 1; i <= nreg; i++) { d = km2(lat, lon, RG[i, 5], RG[i, 6]); if (d < bd) { bd = d; best = RG[i, 1] } }
	return best
}
function srating(ip) { return (S_rn[ip] > 0) ? int(S_rsum[ip] / S_rn[ip] + 0.5) : int(S_all[ip] / S_n[ip] + 0.5) }

END {
	# Where each game plays: one entry per game and server network (a /24), from your matches, from the
	# servers the game tried without your playing on them (TRIED), and from what others shared (SHARED).
	#   ARG = share : game|network|city|country|host|lat|lon|matches|rating   (your own only, for a share file)
	#   ARG = json  : grouped by game and place, for the dashboard; "in" says whether the place is in the stay pool
	if (MODE == "gameplaces") {
		for (i = 1; i <= n; i++) {
			if (!is_game_port(R[i, 6], R[i, 9] " " R[i, 10])) continue
			g = game_of(R[i, 6], R[i, 9] " " R[i, 10]); k = g SUBSEP p24(R[i, 5])
			if (!(k in GPs)) { GPs[k] = 1; gpo[++ngp] = k; GPm[k] = 1 }
			GPcity[k] = R[i, 8]; GPcc[k] = R[i, 7]; GPorg[k] = R[i, 9]; if (known(R[i, 40]) && known(R[i, 41])) { GPla[k] = R[i, 40]; GPlo[k] = R[i, 41] }
			GPn[k]++; if (R[i, 37] == 1) { GPrn[k]++; GPrs[k] += R[i, 36] }
		}
		if (TRIED != "") { while ((getline l < TRIED) > 0) {
			if (split(l, t, "\t") < 8 || !is_game_port(t[2], t[5] " " t[6])) continue
			g = game_of(t[2], t[5] " " t[6]); k = g SUBSEP t[1]
			if (!(k in GPs)) { GPs[k] = 1; gpo[++ngp] = k; GPm[k] = 1; GPcity[k] = t[3]; GPcc[k] = t[4]; GPorg[k] = t[5]; if (known(t[7]) && known(t[8])) { GPla[k] = t[7]; GPlo[k] = t[8] } }
		} close(TRIED) }
		if (ARG == "share") {
			for (i = 1; i <= ngp; i++) { k = gpo[i]; split(k, a, SUBSEP)
				printf "%s|%s.0/24|%s|%s|%s|%s|%s|%d|%s\n", sc(a[1]), a[2], sc(GPcity[k]), (GPcc[k] ~ /^[A-Z][A-Z]$/ ? GPcc[k] : "-"), sc(GPorg[k]), ((k in GPla) ? GPla[k] : "-"), ((k in GPlo) ? GPlo[k] : "-"), GPn[k], (GPrn[k] ? sprintf("%.0f", GPrs[k] / GPrn[k]) : "")
			}
			exit
		}
		if (SHARED != "") { while ((getline l < SHARED) > 0) {
			if (split(l, t, "\t") < 9) continue
			k = t[1] SUBSEP substr(t[2], 1, length(t[2]) - 5)
			if (k in GPs) continue
			GPs[k] = 1; gpo[++ngp] = k; GPm[k] = 0; GPcity[k] = t[3]; GPcc[k] = t[4]; GPorg[k] = t[5]; if (known(t[6]) && known(t[7])) { GPla[k] = t[6]; GPlo[k] = t[7] }
			GPn[k] = t[8] + 0; if (t[9] != "") { GPrn[k] = 1; GPrs[k] = t[9] + 0 }
		} close(SHARED) }
		# group the networks by game, city, country and who shared them
		for (i = 1; i <= ngp; i++) {
			k = gpo[i]; split(k, a, SUBSEP)
			gk = a[1] SUBSEP GPcity[k] SUBSEP GPcc[k] SUBSEP GPm[k]
			if (!(gk in GG)) { GG[gk] = 1; ggo[++ngg] = gk; Gg[gk] = a[1]; Gcity[gk] = GPcity[k]; Gcc[gk] = GPcc[k]; Gorg[gk] = GPorg[k]; Gm[gk] = GPm[k] }
			Gnet[gk]++; if (Gnet[gk] <= 12) Gnets[gk] = Gnets[gk] (Gnet[gk] > 1 ? "," : "") "\"" a[2] ".0/24\""
			Gn[gk] += GPn[k]; if (GPrn[k]) { Grn[gk] += GPrn[k]; Grs[gk] += GPrs[k] }
			if (k in GPla) { Gla[gk] = GPla[k]; Glo[gk] = GPlo[k] }
		}
		printf "["
		for (i = 1; i <= ngg; i++) {
			gk = ggo[i]; pl = (nsp > 0) ? place_of(((gk in Gla) ? Gla[gk] : "-"), ((gk in Glo) ? Glo[gk] : "-"), Gcc[gk]) : ""
			printf "%s{\"game\":%s,\"city\":%s,\"cc\":%s,\"org\":%s,\"networks\":%d,\"nets\":[%s],\"matches\":%d,\"rating\":%s,\"mine\":%s,\"in\":%s,\"lat\":%s,\"lon\":%s}", (i > 1 ? "," : ""),
				q(Gg[gk]), q(Gcity[gk] == "-" ? "" : Gcity[gk]), q(Gcc[gk] == "-" ? "" : Gcc[gk]), q(Gorg[gk] == "-" ? "" : Gorg[gk]), Gnet[gk], Gnets[gk], Gn[gk],
				(Grn[gk] ? int(Grs[gk] / Grn[gk] + 0.5) : "null"), (Gm[gk] ? "true" : "false"), (pl == "" ? "null" : (pl > 0 ? "true" : "false")), ((gk in Gla) ? Gla[gk] + 0 : "null"), ((gk in Glo) ? Glo[gk] + 0 : "null")
		}
		print "]"
		exit
	}
	# servers for a share file: server|game|city|country|host|rating|matches|latitude|longitude, favourites only
	# (ARG = favourites) or every server with a tenth field saying whether it is a favourite (ARG = allservers)
	if (MODE == "share_servers") {
		while ((getline l < FAVF) > 0) { split(l, ff, "\t"); if (ff[1] != "") { FV[ff[1]] = 1; fo[++nf] = ff[1]; FG[ff[1]] = ff[2]; FC[ff[1]] = ff[3]; FCC[ff[1]] = ff[4]; FO[ff[1]] = ff[5] } }
		close(FAVF)
		for (i = 1; i <= ns; i++) {
			ip = order[i]; if (ARG != "allservers" && !(ip in FV)) continue
			printf "%s|%s|%s|%s|%s|%s|%d|%s|%s%s\n", ip, sc(game_of(S_port[ip], S_org[ip] " " S_asn[ip])), sc(S_city[ip]), (S_cc[ip] ~ /^[A-Z][A-Z]$/ ? S_cc[ip] : "-"), sc(S_org[ip]),
				(S_rn[ip] ? sprintf("%.0f", S_rsum[ip] / S_rn[ip]) : ""), S_rn[ip], ((ip in S_lat) ? S_lat[ip] : "-"), ((ip in S_lon) ? S_lon[ip] : "-"), (ARG == "allservers" ? "|" ((ip in FV) ? 1 : 0) : "")
			shown[ip] = 1
		}
		for (i = 1; i <= nf; i++) { ip = fo[i]; if (ip in shown) continue; printf "%s|%s|%s|%s|%s||0|-|-%s\n", ip, sc(FG[ip]), sc(FC[ip]), (FCC[ip] ~ /^[A-Z][A-Z]$/ ? FCC[ip] : "-"), sc(FO[ip]), (ARG == "allservers" ? "|1" : "") }
		exit
	}
	if (MODE == "hist_txt") {
		lim = 15; only = ""
		if (ARG ~ /^[0-9]+$/) lim = ARG + 0; else if (ARG != "") { only = ARG; lim = 100000 }
		if (n == 0) { print "No matches recorded yet."; exit }
		printf "%-16s %-18s %-16s %-18s %5s %6s %6s %6s %7s %6s  %s\n", "When", "Game", "Server", "Where", "Rate", "Jitter", "Miss%", "Ping", "Overall", "Server", "Finding"
		shown = 0
		for (i = n; i >= 1 && shown < lim; i--) {
			if (only != "" && R[i, 5] != only) continue
			printf "%-16s %-18s %-16s %-18s %5s %6s %6s %6s %7s %6s  %s\n", strftime("%Y-%m-%d %H:%M", R[i, 1]), substr(game_of(R[i, 6], R[i, 9] " " R[i, 10]), 1, 18), R[i, 5], substr(where(i), 1, 18), R[i, 11], R[i, 12], R[i, 14], R[i, 22], R[i, 35], R[i, 36], R[i, 38]
			shown++
		}
		exit
	}
	if (MODE == "area_others") { for (i = 1; i <= nout; i++) print OUT[i]; exit }
	if (MODE == "area_recent") {
		t = 0; j = 0
		if (PLACE != "") { for (i = PN[PLACE] + 0; i >= 1 && j < 3; i--) { t += PH[PLACE, i]; j++ } }
		else { for (i = nin; i >= 1 && j < 3; i--) { t += IN_hist[i]; j++ } }
		print (j > 0 ? int(t / j + 0.5) : "-"), j; exit
	}
	if (MODE == "hours_txt") {
		if (n == 0) { print "No matches recorded yet."; exit }
		print "Hour     Matches  Average server rating"
		for (i = 0; i < 24; i++) if (HR_n[i] > 0) {
			a = int(HR_s[i] / HR_n[i] + 0.5); bar = ""; for (j = 0; j < int(a / 5); j++) bar = bar "#"
			printf "%02d:00    %5d    %3d  %s\n", i, HR_n[i], a, bar
		}
		print ""; print "Only matches that count towards ratings are included. A few matches per hour are needed before this means much."
		exit
	}
	if (MODE == "games_txt") {
		if (ngs == 0) { print "No games seen yet."; exit }
		printf "%-34s %8s %10s %s\n", "Game", "Matches", "Time", "Server port (latest)"
		for (i = 1; i <= ngs; i++) { g = gorder[i]; printf "%-34s %8d %9dm %s\n", substr(g, 1, 34), G_n[g], G_secs[g] / 60, G_port[g] }
		print ""; print "Label one with: matchwatch game name <server port> <name>"
		exit
	}
	if (MODE == "recap_txt") {
		if (n == 0) { print "No matches recorded yet."; exit }
		# the latest session: matches ending with the newest, with gaps of under 90 minutes between them
		first = n
		for (i = n; i > 1; i--) { if (R[i, 1] - (R[i - 1, 1] + R[i - 1, 2]) > 5400) break; first = i - 1 }
		c = 0; t = 0; secs = 0; best = first; worst = first; fl = 0
		for (i = first; i <= n; i++) {
			c++; t += R[i, 35]; secs += R[i, 2]; fl += R[i, 46]
			if (R[i, 35] > R[best, 35]) best = i
			if (R[i, 35] < R[worst, 35]) worst = i
			FC[R[i, 38]]++
			gg = game_of(R[i, 6], R[i, 9] " " R[i, 10]); if (!(gg in RG_n)) rgo[++nrg] = gg; RG_n[gg]++
		}
		gs = ""; for (i = 1; i <= nrg; i++) gs = gs (i > 1 ? ", " : "") rgo[i] " (" RG_n[rgo[i]] ")"
		printf "Latest session: %d match%s, %d minutes of play, %s to %s.\nGames: %s.\n", c, (c == 1 ? "" : "es"), secs / 60, strftime("%d %b %H:%M", R[first, 1]), strftime("%H:%M", R[n, 1] + R[n, 2]), gs
		printf "Average %d/100. Best: %s (%d). Worst: %s (%d, %s).\n", t / c, (R[best, 8] != "-" ? R[best, 8] : R[best, 5]), R[best, 35], (R[worst, 8] != "-" ? R[worst, 8] : R[worst, 5]), R[worst, 35], R[worst, 38]
		s = ""; for (k in FC) s = s (s != "" ? ", " : "") FC[k] " " k
		print "Findings: " s "."
		if (fl > 0) print "You flagged " fl " moment" (fl == 1 ? "" : "s") ". See each match's report for what was happening."
		exit
	}
	if (MODE ~ /^regions_/) {
		# nearest first; regions that did not answer go last
		for (i = 1; i <= nreg; i++) ri[i] = i
		for (i = 1; i <= nreg; i++) for (j = i + 1; j <= nreg; j++) {
			a = (RG[ri[i], 8] == "-") ? 99999 : RG[ri[i], 8] + 0; b2 = (RG[ri[j], 8] == "-") ? 99999 : RG[ri[j], 8] + 0
			if (b2 < a) { t = ri[i]; ri[i] = ri[j]; ri[j] = t }
		}
		if (MODE == "regions_txt") {
			if (nreg == 0) { print "No regions measured yet. Run: matchwatch regions measure"; exit }
			printf "%-16s %-3s %-14s %8s %8s %8s %7s %11s\n", "Region", "", "Area", "Ping ms", "Jitter", "Matches", "Rating", "Match ping"
			for (i = 1; i <= nreg; i++) { r = ri[i]; c = RG[r, 1]
				printf "%-16s %-3s %-14s %8s %8s %8s %7s %11s  %s\n", RG[r, 2], RG[r, 3], RG[r, 4], (RG[r, 8] == "-" ? "no reply" : RG[r, 8]), RG[r, 9], (RP_n[c] + 0), (RP_rn[c] > 0 ? int(RP_rs[c] / RP_rn[c] + 0.5) : "-"), (RP_pn[c] > 0 ? sprintf("%.1f", RP_p[c] / RP_pn[c]) : "-"), (inside(RG[r, 5], RG[r, 6], RG[r, 3]) == 1 ? "STAYING HERE" : "")
			}
			print ""
			print "Pings are to the host's test server in each datacentre, measured " strftime("%d %b %H:%M", RG[1, 11]) "."
			exit
		}
		printf "["
		for (i = 1; i <= nreg; i++) { r = ri[i]; c = RG[r, 1]
			printf "%s{\"code\":%s,\"city\":%s,\"cc\":%s,\"area\":%s,\"ping\":%s,\"jit\":%s,\"ts\":%d,\"matches\":%d,\"rating\":%s,\"matchping\":%s,\"stay\":%s,\"lat\":%s,\"lon\":%s}", (i > 1 ? "," : ""), q(c), q(RG[r, 2]), q(RG[r, 3]), q(RG[r, 4]), jn(RG[r, 8]), jn(RG[r, 9]), RG[r, 11], RP_n[c] + 0, (RP_rn[c] > 0 ? int(RP_rs[c] / RP_rn[c] + 0.5) : "null"), (RP_pn[c] > 0 ? sprintf("%.1f", RP_p[c] / RP_pn[c]) : "null"), (inside(RG[r, 5], RG[r, 6], RG[r, 3]) == 1 ? "true" : "false")
		}
		print "]"
		exit
	}
	if (MODE == "dc_recent") {          # average of the last three counted matches in one datacentre
		c = D_rn[KEY] + 0; t = 0; j = 0
		for (i = c; i >= 1 && j < 3; i--) { t += D_hist[KEY, i]; j++ }
		print (j > 0 ? int(t / j + 0.5) : "-"), j
		exit
	}
	if (MODE == "dc_last") { print LASTDK "\t" LASTPFX ".0/24"; exit }
	if (MODE == "dc_others") {          # every /24 seen in datacentres other than KEY
		for (i = 1; i <= nd; i++) { k = dorder[i]; if (k == KEY) continue
			for (j = 1; j <= D_npfx[k]; j++) print D_pfx[k, j] ".0/24" }
		exit
	}
	if (MODE == "lobby") {              # what do we know about this server and its datacentre? ARG = ip, KEY = datacentre key
		print "srv_n=" (S_rn[ARG] + 0)
		if (S_rn[ARG] > 0) print "srv_rating=" int(S_rsum[ARG] / S_rn[ARG] + 0.5)
		if (KEY in D_n) {
			print "dc_name=" D_name[KEY]; print "dc_n=" D_n[KEY]; print "dc_rating=" drating(KEY)
			if (D_pingn[KEY] > 0) printf "dc_ping=%.1f\n", D_ping[KEY] / D_pingn[KEY]
		}
		best = ""
		for (i = 1; i <= nd; i++) { k = dorder[i]
			if (D_pingn[k] < 1 || drating(k) < 60) continue
			if (best == "" || D_ping[k] / D_pingn[k] < D_ping[best] / D_pingn[best]) best = k }
		if (best != "") { print "best_key=" best; print "best_name=" D_name[best]; printf "best_ping=%.1f\n", D_ping[best] / D_pingn[best] }
		exit
	}
	if (MODE ~ /^dc_/) {
		for (i = 1; i <= nd; i++) di[i] = dorder[i]
		for (i = 1; i <= nd; i++) for (j = i + 1; j <= nd; j++) if (drating(di[j]) < drating(di[i])) { t = di[i]; di[i] = di[j]; di[j] = t }
		if (MODE == "dc_loc") { k = di[ARG + 0]; if (ARG + 0 >= 1 && ARG + 0 <= nd && D_ln[k] > 0) printf "%s\t%.3f\t%.3f\n", D_name[k], D_lat[k] / D_ln[k], D_lon[k] / D_ln[k]; exit }
		if (MODE == "dc_key") { if (ARG + 0 >= 1 && ARG + 0 <= nd) print di[ARG + 0] "\t" D_name[di[ARG + 0]]; exit }
		if (MODE == "dc_prefixes") {
			k = di[ARG + 0]
			if (ARG + 0 < 1 || ARG + 0 > nd) exit
			print D_name[k]
			for (i = 1; i <= D_npfx[k]; i++) print D_pfx[k, i] ".0/24"
			exit
		}
		if (MODE == "dc_txt") {
			if (nd == 0) { print "No datacentres seen yet."; exit }
			printf "%2s  %-44s %7s %7s %6s %5s %6s %s\n", "#", "Datacentre", "Matches", "Servers", "Rating", "Worst", "Ping", ""
			for (i = 1; i <= nd; i++) { k = di[i]
				printf "%2d  %-44s %7d %7d %6d %5d %6s %s\n", i, substr(D_name[k], 1, 44), D_n[k], D_srv[k], drating(k), D_worst[k], (D_pingn[k] > 0 ? sprintf("%.1f", D_ping[k] / D_pingn[k]) : "-"), (dstay(k) ? "STAYING HERE" : (dblocked(k) ? "BLOCKED" : ""))
			}
			print ""
			print "Ratings need a few matches each before they mean much. Block one with: matchwatch block-dc <#>"
			exit
		}
		printf "["
		for (i = 1; i <= nd; i++) { k = di[i]
			printf "%s{\"n\":%d,\"name\":%s,\"matches\":%d,\"counted\":%d,\"servers\":%d,\"rating\":%d,\"worst\":%d,\"ping\":%s,\"minutes\":%d,\"blocked\":%s,\"stay\":%s}", (i > 1 ? "," : ""), i, q(D_name[k]), D_n[k], D_rn[k] + 0, D_srv[k], drating(k), D_worst[k], (D_pingn[k] > 0 ? sprintf("%.1f", D_ping[k] / D_pingn[k]) : "null"), D_secs[k] / 60, (dblocked(k) ? "true" : "false"), (dstay(k) ? "true" : "false")
		}
		print "]"
		exit
	}
	# servers sorted worst first (simple selection sort; server counts are small)
	for (i = 1; i <= ns; i++) idx[i] = order[i]
	for (i = 1; i <= ns; i++) for (j = i + 1; j <= ns; j++) if (srating(idx[j]) < srating(idx[i])) { t = idx[i]; idx[i] = idx[j]; idx[j] = t }
	if (MODE == "srv_txt") {
		if (ns == 0) { print "No servers seen yet."; exit }
		printf "%-16s %-20s %-22s %7s %6s %5s %6s %s\n", "Server", "Where", "Host", "Matches", "Rating", "Worst", "Ping", ""
		for (i = 1; i <= ns; i++) {
			ip = idx[i]; w = (S_city[ip] != "-" ? S_city[ip] ", " : "") (S_cc[ip] != "-" ? S_cc[ip] : "")
			printf "%-16s %-20s %-22s %7d %6d %5d %6s %s\n", ip, substr(w, 1, 20), substr(S_org[ip], 1, 22), S_n[ip], srating(ip), S_worst[ip], (S_pingn[ip] > 0 ? sprintf("%.1f", S_ping[ip] / S_pingn[ip]) : "-"), (blocked(ip) ? "BLOCKED" : "")
		}
		exit
	}
	if (MODE == "srv_json") {
		printf "["
		for (i = 1; i <= ns; i++) {
			ip = idx[i]
			printf "%s{\"ip\":%s,\"cc\":%s,\"city\":%s,\"org\":%s,\"matches\":%d,\"counted\":%d,\"rating\":%d,\"worst\":%d,\"tick\":%.1f,\"ping\":%s,\"last\":%d,\"minutes\":%d,\"blocked\":%s,\"in\":%s,\"lat\":%s,\"lon\":%s}", (i > 1 ? "," : ""), q(ip), q(S_cc[ip]), q(S_city[ip]), q(S_org[ip]), S_n[ip], S_rn[ip] + 0, srating(ip), S_worst[ip], S_tick[ip] / S_n[ip], (S_pingn[ip] > 0 ? sprintf("%.1f", S_ping[ip] / S_pingn[ip]) : "null"), S_last[ip], S_secs[ip] / 60, (blocked(ip) ? "true" : "false"), ((w = inside(S_lat[ip], S_lon[ip], S_cc[ip])) == "" ? "null" : (w ? "true" : "false")), ((ip in S_lat) ? S_lat[ip] + 0 : "null"), ((ip in S_lon) ? S_lon[ip] + 0 : "null")
		}
		print "]"
		exit
	}
	if (MODE == "hist_json") {
		printf "["
		c = 0
		for (i = n; i >= 1 && c < 200; i--) {
			printf "%s{\"game\":%s,\"start\":%d,\"dur\":%d,\"analysed\":%d,\"device\":%s,\"ip\":%s,\"port\":%d,\"cc\":%s,\"city\":%s,\"org\":%s,\"asn\":%s", (c ? "," : ""), q(game_of(R[i, 6], R[i, 9] " " R[i, 10])), R[i, 1], R[i, 2], R[i, 3], q(R[i, 4]), q(R[i, 5]), R[i, 6], q(R[i, 7]), q(R[i, 8]), q(R[i, 9]), q(R[i, 10])
			printf ",\"tick\":%s,\"jit\":%s,\"late\":%s,\"lost\":%s,\"clump\":%s,\"freeze\":%s,\"rough\":%s", jn(R[i, 11]), jn(R[i, 12]), jn(R[i, 13]), jn(R[i, 14]), jn(R[i, 15]), jn(R[i, 16]), jn(R[i, 17])
			printf ",\"uprate\":%s,\"upjit\":%s,\"hitch\":%s,\"farkind\":%s,\"ping\":%s,\"pingjit\":%s,\"pingloss\":%s", jn(R[i, 18]), jn(R[i, 19]), jn(R[i, 20]), q(R[i, 21]), jn(R[i, 22]), jn(R[i, 23]), jn(R[i, 24])
			printf ",\"nearping\":%s,\"nearjit\":%s,\"nearloss\":%s,\"lanping\":%s", jn(R[i, 25]), jn(R[i, 26]), jn(R[i, 27]), jn(R[i, 28])
			printf ",\"s_server\":%s,\"s_route\":%s,\"s_line\":%s,\"s_pc\":%s,\"overall\":%s,\"rating\":%s,\"counted\":%s,\"code\":%s,\"verdict\":%s,\"hops\":%s,\"marks\":%s,\"marksum\":%s,\"qos\":%s}", jn(R[i, 31]), jn(R[i, 32]), jn(R[i, 33]), jn(R[i, 34]), jn(R[i, 35]), jn(R[i, 36]), jn(R[i, 37]), q(R[i, 38]), q(R[i, 39]), q(R[i, 45]), jn(R[i, 46]), q(R[i, 47]), q(R[i, 48])
			c++
		}
		print "]"
	}
}
MW_FILE_END_2
chmod 644 "$R/usr/lib/matchwatch/report.awk.new"
mv -f "$R/usr/lib/matchwatch/report.awk.new" "$R/usr/lib/matchwatch/report.awk"
cat > "$R/usr/lib/matchwatch/public.html.new" <<'MW_FILE_END_3'
<!DOCTYPE html>
<html lang="en">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<title>matchwatch</title>
<style>
html, body { margin: 0; }
body { background: #eef2ea; }
@media (prefers-color-scheme: dark) { body { background: #0f2a2b; } }
</style>
</head>
<body>
<!-- The dashboard without login: view only, plus "I felt that". Served at /matchwatch/ when the
     setting is on. The full dashboard, with its buttons, is in LuCI under Services, MatchWatch. -->
<div id="mw"></div>
<script src="/luci-static/resources/matchwatch/dashboard.js"></script>
<script>
MatchwatchDashboard(document.getElementById("mw"), {
	css: "/luci-static/resources/matchwatch/dashboard.css",
	readonly: true,
	full: true,
	get: function (file) {
		return fetch("data/" + file, { cache: "no-store" }).then(function (r) { if (!r.ok) throw 0; return r.json(); });
	},
	act: function (p) {
		if (p.action !== "mark") return Promise.resolve({ ok: false, error: "This page is view only." });
		return fetch("/cgi-bin/matchwatch-mark", { method: "POST", cache: "no-store" }).then(function (r) { return r.json(); });
	}
});
</script>
</body>
</html>
MW_FILE_END_3
chmod 644 "$R/usr/lib/matchwatch/public.html.new"
mv -f "$R/usr/lib/matchwatch/public.html.new" "$R/usr/lib/matchwatch/public.html"
cat > "$R/usr/lib/matchwatch/config.uci.new" <<'MW_FILE_END_4'

config matchwatch 'main'
	option device_ip ''
	option geo '1'
	option pc_score '1'
	option web '0'
	option lobby_alert '1'
	option block_days '14'
	option autoblock '0'
	option stay_strict '1'
MW_FILE_END_4
chmod 644 "$R/usr/lib/matchwatch/config.uci.new"
mv -f "$R/usr/lib/matchwatch/config.uci.new" "$R/usr/lib/matchwatch/config.uci"
cat > "$R/usr/lib/matchwatch/regions.list.new" <<'MW_FILE_END_5'
# Vultr datacentre regions and their public ping test hosts.
# code|city|country code|area|latitude|longitude|host
# Call of Duty game servers seen so far are all hosted by Vultr. Add lines for other hosts if you meet them.
lon-gb|London|GB|Europe|51.51|-0.13|lon-gb-ping.vultr.com
man-uk|Manchester|GB|Europe|53.48|-2.24|man-uk-ping.vultr.com
ams-nl|Amsterdam|NL|Europe|52.37|4.90|ams-nl-ping.vultr.com
par-fr|Paris|FR|Europe|48.86|2.35|par-fr-ping.vultr.com
fra-de|Frankfurt|DE|Europe|50.11|8.68|fra-de-ping.vultr.com
mxp-it|Milan|IT|Europe|45.46|9.19|mxp-it-ping.vultr.com
mad-es|Madrid|ES|Europe|40.42|-3.70|mad-es-ping.vultr.com
sto-se|Stockholm|SE|Europe|59.33|18.07|sto-se-ping.vultr.com
waw-pl|Warsaw|PL|Europe|52.23|21.01|waw-pl-ping.vultr.com
tlv-il|Tel Aviv|IL|Middle East|32.09|34.78|tlv-il-ping.vultr.com
nj-us|New Jersey|US|North America|40.74|-74.17|nj-us-ping.vultr.com
tor-ca|Toronto|CA|North America|43.65|-79.38|tor-ca-ping.vultr.com
il-us|Chicago|US|North America|41.88|-87.63|il-us-ping.vultr.com
ga-us|Atlanta|US|North America|33.75|-84.39|ga-us-ping.vultr.com
fl-us|Miami|US|North America|25.76|-80.19|fl-us-ping.vultr.com
tx-us|Dallas|US|North America|32.78|-96.80|tx-us-ping.vultr.com
wa-us|Seattle|US|North America|47.61|-122.33|wa-us-ping.vultr.com
sjo-ca-us|Silicon Valley|US|North America|37.34|-121.89|sjo-ca-us-ping.vultr.com
lax-ca-us|Los Angeles|US|North America|34.05|-118.24|lax-ca-us-ping.vultr.com
hon-hi-us|Honolulu|US|North America|21.31|-157.86|hon-hi-us-ping.vultr.com
mex-mx|Mexico City|MX|North America|19.43|-99.13|mex-mx-ping.vultr.com
sao-br|Sao Paulo|BR|South America|-23.55|-46.63|sao-br-ping.vultr.com
scl-cl|Santiago|CL|South America|-33.45|-70.67|scl-cl-ping.vultr.com
jnb-za|Johannesburg|ZA|Africa|-26.20|28.05|jnb-za-ping.vultr.com
bom-in|Mumbai|IN|Asia|19.08|72.88|bom-in-ping.vultr.com
del-in|Delhi|IN|Asia|28.61|77.21|del-in-ping.vultr.com
blr-in|Bangalore|IN|Asia|12.97|77.59|blr-in-ping.vultr.com
sgp|Singapore|SG|Asia|1.35|103.82|sgp-ping.vultr.com
hnd-jp|Tokyo|JP|Asia|35.68|139.69|hnd-jp-ping.vultr.com
osk-jp|Osaka|JP|Asia|34.69|135.50|osk-jp-ping.vultr.com
sel-kor|Seoul|KR|Asia|37.57|126.98|sel-kor-ping.vultr.com
syd-au|Sydney|AU|Oceania|-33.87|151.21|syd-au-ping.vultr.com
mel-au|Melbourne|AU|Oceania|-37.81|144.96|mel-au-ping.vultr.com
MW_FILE_END_5
chmod 644 "$R/usr/lib/matchwatch/regions.list.new"
mv -f "$R/usr/lib/matchwatch/regions.list.new" "$R/usr/lib/matchwatch/regions.list"
cat > "$R/usr/lib/matchwatch/geofeeds.list.new" <<'MW_FILE_END_6'
# Hosting companies that publish which of their address ranges is in which city (a geofeed, RFC 8805).
# With stay mode on, MatchWatch uses these to turn away every range outside your places ahead of time,
# for the gaming device's game traffic only.
#
#   name|address of the list|games it is known to host
#
# The list must be plain text with lines of: range,country code,region,city,postal code
# Add your own in /etc/matchwatch/geofeeds.local, then run: matchwatch ranges refresh
# Only add a company whose list you have opened and read. Do not add one from memory.

# Hosts every Call of Duty server seen so far. Checked 12 November 2026: about 490 ranges.
Vultr|https://geofeed.constant.com/?csv|Call of Duty
MW_FILE_END_6
chmod 644 "$R/usr/lib/matchwatch/geofeeds.list.new"
mv -f "$R/usr/lib/matchwatch/geofeeds.list.new" "$R/usr/lib/matchwatch/geofeeds.list"
cat > "$R/usr/lib/matchwatch/countries.list.new" <<'MW_FILE_END_7'
# Rough centre of each country that can be stayed on: country code|latitude|longitude
# Only used to suggest the nearest places with servers when a country in the pool has none.
# Approximate on purpose: nothing is blocked or allowed from these figures.
GB|54.0|-2.5
IE|53.2|-8.0
FR|46.6|2.4
BE|50.6|4.6
NL|52.2|5.3
LU|49.8|6.1
DE|51.1|10.4
CH|46.8|8.2
AT|47.6|14.1
ES|40.2|-3.6
PT|39.6|-8.0
IT|42.8|12.6
GR|39.0|22.0
SE|62.0|15.0
NO|62.0|10.0
DK|56.0|10.0
FI|64.0|26.0
IS|65.0|-18.5
PL|52.1|19.4
CZ|49.8|15.5
HU|47.2|19.4
RO|45.9|25.0
BG|42.7|25.5
HR|45.1|15.5
RS|44.0|20.9
UA|49.0|31.4
TR|39.0|35.2
RU|55.8|37.6
US|39.8|-98.6
CA|50.0|-97.0
MX|23.6|-102.5
BR|-10.8|-52.9
AR|-34.6|-64.0
CL|-33.5|-70.7
CO|4.6|-74.1
PE|-9.2|-75.0
AE|24.3|54.3
SA|24.0|45.0
BH|26.0|50.6
QA|25.3|51.2
IL|31.5|34.9
ZA|-29.0|24.7
EG|27.0|30.0
IN|21.0|78.0
JP|36.2|138.3
KR|36.5|127.9
SG|1.35|103.8
HK|22.3|114.2
TW|23.7|121.0
TH|15.0|101.0
MY|4.0|102.0
ID|-2.5|118.0
PH|12.9|121.8
AU|-25.3|133.8
NZ|-41.5|173.0
MW_FILE_END_7
chmod 644 "$R/usr/lib/matchwatch/countries.list.new"
mv -f "$R/usr/lib/matchwatch/countries.list.new" "$R/usr/lib/matchwatch/countries.list"
cat > "$R/usr/lib/matchwatch/places.list.new" <<'MW_FILE_END_8'
# Wider places to stay on, by country code. kind|code|name|country codes (comma separated)
# kind "area" = a named group of countries; kind "country" = one country.
area|uk-ireland|UK and Ireland|GB,IE
area|western-europe|Western Europe|GB,IE,FR,BE,NL,LU,DE,CH,AT
area|southern-europe|Southern Europe|ES,PT,IT,GR,MT,CY
area|northern-europe|Northern Europe|SE,NO,DK,FI,IS,EE,LV,LT
area|eastern-europe|Eastern Europe|PL,CZ,SK,HU,RO,BG,HR,SI,RS,UA,MD
area|europe|Europe|GB,IE,FR,BE,NL,LU,DE,CH,AT,ES,PT,IT,GR,MT,CY,SE,NO,DK,FI,IS,EE,LV,LT,PL,CZ,SK,HU,RO,BG,HR,SI,RS,UA,MD
area|north-america|North America|US,CA,MX
area|south-america|South America|BR,AR,CL,CO,PE,UY,EC
area|middle-east|Middle East|AE,SA,BH,QA,KW,OM,IL,TR,JO
area|asia|Asia|JP,KR,SG,IN,HK,TW,TH,MY,ID,PH,VN
area|oceania|Oceania|AU,NZ
area|africa|Africa|ZA,EG,NG,KE,MA
country|gb|United Kingdom|GB
country|uk|United Kingdom|GB
country|ie|Ireland|IE
country|fr|France|FR
country|be|Belgium|BE
country|nl|Netherlands|NL
country|lu|Luxembourg|LU
country|de|Germany|DE
country|ch|Switzerland|CH
country|at|Austria|AT
country|es|Spain|ES
country|pt|Portugal|PT
country|it|Italy|IT
country|gr|Greece|GR
country|se|Sweden|SE
country|no|Norway|NO
country|dk|Denmark|DK
country|fi|Finland|FI
country|is|Iceland|IS
country|pl|Poland|PL
country|cz|Czechia|CZ
country|hu|Hungary|HU
country|ro|Romania|RO
country|bg|Bulgaria|BG
country|hr|Croatia|HR
country|rs|Serbia|RS
country|ua|Ukraine|UA
country|tr|Turkey|TR
country|ru|Russia|RU
country|us|United States|US
country|ca|Canada|CA
country|mx|Mexico|MX
country|br|Brazil|BR
country|ar|Argentina|AR
country|cl|Chile|CL
country|co|Colombia|CO
country|pe|Peru|PE
country|ae|United Arab Emirates|AE
country|sa|Saudi Arabia|SA
country|bh|Bahrain|BH
country|qa|Qatar|QA
country|il|Israel|IL
country|za|South Africa|ZA
country|eg|Egypt|EG
country|in|India|IN
country|jp|Japan|JP
country|kr|South Korea|KR
country|sg|Singapore|SG
country|hk|Hong Kong|HK
country|tw|Taiwan|TW
country|th|Thailand|TH
country|my|Malaysia|MY
country|id|Indonesia|ID
country|ph|Philippines|PH
country|au|Australia|AU
country|nz|New Zealand|NZ
MW_FILE_END_8
chmod 644 "$R/usr/lib/matchwatch/places.list.new"
mv -f "$R/usr/lib/matchwatch/places.list.new" "$R/usr/lib/matchwatch/places.list"
cat > "$R/usr/lib/matchwatch/games.list.new" <<'MW_FILE_END_9'
# Labels for game servers and voice chat:   name|ports|kind|hosts
#
#   ports  the SERVER's UDP port: single ports or ranges, separated by commas
#   kind   empty = a game. "voice" = voice chat, which is never recorded and never blocked.
#   hosts  optional. Words looked for in the name of the company hosting the server (its isp, org
#          and AS name, any case). The label only matches when one is found. Use it where a port
#          range is shared with something else. It needs "Look up where servers are" switched on.
#
# The first line that matches wins, so narrow and host-checked lines come before wide ones.
# Your own names (the Tools page, or: matchwatch game name <port or lo-hi> <name>) are kept in
# /etc/matchwatch/games.local and are checked before this file.
#
# Only a labelled game is ever turned away, blocked automatically or announced by the lobby alert.
# Anything not listed is still recorded and rated, as "Game on port N", until it is given a name.
#
# Where the ports come from: publishers' own port lists where they publish one, otherwise the
# figures used by router makers and esports network guides. Many publishers do not publish server
# ports at all, several games share ranges, and games hosted player-to-player have no server port,
# so this cannot be complete. Lines marked "unconfirmed" have no publisher source.

# ---- voice chat on its own ports (checked first so a game range cannot swallow them)
Valorant voice|27016-27024,54000-54012|voice|riot,as6507
TeamSpeak|9987|voice
Mumble|64738|voice
Voice and party chat|3478-3481,5060,5062,6250|voice

# ---- games recognised by who hosts the server, because the port range is shared or very wide
Roblox|49152-65535||roblox,as22697
Valorant|7000-8000,8180-8181||riot,as6507
League of Legends|5000-5500||riot,as6507
Overwatch 2|12000-64000||blizzard,as57976
iRacing|15000-52500||iracing
War Thunder|20000-30000||gaijin
Call of Duty|3074,30000-45000||vultr,constant company,choopa,as20473

# ---- games on a narrow range of their own
Minecraft|19132-19133
Rust|28015
DayZ|2302
Palworld|8211
ARK|7777-7778
Among Us|22023
Genshin Impact|22101-22102
# unconfirmed
Escape from Tarkov|17000-17100
# unconfirmed
Rainbow Six Siege|6015,10000-10099
# unconfirmed
Battlefield|14000-14016,22990-23006,25200-25300
# unconfirmed
World of Tanks|32800-32900
Street Fighter 6|30840-30859,30870-30879

# ---- games on a wider range, or one shared with others
# Valve's own games and every game using Steam's relay network arrive on the same ports.
Steam games (Counter-Strike 2, Dota 2, Deadlock, TF2, Destiny 2)|27000-27200
# unconfirmed: Epic does not publish Fortnite's server ports
Fortnite|9000-9100
# these three share a range and cannot be told apart by port
EA Sports FC, Smite or Paladins|9101-9999
Apex Legends|37000-40000
Rocket League|7000-9000
# Call of Duty servers on a host not listed above
Call of Duty|30000-45000

# ---- everything else on high ports is taken to be voice chat (Discord uses 50000-65535)
Discord voice|50000-65535|voice
MW_FILE_END_9
chmod 644 "$R/usr/lib/matchwatch/games.list.new"
mv -f "$R/usr/lib/matchwatch/games.list.new" "$R/usr/lib/matchwatch/games.list"
cat > "$R/etc/init.d/matchwatch.new" <<'MW_FILE_END_10'
#!/bin/sh /etc/rc.common
# matchwatch service

START=95
STOP=10
USE_PROCD=1

start_service() {
	# settings from versions before 0.10.0 lived in a shell file; carry them over once
	/usr/bin/matchwatch _migrate >/dev/null 2>&1
	procd_open_instance
	procd_set_param command /usr/bin/matchwatch run
	procd_set_param respawn 3600 10 0
	procd_set_param stderr 1
	procd_close_instance
}

# Save & Apply in LuCI (or reload_config after uci commit) restarts the service with the new settings
service_triggers() {
	procd_add_reload_trigger matchwatch
}

# a stopped MatchWatch must never leave servers held: nothing would be there to let them through
stop_service() {
	nft flush set inet matchwatch hold_ports 2>/dev/null
	rm -f /tmp/matchwatch/hold.ports
}

reload_service() {
	stop
	start
}
MW_FILE_END_10
chmod 755 "$R/etc/init.d/matchwatch.new"
mv -f "$R/etc/init.d/matchwatch.new" "$R/etc/init.d/matchwatch"
cat > "$R/usr/libexec/rpcd/luci.matchwatch.new" <<'MW_FILE_END_11'
#!/bin/sh
# rpcd backend for luci-app-matchwatch: runs the dashboard's buttons.
# Two methods so LuCI's permissions can tell looking from changing:
#   read   checks, the line test, a route trace, the activity log, making a share file, the version check, and "I felt that"
#   write  updating, and anything that blocks, stays, favourites, measures, alerts, renames, clears, imports, or changes QoSmate or the device
# The work itself is done by /usr/bin/matchwatch _action, which validates every argument.

. /usr/share/libubox/jshn.sh

READ="hello mark devices doctor qos log linetest trace shareexport updatecheck"
WRITE="block unblock blockdc unblockdc stay stayoff stayadd stayrm staysuggest regions qosfix qosunfix setdevice setdeviceall testalert gamename gamedel clearhistory sharecheck shareimport shareundo shareforget shareforgetgs fav unfav forgetmatch forgetserver forgetdc update allow unallow staycircle stayset holdon holdoff"

reply() { # ok(0|1) text
	json_init
	json_add_boolean ok "$1"
	json_add_string out "$2"
	json_dump
}

case "$1" in
	list)
		echo '{"read":{"action":"str","arg":"str"},"write":{"action":"str","arg":"str","days":"str","region":"str","name":"str","data":"str"}}'
		;;
	call)
		read -r input
		json_load "$input" 2>/dev/null || { reply 0 "bad request"; exit 0; }
		json_get_var action action
		json_get_var arg arg
		json_get_var days days
		json_get_var region region
		json_get_var name name
		json_get_var data data

		case "$2" in
			read) allowed="$READ" ;;
			write) allowed="$WRITE" ;;
			*) reply 0 "unknown method"; exit 0 ;;
		esac
		case "$action" in ""|*[!a-z]*) reply 0 "unknown action"; exit 0 ;; esac
		case " $allowed " in *" $action "*) ;; *) reply 0 "unknown action"; exit 0 ;; esac

		# a share file being checked or imported goes in on standard input
		if out="$(printf '%s
' "$data" | /usr/bin/matchwatch _action "$action" "$arg" "$days" "$region" "$name" 2>&1)"; then
			reply 1 "$out"
		else
			reply 0 "$out"
		fi
		;;
esac
MW_FILE_END_11
chmod 755 "$R/usr/libexec/rpcd/luci.matchwatch.new"
mv -f "$R/usr/libexec/rpcd/luci.matchwatch.new" "$R/usr/libexec/rpcd/luci.matchwatch"
cat > "$R/usr/share/luci/menu.d/luci-app-matchwatch.json.new" <<'MW_FILE_END_12'
{
	"admin/services/matchwatch": {
		"title": "MatchWatch",
		"order": 60,
		"action": {
			"type": "firstchild"
		},
		"depends": {
			"acl": [ "luci-app-matchwatch" ]
		}
	},
	"admin/services/matchwatch/dashboard": {
		"title": "Dashboard",
		"order": 10,
		"action": {
			"type": "view",
			"path": "matchwatch/dashboard"
		}
	},
	"admin/services/matchwatch/settings": {
		"title": "Settings",
		"order": 20,
		"action": {
			"type": "view",
			"path": "matchwatch/settings"
		}
	}
}
MW_FILE_END_12
chmod 644 "$R/usr/share/luci/menu.d/luci-app-matchwatch.json.new"
mv -f "$R/usr/share/luci/menu.d/luci-app-matchwatch.json.new" "$R/usr/share/luci/menu.d/luci-app-matchwatch.json"
cat > "$R/usr/share/rpcd/acl.d/luci-app-matchwatch.json.new" <<'MW_FILE_END_13'
{
	"luci-app-matchwatch": {
		"description": "Grant access to MatchWatch",
		"read": {
			"ubus": {
				"luci.matchwatch": [ "read" ],
				"luci-rpc": [ "getHostHints" ]
			},
			"file": {
				"/tmp/matchwatch/www/*": [ "read" ],
				"/tmp/matchwatch/www/matches/*": [ "read" ],
				"/etc/matchwatch/matches/*": [ "read" ]
			},
			"uci": [ "matchwatch" ]
		},
		"write": {
			"ubus": {
				"luci.matchwatch": [ "write" ]
			},
			"uci": [ "matchwatch" ]
		}
	}
}
MW_FILE_END_13
chmod 644 "$R/usr/share/rpcd/acl.d/luci-app-matchwatch.json.new"
mv -f "$R/usr/share/rpcd/acl.d/luci-app-matchwatch.json.new" "$R/usr/share/rpcd/acl.d/luci-app-matchwatch.json"
cat > "$R/www/luci-static/resources/matchwatch/dashboard.js.new" <<'MW_FILE_END_14'
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
var D = { st: null, hist: [], servers: [], dcs: [], blocks: [], info: {}, lobby: null, regions: [], favs: [], favInfo: {}, gp: [], cov: null, hold: [] };
var page = "", pageArg = "", armed = 0, view = shadow.getElementById("view");
// The version this file belongs to (build.py checks it matches the program's). When the router reports
// another, MatchWatch has been updated under this page: the browser's stored copies of the dashboard
// files are fetched afresh, which replaces them, and the page reloads itself. Without this an updated
// router kept showing the old dashboard until the browser happened to let go of it.
var BUILT = "0.25.0", reloading = false;
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
		MAP.legend = h("p", { cls: "note", text: "Loading the map..." });
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
	mapBar("Press where the middle of the circle should be, drag outwards, and let go.", [["Cancel", "", function () { off(); mapDone(); }]]);
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
	function off() { map.off("mousedown", down); map.off("mousemove", move); map.off("mouseup", up); document.removeEventListener("mouseup", up); }
	map.on("mousedown", down); map.on("mousemove", move); map.on("mouseup", up); document.addEventListener("mouseup", up);
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
	MAP.legend.textContent = "Green circles are the places you stay on" + (RO ? "" : "; press one to move, resize or remove it") + ". Round markers are servers you have played on, coloured by how they rated; a number means several in one city, and a faded one is outside your places. Small hollow dots are datacentre regions with their ping."
		+ (whole.length ? " Also in the pool, but not drawn because they are whole countries or areas: " + whole.join(", ") + "." : "") + " The map pictures come from OpenStreetMap, fetched by your browser.";
}
// Strict, per game: hold every new server of a game until it has been placed. Offered for the games you have
// played, and only where the game's ports are not shared with voice chat.
function strictSection() {
	if (RO) return null;
	var played = {}, rows = [];
	D.hist.forEach(function (m) { if (m.game) played[m.game] = 1; });
	(D.hold || []).forEach(function (g) { if (g.on || played[g.name]) rows.push(g); });
	if (!rows.length) return null;
	var staying = (D.info.stays || []).length, box = h("div", null, h("h2", "Strict games"));
	box.appendChild(h("p", { cls: "note", text: "Normally a server MatchWatch has not seen before gets its first packets through while it is being looked up, and is then turned away if it is outside your places. Make a game strict and every new server on its ports is held for a moment first, so one outside your places never connects at all. It applies to your gaming device only." + (staying ? "" : " It only does anything while you are staying on places.") }));
	var t = table([["Game"], ["Server ports"], ["", ""]]);
	rows.forEach(function (g) {
		var td = h("td", { cls: "act" });
		if (g.on) { td.appendChild(h("span", { cls: "tag keep", text: staying ? "Strict" : "Strict when you stay" })); td.appendChild(act("Stop", "holdoff", null, { extra: "&name=" + g.name })); }
		else if (!g.ok) td.appendChild(h("span", { cls: "kept", title: "Most of its ports are also used by voice chat, and holding them would hold the start of a call.", text: "Shares its ports with voice chat" }));
		else td.appendChild(act("Make strict", "holdon", null, { extra: "&name=" + g.name }));
		t.lastChild.appendChild(row([[g.name], [g.ports.replace(/ /g, ", ")], td]));
	});
	box.appendChild(h("div", { cls: "tablewrap" }, t));
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
			cov.appendChild(h("p", { cls: "note", text: (c.refusing ? "Whole regions are refused ahead of time for games hosted by " + c.hosts + ": " + c.refused + " of its " + c.known + " address ranges, for your gaming device only. " : "MatchWatch knows where the servers are for games hosted by " + c.hosts + ". ") + "Servers of any other game are turned away one at a time, as the game tries them, and MatchWatch cannot tell in advance whether such a game has servers in your places." }));
		})(D.cov);
		if (stays.length > 1) {
			var rm = h("div", { cls: "actions" });
			stays.forEach(function (nm, i) { rm.appendChild(act("Remove " + nm, "stayrm", i + 1, {})); });
			view.appendChild(rm);
		}
	}
	// single servers let through, whatever region they are in
	var lets = D.info.allowed || [];
	if (lets.length) {
		view.appendChild(h("h3", { cls: "favgame" }, "Single servers in the pool", h("small", String(lets.length))));
		var lr = h("div", { cls: "actions" });
		lets.forEach(function (ip) { var s = D.servers.filter(function (x) { return x.ip === ip; })[0] || D.favInfo[ip]; lr.appendChild(act("Remove " + ip + (s && place(s) ? ", " + place(s) : ""), "unallow", ip, {})); });
		view.appendChild(lr);
		view.appendChild(h("p", { cls: "note", text: (stays.length ? "These servers are let through even though they are outside the places you stay on. " : "These will be let through when you stay on places. ") + "Only the exact address is allowed, so its neighbours in the same datacentre are still turned away. The game still decides whether to offer one to you." }));
	} else if (stays.length && !RO) view.appendChild(h("p", { cls: "note", text: "To let one server through from outside these places, press Add to pool beside it in your favourites or the server list below, or on a match report." }));
	view.appendChild(h("h2", "Map"));
	view.appendChild(mapSection());
	addIf(view, strictSection());
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
	view.appendChild(gamePlacesSection());
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
	view.appendChild(h("p", { cls: "note", text: "Ping from your router to the test server Vultr runs in each of its datacentres" + (rg.length ? ", measured " + when(rg[0].ts) : "") + ". Every Call of Duty server you have been placed on so far is hosted by Vultr, but the game is reported to use other hosts in some places, so this is not a complete list of where it has servers. Stay here on a row is the same as typing that city above: it allows servers within about 150 km of it, whoever hosts them. The game still decides which regions to offer you." }));
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
// Fresh data every fifteen seconds. The page is only drawn again when something in it has changed:
// rebuilding it each time made it flicker, and anything filled in a moment later pushed the rest down.
var lastSig = "";
function loadAll(then) {
	var left = 10, done = function () { if (--left === 0) then(); };
	get("hold.json", function (x) { D.hold = x || []; done(); });
	get("history.json", function (x) { D.hist = x || []; done(); });
	get("servers.json", function (x) { D.servers = x || []; done(); });
	get("datacentres.json", function (x) { D.dcs = x || []; done(); });
	get("blocklist.json", function (x) { D.blocks = x || []; done(); });
	get("info.json", function (x) { D.info = x || {}; versionSeen(D.info.version); done(); });
	get("favourites.json", function (x) { setFavs(x); done(); });
	get("regions.json", function (x) { D.regions = x || []; done(); });
	get("gameplaces.json", function (x) { D.gp = x || []; done(); });
	get("coverage.json", function (x) { D.cov = x || null; done(); });
}
function sigNow() { try { return JSON.stringify([D.hist, D.servers, D.dcs, D.blocks, D.info, D.favs, D.regions, D.gp, D.cov, D.hold]); } catch (e) { return String(Date.now()); } }
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
MW_FILE_END_14
chmod 644 "$R/www/luci-static/resources/matchwatch/dashboard.js.new"
mv -f "$R/www/luci-static/resources/matchwatch/dashboard.js.new" "$R/www/luci-static/resources/matchwatch/dashboard.js"
cat > "$R/www/luci-static/resources/matchwatch/dashboard.css.new" <<'MW_FILE_END_15'
:host { display: block; }
/* Colours. --soft is the quiet fill for buttons and hovers; --grid is every hairline. The chart reads these too. */
.mw {
	--paper: #f2f5f1; --panel: #ffffff; --soft: #e6ece5; --grid: #d3dcd2; --ink: #13272d; --muted: #5a6b67;
	--pen: #0f7a72; --pen2: #9a7412; --bad: #c2362c; --ok: #23804a; --mid: #a86f0a; --star: #c58a00;
	--display: "Bahnschrift", "DIN Alternate", "Roboto Condensed", "Arial Narrow", system-ui, sans-serif;
	--r: 8px; --r2: 12px;
}
.mw.dark { --paper: #0e2325; --panel: #153032; --soft: #1c3d3f; --grid: #27494b; --ink: #e6f0e9; --muted: #9bb5ad;
		--pen: #7fd1c0; --pen2: #e3c672; --bad: #ff6f5c; --ok: #7ed69b; --mid: #e6b655; --star: #f0c75e; }
* { box-sizing: border-box; }
.mw { text-align: left; background: var(--paper); color: var(--ink); font: 16px/1.5 system-ui, -apple-system, "Segoe UI", Roboto, sans-serif; font-variant-numeric: tabular-nums; }
.mw.full { min-height: 100vh; }
.mw.framed { border-radius: var(--r2); }
a { color: var(--pen); text-underline-offset: 3px; }
a:focus-visible, button:focus-visible, tr[tabindex]:focus-visible, input:focus-visible, select:focus-visible, textarea:focus-visible { outline: 3px solid var(--pen); outline-offset: 2px; }

/* ---- top bar */
.top { display: flex; align-items: center; gap: 10px 28px; flex-wrap: wrap; max-width: 1120px; margin: 0 auto; padding: 16px 16px 0; }
.brand { font: 700 1.35rem/1 var(--display); letter-spacing: 0.01em; text-decoration: none; color: var(--ink); }
nav { display: flex; gap: 2px; flex-wrap: wrap; flex: 1; }
nav a { text-decoration: none; padding: 7px 14px; border-radius: var(--r); color: var(--muted); font-weight: 600; }
nav a:hover { color: var(--ink); }
nav a[aria-current] { background: var(--soft); color: var(--ink); }
#state { display: inline-flex; align-items: center; gap: 8px; color: var(--muted); font-size: 0.9rem; padding: 5px 13px; border: 1px solid var(--grid); border-radius: 999px; }
#state::before { content: ""; width: 8px; height: 8px; border-radius: 50%; background: var(--muted); opacity: 0.6; }
#state.on { color: var(--ok); font-weight: 700; border-color: var(--ok); }
#state.on::before { background: var(--ok); opacity: 1; }
main { max-width: 1120px; margin: 0 auto; padding: 22px 16px 64px; }
@media (max-width: 680px) {
	.top { gap: 10px 12px; justify-content: space-between; }
	nav { order: 3; flex-basis: 100%; flex-wrap: nowrap; overflow-x: auto; margin: 0 -16px; padding: 0 16px 2px; }
	nav a { white-space: nowrap; }
	h1 { font-size: 1.6rem; }
}

/* ---- type */
h1 { font: 700 2rem/1.1 var(--display); margin: 0; letter-spacing: 0.005em; }
h2 { font: 700 1.3rem/1.2 var(--display); margin: 44px 0 12px; }
h3 { font: 700 1.05rem/1.25 var(--display); margin: 24px 0 6px; }
.sub { color: var(--muted); margin: 6px 0 0; }
.lede { font-size: 1.15rem; max-width: 64ch; margin: 14px 0 0; }
.lede.ok, .lede.mid, .lede.low { font-weight: 600; }
.empty { color: var(--muted); }
.note { color: var(--muted); font-size: 0.9rem; margin: 8px 0 0; max-width: 70ch; }
.ok { color: var(--ok); } .mid { color: var(--mid); } .low { color: var(--bad); }
.s { font-weight: 700; }

/* ---- buttons and fields */
button { font: 600 0.9rem/1.3 system-ui, sans-serif; color: var(--ink); background: var(--soft); border: 1px solid transparent; border-radius: var(--r); padding: 7px 14px; margin: 0; cursor: pointer; }
button:hover:not(:disabled) { border-color: var(--ink); }
button.solid { background: var(--ink); color: var(--paper); }
button.solid:hover:not(:disabled) { opacity: 0.88; }
button.big { font-size: 1.05rem; padding: 13px 22px; }
button.danger { background: none; border-color: var(--bad); border-color: color-mix(in srgb, var(--bad) 45%, transparent); color: var(--bad); }
button.danger:hover:not(:disabled) { border-color: var(--bad); }
button.arm, button.arm:hover:not(:disabled) { background: var(--bad); border-color: var(--bad); color: var(--paper); }
button:disabled { opacity: 0.45; cursor: default; }
button.star { background: none; border: 0; padding: 2px 6px; font-size: 1.2rem; line-height: 1; color: var(--muted); }
button.star:hover:not(:disabled), .star.on { color: var(--star); }
span.star { font-size: 1.2rem; line-height: 1; padding: 2px 6px; }
select, input[type="text"], textarea { font: inherit; color: var(--ink); background: var(--panel); border: 1px solid var(--grid); border-radius: var(--r); padding: 8px 11px; }
select { padding: 7px 10px; max-width: 100%; }
.actions { display: flex; gap: 10px; flex-wrap: wrap; align-items: center; margin: 16px 0 0; }
.stayform { display: flex; gap: 8px; flex-wrap: wrap; max-width: 560px; }
.stayform input { flex: 1; min-width: 200px; }
.banner .stayform { flex: 1; min-width: 260px; }
td .stayform { max-width: 420px; }
td .stayform input { min-width: 140px; }

/* ---- chart */
.strip { margin-top: 18px; background: var(--panel); border: 1px solid var(--grid); border-radius: var(--r2); overflow: hidden; }
canvas { display: block; width: 100%; height: 300px; }
.legend { display: flex; gap: 6px 18px; flex-wrap: wrap; padding: 10px 14px; border-top: 1px solid var(--grid); color: var(--muted); font-size: 0.85rem; }
.legend i { display: inline-block; width: 10px; height: 10px; border-radius: 2px; margin-right: 6px; vertical-align: -1px; }

/* ---- the live figures: one tile each */
.figs { display: grid; grid-template-columns: repeat(auto-fit, minmax(150px, 1fr)); gap: 10px; margin: 14px 0 0; padding: 0; }
.figs div { background: var(--panel); border: 1px solid var(--grid); border-radius: var(--r2); padding: 12px 14px; }
.figs dt { color: var(--muted); font-size: 0.85rem; }
.figs dd { margin: 2px 0 0; font: 600 1.7rem/1.2 var(--display); }
.figs dd small { font: 400 0.85rem system-ui, sans-serif; color: var(--muted); margin-left: 4px; }

/* ---- the path a packet takes: PC, line, route, server. The weak link stands out. */
.chain { display: grid; grid-template-columns: repeat(4, 1fr); margin: 26px 0 0; position: relative; }
.chain::before { content: ""; position: absolute; left: 12%; right: 12%; top: 27px; border-top: 2px solid var(--grid); }
.link { position: relative; padding: 0 10px; text-align: center; }
.link .dot { width: 54px; height: 54px; border-radius: 50%; margin: 0 auto; display: grid; place-items: center; background: var(--paper); border: 3px solid var(--ok); font: 700 1.25rem/1 var(--display); }
.link.mid .dot { border-color: var(--mid); } .link.low .dot { border-color: var(--bad); background: var(--bad); color: var(--paper); }
.link.na .dot { border-color: var(--grid); color: var(--muted); font-size: 0.9rem; }
.link b { display: block; margin-top: 8px; font: 700 1.02rem var(--display); }
.link span { display: block; color: var(--muted); font-size: 0.88rem; }
.link small { display: block; margin: 6px auto 0; max-width: 26ch; color: var(--ink); font-size: 0.8rem; line-height: 1.35; }
.grade { display: flex; align-items: center; gap: 14px; margin: 4px 0 14px; }
.grade b { flex: none; min-width: 56px; height: 56px; padding: 0 8px; display: grid; place-items: center; border-radius: var(--r); border: 3px solid var(--ok); font: 700 1.5rem/1 var(--display); }
.grade.mid b { border-color: var(--mid); } .grade.low b { border-color: var(--bad); background: var(--bad); color: var(--paper); }
.grade p { margin: 0; }
@media (max-width: 560px) { .chain { grid-template-columns: repeat(2, 1fr); row-gap: 18px; } .chain::before { display: none; } }

.head { display: flex; justify-content: space-between; align-items: flex-end; gap: 16px; flex-wrap: wrap; }
.score { text-align: right; }
.score b { font: 700 3.4rem/0.9 var(--display); }
.score b small { font-size: 1.1rem; color: var(--muted); font-weight: 600; }
.score span { display: block; font-weight: 700; }

.cols { display: grid; grid-template-columns: repeat(auto-fit, minmax(min(420px, 100%), 1fr)); gap: 0 48px; }
.kv { margin: 0; display: grid; grid-template-columns: 1fr auto; gap: 0 14px; }
.kv dt, .kv dd { margin: 0; padding: 8px 0; border-bottom: 1px solid var(--grid); }
.kv dd { text-align: right; font-weight: 600; }
.kv dt small { display: block; color: var(--muted); font-size: 0.82rem; }
ol.hops { margin: 8px 0 0; padding: 0; list-style: none; font-size: 0.9rem; color: var(--muted); columns: 2 220px; }

/* ---- tables */
.tablewrap { overflow-x: auto; }
table { border-collapse: collapse; width: 100%; font-size: 0.93rem; }
th { text-align: left; font-weight: 600; font-size: 0.85rem; color: var(--muted); border-bottom: 1px solid var(--grid); padding: 6px 14px 8px 0; white-space: nowrap; }
td { border-bottom: 1px solid var(--grid); padding: 10px 14px 10px 0; white-space: nowrap; }
td.num, th.num { text-align: right; }
td.act { text-align: right; padding-right: 0; }
td.act > * + * { margin-left: 6px; }
td.act button:not(.star) { padding: 4px 11px; }
.kept { color: var(--muted); font-size: 0.85rem; padding: 0 6px; cursor: help; }
tr[tabindex] { cursor: pointer; } tr[tabindex]:hover td { background: var(--soft); }
.tag { display: inline-block; font-size: 0.78rem; font-weight: 700; padding: 3px 10px; border-radius: 999px; color: var(--bad); background: var(--soft); background: color-mix(in srgb, var(--bad) 16%, transparent); }
.tag.keep { color: var(--ok); background: var(--soft); background: color-mix(in srgb, var(--ok) 16%, transparent); }

/* ---- ratings by hour */
.hours { display: grid; grid-template-columns: repeat(24, 1fr); gap: 3px; align-items: end; max-width: 760px; margin-top: 6px; }
.hr { display: flex; flex-direction: column; align-items: center; justify-content: flex-end; height: 104px; font-size: 0.72rem; color: var(--muted); }
button.hr, button.hr:hover:not(:disabled) { background: none; border: 0; border-radius: 0; padding: 0; font-weight: 400; }
button.hr:hover i, button.hr.sel i { outline: 2px solid var(--ink); outline-offset: 1px; }
.hr i { display: block; width: 100%; background: var(--grid); border-radius: 3px 3px 0 0; }
.hr i.ok { background: var(--ok); } .hr i.mid { background: var(--mid); } .hr i.low { background: var(--bad); }
.hr span { height: 16px; line-height: 16px; } .hr .v { color: var(--ink); font-weight: 600; }

/* ---- messages */
.banner { margin: 16px 0 18px; padding: 14px 16px; border: 1px solid var(--grid); border-left: 4px solid var(--pen); border-radius: var(--r2); background: var(--panel); display: flex; gap: 12px; justify-content: space-between; align-items: center; flex-wrap: wrap; }
.banner.far { border-left-color: var(--mid); } .banner.bad { border-left-color: var(--bad); }
.banner p { margin: 0; max-width: 70ch; flex: 1 1 320px; }
button.close { background: none; border: 0; padding: 0 6px; font-size: 1.5rem; line-height: 1; color: var(--muted); align-self: flex-start; }
button.close:hover:not(:disabled) { color: var(--ink); }
.toolbody .stayform + .stayform { margin-top: 8px; }
.banner b { font-family: var(--display); }
#toast { position: fixed; left: 50%; bottom: 20px; transform: translateX(-50%); max-width: min(92vw, 640px); background: var(--ink); color: var(--paper); padding: 11px 18px; border-radius: var(--r2); font-size: 0.95rem; white-space: pre-line; display: none; z-index: 5; }
#toast.err { background: var(--bad); }
ul.marks { list-style: none; margin: 10px 0 0; padding: 0; max-width: 72ch; }
ul.marks li { padding: 8px 0; border-top: 1px solid var(--grid); }
ul.marks time { color: var(--muted); margin-right: 10px; }
pre { background: var(--panel); border: 1px solid var(--grid); border-radius: var(--r); padding: 12px 14px; overflow-x: auto; font-size: 0.85rem; white-space: pre-wrap; margin: 12px 0 0; }
code { background: var(--panel); border: 1px solid var(--grid); padding: 1px 5px; border-radius: 4px; }

/* ---- Tools: one row per tool. What it does on the left, the control and its result on the right. */
.tool { display: grid; grid-template-columns: minmax(220px, 330px) minmax(0, 1fr); gap: 10px 36px; padding: 18px 0; border-top: 1px solid var(--grid); }
h2 + .tool, .seg + .tool { border-top: 0; padding-top: 4px; }
/* the tabs inside Tools */
.seg { display: inline-flex; flex-wrap: wrap; gap: 2px; margin: 16px 0 14px; padding: 3px; background: var(--soft); border-radius: 10px; }
.seg a { text-decoration: none; padding: 6px 16px; border-radius: 7px; color: var(--muted); font-weight: 600; font-size: 0.93rem; }
.seg a:hover { color: var(--ink); }
.seg a[aria-current] { background: var(--panel); color: var(--ink); }
.seg + .note { margin-top: 0; }
.toolhead h3 { margin: 0; }
.toolhead .note { margin: 4px 0 0; }
.toolbody > :first-child { margin-top: 0; }
.toolbody .stayform { max-width: none; }
@media (max-width: 760px) { .tool { grid-template-columns: 1fr; } }

/* ---- favourites */
.favgame { display: flex; align-items: baseline; gap: 10px; }
.favgame small { color: var(--muted); font: 400 0.9rem system-ui, sans-serif; }

/* ---- share files */
.ticks { display: flex; flex-direction: column; gap: 6px; margin: 10px 0 0; }
.tickbox { display: flex; gap: 9px; align-items: flex-start; max-width: 70ch; margin: 8px 0 0; cursor: pointer; }
.ticks .tickbox { margin: 0; }
.tickbox input { margin: 4px 0 0; width: 16px; height: 16px; flex: none; accent-color: var(--pen); }
.tickbox:has(input:disabled) { color: var(--muted); cursor: default; }
.sharetext { display: block; width: 100%; max-width: 720px; margin: 12px 0 0; padding: 12px; font: 0.85rem/1.45 ui-monospace, Consolas, monospace; resize: vertical; }
.pick { margin: 8px 0 0; max-width: 720px; }
details.pick { border: 1px solid var(--grid); border-radius: var(--r); background: var(--panel); padding: 9px 14px; }
details.pick > summary { cursor: pointer; }
details.pick > summary b { margin-left: 4px; }
details.pick .picklist { border: 0; padding: 4px 0 2px; background: none; max-height: 230px; }
details.pick + div.pick { margin-top: 16px; }
.pickhead { display: flex; align-items: center; gap: 8px; flex-wrap: wrap; }
.quick button, .quick select { padding: 3px 10px; font-size: 0.82rem; }
.pickcount { color: var(--muted); font-size: 0.9rem; margin-right: auto; }
summary.pickhead { display: list-item; }
summary.pickhead .pickcount { margin-left: 8px; }
.quick { display: flex; align-items: center; gap: 8px; flex-wrap: wrap; margin: 8px 0 0; color: var(--muted); font-size: 0.9rem; }
.picklist { display: flex; flex-direction: column; gap: 7px; margin: 8px 0 0; padding: 12px 14px; max-height: 250px; overflow-y: auto; border: 1px solid var(--grid); border-radius: var(--r); background: var(--panel); }
.picklist .tickbox { margin: 0; max-width: none; }
.pick .stayform { margin: 8px 0 0; max-width: none; }
.filepick { margin: 10px 0 0; }
.filepick input { font: inherit; color: var(--ink); max-width: 100%; }

h2 + .kv { max-width: 640px; }

/* the map */
.mapbox { margin: 10px 0 4px; }
.maptools { display: flex; gap: 8px; flex-wrap: wrap; margin-bottom: 8px; }
.map { height: 460px; border-radius: var(--r); border: 1px solid var(--grid); overflow: hidden; background: var(--soft); position: relative; z-index: 0; }
.map.drawing, .map.drawing .leaflet-grab, .map.drawing .leaflet-interactive { cursor: crosshair; }
.mapbar { display: flex; gap: 10px; align-items: center; flex-wrap: wrap; padding: 10px 12px; margin-top: 8px; background: var(--soft); border-radius: var(--r2); }
.mapbar p { margin: 0; flex: 1; min-width: 220px; }
.pin { display: grid; place-items: center; width: 26px; height: 26px; box-sizing: border-box; border-radius: 50%; background: var(--ok); color: var(--paper); font: 700 0.8rem/1 var(--display); border: 2px solid var(--paper); box-shadow: 0 1px 4px rgba(0, 0, 0, 0.45); }
.pin.mid { background: var(--mid); } .pin.low { background: var(--bad); } .pin.na { background: var(--muted); }
.pin.out { opacity: 0.5; border-style: dashed; }
.pin.home { background: var(--pen); font-size: 1rem; }
.pin.grip { width: 18px; height: 18px; background: var(--paper); border: 3px solid var(--pen); cursor: move; }
.mw .leaflet-container { font: inherit; background: var(--soft); }
.mw.dark .leaflet-tile-pane { filter: invert(1) hue-rotate(180deg) brightness(1.08) contrast(0.86) saturate(0.5); }
.mw .leaflet-popup-content-wrapper, .mw .leaflet-popup-tip { background: var(--panel); color: var(--ink); box-shadow: 0 4px 18px rgba(0, 0, 0, 0.4); }
.mw .leaflet-popup-content-wrapper { border-radius: var(--r2); }
.mw .leaflet-popup-content { margin: 12px 14px; font-size: 0.92rem; line-height: 1.4; }
.mw .leaflet-container a.leaflet-popup-close-button { color: var(--muted); }
.mw .leaflet-bar a, .mw .leaflet-bar a:hover { background: var(--panel); color: var(--ink); border-bottom-color: var(--grid); }
.mw .leaflet-bar { border: 1px solid var(--grid); box-shadow: none; }
.mw .leaflet-tooltip { background: var(--panel); color: var(--ink); border: 1px solid var(--grid); box-shadow: none; }
.mw .leaflet-tooltip::before { display: none; }
.mw .leaflet-control-attribution { background: var(--panel); color: var(--muted); opacity: 0.85; font-size: 0.7rem; }
.mw .leaflet-control-attribution a { color: var(--muted); }
.spot > b { display: block; font: 700 1rem var(--display); }
.spot small { display: block; color: var(--muted); }
.spotrow { display: flex; gap: 10px; align-items: center; justify-content: space-between; padding: 8px 0 0; margin-top: 8px; border-top: 1px solid var(--grid); }
.spotrow .actions { margin: 0; flex: none; }
MW_FILE_END_15
chmod 644 "$R/www/luci-static/resources/matchwatch/dashboard.css.new"
mv -f "$R/www/luci-static/resources/matchwatch/dashboard.css.new" "$R/www/luci-static/resources/matchwatch/dashboard.css"
cat > "$R/www/luci-static/resources/matchwatch/leaflet.js.new" <<'MW_FILE_END_16'
/* @preserve
 * Leaflet 1.9.4, a JS library for interactive maps. https://leafletjs.com
 * (c) 2010-2023 Vladimir Agafonkin, (c) 2010-2011 CloudMade
 */
!function(t,e){"object"==typeof exports&&"undefined"!=typeof module?e(exports):"function"==typeof define&&define.amd?define(["exports"],e):e((t="undefined"!=typeof globalThis?globalThis:t||self).leaflet={})}(this,function(t){"use strict";function l(t){for(var e,i,n=1,o=arguments.length;n<o;n++)for(e in i=arguments[n])t[e]=i[e];return t}var R=Object.create||function(t){return N.prototype=t,new N};function N(){}function a(t,e){var i,n=Array.prototype.slice;return t.bind?t.bind.apply(t,n.call(arguments,1)):(i=n.call(arguments,2),function(){return t.apply(e,i.length?i.concat(n.call(arguments)):arguments)})}var D=0;function h(t){return"_leaflet_id"in t||(t._leaflet_id=++D),t._leaflet_id}function j(t,e,i){var n,o,s=function(){n=!1,o&&(r.apply(i,o),o=!1)},r=function(){n?o=arguments:(t.apply(i,arguments),setTimeout(s,e),n=!0)};return r}function H(t,e,i){var n=e[1],e=e[0],o=n-e;return t===n&&i?t:((t-e)%o+o)%o+e}function u(){return!1}function i(t,e){return!1===e?t:(e=Math.pow(10,void 0===e?6:e),Math.round(t*e)/e)}function W(t){return t.trim?t.trim():t.replace(/^\s+|\s+$/g,"")}function F(t){return W(t).split(/\s+/)}function c(t,e){for(var i in Object.prototype.hasOwnProperty.call(t,"options")||(t.options=t.options?R(t.options):{}),e)t.options[i]=e[i];return t.options}function U(t,e,i){var n,o=[];for(n in t)o.push(encodeURIComponent(i?n.toUpperCase():n)+"="+encodeURIComponent(t[n]));return(e&&-1!==e.indexOf("?")?"&":"?")+o.join("&")}var V=/\{ *([\w_ -]+) *\}/g;function q(t,i){return t.replace(V,function(t,e){e=i[e];if(void 0===e)throw new Error("No value provided for variable "+t);return e="function"==typeof e?e(i):e})}var d=Array.isArray||function(t){return"[object Array]"===Object.prototype.toString.call(t)};function G(t,e){for(var i=0;i<t.length;i++)if(t[i]===e)return i;return-1}var K="data:image/gif;base64,R0lGODlhAQABAAD/ACwAAAAAAQABAAACADs=";function Y(t){return window["webkit"+t]||window["moz"+t]||window["ms"+t]}var X=0;function J(t){var e=+new Date,i=Math.max(0,16-(e-X));return X=e+i,window.setTimeout(t,i)}var $=window.requestAnimationFrame||Y("RequestAnimationFrame")||J,Q=window.cancelAnimationFrame||Y("CancelAnimationFrame")||Y("CancelRequestAnimationFrame")||function(t){window.clearTimeout(t)};function x(t,e,i){if(!i||$!==J)return $.call(window,a(t,e));t.call(e)}function r(t){t&&Q.call(window,t)}var tt={__proto__:null,extend:l,create:R,bind:a,get lastId(){return D},stamp:h,throttle:j,wrapNum:H,falseFn:u,formatNum:i,trim:W,splitWords:F,setOptions:c,getParamString:U,template:q,isArray:d,indexOf:G,emptyImageUrl:K,requestFn:$,cancelFn:Q,requestAnimFrame:x,cancelAnimFrame:r};function et(){}et.extend=function(t){function e(){c(this),this.initialize&&this.initialize.apply(this,arguments),this.callInitHooks()}var i,n=e.__super__=this.prototype,o=R(n);for(i in(o.constructor=e).prototype=o,this)Object.prototype.hasOwnProperty.call(this,i)&&"prototype"!==i&&"__super__"!==i&&(e[i]=this[i]);if(t.statics&&l(e,t.statics),t.includes){var s=t.includes;if("undefined"!=typeof L&&L&&L.Mixin){s=d(s)?s:[s];for(var r=0;r<s.length;r++)s[r]===L.Mixin.Events&&console.warn("Deprecated include of L.Mixin.Events: this property will be removed in future releases, please inherit from L.Evented instead.",(new Error).stack)}l.apply(null,[o].concat(t.includes))}return l(o,t),delete o.statics,delete o.includes,o.options&&(o.options=n.options?R(n.options):{},l(o.options,t.options)),o._initHooks=[],o.callInitHooks=function(){if(!this._initHooksCalled){n.callInitHooks&&n.callInitHooks.call(this),this._initHooksCalled=!0;for(var t=0,e=o._initHooks.length;t<e;t++)o._initHooks[t].call(this)}},e},et.include=function(t){var e=this.prototype.options;return l(this.prototype,t),t.options&&(this.prototype.options=e,this.mergeOptions(t.options)),this},et.mergeOptions=function(t){return l(this.prototype.options,t),this},et.addInitHook=function(t){var e=Array.prototype.slice.call(arguments,1),i="function"==typeof t?t:function(){this[t].apply(this,e)};return this.prototype._initHooks=this.prototype._initHooks||[],this.prototype._initHooks.push(i),this};var e={on:function(t,e,i){if("object"==typeof t)for(var n in t)this._on(n,t[n],e);else for(var o=0,s=(t=F(t)).length;o<s;o++)this._on(t[o],e,i);return this},off:function(t,e,i){if(arguments.length)if("object"==typeof t)for(var n in t)this._off(n,t[n],e);else{t=F(t);for(var o=1===arguments.length,s=0,r=t.length;s<r;s++)o?this._off(t[s]):this._off(t[s],e,i)}else delete this._events;return this},_on:function(t,e,i,n){"function"!=typeof e?console.warn("wrong listener type: "+typeof e):!1===this._listens(t,e,i)&&(e={fn:e,ctx:i=i===this?void 0:i},n&&(e.once=!0),this._events=this._events||{},this._events[t]=this._events[t]||[],this._events[t].push(e))},_off:function(t,e,i){var n,o,s;if(this._events&&(n=this._events[t]))if(1===arguments.length){if(this._firingCount)for(o=0,s=n.length;o<s;o++)n[o].fn=u;delete this._events[t]}else"function"!=typeof e?console.warn("wrong listener type: "+typeof e):!1!==(e=this._listens(t,e,i))&&(i=n[e],this._firingCount&&(i.fn=u,this._events[t]=n=n.slice()),n.splice(e,1))},fire:function(t,e,i){if(this.listens(t,i)){var n=l({},e,{type:t,target:this,sourceTarget:e&&e.sourceTarget||this});if(this._events){var o=this._events[t];if(o){this._firingCount=this._firingCount+1||1;for(var s=0,r=o.length;s<r;s++){var a=o[s],h=a.fn;a.once&&this.off(t,h,a.ctx),h.call(a.ctx||this,n)}this._firingCount--}}i&&this._propagateEvent(n)}return this},listens:function(t,e,i,n){"string"!=typeof t&&console.warn('"string" type argument expected');var o=e,s=("function"!=typeof e&&(n=!!e,i=o=void 0),this._events&&this._events[t]);if(s&&s.length&&!1!==this._listens(t,o,i))return!0;if(n)for(var r in this._eventParents)if(this._eventParents[r].listens(t,e,i,n))return!0;return!1},_listens:function(t,e,i){if(this._events){var n=this._events[t]||[];if(!e)return!!n.length;i===this&&(i=void 0);for(var o=0,s=n.length;o<s;o++)if(n[o].fn===e&&n[o].ctx===i)return o}return!1},once:function(t,e,i){if("object"==typeof t)for(var n in t)this._on(n,t[n],e,!0);else for(var o=0,s=(t=F(t)).length;o<s;o++)this._on(t[o],e,i,!0);return this},addEventParent:function(t){return this._eventParents=this._eventParents||{},this._eventParents[h(t)]=t,this},removeEventParent:function(t){return this._eventParents&&delete this._eventParents[h(t)],this},_propagateEvent:function(t){for(var e in this._eventParents)this._eventParents[e].fire(t.type,l({layer:t.target,propagatedFrom:t.target},t),!0)}},it=(e.addEventListener=e.on,e.removeEventListener=e.clearAllEventListeners=e.off,e.addOneTimeEventListener=e.once,e.fireEvent=e.fire,e.hasEventListeners=e.listens,et.extend(e));function p(t,e,i){this.x=i?Math.round(t):t,this.y=i?Math.round(e):e}var nt=Math.trunc||function(t){return 0<t?Math.floor(t):Math.ceil(t)};function m(t,e,i){return t instanceof p?t:d(t)?new p(t[0],t[1]):null==t?t:"object"==typeof t&&"x"in t&&"y"in t?new p(t.x,t.y):new p(t,e,i)}function f(t,e){if(t)for(var i=e?[t,e]:t,n=0,o=i.length;n<o;n++)this.extend(i[n])}function _(t,e){return!t||t instanceof f?t:new f(t,e)}function s(t,e){if(t)for(var i=e?[t,e]:t,n=0,o=i.length;n<o;n++)this.extend(i[n])}function g(t,e){return t instanceof s?t:new s(t,e)}function v(t,e,i){if(isNaN(t)||isNaN(e))throw new Error("Invalid LatLng object: ("+t+", "+e+")");this.lat=+t,this.lng=+e,void 0!==i&&(this.alt=+i)}function w(t,e,i){return t instanceof v?t:d(t)&&"object"!=typeof t[0]?3===t.length?new v(t[0],t[1],t[2]):2===t.length?new v(t[0],t[1]):null:null==t?t:"object"==typeof t&&"lat"in t?new v(t.lat,"lng"in t?t.lng:t.lon,t.alt):void 0===e?null:new v(t,e,i)}p.prototype={clone:function(){return new p(this.x,this.y)},add:function(t){return this.clone()._add(m(t))},_add:function(t){return this.x+=t.x,this.y+=t.y,this},subtract:function(t){return this.clone()._subtract(m(t))},_subtract:function(t){return this.x-=t.x,this.y-=t.y,this},divideBy:function(t){return this.clone()._divideBy(t)},_divideBy:function(t){return this.x/=t,this.y/=t,this},multiplyBy:function(t){return this.clone()._multiplyBy(t)},_multiplyBy:function(t){return this.x*=t,this.y*=t,this},scaleBy:function(t){return new p(this.x*t.x,this.y*t.y)},unscaleBy:function(t){return new p(this.x/t.x,this.y/t.y)},round:function(){return this.clone()._round()},_round:function(){return this.x=Math.round(this.x),this.y=Math.round(this.y),this},floor:function(){return this.clone()._floor()},_floor:function(){return this.x=Math.floor(this.x),this.y=Math.floor(this.y),this},ceil:function(){return this.clone()._ceil()},_ceil:function(){return this.x=Math.ceil(this.x),this.y=Math.ceil(this.y),this},trunc:function(){return this.clone()._trunc()},_trunc:function(){return this.x=nt(this.x),this.y=nt(this.y),this},distanceTo:function(t){var e=(t=m(t)).x-this.x,t=t.y-this.y;return Math.sqrt(e*e+t*t)},equals:function(t){return(t=m(t)).x===this.x&&t.y===this.y},contains:function(t){return t=m(t),Math.abs(t.x)<=Math.abs(this.x)&&Math.abs(t.y)<=Math.abs(this.y)},toString:function(){return"Point("+i(this.x)+", "+i(this.y)+")"}},f.prototype={extend:function(t){var e,i;if(t){if(t instanceof p||"number"==typeof t[0]||"x"in t)e=i=m(t);else if(e=(t=_(t)).min,i=t.max,!e||!i)return this;this.min||this.max?(this.min.x=Math.min(e.x,this.min.x),this.max.x=Math.max(i.x,this.max.x),this.min.y=Math.min(e.y,this.min.y),this.max.y=Math.max(i.y,this.max.y)):(this.min=e.clone(),this.max=i.clone())}return this},getCenter:function(t){return m((this.min.x+this.max.x)/2,(this.min.y+this.max.y)/2,t)},getBottomLeft:function(){return m(this.min.x,this.max.y)},getTopRight:function(){return m(this.max.x,this.min.y)},getTopLeft:function(){return this.min},getBottomRight:function(){return this.max},getSize:function(){return this.max.subtract(this.min)},contains:function(t){var e,i;return(t=("number"==typeof t[0]||t instanceof p?m:_)(t))instanceof f?(e=t.min,i=t.max):e=i=t,e.x>=this.min.x&&i.x<=this.max.x&&e.y>=this.min.y&&i.y<=this.max.y},intersects:function(t){t=_(t);var e=this.min,i=this.max,n=t.min,t=t.max,o=t.x>=e.x&&n.x<=i.x,t=t.y>=e.y&&n.y<=i.y;return o&&t},overlaps:function(t){t=_(t);var e=this.min,i=this.max,n=t.min,t=t.max,o=t.x>e.x&&n.x<i.x,t=t.y>e.y&&n.y<i.y;return o&&t},isValid:function(){return!(!this.min||!this.max)},pad:function(t){var e=this.min,i=this.max,n=Math.abs(e.x-i.x)*t,t=Math.abs(e.y-i.y)*t;return _(m(e.x-n,e.y-t),m(i.x+n,i.y+t))},equals:function(t){return!!t&&(t=_(t),this.min.equals(t.getTopLeft())&&this.max.equals(t.getBottomRight()))}},s.prototype={extend:function(t){var e,i,n=this._southWest,o=this._northEast;if(t instanceof v)i=e=t;else{if(!(t instanceof s))return t?this.extend(w(t)||g(t)):this;if(e=t._southWest,i=t._northEast,!e||!i)return this}return n||o?(n.lat=Math.min(e.lat,n.lat),n.lng=Math.min(e.lng,n.lng),o.lat=Math.max(i.lat,o.lat),o.lng=Math.max(i.lng,o.lng)):(this._southWest=new v(e.lat,e.lng),this._northEast=new v(i.lat,i.lng)),this},pad:function(t){var e=this._southWest,i=this._northEast,n=Math.abs(e.lat-i.lat)*t,t=Math.abs(e.lng-i.lng)*t;return new s(new v(e.lat-n,e.lng-t),new v(i.lat+n,i.lng+t))},getCenter:function(){return new v((this._southWest.lat+this._northEast.lat)/2,(this._southWest.lng+this._northEast.lng)/2)},getSouthWest:function(){return this._southWest},getNorthEast:function(){return this._northEast},getNorthWest:function(){return new v(this.getNorth(),this.getWest())},getSouthEast:function(){return new v(this.getSouth(),this.getEast())},getWest:function(){return this._southWest.lng},getSouth:function(){return this._southWest.lat},getEast:function(){return this._northEast.lng},getNorth:function(){return this._northEast.lat},contains:function(t){t=("number"==typeof t[0]||t instanceof v||"lat"in t?w:g)(t);var e,i,n=this._southWest,o=this._northEast;return t instanceof s?(e=t.getSouthWest(),i=t.getNorthEast()):e=i=t,e.lat>=n.lat&&i.lat<=o.lat&&e.lng>=n.lng&&i.lng<=o.lng},intersects:function(t){t=g(t);var e=this._southWest,i=this._northEast,n=t.getSouthWest(),t=t.getNorthEast(),o=t.lat>=e.lat&&n.lat<=i.lat,t=t.lng>=e.lng&&n.lng<=i.lng;return o&&t},overlaps:function(t){t=g(t);var e=this._southWest,i=this._northEast,n=t.getSouthWest(),t=t.getNorthEast(),o=t.lat>e.lat&&n.lat<i.lat,t=t.lng>e.lng&&n.lng<i.lng;return o&&t},toBBoxString:function(){return[this.getWest(),this.getSouth(),this.getEast(),this.getNorth()].join(",")},equals:function(t,e){return!!t&&(t=g(t),this._southWest.equals(t.getSouthWest(),e)&&this._northEast.equals(t.getNorthEast(),e))},isValid:function(){return!(!this._southWest||!this._northEast)}};var ot={latLngToPoint:function(t,e){t=this.projection.project(t),e=this.scale(e);return this.transformation._transform(t,e)},pointToLatLng:function(t,e){e=this.scale(e),t=this.transformation.untransform(t,e);return this.projection.unproject(t)},project:function(t){return this.projection.project(t)},unproject:function(t){return this.projection.unproject(t)},scale:function(t){return 256*Math.pow(2,t)},zoom:function(t){return Math.log(t/256)/Math.LN2},getProjectedBounds:function(t){var e;return this.infinite?null:(e=this.projection.bounds,t=this.scale(t),new f(this.transformation.transform(e.min,t),this.transformation.transform(e.max,t)))},infinite:!(v.prototype={equals:function(t,e){return!!t&&(t=w(t),Math.max(Math.abs(this.lat-t.lat),Math.abs(this.lng-t.lng))<=(void 0===e?1e-9:e))},toString:function(t){return"LatLng("+i(this.lat,t)+", "+i(this.lng,t)+")"},distanceTo:function(t){return st.distance(this,w(t))},wrap:function(){return st.wrapLatLng(this)},toBounds:function(t){var t=180*t/40075017,e=t/Math.cos(Math.PI/180*this.lat);return g([this.lat-t,this.lng-e],[this.lat+t,this.lng+e])},clone:function(){return new v(this.lat,this.lng,this.alt)}}),wrapLatLng:function(t){var e=this.wrapLng?H(t.lng,this.wrapLng,!0):t.lng;return new v(this.wrapLat?H(t.lat,this.wrapLat,!0):t.lat,e,t.alt)},wrapLatLngBounds:function(t){var e=t.getCenter(),i=this.wrapLatLng(e),n=e.lat-i.lat,e=e.lng-i.lng;return 0==n&&0==e?t:(i=t.getSouthWest(),t=t.getNorthEast(),new s(new v(i.lat-n,i.lng-e),new v(t.lat-n,t.lng-e)))}},st=l({},ot,{wrapLng:[-180,180],R:6371e3,distance:function(t,e){var i=Math.PI/180,n=t.lat*i,o=e.lat*i,s=Math.sin((e.lat-t.lat)*i/2),e=Math.sin((e.lng-t.lng)*i/2),t=s*s+Math.cos(n)*Math.cos(o)*e*e,i=2*Math.atan2(Math.sqrt(t),Math.sqrt(1-t));return this.R*i}}),rt=6378137,rt={R:rt,MAX_LATITUDE:85.0511287798,project:function(t){var e=Math.PI/180,i=this.MAX_LATITUDE,i=Math.max(Math.min(i,t.lat),-i),i=Math.sin(i*e);return new p(this.R*t.lng*e,this.R*Math.log((1+i)/(1-i))/2)},unproject:function(t){var e=180/Math.PI;return new v((2*Math.atan(Math.exp(t.y/this.R))-Math.PI/2)*e,t.x*e/this.R)},bounds:new f([-(rt=rt*Math.PI),-rt],[rt,rt])};function at(t,e,i,n){d(t)?(this._a=t[0],this._b=t[1],this._c=t[2],this._d=t[3]):(this._a=t,this._b=e,this._c=i,this._d=n)}function ht(t,e,i,n){return new at(t,e,i,n)}at.prototype={transform:function(t,e){return this._transform(t.clone(),e)},_transform:function(t,e){return t.x=(e=e||1)*(this._a*t.x+this._b),t.y=e*(this._c*t.y+this._d),t},untransform:function(t,e){return new p((t.x/(e=e||1)-this._b)/this._a,(t.y/e-this._d)/this._c)}};var lt=l({},st,{code:"EPSG:3857",projection:rt,transformation:ht(lt=.5/(Math.PI*rt.R),.5,-lt,.5)}),ut=l({},lt,{code:"EPSG:900913"});function ct(t){return document.createElementNS("http://www.w3.org/2000/svg",t)}function dt(t,e){for(var i,n,o,s,r="",a=0,h=t.length;a<h;a++){for(i=0,n=(o=t[a]).length;i<n;i++)r+=(i?"L":"M")+(s=o[i]).x+" "+s.y;r+=e?b.svg?"z":"x":""}return r||"M0 0"}var _t=document.documentElement.style,pt="ActiveXObject"in window,mt=pt&&!document.addEventListener,n="msLaunchUri"in navigator&&!("documentMode"in document),ft=y("webkit"),gt=y("android"),vt=y("android 2")||y("android 3"),yt=parseInt(/WebKit\/([0-9]+)|$/.exec(navigator.userAgent)[1],10),yt=gt&&y("Google")&&yt<537&&!("AudioNode"in window),xt=!!window.opera,wt=!n&&y("chrome"),bt=y("gecko")&&!ft&&!xt&&!pt,Pt=!wt&&y("safari"),Lt=y("phantom"),o="OTransition"in _t,Tt=0===navigator.platform.indexOf("Win"),Mt=pt&&"transition"in _t,zt="WebKitCSSMatrix"in window&&"m11"in new window.WebKitCSSMatrix&&!vt,_t="MozPerspective"in _t,Ct=!window.L_DISABLE_3D&&(Mt||zt||_t)&&!o&&!Lt,Zt="undefined"!=typeof orientation||y("mobile"),St=Zt&&ft,Et=Zt&&zt,kt=!window.PointerEvent&&window.MSPointerEvent,Ot=!(!window.PointerEvent&&!kt),At="ontouchstart"in window||!!window.TouchEvent,Bt=!window.L_NO_TOUCH&&(At||Ot),It=Zt&&xt,Rt=Zt&&bt,Nt=1<(window.devicePixelRatio||window.screen.deviceXDPI/window.screen.logicalXDPI),Dt=function(){var t=!1;try{var e=Object.defineProperty({},"passive",{get:function(){t=!0}});window.addEventListener("testPassiveEventSupport",u,e),window.removeEventListener("testPassiveEventSupport",u,e)}catch(t){}return t}(),jt=!!document.createElement("canvas").getContext,Ht=!(!document.createElementNS||!ct("svg").createSVGRect),Wt=!!Ht&&((Wt=document.createElement("div")).innerHTML="<svg/>","http://www.w3.org/2000/svg"===(Wt.firstChild&&Wt.firstChild.namespaceURI));function y(t){return 0<=navigator.userAgent.toLowerCase().indexOf(t)}var b={ie:pt,ielt9:mt,edge:n,webkit:ft,android:gt,android23:vt,androidStock:yt,opera:xt,chrome:wt,gecko:bt,safari:Pt,phantom:Lt,opera12:o,win:Tt,ie3d:Mt,webkit3d:zt,gecko3d:_t,any3d:Ct,mobile:Zt,mobileWebkit:St,mobileWebkit3d:Et,msPointer:kt,pointer:Ot,touch:Bt,touchNative:At,mobileOpera:It,mobileGecko:Rt,retina:Nt,passiveEvents:Dt,canvas:jt,svg:Ht,vml:!Ht&&function(){try{var t=document.createElement("div"),e=(t.innerHTML='<v:shape adj="1"/>',t.firstChild);return e.style.behavior="url(#default#VML)",e&&"object"==typeof e.adj}catch(t){return!1}}(),inlineSvg:Wt,mac:0===navigator.platform.indexOf("Mac"),linux:0===navigator.platform.indexOf("Linux")},Ft=b.msPointer?"MSPointerDown":"pointerdown",Ut=b.msPointer?"MSPointerMove":"pointermove",Vt=b.msPointer?"MSPointerUp":"pointerup",qt=b.msPointer?"MSPointerCancel":"pointercancel",Gt={touchstart:Ft,touchmove:Ut,touchend:Vt,touchcancel:qt},Kt={touchstart:function(t,e){e.MSPOINTER_TYPE_TOUCH&&e.pointerType===e.MSPOINTER_TYPE_TOUCH&&O(e);ee(t,e)},touchmove:ee,touchend:ee,touchcancel:ee},Yt={},Xt=!1;function Jt(t,e,i){return"touchstart"!==e||Xt||(document.addEventListener(Ft,$t,!0),document.addEventListener(Ut,Qt,!0),document.addEventListener(Vt,te,!0),document.addEventListener(qt,te,!0),Xt=!0),Kt[e]?(i=Kt[e].bind(this,i),t.addEventListener(Gt[e],i,!1),i):(console.warn("wrong event specified:",e),u)}function $t(t){Yt[t.pointerId]=t}function Qt(t){Yt[t.pointerId]&&(Yt[t.pointerId]=t)}function te(t){delete Yt[t.pointerId]}function ee(t,e){if(e.pointerType!==(e.MSPOINTER_TYPE_MOUSE||"mouse")){for(var i in e.touches=[],Yt)e.touches.push(Yt[i]);e.changedTouches=[e],t(e)}}var ie=200;function ne(t,i){t.addEventListener("dblclick",i);var n,o=0;function e(t){var e;1!==t.detail?n=t.detail:"mouse"===t.pointerType||t.sourceCapabilities&&!t.sourceCapabilities.firesTouchEvents||((e=Ne(t)).some(function(t){return t instanceof HTMLLabelElement&&t.attributes.for})&&!e.some(function(t){return t instanceof HTMLInputElement||t instanceof HTMLSelectElement})||((e=Date.now())-o<=ie?2===++n&&i(function(t){var e,i,n={};for(i in t)e=t[i],n[i]=e&&e.bind?e.bind(t):e;return(t=n).type="dblclick",n.detail=2,n.isTrusted=!1,n._simulated=!0,n}(t)):n=1,o=e))}return t.addEventListener("click",e),{dblclick:i,simDblclick:e}}var oe,se,re,ae,he,le,ue=we(["transform","webkitTransform","OTransform","MozTransform","msTransform"]),ce=we(["webkitTransition","transition","OTransition","MozTransition","msTransition"]),de="webkitTransition"===ce||"OTransition"===ce?ce+"End":"transitionend";function _e(t){return"string"==typeof t?document.getElementById(t):t}function pe(t,e){var i=t.style[e]||t.currentStyle&&t.currentStyle[e];return"auto"===(i=i&&"auto"!==i||!document.defaultView?i:(t=document.defaultView.getComputedStyle(t,null))?t[e]:null)?null:i}function P(t,e,i){t=document.createElement(t);return t.className=e||"",i&&i.appendChild(t),t}function T(t){var e=t.parentNode;e&&e.removeChild(t)}function me(t){for(;t.firstChild;)t.removeChild(t.firstChild)}function fe(t){var e=t.parentNode;e&&e.lastChild!==t&&e.appendChild(t)}function ge(t){var e=t.parentNode;e&&e.firstChild!==t&&e.insertBefore(t,e.firstChild)}function ve(t,e){return void 0!==t.classList?t.classList.contains(e):0<(t=xe(t)).length&&new RegExp("(^|\\s)"+e+"(\\s|$)").test(t)}function M(t,e){var i;if(void 0!==t.classList)for(var n=F(e),o=0,s=n.length;o<s;o++)t.classList.add(n[o]);else ve(t,e)||ye(t,((i=xe(t))?i+" ":"")+e)}function z(t,e){void 0!==t.classList?t.classList.remove(e):ye(t,W((" "+xe(t)+" ").replace(" "+e+" "," ")))}function ye(t,e){void 0===t.className.baseVal?t.className=e:t.className.baseVal=e}function xe(t){return void 0===(t=t.correspondingElement?t.correspondingElement:t).className.baseVal?t.className:t.className.baseVal}function C(t,e){if("opacity"in t.style)t.style.opacity=e;else if("filter"in t.style){var i=!1,n="DXImageTransform.Microsoft.Alpha";try{i=t.filters.item(n)}catch(t){if(1===e)return}e=Math.round(100*e),i?(i.Enabled=100!==e,i.Opacity=e):t.style.filter+=" progid:"+n+"(opacity="+e+")"}}function we(t){for(var e=document.documentElement.style,i=0;i<t.length;i++)if(t[i]in e)return t[i];return!1}function be(t,e,i){e=e||new p(0,0);t.style[ue]=(b.ie3d?"translate("+e.x+"px,"+e.y+"px)":"translate3d("+e.x+"px,"+e.y+"px,0)")+(i?" scale("+i+")":"")}function Z(t,e){t._leaflet_pos=e,b.any3d?be(t,e):(t.style.left=e.x+"px",t.style.top=e.y+"px")}function Pe(t){return t._leaflet_pos||new p(0,0)}function Le(){S(window,"dragstart",O)}function Te(){k(window,"dragstart",O)}function Me(t){for(;-1===t.tabIndex;)t=t.parentNode;t.style&&(ze(),le=(he=t).style.outlineStyle,t.style.outlineStyle="none",S(window,"keydown",ze))}function ze(){he&&(he.style.outlineStyle=le,le=he=void 0,k(window,"keydown",ze))}function Ce(t){for(;!((t=t.parentNode).offsetWidth&&t.offsetHeight||t===document.body););return t}function Ze(t){var e=t.getBoundingClientRect();return{x:e.width/t.offsetWidth||1,y:e.height/t.offsetHeight||1,boundingClientRect:e}}ae="onselectstart"in document?(re=function(){S(window,"selectstart",O)},function(){k(window,"selectstart",O)}):(se=we(["userSelect","WebkitUserSelect","OUserSelect","MozUserSelect","msUserSelect"]),re=function(){var t;se&&(t=document.documentElement.style,oe=t[se],t[se]="none")},function(){se&&(document.documentElement.style[se]=oe,oe=void 0)});pt={__proto__:null,TRANSFORM:ue,TRANSITION:ce,TRANSITION_END:de,get:_e,getStyle:pe,create:P,remove:T,empty:me,toFront:fe,toBack:ge,hasClass:ve,addClass:M,removeClass:z,setClass:ye,getClass:xe,setOpacity:C,testProp:we,setTransform:be,setPosition:Z,getPosition:Pe,get disableTextSelection(){return re},get enableTextSelection(){return ae},disableImageDrag:Le,enableImageDrag:Te,preventOutline:Me,restoreOutline:ze,getSizedParentNode:Ce,getScale:Ze};function S(t,e,i,n){if(e&&"object"==typeof e)for(var o in e)ke(t,o,e[o],i);else for(var s=0,r=(e=F(e)).length;s<r;s++)ke(t,e[s],i,n);return this}var E="_leaflet_events";function k(t,e,i,n){if(1===arguments.length)Se(t),delete t[E];else if(e&&"object"==typeof e)for(var o in e)Oe(t,o,e[o],i);else if(e=F(e),2===arguments.length)Se(t,function(t){return-1!==G(e,t)});else for(var s=0,r=e.length;s<r;s++)Oe(t,e[s],i,n);return this}function Se(t,e){for(var i in t[E]){var n=i.split(/\d/)[0];e&&!e(n)||Oe(t,n,null,null,i)}}var Ee={mouseenter:"mouseover",mouseleave:"mouseout",wheel:!("onwheel"in window)&&"mousewheel"};function ke(e,t,i,n){var o,s,r=t+h(i)+(n?"_"+h(n):"");e[E]&&e[E][r]||(s=o=function(t){return i.call(n||e,t||window.event)},!b.touchNative&&b.pointer&&0===t.indexOf("touch")?o=Jt(e,t,o):b.touch&&"dblclick"===t?o=ne(e,o):"addEventListener"in e?"touchstart"===t||"touchmove"===t||"wheel"===t||"mousewheel"===t?e.addEventListener(Ee[t]||t,o,!!b.passiveEvents&&{passive:!1}):"mouseenter"===t||"mouseleave"===t?e.addEventListener(Ee[t],o=function(t){t=t||window.event,We(e,t)&&s(t)},!1):e.addEventListener(t,s,!1):e.attachEvent("on"+t,o),e[E]=e[E]||{},e[E][r]=o)}function Oe(t,e,i,n,o){o=o||e+h(i)+(n?"_"+h(n):"");var s,r,i=t[E]&&t[E][o];i&&(!b.touchNative&&b.pointer&&0===e.indexOf("touch")?(n=t,r=i,Gt[s=e]?n.removeEventListener(Gt[s],r,!1):console.warn("wrong event specified:",s)):b.touch&&"dblclick"===e?(n=i,(r=t).removeEventListener("dblclick",n.dblclick),r.removeEventListener("click",n.simDblclick)):"removeEventListener"in t?t.removeEventListener(Ee[e]||e,i,!1):t.detachEvent("on"+e,i),t[E][o]=null)}function Ae(t){return t.stopPropagation?t.stopPropagation():t.originalEvent?t.originalEvent._stopped=!0:t.cancelBubble=!0,this}function Be(t){return ke(t,"wheel",Ae),this}function Ie(t){return S(t,"mousedown touchstart dblclick contextmenu",Ae),t._leaflet_disable_click=!0,this}function O(t){return t.preventDefault?t.preventDefault():t.returnValue=!1,this}function Re(t){return O(t),Ae(t),this}function Ne(t){if(t.composedPath)return t.composedPath();for(var e=[],i=t.target;i;)e.push(i),i=i.parentNode;return e}function De(t,e){var i,n;return e?(n=(i=Ze(e)).boundingClientRect,new p((t.clientX-n.left)/i.x-e.clientLeft,(t.clientY-n.top)/i.y-e.clientTop)):new p(t.clientX,t.clientY)}var je=b.linux&&b.chrome?window.devicePixelRatio:b.mac?3*window.devicePixelRatio:0<window.devicePixelRatio?2*window.devicePixelRatio:1;function He(t){return b.edge?t.wheelDeltaY/2:t.deltaY&&0===t.deltaMode?-t.deltaY/je:t.deltaY&&1===t.deltaMode?20*-t.deltaY:t.deltaY&&2===t.deltaMode?60*-t.deltaY:t.deltaX||t.deltaZ?0:t.wheelDelta?(t.wheelDeltaY||t.wheelDelta)/2:t.detail&&Math.abs(t.detail)<32765?20*-t.detail:t.detail?t.detail/-32765*60:0}function We(t,e){var i=e.relatedTarget;if(!i)return!0;try{for(;i&&i!==t;)i=i.parentNode}catch(t){return!1}return i!==t}var mt={__proto__:null,on:S,off:k,stopPropagation:Ae,disableScrollPropagation:Be,disableClickPropagation:Ie,preventDefault:O,stop:Re,getPropagationPath:Ne,getMousePosition:De,getWheelDelta:He,isExternalTarget:We,addListener:S,removeListener:k},Fe=it.extend({run:function(t,e,i,n){this.stop(),this._el=t,this._inProgress=!0,this._duration=i||.25,this._easeOutPower=1/Math.max(n||.5,.2),this._startPos=Pe(t),this._offset=e.subtract(this._startPos),this._startTime=+new Date,this.fire("start"),this._animate()},stop:function(){this._inProgress&&(this._step(!0),this._complete())},_animate:function(){this._animId=x(this._animate,this),this._step()},_step:function(t){var e=+new Date-this._startTime,i=1e3*this._duration;e<i?this._runFrame(this._easeOut(e/i),t):(this._runFrame(1),this._complete())},_runFrame:function(t,e){t=this._startPos.add(this._offset.multiplyBy(t));e&&t._round(),Z(this._el,t),this.fire("step")},_complete:function(){r(this._animId),this._inProgress=!1,this.fire("end")},_easeOut:function(t){return 1-Math.pow(1-t,this._easeOutPower)}}),A=it.extend({options:{crs:lt,center:void 0,zoom:void 0,minZoom:void 0,maxZoom:void 0,layers:[],maxBounds:void 0,renderer:void 0,zoomAnimation:!0,zoomAnimationThreshold:4,fadeAnimation:!0,markerZoomAnimation:!0,transform3DLimit:8388608,zoomSnap:1,zoomDelta:1,trackResize:!0},initialize:function(t,e){e=c(this,e),this._handlers=[],this._layers={},this._zoomBoundLayers={},this._sizeChanged=!0,this._initContainer(t),this._initLayout(),this._onResize=a(this._onResize,this),this._initEvents(),e.maxBounds&&this.setMaxBounds(e.maxBounds),void 0!==e.zoom&&(this._zoom=this._limitZoom(e.zoom)),e.center&&void 0!==e.zoom&&this.setView(w(e.center),e.zoom,{reset:!0}),this.callInitHooks(),this._zoomAnimated=ce&&b.any3d&&!b.mobileOpera&&this.options.zoomAnimation,this._zoomAnimated&&(this._createAnimProxy(),S(this._proxy,de,this._catchTransitionEnd,this)),this._addLayers(this.options.layers)},setView:function(t,e,i){if((e=void 0===e?this._zoom:this._limitZoom(e),t=this._limitCenter(w(t),e,this.options.maxBounds),i=i||{},this._stop(),this._loaded&&!i.reset&&!0!==i)&&(void 0!==i.animate&&(i.zoom=l({animate:i.animate},i.zoom),i.pan=l({animate:i.animate,duration:i.duration},i.pan)),this._zoom!==e?this._tryAnimatedZoom&&this._tryAnimatedZoom(t,e,i.zoom):this._tryAnimatedPan(t,i.pan)))return clearTimeout(this._sizeTimer),this;return this._resetView(t,e,i.pan&&i.pan.noMoveStart),this},setZoom:function(t,e){return this._loaded?this.setView(this.getCenter(),t,{zoom:e}):(this._zoom=t,this)},zoomIn:function(t,e){return t=t||(b.any3d?this.options.zoomDelta:1),this.setZoom(this._zoom+t,e)},zoomOut:function(t,e){return t=t||(b.any3d?this.options.zoomDelta:1),this.setZoom(this._zoom-t,e)},setZoomAround:function(t,e,i){var n=this.getZoomScale(e),o=this.getSize().divideBy(2),t=(t instanceof p?t:this.latLngToContainerPoint(t)).subtract(o).multiplyBy(1-1/n),n=this.containerPointToLatLng(o.add(t));return this.setView(n,e,{zoom:i})},_getBoundsCenterZoom:function(t,e){e=e||{},t=t.getBounds?t.getBounds():g(t);var i=m(e.paddingTopLeft||e.padding||[0,0]),n=m(e.paddingBottomRight||e.padding||[0,0]),o=this.getBoundsZoom(t,!1,i.add(n));return(o="number"==typeof e.maxZoom?Math.min(e.maxZoom,o):o)===1/0?{center:t.getCenter(),zoom:o}:(e=n.subtract(i).divideBy(2),n=this.project(t.getSouthWest(),o),i=this.project(t.getNorthEast(),o),{center:this.unproject(n.add(i).divideBy(2).add(e),o),zoom:o})},fitBounds:function(t,e){if((t=g(t)).isValid())return t=this._getBoundsCenterZoom(t,e),this.setView(t.center,t.zoom,e);throw new Error("Bounds are not valid.")},fitWorld:function(t){return this.fitBounds([[-90,-180],[90,180]],t)},panTo:function(t,e){return this.setView(t,this._zoom,{pan:e})},panBy:function(t,e){var i;return e=e||{},(t=m(t).round()).x||t.y?(!0===e.animate||this.getSize().contains(t)?(this._panAnim||(this._panAnim=new Fe,this._panAnim.on({step:this._onPanTransitionStep,end:this._onPanTransitionEnd},this)),e.noMoveStart||this.fire("movestart"),!1!==e.animate?(M(this._mapPane,"leaflet-pan-anim"),i=this._getMapPanePos().subtract(t).round(),this._panAnim.run(this._mapPane,i,e.duration||.25,e.easeLinearity)):(this._rawPanBy(t),this.fire("move").fire("moveend"))):this._resetView(this.unproject(this.project(this.getCenter()).add(t)),this.getZoom()),this):this.fire("moveend")},flyTo:function(n,o,t){if(!1===(t=t||{}).animate||!b.any3d)return this.setView(n,o,t);this._stop();var s=this.project(this.getCenter()),r=this.project(n),e=this.getSize(),a=this._zoom,h=(n=w(n),o=void 0===o?a:o,Math.max(e.x,e.y)),i=h*this.getZoomScale(a,o),l=r.distanceTo(s)||1,u=1.42,c=u*u;function d(t){t=(i*i-h*h+(t?-1:1)*c*c*l*l)/(2*(t?i:h)*c*l),t=Math.sqrt(t*t+1)-t;return t<1e-9?-18:Math.log(t)}function _(t){return(Math.exp(t)-Math.exp(-t))/2}function p(t){return(Math.exp(t)+Math.exp(-t))/2}var m=d(0);function f(t){return h*(p(m)*(_(t=m+u*t)/p(t))-_(m))/c}var g=Date.now(),v=(d(1)-m)/u,y=t.duration?1e3*t.duration:1e3*v*.8;return this._moveStart(!0,t.noMoveStart),function t(){var e=(Date.now()-g)/y,i=(1-Math.pow(1-e,1.5))*v;e<=1?(this._flyToFrame=x(t,this),this._move(this.unproject(s.add(r.subtract(s).multiplyBy(f(i)/l)),a),this.getScaleZoom(h/(e=i,h*(p(m)/p(m+u*e))),a),{flyTo:!0})):this._move(n,o)._moveEnd(!0)}.call(this),this},flyToBounds:function(t,e){t=this._getBoundsCenterZoom(t,e);return this.flyTo(t.center,t.zoom,e)},setMaxBounds:function(t){return t=g(t),this.listens("moveend",this._panInsideMaxBounds)&&this.off("moveend",this._panInsideMaxBounds),t.isValid()?(this.options.maxBounds=t,this._loaded&&this._panInsideMaxBounds(),this.on("moveend",this._panInsideMaxBounds)):(this.options.maxBounds=null,this)},setMinZoom:function(t){var e=this.options.minZoom;return this.options.minZoom=t,this._loaded&&e!==t&&(this.fire("zoomlevelschange"),this.getZoom()<this.options.minZoom)?this.setZoom(t):this},setMaxZoom:function(t){var e=this.options.maxZoom;return this.options.maxZoom=t,this._loaded&&e!==t&&(this.fire("zoomlevelschange"),this.getZoom()>this.options.maxZoom)?this.setZoom(t):this},panInsideBounds:function(t,e){this._enforcingBounds=!0;var i=this.getCenter(),t=this._limitCenter(i,this._zoom,g(t));return i.equals(t)||this.panTo(t,e),this._enforcingBounds=!1,this},panInside:function(t,e){var i=m((e=e||{}).paddingTopLeft||e.padding||[0,0]),n=m(e.paddingBottomRight||e.padding||[0,0]),o=this.project(this.getCenter()),t=this.project(t),s=this.getPixelBounds(),i=_([s.min.add(i),s.max.subtract(n)]),s=i.getSize();return i.contains(t)||(this._enforcingBounds=!0,n=t.subtract(i.getCenter()),i=i.extend(t).getSize().subtract(s),o.x+=n.x<0?-i.x:i.x,o.y+=n.y<0?-i.y:i.y,this.panTo(this.unproject(o),e),this._enforcingBounds=!1),this},invalidateSize:function(t){if(!this._loaded)return this;t=l({animate:!1,pan:!0},!0===t?{animate:!0}:t);var e=this.getSize(),i=(this._sizeChanged=!0,this._lastCenter=null,this.getSize()),n=e.divideBy(2).round(),o=i.divideBy(2).round(),n=n.subtract(o);return n.x||n.y?(t.animate&&t.pan?this.panBy(n):(t.pan&&this._rawPanBy(n),this.fire("move"),t.debounceMoveend?(clearTimeout(this._sizeTimer),this._sizeTimer=setTimeout(a(this.fire,this,"moveend"),200)):this.fire("moveend")),this.fire("resize",{oldSize:e,newSize:i})):this},stop:function(){return this.setZoom(this._limitZoom(this._zoom)),this.options.zoomSnap||this.fire("viewreset"),this._stop()},locate:function(t){var e,i;return t=this._locateOptions=l({timeout:1e4,watch:!1},t),"geolocation"in navigator?(e=a(this._handleGeolocationResponse,this),i=a(this._handleGeolocationError,this),t.watch?this._locationWatchId=navigator.geolocation.watchPosition(e,i,t):navigator.geolocation.getCurrentPosition(e,i,t)):this._handleGeolocationError({code:0,message:"Geolocation not supported."}),this},stopLocate:function(){return navigator.geolocation&&navigator.geolocation.clearWatch&&navigator.geolocation.clearWatch(this._locationWatchId),this._locateOptions&&(this._locateOptions.setView=!1),this},_handleGeolocationError:function(t){var e;this._container._leaflet_id&&(e=t.code,t=t.message||(1===e?"permission denied":2===e?"position unavailable":"timeout"),this._locateOptions.setView&&!this._loaded&&this.fitWorld(),this.fire("locationerror",{code:e,message:"Geolocation error: "+t+"."}))},_handleGeolocationResponse:function(t){if(this._container._leaflet_id){var e,i,n=new v(t.coords.latitude,t.coords.longitude),o=n.toBounds(2*t.coords.accuracy),s=this._locateOptions,r=(s.setView&&(e=this.getBoundsZoom(o),this.setView(n,s.maxZoom?Math.min(e,s.maxZoom):e)),{latlng:n,bounds:o,timestamp:t.timestamp});for(i in t.coords)"number"==typeof t.coords[i]&&(r[i]=t.coords[i]);this.fire("locationfound",r)}},addHandler:function(t,e){return e&&(e=this[t]=new e(this),this._handlers.push(e),this.options[t]&&e.enable()),this},remove:function(){if(this._initEvents(!0),this.options.maxBounds&&this.off("moveend",this._panInsideMaxBounds),this._containerId!==this._container._leaflet_id)throw new Error("Map container is being reused by another instance");try{delete this._container._leaflet_id,delete this._containerId}catch(t){this._container._leaflet_id=void 0,this._containerId=void 0}for(var t in void 0!==this._locationWatchId&&this.stopLocate(),this._stop(),T(this._mapPane),this._clearControlPos&&this._clearControlPos(),this._resizeRequest&&(r(this._resizeRequest),this._resizeRequest=null),this._clearHandlers(),this._loaded&&this.fire("unload"),this._layers)this._layers[t].remove();for(t in this._panes)T(this._panes[t]);return this._layers=[],this._panes=[],delete this._mapPane,delete this._renderer,this},createPane:function(t,e){e=P("div","leaflet-pane"+(t?" leaflet-"+t.replace("Pane","")+"-pane":""),e||this._mapPane);return t&&(this._panes[t]=e),e},getCenter:function(){return this._checkIfLoaded(),this._lastCenter&&!this._moved()?this._lastCenter.clone():this.layerPointToLatLng(this._getCenterLayerPoint())},getZoom:function(){return this._zoom},getBounds:function(){var t=this.getPixelBounds();return new s(this.unproject(t.getBottomLeft()),this.unproject(t.getTopRight()))},getMinZoom:function(){return void 0===this.options.minZoom?this._layersMinZoom||0:this.options.minZoom},getMaxZoom:function(){return void 0===this.options.maxZoom?void 0===this._layersMaxZoom?1/0:this._layersMaxZoom:this.options.maxZoom},getBoundsZoom:function(t,e,i){t=g(t),i=m(i||[0,0]);var n=this.getZoom()||0,o=this.getMinZoom(),s=this.getMaxZoom(),r=t.getNorthWest(),t=t.getSouthEast(),i=this.getSize().subtract(i),t=_(this.project(t,n),this.project(r,n)).getSize(),r=b.any3d?this.options.zoomSnap:1,a=i.x/t.x,i=i.y/t.y,t=e?Math.max(a,i):Math.min(a,i),n=this.getScaleZoom(t,n);return r&&(n=Math.round(n/(r/100))*(r/100),n=e?Math.ceil(n/r)*r:Math.floor(n/r)*r),Math.max(o,Math.min(s,n))},getSize:function(){return this._size&&!this._sizeChanged||(this._size=new p(this._container.clientWidth||0,this._container.clientHeight||0),this._sizeChanged=!1),this._size.clone()},getPixelBounds:function(t,e){t=this._getTopLeftPoint(t,e);return new f(t,t.add(this.getSize()))},getPixelOrigin:function(){return this._checkIfLoaded(),this._pixelOrigin},getPixelWorldBounds:function(t){return this.options.crs.getProjectedBounds(void 0===t?this.getZoom():t)},getPane:function(t){return"string"==typeof t?this._panes[t]:t},getPanes:function(){return this._panes},getContainer:function(){return this._container},getZoomScale:function(t,e){var i=this.options.crs;return e=void 0===e?this._zoom:e,i.scale(t)/i.scale(e)},getScaleZoom:function(t,e){var i=this.options.crs,t=(e=void 0===e?this._zoom:e,i.zoom(t*i.scale(e)));return isNaN(t)?1/0:t},project:function(t,e){return e=void 0===e?this._zoom:e,this.options.crs.latLngToPoint(w(t),e)},unproject:function(t,e){return e=void 0===e?this._zoom:e,this.options.crs.pointToLatLng(m(t),e)},layerPointToLatLng:function(t){t=m(t).add(this.getPixelOrigin());return this.unproject(t)},latLngToLayerPoint:function(t){return this.project(w(t))._round()._subtract(this.getPixelOrigin())},wrapLatLng:function(t){return this.options.crs.wrapLatLng(w(t))},wrapLatLngBounds:function(t){return this.options.crs.wrapLatLngBounds(g(t))},distance:function(t,e){return this.options.crs.distance(w(t),w(e))},containerPointToLayerPoint:function(t){return m(t).subtract(this._getMapPanePos())},layerPointToContainerPoint:function(t){return m(t).add(this._getMapPanePos())},containerPointToLatLng:function(t){t=this.containerPointToLayerPoint(m(t));return this.layerPointToLatLng(t)},latLngToContainerPoint:function(t){return this.layerPointToContainerPoint(this.latLngToLayerPoint(w(t)))},mouseEventToContainerPoint:function(t){return De(t,this._container)},mouseEventToLayerPoint:function(t){return this.containerPointToLayerPoint(this.mouseEventToContainerPoint(t))},mouseEventToLatLng:function(t){return this.layerPointToLatLng(this.mouseEventToLayerPoint(t))},_initContainer:function(t){t=this._container=_e(t);if(!t)throw new Error("Map container not found.");if(t._leaflet_id)throw new Error("Map container is already initialized.");S(t,"scroll",this._onScroll,this),this._containerId=h(t)},_initLayout:function(){var t=this._container,e=(this._fadeAnimated=this.options.fadeAnimation&&b.any3d,M(t,"leaflet-container"+(b.touch?" leaflet-touch":"")+(b.retina?" leaflet-retina":"")+(b.ielt9?" leaflet-oldie":"")+(b.safari?" leaflet-safari":"")+(this._fadeAnimated?" leaflet-fade-anim":"")),pe(t,"position"));"absolute"!==e&&"relative"!==e&&"fixed"!==e&&"sticky"!==e&&(t.style.position="relative"),this._initPanes(),this._initControlPos&&this._initControlPos()},_initPanes:function(){var t=this._panes={};this._paneRenderers={},this._mapPane=this.createPane("mapPane",this._container),Z(this._mapPane,new p(0,0)),this.createPane("tilePane"),this.createPane("overlayPane"),this.createPane("shadowPane"),this.createPane("markerPane"),this.createPane("tooltipPane"),this.createPane("popupPane"),this.options.markerZoomAnimation||(M(t.markerPane,"leaflet-zoom-hide"),M(t.shadowPane,"leaflet-zoom-hide"))},_resetView:function(t,e,i){Z(this._mapPane,new p(0,0));var n=!this._loaded,o=(this._loaded=!0,e=this._limitZoom(e),this.fire("viewprereset"),this._zoom!==e);this._moveStart(o,i)._move(t,e)._moveEnd(o),this.fire("viewreset"),n&&this.fire("load")},_moveStart:function(t,e){return t&&this.fire("zoomstart"),e||this.fire("movestart"),this},_move:function(t,e,i,n){void 0===e&&(e=this._zoom);var o=this._zoom!==e;return this._zoom=e,this._lastCenter=t,this._pixelOrigin=this._getNewPixelOrigin(t),n?i&&i.pinch&&this.fire("zoom",i):((o||i&&i.pinch)&&this.fire("zoom",i),this.fire("move",i)),this},_moveEnd:function(t){return t&&this.fire("zoomend"),this.fire("moveend")},_stop:function(){return r(this._flyToFrame),this._panAnim&&this._panAnim.stop(),this},_rawPanBy:function(t){Z(this._mapPane,this._getMapPanePos().subtract(t))},_getZoomSpan:function(){return this.getMaxZoom()-this.getMinZoom()},_panInsideMaxBounds:function(){this._enforcingBounds||this.panInsideBounds(this.options.maxBounds)},_checkIfLoaded:function(){if(!this._loaded)throw new Error("Set map center and zoom first.")},_initEvents:function(t){this._targets={};var e=t?k:S;e((this._targets[h(this._container)]=this)._container,"click dblclick mousedown mouseup mouseover mouseout mousemove contextmenu keypress keydown keyup",this._handleDOMEvent,this),this.options.trackResize&&e(window,"resize",this._onResize,this),b.any3d&&this.options.transform3DLimit&&(t?this.off:this.on).call(this,"moveend",this._onMoveEnd)},_onResize:function(){r(this._resizeRequest),this._resizeRequest=x(function(){this.invalidateSize({debounceMoveend:!0})},this)},_onScroll:function(){this._container.scrollTop=0,this._container.scrollLeft=0},_onMoveEnd:function(){var t=this._getMapPanePos();Math.max(Math.abs(t.x),Math.abs(t.y))>=this.options.transform3DLimit&&this._resetView(this.getCenter(),this.getZoom())},_findEventTargets:function(t,e){for(var i,n=[],o="mouseout"===e||"mouseover"===e,s=t.target||t.srcElement,r=!1;s;){if((i=this._targets[h(s)])&&("click"===e||"preclick"===e)&&this._draggableMoved(i)){r=!0;break}if(i&&i.listens(e,!0)){if(o&&!We(s,t))break;if(n.push(i),o)break}if(s===this._container)break;s=s.parentNode}return n=n.length||r||o||!this.listens(e,!0)?n:[this]},_isClickDisabled:function(t){for(;t&&t!==this._container;){if(t._leaflet_disable_click)return!0;t=t.parentNode}},_handleDOMEvent:function(t){var e,i=t.target||t.srcElement;!this._loaded||i._leaflet_disable_events||"click"===t.type&&this._isClickDisabled(i)||("mousedown"===(e=t.type)&&Me(i),this._fireDOMEvent(t,e))},_mouseEvents:["click","dblclick","mouseover","mouseout","contextmenu"],_fireDOMEvent:function(t,e,i){"click"===t.type&&((a=l({},t)).type="preclick",this._fireDOMEvent(a,a.type,i));var n=this._findEventTargets(t,e);if(i){for(var o=[],s=0;s<i.length;s++)i[s].listens(e,!0)&&o.push(i[s]);n=o.concat(n)}if(n.length){"contextmenu"===e&&O(t);var r,a=n[0],h={originalEvent:t};for("keypress"!==t.type&&"keydown"!==t.type&&"keyup"!==t.type&&(r=a.getLatLng&&(!a._radius||a._radius<=10),h.containerPoint=r?this.latLngToContainerPoint(a.getLatLng()):this.mouseEventToContainerPoint(t),h.layerPoint=this.containerPointToLayerPoint(h.containerPoint),h.latlng=r?a.getLatLng():this.layerPointToLatLng(h.layerPoint)),s=0;s<n.length;s++)if(n[s].fire(e,h,!0),h.originalEvent._stopped||!1===n[s].options.bubblingMouseEvents&&-1!==G(this._mouseEvents,e))return}},_draggableMoved:function(t){return(t=t.dragging&&t.dragging.enabled()?t:this).dragging&&t.dragging.moved()||this.boxZoom&&this.boxZoom.moved()},_clearHandlers:function(){for(var t=0,e=this._handlers.length;t<e;t++)this._handlers[t].disable()},whenReady:function(t,e){return this._loaded?t.call(e||this,{target:this}):this.on("load",t,e),this},_getMapPanePos:function(){return Pe(this._mapPane)||new p(0,0)},_moved:function(){var t=this._getMapPanePos();return t&&!t.equals([0,0])},_getTopLeftPoint:function(t,e){return(t&&void 0!==e?this._getNewPixelOrigin(t,e):this.getPixelOrigin()).subtract(this._getMapPanePos())},_getNewPixelOrigin:function(t,e){var i=this.getSize()._divideBy(2);return this.project(t,e)._subtract(i)._add(this._getMapPanePos())._round()},_latLngToNewLayerPoint:function(t,e,i){i=this._getNewPixelOrigin(i,e);return this.project(t,e)._subtract(i)},_latLngBoundsToNewLayerBounds:function(t,e,i){i=this._getNewPixelOrigin(i,e);return _([this.project(t.getSouthWest(),e)._subtract(i),this.project(t.getNorthWest(),e)._subtract(i),this.project(t.getSouthEast(),e)._subtract(i),this.project(t.getNorthEast(),e)._subtract(i)])},_getCenterLayerPoint:function(){return this.containerPointToLayerPoint(this.getSize()._divideBy(2))},_getCenterOffset:function(t){return this.latLngToLayerPoint(t).subtract(this._getCenterLayerPoint())},_limitCenter:function(t,e,i){var n,o;return!i||(n=this.project(t,e),o=this.getSize().divideBy(2),o=new f(n.subtract(o),n.add(o)),o=this._getBoundsOffset(o,i,e),Math.abs(o.x)<=1&&Math.abs(o.y)<=1)?t:this.unproject(n.add(o),e)},_limitOffset:function(t,e){var i;return e?(i=new f((i=this.getPixelBounds()).min.add(t),i.max.add(t)),t.add(this._getBoundsOffset(i,e))):t},_getBoundsOffset:function(t,e,i){e=_(this.project(e.getNorthEast(),i),this.project(e.getSouthWest(),i)),i=e.min.subtract(t.min),e=e.max.subtract(t.max);return new p(this._rebound(i.x,-e.x),this._rebound(i.y,-e.y))},_rebound:function(t,e){return 0<t+e?Math.round(t-e)/2:Math.max(0,Math.ceil(t))-Math.max(0,Math.floor(e))},_limitZoom:function(t){var e=this.getMinZoom(),i=this.getMaxZoom(),n=b.any3d?this.options.zoomSnap:1;return n&&(t=Math.round(t/n)*n),Math.max(e,Math.min(i,t))},_onPanTransitionStep:function(){this.fire("move")},_onPanTransitionEnd:function(){z(this._mapPane,"leaflet-pan-anim"),this.fire("moveend")},_tryAnimatedPan:function(t,e){t=this._getCenterOffset(t)._trunc();return!(!0!==(e&&e.animate)&&!this.getSize().contains(t))&&(this.panBy(t,e),!0)},_createAnimProxy:function(){var t=this._proxy=P("div","leaflet-proxy leaflet-zoom-animated");this._panes.mapPane.appendChild(t),this.on("zoomanim",function(t){var e=ue,i=this._proxy.style[e];be(this._proxy,this.project(t.center,t.zoom),this.getZoomScale(t.zoom,1)),i===this._proxy.style[e]&&this._animatingZoom&&this._onZoomTransitionEnd()},this),this.on("load moveend",this._animMoveEnd,this),this._on("unload",this._destroyAnimProxy,this)},_destroyAnimProxy:function(){T(this._proxy),this.off("load moveend",this._animMoveEnd,this),delete this._proxy},_animMoveEnd:function(){var t=this.getCenter(),e=this.getZoom();be(this._proxy,this.project(t,e),this.getZoomScale(e,1))},_catchTransitionEnd:function(t){this._animatingZoom&&0<=t.propertyName.indexOf("transform")&&this._onZoomTransitionEnd()},_nothingToAnimate:function(){return!this._container.getElementsByClassName("leaflet-zoom-animated").length},_tryAnimatedZoom:function(t,e,i){if(!this._animatingZoom){if(i=i||{},!this._zoomAnimated||!1===i.animate||this._nothingToAnimate()||Math.abs(e-this._zoom)>this.options.zoomAnimationThreshold)return!1;var n=this.getZoomScale(e),n=this._getCenterOffset(t)._divideBy(1-1/n);if(!0!==i.animate&&!this.getSize().contains(n))return!1;x(function(){this._moveStart(!0,i.noMoveStart||!1)._animateZoom(t,e,!0)},this)}return!0},_animateZoom:function(t,e,i,n){this._mapPane&&(i&&(this._animatingZoom=!0,this._animateToCenter=t,this._animateToZoom=e,M(this._mapPane,"leaflet-zoom-anim")),this.fire("zoomanim",{center:t,zoom:e,noUpdate:n}),this._tempFireZoomEvent||(this._tempFireZoomEvent=this._zoom!==this._animateToZoom),this._move(this._animateToCenter,this._animateToZoom,void 0,!0),setTimeout(a(this._onZoomTransitionEnd,this),250))},_onZoomTransitionEnd:function(){this._animatingZoom&&(this._mapPane&&z(this._mapPane,"leaflet-zoom-anim"),this._animatingZoom=!1,this._move(this._animateToCenter,this._animateToZoom,void 0,!0),this._tempFireZoomEvent&&this.fire("zoom"),delete this._tempFireZoomEvent,this.fire("move"),this._moveEnd(!0))}});function Ue(t){return new B(t)}var B=et.extend({options:{position:"topright"},initialize:function(t){c(this,t)},getPosition:function(){return this.options.position},setPosition:function(t){var e=this._map;return e&&e.removeControl(this),this.options.position=t,e&&e.addControl(this),this},getContainer:function(){return this._container},addTo:function(t){this.remove(),this._map=t;var e=this._container=this.onAdd(t),i=this.getPosition(),t=t._controlCorners[i];return M(e,"leaflet-control"),-1!==i.indexOf("bottom")?t.insertBefore(e,t.firstChild):t.appendChild(e),this._map.on("unload",this.remove,this),this},remove:function(){return this._map&&(T(this._container),this.onRemove&&this.onRemove(this._map),this._map.off("unload",this.remove,this),this._map=null),this},_refocusOnMap:function(t){this._map&&t&&0<t.screenX&&0<t.screenY&&this._map.getContainer().focus()}}),Ve=(A.include({addControl:function(t){return t.addTo(this),this},removeControl:function(t){return t.remove(),this},_initControlPos:function(){var i=this._controlCorners={},n="leaflet-",o=this._controlContainer=P("div",n+"control-container",this._container);function t(t,e){i[t+e]=P("div",n+t+" "+n+e,o)}t("top","left"),t("top","right"),t("bottom","left"),t("bottom","right")},_clearControlPos:function(){for(var t in this._controlCorners)T(this._controlCorners[t]);T(this._controlContainer),delete this._controlCorners,delete this._controlContainer}}),B.extend({options:{collapsed:!0,position:"topright",autoZIndex:!0,hideSingleBase:!1,sortLayers:!1,sortFunction:function(t,e,i,n){return i<n?-1:n<i?1:0}},initialize:function(t,e,i){for(var n in c(this,i),this._layerControlInputs=[],this._layers=[],this._lastZIndex=0,this._handlingClick=!1,this._preventClick=!1,t)this._addLayer(t[n],n);for(n in e)this._addLayer(e[n],n,!0)},onAdd:function(t){this._initLayout(),this._update(),(this._map=t).on("zoomend",this._checkDisabledLayers,this);for(var e=0;e<this._layers.length;e++)this._layers[e].layer.on("add remove",this._onLayerChange,this);return this._container},addTo:function(t){return B.prototype.addTo.call(this,t),this._expandIfNotCollapsed()},onRemove:function(){this._map.off("zoomend",this._checkDisabledLayers,this);for(var t=0;t<this._layers.length;t++)this._layers[t].layer.off("add remove",this._onLayerChange,this)},addBaseLayer:function(t,e){return this._addLayer(t,e),this._map?this._update():this},addOverlay:function(t,e){return this._addLayer(t,e,!0),this._map?this._update():this},removeLayer:function(t){t.off("add remove",this._onLayerChange,this);t=this._getLayer(h(t));return t&&this._layers.splice(this._layers.indexOf(t),1),this._map?this._update():this},expand:function(){M(this._container,"leaflet-control-layers-expanded"),this._section.style.height=null;var t=this._map.getSize().y-(this._container.offsetTop+50);return t<this._section.clientHeight?(M(this._section,"leaflet-control-layers-scrollbar"),this._section.style.height=t+"px"):z(this._section,"leaflet-control-layers-scrollbar"),this._checkDisabledLayers(),this},collapse:function(){return z(this._container,"leaflet-control-layers-expanded"),this},_initLayout:function(){var t="leaflet-control-layers",e=this._container=P("div",t),i=this.options.collapsed,n=(e.setAttribute("aria-haspopup",!0),Ie(e),Be(e),this._section=P("section",t+"-list")),o=(i&&(this._map.on("click",this.collapse,this),S(e,{mouseenter:this._expandSafely,mouseleave:this.collapse},this)),this._layersLink=P("a",t+"-toggle",e));o.href="#",o.title="Layers",o.setAttribute("role","button"),S(o,{keydown:function(t){13===t.keyCode&&this._expandSafely()},click:function(t){O(t),this._expandSafely()}},this),i||this.expand(),this._baseLayersList=P("div",t+"-base",n),this._separator=P("div",t+"-separator",n),this._overlaysList=P("div",t+"-overlays",n),e.appendChild(n)},_getLayer:function(t){for(var e=0;e<this._layers.length;e++)if(this._layers[e]&&h(this._layers[e].layer)===t)return this._layers[e]},_addLayer:function(t,e,i){this._map&&t.on("add remove",this._onLayerChange,this),this._layers.push({layer:t,name:e,overlay:i}),this.options.sortLayers&&this._layers.sort(a(function(t,e){return this.options.sortFunction(t.layer,e.layer,t.name,e.name)},this)),this.options.autoZIndex&&t.setZIndex&&(this._lastZIndex++,t.setZIndex(this._lastZIndex)),this._expandIfNotCollapsed()},_update:function(){if(this._container){me(this._baseLayersList),me(this._overlaysList),this._layerControlInputs=[];for(var t,e,i,n=0,o=0;o<this._layers.length;o++)i=this._layers[o],this._addItem(i),e=e||i.overlay,t=t||!i.overlay,n+=i.overlay?0:1;this.options.hideSingleBase&&(this._baseLayersList.style.display=(t=t&&1<n)?"":"none"),this._separator.style.display=e&&t?"":"none"}return this},_onLayerChange:function(t){this._handlingClick||this._update();var e=this._getLayer(h(t.target)),t=e.overlay?"add"===t.type?"overlayadd":"overlayremove":"add"===t.type?"baselayerchange":null;t&&this._map.fire(t,e)},_createRadioElement:function(t,e){t='<input type="radio" class="leaflet-control-layers-selector" name="'+t+'"'+(e?' checked="checked"':"")+"/>",e=document.createElement("div");return e.innerHTML=t,e.firstChild},_addItem:function(t){var e,i=document.createElement("label"),n=this._map.hasLayer(t.layer),n=(t.overlay?((e=document.createElement("input")).type="checkbox",e.className="leaflet-control-layers-selector",e.defaultChecked=n):e=this._createRadioElement("leaflet-base-layers_"+h(this),n),this._layerControlInputs.push(e),e.layerId=h(t.layer),S(e,"click",this._onInputClick,this),document.createElement("span")),o=(n.innerHTML=" "+t.name,document.createElement("span"));return i.appendChild(o),o.appendChild(e),o.appendChild(n),(t.overlay?this._overlaysList:this._baseLayersList).appendChild(i),this._checkDisabledLayers(),i},_onInputClick:function(){if(!this._preventClick){var t,e,i=this._layerControlInputs,n=[],o=[];this._handlingClick=!0;for(var s=i.length-1;0<=s;s--)t=i[s],e=this._getLayer(t.layerId).layer,t.checked?n.push(e):t.checked||o.push(e);for(s=0;s<o.length;s++)this._map.hasLayer(o[s])&&this._map.removeLayer(o[s]);for(s=0;s<n.length;s++)this._map.hasLayer(n[s])||this._map.addLayer(n[s]);this._handlingClick=!1,this._refocusOnMap()}},_checkDisabledLayers:function(){for(var t,e,i=this._layerControlInputs,n=this._map.getZoom(),o=i.length-1;0<=o;o--)t=i[o],e=this._getLayer(t.layerId).layer,t.disabled=void 0!==e.options.minZoom&&n<e.options.minZoom||void 0!==e.options.maxZoom&&n>e.options.maxZoom},_expandIfNotCollapsed:function(){return this._map&&!this.options.collapsed&&this.expand(),this},_expandSafely:function(){var t=this._section,e=(this._preventClick=!0,S(t,"click",O),this.expand(),this);setTimeout(function(){k(t,"click",O),e._preventClick=!1})}})),qe=B.extend({options:{position:"topleft",zoomInText:'<span aria-hidden="true">+</span>',zoomInTitle:"Zoom in",zoomOutText:'<span aria-hidden="true">&#x2212;</span>',zoomOutTitle:"Zoom out"},onAdd:function(t){var e="leaflet-control-zoom",i=P("div",e+" leaflet-bar"),n=this.options;return this._zoomInButton=this._createButton(n.zoomInText,n.zoomInTitle,e+"-in",i,this._zoomIn),this._zoomOutButton=this._createButton(n.zoomOutText,n.zoomOutTitle,e+"-out",i,this._zoomOut),this._updateDisabled(),t.on("zoomend zoomlevelschange",this._updateDisabled,this),i},onRemove:function(t){t.off("zoomend zoomlevelschange",this._updateDisabled,this)},disable:function(){return this._disabled=!0,this._updateDisabled(),this},enable:function(){return this._disabled=!1,this._updateDisabled(),this},_zoomIn:function(t){!this._disabled&&this._map._zoom<this._map.getMaxZoom()&&this._map.zoomIn(this._map.options.zoomDelta*(t.shiftKey?3:1))},_zoomOut:function(t){!this._disabled&&this._map._zoom>this._map.getMinZoom()&&this._map.zoomOut(this._map.options.zoomDelta*(t.shiftKey?3:1))},_createButton:function(t,e,i,n,o){i=P("a",i,n);return i.innerHTML=t,i.href="#",i.title=e,i.setAttribute("role","button"),i.setAttribute("aria-label",e),Ie(i),S(i,"click",Re),S(i,"click",o,this),S(i,"click",this._refocusOnMap,this),i},_updateDisabled:function(){var t=this._map,e="leaflet-disabled";z(this._zoomInButton,e),z(this._zoomOutButton,e),this._zoomInButton.setAttribute("aria-disabled","false"),this._zoomOutButton.setAttribute("aria-disabled","false"),!this._disabled&&t._zoom!==t.getMinZoom()||(M(this._zoomOutButton,e),this._zoomOutButton.setAttribute("aria-disabled","true")),!this._disabled&&t._zoom!==t.getMaxZoom()||(M(this._zoomInButton,e),this._zoomInButton.setAttribute("aria-disabled","true"))}}),Ge=(A.mergeOptions({zoomControl:!0}),A.addInitHook(function(){this.options.zoomControl&&(this.zoomControl=new qe,this.addControl(this.zoomControl))}),B.extend({options:{position:"bottomleft",maxWidth:100,metric:!0,imperial:!0},onAdd:function(t){var e="leaflet-control-scale",i=P("div",e),n=this.options;return this._addScales(n,e+"-line",i),t.on(n.updateWhenIdle?"moveend":"move",this._update,this),t.whenReady(this._update,this),i},onRemove:function(t){t.off(this.options.updateWhenIdle?"moveend":"move",this._update,this)},_addScales:function(t,e,i){t.metric&&(this._mScale=P("div",e,i)),t.imperial&&(this._iScale=P("div",e,i))},_update:function(){var t=this._map,e=t.getSize().y/2,t=t.distance(t.containerPointToLatLng([0,e]),t.containerPointToLatLng([this.options.maxWidth,e]));this._updateScales(t)},_updateScales:function(t){this.options.metric&&t&&this._updateMetric(t),this.options.imperial&&t&&this._updateImperial(t)},_updateMetric:function(t){var e=this._getRoundNum(t);this._updateScale(this._mScale,e<1e3?e+" m":e/1e3+" km",e/t)},_updateImperial:function(t){var e,i,t=3.2808399*t;5280<t?(i=this._getRoundNum(e=t/5280),this._updateScale(this._iScale,i+" mi",i/e)):(i=this._getRoundNum(t),this._updateScale(this._iScale,i+" ft",i/t))},_updateScale:function(t,e,i){t.style.width=Math.round(this.options.maxWidth*i)+"px",t.innerHTML=e},_getRoundNum:function(t){var e=Math.pow(10,(Math.floor(t)+"").length-1),t=t/e;return e*(t=10<=t?10:5<=t?5:3<=t?3:2<=t?2:1)}})),Ke=B.extend({options:{position:"bottomright",prefix:'<a href="https://leafletjs.com" title="A JavaScript library for interactive maps">'+(b.inlineSvg?'<svg aria-hidden="true" xmlns="http://www.w3.org/2000/svg" width="12" height="8" viewBox="0 0 12 8" class="leaflet-attribution-flag"><path fill="#4C7BE1" d="M0 0h12v4H0z"/><path fill="#FFD500" d="M0 4h12v3H0z"/><path fill="#E0BC00" d="M0 7h12v1H0z"/></svg> ':"")+"Leaflet</a>"},initialize:function(t){c(this,t),this._attributions={}},onAdd:function(t){for(var e in(t.attributionControl=this)._container=P("div","leaflet-control-attribution"),Ie(this._container),t._layers)t._layers[e].getAttribution&&this.addAttribution(t._layers[e].getAttribution());return this._update(),t.on("layeradd",this._addAttribution,this),this._container},onRemove:function(t){t.off("layeradd",this._addAttribution,this)},_addAttribution:function(t){t.layer.getAttribution&&(this.addAttribution(t.layer.getAttribution()),t.layer.once("remove",function(){this.removeAttribution(t.layer.getAttribution())},this))},setPrefix:function(t){return this.options.prefix=t,this._update(),this},addAttribution:function(t){return t&&(this._attributions[t]||(this._attributions[t]=0),this._attributions[t]++,this._update()),this},removeAttribution:function(t){return t&&this._attributions[t]&&(this._attributions[t]--,this._update()),this},_update:function(){if(this._map){var t,e=[];for(t in this._attributions)this._attributions[t]&&e.push(t);var i=[];this.options.prefix&&i.push(this.options.prefix),e.length&&i.push(e.join(", ")),this._container.innerHTML=i.join(' <span aria-hidden="true">|</span> ')}}}),n=(A.mergeOptions({attributionControl:!0}),A.addInitHook(function(){this.options.attributionControl&&(new Ke).addTo(this)}),B.Layers=Ve,B.Zoom=qe,B.Scale=Ge,B.Attribution=Ke,Ue.layers=function(t,e,i){return new Ve(t,e,i)},Ue.zoom=function(t){return new qe(t)},Ue.scale=function(t){return new Ge(t)},Ue.attribution=function(t){return new Ke(t)},et.extend({initialize:function(t){this._map=t},enable:function(){return this._enabled||(this._enabled=!0,this.addHooks()),this},disable:function(){return this._enabled&&(this._enabled=!1,this.removeHooks()),this},enabled:function(){return!!this._enabled}})),ft=(n.addTo=function(t,e){return t.addHandler(e,this),this},{Events:e}),Ye=b.touch?"touchstart mousedown":"mousedown",Xe=it.extend({options:{clickTolerance:3},initialize:function(t,e,i,n){c(this,n),this._element=t,this._dragStartTarget=e||t,this._preventOutline=i},enable:function(){this._enabled||(S(this._dragStartTarget,Ye,this._onDown,this),this._enabled=!0)},disable:function(){this._enabled&&(Xe._dragging===this&&this.finishDrag(!0),k(this._dragStartTarget,Ye,this._onDown,this),this._enabled=!1,this._moved=!1)},_onDown:function(t){var e,i;this._enabled&&(this._moved=!1,ve(this._element,"leaflet-zoom-anim")||(t.touches&&1!==t.touches.length?Xe._dragging===this&&this.finishDrag():Xe._dragging||t.shiftKey||1!==t.which&&1!==t.button&&!t.touches||((Xe._dragging=this)._preventOutline&&Me(this._element),Le(),re(),this._moving||(this.fire("down"),i=t.touches?t.touches[0]:t,e=Ce(this._element),this._startPoint=new p(i.clientX,i.clientY),this._startPos=Pe(this._element),this._parentScale=Ze(e),i="mousedown"===t.type,S(document,i?"mousemove":"touchmove",this._onMove,this),S(document,i?"mouseup":"touchend touchcancel",this._onUp,this)))))},_onMove:function(t){var e;this._enabled&&(t.touches&&1<t.touches.length?this._moved=!0:!(e=new p((e=t.touches&&1===t.touches.length?t.touches[0]:t).clientX,e.clientY)._subtract(this._startPoint)).x&&!e.y||Math.abs(e.x)+Math.abs(e.y)<this.options.clickTolerance||(e.x/=this._parentScale.x,e.y/=this._parentScale.y,O(t),this._moved||(this.fire("dragstart"),this._moved=!0,M(document.body,"leaflet-dragging"),this._lastTarget=t.target||t.srcElement,window.SVGElementInstance&&this._lastTarget instanceof window.SVGElementInstance&&(this._lastTarget=this._lastTarget.correspondingUseElement),M(this._lastTarget,"leaflet-drag-target")),this._newPos=this._startPos.add(e),this._moving=!0,this._lastEvent=t,this._updatePosition()))},_updatePosition:function(){var t={originalEvent:this._lastEvent};this.fire("predrag",t),Z(this._element,this._newPos),this.fire("drag",t)},_onUp:function(){this._enabled&&this.finishDrag()},finishDrag:function(t){z(document.body,"leaflet-dragging"),this._lastTarget&&(z(this._lastTarget,"leaflet-drag-target"),this._lastTarget=null),k(document,"mousemove touchmove",this._onMove,this),k(document,"mouseup touchend touchcancel",this._onUp,this),Te(),ae();var e=this._moved&&this._moving;this._moving=!1,Xe._dragging=!1,e&&this.fire("dragend",{noInertia:t,distance:this._newPos.distanceTo(this._startPos)})}});function Je(t,e,i){for(var n,o,s,r,a,h,l,u=[1,4,2,8],c=0,d=t.length;c<d;c++)t[c]._code=si(t[c],e);for(s=0;s<4;s++){for(h=u[s],n=[],c=0,o=(d=t.length)-1;c<d;o=c++)r=t[c],a=t[o],r._code&h?a._code&h||((l=oi(a,r,h,e,i))._code=si(l,e),n.push(l)):(a._code&h&&((l=oi(a,r,h,e,i))._code=si(l,e),n.push(l)),n.push(r));t=n}return t}function $e(t,e){var i,n,o,s,r,a,h;if(!t||0===t.length)throw new Error("latlngs not passed");I(t)||(console.warn("latlngs are not flat! Only the first ring will be used"),t=t[0]);for(var l=w([0,0]),u=g(t),c=(u.getNorthWest().distanceTo(u.getSouthWest())*u.getNorthEast().distanceTo(u.getNorthWest())<1700&&(l=Qe(t)),t.length),d=[],_=0;_<c;_++){var p=w(t[_]);d.push(e.project(w([p.lat-l.lat,p.lng-l.lng])))}for(_=r=a=h=0,i=c-1;_<c;i=_++)n=d[_],o=d[i],s=n.y*o.x-o.y*n.x,a+=(n.x+o.x)*s,h+=(n.y+o.y)*s,r+=3*s;u=0===r?d[0]:[a/r,h/r],u=e.unproject(m(u));return w([u.lat+l.lat,u.lng+l.lng])}function Qe(t){for(var e=0,i=0,n=0,o=0;o<t.length;o++){var s=w(t[o]);e+=s.lat,i+=s.lng,n++}return w([e/n,i/n])}var ti,gt={__proto__:null,clipPolygon:Je,polygonCenter:$e,centroid:Qe};function ei(t,e){if(e&&t.length){var i=t=function(t,e){for(var i=[t[0]],n=1,o=0,s=t.length;n<s;n++)(function(t,e){var i=e.x-t.x,e=e.y-t.y;return i*i+e*e})(t[n],t[o])>e&&(i.push(t[n]),o=n);o<s-1&&i.push(t[s-1]);return i}(t,e=e*e),n=i.length,o=new(typeof Uint8Array!=void 0+""?Uint8Array:Array)(n);o[0]=o[n-1]=1,function t(e,i,n,o,s){var r,a,h,l=0;for(a=o+1;a<=s-1;a++)h=ri(e[a],e[o],e[s],!0),l<h&&(r=a,l=h);n<l&&(i[r]=1,t(e,i,n,o,r),t(e,i,n,r,s))}(i,o,e,0,n-1);var s,r=[];for(s=0;s<n;s++)o[s]&&r.push(i[s]);return r}return t.slice()}function ii(t,e,i){return Math.sqrt(ri(t,e,i,!0))}function ni(t,e,i,n,o){var s,r,a,h=n?ti:si(t,i),l=si(e,i);for(ti=l;;){if(!(h|l))return[t,e];if(h&l)return!1;a=si(r=oi(t,e,s=h||l,i,o),i),s===h?(t=r,h=a):(e=r,l=a)}}function oi(t,e,i,n,o){var s,r,a=e.x-t.x,e=e.y-t.y,h=n.min,n=n.max;return 8&i?(s=t.x+a*(n.y-t.y)/e,r=n.y):4&i?(s=t.x+a*(h.y-t.y)/e,r=h.y):2&i?(s=n.x,r=t.y+e*(n.x-t.x)/a):1&i&&(s=h.x,r=t.y+e*(h.x-t.x)/a),new p(s,r,o)}function si(t,e){var i=0;return t.x<e.min.x?i|=1:t.x>e.max.x&&(i|=2),t.y<e.min.y?i|=4:t.y>e.max.y&&(i|=8),i}function ri(t,e,i,n){var o=e.x,e=e.y,s=i.x-o,r=i.y-e,a=s*s+r*r;return 0<a&&(1<(a=((t.x-o)*s+(t.y-e)*r)/a)?(o=i.x,e=i.y):0<a&&(o+=s*a,e+=r*a)),s=t.x-o,r=t.y-e,n?s*s+r*r:new p(o,e)}function I(t){return!d(t[0])||"object"!=typeof t[0][0]&&void 0!==t[0][0]}function ai(t){return console.warn("Deprecated use of _flat, please use L.LineUtil.isFlat instead."),I(t)}function hi(t,e){var i,n,o,s,r,a;if(!t||0===t.length)throw new Error("latlngs not passed");I(t)||(console.warn("latlngs are not flat! Only the first ring will be used"),t=t[0]);for(var h=w([0,0]),l=g(t),u=(l.getNorthWest().distanceTo(l.getSouthWest())*l.getNorthEast().distanceTo(l.getNorthWest())<1700&&(h=Qe(t)),t.length),c=[],d=0;d<u;d++){var _=w(t[d]);c.push(e.project(w([_.lat-h.lat,_.lng-h.lng])))}for(i=d=0;d<u-1;d++)i+=c[d].distanceTo(c[d+1])/2;if(0===i)a=c[0];else for(n=d=0;d<u-1;d++)if(o=c[d],s=c[d+1],i<(n+=r=o.distanceTo(s))){a=[s.x-(r=(n-i)/r)*(s.x-o.x),s.y-r*(s.y-o.y)];break}l=e.unproject(m(a));return w([l.lat+h.lat,l.lng+h.lng])}var vt={__proto__:null,simplify:ei,pointToSegmentDistance:ii,closestPointOnSegment:function(t,e,i){return ri(t,e,i)},clipSegment:ni,_getEdgeIntersection:oi,_getBitCode:si,_sqClosestPointOnSegment:ri,isFlat:I,_flat:ai,polylineCenter:hi},yt={project:function(t){return new p(t.lng,t.lat)},unproject:function(t){return new v(t.y,t.x)},bounds:new f([-180,-90],[180,90])},xt={R:6378137,R_MINOR:6356752.314245179,bounds:new f([-20037508.34279,-15496570.73972],[20037508.34279,18764656.23138]),project:function(t){var e=Math.PI/180,i=this.R,n=t.lat*e,o=this.R_MINOR/i,o=Math.sqrt(1-o*o),s=o*Math.sin(n),s=Math.tan(Math.PI/4-n/2)/Math.pow((1-s)/(1+s),o/2),n=-i*Math.log(Math.max(s,1e-10));return new p(t.lng*e*i,n)},unproject:function(t){for(var e,i=180/Math.PI,n=this.R,o=this.R_MINOR/n,s=Math.sqrt(1-o*o),r=Math.exp(-t.y/n),a=Math.PI/2-2*Math.atan(r),h=0,l=.1;h<15&&1e-7<Math.abs(l);h++)e=s*Math.sin(a),e=Math.pow((1-e)/(1+e),s/2),a+=l=Math.PI/2-2*Math.atan(r*e)-a;return new v(a*i,t.x*i/n)}},wt={__proto__:null,LonLat:yt,Mercator:xt,SphericalMercator:rt},Pt=l({},st,{code:"EPSG:3395",projection:xt,transformation:ht(bt=.5/(Math.PI*xt.R),.5,-bt,.5)}),li=l({},st,{code:"EPSG:4326",projection:yt,transformation:ht(1/180,1,-1/180,.5)}),Lt=l({},ot,{projection:yt,transformation:ht(1,0,-1,0),scale:function(t){return Math.pow(2,t)},zoom:function(t){return Math.log(t)/Math.LN2},distance:function(t,e){var i=e.lng-t.lng,e=e.lat-t.lat;return Math.sqrt(i*i+e*e)},infinite:!0}),o=(ot.Earth=st,ot.EPSG3395=Pt,ot.EPSG3857=lt,ot.EPSG900913=ut,ot.EPSG4326=li,ot.Simple=Lt,it.extend({options:{pane:"overlayPane",attribution:null,bubblingMouseEvents:!0},addTo:function(t){return t.addLayer(this),this},remove:function(){return this.removeFrom(this._map||this._mapToAdd)},removeFrom:function(t){return t&&t.removeLayer(this),this},getPane:function(t){return this._map.getPane(t?this.options[t]||t:this.options.pane)},addInteractiveTarget:function(t){return this._map._targets[h(t)]=this},removeInteractiveTarget:function(t){return delete this._map._targets[h(t)],this},getAttribution:function(){return this.options.attribution},_layerAdd:function(t){var e,i=t.target;i.hasLayer(this)&&(this._map=i,this._zoomAnimated=i._zoomAnimated,this.getEvents&&(e=this.getEvents(),i.on(e,this),this.once("remove",function(){i.off(e,this)},this)),this.onAdd(i),this.fire("add"),i.fire("layeradd",{layer:this}))}})),ui=(A.include({addLayer:function(t){var e;if(t._layerAdd)return e=h(t),this._layers[e]||((this._layers[e]=t)._mapToAdd=this,t.beforeAdd&&t.beforeAdd(this),this.whenReady(t._layerAdd,t)),this;throw new Error("The provided object is not a Layer.")},removeLayer:function(t){var e=h(t);return this._layers[e]&&(this._loaded&&t.onRemove(this),delete this._layers[e],this._loaded&&(this.fire("layerremove",{layer:t}),t.fire("remove")),t._map=t._mapToAdd=null),this},hasLayer:function(t){return h(t)in this._layers},eachLayer:function(t,e){for(var i in this._layers)t.call(e,this._layers[i]);return this},_addLayers:function(t){for(var e=0,i=(t=t?d(t)?t:[t]:[]).length;e<i;e++)this.addLayer(t[e])},_addZoomLimit:function(t){isNaN(t.options.maxZoom)&&isNaN(t.options.minZoom)||(this._zoomBoundLayers[h(t)]=t,this._updateZoomLevels())},_removeZoomLimit:function(t){t=h(t);this._zoomBoundLayers[t]&&(delete this._zoomBoundLayers[t],this._updateZoomLevels())},_updateZoomLevels:function(){var t,e=1/0,i=-1/0,n=this._getZoomSpan();for(t in this._zoomBoundLayers)var o=this._zoomBoundLayers[t].options,e=void 0===o.minZoom?e:Math.min(e,o.minZoom),i=void 0===o.maxZoom?i:Math.max(i,o.maxZoom);this._layersMaxZoom=i===-1/0?void 0:i,this._layersMinZoom=e===1/0?void 0:e,n!==this._getZoomSpan()&&this.fire("zoomlevelschange"),void 0===this.options.maxZoom&&this._layersMaxZoom&&this.getZoom()>this._layersMaxZoom&&this.setZoom(this._layersMaxZoom),void 0===this.options.minZoom&&this._layersMinZoom&&this.getZoom()<this._layersMinZoom&&this.setZoom(this._layersMinZoom)}}),o.extend({initialize:function(t,e){var i,n;if(c(this,e),this._layers={},t)for(i=0,n=t.length;i<n;i++)this.addLayer(t[i])},addLayer:function(t){var e=this.getLayerId(t);return this._layers[e]=t,this._map&&this._map.addLayer(t),this},removeLayer:function(t){t=t in this._layers?t:this.getLayerId(t);return this._map&&this._layers[t]&&this._map.removeLayer(this._layers[t]),delete this._layers[t],this},hasLayer:function(t){return("number"==typeof t?t:this.getLayerId(t))in this._layers},clearLayers:function(){return this.eachLayer(this.removeLayer,this)},invoke:function(t){var e,i,n=Array.prototype.slice.call(arguments,1);for(e in this._layers)(i=this._layers[e])[t]&&i[t].apply(i,n);return this},onAdd:function(t){this.eachLayer(t.addLayer,t)},onRemove:function(t){this.eachLayer(t.removeLayer,t)},eachLayer:function(t,e){for(var i in this._layers)t.call(e,this._layers[i]);return this},getLayer:function(t){return this._layers[t]},getLayers:function(){var t=[];return this.eachLayer(t.push,t),t},setZIndex:function(t){return this.invoke("setZIndex",t)},getLayerId:h})),ci=ui.extend({addLayer:function(t){return this.hasLayer(t)?this:(t.addEventParent(this),ui.prototype.addLayer.call(this,t),this.fire("layeradd",{layer:t}))},removeLayer:function(t){return this.hasLayer(t)?((t=t in this._layers?this._layers[t]:t).removeEventParent(this),ui.prototype.removeLayer.call(this,t),this.fire("layerremove",{layer:t})):this},setStyle:function(t){return this.invoke("setStyle",t)},bringToFront:function(){return this.invoke("bringToFront")},bringToBack:function(){return this.invoke("bringToBack")},getBounds:function(){var t,e=new s;for(t in this._layers){var i=this._layers[t];e.extend(i.getBounds?i.getBounds():i.getLatLng())}return e}}),di=et.extend({options:{popupAnchor:[0,0],tooltipAnchor:[0,0],crossOrigin:!1},initialize:function(t){c(this,t)},createIcon:function(t){return this._createIcon("icon",t)},createShadow:function(t){return this._createIcon("shadow",t)},_createIcon:function(t,e){var i=this._getIconUrl(t);if(i)return i=this._createImg(i,e&&"IMG"===e.tagName?e:null),this._setIconStyles(i,t),!this.options.crossOrigin&&""!==this.options.crossOrigin||(i.crossOrigin=!0===this.options.crossOrigin?"":this.options.crossOrigin),i;if("icon"===t)throw new Error("iconUrl not set in Icon options (see the docs).");return null},_setIconStyles:function(t,e){var i=this.options,n=i[e+"Size"],n=m(n="number"==typeof n?[n,n]:n),o=m("shadow"===e&&i.shadowAnchor||i.iconAnchor||n&&n.divideBy(2,!0));t.className="leaflet-marker-"+e+" "+(i.className||""),o&&(t.style.marginLeft=-o.x+"px",t.style.marginTop=-o.y+"px"),n&&(t.style.width=n.x+"px",t.style.height=n.y+"px")},_createImg:function(t,e){return(e=e||document.createElement("img")).src=t,e},_getIconUrl:function(t){return b.retina&&this.options[t+"RetinaUrl"]||this.options[t+"Url"]}});var _i=di.extend({options:{iconUrl:"marker-icon.png",iconRetinaUrl:"marker-icon-2x.png",shadowUrl:"marker-shadow.png",iconSize:[25,41],iconAnchor:[12,41],popupAnchor:[1,-34],tooltipAnchor:[16,-28],shadowSize:[41,41]},_getIconUrl:function(t){return"string"!=typeof _i.imagePath&&(_i.imagePath=this._detectIconPath()),(this.options.imagePath||_i.imagePath)+di.prototype._getIconUrl.call(this,t)},_stripUrl:function(t){function e(t,e,i){return(e=e.exec(t))&&e[i]}return(t=e(t,/^url\((['"])?(.+)\1\)$/,2))&&e(t,/^(.*)marker-icon\.png$/,1)},_detectIconPath:function(){var t=P("div","leaflet-default-icon-path",document.body),e=pe(t,"background-image")||pe(t,"backgroundImage");return document.body.removeChild(t),(e=this._stripUrl(e))?e:(t=document.querySelector('link[href$="leaflet.css"]'))?t.href.substring(0,t.href.length-"leaflet.css".length-1):""}}),pi=n.extend({initialize:function(t){this._marker=t},addHooks:function(){var t=this._marker._icon;this._draggable||(this._draggable=new Xe(t,t,!0)),this._draggable.on({dragstart:this._onDragStart,predrag:this._onPreDrag,drag:this._onDrag,dragend:this._onDragEnd},this).enable(),M(t,"leaflet-marker-draggable")},removeHooks:function(){this._draggable.off({dragstart:this._onDragStart,predrag:this._onPreDrag,drag:this._onDrag,dragend:this._onDragEnd},this).disable(),this._marker._icon&&z(this._marker._icon,"leaflet-marker-draggable")},moved:function(){return this._draggable&&this._draggable._moved},_adjustPan:function(t){var e=this._marker,i=e._map,n=this._marker.options.autoPanSpeed,o=this._marker.options.autoPanPadding,s=Pe(e._icon),r=i.getPixelBounds(),a=i.getPixelOrigin(),a=_(r.min._subtract(a).add(o),r.max._subtract(a).subtract(o));a.contains(s)||(o=m((Math.max(a.max.x,s.x)-a.max.x)/(r.max.x-a.max.x)-(Math.min(a.min.x,s.x)-a.min.x)/(r.min.x-a.min.x),(Math.max(a.max.y,s.y)-a.max.y)/(r.max.y-a.max.y)-(Math.min(a.min.y,s.y)-a.min.y)/(r.min.y-a.min.y)).multiplyBy(n),i.panBy(o,{animate:!1}),this._draggable._newPos._add(o),this._draggable._startPos._add(o),Z(e._icon,this._draggable._newPos),this._onDrag(t),this._panRequest=x(this._adjustPan.bind(this,t)))},_onDragStart:function(){this._oldLatLng=this._marker.getLatLng(),this._marker.closePopup&&this._marker.closePopup(),this._marker.fire("movestart").fire("dragstart")},_onPreDrag:function(t){this._marker.options.autoPan&&(r(this._panRequest),this._panRequest=x(this._adjustPan.bind(this,t)))},_onDrag:function(t){var e=this._marker,i=e._shadow,n=Pe(e._icon),o=e._map.layerPointToLatLng(n);i&&Z(i,n),e._latlng=o,t.latlng=o,t.oldLatLng=this._oldLatLng,e.fire("move",t).fire("drag",t)},_onDragEnd:function(t){r(this._panRequest),delete this._oldLatLng,this._marker.fire("moveend").fire("dragend",t)}}),mi=o.extend({options:{icon:new _i,interactive:!0,keyboard:!0,title:"",alt:"Marker",zIndexOffset:0,opacity:1,riseOnHover:!1,riseOffset:250,pane:"markerPane",shadowPane:"shadowPane",bubblingMouseEvents:!1,autoPanOnFocus:!0,draggable:!1,autoPan:!1,autoPanPadding:[50,50],autoPanSpeed:10},initialize:function(t,e){c(this,e),this._latlng=w(t)},onAdd:function(t){this._zoomAnimated=this._zoomAnimated&&t.options.markerZoomAnimation,this._zoomAnimated&&t.on("zoomanim",this._animateZoom,this),this._initIcon(),this.update()},onRemove:function(t){this.dragging&&this.dragging.enabled()&&(this.options.draggable=!0,this.dragging.removeHooks()),delete this.dragging,this._zoomAnimated&&t.off("zoomanim",this._animateZoom,this),this._removeIcon(),this._removeShadow()},getEvents:function(){return{zoom:this.update,viewreset:this.update}},getLatLng:function(){return this._latlng},setLatLng:function(t){var e=this._latlng;return this._latlng=w(t),this.update(),this.fire("move",{oldLatLng:e,latlng:this._latlng})},setZIndexOffset:function(t){return this.options.zIndexOffset=t,this.update()},getIcon:function(){return this.options.icon},setIcon:function(t){return this.options.icon=t,this._map&&(this._initIcon(),this.update()),this._popup&&this.bindPopup(this._popup,this._popup.options),this},getElement:function(){return this._icon},update:function(){var t;return this._icon&&this._map&&(t=this._map.latLngToLayerPoint(this._latlng).round(),this._setPos(t)),this},_initIcon:function(){var t=this.options,e="leaflet-zoom-"+(this._zoomAnimated?"animated":"hide"),i=t.icon.createIcon(this._icon),n=!1,i=(i!==this._icon&&(this._icon&&this._removeIcon(),n=!0,t.title&&(i.title=t.title),"IMG"===i.tagName&&(i.alt=t.alt||"")),M(i,e),t.keyboard&&(i.tabIndex="0",i.setAttribute("role","button")),this._icon=i,t.riseOnHover&&this.on({mouseover:this._bringToFront,mouseout:this._resetZIndex}),this.options.autoPanOnFocus&&S(i,"focus",this._panOnFocus,this),t.icon.createShadow(this._shadow)),o=!1;i!==this._shadow&&(this._removeShadow(),o=!0),i&&(M(i,e),i.alt=""),this._shadow=i,t.opacity<1&&this._updateOpacity(),n&&this.getPane().appendChild(this._icon),this._initInteraction(),i&&o&&this.getPane(t.shadowPane).appendChild(this._shadow)},_removeIcon:function(){this.options.riseOnHover&&this.off({mouseover:this._bringToFront,mouseout:this._resetZIndex}),this.options.autoPanOnFocus&&k(this._icon,"focus",this._panOnFocus,this),T(this._icon),this.removeInteractiveTarget(this._icon),this._icon=null},_removeShadow:function(){this._shadow&&T(this._shadow),this._shadow=null},_setPos:function(t){this._icon&&Z(this._icon,t),this._shadow&&Z(this._shadow,t),this._zIndex=t.y+this.options.zIndexOffset,this._resetZIndex()},_updateZIndex:function(t){this._icon&&(this._icon.style.zIndex=this._zIndex+t)},_animateZoom:function(t){t=this._map._latLngToNewLayerPoint(this._latlng,t.zoom,t.center).round();this._setPos(t)},_initInteraction:function(){var t;this.options.interactive&&(M(this._icon,"leaflet-interactive"),this.addInteractiveTarget(this._icon),pi&&(t=this.options.draggable,this.dragging&&(t=this.dragging.enabled(),this.dragging.disable()),this.dragging=new pi(this),t&&this.dragging.enable()))},setOpacity:function(t){return this.options.opacity=t,this._map&&this._updateOpacity(),this},_updateOpacity:function(){var t=this.options.opacity;this._icon&&C(this._icon,t),this._shadow&&C(this._shadow,t)},_bringToFront:function(){this._updateZIndex(this.options.riseOffset)},_resetZIndex:function(){this._updateZIndex(0)},_panOnFocus:function(){var t,e,i=this._map;i&&(t=(e=this.options.icon.options).iconSize?m(e.iconSize):m(0,0),e=e.iconAnchor?m(e.iconAnchor):m(0,0),i.panInside(this._latlng,{paddingTopLeft:e,paddingBottomRight:t.subtract(e)}))},_getPopupAnchor:function(){return this.options.icon.options.popupAnchor},_getTooltipAnchor:function(){return this.options.icon.options.tooltipAnchor}});var fi=o.extend({options:{stroke:!0,color:"#3388ff",weight:3,opacity:1,lineCap:"round",lineJoin:"round",dashArray:null,dashOffset:null,fill:!1,fillColor:null,fillOpacity:.2,fillRule:"evenodd",interactive:!0,bubblingMouseEvents:!0},beforeAdd:function(t){this._renderer=t.getRenderer(this)},onAdd:function(){this._renderer._initPath(this),this._reset(),this._renderer._addPath(this)},onRemove:function(){this._renderer._removePath(this)},redraw:function(){return this._map&&this._renderer._updatePath(this),this},setStyle:function(t){return c(this,t),this._renderer&&(this._renderer._updateStyle(this),this.options.stroke&&t&&Object.prototype.hasOwnProperty.call(t,"weight")&&this._updateBounds()),this},bringToFront:function(){return this._renderer&&this._renderer._bringToFront(this),this},bringToBack:function(){return this._renderer&&this._renderer._bringToBack(this),this},getElement:function(){return this._path},_reset:function(){this._project(),this._update()},_clickTolerance:function(){return(this.options.stroke?this.options.weight/2:0)+(this._renderer.options.tolerance||0)}}),gi=fi.extend({options:{fill:!0,radius:10},initialize:function(t,e){c(this,e),this._latlng=w(t),this._radius=this.options.radius},setLatLng:function(t){var e=this._latlng;return this._latlng=w(t),this.redraw(),this.fire("move",{oldLatLng:e,latlng:this._latlng})},getLatLng:function(){return this._latlng},setRadius:function(t){return this.options.radius=this._radius=t,this.redraw()},getRadius:function(){return this._radius},setStyle:function(t){var e=t&&t.radius||this._radius;return fi.prototype.setStyle.call(this,t),this.setRadius(e),this},_project:function(){this._point=this._map.latLngToLayerPoint(this._latlng),this._updateBounds()},_updateBounds:function(){var t=this._radius,e=this._radiusY||t,i=this._clickTolerance(),t=[t+i,e+i];this._pxBounds=new f(this._point.subtract(t),this._point.add(t))},_update:function(){this._map&&this._updatePath()},_updatePath:function(){this._renderer._updateCircle(this)},_empty:function(){return this._radius&&!this._renderer._bounds.intersects(this._pxBounds)},_containsPoint:function(t){return t.distanceTo(this._point)<=this._radius+this._clickTolerance()}});var vi=gi.extend({initialize:function(t,e,i){if(c(this,e="number"==typeof e?l({},i,{radius:e}):e),this._latlng=w(t),isNaN(this.options.radius))throw new Error("Circle radius cannot be NaN");this._mRadius=this.options.radius},setRadius:function(t){return this._mRadius=t,this.redraw()},getRadius:function(){return this._mRadius},getBounds:function(){var t=[this._radius,this._radiusY||this._radius];return new s(this._map.layerPointToLatLng(this._point.subtract(t)),this._map.layerPointToLatLng(this._point.add(t)))},setStyle:fi.prototype.setStyle,_project:function(){var t,e,i,n,o,s=this._latlng.lng,r=this._latlng.lat,a=this._map,h=a.options.crs;h.distance===st.distance?(n=Math.PI/180,o=this._mRadius/st.R/n,t=a.project([r+o,s]),e=a.project([r-o,s]),e=t.add(e).divideBy(2),i=a.unproject(e).lat,n=Math.acos((Math.cos(o*n)-Math.sin(r*n)*Math.sin(i*n))/(Math.cos(r*n)*Math.cos(i*n)))/n,!isNaN(n)&&0!==n||(n=o/Math.cos(Math.PI/180*r)),this._point=e.subtract(a.getPixelOrigin()),this._radius=isNaN(n)?0:e.x-a.project([i,s-n]).x,this._radiusY=e.y-t.y):(o=h.unproject(h.project(this._latlng).subtract([this._mRadius,0])),this._point=a.latLngToLayerPoint(this._latlng),this._radius=this._point.x-a.latLngToLayerPoint(o).x),this._updateBounds()}});var yi=fi.extend({options:{smoothFactor:1,noClip:!1},initialize:function(t,e){c(this,e),this._setLatLngs(t)},getLatLngs:function(){return this._latlngs},setLatLngs:function(t){return this._setLatLngs(t),this.redraw()},isEmpty:function(){return!this._latlngs.length},closestLayerPoint:function(t){for(var e=1/0,i=null,n=ri,o=0,s=this._parts.length;o<s;o++)for(var r=this._parts[o],a=1,h=r.length;a<h;a++){var l,u,c=n(t,l=r[a-1],u=r[a],!0);c<e&&(e=c,i=n(t,l,u))}return i&&(i.distance=Math.sqrt(e)),i},getCenter:function(){if(this._map)return hi(this._defaultShape(),this._map.options.crs);throw new Error("Must add layer to map before using getCenter()")},getBounds:function(){return this._bounds},addLatLng:function(t,e){return e=e||this._defaultShape(),t=w(t),e.push(t),this._bounds.extend(t),this.redraw()},_setLatLngs:function(t){this._bounds=new s,this._latlngs=this._convertLatLngs(t)},_defaultShape:function(){return I(this._latlngs)?this._latlngs:this._latlngs[0]},_convertLatLngs:function(t){for(var e=[],i=I(t),n=0,o=t.length;n<o;n++)i?(e[n]=w(t[n]),this._bounds.extend(e[n])):e[n]=this._convertLatLngs(t[n]);return e},_project:function(){var t=new f;this._rings=[],this._projectLatlngs(this._latlngs,this._rings,t),this._bounds.isValid()&&t.isValid()&&(this._rawPxBounds=t,this._updateBounds())},_updateBounds:function(){var t=this._clickTolerance(),t=new p(t,t);this._rawPxBounds&&(this._pxBounds=new f([this._rawPxBounds.min.subtract(t),this._rawPxBounds.max.add(t)]))},_projectLatlngs:function(t,e,i){var n,o,s=t[0]instanceof v,r=t.length;if(s){for(o=[],n=0;n<r;n++)o[n]=this._map.latLngToLayerPoint(t[n]),i.extend(o[n]);e.push(o)}else for(n=0;n<r;n++)this._projectLatlngs(t[n],e,i)},_clipPoints:function(){var t=this._renderer._bounds;if(this._parts=[],this._pxBounds&&this._pxBounds.intersects(t))if(this.options.noClip)this._parts=this._rings;else for(var e,i,n,o,s=this._parts,r=0,a=0,h=this._rings.length;r<h;r++)for(e=0,i=(o=this._rings[r]).length;e<i-1;e++)(n=ni(o[e],o[e+1],t,e,!0))&&(s[a]=s[a]||[],s[a].push(n[0]),n[1]===o[e+1]&&e!==i-2||(s[a].push(n[1]),a++))},_simplifyPoints:function(){for(var t=this._parts,e=this.options.smoothFactor,i=0,n=t.length;i<n;i++)t[i]=ei(t[i],e)},_update:function(){this._map&&(this._clipPoints(),this._simplifyPoints(),this._updatePath())},_updatePath:function(){this._renderer._updatePoly(this)},_containsPoint:function(t,e){var i,n,o,s,r,a,h=this._clickTolerance();if(this._pxBounds&&this._pxBounds.contains(t))for(i=0,s=this._parts.length;i<s;i++)for(n=0,o=(r=(a=this._parts[i]).length)-1;n<r;o=n++)if((e||0!==n)&&ii(t,a[o],a[n])<=h)return!0;return!1}});yi._flat=ai;var xi=yi.extend({options:{fill:!0},isEmpty:function(){return!this._latlngs.length||!this._latlngs[0].length},getCenter:function(){if(this._map)return $e(this._defaultShape(),this._map.options.crs);throw new Error("Must add layer to map before using getCenter()")},_convertLatLngs:function(t){var t=yi.prototype._convertLatLngs.call(this,t),e=t.length;return 2<=e&&t[0]instanceof v&&t[0].equals(t[e-1])&&t.pop(),t},_setLatLngs:function(t){yi.prototype._setLatLngs.call(this,t),I(this._latlngs)&&(this._latlngs=[this._latlngs])},_defaultShape:function(){return(I(this._latlngs[0])?this._latlngs:this._latlngs[0])[0]},_clipPoints:function(){var t=this._renderer._bounds,e=this.options.weight,e=new p(e,e),t=new f(t.min.subtract(e),t.max.add(e));if(this._parts=[],this._pxBounds&&this._pxBounds.intersects(t))if(this.options.noClip)this._parts=this._rings;else for(var i,n=0,o=this._rings.length;n<o;n++)(i=Je(this._rings[n],t,!0)).length&&this._parts.push(i)},_updatePath:function(){this._renderer._updatePoly(this,!0)},_containsPoint:function(t){var e,i,n,o,s,r,a,h,l=!1;if(!this._pxBounds||!this._pxBounds.contains(t))return!1;for(o=0,a=this._parts.length;o<a;o++)for(s=0,r=(h=(e=this._parts[o]).length)-1;s<h;r=s++)i=e[s],n=e[r],i.y>t.y!=n.y>t.y&&t.x<(n.x-i.x)*(t.y-i.y)/(n.y-i.y)+i.x&&(l=!l);return l||yi.prototype._containsPoint.call(this,t,!0)}});var wi=ci.extend({initialize:function(t,e){c(this,e),this._layers={},t&&this.addData(t)},addData:function(t){var e,i,n,o=d(t)?t:t.features;if(o){for(e=0,i=o.length;e<i;e++)((n=o[e]).geometries||n.geometry||n.features||n.coordinates)&&this.addData(n);return this}var s,r=this.options;return(!r.filter||r.filter(t))&&(s=bi(t,r))?(s.feature=Zi(t),s.defaultOptions=s.options,this.resetStyle(s),r.onEachFeature&&r.onEachFeature(t,s),this.addLayer(s)):this},resetStyle:function(t){return void 0===t?this.eachLayer(this.resetStyle,this):(t.options=l({},t.defaultOptions),this._setLayerStyle(t,this.options.style),this)},setStyle:function(e){return this.eachLayer(function(t){this._setLayerStyle(t,e)},this)},_setLayerStyle:function(t,e){t.setStyle&&("function"==typeof e&&(e=e(t.feature)),t.setStyle(e))}});function bi(t,e){var i,n,o,s,r="Feature"===t.type?t.geometry:t,a=r?r.coordinates:null,h=[],l=e&&e.pointToLayer,u=e&&e.coordsToLatLng||Li;if(!a&&!r)return null;switch(r.type){case"Point":return Pi(l,t,i=u(a),e);case"MultiPoint":for(o=0,s=a.length;o<s;o++)i=u(a[o]),h.push(Pi(l,t,i,e));return new ci(h);case"LineString":case"MultiLineString":return n=Ti(a,"LineString"===r.type?0:1,u),new yi(n,e);case"Polygon":case"MultiPolygon":return n=Ti(a,"Polygon"===r.type?1:2,u),new xi(n,e);case"GeometryCollection":for(o=0,s=r.geometries.length;o<s;o++){var c=bi({geometry:r.geometries[o],type:"Feature",properties:t.properties},e);c&&h.push(c)}return new ci(h);case"FeatureCollection":for(o=0,s=r.features.length;o<s;o++){var d=bi(r.features[o],e);d&&h.push(d)}return new ci(h);default:throw new Error("Invalid GeoJSON object.")}}function Pi(t,e,i,n){return t?t(e,i):new mi(i,n&&n.markersInheritOptions&&n)}function Li(t){return new v(t[1],t[0],t[2])}function Ti(t,e,i){for(var n,o=[],s=0,r=t.length;s<r;s++)n=e?Ti(t[s],e-1,i):(i||Li)(t[s]),o.push(n);return o}function Mi(t,e){return void 0!==(t=w(t)).alt?[i(t.lng,e),i(t.lat,e),i(t.alt,e)]:[i(t.lng,e),i(t.lat,e)]}function zi(t,e,i,n){for(var o=[],s=0,r=t.length;s<r;s++)o.push(e?zi(t[s],I(t[s])?0:e-1,i,n):Mi(t[s],n));return!e&&i&&0<o.length&&o.push(o[0].slice()),o}function Ci(t,e){return t.feature?l({},t.feature,{geometry:e}):Zi(e)}function Zi(t){return"Feature"===t.type||"FeatureCollection"===t.type?t:{type:"Feature",properties:{},geometry:t}}Tt={toGeoJSON:function(t){return Ci(this,{type:"Point",coordinates:Mi(this.getLatLng(),t)})}};function Si(t,e){return new wi(t,e)}mi.include(Tt),vi.include(Tt),gi.include(Tt),yi.include({toGeoJSON:function(t){var e=!I(this._latlngs);return Ci(this,{type:(e?"Multi":"")+"LineString",coordinates:zi(this._latlngs,e?1:0,!1,t)})}}),xi.include({toGeoJSON:function(t){var e=!I(this._latlngs),i=e&&!I(this._latlngs[0]),t=zi(this._latlngs,i?2:e?1:0,!0,t);return Ci(this,{type:(i?"Multi":"")+"Polygon",coordinates:t=e?t:[t]})}}),ui.include({toMultiPoint:function(e){var i=[];return this.eachLayer(function(t){i.push(t.toGeoJSON(e).geometry.coordinates)}),Ci(this,{type:"MultiPoint",coordinates:i})},toGeoJSON:function(e){var i,n,t=this.feature&&this.feature.geometry&&this.feature.geometry.type;return"MultiPoint"===t?this.toMultiPoint(e):(i="GeometryCollection"===t,n=[],this.eachLayer(function(t){t.toGeoJSON&&(t=t.toGeoJSON(e),i?n.push(t.geometry):"FeatureCollection"===(t=Zi(t)).type?n.push.apply(n,t.features):n.push(t))}),i?Ci(this,{geometries:n,type:"GeometryCollection"}):{type:"FeatureCollection",features:n})}});var Mt=Si,Ei=o.extend({options:{opacity:1,alt:"",interactive:!1,crossOrigin:!1,errorOverlayUrl:"",zIndex:1,className:""},initialize:function(t,e,i){this._url=t,this._bounds=g(e),c(this,i)},onAdd:function(){this._image||(this._initImage(),this.options.opacity<1&&this._updateOpacity()),this.options.interactive&&(M(this._image,"leaflet-interactive"),this.addInteractiveTarget(this._image)),this.getPane().appendChild(this._image),this._reset()},onRemove:function(){T(this._image),this.options.interactive&&this.removeInteractiveTarget(this._image)},setOpacity:function(t){return this.options.opacity=t,this._image&&this._updateOpacity(),this},setStyle:function(t){return t.opacity&&this.setOpacity(t.opacity),this},bringToFront:function(){return this._map&&fe(this._image),this},bringToBack:function(){return this._map&&ge(this._image),this},setUrl:function(t){return this._url=t,this._image&&(this._image.src=t),this},setBounds:function(t){return this._bounds=g(t),this._map&&this._reset(),this},getEvents:function(){var t={zoom:this._reset,viewreset:this._reset};return this._zoomAnimated&&(t.zoomanim=this._animateZoom),t},setZIndex:function(t){return this.options.zIndex=t,this._updateZIndex(),this},getBounds:function(){return this._bounds},getElement:function(){return this._image},_initImage:function(){var t="IMG"===this._url.tagName,e=this._image=t?this._url:P("img");M(e,"leaflet-image-layer"),this._zoomAnimated&&M(e,"leaflet-zoom-animated"),this.options.className&&M(e,this.options.className),e.onselectstart=u,e.onmousemove=u,e.onload=a(this.fire,this,"load"),e.onerror=a(this._overlayOnError,this,"error"),!this.options.crossOrigin&&""!==this.options.crossOrigin||(e.crossOrigin=!0===this.options.crossOrigin?"":this.options.crossOrigin),this.options.zIndex&&this._updateZIndex(),t?this._url=e.src:(e.src=this._url,e.alt=this.options.alt)},_animateZoom:function(t){var e=this._map.getZoomScale(t.zoom),t=this._map._latLngBoundsToNewLayerBounds(this._bounds,t.zoom,t.center).min;be(this._image,t,e)},_reset:function(){var t=this._image,e=new f(this._map.latLngToLayerPoint(this._bounds.getNorthWest()),this._map.latLngToLayerPoint(this._bounds.getSouthEast())),i=e.getSize();Z(t,e.min),t.style.width=i.x+"px",t.style.height=i.y+"px"},_updateOpacity:function(){C(this._image,this.options.opacity)},_updateZIndex:function(){this._image&&void 0!==this.options.zIndex&&null!==this.options.zIndex&&(this._image.style.zIndex=this.options.zIndex)},_overlayOnError:function(){this.fire("error");var t=this.options.errorOverlayUrl;t&&this._url!==t&&(this._url=t,this._image.src=t)},getCenter:function(){return this._bounds.getCenter()}}),ki=Ei.extend({options:{autoplay:!0,loop:!0,keepAspectRatio:!0,muted:!1,playsInline:!0},_initImage:function(){var t="VIDEO"===this._url.tagName,e=this._image=t?this._url:P("video");if(M(e,"leaflet-image-layer"),this._zoomAnimated&&M(e,"leaflet-zoom-animated"),this.options.className&&M(e,this.options.className),e.onselectstart=u,e.onmousemove=u,e.onloadeddata=a(this.fire,this,"load"),t){for(var i=e.getElementsByTagName("source"),n=[],o=0;o<i.length;o++)n.push(i[o].src);this._url=0<i.length?n:[e.src]}else{d(this._url)||(this._url=[this._url]),!this.options.keepAspectRatio&&Object.prototype.hasOwnProperty.call(e.style,"objectFit")&&(e.style.objectFit="fill"),e.autoplay=!!this.options.autoplay,e.loop=!!this.options.loop,e.muted=!!this.options.muted,e.playsInline=!!this.options.playsInline;for(var s=0;s<this._url.length;s++){var r=P("source");r.src=this._url[s],e.appendChild(r)}}}});var Oi=Ei.extend({_initImage:function(){var t=this._image=this._url;M(t,"leaflet-image-layer"),this._zoomAnimated&&M(t,"leaflet-zoom-animated"),this.options.className&&M(t,this.options.className),t.onselectstart=u,t.onmousemove=u}});var Ai=o.extend({options:{interactive:!1,offset:[0,0],className:"",pane:void 0,content:""},initialize:function(t,e){t&&(t instanceof v||d(t))?(this._latlng=w(t),c(this,e)):(c(this,t),this._source=e),this.options.content&&(this._content=this.options.content)},openOn:function(t){return(t=arguments.length?t:this._source._map).hasLayer(this)||t.addLayer(this),this},close:function(){return this._map&&this._map.removeLayer(this),this},toggle:function(t){return this._map?this.close():(arguments.length?this._source=t:t=this._source,this._prepareOpen(),this.openOn(t._map)),this},onAdd:function(t){this._zoomAnimated=t._zoomAnimated,this._container||this._initLayout(),t._fadeAnimated&&C(this._container,0),clearTimeout(this._removeTimeout),this.getPane().appendChild(this._container),this.update(),t._fadeAnimated&&C(this._container,1),this.bringToFront(),this.options.interactive&&(M(this._container,"leaflet-interactive"),this.addInteractiveTarget(this._container))},onRemove:function(t){t._fadeAnimated?(C(this._container,0),this._removeTimeout=setTimeout(a(T,void 0,this._container),200)):T(this._container),this.options.interactive&&(z(this._container,"leaflet-interactive"),this.removeInteractiveTarget(this._container))},getLatLng:function(){return this._latlng},setLatLng:function(t){return this._latlng=w(t),this._map&&(this._updatePosition(),this._adjustPan()),this},getContent:function(){return this._content},setContent:function(t){return this._content=t,this.update(),this},getElement:function(){return this._container},update:function(){this._map&&(this._container.style.visibility="hidden",this._updateContent(),this._updateLayout(),this._updatePosition(),this._container.style.visibility="",this._adjustPan())},getEvents:function(){var t={zoom:this._updatePosition,viewreset:this._updatePosition};return this._zoomAnimated&&(t.zoomanim=this._animateZoom),t},isOpen:function(){return!!this._map&&this._map.hasLayer(this)},bringToFront:function(){return this._map&&fe(this._container),this},bringToBack:function(){return this._map&&ge(this._container),this},_prepareOpen:function(t){if(!(i=this._source)._map)return!1;if(i instanceof ci){var e,i=null,n=this._source._layers;for(e in n)if(n[e]._map){i=n[e];break}if(!i)return!1;this._source=i}if(!t)if(i.getCenter)t=i.getCenter();else if(i.getLatLng)t=i.getLatLng();else{if(!i.getBounds)throw new Error("Unable to get source layer LatLng.");t=i.getBounds().getCenter()}return this.setLatLng(t),this._map&&this.update(),!0},_updateContent:function(){if(this._content){var t=this._contentNode,e="function"==typeof this._content?this._content(this._source||this):this._content;if("string"==typeof e)t.innerHTML=e;else{for(;t.hasChildNodes();)t.removeChild(t.firstChild);t.appendChild(e)}this.fire("contentupdate")}},_updatePosition:function(){var t,e,i;this._map&&(e=this._map.latLngToLayerPoint(this._latlng),t=m(this.options.offset),i=this._getAnchor(),this._zoomAnimated?Z(this._container,e.add(i)):t=t.add(e).add(i),e=this._containerBottom=-t.y,i=this._containerLeft=-Math.round(this._containerWidth/2)+t.x,this._container.style.bottom=e+"px",this._container.style.left=i+"px")},_getAnchor:function(){return[0,0]}}),Bi=(A.include({_initOverlay:function(t,e,i,n){var o=e;return o instanceof t||(o=new t(n).setContent(e)),i&&o.setLatLng(i),o}}),o.include({_initOverlay:function(t,e,i,n){var o=i;return o instanceof t?(c(o,n),o._source=this):(o=e&&!n?e:new t(n,this)).setContent(i),o}}),Ai.extend({options:{pane:"popupPane",offset:[0,7],maxWidth:300,minWidth:50,maxHeight:null,autoPan:!0,autoPanPaddingTopLeft:null,autoPanPaddingBottomRight:null,autoPanPadding:[5,5],keepInView:!1,closeButton:!0,autoClose:!0,closeOnEscapeKey:!0,className:""},openOn:function(t){return!(t=arguments.length?t:this._source._map).hasLayer(this)&&t._popup&&t._popup.options.autoClose&&t.removeLayer(t._popup),t._popup=this,Ai.prototype.openOn.call(this,t)},onAdd:function(t){Ai.prototype.onAdd.call(this,t),t.fire("popupopen",{popup:this}),this._source&&(this._source.fire("popupopen",{popup:this},!0),this._source instanceof fi||this._source.on("preclick",Ae))},onRemove:function(t){Ai.prototype.onRemove.call(this,t),t.fire("popupclose",{popup:this}),this._source&&(this._source.fire("popupclose",{popup:this},!0),this._source instanceof fi||this._source.off("preclick",Ae))},getEvents:function(){var t=Ai.prototype.getEvents.call(this);return(void 0!==this.options.closeOnClick?this.options.closeOnClick:this._map.options.closePopupOnClick)&&(t.preclick=this.close),this.options.keepInView&&(t.moveend=this._adjustPan),t},_initLayout:function(){var t="leaflet-popup",e=this._container=P("div",t+" "+(this.options.className||"")+" leaflet-zoom-animated"),i=this._wrapper=P("div",t+"-content-wrapper",e);this._contentNode=P("div",t+"-content",i),Ie(e),Be(this._contentNode),S(e,"contextmenu",Ae),this._tipContainer=P("div",t+"-tip-container",e),this._tip=P("div",t+"-tip",this._tipContainer),this.options.closeButton&&((i=this._closeButton=P("a",t+"-close-button",e)).setAttribute("role","button"),i.setAttribute("aria-label","Close popup"),i.href="#close",i.innerHTML='<span aria-hidden="true">&#215;</span>',S(i,"click",function(t){O(t),this.close()},this))},_updateLayout:function(){var t=this._contentNode,e=t.style,i=(e.width="",e.whiteSpace="nowrap",t.offsetWidth),i=Math.min(i,this.options.maxWidth),i=(i=Math.max(i,this.options.minWidth),e.width=i+1+"px",e.whiteSpace="",e.height="",t.offsetHeight),n=this.options.maxHeight,o="leaflet-popup-scrolled";(n&&n<i?(e.height=n+"px",M):z)(t,o),this._containerWidth=this._container.offsetWidth},_animateZoom:function(t){var t=this._map._latLngToNewLayerPoint(this._latlng,t.zoom,t.center),e=this._getAnchor();Z(this._container,t.add(e))},_adjustPan:function(){var t,e,i,n,o,s,r,a;this.options.autoPan&&(this._map._panAnim&&this._map._panAnim.stop(),this._autopanning?this._autopanning=!1:(t=this._map,e=parseInt(pe(this._container,"marginBottom"),10)||0,e=this._container.offsetHeight+e,a=this._containerWidth,(i=new p(this._containerLeft,-e-this._containerBottom))._add(Pe(this._container)),i=t.layerPointToContainerPoint(i),o=m(this.options.autoPanPadding),n=m(this.options.autoPanPaddingTopLeft||o),o=m(this.options.autoPanPaddingBottomRight||o),s=t.getSize(),r=0,i.x+a+o.x>s.x&&(r=i.x+a-s.x+o.x),i.x-r-n.x<(a=0)&&(r=i.x-n.x),i.y+e+o.y>s.y&&(a=i.y+e-s.y+o.y),i.y-a-n.y<0&&(a=i.y-n.y),(r||a)&&(this.options.keepInView&&(this._autopanning=!0),t.fire("autopanstart").panBy([r,a]))))},_getAnchor:function(){return m(this._source&&this._source._getPopupAnchor?this._source._getPopupAnchor():[0,0])}})),Ii=(A.mergeOptions({closePopupOnClick:!0}),A.include({openPopup:function(t,e,i){return this._initOverlay(Bi,t,e,i).openOn(this),this},closePopup:function(t){return(t=arguments.length?t:this._popup)&&t.close(),this}}),o.include({bindPopup:function(t,e){return this._popup=this._initOverlay(Bi,this._popup,t,e),this._popupHandlersAdded||(this.on({click:this._openPopup,keypress:this._onKeyPress,remove:this.closePopup,move:this._movePopup}),this._popupHandlersAdded=!0),this},unbindPopup:function(){return this._popup&&(this.off({click:this._openPopup,keypress:this._onKeyPress,remove:this.closePopup,move:this._movePopup}),this._popupHandlersAdded=!1,this._popup=null),this},openPopup:function(t){return this._popup&&(this instanceof ci||(this._popup._source=this),this._popup._prepareOpen(t||this._latlng)&&this._popup.openOn(this._map)),this},closePopup:function(){return this._popup&&this._popup.close(),this},togglePopup:function(){return this._popup&&this._popup.toggle(this),this},isPopupOpen:function(){return!!this._popup&&this._popup.isOpen()},setPopupContent:function(t){return this._popup&&this._popup.setContent(t),this},getPopup:function(){return this._popup},_openPopup:function(t){var e;this._popup&&this._map&&(Re(t),e=t.layer||t.target,this._popup._source!==e||e instanceof fi?(this._popup._source=e,this.openPopup(t.latlng)):this._map.hasLayer(this._popup)?this.closePopup():this.openPopup(t.latlng))},_movePopup:function(t){this._popup.setLatLng(t.latlng)},_onKeyPress:function(t){13===t.originalEvent.keyCode&&this._openPopup(t)}}),Ai.extend({options:{pane:"tooltipPane",offset:[0,0],direction:"auto",permanent:!1,sticky:!1,opacity:.9},onAdd:function(t){Ai.prototype.onAdd.call(this,t),this.setOpacity(this.options.opacity),t.fire("tooltipopen",{tooltip:this}),this._source&&(this.addEventParent(this._source),this._source.fire("tooltipopen",{tooltip:this},!0))},onRemove:function(t){Ai.prototype.onRemove.call(this,t),t.fire("tooltipclose",{tooltip:this}),this._source&&(this.removeEventParent(this._source),this._source.fire("tooltipclose",{tooltip:this},!0))},getEvents:function(){var t=Ai.prototype.getEvents.call(this);return this.options.permanent||(t.preclick=this.close),t},_initLayout:function(){var t="leaflet-tooltip "+(this.options.className||"")+" leaflet-zoom-"+(this._zoomAnimated?"animated":"hide");this._contentNode=this._container=P("div",t),this._container.setAttribute("role","tooltip"),this._container.setAttribute("id","leaflet-tooltip-"+h(this))},_updateLayout:function(){},_adjustPan:function(){},_setPosition:function(t){var e,i=this._map,n=this._container,o=i.latLngToContainerPoint(i.getCenter()),i=i.layerPointToContainerPoint(t),s=this.options.direction,r=n.offsetWidth,a=n.offsetHeight,h=m(this.options.offset),l=this._getAnchor(),i="top"===s?(e=r/2,a):"bottom"===s?(e=r/2,0):(e="center"===s?r/2:"right"===s?0:"left"===s?r:i.x<o.x?(s="right",0):(s="left",r+2*(h.x+l.x)),a/2);t=t.subtract(m(e,i,!0)).add(h).add(l),z(n,"leaflet-tooltip-right"),z(n,"leaflet-tooltip-left"),z(n,"leaflet-tooltip-top"),z(n,"leaflet-tooltip-bottom"),M(n,"leaflet-tooltip-"+s),Z(n,t)},_updatePosition:function(){var t=this._map.latLngToLayerPoint(this._latlng);this._setPosition(t)},setOpacity:function(t){this.options.opacity=t,this._container&&C(this._container,t)},_animateZoom:function(t){t=this._map._latLngToNewLayerPoint(this._latlng,t.zoom,t.center);this._setPosition(t)},_getAnchor:function(){return m(this._source&&this._source._getTooltipAnchor&&!this.options.sticky?this._source._getTooltipAnchor():[0,0])}})),Ri=(A.include({openTooltip:function(t,e,i){return this._initOverlay(Ii,t,e,i).openOn(this),this},closeTooltip:function(t){return t.close(),this}}),o.include({bindTooltip:function(t,e){return this._tooltip&&this.isTooltipOpen()&&this.unbindTooltip(),this._tooltip=this._initOverlay(Ii,this._tooltip,t,e),this._initTooltipInteractions(),this._tooltip.options.permanent&&this._map&&this._map.hasLayer(this)&&this.openTooltip(),this},unbindTooltip:function(){return this._tooltip&&(this._initTooltipInteractions(!0),this.closeTooltip(),this._tooltip=null),this},_initTooltipInteractions:function(t){var e,i;!t&&this._tooltipHandlersAdded||(e=t?"off":"on",i={remove:this.closeTooltip,move:this._moveTooltip},this._tooltip.options.permanent?i.add=this._openTooltip:(i.mouseover=this._openTooltip,i.mouseout=this.closeTooltip,i.click=this._openTooltip,this._map?this._addFocusListeners():i.add=this._addFocusListeners),this._tooltip.options.sticky&&(i.mousemove=this._moveTooltip),this[e](i),this._tooltipHandlersAdded=!t)},openTooltip:function(t){return this._tooltip&&(this instanceof ci||(this._tooltip._source=this),this._tooltip._prepareOpen(t)&&(this._tooltip.openOn(this._map),this.getElement?this._setAriaDescribedByOnLayer(this):this.eachLayer&&this.eachLayer(this._setAriaDescribedByOnLayer,this))),this},closeTooltip:function(){if(this._tooltip)return this._tooltip.close()},toggleTooltip:function(){return this._tooltip&&this._tooltip.toggle(this),this},isTooltipOpen:function(){return this._tooltip.isOpen()},setTooltipContent:function(t){return this._tooltip&&this._tooltip.setContent(t),this},getTooltip:function(){return this._tooltip},_addFocusListeners:function(){this.getElement?this._addFocusListenersOnLayer(this):this.eachLayer&&this.eachLayer(this._addFocusListenersOnLayer,this)},_addFocusListenersOnLayer:function(t){var e="function"==typeof t.getElement&&t.getElement();e&&(S(e,"focus",function(){this._tooltip._source=t,this.openTooltip()},this),S(e,"blur",this.closeTooltip,this))},_setAriaDescribedByOnLayer:function(t){t="function"==typeof t.getElement&&t.getElement();t&&t.setAttribute("aria-describedby",this._tooltip._container.id)},_openTooltip:function(t){var e;this._tooltip&&this._map&&(this._map.dragging&&this._map.dragging.moving()&&!this._openOnceFlag?(this._openOnceFlag=!0,(e=this)._map.once("moveend",function(){e._openOnceFlag=!1,e._openTooltip(t)})):(this._tooltip._source=t.layer||t.target,this.openTooltip(this._tooltip.options.sticky?t.latlng:void 0)))},_moveTooltip:function(t){var e=t.latlng;this._tooltip.options.sticky&&t.originalEvent&&(t=this._map.mouseEventToContainerPoint(t.originalEvent),t=this._map.containerPointToLayerPoint(t),e=this._map.layerPointToLatLng(t)),this._tooltip.setLatLng(e)}}),di.extend({options:{iconSize:[12,12],html:!1,bgPos:null,className:"leaflet-div-icon"},createIcon:function(t){var t=t&&"DIV"===t.tagName?t:document.createElement("div"),e=this.options;return e.html instanceof Element?(me(t),t.appendChild(e.html)):t.innerHTML=!1!==e.html?e.html:"",e.bgPos&&(e=m(e.bgPos),t.style.backgroundPosition=-e.x+"px "+-e.y+"px"),this._setIconStyles(t,"icon"),t},createShadow:function(){return null}}));di.Default=_i;var Ni=o.extend({options:{tileSize:256,opacity:1,updateWhenIdle:b.mobile,updateWhenZooming:!0,updateInterval:200,zIndex:1,bounds:null,minZoom:0,maxZoom:void 0,maxNativeZoom:void 0,minNativeZoom:void 0,noWrap:!1,pane:"tilePane",className:"",keepBuffer:2},initialize:function(t){c(this,t)},onAdd:function(){this._initContainer(),this._levels={},this._tiles={},this._resetView()},beforeAdd:function(t){t._addZoomLimit(this)},onRemove:function(t){this._removeAllTiles(),T(this._container),t._removeZoomLimit(this),this._container=null,this._tileZoom=void 0},bringToFront:function(){return this._map&&(fe(this._container),this._setAutoZIndex(Math.max)),this},bringToBack:function(){return this._map&&(ge(this._container),this._setAutoZIndex(Math.min)),this},getContainer:function(){return this._container},setOpacity:function(t){return this.options.opacity=t,this._updateOpacity(),this},setZIndex:function(t){return this.options.zIndex=t,this._updateZIndex(),this},isLoading:function(){return this._loading},redraw:function(){var t;return this._map&&(this._removeAllTiles(),(t=this._clampZoom(this._map.getZoom()))!==this._tileZoom&&(this._tileZoom=t,this._updateLevels()),this._update()),this},getEvents:function(){var t={viewprereset:this._invalidateAll,viewreset:this._resetView,zoom:this._resetView,moveend:this._onMoveEnd};return this.options.updateWhenIdle||(this._onMove||(this._onMove=j(this._onMoveEnd,this.options.updateInterval,this)),t.move=this._onMove),this._zoomAnimated&&(t.zoomanim=this._animateZoom),t},createTile:function(){return document.createElement("div")},getTileSize:function(){var t=this.options.tileSize;return t instanceof p?t:new p(t,t)},_updateZIndex:function(){this._container&&void 0!==this.options.zIndex&&null!==this.options.zIndex&&(this._container.style.zIndex=this.options.zIndex)},_setAutoZIndex:function(t){for(var e,i=this.getPane().children,n=-t(-1/0,1/0),o=0,s=i.length;o<s;o++)e=i[o].style.zIndex,i[o]!==this._container&&e&&(n=t(n,+e));isFinite(n)&&(this.options.zIndex=n+t(-1,1),this._updateZIndex())},_updateOpacity:function(){if(this._map&&!b.ielt9){C(this._container,this.options.opacity);var t,e=+new Date,i=!1,n=!1;for(t in this._tiles){var o,s=this._tiles[t];s.current&&s.loaded&&(o=Math.min(1,(e-s.loaded)/200),C(s.el,o),o<1?i=!0:(s.active?n=!0:this._onOpaqueTile(s),s.active=!0))}n&&!this._noPrune&&this._pruneTiles(),i&&(r(this._fadeFrame),this._fadeFrame=x(this._updateOpacity,this))}},_onOpaqueTile:u,_initContainer:function(){this._container||(this._container=P("div","leaflet-layer "+(this.options.className||"")),this._updateZIndex(),this.options.opacity<1&&this._updateOpacity(),this.getPane().appendChild(this._container))},_updateLevels:function(){var t=this._tileZoom,e=this.options.maxZoom;if(void 0!==t){for(var i in this._levels)i=Number(i),this._levels[i].el.children.length||i===t?(this._levels[i].el.style.zIndex=e-Math.abs(t-i),this._onUpdateLevel(i)):(T(this._levels[i].el),this._removeTilesAtZoom(i),this._onRemoveLevel(i),delete this._levels[i]);var n=this._levels[t],o=this._map;return n||((n=this._levels[t]={}).el=P("div","leaflet-tile-container leaflet-zoom-animated",this._container),n.el.style.zIndex=e,n.origin=o.project(o.unproject(o.getPixelOrigin()),t).round(),n.zoom=t,this._setZoomTransform(n,o.getCenter(),o.getZoom()),u(n.el.offsetWidth),this._onCreateLevel(n)),this._level=n}},_onUpdateLevel:u,_onRemoveLevel:u,_onCreateLevel:u,_pruneTiles:function(){if(this._map){var t,e,i,n=this._map.getZoom();if(n>this.options.maxZoom||n<this.options.minZoom)this._removeAllTiles();else{for(t in this._tiles)(i=this._tiles[t]).retain=i.current;for(t in this._tiles)(i=this._tiles[t]).current&&!i.active&&(e=i.coords,this._retainParent(e.x,e.y,e.z,e.z-5)||this._retainChildren(e.x,e.y,e.z,e.z+2));for(t in this._tiles)this._tiles[t].retain||this._removeTile(t)}}},_removeTilesAtZoom:function(t){for(var e in this._tiles)this._tiles[e].coords.z===t&&this._removeTile(e)},_removeAllTiles:function(){for(var t in this._tiles)this._removeTile(t)},_invalidateAll:function(){for(var t in this._levels)T(this._levels[t].el),this._onRemoveLevel(Number(t)),delete this._levels[t];this._removeAllTiles(),this._tileZoom=void 0},_retainParent:function(t,e,i,n){var t=Math.floor(t/2),e=Math.floor(e/2),i=i-1,o=new p(+t,+e),o=(o.z=i,this._tileCoordsToKey(o)),o=this._tiles[o];return o&&o.active?o.retain=!0:(o&&o.loaded&&(o.retain=!0),n<i&&this._retainParent(t,e,i,n))},_retainChildren:function(t,e,i,n){for(var o=2*t;o<2*t+2;o++)for(var s=2*e;s<2*e+2;s++){var r=new p(o,s),r=(r.z=i+1,this._tileCoordsToKey(r)),r=this._tiles[r];r&&r.active?r.retain=!0:(r&&r.loaded&&(r.retain=!0),i+1<n&&this._retainChildren(o,s,i+1,n))}},_resetView:function(t){t=t&&(t.pinch||t.flyTo);this._setView(this._map.getCenter(),this._map.getZoom(),t,t)},_animateZoom:function(t){this._setView(t.center,t.zoom,!0,t.noUpdate)},_clampZoom:function(t){var e=this.options;return void 0!==e.minNativeZoom&&t<e.minNativeZoom?e.minNativeZoom:void 0!==e.maxNativeZoom&&e.maxNativeZoom<t?e.maxNativeZoom:t},_setView:function(t,e,i,n){var o=Math.round(e),o=void 0!==this.options.maxZoom&&o>this.options.maxZoom||void 0!==this.options.minZoom&&o<this.options.minZoom?void 0:this._clampZoom(o),s=this.options.updateWhenZooming&&o!==this._tileZoom;n&&!s||(this._tileZoom=o,this._abortLoading&&this._abortLoading(),this._updateLevels(),this._resetGrid(),void 0!==o&&this._update(t),i||this._pruneTiles(),this._noPrune=!!i),this._setZoomTransforms(t,e)},_setZoomTransforms:function(t,e){for(var i in this._levels)this._setZoomTransform(this._levels[i],t,e)},_setZoomTransform:function(t,e,i){var n=this._map.getZoomScale(i,t.zoom),e=t.origin.multiplyBy(n).subtract(this._map._getNewPixelOrigin(e,i)).round();b.any3d?be(t.el,e,n):Z(t.el,e)},_resetGrid:function(){var t=this._map,e=t.options.crs,i=this._tileSize=this.getTileSize(),n=this._tileZoom,o=this._map.getPixelWorldBounds(this._tileZoom);o&&(this._globalTileRange=this._pxBoundsToTileRange(o)),this._wrapX=e.wrapLng&&!this.options.noWrap&&[Math.floor(t.project([0,e.wrapLng[0]],n).x/i.x),Math.ceil(t.project([0,e.wrapLng[1]],n).x/i.y)],this._wrapY=e.wrapLat&&!this.options.noWrap&&[Math.floor(t.project([e.wrapLat[0],0],n).y/i.x),Math.ceil(t.project([e.wrapLat[1],0],n).y/i.y)]},_onMoveEnd:function(){this._map&&!this._map._animatingZoom&&this._update()},_getTiledPixelBounds:function(t){var e=this._map,i=e._animatingZoom?Math.max(e._animateToZoom,e.getZoom()):e.getZoom(),i=e.getZoomScale(i,this._tileZoom),t=e.project(t,this._tileZoom).floor(),e=e.getSize().divideBy(2*i);return new f(t.subtract(e),t.add(e))},_update:function(t){var e=this._map;if(e){var i=this._clampZoom(e.getZoom());if(void 0===t&&(t=e.getCenter()),void 0!==this._tileZoom){var n,e=this._getTiledPixelBounds(t),o=this._pxBoundsToTileRange(e),s=o.getCenter(),r=[],e=this.options.keepBuffer,a=new f(o.getBottomLeft().subtract([e,-e]),o.getTopRight().add([e,-e]));if(!(isFinite(o.min.x)&&isFinite(o.min.y)&&isFinite(o.max.x)&&isFinite(o.max.y)))throw new Error("Attempted to load an infinite number of tiles");for(n in this._tiles){var h=this._tiles[n].coords;h.z===this._tileZoom&&a.contains(new p(h.x,h.y))||(this._tiles[n].current=!1)}if(1<Math.abs(i-this._tileZoom))this._setView(t,i);else{for(var l=o.min.y;l<=o.max.y;l++)for(var u=o.min.x;u<=o.max.x;u++){var c,d=new p(u,l);d.z=this._tileZoom,this._isValidTile(d)&&((c=this._tiles[this._tileCoordsToKey(d)])?c.current=!0:r.push(d))}if(r.sort(function(t,e){return t.distanceTo(s)-e.distanceTo(s)}),0!==r.length){this._loading||(this._loading=!0,this.fire("loading"));for(var _=document.createDocumentFragment(),u=0;u<r.length;u++)this._addTile(r[u],_);this._level.el.appendChild(_)}}}}},_isValidTile:function(t){var e=this._map.options.crs;if(!e.infinite){var i=this._globalTileRange;if(!e.wrapLng&&(t.x<i.min.x||t.x>i.max.x)||!e.wrapLat&&(t.y<i.min.y||t.y>i.max.y))return!1}return!this.options.bounds||(e=this._tileCoordsToBounds(t),g(this.options.bounds).overlaps(e))},_keyToBounds:function(t){return this._tileCoordsToBounds(this._keyToTileCoords(t))},_tileCoordsToNwSe:function(t){var e=this._map,i=this.getTileSize(),n=t.scaleBy(i),i=n.add(i);return[e.unproject(n,t.z),e.unproject(i,t.z)]},_tileCoordsToBounds:function(t){t=this._tileCoordsToNwSe(t),t=new s(t[0],t[1]);return t=this.options.noWrap?t:this._map.wrapLatLngBounds(t)},_tileCoordsToKey:function(t){return t.x+":"+t.y+":"+t.z},_keyToTileCoords:function(t){var t=t.split(":"),e=new p(+t[0],+t[1]);return e.z=+t[2],e},_removeTile:function(t){var e=this._tiles[t];e&&(T(e.el),delete this._tiles[t],this.fire("tileunload",{tile:e.el,coords:this._keyToTileCoords(t)}))},_initTile:function(t){M(t,"leaflet-tile");var e=this.getTileSize();t.style.width=e.x+"px",t.style.height=e.y+"px",t.onselectstart=u,t.onmousemove=u,b.ielt9&&this.options.opacity<1&&C(t,this.options.opacity)},_addTile:function(t,e){var i=this._getTilePos(t),n=this._tileCoordsToKey(t),o=this.createTile(this._wrapCoords(t),a(this._tileReady,this,t));this._initTile(o),this.createTile.length<2&&x(a(this._tileReady,this,t,null,o)),Z(o,i),this._tiles[n]={el:o,coords:t,current:!0},e.appendChild(o),this.fire("tileloadstart",{tile:o,coords:t})},_tileReady:function(t,e,i){e&&this.fire("tileerror",{error:e,tile:i,coords:t});var n=this._tileCoordsToKey(t);(i=this._tiles[n])&&(i.loaded=+new Date,this._map._fadeAnimated?(C(i.el,0),r(this._fadeFrame),this._fadeFrame=x(this._updateOpacity,this)):(i.active=!0,this._pruneTiles()),e||(M(i.el,"leaflet-tile-loaded"),this.fire("tileload",{tile:i.el,coords:t})),this._noTilesToLoad()&&(this._loading=!1,this.fire("load"),b.ielt9||!this._map._fadeAnimated?x(this._pruneTiles,this):setTimeout(a(this._pruneTiles,this),250)))},_getTilePos:function(t){return t.scaleBy(this.getTileSize()).subtract(this._level.origin)},_wrapCoords:function(t){var e=new p(this._wrapX?H(t.x,this._wrapX):t.x,this._wrapY?H(t.y,this._wrapY):t.y);return e.z=t.z,e},_pxBoundsToTileRange:function(t){var e=this.getTileSize();return new f(t.min.unscaleBy(e).floor(),t.max.unscaleBy(e).ceil().subtract([1,1]))},_noTilesToLoad:function(){for(var t in this._tiles)if(!this._tiles[t].loaded)return!1;return!0}});var Di=Ni.extend({options:{minZoom:0,maxZoom:18,subdomains:"abc",errorTileUrl:"",zoomOffset:0,tms:!1,zoomReverse:!1,detectRetina:!1,crossOrigin:!1,referrerPolicy:!1},initialize:function(t,e){this._url=t,(e=c(this,e)).detectRetina&&b.retina&&0<e.maxZoom?(e.tileSize=Math.floor(e.tileSize/2),e.zoomReverse?(e.zoomOffset--,e.minZoom=Math.min(e.maxZoom,e.minZoom+1)):(e.zoomOffset++,e.maxZoom=Math.max(e.minZoom,e.maxZoom-1)),e.minZoom=Math.max(0,e.minZoom)):e.zoomReverse?e.minZoom=Math.min(e.maxZoom,e.minZoom):e.maxZoom=Math.max(e.minZoom,e.maxZoom),"string"==typeof e.subdomains&&(e.subdomains=e.subdomains.split("")),this.on("tileunload",this._onTileRemove)},setUrl:function(t,e){return this._url===t&&void 0===e&&(e=!0),this._url=t,e||this.redraw(),this},createTile:function(t,e){var i=document.createElement("img");return S(i,"load",a(this._tileOnLoad,this,e,i)),S(i,"error",a(this._tileOnError,this,e,i)),!this.options.crossOrigin&&""!==this.options.crossOrigin||(i.crossOrigin=!0===this.options.crossOrigin?"":this.options.crossOrigin),"string"==typeof this.options.referrerPolicy&&(i.referrerPolicy=this.options.referrerPolicy),i.alt="",i.src=this.getTileUrl(t),i},getTileUrl:function(t){var e={r:b.retina?"@2x":"",s:this._getSubdomain(t),x:t.x,y:t.y,z:this._getZoomForUrl()};return this._map&&!this._map.options.crs.infinite&&(t=this._globalTileRange.max.y-t.y,this.options.tms&&(e.y=t),e["-y"]=t),q(this._url,l(e,this.options))},_tileOnLoad:function(t,e){b.ielt9?setTimeout(a(t,this,null,e),0):t(null,e)},_tileOnError:function(t,e,i){var n=this.options.errorTileUrl;n&&e.getAttribute("src")!==n&&(e.src=n),t(i,e)},_onTileRemove:function(t){t.tile.onload=null},_getZoomForUrl:function(){var t=this._tileZoom,e=this.options.maxZoom;return(t=this.options.zoomReverse?e-t:t)+this.options.zoomOffset},_getSubdomain:function(t){t=Math.abs(t.x+t.y)%this.options.subdomains.length;return this.options.subdomains[t]},_abortLoading:function(){var t,e,i;for(t in this._tiles)this._tiles[t].coords.z!==this._tileZoom&&((i=this._tiles[t].el).onload=u,i.onerror=u,i.complete||(i.src=K,e=this._tiles[t].coords,T(i),delete this._tiles[t],this.fire("tileabort",{tile:i,coords:e})))},_removeTile:function(t){var e=this._tiles[t];if(e)return e.el.setAttribute("src",K),Ni.prototype._removeTile.call(this,t)},_tileReady:function(t,e,i){if(this._map&&(!i||i.getAttribute("src")!==K))return Ni.prototype._tileReady.call(this,t,e,i)}});function ji(t,e){return new Di(t,e)}var Hi=Di.extend({defaultWmsParams:{service:"WMS",request:"GetMap",layers:"",styles:"",format:"image/jpeg",transparent:!1,version:"1.1.1"},options:{crs:null,uppercase:!1},initialize:function(t,e){this._url=t;var i,n=l({},this.defaultWmsParams);for(i in e)i in this.options||(n[i]=e[i]);var t=(e=c(this,e)).detectRetina&&b.retina?2:1,o=this.getTileSize();n.width=o.x*t,n.height=o.y*t,this.wmsParams=n},onAdd:function(t){this._crs=this.options.crs||t.options.crs,this._wmsVersion=parseFloat(this.wmsParams.version);var e=1.3<=this._wmsVersion?"crs":"srs";this.wmsParams[e]=this._crs.code,Di.prototype.onAdd.call(this,t)},getTileUrl:function(t){var e=this._tileCoordsToNwSe(t),i=this._crs,i=_(i.project(e[0]),i.project(e[1])),e=i.min,i=i.max,e=(1.3<=this._wmsVersion&&this._crs===li?[e.y,e.x,i.y,i.x]:[e.x,e.y,i.x,i.y]).join(","),i=Di.prototype.getTileUrl.call(this,t);return i+U(this.wmsParams,i,this.options.uppercase)+(this.options.uppercase?"&BBOX=":"&bbox=")+e},setParams:function(t,e){return l(this.wmsParams,t),e||this.redraw(),this}});Di.WMS=Hi,ji.wms=function(t,e){return new Hi(t,e)};var Wi=o.extend({options:{padding:.1},initialize:function(t){c(this,t),h(this),this._layers=this._layers||{}},onAdd:function(){this._container||(this._initContainer(),M(this._container,"leaflet-zoom-animated")),this.getPane().appendChild(this._container),this._update(),this.on("update",this._updatePaths,this)},onRemove:function(){this.off("update",this._updatePaths,this),this._destroyContainer()},getEvents:function(){var t={viewreset:this._reset,zoom:this._onZoom,moveend:this._update,zoomend:this._onZoomEnd};return this._zoomAnimated&&(t.zoomanim=this._onAnimZoom),t},_onAnimZoom:function(t){this._updateTransform(t.center,t.zoom)},_onZoom:function(){this._updateTransform(this._map.getCenter(),this._map.getZoom())},_updateTransform:function(t,e){var i=this._map.getZoomScale(e,this._zoom),n=this._map.getSize().multiplyBy(.5+this.options.padding),o=this._map.project(this._center,e),n=n.multiplyBy(-i).add(o).subtract(this._map._getNewPixelOrigin(t,e));b.any3d?be(this._container,n,i):Z(this._container,n)},_reset:function(){for(var t in this._update(),this._updateTransform(this._center,this._zoom),this._layers)this._layers[t]._reset()},_onZoomEnd:function(){for(var t in this._layers)this._layers[t]._project()},_updatePaths:function(){for(var t in this._layers)this._layers[t]._update()},_update:function(){var t=this.options.padding,e=this._map.getSize(),i=this._map.containerPointToLayerPoint(e.multiplyBy(-t)).round();this._bounds=new f(i,i.add(e.multiplyBy(1+2*t)).round()),this._center=this._map.getCenter(),this._zoom=this._map.getZoom()}}),Fi=Wi.extend({options:{tolerance:0},getEvents:function(){var t=Wi.prototype.getEvents.call(this);return t.viewprereset=this._onViewPreReset,t},_onViewPreReset:function(){this._postponeUpdatePaths=!0},onAdd:function(){Wi.prototype.onAdd.call(this),this._draw()},_initContainer:function(){var t=this._container=document.createElement("canvas");S(t,"mousemove",this._onMouseMove,this),S(t,"click dblclick mousedown mouseup contextmenu",this._onClick,this),S(t,"mouseout",this._handleMouseOut,this),t._leaflet_disable_events=!0,this._ctx=t.getContext("2d")},_destroyContainer:function(){r(this._redrawRequest),delete this._ctx,T(this._container),k(this._container),delete this._container},_updatePaths:function(){if(!this._postponeUpdatePaths){for(var t in this._redrawBounds=null,this._layers)this._layers[t]._update();this._redraw()}},_update:function(){var t,e,i,n;this._map._animatingZoom&&this._bounds||(Wi.prototype._update.call(this),t=this._bounds,e=this._container,i=t.getSize(),n=b.retina?2:1,Z(e,t.min),e.width=n*i.x,e.height=n*i.y,e.style.width=i.x+"px",e.style.height=i.y+"px",b.retina&&this._ctx.scale(2,2),this._ctx.translate(-t.min.x,-t.min.y),this.fire("update"))},_reset:function(){Wi.prototype._reset.call(this),this._postponeUpdatePaths&&(this._postponeUpdatePaths=!1,this._updatePaths())},_initPath:function(t){this._updateDashArray(t);t=(this._layers[h(t)]=t)._order={layer:t,prev:this._drawLast,next:null};this._drawLast&&(this._drawLast.next=t),this._drawLast=t,this._drawFirst=this._drawFirst||this._drawLast},_addPath:function(t){this._requestRedraw(t)},_removePath:function(t){var e=t._order,i=e.next,e=e.prev;i?i.prev=e:this._drawLast=e,e?e.next=i:this._drawFirst=i,delete t._order,delete this._layers[h(t)],this._requestRedraw(t)},_updatePath:function(t){this._extendRedrawBounds(t),t._project(),t._update(),this._requestRedraw(t)},_updateStyle:function(t){this._updateDashArray(t),this._requestRedraw(t)},_updateDashArray:function(t){if("string"==typeof t.options.dashArray){for(var e,i=t.options.dashArray.split(/[, ]+/),n=[],o=0;o<i.length;o++){if(e=Number(i[o]),isNaN(e))return;n.push(e)}t.options._dashArray=n}else t.options._dashArray=t.options.dashArray},_requestRedraw:function(t){this._map&&(this._extendRedrawBounds(t),this._redrawRequest=this._redrawRequest||x(this._redraw,this))},_extendRedrawBounds:function(t){var e;t._pxBounds&&(e=(t.options.weight||0)+1,this._redrawBounds=this._redrawBounds||new f,this._redrawBounds.extend(t._pxBounds.min.subtract([e,e])),this._redrawBounds.extend(t._pxBounds.max.add([e,e])))},_redraw:function(){this._redrawRequest=null,this._redrawBounds&&(this._redrawBounds.min._floor(),this._redrawBounds.max._ceil()),this._clear(),this._draw(),this._redrawBounds=null},_clear:function(){var t,e=this._redrawBounds;e?(t=e.getSize(),this._ctx.clearRect(e.min.x,e.min.y,t.x,t.y)):(this._ctx.save(),this._ctx.setTransform(1,0,0,1,0,0),this._ctx.clearRect(0,0,this._container.width,this._container.height),this._ctx.restore())},_draw:function(){var t,e,i=this._redrawBounds;this._ctx.save(),i&&(e=i.getSize(),this._ctx.beginPath(),this._ctx.rect(i.min.x,i.min.y,e.x,e.y),this._ctx.clip()),this._drawing=!0;for(var n=this._drawFirst;n;n=n.next)t=n.layer,(!i||t._pxBounds&&t._pxBounds.intersects(i))&&t._updatePath();this._drawing=!1,this._ctx.restore()},_updatePoly:function(t,e){if(this._drawing){var i,n,o,s,r=t._parts,a=r.length,h=this._ctx;if(a){for(h.beginPath(),i=0;i<a;i++){for(n=0,o=r[i].length;n<o;n++)s=r[i][n],h[n?"lineTo":"moveTo"](s.x,s.y);e&&h.closePath()}this._fillStroke(h,t)}}},_updateCircle:function(t){var e,i,n,o;this._drawing&&!t._empty()&&(e=t._point,i=this._ctx,n=Math.max(Math.round(t._radius),1),1!=(o=(Math.max(Math.round(t._radiusY),1)||n)/n)&&(i.save(),i.scale(1,o)),i.beginPath(),i.arc(e.x,e.y/o,n,0,2*Math.PI,!1),1!=o&&i.restore(),this._fillStroke(i,t))},_fillStroke:function(t,e){var i=e.options;i.fill&&(t.globalAlpha=i.fillOpacity,t.fillStyle=i.fillColor||i.color,t.fill(i.fillRule||"evenodd")),i.stroke&&0!==i.weight&&(t.setLineDash&&t.setLineDash(e.options&&e.options._dashArray||[]),t.globalAlpha=i.opacity,t.lineWidth=i.weight,t.strokeStyle=i.color,t.lineCap=i.lineCap,t.lineJoin=i.lineJoin,t.stroke())},_onClick:function(t){for(var e,i,n=this._map.mouseEventToLayerPoint(t),o=this._drawFirst;o;o=o.next)(e=o.layer).options.interactive&&e._containsPoint(n)&&(("click"===t.type||"preclick"===t.type)&&this._map._draggableMoved(e)||(i=e));this._fireEvent(!!i&&[i],t)},_onMouseMove:function(t){var e;!this._map||this._map.dragging.moving()||this._map._animatingZoom||(e=this._map.mouseEventToLayerPoint(t),this._handleMouseHover(t,e))},_handleMouseOut:function(t){var e=this._hoveredLayer;e&&(z(this._container,"leaflet-interactive"),this._fireEvent([e],t,"mouseout"),this._hoveredLayer=null,this._mouseHoverThrottled=!1)},_handleMouseHover:function(t,e){if(!this._mouseHoverThrottled){for(var i,n,o=this._drawFirst;o;o=o.next)(i=o.layer).options.interactive&&i._containsPoint(e)&&(n=i);n!==this._hoveredLayer&&(this._handleMouseOut(t),n&&(M(this._container,"leaflet-interactive"),this._fireEvent([n],t,"mouseover"),this._hoveredLayer=n)),this._fireEvent(!!this._hoveredLayer&&[this._hoveredLayer],t),this._mouseHoverThrottled=!0,setTimeout(a(function(){this._mouseHoverThrottled=!1},this),32)}},_fireEvent:function(t,e,i){this._map._fireDOMEvent(e,i||e.type,t)},_bringToFront:function(t){var e,i,n=t._order;n&&(e=n.next,i=n.prev,e&&((e.prev=i)?i.next=e:e&&(this._drawFirst=e),n.prev=this._drawLast,(this._drawLast.next=n).next=null,this._drawLast=n,this._requestRedraw(t)))},_bringToBack:function(t){var e,i,n=t._order;n&&(e=n.next,(i=n.prev)&&((i.next=e)?e.prev=i:i&&(this._drawLast=i),n.prev=null,n.next=this._drawFirst,this._drawFirst.prev=n,this._drawFirst=n,this._requestRedraw(t)))}});function Ui(t){return b.canvas?new Fi(t):null}var Vi=function(){try{return document.namespaces.add("lvml","urn:schemas-microsoft-com:vml"),function(t){return document.createElement("<lvml:"+t+' class="lvml">')}}catch(t){}return function(t){return document.createElement("<"+t+' xmlns="urn:schemas-microsoft.com:vml" class="lvml">')}}(),zt={_initContainer:function(){this._container=P("div","leaflet-vml-container")},_update:function(){this._map._animatingZoom||(Wi.prototype._update.call(this),this.fire("update"))},_initPath:function(t){var e=t._container=Vi("shape");M(e,"leaflet-vml-shape "+(this.options.className||"")),e.coordsize="1 1",t._path=Vi("path"),e.appendChild(t._path),this._updateStyle(t),this._layers[h(t)]=t},_addPath:function(t){var e=t._container;this._container.appendChild(e),t.options.interactive&&t.addInteractiveTarget(e)},_removePath:function(t){var e=t._container;T(e),t.removeInteractiveTarget(e),delete this._layers[h(t)]},_updateStyle:function(t){var e=t._stroke,i=t._fill,n=t.options,o=t._container;o.stroked=!!n.stroke,o.filled=!!n.fill,n.stroke?(e=e||(t._stroke=Vi("stroke")),o.appendChild(e),e.weight=n.weight+"px",e.color=n.color,e.opacity=n.opacity,n.dashArray?e.dashStyle=d(n.dashArray)?n.dashArray.join(" "):n.dashArray.replace(/( *, *)/g," "):e.dashStyle="",e.endcap=n.lineCap.replace("butt","flat"),e.joinstyle=n.lineJoin):e&&(o.removeChild(e),t._stroke=null),n.fill?(i=i||(t._fill=Vi("fill")),o.appendChild(i),i.color=n.fillColor||n.color,i.opacity=n.fillOpacity):i&&(o.removeChild(i),t._fill=null)},_updateCircle:function(t){var e=t._point.round(),i=Math.round(t._radius),n=Math.round(t._radiusY||i);this._setPath(t,t._empty()?"M0 0":"AL "+e.x+","+e.y+" "+i+","+n+" 0,23592600")},_setPath:function(t,e){t._path.v=e},_bringToFront:function(t){fe(t._container)},_bringToBack:function(t){ge(t._container)}},qi=b.vml?Vi:ct,Gi=Wi.extend({_initContainer:function(){this._container=qi("svg"),this._container.setAttribute("pointer-events","none"),this._rootGroup=qi("g"),this._container.appendChild(this._rootGroup)},_destroyContainer:function(){T(this._container),k(this._container),delete this._container,delete this._rootGroup,delete this._svgSize},_update:function(){var t,e,i;this._map._animatingZoom&&this._bounds||(Wi.prototype._update.call(this),e=(t=this._bounds).getSize(),i=this._container,this._svgSize&&this._svgSize.equals(e)||(this._svgSize=e,i.setAttribute("width",e.x),i.setAttribute("height",e.y)),Z(i,t.min),i.setAttribute("viewBox",[t.min.x,t.min.y,e.x,e.y].join(" ")),this.fire("update"))},_initPath:function(t){var e=t._path=qi("path");t.options.className&&M(e,t.options.className),t.options.interactive&&M(e,"leaflet-interactive"),this._updateStyle(t),this._layers[h(t)]=t},_addPath:function(t){this._rootGroup||this._initContainer(),this._rootGroup.appendChild(t._path),t.addInteractiveTarget(t._path)},_removePath:function(t){T(t._path),t.removeInteractiveTarget(t._path),delete this._layers[h(t)]},_updatePath:function(t){t._project(),t._update()},_updateStyle:function(t){var e=t._path,t=t.options;e&&(t.stroke?(e.setAttribute("stroke",t.color),e.setAttribute("stroke-opacity",t.opacity),e.setAttribute("stroke-width",t.weight),e.setAttribute("stroke-linecap",t.lineCap),e.setAttribute("stroke-linejoin",t.lineJoin),t.dashArray?e.setAttribute("stroke-dasharray",t.dashArray):e.removeAttribute("stroke-dasharray"),t.dashOffset?e.setAttribute("stroke-dashoffset",t.dashOffset):e.removeAttribute("stroke-dashoffset")):e.setAttribute("stroke","none"),t.fill?(e.setAttribute("fill",t.fillColor||t.color),e.setAttribute("fill-opacity",t.fillOpacity),e.setAttribute("fill-rule",t.fillRule||"evenodd")):e.setAttribute("fill","none"))},_updatePoly:function(t,e){this._setPath(t,dt(t._parts,e))},_updateCircle:function(t){var e=t._point,i=Math.max(Math.round(t._radius),1),n="a"+i+","+(Math.max(Math.round(t._radiusY),1)||i)+" 0 1,0 ",e=t._empty()?"M0 0":"M"+(e.x-i)+","+e.y+n+2*i+",0 "+n+2*-i+",0 ";this._setPath(t,e)},_setPath:function(t,e){t._path.setAttribute("d",e)},_bringToFront:function(t){fe(t._path)},_bringToBack:function(t){ge(t._path)}});function Ki(t){return b.svg||b.vml?new Gi(t):null}b.vml&&Gi.include(zt),A.include({getRenderer:function(t){t=(t=t.options.renderer||this._getPaneRenderer(t.options.pane)||this.options.renderer||this._renderer)||(this._renderer=this._createRenderer());return this.hasLayer(t)||this.addLayer(t),t},_getPaneRenderer:function(t){var e;return"overlayPane"!==t&&void 0!==t&&(void 0===(e=this._paneRenderers[t])&&(e=this._createRenderer({pane:t}),this._paneRenderers[t]=e),e)},_createRenderer:function(t){return this.options.preferCanvas&&Ui(t)||Ki(t)}});var Yi=xi.extend({initialize:function(t,e){xi.prototype.initialize.call(this,this._boundsToLatLngs(t),e)},setBounds:function(t){return this.setLatLngs(this._boundsToLatLngs(t))},_boundsToLatLngs:function(t){return[(t=g(t)).getSouthWest(),t.getNorthWest(),t.getNorthEast(),t.getSouthEast()]}});Gi.create=qi,Gi.pointsToPath=dt,wi.geometryToLayer=bi,wi.coordsToLatLng=Li,wi.coordsToLatLngs=Ti,wi.latLngToCoords=Mi,wi.latLngsToCoords=zi,wi.getFeature=Ci,wi.asFeature=Zi,A.mergeOptions({boxZoom:!0});var _t=n.extend({initialize:function(t){this._map=t,this._container=t._container,this._pane=t._panes.overlayPane,this._resetStateTimeout=0,t.on("unload",this._destroy,this)},addHooks:function(){S(this._container,"mousedown",this._onMouseDown,this)},removeHooks:function(){k(this._container,"mousedown",this._onMouseDown,this)},moved:function(){return this._moved},_destroy:function(){T(this._pane),delete this._pane},_resetState:function(){this._resetStateTimeout=0,this._moved=!1},_clearDeferredResetState:function(){0!==this._resetStateTimeout&&(clearTimeout(this._resetStateTimeout),this._resetStateTimeout=0)},_onMouseDown:function(t){if(!t.shiftKey||1!==t.which&&1!==t.button)return!1;this._clearDeferredResetState(),this._resetState(),re(),Le(),this._startPoint=this._map.mouseEventToContainerPoint(t),S(document,{contextmenu:Re,mousemove:this._onMouseMove,mouseup:this._onMouseUp,keydown:this._onKeyDown},this)},_onMouseMove:function(t){this._moved||(this._moved=!0,this._box=P("div","leaflet-zoom-box",this._container),M(this._container,"leaflet-crosshair"),this._map.fire("boxzoomstart")),this._point=this._map.mouseEventToContainerPoint(t);var t=new f(this._point,this._startPoint),e=t.getSize();Z(this._box,t.min),this._box.style.width=e.x+"px",this._box.style.height=e.y+"px"},_finish:function(){this._moved&&(T(this._box),z(this._container,"leaflet-crosshair")),ae(),Te(),k(document,{contextmenu:Re,mousemove:this._onMouseMove,mouseup:this._onMouseUp,keydown:this._onKeyDown},this)},_onMouseUp:function(t){1!==t.which&&1!==t.button||(this._finish(),this._moved&&(this._clearDeferredResetState(),this._resetStateTimeout=setTimeout(a(this._resetState,this),0),t=new s(this._map.containerPointToLatLng(this._startPoint),this._map.containerPointToLatLng(this._point)),this._map.fitBounds(t).fire("boxzoomend",{boxZoomBounds:t})))},_onKeyDown:function(t){27===t.keyCode&&(this._finish(),this._clearDeferredResetState(),this._resetState())}}),Ct=(A.addInitHook("addHandler","boxZoom",_t),A.mergeOptions({doubleClickZoom:!0}),n.extend({addHooks:function(){this._map.on("dblclick",this._onDoubleClick,this)},removeHooks:function(){this._map.off("dblclick",this._onDoubleClick,this)},_onDoubleClick:function(t){var e=this._map,i=e.getZoom(),n=e.options.zoomDelta,i=t.originalEvent.shiftKey?i-n:i+n;"center"===e.options.doubleClickZoom?e.setZoom(i):e.setZoomAround(t.containerPoint,i)}})),Zt=(A.addInitHook("addHandler","doubleClickZoom",Ct),A.mergeOptions({dragging:!0,inertia:!0,inertiaDeceleration:3400,inertiaMaxSpeed:1/0,easeLinearity:.2,worldCopyJump:!1,maxBoundsViscosity:0}),n.extend({addHooks:function(){var t;this._draggable||(t=this._map,this._draggable=new Xe(t._mapPane,t._container),this._draggable.on({dragstart:this._onDragStart,drag:this._onDrag,dragend:this._onDragEnd},this),this._draggable.on("predrag",this._onPreDragLimit,this),t.options.worldCopyJump&&(this._draggable.on("predrag",this._onPreDragWrap,this),t.on("zoomend",this._onZoomEnd,this),t.whenReady(this._onZoomEnd,this))),M(this._map._container,"leaflet-grab leaflet-touch-drag"),this._draggable.enable(),this._positions=[],this._times=[]},removeHooks:function(){z(this._map._container,"leaflet-grab"),z(this._map._container,"leaflet-touch-drag"),this._draggable.disable()},moved:function(){return this._draggable&&this._draggable._moved},moving:function(){return this._draggable&&this._draggable._moving},_onDragStart:function(){var t,e=this._map;e._stop(),this._map.options.maxBounds&&this._map.options.maxBoundsViscosity?(t=g(this._map.options.maxBounds),this._offsetLimit=_(this._map.latLngToContainerPoint(t.getNorthWest()).multiplyBy(-1),this._map.latLngToContainerPoint(t.getSouthEast()).multiplyBy(-1).add(this._map.getSize())),this._viscosity=Math.min(1,Math.max(0,this._map.options.maxBoundsViscosity))):this._offsetLimit=null,e.fire("movestart").fire("dragstart"),e.options.inertia&&(this._positions=[],this._times=[])},_onDrag:function(t){var e,i;this._map.options.inertia&&(e=this._lastTime=+new Date,i=this._lastPos=this._draggable._absPos||this._draggable._newPos,this._positions.push(i),this._times.push(e),this._prunePositions(e)),this._map.fire("move",t).fire("drag",t)},_prunePositions:function(t){for(;1<this._positions.length&&50<t-this._times[0];)this._positions.shift(),this._times.shift()},_onZoomEnd:function(){var t=this._map.getSize().divideBy(2),e=this._map.latLngToLayerPoint([0,0]);this._initialWorldOffset=e.subtract(t).x,this._worldWidth=this._map.getPixelWorldBounds().getSize().x},_viscousLimit:function(t,e){return t-(t-e)*this._viscosity},_onPreDragLimit:function(){var t,e;this._viscosity&&this._offsetLimit&&(t=this._draggable._newPos.subtract(this._draggable._startPos),e=this._offsetLimit,t.x<e.min.x&&(t.x=this._viscousLimit(t.x,e.min.x)),t.y<e.min.y&&(t.y=this._viscousLimit(t.y,e.min.y)),t.x>e.max.x&&(t.x=this._viscousLimit(t.x,e.max.x)),t.y>e.max.y&&(t.y=this._viscousLimit(t.y,e.max.y)),this._draggable._newPos=this._draggable._startPos.add(t))},_onPreDragWrap:function(){var t=this._worldWidth,e=Math.round(t/2),i=this._initialWorldOffset,n=this._draggable._newPos.x,o=(n-e+i)%t+e-i,n=(n+e+i)%t-e-i,t=Math.abs(o+i)<Math.abs(n+i)?o:n;this._draggable._absPos=this._draggable._newPos.clone(),this._draggable._newPos.x=t},_onDragEnd:function(t){var e,i,n,o,s=this._map,r=s.options,a=!r.inertia||t.noInertia||this._times.length<2;s.fire("dragend",t),!a&&(this._prunePositions(+new Date),t=this._lastPos.subtract(this._positions[0]),a=(this._lastTime-this._times[0])/1e3,e=r.easeLinearity,a=(t=t.multiplyBy(e/a)).distanceTo([0,0]),i=Math.min(r.inertiaMaxSpeed,a),t=t.multiplyBy(i/a),n=i/(r.inertiaDeceleration*e),(o=t.multiplyBy(-n/2).round()).x||o.y)?(o=s._limitOffset(o,s.options.maxBounds),x(function(){s.panBy(o,{duration:n,easeLinearity:e,noMoveStart:!0,animate:!0})})):s.fire("moveend")}})),St=(A.addInitHook("addHandler","dragging",Zt),A.mergeOptions({keyboard:!0,keyboardPanDelta:80}),n.extend({keyCodes:{left:[37],right:[39],down:[40],up:[38],zoomIn:[187,107,61,171],zoomOut:[189,109,54,173]},initialize:function(t){this._map=t,this._setPanDelta(t.options.keyboardPanDelta),this._setZoomDelta(t.options.zoomDelta)},addHooks:function(){var t=this._map._container;t.tabIndex<=0&&(t.tabIndex="0"),S(t,{focus:this._onFocus,blur:this._onBlur,mousedown:this._onMouseDown},this),this._map.on({focus:this._addHooks,blur:this._removeHooks},this)},removeHooks:function(){this._removeHooks(),k(this._map._container,{focus:this._onFocus,blur:this._onBlur,mousedown:this._onMouseDown},this),this._map.off({focus:this._addHooks,blur:this._removeHooks},this)},_onMouseDown:function(){var t,e,i;this._focused||(i=document.body,t=document.documentElement,e=i.scrollTop||t.scrollTop,i=i.scrollLeft||t.scrollLeft,this._map._container.focus(),window.scrollTo(i,e))},_onFocus:function(){this._focused=!0,this._map.fire("focus")},_onBlur:function(){this._focused=!1,this._map.fire("blur")},_setPanDelta:function(t){for(var e=this._panKeys={},i=this.keyCodes,n=0,o=i.left.length;n<o;n++)e[i.left[n]]=[-1*t,0];for(n=0,o=i.right.length;n<o;n++)e[i.right[n]]=[t,0];for(n=0,o=i.down.length;n<o;n++)e[i.down[n]]=[0,t];for(n=0,o=i.up.length;n<o;n++)e[i.up[n]]=[0,-1*t]},_setZoomDelta:function(t){for(var e=this._zoomKeys={},i=this.keyCodes,n=0,o=i.zoomIn.length;n<o;n++)e[i.zoomIn[n]]=t;for(n=0,o=i.zoomOut.length;n<o;n++)e[i.zoomOut[n]]=-t},_addHooks:function(){S(document,"keydown",this._onKeyDown,this)},_removeHooks:function(){k(document,"keydown",this._onKeyDown,this)},_onKeyDown:function(t){if(!(t.altKey||t.ctrlKey||t.metaKey)){var e,i,n=t.keyCode,o=this._map;if(n in this._panKeys)o._panAnim&&o._panAnim._inProgress||(i=this._panKeys[n],t.shiftKey&&(i=m(i).multiplyBy(3)),o.options.maxBounds&&(i=o._limitOffset(m(i),o.options.maxBounds)),o.options.worldCopyJump?(e=o.wrapLatLng(o.unproject(o.project(o.getCenter()).add(i))),o.panTo(e)):o.panBy(i));else if(n in this._zoomKeys)o.setZoom(o.getZoom()+(t.shiftKey?3:1)*this._zoomKeys[n]);else{if(27!==n||!o._popup||!o._popup.options.closeOnEscapeKey)return;o.closePopup()}Re(t)}}})),Et=(A.addInitHook("addHandler","keyboard",St),A.mergeOptions({scrollWheelZoom:!0,wheelDebounceTime:40,wheelPxPerZoomLevel:60}),n.extend({addHooks:function(){S(this._map._container,"wheel",this._onWheelScroll,this),this._delta=0},removeHooks:function(){k(this._map._container,"wheel",this._onWheelScroll,this)},_onWheelScroll:function(t){var e=He(t),i=this._map.options.wheelDebounceTime,e=(this._delta+=e,this._lastMousePos=this._map.mouseEventToContainerPoint(t),this._startTime||(this._startTime=+new Date),Math.max(i-(+new Date-this._startTime),0));clearTimeout(this._timer),this._timer=setTimeout(a(this._performZoom,this),e),Re(t)},_performZoom:function(){var t=this._map,e=t.getZoom(),i=this._map.options.zoomSnap||0,n=(t._stop(),this._delta/(4*this._map.options.wheelPxPerZoomLevel)),n=4*Math.log(2/(1+Math.exp(-Math.abs(n))))/Math.LN2,i=i?Math.ceil(n/i)*i:n,n=t._limitZoom(e+(0<this._delta?i:-i))-e;this._delta=0,this._startTime=null,n&&("center"===t.options.scrollWheelZoom?t.setZoom(e+n):t.setZoomAround(this._lastMousePos,e+n))}})),kt=(A.addInitHook("addHandler","scrollWheelZoom",Et),A.mergeOptions({tapHold:b.touchNative&&b.safari&&b.mobile,tapTolerance:15}),n.extend({addHooks:function(){S(this._map._container,"touchstart",this._onDown,this)},removeHooks:function(){k(this._map._container,"touchstart",this._onDown,this)},_onDown:function(t){var e;clearTimeout(this._holdTimeout),1===t.touches.length&&(e=t.touches[0],this._startPos=this._newPos=new p(e.clientX,e.clientY),this._holdTimeout=setTimeout(a(function(){this._cancel(),this._isTapValid()&&(S(document,"touchend",O),S(document,"touchend touchcancel",this._cancelClickPrevent),this._simulateEvent("contextmenu",e))},this),600),S(document,"touchend touchcancel contextmenu",this._cancel,this),S(document,"touchmove",this._onMove,this))},_cancelClickPrevent:function t(){k(document,"touchend",O),k(document,"touchend touchcancel",t)},_cancel:function(){clearTimeout(this._holdTimeout),k(document,"touchend touchcancel contextmenu",this._cancel,this),k(document,"touchmove",this._onMove,this)},_onMove:function(t){t=t.touches[0];this._newPos=new p(t.clientX,t.clientY)},_isTapValid:function(){return this._newPos.distanceTo(this._startPos)<=this._map.options.tapTolerance},_simulateEvent:function(t,e){t=new MouseEvent(t,{bubbles:!0,cancelable:!0,view:window,screenX:e.screenX,screenY:e.screenY,clientX:e.clientX,clientY:e.clientY});t._simulated=!0,e.target.dispatchEvent(t)}})),Ot=(A.addInitHook("addHandler","tapHold",kt),A.mergeOptions({touchZoom:b.touch,bounceAtZoomLimits:!0}),n.extend({addHooks:function(){M(this._map._container,"leaflet-touch-zoom"),S(this._map._container,"touchstart",this._onTouchStart,this)},removeHooks:function(){z(this._map._container,"leaflet-touch-zoom"),k(this._map._container,"touchstart",this._onTouchStart,this)},_onTouchStart:function(t){var e,i,n=this._map;!t.touches||2!==t.touches.length||n._animatingZoom||this._zooming||(e=n.mouseEventToContainerPoint(t.touches[0]),i=n.mouseEventToContainerPoint(t.touches[1]),this._centerPoint=n.getSize()._divideBy(2),this._startLatLng=n.containerPointToLatLng(this._centerPoint),"center"!==n.options.touchZoom&&(this._pinchStartLatLng=n.containerPointToLatLng(e.add(i)._divideBy(2))),this._startDist=e.distanceTo(i),this._startZoom=n.getZoom(),this._moved=!1,this._zooming=!0,n._stop(),S(document,"touchmove",this._onTouchMove,this),S(document,"touchend touchcancel",this._onTouchEnd,this),O(t))},_onTouchMove:function(t){if(t.touches&&2===t.touches.length&&this._zooming){var e=this._map,i=e.mouseEventToContainerPoint(t.touches[0]),n=e.mouseEventToContainerPoint(t.touches[1]),o=i.distanceTo(n)/this._startDist;if(this._zoom=e.getScaleZoom(o,this._startZoom),!e.options.bounceAtZoomLimits&&(this._zoom<e.getMinZoom()&&o<1||this._zoom>e.getMaxZoom()&&1<o)&&(this._zoom=e._limitZoom(this._zoom)),"center"===e.options.touchZoom){if(this._center=this._startLatLng,1==o)return}else{i=i._add(n)._divideBy(2)._subtract(this._centerPoint);if(1==o&&0===i.x&&0===i.y)return;this._center=e.unproject(e.project(this._pinchStartLatLng,this._zoom).subtract(i),this._zoom)}this._moved||(e._moveStart(!0,!1),this._moved=!0),r(this._animRequest);n=a(e._move,e,this._center,this._zoom,{pinch:!0,round:!1},void 0);this._animRequest=x(n,this,!0),O(t)}},_onTouchEnd:function(){this._moved&&this._zooming?(this._zooming=!1,r(this._animRequest),k(document,"touchmove",this._onTouchMove,this),k(document,"touchend touchcancel",this._onTouchEnd,this),this._map.options.zoomAnimation?this._map._animateZoom(this._center,this._map._limitZoom(this._zoom),!0,this._map.options.zoomSnap):this._map._resetView(this._center,this._map._limitZoom(this._zoom))):this._zooming=!1}})),Xi=(A.addInitHook("addHandler","touchZoom",Ot),A.BoxZoom=_t,A.DoubleClickZoom=Ct,A.Drag=Zt,A.Keyboard=St,A.ScrollWheelZoom=Et,A.TapHold=kt,A.TouchZoom=Ot,t.Bounds=f,t.Browser=b,t.CRS=ot,t.Canvas=Fi,t.Circle=vi,t.CircleMarker=gi,t.Class=et,t.Control=B,t.DivIcon=Ri,t.DivOverlay=Ai,t.DomEvent=mt,t.DomUtil=pt,t.Draggable=Xe,t.Evented=it,t.FeatureGroup=ci,t.GeoJSON=wi,t.GridLayer=Ni,t.Handler=n,t.Icon=di,t.ImageOverlay=Ei,t.LatLng=v,t.LatLngBounds=s,t.Layer=o,t.LayerGroup=ui,t.LineUtil=vt,t.Map=A,t.Marker=mi,t.Mixin=ft,t.Path=fi,t.Point=p,t.PolyUtil=gt,t.Polygon=xi,t.Polyline=yi,t.Popup=Bi,t.PosAnimation=Fe,t.Projection=wt,t.Rectangle=Yi,t.Renderer=Wi,t.SVG=Gi,t.SVGOverlay=Oi,t.TileLayer=Di,t.Tooltip=Ii,t.Transformation=at,t.Util=tt,t.VideoOverlay=ki,t.bind=a,t.bounds=_,t.canvas=Ui,t.circle=function(t,e,i){return new vi(t,e,i)},t.circleMarker=function(t,e){return new gi(t,e)},t.control=Ue,t.divIcon=function(t){return new Ri(t)},t.extend=l,t.featureGroup=function(t,e){return new ci(t,e)},t.geoJSON=Si,t.geoJson=Mt,t.gridLayer=function(t){return new Ni(t)},t.icon=function(t){return new di(t)},t.imageOverlay=function(t,e,i){return new Ei(t,e,i)},t.latLng=w,t.latLngBounds=g,t.layerGroup=function(t,e){return new ui(t,e)},t.map=function(t,e){return new A(t,e)},t.marker=function(t,e){return new mi(t,e)},t.point=m,t.polygon=function(t,e){return new xi(t,e)},t.polyline=function(t,e){return new yi(t,e)},t.popup=function(t,e){return new Bi(t,e)},t.rectangle=function(t,e){return new Yi(t,e)},t.setOptions=c,t.stamp=h,t.svg=Ki,t.svgOverlay=function(t,e,i){return new Oi(t,e,i)},t.tileLayer=ji,t.tooltip=function(t,e){return new Ii(t,e)},t.transformation=ht,t.version="1.9.4",t.videoOverlay=function(t,e,i){return new ki(t,e,i)},window.L);t.noConflict=function(){return window.L=Xi,this},window.L=t});
//# sourceMappingURL=leaflet.js.map
MW_FILE_END_16
chmod 644 "$R/www/luci-static/resources/matchwatch/leaflet.js.new"
mv -f "$R/www/luci-static/resources/matchwatch/leaflet.js.new" "$R/www/luci-static/resources/matchwatch/leaflet.js"
cat > "$R/www/luci-static/resources/matchwatch/leaflet.css.new" <<'MW_FILE_END_17'
/* required styles */

.leaflet-pane,
.leaflet-tile,
.leaflet-marker-icon,
.leaflet-marker-shadow,
.leaflet-tile-container,
.leaflet-pane > svg,
.leaflet-pane > canvas,
.leaflet-zoom-box,
.leaflet-image-layer,
.leaflet-layer {
	position: absolute;
	left: 0;
	top: 0;
	}
.leaflet-container {
	overflow: hidden;
	}
.leaflet-tile,
.leaflet-marker-icon,
.leaflet-marker-shadow {
	-webkit-user-select: none;
	   -moz-user-select: none;
	        user-select: none;
	  -webkit-user-drag: none;
	}
/* Prevents IE11 from highlighting tiles in blue */
.leaflet-tile::selection {
	background: transparent;
}
/* Safari renders non-retina tile on retina better with this, but Chrome is worse */
.leaflet-safari .leaflet-tile {
	image-rendering: -webkit-optimize-contrast;
	}
/* hack that prevents hw layers "stretching" when loading new tiles */
.leaflet-safari .leaflet-tile-container {
	width: 1600px;
	height: 1600px;
	-webkit-transform-origin: 0 0;
	}
.leaflet-marker-icon,
.leaflet-marker-shadow {
	display: block;
	}
/* .leaflet-container svg: reset svg max-width decleration shipped in Joomla! (joomla.org) 3.x */
/* .leaflet-container img: map is broken in FF if you have max-width: 100% on tiles */
.leaflet-container .leaflet-overlay-pane svg {
	max-width: none !important;
	max-height: none !important;
	}
.leaflet-container .leaflet-marker-pane img,
.leaflet-container .leaflet-shadow-pane img,
.leaflet-container .leaflet-tile-pane img,
.leaflet-container img.leaflet-image-layer,
.leaflet-container .leaflet-tile {
	max-width: none !important;
	max-height: none !important;
	width: auto;
	padding: 0;
	}

.leaflet-container img.leaflet-tile {
	/* See: https://bugs.chromium.org/p/chromium/issues/detail?id=600120 */
	mix-blend-mode: plus-lighter;
}

.leaflet-container.leaflet-touch-zoom {
	-ms-touch-action: pan-x pan-y;
	touch-action: pan-x pan-y;
	}
.leaflet-container.leaflet-touch-drag {
	-ms-touch-action: pinch-zoom;
	/* Fallback for FF which doesn't support pinch-zoom */
	touch-action: none;
	touch-action: pinch-zoom;
}
.leaflet-container.leaflet-touch-drag.leaflet-touch-zoom {
	-ms-touch-action: none;
	touch-action: none;
}
.leaflet-container {
	-webkit-tap-highlight-color: transparent;
}
.leaflet-container a {
	-webkit-tap-highlight-color: rgba(51, 181, 229, 0.4);
}
.leaflet-tile {
	filter: inherit;
	visibility: hidden;
	}
.leaflet-tile-loaded {
	visibility: inherit;
	}
.leaflet-zoom-box {
	width: 0;
	height: 0;
	-moz-box-sizing: border-box;
	     box-sizing: border-box;
	z-index: 800;
	}
/* workaround for https://bugzilla.mozilla.org/show_bug.cgi?id=888319 */
.leaflet-overlay-pane svg {
	-moz-user-select: none;
	}

.leaflet-pane         { z-index: 400; }

.leaflet-tile-pane    { z-index: 200; }
.leaflet-overlay-pane { z-index: 400; }
.leaflet-shadow-pane  { z-index: 500; }
.leaflet-marker-pane  { z-index: 600; }
.leaflet-tooltip-pane   { z-index: 650; }
.leaflet-popup-pane   { z-index: 700; }

.leaflet-map-pane canvas { z-index: 100; }
.leaflet-map-pane svg    { z-index: 200; }

.leaflet-vml-shape {
	width: 1px;
	height: 1px;
	}
.lvml {
	behavior: url(#default#VML);
	display: inline-block;
	position: absolute;
	}


/* control positioning */

.leaflet-control {
	position: relative;
	z-index: 800;
	pointer-events: visiblePainted; /* IE 9-10 doesn't have auto */
	pointer-events: auto;
	}
.leaflet-top,
.leaflet-bottom {
	position: absolute;
	z-index: 1000;
	pointer-events: none;
	}
.leaflet-top {
	top: 0;
	}
.leaflet-right {
	right: 0;
	}
.leaflet-bottom {
	bottom: 0;
	}
.leaflet-left {
	left: 0;
	}
.leaflet-control {
	float: left;
	clear: both;
	}
.leaflet-right .leaflet-control {
	float: right;
	}
.leaflet-top .leaflet-control {
	margin-top: 10px;
	}
.leaflet-bottom .leaflet-control {
	margin-bottom: 10px;
	}
.leaflet-left .leaflet-control {
	margin-left: 10px;
	}
.leaflet-right .leaflet-control {
	margin-right: 10px;
	}


/* zoom and fade animations */

.leaflet-fade-anim .leaflet-popup {
	opacity: 0;
	-webkit-transition: opacity 0.2s linear;
	   -moz-transition: opacity 0.2s linear;
	        transition: opacity 0.2s linear;
	}
.leaflet-fade-anim .leaflet-map-pane .leaflet-popup {
	opacity: 1;
	}
.leaflet-zoom-animated {
	-webkit-transform-origin: 0 0;
	    -ms-transform-origin: 0 0;
	        transform-origin: 0 0;
	}
svg.leaflet-zoom-animated {
	will-change: transform;
}

.leaflet-zoom-anim .leaflet-zoom-animated {
	-webkit-transition: -webkit-transform 0.25s cubic-bezier(0,0,0.25,1);
	   -moz-transition:    -moz-transform 0.25s cubic-bezier(0,0,0.25,1);
	        transition:         transform 0.25s cubic-bezier(0,0,0.25,1);
	}
.leaflet-zoom-anim .leaflet-tile,
.leaflet-pan-anim .leaflet-tile {
	-webkit-transition: none;
	   -moz-transition: none;
	        transition: none;
	}

.leaflet-zoom-anim .leaflet-zoom-hide {
	visibility: hidden;
	}


/* cursors */

.leaflet-interactive {
	cursor: pointer;
	}
.leaflet-grab {
	cursor: -webkit-grab;
	cursor:    -moz-grab;
	cursor:         grab;
	}
.leaflet-crosshair,
.leaflet-crosshair .leaflet-interactive {
	cursor: crosshair;
	}
.leaflet-popup-pane,
.leaflet-control {
	cursor: auto;
	}
.leaflet-dragging .leaflet-grab,
.leaflet-dragging .leaflet-grab .leaflet-interactive,
.leaflet-dragging .leaflet-marker-draggable {
	cursor: move;
	cursor: -webkit-grabbing;
	cursor:    -moz-grabbing;
	cursor:         grabbing;
	}

/* marker & overlays interactivity */
.leaflet-marker-icon,
.leaflet-marker-shadow,
.leaflet-image-layer,
.leaflet-pane > svg path,
.leaflet-tile-container {
	pointer-events: none;
	}

.leaflet-marker-icon.leaflet-interactive,
.leaflet-image-layer.leaflet-interactive,
.leaflet-pane > svg path.leaflet-interactive,
svg.leaflet-image-layer.leaflet-interactive path {
	pointer-events: visiblePainted; /* IE 9-10 doesn't have auto */
	pointer-events: auto;
	}

/* visual tweaks */

.leaflet-container {
	background: #ddd;
	outline-offset: 1px;
	}
.leaflet-container a {
	color: #0078A8;
	}
.leaflet-zoom-box {
	border: 2px dotted #38f;
	background: rgba(255,255,255,0.5);
	}


/* general typography */
.leaflet-container {
	font-family: "Helvetica Neue", Arial, Helvetica, sans-serif;
	font-size: 12px;
	font-size: 0.75rem;
	line-height: 1.5;
	}


/* general toolbar styles */

.leaflet-bar {
	box-shadow: 0 1px 5px rgba(0,0,0,0.65);
	border-radius: 4px;
	}
.leaflet-bar a {
	background-color: #fff;
	border-bottom: 1px solid #ccc;
	width: 26px;
	height: 26px;
	line-height: 26px;
	display: block;
	text-align: center;
	text-decoration: none;
	color: black;
	}
.leaflet-bar a,
.leaflet-control-layers-toggle {
	background-position: 50% 50%;
	background-repeat: no-repeat;
	display: block;
	}
.leaflet-bar a:hover,
.leaflet-bar a:focus {
	background-color: #f4f4f4;
	}
.leaflet-bar a:first-child {
	border-top-left-radius: 4px;
	border-top-right-radius: 4px;
	}
.leaflet-bar a:last-child {
	border-bottom-left-radius: 4px;
	border-bottom-right-radius: 4px;
	border-bottom: none;
	}
.leaflet-bar a.leaflet-disabled {
	cursor: default;
	background-color: #f4f4f4;
	color: #bbb;
	}

.leaflet-touch .leaflet-bar a {
	width: 30px;
	height: 30px;
	line-height: 30px;
	}
.leaflet-touch .leaflet-bar a:first-child {
	border-top-left-radius: 2px;
	border-top-right-radius: 2px;
	}
.leaflet-touch .leaflet-bar a:last-child {
	border-bottom-left-radius: 2px;
	border-bottom-right-radius: 2px;
	}

/* zoom control */

.leaflet-control-zoom-in,
.leaflet-control-zoom-out {
	font: bold 18px 'Lucida Console', Monaco, monospace;
	text-indent: 1px;
	}

.leaflet-touch .leaflet-control-zoom-in, .leaflet-touch .leaflet-control-zoom-out  {
	font-size: 22px;
	}


/* layers control */

.leaflet-control-layers {
	box-shadow: 0 1px 5px rgba(0,0,0,0.4);
	background: #fff;
	border-radius: 5px;
	}
.leaflet-control-layers-toggle {
	background-image: url(images/layers.png);
	width: 36px;
	height: 36px;
	}
.leaflet-retina .leaflet-control-layers-toggle {
	background-image: url(images/layers-2x.png);
	background-size: 26px 26px;
	}
.leaflet-touch .leaflet-control-layers-toggle {
	width: 44px;
	height: 44px;
	}
.leaflet-control-layers .leaflet-control-layers-list,
.leaflet-control-layers-expanded .leaflet-control-layers-toggle {
	display: none;
	}
.leaflet-control-layers-expanded .leaflet-control-layers-list {
	display: block;
	position: relative;
	}
.leaflet-control-layers-expanded {
	padding: 6px 10px 6px 6px;
	color: #333;
	background: #fff;
	}
.leaflet-control-layers-scrollbar {
	overflow-y: scroll;
	overflow-x: hidden;
	padding-right: 5px;
	}
.leaflet-control-layers-selector {
	margin-top: 2px;
	position: relative;
	top: 1px;
	}
.leaflet-control-layers label {
	display: block;
	font-size: 13px;
	font-size: 1.08333em;
	}
.leaflet-control-layers-separator {
	height: 0;
	border-top: 1px solid #ddd;
	margin: 5px -10px 5px -6px;
	}

/* Default icon URLs */
.leaflet-default-icon-path { /* used only in path-guessing heuristic, see L.Icon.Default */
	background-image: url(images/marker-icon.png);
	}


/* attribution and scale controls */

.leaflet-container .leaflet-control-attribution {
	background: #fff;
	background: rgba(255, 255, 255, 0.8);
	margin: 0;
	}
.leaflet-control-attribution,
.leaflet-control-scale-line {
	padding: 0 5px;
	color: #333;
	line-height: 1.4;
	}
.leaflet-control-attribution a {
	text-decoration: none;
	}
.leaflet-control-attribution a:hover,
.leaflet-control-attribution a:focus {
	text-decoration: underline;
	}
.leaflet-attribution-flag {
	display: inline !important;
	vertical-align: baseline !important;
	width: 1em;
	height: 0.6669em;
	}
.leaflet-left .leaflet-control-scale {
	margin-left: 5px;
	}
.leaflet-bottom .leaflet-control-scale {
	margin-bottom: 5px;
	}
.leaflet-control-scale-line {
	border: 2px solid #777;
	border-top: none;
	line-height: 1.1;
	padding: 2px 5px 1px;
	white-space: nowrap;
	-moz-box-sizing: border-box;
	     box-sizing: border-box;
	background: rgba(255, 255, 255, 0.8);
	text-shadow: 1px 1px #fff;
	}
.leaflet-control-scale-line:not(:first-child) {
	border-top: 2px solid #777;
	border-bottom: none;
	margin-top: -2px;
	}
.leaflet-control-scale-line:not(:first-child):not(:last-child) {
	border-bottom: 2px solid #777;
	}

.leaflet-touch .leaflet-control-attribution,
.leaflet-touch .leaflet-control-layers,
.leaflet-touch .leaflet-bar {
	box-shadow: none;
	}
.leaflet-touch .leaflet-control-layers,
.leaflet-touch .leaflet-bar {
	border: 2px solid rgba(0,0,0,0.2);
	background-clip: padding-box;
	}


/* popup */

.leaflet-popup {
	position: absolute;
	text-align: center;
	margin-bottom: 20px;
	}
.leaflet-popup-content-wrapper {
	padding: 1px;
	text-align: left;
	border-radius: 12px;
	}
.leaflet-popup-content {
	margin: 13px 24px 13px 20px;
	line-height: 1.3;
	font-size: 13px;
	font-size: 1.08333em;
	min-height: 1px;
	}
.leaflet-popup-content p {
	margin: 17px 0;
	margin: 1.3em 0;
	}
.leaflet-popup-tip-container {
	width: 40px;
	height: 20px;
	position: absolute;
	left: 50%;
	margin-top: -1px;
	margin-left: -20px;
	overflow: hidden;
	pointer-events: none;
	}
.leaflet-popup-tip {
	width: 17px;
	height: 17px;
	padding: 1px;

	margin: -10px auto 0;
	pointer-events: auto;

	-webkit-transform: rotate(45deg);
	   -moz-transform: rotate(45deg);
	    -ms-transform: rotate(45deg);
	        transform: rotate(45deg);
	}
.leaflet-popup-content-wrapper,
.leaflet-popup-tip {
	background: white;
	color: #333;
	box-shadow: 0 3px 14px rgba(0,0,0,0.4);
	}
.leaflet-container a.leaflet-popup-close-button {
	position: absolute;
	top: 0;
	right: 0;
	border: none;
	text-align: center;
	width: 24px;
	height: 24px;
	font: 16px/24px Tahoma, Verdana, sans-serif;
	color: #757575;
	text-decoration: none;
	background: transparent;
	}
.leaflet-container a.leaflet-popup-close-button:hover,
.leaflet-container a.leaflet-popup-close-button:focus {
	color: #585858;
	}
.leaflet-popup-scrolled {
	overflow: auto;
	}

.leaflet-oldie .leaflet-popup-content-wrapper {
	-ms-zoom: 1;
	}
.leaflet-oldie .leaflet-popup-tip {
	width: 24px;
	margin: 0 auto;

	-ms-filter: "progid:DXImageTransform.Microsoft.Matrix(M11=0.70710678, M12=0.70710678, M21=-0.70710678, M22=0.70710678)";
	filter: progid:DXImageTransform.Microsoft.Matrix(M11=0.70710678, M12=0.70710678, M21=-0.70710678, M22=0.70710678);
	}

.leaflet-oldie .leaflet-control-zoom,
.leaflet-oldie .leaflet-control-layers,
.leaflet-oldie .leaflet-popup-content-wrapper,
.leaflet-oldie .leaflet-popup-tip {
	border: 1px solid #999;
	}


/* div icon */

.leaflet-div-icon {
	background: #fff;
	border: 1px solid #666;
	}


/* Tooltip */
/* Base styles for the element that has a tooltip */
.leaflet-tooltip {
	position: absolute;
	padding: 6px;
	background-color: #fff;
	border: 1px solid #fff;
	border-radius: 3px;
	color: #222;
	white-space: nowrap;
	-webkit-user-select: none;
	-moz-user-select: none;
	-ms-user-select: none;
	user-select: none;
	pointer-events: none;
	box-shadow: 0 1px 3px rgba(0,0,0,0.4);
	}
.leaflet-tooltip.leaflet-interactive {
	cursor: pointer;
	pointer-events: auto;
	}
.leaflet-tooltip-top:before,
.leaflet-tooltip-bottom:before,
.leaflet-tooltip-left:before,
.leaflet-tooltip-right:before {
	position: absolute;
	pointer-events: none;
	border: 6px solid transparent;
	background: transparent;
	content: "";
	}

/* Directions */

.leaflet-tooltip-bottom {
	margin-top: 6px;
}
.leaflet-tooltip-top {
	margin-top: -6px;
}
.leaflet-tooltip-bottom:before,
.leaflet-tooltip-top:before {
	left: 50%;
	margin-left: -6px;
	}
.leaflet-tooltip-top:before {
	bottom: 0;
	margin-bottom: -12px;
	border-top-color: #fff;
	}
.leaflet-tooltip-bottom:before {
	top: 0;
	margin-top: -12px;
	margin-left: -6px;
	border-bottom-color: #fff;
	}
.leaflet-tooltip-left {
	margin-left: -6px;
}
.leaflet-tooltip-right {
	margin-left: 6px;
}
.leaflet-tooltip-left:before,
.leaflet-tooltip-right:before {
	top: 50%;
	margin-top: -6px;
	}
.leaflet-tooltip-left:before {
	right: 0;
	margin-right: -12px;
	border-left-color: #fff;
	}
.leaflet-tooltip-right:before {
	left: 0;
	margin-left: -12px;
	border-right-color: #fff;
	}

/* Printing */

@media print {
	/* Prevent printers from removing background-images of controls. */
	.leaflet-control {
		-webkit-print-color-adjust: exact;
		print-color-adjust: exact;
		}
	}
MW_FILE_END_17
chmod 644 "$R/www/luci-static/resources/matchwatch/leaflet.css.new"
mv -f "$R/www/luci-static/resources/matchwatch/leaflet.css.new" "$R/www/luci-static/resources/matchwatch/leaflet.css"
cat > "$R/www/luci-static/resources/view/matchwatch/dashboard.js.new" <<'MW_FILE_END_18'
'use strict';
'require view';
'require rpc';
'require fs';

/* Services > MatchWatch > Dashboard. Hosts the shared dashboard (resources/matchwatch/dashboard.js)
   and talks to the router through LuCI: data files by file.read, buttons by the luci.matchwatch
   rpcd object, both checked against the logged-in session's permissions. */

var DATA = '/tmp/matchwatch/www/';

var callRead = rpc.declare({ object: 'luci.matchwatch', method: 'read', params: [ 'action', 'arg' ], expect: {} });
var callWrite = rpc.declare({ object: 'luci.matchwatch', method: 'write', params: [ 'action', 'arg', 'days', 'region', 'name', 'data' ], expect: {} });

/* Buttons that only look, or only record a time. Everything else needs write permission. */
var READS = { hello: 1, mark: 1, devices: 1, doctor: 1, qos: 1, log: 1, linetest: 1, trace: 1, shareexport: 1, updatecheck: 1 };

/* The dashboard's two files are asked for by MatchWatch's version, so a browser that still holds
   an older version's copies fetches the new ones after an update instead of showing the old page. */
var stamp = '';

function loadDashboard() {
	if (window.MatchwatchDashboard)
		return Promise.resolve();

	return new Promise(function (resolve, reject) {
		var s = document.createElement('script');
		s.src = L.resource('matchwatch/dashboard.js') + stamp;
		s.onload = resolve;
		s.onerror = function () { reject(new Error('Could not load the MatchWatch dashboard script.')); };
		document.head.appendChild(s);
	});
}

/* Is the LuCI theme in use a dark one? Judged from the page's own background colour. */
function pageIsDark() {
	var els = [ document.getElementById('maincontent'), document.body, document.documentElement ], i, m;

	for (i = 0; i < els.length; i++) {
		if (!els[i])
			continue;

		m = /rgba?\((\d+),\s*(\d+),\s*(\d+)(?:,\s*([\d.]+))?/.exec(getComputedStyle(els[i]).backgroundColor);

		if (m && (m[4] == null || +m[4] > 0.5))
			return (0.2126 * m[1] + 0.7152 * m[2] + 0.0722 * m[3]) < 128;
	}

	return false;
}

return view.extend({
	handleSave: null,
	handleSaveApply: null,
	handleReset: null,

	load: function () {
		return fs.read(DATA + 'info.json').then(function (text) {
			var v = String(JSON.parse(text).version || '');
			stamp = /^[0-9.]+$/.test(v) ? '?v=' + v : '';
		}).catch(function () {}).then(loadDashboard);
	},

	render: function () {
		var host = E('div', { 'class': 'matchwatch' });

		window.MatchwatchDashboard(host, {
			css: L.resource('matchwatch/dashboard.css') + stamp,
			settings: L.url('admin/services/matchwatch/settings'),
			dark: pageIsDark,
			get: function (file) {
				return fs.read(DATA + file).then(function (text) { return JSON.parse(text); });
			},
			act: function (p) {
				if (READS[p.action])
					return callRead(p.action, p.arg || '');

				return callWrite(p.action, p.arg || '', p.days || '', p.region || '', p.name || '', p.data || '');
			}
		});

		return host;
	}
});
MW_FILE_END_18
chmod 644 "$R/www/luci-static/resources/view/matchwatch/dashboard.js.new"
mv -f "$R/www/luci-static/resources/view/matchwatch/dashboard.js.new" "$R/www/luci-static/resources/view/matchwatch/dashboard.js"
cat > "$R/www/luci-static/resources/view/matchwatch/settings.js.new" <<'MW_FILE_END_19'
'use strict';
'require view';
'require form';
'require rpc';

/* Services > MatchWatch > Settings. Edits /etc/config/matchwatch; Save & Apply restarts the service. */

var callHostHints = rpc.declare({ object: 'luci-rpc', method: 'getHostHints', expect: { '': {} } });

return view.extend({
	load: function () {
		return callHostHints().catch(function () { return {}; });
	},

	render: function (hosts) {
		var m, s, o, seen = {}, list = [];

		m = new form.Map('matchwatch', _('MatchWatch'),
			_('Saving restarts MatchWatch, which ends the recording of a match in progress. Change settings between matches.'));

		s = m.section(form.NamedSection, 'main', 'matchwatch');
		s.addremove = false;
		s.tab('general', _('General'));
		s.tab('alerts', _('Alerts'));
		s.tab('blocking', _('Staying and blocking'));
		s.tab('advanced', _('Advanced'));

		/* ---- General */
		o = s.taboption('general', form.Value, 'device_ip', _('Device to watch'),
			_('Your gaming PC or console. Leave empty to watch every device. Give the device a fixed address under Network, DHCP and DNS, Static Leases, or MatchWatch loses track of it when the address changes.'));
		o.datatype = 'ip4addr("nomask")';
		o.placeholder = _('Every device');
		o.rmempty = true;

		Object.keys(hosts || {}).forEach(function (mac) {
			var h = hosts[mac] || {}, ips = h.ipaddrs || (h.ipv4 ? [ h.ipv4 ] : []);

			ips.forEach(function (ip) {
				if (!seen[ip]) {
					seen[ip] = true;
					list.push([ ip, h.name ? '%s (%s)'.format(h.name, ip) : ip ]);
				}
			});
		});

		list.sort(function (a, b) { return a[1].toLowerCase() < b[1].toLowerCase() ? -1 : 1; });
		list.forEach(function (e) { o.value(e[0], e[1]); });

		o = s.taboption('general', form.Flag, 'pc_score', _('Count your PC towards scores'),
			_('Off: pauses in what your PC sends are still shown in reports, but never lower the overall score or change the verdict.'));
		o.default = '1';
		o.rmempty = false;

		o = s.taboption('general', form.Flag, 'geo', _('Look up where servers are'),
			_('Asks ip-api.com for the city, country and hosting company of each game server. Only the server address is sent. Staying on places and the lobby alert need this on.'));
		o.default = '1';
		o.rmempty = false;

		o = s.taboption('general', form.Flag, 'web', _('Dashboard without login'),
			_('Also serves a view-only copy of the dashboard at /matchwatch/ to anyone on your network, with the "I felt that" button. Useful on a phone or second screen. Nothing can be blocked or changed from it.'));
		o.default = '0';
		o.rmempty = false;

		/* ---- Alerts */
		o = s.taboption('alerts', form.Value, 'ntfy_url', _('Phone alerts (ntfy)'),
			_('Install the ntfy app, subscribe to a hard-to-guess topic, and put its full address here. Leave empty for no phone alerts.'));
		o.placeholder = 'https://ntfy.sh/your-topic';
		o.rmempty = true;
		o.validate = function (section_id, value) {
			return (value === '' || /^https?:\/\/[^\s'"]+$/.test(value)) ? true : _('Enter a web address starting with http:// or https://');
		};

		o = s.taboption('alerts', form.Flag, 'notify_start', _('Alert when a match starts'),
			_('Tells your phone the moment the game itself begins: "Match started: United Kingdom, 5 ms." Handy when you have stepped away during a long queue.'));
		o.default = '0';
		o.rmempty = false;

		o = s.taboption('alerts', form.Flag, 'notify_newgame', _('Alert when a new game is seen'),
			_('Tells your phone the first time a match is played on a server port nobody has named. Until you name the game, staying on places, the lobby alert and automatic blocking leave it alone.'));
		o.default = '1';
		o.rmempty = false;

		o = s.taboption('alerts', form.Flag, 'notify_every_match', _('Alert after every match'),
			_('Off: only after bad matches and when you land on a server with a bad history.'));
		o.default = '0';
		o.rmempty = false;

		o = s.taboption('alerts', form.ListValue, 'lobby_alert', _('Lobby alert'),
			_('When the game starts connecting you to a server, MatchWatch works out where it is and how it has rated. Phone alerts are one short line, and never more than one a minute. A server turned away because you are staying elsewhere only alerts your phone on "Always".'));
		o.value('0', _('Show on the dashboard only'));
		o.value('1', _('Also alert my phone when it is far or badly rated'));
		o.value('2', _('Always alert my phone'));
		o.default = '1';

		o = s.taboption('alerts', form.Value, 'lobby_margin_ms', _('"Far" means this much slower'),
			_('In milliseconds, compared with your best datacentre.'));
		o.datatype = 'range(0,500)';
		o.placeholder = '4';

		o = s.taboption('alerts', form.Value, 'warn_score', _('Warn below this rating'),
			_('Out of 100. Also the level at which a place is dropped from the places you stay on.'));
		o.datatype = 'range(0,100)';
		o.placeholder = '55';

		/* ---- Staying and blocking */
		o = s.taboption('blocking', form.Value, 'block_days', _('Blocks last'),
			_('In days. Server addresses get reused, so blocks expire.'));
		o.datatype = 'range(1,365)';
		o.placeholder = '14';

		o = s.taboption('blocking', form.Flag, 'autoblock', _('Block bad servers automatically'),
			_('Blocks a server once enough counted matches on it average under the rating below.'));
		o.default = '0';
		o.rmempty = false;

		o = s.taboption('blocking', form.Value, 'autoblock_score', _('Automatic block below'));
		o.datatype = 'range(0,100)';
		o.placeholder = '45';
		o.depends('autoblock', '1');

		o = s.taboption('blocking', form.Value, 'autoblock_matches', _('After this many matches'));
		o.datatype = 'range(1,50)';
		o.placeholder = '2';
		o.depends('autoblock', '1');

		o = s.taboption('blocking', form.Flag, 'stay_strict', _('Turn servers away as the game tries them'),
			_('When you are staying on places. Off: servers elsewhere are only blocked after you have played a match on them.'));
		o.default = '1';
		o.rmempty = false;

		o = s.taboption('blocking', form.Flag, 'stay_ranges', _('Turn whole regions away ahead of time'),
			_('When you are staying on places. Hosting companies publish which of their address ranges is in which city. MatchWatch downloads those lists and refuses every range outside your places before the game tries it, which makes finding a match much quicker. Only game traffic from the device you watch is refused; web sites and other devices are untouched. Needs a device to watch, on the General tab.'));
		o.default = '1';
		o.rmempty = false;

		o = s.taboption('blocking', form.Value, 'stay_km', _('A city reaches this far'),
			_('In kilometres. How far from a chosen city a server may be and still count as being there.'));
		o.datatype = 'range(10,2000)';
		o.placeholder = '150';

		/* ---- Advanced */
		o = s.taboption('advanced', form.Value, 'lan_if', _('LAN interface'), _('Leave empty to detect it.'));
		o.datatype = 'network_device';
		o.placeholder = _('Detected');
		o.rmempty = true;

		o = s.taboption('advanced', form.Value, 'wan_if', _('WAN interface'), _('Leave empty to detect it.'));
		o.datatype = 'network_device';
		o.placeholder = _('Detected');
		o.rmempty = true;

		o = s.taboption('advanced', form.Value, 'ignore_ports', _('UDP ports that are never a game'),
			_('Separated by spaces.'));
		o.placeholder = '53 67 68 123 443 1900 5353';
		o.validate = function (section_id, value) {
			return /^[0-9 ]*$/.test(value) ? true : _('Port numbers separated by spaces');
		};

		o = s.taboption('advanced', form.Value, 'only_filter', _('Only look at this traffic'),
			_('A tcpdump expression, for example: port 3074 or portrange 30000-45000. Leave empty to consider all UDP.'));
		o.rmempty = true;
		o.validate = function (section_id, value) {
			return /^[A-Za-z0-9 .\/()-]*$/.test(value) ? true : _('Letters, numbers, spaces, dots, slashes, brackets and hyphens only');
		};

		o = s.taboption('advanced', form.Value, 'min_down_pps', _('A match needs this many packets a second down'));
		o.datatype = 'range(1,1000)';
		o.placeholder = '15';

		o = s.taboption('advanced', form.Value, 'min_up_pps', _('And this many up'));
		o.datatype = 'range(1,1000)';
		o.placeholder = '8';

		return m.render();
	}
});
MW_FILE_END_19
chmod 644 "$R/www/luci-static/resources/view/matchwatch/settings.js.new"
mv -f "$R/www/luci-static/resources/view/matchwatch/settings.js.new" "$R/www/luci-static/resources/view/matchwatch/settings.js"

rm -f "$R/usr/lib/matchwatch/index.html" "$R/usr/lib/matchwatch/config.default" "$R/www/cgi-bin/matchwatch-api"
if [ ! -f "$R/etc/config/matchwatch" ]; then
	cp "$R/usr/lib/matchwatch/config.uci" "$R/etc/config/matchwatch"
	echo "Created /etc/config/matchwatch"
fi
if [ -z "$R" ]; then
	/usr/bin/matchwatch _migrate
	case "$1" in
		[0-9]*.[0-9]*.[0-9]*.[0-9]*)
			uci set "matchwatch.main.device_ip=$1" && uci commit matchwatch
			echo "Watching device $1" ;;
	esac
	grep -q '^/etc/matchwatch/' /etc/sysupgrade.conf 2>/dev/null || echo "/etc/matchwatch/" >> /etc/sysupgrade.conf
	luci_refresh
	/etc/init.d/matchwatch enable
	/etc/init.d/matchwatch restart
	sleep 2
	/usr/bin/matchwatch doctor
	echo
	echo "Installed. In LuCI, open Services, then MatchWatch."
	echo "If you were already logged in to LuCI, log out and in again so the new page appears."
	echo "Play a match, then open the dashboard."
else
	echo "Installed into $R"
fi
