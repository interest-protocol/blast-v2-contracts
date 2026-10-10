# 0112: Daily holder-reward intervals

- Status: accepted
- Date: 2026-10-10

## Context

A daily reward period may be fully evaluated and skipped without publishing a
funded round. Requiring the next published interval to touch the previous one
would force later rewards to include skipped holding time. Holding cutoffs and
claim deadlines serve different purposes.

## Decision

Presale publication requires `previous published end <= new start < new end`.
Only funded publications advance the sequential round number. Authority,
funding checks, the 1–65,536 leaf bound, beneficiary proofs and claim bitmap
remain unchanged. Events preserve the actual interval. Publication tooling
chooses the full seven-day mainnet claim window from current preparation time,
including when recovering an old holding period.

## Alternatives considered

- Keep contiguous intervals: rejected because a skipped day is not part of the
  next day's holder allocation.
- Publish empty rounds for skipped days: rejected because a skip creates no
  funded custody and consumes no published number.

## Consequences

Existing roots and their intervals remain authoritative. This source change
requires a new presale publication: the deployed package's dependency-only
policy cannot change Move logic (ADR 0099). No live migration or deployment is
claimed. Existing vault compatibility and financial obligations require an
explicit cutover assessment before activation.

## Verification

The presale gate covers publication after a gap, sequential numbers, a full
independent claim window, beneficiary payment, actual close, and restored
vault balances. It rejects overlapping, empty and reversed intervals. SDK
operator tests cover initial and gap publication, exact interval preservation,
overlap rejection and a deadline based on current preparation time.

## Sources

| Ref | Source |
| --- | --- |
| S1 | Shared ingestion and outbox discovery D-025/D-033 and approved specification REQ-019/AC-016, 2026-10-10 |
| S2 | Existing publication and dependency-only policy: [presale package at 8a2c0fa2b0469ab229b0057089e462fe5943a5df](https://github.com/interest-protocol/blast-v2-contracts/tree/8a2c0fa2b0469ab229b0057089e462fe5943a5df/sui/presale) |
