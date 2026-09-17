# Blast Boosts

This directory groups the independently published Boost packages (leveraged
coins); it is not a Move package. `core` (Series1) owns venue-neutral policy
and accounting. Each adapter depends inward on the core and owns its venue
state, currency, package version, and capability custody. `products` is the
Blast-owned home of product tags, so every Boost coin type reads as Blast on
an explorer.

Read [the leverage implementation rules](../../docs/leverage-implementation-lessons.md)
before changing these packages. Current structure and behavior are
authoritative in each package's source, tests, manifest, and lockfile.
