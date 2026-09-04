# Shared differential vectors

Implementation-independent test data consumed by Sui and reserved for any future
chain implementation. An unexplained numeric difference is a release blocker.

## Files

| File | Covers | Owning decision |
| --- | --- | --- |
| [`curve.json`](curve.json) | buy, sell, threshold crossing, both burn moments, boundaries, round trip | [`../decisions/0004-bonding-curve.md`](../decisions/0004-bonding-curve.md), [`../decisions/0003-treasury-cap-lifetime-and-burn.md`](../decisions/0003-treasury-cap-lifetime-and-burn.md) |
| [`fees.json`](fees.json) | configurable protocol/creator shares, rounding, update sequences, maximum width | [`../decisions/0022-dual-asset-fee-ledger-and-claims.md`](../decisions/0022-dual-asset-fee-ledger-and-claims.md) |
| [`quote-decimals.json`](quote-decimals.json) | decimal combinations, both pair orientations, `sqrt_price_x64`, display price | [`../decisions/0005-quote-asset-generalisation.md`](../decisions/0005-quote-asset-generalisation.md), [`../decisions/0010-migration-and-venue-adapters.md`](../decisions/0010-migration-and-venue-adapters.md) |
| [`x-creator-claim.json`](x-creator-claim.json) | canonical coin-type-bound X claim BCS encoding and Ed25519 verification fixture | [`../decisions/0017-coin-type-domain-for-x-creator-claims.md`](../decisions/0017-coin-type-domain-for-x-creator-claims.md) |
| [`vesting.json`](vesting.json) | stepped-linear cliff boundaries, rounding remainder, and maximum-width arithmetic | [`../decisions/0052-stepped-linear-vesting.md`](../decisions/0052-stepped-linear-vesting.md) |

## Rules

1. **Atomic units everywhere.** Every amount is an integer in the smallest unit of its asset. No vector
   contains a human-readable price except in a field explicitly named `display_*`, which exists to prove
   that the display conversion needs both decimal values while the raw on-chain ratio does not.
2. **Integers are exact; derived decimals are not.** Every integer field is computed with exact integer
   arithmetic — floor division, ceiling division, integer square root — and is a valid test oracle. Any
   field whose name ends `_decimal_*` or is flagged
   `display_price_is_a_derived_presentation_value` is a **rounded presentation value** and must never be
   used as an oracle; the accompanying `*_exact_rational` field is authoritative. The display price in
   `quote-decimals.json` is a non-terminating rational, so no finite decimal represents it exactly.
3. **Every division names its direction.** Each case records the rounding direction applied and, where
   value moves, who receives the remainder.
4. **Parameter status follows its owning ADR.** The fee-rate ceiling and global split bounds in
   `fees.json` are accepted by ADR 0022; the remaining curve, migration-fee, and burn parameters are
   proposed. Changing any value invalidates every dependent vector, and the files must be regenerated
   rather than edited by hand.
5. **Every implementation consumes shared economic files.** Signature-domain
   fixtures may be chain-specific where chains expose different native type
   systems. ADR 0017 binds the Sui claim to the generated coin's original
   `TypeName`. Any future difference must be documented in an ADR, per
   `../architecture.md`.
6. **Unreachable cases are labelled.** A case whose `expect` names `EUnreachableByConstruction` pins pure
   arithmetic at a boundary the lifecycle cannot produce. It is a maths oracle, never evidence that the
   trade can execute.
7. **No empirical claim without a committed generator.** These files state properties as *required tests*
   and do not assert measured pass counts, because no generator is committed here to substantiate one.

## Schema

The arithmetic vector files are JSON objects with:

- `schema_version` — integer, bumped on any structural change;
- `description` — what the file covers;
- `source_decisions` — the ADR paths that own the values;
- `units` — the unit and rounding conventions in force;
- `parameters` — the accepted or proposed constants and bounds the cases were generated from;
- `cases` — an array of objects, each with `name`, `kind`, `given`, `expect`, and `notes`.

A case's `expect` block is the assertion target. A case whose `expect` contains
`abort` names the exact expected error; a bare failure could be satisfied by an
unrelated abort.

`properties` entries are not per-case oracles. They are invariants the implementation must prove by test;
one carries a `status` field recording that it is asserted rather than yet evidenced.

`x-creator-claim.json` instead records the exact typed-field order, signed BCS
bytes, digest, public key, Ed25519 signature, and the canonical 73-byte value
inside the X branch's `Some(vector<u8>)` call argument. Its
`vector_schema_version` describes the JSON fixture, not a field in the signed
message. The address branch sends `None`. The file deliberately contains no
private key and no production credential.

## Reproduction

The curve cases follow the formulas in
[`../decisions/0004-bonding-curve.md`](../decisions/0004-bonding-curve.md) exactly: floor for user
payouts, ceiling for protocol fees and seller obligations, and floor-floor on the burn ramp with a single
ceiling on the burn amount. The sqrt price cases follow
[`../decisions/0005-quote-asset-generalisation.md`](../decisions/0005-quote-asset-generalisation.md):

```text
sqrt_price_x64 = isqrt( (numerator_atomic << 128) / denominator_atomic )
```

where the numerator is the asset that is coin B and the denominator the asset that is coin A.
