# Validate–Issue–Consume

Use this pattern when a durable capability grants authority only while it
remains valid against canonical live state, and downstream modules should not
depend on that capability or state directly.

## Authorization model

Let:

- `Authority` own the canonical registry, version, role, pause, and revocation
  facts.
- `AdminCap` be the durable object that claims a particular authority.
- `AdminWitness` be the ephemeral proof issued after validating the capability
  against the authority.

The core invariant is:

```text
an operation accepts AdminWitness
only if the authority-owning module could have issued it
after validating the exact durable capability against canonical live state
```

Seal witness construction inside the authority-owning module. Give the witness
`drop` only: it may be abandoned, but it cannot be copied, persisted, or used as
an owned object in a later transaction.

## Safe sequence

1. Borrow the exact `Authority` and `AdminCap`.
2. Check capability-to-authority identity, role, live registry membership,
   revocation state, and any issuance-time version or pause rule.
3. Construct the narrowest witness type that represents the validated action.
4. Pass that witness to the concern-owning module.
5. Consume it by value for one authorized operation, or borrow it only when
   deliberate same-PTB reuse is part of the authority model.
6. Keep mutation invariants and operation-specific version or pause gates at the
   consuming transition.

The consumer trusts the sealed witness type. It should not accept the durable
capability or repeat the capability-to-authority lookup, because that would
reintroduce the dependency this pattern removes.

## Scope the proof

- Prefer one witness type per authority level or action family. A
  `SetFeeWitness` must not authorize unrelated treasury or upgrade operations.
- Use a phantom type parameter when one sealed witness family needs compile-time
  domains and the type identity matches the intended upgrade boundary.
- Use a field-bound proof or separate witness types when authorization is tied
  to one object instance. A fieldless witness is safe only when every issuer
  grants equivalent authority over every consumer that accepts it.
- Never let a narrow durable capability mint a broader witness.

## Define the validity instant

By default, a witness proves that its capability was live when the witness was
issued. Decide explicitly what happens if revocation, pause, authority rotation,
or version activation occurs later in the same PTB.

- If issuance-time validity is sufficient, document that rule and keep the
  witness ephemeral.
- If a later change must invalidate the operation, issue and consume the witness
  inside one guarded function or recheck the relevant canonical fact at the
  consuming transition.
- Do not imply that a witness certifies unrelated economic state, target state,
  or mutation safety.

## Use and avoid

Use this pattern when several modules need the same live authorization decision
but should depend only on a small proof type. Prefer direct capability checking
when there is one consumer and no useful dependency reduction. Prefer a
persistent, explicitly bound authorization object when authority must survive
across transactions; an ephemeral witness cannot represent that lifecycle.

## Verification obligations

Test:

- a live capability bound to the correct authority;
- a capability from another authority or domain;
- a revoked, rotated, stale-role, paused, or wrong-version capability whenever
  those facts affect issuance;
- inability for another module to construct, copy, or store the witness;
- rejection of a narrow witness by broader consumers;
- one-shot consumption or intentional same-PTB reuse, matching the signature;
- same-PTB revocation, pause, and version changes at the documented validity
  boundary;
- ordinary mutation and economic invariants independently of authorization.
