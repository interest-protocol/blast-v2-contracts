# 0025: Quote whitelist and migration targets

- Status: accepted
- Date: 2026-08-24
- Amends: [0005](0005-quote-asset-generalisation.md), [0023](0023-generated-coin-supply-and-metadata-custody.md)

> Amended by [ADR 0027](0027-graduation-economics-and-migration-witnesses.md): the
> uncommitted `QuoteConfig` surface became `LaunchConfig`, and the package-only
> snapshot now returns the unchanged quote target together with bounded cold
> graduation and migration-witness policy.

## Sources

| Ref | Full commit | Repository |
| --- | --- | --- |
| — | No external ABI fact introduced | — |

Quote admission and target snapshotting are Blast-owned policy and storage
decisions.

## Context

The quote asset becomes a launch's real reserve and the asset paired with the
generated meme at migration. Permissionless admission would let a launch use an
economically worthless or operationally unsupported quote. A single
global migration amount is also invalid because quote assets have different
atomic units and market values.

Administrative changes must not move the terminal condition of an already-live
launch. Lowering a live threshold could force an unexpected migration, while
raising it could strand traders behind a goal they did not accept.

## Decision

### Bounded quote whitelist

`launch_config.move` owns one shared `LaunchConfig` containing at most 16
allowed quote policies. Each policy is keyed by the quote's original `TypeName`
and contains its nonzero `migration_quote_target` in quote atomic units.

An active `AdminWitness` may allow a quote with a target, use that same operation
to update the target of an already-allowed quote, or disallow a quote from
admission for future launches.

The module rejects missing disallows, zero and unchanged targets, and inserts
beyond the active bound. Every successful mutation emits the full old/new fact
needed for event-only replay. Events rely on native Sui event order and add no
application sequence.

### Launch-time snapshot

The package-only `snapshot_for_launch<Quote>` interface is the only production
read seam. It rejects a quote absent from the whitelist and returns the current
target. It does not require `Currency<Quote>` or another quote-registry object:
the administrator's explicit whitelist decision is the admission proof, and a
registry object would otherwise add an unrelated shared input to every launch.

The whitelist is curated by Blast administrators. It does not attempt to infer
liquidity, peg quality, regulatory behavior, or venue support from incomplete
onchain metadata. If those properties matter for a quote, they are part of the
administrator's admission review rather than a second launch-time mechanism.
Accordingly, administrators may deliberately whitelist a regulated quote asset;
the generated meme currency remains separately required to be unregulated by
ADR 0023.

`Launch<Meme, Quote>` stores the returned target as immutable launch state.
Later whitelist changes affect only launches constructed afterward. Disallowing a
quote prevents new launches without changing the pair, trading rules, exits, or
migration target of an existing launch.

The target is the minimum real quote reserve at which bonding closes. Trade
fees are already excluded from that reserve. A terminal buy may overshoot the
target; migration accounts for and deploys the complete resulting reserve after
any separately approved migration fee.

### Frontend quotes

The pure `curve` module remains package-only. The future public
`launch::quote_buy` and `launch::quote_sell` functions read the actual launch
state and fixed launch parameters, move no assets, and perform no mutation.
This gives frontends authoritative quotes without letting callers substitute
inconsistent reserve or fee inputs.

## Alternatives considered

**Permissionless quote assets.** Rejected: arbitrary quote risk becomes shared
reserve and migration risk for every buyer.

**One global target.** Rejected: the same atomic amount has different meaning
across quote types and decimal scales.

**A target configured per meme coin.** Rejected: it creates unbounded bespoke
administration and lets operators reprice individual launches. A future product
may instead offer a bounded set of approved tiers per quote.

**Apply target changes to live launches.** Rejected: it changes the terminal
condition after users have traded against it.

**Expose raw curve functions publicly.** Rejected: raw caller-selected reserves
and fee parameters are not an authoritative quote for a live launch.

## Consequences

- Quote admission becomes an explicit privileged risk decision.
- Migration targets are comparable only within their quote asset and are
  immutable once snapshotted into a launch.
- Disallowing a quote is safe for existing launches because it affects admission
  only.
- The active whitelist has a fixed storage and iteration bound.

## Verification

- Initialization emits the empty whitelist and active bound.
- Insert, update, and disallow tests assert exact state and replay-complete event
  fields.
- Missing, zero, unchanged, and capacity cases assert exact package errors and
  guard precedence.
- A target update changes the next snapshot while a future launch test proves a
  previously stored target remains unchanged.
- Structural checks keep the configuration concern separate from ACL, launch
  balances, curve math, and venue-specific dependencies.
