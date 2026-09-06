# Shared Administration Consumer Migration Design

Date: 2026-09-06

Status: approved in design review

Scope: `blast_admin` ABI correction plus workflow tickets T-002 through T-006

## Authority

The authoritative requirements remain the `blast-administration` workflow specification and tickets T-002 through T-006 under `/home/ubuntu/blast-v2/.coding-workflow/blast-v2-contracts/workflows/blast-administration/`. Those workflow sources now name `blast_admin::acl::new`; this document records the approved implementation shape and the same deliberate ABI correction.

The owner confirmed that none of the affected packages or administration objects is deployed. Breaking object layouts and public transaction signatures are therefore permitted. If deployment evidence appears, stop and design a compatible on-chain migration before changing layouts.

## Outcome

Every reusable ACL lifecycle is implemented only by the immutable `blast_admin` package. Consumer packages own only their domain marker, role meanings, operational generation container, upgrade-custody wrapper, and product policy. No consumer retains a copied authority registry, administrator capability, witness, root-transfer implementation, operational-version arithmetic, or raw UpgradeCap state machine.

Product economics, balances, permissions unrelated to administration, and external protocol behavior remain unchanged.

A newly published Sui `UpgradeCap` starts at native version 1. The foundational custody intake must therefore require version 1, not version 0; otherwise every real consumer custody constructor aborts. The consumer batch corrects that constant and adds a rejection test for an already-upgraded version-2 cap.

## Shared ACL ABI

Rename the public constructor to:

```move
public fun new<Domain: drop>(
    otw: Domain,
    max_admins: u64,
    root_transfer_delay_ms: u64,
    ctx: &mut TxContext,
)
```

`new` authenticates the domain OTW, validates both configuration values, creates the authority and root capability, shares `Authority<Domain>`, transfers `SuperAdminCap<Domain>` to `ctx.sender()`, and emits `AuthorityCreated<Domain>`.

The operation intentionally returns nothing. `Authority` and `SuperAdminCap` lack `store`, so only their defining module can perform the required share and transfer. A public constructor returning them would either be unusable by consumers or require weakening the capability boundary. Rename the private tuple constructor to `new_objects`; it remains inaccessible in production.

`AdminWitness<Domain>` remains the positional drop-only snapshot:

```move
public struct AdminWitness<phantom Domain: drop>(u64) has drop;
```

## Direct Adoption

Consumers import `blast_admin::acl` types and functions directly. Local compatibility facades are excluded because they preserve a second ACL surface and obscure which package owns the invariant.

Domain-owning packages replace their copied `acl.move` lifecycle with a small domain module:

| Domain module | Authority users | Roles |
| --- | --- | --- |
| `blast_fun::launchpad_domain::LAUNCHPAD_DOMAIN` | Launchpad, Migrators, Distributor | exported package-admin bit |
| `blast_sui::blast_sui_domain::BLAST_SUI_DOMAIN` | Blast SUI | exported package-admin bit |
| `blast_fun_dex::dex_domain::DEX_DOMAIN` | DEX | exported package-admin bit |
| `blast_leverage_series_one::series_one_domain::SERIES_ONE_DOMAIN` | Series One, Aftermath adapter | vault issuer `1`, risk `2`, shutdown `8`, package admin `16`, all widened to `u64` |

Each domain module owns an OTW, `max_admins = 16`, a seven-day root-transfer delay, and an initializer that calls `blast_admin::acl::new`. Role values are exposed by pure public functions from the domain owner. Cross-package consumers import those functions rather than copying numeric bits.

All production signatures use fully typed generic values, for example:

```move
&Authority<LAUNCHPAD_DOMAIN>
&AdminCap<LAUNCHPAD_DOMAIN>
&AdminWitness<LAUNCHPAD_DOMAIN>
```

Launchpad, Blast SUI, and Series One delete their local authority, admin-cap, root-cap, witness, membership, and delayed-transfer implementations. DEX creates its own authority instead of accepting a Launchpad witness.

## Operational Generation and Upgrade Custody

Every upgradeable package owns one typed `OperationalVersion<PackageMarker>` and one `UpgradeCustody<PackageMarker>`. The reusable values are embedded in existing or new key-bearing consumer objects:

| Package | Version container | Custody container |
| --- | --- | --- |
| Launchpad | `PackageVersion` | `PackageAdmin` |
| Migrators | new `PackageVersion` | new `PackageAdmin` |
| Distributor | `PackageVersion`, retaining `paused` beside the shared value | new `PackageAdmin` |
| Blast SUI | `PackageVersion` | `PackageAdmin`, retaining required metadata/display dynamic children |
| DEX | existing `Factory` | new `PackageAdmin` |
| Aftermath adapter | existing `Protocol` | `PackageAdmin` |

Launchpad uses its canonical `blast::BLAST` marker, Blast SUI uses its canonical `blast::BLAST` marker, and Aftermath uses `aftermath::AFTERMATH`. Migrators, Distributor, and DEX add canonical package-marker modules and Publisher-claim initialization. Each consumer wrapper verifies its canonical Publisher module before calling the package-level checks in `UpgradeCustody`.

Each protected mutation checks its implementing package's compiled generation independently of ACL membership. Version validation occurs before pause or product-policy validation. Generic administrative operations require a live witness but accept a zero-role witness. Upgrade authorization, policy restriction, immutability, and commit-and-advance additionally assert the domain owner's package-admin role.

The only upgrade finalizer consumes the native `UpgradeReceipt`, commits it to the same sealed cap, and advances to the exact next compiled generation in one transaction. Separate receipt commit and later activation functions are removed.

## Package Migrations

### Launchpad, Migrators, and Distributor

Launchpad creates the shared domain. All three packages accept `AdminWitness<LAUNCHPAD_DOMAIN>` and use Launchpad's exported package-admin role. They share membership only; each retains a separate version and custody object.

Migrators stops treating Launchpad's version as its own. A composed call supplies both versions when it mutates both packages.

Distributor retains its product `PublisherCap` and gains sealed framework package custody. Its pause continues to block enrollment, both fee-collection paths, round publication, and funded claims. Resume preserves roots, balances, and claim bits.

### Blast SUI

Blast SUI creates an independent domain and removes its copied ACL. Its `PackageAdmin` embeds shared custody while preserving the three required metadata/display child capabilities and the completeness check before sharing.

### Series One and Aftermath

Series One creates an independent domain, widens its existing role bitmap values to `u64`, and is published immutably with no operational version or PackageAdmin. Aftermath imports that domain and its package-admin role, embeds shared operational versioning in `Protocol`, and embeds shared custody in `PackageAdmin`.

### DEX

DEX creates an independent domain and package marker. Its `Factory` embeds the DEX operational generation. Administrative mutations use `AdminWitness<DEX_DOMAIN>`; economic and migration formulas remain unchanged.

`migration::claim_protocol_fees` is the single deliberate Launchpad-witness exception because it drains the Launchpad `FeeLedger` held by the migration vault. It is Launchpad product-fee custody, not DEX factory, pool-policy, or package administration. The DEX source-boundary gate permits that exact call and rejects any other Launchpad witness use.

### AutoLP

AutoLP deletes `Control`, its compiled local version, activation, and the Launchpad witness used for local activation. Fixed-executor checks and permissionless collection remain. Explicit Launchpad, Migrators, or DEX version inputs remain only where AutoLP invokes those external packages. AutoLP publication consumes its UpgradeCap and leaves no local administration.

## Errors and Events

ACL, role, root-transfer, generation, custody, upgrade, restriction, and immutability failures and replay events come from `blast_admin`. Consumer registries retain only product-specific errors and events; removed numeric codes are retired rather than reused.

Consumer boundary checks reject copied ACL/version/custody state, foreign-domain witnesses, missing generation checks, raw capability escape, separate activation, and AutoLP local administration.

## Delivery Order

Use one reviewable commit per dependency slice:

1. Rename the shared constructor and update the foundational boundary contract.
2. Migrate Launchpad, Migrators, and Distributor together.
3. Migrate Blast SUI.
4. Migrate Series One and Aftermath together.
5. Migrate DEX.
6. Remove AutoLP administration and add immutable publication enforcement.

The global documentation and real Upgrade PTB work in T-007 remains outside this implementation scope. Package-local README and runbook changes required by T-002 through T-006 remain in scope.

## Verification

Keep the complete reusable invariant matrix only in `sui/admin`. Consumer tests cover their wiring and policy:

- exact domain and marker isolation;
- zero-role generic membership and package-admin role rejection;
- stale and skipped operational generations;
- canonical Publisher and UpgradeCap intake;
- atomic receipt commit and generation advance;
- child-cap completeness for Blast SUI;
- independent Launchpad/Migrators/Distributor generations and shared revocation;
- Distributor pause behavior, including funded claims;
- unchanged Series One role meanings;
- DEX economic regression tests;
- AutoLP behavior without local administration; and
- immutable publication/source-boundary negative fixtures.

Run build, warning-as-error lint, Move tests, boundary checks, and offline fixtures for every affected package. Do not run funded venue proof or claim live publication/upgrade evidence.
