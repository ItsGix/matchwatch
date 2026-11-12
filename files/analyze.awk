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
		HOPJ = ""; if ((getline HOPJ < (RUN "/probe." F_sid[f] "/hops.json")) <= 0) HOPJ = ""
		close(RUN "/probe." F_sid[f] "/hops.json")
		if (HOPJ !~ /^\[.*\]$/) HOPJ = ""
		close(RUN "/probe." F_sid[f] "/qm.json")
		TRN = 0
		while ((getline trl < (RUN "/probe." F_sid[f] "/trace")) > 0) if (trl ~ /^ *[0-9]+ /) TR[++TRN] = clean(trl)
		close(RUN "/probe." F_sid[f] "/trace")
	} else { TRN = 0; QM = ""; HOPJ = ""; if (PROBESUM != "") load_sum(PROBESUM) }

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
		if (HOPJ != "") dj = dj ",\"hopstats\":" HOPJ
		if (PS["hop_note"] != "") dj = dj ",\"hopnote\":" js(PS["hop_note"])
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
