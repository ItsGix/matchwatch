# SPDX-License-Identifier: GPL-3.0-or-later
# Copyright (C) 2026 ItsGix and the MatchWatch contributors
"""A stand-in for a game stream, for testing the ping buffer on a router with no game and no outside host.

It sends DNS questions to the router on a beat (made uneven on purpose if asked) and times the answers. The
answers are the "server's updates": they leave the router for this computer, which is where the buffer acts.
The question is for the router's own name, which it answers by itself; a router answers only about twenty a
second, so keep the rate at 16 or so. One thread, polling, so the times are good to a few microseconds.

    python test/pbrig.py <router address> <a second> <seconds> clean|jitter|spikes|stall

On the router, hold this stream the way the engine would hold a match (62500 is the beat in microseconds
for 16 a second; 47321 is the port this script listens on):

    matchwatch buffer hold 25
    matchwatch _pb <router address> 53 <this computer's address> 47321 62500
    ... run this script ...
    matchwatch buffer status
    matchwatch _pbstop

Give `_pb` a wrong beat (56000, 68000) to see the program find the real one. A service with a match in
progress will take the buffer over within a minute, so use it when nobody is playing.
"""
import random, socket, struct, sys, time
router, hz, secs, mode = sys.argv[1], float(sys.argv[2]), float(sys.argv[3]), sys.argv[4]
PORT = 47321
s = socket.socket(socket.AF_INET, socket.SOCK_DGRAM); s.bind(("", PORT)); s.setblocking(False)
NAME = b"".join(bytes([len(p)]) + p.encode() for p in reversed(router.split("."))) + b"\x07in-addr\x04arpa\x00"
def q(i): return struct.pack(">HHHHHH", i, 0x0100, 1, 0, 0, 0) + NAME + struct.pack(">HH", 12, 1)
n = int(hz * secs); sent = {}; got = {}
def poll():
    try:
        d, _ = s.recvfrom(600); got.setdefault(struct.unpack(">H", d[:2])[0], time.perf_counter())
    except BlockingIOError: pass
random.seed(3); t0 = time.perf_counter() + 0.2
for i in range(n):
    ideal = t0 + i / hz; x = 0.0
    if mode == "jitter": x = abs(random.gauss(0, 0.006))
    elif mode == "spikes" and random.random() < 0.08: x = random.uniform(0.005, 0.030)
    elif mode == "stall":
        ph = (i / hz) % 2.0
        if ph < 0.15: x = 0.15 - ph      # a stall of 150 ms every two seconds: the held ones go out together
    while time.perf_counter() < ideal + x: poll()
    s.sendto(q(i), (router, 53)); sent[i] = time.perf_counter()
end = time.perf_counter() + 0.6
while time.perf_counter() < end: poll()
first = int(3 * hz)
ids = [i for i in range(first, n) if i in got]
rtt = sorted(got[i] - sent[i] for i in ids)
dev_in = [sent[i] - (t0 + i / hz) for i in ids]
dev_out = [got[i] - (t0 + i / hz) for i in ids]
base = min(dev_out)
def mad(v): m = sorted(v)[len(v) // 2]; return 1000 * sum(abs(x - m) for x in v) / len(v)
order = sum(1 for a, b in zip(ids, ids[1:]) if got[b] < got[a])
print("%-6s %g/s: %d of %d answered | delay through the router: median %.1f ms (least %.1f, most %.1f) | sent late: mean %.1f, most %.1f ms | arrived uneven by %.2f ms (worst %.1f after the earliest) | out of order %d" % (
    mode, hz, len(ids), n - first, 1000 * rtt[len(rtt) // 2], 1000 * rtt[0], 1000 * rtt[-1],
    1000 * sum(dev_in) / len(dev_in), 1000 * max(dev_in), mad(dev_out), 1000 * (max(dev_out) - base), order))
