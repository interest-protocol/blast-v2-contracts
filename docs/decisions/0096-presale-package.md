# 0096: Fixed-price presales in their own package

- Status: accepted
- Date: 2026-09-26

## Context

On 2026-09-26 the founder ruled that the presale is its own package, separate
from the launchpad, and has no bonding curve. A presale sells a creator's tokens
at fixed prices in tranches. Tranches can differ in price and time, and can be
limited to a whitelist. The founder asked that the contract support both
allocation modes (first come and pro rata), both delivery modes (a single claim
time, with or without vesting), and both minimum modes (a minimum raise, or
none). The founder then asked that a successful raise be paid to custom
recipients and, optionally, go partly into a DEX pool directly. The pool is on
Cetus or Bluefin, split by percentage, opens at a listing price the creator
sets, and its position is locked, with the creator earning the trading fees.

An earlier design grew the launchpad's opening round (ADR 0093) into a presale
that buys the curve. It never merged, and the launchpad's opening round stays
as ADR 0093 left it.

## Decision

**Package.** `sui/presale` (`blast_presale`) depends only on `blast_admin`. It
follows the launchpad's package pattern:

- a Publisher marker, `blast_presale::BLAST_PRESALE`;
- its own administration domain, `BLAST_PRESALE_DOMAIN`, with four single-bit
  roles: package admin (1), fee admin (2), treasury admin (4), and adapter
  admin (8);
- a `PackageVersion` that every entry point checks;
- a `PackageAdmin` for upgrade custody.

**Presale.** `presale::new<Token, Quote>` takes:

- one to eight tranches;
- an optional minimum raise (`min_raise`, zero for none);
- a claim time no earlier than the last tranche's end;
- the payout: `recipients` and an optional `Liquidity`;
- exactly the tokens the tranches sell plus the pool reserve (see below).

The sender is the creator. The presale snapshots Blast's current fee, and
`share` publishes it. Settings never change after creation, and the creator
has no further powers.

**Tranche.** A `Tranche` sells `tokens` for `quote` in total, so its price is
`quote / tokens`. Each tranche has:

- its own window, `[start_ms, end_ms)`;
- an allocation mode, `first_come` or `pro_rata`;
- an `Access`, which is one of two variants, so a wallet cap and a whitelist
  can never be combined:
  - `public_access(wallet_cap)`: anyone may commit, up to the cap per address,
    and zero means no limit;
  - `whitelisted(root, leaves)`: only the leaves of a Merkle whitelist may
    commit, each up to its own `max_quote`, where zero means no limit;
- an optional linear vesting period.

**Commit.** Buyers commit through `commit` for a public tranche, or through
`commit_whitelisted` with a leaf and its proof. Each call returns what the
tranche did not accept. A first-come tranche accepts until its Quote is reached,
and then fails with `tranche_sold_out`. A pro-rata tranche accepts everything.
Both modes clamp a commit to the address's remaining allowance under its cap.
What a commit adds must buy at least one token atom at the tranche's price;
otherwise it fails with `zero_purchase`.
Each buyer's commits add up in one position per tranche, kept as a dynamic
field on the presale.

**Payout.** Up to sixteen `recipient(destination, bps)` entries and the
optional liquidity share must sum to exactly 10,000. After Blast's fee, each
recipient and the liquidity get their share of the net raise, rounded down, and
the first recipient takes the remainder. Without recipients, the liquidity
share is the whole 10,000 and takes all of it. Each payment emits
`ProceedsPaid`.

**Liquidity.** `payout::liquidity<Token, Quote, Adapter>(Adapter, ...)` records:

- the pair;
- the adapter's witness type;
- its pool tier;
- the share;
- the listing price `listing_quote` Quote per `listing_tokens` tokens.

Only an adapter can construct its own witness. A presale accepts the liquidity
only for its own pair and only when the adapter admin has admitted that adapter
in `BlastPresaleConfig`.

- **Reserve:** at creation the creator deposits the pool reserve on top of the
  tranches' tokens. The reserve is the tokens that the liquidity share of every
  tranche's Quote buys at the listing price, rounded down.
- **At finalization, on success:** the pool keeps its share of the net raise
  and the tokens that share buys at the listing price, rounded down. The rest of
  the reserve goes back to the creator with the unsold tokens.
- **Failure or empty pool:** a failure returns the whole reserve to the
  creator. A success whose pool share buys no token sends that share to the
  creator. Either way, the presale then has no liquidity to hand off.
- **Handoff:** `take_liquidity<Token, Quote, Adapter>(Adapter, clock)` hands the
  pool's tokens, Quote, and terms to the named adapter once, from the claim
  time, so the pool opens when buyers can claim. It emits `LiquidityTaken`.

**Adapters (migrators package).** The migrators package, which already owns
Cetus and Bluefin pool creation and Blast's LP fee share, holds both presale
adapters under its existing `cetus::Witness` and `bluefin::Witness`.

- `cetus::presale_liquidity` needs the token's `TreasuryCap`. It reserves
  Cetus pool creation for the pair at the chosen tick spacing, as a launch
  start does, then returns the terms.
- `bluefin::presale_liquidity` checks Bluefin's tier bounds.
- `open_presale_pool` (per Cetus coin order) is permissionless. It takes the
  pool share, creates a full-range pool priced from those balances (the
  listing price), and seeds it with them:
  - on Cetus, with the reserved creation cap, burning the position through
    Cetus LP Burn;
  - on Bluefin, paying the caller's whole creation fee.
- The position is locked in a new shared `BlastPresaleVault` with no removal
  path, and the venue's residuals go to the creator (`PresaleVaultCreated`).
- `collect_presale_fees` is permissionless. It pays Blast's live LP share from
  `LpFeePolicy` for the token, rounded up, to the protocol destination, and the
  rest to the creator (`PresaleFeesCollected`).
- Presale pools have no auto-LP, rewards, buyback, or fee split.

**Finalize.** Once every tranche has ended, anyone may finalize. The raise is
each tranche's accepted Quote, capped at the tranche's Quote.

- If the raise is at least the minimum, the presale succeeds. Blast's fee,
  rounded up, goes to the fee destination the configuration holds at that
  moment. The recipients are paid, and the pool share waits for its adapter.
  Unsold tokens and the unused reserve go back to the creator.
- Otherwise it fails: every token goes back to the creator, and every commit
  becomes refundable.

**Claim.** Anyone may claim a buyer's position, and the tokens and Quote always
go to the buyer.

- After a success, a pro-rata refund is paid at once. Tokens vest linearly from
  the claim time over the tranche's vesting period, or unlock at the claim time
  when there is none.
- In an oversubscribed tranche, each position receives `committed × tokens /
  total` tokens and `committed × (total − quote) / total` back, both rounded
  down. The rounding dust stays in the presale.
- After a failure, a claim refunds the whole commit.
- A position that has paid everything is deleted.

**Whitelist tree.** Leaf `i` is
`blake2b256(0x00 || "blast-presale-whitelist-v1" || bcs(i: u64) || bcs(address) || bcs(max_quote: u64))`,
and an internal node is `blake2b256(0x01 || left || right)`.

- Proofs are positional: at each level the index's low bit says whether the
  running digest is the left child (0) or the right child (1). Pairs are not
  sorted.
- A level with an odd count pairs its last node with itself.
- Every proof has exactly `ceil(log2(leaves))` siblings, each 32 bytes long.
- `leaves` must equal the tree's leaf count, and `index < leaves` is checked.
- The leaf commits its own index, so padding cannot create a phantom entry.

**Policy.** A shared `BlastPresaleConfig` holds:

- the fee, at most 10%, which the fee admin sets;
- its destination, which the treasury admin sets;
- the admitted liquidity adapters, which the adapter admin sets.

Setting the current value is rejected. Each role getter is package-internal,
and `sui/presale/scripts/check_source_boundaries.sh` pins which role each
administrator action asserts.

**Events.** The presale package emits these inside the `blast_events::Event`
envelope:

- `PresaleCreated`, with every setting, including the tranches, the
  recipients, and the liquidity;
- `Committed`;
- `PresaleFinalized`, with the returned tokens and the pool's Quote and tokens;
- `ProceedsPaid`;
- `LiquidityTaken`;
- `Claimed`;
- `FeeSet`, `FeeDestinationSet`, and `AdapterSet`.

The buyer is named only in `Claimed`, where it can differ from the sender. The
migrators emit `PresaleVaultCreated` and `PresaleFeesCollected` directly, like
their other events.

## Alternatives considered

- **Presale inside the launchpad, buying the bonding curve.** The founder ruled
  that out: the presale is a separate product with no curve.
- **One allocation, delivery, or minimum mode.** The founder asked for both of
  each.
- **Owned receipts instead of positions.** A receipt cannot enforce a
  per-address cap or whitelist allowance, since an address can hold many.
- **Address-balance commits to avoid shared-object contention.** Caps and
  first-come fills need the running totals at commit time, so every commit
  writes the presale either way. Pro-rata tranches have no speed race, so a
  commit cancelled under congestion can simply be retried within the window.
- **Vesting through the util-contracts vesting package.** Vesting inside each
  position needs no extra object and no external dependency.
- **DEX code inside the presale package.** Venue dependencies belong in
  adapters, and the migrators package already has them.
- **Reusing the launch `LpVault`.** It is tied to a launch's creator cap, fee
  split, auto-LP, rewards, and buyback. A presale pool only pays Blast's share
  and the creator, so a small separate vault is simpler.
- **Opening the pool at finalization.** The creator gets unsold tokens back at
  finalization, before buyers can claim, and could sell them into a fresh pool
  first. Opening from the claim time closes that gap.

## Consequences

- Each commit writes the shared presale. A first-come tranche is a race among
  its buyers, which is inherent to that mode. Pro-rata tranches are neutral to
  timing and to wallet splitting, apart from any per-wallet cap.
- A creator can choose a claim time or vesting long after the sale. Refunds
  never wait: a pro-rata refund is paid right after finalization, and a failed
  presale refunds right away.
- Whitelist leaves do not include the presale ID, so whoever builds the tree
  does not need to know it. A proof works in any tranche that uses the same
  root, which is the same list by construction.
- Creation is permissionless. A hostile token or Quote affects only its own
  presale.
- A creator cannot cap the fee it agrees to at creation. The fee admin could
  raise the fee between the creator signing and the transaction executing, up
  to the 10% ceiling. That matches the launchpad's snapshot of trade fees at
  intake. `PresaleCreated` records the fee each presale took.
- Pro-rata dilution can reduce a small commit to zero tokens. That position
  still gets its refund, and claiming deletes it.
- A Cetus pool needs the token's `TreasuryCap` at creation to reserve the pool.
  A coin whose supply was fixed has no cap, so it can only use Bluefin.
- Opening can fail if Cetus's pool-manager role creates the pair's pool first,
  or if the venue stops registering the tier. The pool share then stays in the
  presale, and only a migrators upgrade could recover it. Launches accept the
  same venue-operator assumption (ADR 0088).
- The creator earns the pool's fees at the address that created the presale,
  and nothing can transfer that right.
- The SDK and indexer need the new types and events. The presale package is
  upgradeable through its own `PackageAdmin`, and the migrators through theirs.

## Verification

- Pure tranche tests cover:
  - constructor bounds and window edges;
  - the one-atom minimum purchase;
  - both fill modes, with sold-out and cap precedence;
  - owed tokens and refunds, including a conservation property over many
    commits;
  - vesting boundaries;
  - one-, three-, and four-leaf whitelist proofs and their negatives.
- Presale tests cover:
  - fee-policy roles, bounds, and no-op setters;
  - every creation, commit, finalization, and claim guard, each with its
    exact abort;
  - guard precedence pairs;
  - the success and failure payouts, including the fee snapshot and the fee
    rounding up;
  - refunds before the claim time, and a commit diluted to zero tokens;
  - vesting claims, and claims made for another buyer;
  - exact rounding dust after every claim;
  - eventless initialization.
- `sui/presale/scripts/check_source_boundaries.sh` pins the role each
  administrator action asserts. Changing a role, dropping an assert, or adding
  a witness-taking function makes it fail.
- Payout tests cover share validation, the reserve, the split with its
  remainder, and pricing at the listing price. Presale tests cover the
  recipients' payments and the pool's balances on success, and the handoff:
  once, from the claim time, to the named adapter only, after finalization,
  with the version checked first. They also cover a failure or an empty raise
  returning the reserve, an unadmitted adapter, a pair mismatch, a missing
  reserve, shares that miss the whole, and the adapter role.
- Migrators tests drive a mock adapter through the handoff into a
  `BlastPresaleVault`. They check the residuals paid to the creator, Blast's
  rounded-up LP share and the creator's rest, an empty collection that emits
  nothing, and a position without liquidity.
- The migrators source gate pins each presale route: its witness, the reserved
  Cetus cap, the coin order, the LP burn, the Bluefin creation fee, and the
  vault custody. The venue interfaces are link stubs, so a PTB-harness run of
  the real Cetus and Bluefin routes on forked bytecode is a release gate.
- Package administration and domain tests mirror the launchpad's.
- `python3 scripts/check_move_style.py` passes, and so does
  `sui move test --lint --warnings-are-errors` in `sui/presale` and
  `sui/migrators`.

## Sources

| Ref | Revision | Path |
| --- | --- | --- |
| FW | MystenLabs/sui `06734f6ff0af45d8632a14a4dc4b100197f6b1a2` (`sui/presale/Move.lock`) | `crates/sui-framework/packages/move-stdlib/sources/u64.move` (`mul_div`, `mul_div_ceil`); `crates/sui-framework/packages/sui-framework/sources/dynamic_field.move` |
