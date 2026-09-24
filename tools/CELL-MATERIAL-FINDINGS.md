# Reading a world cell's material in Noita (32-bit, `noita.exe`, image base 0x400000)

Investigation directory: `agent/tools/re/`. All addresses below were read out of
`D:\Sware\Steam\steamapps\common\Noita\noita.exe` with the venv `pefile`/`capstone` tooling in
this directory. Nothing was written outside `agent/tools/re/`.

New helper scripts written for this investigation (all read-only):

| script | purpose |
|---|---|
| `cellre.py` | PE/VA mapping, correct `file offset -> VA` conversion, flat memory image, disasm helpers |
| `xref.py` | desync-proof xrefs via raw `E8/E9 rel32` byte scan (see "Ruled out") |
| `dump_range.py` | exact `[start,end)` instruction dump that does not stop at the first `ret` |
| `luaresolve.py` | Lua API name string -> C implementation VA (registration-pattern walk-back) |
| `vtable_find.py` | RTTI TypeDescriptor -> vtable, slot-by-slot dump |
| `rt_refs.py`, `rt_stage2.py`, `matid_scan.py`, `rtti_scan.py`, `cellfactory.py`, `docs_dump.py`, `gridworld_vt.py`, `gridctor.py`, `holder_store.py`, `final_checks.py`, `cell_table.py` | supporting scans, quoted below |
| `selfcheck.py` | re-reads every address quoted in this document and compares the bytes against the quoted text — run it; it currently reports `TOTAL MISMATCHES: 0` |

`selfcheck.py` output is the machine check for this report: string contents, `push imm32`
targets, vtable slots, instruction bytes at each quoted address, and the BSS check for
`0x122374C` / `0x1224644`. If any address here is ever wrong, that script will say so.

---

## 0. Correction to the briefing (important)

Two of the "already known" facts are **wrong**, and they were the reason the earlier attempt
concluded the Raytrace implementations were unreachable:

1. **String VAs.** `Raytrace` / `RaytraceSurfaces` / `RaytraceSurfacesAndLiquiform` /
   `RaytracePlatforms` are at **`0x10270CC`, `0x10270D8`, `0x10270EC`, `0x102710C`** — not
   `0x10264CC` / `0x10264D8` / `0x102650C`. The earlier figures are *file offsets + 0x400000*.
   `noita.exe`'s `.text` has `VirtualAddress = 0x1000` but `PointerToRawData = 0x400`, so
   `image_base + file_offset` is 0x400 too low for every section and lands mid-instruction.
   That is why "disassembling at 0x7E9E41" produced `add byte ptr [ecx], al`.
2. **"No `push imm32` reference" is false.** All four names *do* have exactly one `push imm32`
   each, in one contiguous registration block (`0x7EB50B`, `0x7EB522`, `0x7EB539`, `0x7EB553`).
   There is no table loop and no computed addressing to figure out.

Everything below is measured against the corrected mapping.

---

## 1. Verdict

**(a) Reachable.** The engine reads a world cell through a two-level, per-world-pixel pointer
grid, and a cell yields its material as a `grid::CellData*` (the static material descriptor).
The material id and name are then a pointer subtraction + division and an indexed
`std::string`. Every step is a plain memory read on a fixed VA; **no engine function needs to be
called except optionally the already-existing accessor at `0x89C2D0`.**

One honest caveat, stated up front and repeated in §3:

* The link `worldRoot = *(void**)(singleton + 0x0C)` is quoted from the engine's own material
  conversion code (`0xBAA5F0`), and the link `gridWorld = *(void**)(worldRoot + 0x44)` is
  corroborated by three independent code sites. I did **not** find the *store* that puts the
  GridWorld-owning object into `[singleton+0x0C]`, so I am labelling that specific step
  "quoted from shipping code, not independently confirmed by its writer".
* A cell has **no integer material-id field.** The 4-byte grid entry is a `grid::ICell*`
  pointer to a polymorphic cell object (`CSolidCell` / `CLiquidCell` / `CGasCell` / `CFireCell`).
  The material id must be derived: `(cellData - cellDataArray) / 0x290`.

The **same technique works at an arbitrary position**, not only along a ray. The accessor
`0x89C2D0` is pure coordinate arithmetic with no ray/visibility state; `Raytrace*` merely walks
it in a DDA loop. `RaytracePlatforms(x, y, x+0.1, y)` is the game's own idiom for "read the cell
I am standing in" (see §6).

---

## 2. Evidence

### 2.1 The four Raytrace implementations (Lua registration)

`rt_refs.py` found exactly one `push imm32` per name. Registration pattern is
`push 0 / push <lua_CFunction> / push lua_State* / call lua_pushcclosure`, then
`push <name> / push -10002 (LUA_GLOBALSINDEX) / push lua_State* / call lua_setfield`:

```
0x7EB501  6a 00                 push 0
0x7EB503  68 30 a1 7b 00        push 0x7ba130        ; Raytrace
0x7EB508  53                    push ebx
0x7EB509  ff d7                 call edi             ; lua_pushcclosure
0x7EB50B  68 cc 70 02 01        push 0x10270cc       ; "Raytrace"
0x7EB510  68 ee d8 ff ff        push 0xffffd8ee
0x7EB515  53                    push ebx
0x7EB516  ff d6                 call esi             ; lua_setfield

0x7EB51A  68 10 a4 7b 00        push 0x7ba410        ; RaytraceSurfaces            name @0x10270D8
0x7EB531  68 f0 a6 7b 00        push 0x7ba6f0        ; RaytraceSurfacesAndLiquiform name @0x10270EC
0x7EB54B  68 d0 a9 7b 00        push 0x7ba9d0        ; RaytracePlatforms           name @0x102710C
```

So:

| Lua name | C function |
|---|---|
| `Raytrace` | `0x7BA130` |
| `RaytraceSurfaces` | `0x7BA410` |
| `RaytraceSurfacesAndLiquiform` | `0x7BA6F0` |
| `RaytracePlatforms` | `0x7BA9D0` |

All four are genuine MSVC functions (`55 8b ec 83 e4 f8 6a ff 68 … 64 a1 00 00 00 00`).

Each wrapper only does argument-count checking, then builds a **by-value 0x14-byte object whose
first dword is a distinct lambda vtable** and calls one shared body `0x78DEE0`.

### 2.2 The four "strategies" are C++ lambdas — this gives the real types

Each of the four vtables is the vtable of a `std::_Func_impl` over a distinct lambda closure.
The CompleteObjectLocator of each vtable points at the `_Func_impl` TypeDescriptor
(`vtable_find.py` / `selfcheck.py`; the `.?AV...` name starts 8 bytes into a TypeDescriptor):

| variant | vtable | COL | `_Func_impl` RTTI string |
|---|---|---|---|
| Raytrace | `0xFE83A8` | `0x10586F8` | `.?AV?$_Func_impl@U?$_Callable_obj@V<lambda_9a944994520200cc5757d0f5277c68aa>@@…` @ `0x11DB588` |
| RaytraceSurfaces | `0xFF9500` | `0x105C1D0` | `.?AV?$_Func_impl@U?$_Callable_obj@V<lambda_691a437e9190b5d7017c0e6b64352510>@@…` @ `0x11DB2B0` |
| RaytraceSurfacesAndLiquiform | `0x100538C` | `0x1059D20` | `.?AV?$_Func_impl@U?$_Callable_obj@V<lambda_d7b5dcba8f5ab36b09e59699d1239611>@@…` @ `0x11DE850` |
| RaytracePlatforms | `0x1017CE0` | `0x1060128` | `.?AV?$_Func_impl@U?$_Callable_obj@V<lambda_8262b0d6b4be6598ae5a3b4549ddb95c>@@…` @ `0x11DEB40` |

The bare closure TypeDescriptors also exist separately
(`0x11DAD18`, `0x11DFE88`, `0x11D77D0`, `0x11D8B88` → `.?AV<lambda_…>@@`).

The full `_Func_impl` mangling spells out the signature — the second parameter of the callable
is a `grid::ICell*`:

```
.?AV?$_Func_impl@U?$_Callable_obj@V<lambda_8262b0d6b4be6598ae5a3b4549ddb95c>@@$0A@@std@@
    V?$allocator@V?$_Func_class@_NV?$CVector2@H@math@ceng@@PAVICell@grid@@@std@@@2@
    _NV?$CVector2@H@math@ceng@@PAVICell@grid@@@std@@
```

i.e. **`std::function<bool(math::CVector2<int>, grid::ICell*)>`** — the second parameter is a
`grid::ICell*`. That is the name of the per-cell object type, and it is what unlocked the rest.
(The corresponding `_Func_base` name is at `0x11D8F00`:
`.?AV?$_Func_base@_NV?$CVector2@H@math@ceng@@PAVICell@grid@@@std@@`.)

Documented behaviour (embedded doc strings, `docs_dump.py`) matches the filters exactly:

```
0x101DE78  Raytrace( x1:number, y1:number, x2:number, y2:number ) -> did_hit:bool,hit_x:number,hit_y:number [Does a raytrace that stops on any cell it hits.]
0x101DF10  RaytraceSurfaces( ... ) [Does a raytrace that stops on any cell that is not fluid, gas (yes, technically gas is a fluid), or fire.]
0x101DFE8  RaytraceSurfacesAndLiquiform( ... ) [Does a raytrace that stops on any cell that is not gas or fire.]
0x101E0A0  RaytracePlatforms( ... ) [Does a raytrace that stops on any cell a character can stand on.]
```

### 2.3 Shared body `0x78DEE0`: read 4 numbers, call the ray march

```
0x78DF0A  6a 01                 push 1
0x78DF0C  57                    push edi                    ; lua_State*
0x78DF14  ff 15 54 79 f0 00     call dword ptr [0xf07954]   ; lua_tonumber
0x78DF1A  6a 02                 push 2
0x78DF1C  d9 5d e0              fstp dword ptr [ebp - 0x20] ; x1
0x78DF1F  57                    push edi
0x78DF20  ff 15 54 79 f0 00     call dword ptr [0xf07954]
0x78DF26  6a 03                 push 3
0x78DF28  d9 5d e4              fstp dword ptr [ebp - 0x1c] ; y1
0x78DF2B  57                    push edi
0x78DF2C  ff 15 54 79 f0 00     call dword ptr [0xf07954]
0x78DF32  6a 04                 push 4
0x78DF34  d9 5d d8              fstp dword ptr [ebp - 0x28] ; x2
0x78DF37  57                    push edi
0x78DF38  ff 15 54 79 f0 00     call dword ptr [0xf07954]
0x78DF3E  83 c4 08              add esp, 8
0x78DF41  c7 45 ec 00 00 00 00  mov dword ptr [ebp - 0x14], 0   ; hit_x = 0
0x78DF4A  c7 45 f0 00 00 00 00  mov dword ptr [ebp - 0x10], 0   ; hit_y = 0
0x78DF51  d9 5d dc              fstp dword ptr [ebp - 0x24] ; y2
0x78DF88  a1 4c 37 22 01        mov eax, dword ptr [0x122374c]
...
0x78DFBE  8b 48 20              mov ecx, dword ptr [eax + 0x20]  ; this = *(singleton + 0x20)
0x78DFC1  8d 45 ec              lea eax, [ebp - 0x14]
0x78DFC4  50                    push eax                        ; 3rd push
0x78DFC5  8d 45 d8              lea eax, [ebp - 0x28]           ; &(x2,y2)
0x78DFCC  50                    push eax                        ; 2nd push
0x78DFCD  8d 45 e0              lea eax, [ebp - 0x20]           ; &(x1,y1)
0x78DFD0  50                    push eax                        ; 1st push = arg1
0x78DFD1  e8 7a 1a eb ff        call 0x63fa50
0x78DFD9  8a d8                 mov bl, al                      ; did_hit
0x78DFE3  84 db                 test bl, bl
0x78DFE5  0f 95 c1              setne cl
0x78DFEA  ff 15 b4 79 f0 00     call dword ptr [0xf079b4]       ; lua_pushboolean
0x78DFF0  f3 0f 10 45 ec        movss xmm0, dword ptr [ebp - 0x14]; hit_x
0x78DFF5  83 c4 08              add esp, 8
0x78E009  f3 0f 10 45 f0        movss xmm0, dword ptr [ebp - 0x10]; hit_y
```

The three stack arguments are `&from`, `&to`, `&hit_pos` (right-to-left, so `&(x1,y1)` is arg1),
and `ecx` is the strategy carrier.

(The by-value lambda object is what the caller built at the top of its stack; it therefore
reaches `0x63FA50` as stack arguments, and the ray march reads the strategy back as its 8th
stack argument `[ebp+0x24]`. That is why the four variants differ only in that vtable.)

### 2.4 The ray march `0x63FA50` — the grid read

`0x63FA50` computes `dx,dy`, `len2 = dx*dx+dy*dy`, calls `0x44A410` (`sqrtf`) and normalises to
unit steps. Its inner loop is a DDA; the grid lookup is:

```
0x63FC4F  f3 0f 2c f2           cvttss2si esi, xmm2            ; iy = (int)pos.y
0x63FC53  8b c2                 mov eax, edx                   ; ix = (int)pos.x
0x63FC55  c1 f8 09              sar eax, 9                     ; ix >> 9
0x63FC58  2d 00 01 00 00        sub eax, 0x100
0x63FC5D  25 ff 01 00 00        and eax, 0x1ff
0x63FC62  8b ce                 mov ecx, esi
0x63FC64  c1 f9 09              sar ecx, 9                     ; iy >> 9
0x63FC67  81 e9 00 01 00 00     sub ecx, 0x100
0x63FC6D  81 e1 ff 01 00 00     and ecx, 0x1ff
0x63FC73  c1 e1 09              shl ecx, 9                     ; (chunkY) * 512
0x63FC76  03 c8                 add ecx, eax                   ; idx = chunkY*512 + chunkX
0x63FC78  8b 45 ec              mov eax, dword ptr [ebp - 0x14] ; this
0x63FC7B  8b 00                 mov eax, dword ptr [eax]        ; *(this)          <- the grid holder
0x63FC7D  8b 40 08              mov eax, dword ptr [eax + 8]    ; chunkTable
0x63FC80  8b 1c 88              mov ebx, dword ptr [eax + ecx*4]; chunk
0x63FC83  85 db                 test ebx, ebx
0x63FC85  75 07                 jne 0x63fc8e
0x63FC87  b8 44 46 22 01        mov eax, 0x1224644              ; static empty cell (BSS, = 0)
0x63FC8C  eb 19                 jmp 0x63fca7
0x63FC8E  8b ce                 mov ecx, esi
0x63FC90  8b c2                 mov eax, edx
0x63FC92  81 e1 ff 01 00 00     and ecx, 0x1ff                  ; iy & 511
0x63FC98  25 ff 01 00 00        and eax, 0x1ff                  ; ix & 511
0x63FC9D  c1 e1 09              shl ecx, 9
0x63FCA0  0b c8                 or  ecx, eax                    ; local = (iy&511)*512 | (ix&511)
0x63FCA2  8b 03                 mov eax, dword ptr [ebx]        ; chunk->cells
0x63FCA4  8d 04 88              lea eax, [eax + ecx*4]          ; &cells[local]
0x63FCA7  8b 4d 24              mov ecx, dword ptr [ebp + 0x24] ; the std::function strategy
0x63FCAA  8b 00                 mov eax, dword ptr [eax]        ; ICell*  (4 bytes)
0x63FCAC  89 45 bc              mov dword ptr [ebp - 0x44], eax
0x63FCAF  89 55 ac              mov dword ptr [ebp - 0x54], edx ; x
0x63FCB2  89 75 b0              mov dword ptr [ebp - 0x50], esi ; y
0x63FCBD  8b 01                 mov eax, dword ptr [ecx]
0x63FCBF  8d 55 bc              lea edx, [ebp - 0x44]
0x63FCC2  52                    push edx                        ; arg2 = &ICell*
0x63FCC3  8d 55 ac              lea edx, [ebp - 0x54]
0x63FCC6  52                    push edx                        ; arg1 = &CVector2<int>
0x63FCC7  8b 40 08              mov eax, dword ptr [eax + 8]    ; lambda vtbl[2] = the cell filter
0x63FCCA  ff d0                 call eax
0x63FCCC  84 c0                 test al, al
0x63FCCE  0f 84 8f 00 00 00     je 0x63fd63                     ; filter false -> HIT
...
0x63FD63  8b 4d dc              mov ecx, dword ptr [ebp - 0x24] ; out vec2
0x63FD66  b3 01                 mov bl, 1                       ; did_hit = true
```

Note the coordinates: `ix = (int)world_x` **in world pixels** (a Lua float), and the index math
uses `& 0x1FF` of the *pixel*, so a chunk is **512×512 world pixels with one 4-byte entry per
pixel**. There is no `>> 3` anywhere in this path.

### 2.5 The canonical accessor `0x89C2D0` (`grid::ICell** GetCellSlot(gridHolder, x, y)`)

`0x63FA50` uses it directly for zero-length rays; it has ~180 callers.

```
0x89C2D0  55                    push ebp
0x89C2D1  8b ec                 mov ebp, esp
0x89C2D3  56                    push esi
0x89C2D4  8b 75 0c              mov esi, dword ptr [ebp + 0xc]   ; arg2 = y
0x89C2D7  8b d6                 mov edx, esi
0x89C2D9  c1 fa 09              sar edx, 9
0x89C2DC  57                    push edi
0x89C2DD  8b 7d 08              mov edi, dword ptr [ebp + 8]     ; arg1 = x
0x89C2E0  81 ea 00 01 00 00     sub edx, 0x100
0x89C2E6  8b c7                 mov eax, edi
0x89C2E8  81 e2 ff 01 00 00     and edx, 0x1ff
0x89C2EE  c1 f8 09              sar eax, 9
0x89C2F1  2d 00 01 00 00        sub eax, 0x100
0x89C2F6  c1 e2 09              shl edx, 9
0x89C2F9  25 ff 01 00 00        and eax, 0x1ff
0x89C2FE  03 d0                 add edx, eax
0x89C300  8b 41 08              mov eax, dword ptr [ecx + 8]     ; ecx = gridHolder -> chunkTable
0x89C303  8b 04 90              mov eax, dword ptr [eax + edx*4] ; chunk
0x89C306  85 c0                 test eax, eax
0x89C308  75 0b                 jne 0x89c315
0x89C30A  5f                    pop edi
0x89C30B  b8 44 46 22 01        mov eax, 0x1224644               ; return &static_empty_cell
0x89C310  5e                    pop esi
0x89C311  5d                    pop ebp
0x89C312  c2 08 00              ret 8
0x89C315  8b 00                 mov eax, dword ptr [eax]         ; chunk->cells
0x89C317  81 e6 ff 01 00 00     and esi, 0x1ff                   ; y & 511
0x89C31D  c1 e6 09              shl esi, 9
0x89C320  81 e7 ff 01 00 00     and edi, 0x1ff                   ; x & 511
0x89C326  0b f7                 or  esi, edi
0x89C328  5f                    pop edi
0x89C329  8d 04 b0              lea eax, [eax + esi*4]           ; &cells[local]
0x89C32C  5e                    pop esi
0x89C32D  5d                    pop ebp
0x89C32E  c2 08 00              ret 8
```

`ecx` = grid holder, `ret 8` → plain `__thiscall(gridHolder, int x, int y) -> ICell**`.
`0x1224644` is in `.data` past `SizeOfRawData` (BSS) so its value is 0 at load: the
"chunk not allocated" case returns a pointer to a static zero, i.e. `ICell* == NULL`.

### 2.6 The chunk table really is 512×512×4 bytes

`grid::GridWorld`'s constructor is `0x717C50`; it ends with `lea ecx, [esi + 0x500]` and
`call 0x89BF90`, which is the chunk-table constructor:

```
0x89BF90  56                    push esi
0x89BF91  8b f1                 mov esi, ecx
0x89BF93  68 00 00 10 00        push 0x100000                 ; 1048576 = 512*512*4
0x89BF98  c7 06 00 02 00 00     mov dword ptr [esi], 0x200    ; 512
0x89BF9E  c6 46 04 00           mov byte ptr [esi + 4], 0
0x89BFA2  e8 75 0c 56 00        call 0xdfcc1c                 ; operator new
0x89BFA7  68 00 00 10 00        push 0x100000
0x89BFAC  6a 00                 push 0
0x89BFAE  50                    push eax
0x89BFAF  89 46 08              mov dword ptr [esi + 8], eax  ; *** chunkTable ***
0x89BFB2  e8 c7 22 56 00        call 0xdfe27e                 ; memset(chunkTable, 0, 0x100000)
...
0x89C017  81 46 28 00 02 00 00  add dword ptr [esi + 0x28], 0x200
0x89C01E  81 46 2c 00 02 00 00  add dword ptr [esi + 0x2c], 0x200
```

and `grid::GridWorld` vtable slot 3 (which the material-conversion code calls to obtain the grid
holder) is literally "this + 0x500":

```
vtable 0x10013BC  [3] = 0x004AD900
0x4AD900  8d 81 00 05 00 00     lea eax, [ecx + 0x500]
0x4AD906  c3                    ret
```

### 2.7 How the grid holder and GridWorld are reached

`ConvertMaterialOnAreaInstantly` (Lua `0x7E5D50`, body at `0x7E5FF1`) calls `0xBAA5F0`. That
function obtains the grid holder like this — this is the engine's own read path, quoted:

```
0xBAA61F  a1 4c 37 22 01        mov eax, dword ptr [0x122374c]   ; the lazy global singleton
0xBAA65D  8b 40 0c              mov eax, dword ptr [eax + 0xc]   ; worldRoot
0xBAA660  8b 48 44              mov ecx, dword ptr [eax + 0x44]  ; grid::GridWorld*
0xBAA663  8b 01                 mov eax, dword ptr [ecx]         ; GridWorld vtable
0xBAA665  8b 40 0c              mov eax, dword ptr [eax + 0xc]   ; vtbl[3] == 0x4AD900
0xBAA668  ff d0                 call eax                         ; -> GridWorld + 0x500  (gridHolder)
0xBAA66A  89 45 cc              mov dword ptr [ebp - 0x34], eax
...
0xBAA899  8b 45 cc              mov eax, dword ptr [ebp - 0x34]
0xBAA89C  8b 40 08              mov eax, dword ptr [eax + 8]     ; chunkTable
0xBAA89F  8b 04 88              mov eax, dword ptr [eax + ecx*4] ; chunk
```

Corroboration for `[worldRoot + 0x44] == GridWorld`:

* the only caller of the GridWorld constructor stores the new object into `[<obj>+0x44]`:
  ```
  0x6F1930  8b c8                 mov ecx, eax
  0x6F1932  56                    push esi
  0x6F1933  e8 18 63 02 00        call 0x717c50        ; GridWorld::GridWorld
  0x6F1940  89 46 44              mov dword ptr [esi + 0x44], eax
  ```
* `0x6AFF6C` independently does exactly the same three steps:
  ```
  0x6AFF6C  8b 4b 20              mov ecx, dword ptr [ebx + 0x20]
  0x6AFF6F  8b 49 44              mov ecx, dword ptr [ecx + 0x44]  ; GridWorld
  0x6AFF72  8b 11                 mov edx, dword ptr [ecx]
  0x6AFF74  ff 52 0c              call dword ptr [edx + 0xc]       ; vtbl[3] -> GridWorld+0x500
  0x6AFF77  89 07                 mov dword ptr [edi], eax
  ```

`[0x122374C]` is a lazily created 0x1A0-byte global; its getter is `0x439BB0`
(`mov eax,[0x122374c]; test; jne; push 0x1a0; call operator new; mov ecx,eax; call 0x635c20;
mov [0x122374c], eax; ret`). It is 0 on disk (BSS), and 540 sites load it with the
`mov eax, [0x122374C]` form.

### 2.8 The cell objects, and where the material descriptor lives

`vtable_find.py` resolves RTTI TypeDescriptors to vtables. The four concrete cell classes:

| class | RTTI string | vtable | slot 1 (`GetType`) | slot 12 (`GetCellData`) |
|---|---|---|---|---|
| `grid::CSolidCell` | `0x11DFC20` | `0xFF8A6C` | `0x4ADAB0` `mov eax,3; ret` | `0x4AC0D0` `mov eax,[ecx+0x14]; ret` |
| `grid::CLiquidCell` | `0x11D9AC8` | `0x100BB90` | `0x5B01A0` `mov eax,1; ret` | `0x4AC0D0` `mov eax,[ecx+0x14]; ret` |
| `grid::CGasCell` | `0x11DD350` | `0x1007BCC` | `0x6F98D0` `mov eax,2; ret` | `0x4AC0D0` `mov eax,[ecx+0x14]; ret` |
| `grid::CFireCell` | `0x11D80D0` | `0x10096E0` | `0x6F9860` `mov eax,4; ret` | `0x4AC0D0` `mov eax,[ecx+0x14]; ret` |

`grid::ICell` itself is `0xFEF78C` (slots 12/13 are `_purecall`). **Every concrete
implementation's slot 12 is `mov eax, [ecx+0x14]; ret`**, so a cell's static material
descriptor is `*(void**)(icell + 0x14)`.

The four Raytrace filters use exactly these:
* `Raytrace` (`0x9A5730`): `mov ecx,[ebp+0xc]; xor eax,eax; cmp dword ptr [ecx], eax; sete al` → transparent iff `ICell* == NULL`.
* `RaytraceSurfacesAndLiquiform` (`0x9A5940`): transparent iff `NULL` or `cell->vtbl[1]() ∈ {2,4}` = {gas, fire}.
* `RaytraceSurfaces` (`0x9A5820`): `cell->vtbl[12]()` → descriptor; blocked iff `descriptor[+0x38]==3` or (`==1` and byte `[+0x160]!=0`).
* `RaytracePlatforms` (`0x9A5A40`): blocked iff `cell->vtbl[11]() == 1`.

### 2.9 Material ids and names

Material descriptors (`grid::CellData`, 656 = 0x290 bytes) live in a flat array whose base is
`[CellFactory + 0x18]`. The CellFactory is `*(void**)(singleton + 0x18)`.

```
; CellFactory::GetMaterial(int id)  @ 0x4AD060   (thiscall, ecx = CellFactory, ret 4)
0x4AD063  8b 45 08              mov eax, dword ptr [ebp + 8]     ; id
0x4AD066  85 c0                 test eax, eax
0x4AD068  75 04                 jne 0x4ad06e
0x4AD06A  5d                    pop ebp
0x4AD06B  c2 04 00              ret 4                            ; id 0 -> NULL
0x4AD06E  69 c0 90 02 00 00     imul eax, eax, 0x290
0x4AD074  03 41 18              add eax, dword ptr [ecx + 0x18]   ; CellData array base
0x4AD077  5d                    pop ebp
0x4AD078  c2 04 00              ret 4
```

```
; CellFactory::GetName(int id, std::string* out) @ 0x704E70
0x704E86  8b 57 08              mov edx, dword ptr [edi + 8]
0x704E89  b8 ab aa aa 2a        mov eax, 0x2aaaaaab
0x704E8E  2b 57 04              sub edx, dword ptr [edi + 4]
0x704E91  f7 ea                 imul edx
0x704E93  c1 fa 02              sar edx, 2
0x704E96  8b c2                 mov eax, edx
0x704E98  c1 e8 1f              shr eax, 0x1f
0x704E9B  03 c2                 add eax, edx                      ; eax = (end-begin)/24
0x704E9D  3b f0                 cmp esi, eax
0x704E9F  7d 33                 jge 0x704ed4                     ; out of range -> empty
0x704EA1  8b 47 04              mov eax, dword ptr [edi + 4]     ; names vector begin
0x704EA4  8d 0c 76              lea ecx, [esi + esi*2]           ; id*3
0x704EAE  8d 0c c8              lea ecx, [eax + ecx*8]           ; begin + id*24
```

```
; CellFactory::GetType(std::string* name) @ 0x704C20  -- LINEAR SCAN, returns the index
0x704C66  8b 4f 08              mov ecx, dword ptr [edi + 8]
0x704C86  8b 77 04              mov esi, dword ptr [edi + 4]     ; begin
0x704CE2  83 c6 18              add esi, 0x18                    ; stride 24
0x704CDF  ff 45 08              inc dword ptr [ebp + 8]          ; ++id
0x704D28  8b 45 08              mov eax, dword ptr [ebp + 8]     ; return the index
0x704D1C  83 c8 ff              or eax, 0xffffffff               ; not found -> -1
```

So the Lua-visible **material id is the index into the parallel arrays**: 24-byte
`std::string` names at `[CellFactory+4]` and 0x290-byte `CellData` at `[CellFactory+0x18]`.
The definitive proof that a cell's descriptor is a `CellData` at that stride is in `0xBAA5F0`,
where the Lua integer argument `material_from` is turned into a descriptor pointer and compared
with `cell->GetCellData()`:

```
0xBAA6A8  8b 40 18              mov eax, dword ptr [eax + 0x18]   ; CellFactory
0xBAA6B6  69 d7 90 02 00 00     imul edx, edi, 0x290              ; edi = material_from (int)
0xBAA6BC  03 50 18              add edx, dword ptr [eax + 0x18]   ; CellData* for that id
...
0xBAA8CB  8b 07                 mov eax, dword ptr [edi]          ; edi = ICell*
0xBAA8CF  8b 40 30              mov eax, dword ptr [eax + 0x30]   ; vtbl[12] == GetCellData()
0xBAA8D2  ff d0                 call eax
0xBAA8D4  3b 45 d0              cmp eax, dword ptr [ebp - 0x30]   ; == CellData* for material_from ?
```

`materials.xml` (`archive/ref-orin-data/materials.xml`) declares its materials in id order and
starts with `air`, `fire`, `fire_blue`, `spark`, … and even comments `order of materials: fire
(for hax reasons), static, sand, …`. Combined with `GetMaterial(0) == NULL`, this means
**`ICell* == NULL` (empty) is material id 0 = `air`** — consistent, though the id-0-equals-air
identification is from the XML, not from the binary (verify with `CellFactory_GetName(0)`).

---

## 3. The address chain

```c
#include <stdint.h>

/* --- constants ------------------------------------------------------------------ */
#define IB               0x400000u
#define P_SINGLETON      0x0122374Cu   /* [0x122374C] = lazily created 0x1A0-byte global */
#define P_GET_SINGLETON  0x00439BB0u   /* creates the singleton if [P_SINGLETON]==0        */
#define FN_GET_CELL_SLOT 0x0089C2D0u   /* ICell** __thiscall(gridHolder, int x, int y)     */
#define STATIC_EMPTY     0x01224644u   /* 4-byte zero in BSS                               */
#define VT_GRIDWORLD     0x010013BCu   /* grid::GridWorld vtable                           */
#define VT_GRIDWORLD_TH  0x01017B24u   /* grid::GridWorldThreaded vtable                   */
#define CELLDATA_STRIDE  0x290u
#define NAME_STRIDE      0x18u
#define CHUNK_PX         512u          /* world pixels per chunk, one grid entry per pixel */

/* MSVC std::string (32-bit): { char buf[16]; uint32 size; uint32 cap; }  */
static const char *msvc_c_str(const void *p) {
    const uint32_t cap = *(const uint32_t *)((const char *)p + 0x14);
    return (cap >= 0x10) ? *(const char *const *)p : (const char *)p;
}

/* --- 1. global chain ------------------------------------------------------------ */
void *S = *(void **)P_SINGLETON;                 /* if NULL: game not up yet; bail or call  */
                                                 /* ((void*(*)())P_GET_SINGLETON)()         */
void *worldRoot  = *(void **)((char *)S + 0x0C); /* quoted 0xBAA65D                         */
void *gridWorld  = *(void **)((char *)worldRoot + 0x44);      /* quoted 0xBAA660          */
void *gridHolder = (char *)gridWorld + 0x500;    /* == GridWorld::vtbl[3]() (0x4AD900)      */

/* optional robustness: GridWorldThreaded exposes the grid holder differently */
if (*(uint32_t *)gridWorld == VT_GRIDWORLD_TH)
    gridHolder = *(void **)((char *)gridWorld + 0x45C);   /* 0x7222B0: mov eax,[ecx+0x45c] */

void *cellFactory = *(void **)((char *)S + 0x18);         /* quoted 0x7AC0E9 / 0xBAA6A8    */
void *chunkTable  = *(void **)((char *)gridHolder + 8);   /* 512*512 pointers (0x100000 B) */

/* --- 2. cell lookup at an arbitrary world pixel position ------------------------ */
/* Coordinates are WORLD PIXELS (the same units entity x/y and Lua Raytrace use).      */
void *get_icell(int x, int y) {
    uint32_t cy = (uint32_t)(((int32_t)y >> 9) - 0x100) & 0x1FFu;
    uint32_t cx = (uint32_t)(((int32_t)x >> 9) - 0x100) & 0x1FFu;
    void *chunk = ((void **)chunkTable)[cy * CHUNK_PX + cx];

    uint32_t *slot;
    if (!chunk) {
        slot = (uint32_t *)STATIC_EMPTY;                  /* value is 0 -> empty          */
    } else {
        uint32_t local = ((uint32_t)y & 0x1FFu) << 9 | ((uint32_t)x & 0x1FFu);
        slot = (uint32_t *)(*(uint32_t **)chunk + local); /* chunk+0 = cells base         */
    }
    return (void *)(uintptr_t)*slot;                      /* grid::ICell*, NULL == empty  */
}

/* --- 3. material ----------------------------------------------------------------- */
void *icell = get_icell(x, y);
if (!icell) { /* empty / air (material id 0, NULL CellData) */ }

void *cellData = *(void **)((char *)icell + 0x14);        /* == icell->vtbl[12]()         */
                                                          /*    (0x4AC0D0 in all 4 cells) */

#define CELLDATA_BASE() (*(uintptr_t *)((char *)cellFactory + 0x18))

int material_id = (int)(((char *)cellData - (char *)CELLDATA_BASE()) / CELLDATA_STRIDE);

/* bounds/validity */
int name_count = (int)((*(uint32_t *)((char *)cellFactory + 8)
                      - *(uint32_t *)((char *)cellFactory + 4)) / NAME_STRIDE);
/* 0 <= material_id < name_count */

const char *material_name =
    msvc_c_str((char *)(*(void **)((char *)cellFactory + 4)) + NAME_STRIDE * material_id);
```

Equivalently, per step of the chain in the prompt's notation:

```
grid_base   = *(void**)(*(void**)(*(void**)0x122374C + 0x0C) + 0x44) + 0x500;  /* gridHolder */
chunk_table = *(void**)(grid_base + 8);                       /* 512*512  pointers         */
chunk       = chunk_table[ ((cy-256)&511)*512 + ((cx-256)&511) ];   /* cx=x>>9, cy=y>>9     */
cell_slot   = chunk ? chunk->cells + 4*(((y&511)<<9)|(x&511)) : (uint32_t*)0x1224644;
icell       = *(void**)cell_slot;                             /* NULL == empty             */
cell_data   = *(void**)((char*)icell + 0x14);                 /* grid::CellData*           */
material_id = (cell_data - *(void**)(cellFactory + 0x18)) / 0x290;
```

### Useful engine functions a DLL can call instead of reimplementing

| VA | signature | notes |
|---|---|---|
| `0x439BB0` | `void* __cdecl(void)` | creates/returns the `0x122374C` singleton |
| `0x89C2D0` | `ICell** __thiscall(void* gridHolder, int x, int y)` (`ret 8`) | the cell-slot accessor; handles the NULL-chunk case |
| `0x4AD060` | `CellData* __thiscall(void* cellFactory, int id)` (`ret 4`) | `id==0 -> NULL` |
| `0x704E70` | `std::string* __thiscall(void* cellFactory, int id, std::string* out)` (`ret 8`) | material name by id |
| `0x4AD0A0` | `CellData* __thiscall(void* cellFactory, std::string* name)` (`ret 4)` | material by name |
| `0x4AC0D0` | `CellData* __thiscall(ICell*)` (`ret`) | `ICell::GetCellData()`; also vtbl slot 12 of any cell, which is the future-proof call |

Calling `0x89C2D0` with `ecx = gridHolder` is the recommended path: it is a plain non-virtual
function, it already implements the wrap/NULL-chunk logic, and it is the same code the engine's
own raytrace and ~180 other sites use.

---

## 4. How to verify at runtime

Three tests, in increasing strength. Test 1 needs no in-game setup and no guessing at all.

### Test 1 — the material-name table, checked against Lua (zero guesses)

This proves the id indexing, the `CellFactory` link and the `std::string` layout, without ever
touching the world grid.

* From a mod's Lua:
  ```lua
  for i = 0, 400 do
      local n = CellFactory_GetName(i)
      if n ~= nil and n ~= "" then print(i .. "\t" .. n) end
  end
  ```
* From the DLL, with `cf = *(void**)(*(void**)0x122374C + 0x18)`:
  ```
  count = (*(uint32_t*)(cf+8) - *(uint32_t*)(cf+4)) / 0x18
  for i in 0..count-1:
      p = (char*)(*(void**)(cf+4)) + 0x18*i
      cap = *(uint32_t*)(p+0x14)
      str = (cap >= 0x10) ? *(char**)p : p
  ```
  The two lists must be **identical, including the count**. If they are, the whole
  CellFactory/stride/std::string model is confirmed.

### Test 2 — a forced material, read back through the world grid (end-to-end, no guessing)

Use the game's own debug action (`archive/ref-orin-data/entities/_debug/debug_menu.lua:561`,
*"ConvertMaterialOnAreaInstantly() - test near camera"*), which runs:

```lua
local x, y = GameGetCameraPos()
local dim = 128
ConvertMaterialOnAreaInstantly( x-dim, y-dim, dim*2, dim*2,
                                CellFactory_GetType("rock_static"),
                                CellFactory_GetType("wood_prop"), true, true )
```

Then, in the DLL, read the cell at the camera position and compare:

```
cellData( camera )  ==  *(void**)(cellFactory + 0x18)
                     +  CellFactory_GetType("wood_prop") * 0x290
```

Print both the Lua `CellFactory_GetType("wood_prop")` value and the DLL's derived
`material_id`; they must be equal, and the name read from the names vector must be
`"wood_prop"`. Because the material was written by the engine at a known position, this test
cannot pass by accident. (Note `ConvertMaterialOnAreaInstantly`'s first four arguments are
pixel coordinates and width/height in pixels — see §6.)

### Test 3 — cheap self-checks to run every frame

```
*(uint32_t*)gridWorld   == 0x010013BC   /* GridWorld vtable: proves worldRoot+0x44 is right   */
*(uint32_t*)(gridWorld+0x500) == 0x200  /* the 512 constant written by 0x89BF90               */
chunkTable              != NULL         /* 0x100000-byte table allocated by 0x89BF90          */
0 <= material_id < count                /* id derived from the descriptor pointer is in range */
```
If assertion 1 fails, the `[singleton+0x0C] -> [+0x44]` link is wrong for your process state and
you should fall back to the raytrace's route `gridHolder = *(void**)(*(void**)(S+0x20))` (see
§3 caveat / §5).

### Things that will make a correct implementation look wrong

* `[0x122374C]` is 0 until the game creates the singleton. Check for NULL (or call `0x439BB0`).
* Do **not** cache `chunk`, `chunkTable` or `ICell*` across frames. Chunks are allocated and
  freed as the player moves; re-read the chunk pointer for every lookup.
* Do the read on a frame/main thread boundary. The engine has `grid::GridWorldThreaded`
  (`0x1017B24`); a foreign thread can observe a chunk table mid-rebuild.
* "Not allocated" is not "out of the world": an unallocated chunk yields `ICell* == NULL`, which
  means material id 0 (`air`), not an error.

---

## 5. What was ruled out (do not retry)

1. **`0x7E9E41`, `0x102650C`, `0x10264CC`, `0x10264D8` and "no `push imm32` for `Raytrace`".**
   Ruled out: an earlier scan added `0x400000` to *raw file offsets*. `.text` is
   `VA 0x401000 / raw 0x400`, so the result was 0x400 low, which is why disassembly there
   started mid-instruction (`00 01 = add byte ptr [ecx], al`). Correct VAs in §0/§2.1. All four
   functions are registered by a plain `push fn / push name / lua_setfield` sequence; there is
   no table loop or computed addressing to reverse.
2. **Linear capstone sweeps from the start of `.text` for xrefs.** Ruled out: such a sweep
   missed a plainly visible `call 0x7EFAF0` at `0x7BAA52` and reported 0 callers for
   `0x78DEE0` (which has 4). Use `xref.py`'s raw `E8/E9 rel32` byte scan instead; it cannot
   desync.
3. **"The grid entry is a packed material id (e.g. `*(uint16*)(cell + off)`)."** Ruled out.
   The 4-byte entry is a `grid::ICell*`; the cell filters call virtual functions on it
   (`RaytracePlatforms` does `mov ecx,[arg2]; test ecx,ecx; je; mov eax,[ecx]; call [eax+0x2c]`,
   i.e. dereferences it as an object with a vtable), and RTTI names the four concrete cell
   classes. `Raytrace`'s test is literally `ICell* == NULL`.
4. **"Noita cells are 8×8 px, so pixel→cell is `>>3`."** Ruled out *for this grid*. The raytrace
   and `ConvertMaterialOnAreaInstantly` both index with `(int)world_coordinate >> 9` and
   `& 0x1FF` — 512 units per chunk, one 4-byte entry per world **pixel**. No `>>3` appears in
   either path. `0x89BF90` allocating exactly `0x100000 = 512*512*4` for the table settles it.
   (The 8×8-pixel notion may describe something else, e.g. `LoadPixelScene` art; it is not this
   grid.)
5. **Reading a material id out of a cell directly, or a "pointer→id" helper in the engine.**
   Not found, and structurally not needed: the engine itself never converts a cell to an id.
   `0xBAA5F0` converts the *id* to a descriptor (`id*0x290 + [CellFactory+0x18]`) and compares
   pointers. Derive the id with the division instead. (I scanned all 81 `imul r32, r32, 0x290`
   sites; there is no reverse/division helper among them.)
6. **`GetMaterialiv` / `GetMaterialfv`, `CellFactory*` and `GetMaterialInventoryMainMaterial`
   as the route.** Confirmed unrelated to world cells: the first two are shader uniforms, and
   the inventory function reads a `MaterialInventoryComponent`, not the grid. Not retried.
7. **`[singleton+0x20]` as the primary route.** The raytrace does reach the same grid holder as
   `*(void**)(*(void**)(S+0x20))`, but I could not identify what owns the slot at `[S+0x20]`
   (the world object constructed at `0x6F0FD0` is stored at `[ebx+0x20]` and its `+0` field is
   zeroed, so it is not that object). Prefer the `[S+0x0C] -> +0x44` route, which is quoted from
   shipping code and structurally explained; use `[S+0x20]` only as a diagnostic cross-check.

## 6. Side finding: the `x±0.1` idiom confirms the units

`archive/ref-orin-data/scripts/buildings/racing_cart_move.lua:29` and
`scripts/projectiles/glue_anchor.lua:78` use
`RaytracePlatforms(x, y, x + 0.1, y)` / `RaytracePlatforms(center_x, center_y, center_x + 1, center_y)`.
`0x63FA50` handles these through the `len2 < 0.5` branch (`0x63FB76 test esi,esi; jg`, then
`0x63FB94 call 0x89C2D0` on `(int)x,(int)y`), i.e. a sub-pixel ray degenerates to "read this one
cell". That is the game's own "what cell am I in" probe, and it is exactly the code path a DLL
would take — it confirms both the pixel units and the single-cell accessor.
