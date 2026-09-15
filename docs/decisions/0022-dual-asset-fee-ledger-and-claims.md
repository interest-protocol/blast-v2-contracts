# 0022: Dual-asset fee ledger and capability claims

- Status: accepted
- Date: 2026-08-23
- Partially accepts: [0006](0006-fees-and-launch-paths.md), [0007](0007-acl-pause-and-versioning.md), [0011](0011-event-schema-and-replay.md)
- Amended by: [0028](0028-hot-cold-runtime-configuration.md), [0030](0030-singleton-event-identity.md), [0041](0041-launch-config-owned-trade-fees.md), [0058](0058-eventless-package-initialization.md), [0079](0079-compact-launch-state-and-events.md), and [0081](0081-separate-lp-fee-share-policy.md)

> ADR 0079 removes initial zero fee totals and sender/type aliases from launch
> events. Trade events retain the fee deltas and final totals needed for replay.

## Sources

| Ref | Full commit | Repository |
| --- | --- | --- |
| `sui@06734f6` | `06734f6ff0af45d8632a14a4dc4b100197f6b1a2` | MystenLabs/sui |

## Context

ADR 0021 fixed where quote and meme trade fees are calculated, but deliberately left the resulting
assets with the future accounting caller. The next slice must preserve those fees separately from curve
reserves, make creator proceeds claimable through the already accepted `CreatorCap<Meme>`, and avoid
making trading depend on an arbitrary recipient.

The generated meme type is unique to one launch and remains stable after migration. It is therefore the
fee authority and indexing domain; the ledger does not need a second launch identifier. A fee ledger is
not independently addressable protocol state. It belongs inside the future `Launch<Meme, Quote>` so a
trade cannot update reserves without atomically updating its fee obligations.

## Decision

### Rates and beneficiary split

Admins set fixed `quote_fee_bps` and `meme_fee_bps` independently in cold
`LaunchConfig` policy. Each rate is between zero and **1,000 basis points
(10%)**, inclusive. Zero disables that asset's fee, and both rates may be
positive. `LaunchConfig` enforces the ceiling and each new launch snapshots the
active pair; `fees.move` receives already-calculated `Balance` values and does
not recompute curve fees or accept rates.

The protocol/creator split is different: it is one live, global `protocol_fee_share_bps` value in the
shared `RuntimeConfig`, bounded from zero through 10,000 basis points. Every trade on every launch
reads the current configuration. An update therefore applies to the next fee accrual of all existing
and future launches; neither `Launch` nor `FeeLedger` snapshots the split.
There is no independently stored `creator_fee_share_bps`: it is always the
complement of the protocol share, and the creator receives the exact fee
remainder after protocol-favouring rounding.
The singleton starts at zero so package publication cannot silently begin taking protocol revenue.
An administrator must choose any nonzero share explicitly, and the setter rejects an unchanged value
so every emitted update represents a real state transition.

Every accrued fee uses that current value:

```text
protocol = ceil(fee * protocol_fee_share_bps / 10_000)
creator  = fee - protocol
```

The protocol receives the indivisible remainder. Computation uses the pinned MoveStdlib
`u64::mul_div_ceil`, which delegates to a `u128` intermediate
(`sui@06734f6:crates/sui-framework/packages/move-stdlib/sources/u64.move:41-42`); the creator amount is
subtraction from the original `u64`. Consequently the full `u64` fee domain is supported without an
intermediate overflow.

### Stored accounting

`FeeLedger<phantom Meme, phantom Quote> has store` contains exactly four balances:

- protocol meme;
- creator meme;
- protocol quote; and
- creator quote.

The ledger has no `UID`, address, recipient list, signature state, launch id, rates, or lifecycle flag.
It is embedded by value in `Launch<Meme, Quote>`. Curve reserves remain separate balances owned by the
launch module.

One package-only `accrue` operation consumes both asset fee balances from a completed curve quote and
the current validated global protocol share. The future shared configuration owns the percentage bound;
the package-only accrual seam does not repeat that assertion on every trade. At least one fee balance
must be nonzero. It then splits and joins the conserved balances. The conservation equations are exact
for each call and sequence:

```text
meme_fee  = protocol_meme_delta  + creator_meme_delta
quote_fee = protocol_quote_delta + creator_quote_delta
```

There is no redundant fee-ledger overflow guard. The framework represents both `Supply<T>` and every
`Balance<T>` as `u64`, prevents minting beyond the remaining `u64` supply, and exposes only conserving
split/join operations for existing balances
(`sui@06734f6:crates/sui-framework/packages/sui-framework/sources/balance.move:30-38,55-59,75-86`).
For valid coin provenance, a ledger balance plus an incoming fee balance is therefore bounded by that
coin's total supply. Test-only fabrication of multiple maximum-width balances for one type violates this
framework invariant and is not a reachable protocol state.

The operation returns the four deltas and the four final ledger totals to the enclosing launch
operation. This gives that operation everything needed to emit one final-state trade event without
exposing ledger fields or reading them again; the pinned `Balance::join` returns the post-join total
(`sui@06734f6:crates/sui-framework/packages/sui-framework/sources/balance.move:76-79`). No recipient
transfer occurs during accrual.

### Claims

`claim_creator_fees` borrows `CreatorCap<Meme>`, drains both creator balances, and returns
`(Coin<Meme>, Coin<Quote>)`. `claim_protocol_fees` borrows `AdminWitness`, drains both protocol
balances, and returns the same pair. Each function aborts if both balances in its authority domain are
zero. A positive balance in either asset is sufficient, and the other returned coin may be zero.

Claims are full-balance and composable. They never transfer directly, accept a recipient, consult the X
signer, resolve SuiNS, or require an application signature. The caller decides how to transfer, merge,
wrap, or distribute the returned coins later in the PTB.

The functions are package-only because the ledger is embedded behind private `Launch` fields. The
future public surface is `launch::claim_creator_fees` and `launch::claim_protocol_fees`; those wrappers
will apply the launch version guard, delegate authority and accounting to this module, advance the
launch state, and emit the replay-complete claim facts after final state is known.

### Events and sequencing

`fees.move` does not emit an event before its caller has completed the enclosing launch transition.
The future `Bought` and `Sold` payloads are the sole accrual facts: each carries both asset fee totals,
the `protocol_fee_share_bps` actually applied, the exact protocol/creator deltas, and all four final
ledger totals. A separate `FeesAccrued` payload would duplicate one atomic mutation and either consume
additional event bandwidth or create two competing facts for one transition.

The initial global share is the compiled zero of the published bytecode — under ADR 0058 there is no
`RuntimeConfigCreated` payload — and `ProtocolFeeShareChanged` records its old and new values.
`LaunchCreated` records all four initial zero ledger totals but no split snapshot.
`CreatorFeesClaimed` and `ProtocolFeesClaimed` carry both claimed amounts and the two affected remaining
totals, which are zero after a full-balance claim. Launch-scoped payloads use the original meme and quote
type names as stable identity and carry a timestamp where the domain needs it; fee-configuration payloads
use their fully qualified singleton payload type and old/new values without repeating the runtime-config
id. Native Sui checkpoint, transaction, and event position provide ordering. Every payload is emitted
through the package event wrapper after final state is known.

Claim events name the transaction claimant, not a recipient. The functions return coins, and a later
command in the same programmable transaction may transfer each coin to any address. An indexer that
needs the final payout address follows native transaction effects; it must not infer the recipient from
the protocol claim event.

### Creator assignment

There is no initial onchain multi-recipient fee-split list and no `set_creator_fee_split` function.
Creator authority is assigned by transferring `CreatorCap<Meme>`. A cap holder may claim both assets and
perform any desired bounded distribution in the same PTB. A persistent allocation or vesting policy is
a separate concern and requires its own approved module and storage decision.

## Alternatives considered

**Separate shared fee vault.** Rejected: every trade would need a second shared mutable object and a
binding invariant between reserves and fees. Embedding the ledger makes reserve and fee accounting one
atomic state transition.

**Route fees during the trade.** Rejected: arbitrary recipient execution would become a trading
dependency and could block otherwise valid buys or sells.

**One balance per asset followed by a split at claim time.** Rejected: changing policy later could
retroactively change ownership of already-earned fees. Splitting at accrual fixes the obligation when it
is created.

**Snapshot the protocol/creator share in each launch.** Rejected: an administrator would need to update
every launch object, and launches missed by the update would keep stale economics. One live shared
configuration makes the update atomic for all subsequent trades.

**Persistent creator recipient vector.** Deferred: the transferable cap and composable coin returns
cover one current authority without adding bounded-vector mutation, per-recipient rounding, or payout
execution to the core ledger.

**A package math module for this division.** Rejected: the pinned MoveStdlib already provides the exact
widened `mul_div_ceil` operation. A Blast wrapper would be a shallow forwarding layer.

## Consequences

- Quote and meme fees can both accrue without sharing storage with their curve reserves.
- Unclaimed creator fees remain claimable during bonding, migration, and after migration.
- A transferred `CreatorCap<Meme>` transfers authority over all currently accrued and future creator
  fees for that meme type.
- A protocol-share update changes every launch's subsequent accrual immediately. It never reclassifies
  creator or protocol balances that were already accrued under the previous percentage.
- Protocol claims use the existing revocable admin sign-in path; creator claims use no ACL or backend
  signer after capability issuance.
- Protocol events reconstruct issuance and fee authority use, while current custody of a transferable
  `CreatorCap<Meme>` remains a native Sui object-ownership fact.
- The future `Launch` layout has one embedded ledger and no second shared fee object.
- Multi-recipient allocation remains outside the first fee-ledger release.

## Verification

- [`../vectors/fees.json`](../vectors/fees.json) fixes multiple configured shares, zero/one-unit,
  rounding, and maximum-`u64` split results.
- Accrual tests cover meme-only, quote-only, both assets, repeated accrual, zero rejection, maximum width,
  both percentage boundaries, a percentage change on an existing ledger, and exact per-asset
  conservation. Tests do not fabricate supply-inconsistent balances to exercise unreachable overflows.
- Creator and protocol tests obtain real `CreatorCap<Meme>` and `AdminWitness` values through their
  production authority seams, then verify full-balance claims and empty-claim aborts.
- A claim with only one accrued asset returns that value and a zero coin of the other type.
- Tests verify that claims return coins without transferring them and that a creator claim does not
  change protocol balances, or vice versa.
- Shared-config tests cover both percentage boundaries, reject values above 10,000 and unchanged
  updates, authorize changes with `AdminWitness`, and emit the config id and old/new percentage after
  mutation without a redundant application sequence.
- Launch integration tests replay fee events against the ledger after buys,
  sells, claims, and migration; transferred-capability routing is covered by
  the fee-ledger integration suite.
- Build, strict lint, full tests, Move coverage, and structural source checks are release gates.
