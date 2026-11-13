# matchwatch history reports. Input: sessions.tsv
# SPDX-License-Identifier: GPL-3.0-or-later
# Copyright (C) 2026 ItsGix and the MatchWatch contributors
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
