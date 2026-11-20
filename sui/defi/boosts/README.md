# Blast Boosts

This directory groups the independently published Boost packages (leveraged
coins); it is not a Move package. `core` (Series1) owns venue-neutral policy
and accounting. Each adapter depends inward on the core and owns its venue
state, currency, package version, and capability custody. `products` is the
Blast-owned home of product tags, so every Boost coin type reads as Blast on
an explorer.

Read [the leverage implementation rules](../../../docs/leverage-implementation-lessons.md)
before changing these packages. Current structure and behavior are
authoritative in each package's source, tests, manifest, and lockfile.

## Where to read

- In the core, start with [vault state and lifecycle](core/sources/vault/).
  The vault uses [risk and fee policy](core/sources/config/) and
  [accounting and rebalance math](core/sources/math/).
- In the Aftermath adapter, start with [vault issuance and custody](aftermath_adapter/sources/vault/).
  Follow [trading operations](aftermath_adapter/sources/trading/) into
  [venue accounts, snapshots and checkpoints](aftermath_adapter/sources/venue/).
  [Package administration](aftermath_adapter/sources/config/) handles upgrades.
- The [core tests](core/tests/) and [adapter tests](aftermath_adapter/tests/) follow
  the same layout. End-to-end core scenarios are under [scenarios](core/tests/scenarios/).
