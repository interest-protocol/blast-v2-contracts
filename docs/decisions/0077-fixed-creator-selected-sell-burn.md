# 0077: Fixed creator-selected sell burn

- Status: accepted
- Date: 2026-09-12
- Amends: [0021](0021-pure-constant-product-curve-quotes.md), [0024](0024-generated-coin-launch-ticket.md), [0026](0026-deferred-sell-burn.md), [0043](0043-versioned-launch-trading-and-atomic-migration.md), and [0051](0051-generated-meme-package-template.md)

## Sources

This record introduces no external ABI fact. It changes only Blast-owned admission and arithmetic.

## Context

The prior sell policy treated the ticket value as a maximum and scaled the actual burn from zero to that maximum with launch progress. That made the creator's selection difficult to explain and made identical sells use different burn rates at different points in the launch.

Generated Meme packages create their launch tickets inside their initializer. That path cannot borrow the shared `LaunchConfig`, so a later mutable configuration ceiling could make a previously generated ticket impossible to launch.

## Decision

The creator selects one immutable `sell_burn_bps` value when generating the Meme package. Ticket construction accepts values from zero through 5,000 basis points inclusive and aborts with `EInvalidSellBurnBps` above that hard ceiling.

Every sell applies that selected rate unchanged. Arithmetic remains fee-first:

1. reserve the Meme fee from gross Meme input, rounding up;
2. reserve `sell_burn_bps` of the post-fee input for pending burn, rounding up; and
3. price only the remaining effective Meme input on the curve.

For a gross input of 1,000, a 1% Meme fee, and a 50% sell burn, the fee is 10, pending burn is 495, and the curve prices 495. The percentages compound because burn applies after fee.

Deferred custody and terminal disposition from ADR 0026 do not change. `Sold.progress_bps` remains informational for compatibility and analytics. `Sold.burn_bps` records the fixed rate actually applied.

## Alternatives considered

**Keep the progress ramp.** Rejected because the configured percentage was only a maximum, not the rate a seller could directly understand.

**Store an administrator-updatable ceiling in `LaunchConfig`.** Rejected because generated-package initialization cannot safely read that shared object. Lowering the ceiling later could strand a valid existing ticket.

**Apply burn before the Meme fee.** Rejected because the protocol fee must be calculated from gross sell input; applying the fee first also makes fee revenue independent of the creator's burn selection.

## Consequences

- Creators can select any fixed rate through 50%; launchers cannot substitute it later.
- Sellers and interfaces can explain the deduction without a progress-dependent rate.
- No shared-object layout or event schema changes.
- A future configurable ceiling requires a ticket-version and liveness design before replacing the hard cap.

## Verification

- Launch-ticket tests cover zero, 5,000 bps, and the first invalid value 5,001.
- Curve tests pin fee-first fixed-burn arithmetic at partial, near-terminal, and terminal progress.
- The SDK preview and generated-package validator use the same formula and ceiling.
- Shared curve vectors record exact integer results and rounding directions.
