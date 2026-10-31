# 0134: Delayed administration, pause, and a Table-backed ACL

- Status: proposed
- Date: 2026-10-31
- Amends: [0007](0007-acl-pause-and-versioning.md) (pause),
  [0032](0032-admin-authorized-upgrade-cap-custody.md) and
  [0034](0034-remove-premature-governance-cutover.md) (upgrades),
  [0097](0097-one-singleton-acl-with-typed-roles.md) (ACL storage)
- Supersedes: the 2026-10-28 canonical stack, which holds no user assets

## Sources

| Ref | Full commit | Repository |
| --- | --- | --- |
| `sui@06734f6` | `06734f6ff0af45d8632a14a4dc4b100197f6b1a2` | [MystenLabs/sui](https://github.com/MystenLabs/sui) |

A `Table` keeps each entry as a dynamic field, not inline
(`sui@06734f6:crates/sui-framework/packages/sui-framework/sources/table.move:26,44-45`).

## Context

An external risk register found:

- **R2:** no timelock on upgrades or on fee, treasury and creator
  administration. It asks for a 48-hour delay covering at least upgrades,
  `UpgradeAdmin` grants, fee shares, treasury destinations and creator-cap
  reassignment. The pause is exempt.
- **R3:** no pause. It asks for a pause on buy, sell and migration, which a
  hot or automated key may hold, before real assets are admitted.

Asymptotic's L-3 found the same gap for upgrades. Today every admin setter
applies in the transaction that signs it, and no package can pause.

The owner also asked for the ACL's admins to live in a `Table`.
`blast_admin` is immutable, so that needs a fresh publish of every package
that links it.

## Decision

### Ship path

Publish a fresh stack: `blast_admin`, `blast_partners`, launchpad, presale and
migrators. Blast SUI and Boosts link the new `blast_admin` at their next
publish.

### One delay type

`blast_admin` gains a module that every package uses for delayed values. The
delay is a constant in the module, so no caller can shorten it.

```move
module blast_admin::delayed;

const DELAY_MS: u64 = 48 * 60 * 60 * 1_000;

/// A value whose changes wait DELAY_MS. No `drop`, so the storing
/// module cannot overwrite the field; it changes only through this module.
public struct Delayed<T: copy + drop + store> has store {
    value: T,
    pending: Option<Pending<T>>,
}

/// One scheduled value or action.
public struct Pending<T: copy + drop + store> has copy, drop, store {
    value: T,
    ready_at_ms: u64,
}

public fun new<T>(value: T): Delayed<T>;
public fun value<T>(self: &Delayed<T>): T;                          // no Clock
public fun pending<T>(self: &Delayed<T>): Option<Pending<T>>;
public fun schedule<T>(self: &mut Delayed<T>, value: T, clock: &Clock): u64; // ready_at_ms
public fun apply<T>(self: &mut Delayed<T>, clock: &Clock): T;       // aborts before ready_at_ms
public fun cancel<T>(self: &mut Delayed<T>): T;                     // the cancelled value
public fun set_now<T>(self: &mut Delayed<T>, value: T);             // authority-reducing changes only

public fun new_pending<T>(value: T, clock: &Clock): Pending<T>;
public fun take_ready<T>(self: Pending<T>, clock: &Clock): T;       // aborts before ready_at_ms
```

The applied value is a plain read, so `buy`, `sell` and claims need no
`Clock`. Scheduling again replaces the pending value and restarts the delay.

### Delayed setters

Every `set_<x>` becomes three functions. The treasury shows the shape; every
other delayed field below follows it with its own role.

```move
public fun schedule_treasury(
    self: &mut RuntimeConfig,
    package_version: &PackageVersion,
    _: &AdminWitness<TreasuryAdmin>,
    treasury: address,
    clock: &Clock,
); // emits TreasuryScheduled { treasury, ready_at_ms }

public fun apply_treasury(          // anyone, once ready
    self: &mut RuntimeConfig,
    package_version: &PackageVersion,
    clock: &Clock,
); // emits TreasuryChanged { treasury }

public fun cancel_treasury(
    self: &mut RuntimeConfig,
    package_version: &PackageVersion,
    _: &AdminWitness<CancelAdmin>,
); // emits TreasuryCancelled { treasury }
```

`CancelAdmin` is a new role held by the multisig. Revoking a compromised role
does not clear what it scheduled, and anyone can apply, so the multisig needs
its own stop.

The delayed fields:

```move
// launchpad
public struct RuntimeConfig has key {
    id: UID,
    creator_claim_signer_public_key: Delayed<vector<u8>>, // ClaimSignerAdmin
    protocol_fee_share_bps: Delayed<Bps>,                 // FeeAdmin
    treasury: Delayed<address>,                           // TreasuryAdmin
}

public struct LaunchConfig has key {
    id: UID,
    meme_decimals: VecSet<u8>,
    quotes: Table<TypeName, bool>,
    trade_fees: Delayed<TradeFees>,                       // FeeAdmin; was quote_fee_bps + meme_fee_bps
    migration_witnesses: VecSet<TypeName>,
    pending_witnesses: VecMap<TypeName, Pending<bool>>,   // AdapterAdmin admits
    protocol_allocation: Delayed<ProtocolAllocation>,     // TreasuryAdmin
    creation_fee: Delayed<u64>,                           // FeeAdmin
}

// presale
public struct FeePolicy has key {
    id: UID,
    destination: Delayed<address>,                        // TreasuryAdmin
    fees: Delayed<ProtocolFees>,                          // FeeAdmin
}

public struct Vault<phantom Meme, phantom Quote> has key {
    // ...
    protocol_fees: Delayed<ProtocolFees>,                 // FeeAdmin (LP-fee rates)
}

public struct CreationPolicy has key {
    // ...
    pending_witnesses: VecMap<TypeName, Pending<bool>>,   // AdapterAdmin admits
}

// migrators
public struct LpFeePolicy has key {
    id: UID,
    destination: Delayed<address>,                        // TreasuryAdmin
    defaults: Delayed<SharePair>,                         // FeeAdmin
    coins: Table<TypeName, Delayed<SharePair>>,           // FeeAdmin
}
```

Revoking the claim signer (an empty key) and removing an adapter use
`set_now` or remove at once, because they only take authority away.

`blast_presale::set_protocol_fees` stays immediate before a sale starts, but
may only set rates at or below the in-force `FeePolicy` rates.

### Upgrades

```move
public enum UpgradeAction has copy, drop, store {
    Upgrade(vector<u8>), // the package digest
    MakeImmutable,
}

public struct PackageAdmin has key {
    id: UID,
    custody: UpgradeCustody<BLAST_FUN>,
    pending: Option<Pending<UpgradeAction>>,
}

public fun schedule_upgrade(self: &mut PackageAdmin, package_version: &PackageVersion, _: &AdminWitness<UpgradeAdmin>, digest: vector<u8>, clock: &Clock);
public fun schedule_make_immutable(self: &mut PackageAdmin, package_version: &PackageVersion, _: &AdminWitness<UpgradeAdmin>, clock: &Clock);
public fun cancel_upgrade_action(self: &mut PackageAdmin, package_version: &PackageVersion, _: &AdminWitness<CancelAdmin>);

/// Aborts unless a ready Upgrade(digest) is pending.
public fun authorize_upgrade(self: &mut PackageAdmin, package_version: &PackageVersion, _: &AdminWitness<UpgradeAdmin>, digest: vector<u8>, clock: &Clock): UpgradeTicket;
/// Aborts unless a ready MakeImmutable is pending.
public fun make_immutable(self: &mut PackageAdmin, package_version: &PackageVersion, _: &AdminWitness<UpgradeAdmin>, clock: &Clock);
```

Launchpad, presale and migrators each get this. `commit_upgrade_and_advance` is
unchanged. `make_immutable` is delayed because it removes the only way to fix
code.

### Creator caps

```move
public struct Launch<phantom Meme, phantom Quote> has key {
    // ...
    pending_curve_fee_cap_recipient: Option<Pending<address>>,
    pending_metadata_cap_recipient: Option<Pending<address>>,
}

public fun schedule_curve_fee_cap_reassignment<Meme, Quote>(self: &mut Launch<Meme, Quote>, package_version: &PackageVersion, _: &AdminWitness<CreatorAdmin>, recipient: address, clock: &Clock);
public fun reassign_curve_fee_cap<Meme, Quote>(self: &mut Launch<Meme, Quote>, package_version: &PackageVersion, clock: &Clock, ctx: &mut TxContext); // anyone, once ready
public fun cancel_curve_fee_cap_reassignment<Meme, Quote>(self: &mut Launch<Meme, Quote>, package_version: &PackageVersion, _: &AdminWitness<CancelAdmin>);
// the same three for the metadata cap
```

The current cap holder can still claim curve fees during the 48 hours.

### Partners

`blast_partners::register` keeps its signature. A new partner starts at
0 bps and its requested share is scheduled with the package's existing 7-day
partner delay, so a new partner can never take a fee share at once.

### Role grants are immediate

`grant_role` and `AdminCap` transfers are not delayed (owner, 2026-10-31).
Every change a role can make to fees, destinations, creator authority,
adapters or code is delayed where it is made, so a new `UpgradeAdmin` still
waits 48 hours from scheduling a digest. That covers R2's `UpgradeAdmin`
grants.

### Pause

```move
public struct PackageVersion has key {   // launchpad; presale is the same with BLAST_PRESALE
    id: UID,
    generation: OperationalVersion<BLAST_FUN>,
    paused: u8,
}

const CREATE: u8 = 1;
const BUY: u8 = 2;
const SELL: u8 = 4;      // launchpad only
const MIGRATE: u8 = 8;

public fun pause(self: &mut PackageVersion, _: &AdminWitness<PauseAdmin>, bits: u8);     // sets bits only
public fun unpause(self: &mut PackageVersion, _: &AdminWitness<UnpauseAdmin>, bits: u8); // clears bits only
public(package) fun assert_not_paused(self: &PackageVersion, bit: u8);
// events: Paused { bits, paused }, Unpaused { bits, paused }
```

| Bit | Launchpad | Presale |
| --- | --- | --- |
| `CREATE` | `new`, `finalize`, `share` | `new`, `share` |
| `BUY` | `buy`, `join_opening_round`, `settle_opening_round` | `commit_open`, `commit_allowlisted`, `commit_uncapped` |
| `SELL` | `sell` | — |
| `MIGRATE` | `migrate` | `migrate` |
| Never paused | `deliver_opening_round`, fee claims | `claim`, `cancel_unlaunched`, `settle` |

`PauseAdmin` may be a hot or automated key; it can freeze but never move funds.
`UnpauseAdmin` is held by the multisig. A pause does not expire.

### Roles

Each package's `*_domain` module adds three roles:

```move
public struct PauseAdmin()
public struct UnpauseAdmin()
public struct CancelAdmin()
```

Migrators use the launchpad's roles and are not paused.

### ACL

```move
public struct ACL has key {
    id: UID,
    super_admin_cap_id: ID,
    admins: Table<ID, VecSet<TypeName>>, // was VecMap<ID, VecSet<TypeName>>
    pending_super_admin: Timelocked<Option<address>>,
}
```

Only storage changes. The functions, `AdminCap` and events keep their
behavior. `MAX_ADMINS` and its abort are removed; `MAX_ROLES_PER_ADMIN`
stays.

### Genesis

```move
// Move.toml [addresses], set before publish; 0x0 aborts init
blast_treasury = "0x…"           // RuntimeConfig.treasury, FeePolicy.destination
blast_lp_fee_destination = "0x…" // LpFeePolicy.destination
```

Destinations are correct from the first block, so nothing waits 48 hours
after publish. The root goes to the multisig, which grants roles at once.

### Never delayed

Claims of fees, rewards and refunds; pause, unpause and cancel; revocations;
quote and decimals allowlists; buybacks (their Meme is burned); reward rounds.

## Alternatives considered

- **Upgrade the 2026-10-28 stack.** Cannot change the immutable ACL.
  Rejected; the stack holds no assets.
- **`Timelocked<T>` for these fields.** Its reads need a `Clock`, which would
  change `buy`, `sell` and claims.
- **Delayed role grants.** Adds a second wait to powers that are already
  delayed, and holds back a new `PauseAdmin` in an incident. Rejected by the
  owner.
- **Pause that expires.** Needs a `Clock` on every paused path; the multisig's
  unpause is the release instead.

## Consequences

- No change to fees, destinations, creator authority, adapters or code takes
  effect within 48 hours of being publicly scheduled.
- Emergency fee or destination changes are gone; the pause is the emergency
  tool. A replaced claim signer stops account claims for 48 hours.
- Pausing `SELL` traps holders until unpause; claims and refunds stay open.
- The indexer reads `*Scheduled`, `*Cancelled`, `Paused` and `Unpaused`. The
  admin console reads the ACL's table entries instead of an inline map.
- SDK, indexer, web, workers and MVR rebind to the new packages; partners
  register again.

## Rollout

| Date | Milestone |
| --- | --- |
| 2026-11-02 | ADR accepted; `PauseAdmin` worker owner named |
| 2026-11-05 | `blast_admin` (`delayed`, Table ACL) and `blast_partners` |
| 2026-11-10 | Launchpad, presale, migrators |
| 2026-11-12 | `docs/llms`, SDK, indexer, admin console; pause worker; multisig signers |
| 2026-11-13 to 11-18 | Independent review of the diff |
| 2026-11-19 | Mainnet publish |
| 2026-11-20 | Rebind; first launch or presale may open |

Nothing opens before the rebind date; if a date slips, so does that gate.

## Verification

- `delayed`: apply before `ready_at_ms` aborts; reschedule restarts the delay;
  cancel clears it; `value` never changes before apply.
- Every delayed setter: schedule, early apply, apply, cancel, old package
  generation.
- `authorize_upgrade` and `make_immutable` abort without a ready matching
  action.
- Every pause bit stops its entry points; every never-paused path works with
  all bits set; `pause` cannot clear and `unpause` cannot set.
- ACL works past 32 admins.
- Publish aborts on a `0x0` destination.
- `check_move_style.py`, package gates and `gen_llms.py` pass.
