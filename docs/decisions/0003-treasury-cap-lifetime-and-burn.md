# 0003: TreasuryCap lifetime and the two burn moments

- Status: proposed
- Date: 2026-08-22

## Sources

| Ref | Full commit | Repository |
| --- | --- | --- |
| `sui@ae60d06` | `ae60d065ed27576d25ac1c94145e5ffe3ddcf89e` | MystenLabs/sui |
| `cetus@ddfbdeb` | `ddfbdeba174319998b012de876ab7ec23c3ab0bc` | CetusProtocol/cetus-contracts |
| `memez@00596fd` | `00596fdac4dd11f427c7bc594e566ce36160db93` | interest-protocol/memez-gg |

## Context

Two framework requirements pull the `TreasuryCap<Meme>` in opposite directions.

**Registry burn requires giving the cap up permanently.** `coin_registry::burn` aborts unless the supply
state is `BurnOnly` (`sui@ae60d06:crates/sui-framework/packages/sui-framework/sources/registries/coin_registry.move:399-411`,
`ESupplyNotBurnOnly`), and reaching `BurnOnly` **consumes the `TreasuryCap` into a `Supply`**
(`sui@ae60d06:crates/sui-framework/packages/sui-framework/sources/registries/coin_registry.move:308-317`). The framework's own tests confirm burning is rejected in the `Fixed`
and `Unknown` states
(`sui@ae60d06:crates/sui-framework/packages/sui-framework/tests/registries/coin_registry_tests.move:149-197`).

**Cetus pool reservation requires still holding the cap.** `factory::mint_pool_creation_cap<Coin>`
takes `_: &mut TreasuryCap<Coin>`
(`cetus@ddfbdeb:packages/cetus_clmm/sources/factory.move:607-621`). It is the only route to a
`PoolCreationCap`, which is the only route to `register_permission_pair` and therefore the only defence
against a third party pre-creating the graduation pool.

If the cap is surrendered at launch, reservation becomes impossible for the rest of the launch's life.

Separately, the product requirement is a **burn on the curve**. The historical implementation is
evidence, not a template, and is restated precisely below.

## Decision

### The cap lives inside `Launch` for the whole bonding phase

`launch::finish` consumes the `TreasuryCap<Meme>` into the `Launch<Meme, Quote>` object. It is never
returned, never borrowed out to any package after that point, and **no public function in `blast_fun`
reaches `coin::mint`**. That absence is enforced by the public-surface inventory in
[ADR 0001](0001-sui-package-and-module-layout.md) and by a dedicated negative test.

The only window in which any other package holds the cap is command 2 of the launch transaction, which
is bounded by the mandatory conservation post-condition described in
[ADR 0002](0002-coin-creation-and-currency-authority.md).

### Burn moment 1 — sell-side, progress-dependent, during bonding

On every **sell**, a progress-dependent fraction of the inbound meme is burned via
`coin::burn(&mut TreasuryCap<Meme>, …)` before the constant-product quote-out is computed. Burned units
never enter curve inventory, so the invariant product rises and remaining holders benefit.

```text
progress_bps = min(real_quote * 10_000 / target_quote, 10_000)      // floor
burn_bps     = MAX_BURN_BPS * progress_bps / 10_000                  // floor
burn_amount  = ceil(meme_in * burn_bps / 10_000)                     // ceil
```

Proposed `MAX_BURN_BPS = 100` (1 %). **The constant is proposed, not accepted.**

Rounding beneficiaries, stated per division: both ramp terms round **down**, so the ramp never overstates
progress; the final burn amount rounds **up**, because a burn is a seller obligation and
`../engineering-principles.md` sets obligations to round up. A sell whose post-burn effective amount is
zero is rejected with a named error rather than silently accepted.

**The historical behaviour, stated precisely.** `memez_burner::calculate(self, liquidity)`
(`memez@00596fd:fun/sources/structs/burner.move:32-44`) returns `0` when `fee == 0` or `liquidity == 0`;
returns the full `fee` when `liquidity >= target_liquidity`; otherwise computes
`progress_percentage = mul_div_up(liquidity, MAX_BPS, target_liquidity)` and then
`mul_div_up(fee, progress_percentage, MAX_BPS)` — a linear ramp in quote progress, rounded **up twice**.
It is applied on the sell path only: the burn tax is taken after the meme swap fee and before the
quote-out computation (`memez@00596fd:fun/sources/structs/constant_product.move:149-152`), and the burn
executes through `IPXTreasuryStandard`, a third-party coin standard rather than the Sui Coin Registry
(`memez@00596fd:fun/sources/structs/constant_product.move:8, 127, 152`).

**The adaptation, and why.** Blast keeps the shape — a linear ramp in quote progress applied on sells —
and changes three things. The double round-up is replaced by floor-floor on the ramp and a single
round-up on the amount, so the rounding error does not compound. The burn executes through the retained
`TreasuryCap` rather than a third-party standard, removing an external dependency from the hot path.
Behaviour at `liquidity == 0`, at `liquidity == target`, and at one atomic unit is specified and
vectored rather than left implicit.

### Burn moment 2 — terminal disposition of non-migrated inventory

At migration, after the venue position is seeded and residual coins are returned, any remaining meme
inventory that was **not** deployed to the venue is burned in a single accounted step. Only then is the
`TreasuryCap` consumed into `coin_registry::make_supply_burn_only`
(`sui@ae60d06:crates/sui-framework/packages/sui-framework/sources/registries/coin_registry.move:308-317`).

`BurnOnly` is chosen over `Fixed` because it keeps community burns possible forever through
`coin_registry::burn`, which after that point requires `&mut Currency<Meme>` as a shared input
(premise **P2**). `Fixed` would foreclose that with no compensating benefit.

Ordering is mandatory and tested: seed the position, return residuals, burn the remainder, then lock the
supply state. Locking first would make the terminal burn impossible, because `coin::burn` needs the cap
that `make_supply_burn_only` consumes.

### Supply state over the lifecycle

| Phase | Registry supply state | `total_supply()` | Mint reachable |
| --- | --- | --- | --- |
| after tx1 | `Unknown` | `none` | no public path |
| bonding | `Unknown` | `none` | no public path |
| after migration | `BurnOnly` | `some(final)` | never |

`total_supply` returns `none` while the state is `Unknown`
(`sui@ae60d06:crates/sui-framework/packages/sui-framework/sources/registries/coin_registry.move:630-638`). **During bonding, wallets and explorers show no
supply for a live launch.** That is a real, visible cost of this decision and is stated plainly rather
than discovered later.

### Conservation

Conservation is **two identities in two different units**, never one mixed equation. Meme and quote are
different assets; adding them would be meaningless.

**Meme atomic units:**

```text
meme_total_supply_initial
  = M                          (curve inventory)
  + meme_outstanding           (held outside the curve)
  + meme_named_claims          (contribution claims, ADR 0006)
  + burned_sell_side
  + burned_terminal
  + meme_deployed_to_venue     (after migration only)
```

**Quote atomic units:**

```text
quote_in_total
  = quote_out_total
  + Q                          (curve reserve)
  + accrued_fees_quote
  + quote_named_claims
  + migration_fee_quote
  + quote_deployed_to_venue    (after migration only)
```

Burn appears **only** in the meme identity, because burning destroys meme and touches no quote. Neither
burn is silent shrinkage: each has its own event carrying the burned amount and the resulting total
supply ([ADR 0011](0011-event-schema-and-replay.md)).

### The top of the ramp is never reached on a live sell

`burn_bps` reaches `MAX_BURN_BPS` only when `progress_bps == 10_000`, which requires `real_quote >= T`.
But crossing `T` closes trading ([ADR 0004](0004-bonding-curve.md)), so no sell can execute in that
state. **The maximum burn attainable on a live sell is one basis point below the configured maximum** —
99 bps at the proposed `MAX_BURN_BPS = 100`.

`MAX_BURN_BPS` is therefore an asymptote, not an attained value. This is stated because a reader
calibrating the constant against expected burn would otherwise be off by the last step, and because the
vectors label the `progress_bps == 10_000` case as pure-math rather than reachable.

## Alternatives considered

**Go `BurnOnly` at launch.** Better explorer semantics and no mint authority in principle, at the cost of
forfeiting Cetus reservation entirely and adding a shared `Currency<Meme>` input to every burning sell.
Rejected because a front-run graduation pool is an economic loss to real users while a blank supply field
during bonding is cosmetic and temporary. This is the decision to revisit if premise **P5** shows Blast's
intended quote assets are not eligible for Cetus permission pairs anyway, since the reservation would
then buy nothing.

**Go `Fixed` at migration instead of `BurnOnly`.** Rejected: it permanently removes the ability to burn.

**Burn on buys as well as sells.** Rejected: it taxes the direction that grows the reserve, and it has no
progress interpretation.

**Copy the historical double round-up.** Rejected: compounding two round-ups is a value transfer with no
stated beneficiary, which `../engineering-principles.md` forbids.

## Consequences

- Cetus reservation is available, which closes the graduation front-running window for eligible pairs.
- Mint authority exists inside `Launch` and must be proved unreachable by test, permanently.
- Explorers show no supply during bonding.
- The terminal ordering (seed, return, burn, lock) is a hard sequence with a single correct order.
- After migration the coin is `BurnOnly` forever, so third parties can burn it and total supply only
  decreases.

## Verification

- Vectors for both burn moments in [`../vectors/curve.json`](../vectors/curve.json), including zero
  progress, mid progress, full progress, and one atomic unit.
- Conservation test after every operation and every sequence of operations.
- Negative test: no public path reaches `coin::mint` for the launch coin type.
- Negative test: attempting `make_supply_burn_only` before the terminal burn makes the terminal burn
  impossible — asserted as an ordering test, not left to review.
- State test: registry supply state and `total_supply()` at each lifecycle edge match the table above.
- Boundary test: `progress_bps` at `real_quote = 0`, `target - 1`, `target`, and `target + 1`.
- Premise **P2** — whether `&mut Currency<Meme>` is obtainable only as a shared input. Test: compile a
  stub taking `&mut Currency<T>` and exercise a post-migration community burn on localnet.
- Premise **P5** — whether the intended quote assets are eligible for Cetus permission pairs. Test:
  mainnet read of the `PermissionPairManager` allowed-pair configuration.
