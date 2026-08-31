# 0053: Single-validator `funSUI` and `blastSUI`

- Status: accepted
- Date: 2026-08-29
- Amended by: [0056](0056-bounded-pending-stake-vector.md), [0060](0060-blastsui-metadata-cap-custody.md), [0061](0061-blastsui-routine-admin-and-composable-package-custody.md)

## Sources

| Short ref | Full commit |
| --- | --- |
| `sui@06734f6` | `06734f6ff0af45d8632a14a4dc4b100197f6b1a2` |
| `spring@49f7573` | `49f757384e69065ab082dc2fcf653f4b285a1940` |

The primary-source comparison, native rounding facts, and rejected
alternatives are recorded in
[`../research/blast-sui-lst-design.md`](../research/blast-sui-lst-design.md).

## Context

Blast needs a SUI-denominated quote coin for launch trading and migrated
liquidity. A conventional value-accruing LST makes a fixed quote-unit launch
target appreciate in SUI terms. Blast also operates one validator and wants all
SUI backing this product delegated only to that validator.

Native Sui provides `StakedSui`, `FungibleStakedSui`, pool exchange rates, and
same-transaction redemption to `Balance<SUI>`. Those receipts are objects, not
`Coin<T>`, so they cannot directly satisfy `blast_fun`'s generic `Quote` type.

Two earlier drafts of this package were reconciled here. One shared a single
native position between both coins and blocked the final `blastSUI` holder
while `funSUI` existed; the other reused the launchpad ACL for upgrade
authority. Both are rejected below.

## Decision

Create an independently deployed `blast_sui` Move package. It depends only on
the pinned `SuiSystem` framework package. It does not import `blast_fun`, and
`blast_fun` does not import it. Existing quote admission and migration
interfaces compose with its coin types without changing launchpad core.

### Two coins, two custody ledgers, one validator

The package creates two unrestricted nine-decimal currencies:

- `funSUI` (`FUN_SUI`) is redeemable for exactly one atomic SUI unit per atomic
  `funSUI` unit. It receives no staking yield. Its intended use is Blast
  launchpad and migrated-pool quote liquidity, but mint, transfer, and
  redemption are permissionless.
- `blastSUI` (`BLAST_SUI`) is a share of blast custody. A depositor first
  receives a key-only `BlastSuiDepositReceipt` that owns the native
  `StakedSui`. After activation, consuming the receipt mints `blastSUI`. It
  receives the native staking rewards produced by blast custody and by the SUI
  backing `funSUI`.

One shared `Vault` owns both treasury caps and two separate custody ledgers,
`fun` and `blast`. Each ledger holds a liquid `Balance<SUI>`, up to three
activation-ordered pending `StakedSui` receipts, at most one active
`FungibleStakedSui`, and the conservative SUI valuation of that active position.
Pending stake is worth exactly its principal before activation. Same-epoch
requests join, arrived receipts drain oldest-first, and a full queue leaves
excess SUI liquid instead of aborting, as specified by ADR 0056. Both ledgers
delegate only to the validator address and
staking-pool ID fixed at creation. The vault caches exactly one native pool
exchange-rate entry — its epoch, `sui_amount`, and `pool_token_amount` — and
each ledger stores the floor valuation of its active tokens at that rate. The
cache is consensus-critical: it is what lets a refresh price and sweep with one
table lookup instead of an unbounded search for the latest entry.

Let `L_f`, `P_f`, `V_f` be fun liquid, pending principal, and active valuation,
`A_f = L_f + P_f + V_f` the fun assets, `F` the `funSUI` supply, and the same
symbols with `_b`/`B` for blast custody and `blastSUI` supply. `R` is the fixed
fun rounding reserve.

```text
create with seed y >= 1 SUI + R:    fun custody += R (mints nothing);
                                    blast custody += y - R; B = y - R (one share per MIST),
                                    all of it transferred to @0x0 and locked forever
mint funSUI with x SUI:             fun custody += x;  F += x
redeem x funSUI:                    fun custody -= x;  F -= x   (exact, fee-free)
refresh sweep:                      if A_f > F + R, move A_f - F - R from fun to blast
request blastSUI with y SUI:        user receipt owns one StakedSui; vault unchanged
claim activated receipt worth y':  mint floor(y' * B / A_b), then add its pool tokens
                                    to blast custody
donate d SUI:                       blast custody += d; B unchanged
blastSUI redemption s < B:          gross = floor(s * A_b / B)
                                    fee = ceil(gross * redeem_fee_bps / 10_000)
                                    user receives gross - fee; fee stays in blast custody
                                    (always partial: the locked shares are never presented)
```

`funSUI` mints and redeems exactly 1:1 against fun custody only. Its mint has
no runtime requirement that `blastSUI` supply is positive; the bootstrap seed
never backs `funSUI`. `blastSUI` pricing uses only blast custody and blast
supply. Blast custody's own staking yield accrues there directly. The refresh
that precedes every mutation revalues both active positions at the applied
rate, then moves only fun yield — fun assets above the `funSUI` supply plus the
reserve — from fun custody into blast custody. It moves liquid SUI above the
reserve first and otherwise splits active pool tokens worth at most the
remaining surplus at the same rate and joins them into the blast position; it
never moves fun principal and never moves value from blast to fun. Every
refresh, fun mint, and fun redemption asserts that fun custody's conservative
assets are at least the `funSUI` supply.

`donate_sui` is a permissionless reward input. It refreshes the vault, adds a
positive `Coin<SUI>` only to blast custody, mints no share or receipt, delegates
idle SUI when possible, and emits the donation amount with the final custody
snapshot. The donation therefore raises assets per existing share. The locked
bootstrap shares receive and retain their pro-rata part permanently. A donor
must account for that allocation when it chooses a reward amount and time.

### blastSUI activation receipt

A `blastSUI` request requires at least the native one-SUI staking minimum. It
delegates the supplied SUI immediately and places the returned `StakedSui`
inside an owned `BlastSuiDepositReceipt`. The receipt has `key` as its only
ability. It cannot be generically transferred, wrapped, or deleted; the
request returns it without an internal transfer. A caller can compose it into
claim or cancellation in the same transaction, or call
`deposit_receipt::keep` to place it in the transaction sender's account. Its
immutable vault binding prevents a receipt from entering another vault.

The receipt and its native stake remain outside both custody ledgers and every
coin supply. A claim is available from the native activation epoch onward and
requires a current pool exchange rate. It refreshes the vault first, converts
the receipt's `StakedSui` to `FungibleStakedSui`, values those pool tokens at
the current rate, computes `floor(contributed_value * B / A_b)` against blast
custody before the contribution, checks slippage, joins the pool tokens, mints
the shares, and consumes the receipt. This gives the depositor all rewards
earned by its own stake after activation without sharing rewards earned before
activation by existing blast or fun stake.

Cancellation is an independent receipt exit. It consumes the receipt and uses
the native withdrawal path to return SUI, before or after activation and even
after validator removal. It neither reads nor mutates the vault and charges no
blast redemption fee because no `blastSUI` was issued. A Sui Display V2
describes the receipt. Its static fields do not duplicate native stake state.
Its permissionless, version-gated creator derives the canonical display from
the system `DisplayRegistry` and locks the `DisplayCap` at `@0x0`.

### Exchange-rate cache and safe mode

Every normal epoch change writes the pool's exchange-rate entry for the new
epoch; a safe-mode epoch writes none. The refresh performs one `Table` lookup
at the current epoch. A present entry replaces the cache, proves that the
immutable pool itself is active, permits blast pending conversion and idle
delegation, and permits activated fun stake to convert when the rounding buffer
remains safe. A missing entry keeps the cached rate and both pending receipts,
because the cache can predate their activation rates. It also keeps new idle
vault balances liquid until a normal epoch. The vault performs no backward scan; native
conversion and redemption remain framework-owned.
`create` requires a current-epoch entry so the cache starts valid. A blast
deposit request does not price or enter vault custody, so it can create a
receipt without a current entry. Claim requires a current entry because it
prices the activated contribution against existing holders. `funSUI` mints,
both coin redemptions, receipt cancellation, and `sync` stay open: a
`blastSUI` exit is quoted on the cached conservative valuation with the
caller's minimum output as its protection. An activated fun receipt that cannot
convert safely is withdrawn to liquid SUI, which realizes its rewards; the
ordinary sweep then retains the rounding reserve, moves surplus to blast, and
allows the remaining principal to be delegated again. Every vault event
carries the applied entry so a consumer can reconstruct which rate priced each
transition.

A newly joined validator has no current pool entry during its first active
epoch under the pinned framework. Deployment therefore creates the vault no
earlier than the validator's second active epoch.

### Rounding reserve

Native conversion of activated `StakedSui` floors the pool-token amount, and
native `FungibleStakedSui` redemption floors the principal and reward portions
separately, so fun custody can be a few MIST below `F` immediately after a
conversion or a full active-position exit. `create` therefore splits the
constant reserve `R` (0.1 SUI) from the owner seed into fun custody as
protocol-funded safety capital with no `funSUI` minted for it. The reserve is
not fun principal, never moves to blast custody, and is a retained value
target rather than a segregated balance: the sweep keeps `F + R` in fun
custody and only sweeps above it, so retained fun yield replenishes whatever
native rounding consumed. Idle fun staking keeps the reserve liquid and stakes
only the liquid excess of at least one SUI; withdrawals still consume liquid
SUI first. Every native redemption of `n` MIST requests ceil pool tokens for
`n + 3` MIST at the conservative valuation, so an exact 1:1 `funSUI`
redemption, including one that redeems every active fun token in its
activation epoch before any reward, never draws on blast custody and never
aborts for want of an unearned reserve. Conversion is replaced by a
withdraw-and-restake recovery when its rate-derived floor-loss bound would
leave less than twice the native redemption margin. Recovery keeps the receipt
through its activation epoch and every safe-mode epoch so native withdrawal
cannot forfeit current or deferred rewards, then realizes it in a normal
current-rate epoch. If later redemptions
consume the buffer to the low-water mark, the vault unwinds the remaining
active fun stake. Future fun principal is delegated above the retained liquid
reserve, so a depleted buffer cannot permanently disable staking or yield.
The 0.1-SUI reserve makes deliberate depletion through repeated few-MIST
native rounding impractical. There is no public reserve top-up and no
administrative claim on it.

### Bootstrap and locked seed supply

`create` takes one owner seed `Coin<SUI>` of at least 1 SUI plus `R`, places
`R` in fun custody and the remaining bootstrap only in blast custody, mints one
`blastSUI` per bootstrap MIST, stakes the bootstrap in the same transaction,
transfers the complete minted `Coin<BLAST_SUI>` to `@0x0`, and shares the
vault. `create` returns nothing. The locked shares can never be redeemed or
removed, so `blastSUI` supply is permanently positive and the seed backing is
permanent protocol capital inside blast custody: it earns and retains its
pro-rata share of every reward, sweep, and redemption fee, and no user can
redeem it. The vault stores no duplicate locked-supply field; the treasury
total supply and `VaultCreated.locked_blast_sui` are sufficient.

Because supply never reaches zero, the package has no final-share drain, no
fee-free final redemption, no fun unwind on zero blast supply, no one-to-one
restart deposit, and no safe-mode mint exemption. Every user redemption is
partial against total supply and pays the current fee. Fun yield always has an
owner, so fun custody keeps staking and no orphaned yield can accumulate for a
first-depositor attack.

If the validator leaves the active set, refresh unwinds both ledgers separately
into liquid SUI, rejects new fun mints and new blast deposit requests, and keeps
both coin redemption paths, receipt cancellation, and donation live. A donation
remains liquid after unwind. An outstanding receipt cannot be claimed into an
unwind-only vault, but its native cancellation remains available. The vault
does not select another validator. Only the pool ID is stored; the framework's
canonical pool-to-validator mapping derives the validator address when it is
needed.

An inactive validator address can later register a new pool. Address membership
therefore does not authorize conversion or idle delegation by itself. Every
native stake request must return the vault's immutable pool ID or the complete
transaction aborts. If address reuse occurs before refresh observes departure,
the old pool remains on its conservative cached rate: both redemptions,
donations, funSUI mints, `sync`, and receipt cancellation stay live, while a
blastSUI request to the replacement pool is rejected. The operational path is
to call `sync` during departure and use a different address for a replacement.

### Redemption fee

The `Vault` stores `redeem_fee_bps`, initialized to 2. It applies to every
`blastSUI` redemption, rounds up, and remains in blast custody where it raises
the value of the remaining shares, which always include the locked seed
supply. There is no admin fee balance and no claim path. The active
`SuperAdminCap` may change it through the package version gate; the setter
rejects an unchanged value and any value above the immutable maximum of 100
bps, and emits the old and new rate. A 0-bps setting is the only fee-free user
redemption.

### Package-local authority

The package has its own `acl` module with a shared `ProtocolAuthority` and one
active `SuperAdminCap`. There are no routine administrators, role bits, or
transaction witnesses. Every privileged operation validates the supplied cap
ID against the registry, so a retired cap cannot act after a transfer. Root
rotation uses delayed transfer, cancellation, acceptance, and retired-cap
destruction. Acceptance returns the new key-only root cap for same-transaction
composition; `acl::keep` places it in the accepting sender's account. Package
initialization is the only direct key-only delivery because an initializer
cannot return a value. No other governance exists.

The shared `PackageAdmin` permanently holds this package's raw `Publisher` and
`UpgradeCap` with no release or borrow path. `wrap` validates both package
capabilities, shares the object, and returns nothing. Upgrade authorization,
irreversible policy restriction, package-version activation, and fee changes
require the active package-local `SuperAdminCap`; commit remains authorized
only by the matching native receipt. Additive is the strictest exposed
policy restriction. A dependency-only restriction is deliberately not
exposed: it would foreclose adding a rescue entry point if a defensive
invariant abort ever froze the vault, while additive still permits new code
beside the frozen path. One shared `PackageVersion` gates package
administration and every vault mutation.

The same offchain maintainer multisig may own this package's `SuperAdminCap`
and the launchpad `SuperAdminCap`, but they are separate onchain capabilities
in separate packages. Neither package's authority state or rotation affects
the other.

### Withdrawal guarantees

There is no pause and no administrative withdrawal path. Every redemption
enforces the caller's minimum output before it burns coins; a slippage abort
reverts atomically and can be retried.

An unclaimed blast deposit is self-custodial native stake inside its receipt.
The holder can cancel it without the shared vault or package version object.
Claim can wait indefinitely after activation; the receipt's own stake continues
to earn native rewards until it is claimed or cancelled.

## Rejected alternatives

- **One shared native position for both coins** with a virtual split. It
  required every fun transition to pass through blast pricing and made the
  final `blastSUI` holder a permanent yield recipient that could never exit
  while `funSUI` existed.
- **Reusing `blast_fun::acl`.** It would make the launchpad package a runtime
  dependency of the quote asset's upgrade path and couple two independent
  revocation registries.
- **A transferable package `UpgradeAdminCap`.** A bare owned object cannot be
  revoked without a registry; the local ACL already provides one.
- **Covering fun rounding from blast custody.** It moved blast principal on a
  path that only reserve retention needs.
- **Earning the reserve from the first rewarded epoch.** Until then a full
  `funSUI` exit converted in its activation epoch was a few MIST short and had
  to abort; seeding `R` from the owner makes every valid 1:1 exit live.
- **Walking the exchange-rate table backward to the latest entry.** The walk
  is bounded only by the number of consecutive safe-mode epochs, which the
  package does not control. The one-entry cache is bounded and conservative.
- **Returning the seed shares to the owner with a fee-free final exit and a
  one-to-one restart deposit.** It let the owner drain the bootstrap backing,
  left fun custody unstaked whenever blast supply was zero, and needed a
  supply-zero exemption from the stale-rate mint guard. Locking the seed at
  `@0x0` removes every zero-supply path.
- **A stored locked-supply field.** The treasury total supply and the creation
  event already record the amount; a duplicate would be a second source of
  truth.

## Consequences

- `funSUI` stays a stable SUI unit while staking rewards increase the
  `blastSUI` exchange rate.
- `blastSUI` yield is leveraged by the outstanding `funSUI` supply; it is a
  share of blast custody plus swept fun yield, not a second 1:1 receipt.
- The owner seed is permanently locked capital. Its pro-rata share of blast
  custody grows with every reward and fee but is never withdrawable by anyone.
- Delayed blast issuance prevents an epoch-boundary deposit from taking rewards
  earned by older blast or fun stake. The redemption fee remains an exit cost
  and a benefit to remaining holders; it is not the anti-sniping proof.
- A parked activated receipt can claim before a predictable external donation
  and share that donation as an existing holder. This is the ordinary timing
  exposure of a discrete reward injection, not native epoch-reward sniping.
  Operators should inject rewards atomically with their source when possible
  and avoid publicly scheduled large cliffs; a streamed reward design is
  required if large predictable distributions become a product requirement.
- One validator deliberately concentrates performance and inactivity risk.
  Automatic unwind preserves exits but not deposits.
- The active `SuperAdminCap` holds full code and fee authority within the
  current native policy. Its custody is a production
  security decision independent of the launchpad's.

## Verification

- Prove `funSUI` mint and redemption change fun custody and senior supply
  equally and never touch blast custody.
- Prove every sweep moves at most `A_f - F - R`, and every blast fee and
  native reward remains in blast custody.
- Test that `create` returns no seed coin and locks every bootstrap share at
  `@0x0`, that the locked supply and its backing remain after every
  redeemable share is burned, that repeated full user exits cannot drain the
  seed backing, and that fun custody keeps its native position throughout.
- Test receipt creation, key-only ownership, pre-activation claim rejection,
  claim at and after activation, multiple same-epoch receipts, stale-rate claim
  rejection, cancellation before and after activation, cancellation after
  validator removal, wrong-vault rejection, and the epoch-boundary
  reward-sniping model. Test blast exits from liquid, pending, and active
  positions, and that every coin exit pays the current fee.
- Test exact fun redemption from liquid, pending, active, safe mode, inactive
  validator, a full active-position exit after a reward sweep, and a full exit
  before any reward in the pinned framework rounding regression vector.
- Test that creation rejects a pool without a current-epoch entry, that a
  safe-mode epoch accepts a blast deposit request but rejects its share claim,
  while fun mints, both coin redemptions, and receipt cancellation stay live,
  and that the next normal epoch refreshes the cache and opens the claim.
- Drive the fun rounding buffer below its target, prove later deposits resume
  delegation, and prove an activated receipt that cannot convert survives its
  activation epoch, earns a complete reward epoch, is realized, swept, and
  restaked without an administrative transaction.
- Test the fee default, authorization, bounds, unchanged rejection, retention
  in blast custody, the 0-bps fee-free case, and the structural absence of any
  claim path.
- Test singleton-cap validation, delayed root transfer, retired-cap rejection
  and destruction, package-capability custody, and the upgrade flow.
- Replay emitted completed facts to reconcile both supplies, both custody
  ledgers, and the fee rate.
