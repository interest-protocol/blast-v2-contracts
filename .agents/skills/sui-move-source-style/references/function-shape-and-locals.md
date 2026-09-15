# Function Shape and Locals

Apply these rules when splitting or simplifying a multi-phase function,
extracting helpers, inlining locals, or changing pass-through parameters.

## Expose the transition shape

- Treat two independently nameable phases, or one phase-specific nested branch,
  as an extraction signal. A line count alone is not a boundary.
- Keep the owner function as an ordered transition summary. Extract cohesive
  phases into domain-named private helpers with the narrowest inputs and result
  that phase requires.
- Give each helper one phase, such as eligibility derivation, settlement
  preparation, accounting reconciliation, custody movement, or final cleanup.
- Preserve validation, borrow, evaluation, abort, mutation, asset movement, and
  emission order exactly. The owner function must expose the complete protocol
  sequence at a glance.
- Keep a phase inline when extraction would hide ordering, split one invariant,
  or add indirection without reducing the reasoning surface.
- Keep extracted helpers private unless a real package or public caller needs
  them. Tests use test-only seams rather than wider production visibility.
- Name helpers for their domain phase. Generic `handle_*`, `process_*`,
  pass-through, and arbitrary line-count helpers do not establish ownership.

## Keep meaningful locals

A redundant single-use temporary merely names one pure expression for one later
argument, condition, arithmetic operand, or return.

- Inline it only when its name adds no domain meaning and moving the expression
  preserves borrow lifetime, evaluation order, abort order, and mutation order.
- Keep a local when it is reused, names a unit or protocol role, freezes
  pre-mutation state for a later event, separates validation from mutation,
  narrows a borrow, or makes nontrivial arithmetic auditable.
- Keep reads on their original side of a mutation or external call. A later read
  may observe different state, and recomputing a proposed value after mutation
  weakens the audit trail.
- Construct a unit witness, one-off wrapper, direct getter, or immediate return
  at the call site when no intermediate invariant needs a name.
- Let assertion helpers validate. The owning transition reads and names its own
  pre-state instead of receiving it unchanged from an assertion helper.

## Remove empty relays

- Pass a value to another module only when that module validates, transforms,
  consumes, or stores it.
- Treat a witness, marker, or capability used for type-level authority as live.
  Name it `_` or with a meaningful `_role`.
- Remove an unread parameter from private code and from a signature already
  changing for another reason.
- Preserve a published or intentionally uniform forwarding signature when
  dropping the parameter would create compatibility churn. Keep it anonymous
  and document a non-obvious compatibility reason.

The refactor is complete only when the owner function still exposes execution
order, each helper owns one phase, every remaining local carries meaning or
ordering, and no parameter is an accidental relay.
