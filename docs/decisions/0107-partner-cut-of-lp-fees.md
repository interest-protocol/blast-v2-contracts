# 0107: Partners earn a cut of Blast's LP fees after migration

- Status: proposed
- Date: 2026-10-05
- Amends: [0098](0098-launch-creation-fee-and-partners.md), which left a
  launch's recurring LP fees outside its partner's cut;
  [0106](0106-presale-partners.md), whose partners never shared Blast's LP
  fees; [0089](0089-migrators-own-post-migration-and-start-launches.md) and
  [0101](0101-presale-protocol-fees.md), whose vaults paid Blast's LP fees at
  every collection

In this record a partner's percentage of a fee Blast takes is its cut, the rate
`blast_partners` stores as `share_bps`. "Share" is the Sui operation only.

## Context

A launch or a presale may name one Blast partner at creation. Before this
record the partner earned its cut of what Blast takes up to migration: on a
launch, the creation, curve and one-time migration fees in the launch's ledger
(ADRs 0098 and 0105); on a presale, Blast's raise fee (ADR 0106). After
migration each product custodies its pool position in an LP vault, and every
fee collection pays Blast's LP fees at once to a destination Blast sets:
`blast_fun_migrators::vault::LpVault` at the `LpFeePolicy` rates for launches,
and `blast_presale::presale_vault::PresaleVault` at its own rates for presales.
Collection is permissionless and lives in each venue adapter: Cetus and Bluefin
`collect_fees`, and on the launchpad also `settle_and_update_fee_split` and
auto-LP.

After migration is where a successful token trades most, so a partner earned
little over the life of the tokens it brought. On 2026-10-05 the owner asked
that partners also earn their cut after bonding, on both products,
implemented separately for each. The partner ID
stays on the launch and the sale, migration passes it to the LP vault, the
change must touch as little as possible, and the claim should be
permissionless, with every payout going to the right address.

## Decision

**Scope.** A vault's partner earns its cut of Blast's LP fees on that vault, in
both assets. Every other part of a collection is unchanged: the creator,
recipients, auto-LP, holder rewards and burn receive exactly what they would
without a partner. A launch vault's protocol migration residuals stay Blast's,
claimed by `TreasuryAdmin`; a presale's token fee stays Blast's.

**The vault inherits the partner.** At creation each vault copies its sale's
or launch's `partner_id: Option<ID>`. Nothing writes the field again. The
launchpad gains `launch::partner_id`, since the migrators package reads it
across packages; the presale's package-only `vault_config` returns it.

**Collections hold Blast's LP fees for a partnered vault.** `split_fees`, the
one function every collection path already calls, computes Blast's LP fees as
before, rounded up. A vault without a partner pays them to the live
destination, unchanged. A partnered vault keeps them in two new balances,
`unpaid_protocol_meme` and `unpaid_protocol_quote`. No venue entry point
changes, and no collection takes the `Partner`.

**Anyone pays the held fees.** One new function per product pays them:

- launchpad: `vault::claim_protocol_lp_fees_with_partner(vault,
  migrators_version, policy, partner, clock, ctx)`, version-gated first and
  named like the launch's `claim_protocol_fees_with_partner` (ADR 0105);
- presale: `presale_vault::pay_protocol_lp_fees_with_partner(vault,
  fee_policy, partner, clock, ctx)`, named like the sale's
  `pay_protocol_fees_with_partner` (ADR 0106).

Each checks that `partner` is the vault's own (`EPartnerMismatch` on the
launchpad, `EWrongPartner` on presales), which also refuses a vault without a
partner. It takes every held unit, pays the partner its cut in force of each
asset through `blast_partners::pay`, rounded down, and pays the rest to the
destination the policy names now. A vault holding nothing returns without
moving or emitting anything, as an empty collection does, so the payout can
follow any collection in one transaction. Both payees are fixed, so no
authority is needed.

**Events.** In both packages `FeesCollected.protocol_destination` becomes
`Option<address>`: the destination paid, or none when a partnered vault held
Blast's LP fees. Each payout emits one event with the vault, the destination
paid, what Blast kept and what the partner received: `ProtocolLpFeesClaimed`
on the launchpad, in `blast_events`, and `ProtocolLpFeesPaid<Meme, Quote>` on
presales. `blast_partners` also emits `PartnerPaid<T>` for each nonzero
payment. The vault-creation events are unchanged: `LaunchCreated` and
`PresaleOpened` already record the partner a vault inherits.

## Alternatives considered

- **Pay the partner inside each collection.** Every collection would need the
  `Partner`, and Move has no `Option<&Partner>` (ADR 0098). Partner variants
  would double each venue's `collect_fees`, and on the launchpad also
  `settle_and_update_fee_split`; the plain variants would have to abort on
  partnered vaults. A partner whose recipient is denied a Quote would block
  every collection, auto-LP and split change on its vaults. Holding Blast's
  part in `split_fees` keeps every venue entry point unchanged.
- **Hold every vault's Blast LP fees for a claim, as the launch ledger does.**
  It would change how Blast is paid on every vault, and add a claim for vaults
  without a partner. Only partnered vaults need the wait.
- **Abort a payout that has nothing to pay**, as the launch claim and the
  presale migration payout do. Those run once a ledger holds fees. This one is
  appended to collections that may collect nothing, and an abort would revert
  the collection with it.
- **Apply the cut at each collection and hold only the partner's part.**
  `blast_partners` exposes no cut getter, only `pay`, by design: the cut in
  force always comes from the timelock at payment.
- **Store the partner's recipient and cut in the vault.** The `Partner` keeps
  both under `blast_partners`' timelock; a copy would freeze them and bypass the
  notice Blast gives before changing either.
- **Divide the protocol migration residuals too.** They are what the venue did
  not take when the pool was seeded, not fees; ADR 0098 already left them out.
- **Record the partner in `VaultCreated` and `PresaleVaultCreated`.** The
  creation events of the launch and the sale already carry it, and the vault
  links to them.
- **A sentinel destination, such as `@0x0`, for held fees.** `Option` says
  "held" without a magic address.

## Consequences

- Only Blast's LP fees are divided; nobody else receives less.
- A partnered vault's Blast LP fees stay in the vault until anyone pays them,
  and nothing else can move them. The cut applied is the one in force at the
  payout, so fees collected before a scheduled cut change can be paid at the
  old cut by paying before it takes effect, as on the launch (ADR 0105).
- Held fees go to the destination in force at the payout, not the one at
  collection.
- A Quote deny list blocking the partner's recipient makes the payout abort
  until the partner sets a new recipient; collections continue and Blast's
  fees stay held meanwhile.
- The binding is permanent. To stop paying a bound partner, Blast schedules
  its cut to zero in `blast_partners`, which affects that deal on every
  product.
- `blast_fun_migrators` now uses `blast_partners`, already a dependency of
  `blast_fun`.
- ABI:
  - new functions: `launch::partner_id`,
    `vault::claim_protocol_lp_fees_with_partner`, and
    `presale_vault::pay_protocol_lp_fees_with_partner`;
  - `LpVault` and `PresaleVault` gain `partner_id`, `unpaid_protocol_meme`
    and `unpaid_protocol_quote`;
  - both `FeesCollected` events make `protocol_destination` an
    `Option<address>`;
  - new events: `ProtocolLpFeesClaimed` and `ProtocolLpFeesPaid`;
  - new errors: the migrators vault's `EPartnerMismatch` and the presale
    vault's `EWrongPartner`.

  The SDK follows: decoders, reducers, and a payout builder the SDK appends to
  collections on partnered vaults.

## Verification

- Launchpad (`sui/migrators/tests/vault_tests.move`):
  - a partnered launch's vault inherits its partner, and an unpartnered one
    none;
  - a partnered vault's collection pays every other part exactly as before,
    records no destination, and holds Blast's LP fees;
  - a permissionless payout across two collections pays the partner its
    rounded-down cut of each asset and the live destination the rest,
    agreeing with `PartnerPaid`, and leaves nothing held;
  - a zero-cut partner is paid nothing, with no `PartnerPaid`;
  - a payout holding nothing moves and emits nothing;
  - refusals: another partner, a vault without a partner, and a stale
    migrators version before the partner check.
- Presale (`sui/presale/tests/migration_rewards_tests.move` and
  `blast_presale_tests.move`):
  - a partnered sale's vault configuration carries its partner, and an
    unpartnered sale's none;
  - the same collection, payout, zero-cut, nothing-held and refusal cases;
  - an unpartnered vault's collection records the destination it paid.
- `sui/presale/scripts/check_source_boundaries.sh` pins that a presale vault's
  partner is never rewritten.
- Still to run before release: Move tests cannot observe address balances, so
  a live rehearsal of each payout reading the partner's balance is a release
  gate, as ADR 0095 requires for partner payments.
