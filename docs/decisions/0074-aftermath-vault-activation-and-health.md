# 0074: Aftermath Vault activation and health evidence

Active-contract amendment: 2026-09-20 (venue bytecode read; shutdown reconciliation). This is the pre-publication source
contract; local evidence does not establish publication or live release readiness.

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
conversion functions directly. It does not reproduce hidden Aftermath math or
inspect an upstream implementation to invent calls. The pinned ports are
sufficient to design and compile the adapter. Later live inspection verifies
real object values and transaction effects; it is not an API-discovery step.

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
normalization conservatively adds one destination atomic unit when discarded
IFixed remainder exists; positive assets round down. Absolute risk quantities
round up under the same remainder rule.

The raw checkpoint stores IFixed values unchanged. The normalized operation
observation uses nine-decimal base quantity, base index, collateral price,
mark, and confidence units. Free and allocated collateral, signed PnL, venue
equity, quote notional, funding amounts, and reserve use six-decimal atomic
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
| Allocated collateral | `position::position::collateral` | signed-IFixed carrier, `u256`, 18 decimals | Asset magnitudes round down; liability magnitudes round up before equity netting | Yes |
| Signed base | first result of `position::position::base_and_quote_amounts` | signed IFixed in `u256`, 18 decimals | Preserve sign with `is_neg`; absolute base converts to 9 decimals, up for risk | Yes, raw signed value |
| Signed quote cost basis | second result of `position::position::base_and_quote_amounts` | USD-valued signed IFixed in `u256`, 18 decimals, **under the base's sign** (a long holds positive base and positive quote; `add_base_to_position` bytecode, 2026-09-20) | Preserve only for direction coherence and raw transition guards; it is historical cost basis, not current leverage notional | Yes, raw signed value |
| Expected funding settlement | replay of `position::position::settle_position_funding` from the stored checkpoint: the held side's `market rate − snapshot` times `|base|`, divided by the venue collateral price the capture read (2026-09-20 amendment; `calculate_position_funding_internal` is no longer called) | collateral-token IFixed magnitude with a sign | Floor for a credit, ceiling for a cost, exactly as the venue rounds the 10^36 product; a credit that floors to zero is no change | No derived amount; store both rate snapshots, both market rates, and collateral before/after |
| Current absolute notional | absolute normalized base multiplied by the authenticated Pyth base index | USD value converted through the authenticated collateral price | Base size and the Pyth base numerator round up; the collateral-price denominator rounds down and final collateral notional rounds up. Historical quote cost basis is not used | No; operation-scoped leverage input |
| Unrealized PnL | `position::position::unrealized_pnl(position, base_index)` | USD-valued signed IFixed in `u256`, 18 decimals | Pyth index anchors shareholder accounting; divide by authenticated collateral price, flooring positive equity and ceiling negative liability | No; derive at the operation index |
| Base index | `perpetuals::market::base_oracle_price(params, base_storage, clock)` after exact storage/source binding | positive IFixed in `u256`, 18 decimals | Convert to 9 decimals; down for shareholder equity and up for absolute risk bounds | No; operation-scoped price |
| Collateral price | `perpetuals::market::collateral_oracle_price(params, collateral_storage, clock)` after exact storage/source binding | positive IFixed in `u256`, 18 decimals (the feed's raw `u128` cast unchanged) | Convert to 9 decimals; collateral asset value rounds down; the raw value is what the funding replay divides by | No; operation-scoped price |
| Mark | `perpetuals::clearing_house::mark_price(clearing_house, base_storage, clock)` | positive IFixed in `u256`, 18 decimals | Convert to 9 decimals through IFixed; use only for venue margin and divergence checks | No; operation-scoped price |
| Lot size | `perpetuals::market::lot_size(params)` | `u64`, base units at 9 decimals | Exact; order sizes are whole multiples and risk conversion rounds up | Yes |
| Collateral scale | `perpetuals::market::scaling_factor(params)` | `u256`, raw IFixed units per collateral atom; the venue multiplies every allocated atom by it | Must equal `10^12` at initialization (2026-09-20) | No; bound once |
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

1. Read the `&Position`, its two funding snapshots, its collateral, the two
   current market cumulative rates, and the venue collateral price
   (`market::collateral_oracle_price`) into the pre-settlement checkpoint.
2. Call `clearing_house::settle_position_funding` with the bound collateral
   oracle, account number, and clock.
3. Read the position and market checkpoint again.
4. Replay the venue's settlement from the pre-settlement checkpoint: the held
   side's rate delta times the base magnitude, divided by the same collateral
   price, floored for a credit and ceiled for a cost (bytecode read of
   2026-09-20, [research](../research/aftermath-venue-bytecode-2026-09-20.md)
   F1). Classify the change as realized funding only when the snapshots moved
   to the market rates, the allocated collateral moved by exactly the replayed
   amount, and every unrelated checkpoint field is unchanged. Otherwise
   classify the change as unexpected and do not debit the reserve.

Until 2026-09-20 step 4 converted `calculate_position_funding_internal`'s USD
result; that figure is rounded to 10^18 before the division and disagrees with
the venue's collateral move in about half of all settlements at a non-unit
collateral price. The replay agrees with a bytecode model of the venue on
200,000 random settlements.

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

### Atomic activation and order-side amendment

The official Move ports are the authoritative callable interface. Their
function names, parameter types, and return types define the adapter boundary;
their `abort 404` bodies are not dependency implementations. When a named
interface leaves a safety-critical representation ambiguous, Blast inspects
the immutable deployed bytecode rather than importing or copying the venue
implementation.

That inspection fixes Aftermath's order-side boolean as `false = bid` and
`true = ask`: the deployed `filled_base_and_quote` and `execution_price`
branches select ask fields for `true` and bid fields for `false`. Atomic
activation therefore maps Series1 long to `false` and Series1 short to `true`.
Unit and source-boundary gates pin that mapping.

Initialization takes no oracle object beyond the two Aftermath
`PriceFeedStorage` values (the two Pyth `PriceInfoObject` arguments were
removed on 2026-09-20; see the oracle amendment below). The caller cannot
supply a price, source ID, market ID, side, order size, or share amount.

The adapter exposes a stateless `product::Product<phantom Tag>` witness with a
public zero-state constructor. The witness carries only type identity and no
authority. A Series1 administrator still authorizes `vault::issue`, and Coin
Registry uniqueness prevents a second currency for the same
`Vault<Product<Tag>>` type. Different tag types let one adapter package issue
distinct 2x, 5x, long, short, or future product currencies without hard-coding
their economic policy into the witness constructor.

One selected risk-module witness can atomically activate an issued Vault once.
The adapter creates and binds the account authority, deposits and allocates the
whole seed as real position margin, including the reserve that Series1 excludes
from shareholder NAV, creates one position, sets and later rechecks its IMR,
and captures a strict flat pre-trade observation. Series1 derives the target,
direction, and live per-order notional cap. The adapter rounds the target down
to whole live lots and splits it into reference-price cap-compliant market
orders. Each order runs in its own Aftermath session so the adapter can require
the exact fill on the required side, no posted order, liquidation, or bad debt,
strict execution tolerance, and actual filled-quote notional at or below the
live cap before the next order begins. It then settles funding and captures the
final observation.
Only after strict execution and all Series1 activation gates pass does it mint
the reserve-excluded seed NAV at the fixed 1,000 share scale, lock those shares
at `@0x0`, retain that exact locked amount and the explicit nonzero seed funder,
seal the sole admin capability and checkpoint into the Vault, share
the account and returned clearing house through their defining modules, and
emit the replay-complete activation event. Any abort rolls back the complete
transaction.

One initialization may place at most 16 market orders. The adapter computes
the exact ceiling of `target_base / max_order_base` through quotient and
remainder before it constructs the order vector or enters the loop, then
rejects a count above 16 with a dedicated append-only abort. Sixteen is the
smallest fixed bound accepted for this generation: it keeps the only venue
order loop small while allowing a launch target to be split across materially
smaller risk-module order caps. The value is adapter bytecode, not configurable
Vault state; a policy/cap pair that needs more calls cannot initialize. Zero
remaining base, the inclusive maximum, the first value above it, and a
maximum-width ceil vector are pinned independently. The completed vector must
still sum to the exact whole-lot target and every order must independently pass
the live notional cap both when planned at the Pyth reference price and after
execution using that session's actual filled quote.

After the session, `settle_position_funding` receives the bound collateral
oracle, not the base oracle. Funding is collateral-denominated in the named
Aftermath interface. The source-boundary gate pins the exact argument and call
order so this distinction cannot regress behind two values of the same Move
type.

Local unit tests prove the individual Blast-owned guards and mutation seams.
The source-boundary gate pins their production order: Series activation and
reserve, locked-share minting, cap/checkpoint sealing, VenueAccount
installation, account and ClearingHouse sharing, and event emission. These
tests do not prove transaction rollback. Move unit tests cannot catch an abort
and then inspect the aborted transaction's object effects, and the official
external ports abort locally. An authorized verifier must therefore prove
activation atomicity with controlled submitted local or testnet transactions at every named phase
boundary, in addition to one successful end-to-end activation.

### Release evidence protocol

Offline activation vectors exercise the same exact command-result, effect,
event, checkpoint, final-state, case-classification, and rollback validators as
the live gates. They are synthetic regression inputs and are never deployment
or rollback evidence.

The read-only gate serializes the reviewed PTB, then passes that exact base64
`TransactionData` to the pinned Sui CLI's machine-readable `serialized-tx`
surface with `--dev-inspect --json` on the exact mainnet chain. A committed fixture
captured from that pinned surface fixes its schema; omitted optional result
arrays normalize to empty arrays. The gate consumes the standard transaction
effects, raw typed `events_wrapper::Event<T>` values paired with `event_json`,
changed objects, and command outputs. It authenticates every configured input
object type and requires one exact wrapped `VaultInitialized<Product>` schema.
It does not accept a tool-specific normalized response or infer a return value
from `initialize`, which returns nothing. Every live proof path rejects a Sui
CLI version other than the pinned revision.

The controlled health gate submits configured production calls for all sixteen
P16-P19 cases: long, short, flat, profit, loss, funding credit, funding cost,
repeated funding settlement, liquidation, ADL, collateral movement, pending
orders, pause, freeze, stale price, and collateral depeg. Every case records the
canonical Vault before and after, raw transaction output, checkpoint, lifecycle,
typed protocol events, and exact change classification from an immutable
committed oracle keyed by the fixed case set. Live configuration supplies only
call targets, object inputs, and preparation resources; it cannot supply event
types, filters, or expected outcomes. A test-only target, relabeled, missing,
duplicate, or unknown case, unexpected event set, or unconfigured state
transition fails the gate. Each case name is also bound to its committed
scenario-preparation call. The preparation package is accepted only after its
reviewed Git commit, tree, build-input digest, published package digest, and
compiled/on-chain module hashes agree. The gate parses PTB command boundaries;
it requires the exact full
`package::controlled_health_cases::prepare_<case>` target and the exact
production `package::operations::sync_health` target, with the same case Vault
as the first object argument to both. A duplicate call, suffix match, target
string used as an argument, or decoy object elsewhere in the PTB cannot satisfy
that binding.

Canonical pre/post evidence includes the stored maintenance reserve. A call
without an accepted net funding effect preserves it exactly. Net funding credit
must increase allocated collateral by the event's raw IFixed amount, emit the
exact down-rounded atomic amount, increase the reserve by that amount, and
report zero absorbed and uncovered values. Funding cost must decrease allocated collateral by the raw
amount, emit the exact up-rounded atomic amount, absorb
`min(reserve_before, amount)`, persist `reserve_before - absorbed`, and report
the exact uncovered remainder. The committed validator covers cost below,
equal to, and above the available reserve and rejects inconsistent raw amounts,
rounding, reserve movement, checkpoints, or event accounting.

The controlled atomicity gate submits one successful activation and failed
A1-A7 transactions on testnet. Success requires exact lifecycle, reserve,
supply, locked coin, treasury-cap, VenueAccount, checkpoint, Aftermath Account,
and ClearingHouse state plus exactly one typed activation event. Every event
field is bound to the submitted PTB, pre-state, final state, or persisted
checkpoint; every non-gas success effect must have the exact expected identity
and category, while every surviving output's version, digest, and owner must
equal its post-state snapshot. Every tracked identity is bound to a submitted
PTB argument, a transaction effect, an origin transaction effect, or a
transaction-digest creation index. Role selectors are fixed by the validator,
not live configuration. The initializer is parsed as one exact move-call
record: its package target, three type arguments, and thirteen explicit
arguments must equal the reviewed run configuration. Vault, Protocol,
Currency, Registry, ClearingHouse, both oracle stores,
seed coin, and Clock are each bound to their fixed initializer argument index
and exact tracked type; mentioning an ID in another call is not a binding. The
explicit funder address must match the reviewed nonzero beneficiary. The
same identity and state validators check offline fixtures and live captures.
Each failure
snapshots canonical object references and decoded content before and after,
permits only the gas object to change, requires no event, and matches the fixed
package, module, function, and abort code for its boundary.

An instrumented failpoint package is admissible only when the complete build
input set is byte-for-byte equal to the reviewed production tree except for one
fixed abort line immediately after its unique standalone A1-A7 source marker.
The proof pins the reviewed Git commit, tree, and source digest, verifies the
Blast production and failpoint sources against their published packages, and
records compiled and on-chain module hashes. The Aftermath named ABI ports and
their existing package/signature gate remain the authority for upstream calls;
their deliberate `abort 404` bodies are not compared with venue implementation
bodies. Neither dev-inspect, a fixture comparison, nor an abort code alone
proves rollback.

Each offline A1-A7 regression vector carries the same synthetic initializer,
structural PTB, complete tracked-object set, origin-effect evidence,
transaction-derived identities, canonical pre/post state, and one-line
instrumentation proof consumed by the live validator's non-network checks.
Wrong initializer positions, decoy objects, duplicate or argument-shaped
targets, relabeled markers/codes, and extra instrumentation mutations therefore
fail locally before any funded deployment is trusted. Compilation,
publication, and submission remain the only live-only portions of the proof.

## Evidence and remaining gates

Local source and fixture evidence establishes the implemented Blast boundary,
not deployed venue execution. Release still requires:

- Preserve independent local long, short, flat, PnL, funding, depeg,
  minimum-lot, width, and rounding regressions for this table.
- An authorized verifier must compare the named interface results and funding
  checkpoint effect against live inspection and controlled mutation fixtures. It must also
  observe failed submitted local or testnet transactions at every activation
  phase boundary and prove that no protocol-owned mutation, supply, custody,
  or event effect survives; read-only mainnet dev-inspect is not rollback
  evidence.
- The selected SUI-USDC market, registry, oracle objects, source IDs, lot size,
  IMR, MMR, pause/freeze behavior, and usable owned collateral remain deployment
  inputs that must be recorded and verified.
- **Oracle amendment (2026-09-20, F4 of the venue bytecode read).** Every
  live Aftermath feed is written by a Pyth Lazer vendor package: its `from` is
  a `FeedInfoObject`, not a Pyth `PriceInfoObject`; the feed price is an
  18-decimal IFixed; its timestamp is the Lazer update time in milliseconds;
  the signed update is verified in the updater's transaction and stored
  nowhere else on chain. The Pyth `PriceInfoObject` binding this section
  used to describe could never be satisfied on mainnet and is removed, with
  the Pyth port, its two initializer and operation arguments, and the
  `pyth_price_info_mismatch` / `oracle_source_mismatch` codes. What replaces
  it: the venue's own price functions (`market::base_oracle_price`,
  `collateral_oracle_price`, both pinned by bytecode to return the bound
  feed's raw price after the venue's staleness and, for collateral,
  index/TWAP divergence checks) are the price; the storages are checked
  against the market's storage ids; and each feed's origin object
  (`PriceFeed.from`) is bound at activation and re-checked on every capture
  (`oracle_feed_mismatch`), so a re-pointed feed halts the vault exactly as
  a market parameter change does. The feed's raw price must equal the venue's
  named price (`oracle_observation_mismatch`). Aftermath feeds carry no
  confidence interval: the adapter reports zero confidence and the core's
  `max_confidence_bps` bound is vacuous for this adapter. An external
  classic-Pyth tolerance check was considered and not adopted: it is a
  different property (two sources, two update times) needing tolerance
  parameters, and both Lazer and classic Pyth are the same publisher network.

### Pyth ABI port and snapshot classification amendment

*Superseded on 2026-09-20 by the oracle amendment above: the Pyth port and the
`PriceInfoObject` identity, price and timestamp checks described here no
longer exist. The snapshot classification (strict versus health capture) it
introduced stands.*

The official `pyth-network/pyth-crosschain` source is pinned at
`6c1c9138e71a62629232607e252b12bcaa38356a`, subdirectory
`target_chains/sui/contracts`. Its upstream package manifest cannot be linked by
the pinned package manager because it depends on a new-style Wormhole package.
The adapter consequently carries the smallest local ABI port of the official
Pyth declarations, with the official mainnet/testnet `Published.toml` lineage.
The port exposes only `PriceInfoObject`, `PriceInfo`, `PriceFeed`, `Price`,
`I64`, and the named getters used by capture; its `abort 404` bodies are link
stubs and are never used in unit tests. The ABI checker pins the deployed Pyth
lineage, bytecode and normalized getter signatures.

Capture checks account, registry, clearing house, oracle objects, collateral
type, market storage/source IDs, feed source IDs, feed `from` IDs, Pyth object
IDs, and the one supplied `Clock` before constructing an observation. It uses
the named effective-IMR and `compute_margin_and_requirement` method with the
bound collateral price, mark, and haircut; margin below requirement is unsafe.
`compute_free_collateral` is clamped and is not a margin-safety predicate. Venue
availability is independently an allowed pause mode and not-frozen state.
Margin uses a signed IFixed carrier: a negative margin is unsafe even if its
raw `u256` encoding compares above the requirement. Strict capture rejects
incoherent base/quote signs; health capture preserves the authenticated facts
but makes the same shared sign predicate unhealthy. USD-to-collateral
conversion checks multiplication and final-addition width before every result;
strict operations abort on overflow while health capture degrades without an
economic-state abort.
Strict capture also rejects any unrepresentable base, Pyth-valued current
notional, allocated/PnL equity, or normalized economic input with the adapter
normalization error; it must never turn that failure into a zero-valued priced
observation. The permissive health path alone maps that condition to an
unhealthy fact.

There are two capture modes over that same authenticated path. Strict capture
constructs strict Series1 observations and is used by priced or risk-increasing
operations. Health capture performs every binding, storage/source, and
Pyth-object identity check first. A representable feed/Pyth/named-price or
timestamp disagreement still aborts. An authenticated negative or
unrepresentable Pyth component, feed width, named-price width, exponent, or
seconds-to-milliseconds conversion instead becomes an invalid economic fact,
alongside zero price, mark, lot, or malformed exposure, in the adapter's
linear capture. After checkpoint classification, the adapter consumes that
capture and retains only its authenticated checkpoint; it does not construct a
Series1 position observation for health. A temporary economic-data fault does
not retire or degrade an active Vault. This path never weakens source identity
or accepts caller-shaped economics.

`CheckpointChange` preserves raw collateral-token IFixed deltas. The ordinary
stored-to-pre edge may advance only the market cumulative rates while the
position snapshots and every other field remain unchanged. Settlement then
refreshes both snapshots, so funding is recognized only when both equal the
captured market rates, at least one advanced, the USD candidate converts to the
exact allocated-collateral delta with directional rounding, and every other raw
checkpoint field is unchanged. Because Aftermath settlement is permissionless,
the adapter independently classifies the stored-to-pre and pre-to-post edges.
The first may contain one externally completed snapshot refresh plus
allocated-collateral delta while market rates advance again; the second may
contain the adapter's settlement to those newer rates. When both occur,
the adapter aggregates their authenticated signed collateral-IFixed effects
before one conservative normalization and one Series1 settlement. Net credits
increase the reserve; net costs consume it before holder NAV. An authenticated
zero-net snapshot advancement is accepted and emitted once. Persisting the
final accepted checkpoint makes the complete interval exactly once. Any
unexplained collateral, exposure, order, or parameter mutation makes the
synchronization unresolved: preserve the accepted checkpoint and reserve,
and record only a distinct diagnostic fingerprint.

Any live lineage, bytecode, ABI, dependency, source-binding, conversion-vector,
or checkpoint mismatch reopens this decision and blocks publication.

### Permissionless funding and health synchronization

`sync_health` is public and accepts no witness, capability, side, size, market
identifier, source identifier, or share amount. The caller supplies the bound
account, Registry, ClearingHouse, oracle storages, and the exact base and
collateral Pyth `PriceInfoObject` values. The adapter version guard runs first.
The stored `VenueAccount` then rechecks its sealed admin capability against the
bound account object, and the shared snapshot path authenticates every object,
type, storage, source, Pyth identity, price, and timestamp.

After authentication, synchronization has one fixed sequence:

1. Ask the venue to update its cumulative funding when the update is due:
   call `clearing_house::update_funding` with the bound base oracle storage
   only when `market::is_time_to_update(now, funding_last_upd_ms,
   funding_frequency_ms)` holds for the bound market, so the candidate, the
   settlement, and both captured checkpoints read current rates (amendment
   below).
2. Capture a permissive pre-settlement checkpoint and the named Aftermath
   funding candidate at the captured market rates.
3. Call `clearing_house::settle_position_funding` with the bound collateral
   oracle.
4. Capture the post-settlement facts and classify both stored-to-pre and
   pre-to-post checkpoint edges.
5. Aggregate both authenticated signed effects before rounding. Costs round
   up and consume reserve, with any uncovered cost borne by holder NAV and
   recorded as the Series' uncovered deficit. Credits round down and repay
   that deficit first, staying in holder NAV; only the remainder increases
   reserve (amended 2026-09-17; `FundingSettled.restored_to_holders` carries
   the split).
6. Consume the final linear capture and extract its checkpoint without a
   lifecycle mutation. Accept the economic checkpoint only for a reconciled interval;
   unresolved observations update only the diagnostic fingerprint.
7. Emit accepted funding facts (including zero-net advancement) and new
   unresolved/reconciled diagnostics after their mutations. Unchanged repeats
   emit nothing.

Stored-to-pre market-rate advancement is the expected precursor to local
funding settlement. A permissionless settlement already completed before this
call is accepted exactly once when its snapshot and collateral transition is
isolated. If rates advanced again afterward, the adapter also recognizes its
own pre-to-post settlement and nets the interval before rounding. Every other
stored-to-pre drift is an authenticated unexpected venue change: the call
preserves the accepted economic checkpoint, reserve and lifecycle. Priced
operations remain blocked until reconciliation. A binding, type, storage/source,
Pyth identity, or representable observation agreement failure still aborts. No
health path can activate, resume, start shutdown, mint, burn, withdraw, place
an order, or increase risk.

`FundingSettled<Product>` occurs for each accepted funding checkpoint advancement,
including a zero-net interval. It records the Vault, credit/cost direction,
exact raw collateral-IFixed amount,
conservative six-decimal amount, reserve absorption, uncovered cost, reserve
after settlement, and both the previous and post checkpoints.
`HealthSynchronized<Product>` reports reason `1` for a distinct unresolved
observation and reason `2` when that diagnostic clears. It contains the Vault,
reason and observed checkpoint, not a constant lifecycle-change flag. The
diagnostic is distinct from the accepted economic checkpoint. Together with
issuance, activation, active economic, fee-setting, order-limit, risk-module
rotation and terminal lifecycle events, the stream reconstructs native
supply, locked seed/funder, reserve, separate admin cash, settings, bindings,
lifecycle, selected risk module and both checkpoint/reporting identities.

One package-private production helper owns the complete Blast post-capture
phase: aggregate funding normalization and reserve settlement, linear
capture consumption, conditional accepted-checkpoint persistence,
diagnostic novelty tracking and conditional event emission. Local connected tests
invoke that same helper against real issued and Series-initialized Vault state;
they do not duplicate
the reserve, lifecycle, persistence, or event formulas.

`VenueAccount` represents its retained account-admin cap as an `Option` solely
because the authoritative external cap constructor is an aborting ABI stub in
local tests. The only production constructor authenticates the cap and always
stores `some(cap)`. Published code has no path to create `none`, clear, take, or
replace the option, and every production borrow first asserts `is_some`. The
`none` constructor is `#[test_only]`; it retains a real Binding and Checkpoint
inside the real VenueAccount/Vault fixture and is absent from published
bytecode. It does not weaken live custody authentication.

The official Aftermath and Pyth ports abort in local unit tests, so local tests
exercise the exact Blast-owned classification, rounding, real Vault/Series
post-capture transition, event, and reducer paths while source gates pin the
production call and mutation order. Replay tests drive issuance, activation,
funding/health, active economics, fee settings, order-limit, risk-rotation and
terminal lifecycle events through real package mutation seams, including two
product types, and compare reconstructed canonical facts to the resulting
Vaults. An authorized combined verifier must still execute the complete
permissionless path against controlled live objects and compare the resulting
checkpoint, reserve, lifecycle, and events.

### Funding update before settlement amendment (2026-09-16)

Aftermath advances its cumulative funding rates lazily, when a trade or its
permissionless `clearing_house::update_funding` runs. An idle market therefore
leaves accrued funding out of the vault's candidate, its settlement, and both
captured checkpoints. ADR 0084 D5 requires the adapter to refresh the rates
before every settlement it accepts. The package-private helper
`operations::update_funding_when_due` runs immediately before the
pre-settlement capture in `initialize`, `sync_health` and `unwind_market`; it
reads the bound market's `funding_last_upd_ms` and the frequency, and calls
`update_funding` only when the update is due. The adapter never calls
`update_twaps`. The classifier, the aggregate net-funding rule and the
funding event are unchanged: stored-to-pre market-rate advancement was already
the expected precursor of a local settlement.

Two facts the interface does not state were read from the deployed package
`0x3ec740df8428aa9c93aaef7f8cc1542ac3194fd014826b51bfe245346d64efc7`, whose
`market` and `clearing_house` bytecode hashes the ABI gate already pins
(`7b487816…` and `56290307…`), by disassembling the modules the GraphQL
endpoint returns:

- `market::funding_params(&MarketParams): (u64, u64)` returns
  `(TwapParams.funding_frequency_ms, TwapParams.funding_period_ms)`; the
  frequency in milliseconds is the first element.
- `clearing_house::update_funding` delegates to
  `market::try_update_funding`, which prices the premium through
  `base_oracle_price_and_twap_price(&MarketParams, &PriceFeedStorage, &Clock)`;
  that function asserts the storage id equals `CoreParams.base_storage_id`, so
  the call expects the base price-feed storage and aborts at the venue on any
  other storage. `settle_position_funding` keeps reading
  `collateral_oracle_price`.
- `market::is_time_to_update(now, last, frequency)` is
  `now >= next_funding_update_time(last, frequency)` with
  `next = last - last % frequency + frequency`; the venue's inner
  `try_update_fundings` repeats this check, so the adapter's guard only
  decides whether a venue call is spent. `try_update_funding` also refreshes
  the premium and spread TWAPs and asserts the index/TWAP divergence limit,
  which is why the adapter guards the call instead of calling
  unconditionally.

The adapter's `is_time_to_update_funding` mirrors that formula and treats a
zero frequency as never due. The ABI gate pins `update_funding`,
`funding_params`, `funding_last_upd_ms`, `is_time_to_update` and
`next_funding_update_time`; the source-boundary gate pins that every
`settle_position_funding` call site is preceded in its function by the guarded
update, before the pre-settlement capture, with the base storage; the offline
controlled-health matrix carries the `update_due_then_settlement` vector, a
due update followed by one settlement whose post checkpoint carries the
updated market rates. Live execution of the venue call remains part of the
separately authorized verification stage.

### Terminal finality and event ABI amendment (2026-09-06)

This amendment defines the current pre-publication contract with ADR 0073's
four states and shutdown-only authority. It changes the source event ABI; it is
not a claim of compatibility with a previously published payload or permission
to publish, upgrade, or execute a live venue transaction.

Finalization captures the bound account at full precision. Raw base and entry
quote, pending ask/bid base and order count must be exactly zero, and both
position funding snapshots must equal the captured market rates. Named IFixed
`is_neg` and `abs` reject any negative allocated collateral before conversion.
For the admitted six-decimal collateral, one atomic coin unit is `10^12` raw
collateral-token IFixed units. Recoverable cash is free collateral plus the
whole-atom floor of the nonnegative allocated magnitude, with a checked `u64`
sum. A fractional positive remainder does not block this irreversible exit.

The returned native coin must equal that entire recoverable amount. The final
checkpoint must equal the captured pre-withdrawal checkpoint in every field
except free collateral, which must be zero, and allocated collateral, which
must equal the exact original magnitude modulo `10^12`. Thus the remainder is
nonnegative and strictly below one atom; neither a liability, one recoverable
atom, an erased raw unit, nor an unrelated venue mutation can be accepted.
This raw residual remains in the venue checkpoint and is explicitly reported;
it is not local backing, a fee, a synthetic coin, or a caller-selected loss.
An unstorable package-constructed `TerminalWithdrawal` binds the actual returned
coin to that verified final checkpoint until Vault finalization consumes it.

Completed terminal payloads share the existing event envelope and stable Vault
identity. Their primitives supplement native transaction effects and ordered
events; there is no event-only replay guard or extra on-chain claim ledger:

- `ShutdownBegun`: Vault and administrator-declared shutdown reason, emitted
  after Active becomes Unwinding without a venue/oracle call.
- `UnwindProgress`: Vault, the adopted before checkpoint, the after checkpoint,
  market-order count and optional actual filled quote. The settlement of a
  closed market has no invented order or quote fill (shutdown reconciliation
  amendment, 2026-09-20).
- `ShutdownFinalized`: Vault, actual recovered atomic cash, eligible native
  supply, optional recorded seed-funder payment beneficiary, final checkpoint,
  and `unrecoverable_collateral_raw: u256`. The final primitive deliberately
  reports the exact bounded raw residual also preserved in the checkpoint for
  resynchronization and loss visibility. It is never counted as claim cash.
- `ShutdownRedeemed`: Vault, burned native shares, paid and remaining atomic
  cash, and remaining eligible native supply. Claims charge no fee; the last
  eligible holder receives local rounding dust. Zero eligibility at finalization
  instead transfers all recovered holder cash once to the recorded funder.

Successful finalization clears a pending unresolved diagnostic through the
existing reconciled event. It preserves the distinction between the accepted
economic checkpoint and deduplicated diagnostic identity. Long and short local
reducers include the raw residual, terminal cash, native supply, locked seed,
recorded funder, and reconciliation. Local tests substitute only unavailable
IFixed decoding outputs and venue facts; named ports still abort locally, so
they do not prove deployed deallocation, settlement, or transaction effects.
Publication, live ABI, funded submissions and whole-feature rehearsal remain
separately authorized evidence under A-003.

### Shutdown reconciliation amendment (2026-09-20)

Every unwind step begins by reconciling the stored checkpoint with the venue
through the same synchronization every priced operation uses. An explainable
funding move is booked to the reserve and emitted as `FundingSettled`; a venue
the stored checkpoint cannot explain emits `CheckpointDrifted` with the live
checkpoint. Either way the step proceeds from the live state: shutdown closes
what the venue holds, whatever moved it there, so a liquidation, an ADL or a
settlement the adapter cannot replay never blocks the exit. A paused market
admits no session, funding update or settlement, so the settlement path, which
the venue opens only once it has closed the market and enabled settlement
prices, reconciles without a venue call, classifying only the change since the
stored checkpoint. A frozen clearing house aborts every venue call on its
version check, the settlement close included, so `unwind` refuses it until it
is unfrozen (finding F5 of the venue bytecode record). The
isolated funding checkpoint the market path used to prove separately is gone
with it, and `UnwindProgress` carries the adopted before checkpoint, the after
checkpoint, the market-order count and the optional filled quote.

## Consequences

- The adapter, not Series1 core, owns all volatile Aftermath dependencies.
- Builds are reproducible against one Aftermath and one Sui revision.
- Exact marker generics and cap binding remain visible in the committed ABI
  table.
- Raw mutation facts can detect out-of-band venue changes without storing
  display NAV, leverage, token price, or oracle prices.
- Funding can affect the protected reserve only after exact before/after
  checkpoint verification.
