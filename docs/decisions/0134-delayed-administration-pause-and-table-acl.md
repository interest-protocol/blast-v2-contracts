# 0134: Delayed administration, pause, and a Table-backed ACL

- Status: proposed
- Date: 2026-10-31
- Amends: [0007](0007-acl-pause-and-versioning.md) (pause scope, now decided),
  [0032](0032-admin-authorized-upgrade-cap-custody.md) and
  [0034](0034-remove-premature-governance-cutover.md) (upgrade authorization
  gains a delay), [0097](0097-one-singleton-acl-with-typed-roles.md) (ACL
  storage, `AdminCap` abilities, delayed role grants)
- Supersedes: the 2026-10-28 canonical stack (`admin 0x4a27d8…`, `partners
  0x163a96…`, `launchpad 0x079a1b…`, `migrators 0x4a5d11…`, `presale
  0xb0279f…`), which holds no user assets (owner, 2026-10-31)

## Sources

| Ref | Full commit | Repository |
| --- | --- | --- |
| `sui@06734f6` | `06734f6ff0af45d8632a14a4dc4b100197f6b1a2` | [MystenLabs/sui](https://github.com/MystenLabs/sui) |
| `util@63b6cf8` | `63b6cf86c0e1a74f699610fe182b1de8d8789a14` | [interest-protocol/blast-util-contracts](https://github.com/interest-protocol/blast-util-contracts) |

- A `Table` stores each entry as a dynamic field of its own UID
  (`sui@06734f6:crates/sui-framework/packages/sui-framework/sources/table.move:26,44-45`),
  so entries are not listed inline in the owning object. `destroy_empty` needs
  an empty table and `drop` needs `V: drop` (`table.move:91,99`).
- `Timelocked<T>::value` takes a `&Clock`
  (`util@63b6cf8:sui/timelock/sources/blast_fun_timelock.move:52`).

## Context

An external risk register raised two findings against the launchpad and
presale:

- **R2.** No timelock on upgrades or on fee, treasury and creator
  administration. Required: a dated plan for a 48-hour delay on
  solvency-affecting admin actions, covering at least upgrades, `UpgradeAdmin`
  grants, fee shares, treasury destinations and creator-cap reassignment. The
  emergency pause is exempt.
- **R3.** No pause or circuit breaker. Required: a dated plan for a pause on
  buy, sell and migration, which may be held by a hot or automated key, before
  real assets are admitted.

Asymptotic's launchpad review (L-3, acknowledged) found the same gap for
upgrades: `authorize_upgrade` and `commit_upgrade_and_advance` apply a digest
in one transaction, and `blast_acl::grant_role` applies at once.

At `d82645c` every solvency-affecting setter applies in the transaction that
signs it. The only delays are the ACL's 7-day root transfer and partner share
changes. No package has a pause flag; ADR 0007 proposed one and
`docs/protocol-scope.md` deferred it.

The owner also asked that the ACL keep its admins in a `Table`.

`blast_admin` is published immutable (ADR 0097), and every admin setter takes
`&AdminWitness<Role>`, a `blast_admin` type. The ACL's storage, the
`AdminCap` abilities and the grant path therefore cannot change in place: they
need a new `blast_admin` and a new publish of every package that links it.

## Decision

### Ship path

Publish a fresh stack: `blast_admin`, `blast_partners`, launchpad, presale and
migrators. The 2026-10-28 stack is superseded, not upgraded. Other packages
that link `blast_admin` (Blast SUI, Boosts) link the new one at their next
publish; their own setters are outside this record.

### The delay

`ADMIN_DELAY_MS = 48 * 60 * 60 * 1_000`, a constant in each package. It is not
configurable.

Every delayed setter becomes three functions:

| Function | Caller | Effect |
| --- | --- | --- |
| `schedule_<x>(…, value, clock)` | the setter's role | stores `pending = { value, ready_at_ms: now + ADMIN_DELAY_MS }`, replacing any pending value and restarting the delay; emits `<X>Scheduled` with the full value and `ready_at_ms` |
| `apply_<x>(…, clock)` | anyone | aborts before `ready_at_ms`; writes the plain field, clears `pending`, emits the existing `<X>Changed` |
| `cancel_<x>(…)` | `CancelAdmin` | clears `pending` at once; emits `<X>Cancelled` |

- The pending value sits next to the field it changes, in the same object:
  `RuntimeConfig`, `LaunchConfig`, `FeePolicy`, `CreationPolicy`,
  `LpFeePolicy`, a `Launch`, a presale `Vault`, or `PackageAdmin`.
- The applied value is an ordinary field, so `buy`, `sell` and claims keep
  reading it without a `Clock`. `Timelocked<T>` is not used for these fields
  because its reads need one.
- `CancelAdmin` is a separate role held by the multisig. Revoking a
  compromised role does not clear what it already scheduled, and `apply` is
  permissionless, so the multisig needs its own way to stop a pending change.
  One role per action, as in ADR 0094.

The delay applies to **changing** fees, destinations, code and authority. It
never applies to claiming fees, rewards or refunds.

### Delayed actions

| Package | Action | Role |
| --- | --- | --- |
| launchpad, presale, migrators | `authorize_upgrade`: the digest must equal a ready `schedule_upgrade(digest)`; `commit_upgrade_and_advance` is unchanged | `UpgradeAdmin` |
| launchpad, presale, migrators | `make_immutable` | `UpgradeAdmin` |
| admin | `grant_role<Role>`, for every role | `SuperAdminCap` |
| launchpad | `runtime_config::set_protocol_fee_share` | `FeeAdmin` |
| launchpad | `launch_config::set_trade_fees`, `set_creation_fee` | `FeeAdmin` |
| launchpad | `launch_config::set_protocol_allocation` | `TreasuryAdmin` |
| launchpad | `runtime_config::set_treasury` | `TreasuryAdmin` |
| launchpad | `launch::reassign_curve_fee_cap`, `reassign_metadata_cap` | `CreatorAdmin` |
| launchpad | `runtime_config::set_creator_claim_signer`, when setting a key | `ClaimSignerAdmin` |
| launchpad | `launch_config::set_migration_witness_allowed`, when admitting | `AdapterAdmin` |
| presale | `fee_policy::set_fees` | `FeeAdmin` |
| presale | `fee_policy::set_destination` | `TreasuryAdmin` |
| presale | `presale_vault::set_protocol_lp_fees` | `FeeAdmin` |
| presale | `creation_policy::set_migration_witness_allowed`, when admitting | `AdapterAdmin` |
| migrators | `lp_fee_policy::set_protocol_destination` | `TreasuryAdmin` |
| migrators | `lp_fee_policy::set_default_shares`, `set_coin_shares` | `FeeAdmin` |
| partners | `register`: the partner starts at 0 bps in force with the requested share scheduled; `MAX_SHARE_BPS` is unchanged | `PartnerAdmin` |

Migrators are in scope because they hold the LP-fee treasury destination and
LP-fee shares; leaving them out would leave a hole in R2's coverage.

`make_immutable` is delayed because it removes the only way to fix code; a
compromised `UpgradeAdmin` could otherwise make a bug permanent.

### Immediate actions

| Action | Reason |
| --- | --- |
| `pause`, `unpause`, every `cancel_*` | Emergency controls |
| `revoke_admin`, `revoke_role`, `destroy_admin_cap` | Remove authority only |
| Claim-signer revocation (empty key), adapter removal | Remove authority only; existing launches keep their witness. A signer replaced after a compromise waits 48h, so creator-cap claims by account stop for two days |
| `blast_presale::set_protocol_fees` | Allowed only before the sale starts, and now only at or below the in-force `FeePolicy` rates |
| Fee claims, holder-reward rounds and claims, `settle_gas_reserve`, `close_round` | Claiming pays out under the rates and destinations in force and changes no setting |
| Buybacks (`BuybackAdmin`) | The bought Meme is burned, so no value reaches the key |
| Quote and decimals allowlists, `launch_config::add_partner` | Admit future launches only; partner shares are delayed at `register` |
| `grant_admin` | Creates a cap with no role; its roles still wait 48h |

### `AdminCap` is key-only

`AdminCap` drops `store`. With `store`, a holder could `public_transfer` a cap
that already holds `UpgradeAdmin` to anyone, instantly, which would make the
grant delay meaningless. Moving authority becomes revoke plus a delayed grant,
the same model as `SuperAdminCap`.

### Pause

Each of launchpad and presale keeps a `paused: u8` bitmask in its
`PackageVersion`. Every scoped entry point already takes `&PackageVersion`, so
the check adds no argument and no `Clock`:
`package_version.assert_not_paused(BIT)`.

| Bit | Launchpad | Presale |
| --- | --- | --- |
| `CREATE` | `launch::new`, `finalize`, `share` | `new`, `share` |
| `BUY` | `buy`, `join_opening_round`, `settle_opening_round` (it trades on the curve) | `commit_open`, `commit_allowlisted`, `commit_uncapped` |
| `SELL` | `sell` | — |
| `MIGRATE` | `migrate` | `migrate` |
| Never paused | `deliver_opening_round`, creator and protocol fee claims | `claim`, `cancel_unlaunched` refunds, `settle` |

- `pause(bits)` requires `PauseAdmin`, which may be a hot or automated key. It
  can only set bits.
- `unpause(bits)` requires `UnpauseAdmin`, held by the multisig. It can only
  clear bits.
- Both are immediate and emit `Paused { bits, paused }` or
  `Unpaused { bits, paused }`, where `paused` is the resulting mask.
- A pause does not expire. Expiry would put a `Clock` on `buy` and `sell`; the
  multisig's unpause is the release.
- Migrators' own value paths (LP-fee collection, auto-LP, buyback, reward
  rounds) are not paused. Changes to their fee settings are delayed as above.

Each consumer package declares `PauseAdmin`, `UnpauseAdmin` and `CancelAdmin` in
its `*_domain` module, as ADR 0097 requires for every role.

### Table-backed ACL

```move
public struct ACL has key {
    id: UID,
    super_admin_cap_id: ID,
    admins: Table<ID, AdminEntry>,
    pending_super_admin: Timelocked<Option<address>>,
}

public struct AdminEntry has store {
    roles: VecSet<TypeName>,
    pending_roles: VecMap<TypeName, u64>, // role -> ready_at_ms
}

public struct AdminCap has key {
    id: UID,
}
```

- `grant_role<Role>` becomes `schedule_role_grant<Role>`,
  `apply_role_grant<Role>` (anyone, after the delay; re-checks that the cap is
  live) and `cancel_role_grant<Role>` (`SuperAdminCap`).
- Pending grants live inside the admin's entry. `revoke_admin` and
  `destroy_admin_cap` drop them with the entry, and `revoke_role<Role>` also
  drops a pending grant of `Role`. A separate table keyed by cap and role could
  not be enumerated on revoke.
- `MAX_ROLES_PER_ADMIN` bounds `roles` and `pending_roles` together.
  `MAX_ADMINS` is removed, along with its abort.
- `sign_in`, grant and revoke cost the same however many admins exist.
- The ACL is a shared singleton that is never destroyed, so the `Table`
  emptiness rule never applies.
- Events add `AdminRoleGrantScheduled` and `AdminRoleGrantCancelled`;
  `AdminRoleGranted` now fires on apply.

### Genesis

With every grant delayed, the new stack is unusable for 48 hours after publish.
To keep that to one window:

- `runtime_config`'s treasury, `fee_policy`'s destination and `lp_fee_policy`'s
  protocol destination are set in `init` from `Move.toml` named addresses, as
  `blast_acl_root` is today. A `0x0` address aborts the publish.
- The root goes to the protocol multisig at publish. Every operational role
  grant is scheduled in the publish window and applies 48 hours later.

## Alternatives considered

**Compatible upgrade of the 2026-10-28 stack.** Timelock and pause state would
live in dynamic fields of existing objects, and old setters would abort in
favour of new entry points. It cannot change `ACL`, `AdminCap` or
`grant_role`, all in the immutable `blast_admin`, so it can deliver neither
the Table ACL nor the grant delay, and the transfer bypass stays. Rejected
because the stack holds no user assets.

**`Timelocked<T>` for every delayed field.** It needs a `Clock` on every read,
which would change `buy`, `sell` and every claim. Rejected for hot-path
fields; the ACL's root transfer keeps it.

**One delay for authority only, through the ACL.** Delaying role grants alone
leaves a granted `FeeAdmin` or `TreasuryAdmin` free to change rates and
destinations at once. Rejected: R2 names fee shares and treasury destinations.

**Pause with auto-expiry.** It bounds a griefing `PauseAdmin`, but needs a
`Clock` on every paused path. Rejected; the multisig unpauses and revokes.

**A `Table<RoleGrant, u64>` for pending grants.** Revoking an admin could not
find its pending grants. Rejected for per-entry pending maps.

## Consequences

- **Security.** No setter that changes fees, destinations, creator
  authority, adapters or code takes effect sooner than 48 hours after it is
  publicly scheduled. Users can exit before it applies. A compromised
  `PauseAdmin` can freeze trading but never move funds.
- **Operations.** Every routine change becomes schedule, wait, apply.
  Emergency fee or destination changes are no longer possible; the pause is
  the emergency tool. Rotating a compromised claim signer leaves account
  claims down for 48 hours.
- **User exit.** Pausing `SELL` traps holders until unpause; claims and refunds
  stay open in every state.
- **Indexing.** The indexer ingests `*Scheduled`, `*Cancelled`, `Paused`,
  `Unpaused`, `AdminRoleGrantScheduled` and `AdminRoleGrantCancelled`, and
  shows pending changes with their `ready_at_ms`.
- **Off-chain ACL reads.** The ACL no longer lists admins inline. The admin
  console (`admin-acl`) and SDK read the table's dynamic fields or rebuild state
  from events; the console's 32-admin limit goes.
- **Rebind.** SDK, indexer, web, Render workers and MVR move to the new package
  IDs; every partner is registered again.
- **Docs.** `docs/protocol-scope.md` no longer defers pause; `docs/llms` and the
  generated `llms-full.txt` describe the new calls.

## Rollout

| Date | Milestone | Exit criterion |
| --- | --- | --- |
| 2026-11-02 | This ADR accepted | Owner sign-off, including dates and the `PauseAdmin` worker owner |
| 2026-11-05 | `blast_admin` and `blast_partners` | Move tests with exact aborts: early apply, cancel, revoke drops pending, apply on a revoked cap, transfer of `AdminCap` impossible |
| 2026-11-10 | Launchpad, presale and migrators: delayed setters, upgrade delay, pause, per-sale fee cap | See Verification |
| 2026-11-12 | `docs/llms` and `gen_llms.py`; SDK ABI fixtures; indexer events; admin console Table reader | CI green in each repository |
| 2026-11-12 | `PauseAdmin` monitoring worker (owner, triggers, runbook); multisig ready for root, `UnpauseAdmin`, `CancelAdmin`, `UpgradeAdmin` | Dry run against a local fixture; signers and threshold documented |
| 2026-11-13 to 11-18 | Independent review of the diff | No open High or Medium |
| 2026-11-19 | Mainnet publish; root to the multisig; destinations from `init`; every role grant scheduled | Deployment record lists `ADMIN_DELAY_MS`, pause bits, role holders and source commit |
| 2026-11-21 | Grants apply; MVR, SDK, indexer, web and workers rebound | Canonical-publication gate checks the pause roles, `CancelAdmin` and `ADMIN_DELAY_MS` |

No launch or presale opens, and no quote or adapter is admitted, before
2026-11-21. If a date slips, this gate moves with it.

## Verification

- For every delayed setter: schedule, apply before `ready_at_ms` aborts with
  its named error, apply at `ready_at_ms` succeeds, reschedule restarts the
  delay, cancel clears it, and apply on an old package generation aborts.
- `authorize_upgrade` aborts for an unscheduled, unready or different digest.
- For every pause bit: each scoped entry point aborts while set and succeeds
  after unpause; every never-paused path succeeds with all bits set.
- `pause` cannot clear bits and `unpause` cannot set them; each role signs in
  to nothing else.
- ACL: grant, apply and revoke at more than 32 admins; revoke and destroy drop
  pending grants; `MAX_ROLES_PER_ADMIN` counts pending grants.
- `blast_presale::set_protocol_fees` aborts above the in-force rates.
- Publish aborts when any `init` destination is `0x0`.
- `scripts/check_move_style.py`, the package gates and `gen_llms.py` pass.
