# Bind–Handoff–Redeem

Use this pattern when core state must release assets to one selected external
adapter without importing that adapter or allowing the handoff to escape the
transaction.

## Custody model

Let:

- the core select an adapter type while it still controls the transition;
- `Handoff` carry the released assets, origin, domain, and selected adapter
  identity;
- `AdapterWitness` be a value constructible only by the selected adapter;
- `redeem` consume the handoff and release its contents only after exact witness
  matching.

The linear custody invariant is:

```text
assets are either in core custody,
inside exactly one unredeemed Handoff,
or released exactly once to the selected adapter
```

Give `Handoff` no `copy`, `drop`, `store`, or `key`. It cannot be duplicated,
discarded, persisted, transferred as an object, or left unused at the end of a
successful PTB.

## Safe sequence

1. Validate the origin, economic domain, transition state, asset amounts, and
   selected adapter while core custody is intact.
2. Commit the core lifecycle transition and place every settlement asset and
   required fact inside `Handoff`.
3. Call the selected adapter in the same PTB.
4. Let the adapter construct its sealed `AdapterWitness` locally.
5. Consume `Handoff`, check the exact witness type, and release the contents.
6. Complete external settlement or abort, rolling back the core transition and
   handoff creation atomically.

## Bind adapter identity deliberately

- Admit only an audited, module-sealed witness type. Exact `TypeName` equality
  does not prove that construction is exclusive.
- Reject primitives, vectors, publicly constructible structs, and types with an
  unintended public constructor path.
- Choose defining-ID or original-ID type identity according to whether approval
  follows one concrete package generation or an upgrade lineage.
- Bind the handoff to the exact originating object and asset domain. Adapter
  identity alone does not prevent cross-pool or cross-market substitution.
- Decide whether creation-time approval is permanent for an existing handoff
  domain or whether redemption must also consult live revocation state.

The witness proves adapter identity only. It does not prove correct prices,
minimum output, destination ownership, venue state, or final settlement. Keep
every invariant that must remain under core control before handoff creation,
and validate synchronous results when the core depends on them.

## Event boundary

Emit a core redemption event only after the witness matches. Record the origin,
adapter identity, asset types, and released amounts needed to reconstruct the
core transition. Do not claim that external settlement completed unless the
core can observe that result. The adapter owns any event that asserts its venue
operation succeeded.

## Use and avoid

Use this pattern for volatile integrations such as exchanges, bridges, auction
venues, or settlement backends when same-PTB atomicity is required. Prefer a
direct call when the dependency is intentionally fixed and importing it does
not create an unwanted package boundary. Use a persistent request object with
explicit cancellation and recovery rules when settlement must span
transactions; a no-ability handoff cannot wait.

## Verification obligations

Test:

- the approved adapter and exact sealed witness;
- a wrong witness type and a publicly constructible candidate;
- wrong origin, asset type, amount, and economic domain;
- adapter abort and full rollback of core state and custody;
- attempts to copy, discard, store, transfer, or leave the handoff unused;
- creation-time approval and live revocation at the documented boundary;
- package-upgrade behavior for the selected type identity;
- truthful separation between core redemption and adapter settlement events.
