# 0132: Book funding settled inside a closed-market unwind

- Status: accepted
- Date: 2026-10-25

## Context

Audit A4 identifies funding settled by the venue's direct close that never
reaches the reserve, deficit or funding event stream. After ADR 0130 this also
affects protected shutdown's holder/reserve allocation: actual cash recovery
is exact, but the reserve used to split it can be stale.

## Decision

Follow the auditor's recommendation to book the net funding once before
adopting the closed checkpoint. Refine attribution for the actual venue close:
its cash movement combines funding, realized trading PnL, insurance and
collateral release. Neither that cash difference nor the ordinary unchanged-
position funding classifier identifies the funding component.

Capture the authenticated live account immediately before and after the direct
close. Preserve the exact direct-settlement checkpoint proof. Derive local
funding from the pre-close signed position, its held-side funding snapshot and
market rate, and the enabled settlement collateral price. Reuse the existing
venue funding calculation, including its credit-down/cost-up raw rounding.
The source of that calculation and the venue's close order is the reviewed
bytecode in `docs/research/aftermath-venue-bytecode-2026-09-20.md` (F5).

When stored-to-live history is attributable, net its signed raw funding with
the close's funding before converting to collateral atoms once and applying
the canonical reserve/deficit allocation once. Do not book the earlier
interval before closing: opposing sub-atomic amounts must cancel first.

When that history is unexplained, preserve the existing terminal exit policy:
emit `CheckpointDrifted` with the live pre-close checkpoint, establish it as
the accepted baseline, and book only the proven local funding. Do not invent
funding for unknown history or let it discard known local funding. A raw
funding amount that is too large before netting is distinct from unexplained
history; opposing gross amounts may still yield a representable net.

## Events and custody

`FundingSettled` records the single attributable interval and its explicit raw
funding, rounded amount and allocation totals. Its final checkpoint includes
the whole close; consumers must not infer funding from its cash difference.
On clean history its previous checkpoint is the stored checkpoint. After an
explicit terminal drift event its previous checkpoint is that event's live
baseline. A zero net still records the changed checkpoint with zero amounts.
`UnwindProgress` then records the completed direct close, with no market order.
Replay must process these events in emission order.

The updated reserve governs ADR 0130's protected split at finalization.
Protected starter funds and reserves remain physically locked, including
after all holder claims. No new withdrawal path, authority, storage, event
schema or public transaction signature is introduced. Market-order unwind
retains its existing funding and fill proofs in a separate completion helper.

## Limits and verification

This path adds no ordinary funding call or live oracle valuation: those calls
may be unavailable on a paused market. Venue freezes, settlement readiness,
insurance/liquidity restrictions and arithmetic limits can still block a
close. Unrepresentable net funding or reserve/deficit overflow aborts rather
than silently dropping a known charge or credit. Unknown historical changes
remain explicitly unreconciled, and the pre-entry limitation in ADR 0130
remains. Allocation protects actual recovery, not original capital.

Require both sides and funding directions, settlement-price selection, raw
venue rounding and one final atom conversion, offsetting intervals, deficit
allocation, unrelated close cash, drift attribution, event replay, protected
finalization/claims, repeated-close rejection and exact invalid-state errors.
The external call's source routing is mutation-tested because local venue
interfaces cannot execute it. Local tests and read-only live ABI checks are
not live venue execution proof or original-auditor acceptance. Release still
requires the existing venue execution and capability/cutover gates.
