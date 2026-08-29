# Sui V3 DEX Migrators Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Build Bluefin, MMT, Cetus, Turbos, and Full Sail Sui migration packages that initialize or safely adopt a CLMM at the real seed-balance price, permanently lock the position, split LP fees between creator and protocol, and route residuals to the live protocol treasury.

**Architecture:** `blast_fun` adds venue-neutral X64 price math, a live treasury field, and an external runtime-accrual seam on its existing dual-asset fee ledger. Five independent adapter packages depend inward on that ABI and on exact venue revisions. Each package owns its sealed witness and shared `LpVault`, while all venue-specific creation, ordering, tick, and collection calls remain outside core.

**Tech Stack:** Sui Move 2024, Sui CLI `1.77.2-51d177ad7d65`, `u256` integer arithmetic, shell source-boundary checks, exact Git dependency SHAs.

**Spec:** `docs/decisions/0054-v3-dex-migrators-and-locked-lp-fees.md`

## Global Constraints

- Preserve all pre-existing user changes in the dirty contracts and SDK repositories.
- Core imports no venue package; every adapter is an independent child Move package.
- All Git dependencies and transitive overrides use immutable full commit SHAs from ADR 0054.
- No production adapter exposes or calls position transfer, close, burn, decrease-liquidity, or remove-liquidity functionality.
- Price is derived on chain from real Meme and net Quote atomic balances; display decimals and USD prices never enter CLMM math.
- New-pool price deviation is zero; adopted Cetus/Turbos/Full Sail price deviation is at most 50 bps.
- Returned migration residuals are at most 1 bps of each source balance and transfer to the live nonzero protocol treasury.
- Bluefin pool-opening fee must read as supported and exactly zero.
- LP fees use the current `protocol_fee_share_bps`; protocol rounds up and creator receives the remainder.
- Tests precede production changes and each red test must be observed failing for the intended reason.

---

### Task 1: Core migration price arithmetic

**Files:**
- Create: `sui/launchpad/sources/migration_math.move`
- Create: `sui/launchpad/tests/migration_math_tests.move`
- Modify: `sui/launchpad/sources/lib/errors.move`
- Modify: `docs/error-codes.md`

**Interfaces:**
- Produces: `migration_math::sqrt_price_x64(u64, u64, bool): u128`
- Produces: `migration_math::assert_price_within_bps(u64, u64, bool, u128, u64)`
- Produces: `migration_math::minimum_utilized_amount(u64, u64): u64`
- Produces: `migration_math::assert_residual_within_bps(u64, u64, u64)`

- [ ] **Step 1: Write price tests before the module exists**

Add focused tests for `1:1 -> 2^64`, both reciprocal type orders, the committed Quote-decimal vectors, floor-square behavior, zero balances, `u64::MAX`, 50-bps acceptance/rejection, and 1-bps residual boundaries.

- [ ] **Step 2: Run the focused suite and observe RED**

Run: `cd sui/launchpad && sui move test migration_math_tests`

Expected: compilation fails because `blast_fun::migration_math` does not exist.

- [ ] **Step 3: Add append-only errors and bounded `u256` math**

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

- [ ] **Step 4: Run RED-to-GREEN verification**

Run: `cd sui/launchpad && sui move test migration_math_tests`

Expected: all migration-math tests pass.

- [ ] **Step 5: Run the complete core suite**

Run: `cd sui/launchpad && sui move test --lint`

Expected: all existing and new tests pass without warnings.

- [ ] **Step 6: Commit only Task 1 files**

```bash
git add sui/launchpad/sources/migration_math.move sui/launchpad/tests/migration_math_tests.move sui/launchpad/sources/lib/errors.move docs/error-codes.md
git commit -m "feat(sui): add exact migration price math"
```

### Task 2: Live treasury and reusable LP fee accounting

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
- Produces: `runtime_config::protocol_treasury(&RuntimeConfig): address`
- Produces: `runtime_config::protocol_fee_share_bps(&RuntimeConfig): u64`
- Produces: `runtime_config::set_protocol_treasury(&mut RuntimeConfig, &PackageVersion, &AdminWitness, address)`
- Produces: `fees::new<Meme, Quote>(): FeeLedger<Meme, Quote>` as a public constructor
- Produces: `fees::accrue_from_runtime(&mut FeeLedger<Meme, Quote>, Balance<Meme>, Balance<Quote>, &RuntimeConfig)`
- Produces: public creator/protocol ledger claims for adapter-owned ledgers

- [ ] **Step 1: Add failing runtime and external-accrual tests**

Test publisher-sender initialization, nonzero/unchanged treasury rejection,
package-version guard precedence, admin update events, raw public fee-share
reads, prospective live-share accrual, and creator/protocol claim isolation.

- [ ] **Step 2: Observe RED**

Run: `cd sui/launchpad && sui move test runtime_config_tests && sui move test fees_tests`

Expected: compilation fails on the missing treasury and external-accrual seams.

- [ ] **Step 3: Implement the minimum public ABI**

Add `protocol_treasury: address` to `RuntimeConfig`, initialize it from
`ctx.sender()`, validate nonzero/different updates, and emit creation/change
facts. Rename the package-only validated BPS read to `protocol_fee_share` and
make the raw `protocol_fee_share_bps` getter public. Add
`FeeLedger::accrue_from_runtime` and widen only the constructor, totals, and two
claim methods needed by adapters.

- [ ] **Step 4: Update core callers and prove GREEN**

Run: `cd sui/launchpad && sui move test --lint`

Expected: all core tests pass.

- [ ] **Step 5: Commit only Task 2 files**

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
- Create: `sui/migrators/bluefin/Move.toml`
- Create: `sui/migrators/bluefin/sources/bluefin.move`
- Create: `sui/migrators/bluefin/scripts/check_source_boundaries.sh`
- Create: `sui/migrators/bluefin/README.md`

**Interfaces:**
- Produces: sealed `blast_fun_bluefin::bluefin::Witness`
- Produces: shared `LpVault<Meme, Quote>`
- Produces: `migrate_meme_a` and `migrate_meme_b`
- Produces: `collect_fees`, `claim_creator_fees`, and `claim_protocol_fees`

- [ ] **Step 1: Add a failing structural boundary check**

The script must require the witness, vault, migration, collection, and claim
symbols and reject `remove_liquidity`, `close_position`, position transfer,
position burn, and any nonzero creation-fee balance construction.

- [ ] **Step 2: Observe RED**

Run: `bash sui/migrators/bluefin/scripts/check_source_boundaries.sh`

Expected: failure because `sources/bluefin.move` does not exist.

- [ ] **Step 3: Implement the Bluefin migration and vault**

Use exact Bluefin and transitive pins. Read the Quote-denominated creation fee,
assert `supported && fee == 0`, derive pair-order price from core, align the
config-provided full tick range, call `create_pool_with_liquidity`, enforce 1-bps
residual limits, transfer residuals to `protocol_treasury`, and share the vault.
Collection must compare `position::liquidity` before/after and accrue normalized
Meme/Quote balances through `FeeLedger::accrue_from_runtime`.

- [ ] **Step 4: Prove GREEN**

Run:

```bash
cd sui/migrators/bluefin
sui move build
sui move lint --warnings-are-errors
bash scripts/check_source_boundaries.sh
```

- [ ] **Step 5: Commit only the Bluefin package**

```bash
git add sui/migrators/bluefin
git commit -m "feat(sui): add Bluefin locked migration vault"
```

### Task 5: MMT adapter

**Files:**
- Create: `sui/migrators/mmt/Move.toml`
- Create: `sui/migrators/mmt/sources/mmt.move`
- Create: `sui/migrators/mmt/scripts/check_source_boundaries.sh`
- Create: `sui/migrators/mmt/README.md`

**Interfaces:**
- Produces the same normalized vault/migration/collection/claim surface under `blast_fun_mmt::mmt`.

- [ ] **Step 1: Add and run the failing MMT boundary check**

Run: `bash sui/migrators/mmt/scripts/check_source_boundaries.sh`

Expected: failure because the production module is missing.

- [ ] **Step 2: Implement MMT create-initialize-add-share ordering**

Use `check_coin_order`, `create_pool::new`, `pool::initialize`, venue full-range
tick helpers, `liquidity::open_position`, `liquidity::add_liquidity`, and finally
`pool::transfer`. Set both minimum used amounts from core's 1-bps helper. Normalize
fee coins from `collect::fee`, verify unchanged `position::liquidity`, and accrue
through the core ledger.

- [ ] **Step 3: Build, lint, and prove the boundary**

Run:

```bash
cd sui/migrators/mmt
sui move build
sui move lint --warnings-are-errors
bash scripts/check_source_boundaries.sh
```

- [ ] **Step 4: Commit only the MMT package**

```bash
git add sui/migrators/mmt
git commit -m "feat(sui): add MMT locked migration vault"
```

### Task 6: Cetus adapter

**Files:**
- Create: `sui/migrators/cetus/Move.toml`
- Create: `sui/migrators/cetus/sources/cetus.move`
- Create: `sui/migrators/cetus/scripts/check_source_boundaries.sh`
- Create: `sui/migrators/cetus/README.md`

**Interfaces:**
- Produces new-pool and explicit existing-pool routes for both canonical type orders.
- Existing routes accept a typed `&mut cetus_clmm::pool::Pool<A, B>` and enforce 50-bps price deviation before redemption/addition.

- [ ] **Step 1: Add and run the failing Cetus boundary check**

Run: `bash sui/migrators/cetus/scripts/check_source_boundaries.sh`

Expected: failure because the production module is missing.

- [ ] **Step 2: Implement canonical new and adoption paths**

Use `pool_creator::full_range_tick_range`. New unpermissioned pairs use
`create_pool_v3`; adopted pools use `pool::open_position`,
`add_liquidity_fix_coin`, `add_liquidity_pay_amount`, and
`repay_add_liquidity`. Check returned coins or payment amounts against the 1-bps
minimum. Collect with `pool::collect_fee(..., true)` and assert
`position::liquidity` is unchanged.

- [ ] **Step 3: Build, lint, and prove the boundary**

Run:

```bash
cd sui/migrators/cetus
sui move build
sui move lint --warnings-are-errors
bash scripts/check_source_boundaries.sh
```

- [ ] **Step 4: Commit only the Cetus package**

```bash
git add sui/migrators/cetus
git commit -m "feat(sui): add Cetus locked migration vault"
```

### Task 7: Turbos adapter

**Files:**
- Create: `sui/migrators/turbos/Move.toml`
- Create: `sui/migrators/turbos/sources/turbos.move`
- Create: `sui/migrators/turbos/scripts/check_source_boundaries.sh`
- Create: `sui/migrators/turbos/README.md`

**Interfaces:**
- Produces new-pool and explicit existing-pool routes for both type orders and one selected `FeeType`.

- [ ] **Step 1: Add and run the failing Turbos boundary check**

Run: `bash sui/migrators/turbos/scripts/check_source_boundaries.sh`

Expected: failure because the production module is missing.

- [ ] **Step 2: Implement pinned Turbos creation/adoption**

Override upstream's mutable framework reference with `sui@06734f6`. Derive
full-range signed ticks with `math_tick::get_min_tick/get_max_tick`. New pools use
`deploy_pool_and_mint_with_return_`; existing pools use
`position_manager::mint_with_return_` only after the 50-bps check. Pass the
1-bps minima and caller deadline. Collection uses
`collect_with_return_` and compares `get_position_info` liquidity before/after.

- [ ] **Step 3: Build, lint, and prove the boundary**

Run:

```bash
cd sui/migrators/turbos
sui move build
sui move lint --warnings-are-errors
bash scripts/check_source_boundaries.sh
```

- [ ] **Step 4: Commit only the Turbos package**

```bash
git add sui/migrators/turbos
git commit -m "feat(sui): add Turbos locked migration vault"
```

### Task 8: Full Sail adapter and on-chain ABI pin

**Files:**
- Create: `sui/migrators/interfaces/fullsail/Move.toml`
- Create: minimal interface modules under `sui/migrators/interfaces/fullsail/sources/`
- Create: `sui/migrators/fullsail/Move.toml`
- Create: `sui/migrators/fullsail/sources/fullsail.move`
- Create: `sui/migrators/fullsail/scripts/check_source_boundaries.sh`
- Create: `sui/migrators/fullsail/README.md`

**Interfaces:**
- Produces new-pool and explicit existing-pool routes for both canonical type orders.
- Produces the normalized locked vault, fee collection, and creator/protocol claim surface.
- Pins original package `0xe741...b239` to latest mainnet revision 4 at
  `0x497a...a881`, digest `CWkTs...Ho3nF`.

- [ ] **Step 1: Prove the published docs pin is stale and inspect bytecode**

Use Sui GraphQL package lineage to resolve the latest revision from the
original package id. Fetch module bytecode and normalized ABI from revision 4.
Check `factory::create_pool_with_liquidity`, `pool::open_position`,
`pool::add_liquidity_fix_coin`, `pool::repay_add_liquidity`,
`pool::collect_fee`, `pool::current_sqrt_price`, `position::liquidity`, and
`position::pool_id`. Record the package and module digests.

- [ ] **Step 2: Add and observe the failing boundary/build checks**

The boundary script must reject principal withdrawal, position transfer,
close, burn, and gauge staking. Run it before the production module exists.

- [ ] **Step 3: Build the exact local interface and adapter**

Generate only the public types and functions the adapter consumes from the
normalized revision-4 ABI. New pools use
`factory::create_pool_with_liquidity`; adopted pools use the pool receipt flow
after the 50-bps check. Use venue tick helpers for full range, enforce the
1-bps residual bound, transfer residuals to the live treasury, keep the
position in the shared vault, and verify liquidity is unchanged across fee
collection.

- [ ] **Step 4: Build, lint, and prove the boundary**

Run:

```bash
cd sui/migrators/fullsail
sui move build
sui move lint --warnings-are-errors
bash scripts/check_source_boundaries.sh
```

- [ ] **Step 5: Commit only the Full Sail package and interface**

```bash
git add sui/migrators/fullsail sui/migrators/interfaces/fullsail
git commit -m "feat(sui): add Full Sail locked migration vault"
```

### Task 9: Release verification and independent review

**Files:**
- Modify: `sui/migrators/README.md`
- Create: `sui/migrators/DEPENDENCIES.md`
- Modify: `docs/testing.md`

**Interfaces:**
- Produces a reproducible package-id/dependency matrix and explicit mainnet dev-inspect release gate.

- [ ] **Step 1: Verify every package locally from clean commands**

Run the core build, strict lint, complete tests, source-boundary script, then the
build/lint/boundary triplet for all five adapters. Record exact exit codes and
test counts.

- [ ] **Step 2: Inspect the aggregate diff and dependency locks**

Run:

```bash
git diff --check
git status --short
find sui/migrators -name Move.lock -o -name Move.toml | sort
rg -n 'rev = "(main|mainnet|testnet|v[0-9]|mainnet-v)' sui/migrators --glob 'Move.toml'
```

Expected: no whitespace errors and no mutable/tag dependency revision.

- [ ] **Step 3: Request Opus 5 security review**

Use exact `claude-opus-5` under `jose@interestprotocol.com` to review price
orientation, arithmetic bounds, ability/visibility leaks, residual conservation,
principal lock, venue ABI signatures, and dependency pins. Apply only findings
that reproduce against the pinned compiler or source.

- [ ] **Step 4: Re-run full verification after review changes**

Repeat every command from Step 1 and `git diff --check` with fresh output.

- [ ] **Step 5: Commit release documentation**

```bash
git add sui/migrators/README.md sui/migrators/DEPENDENCIES.md docs/testing.md
git commit -m "docs(sui): record migrator release gates"
```
