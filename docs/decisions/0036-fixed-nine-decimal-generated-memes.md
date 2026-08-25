# 0036: Fix generated Meme precision at nine decimals

- Status: accepted
- Date: 2026-08-25
- Amends: [0002](0002-coin-creation-and-currency-authority.md), [0023](0023-generated-coin-supply-and-metadata-custody.md), [0024](0024-generated-coin-launch-ticket.md), [0035](0035-initializer-finalized-meme-supply.md)

## Context

ADR 0035 fixed the whole-coin supply at one billion but still let each generated
package pass a decimal precision to `launch_ticket::new`. That parameter creates
unnecessary variation in metadata, atomic supply, generated-package code, and
tests. Generated Blast memes have one canonical denomination: nine decimals.

## Decision

`launch_ticket::new` does not accept a decimals argument. It always creates the
currency with nine decimals and mints exactly:

```text
1_000_000_000__000_000_000 atomic units
```

The double underscore visually separates one billion whole coins from the nine
fractional decimal positions; it has no numeric effect.

The constructor then consumes the `TreasuryCap<Meme>` into the selected `Fixed`
or `BurnOnly` state exactly as specified by ADR 0035. Callers cannot select a
different precision or supply. Error code 61 is retired because an invalid
decimal value can no longer enter the API, and that code must not be reused.

## Consequences

- Every generated Meme has identical nine-decimal metadata.
- Every launch ticket begins with exactly one billion whole coins, represented
  by one fixed atomic-unit constant.
- Generated package initializers have one fewer argument and cannot accidentally
  disagree with protocol denomination policy.
- Decimal-range validation, overflow arithmetic, and their negative tests are
  unnecessary.

## Verification

- Fixed and burn-only ticket tests inspect the registered `Currency<Meme>` and
  assert nine decimals, the exact atomic supply, and the final supply mode.
- Ticket balance and creation event tests assert the same atomic supply.
- Structural checks reject a decimals parameter, require both canonical
  constants, keep the constructor as the sole mint site, and reject any surviving
  `TreasuryCap<Meme>` custody.
- Build, warnings-as-errors lint, full tests, and source-boundary checks remain
  release gates.
