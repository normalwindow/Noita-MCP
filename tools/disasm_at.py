r"""Disassembles candidate implementations of GameGetFrameNum.

The function is the frame counter's reader, so its body says where the counter lives. A
getter of this kind compiles to very little -- load a global, maybe clamp, return -- so the
disassembly is short enough to read and the answer is unambiguous.

This is a read. Whatever it reports is used to sample a counter from the DLL's worker thread;
nothing is written.
"""
import argparse
import sys

try:
    import pefile
except ImportError:
    sys.exit("pefile is required (tools/re/.venv has it)")
try:
    import capstone
except ImportError:
    sys.exit("capstone is required (tools/re/.venv has it)")


def read_va(pe, ib, va, n):
    for s in pe.sections:
        start = ib + s.VirtualAddress
        size = max(s.SizeOfRawData, s.Misc_VirtualSize)
        if start <= va < start + size:
            off = va - start
            return s.get_data()[off:off + n]
    return None


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--exe", required=True)
    ap.add_argument("--at", action="append", required=True,
                    help="virtual address to disassemble, repeatable")
    ap.add_argument("--bytes", type=int, default=80)
    args = ap.parse_args()

    pe = pefile.PE(args.exe, fast_load=True)
    ib = pe.OPTIONAL_HEADER.ImageBase
    md = capstone.Cs(capstone.CS_ARCH_X86, capstone.CS_MODE_32)
    md.detail = True

    for spec in args.at:
        va = int(spec, 0)
        data = read_va(pe, ib, va, args.bytes)
        print("=" * 74)
        if not data:
            print(f"0x{va:X}: not mapped")
            continue
        print(f"0x{va:X}")
        print("=" * 74)

        # Track absolute memory operands: those are where a global lives.
        globals_touched = []
        for ins in md.disasm(data, va):
            line = f"  0x{ins.address:X}  {ins.bytes.hex(' '):<20} {ins.mnemonic} {ins.op_str}"
            print(line)
            for op in ins.operands:
                if op.type == capstone.x86.X86_OP_MEM and op.mem.base == 0 and op.mem.index == 0:
                    target = op.mem.disp
                    # only plausible image addresses
                    if ib <= target < ib + 0x10000000:
                        globals_touched.append((ins.address, target, ins.mnemonic))
                        print(f"        -> absolute operand 0x{target:X}")
            if ins.mnemonic in ("ret", "retn") or ins.mnemonic.startswith("ret "):
                break
            if ins.mnemonic == "int3":
                break

        print()
        if globals_touched:
            print("   absolute addresses touched (candidate counter locations):")
            for site, target, mnem in globals_touched:
                print(f"     0x{target:X}   used at 0x{site:X} ({mnem})")
        else:
            print("   no absolute operand -- not a simple global getter")
        print()


if __name__ == "__main__":
    main()
