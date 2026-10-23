## Blast Market Maker

Blast market makers fund market-making inventory alongside a bonding-curve launch or
a presale. Each vault keeps capital through launch and migration and earns fees
from permanently burned base liquidity and separate removable strategy positions.
Its creator explicitly keeps, shares or reinvests received fees in each actual
asset. Curve backers use fixed contribution weights. All presale buyers qualify
for Blast-published epoch reward allocations from canonical sale history. Neither
route gives a right to redeem trading principal or demand future fee allocations.

Curve creator-fee income is contingent: the real core creator must voluntarily
claim and escrow its authentic live fee capability. Upstream CreatorAdmin can
replace that authority. The vault cannot promise curve fees from ticket hints;
LP fees after migration follow the independently held positions and burn proof.

### Objects and authority

Each shared `blast_market_maker::market_maker::BlastMarketMakerVault` holds one Meme/Quote pair,
backer records, separate capital/fee/raise-fee balances and discoverable dynamic
object children. Curve Quote is SUI. Presale Quote is its admitted actual asset;
there is no conversion into SUI or a common NAV.

The existing shared Blast ACL authorizes protocol governance with typed
`AdminWitness` values for `blast_market_maker::blast_market_maker_domain::FeeAdmin`,
`TreasuryAdmin`, `RewardsAdmin` and `UpgradeAdmin`. The existing Blast `SuperAdminCap` grants
these roles to AdminCaps, which sign in through the existing ACL. There is no separate market maker root address,
local administrator registry or local role wrapper. Each consumer checks its
current operational generation and canonical object bindings when using a witness.

The shared `blast_market_maker::protocol_treasury::BlastMarketMakerTreasury` accepts actual
typed earned balances and pays only its stored destination under TreasuryAdmin.
The payout starts at the publisher's address. TreasuryAdmin can change it to
another nonzero address through `blast_market_maker::protocol_treasury::set_payout`.
The shared `blast_market_maker::market_maker_fee_policy::BlastMarketMakerFeePolicy` controls bounded
LP deductions under FeeAdmin. The key-only
`blast_market_maker::package_version::BlastMarketMakerVersion` binds canonical treasury,
policy and native custody identities and requires the active bytecode generation.

A publication has one bootstrap. Anyone holding it and the matching original
native UpgradeCap can call `blast_market_maker::package_admin::wrap` to seal custody
and activate the first generation. Blast UpgradeAdmin authorizes and commits
native compatible upgrades using the old active bytecode. `commit_upgrade` commits
only the native receipt and leaves the operational generation unchanged. A later
`activate_generation` call through the new bytecode requires a fresh committed
native revision and its compiled generation to equal the stored generation plus one.
A mismatched new constant cannot activate: the old generation remains usable to
authorize a repair upgrade. After activation every operational call, including
claims/refunds, requires the current generation; ungating old exit bytecode would
allow bypassing future fixes. UpgradeAdmin can replace code and belongs under
Blast governance custody.

Anyone creates an owned `blast_market_maker::market_maker::BlastMarketMakerCreatorCap` through
`new_creator_cap(ctx)`. One cap can control several vaults, each explicitly bound
to its ID at creation. It allocates received fees, withdraws idle capital, pauses discretionary actions
and rotates the operator or price signer. Normal object transfer moves control
of all vaults bound to that cap. `set_creator_cap` rebinds one vault to another
existing creator cap with the current cap's authorization. Neither transfer nor
rebinding invalidates the vault's operator or outstanding risk signatures; use
operator or signer rotation when that is intended. The creator cap may withdraw idle trading capital for distribution or other use,
including while paused and below the delegated idle Quote floor. It cannot consume
curve backer and presale reward reserves, prelaunch refunds, the burned base LP or change fixed weights.
Users trust the creator with strategy capital; the creator may withdraw all of it.

The owned `blast_market_maker::market_maker::BlastMarketMakerOperatorCap` authorizes discretionary
trading together with an independent price-policy signature. Trading remains
separate from creator fee allocation: possession of a creator cap alone does not
authorize trading. Stale operator caps can be destroyed.

### Lifecycle

The curve route starts in Funding. Filling the target permits launch before its
exclusive deadline (strictly future and at most seven days from creation); success moves to Curve and freezes backer weights. At the
deadline anyone may start Refunding if launch did not succeed. Successful core
migration moves Curve to Pool.

The presale route starts in Presale. Its core sale accepts commitments, settles,
delivers tokens/refunds and supports cancellation independently. Buyers use the
core commitment endpoint; no local wrapper tracks buyers or contribution weights.
Successful migration moves the vault to Pool. All core buyers are eligible for
epoch rewards, including buyers who have claimed their participant tokens. Core
claims delete current commitment entries, so publication tooling uses canonical
sale transaction history rather than current commitment fields. Cancelled sales
never reach the active fee-allocation phase.

### Curve flows

The creator selects a mandatory Blast `Partner` object at market maker creation.
Its ID is committed before contributions and cannot be changed at activation.
Pass that exact object again when launching. Core checks its LaunchConfig
admission when setting it on the initializer; a removed partner or changed
upstream admission can prevent launch, leaving the existing deadline/refund path.
There is no unpartnered fallback or partner-replacement path. The code is an
existing shared `Partner` object registered in Blast's partner package and
accepted by the relevant core; the market maker creator needs its reference, not a
PartnerCap or any Blast admin authority.

1. Anyone supplies a real LaunchTicket to
   `blast_market_maker::cetus_migrator::create_and_share`, together with
   immutable terms, risk limits, canonical infrastructure, Currency, an existing
   creator cap and Cetus tier configuration. It escrows the ticket, delivers the
   vault-specific operator cap and shares the new vault internally. No raw initializer or owned vault
   is returned. Ticket creator/burn settings need source/event preflight because
   the unchanged core exposes no public getters for them. Creator/burn values
   are explicitly named `unverified_*` hints, not on-chain checked guarantees.
   Currency decimals are checked independently. Before opening funding, dev-inspect
   the exact core finalize profile against the live LaunchConfig and admission
   policy; incompatible profiles remain refundable only at the stored deadline.
2. Anyone calls `blast_market_maker::market_maker::contribute_and_return_change` with
   Coin Quote and the canonical Clock. Weight equals accepted payment, capped
   at the remaining target. The returned Coin includes change and may be zero;
   transfer, merge or destroy that zero coin in the same PTB.
3. Anyone calls `blast_market_maker::cetus_migrator::launch_buy_and_share`
   after exact fill and before the deadline. The caller supplies Blast's exact
   creation fee separately from backer capital. The adapter reserves Cetus pool
   creation, builds/finalizes the launch with its sealed witness, buys under
   fixed terms and shares the core launch. An initial buy that fills the graduation
   target intentionally permits immediate graduation. All assets stay in the vault.
4. The recorded creator claims the core creator capabilities in a subsequent
   transaction and passes the live CurveFeeCap to
   `blast_market_maker::cetus_migrator::escrow_curve_fee_cap`. Deliver the separate
   metadata capability to its intended owner. The typed
   `blast_market_maker::cetus_migrator::receive_and_escrow_curve_fee_cap` also accepts
   a live cap sent to the vault object's address. The core validates live cap
   authority; CreatorAdmin can revoke/reassign it. Curve-fee receipts depend
   on voluntary live-cap escrow and can stop after core reassignment. A stale cap
   sent to the vault address stays inert: the core exposes no public non-aborting
   liveness predicate for permissionless cleanup. A new valid cap can still
   replace an already escrowed cap.
5. Anyone calls `blast_market_maker::cetus_migrator::claim_and_credit_curve_fees`
   to join actual creator receipts into the funded fee pipeline. Completely
   empty core collection retains the core's abort semantics.
6. Anyone calls `blast_market_maker::cetus_migrator::migrate_and_activate`
   when core is MigrationReady. The sealed witness releases the handoff into
   a new Cetus pool; the full-range base LP is burned, its proof stays in the
   vault, and unused seed coins remain market-maker capital. The Cetus tier
   rate is checked at launch; migration uses the same tick spacing with the live
   venue rate and does not freeze capital if that external rate changes later.

Anyone can start `blast_market_maker::market_maker::begin_refunding` at the deadline while
still Funding. Each backer calls `blast_market_maker::market_maker::refund` for its own
strictly positive remaining contribution and consumes/delivers the returned coin.
Anyone can call `blast_market_maker::cetus_migrator::return_unused_ticket`; its
recipient is fixed to the original ticket supplier.

### Presale flows

Presale V1 requires a zero idle Quote floor at creation. Retention is calculated
from actual upstream net handoff balances, so a positive precommitted floor could
disable every discretionary action before any position exists to unwind. Curve
market makers retain their explicitly funded initial idle-floor checks.

1. Anyone supplies TreasuryCap and Currency to
   `blast_market_maker::presale_adapter::create_and_share`, with immutable presale
   and trading terms, an existing creator cap and the creator-selected Blast
   `Partner` object. It reserves creation before minting and creates/shares a
   real admitted core presale and common vault. Core starts immediately with
   a fixed hard cap, closes when filled and binds that partner through the core
   initializer. Core checks the partner is accepted by its CreationPolicy. There
   is no participant vesting. Optional `team_token_bps` and `team_raise_bps` commit
   unvested token and raise allocations to the vault's address; zero disables each.
   Core checks all allocations against participant, LP and Blast shares. The presale
   cap stays escrowed.
2. Anyone calls `blast_presale::blast_presale::commit_open` with the shared sale,
   core version, Coin Quote and Clock. Core credits the real sender, returns excess
   and preserves token/refund rights. No market-maker vault input is needed.
   Consume every returned change coin. The presale's own eligibility bound applies.
3. Anyone may settle and claim through core. Claims pay the participant's wallet;
   claiming tokens does not remove that buyer from future epoch reward eligibility.
4. Anyone calls `blast_market_maker::presale_adapter::migrate` on the bound funded
   sale. The committed fraction, at most 50%, of both actual net handoff assets becomes
   retained capital; the positive remainder seeds and burns the base LP. The
   reward allocation never gates migration. No caller receives
   handoff assets, position or capability. The partnered core holds its upstream
   protocol fees for settlement. Anyone calls
   `blast_presale::blast_presale::pay_protocol_fees_with_partner` with the same
   partner, core version, upstream FeePolicy and Clock, normally as the next PTB
   command after migration. Core pays the partner its live share of the raise
   fee and Blast the remainder plus its token fee; the operation is one-time.
5. On successful migration, core sends explicit team Meme/Quote allocations to the
   vault address as owned Coin objects. Anyone supplies those object references as
   `Receiving<Coin<Meme>>` or `Receiving<Coin<Quote>>` to
   `blast_market_maker::presale_adapter::receive_team_meme` or
   `blast_market_maker::presale_adapter::receive_team_quote`, with the shared vault,
   exact bound sale and current local version. These calls require the corresponding
   team share to be configured and the vault to be in Pool. They join actual values
   into capital, without fee weight or fee revenue. Obtain owned Coin references
   from the successful migration effects and receive them in a following transaction.
   Native Receiving verifies vault ownership, not provenance; same-asset donations
   sent to that vault are accepted as capital too. This is no claim on participant
   tokens, which remain in core custody.
6. Core cancellation/refunds remain authoritative if the commitment target or
   liquidity deadline fails. The wrapper holds no mirrored refundable
   principal. Anyone may retire its cancelled escrowed PresaleCap through
   `blast_market_maker::presale_adapter::destroy_cancelled_presale_cap`.

Anyone settles partnered launch protocol fees through
`blast_fun::launch::claim_protocol_fees_with_partner`, supplying the exact launch,
core version, runtime configuration, partner and Clock. This pays Blast's fixed
upstream fee bucket to its treasury and the partner recipient. It is separate
from creator-fee collection into the market maker.

### Managed liquidity and trading

A cap holder plus risk signer may call
`blast_market_maker::cetus_migrator::buy` or
`blast_market_maker::cetus_migrator::sell` during Curve. They spend retained capital
through unchanged core operations and retain outputs and change.

In Pool the same authorities may use
`blast_market_maker::cetus_engine::open_position`,
`blast_market_maker::cetus_engine::add_liquidity`,
`blast_market_maker::cetus_engine::remove_liquidity` and
`blast_market_maker::cetus_engine::swap`. Opening atomically funds its new position and returns its inert ID. The signature
commits both tick bounds, maximum token inputs and minimum liquidity. All actions bind the exact pool and
module-owned position; at most eight ordinary positions coexist. The permanently
burned base position is separate and never supplies principal to these operations.
Fees settle through the pipeline before adding or removing ordinary liquidity.

Anyone with a risk signature may call `blast_market_maker::cetus_engine::unwind`
to remove all remaining nonzero liquidity from one managed position, while
paused or after budgets run out. It advances the nonce without consuming
turnover or discretionary action allowance. It can finish below the idle Quote
floor because it spends no capital and reduces position exposure. The signature
may explicitly set both output minima to zero for dust cleanup; venue rounding
and subsequent empty-position close still require native runtime verification. Anyone may use
`blast_market_maker::cetus_engine::close_empty_position` only after zero liquidity,
fees and rewards. `blast_market_maker::cetus_engine::quarantine_managed_reward` retains
actual unsupported reward assets in permanent typed quarantine; it creates no Quote
fee rights or payout, and no governance sweep exists. Fee settlement is permissionless through
`blast_market_maker::cetus_engine::collect_base_fees` and
`blast_market_maker::cetus_engine::collect_managed_fees`.

At finalization, team token BPS are apportioned against total minted supply and
team raise BPS against the fixed raise target. Token shares for participants, LP,
Blast and team must total 10,000; team plus Blast raise shares must leave a positive
LP share. Core uses largest remainders: floor each share, then give leftover atoms
to the largest fractional remainders. Token ties follow participant, LP, Blast,
team order; raise ties follow team, Blast, LP order. Configured recipients and LP
must receive positive amounts. Retention is a separate floor-rounded fraction of
the actual remaining migration handoff after upstream allocations.

### Capital management and returning assets to users

Anyone calls `blast_market_maker::market_maker::deposit_capital` in Curve or Pool
with Meme and Quote coins; at least one must be positive. Deposits create no
weight, fee entitlement or redemption right. Bought inventory, retained migration
assets, team allocations, unused pool-seeding coins and managed-position removal
proceeds remain capital.

The bound creator cap holder calls `blast_market_maker::market_maker::withdraw_capital`
with current version and explicit Meme/Quote amounts. It returns both coins,
including zero coins, for transfer to users, team payouts or other PTB composition.
Use a managed-position removal first when capital is deployed in a range. The
withdrawal spends only idle capital and can withdraw all of it; risk signatures,
trading budgets, pause and delegated idle floors do not constrain this creator
asset-disposition authority. Funding and cancelled/refunding states reject.
Unallocated fees, reserved user fees, treasury buckets and the burned base position
remain unavailable through this call. Consume or transfer both returned coins.
A capital transfer is distinct from a backer's fee claim and is not recorded as fees.

### Fees and rounding

BPS means a share of 10,000. The curve raise fee is floor(target * 500 / 10000),
assessed once only when launch succeeds. Presale adds no local raise fee.
Upstream raise/token fees and migration allocations still apply independently.
The upstream PresaleVault LP-fee settings do not route receipts for this sealed
external migrator; this protocol applies its own post-migration LP policy and
treasury. Core LP-fee metadata does not create a second deduction here.

The local per-asset LP deduction defaults to zero. Applied rates cannot exceed
2000 BPS or the market maker's snapshotted maximum, whichever is smaller. Its amount
rounds up, so a one-atom LP receipt may go wholly to the local treasury. Gross LP
receipt equals direct treasury deduction plus the net receipt. Curve creator
receipts have no additional local LP deduction.

The creator-selected partner affects only upstream Blast partner-eligible fees.
Its recipient and live share follow the existing Partner object's governance;
binding the ID does not freeze those terms. A presale's token fee is never shared
with the partner. This market maker adapter does not construct Blast's ordinary
LP vault, so its base/managed LP receipts use this package's own policy without
an additional Blast or partner LP deduction. Partner payments do not enter
market maker capital, backer weights or funded fee revenue.

Both Meme and Quote net fee receipts enter separate unallocated fee balances.
Neither asset automatically reinvests or receives an additional platform split.
Trading capital, retained migration assets, team allocations, unused seed coins
and the curve raise fee never enter these available fee balances.

Only the bound creator cap can call `blast_market_maker::market_maker::allocate_fees`.
For each asset, pass `blast_market_maker::fee_ledger::allocation(keep, share, reinvest)`
in actual atomic units. The sum cannot exceed that asset's received, unallocated
fees. `keep` returns a Coin to the caller. Curve `share` irrevocably funds
fixed-weight backer claims; presale `share` funds a segregated epoch reward reserve
without a local buyer denominator. `reinvest` moves fees into trading capital. The call returns both
Meme and Quote coins, including zero coins; consume or deliver both in the PTB.
An allocation may leave some fees unallocated. Curve sharing requires positive
frozen weight. Presale sharing has no wrapper-weight requirement.

`blast_market_maker::market_maker::fee_balances` returns available Meme, available Quote,
reserved Meme and reserved Quote, in that order. Presale reserves here are
allocated rewards not yet published; already funded rounds hold their own balances.
`claimable_fees` reports only curve backers' funded entitlement in both assets. These public views require
no creator authority.

Curve fixed weights use separate per-asset Q64 cumulative indices with global and
per-backer remainders. Only explicitly shared fees enter these indices. Claims
round down; repeated claims preserve fractional entitlement. Reserved fees cannot
be reclaimed, reallocated or reinvested by the creator. Rounding stays reserved
with no expiry or dust sweep. A first claim may leave one atom pending even when
one backer owns the full weight.

Each curve backer calls `blast_market_maker::market_maker::claim_fees` for its own sender row in
Curve or Pool. It returns `(Coin<Meme>, Coin<Quote>)`; deliver or consume both,
including zero. Anyone can move the segregated curve raise fee to the bound treasury through
`blast_market_maker::market_maker::credit_raise_fees_to_treasury`. An empty bucket rejects. TreasuryAdmin
withdraws earned balances only to the stored payout and cannot withdraw vault
capital, unallocated creator fees or reserved backer fees.

### Presale epoch rewards

1. The creator cap holder calls `blast_market_maker::market_maker::allocate_fees`
   with positive `share` amounts to fund rewards in either asset. These balances
   cannot be kept, reinvested, withdrawn as capital or paid to the treasury.
2. Blast admin signs in to the existing ACL as
   `blast_market_maker::blast_market_maker_domain::RewardsAdmin`, then calls
   `blast_market_maker::presale_rewards::publish_round` with the active vault,
   version, witness and allocation commitment. Each vault starts at round zero;
   publication increments the number once. Checkpoint intervals satisfy
   previous end <= start < end, allowing skipped epochs. Publication debits only
   the allocated reserve and creates a shared
   `blast_market_maker::presale_rewards::BlastPresaleRewardRound`.
3. Anyone relays `blast_market_maker::presale_rewards::claim` using that shared
   round, current market-maker version, index, beneficiary, amounts and proof.
   Both actual coins are transferred directly to the committed beneficiary.
   The vault, creator, operator and admin are not needed. A bitmap prevents repeat
   payment. Claims remain available while trading is paused. There is no expiry,
   close, creator recovery or gas reimbursement path.

The off-chain publisher includes all core presale buyers, independent of purchase
routing and participant-token claim status. Blast is trusted for eligibility,
allocation completeness, weighting and matching root totals to the funded budget;
Move verifies commitments and custody, not an off-chain buyer list. A cancelled
buyer has no successful-sale allocation. Retained migration assets, team tokens,
team raise and unused seed coins remain creator-managed trading capital and do
not implicitly become rewards. Creator choice still controls when fees are shared.

An epoch root commits 1–65,536 positional leaves. A leaf is Blake2b-256 of
`0x00 || UTF8("blast-market-maker-presale-rewards-v1") || BCS(vault ID) ||
BCS(round u64) || BCS(index u64) || BCS(beneficiary address) || BCS(Meme u64) ||
BCS(Quote u64)`. An internal node hashes `0x01 || left digest || right digest`.
Proofs contain exactly ceil(log2(leaf count)) 32-byte siblings, bottom-up, using
index parity for ordering and the existing Blast duplicate-last rule for odd tree
widths. The root and manifest digest are each 32 bytes. The manifest is an
independently retrievable allocation artifact; its digest is emitted at publication.
Payout amounts are committed atomic units. Rounding belongs to the off-chain
manifest policy; undistributed or underclaimed budget stays reserved forever.
No round may spend another round's funds or the vault's trading inventory.

### Time and risk authorization

The canonical Clock uses milliseconds. Contributions and curve launch require
now strictly before the deadline; refund activation requires now at or after it.

`blast_market_maker::market_maker::signing_bytes` returns canonical BCS for the current
key epoch and next nonce. The message binds the original package domain, market_maker,
external launch, original asset types, exact pool, current operator-cap identity,
action inputs/minima/position/ticks/price limit and issued/expiry times. Ed25519
uses a 32-byte public key and 64-byte signature. Require issued <= now <= expiry
and expiry minus issued <= 15 seconds. Each success consumes its current nonce.

Immutable limits bound per-action atoms, token buckets, lifetime gross inputs,
Quote self-fee basis and discretionary action count. The default
`blast_market_maker::market_maker::trading_limits` constructor gives non-refilling
lifetime-sized buckets; `blast_market_maker::market_maker::with_rate_limits` commits
explicit rolling/refill and self-fee limits. Gross inputs charge both trading
directions and LP deposits. Removal never refills budgets. Claims, collection,
refunds and migration remain usable while discretionary trading is paused. The creator
can pause a funded curve before launch, vetoing launch until the deadline; full
principal refunds remain available at that deadline. No raise fee is charged then.

### Reading, events and common failures

Read canonical shared-object content and dynamic-object-field children to inspect
current authority, immutable terms, principal and segregated balances. The private
UID has no public borrowing or generic receiving seam; presale pair-asset receipt
is exposed only through typed, sale-bound calls. Initial ticket, core
creator-fee cap, pool reservation, burn proof and ordinary position IDs remain discoverable
as dynamic object children. Quarantined reward balances are typed ordinary fields.
The pair-reordering helper temporarily uses two dynamic fields on a fresh UID and
deletes them in the same transaction; this preserves exact typed values but adds
gas/object writes that require native-venue profiling before release.

Creation, accepted contributions, refunds, cap changes, fee receipts, allocations,
treasury credits, capital deposits/withdrawals, activation and signed actions emit
completed facts. Unused migration seed coins
remain capital, available to the creator after activation. `BlastCurveFundingActivated`
records gross funding, the assessed raise fee and net capital. `BlastTreasuryCredited`
records the vault and actual typed amount without a revenue-source tag. The
funding event and `BlastLpFeesCollected` describe the originating fee flows;
sender-linked contribution/refund/claim events use transaction sender metadata. `BlastExternalBound` records
the later curve launch binding.

`BlastFeesCredited` records actual Meme and Quote receipts. `BlastFeesAllocated` records the
creator cap and both per-asset allocation triples. For each asset, cumulative net
receipts equal its available balance plus cumulative kept and reinvested amounts
plus cumulative shared amounts. Curve shared amounts equal backer payouts
plus reserved dust and claims. Presale shared amounts equal the unpublished reward
reserve plus funded-round balances plus paid epoch rewards.
`BlastPresaleRewardRoundPublished` commits the vault, round, checkpoint interval,
root, manifest digest, leaf count, both budgets and remaining unpublished reserves.
`BlastPresaleRewardPaid` records the index, beneficiary, payouts and remaining
round balances. These facts permit independent per-asset reconciliation. Sharing is an explicit
creator decision; a receipt alone never creates a backer liability.

Version mismatches require the active deployment/version or reviewed dependency
relink. Wrong pool, launch or position means the supplied objects belong to
another vault. Deadline failure requires waiting for refunds or taking the
appropriate core presale path. A stale signature requires a fresh quote for the
current nonce/key epoch; an exhausted immutable budget cannot be raised by an
administrator. Unsupported nonzero rewards must be quarantined before close.

`BlastCapitalDeposited` and `BlastCapitalWithdrawn` record vault and actual pair-asset
deltas; withdrawals also identify the authorizing creator cap. They preserve the
separation between capital disposition and received-fee allocation. Migration team
payouts are first visible in core effects as coins owned by the vault; the deposit
event records their later receipt into spendable capital.

### Questions integrators ask

1. **Can backers redeem principal?** Backers have no automatic redemption right.
   The creator may voluntarily withdraw idle capital and transfer it to users;
   backers separately claim fees explicitly allocated to them.
2. **Are base and managed LP the same?** No. Base LP is burned permanently.
   Ordinary managed positions retain removable principal under vault custody.
3. **Does a direct presale purchase qualify for MM fees?** Yes. All core presale
   buyers qualify for epoch allocations from creator-shared fees, including
   buyers who already claimed tokens.
4. **Can a core-only presale migrate and share fees?** Yes. No wrapper buyer
   denominator exists. The creator shares fees and Blast publishes buyer epochs.
5. **Does retention reduce bought tokens?** It applies after upstream allocation
   to migration handoff balances. Participant token allocation stays unchanged.
6. **Can a keeper withdraw collection proceeds?** Collection retains them in
   vault accounting. Only the bound creator cap allocates unallocated fees, and
   curve backers claim their funded weights. Presale rewards pay proof-bound
   buyers from independently funded epoch rounds.
7. **Can CreatorAdmin seize managed LP?** Its upstream authority can invalidate
   the curve creator cap. It grants no authority over this protocol's LP custody.
8. **Does the signer prove market price?** It is a trusted independent risk
   signer, not an on-chain price oracle. Colluding authorities can lose capital
   within immutable limits.
9. **Can governance change code?** Blast UpgradeAdmin can authorize
   compatible replacement code. Governed upgrades are a broader trust boundary.
10. **Do local tests prove Cetus execution?** Local stubs prove linkage only.
    Actual target-network PTBs and custody/ABI evidence are required for release.
