# Shared Administration Consumer Migration Implementation Plan

> **For implementer:** REQUIRED SUB-SKILL: Use `superpowers:executing-plans` to implement this plan task by task.

**Goal:** Make `blast_admin` the only reusable administration implementation, adopt its typed ACL/version/custody primitives across every administration-bearing package, and remove AutoLP's local administration without changing product economics.

**Architecture:** Launchpad, Blast SUI, DEX, and Series One each create a typed authority through `blast_admin::acl::new`. Launchpad shares its domain with Migrators and Distributor; Series One shares its domain with Aftermath. Every upgradeable package still owns an independent operational generation and sealed `UpgradeCap`; Series One and AutoLP are immutable and own neither. Consumer modules directly import the generic administration types—there are no local compatibility ACLs.

**Tech stack:** Sui Move (`sui 1.77.2-51d177ad7d65`), shell source-boundary gates, Node offline ABI fixtures, package-local Markdown runbooks.

**Authoritative sources:**

- `/home/ubuntu/blast-v2/.coding-workflow/blast-v2-contracts/workflows/blast-administration/spec.md`
- `/home/ubuntu/blast-v2/.coding-workflow/blast-v2-contracts/workflows/blast-administration/tickets/T-001.md` through `T-006.md`
- `docs/superpowers/specs/2026-09-06-shared-admin-consumer-migration-design.md`

**Execution rules:** Start each task with the focused failing test or boundary assertion, record the red result, implement the smallest production change, then run the focused test and package gate. Preserve dependency pins and economic assertions. Never run live/funded venue checks, publish scripts in execute mode, or a networked ABI check. Use commands whose exit status is not hidden by a pipeline.

## Confirmed implementation decisions

1. Correct `upgrade_custody::INITIAL_NATIVE_VERSION` from `0` to `1`. A newly published framework `UpgradeCap` starts at version 1; keeping 0 makes every real custody intake abort. Delete the now-redundant test-only intake constructor and test that a version-2 cap is rejected.
2. `dex::migration::claim_protocol_fees` keeps the sole `AdminWitness<LAUNCHPAD_DOMAIN>` exception because it drains a Launchpad-owned `FeeLedger`. DEX package/factory/pool administration uses only `AdminWitness<DEX_DOMAIN>`. The boundary checker permits this one product-custody call and rejects other Launchpad-witness use.
3. Blast SUI preserves its additive-only restriction surface and adds `make_immutable`; it does not add a dependency-only restriction wrapper.
4. Every Migrators public mutation checks the Migrators generation. Composed calls carry both the Launchpad and Migrators versions when both packages mutate. This adds the Migrators version input to `distributor::collect_lp_fees` and `auto_lp::collect_external_lp`.
5. Migrators, Distributor, and DEX use `package_marker.move` / `PACKAGE_MARKER` as their internal custody/version phantom marker.

## Task 1: Correct and finalize the shared administration ABI (T-001)

**Files:**

- Modify: `sui/admin/sources/acl.move`
- Modify: `sui/admin/sources/upgrade_custody.move`
- Modify: `sui/admin/tests/acl_tests.move`
- Modify: `sui/admin/tests/upgrade_custody_tests.move`
- Modify: `sui/admin/scripts/check_source_boundaries.sh`

**Red:** Rename the constructor tests to call `acl::new`, add a test that custody intake rejects a cap already upgraded to native version 2, and update the boundary expectation before changing production sources.

**Green implementation:**

- Rename public `acl::bootstrap` to `acl::new` with the same OTW/configuration parameters and no return value.
- Rename the private tuple constructor to `new_objects`.
- Keep exactly `public struct AdminWitness<phantom Domain: drop>(u64) has drop;`.
- Set the production initial native cap version to 1 and route tests through the production intake constructor.
- Remove all source references to `bootstrap` and keep the public ABI allow-list exact.

**Verify:** `bash sui/admin/scripts/verify.sh all`.

**Commit:** `fix(admin): finalize shared administration ABI`

## Task 2: Migrate Launchpad, Migrators, and Distributor together (T-002)

The three packages form one dependency slice and must land at one common revision.

### 2A. Launchpad

**Files:**

- Delete: `sui/launchpad/sources/acl.move`
- Add: `sui/launchpad/sources/launchpad_domain.move`
- Modify: `sui/launchpad/sources/package_version.move`
- Modify: `sui/launchpad/sources/package_admin.move`
- Modify administration signatures in `fees.move`, `launch.move`, `launch_config.move`, and `runtime_config.move`
- Retire copied constants/errors/events in `sources/lib/`
- Add/replace focused domain and package-admin tests; remove duplicated ACL lifecycle tests
- Modify: `sui/launchpad/Move.toml`, generated `Move.lock`, boundary checker, and README

**Red:** Add tests for OTW initialization, zero-role generic administration, role bit 1, domain isolation, canonical Publisher/UpgradeCap intake, stale generation, missing package-admin role, atomic commit-and-advance, policy narrowing, and irreversibility after immutability.

**Green implementation:**

- `launchpad_domain::LAUNCHPAD_DOMAIN` initializes a 16-admin, seven-day authority using `acl::new` and exports `package_admin_role(): u64` returning 1.
- Store `OperationalVersion<blast::BLAST>` in `PackageVersion`; remove local arithmetic and activation.
- Store `UpgradeCustody<blast::BLAST>` in `PackageAdmin`; require the canonical `blast::BLAST` Publisher; expose authorize, atomic commit-and-advance, both restriction modes, and immutability.
- Generic product administration requires a live typed witness and no role; package custody operations additionally require the package-admin role.
- Retire copied invariant errors/events without reusing codes.

### 2B. Migrators

**Files:**

- Add: `sui/migrators/sources/package_marker.move`, `package_version.move`, `package_admin.move`
- Modify: venue modules and `vault.move`
- Add package-version/package-admin tests and stale-generation coverage to venue/vault suites
- Modify: manifest/lock, `scripts/check_mainnet_abi.mjs`, boundary checker, README, and DEPENDENCIES

**Red:** Prove each protected public mutation rejects a stale Migrators generation, prove package custody provenance/role/atomic advance, and prove advancing Migrators alone leaves Launchpad and Distributor usable.

**Green implementation:**

- Add independent `OperationalVersion<PACKAGE_MARKER>` and `UpgradeCustody<PACKAGE_MARKER>` containers governed by `AdminWitness<LAUNCHPAD_DOMAIN>` plus Launchpad's package-admin role.
- Add the Migrators version to all mutation boundaries: venue policy/tier changes, venue migrations, creator/protocol fee claims.
- Retain the Launchpad version wherever a composed operation mutates Launchpad; neither version substitutes for the other.
- Update the strict offline manifest/lock fixture for the `blast_admin` edge.

### 2C. Distributor

**Files:**

- Add: `sui/distributor/sources/package_marker.move`, `package_admin.move`, and `scripts/check_source_boundaries.sh`
- Modify: `package_version.move`, `distributor.move`, tests, manifest/lock, and README

**Red:** Cover all five pause-blocked paths, version-before-pause error order, resume preserving roots/balances/claim bits, atomic advance preserving pause, and custody independence from the product PublisherCap.

**Green implementation:**

- Embed `OperationalVersion<PACKAGE_MARKER>` beside `paused`; remove local activation/arithmetic.
- Seal the framework UpgradeCap in `UpgradeCustody<PACKAGE_MARKER>` while retaining the unrelated product PublisherCap.
- Keep pause checks after current-generation checks and preserve all economic state transitions.
- Pass the Migrators version through `collect_lp_fees`.

**Verify the slice:** Build, warnings-as-errors lint, tests, and source boundaries for all three packages; run `node sui/migrators/scripts/check_mainnet_abi.mjs --self-test`. Add an integration test showing one Launchpad admin works across the slice, independent generation advance, and shared revocation.

**Commit:** `refactor(admin): share launchpad administration domain`

## Task 3: Migrate Blast SUI (T-003)

**Files:**

- Delete: `sui/blast_sui/sources/acl.move` and its duplicated lifecycle test suite
- Add: `sui/blast_sui/sources/blast_sui_domain.move`
- Modify: version, package-admin, vault/custody/deposit-receipt, errors/events, tests
- Modify: manifest/lock, source-boundary and coverage scripts, README/DEPLOYING/UPGRADING

**Red:** Cover domain isolation, zero-role generic administration, canonical custody intake, all three metadata/display child-cap completeness checks, stale generation, role rejection, atomic advance, additive restriction, immutability, and every protected transition.

**Green implementation:**

- Create the independent `BLAST_SUI_DOMAIN` with role bit 1.
- Embed `OperationalVersion<blast::BLAST>` and `UpgradeCustody<blast::BLAST>`.
- Preserve `MetadataCap<FUN_SUI>`, `MetadataCap<BLAST_SUI>`, and `DisplayCap<BlastSuiDepositReceipt>` as dynamic children and require all three before sharing.
- Preserve additive-only restriction; add immutability and atomic commit-and-advance.
- Do not alter mint/redeem/exchange-rate/validator/metadata/display behavior.

**Verify:** `bash sui/blast_sui/scripts/verify.sh all` then `bash sui/blast_sui/scripts/check_coverage.sh`.

**Commit:** `refactor(admin): isolate blast sui administration`

## Task 4: Migrate Series One and Aftermath (T-004)

### 4A. Series One

**Files:**

- Delete: local ACL source and duplicated ACL lifecycle tests
- Add: `sui/leverage_coins/series_one/sources/series_one_domain.move`
- Modify: state signatures, constants/errors/events, manifest/lock, boundaries, README/DEPLOYING

**Red:** Assert typed initialization, zero-role membership, domain isolation, and exact widened role values: vault issuer 1, risk 2, shutdown 8, package admin 16.

**Green implementation:** Replace the copied ACL with the independent Series One domain and typed shared witnesses. Keep Series One immutable: no operational version, PackageAdmin, or surviving UpgradeCap. Preserve accounting assertions unchanged.

### 4B. Aftermath adapter

**Files:**

- Modify: `protocol.move`, `package_admin.move`, `vault.move`, `operations.move`, `snapshot.move`, `venue_account.move`
- Modify: tests, manifest/lock, offline fixtures if required, boundary checker, README

**Red:** Cover stale generation at every mutation, canonical custody, package-admin-role rejection (including a risk-only admin), atomic advance, restrictions, and immutability.

**Green implementation:** Embed `OperationalVersion<aftermath::AFTERMATH>` and `UpgradeCustody<aftermath::AFTERMATH>`, governed by `AdminWitness<SERIES_ONE_DOMAIN>` and role 16. Remove separate activation and field-peeking custody checks; the sealed typed constructor owns provenance.

**Verify:** `bash sui/leverage_coins/series_one/scripts/verify.sh all` and `bash sui/leverage_coins/aftermath_adapter/scripts/verify.sh local`. Never run `proof` or `all` for the adapter.

**Commit:** `refactor(admin): share series one administration domain`

## Task 5: Add independent DEX administration (T-005)

**Files:**

- Add: `sui/dex/sources/dex_domain.move`, `package_marker.move`, `package_admin.move`
- Modify: `pool.move`, `migration.move`, tests, manifest/lock, README
- Add: `sui/dex/scripts/check_source_boundaries.sh`

**Red:** Cover DEX-domain init/isolation, zero-role generic administration, role-gated custody, canonical intake, stale generation, atomic advance, restriction, and immutability. Keep every existing pool/math/migration economic assertion unchanged.

**Green implementation:**

- Create `DEX_DOMAIN`, role bit 1, independent `OperationalVersion<PACKAGE_MARKER>` in `Factory`, and independent `UpgradeCustody<PACKAGE_MARKER>`.
- Use DEX witnesses for factory, pool-policy, and package administration.
- Preserve the single Launchpad witness on `migration::claim_protocol_fees`, narrowly typed to the Launchpad `FeeLedger` operation.
- Remove local version arithmetic/activation and preserve all coin ordering, quote restrictions, uniqueness, LP/position, fee recipient, and decay behavior.

**Verify:** DEX build, warnings-as-errors lint, tests, and boundary checker.

**Commit:** `feat(admin): add independent dex administration`

## Task 6: Remove AutoLP administration and enforce immutable publication (T-006)

**Files:**

- Modify: `sui/auto_lp/sources/vault.move`, tests, README
- Add: `sui/auto_lp/scripts/check_source_boundaries.sh`, `publish_immutable.sh`

**Red:** Remove obsolete activation/control tests and prove the complete permissionless collection/contribution/compound flow without a local witness or control. Retain wrong-executor, wrong-pool, deadline, max-input, empty-claim, and stale external-generation coverage.

**Green implementation:** Delete `Control`, local version constants/errors/events, initializer, activation, and all control parameters. Keep explicit external Launchpad/DEX version inputs, add the Migrators version to external LP collection, and retain fixed-executor policy. The publication script must consume the returned UpgradeCap with `package::make_immutable` in one PTB and never transfer it.

**Verify:** AutoLP build, warnings-as-errors lint, tests, and boundary checker. Structurally inspect publication only; do not execute it.

**Commit:** `refactor(admin): make auto lp immutable`

## Task 7: Reconcile package-local docs and verify one revision

Update only the package-local README/deployment/upgrade documents named by T-002 through T-006. Remove owner-held framework UpgradeCaps and separate activation steps; document atomic commit-and-advance and shared-domain ownership. Global T-007 operational documentation remains out of scope.

Run from the repository root, stopping on the first nonzero status:

```bash
set -o errexit -o nounset -o pipefail
bash sui/admin/scripts/verify.sh all
sui move build --path sui/launchpad --lint --warnings-are-errors
sui move test --path sui/launchpad --lint
bash sui/launchpad/scripts/check_source_boundaries.sh
sui move build --path sui/migrators --lint --warnings-are-errors
sui move test --path sui/migrators --lint
bash sui/migrators/scripts/check_source_boundaries.sh
node sui/migrators/scripts/check_mainnet_abi.mjs --self-test
sui move build --path sui/distributor --lint --warnings-are-errors
sui move test --path sui/distributor --lint
bash sui/distributor/scripts/check_source_boundaries.sh
bash sui/blast_sui/scripts/verify.sh all
bash sui/blast_sui/scripts/check_coverage.sh
bash sui/leverage_coins/series_one/scripts/verify.sh all
bash sui/leverage_coins/aftermath_adapter/scripts/verify.sh local
sui move build --path sui/dex --lint --warnings-are-errors
sui move test --path sui/dex --lint
bash sui/dex/scripts/check_source_boundaries.sh
sui move build --path sui/auto_lp --lint --warnings-are-errors
sui move test --path sui/auto_lp --lint
bash sui/auto_lp/scripts/check_source_boundaries.sh
```

Record the exact command, revision, status, and test counts for every package. Inspect the final diff for unchanged economics/accounting surfaces, forbidden copied administration, generated artifacts, secret material, and accidental live-network calls.

**Commit:** `docs(admin): reconcile consumer administration runbooks` (only if documentation was not naturally included in the slice commits).

