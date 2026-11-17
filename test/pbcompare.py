# SPDX-License-Identifier: GPL-3.0-or-later
# Copyright (C) 2026 ItsGix and the MatchWatch contributors
"""Compares a match's stream before and after the ping buffer, from a capture taken on the router.

The buffer's own counters say packets are being held; they do not say the stream is better. This does:
it is the test that caught the buffer making a real match worse. On the router, while a match is held
(both captures end by themselves; never end one with killall, which stops MatchWatch's own capture):

    read rip rport lip lport < /tmp/matchwatch/pb.flow
    (tcpdump -i <wan port> -tt -n -q -l -c 3000 udp and src port $rport | cut -d" " -f1,3,8 > /tmp/pre.txt &)
    tcpdump -i <lan port> -tt -n -q -l -c 3000 udp and src port $rport and dst host $lip | cut -d" " -f1,3,8 > /tmp/post.txt
    (echo ====; cat /tmp/pre.txt; echo ====; cat /tmp/post.txt) > capture.txt; rm /tmp/pre.txt /tmp/post.txt

    python test/pbcompare.py capture.txt [buffer in ms]

It prints who sent what (senders are lettered, never shown), how even the updates were on each side, and,
given a buffer size, what the program in bpf/ makes of the same arrivals offline. A capture holds real
server addresses: keep it out of the repository.
"""
import collections, os, sys
parts = open(sys.argv[1]).read().split("====\n")
def load(t):
    out = []
    for l in t.strip().split("\n"):
        f = l.split()
        if len(f) == 3: out.append((float(f[0]), f[1].rsplit(".", 1)[0], int(f[2])))
    return out
pre, post = load(parts[1]), load(parts[2])
names = {}
def who(a): return names.setdefault(a, "sender " + "ABCDEFGHIJKLMNOP"[min(len(names), 15)])
t0 = pre[0][0]
def updates(p):   # the first packet of each update: packets under 3 ms apart belong together
    return [p[0][0]] + [b[0] for a, b in zip(p, p[1:]) if (b[0] - a[0]) * 1000 >= 3]
for label, p in (("before the buffer", pre), ("after the buffer ", post)):
    c = collections.Counter(who(x[1]) for x in p)
    runs = []
    for t, a, l in p:
        if runs and runs[-1][0] == who(a): runs[-1][2] = t; runs[-1][3] += 1
        else: runs.append([who(a), t, t, 1])
    tt = updates(p); g = [(b - a) * 1000 for a, b in zip(tt, tt[1:])]; s = sorted(g); med = s[len(s) // 2]
    print("%s: %d packets over %.0f s (%s)" % (label, len(p), p[-1][0] - p[0][0], ", ".join("%s %d" % kv for kv in sorted(c.items()))))
    print("   carried the match: " + "; ".join("%s %.0f-%.0f s" % (r[0], r[1] - t0, r[2] - t0) for r in runs if r[3] >= 20))
    print("   %d updates, %.2f packets each, beat %.2f ms, uneven by %.2f ms, gaps 3 ms or more off the beat: %d, 10 or more: %d, longest %.0f ms, shortest %.0f ms" % (
        len(tt), len(p) / len(tt), med, sum(abs(x - med) for x in g) / len(g), sum(1 for x in g if abs(x - med) >= 3), sum(1 for x in g if abs(x - med) >= 10), max(g), min(g)))
if len(sys.argv) > 2:
    sys.path.insert(0, os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "bpf"))
    import pb_prog, pb_test
    from pb_prog import N_RESYNC, N_LATE, N_SWITCH, SUM_HOLD, N_HELD, N_OTHER, BYPASS, T
    b = int(float(sys.argv[2]) * 1e6); ids = {}
    tt = updates(pre); g = sorted((y - x) for x, y in zip(tt, tt[1:])); seed = int(g[len(g) // 2] * 1e9)
    vm = pb_test.VM(pb_prog.build(), seed, b); rel = []; last = 0
    for t, a, l in pre:
        arr = int((t - t0 + 100) * 1e9); ts = vm.run(arr, ids.setdefault(a, len(ids) + 1)); r = ts if ts else max(arr, last); last = r; rel.append(r / 1e9)
    tk = [rel[0]] + [y for x, y in zip(rel, rel[1:]) if (y - x) * 1000 >= 3]; g = [(y - x) * 1000 for x, y in zip(tk, tk[1:])][60:]; m = sorted(g)[len(g) // 2]
    held = vm.stat(N_HELD) - vm.stat(N_OTHER)
    print("the program on the same arrivals, offline, at %s ms: beat %.2f ms, uneven by %.2f ms, gaps 3 ms or more off: %d | lost the beat %d times, %d later than the buffer, mean hold %.1f ms, moves %d, stepped aside: %s" % (
        sys.argv[2], vm.stat(T) / 1e6, sum(abs(x - m) for x in g) / len(g), sum(1 for x in g if abs(x - m) >= 3), vm.stat(N_RESYNC), vm.stat(N_LATE),
        vm.stat(SUM_HOLD) / max(1, held) / 1e6, vm.stat(N_SWITCH), "yes" if vm.stat(BYPASS) else "no"))
