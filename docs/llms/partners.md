## Partner codes

### What it is

A partner code lets an app that brings flow to Blast earn a share of the fee
Blast charges on that flow. Package `blast_partners` holds the codes for every
Blast product: Boosts, the launchpad (with its post-migration LP vaults), and
presales. A partner is one deal: a shared `Partner` object with a share of
Blast's fee (0% to 80%) and a recipient address. A company holds one
`PartnerCap` that controls the recipient of every deal registered under it.
Users never pay for a partner: a partner is only ever paid out of Blast's own
fee. Every change Blast makes to a partner's share or managing cap waits seven
days, and the package is published immutable, so no one can shorten that delay.

### Objects and authority

| Object | Kind | Held by | Authorizes |
| --- | --- | --- | --- |
| `blast_partners::blast_partners::Partner` | shared (`key` only, never transferable) | nobody; created by `blast_partners::blast_partners::register` | read by products on every trade; mutated only by the calls below |
| `blast_partners::blast_partners::PartnerCap` | owned (`key, store`; transferable, wrappable) | the partner company | `blast_partners::blast_partners::set_recipient` on every `Partner` whose cap in force is this cap's ID |
| `blast_partners::blast_partners::PartnerAdmin` | role type in Blast's ACL | a Blast `AdminCap` granted this role | `blast_partners::blast_partners::register`, `blast_partners::blast_partners::schedule_share`, `blast_partners::blast_partners::schedule_cap` |

`Partner` fields:

- `recipient: address`: where payments go. Set by the live cap's holder, applies
  at once.
- `share_bps`: the share of Blast's fee, in basis points (BPS, out of 10,000),
  at most 8,000. A timelocked value.
- `cap_id`: the ID of the one `PartnerCap` that may set `recipient`. A
  timelocked value.

A timelocked value is a `Timelocked<T>` struct from Blast's immutable timelock
package with four fields: `before`, `after`, `at_ms`, `delay_ms`. The value in
force at time `t` (milliseconds) is `after` when `t >= at_ms`, otherwise
`before`. `delay_ms` is fixed at creation; for partners it is 604,800,000 ms
(seven days). Scheduling a value `v` at time `now` sets `before` to the value in
force at `now`, `after` to `v`, and `at_ms` to `now + delay_ms`. A change is
pending exactly when `at_ms > now` and `after` differs from the value in force.

Who may call: *anyone* may call `new_cap`, `destroy_cap` (on a cap they hold),
`pay`, and `delay_ms`; the *cap holder* (the `PartnerCap` in force) may call
`set_recipient`; a *Blast admin* with the `PartnerAdmin` role (through
`blast_acl::sign_in`) may call `register`, `schedule_share`, and `schedule_cap`.
Each product keeps its own list of the partners it accepts, managed by that
product's admin.

### Lifecycle

**Cap.** `blast_partners::blast_partners::new_cap` mints an inert cap: it
controls nothing until Blast registers a partner under its ID. It is *live* for
a partner while it is that partner's cap in force. After
`blast_partners::blast_partners::schedule_cap` names a different cap and seven
days pass, the old cap stops working for that partner.
`blast_partners::blast_partners::destroy_cap` deletes a cap, live or not;
destroying a live cap leaves its partners with no working cap until a cap Blast
schedules with `blast_partners::schedule_cap` takes effect, seven days later.

**Partner.** `blast_partners::blast_partners::register` creates and shares the
partner with its share and cap in force immediately (`before == after`,
`at_ms == 0`). From then on:

1. Blast schedules a new share or cap; the old value stays in force for seven
   days.
2. Scheduling again before then replaces the pending change and restarts the
   seven days.
3. Scheduling the value currently in force cancels a pending change.
4. At `at_ms` the new value is in force; nothing needs to be called.

There is no delete: a partner exists forever. To switch it off, Blast schedules
its share to zero; products that name it keep working and simply pay it nothing.

**Product acceptance.** Each product accepts a partner in its own shared config,
as a dynamic field keyed by `PartnerKey(partner_id)` whose `u64` value is the
time the partner stops being accepted (`u64::MAX` until removed):

| Product | Config object and key | Admin |
| --- | --- | --- |
| Boosts | `blast_boosts_aftermath::blast_boosts_aftermath::Protocol`, `blast_boosts_aftermath::blast_boosts_aftermath::PartnerKey` | `RiskAdmin` role (`operations::add_partner`, `operations::remove_partner`) |
| Launchpad | `launch_config::LaunchConfig`, `launch_config::PartnerKey` | `FeeAdmin` role (`launch_config::add_partner`, `launch_config::remove_partner`) |
| Presale | `creation_policy::CreationPolicy`, `creation_policy::PartnerKey` | presale `FeeAdmin` role (`creation_policy::add_partner`, `creation_policy::remove_partner`) |

Adding applies at once (and cancels a pending removal). Removing sets the value
to `now` plus `blast_partners::blast_partners::delay_ms()`: the partner stays
accepted for seven more days. A partner is accepted while the field exists and
`now < value`.

### Flows

#### Become a partner (company)

1. Call `blast_partners::blast_partners::new_cap` (*anyone*). It returns a
   `PartnerCap`; send it with a TransferObjects command to the address that will
   manage your deals (for example your multisig).
2. Give Blast the cap's object ID, the recipient address, and the agreed share.
3. Blast's partner admin, in one PTB: `blast_acl::sign_in` with type argument
   `blast_partners::blast_partners::PartnerAdmin`, passing the shared `ACL` and
   its owned `AdminCap`; then `blast_partners::blast_partners::register` with a
   reference to that `AdminWitness<PartnerAdmin>`, your cap ID, the recipient,
   and the share. The new `Partner` is shared; its ID is in the `PartnerUpdated`
   event and the transaction's created objects.
4. Blast's admin for each product adds the partner to that product's list.

`blast_partners::blast_partners::register` accepts any ID as the cap. Confirm on
chain that the `Partner`'s `cap_id` equals your cap's ID; a wrong ID can only be
fixed by `blast_partners::blast_partners::schedule_cap`, seven days later.

#### Change where a partner pays you (cap holder)

1. Call `blast_partners::blast_partners::set_recipient` with the shared
   `Partner` (mutable), your owned `PartnerCap` (by reference), the new address,
   and `Clock` at `0x6`.
2. It applies at once and emits `PartnerUpdated`. One call per partner.

#### Change a share or replace a lost cap (Blast admin)

1. `blast_acl::sign_in` with `blast_partners::blast_partners::PartnerAdmin`.
2. `blast_partners::blast_partners::schedule_share` (new share) or
   `blast_partners::blast_partners::schedule_cap` (new cap ID), with the shared
   `Partner`, the witness, the value, and `Clock`.
3. Each emits `PartnerUpdated` with the complete timelocked terms. The change
   takes effect seven days later. Until a cap change takes effect, the old cap
   keeps working, including for a thief holding it.

#### Pay a partner (products, or anyone)

`blast_partners::blast_partners::pay<T>` takes the shared `Partner` by immutable
reference, a `&mut Balance<T>` holding Blast's fee on a trade, and `Clock`. It
splits off `floor(fee * share_in_force / 10,000)`, sends it to the partner's
`recipient`, emits `PartnerPaid<T>`, and returns the amount. The rest stays in
the caller's balance. With a zero share (or a fee too small to round above zero)
it sends nothing, emits nothing, and returns 0. Payment uses Sui's
address-balance transfer (`send_funds`): the recipient's balance of `T` grows,
but no new `Coin` object is created. Integrators never call `pay` directly;
products call it inside their own partnered functions.

### How each product uses a partner

| Product | When the partner is named | Blast fee divided | Payment |
| --- | --- | --- | --- |
| Boosts | on each trade: `operations::mint_with_partner` or `operations::redeem_with_partner`, passing the `Partner` right after the `Protocol` | Blast's admin fee that trade retained; never the reserve fee | push: paid in the same call |
| Launchpad | once, at creation: `launch::set_partner` on the `LaunchInitializer` before `launch::finalize`; fixed for good | Blast's whole fee ledger on the launch: the creation fee (SUI), Blast's share of every curve trade fee (Meme and Quote), and Blast's one-time migration fee | held in the launch; paid when anyone calls `launch::claim_protocol_fees_with_partner` |
| Launchpad LP vault | inherited from the launch at migration | Blast's LP fees on each collection | held in the vault; paid when anyone calls `blast_fun_migrators::vault::claim_protocol_lp_fees_with_partner` |
| Presale | once, at creation: `blast_presale::blast_presale::set_partner` on the `PresaleInitializer` before `blast_presale::blast_presale::finalize`; fixed for good | Blast's raise fee (Quote) only; Blast's token fee is never divided | held at migration; paid when anyone calls `blast_presale::blast_presale::pay_protocol_fees_with_partner` (once) |
| Presale LP vault | inherited from the sale at migration | Blast's LP fees on each collection | held in the vault; paid when anyone calls `presale_vault::pay_protocol_lp_fees_with_partner` |

Rules common to every product:

- Naming a partner requires that the product accepts it at that moment;
  otherwise the call aborts. Launches and sales that already name a removed
  partner keep paying it.
- The claim and payment calls are *anyone*: both payees are fixed, so no caller
  chooses where money goes. Each checks that the `Partner` passed is the one the
  launch, sale, or vault named, and aborts otherwise.
- A launch that names a partner cannot use `launch::claim_protocol_fees`; it
  must use `launch::claim_protocol_fees_with_partner`.
- Held fees are divided at the share **in force when they are paid**, not when
  they accrued.
- The `Partner` is read by immutable reference, so naming a busy partner adds no
  contention of its own.

### Economics

- Partner amount per payment: `floor(fee * share_bps / 10,000)` in atomic units
  of `T`, where `share_bps` is the share in force at the payment's `Clock`.
  Blast keeps the remainder, including every rounding dust.
- `share_bps` is between 0 and 8,000 (80%). Blast always keeps at least 20% of
  its fee.
- Users, holders, creators, buyers, and pools receive exactly the same amounts
  with or without a partner.
- Example (Boosts): a mint retains a 15.00 USDC admin fee and the partner's
  share is 4,000 BPS. The partner receives 6.00 USDC; Blast keeps 9.00 USDC.
- Example (presale): Blast's raise fee is 2,000 USDC and the share is 4,000 BPS.
  The partner receives 800 USDC; Blast keeps 1,200 USDC and all of its token
  fee.

### Time rules

- Delay: `blast_partners::blast_partners::delay_ms()` returns 604,800,000 (seven
  days). It is a compile-time constant of an immutable package.
- A scheduled share or cap is in force from the first transaction whose `Clock`
  reads `at_ms` or later.
- A recipient change applies in the same transaction.
- A product removal keeps the partner accepted until `now + delay_ms()`; a trade
  or creation at or after that time aborts.

### Reading state

`blast_partners` has no getters for a partner's fields; read the shared
`Partner` object's content over RPC (`recipient`, `share_bps`, `cap_id`) and
apply the timelock rule above, or replay `PartnerUpdated`. The only on-chain
read is `blast_partners::blast_partners::delay_ms`.

- Share in force now: `share_bps.after` if `now >= share_bps.at_ms`, else
  `share_bps.before`.
- Pending share change: `share_bps.at_ms > now` and `share_bps.after` differs
  from the share in force.
- Which cap controls the recipient: the same rule on `cap_id`.
- Whether a product accepts a partner: read the product config's dynamic field
  `PartnerKey(partner_id)`; accepted while it exists and `now < value`.
- Which partner a launch, sale, or vault names: its `partner_id: Option<ID>`
  field (`launch::partner_id` returns it for a launch).

### Events

Both events are emitted directly (no envelope).

- `blast_partners::blast_partners::PartnerUpdated`: emitted by
  `blast_partners::blast_partners::register`,
  `blast_partners::blast_partners::schedule_share`,
  `blast_partners::blast_partners::schedule_cap`, and
  `blast_partners::blast_partners::set_recipient`. Fields: `partner_id`,
  `recipient`, `share_bps` and `cap_id` (complete timelocked values). Each event
  is the full current state, so the latest one per `partner_id` reconstructs the
  partner.
- `blast_partners::blast_partners::PartnerPaid<T>`: emitted by
  `blast_partners::blast_partners::pay` when it sends a positive amount. Fields:
  `partner_id`, `amount` (atomic units of `T`). The product records the trade in
  its own event in the same transaction:
  `blast_boosts_aftermath::events::PartnerFeePaid` (Boosts),
  `blast_fun::events::ProtocolFeesClaimed` (launch claims),
  `blast_fun_migrators::blast_events::ProtocolLpFeesClaimed` (launchpad LP),
  `blast_presale::blast_presale::ProtocolFeesPaid` (presale raise fee), and
  `presale_vault::ProtocolLpFeesPaid` (presale LP).
  `blast_fun::events::LaunchCreated` and
  `blast_presale::blast_presale::PresaleOpened` record the partner a launch or
  sale names.

### Aborts

| Code | Constant | Raised by | Fix |
| --- | --- | --- | --- |
| 0 | `EInvalidRecipient` | `register`, `set_recipient` | use a non-zero recipient |
| 1 | `EShareAboveMax` | `register`, `schedule_share` | share at most 8,000 BPS |
| 2 | `EUnchanged` | `schedule_share`, `schedule_cap` (value equals the latest scheduled value), `set_recipient` (same recipient) | pass a different value; to restart a pending change with the same value, first schedule the value in force |
| 3 | `ENotLiveCap` | `set_recipient` | use the cap in force for this partner at the current `Clock` |

All four are raised in module `blast_partners`. A product call that names a
partner it does not accept, or passes the wrong `Partner` to a claim, aborts in
that product's module with that product's own error.

### Pitfalls

- `PartnerPaid` alone does not prove a Blast trade:
  `blast_partners::blast_partners::pay` is public, and anyone can pay a partner
  from their own balance. Pair it with the product event in the same
  transaction.
- Payments arrive as address balance, not as new `Coin` objects; a scan of owned
  coin objects does not show them.
- On Boosts, check acceptance before building a partnered trade; otherwise call
  the plain `mint` or `redeem`.
- On the launchpad and presales the partner is fixed at creation. Forgetting
  `launch::set_partner` or `blast_presale::blast_presale::set_partner` cannot be
  fixed later.
- Held fees are divided at the share in force at payment time. A scheduled cut
  to zero also cuts fees accrued earlier but paid later.
- Whoever holds the cap controls the recipient of every deal under it. A stolen
  cap can redirect payments until a `schedule_cap` replacement takes effect.

### Q&A

**How much can a partner earn?** Up to 80% of Blast's fee on the flow that names
it, as agreed with Blast and set by `blast_partners::blast_partners::register`.
Users pay the same fee with or without a partner.

**When am I paid?** On Boosts, in the same transaction as each mint or redeem.
On the launchpad and presales, when anyone calls the product's `*_with_partner`
claim or payment call; you may call it yourself.

**In which asset am I paid?** In the asset of the fee divided: Boost collateral;
launch Meme, Quote, and SUI; presale Quote; LP fees in both pool assets.

**Can Blast change my share without notice?** No. Every share or cap change
waits seven days, visible on chain the moment it is scheduled, and the delay is
fixed in immutable code.

**Can I change my recipient myself?** Yes, with your `PartnerCap` through
`blast_partners::blast_partners::set_recipient`; it applies at once.

**I lost my cap. What now?** Mint a new cap with
`blast_partners::blast_partners::new_cap` and ask Blast to call
`blast_partners::blast_partners::schedule_cap` for each of your partners. The
new cap works seven days later; until then the old cap still works.

**Can one company have several deals?** Yes. Each deal is its own `Partner` with
its own share and recipient; one `PartnerCap` can manage all of them.

**Can another app use my partner code?** Yes. The `Partner` is a public shared
object; any app can name it on a product that accepts it, and you earn on that
flow.

**How do I reconcile income?** Sum `PartnerPaid<T>` by `partner_id` and coin
type, and join each with the product event in the same transaction for trade
detail.

**Can I charge my own users an extra fee?** Not through `blast_partners`. Take
your own fee in your own PTB commands (split it from the user's coin and send it
where you like); Blast takes no cut of it.
