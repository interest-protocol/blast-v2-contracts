# Memez.Fun migration Meme partition and Blast gap

Status: supporting research
Reviewed: 2026-08-25

## Source pins

This note reviews three first-party sources:

- `interest-protocol/memez-gg@00596fdac4dd11f427c7bc594e566ce36160db93`.
  That commit is both Blast's pinned historical reference and the repository's
  current `main`/`HEAD` when rechecked on 2026-08-25.
- `interest-protocol/memez.gg-sdk@e38e4c747e700e94669566e5e577e67a3ed5eed9`,
  the current SDK `main`/`HEAD` when rechecked on 2026-08-25.
- `interest-protocol/interest-mvr@6e800792a6bb640b23b05012c3ea88cb639db78f`,
  the commit behind the `deploy/bps` tag used by Memez.Fun.

The Blast comparison is against
`interest-protocol/blast-v2-contracts@ad951f8c8d500a06db39f96e6098d748a169cc0d`.

## Conclusion

The suspected omission is real. Blast currently has a
`meme_graduation_allocation_bps`, but that value is protocol-owned Meme revenue;
ADR 0027 expressly excludes it from migration inventory. It is **not** the
amount of Meme used to seed the destination pool. No separate launch-policy
field or accepted formula currently determines that amount.

Memez.Fun keeps these concerns independent:

1. `liquidity_provision` determines the Meme balance reserved at launch and
   later handed to the migrator;
2. `allocation` reserves a different Meme balance for configured stakeholders,
   distributed only after migration;
3. `migration` deducts a Quote-denominated fee before the remaining Quote is
   handed to the migrator; and
4. the external XPump migrator has its own reward, residual treasury, and LP-fee
   treasury policy.

Blast should therefore not reinterpret its existing protocol allocation as pool
liquidity. The next protocol decision needs a separately named migration-Meme
policy, such as `meme_liquidity_provision_bps`, or an explicit terminal formula
that derives the amount needed for price continuity.

## Memez.Fun's exact Pump partition

### One launch-specific liquidity-provision rate

`PumpConfig` contains five values: burn tax, virtual Quote liquidity, terminal
Quote target, `liquidity_provision: BPS`, and total Meme supply
([`memez@00596fd:fun/sources/config/pump.move:16-35`](https://github.com/interest-protocol/memez-gg/blob/00596fdac4dd11f427c7bc594e566ce36160db93/fun/sources/config/pump.move#L16-L35)).
Its getter calculates:

```text
reserved_migration_meme
  = floor(total_meme_supply * liquidity_provision_bps / 10_000)
```

The getter calls `BPS.calc(total_supply)`
([`memez@00596fd:fun/sources/config/pump.move:48-57`](https://github.com/interest-protocol/memez-gg/blob/00596fdac4dd11f427c7bc594e566ce36160db93/fun/sources/config/pump.move#L48-L57)),
and the pinned BPS implementation documents and implements `calc` as rounding
down with widened `u128` multiplication
([`interest-mvr@6e80079:bps/sources/bps.move:48-53`](https://github.com/interest-protocol/interest-mvr/blob/6e800792a6bb640b23b05012c3ea88cb639db78f/bps/sources/bps.move#L48-L53)).

At Pump creation, Memez.Fun applies the configured stakeholder allocation first,
then splits the computed liquidity provision into its own balance, and gives
only the remainder to the constant-product curve
([`memez@00596fd:fun/sources/pump.move:84-111`](https://github.com/interest-protocol/memez-gg/blob/00596fdac4dd11f427c7bc594e566ce36160db93/fun/sources/pump.move#L84-L111)).
Thus, ignoring any initial developer purchase and later fees:

```text
initial_supply
  = stakeholder_allocation
  + reserved_migration_meme
  + initial_curve_inventory
```

The rate is supplied per launch, not read from a global migration default. The
contract therefore has no universal percentage. Its Pump tests commonly use
`500` bps (5%)
([`memez@00596fd:fun/tests/pump.move:38-48`](https://github.com/interest-protocol/memez-gg/blob/00596fdac4dd11f427c7bc594e566ce36160db93/fun/tests/pump.move#L38-L48)),
while the focused config test demonstrates `600` bps (6%)
([`memez@00596fd:fun/tests/config/pump.move:7-31`](https://github.com/interest-protocol/memez-gg/blob/00596fdac4dd11f427c7bc594e566ce36160db93/fun/tests/config/pump.move#L7-L31)).
Those are test choices, not immutable production constants.

### Zero has surprising sentinel semantics

At graduation, Pump uses two branches
([`memez@00596fd:fun/sources/pump.move:194-218`](https://github.com/interest-protocol/memez-gg/blob/00596fdac4dd11f427c7bc594e566ce36160db93/fun/sources/pump.move#L194-L218)):

- when the reserved balance is nonzero, it disposes of the entire terminal curve
  Meme balance and migrates exactly the reserved balance;
- when the reserved balance is zero, it migrates the entire terminal curve Meme
  balance.

The current first-party SDK defaults `liquidityProvision` to zero and passes it
as the fourth PumpConfig value
([`memez-sdk@e38e4c7:src/memez/pump.ts:74-101`](https://github.com/interest-protocol/memez.gg-sdk/blob/e38e4c747e700e94669566e5e577e67a3ed5eed9/src/memez/pump.ts#L74-L101),
[`pump.ts:131-143`](https://github.com/interest-protocol/memez.gg-sdk/blob/e38e4c747e700e94669566e5e577e67a3ed5eed9/src/memez/pump.ts#L131-L143)).
Its executable Pump example also explicitly selects zero
([`memez-sdk@e38e4c7:src/scripts/executables/pump/new.ts:29-38`](https://github.com/interest-protocol/memez.gg-sdk/blob/e38e4c747e700e94669566e5e577e67a3ed5eed9/src/scripts/executables/pump/new.ts#L29-L38)).
The contract regression test names this branch `test_migrate_full_liquidity`
([`memez@00596fd:fun/tests/pump.move:955-1017`](https://github.com/interest-protocol/memez-gg/blob/00596fdac4dd11f427c7bc594e566ce36160db93/fun/tests/pump.move#L955-L1017)).

Blast should not copy this overloaded zero implicitly. A zero-safe Blast config
needs to say whether zero means "not configured," "migrate no Meme," or
"migrate all terminal inventory." If both reserved and full-terminal modes are
supported, a named mode is clearer than a numeric sentinel.

### Memez.Fun's terminal disposal is not a supply burn

Memez.Fun calls the terminal helper `destroy_or_burn`, but its nonzero branch
transfers the balance to `@0x0`
([`memez@00596fd:fun/sources/lib/utils.move:25-40`](https://github.com/interest-protocol/memez-gg/blob/00596fdac4dd11f427c7bc594e566ce36160db93/fun/sources/lib/utils.move#L25-L40)).
That makes the balance inaccessible; it does not reduce the coin's recorded total
supply.

Blast already rejects this as a fake burn. Adapting the partition means using a
real Coin Registry burn for a `BurnOnly` launch. A `Fixed` launch cannot burn the
remainder at all: it must either migrate it or return it through an explicitly
accounted residual path
([ADR 0023, lines 77-92](../decisions/0023-generated-coin-supply-and-metadata-custody.md)).
Consequently, "reserve some for the pool and burn the rest" can be a Blast rule
only for burnable launches unless the accepted fixed-supply mode is changed.

## Platform, stakeholder, creator, and treasury lines

Memez.Fun has several economically different destinations that should not be
collapsed into one launch field.

| Line | Memez.Fun behavior | Relevance to Blast |
| --- | --- | --- |
| Stakeholder Meme allocation | `MemezFees` stores a separate `allocation` payload. Launch splits `floor(current_meme_balance * allocation_bps / 10_000)` before reserving pool liquidity, and distributes it only after migration, optionally through vesting ([`fees.move:225-242`](https://github.com/interest-protocol/memez-gg/blob/00596fdac4dd11f427c7bc594e566ce36160db93/fun/sources/structs/fees.move#L225-L242), [`memez_fun.move:346-364`](https://github.com/interest-protocol/memez-gg/blob/00596fdac4dd11f427c7bc594e566ce36160db93/fun/sources/memez_fun.move#L346-L364)). Static configured recipients and launch-supplied stakeholders can share it ([`fees.move:225-240`](https://github.com/interest-protocol/memez-gg/blob/00596fdac4dd11f427c7bc594e566ce36160db93/fun/sources/structs/fees.move#L225-L240)). | Closest historical analogue to Blast's current protocol Meme graduation allocation, not to destination-pool liquidity. A creator could be one configured stakeholder, but Pump does not intrinsically label this balance "creator." |
| Quote migration fee | A percentage `Fee` is copied at launch, rounded up when taken, distributed to its configured recipients, and deducted from terminal Quote before the migration payload is built ([`fees.move:214-223`](https://github.com/interest-protocol/memez-gg/blob/00596fdac4dd11f427c7bc594e566ce36160db93/fun/sources/structs/fees.move#L214-L223), [`pump.move:213-218`](https://github.com/interest-protocol/memez-gg/blob/00596fdac4dd11f427c7bc594e566ce36160db93/fun/sources/pump.move#L213-L218)). | Matches Blast's separate Quote graduation-fee concept. |
| Pump creator/developer Meme | Pump allows the developer to make a paid first purchase and holds those purchased coins for a later developer claim ([`pump.move:137-149`](https://github.com/interest-protocol/memez-gg/blob/00596fdac4dd11f427c7bc594e566ce36160db93/fun/sources/pump.move#L137-L149), [`pump.move:220-232`](https://github.com/interest-protocol/memez-gg/blob/00596fdac4dd11f427c7bc594e566ce36160db93/fun/sources/pump.move#L220-L232)). Stable, a different launch mode, has an explicit vested developer allocation ([`stable.move:93-116`](https://github.com/interest-protocol/memez-gg/blob/00596fdac4dd11f427c7bc594e566ce36160db93/fun/sources/stable.move#L93-L116), [`stable.move:183-203`](https://github.com/interest-protocol/memez-gg/blob/00596fdac4dd11f427c7bc594e566ce36160db93/fun/sources/stable.move#L183-L203)). | Blast deliberately rejected a free creator token allocation for the first release; creator economic exposure currently comes from purchases and fee ownership, not a supply gift ([ADR 0012, line 38](../decisions/0012-flywheel-features.md)). Adding one is a separate product decision. |
| XPump migration caller reward | After unlocking the core payload, XPump splits a configured fixed Quote reward before calculating pool price and adding liquidity ([`xpump.move:188-205`](https://github.com/interest-protocol/memez-gg/blob/00596fdac4dd11f427c7bc594e566ce36160db93/migrators/xpump/sources/xpump.move#L188-L205)). | Adapter incentive, not platform Meme allocation or pool-opening cost. Blast has not accepted it. |
| XPump treasury and LP ownership | XPump transfers pool-add residual Meme and Quote to its configured treasury, transfers the position-owner object to the launch developer, and later directs all collected Meme LP fees plus a configured share of Quote LP fees to the treasury ([`xpump.move:560-603`](https://github.com/interest-protocol/memez-gg/blob/00596fdac4dd11f427c7bc594e566ce36160db93/migrators/xpump/sources/xpump.move#L560-L603), [`xpump.move:631-665`](https://github.com/interest-protocol/memez-gg/blob/00596fdac4dd11f427c7bc594e566ce36160db93/migrators/xpump/sources/xpump.move#L631-L665)). | Adapter-level treasury and LP-fee policy. It should not silently choose the core protocol treasury or change the launch's seed amounts. |

The SDK's first-party fee-setting example selects a 500 bps Quote migration fee,
a zero Meme stakeholder allocation, and one Memez treasury as all configured
static recipients
([`memez-sdk@e38e4c7:src/scripts/executables/config/set-fees.ts:14-39`](https://github.com/interest-protocol/memez.gg-sdk/blob/e38e4c747e700e94669566e5e577e67a3ed5eed9/src/scripts/executables/config/set-fees.ts#L14-L39)).
That script is evidence of one setup, not proof of live mainnet configuration.

## Why the Meme migration amount sets the opening price

For a newly seeded constant-product pool, the raw Quote-per-Meme spot ratio is:

```text
p_pool = quote_seeded / meme_seeded
```

At fixed Quote, increasing `meme_seeded` lowers that opening price. A
concentrated-liquidity pool is more nuanced: its initial price is an explicit
input, while the price, tick range, and supplied balances together determine
how much of each asset the position consumes and what returns as residual.

Memez.Fun's XPump v3 deliberately chooses to couple those values. After
deducting the migration caller reward, it computes the initial X64 square-root
price from Quote divided by a `safe_meme_balance_value`, where the safe amount
subtracts a configurable liquidity margin from the Meme payload
([`memez@00596fd:migrators/xpump/sources/xpump.move:192-205`](https://github.com/interest-protocol/memez-gg/blob/00596fdac4dd11f427c7bc594e566ce36160db93/migrators/xpump/sources/xpump.move#L192-L205)).
It then passes the actual Meme and Quote balances into the liquidity add
([`xpump.move:242-253`](https://github.com/interest-protocol/memez-gg/blob/00596fdac4dd11f427c7bc594e566ce36160db93/migrators/xpump/sources/xpump.move#L242-L253)).
The earlier adapter constants even document a fixed target of `0.000012 SUI` per
Meme, illustrating that graduation price was a deliberate parameter rather than
an arbitrary use of all inventory
([`xpump.move:24-38`](https://github.com/interest-protocol/memez-gg/blob/00596fdac4dd11f427c7bc594e566ce36160db93/migrators/xpump/sources/xpump.move#L24-L38)).

For Blast's virtual-Quote curve, the terminal curve spot ratio is approximately:

```text
p_curve = (virtual_quote + terminal_real_quote) / terminal_curve_meme
```

If the product requires price continuity and the net Quote available after all
approved deductions is `quote_seeded`, the corresponding Meme seed is
approximately:

```text
meme_seeded
  = floor(
      quote_seeded * terminal_curve_meme
      / (virtual_quote + terminal_real_quote)
    )
```

That formula follows from setting `quote_seeded / meme_seeded = p_curve` and must
still specify rounding, orientation, tick quantization, and residual handling.
It also shows why blindly migrating all terminal Meme changes the price: virtual
Quote cannot be moved to the venue, and any Quote fee reduces the real Quote side
again.

A fixed percentage of initial supply, as in Memez.Fun, gives launch policy direct
control and makes the balance reservable before bonding. It does **not** by itself
prove continuity across different `V`, targets, Quote fees, overshoot, Quote
decimals, or concentrated-liquidity ranges. The accepted design must choose
explicitly between:

- a snapshotted, disclosed Meme provision whose resulting DEX price is derived
  from the actual net seed balances; or
- a terminally derived Meme provision whose amount is calculated to preserve the
  curve price, optionally subject to a snapshotted maximum.

## Blast comparison

At `blast-v2-contracts@ad951f8`, `LaunchConfig` stores only the per-Quote terminal
target, Quote migration-fee rate, protocol Meme graduation-allocation rate, and
migration-witness set
([`sui/sources/launch_config.move:17-24`](../../sui/sources/launch_config.move)).
Its snapshot returns exactly the target, those two rates, and witness type
([`launch_config.move:184-214`](../../sui/sources/launch_config.move)). There is no
Meme pool-provision field.

This is not a naming-only issue:

- ADR 0027 says the current Meme graduation allocation is held separately and
  never enters migration inventory
  ([`ADR 0027:141-155`](../decisions/0027-graduation-economics-and-migration-witnesses.md)).
- The same ADR later requires migration to seed "net Meme and Quote" and account
  for gross terminal migration Meme, but never defines how gross or net migration
  Meme is selected
  ([`ADR 0027:173-191`](../decisions/0027-graduation-economics-and-migration-witnesses.md),
  [`ADR 0027:221-239`](../decisions/0027-graduation-economics-and-migration-witnesses.md)).
- ADR 0010 says to burn remaining non-migrated Meme after seeding, but likewise
  does not define the migrated portion
  ([`ADR 0010:141-155`](../decisions/0010-migration-and-venue-adapters.md)).
- The pure curve design says terminal `M` and `Q` drive migration price, which
  makes the absent partition economically material
  ([`ADR 0004:136-141`](../decisions/0004-bonding-curve.md)).

The current `LaunchTicket` is not where this policy belongs. It intentionally
holds only the empty treasury and metadata capabilities, creator authority, and
burnable choice before launch policy is selected
([`sui/sources/launch_ticket.move:14-21`](../../sui/sources/launch_ticket.move)).
The migration-Meme value belongs in the cold launch snapshot and then the future
launch's named balances.

## Design questions exposed for the next ADR

1. Is migration Meme a fixed percentage of initial supply, or dynamically
   derived from the terminal curve price?
2. If fixed, is it global, per Quote target, or selected from an admin-approved
   parameter lattice? A single global rate does not imply equal price continuity
   across quotes or targets.
3. What does zero mean? It should not inherit Memez.Fun's surprising "all
   terminal inventory" sentinel without an explicit decision.
4. Does the protocol Meme allocation remain protocol-only, or can a bounded
   portion go to a creator/community recipient? That is independent of pool seed.
5. Is the protocol claim composable, as ADR 0027 currently says, or is a treasury
   address snapshotted? Memez.Fun's configured core recipients and XPump's adapter
   treasury are different concerns.
6. For a BurnOnly launch, which exact residual is genuinely burned? For a Fixed
   launch, where is the same residual returned or otherwise accounted?
7. Is price continuity mandatory, and against which price: curve spot before
   graduation, average acquisition price, or a separately disclosed opening
   price? The chosen rule determines the Meme seed formula and vectors.

Until those are settled, Blast's current LaunchConfig is sufficient for protocol
graduation revenue and migrator authorization, but incomplete for destination-
pool inventory and opening-price economics.
