# 0142. Boosts uses launchpad governance

- Status: accepted
- Date: 2026-11-20

## Context

The launchpad and Boosts need the same Blast administrators and partner identities.
Leveraged vault holders also need to redeem and reduce risk during an emergency.

## Decision

Resolve the same admin, core treasury and partners packages as the launchpad. Reuse
its fee, treasury and cancellation grants. Each product owns its partner acceptance
list. The adapter pays earned protocol fees to the shared treasury destination.
Vault issuance, risk management and shutdown retain their Boosts roles.

Give each vault fee policy, NAV cap and order cap a separate fixed 48-hour notice.
Replacement starts a new notice. Cancellation remains available until execution.
Execution checks current policy and, for the order cap, current venue capacity.
Emergency shutdown and constrained checkpoint recovery remain immediate.

Use shared package custody and its scoped pause, unpause, upgrade and cancellation
roles. Issuance and minting start paused. Releasing deposits requires guarded
treasury and upgrade delays. Redemption and risk reduction remain available.
Retain the separate successor activation from ADR 0123 so a malformed generation
can be repaired while the previous code serves holders.

## Consequences

The new role identities and vault layout require fresh Boosts package identities.
Existing publication records describe the historical packages. Clients issuing
or minting must pass the adapter's shared package version. Role grants shared
with the launchpad take effect across both products.
