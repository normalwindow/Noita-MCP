r"""Xrefs that survive disassembly desync.

A linear capstone sweep from the start of .text drifts as soon as it walks into inline data,
a jump table, or inter-function padding, and then it silently misses call sites (verified: it
missed the `call 0x7EFAF0` at 0x7BAA52 that is plainly visible in a targeted disassembly).

So the primary mechanism here is a raw byte scan: for every offset p where data[p] == 0xE8
(call rel32) or 0xE9 (jmp rel32), decode the rel32 and check whether the target matches.  The
scan is independent of instruction alignment, so it cannot desync.  False positives require a
0xE8 byte inside other data whose following 4 bytes happen to equal an exact relative offset;
call sites are additionally reported with a short backward disassembly so they can be checked
by eye.
"""
import struct
import sys
sys.path.insert(0, r"D:\STRARG\GHCode\myNoitaMod\agent\tools\re")
from cellre import Image


def scan_rel(im, targets, opcodes=(0xE8, 0xE9)):
    """Return {target: [(site_va, opcode), ...]} using a positional byte scan."""
    targets = set(targets)
    hits = {t: [] for t in targets}
    for s in im.pe.sections:
        data = s.get_data()
        base = im.ib + s.VirtualAddress
        for i in range(len(data) - 4):
            if data[i] not in opcodes:
                continue
            rel = struct.unpack_from("<i", data, i + 1)[0]
            t = base + i + 5 + rel
            if t in targets:
                hits[t].append((base + i, data[i]))
    for t in hits:
        hits[t] = sorted(set(hits[t]))
    return hits


def scan_data_refs(im, targets, sizes=(4,)):
    """Every occurrence of `target` as a little-endian 4-byte value (struct/table refs)."""
    hits = {t: [] for t in targets}
    for t in targets:
        for va in im.find_bytes(struct.pack("<I", t)):
            hits[t].append(va)
    return hits


if __name__ == "__main__":
    im = Image()
    targets = [int(a, 0) for a in sys.argv[1:]]
    res = scan_rel(im, targets)
    for t in targets:
        sites = res[t]
        print(f"0x{t:X}: {len(sites)} call/jmp site(s)")
        for site, op in sites:
            kind = "call" if op == 0xE8 else "jmp "
            ctx = []
            for ins in im.disasm(site - 32, 40, stop_ret=False):
                if ins.address > site:
                    break
                ctx.append(ins)
            tail = " | ".join(f"{i.mnemonic} {i.op_str}" for i in ctx[-4:])
            print(f"    {kind} @ 0x{site:X}   ... {tail}")
