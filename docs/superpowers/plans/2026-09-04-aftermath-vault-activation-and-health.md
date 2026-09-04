# Aftermath Vault Activation and Health Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Turn an issued, inert `Vault<Product>` into one atomically seeded and permanently bound Aftermath account, then let any caller reconcile funding and persist objective health degradation without adding public mint, redemption, or rebalance yet.

**Architecture:** The Aftermath adapter owns the account capability, object bindings, raw venue checkpoint, package version gate, and all calls into Aftermath. Series1 owns reserve accounting, immutable policy checks, target-notional math, and monotone lifecycle transitions. The adapter privately stores `State<Product>` and calls its public mutation functions directly; there is no witness-based handoff, `Bag`, adapter-local admin cap, or externally constructible order surface.

**Tech Stack:** Sui Move 2024, Sui CLI `1.77.2`, Aftermath `move-interfaces` revision `f62e74aa862ef65b8950a70d83aac8cb71c19837`, Node.js built-ins for ABI checks, repository `verify.sh` gates.

**Spec:** `/home/ubuntu/blast-v2/contracts/docs/decisions/0064-aftermath-backed-leverage-coins.md`, as superseded for package ownership by `/home/ubuntu/blast-v2/contracts/docs/decisions/0073-series-one-adapter-owned-vaults.md`, plus `/home/ubuntu/blast-v2/contracts/docs/leverage-implementation-lessons.md`.

## Global Constraints

- Preserve `Vault<phantom Product>` and `Coin<Vault<Product>>`; do not add a collateral or venue type parameter to the currency.
- Only the selected runtime risk-module witness may initialize an issued Vault.
- `State<Product>` construction during issuance remains the only Series1 State call that requires an `AdminWitness`; every later Series1 mutation relies on adapter custody.
- Initialization starts from zero share supply, opens exactly one bound position, locks all seed shares at `@0x0`, and changes `Uninitialized` to `Active` only after every venue and policy postcondition passes.
- Every individual Aftermath order must be at or below the live `max_order_notional`; a larger initialization target is split into several capped orders inside one session.
- Share pricing uses the Pyth-backed base index and collateral oracle. The order book and Aftermath mark are execution and margin checks only; they never supply shareholder NAV.
- Do not store display NAV, current leverage, token price, or oracle prices. Store only immutable bindings, reserve, lifecycle, and the smallest raw mutation checkpoint required for later reconciliation.
- `sync_health` is permissionless and may only preserve lifecycle or degrade it to `ReduceOnly`. It must not activate, resume, begin irreversible shutdown, mint, burn, withdraw, or increase risk.
- Do not add public mint, redemption, rebalance, shutdown, or donation routes in this slice.
- The official interface package contains ABI stubs that abort when unit-tested. Production ABI parity and mainnet `dev-inspect` are mandatory gates; synthetic unit tests cover only Blast-owned normalization and reconciliation code.
- Keep the current dirty foundation changes separate. Commit or otherwise checkpoint them before executing Task 1 so each task below has a reviewable diff.

---

## File Structure

### Series1

- Modify `sui/leverage_coins/series_one/sources/lifecycle.move` — add the sole production `Uninitialized -> Active` transition.
- Create `sui/leverage_coins/series_one/sources/observation.move` — venue-neutral, operation-scoped normalized price and position facts consumed by State.
- Modify `sui/leverage_coins/series_one/sources/state.move` — compute initialization targets, enforce activation policy, settle authenticated funding, and synchronize health.
- Modify `sui/leverage_coins/series_one/sources/lib/accounting_math.move` — expose no new raw-NAV API; add only reserve-aware helpers required by activation and funding reconciliation.
- Modify `sui/leverage_coins/series_one/sources/lib/errors.move` and tests — append activation and observation failures without reusing retired codes.
- Modify `sui/leverage_coins/series_one/scripts/check_source_boundaries.sh` — pin the new public surface and lifecycle-construction rules.
- Create `sui/leverage_coins/series_one/tests/observation_tests.move` and extend lifecycle/state/accounting tests.

### Aftermath adapter

- Modify `sui/leverage_coins/aftermath_adapter/Move.toml` and `Move.lock` — pin the official interface graph at one immutable revision.
- Create `sui/leverage_coins/aftermath_adapter/sources/snapshot.move` — normalize authenticated Aftermath and Pyth state into Series1 observations.
- Create `sui/leverage_coins/aftermath_adapter/sources/venue_account.move` — store the only account admin cap, immutable object/type bindings, and raw mutation checkpoint.
- Create `sui/leverage_coins/aftermath_adapter/sources/operations.move` — orchestrate risk-module initialization and permissionless health sync.
- Modify `sui/leverage_coins/aftermath_adapter/sources/vault.move` — add an optional typed `VenueAccount` field and package-only accessors; keep issuance, sharing, and admin routes here.
- Modify `sui/leverage_coins/aftermath_adapter/sources/lib/events.move` and `sources/lib/errors.move` — append replay facts and exact adapter failures.
- Modify `sui/leverage_coins/aftermath_adapter/scripts/check_source_boundaries.sh` and `scripts/verify.sh` — enforce bindings, cap confinement, route shape, and the live ABI gate.
- Create `sui/leverage_coins/aftermath_adapter/scripts/check_mainnet_abi.mjs` — verify chain, lineage, module ABI, manifest, and lockfile using Node built-ins only.
- Create `sui/leverage_coins/aftermath_adapter/tests/snapshot_tests.move`, `venue_account_tests.move`, and `operations_tests.move`.

### Decisions and evidence

- Create `docs/decisions/0074-aftermath-vault-activation-and-health.md` — record the exact normalized formulas, bindings, checkpoint, event schema, and P16-P19 evidence.
- Modify `docs/decisions/README.md`, both leverage package READMEs, `docs/error-codes.md`, and `docs/leverage-implementation-lessons.md` after the gates pass.

---

### Task 1: Freeze the live Aftermath dependency and falsify the ABI premises

**Files:**
- Modify: `sui/leverage_coins/aftermath_adapter/Move.toml`
- Modify: `sui/leverage_coins/aftermath_adapter/Move.lock`
- Create: `sui/leverage_coins/aftermath_adapter/scripts/check_mainnet_abi.mjs`
- Modify: `sui/leverage_coins/aftermath_adapter/scripts/verify.sh`
- Create: `docs/decisions/0074-aftermath-vault-activation-and-health.md`

**Interfaces:**
- Consumes: official `AftermathFinance/move-interfaces` revision `f62e74aa862ef65b8950a70d83aac8cb71c19837`, whose current `main` HEAD and published Move toolchain are both already verified as matching the repository's pin and Sui `1.77.2`.
- Produces: immutable dependencies on the `perpetuals`, `position`, `authority_cap`, `oracle_aggregator`, and `ifixed` subpackages; `node scripts/check_mainnet_abi.mjs [--self-test|--emit]`.

- [ ] **Step 1: Write the offline ABI-gate tests**

  Add `--self-test` fixtures for the correct chain identifier, wrong original package id, wrong current package id, wrong version, missing function, changed function signature, mutable Git revision, unexpected lock node, and malformed GraphQL response. Each fixture must assert the exact rejection message.

- [ ] **Step 2: Run the self-test and verify it fails before the checker exists**

  Run: `node scripts/check_mainnet_abi.mjs --self-test`

  Expected: failure because the script or expected interface table does not exist.

- [ ] **Step 3: Implement the immutable manifest and ABI checker**

  Pin every direct subpackage to the same full Git revision. Check at least these consumed declarations and their complete normalized signatures:

  ```text
  perpetuals::account::{create_account, consume_policy_and_share_account,
      deposit_collateral, withdraw_collateral, account_id, collateral_balance}
  perpetuals::clearing_house::{allocate_collateral, create_market_position,
      set_position_initial_margin_ratio, settle_position_funding, start_session,
      place_market_order, end_session, position, market_params, market_state,
      market_pause_mode, is_frozen, filled_base_and_quote, execution_price}
  perpetuals::market::{lot_size, base_storage_id, collateral_storage_id,
      base_source_id, collateral_source_id, margin_ratio_initial,
      margin_ratio_maintenance, cum_funding_rates}
  position::position::{collateral, base_and_quote_amounts,
      pending_base_amounts_by_side, pending_order_count,
      funding_rate_snapshots, initial_margin_ratio, is_long_or_flat,
      unrealized_pnl, abs_net_base}
  authority_cap::authority::for
  ```

  Copy the migrators package's strict GraphQL, manifest, and lock validation shape. Do not import npm packages and do not accept branch names or abbreviated revisions.

- [ ] **Step 4: Record the normalization evidence before writing contract math**

  In ADR 0074, write a table mapping each Blast primitive to its exact Aftermath getter, signed/fixed representation, decimal scale, rounding direction, and whether it is a stored checkpoint field. The table must cover free collateral, allocated collateral, signed base, signed quote notional, realized funding, unrealized PnL, base index, collateral price, mark, lot size, pending base on both sides, pending-order count, market pause/freeze state, IMR, and MMR. Reject the slice if any quantity cannot be derived without an unverified implementation assumption.

- [ ] **Step 5: Run the dependency gates**

  Run:

  ```bash
  node scripts/check_mainnet_abi.mjs --self-test
  node scripts/check_mainnet_abi.mjs
  sui move build --environment testnet
  sui move build --environment mainnet
  ```

  Expected: all pass, and the live package facts equal the committed expectation table.

- [ ] **Step 6: Commit the evidence gate**

  ```bash
  git add sui/leverage_coins/aftermath_adapter/Move.toml \
    sui/leverage_coins/aftermath_adapter/Move.lock \
    sui/leverage_coins/aftermath_adapter/scripts/check_mainnet_abi.mjs \
    sui/leverage_coins/aftermath_adapter/scripts/verify.sh \
    docs/decisions/0074-aftermath-vault-activation-and-health.md
  git commit -m "build(sui): pin Aftermath leverage interfaces"
  ```

### Task 2: Add a linear Series1 observation type

**Files:**
- Create: `sui/leverage_coins/series_one/sources/observation.move`
- Create: `sui/leverage_coins/series_one/tests/observation_tests.move`
- Modify: `sui/leverage_coins/series_one/sources/lib/errors.move`
- Modify: `sui/leverage_coins/series_one/tests/errors_tests.move`
- Modify: `sui/leverage_coins/series_one/README.md`

**Interfaces:**
- Consumes: normalized fields fixed by ADR 0074.
- Produces:

  ```move
  public struct PriceObservation { /* no abilities */ }
  public struct PositionObservation { /* no abilities */ }
  public enum FundingSettlement { /* no abilities: None, Credit(u64), Cost(u64) */ }

  public fun new_price(
      price: u64,
      confidence: u64,
      publish_time_ms: u64,
  ): PriceObservation

  public fun new_position(
      venue_equity: u64,
      absolute_base: u64,
      absolute_notional: u64,
      lot_size: u64,
      observed_side: PositionSide,
      pending_order_count: u64,
      margin_safe: bool,
      venue_operational: bool,
      checkpoint_clean: bool,
      base_index: PriceObservation,
      collateral_oracle: PriceObservation,
      mark_price: u64,
  ): PositionObservation

  public fun no_funding(): FundingSettlement
  public fun funding_credit(amount: u64): FundingSettlement
  public fun funding_cost(amount: u64): FundingSettlement
  ```

  These values are operation-scoped data, not authority. They have no `copy`, `drop`, or `store`, and only Series1 package code can unpack them. Test-only destroy functions consume isolated fixtures.

- [ ] **Step 1: Add constructor and linearity tests**

  Test zero price, zero lot size, contradictory flat/side data as defined by ADR 0074, and one valid long and short observation. Add source-boundary fixtures showing production code cannot declare either type with `copy`, `drop`, or `store`, and cannot expose the package-only unpack functions.

- [ ] **Step 2: Run the focused tests and verify the type is absent**

  Run: `sui move test observation_tests`

  Expected: failure because `observation` is unresolved.

- [ ] **Step 3: Implement constructors and package-only unpacking**

  Keep validation structural: positive normalized prices and lot size, representable fields, and exact position-shape consistency. Do not authenticate a Pyth object, Aftermath object, or caller in this module; the adapter owns source identity.

- [ ] **Step 4: Append and pin error codes**

  Add each new code at the end of the Series1 registry, then add a registry assertion, an `expected_failure` that pins the raising module, and a README row.

- [ ] **Step 5: Run Series1 gates**

  Run: `bash scripts/verify.sh all`

  Expected: boundaries, both builds, warning-as-error lint, and all tests pass.

- [ ] **Step 6: Commit the observation carrier**

  ```bash
  git add sui/leverage_coins/series_one
  git commit -m "feat(sui): add leverage operation observations"
  ```

### Task 3: Add the Series1 activation and health kernel

**Files:**
- Modify: `sui/leverage_coins/series_one/sources/lifecycle.move`
- Modify: `sui/leverage_coins/series_one/sources/state.move`
- Modify: `sui/leverage_coins/series_one/sources/lib/accounting_math.move`
- Modify: `sui/leverage_coins/series_one/sources/lib/errors.move`
- Modify: `sui/leverage_coins/series_one/scripts/check_source_boundaries.sh`
- Modify: `sui/leverage_coins/series_one/tests/lifecycle_tests.move`
- Modify: `sui/leverage_coins/series_one/tests/state_tests.move`
- Modify: `sui/leverage_coins/series_one/tests/maintenance_math_tests.move`

**Interfaces:**
- Consumes: one linear `PositionObservation`, existing `TierPolicy`, `maintenance_reserve`, and `Lifecycle`.
- Produces:

  ```move
  public fun initialization_target_notional<Product>(
      self: &State<Product>,
      seed_venue_equity: u64,
      seed_reserve: u64,
  ): u64

  public fun assert_order_notional_allowed<Product>(
      self: &State<Product>,
      order_notional: u64,
  )

  public fun initialize<Product>(
      self: &mut State<Product>,
      observation: PositionObservation,
      seed_reserve: u64,
      reference_time_ms: u64,
  ): u64

  public fun settle_funding<Product>(
      self: &mut State<Product>,
      settlement: FundingSettlement,
  ): (u64, u64)

  public fun sync_health<Product>(
      self: &mut State<Product>,
      observation: PositionObservation,
      share_supply: u64,
      reference_time_ms: u64,
  ): bool
  ```

  `initialize` returns the reserve-excluded seed shareholder NAV. `settle_funding` returns `(absorbed_by_reserve, uncovered_cost)`. `sync_health` returns true only when this call changed `Active` to `ReduceOnly`; it never restores or starts shutdown.

- [ ] **Step 1: Write lifecycle transition tests**

  Pin the only legal activation edge as `Uninitialized -> Active`. Repeat activation from every other lifecycle and assert code 17 from `lifecycle`. Keep direct `Lifecycle::Active` construction test-only.

- [ ] **Step 2: Write activation policy tests**

  Cover reserve above/equal to equity, zero shareholder NAV, NAV cap equality and one unit above, correct and wrong side, pending orders, stale/future/confidence-invalid base and collateral prices, mark divergence, unsafe margin, paused venue, dirty checkpoint, leverage at both healthy boundaries, leverage one unit outside, base below the immutable lot minimum, and a valid long and short seed. Verify all failures leave reserve zero and lifecycle uninitialized.

- [ ] **Step 3: Write per-order and funding tests**

  Assert that order notional at the live maximum passes and one unit above fails. For funding, cover positive funding, zero amount, a cost below reserve, equal to reserve, above reserve, and `u64` boundaries. The pure function must never infer funding from an equity delta. Exact-once settlement belongs to the adapter checkpoint tests in Task 7 because Series1 intentionally stores no venue funding cursor.

- [ ] **Step 4: Write health degradation tests**

  For each objective failure, assert one successful `Active -> ReduceOnly` mutation: reserve impairment, zero NAV, stale or low-confidence oracle, mark divergence, wrong side, pending order, unsafe margin, paused/frozen venue, dirty checkpoint, hard-cap leverage, and redemption-impossible dust exposure. Repeat each sync in `ReduceOnly` and assert no further lifecycle change. Assert `Uninitialized` fails and `ShutdownPending`/`ShutdownSettled` never move backward.

- [ ] **Step 5: Implement guard order and transitions**

  Apply checks in this order: lifecycle; reserve backing; positive NAV; both valuation freshness/confidence gates against the same `reference_time_ms`; mark/index divergence; exact side; empty orders; venue operational state; checkpoint cleanliness; margin; NAV cap for activation; conservative accounting leverage; minimum-operation/redemption viability. Run every check before mutating reserve or lifecycle.

- [ ] **Step 6: Strengthen the boundary script**

  Pin the exact new production State surface, permit only one production call to the lifecycle activation transition, reject direct lifecycle assignment, and continue rejecting venue/oracle names from Series1.

- [ ] **Step 7: Run Series1 gates**

  Run: `bash scripts/verify.sh all`

  Expected: all gates pass with no lint warnings.

- [ ] **Step 8: Commit the state kernel**

  ```bash
  git add sui/leverage_coins/series_one
  git commit -m "feat(sui): add leverage activation and health kernel"
  ```

### Task 4: Add exact Aftermath capability custody and binding

**Files:**
- Create: `sui/leverage_coins/aftermath_adapter/sources/venue_account.move`
- Create: `sui/leverage_coins/aftermath_adapter/tests/venue_account_tests.move`
- Modify: `sui/leverage_coins/aftermath_adapter/sources/vault.move`
- Modify: `sui/leverage_coins/aftermath_adapter/tests/vault_tests.move`
- Modify: `sui/leverage_coins/aftermath_adapter/sources/lib/errors.move`

**Interfaces:**
- Consumes: `AuthorityCap<ACCOUNT, ADMIN>` and the normalized checkpoint layout fixed in ADR 0074.
- Produces `Binding` and `Checkpoint` with `copy, drop, store`, plus a store-only, non-key `VenueAccount` containing these fields:

  ```text
  admin_cap
  account_object_id
  account_number
  registry_id
  clearing_house_id
  base_oracle_id
  collateral_oracle_id
  collateral_type
  checkpoint
  ```

  `Binding` contains the five object ids, account number, and collateral `TypeName` without the cap or checkpoint. `Vault<Product>` gains `venue_account: Option<VenueAccount>`, initialized to `none`. Initialization can validate snapshots against a `Binding` before it constructs `VenueAccount`. No public function returns or mutably borrows the cap or VenueAccount.

- [ ] **Step 1: Write custody and binding tests**

  Test a valid cap whose `authority::for` equals the account object id. Reject a wrong cap, account, registry, clearing house, base oracle, collateral oracle, and collateral `TypeName` independently. Use a test-only literal checkpoint constructor. Assert a second installation aborts and issuance still returns `none`.

- [ ] **Step 2: Run focused tests and verify failure**

  Run: `sui move test venue_account_tests`

  Expected: failure because `VenueAccount` is unresolved.

- [ ] **Step 3: Implement sealed custody**

  Give `VenueAccount` only `store`; give `Binding` and `Checkpoint` `copy, drop, store`. Expose package-only exact-binding assertions, immutable binding access, checkpoint replacement, and only the narrow cap borrows required by named adapter operations. Recheck `authority::for(cap)` before every use.

- [ ] **Step 4: Extend Vault without changing its currency type**

  Add the typed option field, install it once after successful initialization, and keep `issue` returning an uninitialized Vault with no venue state. Do not add `Bag`, dynamic venue storage, another admin capability, or another Vault type parameter.

- [ ] **Step 5: Append errors and run adapter gates**

  Add append-only error codes with registry, raising-module, README, and precedence tests. Run: `bash scripts/verify.sh all`.

- [ ] **Step 6: Commit capability custody**

  ```bash
  git add sui/leverage_coins/aftermath_adapter
  git commit -m "feat(sui): bind leverage vault to Aftermath account"
  ```

### Task 5: Implement authenticated snapshot normalization and checkpoint classification

**Files:**
- Create: `sui/leverage_coins/aftermath_adapter/sources/snapshot.move`
- Create: `sui/leverage_coins/aftermath_adapter/tests/snapshot_tests.move`
- Modify: `sui/leverage_coins/aftermath_adapter/sources/lib/errors.move`
- Modify: `docs/decisions/0074-aftermath-vault-activation-and-health.md`

**Interfaces:**
- Consumes: bound Aftermath account, clearing house, registry, both exact oracle objects, clock, immutable binding, and the conversion table from Task 1.
- Produces:

  ```move
  public(package) fun capture<Collateral>(
      binding: &Binding,
      account: &Account<Collateral>,
      registry: &Registry,
      clearing_house: &ClearingHouse<Collateral>,
      base_oracle: &PriceFeedStorage,
      collateral_oracle: &PriceFeedStorage,
      clock: &Clock,
  ): (PositionObservation, Checkpoint)

  public(package) fun classify_change(
      before: &Checkpoint,
      after: &Checkpoint,
  ): Change
  ```

  `Change` distinguishes `Unchanged`, one exact positive-funding settlement, one exact negative-funding settlement, and `Unexpected`. It never classifies a total-equity delta as funding.

- [ ] **Step 1: Write independent normalization vectors**

  Transcribe long, short, flat, positive/negative PnL, positive/negative funding, USDC depeg, minimum lot, maximum-width, and every half-way rounding boundary from the approved Aftermath reference into test vectors. Expected numbers must be literal independently calculated values, not values produced by the Move helper under test.

- [ ] **Step 2: Write checkpoint classification tests**

  Change each raw field alone. Only the documented funding snapshot transition may classify as funding. Liquidation, ADL, base/quote change, collateral movement, pending base, pending order count, market-state change, and combined changes must classify `Unexpected`.

- [ ] **Step 3: Run focused tests and verify failure**

  Run: `sui move test snapshot_tests`

  Expected: failure because `snapshot` is unresolved.

- [ ] **Step 4: Implement checked normalization**

  Use `u256` intermediates, explicit sign extraction, and named narrowing helpers. Round NAV components against the Vault when uncertainty exists, round absolute notional up for risk, and reject an unrepresentable value instead of saturating. Build the Series1 observation only after every object id, source id, collateral type, clock, and market binding matches.

- [ ] **Step 5: Add swap and sign-flip adversarial tests**

  Swap base/index, collateral/index, free/allocated collateral, signed base/quote, and long/short funding inputs one pair at a time. Flip a long through flat into short and vice versa. Every swap or sign flip must either change the literal expected result or abort at the exact binding/direction code.

- [ ] **Step 6: Run adapter gates**

  Run: `bash scripts/verify.sh all`

  Expected: all gates pass; the official ABI stubs are never executed by unit tests.

- [ ] **Step 7: Commit normalization**

  ```bash
  git add sui/leverage_coins/aftermath_adapter docs/decisions/0074-aftermath-vault-activation-and-health.md
  git commit -m "feat(sui): normalize Aftermath leverage snapshots"
  ```

### Task 6: Implement atomic risk-module initialization

**Files:**
- Create: `sui/leverage_coins/aftermath_adapter/sources/operations.move`
- Create: `sui/leverage_coins/aftermath_adapter/tests/operations_tests.move`
- Modify: `sui/leverage_coins/aftermath_adapter/sources/vault.move`
- Modify: `sui/leverage_coins/aftermath_adapter/sources/lib/events.move`
- Modify: `sui/leverage_coins/aftermath_adapter/sources/lib/errors.move`
- Modify: `sui/leverage_coins/aftermath_adapter/scripts/check_source_boundaries.sh`

**Interfaces:**
- Consumes: selected `RiskModule`, protocol seed `Coin<Collateral>`, six-decimal `Currency<Collateral>`, Aftermath Registry/ClearingHouse/oracles/Clock, and an issued Vault.
- Produces:

  ```move
  public fun initialize<Product, RiskModule: drop, Collateral>(
      vault: &mut Vault<Product>,
      protocol: &Protocol,
      risk_module: RiskModule,
      currency: &Currency<Collateral>,
      registry: &mut Registry,
      clearing_house: ClearingHouse<Collateral>,
      base_oracle: &PriceFeedStorage,
      collateral_oracle: &PriceFeedStorage,
      seed: Coin<Collateral>,
      seed_reserve: u64,
      position_imr: u256,
      clock: &Clock,
      ctx: &mut TxContext,
  )
  ```

  The function returns no assets. It stores the only admin cap, shares the Aftermath account and returned clearing house, stores the checkpoint, mints the seed shares, sends them to `@0x0`, and emits `VaultInitialized<Product>`.

- [ ] **Step 1: Write orchestration and rollback tests around Blast-owned seams**

  Test stale adapter version, wrong/rotated risk witness, already initialized Vault, non-six-decimal collateral, zero seed, invalid reserve, wrong bindings, a target above one order cap splitting into multiple compliant orders, zero/partial fill, posted order, strict-tolerance failure, wrong side, bad IMR, unhealthy final leverage, cap-authority mismatch, nonzero preexisting supply, and final event fields. Inject an abort after each Blast-owned phase and assert State, supply, capability option, and checkpoint all roll back.

- [ ] **Step 2: Run focused tests and verify failure**

  Run: `sui move test operations_tests`

  Expected: failure because `operations::initialize` is unresolved.

- [ ] **Step 3: Implement the exact call sequence**

  Use this order:

  ```text
  adapter version -> selected risk witness -> uninitialized Vault -> currency decimals
  -> create Account/cap/policy -> verify cap binding -> deposit seed
  -> allocate collateral -> create one position -> set IMR
  -> capture one Pyth valuation pair and reference clock
  -> ask State for target notional -> convert down to whole base lots
  -> split into market orders whose absolute index notional is each <= max_order_notional
  -> end one session with no posted orders -> settle funding
  -> capture final snapshot -> enforce strict execution and all State activation gates
  -> mint `seed_nav * 1_000` atomic shares with checked widening
  -> transfer seed shares to @0x0 -> consume account share policy and share account
  -> install VenueAccount -> share returned ClearingHouse -> emit event
  ```

  A zero, partial, wrong-side, or resting-order result aborts the whole transaction. Do not let the caller provide side, order direction, order size, market id, source id, or share amount.

- [ ] **Step 4: Emit one replay-complete activation fact**

  `VaultInitialized<Product>` records Vault id, account object id and number, Registry/ClearingHouse/oracle ids, collateral type, seed amount, seed venue equity, seed reserve, seed shareholder NAV, locked shares, absolute base/notional, lot size, position side, IMR, and the initial raw checkpoint. It omits sender, display NAV, display share price, and current leverage because those are derivable.

- [ ] **Step 5: Pin the source boundary**

  Require initialization to authenticate the selected risk witness, require one VenueAccount installation, forbid any public cap accessor or generic order function, and assert every public adapter mutation starts with `protocol.assert_current()`.

- [ ] **Step 6: Run both package gates**

  Run:

  ```bash
  (cd ../series_one && bash scripts/verify.sh all)
  bash scripts/verify.sh all
  ```

  Expected: all gates pass.

- [ ] **Step 7: Commit atomic activation**

  ```bash
  git add sui/leverage_coins/aftermath_adapter
  git commit -m "feat(sui): initialize Aftermath leverage vaults"
  ```

### Task 7: Implement permissionless funding reconciliation and health sync

**Files:**
- Modify: `sui/leverage_coins/aftermath_adapter/sources/operations.move`
- Modify: `sui/leverage_coins/aftermath_adapter/sources/lib/events.move`
- Modify: `sui/leverage_coins/aftermath_adapter/sources/lib/errors.move`
- Modify: `sui/leverage_coins/aftermath_adapter/tests/operations_tests.move`
- Modify: `docs/decisions/0074-aftermath-vault-activation-and-health.md`

**Interfaces:**
- Consumes: current bound Aftermath objects and stored checkpoint.
- Produces:

  ```move
  public fun sync_health<Product, Collateral>(
      vault: &mut Vault<Product>,
      protocol: &Protocol,
      account: &mut Account<Collateral>,
      registry: &Registry,
      clearing_house: &mut ClearingHouse<Collateral>,
      base_oracle: &PriceFeedStorage,
      collateral_oracle: &PriceFeedStorage,
      clock: &Clock,
  )
  ```

- [ ] **Step 1: Write exact-once funding tests**

  Cover no funding change, positive funding, a negative cost smaller/equal/larger than reserve, a second call at the same checkpoint, funding plus PnL, funding plus collateral movement, and funding plus liquidation. Only the isolated authenticated funding delta may debit reserve, and it may do so once.

- [ ] **Step 2: Write permissionless degradation tests**

  Invoke `sync_health` from an unrelated sender. For every Series and adapter health failure, assert the transaction succeeds, the latest observed checkpoint is stored, `Active` becomes `ReduceOnly`, and a stable reason is emitted. Healthy sync leaves lifecycle unchanged. Repeated unhealthy sync is idempotent. No case reaches `ShutdownPending`.

- [ ] **Step 3: Implement reconciliation before policy evaluation**

  Recheck all immutable ids and the cap-to-account relation, capture the pre-settlement checkpoint, invoke the documented Aftermath funding settlement, capture the post-settlement checkpoint, classify it, and call `State::settle_funding` only for the exact authenticated funding amount. Any unexpected change sets `checkpoint_clean = false`; it is not relabeled as funding.

- [ ] **Step 4: Persist objective health**

  Construct one Series1 `PositionObservation` from the post-settlement snapshot and call `State::sync_health`. Store the new checkpoint whether healthy or degraded so a later reduce-only operation starts from current facts. Emit `FundingSettled<Product>` only for a nonzero authenticated funding change and `HealthSynchronized<Product>` for every lifecycle change or unexpected checkpoint.

- [ ] **Step 5: Pin event replay**

  Replay issuance, activation, funding, health, max-order-notional, risk rotation, and explicit reduce-only events into a tiny test reducer. Assert reconstructed bindings, reserve, lifecycle, risk witness, order limit, and checkpoint equal final object state.

- [ ] **Step 6: Run both package gates**

  Run both `bash scripts/verify.sh all` commands. Expected: all gates pass.

- [ ] **Step 7: Commit health sync**

  ```bash
  git add sui/leverage_coins/aftermath_adapter docs/decisions/0074-aftermath-vault-activation-and-health.md
  git commit -m "feat(sui): synchronize leverage vault health"
  ```

### Task 8: Prove the complete vertical slice against mainnet state

**Files:**
- Modify: `sui/leverage_coins/aftermath_adapter/scripts/check_mainnet_abi.mjs`
- Create: `sui/leverage_coins/aftermath_adapter/scripts/dev_inspect_activation.mjs`
- Create: `sui/leverage_coins/aftermath_adapter/scripts/fixtures/activation-vectors.json`
- Modify: `sui/leverage_coins/aftermath_adapter/scripts/verify.sh`
- Modify: `docs/decisions/0074-aftermath-vault-activation-and-health.md`
- Modify: `sui/leverage_coins/series_one/README.md`
- Modify: `sui/leverage_coins/aftermath_adapter/README.md`
- Modify: `docs/leverage-implementation-lessons.md`
- Modify: `docs/error-codes.md`
- Modify: `docs/decisions/README.md`

**Interfaces:**
- Consumes: complete activation and sync implementation.
- Produces: deterministic `--self-test` vectors and a read-only mainnet `dev-inspect` gate for P16-P19.

- [ ] **Step 1: Add offline transaction-builder and response fixtures**

  Pin the exact PTB call order, type arguments, object ids, result indices, and normalized outputs. Include malformed result count, wrong object type, one-unit normalization mismatch, and a simulated external mutation.

- [ ] **Step 2: Run self-tests before the script exists**

  Run: `node scripts/dev_inspect_activation.mjs --self-test`

  Expected: failure because the script is unresolved.

- [ ] **Step 3: Implement read-only mainnet dev-inspect**

  Use Node's built-in `child_process` to drive `sui client ptb --dev-inspect`. Build the complete create-account, deposit, allocate, position-create, IMR, multi-order session, funding settlement, snapshot, account-share, and object-return flow without signing or broadcasting. Compare every normalized result with `activation-vectors.json`. Never use an HTTP quote as authority.

- [ ] **Step 4: Falsify P16-P19 one transition at a time**

  Run mainnet read-only inspection for account/session composition and current long/short market state. Run long, short, flat, funding in both directions, partial liquidation, ADL/settlement, collateral movement, pending order, pause/freeze, and stale-oracle cases against a controlled local or testnet fixture. Require the checkpoint classifier and health outcome stated in ADR 0074. A material transition that leaves the checkpoint equal blocks completion.

- [ ] **Step 5: Update the durable docs**

  Move every now-enforced rule out of `docs/leverage-implementation-lessons.md` into ADR 0074 or the package READMEs. State explicitly that the packages still cannot accept public mints and that the next slice is mint/redeem only after activation and health parity remain green.

- [ ] **Step 6: Run the final release gate**

  Run:

  ```bash
  node scripts/check_mainnet_abi.mjs --self-test
  node scripts/check_mainnet_abi.mjs
  node scripts/dev_inspect_activation.mjs --self-test
  node scripts/dev_inspect_activation.mjs
  (cd ../series_one && bash scripts/verify.sh all)
  bash scripts/verify.sh all
  git diff --check
  ```

  Expected: every command passes; no warning, network mismatch, uncommitted generated lock drift, or one-unit parity mismatch remains.

- [ ] **Step 7: Commit the integration proof**

  ```bash
  git add docs sui/leverage_coins/series_one sui/leverage_coins/aftermath_adapter
  git commit -m "test(sui): prove Aftermath leverage activation"
  ```

---

## Explicit Stop Line

This chunk is complete when an issued Vault can be atomically initialized against one exact Aftermath account, the only admin capability is sealed inside it, seed shares are permanently locked, funding is reconciled exactly once, and any caller can persist objective `ReduceOnly` degradation.

Do not add public mint, redemption, rebalance, shutdown, or donation in the same review. The next plan can build mint and redemption on this proven checkpoint and valuation substrate without guessing venue behavior.
