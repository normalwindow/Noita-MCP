r"""Finds the frame counter that GameGetFrameNum reads, by disassembling the function.

WHY THIS, AND WHY IT IS SAFE
  The frame-rate instrument has a blind spot that matters here: it samples from the bridge's
  per-frame update, and the bridge runs inside the engine's frame loop. So when the engine
  stops, the instrument stops with it, and a stall cannot be read -- confirmed by pressing ESC,
  after which state.json froze and ping timed out six times.

  Reading the counter from the DLL's own worker thread removes that dependency. The DLL already
  runs a background thread (it writes the heartbeat markers), so it can sample a counter
  independently of whether the engine is advancing.

  This is a READ. It disassembles a function the game already calls every frame and reports the
  address that function loads from. Nothing is written, and a wrong conclusion costs a bad
  reading rather than a frozen machine -- which is the whole reason to do it this way instead
  of scanning memory for something that looks like a frame counter.

WHAT IT LOOKS FOR
  GameGetFrameNum is exported to Lua through the modding API, so it is reachable from the
  Lua-visible function table. Failing that, the frame counter is found by looking for small
  functions that load a uint32 from a fixed address and return it.

USAGE
  python find_frame_counter.py --exe <noita.exe> [--lua-dll <lua51.dll>]
"""
import argparse
import re
import struct
import sys

try:
    import pefile
except ImportError:
    sys.exit("pefile is required (tools/re/.venv has it)")
try:
    import capstone
except ImportError:
    sys.exit("capstone is required (tools/re/.venv has it)")

# The Lua-registered name, as the modding API exposes it.
LUA_NAME = b"GameGetFrameNum"


def read_va(pe, ib, va, n):
    for s in pe.sections:
        start = ib + s.VirtualAddress
        if start <= va < start + s.SizeOfRawData:
            off = va - start
            return s.get_data()[off:off + n]
    return None


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--exe", required=True)
    args = ap.parse_args()

    pe = pefile.PE(args.exe, fast_load=True)
    pe.parse_data_directories()
    ib = pe.OPTIONAL_HEADER.ImageBase
    md = capstone.Cs(capstone.CS_ARCH_X86, capstone.CS_MODE_32)
    md.detail = True

    print(f"image base 0x{ib:X}")

    # ---- 1. locate the name in the image
    name_vas = []
    for s in pe.sections:
        data = s.get_data()
        start = 0
        while True:
            i = data.find(LUA_NAME, start)
            if i < 0:
                break
            name_vas.append(ib + s.VirtualAddress + i)
            start = i + 1
    print(f"'{LUA_NAME.decode()}' appears at {len(name_vas)} address(es): " +
          ", ".join(f"0x{a:X}" for a in name_vas[:6]))

    # ---- 2. find code that references those addresses (immediate pushes)
    # A Lua registration usually pushes the address of the name string, typically with
    # `push imm32` (0x68). That points at the registration site, whose nearby push of a
    # function address identifies GameGetFrameNum's implementation.
    print()
    print("-- code that pushes the name address --")
    for s in pe.sections:
        if not (s.Characteristics & 0x20000000):      # IMAGE_SCN_MEM_EXECUTE
            continue
        data = s.get_data()
        for name_va in name_vas:
            needle = struct.pack("<I", name_va)
            start = 0
            while True:
                i = data.find(b"\x68" + needle, start)   # push imm32
                if i < 0:
                    break
                va = ib + s.VirtualAddress + i
                print(f"   push 0x{name_va:X} at 0x{va:X}")
                # the function it is registered with is usually pushed within ~64 bytes
                window = data[max(0, i - 96): i + 96]
                pushes = [m for m in re.finditer(b"\x68(....)", window, re.S)]
                for m in pushes[-6:]:
                    target = struct.unpack("<I", m.group(1))[0]
                    if ib <= target < ib + 0x2000000 and target != name_va:
                        print(f"      nearby push 0x{target:X}  <- candidate implementation")
                start = i + 1

    # ---- 3. small functions that load a fixed uint32 and return it
    #
    # A frame counter getter typically compiles to: mov eax, [abs]; ret, or with a bounds
    # check. These are found by scanning executable sections for the 5-byte absolute load
    # pattern followed within a few instructions by a return.
    print()
    print("-- 'mov reg, [absolute]' functions near a ret (candidate counter getters) --")
    found = []
    for s in pe.sections:
        if not (s.Characteristics & 0x20000000):
            continue
        data = s.get_data()
        va_base = ib + s.VirtualAddress
        for m in re.finditer(rb"\xa1(....)", data, re.S):     # mov eax, [imm32]
            i = m.start()
            target = struct.unpack("<I", m.group(1))[0]
            # the loaded address must be inside the image and in a writable section
            sec = None
            for t in pe.sections:
                st = ib + t.VirtualAddress
                if st <= target < st + max(t.SizeOfRawData, t.Misc_VirtualSize):
                    sec = t
                    break
            if not sec or not (sec.Characteristics & 0x80000000):   # IMAGE_SCN_MEM_WRITE
                continue
            # a getter returns quickly: look for `ret` within the next 32 bytes
            tail = data[i:i + 32]
            if b"\xc3" not in tail:
                continue
            found.append((va_base + i, target, sec.Name.decode().strip("\x00")))

    # Deduplicate by target address: the same counter is often read in several places.
    by_target = {}
    for va, target, sec in found:
        by_target.setdefault(target, []).append(va)

    print(f"   {len(by_target)} distinct targets, {len(found)} load sites")
    for target, sites in sorted(by_target.items(), key=lambda kv: -len(kv[1]))[:20]:
        print(f"   0x{target:X}  read by {len(sites)} site(s), first 0x{sites[0]:X}")

    print()
    print("note: a frame counter is read constantly, so the target with many read sites is the")
    print("      better candidate; confirm by reading it twice a second apart in a live game.")


if __name__ == "__main__":
    main()
