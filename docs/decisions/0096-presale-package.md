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
none).

An earlier design grew the launchpad's opening round (ADR 0093) into a presale
that buys the curve. It never merged, and the launchpad's opening round stays
as ADR 0093 left it.

## Decision

**Package.** `sui/presale` (`blast_presale`) depends only on `blast_admin`. It
follows the launchpad's package pattern:

- a Publisher marker, `blast_presale::BLAST_PRESALE`;
- its own administration domain, `BLAST_PRESALE_DOMAIN`, with three single-bit
  roles: package admin (1), fee admin (2), and treasury admin (4);
- a `PackageVersion` that every entry point checks;
- a `PackageAdmin` for upgrade custody.

**Presale.** `presale::new<Token, Quote>` takes exactly the tokens its tranches
sell, one to eight tranches, an optional minimum raise (`min_raise`, zero for
none), and a claim time no earlier than the last tranche's end. The sender is
the creator. The presale snapshots Blast's current fee. `share` publishes it.
Settings never change after creation, and the creator has no further powers.

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

**Finalize.** Once every tranche has ended, anyone may finalize. The raise is
each tranche's accepted Quote, capped at the tranche's Quote.

- If the raise is at least the minimum, the presale succeeds. Blast's fee,
  rounded up, goes to the fee destination the configuration holds at that
  moment; the rest goes to the creator; unsold tokens go back to the creator.
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

**Fee policy.** A shared `BlastPresaleConfig` holds the fee (at most 10%) and
its destination. The fee admin sets the fee, and the treasury admin sets the
destination. Setting the current value is rejected. Each role getter is
package-internal, and `sui/presale/scripts/check_source_boundaries.sh` pins
which role each administrator action asserts.

**Events** (inside the `blast_events::Event` envelope): `PresaleCreated`
(every setting, including the tranches), `Committed`, `PresaleFinalized`,
`Claimed`, `FeeSet`, and `FeeDestinationSet`. The buyer is named only in
`Claimed`, where it can differ from the sender.

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
- The SDK and indexer need the new package's types and events. The package is
  upgradeable through its own `PackageAdmin`.

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
- Package administration and domain tests mirror the launchpad's.
- `python3 scripts/check_move_style.py` passes, and so does
  `sui move test --lint --warnings-are-errors` in `sui/presale`.

## Sources

| Ref | Revision | Path |
| --- | --- | --- |
| FW | MystenLabs/sui `06734f6ff0af45d8632a14a4dc4b100197f6b1a2` (`sui/presale/Move.lock`) | `crates/sui-framework/packages/move-stdlib/sources/u64.move` (`mul_div`, `mul_div_ceil`); `crates/sui-framework/packages/sui-framework/sources/dynamic_field.move` |
