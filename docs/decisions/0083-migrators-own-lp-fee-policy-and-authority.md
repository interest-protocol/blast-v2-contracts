# 0083: Migrators own LP-fee policy and migration-born LP-fee authority

- Status: superseded by [0088](0088-reusable-launch-accounting-and-atomic-migration.md)
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
  `LpFeeAuthority<Meme> = Pending | Cap(ID) | Custodian(TypeName)`, with every
  transition `public(package)`. Only `destroy_lp_fee_cap` is public. Errors are
  module-local codes 0–5.

Launchpad removes the LP-fee implementation and its errors, and adds only
the reads `Launch::assert_fee_custodian` and `Launch::has_fee_custodian`.

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
  with its drop-only witness and binds pending fees with no capability, moving
  `Pending` to `Custodian`. It records the launch's already validated witness
  type, so it needs no separate primitive-witness check. Auto-LP or distributor enrollment before migration therefore
  needs neither an administrator nor a cap holder.
- `lock_creator_fees`: the live cap is destroyed to bind the custodian named by
  its witness type, moving `Cap` to `Custodian`. A primitive, vector, or
  framework witness is rejected with `EInvalidLpFeeCustodian` (code 5).
- `issue_lp_fee_cap`: replaces a capability a creator already claimed, moving
  `Cap` to a fresh `Cap`. It checks the migrators version, then that fees are
  not locked, then a nonzero recipient, then that the authority is no longer
  pending (`ELpFeesFollowTheCurveFeeCap`, code 4), then `creator_admin_role`.
  It mints, retires the previous ID, transfers, and emits. It never reissues
  pending fees, so it takes no `Launch`.

**Pending LP fees follow the curve-fee capability.** An LP-fee cap exists only
for a creator who still holds curve-fee rights, so a pending authority is never
reissued: `issue_lp_fee_cap` aborts from `Pending` for every launch, custodied
or not. A community takeover reassigns the launch's `CurveFeeCap` through the
launchpad, and its new holder claims the LP-fee cap with `claim_lp_fee_cap`.
That keeps takeover a single gated, evented decision instead of letting an
administrator redirect LP fees while a creator still holds the curve-fee
capability that entitles them to those fees. When the launch's creator fees are
bound to a custodian such as Auto-LP or the distributor, the pending LP fees
belong to that same custodian, which binds them with `lock_pending_creator_fees`.
Once a creator has claimed the cap, reissue stays available because the claimed
cap, not the launch, then governs those fees.

Events are `LpFeeCapClaimed`, `LpFeeCapIssued`, and `LpFeesLocked`, whose
`lp_fee_cap_id` is `Option<ID>` and is none for pending binds and whose
`custodian` is the witness `TypeName`.

**Consumers.** The distributor declares one `Witness` for its custody. Both
`lock_lp_fees`, which binds pending fees, and `lock_lp_fees_with_cap`, which
destroys a claimed cap, take the enrolled launch and reject any other, so fees
can only bind to a distributor that exists for that launch. The native DEX and Auto-LP are parked in `scratch-sui/`, outside every
build and gate. They still target the ADR 0082 launchpad ABI and return to
`sui/` only after their redesign.

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

**Custodian obligation.** A `Pending` vault whose launch is already custodied
has exactly one reachable transition: `lock_pending_creator_fees` by that
custodian's own witness. `claim_lp_fee_cap` is impossible because no live
`CurveFeeCap` survives the launch lock, and `issue_lp_fee_cap` aborts. Every
custodian that locks launch creator fees must therefore expose a path that
binds pending LP fees, or those fees stay unclaimable with no administrative
recovery. The distributor exposes `lock_lp_fees`.

## Consequences

- Creators claim LP fees without administrator involvement, and custodians
  enrolled before migration bind them directly.
- `issue_lp_fee_cap` drops the launchpad `PackageVersion` and `Launch` arguments.
- An administrator can no longer redirect pending LP fees away from a creator who
  still holds the launch's curve-fee capability. Takeover of an abandoned launch
  goes through `reassign_curve_fee_cap`, so nothing becomes unrecoverable.
- Indexers read LP-fee policy and authority events from migrators.
- Dex and Auto-LP are parked in `scratch-sui/` until the native migration is
  redesigned; the distributor is the only enrolled fee custodian meanwhile.
- Moving the policy and authority rewrites published struct layouts, public
  signatures and event payloads. No package was published when this was
  decided (confirmed 2026-09-16), so it needed no lineage break.

## Verification

Tests prove the following:

- A migration payload yields a pending authority.
- The live curve-fee holder claims once, and a second claim or a retired curve
  cap is rejected.
- A launch custodian binds pending fees, and a non-custodian cannot.
- A claimed cap blocks capless binding.
- Pending fees reject reissue before the role check, for a custodied launch and
  an uncustodied one alike, while a claimed cap stays reissuable.
- A reassigned curve-fee holder claims the still-pending LP-fee cap, so takeover
  survives the removal of the pending reissue.
- Reissue retires the claimed cap before the empty-ledger check and requires the
  creator-admin role.
- The moved policy keeps its default, pin, re-pin, clear, and guard-order
  behavior.
- The distributor binds pending LP fees and collects them.

Launchpad, migrators and distributor boundary gates pin the new ownership.
