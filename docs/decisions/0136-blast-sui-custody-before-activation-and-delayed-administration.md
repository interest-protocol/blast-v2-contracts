# 0136: Blast SUI custody before activation and delayed administration

- Status: accepted
- Date: 2026-11-04
- Amends: [0053](0053-single-validator-funsui-and-blastsui.md) (redemption fee,
  package-local authority, withdrawal guarantees),
  [0061](0061-blastsui-routine-admin-and-composable-package-custody.md) (composable
  construct–attach–share custody)
- Follows: [0114](0114-launchpad-custody-before-activation.md),
  [0117](0117-presale-versioning-and-activation.md),
  [0134](0134-delayed-administration-pause-and-table-acl.md)

## Context

The Asymptotic launchpad audit (`audits/blast-launchpad-asymptotic-oct-2026.pdf`)
reviewed only `blast_fun`, but three of its findings describe `blast_sui` exactly:

- **L-1.** Publication shared a usable `PackageVersion` and left the Publisher and
  UpgradeCap with the deployer. `vault::create` needed only that version and the
  deployer-held treasury caps, so the vault could take deposits before custody was
  sealed, and a raw upgrade before intake would strand custody for the lineage.
  `add_capability` also accepted any object type with no removal path.
- **L-3.** `authorize_upgrade` and the fee setter applied immediately, so holders had
  no window to exit before new bytecode or a higher fee.
- **I-2.** `errors_tests` pinned every code, but nothing enforced that a new code is
  pinned.

A design review found one brick: `restrict_to_additive`. Under Sui's additive
policy an upgrade cannot change existing function bodies or constants, so
`PACKAGE_VERSION` stays fixed while `commit_upgrade_and_advance`, the only
finalizer, advances the generation. Every gated call, both redemptions included,
would then abort forever, and only receipt `cancel` would survive. The launchpad
already forbids policy narrowing for this reason.

A separate brick review of the vault against the pinned Sui framework found two
recoverable freezes worth closing in source. First, `assert_fun_backed` closes every
call, exits included, if fun custody ever falls below the funSUI supply, and every
entry point (including `donate_sui`, which credits blast custody) refreshes, and so
aborts, first. Second, the upgrade finalizer runs the outgoing bytecode: a PTB cannot call
the package its own `Upgrade` command creates. It therefore advances the generation to
the old bytecode's compiled next value. Bytecode that forgot to raise `PACKAGE_VERSION`
then rejects every gated call, and because authorization was itself gated, no bytecode
could install a fix. Bytecode with a wrong `NEXT_PACKAGE_VERSION` can never be finalized
again ([#169](https://github.com/interest-protocol/blast-v2-contracts/issues/169)).

## Decision

**Custody before activation.** `blast_sui_package::init` keeps the canonical
Publisher and initial generation in an owned, key-only `Publication` and shares no
`PackageVersion`. `package_admin::wrap` alone consumes it, together with the
never-upgraded UpgradeCap and both currencies' `MetadataCap`s. In the same
transaction it creates the receipt Display, seals all three child capabilities
under `PackageAdmin`, and shares `PackageAdmin` and a new `PackageVersion`. No
vault can exist before custody is sealed. `package_admin::new`, `add_capability`,
`share`, and the public `deposit_receipt::create_display` are removed.

**Delayed upgrades without narrowing.** `PackageAdmin` holds a
`DelayedAction<UpgradeKey, UpgradeAction>` with actions `Upgrade(digest)` and
`MakeImmutable`, starting at a 48-hour notice. `UpgradeAdmin` schedules,
`CancelAdmin` cancels even a ready action, and `authorize_upgrade` and
`make_immutable` consume only the matching ready action. Notice changes use the
slot's own schedule/apply path and wait the old notice. `restrict_to_additive` is
removed; no call narrows the policy. `NEXT_PACKAGE_VERSION` is derived as
`PACKAGE_VERSION + 1`, so no bytecode can compile a cutover target other than the
next generation.

**Repair without the generation.** A third action, `Repair(digest)`, installs code
without advancing the generation, so a release that kept `PACKAGE_VERSION` can be
corrected by bytecode that compiles the stored generation. `schedule_repair`,
`authorize_repair` and `commit_repair` read no package version, so they stay
reachable when every bytecode is stale. Each still needs `UpgradeAdmin`, the full
applied notice, the exact digest and sealed custody. `cancel_upgrade_action` also
reads no version, so `CancelAdmin` can stop a repair at any time. `authorize_repair`
sets a transient `repairing` flag that only `commit_repair` accepts and clears, and
`commit_upgrade_and_advance` rejects it. So an `Upgrade` authorization always
advances, and only a disclosed repair can install code without advancing. A repair
does not retire the bytecode it replaces when that bytecode still matches the
generation; it is meant for a package in which none does.

**Delayed redemption fee.** `Vault.redeem_fee` is a
`blast_admin::delayed::Delayed<RedeemFeeKey, u64>` created with the compiled
2-BPS default and a 48-hour notice. `FeeAdmin` schedules a fee (at most 100 BPS)
and its next notice; anyone applies it after the applied notice; `CancelAdmin`
cancels. Redemptions read the applied value without a Clock. The immediate setter,
`ERedeemFeeUnchanged`, and `RedeemFeeChanged` are removed; `blast_admin` emits
the lifecycle facts, keyed by the vault ID.

**Deposit-only pause.** `PackageVersion` carries three pause flags, one each for
`mint_fun_sui`, `request_blast_sui`, and `claim_blast_sui`. `PauseAdmin` sets
flags immediately. `package_admin::unpause` (`UnpauseAdmin`) clears them only while
the upgrade and fee notices are both nonzero with no pending change to zero. `wrap`
shares the version with every flag set. Redemptions, receipt cancellation,
donations, `top_up_fun_reserve`, `sync`, and `create` never read the flags, so the
withdrawal guarantee is unchanged: exits never pause. A paused claim strands
nobody, because `cancel` needs neither the vault nor the version.

**Fun-reserve recovery.** `vault::top_up_fun_reserve` adds SUI to fun custody
without refreshing, minting, or delegating. If fun custody ever falls below the
funSUI supply, anyone can cover the gap in one call and every exit reopens without
an upgrade. Any excess above the supply plus the reserve moves to blast custody at
the next refresh.

**Unusable rate entries.** An exchange-rate entry with a zero component counts as
missing, exactly like a safe-mode epoch. Native pricing would value such an entry at
one MIST per pool token, possibly below the cached rate, which could trip the fun
backing check. `create` rejects it, and refresh keeps the cached rate.

**Gates.** The source-boundary script pins the publication path, the delayed
upgrade slot and its exact actions, the absence of policy narrowing, pause scope
and release, and that every public function receiving the version checks it first.
A ported error-registry gate, with a self-test, requires sequential codes and
exactly one literal pin per code. Event fields that named a delta like a balance
are renamed: `BlastSuiDepositClaimed.claimed_pool_tokens`,
`FunYieldSwept.swept_liquid_sui`, and `FunYieldSwept.swept_pool_tokens`.

## Alternatives considered

- **A runbook alone for L-1.** It cannot stop the vault going live before custody.
- **Keep `restrict_to_additive`.** It is a self-brick, not a rescue path.
- **No pause.** With a 48-hour upgrade notice, a deposit-pricing bug would stay
  exploitable for two days. Pausing exits as well was rejected: holders must always
  be able to leave.
- **A zero initial fee notice with an unpause guard.** The genesis fee is compiled,
  so setup never needs a zero notice.
- **Ungated `authorize_upgrade` with a commit that skips the advance when the
  generation is already ahead.** `blast_admin` exposes no production read of the stored
  generation, and any stale bytecode could then install code silently without retiring
  the current one. A named, delayed `Repair` action discloses that intent.
- **Detecting validator-address reuse on chain.** The pinned framework exposes an
  active validator's pool ID only to test code (`validator_staking_pool_id` and
  `active_validator_by_address` are `#[test_only]`), so ADR 0053's operational
  mitigation (call `sync` during departure) stands.

## Consequences

The ABI changes for a fresh publication: `PackageVersion` is discovered in the
wrap effects, upgrade and fee administration take `Clock`, deposits start paused,
and error codes are renumbered. Off-chain tooling must decode the delayed-value
events for the fee and the action events for upgrades. Root, `UpgradeAdmin`,
`CancelAdmin`, `PauseAdmin`, and `UnpauseAdmin` custody must be recorded in the
deployment record (audit L-3/L-4 recommendations); `CancelAdmin` and `PauseAdmin`
belong with the independent multisig.

Residual risks that this decision does not close:

- An upgrade whose bytecode keeps `PACKAGE_VERSION` at the deployed generation still
  closes every gated call, user exits included, until a repair completes: at least the
  applied upgrade notice. The upgrade runbook requires the bump, and the same mechanism
  affects launchpad, presale and migrators, which have no repair path (#169).
- Validator-address reuse before any vault transaction observes the departure
  closes deposits on the old pool's cached rate (ADR 0053).
- Each refresh performs native work for both ledgers, so a native abort on one
  ledger blocks the other coin's exits until it clears.

## Verification

Move tests cover publication without a shared version, wrap sealing and pausing,
foreign-cap rejection, notice enforcement for upgrade, immutability and fee
changes, cancellation of ready actions, wrong-action rejection, notice changes, repair
scheduling, notice, cancellation and authorization with a stale generation, repair and
upgrade action separation, a repair commit without repair authorization,
pause scope, guarded release, exits while fully paused, and recovery of a frozen
vault through `top_up_fun_reserve`. `scripts/check_source_boundaries.sh` and
`scripts/test_error_registry.sh` run in `scripts/verify.sh`.

## Sources

| Short ref | Full commit |
| --- | --- |
| `sui@06734f6` | `06734f6ff0af45d8632a14a4dc4b100197f6b1a2` |

The test-only status of the pool-ID lookups is at `sui@06734f6`
`crates/sui-framework/packages/sui-system/sources/sui_system.move` (the
`#[test_only]` attributes on `validator_staking_pool_id` and
`active_validator_by_address`).
