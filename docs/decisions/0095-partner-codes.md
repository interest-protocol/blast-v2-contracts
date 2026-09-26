# 0095: Partner codes in one immutable package

- Status: proposed
- Date: 2026-09-26

## Sources

| Ref | Full commit | Repository |
| --- | --- | --- |
| `sui@06734f6` | `06734f6ff0af45d8632a14a4dc4b100197f6b1a2` | MystenLabs/sui (the pinned framework) |
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
the launchpad later. The owner then required a forced timelock on Blast's powers
over partners: every share Blast sets and every cap Blast reissues takes effect
seven days later, and nobody can shorten that.

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

**One package.** `blast_partners` is a leaf package that depends only on
`blast_admin`. Boosts and the launchpad are independently deployed peers, and the
Boosts core is immutable, so no existing package can hold a type both products
read. It is published and made immutable in one transaction
(`sui/partners/scripts/publish_immutable.sh`): the timelock is only as credible
as the package that enforces it. It has its own `blast_admin` domain,
`BLAST_PARTNERS`, with one role, the partner administrator. One role covers
registering, scheduling shares and reissuing caps: all three wait the delay and
the root can revoke the role within it, so splitting them per action
([0094](0094-one-role-per-administrator-action.md)) would protect nothing more.

**The partner.** `Partner` is a shared object with a `recipient` address, a
`share_bps` of Blast's fee (at most 8,000), and the ID of the one live
`PartnerCap`. `PartnerCap` is `key, store`, so a partner can keep it in a
multisig or move it without asking Blast. Only the live cap may change the
recipient, which applies at once.

**The forced delay.** The share and the live cap ID are each a `Delayed` value:
`before` until `at_ms`, `after` from then on. Blast's three powers schedule it
`DELAY_MS` (seven days, a constant) ahead:

- `register` returns the new cap; the share starts at zero and switches to the
  registered share seven days later. The cap is live at once.
- `schedule_share` sets the share seven days ahead. A new schedule replaces a
  pending one and restarts the delay; scheduling the share in force cancels a
  pending change. Nothing Blast schedules takes effect sooner than seven days
  after it was last scheduled.
- `reissue_cap` mints a new cap now that becomes the live one seven days later.
  Until then the old cap keeps working; a newer reissue supersedes a pending
  one, whose cap never goes live. A pending reissue cannot be cancelled back to
  the original cap: a mistaken one is corrected only by another reissue, whose
  cap Blast then delivers to the partner. Anyone may destroy a cap.

Reads are lazy: a trade reads the value in force at the Clock it already takes,
so no keeper applies anything and the object is never written on the hot path.

**Payment.** `pay(partner, fee, clock)` takes a product's own fee on one trade,
sends the partner `floor(fee × share / 10_000)` with `balance::send_funds`
(`sui@06734f6:crates/sui-framework/packages/sui-framework/sources/balance.move:102`),
the address-balance accumulator that needs no object input, leaves the rest in
`fee`, and returns the amount. DeepBook Predict pays builder codes the same way
(`deepbook@a60c1ee:packages/predict/sources/expiry_market.move:1623`). A zero
share sends nothing. `pay` emits nothing: the product that made the trade records
the partner and the amount in its own trade event, so a payment can only be
attributed by that product. `PartnerUpdated` carries a partner's complete terms,
both delayed values included, after registration and after every change.

**Boosts.** `operations::mint` and `operations::redeem` take `&Partner` after the
`Protocol`. Blast registers a zero-share house partner for its own and
unaffiliated flow, so there is no optional argument. Completion hands Blast's
admin fee to `pay` and keeps the rest as admin cash; the reserve fee, the shares
minted and the redemption net are the core's values, identical for every
partner. `Minted` and `Redeemed` carry `partner_id` and `partner_fee`;
`admin_fee` stays Blast's whole admin share and `admin_cash_after` what Blast
kept. The adapter never calls `send_funds` itself (source gate).

**The launchpad, later.** `buy` and `sell` take the partner and the Clock, and pay
it from Blast's protocol portion of the trade fee in both assets; the creator's
share and the sell burn are untouched. The opening round's permissionless
settlement pays no partner.

**Tiers** are set off chain from the Blast fee kept on each partner's attributed
flow. No on-chain volume counter exists.

## Alternatives considered

**An on-chain add-on fee, Hyperliquid style.** Rejected: the user signs the whole
transaction, a contract cap cannot bound a frontend's own coin split, and the
code path is where Aftermath lost funds. Partners add their fee in their own
transaction; Blast takes no cut of it.

**Cashback set by the partner.** Dropped by the owner; a partner rebates its
users itself.

**An owner address instead of a cap.** Both are equally exposed to a stolen key;
the cap lets the partner move custody without Blast, and the stored live-cap ID
lets Blast replace a lost one.

**The partner type inside the Boosts adapter or core.** The launchpad could not
use it without depending on a peer product, and the core is immutable.

**An upgradeable package.** An upgrade could shorten the delay. Changing the ABI
means publishing a new package and registering partners again.

**A pending value with an apply step or a keeper, a cancel function, per-product
shares, accrual with claims, binding codes to a gas sponsor.** Each adds state
or a call without a property the lazy `Delayed` read, a reschedule, a second
`Partner`, the push payment or a public code does not already give; binding would
also shut out wallet partners, the largest builders on Hyperliquid.

## Consequences

- Blast cannot stop a stolen cap in under seven days: the thief's recipient
  change is instant and the reissue waits. Exposure is the partner's share of
  Blast's fee on that code for seven days; integrators can name the house partner
  meanwhile. Partners should hold their cap in a multisig.
- A new partner earns nothing for its first seven days, by design.
- The delay protects partners from targeted cuts only: Blast still sets each
  vault's admin share at once, and partners earn nothing while it is zero, its
  value at activation.
- A recipient the collateral's deny list blocks is expected to make trades naming
  that partner abort, since Sui checks deny lists for address-balance deposits;
  the release rehearsal confirms it. The partner fixes it instantly with its cap,
  or integrators name the house partner. If the deposit landed instead, the funds
  would sit where the recipient cannot withdraw them, which touches no Blast
  invariant.
- Codes are public: anyone can name any partner. The partner earns on that flow;
  Blast bounds its exposure per code with the share and prices tiers on retained
  fee, which free-riding lowers. Self-referral never pays: every trade still pays
  the reserve fee and at least a fifth of Blast's fee, plus venue costs.
- The adapter ABI changes (`mint`, `redeem`, `Minted`, `Redeemed`); Boosts will be
  redeployed fresh. The SDK, the indexer reducers and the release PTB builder pass
  and decode the partner.
- The partner administrator is its own role in its own domain; the Boosts risk
  administrator no longer touches partners.

## Verification

- Package tests: every guard with exact aborts and guard precedence (role before
  input; zero recipient before an oversized share; live cap before input); the
  delay boundaries (one millisecond before reads the old value, the boundary reads
  the new one) for the first share, a scheduled share and a reissued cap; a
  reschedule restarts the delay; scheduling the share in force cancels; a
  superseded reissue never goes live; the old cap is refused after the switch and
  the new one before it; the zero-share house and the maximum share register;
  `pay` against a rounded-down reference sweep and at the largest fee.
- Adapter tests: the same mint through the house and through a paying partner
  leaves every holder-facing `Minted` amount identical and lowers only Blast's
  admin cash by the partner's fee, at 50% and at the 80% maximum; a redemption pays
  the partner from the admin fee and returns exactly the net; the event reducers
  subtract the partner fee from admin cash.
- Gates: `sui/partners/scripts/verify.sh`, the adapter's `verify.sh local` and
  boundary gate, the composition tests, and the style check.
- Still to run before release: Move tests cannot observe address balances, so a
  live rehearsal of a partnered mint and redeem that reads the recipient's balance,
  and a deny-listed recipient, is a release gate that has not been run.
