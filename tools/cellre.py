r"""Shared helpers for the cell-material investigation.

The one thing every earlier scan got wrong: a raw file offset plus the image base is NOT a
virtual address.  Section raw data starts at PointerToRawData, virtual data starts at
VirtualAddress; for noita.exe those differ, so `IB + file_offset` lands in the middle of an
instruction.  Every function here converts properly through pefile.

Read-only: nothing in this module writes to the game or the binary.
"""
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

EXE = r"D:\Sware\Steam\steamapps\common\Noita\noita.exe"


class Image:
    def __init__(self, path=EXE):
        self.path = path
        self.pe = pefile.PE(path, fast_load=True)
        self.ib = self.pe.OPTIONAL_HEADER.ImageBase
        self.md = capstone.Cs(capstone.CS_ARCH_X86, capstone.CS_MODE_32)
        self.md.detail = True

    # ---------------------------------------------------------------- mapping
    def sec_for_va(self, va):
        for s in self.pe.sections:
            start = self.ib + s.VirtualAddress
            size = max(s.SizeOfRawData, s.Misc_VirtualSize)
            if start <= va < start + size:
                return s
        return None

    def va_of_offset(self, off):
        """Raw file offset -> VA, or None."""
        for s in self.pe.sections:
            if s.PointerToRawData <= off < s.PointerToRawData + s.SizeOfRawData:
                return self.ib + s.VirtualAddress + (off - s.PointerToRawData)
        return None

    def off_of_va(self, va):
        s = self.sec_for_va(va)
        if not s:
            return None
        return s.PointerToRawData + (va - (self.ib + s.VirtualAddress))

    def read(self, va, n):
        s = self.sec_for_va(va)
        if not s:
            return None
        off = va - (self.ib + s.VirtualAddress)
        return s.get_data()[off:off + n]

    def u32(self, va):
        b = self.read(va, 4)
        return struct.unpack("<I", b)[0] if b and len(b) == 4 else None

    def u16(self, va):
        b = self.read(va, 2)
        return struct.unpack("<H", b)[0] if b and len(b) == 2 else None

    def cstr(self, va, maxlen=200):
        b = self.read(va, maxlen)
        if b is None:
            return None
        z = b.find(b"\x00")
        return b[:z if z >= 0 else maxlen].decode("latin-1")

    def text(self):
        for s in self.pe.sections:
            if s.Name.rstrip(b"\x00") == b".text":
                return s
        return None

    # ------------------------------------------------------------ searching
    def all_sections(self):
        return list(self.pe.sections)

    def find_bytes(self, needle):
        """Every VA where `needle` occurs, across all sections."""
        out = []
        for s in self.pe.sections:
            data = s.get_data()
            start = 0
            while True:
                i = data.find(needle, start)
                if i < 0:
                    break
                out.append(self.ib + s.VirtualAddress + i)
                start = i + 1
        return out

    def find_string(self, text):
        """VA of a NUL-terminated occurrence of `text`."""
        raw = text.encode("latin-1") if isinstance(text, str) else text
        out = []
        for va in self.find_bytes(raw + b"\x00"):
            out.append(va)
        return out

    # --------------------------------------------------------- disassembly
    def flat(self):
        """One bytearray covering [image base, end of the last section).

        Per-dword Python calls into `read`/`u32` are far too slow when a scan has to test
        hundreds of thousands of candidates; this gives array indexing instead.
        """
        if getattr(self, "_flat", None) is not None:
            return self._flat
        lo = self.ib
        hi = max(self.ib + s.VirtualAddress + max(s.SizeOfRawData, s.Misc_VirtualSize)
                 for s in self.pe.sections)
        buf = bytearray(hi - lo)
        for s in self.pe.sections:
            start = self.ib + s.VirtualAddress - lo
            d = s.get_data()
            buf[start:start + len(d)] = d
        self._flat = (buf, lo, hi)
        return self._flat

    def disasm(self, va, n=200, stop_ret=True, stop_jmp=False, show_bytes=True):
        """Yield capstone instructions starting at va, following nothing.

        stop_ret stops at the first ret/int3 (a linear dump of one function).
        stop_jmp additionally treats an unconditional jmp as the end -- WRONG for a real
        function body, which contains plenty of forward jumps; it only makes sense when
        reading a straight-line block.
        """
        data = self.read(va, n)
        if data is None:
            return
        first = True
        for ins in self.md.disasm(data, va):
            yield ins
            if stop_ret and ins.mnemonic in ("ret", "retn", "int3") and not first:
                return
            if stop_jmp and ins.mnemonic == "jmp" and not first:
                return
            first = False


def fmt(ins, show_bytes=True):
    if show_bytes:
        return (f"  0x{ins.address:X}  {ins.bytes.hex(' '):<24} "
                f"{ins.mnemonic} {ins.op_str}")
    return f"  0x{ins.address:X}  {ins.mnemonic} {ins.op_str}"


def show(im, va, n=200, stop_ret=True, header=None):
    if header:
        print(header)
    for ins in im.disasm(va, n, stop_ret=stop_ret):
        print(fmt(ins))
    print()


def absolute_operands(im, va, n=400):
    """All absolute memory operands inside a linear disassembly from va."""
    out = []
    for ins in im.disasm(va, n, stop_ret=False):
        for op in ins.operands:
            if op.type == capstone.x86.X86_OP_MEM and op.mem.base == 0 and op.mem.index == 0:
                out.append((ins.address, op.mem.disp, ins.mnemonic, ins.op_str))
    return out
