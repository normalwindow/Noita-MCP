/* ============================================================================
 * xinput_hook.c -- Noita input-forge extension (32-bit DLL)
 * ============================================================================
 *
 * WHAT THIS IS
 *   A 32-bit DLL that installs inline (detour) hooks on two functions exported
 *   by the SDL2.dll that noita.exe already has mapped:
 *
 *       SDL_GetKeyboardState(int *numkeys)   -> const Uint8 *  (512-byte array)
 *       SDL_GetMouseState (int *x, int *y)   -> Uint32         (SDL button mask)
 *
 *   While a "forge" is active the hooks return FORGED state. The moment the
 *   forge expires or is cleared the hooks transparently return the real state
 *   by calling through the trampoline.
 *
 *   A third hook on SDL_PumpEvents() (called once per frame by the game)
 *   decrements a time-to-live counter; when it reaches zero all forges are
 *   cleared. This is the SAFETY mechanism that guarantees a forge cannot get
 *   permanently stuck on and hijack the player's input.
 *
 * WHY THE HOOKS ARE INSTALLED ON A WORKER THREAD
 *   DllMain runs while the process loader lock is held. Doing thread
 *   suspension / VirtualProtect / registry work from inside DllMain is a
 *   classic deadlock. So DllMain only resolves two pointers (GetModuleHandleA
 *   + GetProcAddress do NOT take the loader lock for an already-loaded module)
 *   and then hands off to a worker thread. DllMain waits (bounded) for the
 *   worker to finish so that the caller's LoadLibraryA does not return until
 *   the hooks are live. The worker thread deliberately calls NO loader-lock
 *   API (no LoadLibrary, no GetModuleFileName, no FlushInstructionCache) so
 *   the bounded wait cannot deadlock. See the marker-file note below.
 *
 * NO CRT IS USED
 *   Built with /MT but the code below only calls kernel32. Nothing here
 *   touches errno, locale, floating point, SEH or the C runtime, so there is
 *   no CRT-init ordering hazard during DllMain.
 *
 * THREAD-SAFETY MODEL  (read this before changing anything)
 *   - Every shared field below is a naturally-aligned 32-bit value accessed
 *     with Interlocked* or as a single volatile LONG. On x86 a naturally
 *     aligned 32-bit load/store is single-copy atomic, so readers can never
 *     observe a half-written field. There is no mutex anywhere on the hook
 *     path, therefore the hooks can never block and can never deadlock.
 *   - Forge slots are published as one packed 32-bit word (state in the low
 *     byte, scancode in the high three bytes) so "which key" and "up or down"
 *     can never be observed inconsistently.
 *   - A forge is only ever honoured while g_active != 0, and g_active is only
 *     ever set while g_ttl > 0. Clearing always drops g_active/g_ttl BEFORE
 *     wiping the slots, so a racing reader either sees the old complete forge
 *     (harmless, it is about to be discarded) or the cleared state.
 *   - The forged keyboard array (g_kb_shadow) is written by exactly one writer
 *     at a time in practice, guarded by a CAS on g_shadow_busy; a second
 *     concurrent reader that loses the CAS receives the REAL keyboard array
 *     instead. That trades a vanishingly rare stale frame for a guarantee that
 *     the array is never left in a torn state.
 *
 * PROLOGUE-LENGTH ASSUMPTION (explicitly documented, see CodeLen())
 *   The detour is a 5-byte relative JMP (E9 rel32) written at the target entry
 *   point. A trampoline holds the displaced original bytes followed by a jump
 *   back to target+len. We therefore need the smallest instruction count
 *   >= 5 whose byte length we can PROVE by decoding, plus a safety scan that
 *   refuses to install if any relative branch inside the displaced region
 *   points outside that region (relocating such a branch would corrupt it).
 *   If the prologue cannot be decoded with certainty, or if fewer than
 *   XH_MIN_SCAN (32) bytes are available before the next non-decoded byte,
 *   the hook is NOT installed. Doing nothing is always preferred over doing
 *   something unverified.
 * ==========================================================================*/

#include <windows.h>
#include <tlhelp32.h>

/* ---------------------------------------------------------------------------
 * SELF-CONTAINED SDL2 TYPE STAND-INS
 *
 * The Noita installation ships SDL2.dll but NOT the SDL2 SDK (there is no
 * include\SDL2 or SDL2.lib anywhere under the game directory), and this build
 * must not depend on downloading anything. So instead of #include <SDL.h> we
 * declare the only three things we need from SDL here.
 *
 * Why this is safe:
 *   - SDL2's ABI on Windows/x86 uses the cdecl calling convention for these
 *     functions (SDLCALL expands to nothing unless SDL_stdcall is defined,
 *     which the win32/x86 build does not do). __cdecl is MSVC's default, but
 *     we spell it out so the pointers below are unambiguous.
 *   - Uint32 is unsigned int (4 bytes) and Uint8 is unsigned char, matching
 *     SDL_stdinc.h exactly on every SDL2 platform.
 *   - We never link against SDL2.lib. Every SDL address is obtained at runtime
 *     with GetModuleHandleA("SDL2.dll") + GetProcAddress, so a mismatch in
 *     header version is impossible by construction: there are no headers.
 *
 * SDL_GetKeyboardState returns a pointer to an internal array of Uint8 indexed
 * by SDL_Scancode, whose length is SDL_NUM_SCANCODES == 512. SDL writes the
 * count into *numkeys when non-NULL.
 * ------------------------------------------------------------------------- */
typedef unsigned int   Uint32;
typedef unsigned char  Uint8;
#define SDLCALL __cdecl
#define XH_SDL_NUM_SCANCODES 512

/* Compile-time proof that our Uint32 stand-in really is 32 bits. */
typedef char xh_static_assert_u32[(sizeof(Uint32) == 4) ? 1 : -1];

#define XH_PING_MAGIC   0x58494E50  /* 'XINP' */
#define XH_MAX_FORGE    64
#define XH_KB_SIZE      XH_SDL_NUM_SCANCODES
#define XH_JMP_LEN      5           /* E9 rel32 */
#define XH_MIN_SCAN     32          /* bytes that must decode cleanly */
#define XH_DEFAULT_TTL  15
#define XH_MAX_TTL      600
#define XH_TTL_FALLBACK_MS 2000    /* used only if SDL_PumpEvents is missing */
#define XH_EXPORT __declspec(dllexport)
/* cdecl, matching what LuaJIT FFI assumes for these entry points. Declared
 * explicitly so a compiler flag change cannot silently alter the ABI the Lua
 * side is calling through. */
#define XH_CALL   __cdecl

#if !defined(_M_IX86)
#error "xinput_hook.c must be compiled for x86 (32-bit). Run build.ps1, which uses vcvars32.bat."
#endif

/* ------------------------------------------------------------------ types */

typedef const Uint8 *(SDLCALL *PFN_GetKeyboardState)(int *numkeys);
typedef Uint32        (SDLCALL *PFN_GetMouseState)(int *x, int *y);
typedef void          (SDLCALL *PFN_PumpEvents)(void);
/* SDL_PollEvent takes a pointer to SDL_Event and returns 1 if an event was
 * delivered. The event type is only known once the union layout is declared
 * further down, so this is typed as void* here and cast at the hook. */
typedef int           (SDLCALL *PFN_PollEvent)(void *event);

typedef struct {
    volatile LONG scancode;     /* -1 == slot empty                          */
    volatile LONG state;        /* 0 = force up, 1 = force down              */
} XH_KEYFORGE;

typedef struct {
    volatile LONG in_use;
    volatile LONG x;
    volatile LONG y;
    volatile LONG buttons;
} XH_MOUSEFORGE;

typedef struct {
    volatile LONG installed;
    volatile LONG stage;        /* how far setup got: 1..7 (diagnostics)     */
    volatile LONG last_error;   /* GetLastError() at the failing step        */
    volatile LONG bound_ok;
    volatile LONG prologue_len;
    volatile LONG iat_thunk;    /* 1 if the entry is an incremental-link JMP */
    volatile LONG worker_done;
    volatile LONG threads_suspended;
    volatile LONG patch_phase;  /* 0 none, 1 prot, 2 suspended, 3 patched    */
    void *target;
    void *trampoline;
    /* The original prologue bytes. Without these a failed or unwanted
     * installation cannot be undone, which would leave a live hook in the
     * process with no way to remove it. */
    BYTE  orig_bytes[XH_MIN_SCAN];
} XH_HOOKINFO;

/* Forward declarations for the removal helpers.
 *
 * They are defined near the bottom (they are only needed once hooks exist), but
 * the PollEvent hook earlier in the file rolls itself back on failure, so it needs
 * them visible from there. Getting this wrong is not cosmetic: C then assumes an
 * implicit `int` declaration, which later conflicts with the real `void`
 * definition and fails the build. */
static void XhRemoveOne(XH_HOOKINFO *hk);
static void XhRemoveAllHooks(void);
/* Used by XhInstallOne, defined further down with the thunk explanation. */
static BYTE *XhResolveRealTarget(BYTE *target);

/* ---------------------------------------------------------------- globals */

static HINSTANCE g_self = NULL;

/* forge state */
static XH_KEYFORGE   g_keyforge[XH_MAX_FORGE];
static XH_MOUSEFORGE g_mouse;
static volatile LONG g_ttl      = 0;
static volatile LONG g_active   = 0;      /* 1 while g_ttl > 0                 */
static volatile LONG g_def_ttl  = XH_DEFAULT_TTL;
static volatile LONG g_shadow_busy = 0;
static volatile LONG g_arm_tick = 0;
static BYTE g_kb_shadow[XH_KB_SIZE + 8];

/* counters, useful for diagnostics */
static volatile LONG g_calls_kb   = 0;
static volatile LONG g_calls_ms   = 0;
static volatile LONG g_frames     = 0;

/* hooks */
static XH_HOOKINFO g_hk_kb;
static XH_HOOKINFO g_hk_ms;
static XH_HOOKINFO g_hk_pump;
static XH_HOOKINFO g_hk_poll;       /* the SDL_PollEvent hook, the real target */

static PFN_GetKeyboardState g_real_kb   = NULL;
static PFN_GetMouseState    g_real_ms   = NULL;
static PFN_PumpEvents       g_real_pump = NULL;
static PFN_PollEvent        g_real_poll = NULL;

static BYTE  g_prologue_kb[XH_MIN_SCAN];
static BYTE  g_prologue_ms[XH_MIN_SCAN];
static BYTE  g_prologue_pump[XH_MIN_SCAN];
static BYTE  g_prologue_poll[XH_MIN_SCAN];

/* handoff DllMain -> worker */
static HANDLE          g_ev_start = NULL;
static HANDLE          g_ev_done  = NULL;
static volatile LONG   g_hook_ok  = 0;
static char            g_dll_dir[MAX_PATH];
static DWORD           g_target_pid = 0;

/* ------------------------------------------------------- tiny x86 decoder */

/* Byte-length of the addressing-form part of a ModRM byte (ModRM + disp).
 * 1 = ModRM already consumed, 2 = ModRM+SIB, 3 = ModRM+disp32, 4 = ModRM+disp8,
 * 5 = ModRM+disp32. Exact for 32-bit addressing. */
static const BYTE g_len_32[] = {
/* 0 */ 1,1,1,1,1,1,1,1, 2,2,2,2,2,2,2,2,
/* 1 */ 1,1,1,1,1,1,1,1, 2,2,2,2,2,2,2,2,
/* 2 */ 1,1,1,1,1,1,1,1, 2,2,2,2,2,2,2,2,
/* 3 */ 1,1,1,1,1,1,1,1, 2,2,2,2,2,2,2,2,
/* 4 */ 1,1,1,1,1,1,1,1, 2,2,2,2,2,2,2,2,
/* 5 */ 1,1,1,1,1,1,1,1, 2,2,2,2,2,2,2,2,
/* 6 */ 1,1,1,1,1,1,1,1, 2,2,2,2,2,2,2,2,
/* 7 */ 1,1,1,1,1,1,1,1, 2,2,2,2,2,2,2,2,
/* 8 */ 4,4,4,4,4,4,4,4, 4,4,4,4,4,4,4,4,
/* 9 */ 4,4,4,4,4,4,4,4, 4,4,4,4,4,4,4,4,
/* A */ 4,4,4,4,4,4,4,4, 4,4,4,4,4,4,4,4,
/* B */ 4,4,4,4,4,4,4,4, 4,4,4,4,4,4,4,4,
/* C */ 1,1,1,1,1,1,1,1, 2,2,2,2,2,2,2,2,
/* D */ 1,1,1,1,1,1,1,1, 2,2,2,2,2,2,2,2,
/* E */ 1,1,1,1,1,1,1,1, 2,2,2,2,2,2,2,2,
/* F */ 1,1,1,1,1,1,1,1, 2,2,2,2,2,2,2,2,
};
static const BYTE g_len_16[] = {
/* 0 */ 1,1,1,1,1,1,1,1, 2,2,2,2,2,2,2,2,
/* 1 */ 1,1,1,1,1,1,1,1, 2,2,2,2,2,2,2,2,
/* 2 */ 1,1,1,1,1,1,1,1, 2,2,2,2,2,2,2,2,
/* 3 */ 1,1,1,1,1,1,1,1, 2,2,2,2,2,2,2,2,
/* 4 */ 1,1,1,1,1,1,1,1, 2,2,2,2,2,2,2,2,
/* 5 */ 1,1,1,1,1,1,1,1, 2,2,2,2,2,2,2,2,
/* 6 */ 1,1,1,1,1,1,1,1, 2,2,2,2,2,2,2,2,
/* 7 */ 1,1,1,1,1,1,1,1, 2,2,2,2,2,2,2,2,
/* 8 */ 1,1,1,1,1,1,1,1, 1,1,1,1,1,1,1,1,
/* 9 */ 1,1,1,1,1,1,1,1, 1,1,1,1,1,1,1,1,
/* A */ 1,1,1,1,1,1,1,1, 1,1,1,1,1,1,1,1,
/* B */ 1,1,1,1,1,1,1,1, 1,1,1,1,1,1,1,1,
/* C */ 0,1,1,1,1,1,1,1, 1,1,1,1,1,1,1,1,
/* D */ 0,0,0,0,1,1,1,1, 0,0,0,0,0,0,0,0,
/* E */ 1,1,1,1,1,1,1,1, 1,1,1,1,1,1,1,1,
/* F */ 1,1,1,1,1,1,1,1, 0,0,0,0,1,1,1,1,
};
/* second byte of a 0F-prefixed opcode. -3 = bswap (full ModRM), -4 = no
 * operand (0F 06 clts, 0F 07 sysret, 0F 08 invd, 0F 09 wbinvd, 0F 0B ud2). */
static const BYTE g_len_0f[] = {
/* 0 */ -4,-3,-3,-3,-4,-4,-4,-4, -4,-4,0,-4,0,-3,-3,-3,
/* 1 */ 1,1,1,1,1,1,1,1, 1,0,0,0,0,0,1,1,
/* 2 */ -3,-3,-3,-3,0,0,0,0, 1,1,1,1,1,1,1,1,
/* 3 */ 0,0,0,0,0,0,-4,0, 0,0,0,0,0,0,0,0,
/* 4 */ 1,1,1,1,1,1,1,1, 1,1,1,1,1,1,1,1,
/* 5 */ 1,1,1,1,1,1,1,1, 1,1,1,1,1,1,1,1,
/* 6 */ 1,1,1,1,1,1,1,1, 1,1,1,1,1,1,1,1,
/* 7 */ 1,1,1,1,1,1,1,1, 1,1,1,1,1,1,1,1,
/* 8 */ 0,0,0,0,0,0,0,0, 0,0,0,0,0,0,0,0,
/* 9 */ 1,1,1,1,1,1,1,1, 1,1,1,1,1,1,1,1,
/* A */ 0,0,0,1,1,1,1,1, 0,0,0,0,1,1,1,1,
/* B */ 1,1,1,1,1,1,1,1, 1,1,1,1,1,1,1,1,
/* C */ 1,1,1,1,1,1,1,1, 1,1,1,1,1,1,1,1,
/* D */ 1,1,1,1,1,1,1,1, 1,1,1,1,1,1,1,1,
/* E */ 1,1,1,1,1,1,1,1, 1,1,1,1,1,1,1,1,
/* F */ 1,1,1,1,1,1,1,1, 1,1,1,1,1,1,1,1,
};

/* Returns instruction byte length, or 0 if we cannot decode it with
 * certainty. *plen is filled with the "implied" displacement/immediate length
 * so the caller can spot rel8/rel32 operands for the branch-target scan. */
static int XhCodeLen(const BYTE *code, int *plen)
{
    int i   = 0;
    BYTE op;
    int opsize16 = 0;
    int twobyte  = 0;
    int done     = 0;
    int len      = 0;
    int needSIB  = 0;

    *plen = 0;
    op = code[i];

    for (;;) {
        if (twobyte) {
            if (op == 0x38 || op == 0x3A) {
                /* three-byte opcode; 0x38 forms are length 2 (ModRM+SIB ok),
                 * 0x3A forms carry an imm8 we would have to size. Refuse. */
                if (op == 0x3A) return 0;
                len = 2;                       /* ModRM + SIB/operand */
                done = 1;
                break;
            }
            len = g_len_0f[op];
            if (len == 0) return 0;            /* unknown / not valid in 32-bit */
            if (len == -3) { len = 3; done = 1; break; }   /* bswap r32      */
            if (len == -4) { len = 0; done = 1; break; }   /* no operand     */
            if (len == 1)  needSIB = 1;        /* ModRM follows */
            else           done = 1;           /* fixed minimum  */
            break;
        }
        if ((op & 0xC0) == 0xC0) {
            BYTE lo = (BYTE)(op & 0x07);
            if (op == 0xC4 || op == 0xC5) return 0;        /* VEX, 32-bit: refuse */
            /* length already finalised above */
            len = g_len_16[lo];
            if (len == 0) return 0;
            done = 1;
            break;
        }
        /* opcode escape / prefix / one-byte opcode */
        op = (BYTE)((op << 4) + code[++i]);
        if (op == 0x0F) { twobyte = 1; op = code[++i]; continue; }
        if ((op & 0xC0) == 0xC0) {
            BYTE hi = (BYTE)(op >> 4);
            if (hi == 0x0F) { twobyte = 1; op = code[++i]; continue; }
        }
        len = g_len_16[(BYTE)(op >> 4)];
        if (len == 0) return 0;
        done = 1;
        break;
    }

    while (!done) {
        if (needSIB == 0) {
            const BYTE *tbl32 = opsize16 ? g_len_16 : g_len_32;
            BYTE modrm;
            BYTE c;
            if (i >= 15) return 0;             /* instruction cannot exceed 15 */
            modrm = code[i];
            c = tbl32[modrm];
            BYTE mod = (BYTE)(modrm >> 6);
            if (c == 2) {
                if (mod == 3) return 0;        /* invalid encoding */
                needSIB = 1;                   /* extra SIB byte follows */
                i++;
                continue;
            }
            if (c == 1) {
                if (mod == 3) {
                    if (opsize16) len--;
                    done = 1;
                    break;
                }
                i++;                            /* consume ModRM */
                continue;
            }
            if (c == 3 || c == 5) {
                if (mod != 3) {
                    if (c == 3) *plen += 1; else *plen += 4;
                    len += 4;
                }
                done = 1;
                break;
            }
            if (c == 4) {
                if (mod != 3) {
                    if (mod == 1) { *plen += 1; len += 1; }
                    else          { *plen += 4; len += 4; }
                }
                done = 1;
                break;
            }
            return 0;
        }
        needSIB = 0;
        i++;
    }

    len += i + 1;
    if (len > 15) return 0;
    if (len < 1)  return 0;
    return len;
}

/* ----------------------------------------------------------- memory utils */

static int XhWriteBytes(void *dst, const void *src, SIZE_T n)
{
    SIZE_T written = 0;
    return WriteProcessMemory(GetCurrentProcess(), dst, src, n, &written)
           && written == n;
}

static BYTE *XhReadBytes(const void *src, void *out, SIZE_T n)
{
    SIZE_T got = 0;
    if (!ReadProcessMemory(GetCurrentProcess(), src, out, n, &got) || got != n)
        return NULL;
    return (BYTE *)out;
}

/* Allocate executable memory within +/-2GB of "pNear" so that a 5-byte E9
 * relocation can reach it. Walks 1MB-aligned probe addresses outward.
 * NOTE: the parameter is deliberately NOT called `near` -- `near` is a legacy
 * MSVC keyword (__near) and using it as an identifier is a hard syntax error. */
static BYTE *XhAllocNear(void *pNear, SIZE_T size)
{
    SYSTEM_INFO si;
    ULONG_PTR want = (ULONG_PTR)pNear & ~(ULONG_PTR)0xFFFFF;
    ULONG_PTR lo, hi, a, step;
    int i;
    MEMORY_BASIC_INFORMATION mbi;

    GetSystemInfo(&si);
    lo = (ULONG_PTR)si.lpMinimumApplicationAddress;
    hi = (ULONG_PTR)si.lpMaximumApplicationAddress;

    for (i = 1; i < 2048; i++) {
        step = (ULONG_PTR)i * 0x100000;      /* 1 MB steps, outward            */
        a = want + step;
        if (a >= lo && a < hi) {
            if (!VirtualQuery((LPCVOID)a, &mbi, sizeof(mbi)))
                break;
            if (mbi.State == MEM_FREE) {
                BYTE *p = (BYTE *)VirtualAlloc((LPVOID)a, size,
                                               MEM_COMMIT | MEM_RESERVE,
                                               PAGE_EXECUTE_READWRITE);
                if (p) return p;
            }
        }
        if (want > lo + step) {
            a = want - step;
            if (!VirtualQuery((LPCVOID)a, &mbi, sizeof(mbi)))
                break;
            if (mbi.State == MEM_FREE) {
                BYTE *p = (BYTE *)VirtualAlloc((LPVOID)a, size,
                                               MEM_COMMIT | MEM_RESERVE,
                                               PAGE_EXECUTE_READWRITE);
                if (p) return p;
            }
        }
    }
    return NULL;   /* caller must then REFUSE to hook (trampoline too far) */
}

/* --------------------------------------------------------------- analysis */

/* Decode the entry prologue, decide how many bytes to displace, and report
 * whether the relocation is provably safe. Returns 0 on any doubt. */
static int XhAnalyzeTarget(BYTE *addr, int *pLen, int *pThunk)
{
    BYTE buf[XH_MIN_SCAN];
    int  off  = 0;
    int  plen = 0;
    int  need = XH_JMP_LEN;
    int  inner;
    BYTE *in;

    *pLen = 0;
    *pThunk = 0;
    if (!XhReadBytes(addr, buf, XH_MIN_SCAN)) return 0;

    /* An MSVC incremental-link entry point is `jmp rel32` (E9) with zeroed
     * padding (CC) after it. The real body is relocated in .text via the
     * linker's ILT thunk pointer. We refuse to hook that encoding because the
     * displaced JMP would have to be re-targeted; we instead report it so the
     * caller can skip with a clear diagnostic. */
    if (buf[0] == 0xE9 && buf[5] == 0xCC) { *pThunk = 1; return 0; }

    while (off < need && off < XH_MIN_SCAN) {
        int l = XhCodeLen(buf + off, &plen);
        if (l <= 0) return 0;
        if (off + l > XH_MIN_SCAN) return 0;
        off += l;
    }
    if (off < XH_JMP_LEN) return 0;

    /* Safety scan: every relative branch fully inside [0,off) must also point
     * inside [0,off). Anything else means relocation would corrupt control
     * flow -> refuse to hook. We are conservative: an instruction with a 4-byte
     * implied operand that is not a known branch simply causes refusal. */
    inner = 0;
    while (inner < off) {
        int l = XhCodeLen(buf + inner, &plen);
        if (l <= 0) return 0;
        in = buf + inner;
        if (in[0] == 0xE8 || in[0] == 0xE9) {          /* rel32 call/jmp */
            return 0;                                   /* never relocate  */
        }
        if (in[0] == 0xEB || (in[0] >= 0x70 && in[0] <= 0x7F) ||
            in[0] == 0xE3) {                            /* rel8 branch    */
            int disp = (signed char)in[1];
            int tgt  = inner + l + disp;
            if (tgt < 0 || tgt >= off) return 0;
        }
        if (in[0] == 0x0F && in[1] >= 0x80 && in[1] <= 0x8F) {  /* rel32 jcc */
            int disp = *(const int *)(in + 2);
            int tgt  = inner + l + disp;
            if (tgt < 0 || tgt >= off) return 0;
        }
        if (in[0] == 0x66 && in[1] == 0xE9) return 0;   /* 16-bit rel jmp */
        inner += l;
    }

    *pLen = off;
    return 1;
}

/* ------------------------------------------------------------- threading */

typedef struct {
    DWORD  *ids;
    LONG    count;
    LONG    cap;
} XH_ThreadList;

static BOOL CALLBACK XhThreadCb(HANDLE h, DWORD id, LPARAM param)
{
    XH_ThreadList *tl = (XH_ThreadList *)param;
    if (id == GetCurrentProcessId()) return TRUE;       /* never our own PID */
    if (tl->count < tl->cap) {
        if (id == GetCurrentThreadId()) return TRUE;    /* never ourself     */
        tl->ids[tl->count++] = id;
    }
    (void)h;
    return TRUE;
}

/* --------------------------------------------------------- patch install */

/* Write the detour. Order of operations is deliberate:
 *   1. VirtualProtect (may allocate / take locks) -- BEFORE suspending.
 *   2. Suspend every other thread in the process.
 *   3. Relocate the displaced bytes into the trampoline (done by caller before
 *      suspension, see XhInstallHook) and write the 5-byte JMP with a single
 *      WriteProcessMemory.
 *   4. Restore page protection and resume threads.
 * Note step 1 and step 4 are OUTSIDE the suspended window precisely so that no
 * suspended thread can be holding a lock we need. There is no way to be inside
 * a LoadLibraryA on the injecting side that would deadlock (our worker calls
 * no loader-lock API). */
static int XhInstallHook(XH_HOOKINFO *hk, BYTE *stubEntry, const BYTE *prologue,
                         int prolen)
{
    BYTE  patch[XH_JMP_LEN];
    BYTE *tramp;
    BYTE *target = (BYTE *)hk->target;
    DWORD oldProt = 0;
    ULONG_PTR rel;
    int   i, suspended = 0;
    DWORD *ids = NULL;
    XH_ThreadList tl;
    HANDLE snap;

    /* trampoline: [displaced bytes][E9 -> target+prolen] */
    tramp = XhAllocNear(target, 64);
    if (!tramp) { hk->last_error = 0xE001; return 0; }
    hk->trampoline = tramp;

    memcpy(tramp, prologue, (size_t)prolen);
    rel = (ULONG_PTR)(target + prolen) - (ULONG_PTR)(tramp + prolen + XH_JMP_LEN);
    if (rel != (ULONG_PTR)(INT32)rel) { hk->last_error = 0xE002; return 0; }
    tramp[prolen + 0] = 0xE9;
    *(INT32 *)(tramp + prolen + 1) = (INT32)rel;

    /* the forward detour: E9 rel32 to stubEntry */
    rel = (ULONG_PTR)stubEntry - (ULONG_PTR)(target + XH_JMP_LEN);
    if (rel != (ULONG_PTR)(INT32)rel) { hk->last_error = 0xE003; return 0; }
    patch[0] = 0xE9;
    *(INT32 *)(patch + 1) = (INT32)rel;

    if (!VirtualProtect(target, XH_JMP_LEN, PAGE_EXECUTE_READWRITE, &oldProt)) {
        hk->last_error = (LONG)GetLastError();
        hk->patch_phase = 0;
        return 0;
    }
    hk->patch_phase = 1;

    ids = (DWORD *)LocalAlloc(LPTR, sizeof(DWORD) * 4096);
    if (ids) {
        tl.ids = ids; tl.count = 0; tl.cap = 4096;
        snap = CreateToolhelp32Snapshot(TH32CS_SNAPTHREAD, 0);
        if (snap != INVALID_HANDLE_VALUE) {
            THREADENTRY32 te;
            te.dwSize = sizeof(te);
            if (Thread32First(snap, &te)) {
                do {
                    if (te.dwSize >= FIELD_OFFSET(THREADENTRY32, th32OwnerProcessID)
                                      + sizeof(te.th32OwnerProcessID)) {
                        XhThreadCb(NULL, te.th32ThreadID, (LPARAM)&tl);
                    }
                    te.dwSize = sizeof(te);
                } while (Thread32Next(snap, &te));
            }
            CloseHandle(snap);
        }
        for (i = 0; i < tl.count; i++) {
            HANDLE th = OpenThread(THREAD_SUSPEND_RESUME, FALSE, ids[i]);
            if (!th) continue;
            if (SuspendThread(th) != (DWORD)-1) suspended++;
            CloseHandle(th);
        }
    }
    hk->threads_suspended = suspended;
    hk->patch_phase = 2;

    if (!XhWriteBytes(target, patch, XH_JMP_LEN)) {
        hk->last_error = (LONG)GetLastError();
    } else {
        hk->installed = 1;
    }

    /* resume, then restore protection -- both deliberately outside the window */
    if (ids) {
        for (i = 0; i < tl.count; i++) {
            HANDLE th = OpenThread(THREAD_SUSPEND_RESUME, FALSE, ids[i]);
            if (!th) continue;
            ResumeThread(th);
            CloseHandle(th);
        }
        LocalFree(ids);
    }
    hk->patch_phase = 3;

    {
        DWORD dummy = 0;
        VirtualProtect(target, XH_JMP_LEN, oldProt, &dummy);
    }
    return hk->installed;
}

/* --------------------------------------------------------- hook bodies */

static Uint32 SDLCALL XhGetMouseState(int *x, int *y)
{
    Uint32 real;
    InterlockedIncrement(&g_calls_ms);
    if (g_active) {
        /* No trampoline needed for the real value: SDL sets *x/*y itself, and
         * we overwrite them below. Calling through is still cheaper/safer for
         * the button mask, so do that. */
        if (g_real_ms) real = g_real_ms(x, y);
        else           real = 0;
        if (g_mouse.in_use) {
            if (x) *x = (int)g_mouse.x;
            if (y) *y = (int)g_mouse.y;
            return (Uint32)g_mouse.buttons;
        }
        return real;
    }
    return g_real_ms ? g_real_ms(x, y) : 0;
}

static const Uint8 *SDLCALL XhGetKeyboardState(int *numkeys)
{
    const Uint8 *real;
    int i;
    LONG busy;

    InterlockedIncrement(&g_calls_kb);

    if (!g_active)
        return g_real_kb ? g_real_kb(numkeys) : (const Uint8 *)g_kb_shadow;

    real = g_real_kb ? g_real_kb(numkeys) : NULL;
    if (!real && numkeys) *numkeys = XH_KB_SIZE;

    /* Only one thread may build the forged array; losers get the real one. */
    busy = InterlockedCompareExchange(&g_shadow_busy, 1, 0);
    if (busy != 0)
        return real ? real : (const Uint8 *)g_kb_shadow;

    for (i = 0; i < XH_KB_SIZE; i++)
        g_kb_shadow[i] = real ? real[i] : 0;
    for (i = 0; i < XH_MAX_FORGE; i++) {
        LONG sc = g_keyforge[i].scancode;
        if (sc >= 0 && sc < XH_KB_SIZE)
            g_kb_shadow[sc] = (Uint8)(g_keyforge[i].state ? 1 : 0);
    }
    InterlockedExchange(&g_shadow_busy, 0);

    if (numkeys) *numkeys = XH_KB_SIZE;
    return (const Uint8 *)g_kb_shadow;
}

static void SDLCALL XhPumpEvents(void)
{
    LONG t;
    InterlockedIncrement(&g_frames);

    if (g_real_pump) g_real_pump();

    /* TTL bookkeeping happens AFTER the real pump so that a forge armed just
     * before this frame still gets served for the whole frame. */
    t = g_ttl;
    if (t > 0) {
        t--;
        if (t == 0) {
            /* Expire: drop active/ttl FIRST, then wipe slots. A racing reader
             * then either sees the complete old forge (about to be discarded)
             * or the cleared one -- never a half-cleared mixture. */
            InterlockedExchange(&g_ttl, 0);
            InterlockedExchange(&g_active, 0);
            InterlockedExchange(&g_shadow_busy, 0);
            InterlockedExchange(&g_mouse.in_use, 0);
            InterlockedExchange(&g_mouse.buttons, 0);
            for (int k = 0; k < XH_MAX_FORGE; k++)
                InterlockedExchange(&g_keyforge[k].scancode, -1);
        } else {
            InterlockedExchange(&g_ttl, t);
        }
    }
    /* Safety net: if SDL_PumpEvents was unavailable we still must not leave a
     * forge armed forever. Wall-clock watchdog. */
    if (g_active && t <= 0) {
        DWORD now = GetTickCount();
        if (now - (DWORD)g_arm_tick > XH_TTL_FALLBACK_MS) {
            InterlockedExchange(&g_active, 0);
            InterlockedExchange(&g_ttl, 0);
            InterlockedExchange(&g_mouse.in_use, 0);
            for (int k = 0; k < XH_MAX_FORGE; k++)
                InterlockedExchange(&g_keyforge[k].scancode, -1);
        }
    }
}

/* --------------------------------------------------------- tiny formatters
 * wsprintfA lives in user32.dll. This DLL deliberately imports from kernel32
 * ONLY: a smaller import surface means fewer things that can fail while the
 * target's loader lock is held, and it removes any chance of dragging the
 * process into a user32 initialisation we did not intend. So we format the few
 * diagnostics we need by hand. Everything is bounded -- no buffer overruns. */

static char *XhPutS(char *p, char *end, const char *s)
{
    while (s && *s && p < end) *p++ = *s++;
    return p;
}

static char *XhPutX(char *p, char *end, unsigned long v)
{
    static const char hexd[] = "0123456789ABCDEF";
    char tmp[9];
    int  i = 0;
    if (v == 0) { if (p < end) *p++ = '0'; return p; }
    while (v && i < 8) { tmp[i++] = hexd[v & 0xF]; v >>= 4; }
    while (i > 0 && p < end) *p++ = tmp[--i];
    return p;
}

static char *XhPutD(char *p, char *end, long v)
{
    char tmp[12];
    int  i = 0;
    unsigned long u;
    if (v < 0) { if (p < end) *p++ = '-'; u = (unsigned long)(-(v + 1)) + 1UL; }
    else u = (unsigned long)v;
    if (u == 0) { if (p < end) *p++ = '0'; return p; }
    while (u && i < 11) { tmp[i++] = (char)('0' + (u % 10)); u /= 10; }
    while (i > 0 && p < end) *p++ = tmp[--i];
    return p;
}

static void XhTerm(char *p, char *begin, char *end)
{
    if (p < end) *p = 0; else if (end > begin) *(end - 1) = 0;
}

/* ---------------------------------------------------------- exported API */

XH_EXPORT int xh_ping(void)
{
    return (int)XH_PING_MAGIC;
}

XH_EXPORT void xh_set_key_forge(int scancode, int down)
{
    int i, free = -1;

    if (scancode < 0 || scancode >= XH_KB_SIZE) {
        /* scancode out of range: clear everything for that key (no-op if none)*/
        for (i = 0; i < XH_MAX_FORGE; i++)
            if (g_keyforge[i].scancode == scancode)
                InterlockedExchange(&g_keyforge[i].scancode, -1);
        return;
    }
    if (down < 0) {
        for (i = 0; i < XH_MAX_FORGE; i++)
            if (g_keyforge[i].scancode == scancode)
                InterlockedExchange(&g_keyforge[i].scancode, -1);
        g_active = (g_ttl > 0) ? 1 : 0;
        return;
    }
    for (i = 0; i < XH_MAX_FORGE; i++) {
        if (g_keyforge[i].scancode == scancode) {       /* update in place */
            InterlockedExchange(&g_keyforge[i].state, down ? 1 : 0);
            goto arm;
        }
        if (free < 0 && g_keyforge[i].scancode < 0) free = i;
    }
    if (free < 0) return;                                /* table full: drop  */
    InterlockedExchange(&g_keyforge[free].state, down ? 1 : 0);
    InterlockedExchange(&g_keyforge[free].scancode, scancode);

arm:
    /* NOTE: `InterlockedExchange(&g_ttl, g_ttl)` would be undefined behaviour --
     * passing a volatile global as the *value* argument of an interlocked
     * intrinsic is not a legal way to "read it atomically". Read it into a
     * local with an explicit atomic read first. */
    {
        LONG cur = InterlockedCompareExchange(&g_ttl, 0, 0);
        if (cur <= 0) InterlockedExchange(&g_ttl, g_def_ttl);
    }
    InterlockedExchange(&g_arm_tick, (LONG)GetTickCount());
    InterlockedExchange(&g_active, 1);
}

XH_EXPORT void xh_clear_forges(void)
{
    int i;
    InterlockedExchange(&g_ttl, 0);
    InterlockedExchange(&g_active, 0);
    InterlockedExchange(&g_shadow_busy, 0);
    InterlockedExchange(&g_mouse.in_use, 0);
    InterlockedExchange(&g_mouse.x, 0);
    InterlockedExchange(&g_mouse.y, 0);
    InterlockedExchange(&g_mouse.buttons, 0);
    for (i = 0; i < XH_MAX_FORGE; i++)
        InterlockedExchange(&g_keyforge[i].scancode, -1);
}

XH_EXPORT void xh_set_mouse_forge(int x, int y, int buttons)
{
    if (x < 0) {
        InterlockedExchange(&g_mouse.in_use, 0);
        InterlockedExchange(&g_mouse.buttons, 0);
        g_active = (g_ttl > 0) ? 1 : 0;
        return;
    }
    InterlockedExchange(&g_mouse.x, x);
    InterlockedExchange(&g_mouse.y, y);
    InterlockedExchange(&g_mouse.buttons, buttons);
    InterlockedExchange(&g_mouse.in_use, 1);
    {
        LONG cur = InterlockedCompareExchange(&g_ttl, 0, 0);
        if (cur <= 0) InterlockedExchange(&g_ttl, g_def_ttl);
    }
    InterlockedExchange(&g_arm_tick, (LONG)GetTickCount());
    InterlockedExchange(&g_active, 1);
}

XH_EXPORT int xh_forge_frames_left(void)
{
    if (!g_active) return 0;
    return (int)g_ttl;
}

XH_EXPORT void xh_set_ttl(int frames)
{
    if (frames < 1) frames = 1;
    if (frames > XH_MAX_TTL) frames = XH_MAX_TTL;
    InterlockedExchange(&g_def_ttl, frames);
}

/* Diagnostics (not required by the spec, but invaluable when it misbehaves). */
XH_EXPORT int xh_status(int which)
{
    switch (which) {
    case 0: return (int)g_calls_kb;
    case 1: return (int)g_calls_ms;
    case 2: return (int)g_frames;
    case 3: return (int)g_hk_kb.installed;
    case 4: return (int)g_hk_ms.installed;
    case 5: return (int)g_hk_pump.installed;
    case 6: return (int)g_hk_kb.prologue_len;
    case 7: return (int)g_hk_ms.prologue_len;
    case 8: return (int)g_active;
    case 9: return (int)g_hk_kb.last_error;
    case 10: return (int)g_hk_ms.last_error;
    case 11: return (int)g_hk_pump.last_error;
    case 12: return (int)g_hk_pump.prologue_len;
    case 13: return (int)g_calls_kb;
    default: return 0;
    }
}

XH_EXPORT void *xh_target_addr(int which)
{
    if (which == 0) return g_hk_kb.target;
    if (which == 1) return g_hk_ms.target;
    if (which == 2) return g_hk_pump.target;
    if (which == 3) return g_hk_kb.trampoline;
    if (which == 4) return g_hk_ms.trampoline;
    if (which == 5) return g_hk_pump.trampoline;
    return NULL;
}

XH_EXPORT int xh_loaded_mark(void)
{
    /* Touching this export proves the module is mapped and its export table is
     * resolvable. Re-write the heartbeat file with a fresh tick. */
    char path[MAX_PATH];
    char body[192];
    char *p, *end;
    DWORD w;
    HANDLE f;

    lstrcpyA(path, g_dll_dir);
    lstrcatA(path, "\\xh_heartbeat.txt");
    p = body; end = body + sizeof(body) - 1;
    p = XhPutS(p, end, "ping=0x");
    p = XhPutX(p, end, (unsigned long)XH_PING_MAGIC);
    p = XhPutS(p, end, " pid=");
    p = XhPutD(p, end, (long)g_target_pid);
    p = XhPutS(p, end, " tick=");
    p = XhPutD(p, end, (long)GetTickCount());
    p = XhPutS(p, end, "\r\n");
    XhTerm(p, body, body + sizeof(body));

    f = CreateFileA(path, GENERIC_WRITE, FILE_SHARE_READ, NULL,
                    CREATE_ALWAYS, FILE_ATTRIBUTE_NORMAL, NULL);
    if (f == INVALID_HANDLE_VALUE) return 0;
    WriteFile(f, body, (DWORD)lstrlenA(body), &w, NULL);
    CloseHandle(f);
    return (int)XH_PING_MAGIC;
}


/* ------------------------------------------------------------- worker */

static void XhWriteMarker(const char *suffix, const char *detail)
{
    char path[MAX_PATH];
    char body[1024];
    char *p, *end;
    HANDLE f;
    DWORD w;

    lstrcpyA(path, g_dll_dir);
    lstrcatA(path, "\\");
    lstrcatA(path, suffix);

    p = body; end = body + sizeof(body) - 1;
    p = XhPutS(p, end, "xh_ping=0x");
    p = XhPutX(p, end, (unsigned long)XH_PING_MAGIC);
    p = XhPutS(p, end, "\r\npid=");
    p = XhPutD(p, end, (long)g_target_pid);
    p = XhPutS(p, end, "\r\ntick=");
    p = XhPutD(p, end, (long)GetTickCount());
    p = XhPutS(p, end, "\r\ndll=");
    p = XhPutS(p, end, g_dll_dir);
    p = XhPutS(p, end, "\\xinput_hook.dll\r\n");
    if (detail) p = XhPutS(p, end, detail);
    XhTerm(p, body, body + sizeof(body));

    f = CreateFileA(path, GENERIC_WRITE, FILE_SHARE_READ, NULL,
                    CREATE_ALWAYS, FILE_ATTRIBUTE_NORMAL, NULL);
    if (f == INVALID_HANDLE_VALUE) return;
    WriteFile(f, body, (DWORD)lstrlenA(body), &w, NULL);
    CloseHandle(f);
}

/* Build the detour stub for one target. The stub is
 *      E9 rel32 -> RealStub        (forwards to the real function)
 *      E9 rel32 -> our hook
 * but simpler and cheaper: the stub IS the C hook function itself, and the
 * "call the real thing" path uses g_real_*. If the trampoline could not be
 * placed in range we refuse installation entirely, so g_real_* is only ever
 * the trampoline. */
static int XhInstallOne(XH_HOOKINFO *hk, const char *dllname, const char *fnname,
                        void *hookFn, void **realOut,
                        BYTE *prologue)
{
    HMODULE mod;
    BYTE *target;
    int plen = 0, thunk = 0;
    BYTE *tramp;
    char detail[256];

    hk->stage = 1;
    mod = GetModuleHandleA(dllname);
    if (!mod) { hk->last_error = 0xE020; return 0; }
    hk->stage = 2;
    target = (BYTE *)GetProcAddress(mod, fnname);
    if (!target) { hk->last_error = 0xE021; return 0; }

    /* SDL2's exports are 7-byte import thunks whose prologue analysis is both
     * wrong (6 vs 7 bytes, truncating `jmp eax`) and useless to hook. Follow the
     * thunk to the real implementation and hook that instead. */
    {
        BYTE *real = XhResolveRealTarget(target);
        if (real && real != target) {
            hk->iat_thunk = 1;
            target = real;
        }
    }

    hk->target = target;
    hk->stage = 3;

    if (!XhAnalyzeTarget(target, &plen, &thunk)) {
        hk->last_error = thunk ? 0xE010 : 0xE011;   /* 0xE010 = ILT thunk entry */
        hk->prologue_len = 0;
        return 0;
    }
    hk->prologue_len = plen;
    hk->stage = 4;
    if (!XhReadBytes(target, prologue, (SIZE_T)plen)) {
        hk->last_error = (LONG)GetLastError();
        return 0;
    }
    /* Keep a copy so this hook can be removed again. A patch with no saved
     * original is a one-way door. */
    memcpy(hk->orig_bytes, prologue, (size_t)plen);
    /* The detour source must live within +/-2GB of the target. Our own DLL
     * image is wherever the injector put it; if that is too far we make an
     * in-range 5-byte forwarder and jump through that instead. */
    {
        ULONG_PTR rel = (ULONG_PTR)hookFn - (ULONG_PTR)(target + XH_JMP_LEN);
        if (rel != (ULONG_PTR)(INT32)rel) {
            BYTE *farstub = XhAllocNear(target, 32);
            if (!farstub) { hk->last_error = 0xE004; return 0; }
            rel = (ULONG_PTR)hookFn - (ULONG_PTR)(farstub + XH_JMP_LEN);
            farstub[0] = 0xE9;
            *(INT32 *)(farstub + 1) = (INT32)rel;
            hookFn = farstub;
        }
    }
    hk->stage = 5;

    if (!XhInstallHook(hk, (BYTE *)hookFn, prologue, plen)) {
        return 0;
    }
    hk->stage = 6;
    tramp = (BYTE *)hk->trampoline;
    if (!tramp) { hk->last_error = 0xE005; return 0; }

    *realOut = (void *)tramp;
    hk->bound_ok = 1;
    hk->stage = 7;

    {
        char *p = detail, *end = detail + sizeof(detail) - 1;
        p = XhPutS(p, end, "hook ");
        p = XhPutS(p, end, dllname);
        p = XhPutS(p, end, "!");
        p = XhPutS(p, end, fnname);
        p = XhPutS(p, end, " target=0x");
        p = XhPutX(p, end, (unsigned long)(ULONG_PTR)target);
        p = XhPutS(p, end, " prologue=");
        p = XhPutD(p, end, plen);
        p = XhPutS(p, end, " bytes\r\n");
        XhTerm(p, detail, detail + sizeof(detail));
    }
    XhWriteMarker("xh_loaded.txt", detail);
    return 1;
}

/* SAFETY GATE -- read this before changing it.
 *
 * Hooking is now OPT-IN and OFF BY DEFAULT. The reason is a real incident: loading
 * the previous build froze the whole machine. Merely being present in the process
 * must therefore never be able to change the game's behaviour, or a player who
 * copies the DLL in without reading anything can hang their PC.
 *
 * The contract:
 *   DllMain / worker  -- resolve pointers, report status. NO hooks. Ever.
 *   xh_install_hooks  -- an explicit call, from Lua, installs them.
 *
 * xh_install_hooks refuses to install only SOME of the hooks: a half-installed set
 * (for example keyboard but not pump, so the TTL never ticks down) would leave a
 * forge that never expires, which is worse than not hooking at all. If any hook
 * fails to analyse or install, all of them are removed again.
 *
 * xh_remove_hooks restores the original bytes, so a bad state can be undone
 * without restarting the game.
 */
static volatile LONG g_install_requested = 0;   /* set by xh_install_hooks      */
static volatile LONG g_hooks_installed   = 0;   /* 1 only when all three are in */

/* Forward declarations for the removal helpers.
 *
 * They are defined near the bottom (they are only needed once hooks exist), but
 * the PollEvent hook earlier in the file can roll itself back, so it needs them
 * visible from there. Getting this wrong is not cosmetic: an implicit declaration
 * assumes `int`, which then conflicts with the real `void` definition. */
static void XhRemoveOne(XH_HOOKINFO *hk);
static void XhRemoveAllHooks(void);

/* -------------------------------------------------------- thunk resolution */

/* SDL2.dll's exported input functions are NOT the real functions.
 *
 * Disassembling SDL2.dll shows every one of them is a 7-byte import thunk:
 *
 *   SDL_PollEvent @ 0x6C75B720:            real implementation @ 0x6C7550F0:
 *     mov eax, [0x6C80F314]   (5 bytes)      push ebx
 *     jmp eax                 (2 bytes)      mov ebx, [esp + 8]
 *     mov esi, esi  <- padding               call ...
 *
 * Two consequences, and together they explain three separate crashes:
 *
 *   1. The prologue is SEVEN bytes, not six. The analysis reported 6 and copied 6,
 *      so `jmp eax` was cut in half and the trampoline held a truncated
 *      instruction. Jumping into that wedges or crashes the process -- this is the
 *      real reason the PumpEvents, PollEvent and keyboard/mouse hooks all failed,
 *      not the individual hook bodies.
 *   2. Hooking the thunk would be pointless even with the right length: it only
 *      forwards. The real logic lives at the IAT target, which the thunk re-reads
 *      on every call.
 *
 * So the address inside the thunk's `mov eax, [imm32]` is read and the REAL
 * function is hooked. That one has an ordinary prologue with clean instruction
 * boundaries. */
static BYTE *XhResolveRealTarget(BYTE *target)
{
    BYTE *slot;
    ULONG_PTR real = 0;

    if (!target) return NULL;
    if (target[0] != 0xA1) return target;      /* already a real function */

    slot = (BYTE *)(ULONG_PTR)(*(UINT32 *)(target + 1));
    if (!slot) return target;

    /* The slot is only safe to read if it is mapped; XhReadBytes uses the guarded
     * path, so a bogus slot cannot fault the process. */
    if (!XhReadBytes(slot, (BYTE *)&real, sizeof(real))) return target;
    if (!real) return target;

    return (BYTE *)real;
}


/* ---------------------------------------------------------- time scaling */

/* Slows down or speeds up the game by scaling the clock it reads.
 *
 * THE APPROACH IS NOT MY INVENTION, IT IS CHEAT ENGINE'S -- and that is the point. An earlier
 * search for Noita's own time variable was looking for the wrong thing. The engine does not
 * keep a "time scale"; it asks Windows what time it is, every frame, and integrates whatever
 * it gets. There is no variable to find. What you change is the ANSWER.
 *
 * Confirmed from the import tables rather than assumed:
 *
 *   noita.exe  -> KERNEL32.dll: QueryPerformanceCounter, QueryPerformanceFrequency,
 *                              GetSystemTimeAsFileTime, GetSystemTime, GetLocalTime
 *   SDL2.dll   -> KERNEL32.dll: QueryPerformanceCounter, QueryPerformanceFrequency,
 *                              GetSystemTimeAsFileTime, GetTickCount
 *              -> WINMM.dll:    timeGetTime
 *
 * The engine imports the timing functions DIRECTLY, not through SDL. That decides where to
 * hook: patching the prologue of kernel32!QueryPerformanceCounter covers every caller in the
 * process, including SDL, so one hook does the job. Hooking an SDL export would miss the
 * engine's own calls entirely.
 *
 * WHY AN ANCHORED SCALE AND NOT A MULTIPLIER ON THE RAW COUNTER
 *
 * QueryPerformanceCounter's value counts ticks since boot; on a machine up for hours it is
 * around 10^13, and the low bits are the resolution that matters. Multiplying that directly
 * overflows, and doing it in floating point throws away exactly those low bits. So the
 * counter is ANCHORED: the first value becomes the origin and later values are scaled as
 * `origin + (now - origin) * scale`. Both deltas stay small, the arithmetic is integer, and
 * precision is preserved however long the machine has been up.
 *
 * WHAT THIS DOES, AND WHAT CANNOT BE READ FROM THE FRAME RATE
 *
 *   scale < 1  slows the game. Directly measurable: game time advances slower than wall time
 *              while the frame rate is unchanged.
 *   scale > 1  speeds it up, but only until the engine reaches its own frame-rate ceiling.
 *              Past that, frames per second stops rising because frames are not free. So
 *              acceleration is real but its SIZE cannot be read from the frame rate; it has to
 *              be measured as (game ticks elapsed) / (real ticks elapsed). Both numbers are
 *              exposed for that reason.
 *
 * QueryPerformanceFrequency is deliberately left alone: the ratio between the counter and
 * seconds stays consistent, so anything dividing one by the other still gets a coherent
 * duration. */

typedef BOOL (WINAPI *PFN_QPC)(LARGE_INTEGER *);
typedef DWORD (WINAPI *PFN_TGT)(void);

static PFN_QPC  g_real_qpc = NULL;
static PFN_TGT  g_real_tgt = NULL;
static XH_HOOKINFO g_hk_qpc;
static XH_HOOKINFO g_hk_tgt;
static BYTE g_prologue_qpc[XH_MIN_SCAN];
static BYTE g_prologue_tgt[XH_MIN_SCAN];

/* Fixed point, 1/65536 of a unit. A float would drift and cannot be combined atomically; an
 * integer can be, and 16 fractional bits is far more resolution than a clock needs.
 *
 * THE ANCHOR IS STORED AS BOTH A RAW AND A SCALED VALUE, and that is not a detail -- getting
 * it wrong froze the game.
 *
 * The first version stored only a scaled origin and set it lazily, so on the first scaled read
 * after enabling a 0.25x scale the origin was still 0 and the value became
 * `raw * 0.25` -- the clock jumped BACKWARDS by roughly 10^13 ticks at the moment the scale
 * was applied. The engine uses this counter to pace its frames, so a clock that jumps back
 * leaves it waiting for a deadline it has already passed, and the process wedges.
 *
 * Keeping the raw anchor alongside the scaled one makes the mapping
 * `scaled = scaled_anchor + (raw - raw_anchor) * scale`, which is continuous at the moment the
 * scale changes: at raw == raw_anchor it yields exactly scaled_anchor, whatever the scale.
 * The counter is also clamped so it can never go backwards, even if a caller changes the scale
 * at an awkward moment.
 *
 * THE LOCK IS REQUIRED. The engine polls the clock from more than one thread; without a
 * critical section a reader can observe a new scale with an old anchor and see time move
 * backwards, which is the same wedge by a different route. */
static volatile LONG   g_time_scale_fp = 65536;   /* 1.0, in 1/65536 units */
static volatile LONG   g_time_active   = 0;
static volatile LONG64 g_time_raw_anchor    = 0;
static volatile LONG64 g_time_scaled_anchor = 0;
static volatile LONG64 g_time_last_scaled   = 0;
static volatile LONG   g_time_calls    = 0;
static volatile LONG   g_time_scaled   = 0;
static volatile LONG   g_time_backwards = 0;

static CRITICAL_SECTION g_time_lock;
static volatile LONG    g_time_lock_ready = 0;

/* Created on first use rather than in DllMain: creating a lock inside DllMain risks a loader
 * deadlock, and this is the documented reason not to do work there. */
static void XhTimeLockInit(void)
{
    if (InterlockedCompareExchange(&g_time_lock_ready, 1, 0) == 0) {
        InitializeCriticalSection(&g_time_lock);
        InterlockedExchange(&g_time_lock_ready, 2);
    }
}

static void XhTimeLock(void)
{
    if (g_time_lock_ready == 2) EnterCriticalSection(&g_time_lock);
}

static void XhTimeUnlock(void)
{
    if (g_time_lock_ready == 2) LeaveCriticalSection(&g_time_lock);
}

XH_EXPORT int XH_CALL xh_time_calls(void)     { return (int)g_time_calls; }
XH_EXPORT int XH_CALL xh_time_scaled(void)    { return (int)g_time_scaled; }
XH_EXPORT int XH_CALL xh_time_active(void)    { return (int)g_time_active; }
/* Non-zero if a backwards step was ever observed and clamped. Should stay 0; anything else
 * means the anchor and the scale were momentarily inconsistent. */
XH_EXPORT int XH_CALL xh_time_backwards(void) { return (int)g_time_backwards; }

XH_EXPORT int XH_CALL xh_qpc_points(LONGLONG *raw_anchor, LONGLONG *scaled_anchor,
                                    LONGLONG *last_scaled, LONGLONG *current_raw)
{
    LARGE_INTEGER now;
    if (!raw_anchor || !scaled_anchor || !last_scaled || !current_raw) return 0;
    if (!g_real_qpc || !g_real_qpc(&now)) return 0;
    *raw_anchor    = g_time_raw_anchor;
    *scaled_anchor = g_time_scaled_anchor;
    *last_scaled   = g_time_last_scaled;
    *current_raw   = now.QuadPart;
    return 1;
}

/* The raw counter and the value the engine would see from it, read together.
 *
 * This is what makes the pre-flight check meaningful. Reporting the anchors instead was the
 * first attempt and it was misleading: `last_scaled` cannot change while scaling is off, so a
 * healthy, disabled hook reported a stale zero and the check declared the mapping unsound.
 * A check that measures the wrong thing is worse than none, because it teaches you to ignore
 * it.
 *
 * Deliberately does NOT increment the scaled counter: this is a diagnostic read, and counting
 * it would make the statistics report scaling that the engine never saw. */
XH_EXPORT int XH_CALL xh_qpc_both(LONGLONG *raw_out, LONGLONG *mapped_out)
{
    LARGE_INTEGER now;
    LONGLONG r;

    if (!raw_out || !mapped_out) return 0;
    if (!g_real_qpc || !g_real_qpc(&now)) return 0;
    r = now.QuadPart;
    *raw_out = r;

    if (!g_time_active || g_time_scale_fp == 65536) {
        *mapped_out = r;                      /* identity when off */
        return 1;
    }

    XhTimeLock();
    *mapped_out = g_time_scaled_anchor +
                  (LONGLONG)((r - g_time_raw_anchor) * (LONGLONG)g_time_scale_fp / 65536);
    XhTimeUnlock();
    return 1;
}

/* The current scale as a plain number, for reporting. */
XH_EXPORT double XH_CALL xh_time_scale_get(void)
{
    return (double)g_time_scale_fp / 65536.0;
}

/* Sets the scale. Returns 1 if accepted.
 *
 * Re-anchors at the current true counter, so the value the game sees is CONTINUOUS across the
 * change: it does not jump forwards or backwards when the scale changes, and setting 1.0
 * restores the true counter from that moment on. */
XH_EXPORT int XH_CALL xh_time_scale_set(double scale)
{
    LONG fp;
    LARGE_INTEGER now;

    if (scale < 0.01) scale = 0.01;   /* slower than 1% would look frozen */
    if (scale > 20.0) scale = 20.0;   /* beyond this only the engine's ceiling is visible */

    fp = (LONG)(scale * 65536.0 + 0.5);

    XhTimeLockInit();
    XhTimeLock();

    /* Anchor at the raw value the engine would read right now. If a scale is already running,
     * anchor at the value the game is currently SEEING, so there is no discontinuity. */
    if (g_real_qpc && g_real_qpc(&now)) {
        if (g_time_active) {
            LONGLONG shown = g_time_scaled_anchor +
                             (LONGLONG)((now.QuadPart - g_time_raw_anchor) *
                                        (LONGLONG)g_time_scale_fp / 65536);
            if (shown < g_time_last_scaled) shown = g_time_last_scaled;
            g_time_scaled_anchor = shown;
            g_time_last_scaled   = shown;
        } else {
            g_time_scaled_anchor = now.QuadPart;
            g_time_last_scaled   = now.QuadPart;
        }
        g_time_raw_anchor = now.QuadPart;
    }

    InterlockedExchange(&g_time_scale_fp, fp);
    InterlockedExchange(&g_time_active, 1);

    XhTimeUnlock();
    return 1;
}

XH_EXPORT int XH_CALL xh_time_scale_clear(void)
{
    LARGE_INTEGER now;

    XhTimeLockInit();
    XhTimeLock();
    /* Anchor back to the true counter, so clearing is an exact restore rather than a jump. */
    if (g_real_qpc && g_real_qpc(&now)) {
        g_time_raw_anchor    = now.QuadPart;
        g_time_scaled_anchor = now.QuadPart;
        g_time_last_scaled   = now.QuadPart;
    }
    InterlockedExchange(&g_time_scale_fp, 65536);
    InterlockedExchange(&g_time_active, 0);
    XhTimeUnlock();
    return 1;
}

/* Shared by both hooks.
 *
 * `active` gates the work as well as the stamping, so with scaling off this is one predictable
 * branch and the engine's timing is untouched. */
static LONGLONG XhScaleCounter(LONGLONG raw)
{
    LONGLONG out;

    /* FAST PATH, and it matters: the engine reads this clock around 800 times per frame --
     * measured at 3,012,117 calls a few seconds into a run. Taking a lock on every one of
     * those would turn a timing change into a stutter, so the two cases that need no work
     * (scaling off, scale exactly 1.0) return before touching it. Reading the scale twice is
     * deliberate: the first read is outside the lock to skip it, the second is inside, where
     * it cannot change underneath the arithmetic. */
    if (!g_time_active) return raw;
    if (g_time_scale_fp == 65536) return raw;

    XhTimeLock();

    if (!g_time_active || g_time_scale_fp == 65536) {
        XhTimeUnlock();
        return raw;
    }

    /* PURE FUNCTION OF `raw`. No shared mutable state, and that is deliberate.
     *
     * The first version clamped the result against a global high-water mark, to guarantee the
     * clock could not step backwards. That was both unnecessary and wrong. Unnecessary,
     * because with a constant scale a strictly increasing input produces a strictly increasing
     * output -- the property comes from the formula. Wrong, because the engine reads this
     * clock from several threads: the last writer to the high-water mark is not the reader
     * with the largest raw value, so threads clobbered each other and the clamp fired
     * constantly -- 2,858 spurious "backwards" steps while the mapping was in fact monotonic.
     *
     * Continuity across a scale CHANGE is handled where the change happens, in
     * xh_time_scale_set, which re-anchors at the currently displayed value. That is the only
     * place the invariant can actually be broken. */
    InterlockedIncrement(&g_time_scaled);
    XhTimeUnlock();

    return g_time_scaled_anchor +
           (LONGLONG)((raw - g_time_raw_anchor) * (LONGLONG)g_time_scale_fp / 65536);
}

static BOOL WINAPI XhQueryPerformanceCounter(LARGE_INTEGER *out)
{
    BOOL ok;

    InterlockedIncrement(&g_time_calls);
    ok = g_real_qpc ? g_real_qpc(out) : 0;
    if (!ok || !out) return ok;

    out->QuadPart = XhScaleCounter(out->QuadPart);
    return ok;
}

static DWORD WINAPI XhTimeGetTime(void)
{
    DWORD raw;

    InterlockedIncrement(&g_time_calls);
    raw = g_real_tgt ? g_real_tgt() : 0;
    if (!g_time_active || g_time_scale_fp == 65536) return raw;

    /* A 32-bit millisecond counter wraps every 49 days; scaling it in place is fine for the
     * frame-sized deltas that use it, and consistency with QPC matters more than its absolute
     * value. */
    return (DWORD)(XhScaleCounter((LONGLONG)raw) & 0xFFFFFFFF);
}

XH_EXPORT int XH_CALL xh_install_timehooks(void)
{
    int ok_qpc, ok_tgt;

    if (g_real_qpc) return 1;

    ok_qpc = XhInstallOne(&g_hk_qpc, "kernel32.dll", "QueryPerformanceCounter",
                          (void *)XhQueryPerformanceCounter, (void **)&g_real_qpc,
                          g_prologue_qpc);
    if (!ok_qpc || !g_real_qpc) {
        if (ok_qpc) XhRemoveOne(&g_hk_qpc);
        return 0;
    }

    /* timeGetTime is best effort: the engine's own timing goes through QPC, and SDL may use
     * either. A failure here is recorded but does not fail the install, because a scale that
     * works for the engine and not for SDL's fallback clock is still a working scale. */
    ok_tgt = XhInstallOne(&g_hk_tgt, "winmm.dll", "timeGetTime",
                          (void *)XhTimeGetTime, (void **)&g_real_tgt, g_prologue_tgt);
    if (!ok_tgt) g_real_tgt = NULL;

    return 1;
}

XH_EXPORT int XH_CALL xh_remove_timehooks(void)
{
    xh_time_scale_clear();
    XhRemoveOne(&g_hk_qpc);
    if (g_real_tgt) XhRemoveOne(&g_hk_tgt);
    g_real_tgt = NULL;
    return 1;
}

XH_EXPORT int XH_CALL xh_timehooks_installed(void) { return g_real_qpc ? 1 : 0; }
XH_EXPORT int XH_CALL xh_time_tgt_installed(void)  { return g_real_tgt ? 1 : 0; }

/* The true and the scaled clock, side by side.
 *
 * The comparison is the whole measurement: the frame rate shows a slowdown but not the size of
 * an acceleration, because frames have a ceiling. Elapsed game time over elapsed real time is
 * the only honest number, and it needs both readings from the same process so the windows
 * match.
 *
 * xh_qpc_raw calls the REAL function directly rather than going through the hooked entry, so
 * it returns the unscaled value even while scaling is active. Without that there would be
 * nothing to compare against. */
XH_EXPORT int XH_CALL xh_qpc_raw(LONGLONG *out)
{
    LARGE_INTEGER v;
    if (!out) return 0;
    if (!g_real_qpc) return 0;
    if (!g_real_qpc(&v)) return 0;
    *out = v.QuadPart;
    return 1;
}

/* The counter as the game sees it, i.e. with the scale applied. Falls back to the raw value
 * when scaling is off, so a caller never has to special-case that. */
XH_EXPORT int XH_CALL xh_qpc_scaled(LONGLONG *out)
{
    LARGE_INTEGER v;
    if (!out) return 0;
    if (!g_real_qpc) return 0;
    if (!g_real_qpc(&v)) return 0;
    *out = XhScaleCounter(v.QuadPart);
    return 1;
}

/* The counter's frequency, so a caller can turn ticks into seconds. Read through the real
 * function because the frequency is deliberately never scaled. */
XH_EXPORT int XH_CALL xh_qpc_freq(LONGLONG *out)
{
    LARGE_INTEGER f;
    typedef BOOL (WINAPI *PFN_QPF)(LARGE_INTEGER *);
    HMODULE k = GetModuleHandleA("kernel32.dll");
    PFN_QPF fn;
    if (!out || !k) return 0;
    fn = (PFN_QPF)GetProcAddress(k, "QueryPerformanceFrequency");
    if (!fn || !fn(&f)) return 0;
    *out = f.QuadPart;
    return 1;
}


/* The correct target, found by parsing noita.exe's IMPORT TABLE rather than by
 * guessing or by string search:
 *
 *   SDL2.dll: SDL_PollEvent, SDL_GameControllerEventState,
 *             SDL_JoystickEventState, SDL_GetKeyName
 *
 * SDL_GetKeyboardState and user32!GetKeyboardState are NOT imported at all, which
 * is why the earlier hooks on them counted zero calls even while the player really
 * walked. SDL_PollEvent is the engine's only route for keyboard and mouse input.
 *
 * It is also a far safer target than SDL_PumpEvents:
 *   * called from the main thread's frame loop, not from arbitrary threads
 *   * does NOT call back into SDL, so a hook here cannot recurse -- that recursion
 *     is the failure mode that hung the machine when PumpEvents was hooked
 *   * forging edits the EVENT STRUCT rather than replacing a return value, so the
 *     surrounding contract is untouched
 *
 * Forging model: the real function is called first and its event is then adjusted.
 * A forge of N frames reports key-down on the first poll and key-up on the last,
 * so the engine is told the truth about the key's lifetime -- which is what a
 * game's own input state machine expects. Real input is never starved and the
 * number of events the engine sees never changes. */

#define XH_SDL_KEYDOWN      0x300u
#define XH_SDL_KEYUP        0x301u
#define XH_SDL_MOUSEMOTION  0x400u

/* SDL_Event is a union; these mirror the SDL2 definitions on 32-bit Windows. Only
 * the touched fields are named, but the full sizes are preserved so the offsets
 * match the real struct. */
typedef struct {
    UINT32 type;
    UINT32 timestamp;
    UINT32 windowID;
    UINT8  state;
    UINT8  repeat;
    UINT8  padding2;
    UINT8  padding3;
    struct { INT32 scancode; INT32 sym; UINT16 mod; UINT16 modpad; UINT32 unused; } keysym;
} XH_SDL_KeyboardEvent;

typedef struct {
    UINT32 type;
    UINT32 timestamp;
    UINT32 windowID;
    UINT32 which;
    UINT32 state;
    INT32  x;
    INT32  y;
    INT32  xrel;
    INT32  yrel;
} XH_SDL_MouseMotionEvent;

typedef union {
    UINT32 type;
    XH_SDL_KeyboardEvent    key;
    XH_SDL_MouseMotionEvent motion;
    UINT8 padding[64];
} XH_SDL_Event;

/* --------------------------------------------------- synthesising events */

/* Why this exists, and why it is the safest mechanism tried so far.
 *
 * The queue problem, measured: SDL_PollEvent is called ~100 times/second, but the
 * real poll returned an event on essentially none of them -- the engine drains the
 * queue before we see it. Rewriting a polled event therefore only ever worked by
 * accident, when the operator happened to move the mouse and produced traffic.
 *
 * Supplying an event from the hook and returning 1 was tried and FROZE the machine:
 * the engine's loop stops only when the poll reports no event.
 *
 * So instead of faking a poll, this asks SDL to enqueue a REAL event:
 *
 *   SDL_PushEvent(&e) puts a properly formed event into SDL's own queue.
 *
 * Which fixes both previous failures at once:
 *   * the engine receives it through its normal path, so every return value stays
 *     exactly as SDL computed it -- the deadlock above cannot occur
 *   * the struct is validated and owned by SDL, so no hand-written offsets are
 *     involved (mis-set fields were the other source of silent failure)
 *
 * THE LOCKING RULE, not optional: SDL_PushEvent must NOT be called from inside the
 * poll hook. The poll hook runs while SDL holds the event-queue lock, so pushing
 * from there would re-acquire it and deadlock. The bridge calls this from its
 * per-frame update instead, which runs outside SDL entirely. */
typedef int (SDLCALL *PFN_PushEvent)(const void *event);

static PFN_PushEvent g_push_event = NULL;
static volatile LONG g_push_ok    = 0;
static volatile LONG g_push_fail  = 0;
static volatile LONG g_push_last  = 0;

XH_EXPORT int XH_CALL xh_push_ok(void)   { return (int)g_push_ok; }
XH_EXPORT int XH_CALL xh_push_fail(void) { return (int)g_push_fail; }
XH_EXPORT int XH_CALL xh_push_last(void) { return (int)g_push_last; }

static PFN_PushEvent XhGetPushEvent(void)
{
    HMODULE mod;
    if (g_push_event) return g_push_event;
    mod = GetModuleHandleA("SDL2.dll");
    if (!mod) return NULL;
    g_push_event = (PFN_PushEvent)GetProcAddress(mod, "SDL_PushEvent");
    return g_push_event;
}

/* Pushes ONE key event into SDL's queue. state 1 = down, 0 = up.
 *
 * The event is built on the stack and handed to SDL, which copies it into the
 * queue, so nothing here outlives the call. Returns 1 when SDL accepted it.
 *
 * Call from OUTSIDE SDL (the bridge's frame update), never from a hook. */
XH_EXPORT int XH_CALL xh_push_key(int scancode, int state)
{
    XH_SDL_Event ev;
    PFN_PushEvent fn = XhGetPushEvent();

    if (!fn) { InterlockedIncrement(&g_push_fail); return 0; }
    if (scancode < 0 || scancode > 511) { InterlockedIncrement(&g_push_fail); return 0; }

    memset(&ev, 0, sizeof(ev));
    ev.type = state ? XH_SDL_KEYDOWN : XH_SDL_KEYUP;
    ev.key.type            = ev.type;
    ev.key.state           = state ? 1 : 0;
    ev.key.repeat          = 0;
    ev.key.keysym.scancode = scancode;
    ev.key.keysym.sym      = 0;
    ev.key.keysym.mod      = 0;

    {
        int rc = fn(&ev);            /* 1 = queued, 0 = queue full */
        InterlockedExchange(&g_push_last, rc);
        if (rc) InterlockedIncrement(&g_push_ok);
        else    InterlockedIncrement(&g_push_fail);
        return rc;
    }
}

static volatile LONG g_pe_calls     = 0;   /* how often the engine polls        */
static volatile LONG g_pe_forged    = 0;   /* events we rewrote                 */
static volatile LONG g_ev_forge_on  = 0;
static volatile LONG g_ev_scancode  = -1;
static volatile LONG g_ev_frames    = 0;
/* Hold length, kept so the hook can tell the FIRST poll of a hold (emit key-down)
 * from the LAST (emit key-up). Without it every poll looked alike and the forge
 * degenerated into a storm of taps. */
static volatile LONG g_ev_total     = 0;
static volatile LONG g_ev_real_seen = 0;   /* real key events observed          */
/* Counted before ANY early return, so "the hook ran at all" is separable from
 * "the hook reached the forging branch". Without this, a zero forged count cannot
 * distinguish a hook that is never called from one that returns early. */
static volatile LONG g_ev_entered   = 0;
/* Counted when the real poll returned an event, i.e. when there was something to
 * forge into. */
static volatile LONG g_ev_with_event = 0;

/* Build identity.
 *
 * Deployment kept appearing to be stale during development -- the same test would
 * pass and then fail with no code change, and there was no way to tell which build
 * the running game actually had. This string is written into every probe/status
 * marker, so the answer is one read away instead of a guess. Bump it whenever the
 * hook behaviour changes. */
#define XH_BUILD_ID "xh-build-2026-09-23-poll-minimal-1"

XH_EXPORT const char * XH_CALL xh_build_id(void) { return XH_BUILD_ID; }

/* Readable by Lua, so "installed" and "actually called" stay distinguishable.
 * That distinction is exactly what the earlier SDL_GetKeyboardState hooks lacked:
 * they installed fine and were never called. */
XH_EXPORT int XH_CALL xh_event_calls(void)     { return (int)g_pe_calls; }
XH_EXPORT int XH_CALL xh_event_forged(void)    { return (int)g_pe_forged; }
XH_EXPORT int XH_CALL xh_event_real_seen(void) { return (int)g_ev_real_seen; }
XH_EXPORT int XH_CALL xh_event_frames(void)    { return (int)g_ev_frames; }
XH_EXPORT int XH_CALL xh_event_entered(void)   { return (int)g_ev_entered; }
XH_EXPORT int XH_CALL xh_event_with_event(void){ return (int)g_ev_with_event; }

/* Internal state of the forge, for diagnosing "armed but nothing happened".
 *
 * This exists because a confusing state was reached once: poll_calls grew (so the
 * hook was live) while forged_events stayed at 0 (so the hook never took the
 * forging branch), and there was no way to tell from outside whether the arm call
 * had actually taken effect. Guessing at that costs a rebuild-and-restart cycle
 * each time; one getter answers it immediately. */
XH_EXPORT void XH_CALL xh_event_state(int *armed, int *frames, int *scancode, int *total)
{
    if (armed)    *armed    = (int)g_ev_forge_on;
    if (frames)   *frames   = (int)g_ev_frames;
    if (scancode) *scancode = (int)g_ev_scancode;
    if (total)    *total    = (int)g_ev_total;
}

XH_EXPORT int XH_CALL xh_event_forge_key(int scancode, int frames)
{
    if (scancode < 0 || scancode > 511) return 0;
    if (frames < 2) frames = 2;          /* need at least a down edge and an up */
    if (frames > 600) frames = 600;
    /* Arm the hold: total is the reference the hook compares against to detect the
     * rising edge, so it must be stored before the forge is marked active. */
    InterlockedExchange(&g_ev_scancode, scancode);
    InterlockedExchange(&g_ev_total, frames);
    InterlockedExchange(&g_ev_frames, frames);
    InterlockedExchange(&g_ev_real_seen, 0);
    InterlockedExchange(&g_ev_forge_on, 1);
    return 1;
}

XH_EXPORT void XH_CALL xh_event_forge_clear(void)
{
    InterlockedExchange(&g_ev_forge_on, 0);
    InterlockedExchange(&g_ev_frames, 0);
    InterlockedExchange(&g_ev_scancode, -1);
}

/* Pushes ONE mouse button event into SDL's queue.
 *
 * Noita fires the held wand on the LEFT MOUSE BUTTON, not on a key, so keyboard
 * synthesis is not enough for firing. SDL_MOUSEBUTTONDOWN = 0x401,
 * SDL_MOUSEBUTTONUP = 0x402, and SDL_BUTTON_LEFT = 1.
 *
 * The x/y carried on the event are the click position; they are taken from the
 * caller so the shot lands where the caller intends. Call from OUTSIDE SDL, same
 * locking rule as xh_push_key. */
#define XH_SDL_MOUSEBUTTONDOWN 0x401u
#define XH_SDL_MOUSEBUTTONUP   0x402u
#define XH_SDL_BUTTON_LEFT     1
#define XH_SDL_BUTTON_RIGHT    3

typedef struct {
    UINT32 type;
    UINT32 timestamp;
    UINT32 windowID;
    UINT32 which;
    UINT8  button;
    UINT8  state;
    UINT8  clicks;
    UINT8  padding1;
    INT32  x;
    INT32  y;
} XH_SDL_MouseButtonEvent;

typedef union {
    UINT32 type;
    XH_SDL_MouseButtonEvent button;
    UINT8 padding[64];
} XH_SDL_MouseEvent;

XH_EXPORT int XH_CALL xh_push_mouse(int button, int down, int x, int y)
{
    XH_SDL_MouseEvent ev;
    PFN_PushEvent fn = XhGetPushEvent();

    if (!fn) { InterlockedIncrement(&g_push_fail); return 0; }
    if (button != XH_SDL_BUTTON_LEFT && button != XH_SDL_BUTTON_RIGHT) {
        InterlockedIncrement(&g_push_fail);
        return 0;
    }

    memset(&ev, 0, sizeof(ev));
    ev.type = down ? XH_SDL_MOUSEBUTTONDOWN : XH_SDL_MOUSEBUTTONUP;
    ev.button.type    = ev.type;
    ev.button.button  = (UINT8)button;
    ev.button.state   = down ? 1 : 0;
    ev.button.clicks  = 1;
    ev.button.x       = x;
    ev.button.y       = y;

    {
        int rc = fn(&ev);
        InterlockedExchange(&g_push_last, rc);
        if (rc) InterlockedIncrement(&g_push_ok);
        else    InterlockedIncrement(&g_push_fail);
        return rc;
    }
}

/* The RIGHT target, and why -- this supersedes the SDL_PollEvent hook below.
 *
 * Measured from the previous attempt: hooking SDL_PollEvent, 405 invocations, and
 * `with_event` (real poll returned something) stayed at ZERO the whole time. The
 * engine drains the SDL queue itself, so by the time it reaches SDL_PollEvent there
 * is usually nothing left -- a forge could only ever rewrite a stray mouse or
 * window event. That is exactly why forging appeared to work when the operator
 * happened to move the mouse into the window, and did nothing when they did not.
 *
 * The fix tried next -- supplying an event and returning 1 when the queue was
 * empty -- FROZE the machine, because the engine's loop is
 *
 *     while (SDL_PollEvent(&e)) { handle(e); }
 *
 * and a poll that never returns 0 is a loop that never ends.
 *
 * Hence this design, which is safe by construction:
 *
 *   * hook SDL_PeepEvents, the call the engine actually drains the queue through
 *   * NEVER change the return value. The number of events the engine receives is
 *     exactly what SDL produced, so the caller's loop conditions are untouched and
 *     the deadlock above cannot happen.
 *   * only EDIT the contents of events the engine has already been given.
 *   * only while a forge is armed; otherwise touch nothing at all.
 *   * only for a GET, never ADD or PEEK, so nothing is written into the queue and
 *     no event is delivered twice.
 *
 * Signature:
 *   int SDL_PeepEvents(SDL_Event *events, int numevents, SDL_eventaction action,
 *                      Uint32 minType, Uint32 maxType);
 *
 * SDL_eventaction: SDL_ADDEVENT=0, SDL_PEEKEVENT=1, SDL_GETEVENT=2 */

#define XH_SDL_ADDEVENT 0
#define XH_SDL_PEEKEVENT 1
#define XH_SDL_GETEVENT 2

typedef int (SDLCALL *PFN_PeepEvents)(void *events, int numevents, int action,
                                      UINT32 minType, UINT32 maxType);

static PFN_PeepEvents g_real_peep = NULL;
static XH_HOOKINFO    g_hk_peep;
static BYTE           g_prologue_peep[XH_MIN_SCAN];

static volatile LONG g_pp_calls     = 0;   /* times the engine drained events   */
static volatile LONG g_pp_events    = 0;   /* events seen across those calls    */
static volatile LONG g_pp_forged    = 0;   /* events we rewrote                 */
static volatile LONG g_pp_real_keys = 0;   /* real key events seen (the check)  */
static volatile LONG g_pp_gets      = 0;   /* GETs only                         */

XH_EXPORT int XH_CALL xh_peep_calls(void)      { return (int)g_pp_calls; }
XH_EXPORT int XH_CALL xh_peep_events(void)     { return (int)g_pp_events; }
XH_EXPORT int XH_CALL xh_peep_forged(void)     { return (int)g_pp_forged; }
XH_EXPORT int XH_CALL xh_peep_real_keys(void)  { return (int)g_pp_real_keys; }
XH_EXPORT int XH_CALL xh_peep_gets(void)       { return (int)g_pp_gets; }

static int SDLCALL XhPeepEvents(void *events, int numevents, int action,
                                UINT32 minType, UINT32 maxType)
{
    XH_SDL_Event *arr = (XH_SDL_Event *)events;
    int ret, i, f, sc;

    InterlockedIncrement(&g_pp_calls);

    /* Call the real one and hand back EXACTLY its result. The return value is
     * never altered, which is what keeps this free of the poll-loop deadlock. */
    ret = g_real_peep ? g_real_peep(events, numevents, action, minType, maxType) : 0;

    if (ret <= 0 || !arr) return ret;

    /* Only a GET removes events for the caller. ADD and PEEK are left completely
     * alone so the queue itself is never modified. */
    if (action != XH_SDL_GETEVENT) return ret;
    InterlockedIncrement(&g_pp_gets);

    if (ret > numevents) ret = numevents;
    InterlockedAdd(&g_pp_events, ret);

    f  = (int)g_ev_frames;
    sc = (int)g_ev_scancode;

    for (i = 0; i < ret; i++) {
        /* Count real key traffic regardless of forging: this is the number that
         * proves whether the engine's keyboard input really flows through here. If
         * it stays 0 while a human types, this is the wrong function too. */
        if (arr[i].type == XH_SDL_KEYDOWN || arr[i].type == XH_SDL_KEYUP)
            InterlockedIncrement(&g_pp_real_keys);

        if (!g_ev_forge_on || f <= 0 || sc < 0) continue;

        /* EDIT IN PLACE. The event count is untouched and the struct is one the
         * engine already owns, so nothing is inserted into the queue. */
        arr[i].type = (f > 1) ? XH_SDL_KEYDOWN : XH_SDL_KEYUP;
        arr[i].key.type            = arr[i].type;
        arr[i].key.state           = (f > 1) ? 1 : 0;
        arr[i].key.keysym.scancode = sc;
        InterlockedIncrement(&g_pp_forged);
    }

    if (g_ev_forge_on && f > 0) {
        InterlockedExchange(&g_ev_frames, f - 1);
        if (f == 1) InterlockedExchange(&g_ev_forge_on, 0);
    }
    return ret;
}

XH_EXPORT int XH_CALL xh_install_peepevents(void)
{
    int ok;
    if (g_real_peep) return 1;
    ok = XhInstallOne(&g_hk_peep, "SDL2.dll", "SDL_PeepEvents",
                      (void *)XhPeepEvents, (void **)&g_real_peep, g_prologue_peep);
    if (!ok || !g_real_peep) {
        if (ok) XhRemoveOne(&g_hk_peep);
        return 0;
    }
    return 1;
}

XH_EXPORT int XH_CALL xh_remove_peepevents(void)
{
    xh_event_forge_clear();
    XhRemoveOne(&g_hk_peep);
    return 1;
}

static int SDLCALL XhPollEvent(void *eventptr)
{
    XH_SDL_Event *ev = (XH_SDL_Event *)eventptr;
    int got, f, sc;

    InterlockedIncrement(&g_pe_calls);
    InterlockedIncrement(&g_ev_entered);

    /* Real event first. */
    got = g_real_poll ? g_real_poll(eventptr) : 0;

    /* WHY THIS DOES NOT JUST REWRITE A REAL EVENT
     *
     * Measured: `got` is 0 on essentially every call -- with_event stayed at 0
     * across 405 invocations. The engine drains the SDL queue itself (it imports
     * SDL_PeepEvents), so by the time it polls, nothing is left. A forge that could
     * only rewrite an existing event therefore had nothing to work with, which is
     * exactly why `forged` stayed 0 and the player never moved, while the same code
     * appeared to work on the occasions when a stray mouse or window event happened
     * to be in the queue.
     *
     * So when the queue is empty AND a forge is armed, this SUPPLIES an event and
     * reports one to the caller. The engine checks the return value and processes
     * what it is given, so this is the same contract as a real event -- the forge
     * stops being contingent on unrelated traffic.
     *
     * The event is written field by field into the caller's struct, which is
     * already zeroed or holds the previous event, and only the fields a key event
     * needs are set. Nothing outside the struct is touched. */
    if (!got) {
        if (!ev || !g_ev_forge_on) return got;

        f  = (int)g_ev_frames;
        sc = (int)g_ev_scancode;
        if (f <= 0 || sc < 0) {
            InterlockedExchange(&g_ev_forge_on, 0);
            return got;
        }

        /* SDL_Event is a 64-byte union; clear it so no stale field is visible. */
        memset(ev, 0, sizeof(XH_SDL_Event));
        ev->type = (f > 1) ? XH_SDL_KEYDOWN : XH_SDL_KEYUP;
        ev->key.type            = ev->type;
        ev->key.state           = (f > 1) ? 1 : 0;
        ev->key.repeat          = 0;
        ev->key.keysym.scancode = sc;
        ev->key.keysym.sym      = 0;
        ev->key.keysym.mod      = 0;
        InterlockedIncrement(&g_pe_forged);

        InterlockedExchange(&g_ev_frames, f - 1);
        if (f == 1) InterlockedExchange(&g_ev_forge_on, 0);
        return 1;                    /* one supplied event, as the contract requires */
    }

    InterlockedIncrement(&g_ev_with_event);

    if (!g_ev_forge_on) {
        if (ev->type == XH_SDL_KEYDOWN || ev->type == XH_SDL_KEYUP)
            InterlockedIncrement(&g_ev_real_seen);
        return got;
    }

    f  = (int)g_ev_frames;
    sc = (int)g_ev_scancode;
    if (f <= 0 || sc < 0) {
        InterlockedExchange(&g_ev_forge_on, 0);
        return got;
    }

    /* Deliver a KEY-DOWN on every frame of the hold, with the type set as well as
     * the scancode.
     *
     * This combination is what was MEASURED to work, and the two properties are
     * both load-bearing:
     *
     *   * the TYPE must be set. A version that only rewrote the scancode left the
     *     event typed as whatever SDL had produced (usually MOUSEMOTION), so the
     *     engine never treated it as a key at all -- forged_events stayed 0 and the
     *     player did not move. The successful run had set the type.
     *   * it must repeat EVERY frame. A single edge pair was ignored; the engine
     *     only advances its input state on frames where it actually receives an
     *     event for the key. A physical keyboard has the same property, because the
     *     OS repeats key-down while the key is held.
     *
     * The observed success: forged_events=16, mButtonFrameRight +2243, vx 0 -> +52.
     *
     * Fields beyond type/scancode/state are left as SDL produced them, because the
     * hand-written struct layout does not match SDL's exactly for keysym.mod and
     * writing those bytes corrupts the event. */
    if (f > 1) {
        ev->type = XH_SDL_KEYDOWN;
        ev->key.type            = XH_SDL_KEYDOWN;
        ev->key.state           = 1;
        ev->key.keysym.scancode = sc;
        InterlockedIncrement(&g_pe_forged);
    } else {
        ev->type = XH_SDL_KEYUP;
        ev->key.type            = XH_SDL_KEYUP;
        ev->key.state           = 0;
        ev->key.keysym.scancode = sc;
        InterlockedIncrement(&g_pe_forged);
    }

    InterlockedExchange(&g_ev_frames, f - 1);
    if (f == 1) InterlockedExchange(&g_ev_forge_on, 0);
    return got;
}

/* Installed through the SAME XhInstallOne path as everything else, so it gets the
 * real prologue analysis (XhAnalyzeTarget) and a genuine trampoline.
 *
 * This matters. A counting probe written during the investigation took a shortcut
 * and emitted a naive 5-byte jump back to target+5, which is only correct if an
 * instruction boundary happens to fall exactly there. It does not in general, and
 * that shortcut wedged the process. There is no shortcut here. */
XH_EXPORT int XH_CALL xh_install_pollevent(void)
{
    int ok;
    if (g_real_poll) return 1;               /* already in */

    ok = XhInstallOne(&g_hk_poll, "SDL2.dll", "SDL_PollEvent",
                      (void *)XhPollEvent, (void **)&g_real_poll, g_prologue_poll);
    if (!ok || !g_real_poll) {
        if (ok) XhRemoveOne(&g_hk_poll);
        return 0;
    }
    return 1;
}

XH_EXPORT int XH_CALL xh_remove_pollevent(void)
{
    xh_event_forge_clear();
    XhRemoveOne(&g_hk_poll);
    return 1;
}

/* Whether the PollEvent hook is currently in place.
 *
 * The Lua side needs this to tell "the DLL is loaded" from "input can actually be
 * forged". Checking only the legacy xh_hooks_installed made a working install
 * report mode "base" and every forge refuse. */
XH_EXPORT int XH_CALL xh_poll_installed(void)
{
    return g_real_poll ? 1 : 0;
}

/* ------------------------------------------------------------- probe hooks */

/* Counting-only hooks, used to find out WHICH function the engine actually reads
 * input through.
 *
 * This exists because two hooks were installed, the game stayed healthy, and the
 * forge still did nothing -- the counters showed the engine never calls
 * SDL_GetKeyboardState or SDL_GetMouseState at all. Rather than guess the real
 * function and write a forging hook for each candidate, this probes every
 * candidate at once.
 *
 * Safety property, which is the whole point: a probe does NOT alter behaviour.
 * It increments a counter and jumps straight back into the original function. No
 * arguments are examined or changed, no return value is replaced, and no
 * trampoline is needed -- so installing a probe on the wrong function, or on a
 * function that is called constantly, cannot change what the game does. The only
 * observable effect is a counter.
 *
 * Usage: xh_probe_install() installs them all, xh_probe_count(i) reads one, and
 *        xh_probe_remove() takes them all out again. */

#define XH_MAX_PROBES 16

typedef struct {
    const char *dll;
    const char *fn;
    void       *target;         /* resolved address, NULL if not found         */
    BYTE        orig[XH_JMP_LEN];
    volatile LONG count;
    volatile LONG installed;
    void       *stub;           /* in-range forwarder, NULL if direct is fine  */
    volatile LONG found;
} XH_PROBE;

static XH_PROBE g_probes[XH_MAX_PROBES];
static volatile LONG g_probe_n = 0;

/* Every function that could plausibly be the engine's input source. The list is
 * deliberately generous: probing costs a counter increment, so a wrong guess is
 * free, while missing the real one costs another whole cycle. */
static const char *g_probe_dll[] = {
    "SDL2.dll", "SDL2.dll", "SDL2.dll", "SDL2.dll", "SDL2.dll",
    "user32.dll", "user32.dll", "user32.dll", "user32.dll",
    "user32.dll", "user32.dll", "user32.dll",
};
static const char *g_probe_fn[] = {
    "SDL_PollEvent", "SDL_PeepEvents", "SDL_WaitEvent", "SDL_PumpEvents",
    "SDL_GetGlobalMouseState",
    "GetKeyboardState", "GetAsyncKeyState", "GetKeyState", "GetCursorPos",
    "PeekMessageA", "GetMessageA", "SetCursorPos",
};

/* The shared entry point every probe stub jumps to. Which probe fired is encoded
 * in the stub itself (see XhMakeProbeStub), so this only has to be reachable. */
static void *g_probe_gate = NULL;

/* Each probe gets a tiny stub: inc [counter]; jmp original. The stub is built in
 * memory near the target so the forwarder jump is always in range. */
static int XhBuildProbeStub(XH_PROBE *p)
{
    /* mov eax, imm32 ; lock inc dword [eax] ; mov eax, imm32 ; jmp eax
     * Hand-assembled because it must not touch flags or registers the caller
     * might be relying on -- only eax is clobbered, and it is volatile by
     * convention in every calling convention involved. */
    BYTE code[64];
    int  n = 0;
    ULONG_PTR cnt = (ULONG_PTR)&p->count;
    ULONG_PTR back = (ULONG_PTR)p->target + XH_JMP_LEN;
    BYTE *stub;

    stub = XhAllocNear(p->target, 64);
    if (!stub) return 0;

    code[n++] = 0xB8;                       /* mov eax, imm32 */
    *(UINT32 *)(code + n) = (UINT32)cnt; n += 4;
    code[n++] = 0xF0;                       /* lock */
    code[n++] = 0xFF; code[n++] = 0x00;     /* inc dword [eax] */
    code[n++] = 0xB8;                       /* mov eax, imm32 */
    *(UINT32 *)(code + n) = (UINT32)back; n += 4;
    code[n++] = 0xFF; code[n++] = 0xE0;     /* jmp eax */

    memcpy(stub, code, (size_t)n);
    FlushInstructionCache(GetCurrentProcess(), stub, (size_t)n);
    p->stub = stub;
    return 1;
}

/* Writes the 5-byte jmp for one probe. Reuses the suspended-thread discipline of
 * the real installer so a thread mid-call cannot observe a half-written patch. */
static int XhWriteProbePatch(XH_PROBE *p, void *dest)
{
    BYTE patch[XH_JMP_LEN];
    DWORD oldProt = 0;
    ULONG_PTR rel = (ULONG_PTR)dest - (ULONG_PTR)((BYTE *)p->target + XH_JMP_LEN);
    XH_ThreadList tl;
    DWORD *ids = NULL;
    int i, suspended = 0;
    HANDLE snap;

    if (rel != (ULONG_PTR)(INT32)rel) return 0;      /* not in range */

    patch[0] = 0xE9;
    *(INT32 *)(patch + 1) = (INT32)rel;

    if (!VirtualProtect(p->target, XH_JMP_LEN, PAGE_EXECUTE_READWRITE, &oldProt)) return 0;

    ids = (DWORD *)LocalAlloc(LPTR, sizeof(DWORD) * 4096);
    if (ids) {
        tl.ids = ids; tl.count = 0; tl.cap = 4096;
        snap = CreateToolhelp32Snapshot(TH32CS_SNAPTHREAD, 0);
        if (snap != INVALID_HANDLE_VALUE) {
            THREADENTRY32 te;
            te.dwSize = sizeof(te);
            if (Thread32First(snap, &te)) {
                do {
                    XhThreadCb(NULL, te.th32ThreadID, (LPARAM)&tl);
                    te.dwSize = sizeof(te);
                } while (Thread32Next(snap, &te));
            }
            CloseHandle(snap);
        }
        for (i = 0; i < tl.count; i++) {
            HANDLE th = OpenThread(THREAD_SUSPEND_RESUME, FALSE, ids[i]);
            if (!th) continue;
            if (SuspendThread(th) != (DWORD)-1) suspended++;
            CloseHandle(th);
        }
    }

    memcpy(p->target, patch, XH_JMP_LEN);
    FlushInstructionCache(GetCurrentProcess(), p->target, XH_JMP_LEN);

    if (ids) {
        for (i = 0; i < tl.count; i++) {
            HANDLE th = OpenThread(THREAD_SUSPEND_RESUME, FALSE, ids[i]);
            if (!th) continue;
            ResumeThread(th);
            CloseHandle(th);
        }
        LocalFree(ids);
    }

    VirtualProtect(p->target, XH_JMP_LEN, oldProt, &oldProt);
    p->installed = 1;
    return 1;
}

XH_EXPORT int XH_CALL xh_probe_install(void)
{
    int i, n = (int)(sizeof(g_probe_fn) / sizeof(g_probe_fn[0]));
    int ok = 0;

    if (n > XH_MAX_PROBES) n = XH_MAX_PROBES;

    for (i = 0; i < n; i++) {
        HMODULE mod;
        XH_PROBE *p = &g_probes[i];

        p->dll = g_probe_dll[i];
        p->fn  = g_probe_fn[i];
        p->target = NULL;
        p->found = 0;
        p->installed = 0;

        mod = GetModuleHandleA(p->dll);
        if (!mod) continue;
        p->target = (void *)GetProcAddress(mod, p->fn);
        if (!p->target) continue;
        p->found = 1;

        XhReadBytes(p->target, p->orig, XH_JMP_LEN);
        if (!XhBuildProbeStub(p)) continue;
        if (XhWriteProbePatch(p, p->stub)) ok++;
    }

    g_probe_n = (LONG)n;
    return ok;
}

XH_EXPORT int XH_CALL xh_probe_remove(void)
{
    int i, n = (int)g_probe_n;
    for (i = 0; i < n; i++) {
        XH_PROBE *p = &g_probes[i];
        DWORD oldProt = 0;
        if (!p->installed || !p->target) continue;
        if (VirtualProtect(p->target, XH_JMP_LEN, PAGE_EXECUTE_READWRITE, &oldProt)) {
            memcpy(p->target, p->orig, XH_JMP_LEN);
            FlushInstructionCache(GetCurrentProcess(), p->target, XH_JMP_LEN);
            VirtualProtect(p->target, XH_JMP_LEN, oldProt, &oldProt);
        }
        p->installed = 0;
    }
    return 1;
}

XH_EXPORT int XH_CALL xh_probe_count(int which)
{
    if (which < 0 || which >= (int)g_probe_n) return -1;
    return (int)g_probes[which].count;
}

XH_EXPORT int XH_CALL xh_probe_found(int which)
{
    if (which < 0 || which >= (int)g_probe_n) return -1;
    return g_probes[which].found ? 1 : 0;
}

/* Writes the whole probe table to a file, so the answer can be read without a
 * round trip per function. */
XH_EXPORT int XH_CALL xh_probe_report(void)
{
    char buf[4096];
    char *p = buf, *end = buf + sizeof(buf) - 1;
    int i, n = (int)g_probe_n;

    p = XhPutS(p, end, "which | found | count | dll!function\r\n");
    for (i = 0; i < n; i++) {
        XH_PROBE *q = &g_probes[i];
        p = XhPutD(p, end, (long)i);
        p = XhPutS(p, end, " | ");
        p = XhPutD(p, end, (long)(q->found ? 1 : 0));
        p = XhPutS(p, end, " | ");
        p = XhPutD(p, end, (long)q->count);
        p = XhPutS(p, end, " | ");
        p = XhPutS(p, end, q->dll);
        p = XhPutS(p, end, "!");
        p = XhPutS(p, end, q->fn);
        p = XhPutS(p, end, "\r\n");
    }
    *p = 0;
    XhWriteMarker("xh_probe_report.txt", buf);
    return n;
}

/* ------------------------------------------------------ heartbeat watchdog */

/* Forward declaration: the watchdog below can fire before the definition of
 * XhRemoveAllHooks appears in the file. */
static void XhRemoveAllHooks(void);
/* Same reason: the PollEvent hook can roll itself back before XhRemoveOne is
 * defined further down. */
static void XhRemoveOne(XH_HOOKINFO *hk);

/* Why this exists: an earlier build installed hooks and froze the machine. The
 * hooks themselves looked correct, so the lesson taken is not "the hooks are
 * fine" but "there must be a way back that does not depend on the game working".
 *
 * The watchdog is that way back. Once hooks are installed, a background thread
 * waits for the Lua side to call xh_heartbeat() every frame. If no heartbeat
 * arrives within XH_WATCHDOG_MS, the hooks are removed automatically. So the
 * worst case is bounded: a few seconds of odd input, then the game is back to
 * stock even if Lua is wedged, the frame loop has stalled, or nobody is watching.
 *
 * The Lua side only has to prove it is alive; it does not have to decide to
 * clean up. A cleanup that depends on the failing component is not a cleanup. */
#define XH_WATCHDOG_MS 5000

static volatile LONG g_heartbeat = 0;
static volatile LONG g_watchdog_run = 0;
static HANDLE        g_watchdog_thread = NULL;

static DWORD WINAPI XhWatchdog(LPVOID param)
{
    (void)param;
    while (InterlockedCompareExchange(&g_watchdog_run, 1, 1) == 1) {
        Sleep(250);
        if (InterlockedCompareExchange(&g_hooks_installed, 0, 0) != 1) continue;

        /* has the heartbeat advanced since last look? */
        {
            static LONG last = 0;
            LONG now = InterlockedCompareExchange(&g_heartbeat, 0, 0);
            if (now == last) {
                /* stale -> nobody is driving us any more; remove the hooks */
                XhRemoveAllHooks();
                InterlockedExchange(&g_hooks_installed, 0);
                InterlockedExchange(&g_hook_ok, 0);
                XhWriteMarker("xh_watchdog_fired.txt",
                    "no heartbeat within the window; hooks removed automatically\r\n");
                /* keep looping so a later re-install is also watched */
            }
            last = now;
        }
    }
    return 0;
}

/* Called by Lua once per frame while it wants the hooks to stay in. */
XH_EXPORT void XH_CALL xh_heartbeat(void)
{
    InterlockedIncrement(&g_heartbeat);
}

/* -------------------------------------------------------------- keyboard only */

/* Installs ONLY the keyboard and mouse hooks -- deliberately not SDL_PumpEvents.
 *
 * SDL_PumpEvents is the suspected cause of the freeze: the game calls it every
 * frame, it can be called from more than one thread, and it may re-enter SDL's
 * input path. A hook that calls the real function through a trampoline risks
 * unbounded recursion there, which presents exactly as a machine-wide hang.
 *
 * Nothing needs it: the TTL is decremented from Lua, which already runs every
 * frame, so the forge expiry no longer depends on hooking the pump at all. */
XH_EXPORT int XH_CALL xh_install_keyboard_only(void)
{
    int ok_kb, ok_ms;

    if (InterlockedCompareExchange(&g_hooks_installed, 0, 0) == 1) return 1;

    ok_kb = XhInstallOne(&g_hk_kb, "SDL2.dll", "SDL_GetKeyboardState",
                         (void *)XhGetKeyboardState, (void **)&g_real_kb,
                         g_prologue_kb);
    ok_ms = XhInstallOne(&g_hk_ms, "SDL2.dll", "SDL_GetMouseState",
                         (void *)XhGetMouseState, (void **)&g_real_ms,
                         g_prologue_ms);

    if (ok_kb && !g_real_kb) ok_kb = 0;
    if (ok_ms && !g_real_ms) ok_ms = 0;

    /* all or nothing -- see the note above xh_install_hooks */
    if (!(ok_kb && ok_ms)) {
        XhRemoveAllHooks();
        InterlockedExchange(&g_hooks_installed, 0);
        return 0;
    }

    InterlockedExchange(&g_hooks_installed, 1);
    InterlockedExchange(&g_hook_ok, 1);
    InterlockedExchange(&g_heartbeat, 0);

    /* start (or restart) the watchdog */
    InterlockedExchange(&g_watchdog_run, 1);
    if (!g_watchdog_thread) {
        g_watchdog_thread = CreateThread(NULL, 0, XhWatchdog, NULL, 0, NULL);
    }
    return 1;
}

/* ------------------------------------------------------- remove / rollback */
/* Restores one hook's original bytes. Safe to call on a hook that was never
 * installed (it checks), and used both by an explicit xh_remove_hooks and by the
 * all-or-nothing rollback in the worker. */
static void XhRemoveOne(XH_HOOKINFO *hk)
{
    DWORD oldProt = 0;

    if (!hk->installed || !hk->target || hk->prologue_len <= 0) return;

    if (VirtualProtect(hk->target, XH_JMP_LEN, PAGE_EXECUTE_READWRITE, &oldProt)) {
        /* Restore only the bytes the JMP overwrote, from the copy taken before
         * the patch. Suspending threads here matters for the same reason it did
         * during installation: a thread mid-call must not see a half-restored
         * prologue. */
        XH_ThreadList tl;
        DWORD *ids = (DWORD *)LocalAlloc(LPTR, sizeof(DWORD) * 4096);
        int i, suspended = 0;
        HANDLE snap;

        if (ids) {
            tl.ids = ids; tl.count = 0; tl.cap = 4096;
            snap = CreateToolhelp32Snapshot(TH32CS_SNAPTHREAD, 0);
            if (snap != INVALID_HANDLE_VALUE) {
                THREADENTRY32 te;
                te.dwSize = sizeof(te);
                if (Thread32First(snap, &te)) {
                    do {
                        XhThreadCb(NULL, te.th32ThreadID, (LPARAM)&tl);
                        te.dwSize = sizeof(te);
                    } while (Thread32Next(snap, &te));
                }
                CloseHandle(snap);
            }
            for (i = 0; i < tl.count; i++) {
                HANDLE th = OpenThread(THREAD_SUSPEND_RESUME, FALSE, ids[i]);
                if (!th) continue;
                if (SuspendThread(th) != (DWORD)-1) suspended++;
                CloseHandle(th);
            }
        }

        memcpy(hk->target, hk->orig_bytes, (size_t)hk->prologue_len);
        FlushInstructionCache(GetCurrentProcess(), hk->target, (size_t)hk->prologue_len);

        if (ids) {
            for (i = 0; i < tl.count; i++) {
                HANDLE th = OpenThread(THREAD_SUSPEND_RESUME, FALSE, ids[i]);
                if (!th) continue;
                ResumeThread(th);
                CloseHandle(th);
            }
            LocalFree(ids);
        }

        VirtualProtect(hk->target, XH_JMP_LEN, oldProt, &oldProt);
        hk->installed = 0;
        hk->patch_phase = 0;
    }
}

static void XhRemoveAllHooks(void)
{
    XhRemoveOne(&g_hk_kb);
    XhRemoveOne(&g_hk_ms);
    XhRemoveOne(&g_hk_pump);
    /* also drop any forge, so removing the hooks cannot leave one latched */
    InterlockedExchange(&g_ttl, 0);
    InterlockedExchange(&g_active, 0);
    InterlockedExchange(&g_mouse.in_use, 0);
}

/* ------------------------------------------------------------ exported API */

/* Installs the hooks. EXPLICIT OPT-IN -- nothing installs them automatically.
 * Returns 1 if all three went in, 0 otherwise (in which case none are left). */
XH_EXPORT int XH_CALL xh_install_hooks(void)
{
    if (InterlockedCompareExchange(&g_hooks_installed, 0, 0) == 1) return 1;
    InterlockedExchange(&g_install_requested, 1);
    if (g_ev_start) SetEvent(g_ev_start);

    /* Wait for the worker to finish, but never forever: if it does not complete
     * within this bound, report failure rather than blocking the caller (which
     * runs inside the game). */
    {
        int waited = 0;
        while (InterlockedCompareExchange(&g_hooks_installed, 0, 0) == 0 && waited < 8000) {
            Sleep(50);
            waited += 50;
        }
    }
    return InterlockedCompareExchange(&g_hooks_installed, 0, 0) == 1 ? 1 : 0;
}

XH_EXPORT int XH_CALL xh_remove_hooks(void)
{
    XhRemoveAllHooks();
    InterlockedExchange(&g_hooks_installed, 0);
    InterlockedExchange(&g_hook_ok, 0);
    return 1;
}

XH_EXPORT int XH_CALL xh_hooks_installed(void)
{
    return InterlockedCompareExchange(&g_hooks_installed, 0, 0) == 1 ? 1 : 0;
}

static DWORD WINAPI XhWorker(LPVOID param)
{
    char detail[768];
    int ok_kb, ok_ms, ok_pump;

    (void)param;
    if (g_ev_start) WaitForSingleObject(g_ev_start, 10000);

    /* Resolve the targets and report what WOULD be hooked, but touch nothing.
     * This is the only thing that happens automatically, and it is read-only. */
    g_hook_ok = 0;
    {
        char *p = detail, *end = detail + sizeof(detail) - 1;
        p = XhPutS(p, end, "loaded=OK hooks=NOT_INSTALLED (opt-in; call xh_install_hooks)\r\n");
        p = XhPutS(p, end, "SDL2.dll=");
        p = XhPutS(p, end, GetModuleHandleA("SDL2.dll") ? "present" : "MISSING");
        p = XhPutS(p, end, "\r\n");
        *p = 0;
        XhWriteMarker("xh_status.txt", detail);
    }

    /* Wait for the explicit request, with a generous but finite bound so the
     * thread does not linger forever if nobody asks. */
    {
        int waited = 0;
        while (!g_install_requested && waited < 60000) {
            Sleep(50);
            waited += 50;
        }
    }
    if (!g_install_requested) {
        XhWriteMarker("xh_status.txt", "hooks never requested; thread exiting\r\n");
        return 0;
    }

    ok_kb   = XhInstallOne(&g_hk_kb,   "SDL2.dll", "SDL_GetKeyboardState",
                           (void *)XhGetKeyboardState, (void **)&g_real_kb,
                           g_prologue_kb);
    ok_ms   = XhInstallOne(&g_hk_ms,   "SDL2.dll", "SDL_GetMouseState",
                           (void *)XhGetMouseState, (void **)&g_real_ms,
                           g_prologue_ms);
    ok_pump = XhInstallOne(&g_hk_pump, "SDL2.dll", "SDL_PumpEvents",
                           (void *)XhPumpEvents, (void **)&g_real_pump,
                           g_prologue_pump);

    /* SDL_PumpEvents is deliberately NOT hooked. It runs every frame, may run on
     * more than one thread, and may re-enter SDL's input path -- so a hook that
     * calls the real function through a trampoline risks unbounded recursion,
     * which presents as a machine-wide hang. It is also unnecessary: the TTL is
     * decremented from Lua, which already runs every frame.
     *
     * The pump hook is still available through xh_install_hooks (the full set),
     * but the keyboard+mouse set is what the Lua side uses. */

    /* Sanity: never leave a hook installed whose trampoline is unusable. */
    if (ok_kb && !g_real_kb) { ok_kb = 0; }
    if (ok_ms && !g_real_ms) { ok_ms = 0; }

    /* ALL OR NOTHING. A partial set is the dangerous case: without the pump hook
     * the TTL never decrements, so a forge would never expire and the player's
     * input would stay hijacked. Roll everything back instead. */
    if (!(ok_kb && ok_ms && ok_pump)) {
        XhRemoveAllHooks();
        g_hooks_installed = 0;
        g_hook_ok = 0;
    } else {
        g_hooks_installed = 1;
        g_hook_ok = 1;
        InterlockedExchange(&g_heartbeat, 0);
        InterlockedExchange(&g_watchdog_run, 1);
        if (!g_watchdog_thread) {
            g_watchdog_thread = CreateThread(NULL, 0, XhWatchdog, NULL, 0, NULL);
        }
    }

    {
        char *p = detail, *end = detail + sizeof(detail) - 1;
        p = XhPutS(p, end, g_hooks_installed ? "hooks=INSTALLED (all three)\r\n"
                                             : "hooks=ROLLED_BACK (a hook failed; none left in)\r\n");
        p = XhPutS(p, end, "keyboard_hook=");
        p = XhPutS(p, end, ok_kb ? "OK" : "FAILED");
        p = XhPutS(p, end, " (prologue=");
        p = XhPutD(p, end, (long)g_hk_kb.prologue_len);
        p = XhPutS(p, end, " bytes, err=0x");
        p = XhPutX(p, end, (unsigned long)g_hk_kb.last_error);
        p = XhPutS(p, end, ")\r\nmouse_hook=");
        p = XhPutS(p, end, ok_ms ? "OK" : "FAILED");
        p = XhPutS(p, end, " (prologue=");
        p = XhPutD(p, end, (long)g_hk_ms.prologue_len);
        p = XhPutS(p, end, " bytes, err=0x");
        p = XhPutX(p, end, (unsigned long)g_hk_ms.last_error);
        p = XhPutS(p, end, ")\r\npump_hook=");
        p = XhPutS(p, end, ok_pump ? "OK" : "FAILED");
        p = XhPutS(p, end, " (prologue=");
        p = XhPutD(p, end, (long)g_hk_pump.prologue_len);
        p = XhPutS(p, end, " bytes, err=0x");
        p = XhPutX(p, end, (unsigned long)g_hk_pump.last_error);
        p = XhPutS(p, end, ")\r\nkb=0x");
        p = XhPutX(p, end, (unsigned long)(ULONG_PTR)g_hk_kb.target);
        p = XhPutS(p, end, " ms=0x");
        p = XhPutX(p, end, (unsigned long)(ULONG_PTR)g_hk_ms.target);
        p = XhPutS(p, end, " pump=0x");
        p = XhPutX(p, end, (unsigned long)(ULONG_PTR)g_hk_pump.target);
        p = XhPutS(p, end, "\r\n");
        XhTerm(p, detail, detail + sizeof(detail));
    }

    if (ok_kb && ok_ms) XhWriteMarker("xh_loaded.txt", detail);
    else                XhWriteMarker("xh_FAILED.txt", detail);

    g_hk_kb.worker_done = 1;
    if (g_ev_done) SetEvent(g_ev_done);
    return 0;
}

/* ------------------------------------------------------------- DllMain */

BOOL WINAPI DllMain(HINSTANCE hinst, DWORD reason, LPVOID reserved)
{
    (void)reserved;
    if (reason == DLL_PROCESS_ATTACH) {
        HANDLE th;
        int i;

        g_self = hinst;
        g_target_pid = GetCurrentProcessId();
        DisableThreadLibraryCalls(hinst);

        for (i = 0; i < XH_MAX_FORGE; i++) {
            g_keyforge[i].scancode = -1;
            g_keyforge[i].state = 0;
        }
        g_mouse.in_use = 0;
        g_mouse.x = g_mouse.y = g_mouse.buttons = 0;
        g_ttl = 0;
        g_active = 0;
        g_def_ttl = XH_DEFAULT_TTL;
        g_dll_dir[0] = 0;

        /* Determine our own directory. GetModuleFileNameA on an already-loaded
         * module does not take the loader lock. */
        {
            DWORD n = GetModuleFileNameA(hinst, g_dll_dir, MAX_PATH);
            if (n == 0 || n >= MAX_PATH) { g_dll_dir[0] = 0; }
            else {
                while (n > 0 && g_dll_dir[n - 1] != '\\') n--;
                g_dll_dir[n > 0 ? n - 1 : 0] = 0;
            }
        }

        g_ev_start = CreateEventA(NULL, TRUE, FALSE, NULL);
        g_ev_done  = CreateEventA(NULL, TRUE, FALSE, NULL);

        th = CreateThread(NULL, 0, XhWorker, NULL, 0, NULL);
        if (th) {
            CloseHandle(th);
        } else {
            /* Could not spawn: do absolutely nothing rather than hook inline. */
            XhWriteMarker("xh_FAILED.txt", "CreateThread for worker failed\r\n");
        }
        if (g_ev_start) SetEvent(g_ev_start);
        if (g_ev_done)  WaitForSingleObject(g_ev_done, 10000);
    }
    return TRUE;
}
