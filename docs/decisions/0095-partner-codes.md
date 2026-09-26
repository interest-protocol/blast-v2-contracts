# 0095: Partner codes in one immutable package

- Status: proposed
- Date: 2026-09-26

## Sources

| Ref | Full commit | Repository |
| --- | --- | --- |
| `sui@06734f6` | `06734f6ff0af45d8632a14a4dc4b100197f6b1a2` | MystenLabs/sui (the pinned framework) |
| `util@63b6cf8` | `63b6cf86c0e1a74f699610fe182b1de8d8789a14` | interest-protocol/blast-util-contracts |
| `deepbook@a60c1ee` | `a60c1eeeec65a61ebc8c76e58492f5dee0674840` | MystenLabs/deepbookv3 |
| `dhedge@f09febf` | `f09febf528895fdd5b69f68b0dd3a9bb7d9ecc0c` | dhedge/V2-Public |
| `dydx@127ef76` | `127ef76506ccca909d937920980c1ae2d9b736a5` | dydxprotocol/v4-chain |

## Context

Integrators that build on Blast (wallets, trading frontends, bots, aggregators)
asked for partner codes. On 2026-09-26 the owner set the model: a partner earns
a percentage of the fee Blast charges on every trade that names it, sent straight
to the partner's address; Blast's administrator sets each partner's share from 0
to 80%; the partner sets its recipient with a `PartnerCap`; a partner that wants
an extra fee adds it in its own transaction. The same model serves Boosts now and
the launchpad later. The owner then asked for:

- a forced timelock on Blast's powers over partners: every change to a share or
  a cap takes effect seven days later, and nobody can shorten that; a new deal's
  share applies from registration (owner, 2026-09-26);
- that timelock as its own immutable package in the public util contracts, for
  anyone to reuse;
- one cap per company across several deals, each with its own share (for
  example 50% on Boosts and 8% on another product);
- an event for every payment a partner receives;
- plain `mint` and `redeem` left exactly as they were, with separate entry points
  for trades that name a partner, so the many users without one pay for nothing
  extra.

Two program families exist elsewhere. In one, the integrator adds its own fee on
top (Hyperliquid builder codes; dYdX builder codes capped at 1%,
`dydx@127ef76:protocol/x/clob/types/message_place_order.go:28`). In the other,
the protocol pays a partner part of the fee it already charges (dYdX order
routers up to 80% of the protocol fee,
`dydx@127ef76:protocol/x/revshare/keeper/msg_set_order_router_rev_share.go:16`;
dHEDGE referrers paid "from manager's portion only, DAO share is never
affected", `dhedge@f09febf:contracts/utils/PoolLogicLib.sol:163`). The add-on
family exists there because orders are executed after the user signs, so consent
has to travel inside the protocol. On Sui the user signs the whole transaction,
and a frontend adds its own fee with one coin split that no contract cap could
stop. Only the carve-out needs the contracts.

Failures on record: Aftermath perpetuals lost about 1.14M USDC on 2026-04-29 to
an integrator fee that went negative; DeepBook spot lets a referrer raise its
rate after users bind to it; Level Finance lost about $1.1M to referral tiers
lifted with flash-loaned volume; partner programs that write a shared partner
object on every trade serialize that partner's flow. The launchpad's earlier
referral proposal ([0009](0009-referrals-and-revshare.md)) rejected per-trade
payouts because the referrer was any address the caller passed; a code Blast
issues answers that.

## Decision

**The timelock.** `blast_fun_timelock` lives in the public util contracts
(`util@63b6cf8:sui/timelock/sources/blast_fun_timelock.move`), MIT licensed and
published immutable on mainnet at `0x1749b76a3ae065dedfe847578b07826fa83d1e18ff485d9e4f9647f3698e104d`. `Timelocked<T>` is a value whose
every change takes effect exactly its delay after it is scheduled; the delay is
fixed when the value is created (any positive number of milliseconds). A new schedule replaces a pending one and
restarts the delay, so scheduling the value in force cancels. Reads are lazy: the
value in force comes from the Clock the caller already has, so nothing writes on
a trade and no keeper applies anything. The module that stores a `Timelocked`
decides who may schedule it.

**The partner package.** `blast_partners` is a leaf package that depends only on
`blast_admin` and the timelock. Boosts and the launchpad are independently
deployed peers, and the Boosts core is immutable, so no existing package can hold
a type both read. It is published and made immutable in one transaction
(`sui/partners/scripts/publish_immutable.sh`): the delay is only as credible as
the packages that enforce it. It has its own `blast_admin` domain,
`BLAST_PARTNERS`, with one role, the partner administrator. One role covers
registering, scheduling shares and moving partners between caps: a registration
pays only on flow that names the new deal, share changes and cap moves wait the
delay, and the root can revoke the role at once, so splitting them per action
([0094](0094-one-role-per-administrator-action.md)) would protect nothing more.

**Partners and caps.** A `Partner` is one deal: a shared object with a
`recipient`, a `share_bps` of Blast's fee (at most 8,000, timelocked) and the ID
of the cap that manages it (timelocked). A `PartnerCap` is a company's authority
over the recipients of every partner bound to it; one cap can manage any number
of partners, each with its own share and recipient. `new_cap` mints a cap that
controls nothing until Blast registers a partner under it, so anyone may mint one.

- `register(cap_id, recipient, share)` shares a partner managed by that cap,
  with its share in force at once.
- `schedule_share` sets the share seven days ahead.
- `schedule_cap` moves the partner to another cap seven days ahead, to replace a
  lost or stolen cap. Until then the current cap keeps working.
- `set_recipient`, called with the partner's live cap, changes the recipient at
  once.
- `destroy_cap` destroys a cap, live or not.

**Payment.** `pay(partner, fee, clock)` takes a product's own fee on one trade,
sends the partner `floor(fee × share / 10_000)` with `balance::send_funds`
(`sui@06734f6:crates/sui-framework/packages/sui-framework/sources/balance.move:102`),
the address-balance accumulator that needs no object input, leaves the rest in
`fee`, and returns the amount. DeepBook Predict pays builder codes the same way
(`deepbook@a60c1ee:packages/predict/sources/expiry_market.move:1623`). Every
payment emits `PartnerPaid<T> { partner_id, amount }`; a zero share sends and
emits nothing. Anyone calling `pay` pays the partner from their own balance, so
the event always records money the partner really received. `PartnerUpdated`
carries a partner's complete terms, both timelocked values included, after
registration and after every change.

**Boosts.** `operations::mint` and `operations::redeem` are unchanged.
`mint_with_partner` and `redeem_with_partner` take `&Partner` after the
`Protocol`, run the plain operation, and then pay the partner out of the admin fee
it just retained: the increase in Blast's admin cash across the operation is
exactly that fee. The reserve fee, the shares minted and the redemption net are
the plain operation's. `PartnerFeePaid<Product> { vault_id, partner_id,
admin_fee, partner_fee }` records the payment against the vault, also when the
partner is paid nothing, so the flow stays attributed. It carries no admin-cash
total: it follows the operation's `Minted` or `Redeemed` in the same transaction,
and Blast's admin cash is that event's `admin_cash_after` minus `partner_fee`. The adapter
never calls `send_funds` itself, and only `operations` calls `pay` (source gate).

**Each product accepts its own partners** (owner, 2026-09-26). A deal is priced
for one product, so a product pays only the partners it accepts: otherwise a 50%
Boosts deal could be named on the launchpad. Boosts keeps the list on its
`Protocol`, one dynamic field per partner under `PartnerKey(ID)`, whose value is
the time the partner stops being accepted (`u64::MAX` until removed). The
`Protocol` layout does not change, and partner trades take no new object: they
already read `&Protocol`. The Boosts risk administrator, who already sets each
vault's admin share and withdraws its admin cash, calls `operations::add_partner`
and `operations::remove_partner`. Adding is instant and cancels a pending removal.
Removing takes effect `blast_partners::delay_ms()` later, and the partner stays
accepted and paid until then; the owner ruled no instant removal is needed, since
a bad cap redirects only that partner's payouts. `mint_with_partner` and
`redeem_with_partner` abort with `EPartnerNotAccepted` before any venue work for
a partner Boosts does not accept. `PartnerAdded` and `PartnerRemoved { partner_id,
accepted_until_ms }` record every change.

**The launchpad, later.** `buy` and `sell` gain partner variants that pay from
Blast's protocol portion of the trade fee in both assets, for partners the
launchpad accepts; the creator's share and the sell burn are untouched. The
opening round's permissionless settlement pays no partner.

**Tiers** are set off chain from the Blast fee kept on each partner's attributed
flow. No on-chain volume counter exists.

## Alternatives considered

**An on-chain add-on fee, Hyperliquid style.** Rejected: the user signs the whole
transaction, a contract cap cannot bound a frontend's own coin split, and the
code path is where Aftermath lost funds. Partners add their fee in their own
transaction; Blast takes no cut of it.

**Every mint and redeem naming a partner, with a zero-share house partner for
direct flow.** Rejected by the owner: most flow has no partner, and it would pay
for an extra shared input and the settlement step on every trade. It also needed
a house object at launch.

**Cashback set by the partner.** Dropped by the owner; a partner rebates its
users itself.

**One cap per partner.** A company with several deals would juggle several caps;
one cap per company with a timelocked cap ID per partner keeps each deal's share
separate.

**An owner address instead of a cap.** Both are equally exposed to a stolen key;
the cap lets the partner move custody without Blast, and the timelocked cap ID
lets Blast replace a lost one.

**The timelock inside the partner package.** It is a general primitive with no
Blast authority in it; as its own immutable MIT package any team can reuse it.

**The partner type inside the Boosts adapter or core.** The launchpad could not
use it without depending on a peer product, and the core is immutable.

**Upgradeable packages.** An upgrade could shorten the delay. Changing the ABI
means publishing new packages and registering partners again.

**The partner recording its product.** A product type set at registration and
checked by `pay` needs no list, but gives products no control of their own, writes
product type names into an immutable package, and is set by the same partner
administrator. A per-vault list has the wrong grain: deals are per product.

**A pending value with an apply step or a keeper, a cancel function, accrual with
claims, binding codes to a gas sponsor.** Each adds state or a call without a
property the lazy read, a reschedule, the push payment or a public code does not
already give; binding would also shut out wallet partners, the largest builders
on Hyperliquid.

## Consequences

- Blast cannot stop a stolen cap in under seven days: the thief's recipient
  changes are instant and `schedule_cap` waits. Exposure is each bound partner's
  share of Blast's fee for seven days; integrators can stop naming the partner
  meanwhile. Partners should hold their cap in a multisig.
- A new partner earns from registration, on each product that accepts it. A
  rogue partner administrator's new deal pays nothing until a product's risk
  administrator accepts it, so both domains must agree before a deal pays.
- The delay protects partners from targeted cuts only: Blast still sets each
  vault's admin share at once, and partners earn nothing while it is zero, its
  value at activation.
- A recipient the collateral's deny list blocks is expected to make partner
  trades abort, since Sui checks deny lists for address-balance deposits; the
  release rehearsal confirms it. The partner fixes it instantly with its cap, or
  integrators call the plain entry points.
- Codes are public: anyone can name any partner a product accepts. The partner earns on that flow;
  Blast bounds its exposure per partner with the share and prices tiers on
  retained fee, which free-riding lowers. Self-referral never pays: every trade
  still pays the reserve fee and at least a fifth of Blast's fee, plus venue
  costs.
- The adapter ABI gains the two partner entry points, `add_partner`,
  `remove_partner` and three events; `mint`, `redeem`, `Minted` and `Redeemed`
  are unchanged. The SDK, the indexer reducers and the release PTB builder add
  them, and the SDK reads a partner's `PartnerKey` field to fall back to the
  plain entry points once a removal takes effect.
- The partner administrator sets each deal's terms in its own domain; the Boosts
  risk administrator decides which deals Boosts accepts.
- The Boosts removal notice is as strong as the adapter's governed upgrades, not
  immutable like the share and cap delays: the adapter is upgradeable.
- Removed partners stay as inert dynamic fields under `Protocol`; only the risk
  administrator adds them, and nothing iterates them.
- `blast_partners` pins the timelock to the util-contracts commit that records
  its mainnet publication (`util@63b6cf8`), so mainnet builds link to the
  immutable package through its `Published.toml`.

## Verification

- Timelock tests (util contracts): the delay boundaries, reschedule, cancel,
  schedules after a switch, the shortest delay, the refused one, and 100%
  coverage.
- Partner tests: every guard with exact aborts and guard precedence; a
  registered share and cap in force at once; a scheduled share and a moved cap at
  their boundaries; one cap managing
  two partners with different shares; a cap anyone mints controls nothing; `pay`
  against a rounded-down reference sweep, at the largest fee, and its
  `PartnerPaid` event, which a zero payment does not emit.
- Accepted partners: added at once and a removal at its boundary; a pending
  removal cancelled; a removed partner added again; refusals for adding twice,
  removing twice, and removing an unknown or removed partner; the risk role and
  the version guard, in that order; the events.
- Adapter tests: a partner is paid only out of the admin fee its operation
  retained, derived from the admin cash before it, leaving earlier admin cash,
  the reserve and the supply alone; the 80% maximum leaves Blast a fifth; a share
  switching one millisecond after the operation pays nothing but is still
  attributed, and one switching at it pays in full; `PartnerFeePaid` and
  `PartnerPaid` agree; the event reducer replays `PartnerFeePaid` after `Minted`
  and `Redeemed` and matches the vault's admin cash.
- Gates: the util coverage script, `sui/partners/scripts/verify.sh`, the adapter's
  `verify.sh local` and boundary gate, the composition tests, the style check.
- Still to run before release: Move tests cannot observe address balances, so a
  live rehearsal of a partnered mint and redeem that reads the recipient's balance,
  and a deny-listed recipient, is a release gate that has not been run. The
  partner entry points cannot run locally against the Aftermath stubs, so the
  rehearsal also covers `mint_with_partner` and `redeem_with_partner` end to end,
  including a partner Boosts does not accept aborting before any venue effect.
