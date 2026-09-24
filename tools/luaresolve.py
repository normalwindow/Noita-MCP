r"""Resolve a Lua API name to its C implementation.

Noita registers an API function as:

    push 0                    ; nupvalues
    push <fn VA>              ; lua_CFunction   <-- wanted
    push <lua_State*>
    call lua_pushcclosure
    push <name VA>
    push 0xffffd8ee           ; LUA_GLOBALSINDEX
    push <lua_State*>
    call lua_setfield

so the implementation is the nearest preceding `push imm32` whose immediate points into .text.
This script finds the name string, the registration site (the `push` of the name), and walks
backwards with capstone to the function pointer.  It also reports if no code-like push precedes.
"""
import struct
import sys
sys.path.insert(0, r"D:\STRARG\GHCode\myNoitaMod\agent\tools\re")
from cellre import Image, fmt

im = Image()
TEXT_LO = im.ib + 0x1000
TEXT_HI = im.ib + 0xF06E1E


def resolve(name):
    # A name can occur several times: once as the short registration key and once inside the
    # long doc string.  Only the registration key is pushed by code, so try every occurrence.
    vas = im.find_string(name)
    if not vas:
        return None, None, "name string not found"
    tried = []
    for cand in vas:
        sites = im.find_bytes(b"\x68" + struct.pack("<I", cand))
        if sites:
            name_va, site = cand, sites[0]
            break
        tried.append(hex(cand))
    else:
        return vas[0], None, f"no push imm32 reference at any occurrence {tried}"
    return _walkback(name_va, site)


def _walkback(name_va, site):
    # Raw byte scan backwards rather than a linear disassembly: the bytes before a name push
    # can be misaligned relative to the previous function, and capstone would then miss the
    # `push imm32` entirely.  A `push imm32` is 68 <imm32>; take the nearest one whose
    # immediate lands in .text.
    cands = []
    for back in range(5, 40):
        p = site - back
        b = im.read(p, 5)
        if b and b[0] == 0x68:
            v = struct.unpack("<I", b[1:5])[0]
            if TEXT_LO <= v < TEXT_HI:
                cands.append((back, p, v))
    if not cands:
        return name_va, None, "no `68 <imm32-in-text>` in the 40 bytes before the name push"
    # nearest match wins
    cands.sort()
    back, p, fn = cands[0]
    contradicting = [f"0x{q:X}->0x{v:X}" for q, _, v in cands[1:]]
    head = im.read(fn, 12)
    note = f"push site 0x{p:X} ({back} bytes before name), prologue {head.hex(' ')}"
    if contradicting:
        note += f"  [other candidates: {', '.join(contradicting)}]"
    return name_va, fn, note


if __name__ == "__main__":
    for name in sys.argv[1:]:
        name_va, fn, note = resolve(name)
        if fn:
            print(f"  {name:<40} impl = 0x{fn:X}   ({note})")
        else:
            print(f"  {name:<40} UNRESOLVED   name_va={name_va}  ({note})")
