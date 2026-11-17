# SPDX-License-Identifier: GPL-3.0-or-later
# Copyright (C) 2026 ItsGix and the MatchWatch contributors
"""The ping buffer's kernel program, assembled by hand (no compiler needed).

It runs on each packet of one game stream going to the gaming device, and writes into the packet the time
it should be sent on (skb->tstamp); an fq queue then holds it until then. The server sends on a steady beat,
so the program keeps a grid of when each update is due, holds an on-time update for the whole buffer and a
late one for less, and lets one later than the buffer straight through.

.data (set from outside):  0 T0, the server's beat in ns (0: do nothing)   8 B, the buffer in ns (0: do nothing)
.bss  (kept by the program): see the offsets below; the counters are read from outside for the match report.
"""
from bpfasm import *

G, LAST_ARR, LAST_REL, T, E_PREV, WIN_N, WIN_MIN, SPARE, C_LATE = 0, 8, 16, 24, 32, 40, 48, 56, 64
N_PKTS, N_HELD, N_LATE, SUM_HOLD, MAX_E, N_RESYNC, N_SAME = 72, 80, 88, 96, 104, 112, 120
SLOT, W_TMIN, W_SMIN, P_TMIN, P_SMIN = 128, 136, 144, 152, 160
BSS_SIZE = 176
TSTAMP = 152          # offsetof(struct __sk_buff, tstamp)
WIN = 32              # updates per correction window
MAXB = 200_000_000    # the program never holds longer than this, whatever it is told

def build():
    a = Asm()
    def inc(off):
        a.ld64(R1, R9, off); a.addi(R1, 1); a.st64(R9, off, R1)
    a.mov(R6, R1)
    a.call(5)                               # bpf_ktime_get_ns
    a.mov(R7, R0)                           # r7 = now
    a.addr(R8, ".data")
    a.addr(R9, ".bss")
    inc(N_PKTS)
    a.ld64(R5, R8, 8)                       # r5 = B
    a.jeqi(R5, 0, "out")
    a.movi(R1, MAXB); a.jle(R5, R1, "okb"); a.mov(R5, R1)
    a.label("okb")
    a.ld64(R4, R9, T)                       # r4 = T
    a.ld64(R3, R8, 0); a.jeqi(R3, 0, "out")
    # no beat yet, or the engine has measured a different one (lobby to match): start again from its figure
    a.jeqi(R4, 0, "sett0")
    a.mov(R1, R3); a.rshi(R1, 4); a.mov(R2, R3); a.add(R2, R1); a.jgt(R4, R2, "sett0")
    a.mov(R2, R3); a.sub(R2, R1); a.jge(R4, R2, "havet")
    a.label("sett0")
    a.mov(R4, R3); a.st64(R9, T, R4); a.st64i(R9, G, 0)
    a.label("havet")
    a.ld64(R1, R9, LAST_ARR); a.mov(R3, R7); a.sub(R3, R1); a.st64(R9, LAST_ARR, R7)   # r3 = gap
    a.ld64(R2, R9, G)                       # r2 = g
    a.jeqi(R2, 0, "init")
    a.movi(R1, 500_000_000); a.jgt(R3, R1, "init")
    # a second packet of the same update: it follows at once, and the one before was not late
    a.mov(R1, R4); a.rshi(R1, 3); a.jge(R3, R1, "tick")
    a.ld64(R0, R9, E_PREV); a.mov(R1, R4); a.rshi(R1, 1); a.jsge(R0, R1, "tick")
    inc(N_SAME)
    a.ld64(R1, R9, LAST_REL)
    a.ja("emit")

    a.label("init")                          # first packet, or the stream paused: start the grid here
    a.st64(R9, G, R7); a.st64i(R9, E_PREV, 0); a.st64i(R9, WIN_N, 0); a.st64i(R9, C_LATE, 0); a.st64i(R9, P_TMIN, 0)
    a.movi(R1, 1); a.lshi(R1, 60); a.st64(R9, WIN_MIN, R1)
    a.mov(R1, R7); a.add(R1, R5)
    a.ja("emit")

    a.label("tick")
    a.add(R2, R4)                           # the next update is due one beat on
    inc(SLOT)
    a.mov(R0, R7); a.sub(R0, R2)            # r0 = e, how late this one is (signed)
    a.jsgei(R0, 0, "nonneg")
    # earlier than the grid: the grid was late, so move it here. Over half a beat early means the count ran ahead
    a.mov(R1, R0); a.neg(R1)
    a.mov(R0, R4); a.rshi(R0, 1); a.jle(R1, R0, "zeroe")
    a.label("lost")
    inc(N_RESYNC)
    # the count of updates is no longer trustworthy across this point: measure the beat afresh from here
    a.st64i(R9, P_TMIN, 0); a.st64i(R9, WIN_N, 0)
    a.movi(R1, 1); a.lshi(R1, 60); a.st64(R9, WIN_MIN, R1)
    a.label("zeroe")
    a.mov(R2, R7); a.movi(R0, 0)
    a.ja("havee")

    a.label("nonneg")
    a.movi(R1, 250_000_000); a.jgt(R0, R1, "init")
    a.ld64(R1, R9, MAX_E); a.jle(R0, R1, "m1"); a.st64(R9, MAX_E, R0)
    a.label("m1")
    # three in a row over half a beat late, arriving at the normal spacing: an update was lost and the
    # count slipped, or the path got longer. Either way these are on time: move the grid to them.
    a.mov(R1, R4); a.rshi(R1, 1)
    a.jle(R0, R1, "c0"); a.jle(R3, R1, "c0")
    a.ld64(R1, R9, C_LATE); a.addi(R1, 1); a.st64(R9, C_LATE, R1)
    a.jslti(R1, 3, "havee")
    a.st64i(R9, C_LATE, 0)
    a.ja("lost")
    a.label("c0")
    a.st64i(R9, C_LATE, 0)

    a.label("havee")                         # r0 = e (0 or more), r2 = g
    a.ld64(R1, R9, WIN_MIN); a.jge(R0, R1, "w1")
    a.st64(R9, WIN_MIN, R0); a.mov(R1, R0)   # the least late update of this window: remember when it came
    a.st64(R9, W_TMIN, R7); a.ld64(R3, R9, SLOT); a.st64(R9, W_SMIN, R3)
    a.label("w1")                            # r1 = the least lateness in this window
    a.ld64(R3, R9, WIN_N); a.addi(R3, 1); a.st64(R9, WIN_N, R3)
    a.jslti(R3, WIN, "wdone")
    a.st64i(R9, WIN_N, 0)
    # every update in the window was at least r1 late: the grid is early by that, so move it
    a.add(R2, R1); a.sub(R0, R1)
    a.st64(R9, G, R2); a.st64(R9, E_PREV, R0)
    # the beat, measured between the least late update of the last window and of this one
    a.ld64(R1, R9, P_TMIN); a.jeqi(R1, 0, "nobeat")
    a.ld64(R3, R9, W_TMIN); a.sub(R3, R1)
    a.ld64(R1, R9, W_SMIN); a.ld64(R0, R9, P_SMIN); a.jle(R1, R0, "nobeat"); a.sub(R1, R0)
    a.div(R3, R1)                            # r3 = the measured beat
    a.ld64(R0, R8, 0); a.mov(R2, R0); a.rshi(R2, 5)       # only believed within 3% of what the engine measured
    a.mov(R1, R0); a.add(R1, R2); a.jgt(R3, R1, "nobeat")
    a.sub(R0, R2); a.jlt(R3, R0, "nobeat")
    a.jge(R3, R4, "up")
    a.mov(R1, R4); a.sub(R1, R3); a.rshi(R1, 2); a.sub(R4, R1)
    a.ja("sett")
    a.label("up")
    a.sub(R3, R4); a.rshi(R3, 2); a.add(R4, R3)
    a.label("sett")
    a.st64(R9, T, R4)
    a.label("nobeat")
    a.ld64(R1, R9, W_TMIN); a.st64(R9, P_TMIN, R1); a.ld64(R1, R9, W_SMIN); a.st64(R9, P_SMIN, R1)
    a.movi(R1, 1); a.lshi(R1, 60); a.st64(R9, WIN_MIN, R1)
    a.ld64(R2, R9, G); a.ld64(R0, R9, E_PREV)
    a.label("wdone")
    a.st64(R9, G, R2); a.st64(R9, E_PREV, R0)
    a.jle(R0, R5, "nl")
    inc(N_LATE)
    a.label("nl")
    a.mov(R1, R2); a.add(R1, R5)            # send it one buffer after it was due

    a.label("emit")                          # r1 = when to send
    a.ld64(R0, R9, LAST_REL)
    a.jge(R1, R0, "e1"); a.mov(R1, R0)      # never before the one in front
    a.label("e1")
    a.jgt(R1, R7, "e2")
    a.st64(R9, LAST_REL, R7)                 # due already: no hold
    a.ja("out")
    a.label("e2")
    a.mov(R0, R1); a.sub(R0, R7)            # r0 = the hold
    a.jle(R0, R5, "e3"); a.mov(R1, R7); a.add(R1, R5); a.mov(R0, R5)   # never longer than the buffer
    a.label("e3")
    a.st64(R9, LAST_REL, R1)
    a.st64(R6, TSTAMP, R1)
    a.ld64(R2, R9, N_HELD); a.addi(R2, 1); a.st64(R9, N_HELD, R2)
    a.ld64(R2, R9, SUM_HOLD); a.add(R2, R0); a.st64(R9, SUM_HOLD, R2)
    a.label("out")
    a.movi(R0, 3)                            # TC_ACT_PIPE: go on to the next action
    a.exit()
    return a

if __name__ == "__main__":
    import sys
    a = build()
    obj = elf("mwpb", "mw_pb", a.code(), a.relocs, b"\0" * 64, BSS_SIZE)
    if sys.argv[1] == "--oct":      # as text for the installer: the router turns it back into the object with printf
        open(sys.argv[2], "w", newline="\n").write("".join("\\%03o" % b for b in obj) + "\n")
    else: open(sys.argv[1], "wb").write(obj)
    print("wrote", sys.argv[-1], len(a.ins), "instructions,", len(obj), "bytes")
