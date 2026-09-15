# 0081: Separate LP-fee share policy with per-project pins

- Status: accepted
- Date: 2026-09-15
- Amends: [0022](0022-dual-asset-fee-ledger-and-claims.md),
  [0028](0028-hot-cold-runtime-configuration.md),
  [0044](0044-validated-basis-points-unit.md),
  [0054](0054-v3-dex-migrators-and-locked-lp-fees.md), and
  [0076](0076-native-v2-and-auto-lp.md)
- Preserves: [0062](0062-table-backed-quote-registry.md)

## Sources

| Ref | Full commit | Repository |
| --- | --- | --- |
| — | No external ABI fact introduced | — |

## Context

One `RuntimeConfig.protocol_fee_share_bps` split both bonding-curve trade fees
and every fee collected from a migrated liquidity position (the external venue
`LpVault` and the native `LockedLpVault`). The product needs these splits to
differ, and partner projects need a unique LP split that the protocol-wide
value cannot express.

The shared ledger also reached into launchpad trade configuration:
`fees::accrue_from_runtime(&RuntimeConfig)` was the only accrual seam available
to migrators, so an LP-fee split could only ever follow the trade share.

The repository has no committed Sui publication or deployment record. This is a
pre-publication storage and ABI change. If a deployment exists outside the
repository it requires a new state type, an authorized migration, and
old-version gating before release.

## Decision

### Two share objects

`RuntimeConfig.protocol_fee_share_bps` remains the live bonding-curve trade
share. A new launchpad singleton owns the LP-fee share:

```move
public struct LpFeePolicy has key {
    id: UID,
    protocol_fee_share_bps: Bps,
    project_protocol_fee_shares: Table<TypeName, Bps>,
}
```

Initialization shares one policy with a zero migrator-wide share and no project
pins, and emits no event (ADR 0058). Core therefore keeps five locally shared
protocol singletons.

The policy lives in the launchpad package, not in migrators, because both LP
custodians read it: `blast_fun_migrators` and the separately governed
`blast_fun_dex` share only `blast_fun` as a dependency, and protocol LP fees are
already claimed under `AdminWitness<LAUNCHPAD_DOMAIN>`.

### Effective share and project pins

`protocol_fee_share<Meme>(&LpFeePolicy): Bps` returns the project's pinned share
when one exists and the migrator-wide share otherwise. Pins are keyed by the
Meme's original `TypeName`, the fee identity since ADR 0022, so one pin applies
to whichever venue the project migrates to. A pin may be set before the project
launches or migrates, so its first collection already uses it.

The pin table follows ADR 0062: admin-only writes, one dynamic field per
project, no iteration, and no protocol cardinality cap. Clearing a pin removes
its child and makes the storage rebate recoverable. A pin on a Meme that never
migrates is inert and clearable.

### Mutations, guards, errors, and events

All three mutations take the launchpad `PackageVersion` and
`AdminWitness<LAUNCHPAD_DOMAIN>` and check the version first.

| Function | Rejects | Event |
| --- | --- | --- |
| `set_protocol_fee_share` | unchanged value (85), then out-of-range `Bps` (75) | `LpProtocolFeeShareChanged(u64)` |
| `set_project_protocol_fee_share<Meme>` | re-pin of the project's current value (86), then out-of-range `Bps` (75) | `ProjectLpProtocolFeeShareSet { meme, protocol_fee_share_bps }` |
| `clear_project_protocol_fee_share<Meme>` | project without a pin (87) | `ProjectLpProtocolFeeShareCleared(TypeName)` |

A first pin equal to the current migrator-wide share is a real transition
because it survives later migrator-wide changes.

### Ledger seam

`FeeLedger` stays the one embedded dual-asset ledger in `blast_fun::fees`.
Launch, `LpVault`, and `LockedLpVault` share its conservation, protocol
round-up split, and claim-authority rules, so moving or duplicating it would
add a deployment boundary or triplicate an invariant without a security gain.

`accrue_from_runtime` is removed. `fees::accrue(ledger, meme_fee, quote_fee,
Bps)` becomes public. `Bps` has no public constructor, so an external package
can only pass a share issued by a Blast policy object. `bps::value` becomes
public so collection events can record the applied share. Every other `Bps`
operation remains package-visible.

### Collections

Every migrators collection entry and `blast_fun_dex::migration::collect` takes
`&LpFeePolicy` in place of `&RuntimeConfig`. `LpFeesCollected.protocol_fee_share_bps`
and native `FeesCollected.protocol_share_bps` keep their layouts and now record
the effective share applied. It is the exact economic input of a
permissionless collection whose policy is the join of two replay streams.
Claim authority is unchanged.

## Alternatives considered

**Put the LP policy in the migrators package.** Rejected: the native DEX
migrator cannot read it without importing every external venue interface and
release gate.

**Store an optional share on each vault.** Rejected: it spans two vault types
in two packages, a pin can only be set after permissionless migration, so early
collections take the default, and administrators must locate each vault.

**Move the ledger into its own package or inline it per custodian.** Rejected:
a package adds a separate `UpgradeCap` custody for no boundary, and inline
copies duplicate the rounding and claim invariants.

**Key LP shares by Quote or venue.** Rejected: the requirement is one
migrator-wide share plus partner projects, and the Meme type is the project
identity.

## Consequences

- Trade and LP splits change independently; partner projects keep their pin
  through later migrator-wide changes until cleared.
- The LP default starts at zero, so LP fees accrue fully to creators until an
  administrator sets it. Deployment must set it deliberately.
- Every LP collection reads one more shared object, read-only, plus at most
  one dynamic-field lookup; mutations are rare administrator writes.
- Deployment tooling and the SDK discover a fifth core singleton, `lpFeePolicy`.
- Clients enumerate pins from the three replay events; the parent object alone
  does not list them.

## Verification

- `lp_fee_policy_tests` cover eventless zero initialization, default and pin
  events, boundaries, unchanged and missing rejection, `Bps` range delegation,
  version precedence over value checks, pin precedence, pin survival across
  default changes, clear fallback, and per-Meme isolation.
- Migrators vault tests prove the policy share is prospective, that another
  project's pin never reaches a vault, and that `LpFeesCollected` records the
  pinned share.
- DEX migration tests prove native collection applies the project pin while the
  trade share differs.
- The launchpad source boundary pins the `LpFeePolicy` layout, eventless
  initialization, three gated setters, five core singletons, and the reduced
  ledger surface.
