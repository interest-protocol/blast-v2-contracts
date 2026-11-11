# 0136: Blast SUI custody before activation and delayed administration

- Status: proposed
- Date: 2026-11-10
- Amends: [0053](0053-single-validator-funsui-and-blastsui.md) (redemption fee,
  package-local authority, withdrawal guarantees),
  [0060](0060-blastsui-metadata-cap-custody.md) (capabilities move from `PackageAdmin` to the
  vault),
  [0061](0061-blastsui-routine-admin-and-composable-package-custody.md) (composable
  construct, attach and share custody)
- Follows: [0134](0134-delayed-administration-pause-and-table-acl.md),
  [0137](0137-shared-launch-stack-core-vault-and-venues.md)

## Context

The Asymptotic launchpad audit reviewed only `blast_fun`, but three findings describe
`blast_sui` exactly:

- **L-1.** Publication shared a usable `PackageVersion` and left the Publisher and
  UpgradeCap with the deployer, so a vault could take deposits before custody was sealed.
  `add_capability` also accepted any object type with no removal path.
- **L-3.** `authorize_upgrade` and the fee setter applied immediately, so holders had no
  window to exit before new bytecode or a higher fee.
- **I-2.** `errors_tests` pinned every code, but nothing enforced that a new code is pinned.

The package also built against a pinned pre-fold `blast_admin` source, so it could not bind
to the live administration package
([#223](https://github.com/interest-protocol/blast-v2-contracts/issues/223)).

Two recoverable freezes also needed closing in source. `assert_fun_backed` closes every call,
exits included, if fun custody ever falls below the funSUI supply, and every entry point
refreshes first. And a native exchange-rate entry with a zero component prices at one MIST per
pool token, possibly below the cached rate, which could trip that same check.

## Decision

**Generic administration.** The package adopts `blast_admin::package_admin` and
`blast_admin::package_version` typed by `BLAST_SUI_PACKAGE`, as the launch stack does. The
local `package_admin` module is removed. `init` keeps a `Publication` and shares no version;
`package_admin::wrap` consumes it with the never-upgraded UpgradeCap and shares
`PackageAdmin` and a fully paused `PackageVersion`. Upgrades are delayed by the generic 48-hour
slot. There is no repair action and no policy narrowing, matching 0137.

**Capabilities under the vault.** `vault::create` takes both treasury caps and both metadata
caps, creates the receipt Display, and seals the three non-treasury capabilities as children
of the vault. The generic `PackageAdmin` holds only the Publisher and the UpgradeCap, so the
product-specific capabilities live beside the state they describe. `create_display` is
package-only and has this one caller.

**Delayed redemption fee.** `Vault.redeem_fee` is a
`blast_admin::delayed::Delayed<RedeemFeeKey, u64>`, created with the compiled 2-BPS default and
a 48-hour delay. `FeeAdmin` schedules a fee (at most 100 BPS) and its next delay; anyone applies
it after the applied delay; `CancelAdmin` cancels. The immediate setter and its event are
removed. `blast_admin` emits the lifecycle facts, keyed by the vault ID.

**A guarded delay at creation.** The 48-hour initial delay applies to the first fee or delay
change and lets Blast release deposits as soon as the vault is created. `vault::unpause` still
refuses to release any bit while the delay is zero or a pending change would make it zero.

**Deposit-only pause.** `PackageVersion` carries three pause bits, one each for `mint_fun_sui`,
`request_blast_sui`, and `claim_blast_sui`. `PauseAdmin<BLAST_SUI_PACKAGE>` sets them
immediately. Redemptions, receipt cancellation, donations, `top_up_fun_reserve`, `sync`, and
`create` never read them, so exits never pause. A paused claim strands nobody, because `cancel`
needs neither the vault nor the version.

**Fun-reserve recovery.** `vault::top_up_fun_reserve` adds SUI to fun custody without refreshing,
minting, or delegating. If fun custody falls below the funSUI supply, anyone can cover the gap in
one call and every exit reopens without an upgrade. While fun custody holds active stake, the
top-up must exceed the gap by more than `fun_exit_low_water_mist` (61 MIST over the gap), so the
next refresh skips the protective unwind, whose rounding could drop custody below the supply
again. A smaller top-up loses nothing, and a larger one still recovers. Any excess above the
supply plus the reserve moves to blast custody at the next refresh.

**Unusable rate entries.** An entry with a zero component counts as missing, exactly like a
safe-mode epoch. `create` rejects it and refresh keeps the cached rate.

**Gates.** The source-boundary script pins the dependency, publication path, Display custody,
pause scope and release, and that every public function receiving the version checks it first.
An error-registry gate, with a self-test, requires sequential codes and exactly one literal pin
per code. `scripts/check_admin_delay.py` covers the fee's delayed value and the release.

## Alternatives considered

- **A runbook alone for L-1.** It cannot stop the vault going live before custody.
- **A package-local repair action.** 0137 removed repair and policy narrowing across the stack;
  one package carrying its own path would split the upgrade model.
- **A zero delay at creation.** This would require the deployer to set a nonzero delay before
  releasing deposits.
- **Pausing exits as well.** Holders must always be able to leave.

## Consequences

The ABI changes for a fresh publication: `PackageVersion` is discovered in the wrap effects, fee
administration takes `Clock`, deposits start paused, and error codes are renumbered. Off-chain
tooling must decode the delayed-value events for the fee. This decision assumes the package is
unpublished; that must be confirmed before merge.

Residual risks that this decision does not close:

- An upgrade whose bytecode keeps `constants::version!()` at the deployed version closes every
  gated call, user exits included. The upgrade runbook requires the bump, and the same mechanism
  affects the launch stack
  ([#169](https://github.com/interest-protocol/blast-v2-contracts/issues/169)).
- Each refresh performs native work for both ledgers, so a native abort on one ledger blocks the
  other coin's exits until it clears.

## Verification

Move tests cover publication without a shared version, a fully paused wrap, delay enforcement,
cancellation of a ready change, delay changes, version precedence on every mutator, pause scope,
guarded release, exits while fully paused, the paused deployment order, and recovery of a frozen
vault through `top_up_fun_reserve`. `create` has a direct test against a zero rate entry. Such
an entry is unreachable for refresh in `test_scenario`, so `math::is_usable_rate` has a unit test
and the source gate pins its use.
