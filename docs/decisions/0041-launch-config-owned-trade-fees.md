# 0041: LaunchConfig-owned trade fees

> Storage-type update (2026-08-28): [ADR 0044](0044-validated-basis-points-unit.md)
> wraps both stored rates in `Bps`; the setter inputs, launch snapshot values,
> and event fields remain raw `u64` values.
> Setter-input update (2026-09-15): [ADR 0081](0081-separate-lp-fee-share-policy.md)
> makes both setters take `Bps`; snapshot values and event fields stay as before.

- Status: accepted
- Date: 2026-08-28
- Amends: [0001](0001-sui-package-and-module-layout.md),
  [0004](0004-bonding-curve.md),
  [0006](0006-fees-and-launch-paths.md),
  [0007](0007-acl-pause-and-versioning.md),
  [0011](0011-event-schema-and-replay.md),
  [0012](0012-flywheel-features.md),
  [0021](0021-pure-constant-product-curve-quotes.md),
  [0022](0022-dual-asset-fee-ledger-and-claims.md),
  [0028](0028-hot-cold-runtime-configuration.md), and
  [0040](0040-normalized-launch-state-intake.md)

## Sources

| Ref | Full commit | Repository |
| --- | --- | --- |
| — | No external ABI fact introduced | — |

## Context

ADR 0022 let each launcher select independent Quote and Meme trade-fee rates.
ADR 0040 therefore accepted both values as public `launch::new` parameters.
Blast instead requires protocol administrators to set these rates. A launcher
must not be able to create a zero-fee or unusually priced launch while using the
same protocol configuration and migration policy as other launches.

The rates are cold policy: changing them must affect only launches created
afterward. They are not the live protocol/creator split in `RuntimeConfig`,
which still applies to each later accrual.

## Decision

`LaunchConfig` gains two zero-initialized fields:

```move
quote_fee_bps: u64,
meme_fee_bps: u64,
```

One `AdminWitness`-gated `set_trade_fees` operation updates the pair. Each value
is independently bounded from zero through 1,000 basis points. Guard order is:

1. invalid Quote fee, using `invalid_quote_fee_bps`;
2. invalid Meme fee, using `invalid_meme_fee_bps`; and
3. unchanged pair, using new error `trade_fee_defaults_unchanged`.

`LaunchTradeFeesChanged` records both old values and both new values. The
creation event records the initial zero pair. No independent setters exist
because Quote and Meme fee policy is reviewed and replayed as one launch-time
pair.

`snapshot_for_launch` returns the two trade-fee rates with the Quote parameters,
graduation rates, and selected migration witness. `launch::new` removes both
fee parameters, performs no duplicate fee validation, and stores the values
from that one consistent snapshot. Later configuration updates never change an
existing launch.

The embedded `FeeLedger` remains empty at launch. Each future trade calculates
fees from the launch's immutable rates, then splits the resulting balances using
the current `RuntimeConfig.protocol_fee_share_bps`. Thus cold fee magnitude and
live beneficiary allocation remain separate concerns.

## Alternatives considered

**Keep launcher-selected rates within an administrative ceiling.** Rejected:
the ceiling prevents excess but still lets launchers opt out of Blast's fee
policy.

**Read trade fees live from LaunchConfig on every trade.** Rejected: an update
would rewrite the economics accepted by existing launches and add a second
shared input to the hot path.

**Move the rates into RuntimeConfig.** Rejected: that object contains settings
that intentionally apply to the next operation of every existing launch. Trade
fee magnitude is fixed when each launch is created.

**Use separate Quote and Meme setters.** Rejected: independent mutations create
transient mixed policy and double the privileged surface.

## Consequences

- Launchers choose neither trade-fee rate.
- Administrators set one bounded pair for future launches.
- Existing launches remain economically immutable.
- `launch::new` has two fewer public parameters and no fee-policy authority.
- The live protocol/creator split remains independent and is not snapshotted.

## Verification

- Setter tests cover zero and 1,000 boundaries, both ceiling failures, unchanged
  pairs, guard order, and complete old/new events.
- Snapshot tests prove both rates are returned atomically and remain unchanged
  in an existing launch after later administration.
- Launch construction tests take no fee parameters and assert the configured
  pair in state and `LaunchCreated`.
- Full build, warning-as-error lint, Move tests, coverage, and structural checks
  remain required.
