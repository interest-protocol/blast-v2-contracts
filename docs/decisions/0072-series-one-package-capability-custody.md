# 0072: Series1 package-capability custody

- Status: **accepted**
- Date: 2026-09-03
- Amends: [0064](0064-aftermath-backed-leverage-coins.md) and
  [0070](0070-series-one-versioning-and-role-administration.md)

## Sources

| Short ref | Full commit | Repository |
| --- | --- | --- |
| `sui@06734f6` | `06734f6ff0af45d8632a14a4dc4b100197f6b1a2` | [MystenLabs/sui](https://github.com/MystenLabs/sui) |

## Context

Series1 now issues shared Vaults and therefore needs an explicit old-bytecode
and package-upgrade posture before any Vault holds value. Leaving the framework
`UpgradeCap` address-owned would let its key bypass the Series1 role registry
and exact-digest audit trail. Destroying the cap would prevent repairs and new
adapter-facing modules. The package `Publisher` is also a unique provenance
capability and must not remain in unrelated off-chain custody.

The framework makes an `UpgradeTicket` linear and binds it to one cap, package,
policy, and digest. A successful upgrade returns a linear receipt bound to the
same cap. Authorization temporarily clears the cap's package id, and commit
restores the new package id and advances its native version
(`sui@06734f6:crates/sui-framework/packages/sui-framework/sources/package.move:101-131,273-309`).
Upgrade policies become stricter as their numeric values increase; the
framework exposes compatible, additive, and dependency-only policies and
irreversible restrictions
(`sui@06734f6:crates/sui-framework/packages/sui-framework/sources/package.move:245-269`).

## Decision

Add a canonical `series_one::SERIES_ONE` one-time witness. Its module initializer
uses `package::claim_and_keep` only to create the package `Publisher`; it is not
the Vault currency witness. Vault currencies continue to use the non-OTW Coin
Registry path accepted in ADR 0071. The Publisher records its original package
and claiming module, and `from_module` checks both facts
(`sui@06734f6:crates/sui-framework/packages/sui-framework/sources/package.move:133-174`).

Add one key-only `PackageAdmin` that permanently owns the Publisher and
UpgradeCap inline. `package_admin::new` returns an unshared object after checking
that the Publisher came from `series_one::SERIES_ONE` and that the UpgradeCap
belongs to that type's original package id. A separate `share` function emits
the custody object's id, both capability ids, package id, native version, and
policy after the completed share. There is no capability release or mutable
borrow path.

Add `PACKAGE_ADMIN = 16` to the existing role bitmap. One `AdminCap` may hold it
alone or with any other Series1 role. The super administrator grants and revokes
it through the existing ACL. Governance can later hold the only role-bearing
cap without changing PackageAdmin or adding a governance flag.

`authorize_upgrade` checks the active operational version, requires
`PACKAGE_ADMIN`, requires an exact 32-byte digest, and asks the wrapped cap for
a ticket under its current policy. The event records the package id, native cap
version, policy, and digest. Authorization is immediate; any governance delay
belongs to the future custodian of the role-bearing `AdminCap`, not this core
module.

`commit_upgrade` checks the active operational version and commits the native
receipt into the wrapped cap. It takes no second role witness because the
linear receipt already proves a successful upgrade authorized by this exact
cap. A receipt from another cap is rejected by the framework. The commit event
records the new package id and native version transition.

`restrict_to_additive` and `restrict_to_dependency_only` check the active
operational version, require `PACKAGE_ADMIN`, and accept only a strictly more
restrictive policy. Both transitions are irreversible and emit the old and new
policy.

Native upgrade commit does not activate new Series1 operations. A separate
`activate_package_version` requires `PACKAGE_ADMIN` and calls the exact-next
operational transition accepted in ADR 0070. It deliberately does not assert
that the old shared version equals the newly compiled generation: the upgrade
transaction obtains its `AdminWitness` through the old active bytecode, then
the new bytecode advances shared state by exactly one. Old mutators fail closed
after activation.

## Alternatives considered

**Leave the UpgradeCap address-owned.** Rejected because the key could authorize
an upgrade without Series1 role checks or an application event.

**Destroy the UpgradeCap.** Rejected because Series1 intentionally remains an
evolving shared-state package; fixes and new adapter-facing modules would be
impossible.

**Let the super administrator upgrade directly.** Rejected because the root
manages role custody and does not bypass operational role checks.

**Require a role again when committing the receipt.** Rejected because the
receipt is already linear, same-transaction, and cap-bound. A second check adds
no authority and creates another failure point after successful publication.

**Store a governance mode or core delay.** Rejected for this generation.
Governance can receive exclusive custody of the administrative capability and
enforce its own delay without changing Series1 core state.

**Use the package OTW for Vault currencies.** Rejected because one package OTW
cannot issue multiple `Vault<AdapterRoot>` currencies and Coin Registry already
enforces one currency for each concrete Vault type.

## Consequences

- Raw package authority has one permanent on-chain custody location and no
  release path.
- A compromised package-role holder can authorize an immediate policy-compliant
  upgrade, so production custody of that role remains a deployment-security
  decision.
- The role holder may irreversibly reduce future upgrade flexibility.
- Package upgrade and operational activation remain separate, observable
  transitions.
- The package is still not publishable for value: activation, adapter handoffs,
  asset custody, financial operations, and shutdown remain incomplete.

## Verification

- Test Publisher and UpgradeCap provenance independently and in validation
  order.
- Test exact digest length, role precedence, stale-version precedence, native
  authorization, cap-bound commit, and complete events.
- Test both irreversible policy transitions and reject equal or looser policy.
- Test exact-next operational activation and wrong-role rejection.
- Pin the new role bit, abort codes, public API, capability ownership boundary,
  and package-version checks in source gates.
- Run testnet and mainnet builds, warning-as-error lint, all Move tests, source
  boundaries, and `git diff --check` with the pinned toolchain.
