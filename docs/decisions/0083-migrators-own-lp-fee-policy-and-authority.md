# 0083: Migrators own LP-fee policy and migration-born LP-fee authority

- Status: accepted
- Date: 2026-09-15
- Amends: [0054](0054-v3-dex-migrators-and-locked-lp-fees.md),
  [0081](0081-separate-lp-fee-share-policy.md), and
  [0082](0082-revocable-creator-and-lp-fee-capabilities.md)

## Context

ADR 0082 placed `LpFeeCap<Meme>` in `blast_fun::creator_authority`, where a
creator administrator minted every LP-fee capability, including the first one
after each migration. ADR 0081 placed `LpFeePolicy` in launchpad even though
only migrators read it. Launchpad therefore owned post-migration concerns it
never exercises. An administrator had to act after every migration before a
creator could claim LP fees. A standalone admin mint also let authority exist
independently of the migration it governs.

## Decision

**Ownership.** `blast_fun_migrators` owns both LP-fee concerns:

- `lp_fee_policy::LpFeePolicy`: moved unchanged in behavior. Setters take the
  migrators `PackageVersion` and `AdminWitness<LAUNCHPAD_DOMAIN>`. Events are
  direct migrators events, and errors are module-local codes 0–2.
- `lp_fee_authority`: `LpFeeCap<Meme>` and
  `LpFeeAuthority<Meme> = Pending | Cap(ID) | Custodian(ID)`, with every
  transition `public(package)`. Only `destroy_lp_fee_cap` is public. Errors are
  module-local codes 0–3.

Launchpad keeps no LP-fee code. Its codes 85–87 are retired, and it adds only
the read `Launch::assert_fee_custodian`.

**Migration-born authority.** Every venue entry creates the vault's authority
with `lp_fee_authority::new(&payload, Witness())` before redeeming the
witness-typed `MigrationPayload`. `vault::prepare` and `vault::new` require the
authority as an argument. A vault therefore cannot exist without exactly one
`Pending` authority from its migration, and no administrator mints the first
capability.

**Transitions.**

- `claim_lp_fee_cap`: the launch's live `CurveFeeCap` holder mints the
  capability once, moving `Pending` to `Cap`.
- `lock_pending_creator_fees`: the launch's creator-fee custodian proves itself
  with its `&UID` and binds pending fees with no capability, moving `Pending` to
  `Custodian`. Auto-LP or distributor enrollment before migration therefore
  needs neither an administrator nor a cap holder.
- `lock_creator_fees`: the live cap is destroyed to bind a custodian, moving
  `Cap` to `Custodian`.
- `issue_lp_fee_cap`: a community-takeover reissue from `Pending` or `Cap`. It
  checks the migrators version, then that fees are not locked, then a nonzero
  recipient, then `creator_admin_role`. It mints, retires the previous ID,
  transfers, and emits.

Events are `LpFeeCapClaimed`, `LpFeeCapIssued`, and `LpFeesLocked`, whose
`lp_fee_cap_id` is `Option<ID>` and is none for pending binds.

**Consumers.** The distributor's `lock_lp_fees` binds pending fees through the
enrolled launch, and `lock_lp_fees_with_cap` keeps the destroy-a-claimed-cap
path. The native DEX migration and Auto-LP are on hold. They still target the
ADR 0082 launchpad ABI and do not build until their redesign lands.

## Alternatives considered

- **A separate LP-fee package.** Rejected: the policy and authority serve
  migrators only, and a new package adds versioning and upgrade custody with no
  new trust boundary.
- **Launchpad mints `LpFeeCap` from the payload.** Rejected: it keeps a
  migrators concern in launchpad and still needs a launchpad mint path for
  reissue.
- **Mint the capability object at migration.** Rejected: the vault would have to
  custody a `key` object. Minting at claim keeps the right migration-born and
  the object indexer-visible from creation.
- **Keep the admin-issued first capability.** Rejected: an operational step per
  migration and authority not bound to the migration.

## Consequences

- Creators claim LP fees without administrator involvement, and custodians
  enrolled before migration bind them directly.
- `issue_lp_fee_cap` drops the launchpad `PackageVersion` argument.
- Indexers read LP-fee policy and authority events from migrators.
- Dex and Auto-LP remain non-building until the native migration is redesigned.

## Verification

Tests prove the following:

- A migration payload yields a pending authority.
- The live curve-fee holder claims once, and a second claim or a retired curve
  cap is rejected.
- A launch custodian binds pending fees, and a non-custodian cannot.
- A claimed cap blocks capless binding.
- Reissue retires the claimed cap before the empty-ledger check and requires the
  creator-admin role.
- The moved policy keeps its default, pin, re-pin, clear, and guard-order
  behavior.
- The distributor binds pending LP fees and collects them.

Launchpad and migrators boundary gates pin the new ownership.
