# 0134: Delayed administration, pause, and a Table-backed ACL

- Status: accepted
- Amended by: [0137](0137-shared-launch-stack-core-vault-and-venues.md) (shared launch stack, 2026-11-04)
- Date: 2026-10-31
- Amended: 2026-11-02 — operation-owned notices, delayed creator splits, and bonding reward custody
- Amended: 2026-11-03 — keyed delayed primitives in four modules that own their lifecycle events, a
  `DelayedMap` for per-coin LP overrides; root transfer on `delayed_action`; delayed creator-claim
  signer admission with immediate removal
- Amended: 2026-11-03 — holder-reward rounds publish from a delayed action slot on each vault
- Amended: 2026-11-03 — pre-audit hardening: a 30-day notice ceiling, a guarded-notice release gate
  on `unpause`, a 2-hour default round notice with a capped gas reserve, a 48-hour start for the
  migrators LP-fee policy, and consumption-time validation of presale terms
- Amended: 2026-11-04 — accepted trust boundaries from the pre-audit's informational findings
- Amended: 2026-11-04 — compiled maximums for every admin-set fee
- Amends: [0088](0088-reusable-launch-accounting-and-atomic-migration.md) (delayed migrator
  immutability), [0097](0097-one-singleton-acl-with-typed-roles.md) (ACL storage and timelocked root
  transfer), and
  [0058](0058-eventless-package-initialization.md) (eventless initialization)
- Supersedes: the 2026-10-28 canonical stack, which holds no user assets

## Context

The risk register requests notice before code, treasury, fee and creator-cap changes,
and immediate emergency pausing. A compromised administrator must not be able to
apply a protected change or shorten its own cancellation window in the same transaction.
The intended rollout notice is 48 hours; the owner requires operation-specific,
changeable delays rather than one package-wide duration or privileged bootstrap setters.
The immutable admin package also needs a Table-backed administrator registry, requiring
a fresh publication of the dependent stack. Existing first-party contracts hold no user assets.

## Decision

### Operation-owned notice

A delayed value owns its applied value, applied notice period and at most one pending
replacement. Each replacement binds the proposed value, proposed next notice and an
absolute deadline formed from the **old applied notice**. Application atomically commits
both proposed fields after that deadline. Cancellation changes neither applied field;
replacement restarts the full old notice. Delay-only and value-only helpers delegate to
ordinary scheduling. There is one application path and no immediate setter or bypass.

For example, with an applied 48-hour treasury notice, a proposal to redirect funds and
set the next notice to zero still waits 48 hours. The multisig can cancel it throughout
that window, including after readiness until application. Revoking the compromised
role alone does not cancel its proposal because ordinary application is permissionless.
CancelAdmin therefore remains an independent multisig power.

The primitive validates timestamp addition and that the proposed delay remains representable
at scheduling and actual application, and that no notice exceeds 30 days (amended
2026-11-03; see the pre-audit hardening amendment). Applied-value reads need no Clock. Domain setters permit an
unchanged value when the notice changes, and reject unchanged value-and-notice pairs
where applicable.

Standalone upgrade actions and cap reassignments retain their applied notice after
execution and cancellation. An explicit policy-only proposal can change the notice
without upgrading code, destroying upgrade authority or transferring a creator cap.
It follows the same old-delay rule and cannot be consumed as a different action.
Standalone action schedules accept only their action inputs: an upgrade digest,
immutability decision or creator-cap recipient. They use and preserve the operation's
applied notice. Changing its notice requires an explicit policy-only
proposal; the two proposal kinds share the operation's single pending slot.
Upgrades remain bound to an exact digest, live UpgradeAdmin role, package generation,
capability custody and native upgrade receipt.

Adapter admission retains a single persistent notice across witness types and separate
pending admissions. A fresh witness type cannot reopen zero-notice setup. Admission
schedules identify only the witness type and snapshot a deadline using the currently
applied notice. Applying an admission changes only the allowlist; it cannot
restore an older notice after an independent policy change. Only the explicit admission
policy schedule/apply path changes the shared notice. Accepted deadlines remain fixed.
The operator must settle or cancel old zero-notice admissions before completing setup;
cancelling only the policy proposal does not cancel independent admissions. Immediate
adapter removal clears that type's membership and pending admission without resetting
its notice.

Fresh creator-cap reassignment operations and presale-vault LP-fee operations start at
48 hours. Their later notices can change independently after the current notice. Per-coin
LP overrides share one notice of their own (amended 2026-11-03), held by a `DelayedMap` that
starts at the policy's publication notice and changes only through its own schedule/apply
path, independently of the defaults' notice. Every override and every clear, for a new coin or
an existing one, waits the map notice applied when it was scheduled, so an override set during
zero-notice setup keeps no zero notice once the map notice is raised. Clearing is a delayed
change that removes the entry; cancelling keeps the applied override. New objects cannot reopen
publication bootstrap.

### Delayed migrated-vault creator splits

Both bonding `LpVault.fee_split` and presale `Vault.fee_split` store
`blast_admin::delayed::Delayed<FeeSplit>` with a named 48-hour initial notice.
The applied value remains active until explicit application. The live curve-fee cap
holder (bonding) or exact stored presale cap holder (presale) schedules and cancels.
Scheduling atomically binds a proposed split and next notice. Full old notice applies
to reductions and delay-only changes; replacements restart that wait. Unchanged
applied value and notice are rejected. Cancellation is allowed even after readiness.
Version guards precede authority and value validation. Pending decisions survive
cap reassignment; the new live cap can replace/cancel them, and ready application
remains permissionless. Standalone presale vaults have no matching creator cap.

Application accepts only the stored ready decision. For Bluefin and Cetus, public
venue adapters validate readiness before external work, collect every vault position's
fees under the applied split, compound auto-LP where applicable, and invoke a
package-only core activation. A later transaction failure rolls back collection,
payouts and activation together. No public core activation bypasses this settlement.
The shared read-only `Delayed.assert_ready` owns no-pending, readiness and application-time
representability checks without modifying pending or applied policy.

Aftermath presales retain their established collection-time fee accounting. DAO fees
arrive as separate coins at the vault address; receiving an arbitrary list cannot
prove that every earlier coin was received. After the full notice and an explicit
venue-checked application, later receipt uses the newly applied split, even when the
coin arrived before activation. Neither notice expiry nor scheduling alone changes
receipts. The API and guides make this accounting boundary explicit; the protocol
does not claim accrual-time fee attribution for Aftermath.

`FeeSplitScheduled` records proposal, threshold and next notice;
`FeeSplitCancelled` records the discarded proposal; `FeeSplitChanged` records old
and applied splits plus applied notice. Vault-created events still carry the plain
initial split; the immutable published package bytecode establishes its named 48-hour
initial notice. Replay initializes that notice from the package version, then follows
schedule/cancel/change facts. Indexers decode the stored delayed policy and treat expiry as readiness,
never as activation.

### Bonding holder-reward custody and recovery

Bonding rounds reserve holder assets separately from an optional Quote gas reserve.
The live RewardsAdmin publishes the allocation and may settle reimbursement once;
measuring attributable gas remains an off-chain responsibility. Publication checks the
caller's expected treasury against the governed LP-fee destination, even with no reserve,
and freezes that address for the round. Later treasury changes cannot redirect its
reimbursement. A zero reserve disables reimbursement; settlement is capped at the
reserved amount and immediately returns the unused reserve to the funding vault.
Holder proofs cannot spend the reserve, and bonding holder Meme remains payable to holders.

A round commits a future claim deadline (amended 2026-11-03: the round's terms commit a claim
window, and publication sets the deadline to its own time plus that window). Bonding claims
require a time strictly before that deadline. From the deadline onward, anyone may consume the round and return
unclaimed holder assets and an unsettled reserve to its original vault. This recovery
needs no administrator, so role revocation cannot strand custody. Reimbursement may
still settle after the deadline while the round exists; settlement and closure serialize
through the same shared round. The first completed closure deletes it.

Round numbers remain sequential, but checkpoint intervals need only be nonempty and
nonoverlapping: `previous_end <= start < end`. Gaps allow the publisher to skip periods
with insufficient volume. Closing a round does not rewind its number or checkpoint
cursor. Publication, claims, gas settlement and closure events preserve the separate
holder and gas accounting for replay.

### Signer and administrator authority

(Amended 2026-11-03.) The backend keys that sign account claims form a
`DelayedSet<ClaimSignerKey, vector<u8>>` in `RuntimeConfig`. Admission is delayed:
ClaimSignerAdmin schedules a 32-byte key, anyone applies it after the set's own signer
notice, and CancelAdmin may cancel it, even once ready. Removal is immediate:
ClaimSignerAdmin revokes a live or pending key in one call, and attestations it signed,
including earlier ones, stop verifying. Every admitted key signs claims with full authority,
so an immediate assignment would let a compromised ClaimSignerAdmin sign claims without
notice; the delay gives the multisig time to cancel the admission or replace the
administrator, while immediate revocation still stops a leaked key at once. Claims verify
against any admitted key, so rotation admits the new key before revoking the old one
without downtime. Live and pending keys together are capped at four (two live during a
rotation, two staged), keeping every claim's verification loop bounded; rescheduling a
pending key replaces its admission and does not count twice. The signer notice has its own
schedule/apply/cancel lifecycle under ClaimSignerAdmin and CancelAdmin, starts at zero at
publication so setup admits the first key at once, and is raised before release like every
other notice. Every call checks the live package version.

SuperAdmin sits behind the multisig, which can disable a compromised administrator
immediately. Administrator registration, role assignment and AdminCap transfer remain
immediate. The exception does not extend to creator-cap reassignment, fees, treasury or code.

ACL administrators move from an inline map to Table storage; the total administrator cap
is removed, while the per-administrator role bound remains. Root rotation retains its
independent seven-day timelock. (Amended 2026-11-03.) Later partner share and cap changes use
keyed `Delayed` values with a fixed seven-day notice that `blast_partners` never changes:
PartnerAdmin schedules and cancels, even after readiness, and anyone applies; payouts read the
applied share without a Clock (ADR 0095). Initial partner registration applies the agreed
share immediately.

### Publication and release

Publication retains the canonical Publisher and generation in a unique owned proof.
Wrapping consumes that proof and seals the matching never-upgraded UpgradeCap before
sharing the operational generation. The proof never authorizes policy setters. Launchpad
and presale start fully paused; migrators relies on launchpad migration gating.

Publication-owned policy operations begin with zero notice (amended 2026-11-03: upgrade custody
begins at 48 hours, so no upgrade or immutability action ever runs without notice). Ordinary
ACL roles may configure their values and intended notices in schedule/apply PTBs. There
are no special bootstrap setters. Before release, settle or cancel every outstanding
zero-notice proposal, configure and verify **each operation's** intended notice, then
release the selected pause bits through multisig UnpauseAdmin. Raising a notice never
rewrites an earlier proposal's deadline or proposed next notice. Setup may span transactions;
pause cycles and upgrades do not recreate publication authority or reset notices.

Nonzero compiled treasury destinations remain mandatory. Ordinary rate limits and quote
and adapter admission checks remain active during setup.

### Emergency pause and cancellation

PauseAdmin sets bits immediately and cannot unpause or move funds. UnpauseAdmin clears
selected bits immediately; pauses do not expire. Launchpad creation, trading (both buys
and sells, including opening-round admission/settlement), and migration have independent
bits. Presale creation, commitments and migration have independent bits. Claims, refunds,
presale settlement/cancellation and opening-round delivery remain reachable while paused.
Cancellation remains immediate. Quote/decimals listings, authority revocation, and buybacks
that burn Meme remain outside delayed policy. Holder-reward round publication was also outside
it until the second 2026-11-03 amendment moved it behind each vault's round notice.

### Replay

Scheduling events include the absolute deadline and notice with the proposed action
or value. For value-and-policy replacements the notice is the proposed next period;
for action-only proposals it records the unchanged notice used at scheduling. For
upgrades and adapter admissions, only explicit policy application emits a delay-change
fact. Application and cancellation identify which proposal becomes active or is
discarded. Multi-instance operations retain object identity. The indexer reads live
applied fields for current economics; readiness alone never activates a proposal.
Curve-fee and metadata-cap policy events identify their operation through distinct
payload types, keeping the event stream self-describing without a boolean discriminator.

## Alternatives considered

- A package-wide delay couples unrelated operations and prevents per-operation policy.
- A caller-selected wait permits a compromised administrator to choose zero.
- Immediate setters create a bypass for the same compromise the notice must contain.
- Delayed role grants add a second wait and impede emergency authority replacement.
- Clock-dependent reads would change trade and claim interfaces unnecessarily.
- A pause that expires needs Clock on every gated path; multisig release is explicit.

## Consequences

The fresh stack changes state layouts, signatures and event payloads. SDK, indexer and
operators must bind to the new stack. The fresh interfaces are implemented in
[SDK88](https://github.com/interest-protocol/blast-v2-sdk/pull/88),
[app/workers711](https://github.com/interest-protocol/blast-v2/pull/711),
[indexer114](https://github.com/interest-protocol/blast-infra/pull/114) and
[admin22](https://github.com/interest-protocol/admin-acl/pull/22). These source
changes require a fresh publication manifest and coordinated release.
Each operation's live notice determines its real
cancellation window; zero provides none. The rollout must verify 48 hours where that
notice is required. The admin module remains generic and immutable while owner-stored
notice periods can change through their own timelocks.

## Verification

Tests cover old-delay reductions including zero, value-only/delay-only replacements,
atomic application, cancellation after readiness, replay, rescheduling, overflow at
schedule/application/later schedule, stale generations, exact action/digest matching,
fresh-object defaults, admission policy interactions and live ACL role rejection.
Creator-split tests cover notice boundaries, replacement, cancellation, live-cap binding,
permissionless venue activation and old-split settlement. Bonding reward tests cover
separate gas custody, frozen treasury, capped and disabled reimbursement, checkpoint
gaps, exact claim/closure deadlines, authority revocation and conservation on recovery.
Native PTBs cover application followed by a failing schedule/application, proving rollback
of values, notices, proposals and events. Existing pause, custody, claims and ACL tests
remain required. Source boundary gates reject bypass APIs and missing owner persistence;
integrator guides and generated references must match source.

## Amendment 2026-11-03: keyed primitives that own their events

### Context

Owners re-implemented the delayed state machine around a bare `Pending` record,
encoded notice-only proposals with placeholder values (`DelayOnly`, `false`,
`option::none()`), passed the same notice twice, persisted the next notice by hand
under source-gate protection, and each emitted its own scheduled, cancelled and
changed events. The ACL root transfer used the separate immutable
`blast_fun_timelock` package, whose values switch by themselves at a deadline,
only as a deadline holder.

### Decision

Four `blast_admin` modules each own one delayed type and its lifecycle events:
`delayed` (which also holds `Proposal`, `Notice` and the deadline rules every type
shares), `delayed_action`, `delayed_set` and `delayed_map`. Each type stores its
`owner` object ID and an owner-defined key `K`. Constructors take the owner's `&UID`
rather than an `ID`, so only code that creates or holds an object can attribute
delayed values and events to it:

- `Delayed<K, T>`: a setting with its notice and one proposal (unchanged rules).
- `DelayedAction<K, A>`: a notice and one proposal that is either `Action(A)` or
  a notice change. `take_action` hands a ready action to the owner;
  `apply_delay` applies a ready notice change; each rejects the other kind. The
  primitive persists notice changes itself.
- `DelayedSet<K, E>`: an allowlist whose admissions each snapshot a deadline from
  the applied notice; a notice change never moves accepted deadlines; removal is
  immediate.
- `DelayedMap<K, E, V>`: keyed values under one shared notice, stored in a `Table`
  so the map grows without bound and a read costs one entry. Each entry change,
  setting or clearing, snapshots its deadline from the applied notice; a notice
  change never moves accepted deadlines. Clearing is a delayed change like setting.

Only the module that defines `K` can pack it, so only that module can create a
value keyed by it. Each type's module emits every lifecycle fact of that type,
generic in `K` and the value, action, member or entry types: `Delayed*` from
`delayed`, `Action*` from `delayed_action`, `Set*` and `MemberRemoved` from
`delayed_set`, and `Map*` from `delayed_map`, each family with `Created`,
`Scheduled`, `Cancelled`, `Applied` and `Destroyed`. A map event's change names
its entry, so one map keyed by a unit `K` records every entry's lifecycle. An
error a type raises in its own call is located in its module; readiness and
overflow checked through the shared deadline rules are located in `delayed`. A
replacement emits `Cancelled` for the displaced proposal before `Scheduled`, so
every proposal ends in exactly one `Applied` or `Cancelled`. Destroying a value with a pending proposal aborts, and destruction
emits its own event, so no proposal or membership ends silently. Owners emit only their own side
effects. The primitive rejects proposals that change nothing.

Upgrade custody, creator-cap reassignment and the ACL root transfer use
`DelayedAction`; migration-witness admission uses `DelayedSet`; per-coin LP-fee
overrides use `DelayedMap`; settings use `Delayed`. The raw `Pending` API is removed. The root transfer is a
`DelayedAction` with a fixed seven-day notice and no notice-change path, and
`blast_admin` no longer depends on `blast_fun_timelock`. Zero-notice bootstrap is
unchanged: configure with schedule-and-apply pairs, then raise each notice.

### Consequences

Upgrade custody starts at a 48-hour notice instead of zero. Setup never needs an
upgrade, so this closes the one window in which a compromised UpgradeAdmin could
replace code or seal a package without notice.

Package initialization is no longer eventless: every delayed value created in
`init` emits its type's `Created` event. This is deliberate. Each
operation's stream then starts with its own initial value and notice, so replay
no longer reads initial notices from published bytecode. Consumer `init`
functions still emit no events of their own.

Every delayed field gains `owner` and `key`; delayed, consumer and event layouts
change, and the replay stream for delay lifecycle moves to the event types of
`blast_admin`'s four delayed modules. SDK, indexer and admin console decoders must follow, with a fresh
publication of the stack. Keys must be structs without public constructors, and
owner objects must not expose their `&UID`; otherwise another package could emit
events under that key or owner.

## Amendment 2026-11-03: delayed holder-reward round publication

### Context

RewardsAdmin published a holder-reward round in one call that reserved its budget from
the vault at once. A compromised RewardsAdmin could therefore assign every unreserved
holder-reward balance in a vault to itself with no window in which CancelAdmin or anyone
watching could react.

### Decision

Round publication on both the migrators `LpVault` and the presale `Vault` uses the
`DelayedAction` slot pattern of creator-cap reassignment. Each vault stores
`round_publication: DelayedAction<RoundPublicationKey, RoundTerms>`, created in every
vault constructor right after its UID with `DEFAULT_ROUND_NOTICE_MS`. The vault module
owns `RoundTerms` (number, checkpoint interval, root, manifest digest, leaf count, holder
Meme and Quote, gas reserve, claim window and expected treasury) and checks its static
invariants when building it. It exposes package functions to schedule, take, cancel and
change the notice, never the slot itself.

- `schedule_round` (RewardsAdmin) checks the version, builds the terms, checks them
  against the vault to fail fast (next number, interval after the last checkpoint, budget
  with the gas reserve), and schedules them. Scheduling reserves nothing; rescheduling
  replaces the pending round and restarts the notice.
- `publish_round` is permissionless and takes no caller terms. It takes the ready round,
  re-checks the governed treasury, number, interval and budget, then funds, shares and
  announces the round exactly as before.
- `cancel_round` and `cancel_round_delay` (CancelAdmin) each discard only their own kind of
  proposal. `schedule_round_delay` (RewardsAdmin) and `apply_round_delay` (anyone) change
  the notice, which waits the applied one like every other delayed notice.
- The claim window is a duration. Publication computes the absolute deadline with a
  checked add, so a late publication still gives holders the full window, and
  `RoundPublished` keeps its absolute deadline field.
- The lifecycle is recorded only by `delayed_action`'s events keyed by
  `RoundPublicationKey`; `ActionScheduled` carries the full terms. There is no domain
  round-scheduled event. Claims, gas settlement and closure are unchanged.

The notice started at 0; the pre-audit hardening amendment below sets it to 2 hours.

### Consequences

Until RewardsAdmin raises a vault's round notice, a compromised RewardsAdmin remains
unmitigated: it can schedule and publish a self-serving round in one transaction. Raising
the notice is per vault and is itself delayed by the applied notice, so it must happen
before the protection is needed. At most one round per vault can wait at a time.

Because only publication reserves funds and the slot holds one proposal, the vault's
round cursor and rewards balances cannot fall between scheduling and publication; the
publication re-checks are defence in depth plus the treasury binding. Vault layouts,
`publish_round`'s signature and both packages' error codes change, so SDK builders,
indexers (which must follow `delayed_action` events keyed by `RoundPublicationKey` to
show scheduled rounds) and the fresh publication follow together.

## Amendment 2026-11-03: pre-audit hardening

### Context

An internal pre-audit of launchpad, presale, migrators and admin at `b841a81` found four
low-severity gaps in the delayed-administration design:

- A notice had no upper bound. One role could apply a notice near `u64::MAX`, after which
  every later schedule aborts with `invalid_delay`; nothing pending means nothing to
  cancel, so the setting, an upgrade slot included, froze for good.
- Publication-owned launchpad and presale policies start at zero notice and `unpause`
  checked nothing, so one missed runbook step left a policy changeable in one
  transaction after release. The launchpad protocol fee share is read live by every trade,
  so this reached every live launch's creator fees.
- Holder-reward rounds started at zero notice, and the gas reserve had no cap: a
  compromised RewardsAdmin could publish a self-serving round, or sweep a vault's
  holder Quote to the treasury through the reserve, in one transaction.
- Presale's validating value constructors take no `PackageVersion` and their consumers did
  not re-check, so values built by superseded bytecode could skip tightened rules.

### Decision

- **Ceiling.** Every delayed type accepts notices up to `delayed::max_delay_ms` (30 days),
  checked in each constructor and for every proposed next notice; above it aborts
  `invalid_delay`. Any notice can therefore be changed again within 30 days, and only
  `make_immutable` ends upgradeability.
- **Release gate.** `unpause` moves to each package's `package_admin` (the configuration
  modules import `PackageVersion`, so `blast_fun` and `blast_presale_package` cannot import
  them back); `clear_pause_bits` stays package-only. It aborts with a new error unless every
  notice it covers is guarded (`is_guarded` on `Delayed`, `DelayedAction` and `DelayedSet`):
  the applied notice is nonzero, no pending proposal would set it to zero, and a set has no
  pending admission. Launchpad covers upgrade custody, the claim-signer set, protocol fee
  share, treasury, trade fees, the adapter set, protocol allocation and creation fee;
  presale covers upgrade custody, the fee destination and rates, and the adapter set. Every
  unpause is gated, whatever its bits. The owner chose nonzero, not a fixed 48-hour floor,
  and no permanent floor: a later reduction remains possible, waits the applied notice and
  is visible while it waits. The gate can delay an incident unpause only when an operator
  lowered a notice to zero or left an admission pending; cancelling or applying it clears
  the gate.
- **Migrators LP-fee policy.** The destination, default shares and per-coin map start at
  48 hours. Their genesis values are compiled, so no setup needs zero notice, and migrators
  has no pause to gate.
- **Holder-reward rounds.** Every vault starts its round notice at 2 hours: CancelAdmin and
  watchers of `ActionScheduled` can stop a bad round, and a daily cadence still fits the one
  slot. A round's gas reserve is at most 10% of its holder Quote (`EGasReserveTooLarge`), so a
  Meme-only round has none. A per-round share-of-balance cap was rejected: the worker
  distributes the whole unreserved balance each round, and sequential rounds would defeat it.
- **Consumption-time validation.** Presale's constructors check through private
  validators, which `finalize` re-runs on eligibility, the uncapped phase, participant and
  recipient vesting and the fee split. `presale_vault` re-checks a fee split when a vault is
  built, when a split is scheduled, and before a ready split applies. A value built by
  superseded bytecode thus meets the current generation's rules. `Bps`'s 10,000 bound
  remains a type invariant.

### Consequences

`unpause` changes package and signature in launchpad and presale, adding launchpad error 44
and presale `package_admin::EUnguardedNotice`; migrators gains `vault::EGasReserveTooLarge`
(14) and presale `presale_vault::EGasReserveTooLarge` (12). SDK builders, the admin console
and runbooks follow. Accepted residual: the Merkle root stays opaque, so a compromised
RewardsAdmin can still assign one round's unreserved holder balance once its 2-hour notice
passes uncancelled; revoking the role and cancelling the round is the response.

## Amendment 2026-11-04: accepted trust boundaries

### Context

The same pre-audit listed informational findings. Most were fixed in code or docs; five
describe authority the design deliberately keeps. They are recorded here so integrators and
the external auditor see them as accepted, not overlooked.

### Decision

The owner accepts these boundaries without a code change:

- **No exit from MigrationReady or OpeningRound (LP-I6).** A graduated launch leaves only
  through its stored adapter, and the migration pause bit has no expiry. An opening round
  settles only while the trading bit is clear. The 48-hour upgrade notice therefore protects
  Live holders, who can sell; holders of a launch waiting to migrate or settle depend on
  PauseAdmin and UnpauseAdmin acting in good faith.
- **Presale PauseAdmin and FeeAdmin (PS-I2).** PauseAdmin can hold the presale migration bit
  until a sale's liquidity deadline, which turns a funded sale into refunds. FeeAdmin can raise
  one vault's Blast LP rate after its 48-hour notice, up to the 3,000 bps maximum (see the fee
  maximums amendment).
- **Deny-listed fee recipients (PS-I3).** Cetus and Bluefin vaults collect under the old split
  before applying a new one, so a Quote whose issuer deny-lists a fee recipient blocks that
  vault's collection and its re-split repair. Aftermath does not collect first and stays
  repairable. Listing only Quote types whose deny-list Blast accepts remains the control.
- **Venue operators (MG-I1).** A venue can strand a MigrationReady launch: a Cetus
  `add_denied_list<Meme>`, removing the fee tier, a venue pause or version bump, or a Cetus
  BurnManager pause aborts its migration, and the last two also stop fee collection.
  Recovery needs a migrators upgrade, which waits its notice.
- **LP-share changes reach accrued fees (MG-I2).** A FeeAdmin change to Blast's default or
  per-coin LP share applies to fees accrued but not yet collected. The 48-hour notice lets
  anyone call `collect_fees` first; the share is at most 3,000 bps.

### Consequences

The runbooks and integrator guides point here instead of restating each boundary. Any
future cap or exit path is a new decision.

## Amendment 2026-11-04: fee maximums

### Context

The accepted trust boundaries above left several admin-set fees able to reach 100%, and the
launch creation fee had no bound. A delayed notice makes a change visible; it does not stop an
absurd value.

### Decision

The owner set compiled maximums, enforced in the constructor of each stored value, so genesis,
scheduling and fixtures take the same path:

| Fee | Maximum | Publication value |
| --- | --- | --- |
| Blast's LP-fee share: migrators default and per-coin shares, presale default LP rates, each presale vault's rate | 3,000 bps | 1,500 |
| Launchpad protocol share of each trade fee | 7,000 bps | 5,000 |
| Presale raise fee, presale token fee | 1,000 bps each | 200 / 100 |
| Launchpad protocol allocation, Meme and Quote | 1,000 bps each | 250 / 150 |
| Launchpad creation fee | 10 SUI | 0 |

Per-sale presale rates were already at most the policy rates and inherit the caps. Launch trade
fees keep their existing 1,000 bps maximum and the partner share its 8,000 bps maximum. Raising a
maximum needs a package upgrade, which waits the upgrade notice.

### Consequences

PS-I2 and MG-I2 above now reach at most 30%, not 100%. Launchpad adds error 45
`invalid_protocol_fee_share`; migrators adds `lp_fee_policy::EInvalidShares`; the other caps reuse
`invalid_protocol_allocation`, `invalid_creation_fee` and presale `fee_policy::EInvalidFees`.
`docs/vectors/fees.json` and `graduation.json` follow the new maxima.

## Amendment 2026-11-05: internal deep-review fixes

### Context

The internal deep review of the six launch-stack packages at `4fe8d739`
(`audits/README.md`) found one Low and four Informational issues. Each settles an authority,
ABI or event decision, so they are recorded here. The owner chose to fix all five.

### Decision

- **Every `unpause` is version-gated.** `blast_vault_package::unpause` now calls `assert_current`
  first, as the product wrappers and the vault's own `make_immutable` do (L-1). Superseded
  bytecode can release nothing.
- **The release gate covers the core treasury.** Each package's `unpause` takes the shared
  `blast_core::blast_treasury::Treasury` and refuses with the package's own `unguarded_delay`
  while the treasury's notice is unguarded (I-1). The treasury keeps no floor: a reduction
  stays a visible, cancellable proposal, and the gate now catches one that reached zero before
  release, as it does for each package's own notices.
- **Compounding is its own call.** `collect_fees` and `settle_and_apply_fee_split` no longer add
  auto-LP; anyone calls the venue's `compound_auto_lp`, so a venue refusing the add never blocks
  collection (I-4). Cetus's `collect_fees` no longer takes the `Clock`.
- **Migration payout events carry the schedules.** `MigrationAllocationPaid` gains
  `meme_vesting_id` and `quote_vesting_id`, as the presale's allocation events have (I-2).
- **Holder-reward leaves name accounts.** A claim pays by transfer, so Blast's allocation
  excludes balances held by objects (I-3); nothing on chain tells the two apart, and the
  module and guide say so.

### Consequences

`unpause` changes signature in launchpad, presale and vault; `compound_auto_lp` is new in both
venues and Cetus `collect_fees` drops its `Clock`; `MigrationAllocationPaid` adds two fields. SDK
builders, blast-infra decoders, the admin console, the workers' collection job and the runbooks
follow; a worker that collected and compounded in one call now sends two commands. The launchpad
PTB fork gate appends `compound_auto_lp` to each collection against Cetus and Bluefin bytecode;
adversarial pool states for the review's H-1 stay open.

