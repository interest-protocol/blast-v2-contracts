## Boosts

### What it is

A Boost is a leveraged coin. Each Boost is one Sui coin type,
`Coin<BlastBoost<Product>>`, backed by a single isolated Aftermath perpetuals
position that targets a fixed leverage, for example 2x long NVDA. A user mints
by paying collateral (a six-decimal coin, USDC at launch) and receives shares;
the Vault opens the matching extra position in the same transaction. A user
redeems by burning shares; the Vault closes the proportional position and pays
collateral in the same transaction. Leverage drifts as the price moves; once it
leaves a public band, anyone may call a permissionless rebalance that trades
back toward target. Holders pay all trading costs and funding, a maintenance
reserve inside the venue account absorbs funding costs first, and Blast may
shut a Boost down, after which holders claim the recovered cash pro rata.
Boosts can lose value quickly, and the venue position can be liquidated.

Three packages implement it:

- `blast_boosts_products`: one empty struct per product tag, for example
  `blast_boosts_products::blast_boosts_products::NVDA_BULL_2X`. No state, no
  authority.
- `blast_boosts_core`: venue-neutral policy, lifecycle and accounting
  (`state`, `policy`, `lifecycle`, `observation`). Integrators never call it
  directly; its `State` lives inside the adapter's Vault and only the adapter
  can reach it.
- `blast_boosts_aftermath`: the Aftermath adapter. It owns the share currency,
  the shared `Vault`, the venue account, and every function integrators call
  (the `operations` module and the adapter's `vault` module).

### Objects and authority

#### Product tags and the share coin

- Product tag: an empty struct named `<TICKER>_<SIDE>_<LEVERAGE>` in
  `blast_boosts_products`, for example `NVDA_BULL_2X`, `BTC_BEAR_2X`,
  `XAUT_BULL_2X`. `BULL` means the Vault holds a perp long; `BEAR` means it
  holds a perp short (the inverse). The ticker is the Aftermath base asset
  without its USD suffix. A bull and a bear 2X tag exist for every Aftermath
  market listed on 2026-09-18 (crypto, equities, commodities). A declared tag
  is not a live product until Blast issues its currency.
- Share coin: `Coin<BlastBoost<Product>>`, where `blast_boost::BlastBoost` is
  defined in the adapter. Wallets show it as
  `…::blast_boost::BlastBoost<…::blast_boosts_products::NVDA_BULL_2X>`.
  Shares have **9 decimals**. They are ordinary coins: transferable, splittable,
  usable in any later PTB command. Coin Registry admits one currency per tag.
- The tag name is a label. The Vault's immutable `VaultPolicy` is what fixes
  the side (`policy::PositionSide`, `Long` or `Short`) and the target leverage.
  Read those from the Vault, not from the name.

#### Shared objects

| Object | Type | Created by | Role |
| --- | --- | --- | --- |
| Vault | `blast_boosts_aftermath::vault::Vault<Product, Collateral>` | Blast issuer, once per product | Custody of the core `State`, the bound venue account, the share `TreasuryCap` and `MetadataCap` (dynamic object fields under `TreasuryKey<Product>` and `MetadataKey<Product>`), the locked seed count, earned admin cash, and post-shutdown holder cash. |
| Protocol | `blast_boosts_aftermath::blast_boosts_aftermath::Protocol` | package publish | The adapter's operational generation (every call that takes it checks it) and the accepted partners, one dynamic field per partner keyed by `blast_boosts_aftermath::blast_boosts_aftermath::PartnerKey`. |
| PackageAdmin | `blast_boosts_aftermath::package_admin::PackageAdmin` | deployment | Sealed Publisher and UpgradeCap of the adapter. |
| Blast ACL | `blast_acl::ACL` | `blast_admin` | Role membership for every Blast admin. |

`Vault` fields: `state` (core `state::State<Product>`), `venue_account`
(`venue_account::VenueAccount`: the immutable `binding`, the last accepted
`checkpoint`, and the Aftermath account admin cap, which never leaves),
`locked_shares`, `admin_cash` (`Balance<Collateral>`), `terminal_cash`
(`Balance<Collateral>`).

#### Aftermath objects a PTB must supply

These are Aftermath's shared objects, not Blast code. Every venue-touching
call takes all of them, and the adapter aborts unless each is exactly the
object bound at activation (see `venue_account::Binding`):

| Argument | Aftermath type (package `perpetuals` or `oracle_aggregator`) | Binding field |
| --- | --- | --- |
| `account` | `Account<Collateral>`, the Vault's own isolated Aftermath account, created and shared at activation | `account_object_id`, `account_number` |
| `registry` | Aftermath perpetuals `Registry` | `registry_id` |
| `clearing_house` | `ClearingHouse<Collateral>`, the market | `clearing_house_id` |
| `base_oracle` | `PriceFeedStorage` holding the market's base price feed | `base_oracle_id`, `base_feed_id` |
| `collateral_oracle` | `PriceFeedStorage` holding the collateral price feed | `collateral_oracle_id`, `collateral_feed_id` |

Pass the shared `ClearingHouse` as a normal shared-object input. Several
functions take it by value and re-share it before returning. Also pass the
`Clock` (`0x6`) everywhere a call takes one.

#### Roles

Admin roles are types in `blast_boosts_core`. A Blast admin holding a
`blast_acl::AdminCap` that the ACL granted the role calls
`blast_acl::sign_in<Role>` and passes the returned `blast_acl::AdminWitness<Role>`
to the call. Integrators cannot obtain these witnesses.

| Role | Authorizes |
| --- | --- |
| `blast_boosts_core::blast_boosts_core::VaultIssuer` | `blast_boosts_aftermath::vault::issue` (new Boost), `blast_boosts_aftermath::vault::update_metadata` |
| `blast_boosts_core::blast_boosts_core::RiskAdmin` | `blast_boosts_aftermath::vault::set_fees`, `blast_boosts_aftermath::vault::set_nav_cap`, `blast_boosts_aftermath::vault::set_max_order_notional`, `blast_boosts_aftermath::vault::withdraw_admin_fees`, `operations::add_partner`, `operations::remove_partner` |
| `blast_boosts_core::blast_boosts_core::ShutdownAdmin` | `blast_boosts_aftermath::vault::begin_shutdown` |
| `blast_boosts_core::blast_boosts_core::UpgradeAdmin` | adapter upgrades through `blast_boosts_aftermath::package_admin` |

Everything else (mint, redeem, rebalance, donate, sync, unwind, finalize,
shutdown claims) is *anyone*. No keeper role, keeper reward, or caller-chosen
trade size exists anywhere.

#### Policy (immutable per Vault)

`policy::VaultPolicy`, fixed at issuance:

- `side`: `Long` or `Short`.
- `rebalance_policy` (`policy::RebalancePolicy`), leverage fields in leverage
  basis points where 10,000 = 1x: `rebalance_below_bps < target_leverage_bps <
  rebalance_above_bps < max_leverage_bps <= 1,000,000`; `max_slippage_bps`
  (ordinary execution bound, in bps of the oracle price)
  `<= emergency_max_slippage_bps < 10,000`;
  `min_leverage_improvement_bps > 0`. A zero `rebalance_below_bps` disables
  increase-rebalancing.
- `price_policy` (`policy::PricePolicy`): `max_price_age_ms > 0`,
  `max_price_ahead_ms <= max_price_age_ms`, `max_confidence_bps < 10,000`,
  `max_mark_divergence_bps < 10,000`.
- Fees: `initial_mint_fee_bps <= mint_fee_cap_bps < 10,000`,
  `initial_redeem_fee_bps <= redeem_fee_cap_bps < 10,000`,
  `admin_share_cap_bps <= 10,000`.
- `min_order_lots`: 1 to 1,000,000; the minimum proportional order in venue lots.
- `max_reserve_bps`: 1 to 10,000; ceiling on the reserve as a share of notional.

Live, adjustable values in `State`: `mint_fee_bps`, `redeem_fee_bps`,
`admin_share_bps` (starts at **0** at activation), `nav_cap`,
`max_order_notional`. Other `State` fields: `maintenance_reserve`,
`uncovered_deficit`, `base_unit` (`10^9`), `collateral_unit` (`10^6`),
`lifecycle`.

### Lifecycle

`lifecycle::Lifecycle` has three states and only moves forward. A Vault exists
only from activation, so it is born `Active`.

| State | Entered by | Allowed |
| --- | --- | --- |
| `Active` | `operations::initialize` | mint, redeem (plain and partner), rebalance, `needs_rebalance`, donate, `sync_health`, all admin settings, `begin_shutdown` |
| `Unwinding` | `blast_boosts_aftermath::vault::begin_shutdown` (ShutdownAdmin) | `operations::unwind`, `operations::sync_health`, `operations::finalize_shutdown`, `set_nav_cap`, `set_max_order_notional`, `update_metadata`, `withdraw_admin_fees` |
| `Settled` | `operations::finalize_shutdown` (anyone) | `blast_boosts_aftermath::vault::redeem_shutdown`, `set_nav_cap`, `set_max_order_notional`, `update_metadata`, `withdraw_admin_fees` |

`set_fees` works only in `Active`. Nothing reopens a Vault. Health reporting
(`sync_health`, `CheckpointDrifted`) never changes lifecycle; only the
ShutdownAdmin moves `Active` to `Unwinding`.

### Flows

#### Issue and activate a Boost (Blast admin: VaultIssuer)

One PTB, signed by the issuer. `VaultIssuance` has no abilities, so issuance
and activation succeed or fail together.

1. `blast_acl::sign_in` with type argument `VaultIssuer`, the shared `ACL` and
   the issuer's owned `AdminCap` returns the witness.
2. `policy::new_rebalance_policy(...)`, `policy::new_price_policy(...)`, and
   `policy::long()` or `policy::short()` build the parts;
   `policy::new_vault_policy(side, rebalance_policy, price_policy,
   initial_mint_fee_bps, initial_redeem_fee_bps, mint_fee_cap_bps,
   redeem_fee_cap_bps, admin_share_cap_bps, min_order_lots, max_reserve_bps)`
   returns the `VaultPolicy`.
3. `blast_boosts_aftermath::vault::issue<Product, Collateral>` takes `Protocol`,
   the witness, the Coin Registry (`0xc`), the policy, `max_order_notional`,
   `nav_cap`, and the coin's `symbol`, `name`, `description`, `icon_url`.
   `Product` must be a non-primitive type. It registers the 9-decimal currency,
   emits `VaultIssued`, and returns a `VaultIssuance<Product, Collateral>`.
4. Split the seed `Coin<Collateral>`.
5. `operations::initialize<Product, Collateral>` takes the issuance, `Protocol`,
   the collateral's Coin Registry `Currency<Collateral>`, the Aftermath
   `Registry` (mutable), the `ClearingHouse`, both `PriceFeedStorage` objects,
   the seed coin, `seed_reserve` (atoms of the seed kept as reserve; must be
   below the seed), `position_imr` (the Aftermath position initial margin
   ratio, a nonnegative IFixed `u256`), and the `Clock`. It creates and binds
   the Aftermath account, deposits and allocates the whole seed, sets the
   margin ratio, buys or sells whole lots until the position reaches target
   leverage on the seed NAV (at most 16 orders, each filled completely within
   the ordinary slippage bound and the order cap), settles funding, checks the
   activation invariants (positive NAV, fresh prices, matching side, NAV at or
   under `nav_cap`, leverage inside the band, reserve at or under its ceiling,
   base above `lot_size * min_order_lots`), mints the locked seed shares to
   `0x0`, shares the account and the market, and returns the `Vault`. Emits
   `OrderFilled` per seed order and `VaultInitialized`.
6. `blast_boosts_aftermath::vault::share(vault)` shares the Vault.

Locked seed shares: `locked_shares = seed_shareholder_nav * 1,000` (six-decimal
NAV atoms scaled to nine-decimal share atoms), so the opening price is exactly
1 collateral unit per whole share. They sit at `0x0` forever, count in total
supply, and never redeem.

#### Mint (anyone)

PTB:

1. `SplitCoins` the user's `Coin<Collateral>` into the deposit `cash` (any
   positive amount).
2. `operations::mint<Product, Collateral>(vault, protocol, account, registry,
   clearing_house, base_oracle, collateral_oracle, cash, minimum_shares,
   deadline_ms, clock)`. Objects: `Vault` (shared, mutable), `Protocol`
   (shared, read), `Account<Collateral>` (shared, mutable), `Registry` (shared,
   read), `ClearingHouse<Collateral>` (shared, by value), both
   `PriceFeedStorage` (shared, read), `Clock`. Returns
   `Coin<BlastBoost<Product>>`.
3. `TransferObjects` the shares to the user, or pass them to the next command.
   The coin cannot be dropped.

Parameters: `minimum_shares` is the share floor in share atoms (0 disables it;
set it). `deadline_ms` is inclusive against `Clock`.

What happens, in order, all atomic:

1. Generation, `Active`, positive deposit, and deadline checks.
2. Synchronize: refresh Aftermath's cumulative funding if due, settle the
   position's funding, book it to the reserve (see Funding), and require that
   the venue still matches the accepted checkpoint. Any unexplained change
   aborts (adapter code 32).
3. Price the position at the bound oracle pair; reject stale, future-dated or
   divergent prices, unsafe margin, resting orders, or a paused or frozen
   market.
4. Require leverage **inside** the band (core code 49 otherwise).
5. Fee: `fee = ceil(deposit * mint_fee_bps / 10,000)`,
   `admin_fee = floor(fee * admin_share_bps / 10,000)`,
   `reserve_fee = fee - admin_fee`. Expected contribution
   `C_exp = deposit - fee`.
6. Size the order: `base_to_buy = floor(base * C_exp / N0)` rounded down to
   whole lots, where `base` is the current absolute position and `N0` the
   shareholder NAV. The unrounded figure must be at least
   `lot_size * min_order_lots` (core code 12).
7. Keep `admin_fee` as Vault admin cash; deposit and allocate the rest
   (`deposit - admin_fee`) to the position.
8. Place market orders in the Vault's direction until exactly `base_to_buy` is
   filled: each order at most the whole-lot base worth `max_order_notional` at
   the oracle pair, at most 16 orders, each fill checked for no resting order,
   no liquidation, whole lots, actual collateral notional at or under
   `max_order_notional`, and execution price within `max_slippage_bps` of the
   oracle price.
9. Re-price at the same oracle pair and credit shares (see Economics). Check
   `shares >= minimum_shares`, post-mint NAV at or under `nav_cap`, post-mint
   leverage (rounded up to whole bps) strictly under `max_leverage_bps`, and
   that existing holders' NAV per share did not fall.
10. Mint shares, store the new checkpoint, emit `Minted`.

#### Redeem (anyone)

PTB:

1. Select the `Coin<BlastBoost<Product>>` to burn (split or merge first; any
   positive amount below total supply).
2. `operations::redeem<Product, Collateral>(vault, protocol, account, registry,
   clearing_house, base_oracle, collateral_oracle, shares, minimum_collateral,
   deadline_ms, clock)`. Returns `Coin<Collateral>`.
3. `TransferObjects` the collateral to the user.

What happens: the same generation, lifecycle, deadline, synchronize and price
checks as mint (no band check: redemptions work outside the band). The Vault
sells the proportional position reduce-only:
`max_final_base = floor(base * (S - x) / S)`,
`required = base - max_final_base` (at least `lot_size * min_order_lots`
unless `max_final_base` is 0), and `base_to_sell = min(required rounded up to
whole lots, base)`. Fills face the ordinary slippage bound and the order cap.
It then prices the payout (see Economics), checks `net >= minimum_collateral`,
withdraws `net + admin_fee` from the venue (free collateral first, then
deallocation), keeps `admin_fee` as admin cash, burns the shares, emits
`Redeemed`, and returns `net`.

#### Mint or redeem with a partner code (anyone)

`operations::mint_with_partner` and `operations::redeem_with_partner` take the
same arguments as `mint` and `redeem`, plus the partner's shared
`blast_partners::blast_partners::Partner` object (read only) placed right after
`Protocol`:
`(vault, protocol, partner, account, registry, clearing_house, base_oracle,
collateral_oracle, coin, minimum, deadline_ms, clock)`.

1. The call first requires the partner to be accepted by Boosts at
   `Clock` time (adapter code 38 otherwise).
2. It runs the plain operation unchanged: same shares, same payout, same
   reserve fee.
3. It then pays the partner from the admin fee this operation just retained:
   `partner_fee = floor(admin_fee * share_bps / 10,000)`, where `share_bps` is
   the partner's share in force (at most 8,000), through
   `blast_partners::blast_partners::pay`, which sends it to the partner's
   recipient address and emits `blast_partners::blast_partners::PartnerPaid`
   when nonzero. Blast keeps the rest as admin cash. Emits `PartnerFeePaid`
   (even when the payment is zero).

Before building a partner trade, check acceptance: read the `Protocol`
dynamic field with name `PartnerKey(partner_id)`. The partner is accepted
while the field exists and `now_ms < value` (the value is `u64::MAX` until
Blast removes the partner). Otherwise use the plain calls. While a Vault's
`admin_share_bps` is 0 the partner earns nothing.

#### Rebalance (anyone; keepers)

`operations::rebalance<Product, Collateral>(vault, protocol, account, registry,
clearing_house, base_oracle, collateral_oracle, clock)`. No return value, no
reward, no direction or size argument. Submit it at a gas price **at or below
the reference gas price** (adapter code 37 otherwise), because Aftermath adds
a priority taker fee above it and holders pay every fill.

1. Generation, `Active`, gas price; synchronize as in mint.
2. Require leverage strictly outside the band (core code 54 otherwise):
   `notional * 10,000 < N * rebalance_below_bps` (increase) or
   `notional * 10,000 > N * rebalance_above_bps` (reduce). Band edges are
   healthy.
3. Read the market taker fee, rounded up to whole bps (rebates count as zero).
4. Up to 16 orders. Increase: each order is the largest whole-lot buy that
   keeps post-cost leverage at or under target, reserving adverse slippage
   (`max_slippage_bps`) and the taker fee on it, capped at
   `max_order_notional`; each fill must leave leverage at or under target and
   under max. Reduce: each order sells toward the target base, capped per
   order, rounded down to lots. A reduction that started above
   `max_leverage_bps` uses `emergency_max_slippage_bps` and stops once leverage
   is no longer above max; every other order uses `max_slippage_bps`.
5. Require progress: at least one fill; an increase must raise base and
   leverage; a reduction must lower base and either move leverage at least
   `min_leverage_improvement_bps` toward target or land within one lot of
   target without moving away (core code 55).
6. Store the checkpoint; emit `Rebalanced`. Reserve, supply and admin cash do
   not change; execution cost lowers NAV.

Dry run: `operations::needs_rebalance<Product, Collateral>(vault, protocol,
account, registry, clearing_house, base_oracle, collateral_oracle, clock)`
takes every object by immutable reference and returns `bool`. Run it with
dev-inspect. It aborts where `rebalance` would abort before its first order
(unexplained drift, refused prices, venue not ready). It does not settle
funding first, so a due settlement can shift the answer slightly.

Keeper loop: when dev-inspect returns `true`, submit `rebalance` at the
reference gas price. If another keeper already brought leverage back inside the
band, the call aborts with core code 54; rebuild from current objects. Resolve
an uncertain digest before retrying.

#### Sync health (anyone)

`operations::sync_health<Product, Collateral>(vault, protocol, account,
registry, clearing_house, base_oracle, collateral_oracle, clock)` with the
`ClearingHouse` by mutable reference. Works in `Active` and `Unwinding`.

It refreshes due funding, settles the position's funding, and reconciles with
the accepted checkpoint without pricing anything. An explainable change books
funding to the reserve, adopts the new checkpoint and emits `FundingSettled`
(once per distinct checkpoint; an identical retry emits nothing). Anything
else leaves the accepted checkpoint in place and emits `CheckpointDrifted`;
every drifted sync emits it again. Blast adds no price, margin or drift check
to this call; a binding mismatch aborts.

#### Donate (anyone)

`operations::donate<Product, Collateral>(vault, protocol, account, registry,
clearing_house, base_oracle, collateral_oracle, cash, clock)`, `Active` only,
`cash` positive. It synchronizes (drift aborts), deposits the coin into the
Vault's Aftermath account as free collateral, proves the exact deposit, and
adds it to the maintenance reserve clamped to the reserve ceiling. Any excess
over the ceiling raises shareholder NAV. No shares, no fees. Emits `Donated`.

#### Shutdown

1. **Begin** (Blast admin: ShutdownAdmin).
   `blast_boosts_aftermath::vault::begin_shutdown(vault, protocol, witness,
   reason)` with `reason` from `lifecycle::emergency_reason()` or
   `lifecycle::observed_venue_change_reason()` (an operator's label, never an
   on-chain liquidation verdict). Needs no venue or oracle object. Moves
   `Active` to `Unwinding`, emits `ShutdownBegun`. Mint, redeem, rebalance and
   donate stop.
2. **Unwind** (anyone, repeat until flat). `operations::unwind<Product,
   Collateral>(vault, protocol, account, registry, clearing_house, base_oracle,
   collateral_oracle, clock)`, at or below the reference gas price, refused
   while the clearing house is frozen (adapter code 35).
   - Live market: synchronize (drift is reported with `CheckpointDrifted` and
     the live venue state is adopted anyway), price at fresh oracles, then up
     to 16 reduce-only orders under `emergency_max_slippage_bps` and the order
     cap. Emits `OrderFilled` per order and `UnwindProgress`. Positive NAV and
     the reserve do not gate it. A flat position aborts (adapter code 34): go
     to finalize.
   - Market paused by Aftermath: once Aftermath has enabled positive
     settlement prices, the step closes the position at those prices without a
     market order (`UnwindProgress` with `market_orders = 0`,
     `filled_quote = none`). Before that it aborts (adapter code 33).
3. **Finalize** (anyone). `operations::finalize_shutdown<Product,
   Collateral>(vault, protocol, account, registry, clearing_house, base_oracle,
   collateral_oracle, clock)`. Requires exactly zero base and quote, no orders,
   position funding snapshots equal to the market's (funding fully settled),
   and nonnegative allocated collateral. It withdraws all free collateral plus
   the whole-atom floor of allocated collateral, leaving only a raw remainder
   below one atom at the venue. It sets `Settled`, zeroes the reserve book
   entry, and seals the recovered coin as `terminal_cash` (or as admin cash if
   no eligible share exists). Emits `ShutdownFinalized`. If position funding is
   not fully settled it aborts with adapter code 33; on a live market, settle
   it first, for example with `operations::sync_health` earlier in the same
   PTB.
4. **Claim** (any holder). `blast_boosts_aftermath::vault::redeem_shutdown<Product,
   Collateral>(vault, protocol, shares, minimum_collateral, deadline_ms,
   clock)` returns `Coin<Collateral>`. No venue, oracle or fee. Emits
   `ShutdownRedeemed`.

#### Admin settings (Blast admin)

Each needs `Protocol` and the role witness; none needs venue objects or prices.

| Call | Role | Effect | Event |
| --- | --- | --- | --- |
| `blast_boosts_aftermath::vault::set_fees(vault, protocol, witness, mint_fee_bps, redeem_fee_bps, admin_share_bps)` | RiskAdmin | Sets all three live rates within the policy caps; at least one must change; `Active` only. Affects only future operations. | `FeesUpdated` |
| `blast_boosts_aftermath::vault::set_nav_cap(vault, protocol, witness, nav_cap)` | RiskAdmin | Replaces the NAV cap (positive, changed, and `nav_cap * max_leverage_bps / 10,000` fits in `u64`); may be set below current NAV, which only blocks mints. Any lifecycle. | `NavCapUpdated` |
| `blast_boosts_aftermath::vault::set_max_order_notional(vault, protocol, witness, max_order_notional)` | RiskAdmin | Replaces the per-order collateral notional cap (positive, changed). Any lifecycle, no cooldown. | `MaxOrderNotionalUpdated` |
| `blast_boosts_aftermath::vault::withdraw_admin_fees(vault, protocol, witness, amount)` | RiskAdmin | Returns `Coin<Collateral>` from admin cash only. Any lifecycle. | `AdminFeesWithdrawn` |
| `blast_boosts_aftermath::vault::update_metadata(vault, protocol, witness, currency, name, description, icon_url)` | VaultIssuer | Updates the share coin's name, description and icon in its Coin Registry `Currency<BlastBoost<Product>>`; the symbol is fixed. At least one must change. | `MetadataUpdated` |
| `operations::add_partner(protocol, witness, partner)` | RiskAdmin | Accepts a `Partner` at once, or cancels its pending removal. | `PartnerAdded` |
| `operations::remove_partner(protocol, witness, partner, clock)` | RiskAdmin | Partner stays accepted until `now + blast_partners::blast_partners::delay_ms()` (seven days). | `PartnerRemoved` |

Upgrades: at deployment, the holder of the adapter's Publisher and UpgradeCap
calls `blast_boosts_aftermath::package_admin::wrap` to seal them into the shared
`PackageAdmin`. Then, with the UpgradeAdmin witness,
`blast_boosts_aftermath::package_admin::authorize_upgrade` returns an
`UpgradeTicket` for one digest;
`blast_boosts_aftermath::package_admin::commit_upgrade_and_advance` commits the
receipt and advances `Protocol` to the next generation in the same
transaction; `blast_boosts_aftermath::package_admin::restrict_to_additive`,
`blast_boosts_aftermath::package_admin::restrict_to_dependency_only` and
`blast_boosts_aftermath::package_admin::make_immutable` narrow upgrades
irreversibly. The core package is immutable.

### Economics

Units: collateral amounts in collateral atoms (six decimals; 1 USDC =
1,000,000). Shares in share atoms (nine decimals). Base in base atoms
normalized to nine decimals. Oracle prices normalized to nine decimals. Rates
in basis points out of 10,000; leverage in basis points where 10,000 = 1x.

#### NAV

- `E`, venue equity: free collateral in the Vault's Aftermath account, plus
  collateral allocated to the position, plus unrealized PnL at the base oracle
  price, converted at the collateral oracle price. Assets round down,
  liabilities round up.
- `notional = ceil(base * base_price * 10^6 / (collateral_price * 10^9))`,
  the absolute position valued at the oracle pair (never the venue mark).
- Admitted reserve `R* = min(maintenance_reserve, floor(notional *
  max_reserve_bps / 10,000))`; when the position is flat, `R*` is the whole
  stored reserve.
- Shareholder NAV `N = E - R*`. Every priced operation requires `N > 0`.
- Leverage `= notional / N`. Band comparisons and the rebalance max and target
  checks cross-multiply exactly, without rounding; the post-mint max check
  rounds leverage up to whole bps first.
- NAV per share `= N / S`, where `S` is total share supply including the
  locked seed. A whole share is worth `N * 10^9 / S` collateral atoms.

#### Mint math

```text
fee          = ceil(deposit * mint_fee_bps / 10_000)
admin_fee    = floor(fee * admin_share_bps / 10_000)
reserve_fee  = fee - admin_fee
C_exp        = deposit - fee
R1           = min(R0* + reserve_fee, reserve ceiling at the new notional)
N1           = E1 - R1                    (after the fills, same oracle pair)
contribution = min(N1 - N0, C_exp)        (N1 <= N0 aborts, code 5)
shares       = floor(S0 * contribution / N0)   (zero aborts, code 6)
```

The depositor pays the venue's taker fees and slippage through a smaller
`N1 - N0`. A fill better than the oracle credits at most `C_exp`; the excess
stays with existing holders. Share rounding goes to existing holders.

Example (illustrative rates): deposit 1,000 USDC (1,000,000,000 atoms),
`mint_fee_bps = 30`, `admin_share_bps = 2,000`. Fee = 3,000,000; admin fee =
600,000 (kept by the Vault); reserve fee = 2,400,000 (deposited, credited to
the reserve); `C_exp` = 997,000,000. If execution costs 1,000,000, the
contribution is 996,000,000 and `shares = floor(S0 * 996,000,000 / N0)`.

#### Redemption math

```text
keep   = ceil(N0 * (S0 - x) / S0)
Nu     = E_after_sell - R0*
gross  = min(Nu, N0) - keep               (<= 0 aborts, code 7)
fee    = ceil(gross * redeem_fee_bps / 10_000)
net    = gross - fee                      (0 aborts, code 8)
admin  = floor(fee * admin_share_bps / 10_000)
reserve after = min(R0* + fee - admin, reserve ceiling at the new notional)
```

The Vault withdraws exactly `net + admin`. The redeemer pays the sell's cost;
a sell better than the oracle pays at most the proportional claim `N0 - keep`,
and the gain stays with remaining holders. The reserve fee stays in the venue
account.

#### Fees and who receives them

- Reserve fee: stays in the venue account as maintenance reserve. It protects
  holders and is never paid to anyone during normal operation.
- Admin fee: kept as native `admin_cash` in the Vault, never sent to the
  venue. Only RiskAdmin withdraws it. With a partner code, up to 80% of each
  operation's admin fee goes to the partner, rounded down; Blast keeps the
  dust.
- Rounding: fees round up; the admin share rounds down, so the reserve gets
  the remainder.
- The user passes no fee argument. Execution uses the live rates; read them
  from the Vault before quoting.
- Fee ceilings: the live rates never exceed the policy caps set at issuance.

#### Funding and the maintenance reserve

Funding is booked only from authenticated Aftermath settlement. Each sync
classifies what moved since the accepted checkpoint: funding someone else
settled (permissionless on Aftermath) plus the settlement the Vault just ran,
netted into one credit or cost. Costs round up to atoms; credits round down.

```text
cost:   absorbed = min(reserve, cost); reserve -= absorbed;
        uncovered_deficit += cost - absorbed   (holders bore it)
credit: restored = min(credit, uncovered_deficit); uncovered_deficit -= restored;
        reserve += credit - restored           (restored stays in NAV)
```

A credit may lift the stored reserve above its ceiling; priced operations
value shares against the admitted reserve `R*`, so the excess counts as NAV
from the next priced operation on. Mint, redeem and donate store the clamped
value. Trading losses, slippage, liquidation, ADL and socialized loss are never
treated as funding. The reserve is bookkeeping inside the margin account, not
separate custody: a non-funding loss can impair it, and a priced operation
refuses an account whose equity does not exceed the admitted reserve.

#### Caps

- NAV cap: post-mint `N1 <= nav_cap` (inclusive). Only mints check it; profit
  can carry NAV above it, which blocks mints until NAV falls or RiskAdmin
  raises the cap.
- Order cap: each Aftermath order is sized to at most the whole-lot base worth
  `max_order_notional` at the oracle pair, and each fill's actual collateral
  notional must stay at or under `max_order_notional`. With 16 orders per call,
  one mint can add at most about `16 * max_order_notional` of notional, so the
  largest single mint is roughly `16 * max_order_notional / leverage`.
- Minimum size: a mint or a non-flat redemption must move at least
  `lot_size * min_order_lots` of base.

#### Shutdown payouts

```text
eligible = total_supply - locked_shares
payout   = floor(terminal_cash * shares / eligible)
```

No fee. The last claimant (shares equal to all eligible supply) receives all
remaining cash, dust included. A partial claim that rounds to zero while cash
remains aborts; combine shares. If `terminal_cash` is zero, a burn with
`minimum_collateral = 0` succeeds and returns a zero coin. If no eligible
shares remain at finalization, recovered cash becomes admin cash. The reserve
book entry is consumed at finalization, so recovered reserve cash belongs to
holders. Admin cash never enters the holder pool.

### Time rules

- `deadline_ms` (mint, redeem, partner variants, `redeem_shutdown`):
  inclusive; `Clock` time greater than it aborts (adapter code 28).
- Price freshness: each oracle's publish time must lie in
  `[now - max_price_age_ms, now + max_price_ahead_ms]`, inclusive. Older aborts
  with core code 27; further ahead aborts with core code 28. The confidence
  gate always passes because Aftermath feeds carry no confidence interval. The
  venue mark must be within `max_mark_divergence_bps` of the base oracle price
  (core code 31) for priced operations; unwind skips the mark check.
- Same oracle pair: every order and the final pricing of one operation use the
  oracle pair captured at its start; a change of pair or lot between plan and
  completion aborts (core code 50).
- Funding refresh: before settling, the adapter calls Aftermath's funding
  update only when the market's funding period has elapsed.
- Partner removal: accepted while `now_ms < accepted_until_ms`, where
  `accepted_until_ms = removal time + 7 days`
  (`blast_partners::blast_partners::delay_ms`).
  Partner share changes follow `blast_partners` timelocks.
- Admin settings have no cooldown. Shutdown has no timer: unwind and finalize
  run whenever the venue allows.

### Reading state

There is no public getter on the Vault; read object fields over RPC and use
events and dry runs.

| Question | Where |
| --- | --- |
| Which objects to pass | `VaultInitialized.vault_id` and `VaultInitialized.binding`, or the Vault's `venue_account.binding` (`account_object_id`, `registry_id`, `clearing_house_id`, `base_oracle_id`, `collateral_oracle_id`). |
| Side, target, band, max leverage, slippage | Vault `state.vault_policy` (`side`, `rebalance_policy.*`), also in `VaultIssued.vault_policy`. |
| Live fees | Vault `state.mint_fee_bps`, `state.redeem_fee_bps`, `state.admin_share_bps`; changes in `FeesUpdated`. |
| Fee caps, price policy, `min_order_lots`, `max_reserve_bps` | Vault `state.vault_policy`. |
| NAV cap, order cap | Vault `state.nav_cap`, `state.max_order_notional`. |
| Reserve and uncovered deficit | Vault `state.maintenance_reserve`, `state.uncovered_deficit`; `reserve_after` in `Minted`, `Redeemed`, `Rebalanced`, `FundingSettled`, `Donated`. |
| Lifecycle | Vault `state.lifecycle` variant (`Active`, `Unwinding`, `Settled`). |
| Total supply | `total_supply` of the `TreasuryCap` stored as a dynamic object field of the Vault under `TreasuryKey<Product>`; also `supply_after` in `Minted`, `Redeemed`, `Rebalanced`. |
| Locked seed | Vault `locked_shares`; `VaultInitialized.locked_shares`. |
| Admin cash, holder cash after shutdown | Vault `admin_cash`, `terminal_cash`. |
| Last accepted venue state | Vault `venue_account.checkpoint` (`checkpoint::Checkpoint`). |
| Is a partner accepted | `Protocol` dynamic field `PartnerKey(partner_id)` holding `accepted_until_ms`. |
| Coin name, symbol, decimals | Coin Registry `Currency<BlastBoost<Product>>` (9 decimals). |
| Needs rebalance | dev-inspect `operations::needs_rebalance`. |
| Exact quote | dry-run the mint or redeem PTB with `minimum_shares` or `minimum_collateral` set to 0 and read `Minted.shares` or `Redeemed.net`. |

NAV is not stored. Compute it off chain from the Aftermath account and
position at the oracle prices (formulas in Economics) or take it from a dry
run. The `Checkpoint` holds raw Aftermath values: `free_collateral` (atoms),
`allocated_collateral`, `signed_base`, `signed_quote_notional`, the position's
`funding_snapshot_long` and `funding_snapshot_short`, the market's
`market_funding_long` and `market_funding_short`, `lot_size`,
`pending_ask_base`, `pending_bid_base`, `pending_order_count`,
`market_pause_mode`, `market_frozen`, `position_initial_margin_ratio`,
`market_initial_margin_ratio`, `market_maintenance_margin_ratio`. The `u256`
values are Aftermath IFixed (18 decimals, two's-complement sign).

### Events

Every adapter event is wrapped in the envelope
`blast_boosts_aftermath::blast_events::Event<T>`; the payload `T` is one of the
types below from the adapter's `events` module (for example
`blast_boosts_aftermath::events::Minted`), generic over `Product` except
`PartnerAdded` and `PartnerRemoved`. An aborted transaction emits nothing.

| Event | Emitted by | Use |
| --- | --- | --- |
| `VaultIssued` | `issue` | Policy, initial caps, treasury and metadata cap IDs. No Vault ID yet. |
| `VaultInitialized` | `initialize` | Vault ID, binding, seed amount, seed equity, reserve and NAV, locked shares, opening base and lot, side, IMR, first checkpoint. |
| `OrderFilled` | every Aftermath order (seed, mint, redeem, rebalance, unwind) | `account_object_id` (map to the Vault through the binding), side, reduce-only, emergency, requested and filled base, raw quote, 9-decimal reference and executed prices. |
| `Minted` | `mint` | deposit, shares, contribution, fee, admin and reserve fee, reserve, admin cash and supply after, checkpoint. |
| `Redeemed` | `redeem` | shares burned, net paid, fee split, reserve, admin cash and supply after, checkpoint. |
| `PartnerFeePaid` | partner variants, after `Minted` or `Redeemed` | partner ID, the operation's admin fee, the partner's cut. `admin_cash_after` in the preceding event still includes the cut. |
| `PartnerAdded`, `PartnerRemoved` | partner list changes | `accepted_until_ms` on removal. |
| `Rebalanced` | `rebalance` | equity and base before and after, direction. Equity change is the execution cost (or gain) at the fixed pair. |
| `FundingSettled` | any synchronization (`sync_health`, mint, redeem, rebalance, donate, unwind) that adopts a changed checkpoint | cost or credit, raw IFixed and atom amounts (atoms may be 0), absorbed, uncovered, restored, reserve after, previous and new checkpoint. |
| `CheckpointDrifted` | `sync_health` or `unwind` that finds unexplained venue state | After `sync_health` the accepted checkpoint stands and priced operations abort until a sync finds the venue explainable again; `unwind` then adopts the live state and closes it. |
| `Donated` | `donate` | amount, reserve after. |
| `ShutdownBegun` | `begin_shutdown` | declared reason. |
| `UnwindProgress` | `unwind` | adopted before checkpoint, after checkpoint, market orders, filled quote (`none` for settlement-price closes). |
| `ShutdownFinalized` | `finalize_shutdown` | recovered cash, eligible supply, final checkpoint, raw unrecoverable remainder (below one atom). |
| `ShutdownRedeemed` | `redeem_shutdown` | shares, cash paid, cash and eligible supply remaining. |
| `FeesUpdated`, `NavCapUpdated`, `MaxOrderNotionalUpdated` | admin calls | previous and new values. |
| `MetadataUpdated` | `update_metadata` | the new name, description and icon URL. |
| `AdminFeesWithdrawn` | `withdraw_admin_fees` | amount withdrawn and admin cash remaining. |

An indexer can rebuild supply, reserve and admin cash from the `*_after`
fields plus `FundingSettled`, `Donated`, `PartnerFeePaid`,
`AdminFeesWithdrawn`, `ShutdownFinalized` and `ShutdownRedeemed`, execution
prices from `OrderFilled`, and approximate NAV per share at each mint as
`contribution / shares` (rounding makes it slightly high).

### Aborts

Codes repeat across packages. Decode by the aborting module: modules
`state`, `accounting_math`, `rebalance_math`, `policy`, `lifecycle`,
`observation` belong to `blast_boosts_core`; `operations`, `vault`, `orders`,
`checkpoint`, `snapshot`, `venue_account`, `blast_boosts_aftermath`,
`package_admin` belong to `blast_boosts_aftermath`. A call through an
outdated adapter package aborts in the `operational_version` module of the
`blast_admin` package with code 13.

#### Adapter (`blast_boosts_aftermath`)

| Code | Meaning | Fix |
| --- | --- | --- |
| 0-2, 13-20 | Deployment, issuance, activation input or seed problems | Issuer only. |
| 3-10 | An Aftermath object (account, registry, clearing house, oracle storage or feed) is not the bound one | Pass the objects from the Vault's binding. |
| 11 | The venue's price is not the bound feed's | Same; use the bound feed storage. |
| 12 | A venue value cannot be represented (for example negative equity) | The account is underwater; wait or expect shutdown. |
| 21 | Zero coin or amount | Pass a positive coin. |
| 22 | Admin withdrawal above admin cash | Lower the amount. |
| 23 | A cash move did not match the venue exactly | Retry; the venue changed mid-transaction. |
| 24, 25, 26 | Fill not whole-lot, a resting order left, or a liquidation during the order | Retry later; the book or margin did not support the order. |
| 27 | The operation needed more than 16 orders | Trade a smaller amount or wait for a larger order cap. |
| 28 | Deadline passed | Use a later `deadline_ms`. |
| 29 | A fill changed venue fields it should not | Retry. |
| 31 | The market's taker fee is not a usable rate (rebalance) | Wait; venue configuration. |
| 32 | Venue state the Vault cannot explain since its checkpoint | Call `sync_health` and check for `CheckpointDrifted`; priced operations stay blocked until the venue is explainable. |
| 33 | Terminal step not possible: orders open, funding unsettled, settlement prices not enabled, or wrong order count | Settle funding with `sync_health` first, or wait for Aftermath. |
| 34 | Unwind found no lot-aligned position on the bound side (for example already flat) | Call `finalize_shutdown`. |
| 35 | Venue not ready: resting orders, unsafe margin, paused market or frozen clearing house | Wait. |
| 36, 39 | Metadata or partner list update changes nothing | Admin only. |
| 37 | Rebalance or unwind above the reference gas price | Submit at the reference gas price. |
| 38 | Partner not accepted | Use the plain call. |

#### Core (`blast_boosts_core`)

| Code | Meaning | Fix |
| --- | --- | --- |
| 2 | Shareholder NAV not positive | Equity does not exceed the admitted reserve; operations are blocked. |
| 4 | Redeem amount at or above supply, or a shutdown claim of zero or above eligible supply | Redeem or claim a positive amount within supply. |
| 5 | Contribution not positive (deposit consumed by fee, or no NAV rise) | Deposit more. |
| 6 | Deposit too small for one share atom | Deposit more. |
| 7, 8 | Redemption claim below the sell cost, or fee consumes it; 8 also for a shutdown claim that rounds to zero | Redeem or claim more shares. |
| 12 | Order below `lot_size * min_order_lots` | Mint or redeem a larger amount. |
| 13, 14, 19, 20 | Final base outside the proportional range | Retry; fills did not match the plan. |
| 16 | Reserve exceeds equity after the sell | Redeem less or retry later. |
| 18 | Operation not allowed in this lifecycle | Check `state.lifecycle`. |
| 27, 28 | Oracle price stale or future-dated | Retry after the Aftermath feed updates. |
| 31 | Venue mark too far from the oracle | Retry later. |
| 35 | Fewer shares than `minimum_shares` | Re-quote; raise slippage tolerance. |
| 36 | Post-mint NAV above `nav_cap` | Mint less or wait. |
| 37 | A fill's price outside the slippage bound | Trade smaller or wait for depth. |
| 43 | A fill's actual notional above `max_order_notional` | Trade smaller. |
| 49 | Mint while leverage is outside the band | Call `rebalance` (anyone), then mint. |
| 50, 51 | Oracle pair or fills changed within the operation | Retry. |
| 52 | Leverage after a mint at or above `max_leverage_bps` (rounded up), or a rebalance buy left leverage above target or at or above max | Mint less; for rebalance, retry later. |
| 53 | Payout below `minimum_collateral` | Re-quote. |
| 54 | Rebalance while inside the band | Nothing to do. |
| 55 | Rebalance made no admissible progress | Wait for depth or a better price. |
| 17, 23, 39, 40, 47, 48, 58 | Admin transition or setting rejected (wrong state, invalid, above cap, unchanged) | Admin only. |

### Pitfalls

- Passing an Aftermath object other than the bound one. Always read the binding.
- Setting `minimum_shares` or `minimum_collateral` to 0 in production. The
  mint floors shares and execution costs vary; set a floor from a fresh dry run.
- Expecting to mint at any time. Mints abort while leverage is outside the band
  (49), above the NAV cap (36), or while the checkpoint is drifted (32).
- Tiny trades. Mints and redemptions below `lot_size * min_order_lots` of base
  abort (12); shutdown claims that round to zero abort (8).
- Large trades. More than 16 orders, a fill outside `max_slippage_bps`, or a
  full-size buy order filling above the oracle (actual notional over the cap)
  aborts the whole transaction.
- Submitting `rebalance` or `unwind` with a priority gas price (37). For mint
  and redeem a higher gas price is allowed, but Aftermath then adds its
  priority taker fee to every fill, which the user pays through fewer shares or
  a lower payout.
- Reading `CheckpointDrifted` from a failed mint: aborted transactions emit
  nothing. Only `sync_health` and `unwind` record drift. Drift from a
  lasting venue change (a liquidation, an ADL, or a change to the market's
  margin ratios or lot size) does not clear on its own; Blast's ShutdownAdmin
  may then shut the Boost down.
- Decoding an abort by code alone. Core and adapter codes overlap.
- Calling an old adapter package after an upgrade (blast_admin code 13). Types
  keep their original package IDs; calls must target the current package.
- Treating the tag name as the policy. `NVDA_BULL_2X` is a label; read `side`
  and `target_leverage_bps` from the Vault.
- Assuming NAV per share starts anywhere but 1. The seed mints exactly
  1 whole share per collateral unit of seed NAV.
- Counting locked shares as claimable. They count in total supply for mint and
  redeem math but are excluded from shutdown claims.
- Expecting partner revenue at activation: `admin_share_bps` starts at 0.

### Q&A

**How do I mint a Boost?** Split a collateral coin and call `operations::mint`
with the Vault, `Protocol`, the five bound Aftermath objects, the coin, a
`minimum_shares` floor, an inclusive `deadline_ms`, and the `Clock`. Transfer
the returned `Coin<BlastBoost<Product>>`. With a partner code call
`operations::mint_with_partner` and put the `Partner` after `Protocol`.

**How many shares will I get?** `floor(S * contribution / N)`, where
`contribution` is your deposit minus the mint fee, reduced by any execution
cost, and `N` is shareholder NAV before your mint. The exact figure depends on
fills, so dry-run the PTB and set `minimum_shares` just below the result.

**What fees do I pay?** The live mint or redeem fee, rounded up, plus Aftermath
taker fees and slippage on the Vault's orders. The fee splits into a reserve
part (stays in the Vault for holders) and Blast's admin part. A partner code
changes nothing for the user.

**Why did my mint abort with code 49 in `state`?** The Vault's leverage is
outside the rebalance band, and mints are allowed only inside it. Anyone can call
`operations::rebalance`; once it succeeds, mint again.

**Who rebalances, and is there a reward?** Anyone, through
`operations::rebalance`, at or below the reference gas price. There is no
reward, no role and no size argument; the chain derives direction and size and
holders pay the fills. Use `operations::needs_rebalance` in dev-inspect to
decide when to submit.

**How do I read NAV and leverage?** NAV is not stored. Compute
`N = E - min(maintenance_reserve, notional * max_reserve_bps / 10,000)` from
the Aftermath position at the oracle prices, and leverage as `notional / N`.
For an exact quote, dry-run the mint or redeem and read `Minted` or
`Redeemed`.

**What does the maintenance reserve do?** It is collateral in the venue account
that share pricing excludes. Funding costs consume it before holders bear
them, mint and redeem reserve fees refill it, and donations add to it. It is
capped at `max_reserve_bps` of notional; anything above counts as holder NAV.

**What happens on shutdown?** Blast's ShutdownAdmin calls `begin_shutdown`;
anyone then calls `operations::unwind` until flat and
`operations::finalize_shutdown`. Holders call
`blast_boosts_aftermath::vault::redeem_shutdown` for a fee-free pro-rata share
of the recovered cash, excluding the locked seed; the last claimant gets the
dust.

**Can a Boost be liquidated?** The Aftermath position can be. The Vault never
declares liquidation on chain; a liquidation appears as `CheckpointDrifted`,
priced operations stop, and Blast's ShutdownAdmin may shut the Boost down so
holders can claim what remains.

**Is there a testnet deployment?** No. Blast deploys Boosts on Sui mainnet only.
