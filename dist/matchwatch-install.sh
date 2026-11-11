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
	rm -f "$R/usr/bin/matchwatch" "$R/usr/lib/matchwatch/analyze.awk" "$R/usr/lib/matchwatch/report.awk" "$R/usr/lib/matchwatch/public.html" "$R/usr/lib/matchwatch/config.uci" "$R/usr/lib/matchwatch/regions.list" "$R/usr/lib/matchwatch/places.list" "$R/usr/lib/matchwatch/games.list" "$R/etc/init.d/matchwatch" "$R/usr/libexec/rpcd/luci.matchwatch" "$R/usr/share/luci/menu.d/luci-app-matchwatch.json" "$R/usr/share/rpcd/acl.d/luci-app-matchwatch.json" "$R/www/luci-static/resources/matchwatch/dashboard.js" "$R/www/luci-static/resources/matchwatch/dashboard.css" "$R/www/luci-static/resources/view/matchwatch/dashboard.js" "$R/www/luci-static/resources/view/matchwatch/settings.js"
	rm -f "$R/usr/lib/matchwatch/index.html" "$R/usr/lib/matchwatch/config.default" "$R/www/cgi-bin/matchwatch-api" "$R/www/matchwatch/index.html" "$R/www/matchwatch/data" "$R/www/cgi-bin/matchwatch-mark"
	rmdir "$R/usr/lib/matchwatch" "$R/www/matchwatch" "$R/www/luci-static/resources/matchwatch" "$R/www/luci-static/resources/view/matchwatch" 2>/dev/null
	[ -z "$R" ] && luci_refresh
	if [ "$1" = purge ]; then
		rm -f "$R/etc/config/matchwatch" "$R/etc/matchwatch/config" "$R/etc/matchwatch/config.imported" "$R/etc/matchwatch/sessions.tsv" "$R/etc/matchwatch/blocklist" "$R/etc/matchwatch/geo.cache" "$R/etc/matchwatch/last.txt" "$R/etc/matchwatch/token" "$R/etc/matchwatch/stay" "$R/etc/matchwatch/regions.tsv" "$R/etc/matchwatch/games.local"
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
cat > "$R/usr/bin/matchwatch" <<'MW_FILE_END_0'
#!/bin/sh
# matchwatch - judges game servers, the route to them, your line and your PC
# from packet timing, on an OpenWrt router. Passive: it never alters game traffic.

VERSION="0.11.0"
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
	local g cc country city rest p loc
	sleep 4
	[ -d "$PD" ] || return 0
	g="$(geo_lookup "$1")"
	IFS="$TAB" read -r cc country city rest <<EOF
$g
EOF
	loc="${city:+$city, }$cc"
	p="$(cat "$PD/far.last" 2>/dev/null)"
	case "$p" in ""|x) p="" ;; *) p="$(echo "$p" | awk '{ printf "%.0f", $1 }')" ;; esac
	cmd_notify "Match started${loc:+: $loc}${p:+, ping about $p ms}."
}

cmd_probe_start() {
	local sid="$1" rip="$2" lip="$3" near last hops reached
	is_ipv4 "$rip" || return 1
	PD="$RUN/probe.$sid"; mkdir -p "$PD"
	echo server > "$PD/far.kind"; echo "$rip" > "$PD/far.ip"
	start_ping far "$rip"
	[ "$NOTIFY_START" = 1 ] && notify_start "$rip" &
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
	awk -v MODE=srv_json -v BLOCK="$DATA/blocklist" -f "$LIB/report.awk" "$DATA/sessions.tsv" > "$RUN/www/servers.json.tmp" && mv -f "$RUN/www/servers.json.tmp" "$RUN/www/servers.json"
	awk -v MODE=dc_json -v BLOCK="$DATA/blocklist" $(stay_vars) -f "$LIB/report.awk" "$DATA/sessions.tsv" > "$RUN/www/datacentres.json.tmp" && mv -f "$RUN/www/datacentres.json.tmp" "$RUN/www/datacentres.json"
	awk -F'\t' -v now="$(date +%s)" 'BEGIN { printf "[" } $1 != "" { gsub(/["\\]/, " ", $4); printf "%s{\"ip\":\"%s\",\"days\":%s,\"reason\":\"%s\"}", (n++ ? "," : ""), $1, ($2 == 0 ? "null" : int(($2 - now + 86399) / 86400)), $4 } END { print "]" }' "$DATA/blocklist" > "$RUN/www/blocklist.json.tmp" && mv -f "$RUN/www/blocklist.json.tmp" "$RUN/www/blocklist.json"
	printf '{"version":"%s","device":"%s","stay":"%s","autoblock":%s,"notify":%s,"pc_score":%s,"geo":%s,"block_days":%s,"stays":[%s],"web":%s,"qosmate":%s}\n' "$VERSION" "$DEVICE_IP" "$(stay_names | sed 's/["\\]/ /g')" "$( [ "$AUTOBLOCK" = 1 ] && echo true || echo false )" "$( [ -n "$NTFY_URL" ] && echo true || echo false )" "$( [ "$PC_SCORE" = 0 ] && echo false || echo true )" "$( [ "$GEO" = 1 ] && echo true || echo false )" "${BLOCK_DAYS:-14}" "$(awk -F'\t' 'NF >= 4 { gsub(/["\\]/, " ", $1); printf "%s\"%s\"", (n++ ? "," : ""), $1 }' "$DATA/stay" 2>/dev/null)" "$( [ "$WEB" = 1 ] && echo true || echo false )" "$( [ -x /etc/init.d/qosmate ] && echo true || echo false )" > "$RUN/www/info.json"
	regions_export
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
		if [ -s "$DATA/stay" ]; then stay_apply >/dev/null; else stay_off; cmd_notify "Stay mode is off: every place in the pool had gone bad."; fi
	fi
	export_json
	if [ "$NOTIFY_EVERY_MATCH" = 1 ] || [ "${2:-100}" -lt "$WARN_SCORE" ]; then cmd_notify "$1"; else logger -t matchwatch "$1" 2>/dev/null; fi
}

# ---- blocking (own nftables table; fw4 is left alone)
nft_ready() {
	have nft || { echo "matchwatch: nft not found (blocking needs OpenWrt 22.03 or newer)" >&2; return 1; }
	if nft list table inet matchwatch >/dev/null 2>&1; then
		nft list set inet matchwatch blocked 2>/dev/null | grep -q interval && return 0
		nft delete table inet matchwatch       # table from an older version: rebuild it
	fi
	nft -f - <<'EOF'
table inet matchwatch {
	set blocked {
		type ipv4_addr
		flags interval, timeout
	}
	chain forward {
		type filter hook forward priority -5; policy accept;
		ip daddr @blocked counter drop
		ip saddr @blocked counter drop
	}
}
EOF
	[ "$NFT_FILLING" = 1 ] || { NFT_FILLING=1; fill_blocklist; NFT_FILLING=0; }
	return 0
}
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
	if [ "$days" = auto ]; then days="$BLOCK_DAYS"; reason="auto: $reason"; fi
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
	is_ipv4 "$ip" || return 1
	mkdir -p "$RUN/www"
	g="$(geo_lookup "$ip")"
	IFS="$TAB" read -r cc country city lat lon isp org asn <<EOF
$g
EOF
	key="$asn|$city|$cc"
	for i in 1 2 3; do
		r="$(ping -c 1 -W 1 "$ip" 2>/dev/null | sed -n 's/.*time=\([0-9.]*\).*/\1/p')"
		[ -n "$r" ] && s="$s $r"
	done
	if [ -z "$s" ] && have traceroute; then
		s="$(traceroute -n -q 1 -w 1 -m 20 "$ip" 2>/dev/null | awk -v ip="$ip" '$2 == ip && $3 ~ /^[0-9.]+$/ { print $3; exit }')"
	fi
	[ -n "$s" ] && ping="$(echo $s | awk '{ m = $1; for (i = 2; i <= NF; i++) if ($i < m) m = $i; printf "%.1f", m }')"
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
	msg="Heading to $loc${org:+ ($org)}"
	[ -n "$ping" ] && msg="$msg, about $ping ms"
	msg="$msg."
	if [ "$srv_n" -ge 1 ] 2>/dev/null && [ -n "$srv_rating" ]; then
		msg="$msg This server rated $srv_rating/100 over $srv_n match(es)."
		[ "$srv_rating" -lt "$WARN_SCORE" ] && { verdict=bad; msg="$msg That is poor: consider backing out."; }
	else
		msg="$msg First time on this server."
	fi
	if [ "$verdict" = good ] && [ -n "$ping" ] && [ -n "$best_ping" ] && [ "$best_key" != "$key" ]; then
		if awk -v a="$ping" -v b="$best_ping" -v m="$LOBBY_MARGIN_MS" 'BEGIN { exit !(a > b + m) }'; then
			verdict=far; msg="$msg ${best_name%% - *} is usually $best_ping ms."
		fi
	fi
	# staying somewhere? turn this server away before the match starts if it is outside every chosen place
	if [ -s "$DATA/stay" ] && [ "$STAY_STRICT" = 1 ] && [ -n "$lat" ] && [ -n "$lon" ] && [ -n "$cc" ]; then
		if outside_stay "$lat" "$lon" "$cc"; then
			MW_QUIET=1 cmd_block "${ip%.*}.0/24" 0 stay && blocked=true
			msg="$msg Blocked, because you are staying on $(stay_names). The game should search again."
		fi
	fi
	printf '{"ts":%s,"ip":"%s","port":%s,"loc":"%s","org":"%s","ping":%s,"verdict":"%s","blocked":%s,"msg":"%s"}\n' \
		"$(date +%s)" "$ip" "${port:-0}" "$(jesc "$loc")" "$(jesc "$org")" "${ping:-null}" "$verdict" "$blocked" "$(jesc "$msg")" > "$RUN/www/lobby.json.tmp" && mv -f "$RUN/www/lobby.json.tmp" "$RUN/www/lobby.json"
	if [ "$LOBBY_ALERT" = 2 ] || { [ "$LOBBY_ALERT" = 1 ] && { [ "$verdict" != good ] || [ "$blocked" = true ]; }; }; then cmd_notify "$msg"
	else logger -t matchwatch "$msg" 2>/dev/null; fi
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
		done < "$LIB/regions.list"
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

# ---- stay on one datacentre
stay_off() {
	local ip
	touch "$DATA/blocklist"
	awk -F'\t' '$4 == "stay" { print $1 }' "$DATA/blocklist" | while read -r ip; do nft delete element inet matchwatch blocked "{ $ip }" 2>/dev/null; done
	awk -F'\t' '$4 != "stay"' "$DATA/blocklist" > "$DATA/blocklist.tmp" && mv -f "$DATA/blocklist.tmp" "$DATA/blocklist"
	rm -f "$DATA/stay"
	export_json
}
stay_vars() { # awk variable naming the file of places being kept to (nothing when stay mode is off)
	[ -s "$DATA/stay" ] && echo "-v STAYF=$DATA/stay"
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
			[ -n "$line" ] || line="$(awk -F'|' -v w="$want" -v k="${STAY_KM:-150}" 'BEGIN { w = tolower(w) } /^#/ { next } tolower($1) == w || tolower($2) == w { print $2 ", " $3 "\t" $5 "\t" $6 "\t" k "\t-"; exit }' "$LIB/regions.list" 2>/dev/null)"
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
stay_apply() { # make the blocks match the pool: clear the old ones, then block every address block played on outside it
	local ip p n=0
	touch "$DATA/blocklist"
	awk -F'\t' '$4 == "stay" { print $1 }' "$DATA/blocklist" | while read -r ip; do nft delete element inet matchwatch blocked "{ $ip }" 2>/dev/null; done
	awk -F'\t' '$4 != "stay"' "$DATA/blocklist" > "$DATA/blocklist.tmp" && mv -f "$DATA/blocklist.tmp" "$DATA/blocklist"
	for p in $(awk -v MODE=area_others $(stay_vars) -f "$LIB/report.awk" "$DATA/sessions.tsv"); do MW_QUIET=1 cmd_block "$p" 0 stay; n=$((n + 1)); done
	export_json
	echo "$n"
}
stay_report() {
	echo "Staying on: $(stay_names)"
	echo "Any server in any of these places is allowed, whoever hosts it. Blocked $1 address block(s) you have played on elsewhere; others are turned away as the game tries them."
	echo "The game still decides which of them to offer you. A place is dropped from the pool if its last three matches average under $WARN_SCORE."
}
cmd_stay() { # <places> | add <places> | remove <n> | off | (nothing = status)
	local n
	touch "$DATA/sessions.tsv" "$DATA/blocklist"
	case "$1" in
		off) if [ -s "$DATA/stay" ]; then stay_off; echo "No longer staying anywhere. The blocks it added are removed."; else echo "Stay mode was not on."; fi ;;
		""|status)
			if [ -s "$DATA/stay" ]; then echo "Staying on:"; awk -F'\t' '{ printf "  %d  %s  (%s)\n", NR, $1, ($5 != "" && $5 != "-" ? "anywhere in it" : "within " $4 " km") }' "$DATA/stay"
			else echo "Stay mode is off. Turn it on with: matchwatch stay <places, separated by commas>"; fi ;;
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
cmd_game() { # name <port> <name>
	[ "$1" = name ] || die "usage: matchwatch game name <server port> <name>"
	case "$2" in ""|*[!0-9]*) die "usage: matchwatch game name <server port> <name>" ;; esac
	[ -n "$3" ] || die "usage: matchwatch game name <server port> <name>"
	touch "$DATA/games.local"
	grep -v "|$2\$" "$DATA/games.local" > "$DATA/games.local.tmp"; mv -f "$DATA/games.local.tmp" "$DATA/games.local"
	printf '%s|%s\n' "$(echo "$3" | tr -d '|"\\')" "$2" >> "$DATA/games.local"
	export_json
	echo "Matches on server port $2 are now labelled: $3"
}
cmd_unblock_dc() { # number
	local list p
	case "$1" in ""|*[!0-9]*) die "usage: matchwatch unblock-dc <number>" ;; esac
	list="$(awk -v MODE=dc_prefixes -v ARG="$1" -v BLOCK="$DATA/blocklist" -f "$LIB/report.awk" "$DATA/sessions.tsv")"
	[ -n "$list" ] || die "no datacentre number $1"
	echo "$list" | tail -n +2 | while read -r p; do cmd_unblock "$p"; done
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
		printf "],\"verdict\":\"%s\",\"msg\":\"%s\"}\n", vd, msg
	}'
	rm -f "$d"/*; rmdir "$d" 2>/dev/null
}

# ---- what the dashboard's buttons run (through LuCI's rpcd backend, /usr/libexec/rpcd/luci.matchwatch)
cmd_action() { # action [arg] [days] [place] [name] : prints the result; a non-zero exit means it did not work
	local action="$1" arg="$2" days="$3" region="$4" name="$5"
	case "$name" in *[!A-Za-z0-9\ .:-]*) die "names may only use letters, numbers, spaces, dots, colons and hyphens" ;; esac
	[ "${#name}" -le 40 ] || die "that name is too long"
	case "$arg" in *[!0-9./]*) die "that is not an address or a number" ;; esac
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
		trace) cmd_trace "$arg" ;;
		gamename) [ -n "$arg" ] && [ -n "$name" ] || die "choose a game and type a name for it"; cmd_game name "$arg" "$name" ;;
		clearhistory) cmd_clear_history ;;
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
		put stay_strict "$STAY_STRICT"; put stay_km "$STAY_KM"; put data_dir "$DATA_DIR"; put web "$WEB"
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
		cp -f "$LIB/public.html" /www/matchwatch/index.html
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
	web_setup; export_json
	echo '{"ts":0,"sessions":[],"candidates":0,"flows":0}' > "$RUN/www/status.json"
	echo "Starting up..." > "$RUN/status.txt"
	mkfifo "$RUN/pipe" || die "cannot create $RUN/pipe"
	tcpdump --help 2>&1 | grep -q immediate-mode && imm="--immediate-mode"
	awk -v SELF="$SELF" -v RUN="$RUN" -v DATA="$DATA" -v WANDEV="$WAN_IF" \
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
  matchwatch hours             how your matches rate at each hour of the day
  matchwatch recap             summary of your latest session
  matchwatch games             games seen; 'matchwatch game name <port> <name>' labels one
  matchwatch regions [measure] ping every region the game's host has a datacentre in
  matchwatch mark              flag this moment ("I felt that"); same as the dashboard button
  matchwatch qos               check the game is in QoSmate's top class (run during a match)
  matchwatch device [<ip>|all] show the devices on your network and choose which one to watch
  matchwatch qos fix | unfix   add (or remove) QoSmate rules that put your gaming device's UDP in the top class
  matchwatch block <ip> [days] block a server (default $BLOCK_DAYS days, 0 = until unblocked)
  matchwatch unblock <ip>|all  remove a block
  matchwatch blocklist         show blocked servers
  matchwatch doctor            check that everything needed is in place (changes nothing)
  matchwatch clear-history     forget every recorded match (blocks and settings are kept)
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
	stay) shift; case "$1" in add|remove) c="$1"; shift; cmd_stay "$c" "$*" ;; *) cmd_stay "$*" ;; esac ;;
	hours) touch "$DATA/sessions.tsv"; awk -v MODE=hours_txt -f "$LIB/report.awk" "$DATA/sessions.tsv" ;;
	recap) touch "$DATA/sessions.tsv"; awk -v MODE=recap_txt -v GAMES="$LIB/games.list" -v GAMESL="$DATA/games.local" -f "$LIB/report.awk" "$DATA/sessions.tsv" ;;
	games) touch "$DATA/sessions.tsv"; awk -v MODE=games_txt -v GAMES="$LIB/games.list" -v GAMESL="$DATA/games.local" -f "$LIB/report.awk" "$DATA/sessions.tsv" ;;
	game) cmd_game "$2" "$3" "$4" ;;
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
	doctor) cmd_doctor ;;
	clear-history) cmd_clear_history ;;
	version) echo "$VERSION" ;;
	_probe_start) shift; cmd_probe_start "$@" ;;
	_probe_stop) cmd_probe_stop "$2" ;;
	_notify) cmd_notify "$2" ;;
	_after) cmd_after "$2" "$3" ;;
	_export) mkdir -p "$RUN/www"; export_json ;;
	_stop) [ -f "$RUN/pid" ] && kill "$(cat "$RUN/pid")" 2>/dev/null ;;
	*) usage ;;
esac
MW_FILE_END_0
chmod 755 "$R/usr/bin/matchwatch"
cat > "$R/usr/lib/matchwatch/analyze.awk" <<'MW_FILE_END_1'
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
	while ((getline line < HIST) > 0) {
		n = split(line, c, "\t")
		if (n >= 6) { if (c[6] + 0 >= 1024) KPORT[c[6]] = 1; K24[pfx(c[5])] = 1 }
		if (n >= 37 && c[37] == 1 && c[36] != "-") { REP_n[c[5]]++; REP_sum[c[5]] += c[36]; p24 = pfx(c[5]); R24_n[p24]++; R24_sum[p24] += c[36] }
	}
	close(HIST)
	cursec = 0; NFLOW = 0; SIDN = 0; FTMAX = 5400
	DD = (DETAILDIR != "") ? DETAILDIR : DATA "/matches"
}

# ---------------------------------------------------------------- input

$1 == "TICK" {
	now = ($2 != "") ? $2 + 0 : systime()
	# packets are delivered slightly behind real time, so trail by 2 s
	advance(now - 2)
	if (!REPLAY) { read_marks(); wan_sample(); write_status(now) }
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
	f = lip ":" lport ">" rip ":" rport
	if (!(f in F_seen)) {
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
			if (!REPLAY) system(SELF " _notify 'New server " ip ", but its neighbours in the same datacentre block rate " int(R24_sum[p] / R24_n[p]) "/100 over " R24_n[p] " matches.' &")
		}
		return
	}
	avg = REP_sum[ip] / REP_n[ip]
	if (avg < WARNSCORE) {
		print "WARN known bad server " ip " (rating " int(avg) " over " REP_n[ip] " matches)"
		if (!REPLAY) system(SELF " _notify 'Known bad server " ip " - rated " int(avg) "/100 over " REP_n[ip] " matches. Consider backing out.' &")
	}
}

# first packets to a server that looks like a game server: tell the player where they are headed
function lobby_check(f,    ip) {
	F_lobby[f] = 1
	ip = F_rip[f]
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
	if (!REPLAY) system(SELF " _probe_start " F_sid[f] " " F_rip[f] " " F_lip[f] " " F_rport[f] " >/dev/null 2>&1 &")
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
	n = PS[pfx "_n"] + 0
	if (n < 10) return "-"
	jit = PS[pfx "_jit"] + 0; loss = PS[pfx "_loss"] + 0; med = PS[pfx "_med"] + 0
	if (kind == "server") { A = 1; B = 6; L = 12 }
	else if (kind == "serverudp") { A = 1; B = 6; L = 0 }   # servers ration replies to these probes, so unanswered ones say nothing about the route
	else if (kind == "lan") { A = 0.5; B = 10; L = 15 }
	else { A = 3; B = 3; L = 6 }          # router hops answer ping lazily: be lenient
	s = 100 - clamp((jit - A) * B, 0, 35) - clamp(loss * L, 0, 45)
	if (pfx == "far") s -= clamp((med - 40) / 2, 0, 20)
	return int(clamp(s, 0, 100) + 0.5)
}

function session_end(f, sec,    kd, ku, dur, dsec, usec, tick, dnom, djit, djrel, dlate, dlost, dclump, dfrz, dstut, dbad, p10,
		uhz, unom, ujit, ujrel, ustall, uhitch, upp, s_srv, s_route, s_line, s_pc, s_lan, overall, rating, reliable,
		wsum, w, i, kk, mk, msum, dj, df, trl, code, vtext, farkind, route_ign, s_route_shown, s_pc_shown, pc_low, loc, rep, out, ip, when, note, avg, sumfile, wan_avg) {
	kd = f SUBSEP "D"; ku = f SUBSEP "U"
	ip = F_rip[f]
	dur = F_last[f] - F_first[f]
	dsec = (S_win[kd] + 0) * WIN; usec = (S_win[ku] + 0) * WIN

	split("", PS)
	if (!REPLAY) {
		system(SELF " _probe_stop " F_sid[f])
		sumfile = RUN "/probe." F_sid[f] "/sum"
		load_sum(sumfile)
		TRN = 0
		while ((getline trl < (RUN "/probe." F_sid[f] "/trace")) > 0) if (trl ~ /^ *[0-9]+ /) TR[++TRN] = clean(trl)
		close(RUN "/probe." F_sid[f] "/trace")
	} else { TRN = 0; if (PROBESUM != "") load_sum(PROBESUM) }

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
	dfrz = S_frz[kd] + 0; dstut = S_stut[kd] + 0
	dbad = 100 * S_bad[kd] / S_win[kd]
	p10 = 600 / dsec
	s_srv = 100 - clamp((djrel - 5) * 1.5, 0, 30) - clamp((dlate + dclump) * 4, 0, 25) - clamp(dlost * 12, 0, 35) - clamp(dstut * p10 / 10 * 2, 0, 30) - clamp(dfrz * p10 * 5, 0, 20) - clamp((dbad - 5) * 0.4, 0, 20)
	s_srv = int(clamp(s_srv, 0, 100) + 0.5)

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
	} else { uhz = "-"; ujit = "-"; ustall = "-"; uhitch = "-"; s_pc = "-" }

	s_pc_shown = s_pc
	if (PCSCORE == 0) s_pc = "-"       # shown in the report, left out of the overall score and verdict

	# --- route and line (active probes, if they answered)
	farkind = (PS["far_kind"] != "") ? PS["far_kind"] : "-"
	s_route = probe_score("far", farkind)
	s_line = probe_score("near", "hop")

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
	if (AUTOBLOCK && reliable && (ip in REP_n) && REP_n[ip] >= ABMATCHES) {
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
	print s > sf; close(sf)
	printf "%s", txt > tf; close(tf)
	system("mv -f " sf " " RUN "/www/status.json; mv -f " tf " " RUN "/status.txt")
}
MW_FILE_END_1
chmod 644 "$R/usr/lib/matchwatch/analyze.awk"
cat > "$R/usr/lib/matchwatch/report.awk" <<'MW_FILE_END_2'
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
	if (io == 0 && !(p24(ip) in OUT_seen)) { OUT_seen[p24(ip)] = 1; OUT[++nout] = p24(ip) ".0/24" }
	if (io == 1 && $37 == 1) IN_hist[++nin] = $36
	if ($37 == 1) { hh = strftime("%H", $1) + 0; HR_n[hh]++; HR_s[hh] += $36 }
	g = game_of($6); if (!(g in G_n)) gorder[++ngs] = g; G_n[g]++; G_secs[g] += $2; G_port[g] = $6
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
function game_of(port,   i, k, a, lo) {
	for (i = 1; i <= ngame; i++) {
		k = split(GM[i, 2], a, ",")
		for (lo = 1; lo <= k; lo++) { if (a[lo] ~ /-/) { split(a[lo], b3, "-"); if (port + 0 >= b3[1] + 0 && port + 0 <= b3[2] + 0) return GM[i, 1] } else if (a[lo] + 0 == port + 0) return GM[i, 1] }
	}
	return "Game on port " port
}
function load_games(file,   l, g) { if (file == "") return; while ((getline l < file) > 0) { if (l ~ /^#/ || l == "") continue; split(l, g, "|"); ngame++; GM[ngame, 1] = g[1]; GM[ngame, 2] = g[2] } close(file) }
# which measured region is this match's server in? nearest, within 150 km
function region_of(lat, lon,   i, best, bd, d) {
	if (!known(lat) || !known(lon)) return ""
	best = ""; bd = 150 * 150
	for (i = 1; i <= nreg; i++) { d = km2(lat, lon, RG[i, 5], RG[i, 6]); if (d < bd) { bd = d; best = RG[i, 1] } }
	return best
}
function srating(ip) { return (S_rn[ip] > 0) ? int(S_rsum[ip] / S_rn[ip] + 0.5) : int(S_all[ip] / S_n[ip] + 0.5) }

END {
	if (MODE == "hist_txt") {
		lim = 15; only = ""
		if (ARG ~ /^[0-9]+$/) lim = ARG + 0; else if (ARG != "") { only = ARG; lim = 100000 }
		if (n == 0) { print "No matches recorded yet."; exit }
		printf "%-16s %-18s %-16s %-18s %5s %6s %6s %6s %7s %6s  %s\n", "When", "Game", "Server", "Where", "Rate", "Jitter", "Miss%", "Ping", "Overall", "Server", "Finding"
		shown = 0
		for (i = n; i >= 1 && shown < lim; i--) {
			if (only != "" && R[i, 5] != only) continue
			printf "%-16s %-18s %-16s %-18s %5s %6s %6s %6s %7s %6s  %s\n", strftime("%Y-%m-%d %H:%M", R[i, 1]), substr(game_of(R[i, 6]), 1, 18), R[i, 5], substr(where(i), 1, 18), R[i, 11], R[i, 12], R[i, 14], R[i, 22], R[i, 35], R[i, 36], R[i, 38]
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
			gg = game_of(R[i, 6]); if (!(gg in RG_n)) rgo[++nrg] = gg; RG_n[gg]++
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
			printf "%s{\"code\":%s,\"city\":%s,\"cc\":%s,\"area\":%s,\"ping\":%s,\"jit\":%s,\"ts\":%d,\"matches\":%d,\"rating\":%s,\"matchping\":%s,\"stay\":%s}", (i > 1 ? "," : ""), q(c), q(RG[r, 2]), q(RG[r, 3]), q(RG[r, 4]), jn(RG[r, 8]), jn(RG[r, 9]), RG[r, 11], RP_n[c] + 0, (RP_rn[c] > 0 ? int(RP_rs[c] / RP_rn[c] + 0.5) : "null"), (RP_pn[c] > 0 ? sprintf("%.1f", RP_p[c] / RP_pn[c]) : "null"), (inside(RG[r, 5], RG[r, 6], RG[r, 3]) == 1 ? "true" : "false")
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
			printf "%s{\"ip\":%s,\"cc\":%s,\"city\":%s,\"org\":%s,\"matches\":%d,\"counted\":%d,\"rating\":%d,\"worst\":%d,\"tick\":%.1f,\"ping\":%s,\"last\":%d,\"minutes\":%d,\"blocked\":%s}", (i > 1 ? "," : ""), q(ip), q(S_cc[ip]), q(S_city[ip]), q(S_org[ip]), S_n[ip], S_rn[ip] + 0, srating(ip), S_worst[ip], S_tick[ip] / S_n[ip], (S_pingn[ip] > 0 ? sprintf("%.1f", S_ping[ip] / S_pingn[ip]) : "null"), S_last[ip], S_secs[ip] / 60, (blocked(ip) ? "true" : "false")
		}
		print "]"
		exit
	}
	if (MODE == "hist_json") {
		printf "["
		c = 0
		for (i = n; i >= 1 && c < 200; i--) {
			printf "%s{\"game\":%s,\"start\":%d,\"dur\":%d,\"analysed\":%d,\"device\":%s,\"ip\":%s,\"port\":%d,\"cc\":%s,\"city\":%s,\"org\":%s,\"asn\":%s", (c ? "," : ""), q(game_of(R[i, 6])), R[i, 1], R[i, 2], R[i, 3], q(R[i, 4]), q(R[i, 5]), R[i, 6], q(R[i, 7]), q(R[i, 8]), q(R[i, 9]), q(R[i, 10])
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
chmod 644 "$R/usr/lib/matchwatch/report.awk"
cat > "$R/usr/lib/matchwatch/public.html" <<'MW_FILE_END_3'
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
chmod 644 "$R/usr/lib/matchwatch/public.html"
cat > "$R/usr/lib/matchwatch/config.uci" <<'MW_FILE_END_4'

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
chmod 644 "$R/usr/lib/matchwatch/config.uci"
cat > "$R/usr/lib/matchwatch/regions.list" <<'MW_FILE_END_5'
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
chmod 644 "$R/usr/lib/matchwatch/regions.list"
cat > "$R/usr/lib/matchwatch/places.list" <<'MW_FILE_END_6'
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
MW_FILE_END_6
chmod 644 "$R/usr/lib/matchwatch/places.list"
cat > "$R/usr/lib/matchwatch/games.list" <<'MW_FILE_END_7'
# Game labels by the server's port. name|ports (single ports or ranges, comma separated)
# Your own labels (matchwatch game name <port> <name>) are checked first.
Call of Duty|3074,30000-45000
Valve (Counter-Strike, Dota 2, TF2)|27015-27200
MW_FILE_END_7
chmod 644 "$R/usr/lib/matchwatch/games.list"
cat > "$R/etc/init.d/matchwatch" <<'MW_FILE_END_8'
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

reload_service() {
	stop
	start
}
MW_FILE_END_8
chmod 755 "$R/etc/init.d/matchwatch"
cat > "$R/usr/libexec/rpcd/luci.matchwatch" <<'MW_FILE_END_9'
#!/bin/sh
# rpcd backend for luci-app-matchwatch: runs the dashboard's buttons.
# Two methods so LuCI's permissions can tell looking from changing:
#   read   checks, the line test, a route trace, the activity log, and "I felt that"
#   write  anything that blocks, stays, measures, alerts, renames, clears, or changes QoSmate or the device
# The work itself is done by /usr/bin/matchwatch _action, which validates every argument.

. /usr/share/libubox/jshn.sh

READ="hello mark devices doctor qos log linetest trace"
WRITE="block unblock blockdc unblockdc stay stayoff stayadd stayrm regions qosfix qosunfix setdevice setdeviceall testalert gamename clearhistory"

reply() { # ok(0|1) text
	json_init
	json_add_boolean ok "$1"
	json_add_string out "$2"
	json_dump
}

case "$1" in
	list)
		echo '{"read":{"action":"str","arg":"str"},"write":{"action":"str","arg":"str","days":"str","region":"str","name":"str"}}'
		;;
	call)
		read -r input
		json_load "$input" 2>/dev/null || { reply 0 "bad request"; exit 0; }
		json_get_var action action
		json_get_var arg arg
		json_get_var days days
		json_get_var region region
		json_get_var name name

		case "$2" in
			read) allowed="$READ" ;;
			write) allowed="$WRITE" ;;
			*) reply 0 "unknown method"; exit 0 ;;
		esac
		case "$action" in ""|*[!a-z]*) reply 0 "unknown action"; exit 0 ;; esac
		case " $allowed " in *" $action "*) ;; *) reply 0 "unknown action"; exit 0 ;; esac

		if out="$(/usr/bin/matchwatch _action "$action" "$arg" "$days" "$region" "$name" 2>&1)"; then
			reply 1 "$out"
		else
			reply 0 "$out"
		fi
		;;
esac
MW_FILE_END_9
chmod 755 "$R/usr/libexec/rpcd/luci.matchwatch"
cat > "$R/usr/share/luci/menu.d/luci-app-matchwatch.json" <<'MW_FILE_END_10'
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
MW_FILE_END_10
chmod 644 "$R/usr/share/luci/menu.d/luci-app-matchwatch.json"
cat > "$R/usr/share/rpcd/acl.d/luci-app-matchwatch.json" <<'MW_FILE_END_11'
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
MW_FILE_END_11
chmod 644 "$R/usr/share/rpcd/acl.d/luci-app-matchwatch.json"
cat > "$R/www/luci-static/resources/matchwatch/dashboard.js" <<'MW_FILE_END_12'
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
var D = { st: null, hist: [], servers: [], dcs: [], blocks: [], info: {}, lobby: null, regions: [] };
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
	if (L.ip !== s.ip + isBlocked(s.ip)) {
		L.ip = s.ip + isBlocked(s.ip); L.actions.textContent = "";
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
	var heads = [["When"], ["Where"], ["Server"], ["Length"], ["Ping ms", "num"], ["Jitter ms", "num"], ["Missing %", "num"], ["Overall", "num"], ["Finding"], ["You flagged"]];
	heads.splice(1, 0, ["Game"]);
	var t = table(heads);
	D.hist.forEach(function (m) {
		if (gameFilter && m.game !== gameFilter) return;
		if (hourFilter >= 0 && hourOf(m) !== hourFilter) return;
		var cells = [[when(m.start)], [place(m)], [m.ip], [mins(m.dur)], [m.ping == null ? "n/a" : fmt(m.ping, 1), "num"], [fmt(m.jit, 2), "num"], [fmt(m.lost, 2), "num"], [String(m.overall), "num s " + cls(m.overall)], [FINDING[m.code] || m.code], [m.marks ? m.marksum : ""]];
		cells.splice(1, 0, [m.game || ""]);
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
			t.lastChild.appendChild(row([[d.name], [String(d.matches), "num"], [String(d.servers), "num"], [String(d.rating), "num s " + cls(d.rating)], [String(d.worst), "num"], [d.ping == null ? "n/a" : fmt(d.ping, 1), "num"], td]));
		});
		view.appendChild(h("div", { cls: "tablewrap" }, t));
		view.appendChild(h("p", { cls: "note", text: "A datacentre is one operator in one city. Ratings need a few matches each before they mean much. Blocking one only covers the address blocks you have been placed on there so far." }));
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
			if (s.blocked) td.appendChild(h("span", { cls: "tag", text: "Blocked" })); else td.appendChild(act("Block", "block", s.ip, { danger: true, confirm: "Confirm: " + days + " days" }));
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
function pageTools() {
	view.textContent = ""; view.appendChild(h("h1", "Tools"));
	var i = D.info, hasQos = i.qosmate !== false;
	if (!RO) {
		var out = h("pre"); out.style.display = "none";
		var show = function (text) { out.textContent = text; out.style.display = "block"; };
		view.appendChild(h("h2", "Checks"));
		view.appendChild(h("div", { cls: "actions" }, act("Check MatchWatch is working", "doctor", null, { solid: true, done: show }), hasQos ? act("Is my game prioritised?", "qos", null, { done: show }) : null));
		view.appendChild(h("p", { cls: "note", text: "Neither check changes anything. The first confirms MatchWatch can see your device's traffic, and takes five seconds." + (hasQos ? " The second looks at whether your game's traffic is in QoSmate's top priority queue, and needs a match in progress." : "") }));
		view.appendChild(out);

		view.appendChild(h("h2", "Test your line"));
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
		view.appendChild(h("div", { cls: "actions" }, lineBtn));
		view.appendChild(h("p", { cls: "note", text: "Twenty seconds of pings from the router to your provider and two public servers, with no game needed. Use it before you queue to see whether your own connection is steady tonight. It changes nothing." }));
		view.appendChild(lineOut);

		view.appendChild(h("h2", "Phone alerts"));
		view.appendChild(h("div", { cls: "actions" }, act("Send a test alert", "testalert", null, {})));
		view.appendChild(h("p", { cls: "note", text: i.notify ? "Sends one message to your phone, to prove the address in Settings works." : "No phone alerts address is set yet. Add one under Alerts on the Settings tab, then use this to prove it works." }));

		if (D.servers.length) {
			view.appendChild(h("h2", "Route to a server"));
			var sel = h("select", { "aria-label": "Server to trace" });
			D.servers.slice().sort(function (a, b) { return b.last - a.last; }).forEach(function (s) { sel.appendChild(h("option", { value: s.ip, text: s.ip + (place(s) ? ", " + place(s) : "") + " (rated " + s.rating + ")" })); });
			var trOut = h("div"), trBtn = h("button", { type: "button", text: "Trace the route now" });
			trBtn.addEventListener("click", function () {
				trOut.textContent = "";
				job(trBtn, "trace", sel.value, "trace.json", function (r) {
					if (!r.hops || !r.hops.length) { trOut.appendChild(h("p", { cls: "note", text: "No hop answered." })); return; }
					var ol = h("ol", { cls: "hops" }); r.hops.forEach(function (x) { ol.appendChild(h("li", x)); }); trOut.appendChild(ol);
					trOut.appendChild(h("p", { cls: "note", text: "Each line is one stop between your router and the server, with how long it took to answer. A star means that stop did not answer, which is common and not a fault. Compare with the route in a match report to see whether the path has changed." }));
				});
			});
			view.appendChild(h("div", { cls: "stayform" }, sel, trBtn));
			view.appendChild(trOut);
		}

		var ports = [], names = {};
		D.hist.forEach(function (m) { if (m.port && ports.indexOf(m.port) < 0) { ports.push(m.port); names[m.port] = m.game || ""; } });
		if (ports.length) {
			view.appendChild(h("h2", "Name a game"));
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
			view.appendChild(h("div", { cls: "stayform" }, gsel, ginp, gbtn));
			view.appendChild(h("p", { cls: "note", text: "Games are recognised by the port their servers use. Give an unrecognised one a name and every match on that port, past and future, shows it." }));
		}

		view.appendChild(h("h2", "Your history"));
		var dl = h("button", { type: "button", text: "Download as a spreadsheet file" });
		dl.addEventListener("click", downloadHistory); dl.disabled = !D.hist.length;
		view.appendChild(h("div", { cls: "actions" }, dl, act("Clear all history", "clearhistory", null, { danger: true, confirm: "Confirm: delete every recorded match", done: function (o) { toast(o); setTimeout(function () { refresh(true); if (page === "tools") pageTools(); }, 2500); } })));
		view.appendChild(h("p", { cls: "note", text: D.hist.length + " match" + (D.hist.length === 1 ? "" : "es") + " on file. Clearing deletes every match and the server ratings built from them, and cannot be undone. Blocks, the places you stay on and your settings are kept. It restarts MatchWatch, so do it between matches." }));

		view.appendChild(h("h2", "Recent activity"));
		var logOut = h("pre"); logOut.style.display = "none";
		view.appendChild(h("div", { cls: "actions" }, act("Show recent activity", "log", null, { done: function (o) { logOut.textContent = o || "Nothing logged yet."; logOut.style.display = "block"; } })));
		view.appendChild(h("p", { cls: "note", text: "The last things MatchWatch wrote to the router's log: matches judged, servers blocked, alerts sent." }));
		view.appendChild(logOut);

		if (hasQos) {
			view.appendChild(h("h2", "QoSmate priority"));
			view.appendChild(h("p", { cls: "note", text: "If \"Is my game prioritised?\" says your game is not reaching the top queue, this adds two QoSmate rules that mark all UDP to and from your gaming device, except web ports, as EF: top priority in every QoSmate mode. It restarts QoSmate, which causes a brief blip, so do it between matches. Remove takes these two out again." }));
			view.appendChild(h("div", { cls: "actions" }, act("Prioritise my game traffic", "qosfix", null, { confirm: "Confirm: add the rules and restart QoSmate", done: show }), act("Remove those rules", "qosunfix", null, { confirm: "Confirm: remove and restart QoSmate", done: show })));
		}
	}
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
// half-typed text in the places box would be wiped by a redraw
function typing() { var i = shadow.getElementById("place"); return !!(i && i.value); }
function refresh(force) {
	get("regions.json", function (x) { D.regions = x || []; });
	var left = 5, done = function () { if (--left === 0 && (force || (!armed && !typing())) && page !== "live" && page !== "match" && page !== "tools") route(true); else if (left === 0 && page === "live") { L.ip = null; updateLive(); } };
	get("history.json", function (x) { D.hist = x || []; done(); });
	get("servers.json", function (x) { D.servers = x || []; done(); });
	get("datacentres.json", function (x) { D.dcs = x || []; done(); });
	get("blocklist.json", function (x) { D.blocks = x || []; done(); });
	get("info.json", function (x) { D.info = x || {}; done(); });
}
window.addEventListener("hashchange", route);
window.addEventListener("resize", function () { updateLive(); if (page === "match" && pageMatch.repaint) pageMatch.repaint(); });
var first = 5, boot = function () { if (--first === 0) route(); };
get("history.json", function (x) { D.hist = x || []; boot(); }); get("servers.json", function (x) { D.servers = x || []; boot(); }); get("datacentres.json", function (x) { D.dcs = x || []; boot(); });
get("blocklist.json", function (x) { D.blocks = x || []; boot(); }); get("info.json", function (x) { D.info = x || {}; boot(); });
get("regions.json", function (x) { D.regions = x || []; });
tick(); setInterval(tick, 1000); setInterval(function () { setDark(); refresh(false); }, 15000);
};
MW_FILE_END_12
chmod 644 "$R/www/luci-static/resources/matchwatch/dashboard.js"
cat > "$R/www/luci-static/resources/matchwatch/dashboard.css" <<'MW_FILE_END_13'
:host { display: block; }
.mw {
	--paper: #eef2ea; --panel: #f8faf5; --grid: #cbd8c8; --ink: #17313b; --muted: #5d6f6a;
	--pen: #1f6f78; --pen2: #8a6d1f; --bad: #c8372d; --ok: #2f7d4f; --mid: #a8720d;
	--display: "Bahnschrift", "DIN Alternate", "Roboto Condensed", "Arial Narrow", system-ui, sans-serif;
}
.mw.dark { --paper: #0f2a2b; --panel: #14383a; --grid: #245052; --ink: #e4efe6; --muted: #9db8b0;
		--pen: #7fd1c0; --pen2: #e3c672; --bad: #ff6b57; --ok: #7fd19a; --mid: #e3b24f; }
* { box-sizing: border-box; }
.mw { text-align: left; background: var(--paper); color: var(--ink); font: 16px/1.45 system-ui, -apple-system, "Segoe UI", Roboto, sans-serif; font-variant-numeric: tabular-nums; }
a { color: inherit; }
.top { display: flex; align-items: center; gap: 8px 28px; flex-wrap: wrap; max-width: 1120px; margin: 0 auto; padding: 14px 16px 0; }
.brand { font: 700 1.35rem/1 var(--display); letter-spacing: 0.01em; text-decoration: none; }
nav { display: flex; gap: 4px; flex-wrap: wrap; flex: 1; }
nav a { text-decoration: none; padding: 6px 12px; border-radius: 3px; color: var(--muted); font-weight: 600; }
nav a[aria-current] { background: var(--ink); color: var(--paper); }
nav a:focus-visible, button:focus-visible, tr[tabindex]:focus-visible { outline: 3px solid var(--pen); outline-offset: 2px; }
#state { color: var(--muted); font-size: 0.92rem; }
@media (max-width: 680px) {
	.top { gap: 8px 12px; justify-content: space-between; }
	nav { order: 3; flex-basis: 100%; flex-wrap: nowrap; overflow-x: auto; margin: 0 -16px; padding: 0 16px 2px; }
	nav a { white-space: nowrap; }
	h1 { font-size: 1.6rem; }
}
#state.on { color: var(--ok); font-weight: 700; }
main { max-width: 1120px; margin: 0 auto; padding: 18px 16px 56px; }
h1 { font: 700 2rem/1.1 var(--display); margin: 0; letter-spacing: 0.005em; }
h2 { font: 700 1.2rem/1.2 var(--display); margin: 34px 0 10px; }
.sub { color: var(--muted); margin: 4px 0 0; }
.lede { font-size: 1.2rem; max-width: 64ch; margin: 14px 0 0; }
.empty { color: var(--muted); }

.strip { margin-top: 16px; background: var(--panel); border: 1px solid var(--grid); border-radius: 3px; }
canvas { display: block; width: 100%; height: 300px; }
.legend { display: flex; gap: 6px 18px; flex-wrap: wrap; padding: 8px 12px; border-top: 1px solid var(--grid); color: var(--muted); font-size: 0.85rem; }
.legend i { display: inline-block; width: 10px; height: 10px; margin-right: 6px; vertical-align: -1px; }

.figs { display: grid; grid-template-columns: repeat(auto-fit, minmax(128px, 1fr)); gap: 4px 20px; margin: 16px 0 0; padding: 0; }
.figs div { border-top: 2px solid var(--ink); padding-top: 6px; }
.figs dt { color: var(--muted); font-size: 0.85rem; }
.figs dd { margin: 0; font: 600 1.7rem/1.2 var(--display); }
.figs dd small { font: 400 0.85rem system-ui, sans-serif; color: var(--muted); margin-left: 4px; }

/* the path a packet takes: PC, line, route, server. The weak link stands out. */
.chain { display: grid; grid-template-columns: repeat(4, 1fr); margin: 22px 0 0; position: relative; }
.chain::before { content: ""; position: absolute; left: 12%; right: 12%; top: 27px; border-top: 2px solid var(--grid); }
.link { position: relative; padding: 0 10px; text-align: center; }
.link .dot { width: 54px; height: 54px; border-radius: 50%; margin: 0 auto; display: grid; place-items: center; background: var(--paper); border: 3px solid var(--ok); font: 700 1.25rem/1 var(--display); }
.link.mid .dot { border-color: var(--mid); } .link.low .dot { border-color: var(--bad); background: var(--bad); color: var(--paper); }
.link.na .dot { border-color: var(--grid); color: var(--muted); font-size: 0.9rem; }
.link b { display: block; margin-top: 8px; font: 700 1.02rem var(--display); }
.link span { display: block; color: var(--muted); font-size: 0.88rem; }
@media (max-width: 560px) { .chain { grid-template-columns: repeat(2, 1fr); row-gap: 18px; } .chain::before { display: none; } }

.head { display: flex; justify-content: space-between; align-items: flex-end; gap: 16px; flex-wrap: wrap; }
.score { text-align: right; }
.score b { font: 700 3.4rem/0.9 var(--display); }
.score b small { font-size: 1.1rem; color: var(--muted); font-weight: 600; }
.score span { display: block; font-weight: 700; }
.ok { color: var(--ok); } .mid { color: var(--mid); } .low { color: var(--bad); }

.cols { display: grid; grid-template-columns: repeat(auto-fit, minmax(min(420px, 100%), 1fr)); gap: 0 48px; }
.kv { margin: 0; display: grid; grid-template-columns: 1fr auto; gap: 0 14px; }
.kv dt, .kv dd { margin: 0; padding: 6px 0; border-bottom: 1px solid var(--grid); }
.kv dd { text-align: right; font-weight: 600; }
.kv dt small { display: block; color: var(--muted); font-size: 0.82rem; }
.note { color: var(--muted); font-size: 0.9rem; margin: 6px 0 0; max-width: 70ch; }
ol.hops { margin: 8px 0 0; padding: 0; list-style: none; font-size: 0.9rem; color: var(--muted); columns: 2 220px; }

.tablewrap { overflow-x: auto; }
table { border-collapse: collapse; width: 100%; font-size: 0.93rem; }
th { text-align: left; font-weight: 600; color: var(--muted); border-bottom: 2px solid var(--ink); padding: 6px 12px 6px 0; white-space: nowrap; }
td { border-bottom: 1px solid var(--grid); padding: 8px 12px 8px 0; white-space: nowrap; }
td.num, th.num { text-align: right; }
td.act { text-align: right; padding-right: 0; }
tr[tabindex] { cursor: pointer; } tr[tabindex]:hover td { background: var(--panel); }
.s { font-weight: 700; }
.tag { background: var(--bad); color: var(--paper); font-size: 0.75rem; font-weight: 700; padding: 2px 7px; border-radius: 2px; }
.tag.keep { background: var(--ok); }

button { font: 600 0.9rem system-ui, sans-serif; color: var(--ink); background: none; border: 1.5px solid var(--ink); border-radius: 3px; padding: 5px 12px; cursor: pointer; margin-left: 6px; }
button.solid { background: var(--ink); color: var(--paper); }
button.big { font-size: 1.05rem; padding: 12px 20px; margin: 0; }
button.danger { border-color: var(--bad); color: var(--bad); }
button.arm { background: var(--bad); border-color: var(--bad); color: var(--paper); }
button:disabled { opacity: 0.45; cursor: default; }
.hours { display: grid; grid-template-columns: repeat(24, 1fr); gap: 2px; align-items: end; max-width: 760px; margin-top: 6px; }
.hr { display: flex; flex-direction: column; align-items: center; justify-content: flex-end; height: 104px; font-size: 0.72rem; color: var(--muted); }
button.hr { background: none; border: 0; border-radius: 0; padding: 0; margin: 0; cursor: pointer; font-weight: 400; }
button.hr:hover i, button.hr.sel i { outline: 2px solid var(--ink); outline-offset: 1px; }
.hr i { display: block; width: 100%; background: var(--grid); }
.hr i.ok { background: var(--ok); } .hr i.mid { background: var(--mid); } .hr i.low { background: var(--bad); }
.hr span { height: 16px; line-height: 16px; } .hr .v { color: var(--ink); font-weight: 600; }
select { font: inherit; padding: 6px 10px; color: var(--ink); background: var(--panel); border: 1.5px solid var(--ink); border-radius: 3px; }
.stayform { display: flex; gap: 8px; flex-wrap: wrap; max-width: 520px; }
.stayform input { flex: 1; min-width: 200px; font: inherit; padding: 8px 10px; color: var(--ink); background: var(--panel); border: 1.5px solid var(--ink); border-radius: 3px; }
.stayform input:focus-visible { outline: 3px solid var(--pen); outline-offset: 2px; }
.stayform button { margin: 0; }
.stayform select { max-width: 100%; }
.lede.ok, .lede.mid, .lede.low { font-weight: 600; }
.actions { display: flex; gap: 10px; flex-wrap: wrap; margin: 18px 0 0; }
.actions button { margin: 0; }

.banner { margin: 14px 0 18px; padding: 12px 14px; border-left: 5px solid var(--pen); background: var(--panel); display: flex; gap: 12px; justify-content: space-between; align-items: center; flex-wrap: wrap; }
.banner.far { border-color: var(--mid); } .banner.bad { border-color: var(--bad); }
.banner p { margin: 0; max-width: 70ch; }
.banner b { font-family: var(--display); }
#toast { position: fixed; left: 50%; bottom: 18px; transform: translateX(-50%); max-width: min(92vw, 640px); background: var(--ink); color: var(--paper); padding: 10px 16px; border-radius: 3px; font-size: 0.95rem; white-space: pre-line; display: none; z-index: 5; }
#toast.err { background: var(--bad); }
ul.marks { list-style: none; margin: 10px 0 0; padding: 0; max-width: 72ch; }
ul.marks li { padding: 6px 0; border-top: 1px solid var(--grid); }
ul.marks time { color: var(--muted); margin-right: 10px; }
pre { background: var(--panel); border: 1px solid var(--grid); padding: 12px; overflow-x: auto; font-size: 0.85rem; white-space: pre-wrap; margin: 12px 0 0; }
code { background: var(--panel); border: 1px solid var(--grid); padding: 1px 5px; border-radius: 2px; }
.mw.full { min-height: 100vh; }
.mw.framed { border-radius: 6px; }
MW_FILE_END_13
chmod 644 "$R/www/luci-static/resources/matchwatch/dashboard.css"
cat > "$R/www/luci-static/resources/view/matchwatch/dashboard.js" <<'MW_FILE_END_14'
'use strict';
'require view';
'require rpc';
'require fs';

/* Services > MatchWatch > Dashboard. Hosts the shared dashboard (resources/matchwatch/dashboard.js)
   and talks to the router through LuCI: data files by file.read, buttons by the luci.matchwatch
   rpcd object, both checked against the logged-in session's permissions. */

var DATA = '/tmp/matchwatch/www/';

var callRead = rpc.declare({ object: 'luci.matchwatch', method: 'read', params: [ 'action', 'arg' ], expect: {} });
var callWrite = rpc.declare({ object: 'luci.matchwatch', method: 'write', params: [ 'action', 'arg', 'days', 'region', 'name' ], expect: {} });

/* Buttons that only look, or only record a time. Everything else needs write permission. */
var READS = { hello: 1, mark: 1, devices: 1, doctor: 1, qos: 1, log: 1, linetest: 1, trace: 1 };

function loadDashboard() {
	if (window.MatchwatchDashboard)
		return Promise.resolve();

	return new Promise(function (resolve, reject) {
		var s = document.createElement('script');
		s.src = L.resource('matchwatch/dashboard.js');
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
		return loadDashboard();
	},

	render: function () {
		var host = E('div', { 'class': 'matchwatch' });

		window.MatchwatchDashboard(host, {
			css: L.resource('matchwatch/dashboard.css'),
			settings: L.url('admin/services/matchwatch/settings'),
			dark: pageIsDark,
			get: function (file) {
				return fs.read(DATA + file).then(function (text) { return JSON.parse(text); });
			},
			act: function (p) {
				if (READS[p.action])
					return callRead(p.action, p.arg || '');

				return callWrite(p.action, p.arg || '', p.days || '', p.region || '', p.name || '');
			}
		});

		return host;
	}
});
MW_FILE_END_14
chmod 644 "$R/www/luci-static/resources/view/matchwatch/dashboard.js"
cat > "$R/www/luci-static/resources/view/matchwatch/settings.js" <<'MW_FILE_END_15'
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
			_('Tells your phone the moment the game itself begins, with where the server is and the ping. Handy when you have stepped away during a long queue.'));
		o.default = '0';
		o.rmempty = false;

		o = s.taboption('alerts', form.Flag, 'notify_every_match', _('Alert after every match'),
			_('Off: only after bad matches and when you land on a server with a bad history.'));
		o.default = '0';
		o.rmempty = false;

		o = s.taboption('alerts', form.ListValue, 'lobby_alert', _('Lobby alert'),
			_('When the game starts connecting you to a server, MatchWatch works out where it is and how it has rated.'));
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
MW_FILE_END_15
chmod 644 "$R/www/luci-static/resources/view/matchwatch/settings.js"

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
