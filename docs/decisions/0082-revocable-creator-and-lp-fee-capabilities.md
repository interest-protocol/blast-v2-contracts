# 0082: Revocable curve-fee, metadata, and LP-fee capabilities

- Status: accepted; amended by [0083](0083-migrators-own-lp-fee-policy-and-authority.md)
- Date: 2026-09-15
- Amends: [0023](0023-generated-coin-supply-and-metadata-custody.md),
  [0054](0054-v3-dex-migrators-and-locked-lp-fees.md),
  [0075](0075-independent-holder-fee-distributor.md),
  [0076](0076-native-v2-and-auto-lp.md), and
  [0080](0080-provider-independent-creator-recipient.md)

## Context

Community takeovers (CTOs) require an administrator to strip a creator's rights
and hand them to a new owner. A possession-only `CreatorCap<Meme>` cannot be
revoked, and one cap governing both bonding-curve and post-migration fees would
couple two fee streams that are owned and reassigned independently. Releasing
`MetadataCap<Meme>` to the creator also made coin metadata unrecoverable after
a takeover.

## Decision

**Launch creator authority.** Creator authority is split by concern.
`CurveFeeCap<Meme>` governs bonding-curve creator fees and creator-funded pool
creation. `BlastMetadataCap<Meme>` governs coin metadata. Both are used only
through launchpad operations. `claim_creator_caps` consumes the pending
`CreatorAuthority<Meme>` and returns both caps.

`Launch` records `curve_fee_authority`, an `Unassigned | Cap(ID) |
Custodian(ID)` enum, and `blast_metadata_cap_id: Option<ID>`. Each operation
aborts unless the supplied cap is the recorded one: `ECurveFeeCapNotLive`
(`claim_creator_fees`, `assert_curve_fee_cap`) or `EMetadataCapNotLive` (the
metadata setters).

`reassign_curve_fee_cap` and `reassign_metadata_cap` each retire the pending
claim or live cap for their concern, mint a new cap, record its ID, and
transfer it to a nonzero address. Revoking a pending claim through one leaves
the other concern unassigned until an administrator reassigns it. A CTO calls
both in one transaction. `blast_fun_dex::pool::create` calls
`Launch::assert_curve_fee_cap`.

**Metadata custody.** The native `MetadataCap<Meme>` never leaves `Launch`. The
live `BlastMetadataCap` holder updates metadata through `Launch::set_name`, `set_description`, and
`set_icon_url`, which wrap the framework setters of the same name at
[`sui@06734f6ff0af45d8632a14a4dc4b100197f6b1a2:crates/sui-framework/packages/sui-framework/sources/registries/coin_registry.move#L416-L428`](https://github.com/MystenLabs/sui/blob/06734f6ff0af45d8632a14a4dc4b100197f6b1a2/crates/sui-framework/packages/sui-framework/sources/registries/coin_registry.move#L416-L428).
Unchanged values are rejected, and `MemeMetadataUpdated` carries the complete
snapshot. Symbol and decimals have no framework setter; metadata-cap deletion is
not exposed.

**Post-migration fee authority.** `LpFeeCap<Meme>` is defined beside
`CurveFeeCap` and `BlastMetadataCap` in `blast_fun::creator_authority` so that both the migrators and
native DEX packages depend inward on it. Every post-migration fee vault
(`blast_fun_migrators::vault::LpVault` and `blast_fun_dex::migration::LockedLpVault`)
records `lp_fee_authority`, an `Unassigned | Cap(ID) | Custodian(ID)` enum.
Migration records `Unassigned`, so creator LP fees accrue until the first issue. `issue_lp_fee_cap` mints a cap through the
role-gated `new_lp_fee_cap`, retires any previous ID, and transfers the cap to a
nonzero address. It is the only issuance path and never reads `CurveFeeCap`.

**Authority.** Every reassignment and LP-fee issue path requires the new
`launchpad_domain::creator_admin_role()` (bit 2). A routine administrator that
can claim protocol fees cannot redirect creator fee streams without it.

**Irrevocable custodians.** The live cap holder may call `lock_creator_fees`
on a launch (with `CurveFeeCap`) or a post-migration vault (with `LpFeeCap`),
passing a drop-only `Custodian` witness value. The cap is destroyed and the fee
stream moves to the terminal `Custodian(TypeName)` state, naming that witness
type. Afterward only `claim_custodied_creator_fees` with the same witness
claims it, and `reassign_curve_fee_cap` or `issue_lp_fee_cap` abort before any
role or recipient check. Each lock rejects a witness anyone can construct: a
primitive, a vector, or a framework type such as `Option`, `String`, or
`VecMap`, whose package is `0x1` or `0x2` (`EInvalidFeeCustodian`, launchpad
code 93, and `EInvalidLpFeeCustodian`, `lp_fee_authority` code 5). Move cannot
prove that any other package keeps its witness constructor private, so the
enforced property is that the witness is not publicly constructible by
construction rules the chain can check; the locking cap holder chooses the type
and bears that choice. Every authority is generic over `Meme`, and a
launch consumes its curve-fee cap when it locks, so the witness type together
with `Meme` names exactly one custodian. An earlier revision took the custodian
object's `&UID`, which any module exposing a public UID getter could supply.
Auto-LP enrollment and distributor
creation lock the launch's creator fees to the new object, and
`lock_external_lp_fees`, `lock_native_lp_fees`, and `lock_lp_fees` lock LP
fees once an administrator has issued the cap. Locking never touches `BlastMetadataCap`, so metadata stays editable and
reassignable. A creator-funded native pool must be created before locking.

Holders may destroy either capability. Destroying a live cap forfeits its rights
until an administrator reassigns them.

## Alternatives considered

- **Per-Meme registry of live caps.** Rejected: each `Launch` and fee vault is
  already unique per Meme, so a registry adds a shared-object input to every
  claim without adding an invariant.
- **Issue `LpFeeCap` at migration to the launch creator.** Rejected: migration
  is permissionless, an account recipient has no address, and it would tie LP
  fee ownership back to launch creator state.
- **One creator cap for fees and metadata.** Rejected: locking fees into a
  custodian would have frozen metadata, and a CTO could not move one concern
  without the other.
- **Reassign to a `CreatorRecipient`.** Rejected in favour of a direct address
  transfer; the backend resolves any Blast account to a wallet first.
- **Any live admin may reassign.** Rejected: it widens the compromise scope of
  routine admin keys to creator fee redirection.

## Consequences

- ADR 0080's "no administrative reassignment" and ADR 0023's release of
  `MetadataCap` to the creator no longer hold.
- Creator LP fees require an operational issue after each migration; the backend
  drives it from migration events.
- Enrolling in Auto-LP or the distributor is irreversible for fees: neither the
  creator nor any administrator can later redirect those fee streams, while
  metadata authority remains independent.
- `CreatorFeesLocked` and `LpFeesLocked` name the custodian by witness
  `TypeName` rather than object ID.
- Indexers track live authority from `CreatorCapsClaimed`, `CurveFeeCapReassigned`,
  `MetadataCapReassigned`,
  `LpFeeCapIssued`, `CreatorFeesLocked`, and `LpFeesLocked` rather than object
  ownership alone.
- No Blast V2 package was published on any network when this was decided
  (confirmed 2026-09-16), so rewriting `CurveFeeAuthority`, `LpFeeAuthority`
  and the `CreatorFeesLocked` payload required no new package lineage. The
  same change after first publication would.

## Verification

Tests prove, per owner, that retired caps are rejected before empty-ledger
checks, that reissue retires the previous cap and replays through events, that
zero recipients and missing roles abort, that unassigned vaults honor no cap,
that metadata updates keep the cap in `Launch` and reject unchanged values, that
pool creation rejects a retired `CurveFeeCap`, and that custody consumers reject
retired deposits, replace retired caps, and require a deposited cap to collect.
