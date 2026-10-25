# 0133: Require consumption of every order fill receipt

- Status: accepted
- Date: 2026-10-25

## Decision

Follow audit A5's recommendation: the private order-placement function returns
an ability-less `FillReceipt`. The private checkpoint proof consumes it and
returns the checked base and quote amounts. Mint/redemption, rebalance,
market-order unwind and both profit-realization legs must consume their
receipts. Removing a proof call must fail Move compilation.

Keep placement and proof separate: rebalance captures a plan-aware priced
observation, while the other paths use raw checkpoints. Profit realization
still rejects a partial fill before capturing its checkpoint. Preserve the
existing execution, notional, lot, direction and checkpoint checks; reduction
proof still accepts the venue's realized quote and allocated trading cash.

The current first-party source targets a fresh package lineage. Replace the
old droppable `Fill` rather than retaining the auditor's historical deployed-
upgrade workaround. This is not a compatible patch for that older deployed
package. External venue interfaces, transaction signatures, storage and event
schemas do not change.

## Scope and evidence

This prevents accidental omission of the proof. The defining module can still
be deliberately edited to unpack its own receipt or weaken its checks; the
type system does not verify the economics of a future rewrite. A source gate
restricts production construction and consumption to the intended functions
and checks that loop accounting uses the proven amounts.

Compile the actual adapter unchanged as a positive control, then separately
omit each of the four consuming calls in an isolated copy. Each omission must
fail for the receipt's missing `drop` ability. Exercise the consuming proof
with both sides, openings and reductions, changed trading cash, exact returned
amounts and mismatched base, quote or unrelated cash. Keep existing adapter,
downstream, ABI and source-boundary checks.

The receipt never leaves its module and adds no PTB result. Local venue ports
cannot execute a full exchange session, so these checks do not replace the
existing live-venue release evidence or original-auditor acceptance.
