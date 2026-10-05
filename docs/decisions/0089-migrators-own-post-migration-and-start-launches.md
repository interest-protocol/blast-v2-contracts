# 0089: One migrators package owns everything after migration and starts every launch

- Status: accepted; amended by [0107](0107-partner-cut-of-lp-fees.md): a partnered launch's
  vault holds Blast's LP fees until anyone pays the partner its cut and Blast the rest
- Date: 2026-09-24
- Amends: [0076](0076-native-v2-and-auto-lp.md) (auto-LP),
  [0082](0082-revocable-creator-and-lp-fee-capabilities.md), and
  [0088](0088-reusable-launch-accounting-and-atomic-migration.md)
- Supersedes: [0057](0057-admin-pinned-venue-tiers.md) and
  [0075](0075-independent-holder-fee-distributor.md)

## Context

ADR 0088 put recurring LP-fee routing in the launchpad: a `FeeRouter` and its
`RouterConfigCap` per launch, and the shared `LpFeePolicy` whose share each
router froze at activation. Venue tiers were pinned by an administrator per
venue, a ticket was bound to its adapter in a separate step that lent the
treasury capability through a public `treasury_cap_mut`, and holder rewards
lived in a separate distributor package that destroyed the creator's
curve-fee cap to lock creator fees to itself.

The founder ruled on 2026-09-24:

- At launch the creator chooses the DEX, the pool fee tier, and how LP fees
  are split. Before graduation the team sets the curve trade fee and its
  creator/protocol split.
- The launchpad only holds those initial settings and hands them over at
  migration. Everything after migration belongs to the migrator contracts.
- Migrators, holder rewards, and auto-LP are one package, so nothing inside it
  needs transfer-to-object hops.
- Collection is permissionless and synchronous. One call collects the LP fees,
  pays Blast's share, and splits the rest into the creator's share, auto-LP
  added straight back to the pool, auto rewards, and direct recipients, with
  events that break every amount down for the indexer.
- The creator keeps the curve-fee cap. It claims the creator's share and
  changes the split. The administrator can change Blast's share per coin.
- The Cetus migrator burns the migration liquidity automatically.
- Launch construction follows the Coin Registry pattern: an initializer,
  setters, and a finalization that checks every invariant, with no general
  mutable treasury accessor.

## Decision

**Launch construction.** The generated Meme package's initializer still creates
the `LaunchTicket`, because only its one-time witness can register the currency.
The ticket is pure coin custody. An adapter's `new` (`cetus::new`,
`bluefin::new`) validates the creator's tier against its venue and calls
`launch::new` with its own witness and that tier, which returns a
`LaunchInitializer` with no abilities. The creator calls
`set_graduation_target`, `set_allocation_plan`, `set_lp_fee_split`, and
optionally `set_protection`. `finalize` is version-gated and checks every
setting, the symbol bound, the allocation policy, and the canonical one-billion
supply, then fixes the supply mode. The only `&mut TreasuryCap` borrow is
`LaunchInitializer::treasury_cap_mut`, which only the starting adapter's witness
unlocks: Cetus needs it to mint the Meme type's `PoolCreationCap` before any
Meme can leave the ticket.

**Initial settings.** The `Launch` stores the adapter witness, the
`(tick_spacing, fee_rate)` pool tier, and the `FeeSplit`, and emits them in
`LaunchCreated`. It never changes them. `FeeSplit` (in `allocation`) holds the
creator, auto-LP, and rewards shares and up to sixteen recipient
`(address, share)` pairs, summing to 10,000. It is validated when the launch is
created.

**Venue tiers.** Administrator tier pins and the Cetus compiled default are
removed. Cetus derives the fee rate from its own registry and rejects an
unregistered or disallowed tick spacing when the launch starts. Bluefin checks
a tier only when a pool is created, so `bluefin::new` applies Bluefin's bounds
(tick spacing 1–400, fee rate 1–20,000) up front. Each Meme type has one
launch, so `VenueConfig` keeps only the Meme type's Cetus `PoolCreationCap`.

**Cetus burn.** Cetus migration burns the full-range position through Cetus LP
Burn (`lp_burn::burn_lp_v2`, package version 8, linked to the same Cetus CLMM
version 15 the adapter pins), so Cetus itself records the liquidity as
permanently locked. The vault keeps the `CetusLPBurnProof`, which can only
collect fees and rewards. A burned position cannot receive liquidity, so Cetus
auto-LP adds to a second full-range position that the vault opens on its first
add and keeps with no removal path; collection collects both. Bluefin has no
burn primitive, so its auto-LP adds to the migration position, which the vault
already keeps with no removal path. The migrators link local interface stubs for
LP Burn and, for linkage only, its CLMM-vester and CETUS-token dependencies.

**Collection.** Anyone may call a venue's `collect_fees`. It collects the
position's fees. Blast's share, read live from
`lp_fee_policy::LpFeePolicy` (the coin's own pair if an administrator set one,
otherwise the default pair), goes to the protocol destination. The remainder
is split by the vault's `FeeSplit`:

- the creator share accrues in the vault until the launch's live curve-fee cap
  claims it;
- the auto-LP share is added back to the vault's position in the same call, at
  the pool's current price. The fixed side is chosen with Cetus's own liquidity
  math, and for Bluefin from the pool's and the position's bound sqrt prices
  with a two-atom margin. Whatever the pool does not take waits for the next
  call;
- the rewards share accrues in the vault for holder-reward rounds;
- each recipient is paid directly.

`FeesCollected` and `AutoLiquidityAdded` record every amount. The founder
accepted that a caller can move the pool price around a collection to skim part
of that call's auto-LP amount; frequent collection keeps each slice small.

**Split updates.** `settle_and_update_fee_split` settles the fees accrued under
the current split, then commits the next generation (`FeeSplitChanged`).
Only the launch's live `CurveFeeCap` authorizes it. The launchpad's
lock-to-custodian path is deleted: the creator always keeps a reassignable cap.

**Holder rewards.** `blast_holder_rewards` replaces the distributor package.
Blast's off-chain system builds a Merkle allocation from checkpointed holder
balances, and a Blast administrator publishes it with `publish_round`, which
reserves its budget from the vault's rewards balance into a shared `Round`.
Anyone can relay a proof, and each leaf pays its committed beneficiary once.
There is no enrollment, `PublisherCap`, pause switch, or separate package.

## Consequences

- The launchpad has no post-migration code path. Fee handling changes are
  migrators upgrades, which ADR 0088 keeps possible.
- Blast's share is not frozen per launch: an administrator change applies to
  the next collection of every affected coin.
- Split updates and creator claims take the shared `Launch` as a read-only
  input, so that the migrators check the curve-fee cap against the authority
  the launch honors.
- The auto-LP amount of one collection is exposed to price manipulation around
  that call.
- The launchpad, migrators, and generated-Meme ABIs change, the distributor
  package is removed, and events move as described. The SDK must be regenerated.
