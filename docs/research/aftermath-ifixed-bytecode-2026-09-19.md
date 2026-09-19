# Aftermath IFixed: on-chain bytecode read

- Date: 2026-09-19
- Method: the `ifixed` module of the pinned package
  `0x4b4703a7581781d74a4c7b0fb0836b2a67f34f1a377fb81aab6f5cad29d78760`
  (version 1) was fetched through Sui GraphQL, its sha256
  `ab7e23db8976e59a4e63db87c450ab72d70626050094d6a227bfdb11dccb140e` matched
  the hash `check_mainnet_abi.mjs` pins, and the module was disassembled with
  the Sui 1.77.2 toolchain. Each function the adapter calls was modelled
  instruction by instruction and checked against two's-complement reference
  semantics on 40,000 random and edge inputs.
- Companion decision: [ADR 0074](../decisions/0074-aftermath-vault-activation-and-health.md),
  IFixed convention.

## Why

`blast_boosts_aftermath::ifixed_math` scales IFixed magnitudes to atoms and
converts USD to collateral with its own integer arithmetic. It never
re-implements Aftermath math; it relies only on how Aftermath *encodes* a
value, which until now was taken from the pinned interface source constants.
This read confirms the encoding from the deployed bytecode.

## Constant pool

| Index | Value | Meaning |
| --- | --- | --- |
| 0 | `10^18` | `one()` |
| 1 | `2^256 − 1` | `NEG_ONE`, all bits set |
| 2 | `2^255` | sign bit |
| 3 | `2^255 − 1` | low 255 bits |
| 4 | `12001` | overflow abort code |
| 5 | `vector<u64>` of 19 entries | `10^18, 10^17, …, 1` |

## Functions the adapter calls

| Function | Bytecode | Confirmed semantics |
| --- | --- | --- |
| `is_neg(x)` | `x >= 2^255` | sign is bit 255 |
| `abs(x)` | negative: `((x xor (2^255−1)) + 1) xor 2^255`; else `x` | two's-complement magnitude; aborts (u256 add overflow) only on `−2^255`, whose magnitude is unrepresentable |
| `add(x, y)` | low-bit add, sign check, abort `12001` on signed overflow | signed add |
| `sub(x, y)` | magnitude subtract with sign fix-up, abort `12001` on signed overflow | signed subtract |

## Functions the adapter mirrors but does not call

| Function | Bytecode | Adapter equivalent |
| --- | --- | --- |
| `decimal_scalar_from_decimals(d)` | asserts `d <= 18`, returns table entry `d` | `pow10(18 − d)` |
| `to_balance(x, s)` | asserts `x < 2^255`, returns `(x / s) as u64` | `fixed_to_u64_down(x, d)` gives the same value for every nonnegative `x` that fits a u64, and reports `false` instead of aborting on the cast |
| `mul`, `div` | product or quotient of magnitudes, same sign floors, different signs rounds away from zero | not used; `usd_fixed_to_collateral_fixed` works on magnitudes and picks its rounding per quantity |

## Consequences

- The ADR 0074 convention (`one() == 10^18`, sign from `is_neg`, magnitude
  from `abs`) is what the deployed code does.
- `fixed_to_u64_down` is `to_balance` composed with
  `decimal_scalar_from_decimals` for the nonnegative inputs the adapter passes
  after `abs()`; `fixed_to_u64_up` is the ceiling the venue has no port for.
- Aftermath's own signed `mul` and `div` round negative results away from
  zero, so a liability's magnitude rounds up inside the venue as well; the
  adapter's liability-up rule agrees with the venue's direction.
- The ABI gate already pins this module's hash, so any change to the deployed
  bytecode fails the gate before this reading could go stale.
