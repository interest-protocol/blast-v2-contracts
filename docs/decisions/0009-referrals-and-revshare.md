# 0009: Referral attribution and weekly RevShare settlement

- Status: proposed
- Date: 2026-08-22

## Sources

| Ref | Full commit | Repository |
| --- | --- | --- |
| `memez@00596fd` | `00596fdac4dd11f427c7bc594e566ce36160db93` | interest-protocol/memez-gg |

## Context

The historical design stored no per-trade referral state, but it did take `referrer: Option<address>` as
an argument on **every curve trade** and paid the referrer immediately in-transaction, funding the payment
by discounting the protocol share so the user's total never rose
(`memez@00596fd:fun/sources/structs/constant_product.move:73-99, 125-141`;
`memez@00596fd:fun/sources/structs/fees.move:122-168`).

So the real question is not "stored versus unstored". It is **immediate atomic payout versus off-chain
attribution with periodic settlement**.

## Decision

One production direction, in three parts.

**1. No referral identity or state in core, and no `referrer` argument in curve trades.** The curve ABI
never mentions a referrer. Because public function schemas are release commitments
(`../../AGENTS.md`), this is a permanent decision: a referrer argument added later would be a new
function, not a modified one.

**2. Off-chain attribution from campaign and session evidence.** A referral is established in the
backend's append-only attribution log — campaign id, referrer address, session id, observed sender, and
time window — which an indexer binds to on-chain trades. No custom signed message is created or verified,
and no on-chain trade carries referral data.

**3. A separate, bounded weekly RevShare package (`blast_fun_revshare`) using epoch Merkle roots and
claims.** Per epoch: one root, one claim bitmap, one funding balance.

### Bounds are fixed constants, checked at publication

"Bounded" is executable, not aspirational.

| Constant | Role | Enforcement |
| --- | --- | --- |
| `MAX_EPOCH_LEAVES` | maximum recipients in one epoch; fixes the claim bitmap at exactly `MAX_EPOCH_LEAVES` bits, allocated in full when the epoch opens, so per-epoch storage is constant and known in advance | `publish_root` aborts `ETooManyLeaves` when `leaf_count > MAX_EPOCH_LEAVES`; `claim` aborts `ELeafIndexOutOfRange` when `leaf_index >= leaf_count` |
| `MAX_EPOCH_FUNDED` | maximum quote value one epoch may distribute, capping the blast radius of a compromised root key | a deposit taking `funded_total` above the cap aborts `EEpochOverfunded`; `publish_root` aborts `EEpochOverfunded` when `claimable_cap > funded_total` or `funded_total > MAX_EPOCH_FUNDED` |
| `MAX_OPEN_EPOCHS` | maximum simultaneously unswept epochs, so the epoch collection cannot grow without bound | `open_epoch` aborts `ETooManyOpenEpochs`; an epoch must be swept or fully claimed to free a slot |

Proposed values: `MAX_EPOCH_LEAVES = 8_192`, `MAX_OPEN_EPOCHS = 8`, `MAX_EPOCH_FUNDED` set per quote
asset within a configured ceiling. **Proposed, not accepted.** The ADR records the storage cost each
implies — an 8,192-bit bitmap is 1 KiB plus the constant epoch header — so the number is chosen against a
measured cost rather than a guess.

An epoch that would exceed `MAX_EPOCH_LEAVES` or `MAX_EPOCH_FUNDED` is **split across multiple epochs**.
The epoch identifier is a **monotonic sequence number, not a calendar week**; "weekly" describes the
settlement cadence, not a one-epoch-per-week invariant. Stating this now avoids an
unbounded-by-accident design the first time a campaign outgrows the bound.

### Root authority

An epoch root is published under a dedicated `RootPublisherCap`, held by the protocol multisig and
separate from `AdminCap`. Publication requires the epoch to be funded first. A compromised publisher key
can misdirect at most one epoch's funding, which is why `MAX_EPOCH_FUNDED` exists and why funding is
per-epoch rather than pooled.

### What a root can and cannot prove

A plain Merkle root over claim leaves commits to a *set of leaves*. It does **not** let the contract
learn the sum of those leaves: verifying one inclusion proof reveals one leaf, and the contract never
sees the others. **A contract cannot check `sum_of_leaves == funded` against an ordinary root**, and this
ADR does not pretend otherwise.

Two mechanisms are specified; the second is the default.

**Option A — Merkle-sum commitment (stronger, more work).** Each internal node commits to
`H(left_hash ‖ right_hash ‖ left_sum + right_sum)` and each leaf to `H(recipient ‖ amount)` with
`sum = amount`. The root then carries a `root_sum` the contract can compare with `funded` at publication.
An inclusion proof supplies sibling `(hash, sum)` pairs, and verification recomputes both the hash chain
and the running sum, so a proof is valid only if the leaf's amount is consistent with the committed
total. Overflow in the sum path must be checked at every node, and the proof is larger.

**Option B — plain root plus a hard claimable cap (default).** The root commits only to claims. Safety
comes from the accounting invariant enforced at every claim, not from the root:

```text
publish:  claimable_cap <= funded_total                     // asserted at publication
claim:    cumulative_claimed + amount <= claimable_cap      // asserted at every claim
```

`claimable_cap` is recorded at publication and never raised afterwards. A dishonest or compromised root
can therefore **misdirect** value within one epoch — pay the wrong recipients — but it can never
**create** value: the package cannot pay out more than was funded, and a claim that would breach the cap
aborts `EEpochExhausted` regardless of a valid proof.

Misdirection is addressed by the challenge window and by the auditability of the off-chain input set, not
by arithmetic. That division of responsibility is stated here so no reader assumes the root is
trustlessly checked.

**Why B is the default.** The threat A additionally defends against is a publisher who inflates leaves
beyond funding — which B already makes unpayable. A converts "some claimants find the epoch exhausted"
into "publication fails", which is better operationally but does not change what an attacker can steal.
Adopt A if operational failure at claim time is judged unacceptable; the tests below cover both.

### Challenge and correction

Between publication and claimability there is a mandatory challenge window. During it the holder of
`RootPublisherCap` may **replace** the root; the superseded root becomes permanently unclaimable and the
replacement emits both the old and new root. After the window closes the root is immutable and claims
open. A root can never be replaced once a single claim has succeeded.

### Expiry and sweep

Each epoch carries an expiry. After expiry plus a stated delay, unclaimed funds sweep to a named
destination with an event. Sweep aborts before expiry (`ENotExpired`) and aborts if already swept
(`EAlreadySwept`). Sweeping frees the `MAX_OPEN_EPOCHS` slot.

### Dust

A leaf whose amount is below the configured claim threshold is not silently dropped. The epoch declares
its dust policy at publication — either the amount rolls into the next epoch's funding, or it is included
in the sweep — and the choice is emitted with the root so an indexer can reconcile without inference.

### Double-claim

A per-epoch claim bitmap of exactly `MAX_EPOCH_LEAVES` bits, keyed by leaf index, is checked before
payout. Re-claiming a set index aborts `EAlreadyClaimed`; an index at or beyond `leaf_count` aborts
`ELeafIndexOutOfRange`. The two are distinct errors because they are distinct bugs.

### Funding conservation

For every epoch, at every point in its life, in **quote atomic units**:

```text
funded_total = cumulative_claimed + swept + unclaimed_outstanding
claimable_cap <= funded_total                                  // asserted at publication
cumulative_claimed + amount <= claimable_cap                   // asserted at every claim
```

The first line is provable by reducing the epoch's events alone and is a required test. The second and
third are what actually bound payout: **the contract does not verify the leaf sum** (see "What a root can
and cannot prove"), so the guarantee is that the package can never pay out more than was funded, not that
the recipient set is correct.

### Sybil

Sybil resistance lives at the attribution layer — campaign configuration, session binding, and off-chain
heuristics — and this ADR says so plainly rather than implying the settlement mechanism addresses it. **A
Merkle root cannot fix a bad input set**; it only makes the input set auditable after the fact, which is
itself the reason for the challenge window.

## Alternatives considered

### Atomic per-trade payout — rejected

The historical mechanism. It is documented here for comparison and is **not** a second live baseline.

| Property | Atomic payout | Chosen design |
| --- | --- | --- |
| curve ABI | carries `referrer` forever | clean |
| new persistent state | none | bounded per-epoch |
| operator trust | none | root publisher, bounded per epoch |
| cross-launch aggregation | impossible | native |
| netting and thresholds | impossible | native |
| sybil defence | none — the referrer is whatever address the caller passes | attribution layer, auditable |
| attribution for off-chain referrals | impossible | native |

Rejected because the ABI cost is permanent and the sybil position is indefensible. What would change this
decision: if off-chain attribution cannot be operated reliably, atomic payout returns as the only
trustless option — at the price of a permanent referrer argument.

### Direct batch payouts — rejected

The publisher pushes payments to every recipient. No claim state and no bitmap, but the transaction is
O(recipients), it fails wholesale on one bad recipient, and it forces the protocol to pay gas for users
who may never care. It also cannot express a challenge window, since payment is the publication.

### Balance-table accumulator — rejected

A `Table<address, u64>` credited as fees accrue. It reads simply, but the table **grows without bound**
across the protocol's lifetime, which `../../AGENTS.md` prohibits, and it offers no correction path once
a wrong credit is written. This is the alternative that looks cheapest and is worst, so its rejection is
recorded explicitly.

## Consequences

- The curve stays free of referral concepts permanently.
- Settlement correctness depends on an off-chain indexer whose output is auditable only through the
  challenge window; the window is therefore a load-bearing control, not a formality.
- Campaign operators must fit within `MAX_EPOCH_LEAVES` per epoch or accept epoch splitting.
- Unclaimed value has a defined destination and a defined deadline.
- `blast_fun_revshare` holds funds and is separately governed, so its compromise cannot reach curve state.

## Verification

- Mechanism comparison matrix as above, with the rejection reason for each alternative.
- Full epoch replay: fund, publish, challenge, correct, claim, expire, sweep — reconstructed from events
  alone and reconciled against final state.
- Funding-conservation identity asserted after every operation in the sequence.
- Boundary tests at `MAX_EPOCH_LEAVES`, `MAX_EPOCH_LEAVES + 1`, `MAX_EPOCH_FUNDED`,
  `MAX_EPOCH_FUNDED + 1`, and `MAX_OPEN_EPOCHS + 1`, each asserting its exact named abort.
- Double-claim test and out-of-range-index test, asserting the two distinct errors.
- Challenge tests: replacement inside the window succeeds; replacement after the window aborts;
  replacement after any successful claim aborts; a claim against a superseded root aborts.
- Sweep tests: before expiry aborts; after expiry succeeds and frees a slot; twice aborts.
- Cap tests (Option B): publishing with `claimable_cap > funded_total` aborts `EEpochOverfunded`; a valid
  proof whose payout would breach `claimable_cap` aborts `EEpochExhausted`; `claimable_cap` cannot be
  raised after publication; and a sequence of valid claims summing to exactly `claimable_cap` all
  succeed while the next aborts.
- Sum-commitment tests (Option A, only if adopted): a proof with a correct hash chain but an inconsistent
  sibling sum is rejected; overflow at any internal node aborts; publication with
  `root_sum != funded_total` aborts.
- Misdirection test: a root paying an attacker-chosen recipient set is accepted by the contract and
  caught only by the challenge window — asserted explicitly, so the limit of the mechanism is a tested
  property rather than a footnote.
