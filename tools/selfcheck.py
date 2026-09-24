r"""Self-check: re-read every address quoted in CELL-MATERIAL-FINDINGS.md and print the bytes,
so no address in the report is taken on trust.
"""
import struct
import sys
sys.path.insert(0, r"D:\STRARG\GHCode\myNoitaMod\agent\tools\re")
from cellre import Image

im = Image()

print("### strings")
for va, want in [(0x10270CC, "Raytrace"), (0x10270D8, "RaytraceSurfaces"),
                 (0x10270EC, "RaytraceSurfacesAndLiquiform"), (0x102710C, "RaytracePlatforms"),
                 (0x101DE78, "Raytrace( x1:number"),
                 (0x101E0A0, "RaytracePlatforms( x1:number"),
                 (0x101BEB8, "CellFactory_GetName"),
                 (0x101BF28, "CellFactory_GetType")]:
    got = im.cstr(va, 60)
    ok = got is not None and got.startswith(want)
    print(f"  {'OK ' if ok else 'BAD'} 0x{va:X}  {got!r}")

print()
print("### Lua registrations")
for site, fn in [(0x7EB503, 0x7BA130), (0x7EB51A, 0x7BA410),
                 (0x7EB531, 0x7BA6F0), (0x7EB54B, 0x7BA9D0)]:
    b = im.read(site, 5)
    ok = b[0] == 0x68 and struct.unpack("<I", b[1:5])[0] == fn
    print(f"  {'OK ' if ok else 'BAD'} push at 0x{site:X} -> 0x{struct.unpack('<I', b[1:5])[0]:X} (want 0x{fn:X})")
for site, name_va in [(0x7EB50B, 0x10270CC), (0x7EB522, 0x10270D8),
                      (0x7EB539, 0x10270EC), (0x7EB553, 0x102710C)]:
    b = im.read(site, 5)
    ok = b[0] == 0x68 and struct.unpack("<I", b[1:5])[0] == name_va
    print(f"  {'OK ' if ok else 'BAD'} name push at 0x{site:X} -> 0x{struct.unpack('<I', b[1:5])[0]:X}")

print()
print("### lambda vtables -> _Func_impl RTTI")
LAMBDAS = [(0xFE83A8, 0x11DB580, "lambda_9a944994520200cc5757d0f5277c68aa"),
           (0xFF9500, 0x11DB2A8, "lambda_691a437e9190b5d7017c0e6b64352510"),
           (0x100538C, 0x11DE848, "lambda_d7b5dcba8f5ab36b09e59699d1239611"),
           (0x1017CE0, 0x11DEB38, "lambda_8262b0d6b4be6598ae5a3b4549ddb95c")]
for vt, td_want, lam in LAMBDAS:
    col = im.u32(vt - 4)
    td = im.u32(col + 0xC)
    name = im.cstr(td + 8, 300)
    ok = td == td_want and name.startswith(".?AV?$_Func_impl@U?$_Callable_obj@V<" + lam)
    if not ok:
        bad += 1
    print(f"  {'OK ' if ok else 'BAD'} vtable 0x{vt:X}: COL 0x{col:X} -> TD 0x{td:X} "
          f"contains {lam}")

print()
print("### key instruction sites (first bytes as quoted)")
SITES = {
    0x78DFBE: "8b 48 20",           # mov ecx,[eax+0x20]
    0x78DFD1: "e8 7a 1a eb ff",     # call 0x63fa50
    0x63FC55: "c1 f8 09",           # sar eax,9
    0x63FC64: "c1 f9 09",           # sar ecx,9
    0x63FC73: "c1 e1 09",           # shl ecx,9
    0x63FC7B: "8b 00",              # mov eax,[eax]
    0x63FC7D: "8b 40 08",           # mov eax,[eax+8]
    0x63FC80: "8b 1c 88",           # mov ebx,[eax+ecx*4]
    0x63FC87: "b8 44 46 22 01",     # mov eax,0x1224644
    0x63FCA4: "8d 04 88",           # lea eax,[eax+ecx*4]
    0x63FCA7: "8b 4d 24",           # mov ecx,[ebp+0x24]
    0x63FCC7: "8b 40 08",           # mov eax,[eax+8]
    0x63FCCA: "ff d0",              # call eax
    0x63FCCE: "0f 84 8f 00 00 00",  # je 0x63fd63
    0x63FD66: "b3 01",              # mov bl,1
    0x89C300: "8b 41 08",           # mov eax,[ecx+8]
    0x89C303: "8b 04 90",           # mov eax,[eax+edx*4]
    0x89C30B: "b8 44 46 22 01",     # mov eax,0x1224644
    0x89C312: "c2 08 00",           # ret 8
    0x89C317: "81 e6 ff 01 00 00",  # and esi,0x1ff
    0x89C329: "8d 04 b0",           # lea eax,[eax+esi*4]
    0x89BF93: "68 00 00 10 00",     # push 0x100000
    0x89BF98: "c7 06 00 02 00 00",  # mov [esi],0x200
    0x89BFAF: "89 46 08",           # mov [esi+8],eax
    0x4AD900: "8d 81 00 05 00 00",  # lea eax,[ecx+0x500]
    0x4AD06E: "69 c0 90 02 00 00",  # imul eax,eax,0x290
    0x4AD074: "03 41 18",           # add eax,[ecx+0x18]
    0x4AC0D0: "8b 41 14 c3",        # mov eax,[ecx+0x14]; ret
    0x704CE2: "83 c6 18",           # add esi,0x18
    0x704D28: "8b 45 08",           # mov eax,[ebp+8]
    0xBAA65D: "8b 40 0c",           # mov eax,[eax+0xc]
    0xBAA660: "8b 48 44",           # mov ecx,[eax+0x44]
    0xBAA665: "8b 40 0c",           # mov eax,[eax+0xc]
    0xBAA668: "ff d0",              # call eax
    0xBAA89C: "8b 40 08",           # mov eax,[eax+8]
    0xBAA89F: "8b 04 88",           # mov eax,[eax+ecx*4]
    0xBAA6B6: "69 d7 90 02 00 00",  # imul edx,edi,0x290
    0xBAA6BC: "03 50 18",           # add edx,[eax+0x18]
    0xBAA8D4: "3b 45 d0",           # cmp eax,[ebp-0x30]
    0x6F1933: "e8 18 63 02 00",     # call 0x717c50
    0x6F1940: "89 46 44",           # mov [esi+0x44],eax
    0x6AFF6F: "8b 49 44",           # mov ecx,[ecx+0x44]
    0x6AFF74: "ff 52 0c",           # call [edx+0xc]
    0x7222B0: "8b 81 5c 04 00 00",  # mov eax,[ecx+0x45c]
    0x439BFC: "e8 1f c0 1f 00",     # call 0x635c20
    0x9A5730: "55 8b ec 8b 4d 0c",  # Raytrace filter prologue
    0x9A5820: "55 8b ec 8b 45 0c",  # RaytraceSurfaces filter
    0x9A5940: "55 8b ec 8b 45 0c",  # RaytraceSurfacesAndLiquiform filter
    0x9A5A40: "55 8b ec 8b 45 0c",  # RaytracePlatforms filter
}
bad = 0
for va, want in SITES.items():
    got = im.read(va, len(want.split()))
    hexs = got.hex(" ")
    ok = hexs == want
    if not ok:
        bad += 1
    print(f"  {'OK ' if ok else 'BAD'} 0x{va:X}  got {hexs:<22} want {want}")

print()
print("### vtable slots")
for vt, slot, want in [(0xFF8A6C, 1, 0x4ADAB0), (0xFF8A6C, 11, 0x4ADB40), (0xFF8A6C, 12, 0x4AC0D0),
                       (0x100BB90, 1, 0x5B01A0), (0x100BB90, 12, 0x4AC0D0),
                       (0x1007BCC, 1, 0x6F98D0), (0x1007BCC, 12, 0x4AC0D0),
                       (0x10096E0, 1, 0x6F9860), (0x10096E0, 12, 0x4AC0D0),
                       (0xFEF78C, 12, 0xDFCDDA),
                       (0x10013BC, 3, 0x4AD900), (0x1017B24, 3, 0x7222B0),
                       (0xFE83A8, 2, 0x9A5730), (0xFF9500, 2, 0x9A5820),
                       (0x100538C, 2, 0x9A5940), (0x1017CE0, 2, 0x9A5A40)]:
    got = im.u32(vt + 4 * slot)
    ok = got == want
    if not ok:
        bad += 1
    print(f"  {'OK ' if ok else 'BAD'} vtable 0x{vt:X} slot[{slot}] = 0x{got:X} (want 0x{want:X})")

print()
print("### BSS globals (value 0 at load: VA past SizeOfRawData)")
for va in (0x122374C, 0x1224644):
    off = im.off_of_va(va)
    sec = im.sec_for_va(va)
    raw_end = sec.PointerToRawData + sec.SizeOfRawData
    inside_raw = off is not None and off < raw_end
    print(f"  0x{va:X}: section {sec.Name.rstrip(chr(0).encode()).decode()}, "
          f"raw offset 0x{off:X}, raw end 0x{raw_end:X} -> "
          f"{'INSIDE raw data' if inside_raw else 'past raw data (BSS) => 0 at load'}")

print()
print(f"TOTAL MISMATCHES: {bad}")
