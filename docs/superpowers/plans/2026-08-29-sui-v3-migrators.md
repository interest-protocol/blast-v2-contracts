# Sui V3 DEX Migrators Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Build Bluefin, MMT, Cetus, Turbos, and Full Sail Sui migration packages that initialize or safely adopt a CLMM at the real seed-balance price, permanently lock the position, split LP fees between creator and protocol, and keep residuals in protocol-owned vault custody.

**Architecture:** `blast_fun` adds venue-neutral X64 price math and an external runtime-accrual seam on its existing dual-asset fee ledger. One aggregate migrators package depends inward on that ABI and on exact compatible venue revisions. It owns one shared per-launch `LpVault` implementation, including protocol residual custody, while five modules own sealed witnesses and venue-specific creation, ordering, tick, and collection calls. Each venue position is a dynamic object field keyed by its sealed marker.

**Tech Stack:** Sui Move 2024, Sui CLI `1.77.2-51d177ad7d65`, `u256` integer arithmetic, shell source-boundary checks, exact Git dependency SHAs.

**Spec:** `docs/decisions/0054-v3-dex-migrators-and-locked-lp-fees.md`

## Global Constraints

- Preserve all pre-existing user changes in the dirty contracts and SDK repositories.
- Core imports no venue package; all five adapters are modules in one child Move package.
- All Git dependencies and transitive overrides use immutable full commit SHAs from ADR 0054.
- No production module exposes or calls dynamic-object-field removal, position transfer, close, burn, decrease-liquidity, or remove-liquidity functionality.
- The package is not permanently locked until every venue's published ABI and dev-inspect checks pass and its single `UpgradeCap` is destroyed.
- Price is derived on chain from real Meme and net Quote atomic balances; display decimals and USD prices never enter CLMM math.
- New-pool price deviation is zero; adopted Cetus/Turbos/Full Sail price deviation is at most 50 bps.
- Returned migration residuals are at most 1 bps of each source balance and stay in protocol-owned vault custody.
- Bluefin pool-opening fee must read as supported and exactly zero.
- LP fees use the current `protocol_fee_share_bps`; protocol rounds up and creator receives the remainder.
- Tests precede production changes and each red test must be observed failing for the intended reason.

---

### Task 1: Core migration price arithmetic

**Files:**
- Create: `sui/migrators/sources/migration_math.move`
- Create: `sui/migrators/tests/migration_math_tests.move`
- Modify: `sui/launchpad/sources/lib/errors.move`
- Modify: `docs/error-codes.md`

**Interfaces:**
- Produces: `migration_math::sqrt_price_x64(u64, u64, bool): u128`
- Produces: `migration_math::assert_price_within_bps(u64, u64, bool, u128, u64)`
- Produces: `migration_math::minimum_utilized_amount(u64, u64): u64`
- Produces: `migration_math::assert_residual_within_bps(u64, u64, u64)`

- [x] **Step 1: Write price tests before the module exists**

Add focused tests for `1:1 -> 2^64`, both reciprocal type orders, the committed Quote-decimal vectors, floor-square behavior, zero balances, `u64::MAX`, 50-bps acceptance/rejection, and 1-bps residual boundaries.

- [x] **Step 2: Run the focused suite and observe RED**

Run: `cd sui/migrators && sui move test migration_math_tests`

Expected: compilation fails because `blast_fun_migrators::migration_math` does not exist.

- [x] **Step 3: Add append-only errors and bounded `u256` math**

Implement:

```move
public fun sqrt_price_x64(
    meme_amount: u64,
    quote_amount: u64,
    meme_is_coin_a: bool,
): u128

public fun assert_price_within_bps(
    meme_amount: u64,
    quote_amount: u64,
    meme_is_coin_a: bool,
    actual_sqrt_price_x64: u128,
    max_deviation_bps: u64,
)

public fun minimum_utilized_amount(amount: u64, max_residual_bps: u64): u64

public fun assert_residual_within_bps(
    source_amount: u64,
    residual_amount: u64,
    max_residual_bps: u64,
)
```

Use a fixed upper-exclusive `2^96` binary-search bound because the numerator and denominator are positive `u64` values and the Q128 ratio is below `2^192`.

- [x] **Step 4: Run RED-to-GREEN verification**

Run: `cd sui/migrators && sui move test migration_math_tests`

Expected: all migration-math tests pass.

- [x] **Step 5: Run the complete core suite**

Run: `cd sui/launchpad && sui move test --lint`

Expected: all existing and new tests pass without warnings.

- [x] **Step 6: Commit only Task 1 files**

```bash
git add sui/migrators/sources/migration_math.move sui/migrators/tests/migration_math_tests.move docs/error-codes.md
git commit -m "feat(sui): add exact migration price math"
```

### Task 2: Reusable LP fee accounting

**Files:**
- Modify: `sui/launchpad/sources/runtime_config.move`
- Modify: `sui/launchpad/sources/fees.move`
- Modify: `sui/launchpad/sources/launch.move`
- Modify: `sui/launchpad/sources/lib/events.move`
- Modify: `sui/launchpad/sources/lib/errors.move`
- Modify: `sui/launchpad/tests/runtime_config_tests.move`
- Modify: `sui/launchpad/tests/fees_tests.move`
- Modify: `sui/launchpad/tests/launch_tests.move`
- Modify: `docs/error-codes.md`

**Interfaces:**
- Produces: `runtime_config::protocol_fee_share_bps(&RuntimeConfig): u64`
- Produces: `fees::new<Meme, Quote>(): FeeLedger<Meme, Quote>` as a public constructor
- Produces: `fees::accrue_from_runtime(&mut FeeLedger<Meme, Quote>, Balance<Meme>, Balance<Quote>, &RuntimeConfig)`
- Produces: public creator/protocol ledger claims for adapter-owned ledgers

- [x] **Step 1: Add failing runtime and external-accrual tests**

Test package-version guard precedence, raw public fee-share reads, prospective
live-share accrual, and creator/protocol claim isolation.

- [x] **Step 2: Observe RED**

Run: `cd sui/launchpad && sui move test runtime_config_tests && sui move test fees_tests`

Expected: compilation fails on the missing external-accrual seams.

- [x] **Step 3: Implement the minimum public ABI**

Rename the package-only validated BPS read to `protocol_fee_share` and make the
raw `protocol_fee_share_bps` getter public. Add
`FeeLedger::accrue_from_runtime` and widen only the constructor, totals, and two
claim methods needed by adapters.

- [x] **Step 4: Update core callers and prove GREEN**

Run: `cd sui/launchpad && sui move test --lint`

Expected: all core tests pass.

- [x] **Step 5: Commit only Task 2 files**

```bash
git add sui/launchpad/sources/runtime_config.move sui/launchpad/sources/fees.move sui/launchpad/sources/launch.move sui/launchpad/sources/lib/events.move sui/launchpad/sources/lib/errors.move sui/launchpad/tests/runtime_config_tests.move sui/launchpad/tests/fees_tests.move sui/launchpad/tests/launch_tests.move docs/error-codes.md
git commit -m "feat(sui): expose live treasury and LP fee ledger seam"
```

### Task 3: Graduation valuation vectors and disclosure

**Files:**
- Modify: `docs/vectors/graduation.json`
- Modify: `docs/decisions/README.md`
- Modify: `docs/architecture.md`
- Modify: `README.md`
- Test: existing SDK `test/launch-economics.test.ts` without editing the dirty SDK tree

**Interfaces:**
- Produces: a `recommended_sui_lane` vector with `V = T = 8_000 SUI`, zero terminal fees, 20% Meme provision, and equal 40,000-SUI terminal valuations.

- [x] **Step 1: Add the vector before documentation claims it is supported**

The literal expected values are:

```json
{
  "terminal_curve_meme": "400000000000000000",
  "curve_meme_released": "400000000000000000",
  "quote_migration_fee": "0",
  "net_quote": "8000000000000",
  "opening_valuation": "10000000000000",
  "curve_terminal_valuation": "40000000000000",
  "dex_opening_valuation": "40000000000000"
}
```

- [x] **Step 2: Run the SDK economics suite against the same formula**

Run: `cd ../sdk && npm test -- --test-name-pattern='launch|economics'`

Expected: the existing exact-integer economics tests pass; independently inspect the new vector with the same formulas.

- [x] **Step 3: Update indexes and architecture language**

Document that the recommended lane is operational configuration, not an
on-chain USD oracle or immutable global default. Record Memez, Raydium, Hop, and
Pump comparison limits from ADR 0054.

- [x] **Step 4: Validate JSON and commit only Task 3 files**

Run: `jq empty docs/vectors/graduation.json`

```bash
git add docs/vectors/graduation.json docs/decisions/0054-v3-dex-migrators-and-locked-lp-fees.md docs/decisions/README.md docs/architecture.md README.md docs/superpowers/plans/2026-08-29-sui-v3-migrators.md
git commit -m "docs: accept locked V3 migration design"
```

### Task 4: Bluefin adapter

**Files:**
- Create: `sui/migrators/Move.toml`
- Create: `sui/migrators/sources/vault.move`
- Create: `sui/migrators/sources/bluefin.move`
- Create: `sui/migrators/scripts/check_source_boundaries.sh`
- Create: `sui/migrators/README.md`

**Interfaces:**
- Produces: sealed `blast_fun_migrators::bluefin::Witness` and `Venue`
- Produces: shared per-launch `vault::LpVault<Meme, Quote>` with the position
  attached as a sealed-marker dynamic object field
- Produces: one deterministic `bluefin::migrate` route with Meme coin A
- Produces: `bluefin::collect_fees`, `vault::claim_creator_fees`, and
  `vault::claim_protocol_fees`

- [x] **Step 1: Add a failing structural boundary check**

The script must require the witness, shared vault, dynamic object-field add and
borrow, migration, collection, and claim symbols. It must reject
`dynamic_object_field::remove`, `remove_liquidity`, `close_position`, position
transfer, position burn, and any nonzero creation-fee balance construction.

- [x] **Step 2: Observe RED**

Run: `bash sui/migrators/scripts/check_source_boundaries.sh`

Expected: failure because the aggregate package and production modules do not
exist.

- [x] **Step 3: Implement the Bluefin migration and vault**

First implement the common vault with one dynamic object field keyed by
`PositionKey<Venue>`. Expose package-only typed construction and borrow, never
removal. Expose creator/protocol fee claims once from the vault module.

Use exact Bluefin and compatible normalized transitive pins. Read the
Quote-denominated creation fee, assert `supported && fee == 0`, always derive
the direct Quote/Meme price for `Pool<Meme, Quote>`, align the config-provided
full tick range, call `create_pool_with_liquidity`, enforce 1-bps residual
limits, keep residuals in protocol-owned vault custody, attach the position,
and share the vault. Collection must compare `position::liquidity` before/after and
accrue normalized Meme/Quote balances through
`FeeLedger::accrue_from_runtime`.

- [x] **Step 4: Prove GREEN**

Run:

```bash
cd sui/migrators
sui move build
sui move lint --warnings-are-errors
bash scripts/check_source_boundaries.sh
```

- [x] **Step 5: Commit only the shared vault and Bluefin slice**

```bash
git add sui/migrators/Move.toml sui/migrators/Move.lock sui/migrators/README.md sui/migrators/scripts/check_source_boundaries.sh sui/migrators/sources/vault.move sui/migrators/sources/bluefin.move
git commit -m "feat(sui): add shared migrator vault and Bluefin"
```

### Task 5: MMT module

**Files:**
- Modify: `sui/migrators/Move.toml`
- Create: `sui/migrators/sources/mmt.move`
- Modify: `sui/migrators/scripts/check_source_boundaries.sh`
- Modify: `sui/migrators/README.md`

**Interfaces:**
- Produces MMT migration/collection against the common vault and common claims.

- [x] **Step 1: Add and run the failing MMT boundary check**

Run: `bash sui/migrators/scripts/check_source_boundaries.sh`

Expected: failure because the production module is missing.

- [x] **Step 2: Implement MMT create-initialize-add-share ordering**

Use `check_coin_order`, `create_pool::new`, `pool::initialize`, venue full-range
tick helpers, `liquidity::open_position`, `liquidity::add_liquidity`, and finally
`pool::transfer`. Set both minimum used amounts from core's 1-bps helper. Normalize
fee coins from `collect::fee`, verify unchanged `position::liquidity`, and accrue
through the core ledger.

- [x] **Step 3: Build, lint, and prove the boundary**

Run:

```bash
cd sui/migrators
sui move build
sui move lint --warnings-are-errors
bash scripts/check_source_boundaries.sh
```

- [x] **Step 4: Commit only the MMT slice**

```bash
git add sui/migrators/Move.toml sui/migrators/Move.lock sui/migrators/README.md sui/migrators/scripts/check_source_boundaries.sh sui/migrators/sources/mmt.move
git commit -m "feat(sui): add MMT locked migration vault"
```

### Task 6: Cetus module

**Files:**
- Create: `sui/migrators/interfaces/cetus/Move.toml`
- Create: minimal normalized ABI modules under `sui/migrators/interfaces/cetus/sources/`
- Modify: `sui/migrators/Move.toml`
- Create: `sui/migrators/sources/cetus.move`
- Modify: `sui/migrators/scripts/check_source_boundaries.sh`
- Modify: `sui/migrators/README.md`

**Interfaces:**
- Produces new-pool and explicit existing-pool routes for both canonical type orders.
- Existing routes accept a typed `&mut cetus_clmm::pool::Pool<A, B>` and enforce
  50-bps price deviation immediately after the payload reveals its exact
  balances and before any Cetus pool or position mutation. An abort rolls back
  the atomic core migration transition.

- [x] **Step 1: Add and run the failing Cetus boundary check**

Run: `bash sui/migrators/scripts/check_source_boundaries.sh`

Expected: failure because the production module is missing.

- [x] **Step 2: Implement canonical new and adoption paths**

Use `pool_creator::full_range_tick_range`. New unpermissioned pairs use
`create_pool_v3`; adopted pools use `pool::open_position`,
`add_liquidity_fix_coin`, `add_liquidity_pay_amount`, and
`repay_add_liquidity`. Check returned coins or payment amounts against the 1-bps
minimum. Collect with `pool::collect_fee(..., true)` and assert
`position::liquidity` is unchanged.

The reviewed Git source supplies the interface facts but omits `published-at`.
The local interface must preserve original address `0x1eab...b2fb` and set
`published-at` to latest mainnet revision 14 at `0x25eb...e5e3`, with the
normalized target signatures checked against digest `FEdn2y...Tuokoi`.

- [x] **Step 3: Build, lint, and prove the boundary**

Run:

```bash
cd sui/migrators
sui move build
sui move lint --warnings-are-errors
bash scripts/check_source_boundaries.sh
```

- [x] **Step 4: Commit only the Cetus slice**

```bash
git add sui/migrators/Move.toml sui/migrators/Move.lock sui/migrators/README.md sui/migrators/scripts/check_source_boundaries.sh sui/migrators/sources/cetus.move sui/migrators/interfaces/cetus
git commit -m "feat(sui): add Cetus locked migration vault"
```

### Task 7: Turbos module

**Files:**
- Modify: `sui/migrators/Move.toml`
- Create: `sui/migrators/sources/turbos.move`
- Modify: `sui/migrators/scripts/check_source_boundaries.sh`
- Modify: `sui/migrators/README.md`

**Interfaces:**
- Produces new-pool and explicit existing-pool routes for both type orders and one selected `FeeType`.

- [x] **Step 1: Add and run the failing Turbos boundary check**

Run: `bash sui/migrators/scripts/check_source_boundaries.sh`

Expected: failure because the production module is missing.

- [x] **Step 2: Implement pinned Turbos creation/adoption**

Override upstream's mutable framework reference with `sui@06734f6`. Derive
full-range signed ticks with `math_tick::get_min_tick/get_max_tick`. New pools use
`deploy_pool_and_mint_with_return_`; existing pools use
`position_manager::mint_with_return_` only after the 50-bps check. Pass the
1-bps minima and caller deadline. Collection uses
`collect_with_return_` and compares `get_position_info` liquidity before/after.

- [x] **Step 3: Build, lint, and prove the boundary**

Run:

```bash
cd sui/migrators
sui move build
sui move lint --warnings-are-errors
bash scripts/check_source_boundaries.sh
```

- [x] **Step 4: Commit only the Turbos slice**

```bash
git add sui/migrators/Move.toml sui/migrators/Move.lock sui/migrators/README.md sui/migrators/scripts/check_source_boundaries.sh sui/migrators/sources/turbos.move
git commit -m "feat(sui): add Turbos locked migration vault"
```

### Task 8: Full Sail module and on-chain ABI pin

**Files:**
- Create: `sui/migrators/interfaces/fullsail/Move.toml`
- Create: minimal interface modules under `sui/migrators/interfaces/fullsail/sources/`
- Create: `sui/migrators/interfaces/fullsail_integer_mate/Move.toml`
- Create: minimal integer interface modules under `sui/migrators/interfaces/fullsail_integer_mate/sources/`
- Modify: `sui/migrators/Move.toml`
- Create: `sui/migrators/sources/fullsail.move`
- Modify: `sui/migrators/scripts/check_source_boundaries.sh`
- Modify: `sui/migrators/README.md`

**Interfaces:**
- Produces new-pool and explicit existing-pool routes for both canonical type orders.
- Produces the normalized locked vault, fee collection, and creator/protocol claim surface.
- Pins original package `0xe741...b239` to latest mainnet revision 4 at
  `0x497a...a881`, digest `CWkTs...Ho3nF`.

- [x] **Step 1: Prove the published docs pin is stale and inspect bytecode**

Use Sui GraphQL package lineage to resolve the latest revision from the
original package id. Fetch module bytecode and normalized ABI from revision 4.
Check `factory::create_pool_with_liquidity`, `pool::open_position`,
`pool::add_liquidity_fix_coin`, `pool::repay_add_liquidity`,
`pool::collect_fee`, `pool::current_sqrt_price`, `position::liquidity`, and
`position::pool_id`. Record the package and module digests.

- [x] **Step 2: Add and observe the failing boundary/build checks**

The boundary script must reject principal withdrawal, position transfer,
close, burn, and gauge staking. Run it before the production module exists.

- [x] **Step 3: Build the exact local interface and adapter**

Generate only the public types and functions the adapter consumes from the
normalized revision-4 ABI. New pools use
`factory::create_pool_with_liquidity`; adopted pools use the pool receipt flow
after the 50-bps check. Use venue tick helpers for full range, enforce the
1-bps residual bound, transfer residuals to the live treasury, keep the
position in the shared vault, and verify liquidity is unchanged across fee
collection.

- [x] **Step 4: Build, lint, and prove the boundary**

Run:

```bash
cd sui/migrators
sui move build
sui move lint --warnings-are-errors
bash scripts/check_source_boundaries.sh
```

- [x] **Step 5: Commit only the Full Sail package and interface**

```bash
git add sui/migrators/sources/fullsail.move sui/migrators/interfaces/fullsail sui/migrators/interfaces/fullsail_integer_mate sui/migrators/Move.toml sui/migrators/Move.lock sui/migrators/README.md sui/migrators/scripts/check_source_boundaries.sh
git commit -m "feat(sui): add Full Sail locked migration vault"
```

### Task 9: Release verification and independent review

**Files:**
- Modify: `sui/migrators/README.md`
- Create: `sui/migrators/DEPENDENCIES.md`
- Create: `sui/migrators/scripts/check_mainnet_abi.mjs`
- Modify: `docs/testing.md`

**Interfaces:**
- Produces a reproducible package-id/dependency matrix and explicit mainnet dev-inspect release gate.
- Produces a dependency-free official-GraphQL checker for latest package
  lineage, package/module bytecode digests, and every adapter-consumed ABI.
- Produces an immutable-package gate that records the aggregate package's one
  `UpgradeCap` destruction after every venue passes verification.

- [x] **Step 1: Verify live package lineage, bytecode, and consumed ABI**

Create `scripts/check_mainnet_abi.mjs` with Node built-ins only. Query the
official Sui mainnet GraphQL endpoint, resolve the latest revision after each
original Bluefin, MMT, Cetus, Turbos, and Full Sail package, assert the expected
current package id/version/digest and consumed module-byte fingerprints, then
assert the exact normalized signatures used by the adapters. Include Full
Sail's separate IntegerMate package. Fail closed on GraphQL errors, later
versions, missing modules/functions, signature/ability drift, or digest drift.

Run: `cd sui/migrators && node scripts/check_mainnet_abi.mjs`

- [x] **Step 2: Verify every package locally from clean commands**

Run the core build, strict lint, complete tests, then the aggregate migrators
build/lint/source-boundary triplet. Record exact exit codes and test counts.

- [x] **Step 3: Inspect the aggregate diff and dependency locks**

Run:

```bash
git diff --check
git status --short
find sui/migrators -name Move.lock -o -name Move.toml | sort
rg -n 'rev = "(main|mainnet|testnet|v[0-9]|mainnet-v)' sui/migrators --glob 'Move.toml'
```

Expected: no whitespace errors and no mutable/tag dependency revision.

- [x] **Step 4: Request Opus 5 security review**

Use exact `claude-opus-5` under `jose@interestprotocol.com` to review price
orientation, arithmetic bounds, ability/visibility leaks, residual conservation,
principal lock, venue ABI signatures, and dependency pins. Apply only findings
that reproduce against the pinned compiler or source.

- [x] **Step 5: Re-run full verification after review changes**

Repeat every command from Step 1 and `git diff --check` with fresh output.

- [x] **Step 6: Commit release checker and documentation**

```bash
git add sui/migrators/README.md sui/migrators/DEPENDENCIES.md sui/migrators/scripts/check_mainnet_abi.mjs docs/testing.md
git commit -m "docs(sui): record migrator release gates"
```
