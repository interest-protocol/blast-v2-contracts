# Protocol scope

Accepted ADRs in [`decisions/`](decisions/README.md) own committed protocol
behavior. Source and tests own what is implemented. This file owns only product
boundaries that are intentionally outside the current contract surface.

## Deferred

- Auction and Stable launch modes require approved economics and property tests.
- Existing-coin launches require supply, metadata, and burn authorities that
  satisfy the generated-currency invariants.
- Pause and migration-recovery paths require explicit user-exit, custody, and
  authority decisions.
- New settlement, referral, or allocation state requires a separately approved
  product and bounded accounting design.
- Non-Sui implementations must reproduce accepted observable behavior and
  shared numerical vectors without copying Sui storage or module structure.

## Admission rule

Do not add a mode, role, setter, adapter, stored field, or privileged recovery
path without a concrete product requirement and an accepted ADR defining its
authority, bounds, custody, lifecycle, events, and verification. Venue support
also requires immutable dependency and live-ABI evidence.
