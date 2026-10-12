# 0114: Launchpad custody before activation

- Status: accepted
- Date: 2026-10-12
- Amends: [0031](0031-package-witness-and-publisher-custody.md),
  [0032](0032-admin-authorized-upgrade-cap-custody.md)

## Context

Asymptotic L-1 identifies a deployment ordering failure: launchpad publication
previously shared a usable operational version before capability wrapping.
The deployer could use the platform, then upgrade through the raw native cap.
That cap would no longer pass the original-package/native-version-1 custody
check, permanently stranding the intended custody intake for that lineage.
The auditor offers an operator runbook or an owned bootstrap consumed by wrap.
The user selected Move enforcement of activation on 2026-10-12.

## Decision

The launchpad OTW claims the canonical Publisher and seeds the initial
`OperationalVersion<BLAST_FUN>` in one owned, key-only `Bootstrap`. Publication
shares no `PackageVersion`. Only `package_admin::wrap` consumes that bootstrap
and a native UpgradeCap. Shared custody first checks the Publisher's provenance,
the cap's original package ID, and native version 1. In the same transaction,
wrap seals both capabilities in `PackageAdmin` and shares the usable generation
in a newly created `PackageVersion`. Any failure rolls back the entire intake.

The OTW and linear generation value prevent a second bootstrap or version.
Neither bootstrap fields nor its package-only destructuring expose a public
activation or capability-release path. The new shared version receives a new
UID: Sui sharing requires creation in the current transaction, so the earlier
bootstrap UID cannot be reused. Existing custody events identify both native
capabilities; transaction effects identify the consumed bootstrap and new
shared objects. No additional event or stored activation flag is needed.

Launch creation and configuration setters already require `PackageVersion`.
Without it, a launch initializer cannot be constructed, so downstream launch
operations cannot start. `LaunchConfig` and `RuntimeConfig` may still exist
after publication; their presence confers no mutation authority. Coin-ticket
publication and pure helpers remain usable but cannot create a launch.
Governed upgrade authorization and atomic commit-and-advance remain unchanged.

## Alternatives

- Withhold `LaunchConfig`: gates launch creation, but leaves the existing
  operational version available to other guarded configuration operations.
- Share an inactive version plus an activation flag: adds mutable state and
  another condition to maintain when absence of the required object suffices.
- A runbook alone: cannot enforce the user's required on-chain ordering.

## Boundary and consequences

Sui creates the native UpgradeCap outside Move initialization. The deployer
still holds it until wrap, and Move cannot intercept a framework-native
upgrade authorized by it. Such an upgrade cannot activate through this
reviewed intake; it is not repaired by loosening validation. This design does
not constrain malicious replacement bytecode installed with a raw cap.

The fresh-publication ABI changes from `wrap(Publisher, UpgradeCap)` to
`wrap(Bootstrap, UpgradeCap)`. Deployers discover `PackageVersion` in wrap
effects rather than publication effects. This is a greenfield change;
upgrading an already-published package would not rerun its initializer and
would require a separately reviewed migration. Other products' bootstrap
policies and the separate L-5 stale-generation finding are outside this change.

## Verification

Move tests cover absent pre-wrap version, canonical bootstrap Publisher,
ownership, successful activation and unchanged custody/generation guards.
Native simulator PTBs publish real packages, reject a foreign cap with complete
rollback, consume bootstrap once, reject an already-upgraded cap, and exercise
normal launch creation after wrap. Source gates pin the sole activation path.
The deployment runbook records custody evidence rather than implementing the
activation boundary.
