# 0039: Deterministic Quote-denominated launch valuations

- Status: accepted
- Date: 2026-08-25
- Amends: [0001](0001-sui-package-and-module-layout.md),
  [0011](0011-event-schema-and-replay.md),
  [0025](0025-quote-whitelist-and-migration-targets.md),
  [0027](0027-graduation-economics-and-migration-witnesses.md),
  [0030](0030-singleton-event-identity.md),
  [0033](0033-meme-liquidity-provision.md)

## Sources

| Ref | Full commit | Repository |
| --- | --- | --- |
| — | No external ABI fact introduced | — |

The parameters, formulas, storage, and rounding rules in this record are
Blast-owned protocol decisions.

## Context

A launch needs deterministic valuations in its selected Quote asset. For SUI
launches these values are denominated in SUI atomic units, never USD and never
an oracle conversion. The existing quote policy stores the real-Quote migration
target but does not store the virtual Quote reserve that establishes the opening
price. Without both values in the immutable launch snapshot, the opening and
terminal valuations cannot be reconstructed from launch state.

The forecast amount of Meme released by the curve is not a fourth
administrator-selected quantity. It follows from the initial Meme partition,
virtual Quote reserve, and real-Quote target. Likewise, the DEX opening valuation
follows from the reserved Meme provision and net Quote after the migration fee.
Storing selectable sale, burn, or DEX-valuation fields would permit mutually
inconsistent configurations.

## Decision

### One Quote policy pair

Each admitted Quote maps to one `QuoteParameters` value:

```move
public struct QuoteParameters has copy, drop, store {
    virtual_quote: u64,
    migration_quote_target: u64,
}
```

Both fields are nonzero Quote atomic units. `allow_quote` admits or atomically
updates the pair for future launches. `snapshot_for_launch` returns both values
together with the existing graduation rates and selected migration witness.
Every launch stores the returned pair immutably; later administration cannot
reprice a live curve.

Quote admission, update, and removal events expose the complete relevant pair
for event-only replay. The pre-release `QuoteMigrationTargetChanged` event is
replaced by `QuoteParametersChanged`, because either member may change.

### Contract and SDK seam

The contract commits the primitive facts required for execution and independent
reconstruction: initial supply partitions, virtual and real Quote reserves,
terminal target, fee rates, actual balances, lifecycle, and completed events.
It does not add a public or package-only function merely to project a valuation,
expected release, or other convenience result.

The SDK reads those canonical facts and derives previews. A state-changing
contract operation independently recomputes any curve result needed to enforce
slippage, thresholds, fees, or conservation. It never accepts an SDK forecast as
authority. If an executed balance differs from a preview because of atomic
rounding or transaction history, the executed balance and event win.

### Derived curve endpoint

Let all asset amounts below be atomic units:

```text
S = initial Meme supply
A = ceil(S * meme_graduation_allocation_bps / 10_000)
L = floor(S * meme_liquidity_provision_bps / 10_000)
C = S - A - L
V = virtual Quote reserve
T = real-Quote migration target
F = quote migration fee in basis points
```

At the exact target, the SDK's canonical constant-product preview is:

```text
R = ceil(C * V / (V + T))
B = C - R
```

`R` is terminal Meme inventory retained by the curve for the terminal burn or
other explicitly approved migration disposition. `B` is gross Meme released
from the curve. Consequently, a desired release such as 40% of total supply is
achieved by selecting a valid existing parameter set whose derived `B` equals
that amount; no `curve_sale_bps` or sale-cap field exists on chain.

The future stateful launch module must cap the final buy at exactly `T` net real
Quote. Any unused gross Quote is returned by that stateful interface; it is not
migration principal. The executed terminal Meme balance remains authoritative;
the SDK does not instruct the contract to rewrite it to `R`.

### Derived Quote valuations

The migration fee and net pool Quote are:

```text
M = ceil(T * F / 10_000)
N = T - M
```

The deterministic implied total-supply valuations are:

```text
opening_valuation        = floor(S * V       / C)
curve_terminal_valuation = floor(S * (V + T) / R)
dex_opening_valuation    = floor(S * N       / L)
```

Each result is in Quote atomic units. A SUI UI divides by SUI's decimal scale
only for display. It does not fetch a SUI/USD rate. Valuations round down so
displayed protocol facts never overstate the exact rational value. Products and
the `V + T` sum use arbitrary-precision SDK integers; valuation outputs remain
`bigint` because implied total-supply value may exceed the `u64` balance range.

An off-chain SDK function returns the endpoint quantities, fee, net Quote, and
valuations from these existing inputs. The Move package does not store, return,
or validate these forecast values. Its graduation seam remains limited to the
real Meme and Quote balance partitions required for launch and migration.

### Worked SUI example

For nine-decimal Meme and SUI units:

```text
S = 1_000_000_000 Meme
C =   800_000_000 Meme
L =   200_000_000 Meme
V = 1_000 SUI
T = 3_000 SUI
F = 100 bps
```

the derived results are:

```text
R = 200_000_000 Meme
B = 600_000_000 Meme (60% of S)
M = 30 SUI
N = 2_970 SUI
opening valuation = 1_250 SUI
terminal curve valuation = 20_000 SUI
DEX opening valuation = 14_850 SUI
```

This illustrates why the three valuations cannot be independently selected.
Changing the DEX valuation means changing an existing input such as `L`, `T`,
or `F`, which also changes another named economic result.

With the same `S`, `C`, and `L`, setting `V = T = 800 SUI` and `F = 0` derives
an opening valuation of 1,000 SUI, `R = 400_000_000 Meme`, and
`B = 400_000_000 Meme`: exactly 40% of total supply is released by the curve.
The corresponding terminal and DEX valuations are both 4,000 SUI. Therefore
this parameter set cannot simultaneously promise a 10,000 SUI terminal
valuation; changing that outcome necessarily changes the derived release or
another existing input.

## Alternatives considered

**Store opening, migration, and DEX valuations directly.** Rejected: they would
duplicate arithmetic facts and could disagree with reserves actually held.

**Store a 40% curve-sale cap.** Rejected: curve release is already derived from
`C`, `V`, and `T`; a cap creates a second terminal rule that can conflict with
the Quote target.

**Use a USD oracle.** Rejected: launch economics are native to the selected
Quote asset. Oracle freshness, manipulation, and fallback behavior are outside
this product model.

**Derive virtual Quote from the target.** Rejected: one target does not determine
both opening price and curve steepness. `V` is the independent curve-shape input
that must be snapshotted alongside `T`.

**Permit terminal overshoot.** Rejected for the future stateful launch interface:
overshoot makes the actual Meme release and implied terminal valuation depend on
the final trade size instead of immutable launch parameters.

**Calculate or store forecast valuations in Move.** Rejected: these outputs do
not authorize a transition or allocate an asset. Repeating the calculations on
chain expands the trusted contract surface without improving conservation.

## Consequences

- Quote-policy storage, `allow_quote`, `snapshot_for_launch`, and three quote
  event payloads change before public release.
- Existing error meanings remain stable; new codes cover zero virtual Quote and
  a completely unchanged Quote parameter pair.
- There is no independent curve-sale, burn, or valuation parameter.
- A future stateful launch implementation must enforce exact net-Quote closure
  and allocate actual Meme and Quote balances without consulting an SDK result.
- The SDK preview may differ from an executed curve by atomic rounding dust;
  emitted balances, not the preview, are authoritative.
- Indexers can reconstruct every input and recompute every derived result using
  integer arithmetic only.

## Verification

- Quote-policy tests cover zero `V`, zero `T`, pair updates, unchanged pairs,
  removal, capacity, events, and the six-value immutable snapshot.
- SDK tests include the worked SUI example and the 1,000-SUI/40%-release example
  with literal expected endpoint, fee, net Quote, and valuation values.
- Move graduation tests cover balance conservation, exact division, rounding,
  one-unit reserves, zero fee, and maximum-width inputs without overflow.
- Structural checks pin the Quote policy pair, snapshot arity, event fields, and
  balance-partition seam while rejecting on-chain forecast valuation logic or
  independent sale-cap/valuation storage.
- Future launch integration tests must prove exact target capping, refund
  conservation, and complete allocation of actual terminal balances.
