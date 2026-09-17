# Blast leverage coins

This directory groups independently published leverage packages; it is not a
Move package. Series1 owns venue-neutral policy and accounting. Each adapter
depends inward on Series1 and owns its venue state, currency, package version,
and capability custody.

Read [the leverage implementation rules](../../docs/leverage-implementation-lessons.md)
before changing these packages. Current structure and behavior are
authoritative in each package's source, tests, manifest, and lockfile.
