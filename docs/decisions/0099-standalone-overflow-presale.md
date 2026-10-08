# 0099: Standalone overflow presale

- Status: accepted
- Date: 2026-09-29
- Amended by: [0101](0101-presale-protocol-fees.md): Blast takes admin-set,
  creation-snapshotted shares of the raise, the token supply, and LP fees;
  [0102](0102-presale-creation-allowlists.md): Blast allowlists the Quote types
  and migrators new presales may use
  [0104](0104-external-presale-migrators-and-vendor-packages.md): `new` and
  `migrate` are public, so an allowed migrator in another package can create and
  migrate sales;
  [0110](0110-presale-initializer-and-early-close.md): sales are created through a
  `PresaleInitializer`, the hard cap is a sale setting rather than the uncapped
  phase's, and a sale whose hard cap closes it when filled settles once its raise
  is full
- Amended: 2026-10-02, after the pre-launch security review (owner rulings of
  the same day): the LP-migration window has a seven-day floor; an
  open-to-anyone phase under an allowlist must reach the raise with the slots
  beyond the allowlist's leaves; venue incentive rewards are deliberately not
  collected; regulated Quote and sale coins are vetted off chain
- Amended: 2026-10-02 (owner decision): token and raise recipient shares may
  vest; migration locks each vesting share in an irrevocable
  `blast_fun_vesting` linear schedule that starts at migration
- Amended: 2026-10-03 (owner decision): one package-local `AdminCap`, which a
  key-only `SuperAdminCap` can replace or revoke, replaces the shared Blast ACL
  roles, so presale no longer depends on `blast_admin`
- Amended: 2026-10-04 (owner decision): `share` takes a start time, so a sale
  can be created and shared ahead of its window; commitments open at the start
- Amended: 2026-10-05 (owner decision): a sale may make participant tokens
  vest; each claim locks the participant's tokens in an irrevocable
  `blast_fun_vesting` linear schedule that starts at that claim
- Amended: 2026-10-05 (owner-requested cleanup): a sale stores only what nothing else determines. The
  share fixes the start, and the window's end, the LP deadline, and the
  uncapped start are derived from it and the creation-time lengths, which the
  share proves fit in u64; `PresaleOpened` still reports all four. The sale
  counts the wallets still holding a commitment, so the claim that empties it
  takes the integer remainder and `Claimed` reports the participants remaining.
  The LP-fee split is one sealed `FeeSplit` value, validated where the creator
  builds it and copied into the vault, so no holder of a split can bypass its
  10,000-BPS total

## Context

Projects need a fixed-window presale in which eligible wallets commit up to
per-wallet limits, oversubscription produces the same fill rate for everyone,
and unfilled Quote is refunded. Raise size, token allocations, time windows,
wallet caps, and the eligible population vary per sale. This product is not a
launchpad mode: it has separate custody, lifecycle, authority, deployment, and
upgrade risk.

The contract must also preserve participant exits if a raise is missed or
liquidity migration does not complete after a successful raise. Migration must
not depend on the creator remaining online.

## Decision

Create the independent `blast_presale` package. It neither reads nor mutates
launchpad state, and no launchpad package imports it. Bluefin and Cetus adapters
stay inside this package so core escrow release and venue creation are one
atomic call without a second presale-adapter package. It does not depend on
`blast_admin`; `blast_presale_admin` replaces the shared Blast ACL's four
presale roles (ADR 0097) because the admin package was not yet audited when
presale was readied for launch, and presale logic can never change after
publication, so a presale that depended on it could never take a fix to it
(owner, 2026-10-03). Publication sends the publisher one `AdminCap`, the
package's only administrator, gating Blast's fee rates and destination
(ADR 0101), the creation allowlists (ADR 0102), holder-reward rounds, and
upgrades. A shared `AdminRegistry` records the one cap ID it accepts, and every
gated function checks the presented cap against it. A Sui owned object cannot be
taken from its owner, so a lost or leaked cap is removed through that record:
publication also sends a key-only `SuperAdminCap`, held cold, whose only powers
are `replace_admin_cap`, which mints a new cap and stops the old one in the same
transaction, and `revoke_admin_cap`, which stops all administration until the
next replacement. Without `store` it moves only through `transfer_super_admin`.

The package stays relinkable but its logic never changes. Bluefin requires its
callers to link its exact current version and Cetus rejects callers linked below
its configured version (verified against mainnet bytecode: Bluefin
`config::verify_version`, Cetus `config::checked_package_version` and LP Burn's
`checked_package_version`). An immutable presale would therefore lose migration
and LP-fee collection for every sale on a venue at that venue's next version
bump. After publication the deployer calls `package_admin::wrap`, which accepts
only this package's never-upgraded `UpgradeCap`, narrows it to the
dependency-only policy, and seals it in a shared `PackageAdmin` in the same call.
The `AdminCap` authorizes and commits upgrades that only relink dependencies.
The package claims no `Publisher`. Every
callable generation therefore runs identical presale bytecode, so no operational
version gate is needed, and no path can make the package immutable or widen the
policy.

Each `Presale<SaleToken, Quote>` consumes a `TreasuryCap<SaleToken>` whose total
supply is zero. The Coin Registry holds exactly one `Currency<SaleToken>` and
the type has exactly one `TreasuryCap<SaleToken>`, and fixing or burn-only-ing the
supply consumes that cap, so holding it proves the currency's supply is still
unknown without a separate check. The Bluefin route also rejects a Meme symbol
longer than 32 bytes: Bluefin stores the symbol-derived pool name twice in every
`Position` (ADR 0088). Because the migration amounts are fixed at creation, the
seed price `sqrt(raise / LP tokens)` must also sit a factor of two inside the
sqrt-price bounds Cetus v15 and Bluefin v17 share (`4295048016` to
`79226673515401279992447579055`), so no sale can raise funds it can never pool.
The creator configures a token supply, positive participant and LP allocation
BPS, and zero or more distinct recipient allocations. These BPS total exactly
10,000. The contract mints the complete supply, uses largest-remainder
apportionment so every atomic unit is assigned exactly once, and escrows every
allocation. It then irreversibly consumes the TreasuryCap into the selected Coin
Registry `Fixed` or `BurnOnly` supply state before commitments open. The remaining
immutable per-sale configuration contains a positive Quote raise, a commitment
duration, an LP-migration window of at least seven days
(`MIN_LIQUIDITY_WINDOW_MS`), a sealed migration witness, venue tier, an
LP-fee split, and an `EligibilityPolicy`. The fee split is up to 16 distinct
`(recipient, bps)` fee recipients, the creator configured as one of them, and a
holder-reward BPS; together they total exactly 10,000.

Every rate is a package-local `bps::Bps`, the ADR 0044 unit: callers build each
rate with `bps::new`, which alone owns the `0..=10,000` range, and presale storage
and fee arithmetic hold only validated values. Owner modules keep the stricter
rules: positive shares, distinct recipients, exact or sub-whole totals, and
Blast's fee ceilings. Events keep raw `u64` BPS. The package keeps its own copy
because it must not import launchpad. The eligibility policy is:

- `Open` stores one wallet cap, a maximum participant count, and a minimum
  cumulative commitment per wallet. Creation requires
  `min_commitment * max_participants >= raise_target`, so whoever fills every
  slot has funded the sale; dust commitments cannot lock real buyers out.
- `Allowlisted` stores a positional Blake2b-256 Merkle root and leaf count.
  Each leaf binds `(index, wallet, wallet_cap)`, so one representation covers
  equal caps, rank tiers, and custom caps.

Both policies are bounded by a technical ceiling of 65,536 dynamic commitment
records. This is not a product eligibility count or raise-size constant.

A sale may add an `UncappedPhase` starting `starts_after_ms` into the window,
from which wallet caps no longer apply. Its access is either `Eligible` (only
wallets the policy admits, through `commit_open` or `commit_allowlisted`) or
`Anyone` (any wallet, also through `commit_uncapped`, with its own participant
bound and minimum; the bound must be at least the policy's, and the minimum
must reach the raise over the slots held to it: every slot under an open
policy, whose wallets already meet a minimum that reaches the raise, and only
the slots beyond the leaf count under an allowlist, whose wallets may commit
any positive amount, so a phase that admits no wallet beyond an allowlist is
rejected). With `hard_cap`, a
commitment in the phase accepts only what is left of the raise and returns the
excess as a coin in the same call, the one commitment that exactly fills the
raise may be below the minimum, and a full sale rejects further Quote
(`EPresaleFilled`); commitments made before the phase keep their overflow.
Without it, caps lift but the sale still overflows and fills pro-rata. Every
commit function returns the Quote it did not accept, a zero coin outside a
hard-capped phase.

The creator may also give recipients shares of the raise (`raise_allocations`,
in BPS of `R`, totalling strictly less than 10,000). They are apportioned into
exact Quote payouts at creation, paid at migration, and the LP seeds with the
rest, which is also the Quote the seedable-price check uses. A cancelled sale
refunds every commitment in full.

Any token or raise recipient share may carry `VestingTerms` (cliff, step
period, and step count). The contract bounds the duration only technically,
at 2^63 ms, so a schedule's end always fits in u64; product limits belong to
creation tooling (owner, 2026-10-02). The terms are fixed
at creation and emitted in `PresaleCreated`, so participants see every lockup
before committing. At migration, instead of transferring a vesting share, the
presale funds an irrevocable `blast_fun_linear_vesting` schedule for that
recipient starting at the migration timestamp, shares it, and names it in the
share's `RecipientAllocated` or `RaiseAllocated` event. The vesting package is
the immutable util-contracts package `0x85fd…ec5c` (S2), so it cannot change
under a live sale. Schedules have no cancellation authority: a cancel cap would
let its holder take back what is still locked. Terms are validated at creation
against every check the schedule constructor makes, so a vesting share can
never make migration abort. Fee shares cannot vest; they are paid as fees are
collected.

A sale may also set optional participant `VestingTerms`, built and bounded by
the same `vesting_terms` constructor, fixed at creation, and emitted in
`PresaleCreated`. Under them, each claim after migration funds an irrevocable
`blast_fun_linear_vesting` schedule for the participant with its pro-rata
tokens instead of transferring them, shares it, and names it in the claim's
`Claimed` event; the Quote refund is still paid at once. The schedule is
created when the participant claims, not at migration, because migration cannot
iterate up to 65,536 participants and the vesting package rejects a start before
the current clock, so each schedule starts at its own claim (owner,
2026-10-05). A claim whose tokens round to zero creates no schedule, since a
schedule cannot hold nothing. Cancellation pays no tokens, so it creates none.

The shared-object lifecycle is:

```text
Pending -> Open -> Funded -> Migrated
                   |          claims stay open
                   v
                Cancelled
```

`share` fixes the windows from the creator's `start_ms`, or from the share
itself once that time has passed, so a creator can publish a sale a day ahead
and announce its start. The sale is `Open` from the share, but commitments
abort until `start_ms`; the commitment and LP windows, and any uncapped phase,
count from the start. Nothing bounds how far ahead the start may be: that is a
product limit for creation tooling. Commitments are positive, cumulative per
wallet, and cannot exceed the policy cap. Each commitment consumes a
`Coin<Quote>` and locks its full balance in that `Presale`, so recorded
commitments are backed one-for-one by on-chain Quote custody. There is no
voluntary withdrawal during `Open` or `Funded`: a cancellation returns the
full commitment, while a migrated sale returns only its calculated overflow.
At the exclusive end timestamp, anyone may settle. If total commitments `C`
are below the raise `R`, the sale cancels and all Quote remains refundable.
Otherwise the sale becomes funded and fixes one common fill rate `R / C`.

While the sale is `Funded`, anyone may call the configured venue adapter; the LP
deadline does not close migration. Cetus pools order their coin types, so its
single `migrate` and `collect_fees` routes take the caller-named
`<CoinA, CoinB>` order beside `<Meme, Quote>`, prove the pair is exactly the
presale's, and retype each balance through a transient dynamic field, which
`dynamic_field::remove` returns only under its stored type. The full-range add
fixes the side with more atoms and asks the venue's own `get_liquidity_by_amount`
whether the other balance covers it, fixing the other side when rounding would
overdraw by an atom at nearly equal amounts.
The adapter alone holds the sealed witness needed to take exactly `R` Quote and
the entire LP-token allocation from core. In the same call it creates the
configured full-range pool and seals its position or burn proof in a
`Vault`. Claims open only after this call succeeds; a venue failure rolls
back the complete transaction. That transaction also pays each configured
recipient its distinct immutable token allocation and each raise recipient its
Quote payout. The migration witness, tier,
allocations, and fee split were fixed before commitments opened and cannot be
supplied by the migration caller.

If a funded sale is not migrated by the deadline, anyone can cancel it from
then on. Until someone does, migration stays open, so after the deadline the
first of a migration or a cancellation wins. The window is at least seven
days, so a sale that nobody settled by its end can be settled and cancelled in
one transaction only after a week in which nobody migrated or settled it
(owner, 2026-10-02: a successful raise must not be cancellable through a short
window, and the exit stays because a venue outage that outlasts a relink is the
only way a funded sale cannot migrate). Settlement cancels only an
underfunded sale; a sale that met its raise and is first settled after the
deadline becomes funded and may still migrate or be cancelled. Cancellation never
releases Quote to the creator; participants receive full refunds, while the cap
holder may destroy the now-useless `PresaleCap`. Every minted SaleToken
allocation remains permanently locked in the cancelled presale, and the consumed
TreasuryCap is never recreated.

After migration, participant `i` with commitment `c_i` receives:

```text
tokens_i = floor(token_allocation * c_i / C)
refund_i = floor((C - R) * c_i / C)
```

Claims are permissionlessly relayable and always pay the committed wallet, or
lock its tokens in a schedule for it under participant vesting.
The final claim receives the bounded integer remainder of both balances, so
all escrowed participant assets are conserved. Claim order changes only which
wallet receives that documented sub-participant-count remainder.

LP fee collection is permissionless. The vault apportions each asset across
the fee recipients and the holder-reward share with largest-remainder
apportionment, pays every recipient in the same call, and keeps the holder
share. Blast, holding the `AdminCap`, commits each reward round's beneficiaries and amounts with a Merkle
root and funds it from that share, so holder distribution runs on Blast's
automated reward pipeline rather than the creator's availability. Each round
carries a future claim deadline; after it, anyone may close the round and return
its unclaimed balances to the vault's holder share, so an overcommitted or
abandoned root never strands funds. Anyone may
relay a valid proof, but assets go only to its committed beneficiary. The same
generic positional Blake2b-256 module verifies eligibility and rewards. The
`PresaleCap` claims migration residuals.

## Alternatives considered

- **Add a launchpad mode.** Rejected because presales are independently
  deployed custody and do not require curve, trade-fee, or partner state.
- **Use the launchpad migrators package.** Rejected because it imports launchpad
  types and would couple the independent presale product to that lifecycle.
- **Let the cap holder release migration assets.** Rejected because the caller
  could falsely attest migration or disappear; sealed adapters make completion
  permissionless and atomic.
- **Leave funded sales waiting forever.** Rejected because loss of the creator
  capability or operator availability would permanently lock participant Quote.

## Consequences

- Raise sizes, time windows, allocations, eligibility, and wallet caps are all
  per-sale values; example numbers from product material are not protocol
  constants.
- Token supply; participant, LP, and recipient allocation BPS; recipient
  addresses; and fixed-versus-burn-only mode are per-sale values. The contract
  proves the matching TreasuryCap starts at zero, mints and apportions the
  complete configured supply, and permanently removes mint authority.
- The Merkle manifest and proof construction remain off chain, while the root,
  leaf count, commitments, custody, lifecycle, and payouts are canonical on chain.
  A proof attests only the committed wallet and cap; it does not prove that the
  off-chain rank or eligibility methodology was fair.
- Dependency-only custody keeps venue relinking possible while ruling out logic
  changes: old and new generations run the same presale code, so concurrent
  access to shared custody cannot bypass a guard. A compromised `AdminCap` can
  relink dependencies only; the policy can never widen. Logic changes need a
  new package and new sales.
- One `AdminCap` holds every administrative power, so Blast keeps it in a
  multisig. Until the `SuperAdminCap` replaces it, a compromised cap can
  redirect future holder-reward shares and Blast's fee payouts, set future
  sales' rates and any migrated sale's Blast LP-fee rates (ADR 0101), change
  the creation allowlists, and relink dependencies; it cannot reach any
  participant's commitment, any recipient's allocation, or any other live
  sale term. A compromised `SuperAdminCap` can take all of that by
  issuing itself a cap, so it stays in a cold multisig and is used only to
  recover from a lost or compromised `AdminCap`.
- Blast chooses the reward Merkle roots. Proofs enforce
  the published allocation but cannot prove that its off-chain holder
  methodology was fair. The creator cannot redirect the holder share.
- Fee recipients are fixed addresses, not transferable claims: a recipient that
  loses its key loses its future fee share. Pushing at collection keeps the
  vault free of per-recipient balances and claim paths.
- Cancellation refunds participant Quote but permanently locks every SaleToken
  allocation. It cannot restore mint authority or change the selected Coin
  Registry supply mode; a creator who retries must deploy a new coin type.
- The generic package cannot remove a Quote issuer's deny, pause, or supply
  powers. Such controls can block an affected wallet's transfer, although an
  aborted claim leaves its on-chain commitment and escrow intact for retry.
  Payouts are pushed, so a denied fee recipient blocks that vault's collection
  and a denied raise recipient blocks migration until the LP deadline. A
  regulated sale coin gives its creator the same power over participants'
  post-migration claims. Blast therefore allowlists only Quote types whose
  controls it accepts and vets each sale coin's `Currency` regulated state off
  chain (owner, 2026-10-02). A Quote issuer that lengthens its icon can also
  block Bluefin migration, which then ends in cancellation and full refunds;
  the Coin Registry has no symbol setter.
- Neither adapter collects venue incentive rewards credited to the custodied
  position, as in the migrators (ADR 0088). Under dependency-only custody no
  later generation can add a collection path, so such rewards stay with the
  position.
- Venue operators are trusted for liveness, not custody: a Cetus deny-list
  entry, a paused Bluefin pool, or a venue version bump blocks migration or fee
  collection until the `AdminCap` holder relinks the package or, before migration,
  the sale is cancelled for refunds.
- Largest-remainder ties favour fee recipients over the holder share and earlier
  recipients over later ones. Because collection is permissionless, anyone can
  collect often to steer at most one atomic unit per share per asset per
  collection toward the tie winner.
- A participant's vesting starts at its claim, so a participant that claims
  later unlocks later; since anyone may relay a claim, a keeper can claim for
  every participant right after migration to start every schedule together.
  Relaying funds a new shared object, so the relayer pays its storage.
- A vesting recipient or participant claims from its own schedule; anyone may
  relay that claim, and payment always goes to its beneficiary. The schedule is a separate
  shared object per vesting share, so indexers join it to its presale through
  the allocation event's `vesting_id`. A Quote issuer's deny list can stall a
  vesting raise recipient's claims as it would a direct payout.
- Deployment must seal custody before any upgrade: `package_admin::wrap`
  accepts only a never-upgraded cap, so a raw upgrade before `wrap` would leave
  a compatible-policy cap that can never be sealed.

## Verification

- Unit tests cover equal caps, tiered Merkle caps, cumulative cap enforcement,
  dynamic-record bounds, exact time boundaries, proportional fills, full
  refunds, exact full-supply apportionment, distinct recipient payouts, fixed and
  burn-only supply modes, cancelled-supply locking, migration witness enforcement,
  LP-fee splitting with direct recipient payouts, fee-split validation,
  administrator-published holder rounds, round deadlines and closing, minimum
  commitments and reachable raises, seedable prices, Cetus coin-order routing
  and checked retyping, generic Merkle proofs, and relayed holder rewards.
- Unit tests also pin the seven-day LP-window floor (one millisecond below it is
  rejected, and every fixture opens at the floor) and an allowlisted
  anyone-phase whose slots beyond the leaves cannot reach the raise.
- Unit tests share a sale ahead of its start, reject a commitment one
  millisecond before it ahead of amount checks, open the window at the share
  when the start has passed, and reject a start whose windows end past u64
  milliseconds.
- Unit tests create vesting token and raise shares, check the creation and
  allocation events and each schedule's beneficiary, start, terms, amount, and
  missing cancellation authority, claim each schedule after migration (nothing
  before the cliff counted from migration, half at the cliff, the rest at the
  end), reject vesting fee shares, and pin every `VestingTerms` bound.
- Unit tests lock each participant's claimed tokens in a schedule from its own
  claim (its creation event's beneficiary, amount, start, and terms, the claim's
  `vesting_id`, the Quote refund paid at once, the last claim's remainder), wait
  for the cliff counted from the claim, create no schedule for a claim whose
  tokens round to zero or for a cancelled sale's refunds, and record the terms
  in `PresaleCreated`.
- Unit tests cover publication's caps and registry, replacing and revoking the
  `AdminCap` with their events, a replaced or revoked cap being rejected, a
  replacement after a revocation, and the super administrator's transfer.
- The package gate checks source boundaries (no `blast_admin` dependency; the
  reviewed caps and registry; `SuperAdminCap` minted only at publication and
  used only to replace or revoke; `AdminCap` minted only at publication or by a
  replacement; every function taking an `AdminCap`, at any visibility,
  checking it against the registry as its first statement; and sealed
  dependency-only custody whose transitions each require the `AdminCap`), builds both network environments, lints with
  warnings as errors, and runs Move tests.
- Deployment records the publish transaction and the `package_admin::wrap`
  transaction, whose effects must show the shared `PackageAdmin` and an
  `UpgradeCap` policy of dependency-only before any presale is created.

## Sources

| Ref | Source |
| --- | --- |
| S1 | [Sui framework at `06734f6ff0af45d8632a14a4dc4b100197f6b1a2`](https://github.com/MystenLabs/sui/tree/06734f6ff0af45d8632a14a4dc4b100197f6b1a2/crates/sui-framework/packages/sui-framework) |
| S2 | [`blast_fun_vesting` at util-contracts `63b6cf86c0e1a74f699610fe182b1de8d8789a14`](https://github.com/interest-protocol/blast-util-contracts/tree/63b6cf86c0e1a74f699610fe182b1de8d8789a14/sui/vesting), published immutable on mainnet at `0x85fdb7e3d28162b99e0df758069a3d23cff874c400b2160fc0d4618aefd3ec5c` |
