# SPDX-License-Identifier: GPL-3.0-or-later
# Copyright (C) 2026 ItsGix and the MatchWatch contributors
"""A very small eBPF assembler and ELF writer: enough to make an object libbpf will load, with one
program section, a .data and a .bss section (which libbpf turns into two array maps), and a licence."""
import struct

R0, R1, R2, R3, R4, R5, R6, R7, R8, R9, R10 = range(11)

class Asm:
    def __init__(self):
        self.ins = []      # (opcode, dst, src, off, imm) or ("label", name)
        self.relocs = []   # (insn index, section name)
        self.labels = {}
        self.fix = []      # (insn index, label)
    def _e(self, op, dst=0, src=0, off=0, imm=0): self.ins.append([op, dst, src, off, imm]); return len(self.ins) - 1
    def label(self, name): self.labels[name] = len(self.ins)
    # 64-bit arithmetic: reg and immediate forms
    def mov(self, d, s): self._e(0xbf, d, s)
    def movi(self, d, i): self._e(0xb7, d, 0, 0, i)
    def add(self, d, s): self._e(0x0f, d, s)
    def addi(self, d, i): self._e(0x07, d, 0, 0, i)
    def sub(self, d, s): self._e(0x1f, d, s)
    def mul(self, d, s): self._e(0x2f, d, s)
    def div(self, d, s): self._e(0x3f, d, s)       # unsigned
    def rshi(self, d, i): self._e(0x77, d, 0, 0, i)
    def lshi(self, d, i): self._e(0x67, d, 0, 0, i)
    def ld64(self, d, s, off): self._e(0x79, d, s, off)     # d = *(u64 *)(s + off)
    def st64(self, d, off, s): self._e(0x7b, d, s, off)     # *(u64 *)(d + off) = s
    def st64i(self, d, off, i): self._e(0x7a, d, 0, off, i)
    def call(self, helper): self._e(0x85, 0, 0, 0, helper)
    def exit(self): self._e(0x95)
    def addr(self, d, section, off=0):                      # d = address of section + off (two instructions)
        i = self._e(0x18, d, 0, 0, off); self._e(0, 0, 0, 0, 0); self.relocs.append((i, section))
    def _j(self, op, d, s, imm, label): self.fix.append((self._e(op, d, s, 0, imm), label))
    def ja(self, label): self._j(0x05, 0, 0, 0, label)
    # unsigned compares, register against register
    def jeq(self, d, s, l): self._j(0x1d, d, s, 0, l)
    def jne(self, d, s, l): self._j(0x5d, d, s, 0, l)
    def jgt(self, d, s, l): self._j(0x2d, d, s, 0, l)
    def jge(self, d, s, l): self._j(0x3d, d, s, 0, l)
    def jlt(self, d, s, l): self._j(0xad, d, s, 0, l)
    def jle(self, d, s, l): self._j(0xbd, d, s, 0, l)
    def jsgt(self, d, s, l): self._j(0x6d, d, s, 0, l)     # signed
    def jslt(self, d, s, l): self._j(0xcd, d, s, 0, l)
    def jsge(self, d, s, l): self._j(0x7d, d, s, 0, l)
    def jsgei(self, d, i, l): self._j(0x75, d, 0, i, l)
    def neg(self, d): self._e(0x87, d)
    def jeqi(self, d, i, l): self._j(0x15, d, 0, i, l)
    def jnei(self, d, i, l): self._j(0x55, d, 0, i, l)
    def jsgti(self, d, i, l): self._j(0x65, d, 0, i, l)
    def jslti(self, d, i, l): self._j(0xc5, d, 0, i, l)
    def code(self, big=False):
        for i, l in self.fix: self.ins[i][3] = self.labels[l] - i - 1
        out = b""
        for op, d, s, off, imm in self.ins:
            reg = (d << 4 | s) if big else (s << 4 | d)
            out += struct.pack((">" if big else "<") + "BBhi", op, reg, off, imm)
        return out

def elf(prog_sec, func, code, relocs, data, bss_size, big=False):
    E = ">" if big else "<"
    names = ["", prog_sec, ".rel" + prog_sec, ".data", ".bss", "license", ".symtab", ".strtab", ".shstrtab"]
    shstr = b""; shoff = {}
    for n in names: shoff[n] = len(shstr); shstr += n.encode() + b"\0"
    strtab = b"\0" + func.encode() + b"\0"
    # symbols: null, section .data (3), section .bss (4), then the global function
    def sym(name, info, shndx, value, size): return struct.pack(E + "IBBHQQ", name, info, 0, shndx, value, size)
    symtab = sym(0, 0, 0, 0, 0) + sym(0, 3, 3, 0, 0) + sym(0, 3, 4, 0, 0) + sym(1, 0x12, 1, 0, len(code))
    symidx = {".data": 1, ".bss": 2}
    rel = b"".join(struct.pack(E + "QQ", i * 8, (symidx[s] << 32) | 1) for i, s in relocs)
    lic = b"GPL\0"
    body = [None, code, rel, data, b"", lic, symtab, strtab, shstr]
    types = [0, 1, 9, 1, 8, 1, 2, 3, 3]
    flags = [0, 6, 0, 3, 3, 3, 0, 0, 0]
    link = [0, 0, 6, 0, 0, 0, 7, 0, 0]
    info = [0, 0, 1, 0, 0, 0, 3, 0, 0]
    ents = [0, 0, 16, 0, 0, 0, 24, 0, 0]
    align = [0, 8, 8, 8, 8, 1, 8, 1, 1]
    off = 64; blob = b""; hdrs = []
    for i, n in enumerate(names):
        if i == 0: hdrs.append(struct.pack(E + "IIQQQQIIQQ", 0, 0, 0, 0, 0, 0, 0, 0, 0, 0)); continue
        pad = (-off) % align[i]; blob += b"\0" * pad; off += pad
        size = bss_size if n == ".bss" else len(body[i])
        hdrs.append(struct.pack(E + "IIQQQQIIQQ", shoff[n], types[i], flags[i], 0, off, size, link[i], info[i], align[i], ents[i]))
        if n != ".bss": blob += body[i]; off += len(body[i])
    pad = (-off) % 8; blob += b"\0" * pad; off += pad
    ident = b"\x7fELF" + bytes([2, 2 if big else 1, 1, 0]) + b"\0" * 8
    hdr = ident + struct.pack(E + "HHIQQQIHHHHHH", 1, 247, 1, 0, 0, off, 0, 64, 0, 0, 64, len(names), len(names) - 1)
    return hdr + blob + b"".join(hdrs)
