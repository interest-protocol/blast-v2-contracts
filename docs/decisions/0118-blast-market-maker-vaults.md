# 0118: Blast Market Maker vaults

- Status: accepted
- Date: 2026-10-23

## Context

Market-making inventory must persist through a bonding launch or a presale and
migration, without modifying Launchpad, Migrators or Presale. The product belongs
to Blast and uses its ACL. A creator may manage several vaults with one capability
and decide how received fees are used. This decision supersedes the earlier
standalone-governance and mandatory 80/20 distribution proposal.

## Decision

Name the product **Blast Market Maker** and the package `blast_market_maker`.
The name describes its continuing inventory and range-liquidity operations across
bonding-curve and presale routes.

The `blast_market_maker` side package shares generic vault custody, risk checks, typed fee accounting and
Cetus position execution across two sealed-witness migration adapters. It depends
on existing public core extension points and Blast ACL; no existing package changes.
Upstream governance admits the exact witnesses through existing configuration.
The package defines FeeAdmin, TreasuryAdmin and UpgradeAdmin roles for Blast ACL
AdminWitness authorization. It has no second root, address-role registry or
implicit publisher privileges. Its canonical typed treasury remains separate from
vault capital and backer reserves; Blast ACL controls its earned-asset withdrawals,
bounded LP policy and native upgrade operations.

Each vault binds one reusable BlastMarketMakerCreatorCap ID. The holder can pause, rotate
operators/signers, allocate received fees, deposit/withdraw idle capital and rebind that vault to another existing
creator cap. Native transfer moves authority over every vault bound to that cap;
rebinding moves one vault. Neither operation implicitly revokes delegated operators
or signed authorizations; explicit rotation does. Discretionary execution still
requires a per-vault operator and an independent Ed25519 risk signature. Creator
and operator caps confer no protocol ACL role. The creator cap may withdraw idle
capital after launch, including while paused, for distribution or other composition.
This supersedes the prior capital-lock restriction: immutable risk limits restrict
delegated trades, not creator withdrawals. The creator can exhaust strategy capital.
Neither authority can take funding refunds, fee liabilities or the burned base LP.

Each creator selects a mandatory upstream Blast Partner per market maker. Curve
creation commits its ID before funding and activation supplies that exact object.
Presale construction sets the selected Partner before finalization. Core admission
and existing permissionless partner-fee settlement remain authoritative; removing
admission before curve activation can prevent launch, with deadline refunds still
available. Partner recipient/share remain governed upstream. Partner fees are
separate from the vault creator's fee allocation and local LP policy.

Curve backers fill an exact target before an exclusive deadline bounded to seven
days. Successful launch charges a committed 5% raise fee into a separate protocol
balance, performs the fixed initial buy, and retains inventory. Failure to launch
permits full principal refunds at the deadline and return of the unused ticket to
its supplier. The committed new-address minimum and bounded backer count prevent
cheap table exhaustion. Curve weights freeze on successful launch.

Presale principal and participant token/refund rights stay in core custody. The
wrapper records only accepted commitments through its own endpoint. Direct core
buyers receive no vault fee weight. Successful migration freezes wrapper weights;
a zero wrapper denominator does not prevent migration. Presale terms can retain
at most half of each actual net Meme/Quote migration handoff. Optional explicit
team token and raise shares name the vault address as their sole recipient.
Core validates them with participant/LP/Blast allocations and releases them on
successful migration as vault-owned coins. Narrow typed Receiving joins them into
capital after activation; it also admits same-asset donations because native
ownership proofs do not establish sender provenance. These receipts grant no fee
weight or redemption right. Participant tokens remain in core claim custody;
there is no extra local presale raise fee.
Presales require a zero idle Quote floor because their actual net handoff is not
known at creation. Quote is its admitted asset, while curve Quote is SUI.

Both routes permanently burn their positive full-range graduated base LP and
retain its fee proof. The vault can independently open, add to, partially or fully
remove, and close up to eight simultaneous ordinary managed range positions.
Removals return principal to vault capital; the creator can subsequently distribute
that idle capital through composable Meme and Quote coins. The burned
base proof has no principal-release path. Unknown rewards remain quarantined.

Each asset has separate capital, unallocated received fees and reserved backer
fees. Curve fee receipts and LP receipts after configured local LP deductions enter
unallocated fees. There is no automatic platform split or Meme reinvestment. The
creator chooses explicit keep/share/reinvest amounts independently for Meme and
Quote. Keep returns composable coins, share funds irreversible backer reserves,
and reinvest moves only unallocated fees into trading capital. Unselected fees
remain unallocated. Sharing is permitted only after weights freeze and requires
positive total weight; a zero-backers creator can choose keep or reinvest instead.
Backers have no guaranteed share before allocation and no automatic right to redeem
capital. Creator-directed capital transfers can voluntarily return assets to users;
capital never enters the received-fee ledger.

Asset-generic fixed-weight Q64 ledgers preserve global and per-user remainders.
Claims withdraw only actually funded reserves. No creator, treasury or dust-sweep
path can reclaim them. Public views expose unallocated/reserved balances and
backer claimable amounts; on-chain balances are not private. Local LP deductions
and curve raise fees enter the same typed earned treasury balances, without an
event-only revenue-source type. The treasury always stores a payout address,
initially the publisher's; TreasuryAdmin can rotate it to another nonzero address.
Unused pool-seeding
coins remain market-maker capital rather than treasury revenue.

Signatures bind action parameters, assets, vault, external object, operator, nonce,
key epoch and at most 15 seconds of validity. Immutable per-action, rolling,
lifetime, self-fee conversion and action-count limits remain enforced after fee
reinvestment. Signed full-position unwind stays permissionless during pause or
exhausted discretionary budgets. Fees, claims, refunds and migration stay available
during pause. Controlled trading can lose money, and creator-directed fee income
can include bounded fees generated by the vault's own trades.

Publication consumes a unique bootstrap and seals Publisher/UpgradeCap custody
before the first usable generation exists. UpgradeAdmin witnesses authorize and
commit native compatible upgrades through current bytecode, without advancing the
operational generation. New bytecode activates only its checked-next generation
after a fresh committed native revision. A wrong generation leaves old bytecode
available for repair. Every operational path, including claims/refunds, checks the
current generation. Canonical custody, treasury and policy bindings are retained;
ACL membership alone cannot substitute a foreign infrastructure object. Native
upgrade authority can replace code and must be held under Blast governance.

Explorer-visible marker, key objects, wallet caps and direct events carry Blast
identity under ADR 0085. Internal ledger values and sealed keys retain short
residual names recorded in the explorer survey. The local address alias does not
carry on-chain identity.

## Consequences

The new package needs Blast ACL role assignments and upstream witness admission,
while existing contracts remain frozen. Core upgrades can require a governed
compatible market maker relink; passing newer version objects alone does not relink
bytecode. Real core creator-fee authority remains voluntary and revocable upstream:
the authentic live CurveFeeCap must be claimed and escrowed after core sharing.
Ticket metadata hints are not promises of on-chain creator authority.

No arbitrary pre-created pool, raw initializer, migration witness, base proof,
managed position or migration asset can escape through public construction.
Upstream admission, venue policy, native receiving, dependency identity and
governed upgrades remain explicit trust and integration boundaries.

## Verification

Meaningful local tests cover both core routes, fee isolation and conservation,
creator multi-vault control/transfer/rebinding, frozen weights, typed ACL grants
and revocation, signature/risk limits and native custody/generation guards.
Local venue stubs establish linkage only. Release still requires actual Cetus
construction/actions, real PTBs and rollback, shared-parent Receiving, custody
discovery, maximum-cardinality gas and distinct-bytecode upgrade/relink evidence.

## Sources


| Fact | Pinned source |
| --- | --- |
| Existing public launch construction, curve, cap and migration seams | [Launchpad at 01d7659617abcd552cece6d05b9db409ec4ff2c0](https://github.com/interest-protocol/blast-v2-contracts/blob/01d7659617abcd552cece6d05b9db409ec4ff2c0/sui/launchpad/sources/launch.move) |
| Existing presale construction, accepted commitments, claims and handoff | [Presale at 01d7659617abcd552cece6d05b9db409ec4ff2c0](https://github.com/interest-protocol/blast-v2-contracts/blob/01d7659617abcd552cece6d05b9db409ec4ff2c0/sui/presale/sources/blast_presale.move) |
| Cetus remove/close/fee/reward interfaces | [Official interface at 5ef409e5aa97cf0c545c5ff64560cb65eaa981e7](https://github.com/CetusProtocol/cetus-clmm-interface/blob/5ef409e5aa97cf0c545c5ff64560cb65eaa981e7/sui/cetus_clmm/sources/pool.move); deployment equivalence is independently checked against the pinned live revision before release |
| Native custody and Receiving semantics | [Sui at 06734f6ff0af45d8632a14a4dc4b100197f6b1a2](https://github.com/MystenLabs/sui/tree/06734f6ff0af45d8632a14a4dc4b100197f6b1a2/crates/sui-framework/packages/sui-framework/sources) |
