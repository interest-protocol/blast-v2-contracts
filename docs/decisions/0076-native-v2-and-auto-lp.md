# 0076: Native V2 and automatic liquidity deposits

- Status: accepted for implementation; live release gates remain
- Date: 2026-09-05

## Context

Accepted for implementation on 2026-09-05 after the user approved the reviewed
volume-fee design and requested implementation. This authorizes development,
not publication. The earlier explicit 0%–2% default resolves the subsequent
ambiguous “0.2” wording; no further clarification blocks implementation.

## Decision

Add an independently deployed `blast_fun_dex` package depending inward on the
launchpad, and a separate `blast_fun_auto_lp` custody adapter depending on the
DEX and existing external migrators. Core imports neither. A publication-only
factory enforces one canonical pool per original Meme type, bound to its launch
Quote; Meme is always the first type parameter. Creator-funded pools require
the creator capability and an already-migrated launch. The native migration
witness creates a fresh pool atomically and locks its complete issued position.
That route cannot be preempted by the creator-funded constructor during bonding.
Quote admission requires a migration target of at least two atomic units. With
the existing 500-bps Quote migration-fee ceiling enforced when graduation
defaults are set, this guarantees positive seed principal without rechecking
configuration during launch creation.

Use full-range constant-product principal reserves. Initial shares are the
integer square root of the seed product, with 1,000 shares permanently
unrepresented to protect initial issuance. Subsequent deposits mint the smaller
share amount supported by both supplied assets, charge the rounded-up required
amounts and return both excess coins. Withdrawals round principal payouts down.

All swap fees are Quote, held outside reserves and allocated to LP positions
through a cumulative fee-growth index. Owned transferable positions settle
their old shares before changing size; fractions remain with that position.
No depositor acquires earlier fees. Native migration's locked position routes
its claimed fees through the existing protocol/creator fee ledger and live
runtime split, matching existing external migration semantics. Public LPs earn
their position fees directly; no additional arbitrary fee split is introduced.

The marginal fee rises from zero to an initial 200 bps. Existing protocol admins
may change one pool's cap through 500 bps. The update changes no principal,
volume, time anchor, or previously earned fee. Every swap checks a signed
maximum effective fee on rounded Quote fees, net output and deadline. Burn and
price impact are outside the trading-fee ceiling.

Use capped volume in Q32 Quote atoms, a fixed 1,800-second half-life, and a
target equal to the initial Quote seed. These are explicit initial policy
choices: no new K/H setters. Decay uses exact whole-half-life division and a
bounded upward Q64 remainder approximation; final score truncation loses less
than 2^-32 Quote atoms per successful nonzero swap. No zero-volume operation
updates the anchor. A sufficiently long idle interval resets sub-quantum memory.
Integrate the fee over the current trade, round the final charge up, and solve
buy principal by the exact integer budget inequality. Wide intermediates own
overflow safety. Mathematical same-time split neutrality admits per-call
rounding costs and excludes intervening cap changes.

Creator-funded pools choose an immutable optional Meme burn through 500 bps at
creation, validated against `Currency<Meme>` BurnOnly authority. Native
migration initially uses zero burn. Sells burn before principal enters the curve;
buys burn from curve output. A burn-enabled pool requires actual registry burn
in the same transaction. Fixed-supply pools use the no-burn path. No quote
conversion or balancing swap is introduced.

Auto-LP enrollment consumes the unique CreatorCap into a sealed dynamic object
field and permanently holds a position in the bound native pool. Anyone can
collect creator fees from the launch, external migration vault, or native
migration vault into custody, and collect its own position fees. Enrollment also
pins a nonzero immutable executor address chosen by the cap owner. Only that
executor may compound at the current reserve ratio, with signed maximum Meme
and Quote consumption, minimum-share and deadline bounds;
zero-sided/dust deposits skip and keep custody intact. There is no principal,
cap, position, fee-balance extraction or arbitrary payout path. Quote-only native
fees wait for Meme from other source claims or contributions.

Unrestricted compounding was rejected during implementation review: buying
against reserves 100,000/100,000 for 101,000 Quote, forcing a vault holding
100,000 of each asset to deposit at the skewed ratio, and selling back earns
16,600 Quote after fees. A minimum selected by the attacker does not protect
the vault. Minimum shares alone also permit a price pump to increase Quote
consumption while increasing minted shares; per-asset maximums bind the actual
deposit computed before withdrawal. The chosen executor controls price and timing and must set
meaningful limits; it receives no withdrawal right. Executor loss stops new
deposits permanently in this version, while fee collection remains available.
An externally submitted transaction is still required; contracts do not wake
themselves. A permissionless price-oracle policy is deferred.

## Administration and release

The native factory and auto-LP control use exact operational generation checks
and existing live AdminWitness authorization for next-generation activation.
No pause or new admin-cap hierarchy is added. A package upgrade is separate from
activation; publication and UpgradeCap custody must follow the existing release
process. The core PackageAdmin is bound to the core original package and cannot
custody these two new UpgradeCaps; release records must explicitly name their
custodians and final disposition. Coordinated upgrades must relink dependent
packages before operational cutovers and verify the entire collection/compound
path after activation. Permanent principal/cap lock claims require immutable deployment;
until then upgrade authority remains a trust assumption. Source fee collection
retains upstream launch version and venue availability constraints.

## Alternatives considered

V3 and DLMM add range/bin mechanics outside the required full-range destination.
Balancing swaps add execution risk and venue coupling; pending assets instead
remain in custody. A raw exponentially smoothed fee sampled once per trade
allows splitting to alter the fee, so charge the progressive integral. A mutable
volume target would reprice existing activity and is deferred. Permissionless
compounding needs an independent price policy and is deferred in favor of
creator-chosen execution authority.

## Consequences

Volume measures local Quote turnover, not organic demand or volatility. Self
trading and an LP's own fee recovery weaken manipulation cost assumptions.
The fee ceiling bounds the marginal rate; ceiling to one Quote atom can put the
actual rate slightly above it. For example, at saturation a principal of 1,001
and cap 200 bps costs 21 atoms, so a signed effective limit of 200 bps rejects.
Callers must quote the rounded fee and explicitly approve its effective rate.
Fees attributable to unrepresented initial shares and fee-index rounding dust
stay in the fee pot with no sweep right.

## Verification

Require direct integer vectors, cap/decay/split properties, both swap directions,
burn supply deltas, per-asset conservation, LP ownership and fee eligibility,
wrong-pool/duplicate-pool rejection, revoked admin and stale-generation guards,
permissionless migration, authorized compounding, and auto-LP custody/leftovers. Build, lint and tests
must pass; venue publication remains subject to its existing live evidence gate.

## Sources

| Ref | Immutable source | Applied fact |
| --- | --- | --- |
| Sui | [coin_registry.move at 06734f6ff0af45d8632a14a4dc4b100197f6b1a2](https://github.com/MystenLabs/sui/blob/06734f6ff0af45d8632a14a4dc4b100197f6b1a2/crates/sui-framework/packages/sui-framework/sources/registries/coin_registry.move) | BurnOnly Currency owns native supply destruction. |
| Sui custody | [dynamic_object_field.move at 06734f6ff0af45d8632a14a4dc4b100197f6b1a2](https://github.com/MystenLabs/sui/blob/06734f6ff0af45d8632a14a4dc4b100197f6b1a2/crates/sui-framework/packages/sui-framework/sources/dynamic_object_field.move) | Typed object children retain discoverable IDs behind parent custody. |

The arithmetic is our derivation, tested against rational and high-precision
reference calculations. Research and the earlier Claude Fable disposition are
in `../research/blast-v2-dynamic-fee-recommendation.md` and
`../research/blast-v2-dynamic-fee-fable-2026-09-05.md`; they do not substitute for
review of deployed bytecode.
