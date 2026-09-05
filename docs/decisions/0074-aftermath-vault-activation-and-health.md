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
Task 5 must conservatively add one destination atomic unit when discarded
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
| Allocated collateral | `position::position::collateral` | nonnegative signed-IFixed carrier, `u256`, 18 decimals | `to_balance(raw, decimal_scalar_from_decimals(6))`; down | Yes |
| Signed base | first result of `position::position::base_and_quote_amounts` | signed IFixed in `u256`, 18 decimals | Preserve sign with `is_neg`; absolute base converts to 9 decimals, up for risk | Yes, raw signed value |
| Signed quote cost basis | second result of `position::position::base_and_quote_amounts` | USD-valued signed IFixed in `u256`, 18 decimals | Preserve only for direction coherence and raw transition guards; it is historical cost basis, not current leverage notional | Yes, raw signed value |
| Realized funding candidate | `position::position::calculate_position_funding_internal(position, long_rate, short_rate)` immediately before settlement; rates come from `perpetuals::market::cum_funding_rates` | USD-valued signed IFixed in `u256`, 18 decimals | Divide by authenticated collateral price; credit down and cost up in collateral-token IFixed units | No derived amount; store both rate snapshots, both market rates, and collateral before/after |
| Current absolute notional | absolute normalized base multiplied by the authenticated Pyth base index | USD value converted through the authenticated collateral price | Base size and the Pyth base numerator round up; the collateral-price denominator rounds down and final collateral notional rounds up. Historical quote cost basis is not used | No; operation-scoped leverage input |
| Unrealized PnL | `position::position::unrealized_pnl(position, base_index)` | USD-valued signed IFixed in `u256`, 18 decimals | Pyth index anchors shareholder accounting; divide by authenticated collateral price, flooring positive equity and ceiling negative liability | No; derive at the operation index |
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

Initialization accepts the exact base and collateral Pyth `PriceInfoObject`
values in addition to the original activation interface. Those two read-only
arguments are required because strict capture must prove the Aftermath feeds
and named market prices describe the same Pyth update. They do not let the
caller supply a price, source ID, market ID, side, order size, or share amount.

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
at `@0x0`, seal the sole admin capability and checkpoint into the Vault, share
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
external ports abort locally. Task 8 must therefore prove activation atomicity
with controlled submitted local or testnet transactions at every named phase
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
without an isolated funding cost must preserve it exactly. Funding credit must
increase allocated collateral by the event's raw IFixed amount, emit the exact
down-rounded atomic amount, preserve the reserve, and report zero absorbed and
uncovered values. Funding cost must decrease allocated collateral by the raw
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
record: its package target, three type arguments, and fourteen explicit
arguments must equal the reviewed run configuration. Vault, Protocol,
Currency, Registry, ClearingHouse, both oracle stores, both Pyth price objects,
seed coin, and Clock are each bound to their fixed initializer argument index
and exact tracked type; mentioning an ID in another call is not a binding. The
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

Task 1 establishes immutable linkage and callable raw semantics only. It does
not claim that a Vault can hold value. Before activation:

- Task 5 must implement independent long, short, flat, PnL, funding, depeg,
  minimum-lot, width, and rounding vectors for this table.
- Task 8 must compare the named interface results and funding checkpoint effect
  against live inspection and controlled mutation fixtures. It must also
  observe failed submitted local or testnet transactions at every activation
  phase boundary and prove that no protocol-owned mutation, supply, custody,
  or event effect survives; read-only mainnet dev-inspect is not rollback
  evidence.
- The selected SUI-USDC market, registry, oracle objects, source IDs, lot size,
  IMR, MMR, pause/freeze behavior, and usable owned collateral remain deployment
  inputs that must be recorded and verified.
- Confidence is not present in Aftermath's normalized `PriceFeed`. Task 5
  therefore binds the exact official Pyth `PriceInfoObject` named by the
  Aftermath feed's `from` ID. It reads price, confidence, exponent, and source
  seconds from that same object; price rounds down and confidence rounds up at
  the same normalized 9-decimal scale. Pyth seconds multiply to milliseconds
  with a checked conversion, and both normalized named Aftermath market-oracle
  values and the feed timestamp must equal that one Pyth update. No caller can
  provide confidence or combine two updates.

### Pyth ABI port and snapshot classification amendment

The official `pyth-network/pyth-crosschain` source is pinned at
`6c1c9138e71a62629232607e252b12bcaa38356a`, subdirectory
`target_chains/sui/contracts`. Its legacy package manifest cannot be linked by
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
alongside zero price, mark, lot, or malformed exposure, in Series1's permissive
health observation.
It exists only for objective health synchronization, so an authenticated live
fault can move an active vault to `ReduceOnly` instead of aborting before that
state transition. It never weakens source identity or accepts caller-shaped
economics.

`Change` preserves raw collateral-token IFixed deltas. The ordinary
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
Series1 applies and emits them in chronological order and never nets them,
because reserve absorption is order-sensitive. Persisting the final checkpoint
makes both classifications exactly once. Any other collateral or equity delta,
zero-effect snapshot movement, or field mutation makes the complete
synchronization `Unexpected` and debits no reserve.

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

1. Capture a permissive pre-settlement checkpoint and the named Aftermath
   funding candidate at the captured market rates.
2. Call `clearing_house::settle_position_funding` with the bound collateral
   oracle.
3. Capture the post-settlement facts and classify both stored-to-pre and
   pre-to-post checkpoint edges.
4. Apply Series1 reserve settlement only for a nonzero, representable,
   isolated funding classification. Credits round down and costs round up at
   the six-decimal collateral boundary.
5. Finalize the one post-settlement health observation, persist its checkpoint,
   and then call Series1 health policy with the canonical share supply.
6. Emit completed accounting and health facts after all state mutation.

Stored-to-pre market-rate advancement is the expected precursor to local
funding settlement. A permissionless settlement already completed before this
call is accepted exactly once when its snapshot and collateral transition is
isolated. If rates advanced again afterward, the adapter also recognizes its
own pre-to-post settlement and applies the two funding effects in order without
netting. Every other stored-to-pre drift is an authenticated unexpected venue
change: the call persists the newest post checkpoint, does not debit the
reserve, and sets `checkpoint_clean = false` so Series1 can only preserve
lifecycle or degrade `Active` to `ReduceOnly`. A binding, type, storage/source,
Pyth identity, or representable observation agreement failure still aborts. No
health path can activate, resume, start shutdown, mint, burn, withdraw, place
an order, or increase risk.

`FundingSettled<Product>` occurs only for nonzero authenticated funding. It
records the Vault, credit/cost direction, exact raw collateral-IFixed amount,
conservative six-decimal amount, reserve absorption, uncovered cost, reserve
after settlement, and both the previous and post checkpoints.
`HealthSynchronized<Product>` occurs when lifecycle changes or an unexpected
checkpoint is persisted. Reason `0` is an objective Series1 health failure and
reason `1` is an unexpected checkpoint; it also records whether this call
changed lifecycle and the post checkpoint. Together with issuance, activation,
maximum-order-notional, risk-module rotation, and explicit reduce-only events,
these facts reconstruct the immutable bindings, reserve, lifecycle, selected
risk module, order limit, and latest checkpoint.

One package-private production helper owns the complete Blast post-capture
phase: funding normalization and reserve settlement, final health-observation
construction, exactly-one checkpoint persistence, lifecycle synchronization,
and conditional event emission. Local connected tests invoke that same helper
against real issued and Series-initialized Vault state; they do not duplicate
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
production call and mutation order. The replay test drives issuance,
activation, funding/health, order-limit, risk-rotation, and explicit-reduce-only
events through real package mutation seams, then compares every reconstructed
canonical fact to the resulting Vault. Task 8 must still execute the complete
permissionless path against controlled live objects and compare the resulting
checkpoint, reserve, lifecycle, and events.

## Consequences

- The adapter, not Series1 core, owns all volatile Aftermath dependencies.
- Builds are reproducible against one Aftermath and one Sui revision.
- Exact marker generics and cap binding remain visible in the committed ABI
  table.
- Raw mutation facts can detect out-of-band venue changes without storing
  display NAV, leverage, token price, or oracle prices.
- Funding can affect the protected reserve only after exact before/after
  checkpoint verification.
