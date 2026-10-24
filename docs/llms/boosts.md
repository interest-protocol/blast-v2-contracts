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
| Vault | `blast_boosts_aftermath::vault::Vault<Product, Collateral>` | Blast issuer, once per product | Custody of the core `State`, the bound venue account, the share `TreasuryCap` and `MetadataCap` (dynamic object fields under `TreasuryKey<Product>` and `MetadataKey<Product>`), the locked seed count, earned admin cash, post-shutdown holder cash, and protected cash with no exposed withdrawal path from a size-locked exit. |
| Protocol | `blast_boosts_aftermath::blast_boosts_aftermath::Protocol` | package publish | The adapter's operational generation (ordinary calls require the current generation; upgrade activation requires exactly the next one) and the accepted partners, one dynamic field per partner keyed by `blast_boosts_aftermath::blast_boosts_aftermath::PartnerKey`. |
| PackageAdmin | `blast_boosts_aftermath::package_admin::PackageAdmin` | deployment | Sealed Publisher and UpgradeCap of the adapter. |
| Blast ACL | `blast_acl::ACL` | `blast_admin` | Role membership for every Blast admin. |

`Vault` fields: `state` (core `state::State<Product>`), `venue_account`
(`venue_account::VenueAccount`: the immutable `binding`, the last accepted
`checkpoint`, and the Aftermath account admin cap, which never leaves),
`locked_shares`, `admin_cash`, `terminal_cash`, and `protected_cash`
(the three cash fields are `Balance<Collateral>`).

#### Aftermath objects a PTB must supply

These are Aftermath's shared objects, not Blast code. Every venue-touching
call takes all of them. The account, registry and clearing house must be
exactly the objects bound at activation (see `venue_account::Binding`); the
two price-feed storages are not bound, and must instead be the storages the
clearing house's market parameters name right now, so a venue-side oracle
re-pointing never strands a Vault:

| Argument | Aftermath type (package `perpetuals` or `oracle_aggregator`) | Binding field |
| --- | --- | --- |
| `account` | `Account<Collateral>`, the Vault's own isolated Aftermath account, created and shared at activation | `account_object_id`, `account_number` |
| `registry` | Aftermath perpetuals `Registry` | `registry_id` |
| `clearing_house` | `ClearingHouse<Collateral>`, the market | `clearing_house_id` |
| `base_oracle` | `PriceFeedStorage` holding the market's base price feed | none; its `storage_id` must equal the market's `base_storage_id` |
| `collateral_oracle` | `PriceFeedStorage` holding the collateral price feed | none; its `storage_id` must equal the market's `collateral_storage_id` |

Pass the shared `ClearingHouse` as a normal shared-object input. Several
functions take it by value and return it after settling the required Aftermath
session. Reuse that result in later PTB commands, then call Aftermath
`clearing_house::share` once after its final use. `operations::realize_profit`,
`operations::rebalance` and `operations::unwind` instead share it internally
and return nothing. These
private `entry` calls accept the shared market directly, never a market returned
by an earlier trading session, and end that market's use in the PTB.
Also pass the `Clock` (`0x6`)
everywhere a call takes one. This ABI requires a fresh publication.

#### Roles

Admin roles are types in `blast_boosts_core`. A Blast admin holding a
`blast_acl::AdminCap` that the ACL granted the role calls
`blast_acl::sign_in<Role>` and passes the returned `blast_acl::AdminWitness<Role>`
to the call. Integrators cannot obtain these witnesses.

| Role | Authorizes |
| --- | --- |
| `blast_boosts_core::blast_boosts_core::VaultIssuer` | `blast_boosts_aftermath::vault::issue` (new Boost), `blast_boosts_aftermath::vault::update_metadata` |
| `blast_boosts_core::blast_boosts_core::RiskAdmin` | `blast_boosts_aftermath::vault::set_fees`, `blast_boosts_aftermath::vault::set_nav_cap`, `operations::set_max_order_notional`, `operations::rebaseline`, `blast_boosts_aftermath::vault::withdraw_admin_fees`, `operations::add_partner`, `operations::remove_partner` |
| `blast_boosts_core::blast_boosts_core::ShutdownAdmin` | `blast_boosts_aftermath::vault::begin_shutdown` |
| `blast_boosts_core::blast_boosts_core::UpgradeAdmin` | adapter upgrades through `blast_boosts_aftermath::package_admin` |

Everything else (mint, redeem, realize profit, rebalance, donate, sync, unwind, finalize,
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
  `min_leverage_improvement_bps > 0`. Issuance and either live cap update also
  require `min_leverage_improvement_bps * nav_cap <= 16 * max_order_notional *
  10,000` (core code 69). This optimistic bound does not guarantee execution
  after costs or lot rounding. A zero `rebalance_below_bps` disables
  increase-rebalancing. Every order the Vault places is an immediate-or-cancel
  limit order whose price is the oracle price moved by the applicable bound
  against the order and rounded to the market tick back toward the oracle, so
  no fill can cross the bound; the fill's average price is then checked against
  the same bound.
- `price_policy` (`policy::PricePolicy`): `max_price_age_ms > 0`,
  `max_price_ahead_ms <= max_price_age_ms`, `max_confidence_bps < 10,000`,
  `max_mark_divergence_bps < 10,000`.
- Fees: `initial_mint_fee_bps <= mint_fee_cap_bps < 10,000`,
  `initial_redeem_fee_bps <= redeem_fee_cap_bps < 10,000`,
  `admin_share_cap_bps <= 10,000`.
- `min_order_lots`: 2 to 1,000,000; the minimum proportional order in venue lots.
  Two is only the structural floor; each product needs a simulated minimum.
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
| `Active` | `operations::initialize` | mint, redeem (plain and partner), `realize_profit`, rebalance, `needs_rebalance`, donate, `sync_health`, RiskAdmin `rebaseline`, all admin settings, `begin_shutdown`, `begin_protected_shutdown` |
| `Unwinding` | `blast_boosts_aftermath::vault::begin_shutdown` (ShutdownAdmin) or `operations::begin_protected_shutdown` (anyone, proven size lock) | `operations::unwind`, `operations::sync_health`, `operations::finalize_shutdown`, `set_nav_cap`, `set_max_order_notional`, `update_metadata`, `withdraw_admin_fees` |
| `Settled` | `operations::finalize_shutdown` (anyone) | `blast_boosts_aftermath::vault::redeem_shutdown`, `set_nav_cap`, `set_max_order_notional`, `update_metadata`, `withdraw_admin_fees` |

`set_fees` works only in `Active`. Nothing reopens a Vault. Health reporting
(`sync_health`, `CheckpointDrifted`) never changes lifecycle. ShutdownAdmin or
an explicit, proven permissionless size-lock trigger moves `Active` to
`Unwinding`. Entry seals whether settlement protects the seed and reserves.

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
   ratio, a positive IFixed `u256` no greater than one), and the `Clock`.
   Before creating the account it requires that ratio to meet the live market
   minimum and pass a policy-owned safety budget. The budget accounts for the
   live collateral haircut, ordinary plus configured priority trading fees,
   emergency price limit and allowed mark divergence. It assumes fully realized,
   fully allocated equity at the hard cap, with no reserve credit; it is not a
   guarantee against accumulated losses or later exchange changes. It creates and binds
   the Aftermath account, deposits and allocates the whole seed, sets the
   margin ratio, requires the order cap to cover `min_order_lots` live lots
   including price headroom, buys or sells whole lots until the position reaches target
   leverage on the seed NAV (at most 16 limit orders priced inside the
   ordinary bound, each filled completely and within the order cap), settles
   funding, checks the
   activation invariants (positive NAV, fresh prices, matching side, NAV at or
   under `nav_cap`, leverage inside the band, reserve at or under its ceiling,
   base above `lot_size * min_order_lots`), mints the locked seed shares to
   `0x0`, shares the account, and returns `(Vault, ClearingHouse)`. Emits
   `OrderFilled` per seed order and `VaultInitialized`.
6. `blast_boosts_aftermath::vault::share(vault)` shares the Vault. Reuse the
   returned market as needed, then call Aftermath `clearing_house::share`.

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
   `(Coin<BlastBoost<Product>>, ClearingHouse<Collateral>)`.
3. Reuse the returned market, then call Aftermath `clearing_house::share`.
   `TransferObjects` the shares to the user, or pass them to the next command.
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
4. Require leverage **inside** the band, except for a below-band position
   whose fee-aware standalone increase sizes zero even after considering a
   one-lot landing inside the band. This exception cannot bypass cap, margin,
   price or market admission. Other outside-band deposits abort (core code 49).
5. Fee: `fee = ceil(deposit * mint_fee_bps / 10,000)`,
   `admin_fee = floor(fee * admin_share_bps / 10,000)`,
   `reserve_fee = fee - admin_fee`. Expected contribution
   `C_exp = deposit - fee`.
6. Size the order: `base_to_buy = floor(base * C_exp / N0)` rounded down to
   whole lots, where `base` is the current absolute position and `N0` the
   shareholder NAV. The unrounded figure must be at least
   `lot_size * min_order_lots` (core code 12). For the exceptional below-band
   recovery, use a sealed catch-up buy toward target after adding the expected
   contribution, at most one ordinary order cap, and at least the proportional
   amount. Reject a deposit that cannot produce an in-band projected result.
   Actual contribution must still fund the proportional minimum. All catch-up
   execution costs reduce the depositor's credited contribution and shares;
   `minimum_shares` limits that cost. A priority-gas surcharge, if charged by the
   venue, also reduces actual contribution; the sizing projection uses the ordinary
   taker fee. Ordinary deposits retain proportional sizing.
7. Keep `admin_fee` as Vault admin cash; deposit and allocate the rest
   (`deposit - admin_fee`) to the position.
8. Place immediate-or-cancel limit orders in the Vault's direction, priced at
   the oracle moved by `max_slippage_bps` against the order, until exactly
   `base_to_buy` is filled: each order at most the whole-lot base worth
   `max_order_notional` at the highest admitted execution price (with one
   extra normalized price atom for sell rounding), at most 16 orders, each fill
   checked for no resting order, no liquidation, whole lots, actual collateral
   notional at or under `max_order_notional`, and execution price within
   `max_slippage_bps` of the oracle price. A thin book fills part of an order
   and the next order carries the rest; an order that fills nothing aborts
   inside Aftermath.
9. Re-price at the same oracle pair and credit shares (see Economics). Check
   `shares >= minimum_shares`, post-mint NAV at or under `nav_cap`, post-mint
   leverage inside both inclusive rebalance-band edges, using final equity and
   the final reserve after fee credit and clamping, and
   that existing holders' NAV per share did not fall.
10. Mint shares, store the new checkpoint, emit `Minted`.

#### Redeem (anyone)

PTB:

1. Select the `Coin<BlastBoost<Product>>` to burn (split or merge first; any
   positive amount below total supply).
2. `operations::redeem<Product, Collateral>(vault, protocol, account, registry,
   clearing_house, base_oracle, collateral_oracle, shares, minimum_collateral,
   deadline_ms, clock)`. Returns `(Coin<Collateral>, ClearingHouse<Collateral>)`.
3. Reuse the returned market, then call Aftermath `clearing_house::share`.
   `TransferObjects` the collateral to the user.

What happens: the same generation, lifecycle, deadline, synchronize and price
checks as mint (no band check: redemptions work outside the band). The Vault
sells the proportional position reduce-only:
`max_final_base = floor(base * (S - x) / S)`,
`required = base - max_final_base` (at least `lot_size * min_order_lots`
unless `max_final_base` is 0), and `base_to_sell = min(required rounded up to
whole lots, base)`. Orders are limit orders priced inside the ordinary bound
and face the order cap, with an exception for exactly one live venue lot
when closing (see Caps).
It then prices the payout (see Economics), checks `net >= minimum_collateral`
and that the venue can release `net + admin_fee` (adapter code 39 otherwise),
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

#### Realize profit before redemption (anyone; keepers)

`operations::realize_profit<Product, Collateral>(vault, protocol, account,
registry, clearing_house, base_oracle, collateral_oracle, clock)` is a private
`entry` call. Pass the shared market directly; the call shares it internally
and returns nothing. Submit at or below reference gas price. The keeper builder
accepts `operation: 'realize_profit'` with the same bound objects as `rebalance`.

Share value includes paper gains; Aftermath excludes them from cash available
for withdrawal. When free and allocated cash cannot cover the live initial
margin requirement, this operation closes and reopens exactly the same bounded
portion to turn gains into cash. It selects size from authenticated shortfall,
positive profit, live fee, lot size and the existing cap. The caller chooses no
trade size or price bound and receives no reward.

The full cash gap plus rounding headroom must fit within total profit minus a
full-position cost allowance, or recovery is refused before trading. Both orders
must fill fully within ordinary price limits and the opening-order cap. Either failure rolls back everything. Estimated realized profit must exceed
twice the worst-case trading cost; completion requires a smaller cash shortfall,
an allocated-cash gain greater than actual cost, unchanged position size and
side, and final leverage at or below the hard cap. Supply, reserve, funding
deficit, admin cash and lifecycle are unchanged after initial funding settlement.
Actual costs reduce share value for all holders before a fresh redemption quote.

Repeat in separate transactions if the cap requires several steps. Each step
spends cost headroom; a later code 65 stops the sequence until cash, prices or
exposure improve, and raising the cap alone does not remove that check. Quote and
submit redemption afterward with a fresh minimum payout; it still closes exactly
the holder's proportional position and pays the full agreed amount. The cash
check never silently reduces that payout. Recovery may fail for insufficient
two-sided depth, uneconomic profit, inadequate opening margin, emergency leverage
or stale prices. Prices, funding and cash requirements can change before the
later redemption. Reducing maintenance and initial-margin admission are separate from this round trip;
this call does not bypass either. See ADR 0122 and its live execution release gate.

#### Rebalance (anyone; keepers)

`operations::rebalance<Product, Collateral>(vault, protocol, account, registry,
clearing_house, base_oracle, collateral_oracle, clock)`. Anyone can submit this
private `entry` call directly in a PTB. It shares the clearing house internally
and returns nothing; no earlier trading session may supply its market and no
later command may reuse that market. Use a separate transaction for another
rebalance or a mint on the same market. No reward, direction or size argument.
Ordinary rebalances require a gas price **at or below the reference gas
price** (adapter code 35 otherwise). A rebalance whose authenticated starting
leverage is strictly above `max_leverage_bps` may use a higher gas price.
Holders pay Aftermath's configured priority trading surcharge on those fills.
The caller pays the network gas bill. The extra trading rate is set by the
venue; it does not grow with the gas bid.

1. Generation, `Active`; synchronize the checkpoint and validate prices,
   side, positive shareholder NAV, no resting orders and an operational venue.
   The core chooses the direction. An increase requires opening margin; a
   reduction does not, including an ordinary reduction below the hard cap.
2. Read the ordinary market taker fee, rounded up to whole bps (rebates count
   as zero), and prepare the plan. Require leverage strictly outside the band
   (core code 54 otherwise): `notional * 10,000 < N * rebalance_below_bps`
   (increase) or `notional * 10,000 > N * rebalance_above_bps` (reduce).
   Band edges are healthy. A position with no sizeable first order
   aborts early with core code 67 (`rebalance_not_actionable`).
   Mark-versus-oracle divergence is checked only for ordinary plans. Emergency
   status is derived after validating the oracle pair, side and positive NAV;
   the keeper readiness hint uses the same rule.
3. Check the gas price against that prepared plan. Only a plan starting
   strictly above the hard cap is exempt; exactly at the cap is ordinary.
   The decision is fixed for the transaction: its own fills cannot promote an
   ordinary plan into an emergency. Invalid observations and inside-band
   positions can therefore abort before the gas-price check.
4. Up to 16 limit orders, using the core-owned rebalance budget (core code 70
   rejects an additional accepted fill), each priced at the oracle moved by its bound
   against the order. Increase: each order is the largest whole-lot buy that
   keeps post-cost leverage at or under target, using the reserve admitted at
   the resulting total notional and reserving adverse slippage
   (`max_slippage_bps`) and the taker fee on it, capped at
   `max_order_notional`; each fill must leave leverage at or under target and
   under max. If no whole lot fits under target while the position is below
   the band, exactly one lot may instead land inside the full band. Conservative
   cost and resulting-reserve sizing must admit it, and the actual fill must pass both band edges
   (core code 68 otherwise).
   This exception retains the ordinary price bound and order cap.
   Each increase fill and completion recomputes the admitted reserve at its
   actual notional before checking target or the sealed one-lot band exception.
   The recorded reserve is not clamped by rebalance.
   Reduce: size toward target using the reserve admitted at the remaining
   position, capped per order and rounded to whole lots, under
   `max_slippage_bps`. A plan starting above `max_leverage_bps` instead sizes
   toward that hard cap under `emergency_max_slippage_bps`. Target sizing
   uses current equity without a projected cost deduction to avoid excess
   selling on cheaper fills; every subsequent order uses actual fill equity.
   Each emergency order also limits bounded price cost plus the ordinary
   taker fee below current admitted NAV, protecting partial fills as well as
   full fills. The cost allowance also covers one normalized oracle-price
   atom per base unit, its fee, and three collateral atoms for equity capture
   rounding. Recompute that limit after every fill. If no lot fits that
   conservative limit, exactly one lot may use its own reserve release only
   when its resulting NAV remains positive. Stop when no affordable lot
   remains, or when actual leverage is no longer above max; a later ordinary
   call reduces toward target. A final close to zero must leave
   positive holder value after reserving adverse slippage, the ordinary taker
   fee, the same oracle-price precision and capture-rounding allowances, and
   the full recorded reserve. These allowances apply to ordinary flat closes too. Otherwise leave one lot and stop when
   no further close is sizeable; priority-gas costs can still prevent a fill.
5. Every fill repeats the corresponding admission: increases require opening
   margin; reductions may remain below it. An emergency plan keeps its mark-
   divergence exemption through the final cap-restoring fill; fresh oracle
   prices, side and positive NAV are still required. An ordinary plan cannot
   gain this exemption through its own fills, and a later ordinary call must
   pass the divergence check again. Exact fill and checkpoint proofs,
   price limits and execution caps remain enforced. A bounded reduction may
   commit partial recovery without restoring opening margin in one call.
   Require at least one fill. An increase must raise base and actual leverage.
   An emergency plan must lower both base and oracle-valued notional; partial
   fills may complete while still above the hard cap even if actual costs
   worsen leverage. Positive holder value remains required against the reserve
   admitted at the final position. Ordinary reductions must lower base and
   move leverage at least `min_leverage_improvement_bps` toward target or land
   within one lot of target without moving away (core code 55).
   An ordinary reduction may instead fill all 16 orders in full and finish
   at least as close to target as a conservative projection, with strict net
   progress. Core records whether each fill matched its order and fresh
   sizing. The projection repeats sizing and charges adverse slippage and
   authenticated taker fees per order, repricing the admitted reserve at each
   remaining position. Exact comparisons preserve progress below one basis
   point. Tiny ordinary partial fills do not qualify simply by exhausting
   the order count; a smaller retained order cannot misrepresent a full fill.
   Emergency exposure reduction does not guarantee better leverage or margin.
   An order with no fill still aborts the adapter transaction, including its
   earlier fills; the progress rule does not guarantee liquidity.
6. Store the checkpoint; emit `Rebalanced`. Reserve, supply and admin cash do
   not change; execution cost lowers NAV.

Dry run: `operations::needs_rebalance<Product, Collateral>(vault, protocol,
account, registry, clearing_house, base_oracle, collateral_oracle, clock)`
takes every object by immutable reference and returns `bool`. Run it with
dev-inspect. It returns true for a needed, sizeable reduction even below opening
margin, and for an increase only with opening margin and a nonzero fee-aware
order. Inside the band, when a proposed increase lacks opening margin, or when
whole-lot sizing cannot produce an order, it returns false. A final reduction
that cannot retain the full reserve and positive holder value is not sizeable;
neither is an emergency close with no affordable lot. Unexplained drift, invalid prices, unusable fees,
an insufficient opening cap and an unavailable venue still abort. This is a hint:
it does not settle funding or prove gas admission, liquidity or fill progress;
the real call checks them and can still abort.

The off-chain `keeperDecision` helper returns `inspect_rebalance` for an
outside-band observation. This is only a pre-filter: confirm the on-chain hint
before submitting; it does not authorize a rebalance.

Keeper loop: when dev-inspect returns `true`, submit ordinary `rebalance` at
the reference gas price. Above the hard cap, a higher bid can compete during
congestion. Eligibility is checked again on chain after funding synchronization:
if another keeper has restored the cap, a priority-priced call is refused.
Inside the band, the call aborts with core code 54; rebuild from current
objects. Resolve an uncertain digest before retrying. Ordinary rebalances can
still be delayed by higher-priced traffic.

#### Sync health (anyone)

`operations::sync_health<Product, Collateral>(vault, protocol, account,
registry, clearing_house, base_oracle, collateral_oracle, clock)` with the
`ClearingHouse` by mutable reference. Works in `Active` and `Unwinding`.

It refreshes due funding, settles the position's funding, and reconciles with
the accepted checkpoint without pricing anything. An explainable change books
funding to the reserve, adopts the new checkpoint and emits `FundingSettled`
(once per distinct checkpoint; an identical retry emits nothing). A change to
the market's pause mode, frozen flag or market-wide margin ratios is venue
policy, adopted the same way with a zero funding delta; the lot size and every
account, position, order and position-margin field must be exact. Anything
else leaves the accepted checkpoint in place and emits `CheckpointDrifted`;
every drifted sync emits it again. Blast adds no price, margin or drift check
to this call; a binding mismatch aborts.

#### Recover a reviewed forced reduction (Blast admin: RiskAdmin)

`operations::rebaseline` takes the Vault, Protocol, a live
`AdminWitness<RiskAdmin>`, bound account, registry, clearing house, both current
oracle storages and Clock. The clearing house is borrowed mutably; no object or
coin is returned. An administrator obtains the witness through the shared ACL
earlier in the same PTB, then calls this function. Recovery is Active-only.

The call refreshes funding and captures immediately before and after settlement.
The final position must be strictly smaller on the same side or exactly flat
with zero entry quote. Allocated collateral may reflect realized profit or loss;
free cash, lot size and position IMR cannot change; stored and final checkpoints
must have no orders. Final funding snapshots must be current. Fresh-price,
representation, correct-side, operational-venue and positive shareholder-NAV
checks apply. Recording recovery needs no opening-margin headroom; normal
increasing trades retain their opening-margin checks; reducing rebalances use
the recovery admission described above.

The administrator supplies no replacement numbers and must review venue history:
the shape alone does not prove liquidation. `CheckpointRebaselined` records
stored state to the capture before local funding. Any local settlement must
match the ordinary funding calculation exactly; it is booked under normal
reserve/deficit rules and emitted as a following `FundingSettled` to the final
checkpoint. Process both events in transaction order. Historical mixed PnL,
fees and funding remain in holder NAV without inventing a reserve entitlement.
Supply, admin cash, fee settings and lifecycle stay unchanged. Subsequent
operations price the actual remaining position. An identical retry aborts.

A free-cash change, changed lot or position IMR, unexplained orders or a loss
without a position reduction is outside this recovery path. Insolvency, stale
prices and paused/frozen markets still block recovery. The independently
authorized shutdown path remains available. See ADR 0121 for the auditor
recommendation adopted, explicit extensions and release evidence limits.

#### Donate (anyone)

`operations::donate<Product, Collateral>(vault, protocol, account, registry,
clearing_house, base_oracle, collateral_oracle, cash, clock)`, `Active` only,
`cash` positive. It synchronizes (drift aborts), deposits the coin into the
Vault's Aftermath account and immediately allocates that amount to its
position, proves the exact allocated deposit, and
adds it to the maintenance reserve clamped to the reserve ceiling. Any excess
over the ceiling raises shareholder NAV. A partial donation can complete while
opening margin remains insufficient; valid prices, accounting and the other
active checks still apply. No shares, no fees. Emits `Donated`.

#### Shutdown

1. **Begin** (Blast admin: ShutdownAdmin).
   `blast_boosts_aftermath::vault::begin_shutdown(vault, protocol, witness,
   reason, clock)` with `reason` from `lifecycle::emergency_reason()` or
   `lifecycle::observed_venue_change_reason()` (an operator's label, never an
   on-chain liquidation verdict). Needs no venue or oracle object; the `Clock`
   fixes when shutdown began. Moves
   `Active` to `Unwinding`, emits `ShutdownBegun`. Mint, redeem, rebalance and
   donate stop.
   Alternatively, anyone may call `operations::begin_protected_shutdown(vault,
   protocol, account, registry, clearing_house, base_oracle, collateral_oracle,
   clock)`. It authenticates a raw, accepted, order-free checkpoint and native
   supply. If even burning all circulating shares fails the ordinary minimum
   order, it starts protected closure and emits `ProtectedShutdownBegun`. Flat,
   seed-only and ordinary-exitable positions are rejected. It reads no live
   prices and requires neither positive NAV nor opening margin; unexplained
   account drift must first be reconciled. Market pause/freeze, margin policy
   and cumulative rates may change without synchronization; the trigger adopts
   them. If another caller has already settled account funding, run `sync_health`
   first while the venue permits it, then the trigger (in the same transaction
   if desired). The offline planner leaves this optional: unconditional sync
   would block closed markets. Entry places no trade and pays no reward.
2. **Unwind** (anyone, repeat until flat). `operations::unwind<Product,
   Collateral>(vault, protocol, account, registry, clearing_house, base_oracle,
   collateral_oracle, clock)`. Any gas price is allowed, including a higher
   bid to compete during congestion. Holders pay the venue's priority trading
   surcharge on those fills; the caller pays network gas. The call is refused
   while the clearing house is frozen (adapter code 33). This private `entry`
   call shares the clearing house internally and returns nothing. Pass the
   shared market directly, without a preceding trading session. Repeat unwind
   and finalize in separate transactions because the market cannot be reused
   after this call.
   - Live market: synchronize (drift is reported with `CheckpointDrifted` and
     the live venue state is adopted anyway), price at fresh oracles, then up
     to 16 reduce-only limit orders under the order cap (with the one-lot
     closing exception described in Caps) and a bound that
     starts at `max_slippage_bps` when shutdown begins and widens linearly to
     `emergency_max_slippage_bps` over the following 24 hours, where it stays.
     Emits `OrderFilled` per order and `UnwindProgress`. Positive NAV and the
     reserve do not gate it. A flat position aborts (adapter code 32): go to
     finalize.
   - Market paused by Aftermath: once Aftermath has enabled positive
     settlement prices, the step closes the position at those prices without a
     venue order (`UnwindProgress` with `market_orders = 0`,
     `filled_quote = none`). Before that it aborts (adapter code 33).
3. **Finalize** (anyone). `operations::finalize_shutdown<Product,
   Collateral>(vault, protocol, account, registry, clearing_house, base_oracle,
   collateral_oracle, clock)`. Requires exactly zero base and quote, no orders,
   position funding snapshots equal to the market's (funding fully settled),
   and nonnegative allocated collateral. It withdraws all free collateral plus
   the whole-atom floor of allocated collateral, leaving only a raw remainder
   below one atom at the venue. It sets `Settled`, zeroes the reserve book
   entry, and seals the holder allocation as `terminal_cash`. Protected closure
   first segregates reserve and seed cash with no exposed withdrawal path; administrator-approved
   closure retains its existing allocation, including admin cash when no
   eligible shares exist. Emits `ShutdownFinalized`, including both protected
   amounts (explicitly zero for admin shutdown). If position funding is
   not fully settled it aborts with adapter code 33; on a live market, settle
   it first, for example with `operations::sync_health` earlier in the same
   PTB.
4. **Claim** (any holder). `blast_boosts_aftermath::vault::redeem_shutdown<Product,
   Collateral>(vault, protocol, shares, minimum_collateral, deadline_ms,
   clock)` returns `Coin<Collateral>`. No venue, oracle or fee. Emits
   `ShutdownRedeemed`.

#### Admin settings (Blast admin)

Each needs `Protocol` and the role witness. The order-cap update also needs
venue objects and prices.

| Call | Role | Effect | Event |
| --- | --- | --- | --- |
| `blast_boosts_aftermath::vault::set_fees(vault, protocol, witness, mint_fee_bps, redeem_fee_bps, admin_share_bps)` | RiskAdmin | Sets all three live rates within the policy caps; at least one must change; `Active` only. Affects only future operations. | `FeesUpdated` |
| `blast_boosts_aftermath::vault::set_nav_cap(vault, protocol, witness, nav_cap)` | RiskAdmin | Replaces the NAV cap (positive, changed, and `nav_cap * max_leverage_bps / 10,000` fits in `u64`, and the rebalance capacity bound holds); may be set below current NAV, which only blocks mints. Any lifecycle. | `NavCapUpdated` |
| `operations::set_max_order_notional` | RiskAdmin | Replaces the per-order cap in collateral atoms. Takes the bound account, registry, market, both oracle objects and Clock; requires fresh prices and capacity for `min_order_lots` live lots under the ordinary execution bound. Positive and changed; must also preserve the rebalance capacity bound. Any lifecycle, no cooldown, no current-NAV or margin gate. | `MaxOrderNotionalUpdated` |
| `blast_boosts_aftermath::vault::withdraw_admin_fees(vault, protocol, witness, amount)` | RiskAdmin | Returns `Coin<Collateral>` from admin cash only. Any lifecycle. | `AdminFeesWithdrawn` |
| `blast_boosts_aftermath::vault::update_metadata(vault, protocol, witness, currency, name, description, icon_url)` | VaultIssuer | Updates the share coin's name, description and icon in its Coin Registry `Currency<BlastBoost<Product>>`; the symbol is fixed. At least one must change. | `MetadataUpdated` |
| `operations::add_partner(protocol, witness, partner)` | RiskAdmin | Accepts a `Partner` at once, or cancels its pending removal. | `PartnerAdded` |
| `operations::remove_partner(protocol, witness, partner, clock)` | RiskAdmin | Partner stays accepted until `now + blast_partners::blast_partners::delay_ms()` (seven days). | `PartnerRemoved` |

Upgrades: at deployment, the holder of the adapter's Publisher and UpgradeCap
calls `blast_boosts_aftermath::package_admin::wrap` to seal them into the shared
`PackageAdmin`. A Blast admin signs in with the UpgradeAdmin role, then calls
`blast_boosts_aftermath::package_admin::authorize_upgrade` for one digest. Its
`UpgradeTicket` feeds the native upgrade command, whose `UpgradeReceipt` feeds
`blast_boosts_aftermath::package_admin::commit_upgrade` in the same transaction.
Commit needs no second witness: the receipt binds the authorized upgrade to the
same cap. Neither operation checks or changes `Protocol`, so repair remains
possible during a version mismatch.

In a follow-up transaction a Blast UpgradeAdmin calls the new package's
`blast_boosts_aftermath::package_admin::activate_upgrade` with the shared
`Protocol` and a fresh witness. It accepts only the running code's compiled
generation equal to the active generation plus one. A wrong build cannot
advance it; the previous generation remains usable. Successful activation emits
`blast_admin::blast_admin_events::OperationalVersionAdvanced` and rejects older
operational generations on ordinary paths. The native upgrade count may exceed
the active generation after a failed attempt; they are separate values.

There is no policy-narrowing path. A Blast UpgradeAdmin may permanently destroy
the cap through `blast_boosts_aftermath::package_admin::make_immutable`, but only
from code matching the active generation. This proves a version match, not the
absence of other bugs or that this is the latest installed package. Historical
repair-authorization paths still require the live ACL role; changing the active
generation does not revoke that role. The core package is immutable.

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
  checks cross-multiply exactly, without rounding. Mint must start and finish
  inside the band; the final comparison uses final equity and final reserve.
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

A credit must leave the stored reserve within `u64`; the amount restored to
holders does not count against that reserve limit. The old reserve plus the
full credit may exceed `u64` when the restored amount makes the final reserve fit.

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
- Order cap: each order reserves the highest price allowed by its execution
  bound plus one normalized price atom to cover sell rounding, then rounds
  size down to whole lots. Each fill checks actual collateral notional
  (excluding fees) against `max_order_notional`. Opening orders obey the cap
  strictly. A reduce-only fill of exactly one live venue lot may exceed it;
  that fill must still pass the same execution-price check. With 16 orders per call,
  one mint can add at most about `16 * max_order_notional` of notional, so the
  largest single mint is roughly `16 * max_order_notional / leverage`.
- Rebalance progress: issuance and both cap setters reject a configured
  minimum larger than the optimistic effect of 16 cap-sized orders at
  `nav_cap`. Actual NAV can exceed that ceiling. The full-batch completion
  rule above permits smaller, cost-adjusted ordinary progress when capacity
  is the limit. Emergency progress requires actual exposure reduction and
  positive holder value, even if costs worsen leverage. Neither rule promises
  liquidity. A final lot that cannot retain the full reserve may need shutdown.
- Minimum size: a mint or a non-flat redemption must move at least
  `lot_size * min_order_lots` of base. At initialization and each cap change,
  the cap must cover that minimum in one order at current prices. Later price
  or lot growth can block openings (core code 63) or make a normal redemption
  exceed the 16-order budget. RiskAdmin can raise the cap. ShutdownAdmin can
  instead begin shutdown, after which anyone can repeat unwind calls in
  separate transactions. Closing still needs fresh prices and executable
  liquidity inside the bound; a venue freeze or other venue restriction can
  block it.

#### Shutdown payouts

```text
eligible = total_supply - locked_shares
payout   = floor(terminal_cash * shares / eligible)
```

For permissionless size-locked closure, finalization first allocates:

```text
protected_reserve = min(actual_recovered_cash, full_recorded_reserve)
share_cash = actual_recovered_cash - protected_reserve
terminal_cash = floor(share_cash * eligible / total_supply)
protected_seed = share_cash - terminal_cash
```

Both protected amounts stay in the upgradeable adapter's `protected_cash`,
including after all holder claims. No holder or admin withdrawal path exists
under this code; upgrade governance remains a trust assumption (ADR 0130).
Closing losses may exhaust holder cash; this does not guarantee seed capital.
The full recorded reserve is retained under the flat-position policy, rather
than releasing the last open position's excess reserve to holders (ADR 0130).
A closed-market settlement can include funding that was not separately booked
into the reserve; recovery stays exact, but protection then uses the last
recorded reserve. Already-settled account funding followed by a market pause
can also block protected entry until reconciliation becomes available.

No fee. The last claimant (shares equal to all eligible supply) receives all
remaining **holder-pool** cash, dust included. A partial claim that rounds to zero while cash
remains aborts; combine shares. If `terminal_cash` is zero, a burn with
`minimum_collateral = 0` succeeds and returns a zero coin. If no eligible
shares remain at administrator-approved finalization, recovered cash becomes
admin cash. Administrator-approved closure distributes recovered reserve and
seed-backed cash to circulating holders when any exist; protected closure
does not. Admin cash never enters the holder pool.

### Time rules

- `deadline_ms` (mint, redeem, partner variants, `redeem_shutdown`):
  inclusive; `Clock` time greater than it aborts (adapter code 28).
- Price freshness: each oracle's publish time must lie in
  `[now - max_price_age_ms, now + max_price_ahead_ms]`, inclusive. Older aborts
  with core code 27; further ahead aborts with core code 28. The confidence
  gate always passes because Aftermath feeds carry no confidence interval. The
  venue mark must be within `max_mark_divergence_bps` of the base oracle price
  (core code 31) for priced operations except emergency rebalance reductions.
  That exception lasts through the final cap-restoring fill; unwind also skips
  the mark check. Both oracle legs still require valid, fresh prices.
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
| Admin cash, holder cash after shutdown, protected cash | Vault `admin_cash`, `terminal_cash`, `protected_cash`. |
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
| `OrderFilled` | every Aftermath order (seed, mint, redeem, profit realization, rebalance, unwind) | `account_object_id` (map to the Vault through the binding), side, reduce-only, requested and filled base, raw quote, 9-decimal reference price, limit price and executed price. The limit sits inside the bound the order ran under. |
| `Minted` | `mint` | deposit, shares, contribution, fee, admin and reserve fee, reserve, admin cash and supply after, checkpoint. |
| `Redeemed` | `redeem` | shares burned, net paid, fee split, reserve, admin cash and supply after, checkpoint. |
| `PartnerFeePaid` | partner variants, after `Minted` or `Redeemed` | partner ID, the operation's admin fee, the partner's cut. `admin_cash_after` in the preceding event still includes the cut. |
| `PartnerAdded`, `PartnerRemoved` | partner list changes | `accepted_until_ms` on removal. |
| `ProfitRealized` | `realize_profit` | vault ID, equity before/after, base closed and reopened, cash shortfall before/after, previous and new raw checkpoint. |
| `Rebalanced` | `rebalance` | equity and base before and after, direction. Equity change is the execution cost (or gain) at the fixed pair. |
| `FundingSettled` | any synchronization (`sync_health`, mint, redeem, profit realization, rebalance, donate, unwind) that adopts a changed checkpoint | cost or credit, raw IFixed and atom amounts (atoms may be 0), absorbed, uncovered, restored, reserve after, previous and new checkpoint. |
| `CheckpointRebaselined` | RiskAdmin `operations::rebaseline` | vault ID, stored checkpoint and capture before local funding; a following `FundingSettled` carries any local settlement to the final checkpoint and reserve. |
| `CheckpointDrifted` | `sync_health` or `unwind` that finds unexplained venue state | After `sync_health` the accepted checkpoint stands and priced operations abort until ordinary synchronization or RiskAdmin recovery accepts it; `unwind` adopts the live state and closes it. |
| `Donated` | `donate` | amount, reserve after. |
| `ShutdownBegun` | `begin_shutdown` | declared reason. |
| `ProtectedShutdownBegun` | `begin_protected_shutdown` | accepted raw checkpoint, total supply and locked shares. |
| `UnwindProgress` | `unwind` | adopted before checkpoint, after checkpoint, orders placed (`market_orders`), filled quote (`none` for settlement-price closes). |
| `ShutdownFinalized` | `finalize_shutdown` | total recovered cash, eligible supply, final checkpoint, raw unrecoverable remainder (below one atom), protected reserve and seed cash (both zero for admin shutdown). Subtract protected cash to replay the holder pool. |
| `ShutdownRedeemed` | `redeem_shutdown` | shares, cash paid, cash and eligible supply remaining. |
| `FeesUpdated`, `NavCapUpdated`, `MaxOrderNotionalUpdated` | admin calls | previous and new values. |
| `MetadataUpdated` | `update_metadata` | the new name, description and icon URL. |
| `AdminFeesWithdrawn` | `withdraw_admin_fees` | amount withdrawn and admin cash remaining. |

An indexer can rebuild supply, reserve and admin cash from the `*_after`
fields plus `FundingSettled`, `Donated`, `PartnerFeePaid`,
`AdminFeesWithdrawn`, `ProtectedShutdownBegun`,
`ShutdownFinalized` and `ShutdownRedeemed`, execution
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
| 0-1, 11-15, 17-18 | Deployment, issuance, activation input or seed problems | Issuer only. |
| 2-8 | An Aftermath object (account, registry, clearing house, oracle storage or feed) is not the bound one | Pass the objects from the Vault's binding. |
| 9 | The venue's price is not the bound feed's | Same; use the bound feed storage. |
| 10 | A venue value cannot be represented, or its collateral haircut is outside the supported range | Inspect account equity and venue rates. |
| 16 | Initial margin is outside (0, 1], below the market minimum, or changed while seeding | Correct issuance settings; the exchange minimum applies. |
| 19 | Zero coin or amount | Pass a positive coin. |
| 20 | Admin withdrawal above admin cash | Lower the amount. |
| 21 | A cash move did not match the venue exactly | Retry; the venue changed mid-transaction. |
| 22, 23, 24 | Fill not whole-lot, a resting order left, or a liquidation during the order | Retry later; the book or margin did not support the order. |
| 25 | The operation needed more than 16 orders | Trade a smaller amount or wait for a larger order cap. |
| 26 | Deadline passed | Use a later `deadline_ms`. |
| 27 | A fill changed venue fields it should not | Retry. |
| 29 | The market's trading fee is not a usable rate (initialization, rebalance or profit realization) | Wait; venue configuration. |
| 30 | Unaccepted account change since the checkpoint | Before protected entry, use `sync_health` for already-settled attributable funding while the venue permits it. For unexplained drift inspect `CheckpointDrifted`; RiskAdmin may recover an admitted forced reduction with `operations::rebaseline`. |
| 31 | Terminal step not possible: orders open, funding unsettled, settlement prices not enabled, or wrong order count | Settle funding with `sync_health` first, or wait for Aftermath. |
| 32 | Unwind or protected entry found no exact whole-lot position on the bound side (including flat) | During Unwinding, finalize if fully settled. During Active, protected entry is unavailable; use the applicable ordinary or admin recovery path. |
| 33 | Venue not ready: resting orders, paused/frozen market, or insufficient opening margin on a strict path | Reductions and donations need no opening margin; other guards still apply. |
| 34, 37 | Metadata or partner list update changes nothing | Admin only. |
| 35 | Ordinary rebalance or profit realization above the reference gas price | Submit at the reference gas price. |
| 36 | Partner not accepted | Use the plain call. |
| 38 | Recovery does not match the admitted forced-reduction shape | RiskAdmin must review the venue event; recovery cannot accept arbitrary drift. |
| 39 | Redemption payout exceeds cash the venue can release | Realize profit first when eligible, then obtain a fresh quote; never discount the agreed payout. |
| 40 | Profit realization did not sufficiently improve cash | Wait for better execution or cash conditions. |

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
| 31 | Venue mark too far from the oracle for an operation requiring that check | Retry later; emergency reductions and shutdown closes are exempt from this check only. |
| 35 | Fewer shares than `minimum_shares` | Re-quote; raise slippage tolerance. |
| 36 | Post-mint NAV above `nav_cap` | Mint less or wait. |
| 37 | A fill's price outside the execution bound, or no tick inside it | Trade smaller or wait for depth. |
| 43 | A fill's actual notional above `max_order_notional`, outside the one-lot reduce-only exception | Trade smaller. |
| 49 | Leverage before or after mint is outside the band | Dry-run another amount. Rebalance first only if the current position is outside the band. |
| 50, 51 | Oracle pair or fills changed within the operation | Retry. |
| 52 | A rebalance buy left leverage above target or at or above max | Retry later. |
| 53 | Payout below `minimum_collateral` | Re-quote. |
| 54 | Rebalance while inside the band | Nothing to do. |
| 55 | Rebalance made no admissible progress | Wait for depth or a better price. |
| 63 | Cap cannot cover one opening lot, or a configured cap cannot cover `min_order_lots` live lots | RiskAdmin must raise the cap; shutdown closes retain the one-lot exception. |
| 64 | No positive cash shortfall or profit to realize | No recovery trade is needed or possible. |
| 65 | Profit realization is uneconomic or exceeds its cost allowance | Wait for better prices or sufficient profit. |
| 66 | Initial margin leaves no cushion under the issuance policy and live venue rates | Choose compatible issuance settings before activation; the venue minimum still applies. |
| 71 | Permissionless shutdown found no exact redemption size lock | Use an ordinary exit or reconcile the position first; seed-only positions are ineligible. Flat or malformed base aborts earlier with adapter code 32. |
| 17, 23, 39, 40, 47, 48, 58 | Admin transition or setting rejected (wrong state, invalid, above cap, unchanged) | Admin only. |

### Pitfalls

- Passing an Aftermath object other than the bound one. Always read the binding.
- Setting `minimum_shares` or `minimum_collateral` to 0 in production. The
  mint floors shares and execution costs vary; set a floor from a fresh dry run.
- Expecting to mint at any time. Mints abort if starting or final leverage is
  outside the band (49), above the NAV cap (36), or while the checkpoint is
  drifted (32). A minimum-sized mint is not guaranteed to pass. At an exact
  band edge, a rounded mint may fail while rebalance remains unavailable.
- Tiny trades. Mints and redemptions below `lot_size * min_order_lots` of base
  abort (12). If every accessible ordinary burn fails this size guard, anyone
  can begin protected closure with `begin_protected_shutdown`. Positive-cash
  shutdown claims that round to zero abort (8).
- Large trades. More than 16 orders, a fill outside `max_slippage_bps`, an
  order that finds nothing to fill inside its limit (Aftermath aborts the empty
  session), or a fill above the cap outside the one-lot closing exception
  aborts the whole transaction.
- Submitting an ordinary `rebalance` with a priority gas price (35).
  Emergency rebalances and `unwind` permit it, and holders bear the extra
  venue trading fee. Venue priority support, usable liquidity and the existing
  price, margin and progress checks still apply; permission to bid higher is
  not a guarantee of execution. For mint and redeem, a higher gas price is
  allowed and the user pays the extra trading fee through fewer shares or a
  lower payout.
- Reading `CheckpointDrifted` from a failed mint: aborted transactions emit
  nothing. Only `sync_health` and `unwind` record drift. Drift from a
  lasting account change does not clear on its own. RiskAdmin can recover an
  admitted forced reduction; other drift may require ShutdownAdmin to shut
  the Boost down. Market-wide margin changes are accepted automatically.
- Decoding an abort by code alone. Core and adapter codes overlap.
- Calling an old adapter generation after activation (blast_admin code 13). Types
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
the returned coin and re-share the returned clearing house after its final
use. With a partner code call
`operations::mint_with_partner` and put the `Partner` after `Protocol`.

**How many shares will I get?** `floor(S * contribution / N)`, where
`contribution` is your deposit minus the mint fee, reduced by any execution
cost, and `N` is shareholder NAV before your mint. The exact figure depends on
fills, so dry-run the PTB and set `minimum_shares` just below the result.

**What fees do I pay?** The live mint or redeem fee, rounded up, plus Aftermath
taker fees and slippage on the Vault's orders. The fee splits into a reserve
part (stays in the Vault for holders) and Blast's admin part. A partner code
changes nothing for the user.

**Why did my mint abort with code 49 in `state`?** Starting or final leverage
was outside the rebalance band. The whole transaction rolls back; gas is still
payable. Dry-run a different amount. Anyone can rebalance an already out-of-band
position first, but an exact band edge does not allow rebalance.

**Who rebalances, and is there a reward?** Anyone, through
`operations::rebalance`. Ordinary calls require a gas price at or below the
reference; emergency reductions starting strictly above the hard cap permit
higher bids. There is no reward, role or size argument; the chain derives
direction and size and holders pay the fills, including any priority trading
surcharge. Use `operations::needs_rebalance` in dev-inspect to decide when to
submit.

**How do I read NAV and leverage?** NAV is not stored. Compute
`N = E - min(maintenance_reserve, notional * max_reserve_bps / 10,000)` from
the Aftermath position at the oracle prices, and leverage as `notional / N`.
For an exact quote, dry-run the mint or redeem and read `Minted` or
`Redeemed`.

**What does the maintenance reserve do?** It is collateral in the venue account
that share pricing excludes. Funding costs consume it before holders bear
them, mint and redeem reserve fees refill it, and donations add to it. It is
capped at `max_reserve_bps` of notional; anything above counts as holder NAV.

**What happens on shutdown?** Blast's ShutdownAdmin calls `begin_shutdown`,
or anyone proves a size lock through `begin_protected_shutdown`. Anyone then calls `operations::unwind` until flat and
`operations::finalize_shutdown`. Holders call
`blast_boosts_aftermath::vault::redeem_shutdown` for a fee-free pro-rata share
of the holder cash pool. Permissionless size-locked closure
retains reserve and seed cash separately with no holder or admin withdrawal
path; the adapter remains upgradeable. The last claimant gets only the
holder pool's dust. Administrator-approved closure retains its original payout.

**Can a Boost be liquidated?** The Aftermath position can be. The Vault never
declares liquidation on chain; a liquidation appears as `CheckpointDrifted`,
priced operations stop, and RiskAdmin may recover the admitted reduction shape
once the remaining position is healthy. Otherwise ShutdownAdmin may shut the
Boost down so holders can claim what remains.

**Is there a testnet deployment?** No. Blast deploys Boosts on Sui mainnet only.
