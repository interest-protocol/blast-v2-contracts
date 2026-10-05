# 0105: Permissionless launch fee claims, paid to a rotatable treasury

- Status: proposed
- Date: 2026-10-05
- Amends: [0098](0098-launch-creation-fee-and-partners.md), whose "Paying the
  partner" claims returned Blast's part to the treasury administrator, and
  [0022](0022-dual-asset-fee-ledger-and-claims.md), whose protocol claim was
  administrator-only

## Context

Under ADR 0098 only the treasury administrator (`TreasuryAdmin`) could claim
Blast's fees from a launch: the creation fee, Blast's part of every curve trade
fee, and the one-time migration fee. `claim_protocol_fees` and
`claim_protocol_fees_with_partner` returned Blast's coins to that caller. A
launch's partner is paid its share only inside that claim, so a partner waited
on Blast to be paid.

On 2026-10-05 the owner asked for both claims to be permissionless. The partner
can then claim its own launches. Every payout goes straight to a fixed
destination, so the caller chooses nothing: the partner's share goes to its
`Partner` recipient, and Blast's part goes to a treasury address in
`RuntimeConfig` that an administrator rotates.

## Decision

**Treasury.** `RuntimeConfig` gains `treasury: address`, set to the publisher at
initialization, as with the migrators' `LpFeePolicy` destination and the
presale `FeePolicy` destination. `runtime_config::set_treasury`, authorized by
`AdminWitness<TreasuryAdmin>` and version-gated first, replaces it. It rejects
`@0x0` (`EInvalidDestination`) and the current address (`EUnchanged`), and emits
`TreasuryChanged(address)`. Claims read the treasury live, so a rotation applies
to every later claim on every launch.

**Permissionless claims.** Neither claim takes an administrator witness. Each
takes `&RuntimeConfig` after the `PackageVersion` and returns nothing:

- `claim_protocol_fees(launch, package_version, runtime_config, ctx)` claims from
  a launch that names no partner and pays everything to the treasury.
- `claim_protocol_fees_with_partner(launch, package_version, runtime_config,
  partner, clock, ctx)` claims from a launch that names exactly `partner`. As
  before, it pays the partner its rounded-down share of each balance through
  `blast_partners::pay`, then pays the treasury the rest.

Guards and their order are unchanged: the version, then the partner check
(`EPartnerMismatch`), then the empty-ledger check (`ENothingAccrued`). Each
positive Meme, Quote, and SUI balance reaches the treasury as one coin; a zero
balance is destroyed instead of sending an empty coin. `RuntimeConfig` has no
constructor outside the package initializer, so a caller cannot substitute
another treasury.

**Event.** `ProtocolFeesClaimed` gains `treasury: address` after `launch_id`.
The claimant is no longer Blast, so the payee is recorded with the amounts, as
the presale `ProtocolFeesPaid` and the migrators' `FeesCollected` record their
destinations.

**Ledger.** `fees::claim_protocol_fees` returns the three balances instead of
coins, so the launch pays the partner and the treasury from them directly.

## Alternatives considered

**Keep the admin claim and add a partner-only claim.** A partner would still
wait on Blast for unpartnered launches' accounting, and two paths would release
the same balances. One permissionless path keeps a single payout rule.

**A caller-supplied recipient checked against the treasury.** The parameter
would only be a value the contract checks against its own copy. Reading the
treasury from `RuntimeConfig` leaves the caller nothing to choose.

**The treasury in `LaunchConfig`.** `LaunchConfig` holds what launch creation
snapshots. The treasury is read live at each claim, like the protocol fee share
that trades read, so it belongs with the other live settings.

**An unset treasury that blocks claims until configured.** A zero default would
add a liveness gate and a distinct unset state. The publisher default matches the
two sibling destinations, and the deployment rotates it to the treasury before
launches accrue fees.

**Snapshotting the treasury per launch.** A rotated treasury must keep
receiving every launch's fees, as ADR 0101 rules for presale LP fees.

## Consequences

- Anyone, the partner included, can trigger a claim at any time. The caller
  cannot redirect or keep any part of it. Claims stay all-or-nothing per launch,
  and an empty ledger still aborts, so a claim cannot emit an empty event.
- The partner share applied is still the one in force at the claim. Since anyone
  may claim, fees accrued before a scheduled share change can be settled at the
  old share by claiming before the change takes effect. Blast no longer chooses
  when a partner is paid.
- A compromised `TreasuryAdmin` can redirect Blast's future launch fees, but can
  no longer withdraw them to itself in one call. It cannot touch the partner's
  share or the creator's fees.
- Each payout is a coin object sent to the treasury, observable in transaction
  effects. The partner keeps `blast_partners`' address-balance payment.
- ABI and indexing:
  - both claims drop the `AdminWitness<TreasuryAdmin>`, take `&RuntimeConfig`,
    and return nothing;
  - new function: `runtime_config::set_treasury`;
  - new event: `TreasuryChanged`;
  - `ProtocolFeesClaimed` gains `treasury`.

  The SDK builders, decoders and reducer follow.
- Deployment: after publication, the treasury administrator sets the treasury
  before the first launch's fees are claimed.
- Out of scope: the creator's curve-fee claim keeps its `CurveFeeCap`, and the
  migrators' `vault::claim_protocol_fees` for migration residuals keeps its
  `TreasuryAdmin` witness.

## Verification

- `RuntimeConfig` tests:
  - initialization pays the publisher;
  - the setter emits each new address;
  - refusals of the zero address and the current address;
  - the version check before the address.
- Launch tests:
  - a non-administrator's claim pays the treasury, not the sender, with no
    coin for a zero balance;
  - a rotated treasury receives every later claim, and the old one nothing more;
  - the partner's own claim pays it its share and the treasury the rest,
    including the creation and migration fees;
  - a zero-share partner pays the treasury everything;
  - the version check before the partner check, and the existing partner
    refusals.
- `ProtocolFeesClaimed` bytes are pinned with the treasury in every claim test.
- `scripts/check_source_boundaries.sh` pins:
  - the role map without the claims and with `set_treasury`;
  - both claim signatures, so no caller chooses a payee;
  - the one `pay_treasury` helper and its zero-skip;
  - three treasury payouts before the claim event;
  - the `RuntimeConfig` layout, setters and events.
