# Testing standard

Tests are organized around risk, not only function names.

## Required layers

| Layer | Required evidence |
| --- | --- |
| Pure math | tables, boundary cases, monotonicity, inverse/dust bounds, randomized/property tests |
| State transitions | every legal lifecycle edge and rejection of every illegal source state |
| Authorization | each role's allowed and forbidden actions, rotation/revocation, pause/version precedence |
| Accounting | reserve/fee/allocation/vesting conservation after every operation and sequence |
| Adversarial | X-claim replay, expired backend attestation, wrong claim domain or sender, slippage, reentrancy/callback, duplicate migration, hostile token/coin assumptions |
| Events | field-level assertions plus full reducer replay against final state |
| Upgrade | old-version rejection, state migration, ABI/storage compatibility, initializer and authority checks |
| Deployment | simulation/dry run, execution status, finality, normalized artifact schema, post-deploy smoke assertions |
| Cross-chain | shared vectors for quotes, fees, thresholds, vesting, X-claim attestations, lifecycle, and intentional difference records |

## Test rules

- Assert exact named errors/abort codes for negative cases, pinning
  `location` to the raising module. A bare expected failure
  is prohibited because an unrelated abort can make it pass.
- Assert guard precedence when more than one condition is invalid.
- Prefer `assert_eq!` for values and plain boolean assertions without arbitrary
  test abort codes.
- Import frequently used `std::unit_test::{assert_eq, destroy}` members in test
  modules so assertions and teardown remain visually direct.
- Keep test builders deterministic and explicit about sender, clock/time,
  balances, state, and authority.
- Stateful Sui suites use small, purpose-specific hot-potato fixtures: one
  ability-free fixture type per setup family, named for what it provides
  (`ClaimFixture`, `UpgradeFixture`, …), storing the scenario plus only the
  objects that family actually uses. A uniquely named `start` variant per
  fixture owns all scenario choreography and shared or sender-owned object
  take/return. Receiver-style `next_tx!` macros — `use fun`-aliased onto each
  fixture type when a module defines several — advance the sender and pass the
  single named fixture handle to the closure, never a positional reference
  list or underscore placeholders. A fixture `ctx!` macro is the only
  transaction-context access a body may use. `Option<T>` fields exist only for
  consuming or replacement flows behind narrowly named
  `take_*`/`replace_*`/`retake_*` helpers. Test bodies orchestrate only
  starts, transaction macros, fixture helpers and field reads, assertions, and
  one consuming `end`; they never touch `test_scenario`, the scenario field,
  or fixture `Option` internals directly, and pure math or error-registry
  tests stay fixture-free.
- Random tests use fixed seeds in CI and print enough input to reproduce failure.
- Fuzz domains must include zero, one, maximum supported values, just below/at/
  above thresholds, and values that stress intermediate multiplication.
- Tests must not call production-only cleanup or add public API solely to destroy
  fixtures.
- If a coverage tool cannot represent a branch accurately, enumerate the branch
  in named tests and document the tool limitation. Do not invent a false coverage
  gate.

## Sui gate

From `sui/`:

```bash
sui move build
sui move lint --warnings-are-errors
sui move test --lint
```

Add gas/trace/coverage jobs only when the pinned Sui CLI supports stable output.
Generated traces and coverage maps are not committed.

## EVM gate

From `evm/`:

```bash
forge fmt --check
forge build
forge test
forge test --gas-report
```

Production releases also require fuzz/invariant profiles with committed run
counts/seeds, storage-layout checks if upgradeable, and integration tests against
the exact external interfaces used by approved adapters.

## Differential vectors

Shared vectors should be chain-neutral data with explicit units and expected
results. Both implementations consume the same cases. At minimum include:

- quote input/output and post-trade reserves;
- fee split and rounding remainder;
- threshold crossing and final migration amounts;
- vesting claim at every time boundary;
- X-claim attestation domain, sender-binding, expiry, and replay cases.

A difference caused by chain representation must be documented; an unexplained
numeric difference is a release blocker.

The committed vector files live in [vectors/](vectors/):

| File | Covers |
| --- | --- |
| [vectors/curve.json](vectors/curve.json) | buys, sells, threshold crossing, both burn moments, one-atomic-unit boundaries, round-trip dust, and the sell-back property |
| [vectors/fees.json](vectors/fees.json) | configurable protocol/creator shares, rounding, update sequences, and maximum-width boundaries |
| [vectors/quote-decimals.json](vectors/quote-decimals.json) | decimal combinations, both pair orientations, exact `sqrt_price_x64`, venue range bounds |
| [vectors/x-creator-claim.json](vectors/x-creator-claim.json) | canonical X claim BCS bytes, original meme-type domain, and Ed25519 fixture |

Vector files are generated from the formulas in their owning decision record with
exact integer arithmetic. They are regenerated, never hand-edited, when a proposed
constant changes.

## Operation-to-rule checklist

Every public operation must be shown to satisfy all six standing invariants. The
per-operation table lives in
[decisions/0011-event-schema-and-replay.md](decisions/0011-event-schema-and-replay.md);
this is the rule set it is checked against.

| Rule | What the test must show |
| --- | --- |
| validation before mutation | the guard order is observable through abort precedence, and each simultaneously-invalid pair asserts which guard fires first |
| replay-complete events | a reducer over the event stream alone reproduces final state field-by-field |
| immutable dependencies | the built package resolves no mutable revision; adapters carry a recorded exemption |
| bounded state | no persistent collection and no loop input can grow without a fixed constant bounding it |
| composability | the function returns owned values rather than self-transferring |
| exact failures | every negative case asserts a named error, never a bare expected failure |

## Additional required suites

- **Replay reducer.** One reducer, exercised over a sequence covering launch, many
  trades, both burn moments, threshold crossing, a failed migration with retry, a
  successful migration, and a full settlement epoch.
- **Display resolution.** For each displayed type, every required field resolves to
  a non-empty string.
- **No post-initializer mint.** Structural and lifecycle tests prove the OTW-only
  `launch_ticket::new` constructor is the sole mint site and consumes supply
  authority before returning, so no later public path can mint the coin type.
- **Pair immutability.** No transition, route, retry, or recovery path changes the
  selected `(Meme, Quote)` pair.
- **Premise conversion.** Each open premise in
  [decisions/README.md](decisions/README.md) has a compile or localnet test that
  converts it into evidence. An ADR cannot be accepted while a premise it depends on
  is unconverted.

## Implementation and release checklist

This is the single agent-operable list. Work through it in order; each row links to
the decision that owns it. Nothing here may be marked done from prose alone.

### Gate 0 — premises, before any ABI is written

| # | Test | Owner |
| --- | --- | --- |
| 0.1 | P10 cross-package hot-potato threading compile fixture | [0002](decisions/0002-coin-creation-and-currency-authority.md) |
| 0.2 | Retired: initializer-finalized supply removes `TreasuryCap` command threading | [0035](decisions/0035-initializer-finalized-meme-supply.md) |
| 0.3 | P13 `init` accepting a shared object | [0002](decisions/0002-coin-creation-and-currency-authority.md) |
| 0.4 | P14 command result as a Move reference | [0002](decisions/0002-coin-creation-and-currency-authority.md) |
| 0.5 | P1 type argument naming a package published in the same transaction | [0002](decisions/0002-coin-creation-and-currency-authority.md) |
| 0.6 | P2 `&mut Currency<T>` shared-input only | [0003](decisions/0003-treasury-cap-lifetime-and-burn.md) |
| 0.7 | P3 Cetus canonical ordering direction | [0010](decisions/0010-migration-and-venue-adapters.md) |
| 0.8 | P8 Display freeze semantics, P12 generic instantiation | [0001](decisions/0001-sui-package-and-module-layout.md) |
| 0.9 | P4, P5, P7, P9 live venue reads | [0006](decisions/0006-fees-and-launch-paths.md), [0010](decisions/0010-migration-and-venue-adapters.md) |

### Gate 1 — core invariants

| # | Test | Owner |
| --- | --- | --- |
| 1.1 | The OTW ticket constructor is the sole mint site and no treasury cap survives it | [0035](decisions/0035-initializer-finalized-meme-supply.md) |
| 1.2 | Pair immutability across every transition, route, retry and recovery | [0005](decisions/0005-quote-asset-generalisation.md) |
| 1.3 | Both conservation identities, meme units and quote units, after every operation | [0003](decisions/0003-treasury-cap-lifetime-and-burn.md) |
| 1.4 | Curve vectors and both burn moments | [0004](decisions/0004-bonding-curve.md), [vectors/curve.json](vectors/curve.json) |
| 1.5 | Sell-back invariant, seeded property test with a committed generator | [0004](decisions/0004-bonding-curve.md) |
| 1.6 | Decimal and orientation vectors, exact rationals only | [0005](decisions/0005-quote-asset-generalisation.md), [vectors/quote-decimals.json](vectors/quote-decimals.json) |
| 1.7 | Initializer supply suite: canonical nine-decimal billion, both modes, and no surviving treasury cap | [0035](decisions/0035-initializer-finalized-meme-supply.md), [0036](decisions/0036-fixed-nine-decimal-generated-memes.md) |

### Gate 2 — authority, identity, settlement

| # | Test | Owner |
| --- | --- | --- |
| 2.1 | Authority matrix and negative transition matrix as test tables | [0007](decisions/0007-acl-pause-and-versioning.md) |
| 2.2 | Guard precedence, including witness-membership as input validation | [0007](decisions/0007-acl-pause-and-versioning.md), [0002](decisions/0002-coin-creation-and-currency-authority.md) |
| 2.3 | Fee-split and LP-fee authority, bounds and events | [0007](decisions/0007-acl-pause-and-versioning.md), [0012](decisions/0012-flywheel-features.md) |
| 2.4 | Address/SuiNS and X one-time creator-cap claims, coin-type isolation, threat table, backend integration P15, and attestation vectors | [0013](decisions/0013-creator-fee-authority-and-x-claims.md), [0016](decisions/0016-unified-creator-cap-claim-and-suins-periphery.md), [0017](decisions/0017-coin-type-domain-for-x-creator-claims.md) |
| 2.5 | RevShare bounds, claimable cap, challenge, sweep, double-claim | [0009](decisions/0009-referrals-and-revshare.md) |

### Gate 3 — migration and release

| # | Test | Owner |
| --- | --- | --- |
| 3.1 | Route A/B/C decision table and acceptance-band boundaries | [0010](decisions/0010-migration-and-venue-adapters.md) |
| 3.2 | Reservation cleanup before any venue switch | [0010](decisions/0010-migration-and-venue-adapters.md) |
| 3.3 | Terminal ordering preserves already-final supply while routing liquidity, residuals, and deferred burn | [0026](decisions/0026-deferred-sell-burn.md), [0035](decisions/0035-initializer-finalized-meme-supply.md) |
| 3.4 | Event reducer replay in native Sui order across all entity scopes | [0011](decisions/0011-event-schema-and-replay.md) |
| 3.5 | Per-venue dependency exemption resolved or the adapter excluded | [0010](decisions/0010-migration-and-venue-adapters.md) |
