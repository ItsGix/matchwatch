# SPDX-License-Identifier: GPL-3.0-or-later
# Copyright (C) 2026 ItsGix and the MatchWatch contributors
"""Runs the ping buffer's real bytecode in a small interpreter against invented streams, and checks what
comes out against the ideal: every update sent exactly one buffer after it was due."""
import random, struct, sys
import pb_prog
from pb_prog import *

M = (1 << 64) - 1
def s64(x): return x - (1 << 64) if x >> 63 else x

class VM:
    def __init__(self, asm, t0, b):
        asm.code(); self.ins = [tuple(i) for i in asm.ins]
        self.rel = dict(asm.relocs)
        self.mem = {1: bytearray(256), 2: bytearray(struct.pack("<QQ", t0, b) + b"\0" * 48), 3: bytearray(BSS_SIZE)}
    def rd(self, p, off): seg = p >> 28; o = (p & 0xfffffff) + off; return struct.unpack_from("<Q", self.mem[seg], o)[0]
    def wr(self, p, off, v): seg = p >> 28; o = (p & 0xfffffff) + off; struct.pack_into("<Q", self.mem[seg], o, v & M)
    def run(self, now):
        r = [0] * 11; r[1] = 1 << 28; pc = 0; self.wr(1 << 28, TSTAMP, 0); n = 0
        while True:
            n += 1; assert n < 500
            op, d, s, off, imm = self.ins[pc]; pc += 1
            if op == 0xbf: r[d] = r[s]
            elif op == 0xb7: r[d] = imm & M
            elif op == 0x0f: r[d] = (r[d] + r[s]) & M
            elif op == 0x07: r[d] = (r[d] + imm) & M
            elif op == 0x1f: r[d] = (r[d] - r[s]) & M
            elif op == 0x3f: r[d] = (r[d] // r[s]) if r[s] else 0
            elif op == 0x87: r[d] = (-r[d]) & M
            elif op == 0x77: r[d] = r[d] >> imm
            elif op == 0x67: r[d] = (r[d] << imm) & M
            elif op == 0x79: r[d] = self.rd(r[s], off)
            elif op == 0x7b: self.wr(r[d], off, r[s])
            elif op == 0x7a: self.wr(r[d], off, imm)
            elif op == 0x85: assert imm == 5; r[0] = now
            elif op == 0x95: assert r[0] == 3; return self.rd(1 << 28, TSTAMP)
            elif op == 0x18: r[d] = ((2 if self.rel[pc - 1] == ".data" else 3) << 28) + imm; pc += 1
            elif op == 0x05: pc += off
            else:
                a = r[d]; b = r[s] if op & 8 else imm & M
                t = {0x10: a == b, 0x50: a != b, 0x20: a > b, 0x30: a >= b, 0xa0: a < b, 0xb0: a <= b,
                     0x70: s64(a) >= s64(b), 0xc0: s64(a) < s64(b), 0x60: s64(a) > s64(b)}[op & 0xf0]
                assert op & 7 == 5, hex(op)
                if t: pc += off
    def stat(self, off): return self.rd(3 << 28, off)

def stream(hz, secs, jit=0.0003, loss=0.0, clump=None, per_tick=1, spike=None, step=None, seed=7):
    """returns [(arrival ns, due ns)]: due is when it would arrive on a perfect line"""
    random.seed(seed); out = []; C = 0.004
    for i in range(int(secs * hz)):
        ts = 10.0 + i / hz
        if random.random() < loss: continue
        late = abs(random.gauss(0, jit))
        if spike and random.random() < spike[0]: late += random.uniform(0, spike[1])
        arr = ts + C + late
        if clump:
            ph = ts % clump[0]
            if ph < clump[1]: arr = ts - ph + clump[1] + C + random.random() * 0.0002
        if step and ts > step[0]: arr += step[1]; due_shift = step[1]
        else: due_shift = 0
        for p in range(per_tick):
            out.append((int((arr + p * 0.00005) * 1e9), int((ts + C + due_shift) * 1e9)))
    out.sort()
    return out

def run(name, pk, t0_ms, b_ms, quiet=False):
    vm = VM(pb_prog.build(), int(t0_ms * 1e6), int(b_ms * 1e6)); B = int(b_ms * 1e6)
    last = 0; res = []
    for arr, due in pk:
        ts = vm.run(arr); rel = ts if ts else arr
        assert rel >= arr, "sent before it arrived"
        assert rel - arr <= B, "held longer than the buffer"
        assert rel >= last, "out of order"
        last = rel; res.append((arr, due, rel))
    skip = [x for x in res if x[1] > res[0][1] + 3_000_000_000]      # let it settle for three seconds
    inlate = [a - d for a, d, r in skip]; outdev = [r - (d + B) for a, d, r in skip]
    could = sum(1 for x in inlate if x <= B)
    good = sum(1 for (a, d, r), x, o in zip(skip, inlate, outdev) if x <= B and abs(o) <= 1_500_000)
    early = sum(1 for (a, d, r), x, o in zip(skip, inlate, outdev) if o < -1_500_000)
    lateout = sum(1 for (a, d, r), x, o in zip(skip, inlate, outdev) if x <= B and o > 1_500_000)
    hold = sum(r - a for a, d, r in skip) / len(skip) / 1e6
    # how uneven the beat is going in, and coming out (mean gap error against the true beat, ticks only)
    def rough(ts):
        g = [b - a for a, b in zip(ts, ts[1:]) if b - a > 2_000_000]
        g.sort(); med = g[len(g) // 2]; return sum(abs(x - med) for x in g) / len(g) / 1e6
    rin = rough([a for a, d, r in skip]); rout = rough([r for a, d, r in skip])
    line = "%-34s B=%2d  hold %5.1f ms  on the beat %5.1f%% of those it could (%d early, %d late)  uneven in %.2f out %.2f ms  resync %d  beat %.3f ms" % (
        name, b_ms, hold, 100.0 * good / max(1, could), early, lateout, rin, rout, vm.stat(N_RESYNC), vm.stat(T) / 1e6)
    if not quiet: print(line)
    return 100.0 * good / max(1, could), early, rin, rout

if __name__ == "__main__":
    for b in (10, 25):
        run("clean 60/s", stream(60, 60), 16.7, b)
        run("clean 60/s, beat measured short", stream(60, 60), 16.6, b)
        run("clean 21/s", stream(21, 60, jit=0.0014), 47.6, b)
        run("jitter 4 ms", stream(60, 60, jit=0.004), 16.7, b)
        run("spikes: 5% up to 20 ms", stream(60, 60, spike=(0.05, 0.02)), 16.7, b)
        run("stall 40 ms every 2 s", stream(60, 60, clump=(2.0, 0.04)), 16.7, b)
        run("stall 80 ms every 2 s", stream(60, 60, clump=(2.0, 0.08)), 16.7, b)
        run("2% lost", stream(60, 60, loss=0.02), 16.7, b)
        run("two packets an update, 3% lost", stream(60, 60, per_tick=2, loss=0.03), 16.7, b)
        run("path 12 ms longer after 30 s", stream(60, 60, step=(40.0, 0.012)), 16.7, b)
        run("128/s", stream(128, 60, jit=0.0002), 7.8, b)
        print()
