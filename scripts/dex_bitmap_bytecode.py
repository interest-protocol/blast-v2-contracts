"""Bind the Z3 bitmap mask and scan models to compiled Move."""

import re

from dex_mul_div_bytecode import disassemble, disassemble_module, read_function
from dex_tick_proof import SCAN_SHIFTS, WIDTH


def check_bitmap_bytecode(module):
    source = disassemble_module(module, 0, "curve")
    if not re.search(r"^use 0*1::vector;$", source, re.M):
        raise SystemExit("Compiled curve does not bind std::vector.")
    maximum = (1 << WIDTH) - 1
    expected = (
        ("at_or_beyond", "u256 u8 bool", "u256 u256", "u256",
         f"LdU256:1|CopyLoc1|Shl|LdU256:1|Sub|StLoc4|MoveLoc2|BrFalse(15)|"
         f"MoveLoc0|LdU256:{maximum}|MoveLoc4|Xor|BitAnd|StLoc3|Branch(23)|"
         "MoveLoc0|MoveLoc4|LdU256:1|MoveLoc1|Shl|BitOr|BitAnd|StLoc3|MoveLoc3|Ret"),
        ("strictly_beyond", "u256 u8 bool", "", "u256",
         "MoveLoc0|CopyLoc1|MoveLoc2|Call at_or_beyond(u256, u8, bool): u256|"
         f"LdU256:{maximum}|LdU256:1|MoveLoc1|Shl|Xor|BitAnd|Ret"),
        ("bit_index", "u256 bool", "u64 bool u256 u64 u32 u256 u8 u64 vector<u8>", "u32",
         "LdU32:0|StLoc6|LdConst1|StLoc10|MutBorrowLoc10|Call vector::reverse<u8>(&mut vector<u8>)|"
         "ImmBorrowLoc10|VecLen(54)|StLoc2|LdU64:0|StLoc5|MoveLoc2|StLoc9|"
         "CopyLoc5|CopyLoc9|Lt|BrFalse(62)|CopyLoc5|Pop|MutBorrowLoc10|VecPopBack(54)|StLoc8|"
         "CopyLoc0|CopyLoc8|Shr|StLoc4|MoveLoc0|LdU256:1|CopyLoc8|Shl|LdU256:1|Sub|BitAnd|StLoc7|"
         "CopyLoc1|BrFalse(41)|CopyLoc7|LdU256:0|Eq|StLoc3|Branch(45)|CopyLoc4|LdU256:0|Gt|StLoc3|"
         "MoveLoc3|BrFalse(55)|MoveLoc4|StLoc0|MoveLoc6|MoveLoc8|CastU32|Add|StLoc6|Branch(57)|"
         "MoveLoc7|StLoc0|MoveLoc5|LdU64:1|Add|StLoc5|Branch(13)|"
         "MoveLoc10|VecUnpack(54, 0)|MoveLoc6|Ret"),
    )
    for name, arguments, locals_, result, instructions in expected:
        if read_function(source, name, arguments, locals_, result) != instructions.split("|"):
            raise SystemExit(f"Compiled {name} differs from the bitmap proof.")

    debug = disassemble(module, "--Xdebug")
    constants = re.search(r"^    constant_pool: \[(.*?)^    \],", debug, re.M | re.S)
    if constants is None:
        raise SystemExit("Compiled curve constant pool is missing.")
    entries = re.findall(r"^        Constant \{\n(.*?)^        \},", constants[1], re.M | re.S)
    if len(entries) < 2:
        raise SystemExit("Compiled bitmap scan constant is missing.")
    vector = re.fullmatch(r"\s*type_: Vector\(U8\),\s*data: \[([\d,\s]+)\],\s*", entries[1])
    if vector is None or tuple(map(int, re.findall(r"\d+", vector[1]))) != (len(SCAN_SHIFTS), *SCAN_SHIFTS):
        raise SystemExit("Compiled bitmap scan uses a different vector of shifts.")
    print("PASS compiled bitmap masks and scan instructions and shift vector", flush=True)
