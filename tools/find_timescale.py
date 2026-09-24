r"""Static analysis for Noita's time delta, as a first step before any memory write.

The question: the Lua API has no time-scale setter, so the only route is memory. Before
touching memory, find out whether there is a single, identifiable value to touch -- and
whether writing it could plausibly work.

WHAT THIS LOOKS FOR
  1. Float constants that look like a frame delta (1/60 = 0.0166667, and its neighbours).
     A timescale multiply usually references such a literal.
  2. Strings that name the concept (timescale, time_scale, slowmo, game_speed...), which
     point at the code that reads them.
  3. The import table, for functions that reveal how the engine keeps time
     (QueryPerformanceCounter, timeGetTime, SDL_GetTicks).

WHAT IT DELIBERATELY DOES NOT DO
  It does not write anything, and it does not produce a candidate address to patch. A
  xref to a float constant is where a value is READ, not necessarily where the game's
  authoritative clock lives; concluding otherwise is how a wrong write gets made.
"""
import argparse
import collections
import struct
import sys

try:
    import pefile
except ImportError:
    sys.exit("pefile is required: tools/re/.venv has it")

try:
    import capstone
except ImportError:
    sys.exit("capstone is required: tools/re/.venv has it")

INTERESTING_STRINGS = [
    "timescale", "time_scale", "Timescale", "TimeScale", "time scale",
    "slowmo", "slow_mo", "slow-motion", "slow motion",
    "game_speed", "gamespeed", "game speed",
    "fixed_timestep", "timestep", "time_step", "fixed_dt", "delta_time", "deltatime",
    "physics_dt", "frame_time", "time_scale_multiplier", "global_time",
]

TIMING_IMPORTS = [
    "QueryPerformanceCounter", "QueryPerformanceFrequency", "timeGetTime",
    "GetTickCount", "GetTickCount64", "SDL_GetTicks", "SDL_GetPerformanceCounter",
    "SDL_Delay", "Sleep", "GetSystemTimeAsFileTime",
]


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--exe", required=True, help="path to noita.exe")
    ap.add_argument("--dll", help="optional second binary to scan (e.g. SDL2.dll)")
    ap.add_argument("--max-hits", type=int, default=40)
    args = ap.parse_args()

    targets = [args.exe] + ([args.dll] if args.dll else [])
    for path in targets:
        print("=" * 78)
        print(path)
        print("=" * 78)
        scan(path, args.max_hits)
        print()


def scan(path, max_hits):
    pe = pefile.PE(path, fast_load=True)
    pe.parse_data_directories()
    ib = pe.OPTIONAL_HEADER.ImageBase
    image_end = max(s.VirtualAddress + s.SizeOfRawData for s in pe.sections)

    # ---------------------------------------------------------------- imports
    print("-- timing-related imports --")
    found_imports = []
    for entry in getattr(pe, "DIRECTORY_ENTRY_IMPORT", []) or []:
        dll = entry.dll.decode(errors="replace")
        for imp in entry.imports:
            if not imp.name:
                continue
            name = imp.name.decode(errors="replace")
            if name in TIMING_IMPORTS:
                found_imports.append(f"{dll}!{name} @ IAT 0x{imp.address:X}")
    if found_imports:
        for f in found_imports:
            print("   " + f)
    else:
        print("   (none -- the engine may keep time through SDL only)")

    # ---------------------------------------------------------------- strings
    print()
    print("-- strings naming the concept --")
    hits = 0
    for s in pe.sections:
        data = s.get_data()
        for needle in INTERESTING_STRINGS:
            b = needle.encode()
            start = 0
            while True:
                i = data.find(b, start)
                if i < 0:
                    break
                # must be a whole C string, not a fragment of a longer identifier
                before = data[i - 1] if i > 0 else 0
                after = data[i + len(b)] if i + len(b) < len(data) else 0
                if not (chr(before).isalnum() or before == 0x5F) and after == 0:
                    va = ib + s.VirtualAddress + i
                    print(f"   {needle!r} @ 0x{va:X}")
                    hits += 1
                    if hits >= max_hits:
                        print("   (truncated)")
                        return
                start = i + 1
    if not hits:
        print("   (none)")

    # ---------------------------------------------------------------- floats
    print()
    print("-- float constants that look like a frame delta --")
    # 60 fps: 1/60, and the doubles a compiler emits for the same value
    candidates = {
        1.0 / 60.0: "1/60 (a 60Hz step)",
        1.0 / 30.0: "1/30",
        1.0 / 120.0: "1/120",
        60.0: "60 (a rate)",
        0.0166667: "1/60 rounded",
    }
    per_section = collections.Counter()
    detail = []
    for s in pe.sections:
        data = s.get_data()
        for value, label in candidates.items():
            packed32 = struct.pack("<f", value)
            start = 0
            while True:
                i = data.find(packed32, start)
                if i < 0:
                    break
                va = ib + s.VirtualAddress + i
                per_section[s.Name.decode().strip("\x00")] += 1
                if len(detail) < max_hits:
                    detail.append((va, label, "float32"))
                start = i + 1
            packed64 = struct.pack("<d", value)
            start = 0
            while True:
                i = data.find(packed64, start)
                if i < 0:
                    break
                va = ib + s.VirtualAddress + i
                per_section[s.Name.decode().strip("\x00")] += 1
                if len(detail) < max_hits:
                    detail.append((va, label, "float64"))
                start = i + 1

    for sec, n in per_section.most_common():
        print(f"   section {sec}: {n}")
    for va, label, width in detail[:24]:
        print(f"   0x{va:X}  {width:8} {label}")
    if len(detail) > 24:
        print(f"   ... {len(detail) - 24} more")

    print()
    print(f"-- image base 0x{ib:X}, image spans to 0x{image_end:X} --")


if __name__ == "__main__":
    main()
