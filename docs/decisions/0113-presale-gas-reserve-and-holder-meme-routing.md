# 0113: Presale gas reserve and holder Meme routing

- Status: accepted
- Date: 2026-10-10
- Amends: [0099](0099-standalone-overflow-presale.md)

## Decision

A distinct `holder_rewards::BlastRewardRound` preserves old `Round` layouts
and proof domains while holding holder assets separately from a bounded Quote
gas reserve. Publication atomically funds both from the vault, stores the
governed fee-policy destination, and advances its number and holding end.
RewardsAdmin settles the reserve exactly once: reimburse a chosen amount no
larger than reserve, then return the entire remainder. The contract bounds
custody; trusted off-chain evidence determines eligible actual gas cost.
Permissionless actual close returns unclaimed holder assets and any unsettled
reserve, including after authority loss. Passing a deadline alone returns
nothing. Holder claims never consume gas custody.

Fee collection preserves protocol, partner and creator splits and rounding.
Only the holder Meme remainder is paid to the current governed fee-policy
destination; holder Quote accrues. Existing `FeesCollected` keeps its allocation
meaning; a new `BlastHolderMemePaid` records the exact payment and remaining
legacy unallocated balance. Reducers consume both in native event order.
RewardsAdmin can reconcile only an exact positive unallocated legacy Meme
balance to that governed destination. Already-funded roots and unresolved
commitments must be inventoried before preparation; reconciliation never
changes funded Round balances or proofs. No caller supplies a recipient.

## Compatibility and activation

The deployed presale package is dependency-only. New source bodies and types
require a new publication; they cannot change existing mainnet vaults in place.
Old close cannot accept the new round type. Old fee collectors can still reach
old vaults. Updating an SDK or adding a new-only guard does not disable them.
Safe migration of existing LP custody and outstanding obligations is unproven
and blocks activation. Existing roots retain their original claims and close
exits. A fresh lineage must grant its own ACL roles and verify its governed
policy equals intended Blast treasury before enabling financial execution.
This decision authorizes source implementation and rehearsal, no live sweep,
publication, upgrade, migration or payment.

## Alternatives

Adding reserve fields to old Round breaks published layout compatibility.
Storing reserve outside it lets an old close ignore custody. A treasury reward
leaf cannot return unused actual-cost reserve. Caller-selected recipients create
an extra authority seam. All are rejected.

## Evidence

Approved shared-ingestion/outbox specification E-006/E-007 and contract sections
5.1–5.3 own the behavior. The 2026-10-09 deployment record pins the presale
original/current package IDs, dependency-only policy and sealed cap. Local
Move/SDK/indexed tests verify source semantics; they are not live migration
proof.
