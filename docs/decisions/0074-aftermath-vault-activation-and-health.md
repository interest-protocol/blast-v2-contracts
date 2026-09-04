# 0074: Aftermath Vault activation and health evidence

- Status: **accepted for dependency and raw-field normalization**
- Date: 2026-09-04
- Extends: [0064](0064-aftermath-backed-leverage-coins.md)
- Preserves the package ownership decision in
  [0073](0073-series-one-adapter-owned-vaults.md)

## Context

The issued Aftermath `Vault<Product>` is inert. Before it can hold collateral,
the adapter needs one immutable external dependency graph and one reproducible
interpretation of every raw Aftermath value used by activation and health
reconciliation. A local interface build is not evidence that the deployed
package still has the reviewed lineage or ABI.

The official `AftermathFinance/move-interfaces` package is the callable
semantic and ABI contract. Its local `abort 404` bodies are link stubs, not
implementations for unit tests. Blast calls the named getters and IFixed
conversion functions directly. It does not reproduce hidden Aftermath math.
Later live inspection must compare their returned values and state effects.

## Decision

### Immutable dependency and deployment

All five direct dependencies use the official repository and full revision
`f62e74aa862ef65b8950a70d83aac8cb71c19837`:

| Package | Repository subdirectory | Original and current mainnet package | Version |
| --- | --- | --- | ---: |
| `perpetuals` | `packages/iperps/perpetuals` | `0x3ec740df8428aa9c93aaef7f8cc1542ac3194fd014826b51bfe245346d64efc7` | 1 |
| `position` | `packages/iperps/position` | `0x9196fffe0341b2f0ca7424926b22d9e9e35b4807a1f625fc20eeea1382d08dec` | 1 |
| `authority_cap` | `packages/authority-cap/authority-cap` | `0x4e2df80a5e2fd0392878298c51ce15164222111ccea05504b9291b158f552677` | 1 |
| `oracle_aggregator` | `packages/oracle-aggregator/oracle-aggregator` | `0x9237337d846fc90b0a7acbdee4ab91809298691873d28e1d64d91e6303ff6ba4` | 1 |
| `ifixed` | `packages/ifixed/ifixed` | `0x4b4703a7581781d74a4c7b0fb0836b2a67f34f1a377fb81aab6f5cad29d78760` | 1 |

The live checker first requires Sui mainnet chain identifier
`4btiuiMPvEENsttpZC7CZ53DruC3MAgfznDbASZ7DR6S`. It then checks each original
package, current package, version, digest, previous transaction, module bytecode
hash, and every consumed normalized function signature. It rejects a newer
lineage tip. It also parses `Move.toml` and both lock environments with a
fail-closed reader. A mutable selector, changed repository or subdirectory,
unknown table, dependency-edge drift, or unexpected lock node fails the gate.

### IFixed convention

Aftermath IFixed is a signed two's-complement value carried in `u256` with
`ifixed::ifixed::one() == 10^18`. Blast must use
`ifixed::ifixed::{is_neg, abs, decimal_scalar_from_decimals, to_balance}` for
sign extraction and conversion. It must not cast a signed raw value or copy an
unpublished formula. `to_balance` rounds toward zero. For a negative liability,
Task 5 must conservatively add one destination atomic unit when discarded
IFixed remainder exists; positive assets round down. Absolute risk quantities
round up under the same remainder rule.

The raw checkpoint stores IFixed values unchanged. The normalized operation
observation uses nine-decimal base/price/notional units and six-decimal atomic
collateral units. Activation separately requires the bound collateral
`Currency` to have six decimals.

### Primitive and checkpoint map

“Exact” means the getter returns the stored or Aftermath-computed value and
Blast performs no rounding while capturing it. Tuple order follows the named
official interface. “Checkpoint” means the raw value is persisted in the
adapter's mutation checkpoint; immutable object/source bindings are stored in
`Binding`, not duplicated there.

| Blast primitive | Exact Aftermath source | Raw representation and scale | Normalization and rounding | Stored checkpoint field |
| --- | --- | --- | --- | --- |
| Free collateral | `perpetuals::account::collateral_balance<T>` | `u64`, atomic units of `T`; six decimals for the admitted collateral | Exact; no conversion | Yes |
| Allocated collateral | `position::position::collateral` | nonnegative signed-IFixed carrier, `u256`, 18 decimals | `to_balance(raw, decimal_scalar_from_decimals(6))`; down | Yes |
| Signed base | first result of `position::position::base_and_quote_amounts` | signed IFixed in `u256`, 18 decimals | Preserve sign with `is_neg`; absolute base converts to 9 decimals, up for risk | Yes, raw signed value |
| Signed quote notional | second result of `position::position::base_and_quote_amounts` | signed IFixed in `u256`, 18 decimals | Preserve sign; absolute notional converts to 9 decimals, up for risk | Yes, raw signed value |
| Realized funding candidate | `position::position::calculate_position_funding_internal(position, long_rate, short_rate)` immediately before settlement; rates come from `perpetuals::market::cum_funding_rates` | signed IFixed in `u256`, 18 decimals | Preserve the signed raw result. Credit rounds down; cost rounds away from zero when converted to six-decimal collateral | No derived amount; store both rate snapshots, both market rates, and collateral before/after |
| Unrealized PnL | `position::position::unrealized_pnl(position, mark)` | signed IFixed in `u256`, 18 decimals | Positive equity contribution down; negative liability away from zero, then six-decimal collateral | No; derive from stored position primitives and operation mark |
| Base index | `perpetuals::market::base_oracle_price(params, base_storage, clock)` after exact storage/source binding | positive IFixed in `u256`, 18 decimals | Convert to 9 decimals; down for shareholder equity and up for absolute risk bounds | No; operation-scoped price |
| Collateral price | `perpetuals::market::collateral_oracle_price(params, collateral_storage, clock)` after exact storage/source binding | positive IFixed in `u256`, 18 decimals | Convert to 9 decimals; collateral asset value rounds down | No; operation-scoped price |
| Mark | `perpetuals::clearing_house::mark_price(clearing_house, base_storage, clock)` | positive IFixed in `u256`, 18 decimals | Convert to 9 decimals through IFixed; use only for venue margin and divergence checks | No; operation-scoped price |
| Lot size | `perpetuals::market::lot_size(params)` | `u64`, base units at 9 decimals | Exact; order sizes are whole multiples and risk conversion rounds up | Yes |
| Pending ask base | first result of `position::position::pending_base_amounts_by_side` | nonnegative IFixed magnitude in `u256`, 18 decimals | Exact raw checkpoint; conversion to 9 decimals rounds up for risk | Yes |
| Pending bid base | second result of `position::position::pending_base_amounts_by_side` | nonnegative IFixed magnitude in `u256`, 18 decimals | Exact raw checkpoint; conversion to 9 decimals rounds up for risk | Yes |
| Pending-order count | `position::position::pending_order_count` | `u64` count | Exact | Yes |
| Market pause mode | `perpetuals::clearing_house::market_pause_mode<T>` | `u8` venue mode | Exact; any disallowed mode makes the operation non-operational | Yes |
| Market frozen | `perpetuals::clearing_house::is_frozen<T>` | `bool` | Exact | Yes |
| Position IMR | `position::position::initial_margin_ratio` | nonnegative IFixed in `u256`, 18 decimals | Exact for equality/bounds; ratio conversion rounds against risk | Yes |
| Market IMR | `perpetuals::market::margin_ratio_initial(params)` | nonnegative IFixed in `u256`, 18 decimals | Exact raw risk parameter | Yes |
| Market MMR | `perpetuals::market::margin_ratio_maintenance(params)` | nonnegative IFixed in `u256`, 18 decimals | Exact raw risk parameter | Yes |

The operation also binds `base_storage_id`, `collateral_storage_id`,
`base_source_id`, and `collateral_source_id` from `MarketParams`. The selected
`PriceFeedStorage` values must match both storage IDs. Their indexed
`price_feed(source_id)` records must return the same source ID before their
price and timestamp can be observed. These are authentication inputs, not
caller-selected economic values.

### Funding classification

Funding settlement is isolated from orders, allocation, and every other venue
mutation:

1. Read the `&Position`, its two funding snapshots, its collateral, and the two
   current market cumulative rates.
2. Call `calculate_position_funding_internal` with that same position and rate
   pair. Preserve the signed IFixed result.
3. Call `clearing_house::settle_position_funding` with the bound collateral
   oracle, account number, and clock.
4. Read the position and market checkpoint again.
5. Classify the candidate as realized funding only when the expected funding
   snapshot transition and collateral effect both match and every unrelated
   checkpoint field is unchanged. Otherwise classify the change as unexpected
   and do not debit the reserve.

The later classifier owns the exact comparison. A total-equity delta, PnL,
liquidation, ADL, collateral movement, or order mutation is never funding.

### Capability semantics

`account::create_account<T>` returns exactly one
`AuthorityCap<account::ACCOUNT, authority::ADMIN>`. Deposit, allocation,
position creation, session start/end, and IMR configuration preserve the
official generic authority marker required by each signature. The adapter must
check `authority_cap::authority::for<account::ACCOUNT, authority::ADMIN>`
against the bound account object and must never create, store, or accept an
assistant cap. The later `VenueAccount` permanently contains the admin cap and
exposes no borrow or release API.

## Evidence and remaining gates

Task 1 establishes immutable linkage and callable raw semantics only. It does
not claim that a Vault can hold value. Before activation:

- Task 5 must implement independent long, short, flat, PnL, funding, depeg,
  minimum-lot, width, and rounding vectors for this table.
- Task 8 must compare the named interface results and funding checkpoint effect
  against live inspection and controlled mutation fixtures.
- The selected SUI-USDC market, registry, oracle objects, source IDs, lot size,
  IMR, MMR, pause/freeze behavior, and usable owned collateral remain deployment
  inputs that must be recorded and verified.
- Confidence is not present in the normalized `PriceFeed` interface consumed
  here. A later valuation observation must not invent it; Task 5 must bind an
  approved source that supplies the required confidence or revise the policy
  through a separate accepted decision before activation.

Any live lineage, bytecode, ABI, dependency, source-binding, conversion-vector,
or checkpoint mismatch reopens this decision and blocks publication.

## Consequences

- The adapter, not Series1 core, owns all volatile Aftermath dependencies.
- Builds are reproducible against one Aftermath and one Sui revision.
- Exact marker generics and cap binding remain visible in the committed ABI
  table.
- Raw mutation facts can detect out-of-band venue changes without storing
  display NAV, leverage, token price, or oracle prices.
- Funding can affect the protected reserve only after exact before/after
  checkpoint verification.
