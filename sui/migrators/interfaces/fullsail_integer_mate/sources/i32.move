/// Minimal Full Sail IntegerMate revision-1 interface. Link stubs must not execute.
module fullsail_integer_mate::i32;

public struct I32 has copy, drop, store { bits: u32 }

public fun abs_u32(_value: I32): u32 { abort 0 }
public fun as_u32(_value: I32): u32 { abort 0 }
public fun neg_from(_value: u32): I32 { abort 0 }
