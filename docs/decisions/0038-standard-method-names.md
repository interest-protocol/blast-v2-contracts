# 0038: Standard method names for reads, conversions, and wrapper destruction

- Status: accepted
- Date: 2026-08-25
- Amends: [0024](0024-generated-coin-launch-ticket.md), [0029](0029-composable-creator-identity.md), [0037](0037-remove-redundant-ticket-burn-mode.md)

## Context

Two package APIs used generic names that did not explain their semantics:

- `CreatorIdentity.fields()` returned a tuple projection for one caller; and
- `LaunchTicket.into_parts()` deleted the ticket UID and released its resources.

Those names make callers inspect implementations to learn what the method does.
They also diverge from the pinned Sui framework, where reads are normally named
for the value returned, `into_*` names an actual destination type, and consuming
wrappers use `destroy` when they delete themselves and release contents.

## Decision

Blast uses one method-naming rule:

- a read is named exactly for the domain value returned, with `is_*` or `has_*`
  for predicates;
- `into_*` is reserved for a real type conversion and names its destination;
- a consuming wrapper that deletes itself and returns contained resources uses
  `destroy`; and
- state changes use their specific domain verb.

Accordingly, `CreatorIdentity` exposes `creator()` and `x_identity_hash()`, and
`LaunchTicket` exposes `destroy()`. Generic names such as `fields`, `parts`,
`data`, and `info` are not production APIs.

The existing `<event>_fields` helpers are a narrow test-only exception. They are
the established package convention for snapshotting private event payloads, and
Move does not support overloading a single field getter across the many event
types. They do not enter production bytecode.

## Consequences

- Call sites state which identity value they read.
- Ticket consumption follows framework wrapper vocabulary.
- Genuine conversions such as `CreatorIdentity.into_authority()` remain clear.
- New generic projection or decomposition methods fail the structural gate.

## Verification

- Launch-ticket tests exercise both identity variants through the field-named
  reads and consume tickets through `destroy()`.
- Source-boundary checks reject `fields` and `into_parts` function or method
  names.
- Build, warnings-as-errors lint, full tests, and source-boundary checks remain
  release gates.
