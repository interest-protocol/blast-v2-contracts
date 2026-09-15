# 0028: Hot/cold runtime configuration consolidation

> Storage-type update (2026-08-28): [ADR 0044](0044-validated-basis-points-unit.md)
> wraps `protocol_fee_share_bps` in `Bps`; the public setter and event fields
> remain raw `u64` values.
> Version ownership update (2026-08-29):
> [ADR 0049](0049-audit-hardened-package-version-and-launch-intake.md) keeps
> `RuntimeConfig` limited to its two live settings and adds a separate shared
> `PackageVersion` singleton to avoid an ACL dependency cycle.

- Status: accepted
- Date: 2026-08-24
- Amends: [0001](0001-sui-package-and-module-layout.md), [0011](0011-event-schema-and-replay.md), [0015](0015-protocol-authority-and-x-signer-state.md), [0017](0017-coin-type-domain-for-x-creator-claims.md), [0018](0018-authority-module-separation.md), [0022](0022-dual-asset-fee-ledger-and-claims.md)
- Amended by: [0030](0030-singleton-event-identity.md), [0041](0041-launch-config-owned-trade-fees.md), [0049](0049-audit-hardened-package-version-and-launch-intake.md), [0058](0058-eventless-package-initialization.md), [0062](0062-table-backed-quote-registry.md), [0081](0081-separate-lp-fee-share-policy.md)
- Preserves: [0027](0027-graduation-economics-and-migration-witnesses.md)

## Sources

| Ref | Full commit | Repository |
| --- | --- | --- |
| — | No external ABI fact introduced | — |

This record changes Blast-owned storage and interface placement only.

## Context

The first accepted slices created one shared singleton per configuration
concern: `XClaimConfig` for the dedicated backend signer, `TradeFeeConfig` for
the live protocol fee share, and `LaunchConfig` for bounded launch-time policy.
That separation kept reviews local while the authorization and economic rules
were being fixed, but it also made the two smallest live values independently
addressable shared objects with separate initialization and discovery facts.

Shared-object count alone is not the target. A configuration seam should follow
how state is consumed. The X signer and protocol fee share are both small,
protocol-wide values whose updates apply immediately to the next relevant
operation. `LaunchConfig` is different: it owns one Table-backed quote registry,
one bounded migration-witness set, the trade-fee pair, and the graduation values
that are read together once and then snapshotted into a new
launch. `ProtocolAuthority` is not configuration at all; it is the live registry
for root and routine-administrator authority.

The repository has no committed Sui publication or deployment record. This is
therefore treated as a pre-publication storage and event correction. If a
deployment exists outside the repository, this decision requires an explicit
state-migration and old-version-gating record before release.

## Decision

### Three protocol-wide shared singletons

The core package initializes exactly:

1. one shared `ProtocolAuthority` for root rotation and routine-admin
   membership;
2. one shared `RuntimeConfig` for the two small live global settings; and
3. one shared `LaunchConfig` for cold policy snapshotted only at launch
   creation.

Future per-launch shared objects, external framework objects, and adapter state
are not protocol-wide configuration and are outside this count.

### Static typed runtime state

`runtime_config.move` owns:

```move
public struct RuntimeConfig has key {
    id: UID,
    x_claim_signer_public_key: vector<u8>,
    protocol_fee_share_bps: u64,
}
```

Initialization creates one shared object with an empty signer key and zero
protocol fee share. Those values retain their existing meanings: X claims are
disabled until an administrator supplies one valid 32-byte key, and publication
cannot silently begin taking protocol trade revenue.

The public mutation interface contains exactly three `AdminWitness`-gated
operations:

- set or rotate the dedicated X claim signer;
- revoke the X claim signer; and
- set the live protocol fee share from zero through 10,000 basis points.

The package interface verifies X claim activity and Ed25519 signatures and
returns the current validated protocol fee share. The configuration never
interprets creator identity, constructs `CreatorCap<Meme>`, accrues balances, or
stores launch policy.

The signer remains dedicated to the one X creator-claim message and transition.
Combining its storage with the fee-share scalar does not make it a generic
signer and does not let a signature authorize economic configuration. Both
public mutation domains already use the same transaction-local `AdminWitness`,
so the administrative compromise scope is unchanged.

### Cold launch policy remains separate

`LaunchConfig` keeps its Table-backed quote registry, independently bounded Quote
and Meme trade-fee rates, graduation defaults
(extended to a triple by [ADR 0033](0033-meme-liquidity-provision.md)),
migration witness set, six public mutations, and one package-only launch
snapshot. It does
not absorb the X signer or live trade-fee share. Every trade therefore reads a
small `RuntimeConfig`, while launch creation reads `LaunchConfig` once and stores
its immutable effective policy.

### No generic settings registry

The first release uses direct typed fields. It does not introduce dynamic
fields, arbitrary setting keys, byte payloads, generic getters/setters, a
policy-count registry, or speculative versioned policy wrappers. A future need
to add configuration after publication must make its own storage and upgrade
decision against the actual traffic and compatibility requirements.

### Events and replay identity

Under ADR 0058 neither singleton emits a creation payload: publication effects
establish both identities, the initial zero fee share and zero cold rates are
compiled constants, and the empty signer is an initialization invariant.
`XClaimSignerSet`, `XClaimSignerRevoked`, and `ProtocolFeeShareChanged` retain
their typed payloads without repeating the unchanging singleton id. There is no
generic `ConfigChanged` event, application sequence, schema version, action tag,
or nonce.

Each typed cold-policy mutation likewise carries only its changing entry identity
and old/new values. Indexers therefore retain two singleton replay scopes that
match the hot and cold shared objects.

## Alternatives considered

**Keep four concern-specific shared singletons.** Rejected: it preserves maximum
storage isolation but leaves two tiny live values with separate shared identity,
initialization, deployment discovery, and client configuration.

**Merge every setting into one static `ProtocolSettings`.** Rejected: each trade
would read the object that also stores both bounded launch-policy collections,
and unrelated cold-policy mutations would share the same object dependency as
all live trading and X claims.

**Use one dynamic-field settings root.** Rejected for the first release: typed
dynamic slots improve future extensibility but add lookup cost, missing/wrong
slot failures, generic storage invariants, migration mechanics, and a common
root dependency before those costs solve an observed need.

**Merge configuration into `ProtocolAuthority`.** Rejected: authority membership
and root rotation remain a distinct security module. Feature setters continue
to receive only `AdminWitness`, never ACL storage or capability identity.

## Consequences

- Protocol-wide shared singleton count falls from four to three.
- Deployment tooling and SDKs discover one runtime-config id instead of separate
  X-claim and trade-fee config ids.
- A rare signer or fee-share mutation shares one small runtime object with live
  reads in the other concern; this accepted coupling is bounded to two scalars.
- Launch-policy collection size and mutation remain outside the trading path.
- X authentication, fee splitting, launch snapshotting, and ACL membership
  remain independently testable through their concern interfaces.
- The former `XClaimConfigCreated` and `TradeFeeConfigCreated` payloads are
  replaced before publication by one `RuntimeConfigCreated` payload, which
  ADR 0058 then removes entirely.

## Verification

- Package initialization creates exactly one disabled, zero-share
  `RuntimeConfig` and, under ADR 0058, emits no event.
- Existing key-length, inactive, unchanged-key, rotation, revocation, old-key,
  expiry, message-domain, and signature tests pass through `RuntimeConfig`.
- Existing fee-share zero, 10,000, above-ceiling, unchanged, old/new event, and
  next-accrual tests pass through `RuntimeConfig`.
- One active `AdminWitness` can update both live concerns without passing ACL
  state into runtime configuration.
- `LaunchConfig` tests continue to prove independent cold snapshot behavior and
  bounded collections.
- Structural checks enforce exactly three protocol-wide `share_object` calls,
  keep ACL and launch policy out of `runtime_config.move`, and reject the retired
  shared config types.
- Build, warning-as-error lint, complete Move tests, coverage, event inspection,
  and `git diff --check` remain release gates.
