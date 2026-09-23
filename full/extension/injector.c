/* ============================================================================
 * injector.c -- 32-bit remote-DLL injector + verifier for noita.exe
 * ============================================================================
 *
 * WHY A NATIVE HELPER INSTEAD OF ffi-napi
 *   ffi-napi needs node-gyp + a Python toolchain + node headers matching the
 *   exact Node ABI (prebuilds for Node 22 are frequently missing), AND it would
 *   still be a 64-bit host: CreateRemoteThread/LoadLibraryA against a 32-bit
 *   target is an address-width matter a 64-bit Node process cannot express.
 *   So the robust choice is a tiny 32-bit helper .exe built by the same MSVC
 *   toolchain, which inject.js shells out to. Zero npm dependencies.
 *
 * WHY HAND-ASSEMBLED SHELLCODE INSTEAD OF "COMPILE A FUNCTION AND MEMCPY IT"
 *   The classic trick of copying a compiled C function bytewise into the target
 *   is BROKEN under MSVC: with incremental linking (the default, and what
 *   /ZI and debug builds force) the exported entry point of a function is not
 *   the function body at all, it is a `jmp rel32` trampoline whose destination
 *   only exists in the source process. Copying those 5 bytes and running them
 *   in the target jumps into unmapped memory and kills the process. There is
 *   also no guarantee the compiler did not emit a prologue referencing a stack
 *   cookie or a RIP-relative global.
 *   Therefore the blob is emitted as literal, hand-assembled, position-
 *   independent x86 shellcode built at runtime with no fixups. Every pointer it
 *   needs is read out of the parameter block, whose address it receives in its
 *   single stack argument. This is boring and provably correct.
 *
 * USAGE
 *   injector.exe find   <exeName> [index]
 *   injector.exe arch   <pid>
 *   injector.exe inject <pid> <dllPath> [exportToCall] [arg]
 *   injector.exe call   <pid> <moduleName> <exportName> [arg]
 *
 * EXIT CODES
 *   0 ok | 1 usage | 2 no such process | 3 arch mismatch / unknown target arch
 *   4 OpenProcess denied | 5 remote alloc failed | 6 remote write failed
 *   7 remote thread failed | 8 LoadLibraryA returned NULL in target
 *   9 GetProcAddress returned NULL in target | 10 export call failed
 * ==========================================================================*/

#include <windows.h>
#include <tlhelp32.h>
#include <stdio.h>
#include <string.h>
#include <stdlib.h>
/* ------------------------------------------------------ shared blob layout */

#pragma pack(push, 1)
typedef struct {
    /* kernel32 pointers the shellcode calls through (already mapped in target) */
    HMODULE (WINAPI *pLoadLibraryA)(LPCSTR);
    HMODULE (WINAPI *pGetModuleHandleA)(LPCSTR);
    FARPROC (WINAPI *pGetProcAddress)(HMODULE, LPCSTR);
    DWORD   (WINAPI *pGetLastError)(void);

    char   arg0[260];   /* LoadLibraryA path  /  GetModuleHandleA name        */
    char   arg1[128];   /* export name                                        */

    DWORD  entry;       /* which shellcode routine to run (see XH_E_*)        */
    DWORD  callArg;     /* argument for the called export                     */
    DWORD  status;      /* Win32 error reported by the blob                   */
    DWORD  stage;       /* 1 LoadLibrary, 2 loaded, 3 GetProcAddress,         */
                        /* 4 resolved, 5 called                               */
    void  *module;      /* HMODULE from LoadLibrary/GetModuleHandle in target */
    FARPROC fn;         /* resolved export in target                          */
    DWORD  fnResult;    /* export return value                                */
    DWORD  ebxSeen;     /* diagnostic: EBX as decoded by the shellcode        */
    DWORD  probe1;      /* diagnostic progress markers                        */
    DWORD  probe2;
    DWORD  probe3;
    DWORD  probe4;
} XH_REMOTE;
#pragma pack(pop)

#define XH_E_LOADLIB    0
#define XH_E_GETMODULE  1

/* ------------------------------------------------------------- assembler */

typedef struct {
    BYTE  b[512];
    DWORD n;
} XH_BUF;

/* Forward-declared so the emitters below can use them before definition. */
static void Em(BYTE *p, DWORD *n, BYTE v);
static void EmD(BYTE *p, DWORD *n, DWORD v);

static void Em(BYTE *p, DWORD *n, BYTE v) { p[(*n)++] = v; }

static void EmD(BYTE *p, DWORD *n, DWORD v)
{
    p[(*n)++] = (BYTE)(v & 0xFF);
    p[(*n)++] = (BYTE)((v >> 8) & 0xFF);
    p[(*n)++] = (BYTE)((v >> 16) & 0xFF);
    p[(*n)++] = (BYTE)((v >> 24) & 0xFF);
}

/* ---------------------------------------------------------------------------
 * ModRM encoding helpers -- DISP32 ONLY. Read this before "optimising".
 *
 * The XH_REMOTE parameter block is ~452 bytes, so every field of interest lives
 * at an offset far above 127. A disp8 ModRM (mod=01, e.g. `C7 43 xx imm32`)
 * holds only ONE displacement byte: emitting it for offset 416 (0x1A0) silently
 * truncates to [ebx+0xA0] and the store lands 256 bytes away in the wrong
 * field. That bug produced an immediate 0xC0000005 in the target every time.
 * Every helper here therefore uses mod=10 (disp32), which is always correct,
 * and asserts the offset fits in 31 bits.
 * ------------------------------------------------------------------------- */
#define OFF(f) ((DWORD)offsetof(XH_REMOTE, f))

/* Emit ModRM(+SIB)+disp32 for [ebx+offset], with the given reg field. */
static void EmEbxMem(BYTE *p, DWORD *n, BYTE reg, DWORD offset)
{
    Em(p, n, (BYTE)(0x80 | ((reg & 7) << 3) | 3));   /* mod=10, rm=011 (EBX) */
    EmD(p, n, offset & 0x7FFFFFFFu);
}

/* mov dword ptr [ebx+disp32], imm32 */
static void EmMovEbxImm(BYTE *p, DWORD *n, DWORD offset, DWORD imm)
{
    Em(p, n, 0xC7);
    EmEbxMem(p, n, 0, offset);                       /* reg=000 */
    EmD(p, n, imm);
}

/* mov dword ptr [ebx+disp32], reg   (reg = 0..7) */
static void EmMovEbxFromReg(BYTE *p, DWORD *n, DWORD offset, BYTE reg)
{
    Em(p, n, 0x89);
    EmEbxMem(p, n, reg, offset);
}

/* mov eax, [ebx+disp32] */
static void EmMovEaxFromEbx(BYTE *p, DWORD *n, DWORD offset)
{
    Em(p, n, 0x8B);
    EmEbxMem(p, n, 0, offset);
}

/* mov ecx, [ebx+disp32] */
static void EmMovEcxFromEbx(BYTE *p, DWORD *n, DWORD offset)
{
    Em(p, n, 0x8B);
    EmEbxMem(p, n, 1, offset);
}

/* push dword ptr [ebx+disp32] */
static void EmPushEbxMem(BYTE *p, DWORD *n, DWORD offset)
{
    Em(p, n, 0xFF);
    EmEbxMem(p, n, 6, offset);                       /* /6 = push r/m32 */
}

/* lea ecx, [ebx+disp32] */
static void EmLeaEcxFromEbx(BYTE *p, DWORD *n, DWORD offset)
{
    Em(p, n, 0x8D);
    EmEbxMem(p, n, 1, offset);
}

/* cmp dword ptr [ebx+disp32], imm8 */
static void EmCmpEbxImm8(BYTE *p, DWORD *n, DWORD offset, BYTE imm)
{
    Em(p, n, 0x83);
    EmEbxMem(p, n, 7, offset);                       /* /7 = cmp */
    Em(p, n, imm);
}

/* cmp byte ptr [ebx+disp32], imm8 */
static void EmCmpEbxByteImm8(BYTE *p, DWORD *n, DWORD offset, BYTE imm)
{
    Em(p, n, 0x80);
    EmEbxMem(p, n, 7, offset);                       /* /7 = cmp */
    Em(p, n, imm);
}

#define MAX_JZ 4

/* Build the position-independent blob.
 *
 * STACK DISCIPLINE
 *   The remote thread entry receives its single 32-bit argument at [esp+4]
 *   (Win32 stdcall thread entry) and the thread procedure is __stdcall, so it
 *   must return with `ret 4`. We load the argument into EBX immediately, save
 *   the caller's EBX with `push ebx`, and restore it with `pop ebx` before the
 *   `ret 4`. Between those points every push we make is matched by an
 *   `add esp, N`, so the return address is still exactly where the CPU put it.
 *
 * JUMP PATCHING
 *   Every `jz rel32` is emitted with a zero displacement and its offset
 *   recorded in jzAt[]. At the end, all of them are pointed at the common
 *   epilogue. A `jz rel32` is SIX bytes (0F 84 + 4), so the displacement is
 *   `target - (jzOffset + 6)`. Getting that constant wrong (using +4) makes the
 *   jump land 2 bytes short and execute garbage -- which is exactly the bug
 *   that made the first revision fault with 0xC0000005. */
static DWORD BuildBlob(BYTE *out, DWORD cap, DWORD entry, DWORD callArg)
{
    DWORD n = 0;
    DWORD jzAt[MAX_JZ];
    DWORD jzCount = 0;
    DWORD k;

    /* push ebx / mov ebx,[esp+8] */
    Em(out,&n,0x53);
    Em(out,&n,0x8B); Em(out,&n,0x5C); Em(out,&n,0x24); Em(out,&n,0x08);

    /* DIAGNOSTIC PROBE: prove we started, and record the EBX we computed.
     * Writing ebxSeen crashes if the thread argument itself is bad; reaching
     * stage=1 proves the argument was decoded correctly. */
    EmMovEbxFromReg(out,&n,OFF(ebxSeen),3);            /* mov [ebx+ebxSeen],ebx */
    EmMovEbxImm(out,&n,OFF(stage),1);                  /* stage = 1             */
    EmMovEbxImm(out,&n,OFF(probe1),0x11111111);
    EmMovEbxImm(out,&n,OFF(probe2),0x22222222);
    EmMovEbxImm(out,&n,OFF(probe3),0x33333333);
    EmMovEbxImm(out,&n,OFF(probe4),0x44444444);

    /* module = LoadLibraryA(arg0)  /  module = GetModuleHandleA(arg0)
     *
     * CRITICAL: arg0 is an INLINE char array at [ebx+OFF(arg0)], NOT a pointer
     * stored in the struct. The value to pass is the ADDRESS ebx+OFF(arg0).
     * The first revision pushed bare `ebx` (the struct base) instead, so
     * LoadLibraryA walked off through the struct's function-pointer fields
     * looking for a NUL terminator and faulted. That is what killed every
     * target process, including when loading a signed Microsoft DLL.
     *
     * CALLING CONVENTION: LoadLibraryA/GetModuleHandleA/GetProcAddress are all
     * __stdcall -- the callee pops its own arguments. An extra `add esp,N`
     * afterwards corrupts ESP and destroys the return path. So the pattern used
     * everywhere in this blob is:
     *      push <target fn>          ; leaves fn at [esp+4] after the arg push
     *      push <arg(s)>
     *      call dword ptr [esp+4]    ; hardcoded displacement, no register
     *                                ; juggling and no manual ESP fixup
     * After the call ESP is exactly as it was before the first push.
     */
    EmMovEaxFromEbx(out,&n, (entry == XH_E_LOADLIB)
                                ? OFF(pLoadLibraryA) : OFF(pGetModuleHandleA));
    Em(out,&n,0x50);                                   /* push eax  (target) */
    EmLeaEcxFromEbx(out,&n,OFF(arg0));
    Em(out,&n,0x51);                                   /* push ecx  = &arg0  */
    Em(out,&n,0xFF); Em(out,&n,0x54); Em(out,&n,0x24); Em(out,&n,0x04);
                                                       /* call [esp+4]       */

    EmMovEbxFromReg(out,&n,OFF(module),0);             /* mov [ebx+module],eax*/

    /* status = GetLastError() */
    EmMovEaxFromEbx(out,&n,OFF(pGetLastError));
    Em(out,&n,0xFF); Em(out,&n,0xD0);                  /* call eax           */
    EmMovEbxFromReg(out,&n,OFF(status),0);             /* mov [ebx+status],eax*/

    /* if (module == 0) -> epilogue */
    EmCmpEbxImm8(out,&n,OFF(module),0);                /* cmp [ebx+module],0 */
    Em(out,&n,0x0F); Em(out,&n,0x84);
    jzAt[jzCount++] = n; EmD(out,&n,0);                /* jz -> epilogue     */

    /* stage = 2 */
    EmMovEbxImm(out,&n,OFF(stage),2);

    /* if (arg1 == 0) -> epilogue  (nothing to resolve) */
    EmCmpEbxByteImm8(out,&n,OFF(arg1),0);              /* cmp byte [ebx+arg1],0 */
    Em(out,&n,0x0F); Em(out,&n,0x84);
    jzAt[jzCount++] = n; EmD(out,&n,0);

    /* stage = 3 */
    EmMovEbxImm(out,&n,OFF(stage),3);

    /* fn = GetProcAddress(module, arg1)   -- stdcall, 2 args, self-popping */
    EmMovEaxFromEbx(out,&n,OFF(pGetProcAddress));
    Em(out,&n,0x50);                                   /* push eax  (target) */
    EmLeaEcxFromEbx(out,&n,OFF(arg1));
    Em(out,&n,0x51);                                   /* push ecx  = &arg1  */
    EmMovEcxFromEbx(out,&n,OFF(module));
    Em(out,&n,0x51);                                   /* push ecx  = module */
    Em(out,&n,0xFF); Em(out,&n,0x54); Em(out,&n,0x24); Em(out,&n,0x08);
                                                       /* call [esp+8]       */
    EmMovEbxFromReg(out,&n,OFF(fn),0);                 /* mov [ebx+fn],eax   */

    /* if (fn == 0) -> epilogue */
    Em(out,&n,0x85); Em(out,&n,0xC0);                  /* test eax,eax       */
    Em(out,&n,0x0F); Em(out,&n,0x84);
    jzAt[jzCount++] = n; EmD(out,&n,0);

    /* stage = 4 */
    EmMovEbxImm(out,&n,OFF(stage),4);

    /* fnResult = fn(callArg)  -- our exports are cdecl on x86, so this call
     * site does NOT pop the argument; we do it ourselves afterwards. That is
     * the one place a manual `add esp,4` is correct. */
    EmMovEaxFromEbx(out,&n,OFF(fn));
    Em(out,&n,0x50);                                   /* push eax  (target) */
    EmPushEbxMem(out,&n,OFF(callArg));                 /* push argument      */
    Em(out,&n,0xFF); Em(out,&n,0x54); Em(out,&n,0x24); Em(out,&n,0x04);
                                                       /* call [esp+4]       */
    Em(out,&n,0x83); Em(out,&n,0xC4); Em(out,&n,0x04); /* add esp,4 (cdecl)  */
    EmMovEbxFromReg(out,&n,OFF(fnResult),0);

    /* stage = 5 */
    EmMovEbxImm(out,&n,OFF(stage),5);

    /* ---- epilogue: all jz land here ---- */
    for (k = 0; k < jzCount; k++)
        *(INT32 *)(out + jzAt[k]) = (INT32)(n - (jzAt[k] + 6));

    Em(out,&n,0x33); Em(out,&n,0xC0);                  /* xor eax,eax        */
    Em(out,&n,0x5B);                                   /* pop ebx            */
    Em(out,&n,0xC2); Em(out,&n,0x04); Em(out,&n,0x00); /* ret 4              */

    if (n > cap) return 0;
    return n;
}

#if 0
/* ---- original emitter, kept only as a reference of what NOT to do ----
 * Two bugs lived here: (1) jz displacement computed as n-(off+4) instead of
 * n-(off+6); (2) raw offsetof() baked in at emit sites. See BuildBlob above. */
#endif

/* --------------------------------------------------------------- helpers */

static DWORD XhFindPid(const char *exeName, char *outPath, DWORD outPathLen,
                       int index)
{
    HANDLE snap = CreateToolhelp32Snapshot(TH32CS_SNAPPROCESS, 0);
    PROCESSENTRY32 pe;
    int seen = 0;
    DWORD pid = 0;

    if (snap == INVALID_HANDLE_VALUE) return 0;
    pe.dwSize = sizeof(pe);
    if (Process32First(snap, &pe)) {
        do {
            if (lstrcmpiA(pe.szExeFile, exeName) == 0) {
                if (seen == index) {
                    pid = pe.th32ProcessID;
                    if (outPath && outPathLen) {
                        HANDLE hp = OpenProcess(PROCESS_QUERY_LIMITED_INFORMATION,
                                                FALSE, pid);
                        DWORD n = outPathLen;
                        outPath[0] = 0;
                        if (hp) {
                            QueryFullProcessImageNameA(hp, 0, outPath, &n);
                            CloseHandle(hp);
                        }
                    }
                    break;
                }
                seen++;
            }
            pe.dwSize = sizeof(pe);
        } while (Process32Next(snap, &pe));
    }
    CloseHandle(snap);
    return pid;
}

static WORD XhRemoteMachine(DWORD pid)
{
    HANDLE hp, hf;
    IMAGE_DOS_HEADER dos;
    IMAGE_NT_HEADERS32 nt;
    DWORD got = 0;
    WORD machine = 0;
    char path[MAX_PATH];
    DWORD n = MAX_PATH;

    hp = OpenProcess(PROCESS_QUERY_LIMITED_INFORMATION, FALSE, pid);
    if (!hp) return 0;
    path[0] = 0;
    QueryFullProcessImageNameA(hp, 0, path, &n);
    CloseHandle(hp);
    if (!path[0]) return 0;

    hf = CreateFileA(path, GENERIC_READ, FILE_SHARE_READ | FILE_SHARE_WRITE,
                     NULL, OPEN_EXISTING, FILE_ATTRIBUTE_NORMAL, NULL);
    if (hf == INVALID_HANDLE_VALUE) return 0;
    if (ReadFile(hf, &dos, sizeof(dos), &got, NULL) && got == sizeof(dos) &&
        dos.e_magic == IMAGE_DOS_SIGNATURE) {
        if (SetFilePointer(hf, dos.e_lfanew, NULL, FILE_BEGIN) != INVALID_SET_FILE_POINTER) {
            if (ReadFile(hf, &nt, sizeof(nt), &got, NULL) &&
                got >= 6 && nt.Signature == IMAGE_NT_SIGNATURE) {
                machine = nt.FileHeader.Machine;
            }
        }
    }
    CloseHandle(hf);
    return machine;
}

static const char *XhMachineName(WORD m)
{
    switch (m) {
    case 0x014C: return "x86 (32-bit)";
    case 0x8664: return "x64 (64-bit)";
    case 0xAA64: return "arm64";
    case 0:      return "unknown/denied";
    default:     return "other";
    }
}

static int XhIsElevated(void)
{
    HANDLE t = NULL;
    TOKEN_ELEVATION te;
    DWORD n = 0;
    int r = 0;
    if (OpenProcessToken(GetCurrentProcess(), TOKEN_QUERY, &t)) {
        if (GetTokenInformation(t, TokenElevation, &te, sizeof(te), &n))
            r = te.TokenIsElevated ? 1 : 0;
        CloseHandle(t);
    }
    return r;
}

/* Modern Windows can forbid unsigned images inside a process. If the game has
 * PROCESS_MITIGATION_BINARY_SIGNATURE_POLICY enabled, LoadLibraryA of our
 * unsigned DLL fails with ERROR_MOD_NOT_FOUND (126) -- which is exactly the
 * error this harness hit. Worth reporting explicitly instead of guessing. */
static void XhReportMitigations(HANDLE hp, DWORD pid)
{
    PROCESS_MITIGATION_BINARY_SIGNATURE_POLICY sig;
    PROCESS_MITIGATION_DYNAMIC_CODE_POLICY      dyn;
    PROCESS_MITIGATION_EXTENSION_POINT_DISABLE_POLICY ext;
    PROCESS_MITIGATION_POLICY p;
    DWORD got = 0;

    ZeroMemory(&sig, sizeof(sig));
    p = ProcessSignaturePolicy;
    if (GetProcessMitigationPolicy(hp, p, &sig, sizeof(sig)))
        printf("mitigation_binary_signature=0x%08lX (blockUnsigned=%lu)\n",
               (unsigned long)sig.Flags, (unsigned long)sig.MicrosoftSignedOnly);
    else
        printf("mitigation_binary_signature=<query failed %lu>\n",
               (unsigned long)GetLastError());

    ZeroMemory(&dyn, sizeof(dyn));
    if (GetProcessMitigationPolicy(hp, ProcessDynamicCodePolicy, &dyn, sizeof(dyn)))
        printf("mitigation_dynamic_code=0x%08lX (prohibitDynamicCode=%lu)\n",
               (unsigned long)dyn.Flags, (unsigned long)dyn.ProhibitDynamicCode);
    else
        printf("mitigation_dynamic_code=<query failed %lu>\n",
               (unsigned long)GetLastError());

    ZeroMemory(&ext, sizeof(ext));
    if (GetProcessMitigationPolicy(hp, ProcessExtensionPointDisablePolicy, &ext, sizeof(ext)))
        printf("mitigation_extension_point_disable=0x%08lX\n",
               (unsigned long)ext.Flags);
    else
        printf("mitigation_extension_point_disable=<query failed %lu>\n",
               (unsigned long)GetLastError());
    (void)got; (void)pid;

    {
        HANDLE ht = NULL;
        if (OpenProcessToken(hp, TOKEN_QUERY, &ht)) {
            DWORD il = 0, sz = 0, tokIsElev = 0;
            if (GetTokenInformation(ht, TokenIntegrityLevel, NULL, 0, &sz) ||
                GetLastError() == ERROR_INSUFFICIENT_BUFFER) {
                TOKEN_MANDATORY_LABEL *tml = (TOKEN_MANDATORY_LABEL *)LocalAlloc(LPTR, sz);
                if (tml && GetTokenInformation(ht, TokenIntegrityLevel, tml, sz, &sz)) {
                    DWORD rid = *GetSidSubAuthority(tml->Label.Sid,
                        (DWORD)(*GetSidSubAuthorityCount(tml->Label.Sid) - 1));
                    il = rid;
                }
                if (tml) LocalFree(tml);
            }
            {
                TOKEN_ELEVATION te;
                DWORD n2 = 0;
                if (GetTokenInformation(ht, TokenElevation, &te, sizeof(te), &n2))
                    tokIsElev = te.TokenIsElevated;
            }
            CloseHandle(ht);
            printf("target_integrity_rid=%lu target_elevated=%lu "
                   "(this injector elevated=%lu)\n",
                   (unsigned long)il, (unsigned long)tokIsElev,
                   (unsigned long)XhIsElevated());
        }
    }
}

static void XhWin32Error(const char *what)
{
    DWORD e = GetLastError();
    char *buf = NULL;
    FormatMessageA(FORMAT_MESSAGE_ALLOCATE_BUFFER | FORMAT_MESSAGE_FROM_SYSTEM |
                   FORMAT_MESSAGE_IGNORE_INSERTS,
                   NULL, e, MAKELANGID(LANG_NEUTRAL, SUBLANG_DEFAULT),
                   (LPSTR)&buf, 0, NULL);
    if (buf) {
        size_t l = strlen(buf);
        while (l && (buf[l-1] == '\r' || buf[l-1] == '\n')) buf[--l] = 0;
        fprintf(stderr, "ERROR %s failed: %lu (%s)\n", what, (unsigned long)e, buf);
        LocalFree(buf);
    } else {
        fprintf(stderr, "ERROR %s failed: %lu\n", what, (unsigned long)e);
    }
}

/* ------------------------------------------------------------ one remote run */

static int XhRunRemote(DWORD pid, XH_REMOTE *params, int wantExport, int verbose)
{
    HANDLE hp = NULL;
    XH_REMOTE *remote = NULL;
    BYTE *code = NULL;
    SIZE_T written = 0, got = 0;
    HANDLE th = NULL;
    DWORD tid = 0, wait, exitCode = 0;
    XH_REMOTE readback;
    BYTE blob[512];
    DWORD blobLen;
    int rc = 1;

    blobLen = BuildBlob(blob, sizeof(blob), params->entry, params->callArg);
    if (blobLen == 0) { fprintf(stderr, "ERROR shellcode assembly overflow\n"); return 1; }

    if (getenv("XH_DEBUG")) {
        DWORD k;
        FILE *bf;
        char dumpPath[MAX_PATH];
        printf("BLOB len=%lu entry=%lu callArg=%lu sizeof(XH_REMOTE)=%lu\n",
               (unsigned long)blobLen, (unsigned long)params->entry,
               (unsigned long)params->callArg, (unsigned long)sizeof(XH_REMOTE));
        printf("BLOB bytes=");
        for (k = 0; k < blobLen; k++) {
            printf("%02X", blob[k]);
            if ((k & 15) == 15) printf("\n           "); else printf(" ");
        }
        printf("\n");
        printf("BLOB off pLL=%lu arg0=%lu arg1=%lu entry=%lu callArg=%lu "
               "status=%lu stage=%lu module=%lu fn=%lu res=%lu "
               "ebxSeen=%lu p1=%lu p2=%lu p3=%lu p4=%lu\n",
               (unsigned long)OFF(pLoadLibraryA), (unsigned long)OFF(arg0),
               (unsigned long)OFF(arg1), (unsigned long)OFF(entry),
               (unsigned long)OFF(callArg), (unsigned long)OFF(status),
               (unsigned long)OFF(stage), (unsigned long)OFF(module),
               (unsigned long)OFF(fn), (unsigned long)OFF(fnResult),
               (unsigned long)OFF(ebxSeen), (unsigned long)OFF(probe1),
               (unsigned long)OFF(probe2), (unsigned long)OFF(probe3),
               (unsigned long)OFF(probe4));
        /* Also drop the blob on disk so it can be checked independently of
         * PowerShell's handling of this process's stderr. */
        GetTempPathA(sizeof(dumpPath), dumpPath);
        lstrcatA(dumpPath, "xh_blob.bin");
        bf = fopen(dumpPath, "wb");
        if (bf) { fwrite(blob, 1, blobLen, bf); fclose(bf); }
        printf("BLOB file=%s\n", dumpPath);
    }

    hp = OpenProcess(PROCESS_QUERY_INFORMATION | PROCESS_VM_OPERATION |
                     PROCESS_VM_WRITE | PROCESS_VM_READ | PROCESS_CREATE_THREAD,
                     FALSE, pid);
    if (!hp) {
        XhWin32Error("OpenProcess");
        fprintf(stderr, "HINT: %s\n", XhIsElevated()
            ? "This shell is ELEVATED. Windows blocks injection from a higher "
              "integrity process into a lower integrity one. Re-run unelevated."
            : "Noita may be running elevated / as another user. Re-run the "
              "injector from an elevated shell, or lower Noita's integrity.");
        return 4;
    }

    remote = (XH_REMOTE *)VirtualAllocEx(hp, NULL, sizeof(XH_REMOTE),
                                         MEM_COMMIT | MEM_RESERVE, PAGE_READWRITE);
    if (!remote) { XhWin32Error("VirtualAllocEx(params)"); rc = 5; goto done; }
    code = (BYTE *)VirtualAllocEx(hp, NULL, blobLen,
                                  MEM_COMMIT | MEM_RESERVE, PAGE_EXECUTE_READWRITE);
    if (!code) { XhWin32Error("VirtualAllocEx(code)"); rc = 5; goto done; }

    if (getenv("XH_DEBUG")) XhReportMitigations(hp, pid);

    if (!WriteProcessMemory(hp, remote, params, sizeof(*params), &written) ||
        written != sizeof(*params)) {
        XhWin32Error("WriteProcessMemory(params)"); rc = 6; goto done;
    }
    if (!WriteProcessMemory(hp, code, blob, blobLen, &written) || written != blobLen) {
        XhWin32Error("WriteProcessMemory(code)"); rc = 6; goto done;
    }

    th = CreateRemoteThread(hp, NULL, 0, (LPTHREAD_START_ROUTINE)code,
                            remote, 0, &tid);
    if (!th) { XhWin32Error("CreateRemoteThread"); rc = 7; goto done; }

    printf("remote_code=0x%08lX remote_params=0x%08lX blob_len=%lu\n",
           (unsigned long)(ULONG_PTR)code, (unsigned long)(ULONG_PTR)remote,
           (unsigned long)blobLen);

    wait = WaitForSingleObject(th, 30000);
    if (wait != WAIT_OBJECT_0) {
        fprintf(stderr, "ERROR remote thread did not finish within 30s (wait=%lu)\n",
                (unsigned long)wait);
        rc = 7;
        goto done;
    }
    GetExitCodeThread(th, &exitCode);
    /* Dump the blob we actually wrote, so a mismatch between what we generated
     * and what the debugger would show is visible. */
    {
        BYTE verify[512];
        SIZE_T vgot = 0;
        DWORD k;
        if (ReadProcessMemory(hp, code, verify, blobLen, &vgot) && vgot == blobLen) {
            printf("blob_first16=");
            for (k = 0; k < 16 && k < blobLen; k++) printf("%02X", verify[k]);
            printf("\nblob_matches=%s\n",
                   memcmp(verify, blob, blobLen) == 0 ? "yes" : "NO");
        } else {
            printf("blob_readback_failed err=%lu\n", (unsigned long)GetLastError());
        }
    }
    /* In-process sanity check: run the generated blob against a local param
     * block first when asked, so we can tell "blob is wrong" apart from
     * "target refuses to execute the thread". */
    if (getenv("XH_SELFTEST")) {
        XH_REMOTE local;
        BYTE *localcode;
        HANDLE lth;
        DWORD lwait, lcode = 0;
        local = *params;
        localcode = (BYTE *)VirtualAlloc(NULL, blobLen, MEM_COMMIT | MEM_RESERVE,
                                         PAGE_EXECUTE_READWRITE);
        if (localcode) {
            memcpy(localcode, blob, blobLen);
            lth = CreateThread(NULL, 0, (LPTHREAD_START_ROUTINE)localcode,
                               &local, 0, NULL);
            if (lth) {
                lwait = WaitForSingleObject(lth, 30000);
                GetExitCodeThread(lth, &lcode);
                CloseHandle(lth);
                printf("SELFTEST wait=%lu thread_exit=%lu stage=%lu status=%lu "
                       "module=0x%08lX fn=0x%08lX result=0x%08lX\n",
                       (unsigned long)lwait, (unsigned long)lcode,
                       (unsigned long)local.stage, (unsigned long)local.status,
                       (unsigned long)(ULONG_PTR)local.module,
                       (unsigned long)(ULONG_PTR)local.fn,
                       (unsigned long)local.fnResult);
            } else {
                printf("SELFTEST CreateThread failed err=%lu\n",
                       (unsigned long)GetLastError());
            }
            VirtualFree(localcode, 0, MEM_RELEASE);
        }
    }
    if (verbose) printf("remote_thread_exit=%lu\n", (unsigned long)exitCode);

    ZeroMemory(&readback, sizeof(readback));
    if (!ReadProcessMemory(hp, remote, &readback, sizeof(readback), &got) ||
        got != sizeof(readback)) {
        XhWin32Error("ReadProcessMemory(params)"); rc = 6; goto done;
    }

    printf("remote_stage=%lu\n", (unsigned long)readback.stage);
    printf("remote_status=%lu\n", (unsigned long)readback.status);
    printf("remote_module=0x%08lX\n", (unsigned long)(ULONG_PTR)readback.module);
    printf("remote_fn=0x%08lX\n", (unsigned long)(ULONG_PTR)readback.fn);
    printf("remote_result=0x%08lX\n", (unsigned long)readback.fnResult);
    printf("remote_ebxSeen=0x%08lX expected_params=0x%08lX\n",
           (unsigned long)readback.ebxSeen, (unsigned long)(ULONG_PTR)remote);
    printf("remote_probes=%08lX %08lX %08lX %08lX\n",
           (unsigned long)readback.probe1, (unsigned long)readback.probe2,
           (unsigned long)readback.probe3, (unsigned long)readback.probe4);

    if (readback.stage < 2 || readback.module == NULL) {
        fprintf(stderr, "ERROR module load/lookup returned NULL in target");
        if (readback.status) fprintf(stderr, " (Win32 error %lu)",
                                     (unsigned long)readback.status);
        fprintf(stderr, "\n");
        if (readback.status == 126)
            fprintf(stderr, "HINT: 126 = ERROR_MOD_NOT_FOUND. The target cannot "
                            "see that path (bitness of the DLL, or a path the "
                            "target cannot read).\n");
        rc = 8;
        goto done;
    }
    if (wantExport && !readback.fn) {
        fprintf(stderr, "ERROR GetProcAddress(\"%s\") returned NULL in target\n",
                params->arg1);
        rc = 9;
        goto done;
    }
    rc = 0;

done:
    if (th) CloseHandle(th);
    if (hp) CloseHandle(hp);
    return rc;
}

/* ------------------------------------------------------------------ main */

static void usage(void)
{
    fprintf(stderr,
        "usage:\n"
        "  injector.exe find   <exeName> [index]\n"
        "  injector.exe arch   <pid>\n"
        "  injector.exe inject <pid> <dllPath> [exportToCall] [arg]\n"
        "  injector.exe call   <pid> <moduleName> <exportName> [arg]\n");
}

int main(int argc, char **argv)
{
    if (argc < 2) { usage(); return 1; }

    if (lstrcmpiA(argv[1], "find") == 0) {
        const char *name = (argc >= 3) ? argv[2] : "noita.exe";
        char path[MAX_PATH];
        int i, found = 0;
        for (i = 0; i < 16; i++) {
            DWORD pid = XhFindPid(name, path, MAX_PATH, i);
            WORD  m;
            if (!pid) break;
            m = XhRemoteMachine(pid);
            printf("pid=%lu machine=0x%04X (%s) path=%s\n",
                   (unsigned long)pid, (unsigned)m, XhMachineName(m), path);
            found++;
        }
        if (!found) { fprintf(stderr, "no process named %s found\n", name); return 2; }
        return 0;
    }

    if (lstrcmpiA(argv[1], "arch") == 0) {
        DWORD pid;
        WORD m;
        if (argc < 3) { usage(); return 1; }
        pid = (DWORD)strtoul(argv[2], NULL, 10);
        m = XhRemoteMachine(pid);
        printf("pid=%lu machine=0x%04X (%s)\n", (unsigned long)pid,
               (unsigned)m, XhMachineName(m));
        return (m == 0x014C) ? 0 : 3;
    }

    if (lstrcmpiA(argv[1], "inject") == 0) {
        DWORD pid;
        WORD m;
        XH_REMOTE p;
        if (argc < 4) { usage(); return 1; }
        pid = (DWORD)strtoul(argv[2], NULL, 10);
        m = XhRemoteMachine(pid);
        printf("target_pid=%lu\n", (unsigned long)pid);
        printf("target_machine=0x%04X (%s)\n", (unsigned)m, XhMachineName(m));
        printf("injector_machine=0x%04X (%s)\n", (unsigned)0x014C, XhMachineName(0x014C));
        if (m == 0x8664 || m == 0xAA64) {
            fprintf(stderr, "ERROR target is not 32-bit; refusing to inject\n");
            return 3;
        }
        if (m != 0x014C) {
            fprintf(stderr, "ERROR could not determine target architecture "
                            "(OpenProcess denied or unreadable image)\n");
            return 3;
        }
        ZeroMemory(&p, sizeof(p));
        p.pLoadLibraryA     = LoadLibraryA;
        p.pGetModuleHandleA = GetModuleHandleA;
        p.pGetProcAddress   = GetProcAddress;
        p.pGetLastError     = GetLastError;
        printf("local_kernel32=0x%08lX\n",
               (unsigned long)(ULONG_PTR)GetModuleHandleA("kernel32.dll"));
        printf("local_LoadLibraryA=0x%08lX local_GetProcAddress=0x%08lX "
               "local_GetLastError=0x%08lX\n",
               (unsigned long)(ULONG_PTR)p.pLoadLibraryA,
               (unsigned long)(ULONG_PTR)p.pGetProcAddress,
               (unsigned long)(ULONG_PTR)p.pGetLastError);
        lstrcpynA(p.arg0, argv[3], sizeof(p.arg0));
        p.entry = XH_E_LOADLIB;
        if (argc >= 5) lstrcpynA(p.arg1, argv[4], sizeof(p.arg1));
        if (argc >= 6) p.callArg = (DWORD)strtoul(argv[5], NULL, 0);
        return XhRunRemote(pid, &p, (argc >= 5), 1);
    }

    if (lstrcmpiA(argv[1], "call") == 0) {
        DWORD pid;
        XH_REMOTE p;
        if (argc < 5) { usage(); return 1; }
        pid = (DWORD)strtoul(argv[2], NULL, 10);
        ZeroMemory(&p, sizeof(p));
        p.pGetModuleHandleA = GetModuleHandleA;
        p.pGetProcAddress   = GetProcAddress;
        p.pGetLastError     = GetLastError;
        lstrcpynA(p.arg0, argv[3], sizeof(p.arg0));
        lstrcpynA(p.arg1, argv[4], sizeof(p.arg1));
        p.entry = XH_E_GETMODULE;
        if (argc >= 6) p.callArg = (DWORD)strtoul(argv[5], NULL, 0);
        return XhRunRemote(pid, &p, 1, 1);
    }

    usage();
    return 1;
}
