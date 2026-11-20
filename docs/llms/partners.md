## Partner codes

### What it is

A partner code lets an app that brings flow to Blast earn a share of the fee
Blast charges on that flow. Package `blast_partners` holds the codes for every
Blast product: Boosts, the launchpad (with its post-migration LP vaults), and
presales. A partner is one deal: a shared `Partner` object with a share of
Blast's fee (0% to 80%) and a recipient address. A company holds one
`PartnerCap` that controls the recipient of every deal registered under it.
Users never pay for a partner: a partner is only ever paid out of Blast's own
fee. Initial shares apply immediately. A later share or managing cap Blast
proposes applies only when someone applies it, at least seven days after the
proposal. The module never changes that notice. Canonical immutability is
deferred until final audit; a native compatible UpgradeCap remains at the
multisig without an enforced upgrade notice.

### Objects and authority

| Object | Kind | Held by | Authorizes |
| --- | --- | --- | --- |
| `blast_partners::blast_partners::Partner` | shared (`key` only, never transferable) | nobody; created by `blast_partners::blast_partners::register` | read by products on every trade; mutated only by the calls below |
| `blast_partners::blast_partners::PartnerCap` | owned (`key, store`; transferable, wrappable) | the partner company | `blast_partners::blast_partners::set_recipient` on every `Partner` whose applied cap is this cap's ID |
| `blast_partners::blast_partners::PartnerAdmin` | role type in Blast's ACL | a Blast `AdminCap` granted this role | `blast_partners::blast_partners::register`, `blast_partners::blast_partners::schedule_share`, `blast_partners::blast_partners::schedule_cap`, `blast_partners::blast_partners::cancel_share`, `blast_partners::blast_partners::cancel_cap` |

`Partner` fields:

- `recipient: address`: where payments go. Set by the live cap's holder, applies
  at once.
- `share_bps`: the share of Blast's fee, in basis points (BPS, out of 10,000),
  at most 8,000. A `delayed::Delayed<ShareKey, u64>` value.
- `cap_id`: the ID of the one `PartnerCap` that may set `recipient`. A
  `delayed::Delayed<CapKey, ID>` value.

A `delayed::Delayed<K, T>` comes from Blast's shared administration package
`blast_admin` and has five fields in BCS order: `parent` (the `Partner`'s ID),
`key` (`blast_partners::blast_partners::ShareKey` or
`blast_partners::blast_partners::CapKey`, each a one-byte unit struct), `value`
(the applied value), `delay_ms` (the notice), and `pending: Option<Proposal<T>>`.
A `delayed::Proposal<T>` holds `value`, `delay_ms` and `ready_at_ms`. The applied
value is always `value`; a proposal changes nothing until it is applied, even after
`ready_at_ms`. Both notices are 604,800,000 ms (seven days) and stay fixed:
`blast_partners` exposes no call that changes them.

Who may call: *anyone* may call `new_cap`, `destroy_cap` (on a cap they hold),
`pay`, `apply_share`, `apply_cap`, `delay_ms`, `max_share_bps`, and the readers
under Reading state; the *cap holder* (the applied
`PartnerCap`) may call `set_recipient`; a *Blast admin* with the `PartnerAdmin`
role (through `blast_acl::sign_in`) may call `register`, `schedule_share`,
`schedule_cap`, `cancel_share`, and `cancel_cap`.
Each product keeps its own list of the partners it accepts, managed by that
product's admin.

### Lifecycle

**Cap.** `blast_partners::blast_partners::new_cap` mints an inert cap: it
controls nothing until Blast registers a partner under its ID. It is *live* for
a partner while it is that partner's applied cap. After
`blast_partners::blast_partners::schedule_cap` proposes a different cap and seven
days pass, anyone may call `blast_partners::blast_partners::apply_cap`; only then
does the old cap stop working for that partner.
`blast_partners::blast_partners::destroy_cap` deletes a cap, live or not;
destroying a live cap leaves its partners with no working cap until a cap Blast
proposes with `blast_partners::blast_partners::schedule_cap` is applied, at
least seven days later.

**Partner.** `blast_partners::blast_partners::register` creates and shares the
partner with the agreed share and managing cap in force immediately. Registration
needs no `Clock`; there is no initial waiting period. From then on:

1. Blast proposes a new share or cap; the applied value stays in force.
2. A different proposal replaces the pending one and restarts the full seven
   days, even when the old proposal was already ready. Proposing the applied
   value, or the value already pending, aborts.
3. Blast may discard a proposal with `blast_partners::blast_partners::cancel_share`
   or `blast_partners::blast_partners::cancel_cap`, even after it is ready.
4. From `ready_at_ms`, anyone may call `blast_partners::blast_partners::apply_share`
   or `blast_partners::blast_partners::apply_cap`, the partner included. Nothing
   changes merely because time passes. `blast_partners::blast_partners::is_share_ready`
   and `blast_partners::blast_partners::is_cap_ready` say whether that call would
   succeed now.

There is no delete: a partner exists forever, because launches, presales, and
vaults bind its ID for good and pay Blast's held fees only with it. To switch it
off, Blast proposes and then applies a zero share; products that name it keep
working and simply pay it nothing.

**Product acceptance.** Each product accepts a partner in its own shared config,
mapping the partner's ID to the time it stops being accepted (`u64::MAX` until
removed) in the `acceptance_ends_at_ms` table of a `blast_partners::partner_list::PartnerList`:

| Product | Config object and key | Admin |
| --- | --- | --- |
| Boosts | `blast_boosts_aftermath::blast_boosts_aftermath::Protocol`, its embedded `PartnerList` | core `FeeAdmin` role (`operations::add_partner`, `operations::remove_partner`) |
| Launchpad | `launch_config::LaunchConfig`, its embedded `PartnerList` | core `FeeAdmin` role |
| Presale | `creation_policy::CreationPolicy`, its `partners` `blast_partners::partner_list::PartnerList` | core `FeeAdmin` role (`creation_policy::add_partner`, `creation_policy::remove_partner`) |

Adding applies at once (and cancels a pending removal). Removing sets the value
to `now` plus `blast_partners::blast_partners::delay_ms()`: the partner stays
accepted for seven more days. A partner is accepted while the field exists and
`now < value`.

**Shared acceptance list.** `blast_partners::partner_list::PartnerList` is the
same acceptance rule as one embeddable value, for a product to keep inside its
own config. The launchpad embeds one in `launch_config::LaunchConfig` (its
`partners` field), changed by the `FeeAdmin` role through
`launch_config::add_partner` and `launch_config::remove_partner`. It maps each partner's ID to the time, in Unix epoch milliseconds,
it stops being accepted (`u64::MAX` until removed), held in a `Table`, and
records the `parent` object that embeds it. It has no authority of its own: only
the embedding module can reach it mutably, so that product decides who may
change it.

- `blast_partners::partner_list::new` creates an empty list for a parent.
- `blast_partners::partner_list::add` accepts a `Partner` at once, cancelling a
  pending removal or accepting a removed partner again; it aborts when the
  partner is already accepted with no removal pending.
- `blast_partners::partner_list::remove` keeps a partner accepted until `now`
  plus `delay_ms()`; it aborts unless the partner is accepted now with no
  removal pending.
- `blast_partners::partner_list::assert_accepted` aborts unless the list
  accepts the partner now; `blast_partners::partner_list::is_accepted` returns
  the same answer as a `bool`.
- `blast_partners::partner_list::contains` says whether the list has an entry
  for a partner (accepted, removal pending, or removed);
  `blast_partners::partner_list::acceptance_ends_at_ms` returns that entry's end
  time and aborts in `sui::dynamic_field` without one;
  `blast_partners::partner_list::length` counts entries, removed ones included;
  `blast_partners::partner_list::parent` returns the embedding object's ID.
- `blast_partners::partner_list::destroy` deletes the list with every entry and
  emits `PartnerListDestroyed`. It ends every acceptance at once, without the
  notice, so a product destroys it only with the object that embeds it.

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
   event and the transaction's created objects. Its initial share is active immediately.
   Registration also emits `delayed::DelayedCreated` for the share and for the cap.
4. Blast's admin for each product adds the partner to that product's list.

`blast_partners::blast_partners::register` accepts any ID as the cap. Confirm on
chain that the `Partner`'s applied `cap_id.value` equals your cap's ID; a wrong
ID can only be fixed by proposing a new cap and applying it seven days later.

#### Change where a partner pays you (cap holder)

1. Call `blast_partners::blast_partners::set_recipient` with the shared
   `Partner` (mutable), your owned `PartnerCap` (by reference), and the new
   address. It takes no `Clock`.
2. It applies at once and emits `PartnerUpdated`. One call per partner.

#### Change a share or replace a lost cap (Blast admin)

1. `blast_acl::sign_in` with `blast_partners::blast_partners::PartnerAdmin`.
2. `blast_partners::blast_partners::schedule_share` (new share) or
   `blast_partners::blast_partners::schedule_cap` (new cap ID), with the shared
   `Partner`, the witness, the value, and `Clock`.
3. Each emits `delayed::DelayedScheduled` (after `delayed::DelayedCancelled`
   when it replaces a pending proposal) with `ready_at_ms`, seven days later.
4. From `ready_at_ms`, *anyone* calls `blast_partners::blast_partners::apply_share`
   or `blast_partners::blast_partners::apply_cap` with the shared `Partner`
   (mutable) and `Clock` at `0x6`; each emits `delayed::DelayedApplied`. Until a
   cap change is applied, the old cap keeps working, including for a thief
   holding it.
5. Instead, Blast may sign in and call `blast_partners::blast_partners::cancel_share`
   or `blast_partners::blast_partners::cancel_cap` (no `Clock`), even after
   readiness; each emits `delayed::DelayedCancelled`.

#### Pay a partner (products, or anyone)

`blast_partners::blast_partners::pay<T>` takes the shared `Partner` by immutable
reference, a `&mut Balance<T>` holding Blast's fee on a trade, and the
transaction context; it takes no `Clock`. It splits off `floor(fee * applied_share / 10,000)`, sends it to the partner's
`recipient`, emits `PartnerPaid<T>`, and returns the amount. The rest stays in
the caller's balance. With a zero share (or a fee too small to round above zero)
it sends nothing, emits nothing, and returns 0. Each positive payment creates
a `Coin<T>` and transfers it to the recipient with `public_transfer`. Integrators
never call `pay` directly; products call it inside their own partnered functions.

### How each product uses a partner

| Product | When the partner is named | Blast fee divided | Payment |
| --- | --- | --- | --- |
| Boosts | on each trade: `operations::mint_with_partner` or `operations::redeem_with_partner`, passing the `Partner` immediately before the Aftermath account | Blast's admin fee that trade retained; never the reserve fee | push: paid in the same call |
| Launchpad | once, at creation: `launch::set_partner` on the `LaunchInitializer` before `launch::finalize`; fixed for good | Blast's whole fee ledger on the launch: the creation fee (SUI), Blast's share of every curve trade fee (Meme and Quote), and Blast's one-time migration fee | held in the launch; paid when anyone calls `launch::claim_protocol_fees_with_partner` |
| LP vault (launchpad and presale) | inherited from the launch or sale at migration, in its vault terms | Blast's LP fees on each collection, and protocol migration residuals | held in the vault; paid when anyone calls `blast_vault::vault::pay_protocol_fees_with_partner` |
| Presale | once, at creation: `blast_presale::blast_presale::set_partner` on the `PresaleInitializer` before `blast_presale::blast_presale::finalize`; fixed for good | Blast's raise fee (Quote) only; Blast's token fee is never divided | held at migration; paid when anyone calls `blast_presale::blast_presale::pay_protocol_fees_with_partner` (once) |

Rules common to every product:

- Naming a partner requires that the product accepts it at that moment;
  otherwise the call aborts. Launches and sales that already name a removed
  partner keep paying it.
- The claim and payment calls are *anyone*: both payees are fixed, so no caller
  chooses where money goes. Each checks that the `Partner` passed is the one the
  launch, sale, or vault named, and aborts otherwise.
- A launch that names a partner cannot use `launch::claim_protocol_fees`; it
  must use `launch::claim_protocol_fees_with_partner`.
- Held fees are divided at the share **applied when they are paid**, not when
  they accrued.
- The `Partner` is read by immutable reference, so naming a busy partner adds no
  contention of its own.

### Economics

- Partner amount per payment: `floor(fee * share_bps / 10,000)` in atomic units
  of `T`, where `share_bps` is the applied share when the payment executes.
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
  days). It is a compile-time constant; current upgrade authority is recorded in the deployment record.
- The initial share and managing cap apply at registration, without a Clock.
- A proposed share or cap can be applied by the first transaction whose `Clock`
  reads `ready_at_ms` or later; it takes effect only when `apply_share` or
  `apply_cap` succeeds. A replacement restarts the full seven days.
- A recipient change applies in the same transaction.
- A product removal keeps the partner accepted until `now + delay_ms()`; a trade
  or creation at or after that time aborts.

### Reading state

Move callers read a partner with `blast_partners::blast_partners::recipient`,
`blast_partners::blast_partners::share_bps` (applied),
`blast_partners::blast_partners::pending_share_bps`,
`blast_partners::blast_partners::cap_id` (applied), and
`blast_partners::blast_partners::pending_cap_id`; each pending reader returns an
`Option<delayed::Proposal<T>>`. `blast_partners::blast_partners::is_share_ready`
and `blast_partners::blast_partners::is_cap_ready` take the `Clock` and return
whether `apply_share` or `apply_cap` would succeed now: a proposal is pending,
the clock reads its `ready_at_ms` or later, and the clock plus the seven-day
notice still fits in a `u64`. They return false with nothing proposed, before
`ready_at_ms`, and after a cancel or an apply. The share readers keep the field's name,
`share_bps`, the repository's term for a partner's share in basis points.
`blast_partners::blast_partners::max_share_bps` returns the 8,000 BPS ceiling
`register` and `schedule_share` enforce. Off chain, read the shared `Partner`
object's content over RPC, or replay the events below.

- Applied share: `share_bps.value`.
- Pending share: `share_bps.pending`, with its `value` and `ready_at_ms`;
  readiness does not clear it.
- Which cap controls the recipient: `cap_id.value`; its proposal is
  `cap_id.pending`.
- Whether a product's `PartnerList` accepts a partner now:
  `blast_partners::partner_list::is_accepted`.
- Whether a product accepts a partner: read the entry for `partner_id` in the product config’s
  embedded `PartnerList` table. Acceptance lasts while the entry exists and `now < value`.
- Which partner a launch, sale, or vault names: its `partner_id: Option<ID>`
  field; a vault's comes from its terms, recorded in
  `blast_vault::blast_vault_events::VaultCreated`.

### Events

Every event is emitted directly (no envelope).

- `blast_partners::blast_partners::PartnerUpdated`: emitted by
  `blast_partners::blast_partners::register` and
  `blast_partners::blast_partners::set_recipient`. Fields: `partner_id`,
  `recipient`. The latest one per `partner_id` gives the recipient.
- Share and cap lifecycle events come from `blast_admin`'s `delayed` module,
  generic in the key (`ShareKey` for the share, `CapKey` for the cap) and the
  value type (`u64` or `ID`), with `parent` set to the `Partner`'s ID:
  `delayed::DelayedCreated` (registration: initial value and notice),
  `delayed::DelayedScheduled` (proposal: value, notice, `ready_at_ms`),
  `delayed::DelayedCancelled` (a cancel, or a proposal a new one replaced) and
  `delayed::DelayedApplied` (previous and new value, notice). Replaying them per
  `parent` and key reconstructs the applied and pending terms; `blast_partners`
  emits no event of its own for them.
- `blast_partners::partner_list::PartnerAdded`: emitted by
  `blast_partners::partner_list::add`. Fields: `parent` (the object embedding
  the list), `partner_id`.
- `blast_partners::partner_list::PartnerRemoved`: emitted by
  `blast_partners::partner_list::remove`. Fields: `parent`, `partner_id`,
  `acceptance_ends_at_ms` (exclusive). Replaying both per `parent` gives that
  list's accepted partners.
- `blast_partners::partner_list::PartnerListDestroyed`: emitted by
  `blast_partners::partner_list::destroy`. Field: `parent`. From then on the
  parent's list accepts no partner.
- `blast_partners::blast_partners::PartnerPaid<T>`: emitted by
  `blast_partners::blast_partners::pay` when it sends a positive amount. Fields:
  `partner_id`, `amount` (atomic units of `T`). The product records the trade in
  its own event in the same transaction:
  `blast_boosts_aftermath::events::PartnerFeePaid` (Boosts),
  `blast_core::blast_core_events::ProtocolFeesPaid` (launch claims, LP vaults and presale fees).
  `blast_fun::events::LaunchCreated` and
  `blast_presale::events::PresaleOpened` record the partner a launch or
  sale names.

### Aborts

| Code | Constant | Raised by | Fix |
| --- | --- | --- | --- |
| 0 | `EInvalidRecipient` | `register`, `set_recipient` | use a non-zero recipient |
| 1 | `EShareAboveMax` | `register`, `schedule_share` | share at most 8,000 BPS |
| 2 | `EUnchanged` | `schedule_share`, `schedule_cap` (value equals the pending proposal), `set_recipient` (same recipient) | pass a different value; to restart a pending proposal with the same value, cancel it first |
| 3 | `ENotLiveCap` | `set_recipient` | use the partner's applied cap; a ready but unapplied cap is refused until `apply_cap` |
| 4 | `EPartnerNotAccepted` | `partner_list::assert_accepted`, `partner_list::remove` | name a partner the list accepts now |

The codes come from the package registry `blast_partners::errors`. Codes 0 to 3
are raised in module `blast_partners`; `partner_list::add` and
`partner_list::remove` also raise `EUnchanged` (adding an accepted partner, or
removing one whose removal is pending), and code 4 is raised in module
`partner_list`. The share and cap calls also
abort in module `blast_admin::delayed` with `blast_admin`'s error codes:
`ENotReady` (13, `apply_share` or `apply_cap` before `ready_at_ms`),
`ENoPending` (14, apply or cancel with nothing proposed), `EInvalidDelay` (15, a
`ready_at_ms` that would overflow) and `EUnchanged` (16, proposing the applied
value). A product call that names a
partner it does not accept, or passes the wrong `Partner` to a claim, aborts in
that product's module with that product's own error.

### Pitfalls

- `PartnerPaid` alone does not prove a Blast trade:
  `blast_partners::blast_partners::pay` is public, and anyone can pay a partner
  from their own balance. Pair it with the product event in the same
  transaction.
- Each positive payment arrives as an owned `Coin<T>` at the recipient address.
  Repeated payouts produce separate coins that the recipient can merge.
- On Boosts, check acceptance before building a partnered trade; otherwise call
  the plain `mint` or `redeem`.
- On the launchpad and presales the partner is fixed at creation. Forgetting
  `launch::set_partner` or `blast_presale::blast_presale::set_partner` cannot be
  fixed later.
- Held fees are divided at the share applied at payment time. An applied cut
  to zero also cuts fees accrued earlier but paid later.
- A ready proposal is not in force. Payments keep the old share and the old cap
  keeps working until someone calls `apply_share` or `apply_cap`; a partner
  waiting on a raise can apply it itself.
- Whoever holds the cap controls the recipient of every deal under it. A stolen
  cap can redirect payments until a `schedule_cap` replacement is applied.

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
waits seven days, visible on chain the moment it is proposed, and only then can
anyone apply it. The notice is fixed in the published code.

**Can I change my recipient myself?** Yes, with your `PartnerCap` through
`blast_partners::blast_partners::set_recipient`; it applies at once.

**I lost my cap. What now?** Mint a new cap with
`blast_partners::blast_partners::new_cap` and ask Blast to call
`blast_partners::blast_partners::schedule_cap` for each of your partners. After
seven days anyone, you included, calls `blast_partners::blast_partners::apply_cap`;
until then the old cap still works.

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
