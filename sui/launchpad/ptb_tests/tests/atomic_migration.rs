//! Programmable-transaction integration tests for launch creation, the atomic migration seam, and
//! the opening round.
//!
//! Every launch is opened by one PTB composed from public calls: the mock venue's `prepare` issues
//! the venue ticket, `launch::new` takes it with the launch ticket and the coin's `TreasuryCap`, the
//! launchpad setters configure the initializer, and `finalize` and `share` consume it, so the
//! ability-less venue ticket and initializer cross commands of one transaction.
//!
//! Two independent one-time-witness launches reach MigrationReady through public PTBs. Every
//! failing migration PTB must commit nothing (see `Harness::assert_rolled_back`): no allocation
//! reaches the launch ledger or the creator's recipient, and launch A stays migratable through the
//! whole failure matrix before completing in one successful PTB. The hand-off `launch::migrate`
//! returns and the owner proof `launch::prove_owner` returns have no abilities: a PTB that leaves
//! either unconsumed fails with `UnusedValueWithoutDrop` and commits nothing. Every launchpad event
//! is emitted directly, generic in the launch's coin types.
//!
//! A launch with an opening round shows the launch-owned bidder record the first bid creates, that
//! nothing trades or pays out before settlement, that every failing round call commits nothing,
//! the pot's one purchase at settlement, and the delivery that retires the record; each step's
//! storage cost is printed.
//!
//! LP-fee splits that sum to zero or name twenty-one routes abort in `blast_core`'s fee-split
//! constructor before the launch exists, while twenty routes commit unchanged into the launch. A
//! split with every destination kind and sixteen distinct address weights is measured at creation
//! and migration;
//! each record prints as one `LAUNCH_FEE_SPLIT_CAPACITY` JSON line with its margins to the
//! simulator's protocol limits. Recurring LP-fee collection and split updates belong to the
//! migrators and `blast_vault` packages.
//!
//! Run from `sui/launchpad/ptb_tests` with `cargo test` (needs the pinned `sui` on PATH).

use std::{collections::BTreeSet, time::Duration};

use anyhow::Result;
use blast_launchpad_ptb_tests::{
    ActionApplied, ActionScheduled, Change, CompiledPackage, Destination, Expected, FeeSplit, Harness, Outcome,
    GenericPackageVersionContents, RuntimeConfigContents, SetApplied, SetChange, SetScheduled,
    append_launchpad_unpause, build, call, launchpad_role, publish_stack,
};
use move_binary_format::{CompiledModule, file_format::Bytecode};
use serde::Deserialize;
use serde_json::{Value, json};
use sui_types::{
    SUI_CLOCK_OBJECT_ID, SUI_COIN_REGISTRY_OBJECT_ID, SUI_FRAMEWORK_PACKAGE_ID, TypeTag,
    base_types::{ObjectID, SuiAddress},
    effects::TransactionEffectsAPI,
    object::Owner,
    move_package::MovePackage,
    parse_sui_type_tag,
    programmable_transaction_builder::ProgrammableTransactionBuilder,
    transaction::{Argument, Command, ObjectArg, ProgrammableTransaction},
};

const TARGET: u64 = 25_000_000;
const BUY: u64 = 30_000_000;

/// `launch::set_opening_round` argument; zero leaves the launch without one and skips the call.
const NO_OPENING_ROUND: u64 = 0;
const OPENING_ROUND_MS: u64 = 60_000;
/// One opening-round bid, far below the graduation target.
const BID: u64 = 1_000_000;

/// `blast_fun::errors` codes.
const INVALID_LAUNCH_LIFECYCLE: u64 = 12;
const OPENING_ROUND_ENDED: u64 = 15;
const OPENING_ROUND_NOT_ENDED: u64 = 16;
const INVALID_CREATOR_RECIPIENT: u64 = 20;
const ZERO_OPENING_ROUND_BID: u64 = 29;
/// `blast_admin::errors` codes, raised by `blast_admin::package_version`.
const INVALID_PAUSE_BITS: u64 = 19;
const PAUSE_UNCHANGED: u64 = 20;
const PAUSED: u64 = 21;
/// `blast_core::errors::invalid_fee_split`.
const INVALID_FEE_SPLIT: u64 = 4;
/// The most routes one `blast_core` fee split holds.
const MAX_ROUTES: usize = 20;

const DESTINATION: ObjectID = address(&[0xD5]);
/// Blast's one-time share of both the Meme supply and the final Quote reserve.
const BLAST_BPS: u64 = 500;

const fn address(suffix: &[u8]) -> ObjectID {
    let mut bytes = [0u8; 32];
    let mut index = 0;
    while index < suffix.len() {
        bytes[32 - suffix.len() + index] = suffix[index];
        index += 1;
    }
    ObjectID::new(bytes)
}

struct Launch {
    meme: TypeTag,
    launch: ObjectID,
    currency: ObjectID,
}

/// A generated coin before its launch: the ticket and `TreasuryCap` the sender holds, and its
/// shared Currency.
struct Ticket {
    meme: TypeTag,
    ticket: ObjectID,
    treasury_cap: ObjectID,
    currency: ObjectID,
}

struct World {
    h: Harness,
    core: ObjectID,
    blast: ObjectID,
    adapter: ObjectID,
    version: ObjectID,
    runtime: ObjectID,
    config: ObjectID,
    /// The shared `launch::LaunchRegistry` every launch ID derives from, and the original
    /// launchpad ID its key types carry.
    launch_registry: ObjectID,
    launchpad_origin: ObjectID,
    project: CompiledPackage,
    launchpad_code: CompiledPackage,
    adapter_code: CompiledPackage,
    admin: ObjectID,
    acl: ObjectID,
    root: ObjectID,
    admin_cap: ObjectID,
    package_admin: ObjectID,
    /// `blast_core`'s shared `Treasury`, whose delay the launchpad's unpause also requires guarded.
    treasury: ObjectID,
}

const ADMIN_DELAY_MS: u64 = 172_800_000;

#[test]
fn administration_delay_cancellation_revocation_and_ptb_rollback() -> Result<()> {
    let mut w = world("admin-security")?;
    w.change_role("CancelAdmin", true)?;
    let share = 6_000;
    w.h.execute(w.schedule_fee_share(share)?)?.assert_success();
    w.h.sim.advance_clock(Duration::from_millis(ADMIN_DELAY_MS - 1));
    let watched = [w.runtime, w.config, w.acl, w.admin_cap];
    w.h.assert_rolled_back(w.apply_setting("runtime_config", "apply_protocol_fee_share", w.runtime)?,
        Expected::Abort { package: w.admin, module: "delayed", code: 13 }, &watched, &[w.h.sender])?;
    w.h.sim.advance_clock(Duration::from_millis(1));

    // Apply a ready fee share, emit its event, then fail a different not-ready action.
    // The failed PTB must preserve the original share AND the still-pending proposal.
    let mut b = ProgrammableTransactionBuilder::new();
    let fee_admin = w.sign_in(&mut b, "FeeAdmin")?;
    let config = b.obj(w.h.shared(w.config, true))?;
    let version = b.obj(w.h.shared(w.version, false))?;
    let fee = b.pure(123u64)?;
    let clock = b.obj(w.h.shared(SUI_CLOCK_OBJECT_ID, false))?;
    let next_delay = b.pure(172_800_000u64)?;
    call(&mut b, w.blast, "launch_config", "schedule_creation_fee", vec![], vec![config, version, fee_admin, fee, next_delay, clock]);
    w.h.execute(b.finish())?.assert_success();
    let mut b = ProgrammableTransactionBuilder::new();
    let runtime = b.obj(w.h.shared(w.runtime, true))?;
    let config = b.obj(w.h.shared(w.config, true))?;
    let version = b.obj(w.h.shared(w.version, false))?;
    let clock = b.obj(w.h.shared(SUI_CLOCK_OBJECT_ID, false))?;
    call(&mut b, w.blast, "runtime_config", "apply_protocol_fee_share", vec![], vec![runtime, version, clock]);
    call(&mut b, w.blast, "launch_config", "apply_creation_fee", vec![], vec![config, version, clock]);
    w.h.assert_rolled_back(b.finish(), Expected::Abort { package: w.admin, module: "delayed", code: 13 }, &watched, &[w.h.sender])?;

    w.change_role("FeeAdmin", false)?;
    w.h.assert_rolled_back(w.schedule_fee_share(7_000)?,
        Expected::Abort { package: w.admin, module: "blast_acl", code: 5 }, &watched, &[w.h.sender])?;
    // Revocation intentionally does not cancel a proposal. Apply requires no cap or role.
    w.h.execute(w.apply_setting("runtime_config", "apply_protocol_fee_share", w.runtime)?)?.assert_success();
    assert_eq!(w.applied_fee_share()?, share);
    w.h.assert_rolled_back(w.apply_setting("runtime_config", "apply_protocol_fee_share", w.runtime)?,
        Expected::Abort { package: w.admin, module: "delayed", code: 14 }, &watched, &[w.h.sender])?;

    w.change_role("FeeAdmin", true)?;
    w.h.execute(w.schedule_fee_share(7_000)?)?.assert_success();
    w.h.sim.advance_clock(Duration::from_millis(ADMIN_DELAY_MS));
    let mut b = ProgrammableTransactionBuilder::new();
    let cancel = w.sign_in(&mut b, "CancelAdmin")?;
    let runtime = b.obj(w.h.shared(w.runtime, true))?;
    let version = b.obj(w.h.shared(w.version, false))?;
    call(&mut b, w.blast, "runtime_config", "cancel_protocol_fee_share", vec![], vec![runtime, version, cancel]);
    w.h.execute(b.finish())?.assert_success();
    w.h.assert_rolled_back(w.apply_setting("runtime_config", "apply_protocol_fee_share", w.runtime)?,
        Expected::Abort { package: w.admin, module: "delayed", code: 14 }, &watched, &[w.h.sender])?;
    assert_eq!(w.applied_fee_share()?, share);
    Ok(())
}

#[test]
fn venue_admission_order_preserves_policy_and_pending_deadlines() -> Result<()> {
    let mut w = world("venue-policy-order")?;
    for (policy_first, old_delay, next_delay) in [
        (true, ADMIN_DELAY_MS, 100u64),
        (false, 100u64, 25u64),
    ] {
        let first = w.h.publish(w.adapter_code.clone())?.0;
        let second = w.h.publish(w.adapter_code.clone())?.0;
        let adapters = [first, second].map(|id| {
            parse_sui_type_tag(&format!("{id}::mock_adapter::Venue")).unwrap()
        });
        let mut b = ProgrammableTransactionBuilder::new();
        let admin = w.sign_in(&mut b, "VenueAdmin")?;
        let config = b.obj(w.h.shared(w.config, true))?;
        let version = b.obj(w.h.shared(w.version, false))?;
        let clock = b.obj(w.h.shared(SUI_CLOCK_OBJECT_ID, false))?;
        for adapter in &adapters {
            call(&mut b, w.blast, "launch_config", "schedule_venue",
                vec![adapter.clone()], vec![config, version, admin, clock]);
        }
        let delay = b.pure(next_delay)?;
        call(&mut b, w.blast, "launch_config", "schedule_venue_delay",
            vec![], vec![config, version, admin, delay, clock]);
        w.h.execute(b.finish())?.assert_success();

        let mut apply = ProgrammableTransactionBuilder::new();
        let config = apply.obj(w.h.shared(w.config, true))?;
        let version = apply.obj(w.h.shared(w.version, false))?;
        let clock = apply.obj(w.h.shared(SUI_CLOCK_OBJECT_ID, false))?;
        if policy_first {
            call(&mut apply, w.blast, "launch_config", "apply_venue_delay",
                vec![], vec![config, version, clock]);
        }
        for adapter in adapters.iter().rev() {
            call(&mut apply, w.blast, "launch_config", "apply_venue",
                vec![adapter.clone()], vec![config, version, clock]);
        }
        if !policy_first {
            call(&mut apply, w.blast, "launch_config", "apply_venue_delay",
                vec![], vec![config, version, clock]);
        }
        let apply = apply.finish();
        let watched = [w.config, w.version, w.acl, w.admin_cap];
        w.h.sim.advance_clock(Duration::from_millis(old_delay - 1));
        // The first early step aborts: a delay change through the shared readiness check, an
        // admission in the set itself.
        let early_module = if policy_first { "delayed" } else { "delayed_set" };
        w.h.assert_rolled_back(apply.clone(),
            Expected::Abort { package: w.admin, module: early_module, code: 13 },
            &watched, &[w.h.sender])?;
        w.h.sim.advance_clock(Duration::from_millis(1));
        let applied = w.h.execute(apply)?;
        applied.assert_success();
        // The primitive records the delay change and each admission, in application order.
        assert!(applied.payload_names(w.blast).is_empty());
        let changes: Vec<SetApplied<String>> =
            applied.delayed("SetApplied", "launch_config", "VenueKey")?;
        let admitted: Vec<_> = adapters.iter().rev()
            .map(|adapter| SetChange::Admission(adapter.to_canonical_string(false))).collect();
        let expected: Vec<_> = if policy_first {
            std::iter::once(SetChange::Delay).chain(admitted).collect()
        } else {
            admitted.into_iter().chain(std::iter::once(SetChange::Delay)).collect()
        };
        assert_eq!(changes.iter().map(|applied| applied.change.clone()).collect::<Vec<_>>(), expected);
        assert!(changes.iter().all(|applied| applied.owner == w.config));
        assert_eq!(changes.iter().find(|applied| applied.change == SetChange::Delay).map(|applied| applied.delay_ms),
            Some(next_delay));

        // A fresh admission uses the new policy, even after applying older admissions.
        let later = w.h.publish(w.adapter_code.clone())?.0;
        let later = parse_sui_type_tag(&format!("{later}::mock_adapter::Venue"))?;
        let (_, now): (ObjectID, u64) = bcs::from_bytes(&w.h.contents(SUI_CLOCK_OBJECT_ID))?;
        let mut b = ProgrammableTransactionBuilder::new();
        let admin = w.sign_in(&mut b, "VenueAdmin")?;
        let config = b.obj(w.h.shared(w.config, true))?;
        let version = b.obj(w.h.shared(w.version, false))?;
        let clock = b.obj(w.h.shared(SUI_CLOCK_OBJECT_ID, false))?;
        call(&mut b, w.blast, "launch_config", "schedule_venue",
            vec![later.clone()], vec![config, version, admin, clock]);
        let scheduled = w.h.execute(b.finish())?;
        scheduled.assert_success();
        let admissions: Vec<SetScheduled<String>> =
            scheduled.delayed("SetScheduled", "launch_config", "VenueKey")?;
        assert_eq!(admissions.len(), 1);
        assert_eq!(admissions[0].change, SetChange::Admission(later.to_canonical_string(false)));
        assert_eq!((admissions[0].ready_at_ms, admissions[0].delay_ms), (now + next_delay, next_delay));

        let mut b = ProgrammableTransactionBuilder::new();
        let config = b.obj(w.h.shared(w.config, true))?;
        let version = b.obj(w.h.shared(w.version, false))?;
        let clock = b.obj(w.h.shared(SUI_CLOCK_OBJECT_ID, false))?;
        call(&mut b, w.blast, "launch_config", "apply_venue",
            vec![later], vec![config, version, clock]);
        let apply = b.finish();
        w.h.sim.advance_clock(Duration::from_millis(next_delay - 1));
        w.h.assert_rolled_back(apply.clone(),
            Expected::Abort { package: w.admin, module: "delayed_set", code: 13 },
            &watched, &[w.h.sender])?;
        w.h.sim.advance_clock(Duration::from_millis(1));
        w.h.execute(apply)?.assert_success();
    }
    Ok(())
}

#[test]
fn pause_rolls_back_creation_trading_and_migration_but_allows_delivery() -> Result<()> {
    let mut w = world("pause-security")?;
    w.change_role("PauseAdmin", true)?;
    w.change_role("UnpauseAdmin", true)?;
    let round = w.open_launch(OPENING_ROUND_MS)?;
    w.h.execute(w.join(&round, BID)?)?.assert_success();
    let ready = w.open_launch(NO_OPENING_ROUND)?;
    w.buy_to_migration(&ready)?;
    let ticket = w.publish_ticket()?;
    w.set_pause(true, 7)?;
    let watched = [round.launch, ready.launch, ready.currency, ticket.ticket, ticket.treasury_cap, ticket.currency, w.version];
    let abort = || Expected::Abort { package: w.admin, module: "package_version", code: PAUSED };
    w.h.assert_rolled_back(w.create_launch(&ticket, &FeeSplit::single(DESTINATION.into()), NO_OPENING_ROUND)?, abort(), &watched, &[w.h.sender])?;
    w.h.assert_rolled_back(w.join(&round, BID)?, abort(), &watched, &[w.h.sender])?;
    w.h.assert_rolled_back(w.migrate(&ready, &ready, false)?, abort(), &watched, &[w.h.sender])?;
    w.h.sim.advance_clock(Duration::from_millis(OPENING_ROUND_MS));
    w.h.assert_rolled_back(w.settle(&round)?, abort(), &watched, &[w.h.sender])?;
    w.set_pause(false, 2)?;
    w.h.execute(w.settle(&round)?)?.assert_success();
    // Releasing trading must not release migration or creation.
    w.h.assert_rolled_back(w.migrate(&ready, &ready, false)?, Expected::Abort { package: w.admin, module: "package_version", code: PAUSED }, &watched, &[w.h.sender])?;
    w.set_pause(true, 2)?;
    let delivered = w.h.execute(w.deliver(&round, w.h.sender)?)?;
    delivered.assert_success();
    assert!(delivered.payload_names(w.blast).iter().any(|name| name == "OpeningRoundDelivered"));
    Ok(())
}

/// Every reachable pause state against every u8 input, through unmodified production bytecode.
/// Pausing is `blast_admin`'s and reads no consumer version; unpausing is the launchpad's
/// `launch_config::unpause`, which rejects a stale version first.
#[test]
fn pause_exhaustively_checks_masks_events_rollback_and_version_precedence() -> Result<()> {
    let mut w = world("pause-mask-matrix")?;
    w.change_role("PauseAdmin", true)?;
    w.change_role("UnpauseAdmin", true)?;
    // A set oracle keeps expected transitions independent of the contract's bitwise formulas.
    let states: [&[u8]; 8] = [&[], &[1], &[2], &[1, 2], &[4], &[1, 4], &[2, 4], &[1, 2, 4]];
    let watched = [w.version, w.acl, w.admin_cap, w.runtime, w.config, w.package_admin];
    let mut successes = 0;
    let mut invalid = 0;
    let mut unchanged = 0;
    let mut stale = 0;
    for version in [1, 2] {
        for (mask, flags) in states.iter().enumerate() {
            w.set_pause_version_for_fixture(1)?;
            w.replace_pause_mask(mask as u8)?;
            w.set_pause_version_for_fixture(version)?;
            let before: BTreeSet<_> = flags.iter().copied().collect();
            for bits in 0..=u8::MAX {
                for pausing in [true, false] {
                    let requested: BTreeSet<_> = [1u8, 2, 4].into_iter()
                        .filter(|flag| (bits / flag) % 2 == 1).collect();
                    let after: BTreeSet<u8> = if pausing {
                        before.union(&requested).copied().collect()
                    } else {
                        before.difference(&requested).copied().collect()
                    };
                    let pt = w.pause_command(pausing, bits)?;
                    let rejected = if version != 1 && !pausing {
                        stale += 1;
                        Some(Expected::Abort { package: w.admin, module: "package_version", code: 9 })
                    } else if !(1..=7).contains(&bits) {
                        invalid += 1;
                        Some(Expected::Abort { package: w.admin, module: "package_version", code: INVALID_PAUSE_BITS })
                    } else if after == before {
                        unchanged += 1;
                        Some(Expected::Abort { package: w.admin, module: "package_version", code: PAUSE_UNCHANGED })
                    } else {
                        None
                    };
                    if let Some(expected) = rejected {
                        w.h.assert_rolled_back(pt, expected, &watched, &[w.h.sender])?;
                    } else {
                        let untouched = w.h.snapshot(&watched[1..], &[w.h.sender]);
                        let outcome = w.h.execute(pt)?;
                        outcome.assert_success();
                        let name = if pausing { "Paused" } else { "Unpaused" };
                        let next: u8 = after.iter().sum();
                        assert_eq!(outcome.events.len(), 1);
                        assert_eq!(outcome.events_of("blast_admin_events", name),
                            [bcs::to_bytes(&(w.version, bits, next))?.as_slice()]);
                        assert_eq!(w.pause_state()?, (w.version, next, version));
                        assert_eq!(w.h.snapshot(&watched[1..], &[w.h.sender]), untouched);
                        w.set_pause_version_for_fixture(1)?;
                        w.replace_pause_mask(mask as u8)?;
                        w.set_pause_version_for_fixture(version)?;
                        successes += 1;
                    }
                    assert_eq!(w.pause_state()?, (w.version, mask as u8, version),
                        "pausing={pausing}, bits={bits}, initial={mask}, version={version}");
                }
            }
        }
    }
    assert_eq!((successes, invalid, unchanged, stale), (111, 5976, 57, 2048));
    Ok(())
}

#[test]
fn pause_roles_revocation_and_failed_sequences_preserve_state_and_events() -> Result<()> {
    let mut w = world("pause-authority")?;
    let watched = [w.version, w.acl, w.admin_cap];
    // A live AdminCap with neither role authorizes neither operation.
    for pausing in [true, false] {
        w.h.assert_rolled_back(w.pause_command(pausing, 1)?,
            Expected::Abort { package: w.admin, module: "blast_acl", code: 5 }, &watched, &[w.h.sender])?;
    }
    w.change_role("PauseAdmin", true)?;
    w.set_pause(true, 1)?;
    w.h.assert_rolled_back(w.pause_command(false, 1)?,
        Expected::Abort { package: w.admin, module: "blast_acl", code: 5 }, &watched, &[w.h.sender])?;
    let mut b = ProgrammableTransactionBuilder::new();
    w.append_pause(&mut b, false, 1, "PauseAdmin")?;
    w.h.assert_rolled_back(b.finish(), Expected::Error("TypeMismatch"), &watched, &[w.h.sender])?;
    w.change_role("PauseAdmin", false)?;
    w.h.assert_rolled_back(w.pause_command(true, 2)?,
        Expected::Abort { package: w.admin, module: "blast_acl", code: 5 }, &watched, &[w.h.sender])?;
    w.change_role("UnpauseAdmin", true)?;
    w.set_pause(false, 1)?;
    w.h.assert_rolled_back(w.pause_command(true, 1)?,
        Expected::Abort { package: w.admin, module: "blast_acl", code: 5 }, &watched, &[w.h.sender])?;
    let mut b = ProgrammableTransactionBuilder::new();
    w.append_pause(&mut b, true, 1, "UnpauseAdmin")?;
    w.h.assert_rolled_back(b.finish(), Expected::Error("TypeMismatch"), &watched, &[w.h.sender])?;
    w.change_role("UnpauseAdmin", false)?;
    w.h.assert_rolled_back(w.pause_command(false, 1)?,
        Expected::Abort { package: w.admin, module: "blast_acl", code: 5 }, &watched, &[w.h.sender])?;

    w.change_role("PauseAdmin", true)?;
    w.change_role("UnpauseAdmin", true)?;
    for (sequence, code) in [
        (vec![(true, 1), (true, 1)], PAUSE_UNCHANGED),
        (vec![(true, 1), (false, 1), (false, 1)], PAUSE_UNCHANGED),
        (vec![(true, 1), (true, 9)], INVALID_PAUSE_BITS),
    ] {
        let mut b = ProgrammableTransactionBuilder::new();
        for (pausing, bits) in sequence {
            w.append_pause(&mut b, pausing, bits, if pausing { "PauseAdmin" } else { "UnpauseAdmin" })?;
        }
        // Earlier successful commands emitted events, but the later failure commits none.
        w.h.assert_rolled_back(b.finish(),
            Expected::Abort { package: w.admin, module: "package_version", code }, &watched, &[w.h.sender])?;
        assert_eq!(w.pause_state()?, (w.version, 0, 1));
    }

    // Interleaved successful commands preserve native event order and replay to the final mask.
    let steps: [(bool, u8, u8); 6] = [(true, 1, 1), (true, 3, 3), (false, 5, 2),
        (true, 4, 6), (false, 2, 4), (false, 5, 0)];
    let mut b = ProgrammableTransactionBuilder::new();
    for &(pausing, bits, _) in &steps {
        w.append_pause(&mut b, pausing, bits, if pausing { "PauseAdmin" } else { "UnpauseAdmin" })?;
    }
    let outcome = w.h.execute(b.finish())?;
    outcome.assert_success();
    let names: Vec<_> = steps.iter().map(|(pausing, _, _)| if *pausing { "Paused" } else { "Unpaused" }).collect();
    assert_eq!(outcome.events.iter().map(|event| event.type_.name.to_string()).collect::<Vec<_>>(), names);
    assert!(outcome.events.iter().all(|event| event.type_.module.as_str() == "blast_admin_events"));
    for (event, &(_, bits, next)) in outcome.events.iter().zip(&steps) {
        assert_eq!(event.contents, bcs::to_bytes(&(w.version, bits, next))?);
    }
    assert_eq!(w.pause_state()?, (w.version, 0, 1));

    // Revoking the whole administrator defeats both roles even while it still owns its cap.
    let mut b = ProgrammableTransactionBuilder::new();
    let acl = b.obj(w.h.shared(w.acl, true))?;
    let root = b.obj(w.h.owned(w.root))?;
    let cap = b.pure(w.admin_cap)?;
    call(&mut b, w.admin, "blast_acl", "revoke_admin", vec![], vec![acl, root, cap]);
    w.h.impersonate_cap_owner(w.root, b.finish())?.assert_success();
    for pausing in [true, false] {
        w.h.assert_rolled_back(w.pause_command(pausing, 1)?,
            Expected::Abort { package: w.admin, module: "blast_acl", code: 1 }, &watched, &[w.h.sender])?;
    }
    Ok(())
}

#[test]
fn cap_recipient_schedules_enforce_live_roles_and_roll_back_failed_replacements() -> Result<()> {
    let mut w = world("cap-recipient-authority")?;
    let recipient = SuiAddress::from(DESTINATION);
    for (cap, cap_type, key, reassigned_name) in [
        ("curve_fee_cap", "CurveFeeCap", "CurveFeeCapReassignment", "CurveFeeCapReassigned"),
        ("creator_metadata_cap", "CreatorMetadataCap", "CreatorMetadataCapReassignment", "CreatorMetadataCapReassigned"),
    ] {
        let launch = w.open_launch(NO_OPENING_ROUND)?;
        let watched = [launch.launch, launch.currency, w.version, w.acl, w.admin_cap, w.config];
        let owners = [w.h.sender, recipient];
        // A real live AdminCap with other roles cannot schedule either cap replacement.
        let mut b = ProgrammableTransactionBuilder::new();
        w.append_cap_recipient(&mut b, &launch, cap, "CreatorAdmin", recipient)?;
        w.h.assert_rolled_back(b.finish(),
            Expected::Abort { package: w.admin, module: "blast_acl", code: 5 }, &watched, &owners)?;
        let mut b = ProgrammableTransactionBuilder::new();
        w.append_cap_recipient(&mut b, &launch, cap, "TreasuryAdmin", recipient)?;
        w.h.assert_rolled_back(b.finish(), Expected::Error("TypeMismatch"), &watched, &owners)?;

        w.change_role("CreatorAdmin", true)?;
        let (_, scheduled_at_ms): (ObjectID, u64) = bcs::from_bytes(&w.h.contents(SUI_CLOCK_OBJECT_ID))?;
        let mut b = ProgrammableTransactionBuilder::new();
        w.append_cap_recipient(&mut b, &launch, cap, "CreatorAdmin", recipient)?;
        let scheduled = w.h.execute(b.finish())?;
        scheduled.assert_success();
        assert!(scheduled.payload_names(w.blast).is_empty());
        let proposals: Vec<ActionScheduled<SuiAddress>> = scheduled.delayed("ActionScheduled", "launch", key)?;
        assert_eq!(proposals, [ActionScheduled {
            owner: launch.launch,
            key: false,
            change: Change::Action(recipient),
            delay_ms: ADMIN_DELAY_MS,
            ready_at_ms: scheduled_at_ms + ADMIN_DELAY_MS,
        }]);
        assert!(scheduled.created(&w.h, "creator_authority", "CurveFeeCap").is_empty());
        assert!(scheduled.created(&w.h, "creator_authority", "CreatorMetadataCap").is_empty());

        // Invalid replacements cannot erase the already accepted recipient or its deadline.
        let mut b = ProgrammableTransactionBuilder::new();
        w.append_cap_recipient(&mut b, &launch, cap, "CreatorAdmin", SuiAddress::ZERO)?;
        w.h.assert_rolled_back(b.finish(),
            Expected::Abort { package: w.blast, module: "launch", code: INVALID_CREATOR_RECIPIENT }, &watched, &owners)?;

        // A later failing command rolls back the earlier reschedule and all its events.
        let mut b = ProgrammableTransactionBuilder::new();
        w.append_cap_recipient(&mut b, &launch, cap, "CreatorAdmin", w.h.sender)?;
        let launch_arg = b.obj(w.h.shared(launch.launch, true))?;
        let version = b.obj(w.h.shared(w.version, false))?;
        let clock = b.obj(w.h.shared(SUI_CLOCK_OBJECT_ID, false))?;
        call(&mut b, w.blast, "launch", &format!("apply_{cap}_reassignment"),
            vec![launch.meme.clone(), sui()], vec![launch_arg, version, clock]);
        w.h.assert_rolled_back(b.finish(),
            Expected::Abort { package: w.admin, module: "delayed", code: 13 }, &watched, &owners)?;

        w.change_role("CreatorAdmin", false)?;
        let mut b = ProgrammableTransactionBuilder::new();
        w.append_cap_recipient(&mut b, &launch, cap, "CreatorAdmin", w.h.sender)?;
        w.h.assert_rolled_back(b.finish(),
            Expected::Abort { package: w.admin, module: "blast_acl", code: 5 }, &watched, &owners)?;

        // Revocation blocks new schedules; accepted proposals remain permissionlessly applicable.
        w.h.sim.advance_clock(Duration::from_millis(ADMIN_DELAY_MS));
        let mut b = ProgrammableTransactionBuilder::new();
        let launch_arg = b.obj(w.h.shared(launch.launch, true))?;
        let version = b.obj(w.h.shared(w.version, false))?;
        let clock = b.obj(w.h.shared(SUI_CLOCK_OBJECT_ID, false))?;
        call(&mut b, w.blast, "launch", &format!("apply_{cap}_reassignment"),
            vec![launch.meme.clone(), sui()], vec![launch_arg, version, clock]);
        let applied = w.h.execute(b.finish())?;
        applied.assert_success();
        assert_eq!(applied.payload_names(w.blast), [reassigned_name]);
        let changes: Vec<ActionApplied<SuiAddress>> = applied.delayed("ActionApplied", "launch", key)?;
        assert_eq!(changes, [ActionApplied {
            owner: launch.launch,
            key: false,
            change: Change::Action(recipient),
            delay_ms: ADMIN_DELAY_MS,
        }]);
        let caps = applied.created(&w.h, "creator_authority", cap_type);
        assert_eq!(caps.len(), 1);
        assert_eq!(w.h.object(caps[0]).owner().get_address_owner_address()?, recipient);
        assert_eq!(applied.events_of("events", reassigned_name),
            [bcs::to_bytes(&(launch.launch, caps[0], recipient))?.as_slice()]);
        let other_cap = if cap_type == "CreatorMetadataCap" { "CurveFeeCap" } else { "CreatorMetadataCap" };
        assert!(applied.created(&w.h, "creator_authority", other_cap).is_empty());
    }
    Ok(())
}

#[test]
fn mixed_version_creation_rejects_each_stale_step_after_native_upgrade() -> Result<()> {
    let mut w = world("mixed-version-creation")?;
    let ticket = w.publish_ticket()?;
    let original = w.blast;
    // `constants::version!()` expands to the literal each `package_version::assert_current` call
    // loads just before it, so the next version's bytecode loads 2 there instead of 1.
    let mut code = w.launchpad_code.clone();
    let mut changed = 0;
    for bytes in &mut code.modules {
        let mut module = CompiledModule::deserialize_with_defaults(bytes)?;
        let assert_current: Vec<_> = module.function_instantiations.iter().enumerate()
            .filter(|(_, instantiation)| {
                let handle = &module.function_handles[instantiation.handle.0 as usize];
                module.identifiers[handle.name.0 as usize].as_str() == "assert_current"
            })
            .map(|(index, _)| index as u16)
            .collect();
        let mut module_changed = 0;
        for definition in &mut module.function_defs {
            let Some(code) = definition.code.as_mut() else { continue };
            for at in 1..code.code.len() {
                if let Bytecode::CallGeneric(index) = code.code[at] {
                    if assert_current.contains(&index.0) && code.code[at - 1] == Bytecode::LdU64(1) {
                        code.code[at - 1] = Bytecode::LdU64(2);
                        module_changed += 1;
                    }
                }
            }
        }
        if module_changed > 0 {
            changed += module_changed;
            bytes.clear();
            module.serialize_with_version(module.version, bytes)?;
        }
    }
    assert!(changed > 0, "advance every compiled version check");
    let role = launchpad_role(w.admin, w.core, original, "UpgradeAdmin")?;
    let mut b = ProgrammableTransactionBuilder::new();
    let acl = b.obj(w.h.shared(w.acl, true))?;
    let root = b.obj(w.h.owned(w.root))?;
    let cap_id = b.pure(w.admin_cap)?;
    call(&mut b, w.admin, "blast_acl", "grant_role", vec![role.clone()], vec![acl, root, cap_id]);
    w.h.impersonate_cap_owner(w.root, b.finish())?.assert_success();

    let package_admin = w.package_admin;
    let digest = MovePackage::compute_digest_for_modules_and_deps(&code.modules, &code.dependencies, true);
    let mut schedule = ProgrammableTransactionBuilder::new();
    let acl = schedule.obj(w.h.shared(w.acl, false))?;
    let cap = schedule.obj(w.h.owned(w.admin_cap))?;
    let witness = call(&mut schedule, w.admin, "blast_acl", "sign_in", vec![role.clone()], vec![acl, cap]);
    let package_admin_arg = schedule.obj(w.h.shared(package_admin, true))?;
    let proposed = schedule.pure(digest.to_vec())?;
    let clock = schedule.obj(w.h.shared(SUI_CLOCK_OBJECT_ID, false))?;
    let otw = w.otw()?;
    call(&mut schedule, w.admin, "package_admin", "schedule_upgrade", vec![otw.clone()], vec![package_admin_arg, witness, proposed, clock]);
    let schedule = schedule.finish();
    let (_, scheduled_at_ms): (ObjectID, u64) = bcs::from_bytes(&w.h.contents(SUI_CLOCK_OBJECT_ID))?;
    let scheduled = w.h.execute(schedule.clone())?;
    scheduled.assert_success();
    // The primitive records the proposal, keyed by the custody's own upgrade operation.
    #[derive(Debug, Deserialize, PartialEq, Clone)]
    enum UpgradeAction { Upgrade(Vec<u8>), #[allow(dead_code)] MakeImmutable }
    let admin = w.admin;
    let upgrade_event = |name: &str| parse_sui_type_tag(&format!(
        "{admin}::delayed_action::{name}<{admin}::package_admin::UpgradeKey<{original}::blast_fun::BLAST_FUN>, {admin}::package_admin::UpgradeAction>",
    ));
    let proposal = ActionScheduled {
        owner: package_admin,
        key: false,
        change: Change::Action(UpgradeAction::Upgrade(digest.to_vec())),
        delay_ms: ADMIN_DELAY_MS,
        ready_at_ms: scheduled_at_ms + ADMIN_DELAY_MS,
    };
    assert_eq!(scheduled.events.len(), 1);
    assert_eq!(TypeTag::Struct(Box::new(scheduled.events[0].type_.clone())), upgrade_event("ActionScheduled")?);
    assert_eq!(scheduled.delayed::<ActionScheduled<UpgradeAction>>("ActionScheduled", "package_admin", "UpgradeKey")?,
        [proposal.clone()]);

    w.change_role("PackageCancelAdmin", true)?;
    let mut cancel = ProgrammableTransactionBuilder::new();
    let witness = w.sign_in(&mut cancel, "PackageCancelAdmin")?;
    let package_admin_arg = cancel.obj(w.h.shared(package_admin, true))?;
    call(&mut cancel, w.admin, "package_admin", "cancel_upgrade_action", vec![otw.clone()], vec![package_admin_arg, witness]);
    let cancelled = w.h.execute(cancel.finish())?;
    cancelled.assert_success();
    assert_eq!(cancelled.events.len(), 1);
    assert_eq!(TypeTag::Struct(Box::new(cancelled.events[0].type_.clone())), upgrade_event("ActionCancelled")?);
    // `ActionCancelled` has `ActionScheduled`'s fields, so one mirror reads both.
    assert_eq!(cancelled.delayed::<ActionScheduled<UpgradeAction>>("ActionCancelled", "package_admin", "UpgradeKey")?,
        [proposal]);
    w.h.execute(schedule)?.assert_success();
    let mut b = ProgrammableTransactionBuilder::new();
    let acl = b.obj(w.h.shared(w.acl, false))?;
    let cap = b.obj(w.h.owned(w.admin_cap))?;
    let witness = call(&mut b, w.admin, "blast_acl", "sign_in", vec![role], vec![acl, cap]);
    let package_admin_arg = b.obj(w.h.shared(package_admin, true))?;
    let version = b.obj(w.h.shared(w.version, true))?;
    let digest = b.pure(digest.to_vec())?;
    let clock = b.obj(w.h.shared(SUI_CLOCK_OBJECT_ID, false))?;
    let upgrade_ticket = call(&mut b, w.admin, "package_admin", "authorize_upgrade", vec![otw.clone()], vec![package_admin_arg, witness, digest, clock]);
    let receipt = b.upgrade(original, upgrade_ticket, code.dependencies, code.modules);
    call(&mut b, w.admin, "package_admin", "commit_upgrade_and_advance", vec![otw], vec![package_admin_arg, witness, version, receipt]);
    let upgrade = b.finish();
    w.h.assert_rolled_back(
        upgrade.clone(),
        Expected::Abort { package: w.admin, module: "delayed", code: 13 },
        &[package_admin, w.version, w.admin_cap],
        &[w.h.sender],
    )?;
    w.h.sim.advance_clock(Duration::from_millis(172_800_000));
    // Readiness does not retain a revoked UpgradeAdmin's right to authorize code.
    w.change_role("UpgradeAdmin", false)?;
    w.h.assert_rolled_back(
        upgrade.clone(),
        Expected::Abort { package: w.admin, module: "blast_acl", code: 5 },
        &[package_admin, w.version, w.admin_cap, w.acl],
        &[w.h.sender],
    )?;
    w.change_role("UpgradeAdmin", true)?;
    let upgraded = w.h.execute(upgrade)?;
    upgraded.assert_success();
    w.blast = upgraded.effects.created().into_iter()
        .map(|(reference, _)| reference.0).find(|id| w.h.object(*id).is_package()).unwrap();
    let (_, _, version) = w.pause_state()?;
    assert_eq!(version, 2);

    // A fresh adapter links to the active dependency while preserving core type origins.
    let mut adapter = w.adapter_code.clone();
    for dependency in &mut adapter.dependencies {
        if *dependency == original { *dependency = w.blast; }
    }
    w.adapter = w.h.publish(adapter)?.0;
    let mut b = ProgrammableTransactionBuilder::new();
    let acl = b.obj(w.h.shared(w.acl, false))?;
    let cap = b.obj(w.h.owned(w.admin_cap))?;
    let role = launchpad_role(w.admin, w.core, original, "VenueAdmin")?;
    let witness = call(&mut b, w.admin, "blast_acl", "sign_in", vec![role], vec![acl, cap]);
    let config = b.obj(w.h.shared(w.config, true))?;
    let version = b.obj(w.h.shared(w.version, false))?;

    let admin_clock = b.obj(w.h.shared(sui_types::SUI_CLOCK_OBJECT_ID, false))?;
    call(&mut b, w.blast, "launch_config", "schedule_venue", vec![w.adapter_type("Venue")?], vec![config, version, witness, admin_clock]);
    w.h.execute(b.finish())?.assert_success();
    let venue = w.adapter_type("Venue")?;
    blast_launchpad_ptb_tests::apply_admin_changes(&mut w.h, vec![(w.blast, "launch_config", "apply_venue", vec![venue], w.config, w.version)])?;

    let current = w.create_launch(&ticket, &FeeSplit::single(DESTINATION.into()), OPENING_ROUND_MS)?;
    for name in ["new", "set_virtual_quote", "set_graduation_target", "set_allocation_plan", "set_lp_fee_split", "set_opening_round", "finalize", "share"] {
        let mut mixed = current.clone();
        let stale = mixed.commands.iter_mut().find_map(|command| match command {
            Command::MoveCall(call) if call.module.as_str() == "launch" && call.function.as_str() == name => Some(call),
            _ => None,
        }).unwrap();
        stale.package = original;
        // This pinned runtime rejects conflicting linkage before entering Move. Unit tests
        // separately pin the version-first abort for each creation function.
        println!("mixed-version step: {name}");
        w.h.assert_rolled_back(mixed, Expected::Error("InvalidLinkage"), &[ticket.ticket, ticket.treasury_cap, ticket.currency, w.version, w.config], &[w.h.sender])?;
    }
    w.h.execute(current)?.assert_success();
    Ok(())
}

#[test]
fn failed_migration_ptbs_commit_nothing_and_one_ptb_completes_atomically() -> Result<()> {
    let (mut w, a, b) = setup()?;
    let b_ready = w.h.snapshot(&[b.launch, b.currency], &[]);
    let watched = [a.launch, a.currency];
    let owners = [w.h.sender, DESTINATION.into()];

    // An adapter abort after the launch migrated rolls the whole migration back.
    let pt = w.migrate(&a, &a, true)?;
    let adapter_failure = Expected::Abort { package: w.adapter, module: "mock_adapter", code: 0 };
    w.h.assert_rolled_back(pt, adapter_failure, &watched, &owners)?;

    // VM type-rule evidence, not a launch check: launch B's currency cannot stand in for launch
    // A's because distinct one-time-witness types fail PTB type checking before any Move code runs.
    let pt = w.migrate(&a, &b, false)?;
    w.h.assert_rolled_back(
        pt,
        Expected::Error("TypeMismatch"),
        &[a.launch, a.currency, b.currency],
        &owners,
    )?;

    // VM type-rule evidence, not a launch check: a PTB cannot pass pure bytes as the venue
    // witness that redeems the hand-off.
    let pt = {
        let mut builder = ProgrammableTransactionBuilder::new();
        let handoff = w.launch_migrate(&mut builder, &a)?;
        let forged = builder.pure_bytes(vec![], true);
        let redeemed = call(
            &mut builder,
            w.core,
            "migration",
            "redeem",
            vec![a.meme.clone(), sui(), w.adapter_type("Venue")?],
            vec![handoff, forged],
        );
        let Argument::Result(redeemed) = redeemed else { unreachable!() };
        // Taking both principals is the only other work, so a forged witness surfaces as its own
        // error rather than behind an unconsumed balance.
        let mut coins = Vec::new();
        for (index, coin_type) in [a.meme.clone(), sui()].into_iter().enumerate() {
            coins.push(call(
                &mut builder,
                SUI_FRAMEWORK_PACKAGE_ID,
                "coin",
                "from_balance",
                vec![coin_type],
                vec![Argument::NestedResult(redeemed, index as u16)],
            ));
        }
        builder.transfer_args(w.h.sender, coins);
        builder.finish()
    };
    w.h.assert_rolled_back(pt, Expected::Error("InvalidUsageOfPureArg"), &watched, &owners)?;
    assert_eq!(w.launch_lifecycle(&a)?, LaunchLifecycle::MigrationReady);

    // The complete migration succeeds in one PTB, pays the creator's recipient, settles Blast's
    // Meme and Quote allocation into the launch ledger, and leaves the caller with nothing.
    let pt = w.migrate(&a, &a, false)?;
    let outcome = w.h.execute(pt)?;
    outcome.assert_success();
    assert_eq!(
        outcome.payload_names(w.blast),
        ["MigrationAllocationPaid", "ProtocolFeesAccrued", "Migrated"]
    );
    assert_eq!(w.launch_lifecycle(&a)?, LaunchLifecycle::Migrated);
    let migrated = outcome.events_of("events", "Migrated");
    assert_eq!(migrated.len(), 1);
    let migrated: Migrated = bcs::from_bytes(migrated[0])?;
    assert_eq!(migrated.launch_id, a.launch);
    assert!(migrated.meme > 0 && migrated.quote > 0);
    let vaults = outcome.created(&w.h, "mock_adapter", "MockVault");
    assert_eq!(vaults.len(), 1);
    assert!(w.h.object(vaults[0]).is_shared());
    let paid = outcome.events_of("events", "MigrationAllocationPaid");
    assert_eq!(paid.len(), 1);
    let paid: MigrationAllocationPaid = bcs::from_bytes(paid[0])?;
    assert_eq!((paid.launch_id, paid.destination), (a.launch, DESTINATION.into()));
    assert!(paid.meme > 0 && paid.quote > 0);
    assert_eq!(outcome.coins_created_for(&w.h, DESTINATION.into()), w.coins(&a, paid.meme, paid.quote));
    let accrued = outcome.events_of("events", "ProtocolFeesAccrued");
    assert_eq!(accrued.len(), 1);
    let accrued: ProtocolFeesAccrued = bcs::from_bytes(accrued[0])?;
    assert_eq!(accrued.launch_id, a.launch);
    assert!(accrued.meme_amount > 0 && accrued.quote_amount > 0);
    assert!(
        outcome
            .effects
            .created()
            .iter()
            .all(|(_, owner)| *owner != Owner::AddressOwner(w.h.sender)),
        "the caller received an object"
    );

    // A migrated launch cannot migrate again, and launch B was never touched.
    let pt = w.migrate(&a, &a, false)?;
    let lifecycle = Expected::Abort { package: w.blast, module: "launch", code: INVALID_LAUNCH_LIFECYCLE };
    w.h.assert_rolled_back(pt, lifecycle, &watched, &owners)?;
    assert_eq!(w.h.snapshot(&[b.launch, b.currency], &[]), b_ready);

    Ok(())
}

/// ADR 0137 verification: the hand-off and the owner proof have no abilities, so a PTB that
/// leaves either unconsumed fails at the end of execution and commits nothing.
#[test]
fn unredeemed_migration_and_unconsumed_owner_proof_fail_without_drop() -> Result<()> {
    let mut w = world("hot_potatoes")?;
    let launch = w.open_launch(NO_OPENING_ROUND)?;
    w.buy_to_migration(&launch)?;
    let owners = [w.h.sender, DESTINATION.into()];

    // `launch::migrate` runs, pays nothing that survives, and its unredeemed `Migration` aborts the
    // whole PTB; the launch stays MigrationReady.
    let mut builder = ProgrammableTransactionBuilder::new();
    w.launch_migrate(&mut builder, &launch)?;
    w.h.assert_rolled_back(builder.finish(), Expected::Error("UnusedValueWithoutDrop"),
        &[launch.launch, launch.currency], &owners)?;
    assert_eq!(w.launch_lifecycle(&launch)?, LaunchLifecycle::MigrationReady);

    // The creator claims the live curve-fee cap; a proof made from it and left unconsumed aborts.
    let cap = w.claim_curve_fee_cap(&launch)?;
    let mut builder = ProgrammableTransactionBuilder::new();
    let launch_arg = builder.obj(w.h.shared(launch.launch, false))?;
    let version = builder.obj(w.h.shared(w.version, false))?;
    let cap_arg = builder.obj(w.h.owned(cap))?;
    call(&mut builder, w.blast, "launch", "prove_owner", vec![launch.meme.clone(), sui()], vec![launch_arg, version, cap_arg]);
    w.h.assert_rolled_back(builder.finish(), Expected::Error("UnusedValueWithoutDrop"),
        &[launch.launch, cap], &[w.h.sender])?;

    // The launch still migrates in one PTB that redeems its hand-off.
    w.h.execute(w.migrate(&launch, &launch, false)?)?.assert_success();
    assert_eq!(w.launch_lifecycle(&launch)?, LaunchLifecycle::Migrated);
    Ok(())
}

#[test]
fn empty_and_twenty_one_route_fee_splits_abort_before_the_launch_exists() -> Result<()> {
    let mut w = world("fee_split_boundaries")?;
    let maximum = maximum_fee_split(0xA0, 10);
    assert_eq!(maximum.routes.len(), MAX_ROUTES);
    // An empty split fails the 10,000 sum and a twenty-first distinct route fails capacity, while
    // the sum stays whole; both are `invalid_fee_split`.
    let rejected = [FeeSplit::default(), with_twenty_first(maximum.clone())];
    let core = w.core;
    let abort = || Expected::Abort { package: core, module: "fee_split", code: INVALID_FEE_SPLIT };
    let owners = [w.h.sender, DESTINATION.into()];

    // Each rejected split aborts before the ticket is consumed; the same ticket then opens with
    // twenty routes, which the launch records unchanged.
    let ticket = w.publish_ticket()?;
    for fee_split in &rejected {
        let pt = w.create_launch(&ticket, fee_split, NO_OPENING_ROUND)?;
        w.h.assert_rolled_back(pt, abort(), &[ticket.ticket, ticket.treasury_cap, ticket.currency], &owners)?;
    }
    let (_, created) = w.open_split_launch(ticket, &maximum)?;
    assert_eq!(w.launch_created(&created)?.lp_fee_split, maximum);

    Ok(())
}

#[test]
fn maximum_fee_split_fits_protocol_limits_at_creation_and_migration() -> Result<()> {
    let mut w = world("fee_split_capacity")?;
    let fee_split = maximum_fee_split(0xA0, 10);
    let mut records = Vec::new();

    let ticket = w.publish_ticket()?;
    let (a, created) = w.open_split_launch(ticket, &fee_split)?;
    let launch_created = w.launch_created(&created)?;
    assert_eq!(launch_created.lp_fee_split, fee_split);
    assert_eq!(launch_created.opening_round_ms, NO_OPENING_ROUND);
    assert!(launch_created.venue.ends_with("::mock_adapter::Venue"), "the launch records its venue");
    assert_eq!(
        (
            launch_created.allocation_plan.protocol_meme_bps,
            launch_created.allocation_plan.protocol_quote_bps,
        ),
        (BLAST_BPS, BLAST_BPS),
    );
    assert_eq!(launch_created.allocation_plan.recipients, [((DESTINATION.into(), None), 500, 500)]);
    records.push(w.record(&a, "create_launch", "4 parts + 16 address routes", &created));

    // The launch carries the split unchanged to migration, which neither reads nor pays it.
    w.buy_to_migration(&a)?;
    let migrated = w.h.execute(w.migrate(&a, &a, false)?)?;
    migrated.assert_success();
    assert_eq!(
        migrated.payload_names(w.blast),
        ["MigrationAllocationPaid", "ProtocolFeesAccrued", "Migrated"]
    );
    records.push(w.record(&a, "migrate", "4 parts + 16 address routes", &migrated));

    println!(
        "LAUNCH_FEE_SPLIT_CAPACITY {}",
        json!({ "limits": w.h.protocol_limits(), "fixture": { "fee_split": fee_split }, "records": records })
    );

    Ok(())
}

#[test]
fn opening_round_keeps_one_record_per_bidder_and_nothing_trades_before_settlement() -> Result<()> {
    let mut w = world("opening_round")?;
    let launch = w.open_launch(OPENING_ROUND_MS)?;
    let owners = [w.h.sender];
    let blast = w.blast;
    let abort = |code| Expected::Abort { package: blast, module: "launch", code };

    // The first bid creates the bidder's launch-owned record; a later bid only raises it.
    let first = w.h.execute(w.join(&launch, BID)?)?;
    first.assert_success();
    assert_eq!(first.payload_names(w.blast), ["OpeningRoundJoined"]);
    let records = first.created(&w.h, "dynamic_field", "Field");
    assert_eq!(records.len(), 1, "the first bid creates one bidder record");
    let record = records[0];
    assert_eq!(*w.h.object(record).owner(), Owner::ObjectOwner(launch.launch.into()));
    let later = w.h.execute(w.join(&launch, BID)?)?;
    later.assert_success();
    assert!(later.created(&w.h, "dynamic_field", "Field").is_empty());
    assert!(later.effects.mutated().iter().any(|(object, _)| object.0 == record));
    let bid: OpeningRoundBid = bcs::from_bytes(&w.h.contents(record))?;
    assert_eq!((bid.bidder, bid.bid), (w.h.sender, 2 * BID));

    // Before the end nothing trades or pays out, settling is early, and a zero bid is refused;
    // each failure leaves the launch, the record, and the bidder's coins exactly as they were.
    let watched = [launch.launch, record];
    let bidder = w.h.sender;
    for (pt, code) in [
        (w.buy(&launch, BID, 1)?, INVALID_LAUNCH_LIFECYCLE),
        (w.deliver(&launch, bidder)?, INVALID_LAUNCH_LIFECYCLE),
        (w.settle(&launch)?, OPENING_ROUND_NOT_ENDED),
        (w.join(&launch, 0)?, ZERO_OPENING_ROUND_BID),
    ] {
        w.h.assert_rolled_back(pt, abort(code), &watched, &owners)?;
    }

    // At the end bidding closes, and settlement buys once with the whole pot.
    w.h.sim.advance_clock(Duration::from_millis(OPENING_ROUND_MS));
    let pt = w.join(&launch, BID)?;
    w.h.assert_rolled_back(pt, abort(OPENING_ROUND_ENDED), &watched, &owners)?;
    let settled = w.h.execute(w.settle(&launch)?)?;
    settled.assert_success();
    assert_eq!(settled.payload_names(w.blast), ["Bought", "OpeningRoundSettled"]);
    let bought: Bought = bcs::from_bytes(settled.events_of("events", "Bought")[0])?;
    let round: OpeningRoundSettled = bcs::from_bytes(settled.events_of("events", "OpeningRoundSettled")[0])?;
    assert_eq!((bought.quote_in, bought.quote_refund), (2 * BID, 0));
    assert_eq!((round.launch_id, round.bids, round.meme, round.quote), (launch.launch, 2 * BID, bought.meme_out_net, 0));
    assert_eq!(w.launch_lifecycle(&launch)?, LaunchLifecycle::Live);

    // Delivery retires the record and sends the lone bidder everything the pot bought; then the
    // curve trades.
    let delivered = w.h.execute(w.deliver(&launch, bidder)?)?;
    delivered.assert_success();
    assert_eq!(delivered.payload_names(w.blast), ["OpeningRoundDelivered"]);
    assert!(delivered.effects.deleted().iter().any(|(object, _, _)| *object == record));
    assert_eq!(delivered.coins_created_for(&w.h, bidder), w.coins(&launch, round.meme, 0));
    let open = w.h.execute(w.buy(&launch, BID, 1)?)?;
    open.assert_success();
    assert_eq!(open.payload_names(w.blast), ["Bought"]);

    // Capacity evidence: net storage charged by each step. Only the first bid leaves a new object
    // behind, and delivery refunds it.
    let net_storage = |name: &str, outcome: &Outcome| {
        let cost = outcome.effects.gas_cost_summary();
        println!(
            "{name}: storage_cost {} storage_rebate {} non_refundable {} net {}",
            cost.storage_cost,
            cost.storage_rebate,
            cost.non_refundable_storage_fee,
            cost.storage_cost as i64 - cost.storage_rebate as i64,
        );
        cost.storage_cost as i64 - cost.storage_rebate as i64
    };
    let first_net = net_storage("first bid", &first);
    let later_net = net_storage("later bid", &later);
    net_storage("settlement", &settled);
    let delivery_net = net_storage("delivery", &delivered);
    net_storage("buy after settlement", &open);
    assert!(first_net > later_net);
    assert!(delivery_net < first_net);

    Ok(())
}

/// Mirrors `blast_fun::events::Bought` field order for BCS decoding.
#[derive(Deserialize)]
struct Bought {
    _launch_id: ObjectID,
    quote_in: u64,
    _meme_out_gross: u64,
    meme_out_net: u64,
    quote_refund: u64,
    _protocol_meme_fee: u64,
    _creator_meme_fee: u64,
    _protocol_quote_fee: u64,
    _creator_quote_fee: u64,
    _meme_reserve: u64,
    _real_quote_reserve: u64,
}

/// Mirrors `blast_fun::events::OpeningRoundSettled`.
#[derive(Deserialize)]
struct OpeningRoundSettled {
    launch_id: ObjectID,
    bids: u64,
    meme: u64,
    quote: u64,
}

/// Mirrors `0x2::dynamic_field::Field<blast_fun::launch::OpeningRoundBidKey, u64>`.
#[derive(Deserialize)]
struct OpeningRoundBid {
    _id: ObjectID,
    bidder: SuiAddress,
    bid: u64,
}

/// Mirrors `blast_fun::events::LaunchCreated`.
#[derive(Deserialize)]
struct LaunchCreated {
    _launch_id: ObjectID,
    _ticket_id: ObjectID,
    venue: String,
    lp_fee_split: FeeSplit,
    _virtual_quote: u64,
    _graduation_target: u64,
    _quote_fee_bps: u64,
    _meme_fee_bps: u64,
    allocation_plan: AllocationPlan,
    opening_round_ms: u64,
    _creation_fee: u64,
    _partner_id: Option<ObjectID>,
}

/// Mirrors `blast_fun::allocation::AllocationPlan`; each recipient is ((destination, vesting
/// terms), Meme, Quote).
#[derive(Deserialize)]
struct AllocationPlan {
    _curve_meme_bps: u64,
    _lp_meme_bps: u64,
    _lp_quote_bps: u64,
    protocol_meme_bps: u64,
    protocol_quote_bps: u64,
    recipients: Vec<((SuiAddress, Option<(u64, u64, u64)>), u64, u64)>,
}

/// Mirrors `blast_fun::events::Migrated` field order for BCS decoding.
#[derive(Deserialize)]
struct Migrated {
    launch_id: ObjectID,
    meme: u64,
    quote: u64,
    _disposed_meme: u64,
    _total_supply_after: u64,
}

/// `blast_fun::launch::Launch` begins with its UID and this fieldless enum, whose BCS tag is one
/// byte; the rest of the launch is not mirrored.
#[derive(Debug, Deserialize, PartialEq)]
enum LaunchLifecycle {
    OpeningRound,
    Live,
    MigrationReady,
    Migrated,
}

/// Every destination kind, then sixteen address routes whose weights fall by `step`, so they are
/// distinct: twenty routes, the most one split holds, summing to 10,000.
fn maximum_fee_split(tag: u8, step: u64) -> FeeSplit {
    let parts = [(Destination::Owner, 1_000), (Destination::AutoLp, 600), (Destination::HolderRewards, 400),
        (Destination::Burn, 400)];
    let shared = 10_000 - parts.iter().map(|(_, bps)| bps).sum::<u64>();
    assert_eq!((shared - 120 * step) % 16, 0);
    let lowest = (shared - 120 * step) / 16;
    let addresses = (0..16u8)
        .map(|i| (Destination::Address(address(&[tag, i]).into()), lowest + step * u64::from(15 - i)));

    FeeSplit::new(parts.into_iter().chain(addresses))
}

/// Moves one basis point of the owner route to a twenty-first distinct address route; the sum
/// stays whole.
fn with_twenty_first(mut split: FeeSplit) -> FeeSplit {
    split.routes[0].bps -= 1;
    split.routes.push(blast_launchpad_ptb_tests::Route {
        destination: Destination::Address(address(&[0x21, 0x21]).into()),
        bps: 1,
    });
    split
}

/// Mirrors `blast_fun::events::MigrationAllocationPaid`.
#[derive(Deserialize)]
struct MigrationAllocationPaid {
    launch_id: ObjectID,
    destination: SuiAddress,
    meme: u64,
    quote: u64,
    _meme_vesting_id: Option<ObjectID>,
    _quote_vesting_id: Option<ObjectID>,
}

/// Mirrors `blast_fun::events::ProtocolFeesAccrued`.
#[derive(Deserialize)]
struct ProtocolFeesAccrued {
    launch_id: ObjectID,
    meme_amount: u64,
    quote_amount: u64,
}

/// Two launches without an opening round at MigrationReady.
fn setup() -> Result<(World, Launch, Launch)> {
    let mut w = world("atomic_migration")?;
    let mut launches = Vec::new();
    for _ in 0..2 {
        let launch = w.open_launch(NO_OPENING_ROUND)?;
        w.buy_to_migration(&launch)?;
        launches.push(launch);
    }
    let b = launches.pop().expect("launch B");
    let a = launches.pop().expect("launch A");
    assert_ne!(a.meme, b.meme);

    Ok((w, a, b))
}

/// Publishes the packages and admits SUI and the adapter under the production admin path. Each
/// test passes its own `work` directory for build configuration.
fn world(work: &str) -> Result<World> {
    let fixture = blast_launchpad_ptb_tests::crate_dir().join("fixture");
    let work = blast_launchpad_ptb_tests::test_work_dir().join(env!("CARGO_PKG_NAME")).join(work);
    let mut h = Harness::new()?;

    let stack = publish_stack(&mut h, &work)?;
    let (admin, core, blast) = (stack.admin, stack.core, stack.launchpad);
    let admin_published = &stack.admin_publication;
    let published = &stack.launchpad_publication;
    let one = |outcome: &Outcome, module: &str, name: &str| {
        let ids = outcome.created(&h, module, name);
        assert_eq!(ids.len(), 1, "{module}::{name}");
        ids[0]
    };
    let acl = one(admin_published, "blast_acl", "ACL");
    let root = one(admin_published, "blast_acl", "SuperAdminCap");
    let config = one(published, "launch_config", "LaunchConfig");
    let runtime = one(published, "runtime_config", "RuntimeConfig");
    let launch_registry = h.derived_registry(published, "launch", "LaunchRegistry")?;
    let adapter_code = build(&fixture.join("adapter"), &stack.linked(), &work)?;
    let (adapter, _) = h.publish(adapter_code.clone())?;
    let (version, package_admin) = h.wrap_launchpad(blast, published, admin, admin_published, core, sui(), parse_sui_type_tag(&format!("{adapter}::mock_adapter::Venue"))?)?;
    let project = build(&fixture.join("project"), &stack.linked(), &work)?;
    h.unpause_launchpad(blast, admin, admin_published, version, package_admin, runtime, config, stack.treasury, 7)?;
    let launchpad_code = stack.launchpad_code.clone();
    let mut w = World { h, core, blast, adapter, version, runtime, config, launch_registry, launchpad_origin: blast, project, launchpad_code, adapter_code, admin, acl, root, admin_cap: ObjectID::ZERO, package_admin, treasury: stack.treasury };

    // Production admin path: the configured root owner's SuperAdminCap grants one AdminCap and each role the
    // setters below take; the cap then signs in once per role.
    let mut roles = Vec::new();
    for role in ["ListingAdmin", "VenueAdmin", "FeeAdmin", "TreasuryAdmin"] {
        roles.push(launchpad_role(admin, core, blast, role)?);
    }
    let mut builder = ProgrammableTransactionBuilder::new();
    let acl_arg = builder.obj(w.h.shared(acl, true))?;
    let root_arg = builder.obj(w.h.owned(root))?;
    let recipient = builder.pure(w.h.sender)?;
    call(&mut builder, admin, "blast_acl", "grant_admin", vec![], vec![acl_arg, root_arg, recipient]);
    let granted = w.h.impersonate_cap_owner(root, builder.finish())?;
    granted.assert_success();
    let admin_cap = granted.created(&w.h, "blast_acl", "AdminCap")[0];
    w.admin_cap = admin_cap;

    let mut builder = ProgrammableTransactionBuilder::new();
    let acl_arg = builder.obj(w.h.shared(acl, true))?;
    let root_arg = builder.obj(w.h.owned(root))?;
    let admin_cap_id = builder.pure(admin_cap)?;
    for role in &roles {
        call(&mut builder, admin, "blast_acl", "grant_role", vec![role.clone()], vec![acl_arg, root_arg, admin_cap_id]);
    }
    w.h.impersonate_cap_owner(root, builder.finish())?.assert_success();

    let mut builder = ProgrammableTransactionBuilder::new();
    let acl_arg = builder.obj(w.h.shared(acl, false))?;
    let admin_cap = builder.obj(w.h.owned(admin_cap))?;
    let mut witnesses = Vec::new();
    for role in roles {
        witnesses.push(call(&mut builder, admin, "blast_acl", "sign_in", vec![role], vec![acl_arg, admin_cap]));
    }
    let [_listing_admin, _venue_admin, fee_admin, treasury_admin]: [Argument; 4] =
        witnesses.try_into().expect("one witness per role");
    let config_arg = builder.obj(w.h.shared(config, true))?;
    let version_arg = builder.obj(w.h.shared(version, false))?;
    let fee = w.bps(&mut builder, 100)?;
    let admin_clock = builder.obj(w.h.shared(sui_types::SUI_CLOCK_OBJECT_ID, false))?;
    let next_delay = builder.pure(172_800_000u64)?;
    call(&mut builder, blast, "launch_config", "schedule_trade_fees", vec![], vec![config_arg,
        version_arg,
        fee_admin,
        fee,
        fee, next_delay, admin_clock]);
    let blast_bps = w.bps(&mut builder, BLAST_BPS)?;
    let admin_clock = builder.obj(w.h.shared(sui_types::SUI_CLOCK_OBJECT_ID, false))?;
    let next_delay = builder.pure(172_800_000u64)?;
    call(&mut builder, blast, "launch_config", "schedule_protocol_allocation", vec![], vec![config_arg,
        version_arg,
        treasury_admin,
        blast_bps,
        blast_bps, next_delay, admin_clock]);
    w.h.execute(builder.finish())?.assert_success();
    blast_launchpad_ptb_tests::apply_admin_changes(&mut w.h, vec![
        (blast, "launch_config", "apply_trade_fees", vec![], config, version),
        (blast, "launch_config", "apply_protocol_allocation", vec![], config, version),
    ])?;

    Ok(w)
}

impl World {
    fn sign_in(&self, b: &mut ProgrammableTransactionBuilder, role: &str) -> Result<Argument> {
        let acl = b.obj(self.h.shared(self.acl, false))?;
        let cap = b.obj(self.h.owned(self.admin_cap))?;
        let role = launchpad_role(self.admin, self.core, self.launchpad_origin, role)?;
        Ok(call(b, self.admin, "blast_acl", "sign_in", vec![role], vec![acl, cap]))
    }

    fn change_role(&mut self, role: &str, grant: bool) -> Result<()> {
        let mut b = ProgrammableTransactionBuilder::new();
        let acl = b.obj(self.h.shared(self.acl, true))?;
        let root = b.obj(self.h.owned(self.root))?;
        let cap = b.pure(self.admin_cap)?;
        let role = launchpad_role(self.admin, self.core, self.launchpad_origin, role)?;
        call(&mut b, self.admin, "blast_acl", if grant { "grant_role" } else { "revoke_role" }, vec![role], vec![acl, root, cap]);
        self.h.impersonate_cap_owner(self.root, b.finish())?.assert_success();
        Ok(())
    }

    /// Schedules Blast's trade-fee share at `share` basis points under the FeeAdmin role.
    fn schedule_fee_share(&self, share: u64) -> Result<ProgrammableTransaction> {
        let mut b = ProgrammableTransactionBuilder::new();
        let witness = self.sign_in(&mut b, "FeeAdmin")?;
        let config = b.obj(self.h.shared(self.runtime, true))?;
        let version = b.obj(self.h.shared(self.version, false))?;
        let share = self.bps(&mut b, share)?;
        let clock = b.obj(self.h.shared(SUI_CLOCK_OBJECT_ID, false))?;
        let next_delay = b.pure(172_800_000u64)?;
        call(&mut b, self.blast, "runtime_config", "schedule_protocol_fee_share", vec![], vec![config, version, witness, share, next_delay, clock]);
        Ok(b.finish())
    }

    fn append_cap_recipient(
        &self,
        b: &mut ProgrammableTransactionBuilder,
        launch: &Launch,
        cap: &str,
        role: &str,
        recipient: SuiAddress,
    ) -> Result<()> {
        let witness = self.sign_in(b, role)?;
        let launch_arg = b.obj(self.h.shared(launch.launch, true))?;
        let version = b.obj(self.h.shared(self.version, false))?;
        let recipient = b.pure(recipient)?;
        let clock = b.obj(self.h.shared(SUI_CLOCK_OBJECT_ID, false))?;
        call(b, self.blast, "launch", &format!("schedule_{cap}_reassignment"),
            vec![launch.meme.clone(), sui()], vec![launch_arg, version, witness, recipient, clock]);
        Ok(())
    }

    fn apply_setting(&self, module: &str, function: &str, object: ObjectID) -> Result<ProgrammableTransaction> {
        let mut b = ProgrammableTransactionBuilder::new();
        let config = b.obj(self.h.shared(object, true))?;
        let version = b.obj(self.h.shared(self.version, false))?;
        let clock = b.obj(self.h.shared(SUI_CLOCK_OBJECT_ID, false))?;
        call(&mut b, self.blast, module, function, vec![], vec![config, version, clock]);
        Ok(b.finish())
    }

    fn applied_fee_share(&self) -> Result<u64> {
        let (_, _, fee_share): RuntimeConfigContents = bcs::from_bytes(&self.h.contents(self.runtime))?;
        assert_eq!(fee_share.owner, self.runtime);
        Ok(fee_share.value)
    }

    fn set_pause(&mut self, pause: bool, bits: u8) -> Result<()> {
        self.h.execute(self.pause_command(pause, bits)?)?.assert_success();
        Ok(())
    }

    fn pause_command(&self, pause: bool, bits: u8) -> Result<ProgrammableTransaction> {
        let mut b = ProgrammableTransactionBuilder::new();
        self.append_pause(&mut b, pause, bits, if pause { "PauseAdmin" } else { "UnpauseAdmin" })?;
        Ok(b.finish())
    }

    /// Appends `blast_admin::package_admin::pause` or the launchpad's `launch_config::unpause`
    /// under `role`'s witness.
    fn append_pause(&self, b: &mut ProgrammableTransactionBuilder, pause: bool, bits: u8, role: &str) -> Result<()> {
        let witness = self.sign_in(b, role)?;
        if !pause {
            return append_launchpad_unpause(&self.h, b, self.blast, self.package_admin, self.version, witness, self.runtime, self.config, self.treasury, bits);
        }
        let version = b.obj(self.h.shared(self.version, true))?;
        let bits = b.pure(bits)?;
        call(b, self.admin, "package_admin", "pause", vec![self.otw()?], vec![version, witness, bits]);
        Ok(())
    }

    fn otw(&self) -> Result<TypeTag> {
        blast_launchpad_ptb_tests::launchpad_otw(self.launchpad_origin)
    }

    /// The version's id, paused bits and version.
    fn pause_state(&self) -> Result<(ObjectID, u8, u64)> {
        let (id, _, paused, _, version): GenericPackageVersionContents = bcs::from_bytes(&self.h.contents(self.version))?;
        Ok((id, paused, version))
    }

    fn replace_pause_mask(&mut self, mask: u8) -> Result<()> {
        let (_, current, _) = self.pause_state()?;
        if current != 0 {
            self.set_pause(false, current)?;
        }
        if mask != 0 {
            self.set_pause(true, mask)?;
        }
        Ok(())
    }

    /// Only seed the stored version; masks are always reached through real public calls.
    fn set_pause_version_for_fixture(&mut self, version: u64) -> Result<()> {
        let (id, valid, paused, witness, _): GenericPackageVersionContents = bcs::from_bytes(&self.h.contents(self.version))?;
        let mut object = self.h.object(self.version);
        object.data.try_as_move_mut().expect("PackageVersion")
            .set_contents_unsafe(bcs::to_bytes(&(id, valid, paused, witness, version))?);
        self.h.insert(object);
        Ok(())
    }

    /// Publishes one generated project and opens its SUI-quoted launch with `opening_round_ms`,
    /// with the LP-fee split paying `DESTINATION` wholly.
    fn open_launch(&mut self, opening_round_ms: u64) -> Result<Launch> {
        let ticket = self.publish_ticket()?;
        let pt = self.create_launch(&ticket, &FeeSplit::single(DESTINATION.into()), opening_round_ms)?;
        let created = self.h.execute(pt)?;

        Ok(self.created_launch(&created, ticket))
    }

    /// Opens `ticket`'s launch without an opening round with `fee_split` and returns it with the
    /// creation outcome.
    fn open_split_launch(&mut self, ticket: Ticket, fee_split: &FeeSplit) -> Result<(Launch, Outcome)> {
        let created = self.h.execute(self.create_launch(&ticket, fee_split, NO_OPENING_ROUND)?)?;

        Ok((self.created_launch(&created, ticket), created))
    }

    /// One PTB that has the mock venue prepare `ticket`'s coin, starts its launch with the venue
    /// ticket and the coin's `TreasuryCap`, sets the graduation target, the allocation plan,
    /// `fee_split`, and any opening round, then finalizes and shares it.
    fn create_launch(
        &self,
        ticket: &Ticket,
        fee_split: &FeeSplit,
        opening_round_ms: u64,
    ) -> Result<ProgrammableTransaction> {
        let mut builder = ProgrammableTransactionBuilder::new();
        let fee_split = fee_split.arg(&mut builder, self.core)?;
        let plan = self.plan_arg(&mut builder)?;
        let launch_ticket = builder.obj(self.h.owned(ticket.ticket))?;
        let treasury_cap = builder.obj(self.h.owned(ticket.treasury_cap))?;
        let version = builder.obj(self.h.shared(self.version, false))?;
        let config = builder.obj(self.h.shared(self.config, false))?;
        let venue_ticket = call(&mut builder, self.adapter, "mock_adapter", "prepare", vec![ticket.meme.clone()], vec![]);
        let pair = vec![ticket.meme.clone(), sui()];
        let initializer = call(&mut builder, self.blast, "launch", "new", pair.clone(), vec![
            launch_ticket,
            treasury_cap,
            version,
            config,
            venue_ticket,
        ]);
        let virtual_quote = builder.pure(5_000_000u64)?;
        call(&mut builder, self.blast, "launch", "set_virtual_quote", pair.clone(), vec![initializer, version, virtual_quote]);
        let target = builder.pure(TARGET)?;
        call(&mut builder, self.blast, "launch", "set_graduation_target", pair.clone(), vec![initializer, version, target]);
        call(&mut builder, self.blast, "launch", "set_allocation_plan", pair.clone(), vec![initializer, version, plan]);
        call(&mut builder, self.blast, "launch", "set_lp_fee_split", pair.clone(), vec![initializer, version, fee_split]);
        if opening_round_ms != NO_OPENING_ROUND {
            let opening_round_ms = builder.pure(opening_round_ms)?;
            call(&mut builder, self.blast, "launch", "set_opening_round", pair.clone(), vec![
                initializer, version,
                opening_round_ms,
            ]);
        }
        let currency = builder.obj(self.h.shared(ticket.currency, true))?;
        let creation_fee = call(&mut builder, SUI_FRAMEWORK_PACKAGE_ID, "coin", "zero", vec![sui()], vec![]);
        let registry = builder.obj(self.h.shared(self.launch_registry, true))?;
        let launch = call(&mut builder, self.blast, "launch", "finalize", pair.clone(), vec![
            initializer, version,
            registry,
            currency,
            config,
            creation_fee,
        ]);
        let clock = builder.obj(self.h.shared(SUI_CLOCK_OBJECT_ID, false))?;
        call(&mut builder, self.blast, "launch", "share", pair, vec![launch, version, clock]);

        Ok(builder.finish())
    }

    /// Publishes one generated project, which runs its OTW init: the ticket and the coin's
    /// `TreasuryCap` go to the publisher and the Currency to the registry, which must finalize it
    /// into its shared form.
    fn publish_ticket(&mut self) -> Result<Ticket> {
        let (project_id, published) = self.h.publish(self.project.clone())?;
        assert_eq!(published.payload_names(self.blast), ["LaunchTicketCreated"]);
        let ticket = published.created(&self.h, "launch_ticket", "LaunchTicket")[0];
        let treasury_cap = published.created(&self.h, "coin", "TreasuryCap");
        assert_eq!(treasury_cap.len(), 1, "the publisher receives the coin's TreasuryCap");
        assert_eq!(self.h.object(treasury_cap[0]).owner().get_address_owner_address()?, self.h.sender);
        let pending_currency = published.created(&self.h, "coin_registry", "Currency")[0];
        let meme = parse_sui_type_tag(&format!("{project_id}::token::TOKEN"))?;

        let mut builder = ProgrammableTransactionBuilder::new();
        let registry = builder.obj(self.h.shared(SUI_COIN_REGISTRY_OBJECT_ID, true))?;
        let receiving = builder.obj(ObjectArg::Receiving(
            self.h.object(pending_currency).compute_object_reference(),
        ))?;
        call(&mut builder, SUI_FRAMEWORK_PACKAGE_ID, "coin_registry", "finalize_registration", vec![
            meme.clone(),
        ], vec![registry, receiving]);
        let finalized = self.h.execute(builder.finish())?;
        finalized.assert_success();
        let currency = finalized.created(&self.h, "coin_registry", "Currency")[0];

        Ok(Ticket { meme, ticket, treasury_cap: treasury_cap[0], currency })
    }

    /// The launch a successful creation shared. Finalization consumes the coin's `TreasuryCap`,
    /// fixing the supply.
    fn created_launch(&self, created: &Outcome, ticket: Ticket) -> Launch {
        created.assert_success();
        assert!(created.consumed(ticket.treasury_cap), "finalize consumes the TreasuryCap");
        assert_eq!(
            created.payload_names(self.blast),
            ["LaunchCreated", "LaunchShared"],
        );
        let launch = created.created(&self.h, "launch", "Launch");
        assert_eq!(launch.len(), 1, "launch::Launch");
        assert!(self.h.object(launch[0]).is_shared());
        let derived = blast_launchpad_ptb_tests::launch_id(self.launchpad_origin, self.launch_registry, &ticket.meme)
            .expect("derive the launch ID");
        assert_eq!(launch[0], derived, "the launch ID derives from the registry and the coin type");

        Launch { meme: ticket.meme, launch: launch[0], currency: ticket.currency }
    }

    /// Decodes the one `LaunchCreated` of a creation.
    fn launch_created(&self, created: &Outcome) -> Result<LaunchCreated> {
        let launch_created = created.events_of("events", "LaunchCreated");
        assert_eq!(launch_created.len(), 1);

        Ok(bcs::from_bytes(launch_created[0])?)
    }

    fn adapter_type(&self, name: &str) -> Result<TypeTag> {
        parse_sui_type_tag(&format!("{}::mock_adapter::{name}", self.adapter))
    }

    fn buy_to_migration(&mut self, launch: &Launch) -> Result<()> {
        let pt = self.buy(launch, BUY, 1)?;
        let bought = self.h.execute(pt)?;
        bought.assert_success();
        assert_eq!(bought.payload_names(self.blast), ["Bought"]);
        assert_eq!(self.launch_lifecycle(launch)?, LaunchLifecycle::MigrationReady);

        Ok(())
    }

    /// Buys from `launch` with `quote_in` MIST split from gas and keeps both returned coins.
    fn buy(&self, launch: &Launch, quote_in: u64, min_meme_out: u64) -> Result<ProgrammableTransaction> {
        let mut builder = ProgrammableTransactionBuilder::new();
        let amount = builder.pure(quote_in)?;
        let Argument::Result(split) = builder.command(Command::SplitCoins(Argument::GasCoin, vec![amount])) else {
            unreachable!()
        };
        let launch_arg = builder.obj(self.h.shared(launch.launch, true))?;
        let version = builder.obj(self.h.shared(self.version, false))?;
        let runtime = builder.obj(self.h.shared(self.runtime, false))?;
        let min_out = builder.pure(min_meme_out)?;
        let Argument::Result(bought) = call(
            &mut builder,
            self.blast,
            "launch",
            "buy",
            vec![launch.meme.clone(), sui()],
            vec![launch_arg, version, runtime, Argument::NestedResult(split, 0), min_out],
        ) else {
            unreachable!()
        };
        builder.transfer_args(self.h.sender, vec![
            Argument::NestedResult(bought, 0),
            Argument::NestedResult(bought, 1),
        ]);

        Ok(builder.finish())
    }

    /// Joins `launch`'s opening round with `quote_in` MIST split from gas.
    fn join(&self, launch: &Launch, quote_in: u64) -> Result<ProgrammableTransaction> {
        let mut builder = ProgrammableTransactionBuilder::new();
        let amount = builder.pure(quote_in)?;
        let Argument::Result(split) = builder.command(Command::SplitCoins(Argument::GasCoin, vec![amount])) else {
            unreachable!()
        };
        let launch_arg = builder.obj(self.h.shared(launch.launch, true))?;
        let version = builder.obj(self.h.shared(self.version, false))?;
        let clock = builder.obj(self.h.shared(SUI_CLOCK_OBJECT_ID, false))?;
        call(&mut builder, self.blast, "launch", "join_opening_round", vec![launch.meme.clone(), sui()], vec![
            launch_arg,
            version,
            Argument::NestedResult(split, 0),
            clock,
        ]);

        Ok(builder.finish())
    }

    /// Settles `launch`'s opening round.
    fn settle(&self, launch: &Launch) -> Result<ProgrammableTransaction> {
        let mut builder = ProgrammableTransactionBuilder::new();
        let launch_arg = builder.obj(self.h.shared(launch.launch, true))?;
        let version = builder.obj(self.h.shared(self.version, false))?;
        let runtime = builder.obj(self.h.shared(self.runtime, false))?;
        let clock = builder.obj(self.h.shared(SUI_CLOCK_OBJECT_ID, false))?;
        call(&mut builder, self.blast, "launch", "settle_opening_round", vec![launch.meme.clone(), sui()], vec![
            launch_arg,
            version,
            runtime,
            clock,
        ]);

        Ok(builder.finish())
    }

    /// Delivers `bidder`'s share of `launch`'s settled opening round.
    fn deliver(&self, launch: &Launch, bidder: SuiAddress) -> Result<ProgrammableTransaction> {
        let mut builder = ProgrammableTransactionBuilder::new();
        let launch_arg = builder.obj(self.h.shared(launch.launch, true))?;
        let version = builder.obj(self.h.shared(self.version, false))?;
        let bidder = builder.pure(bidder)?;
        call(&mut builder, self.blast, "launch", "deliver_opening_round", vec![launch.meme.clone(), sui()], vec![
            launch_arg,
            version,
            bidder,
        ]);

        Ok(builder.finish())
    }

    /// The coins one payment of `meme` and `quote` on `launch` creates, in `coins_created_for` order.
    fn coins(&self, launch: &Launch, meme: u64, quote: u64) -> Vec<(String, u64)> {
        let mut coins = vec![
            (launch.meme.to_canonical_string(true), meme),
            (sui().to_canonical_string(true), quote),
        ];
        coins.retain(|(_, value)| *value > 0);
        coins.sort();
        coins
    }

    fn launch_lifecycle(&self, launch: &Launch) -> Result<LaunchLifecycle> {
        let contents = self.h.contents(launch.launch);
        let (_, lifecycle): (ObjectID, LaunchLifecycle) = bcs::from_bytes(&contents[..33])?;

        Ok(lifecycle)
    }

    /// The two-call migration: `launch::migrate` with `launch`'s launch and `currency_owner`'s
    /// currency returns the `Migration`, and the adapter's `migrate` redeems it.
    fn migrate(&self, launch: &Launch, currency_owner: &Launch, fail: bool) -> Result<ProgrammableTransaction> {
        let mut builder = ProgrammableTransactionBuilder::new();
        let launch_arg = builder.obj(self.h.shared(launch.launch, true))?;
        let version = builder.obj(self.h.shared(self.version, false))?;
        let config = builder.obj(self.h.shared(self.config, false))?;
        let currency = builder.obj(self.h.shared(currency_owner.currency, true))?;
        let clock = builder.obj(self.h.shared(SUI_CLOCK_OBJECT_ID, false))?;
        let migration = call(&mut builder, self.blast, "launch", "migrate", vec![launch.meme.clone(), sui()], vec![
            launch_arg,
            version,
            config,
            currency,
            clock,
        ]);
        let fail = builder.pure(fail)?;
        call(&mut builder, self.adapter, "mock_adapter", "migrate", vec![launch.meme.clone()], vec![migration, fail]);

        Ok(builder.finish())
    }

    /// Appends `launch::migrate` directly, returning its `Migration` hand-off.
    fn launch_migrate(&self, builder: &mut ProgrammableTransactionBuilder, launch: &Launch) -> Result<Argument> {
        let launch_arg = builder.obj(self.h.shared(launch.launch, true))?;
        let version = builder.obj(self.h.shared(self.version, false))?;
        let config = builder.obj(self.h.shared(self.config, false))?;
        let currency = builder.obj(self.h.shared(launch.currency, true))?;
        let clock = builder.obj(self.h.shared(SUI_CLOCK_OBJECT_ID, false))?;

        Ok(call(builder, self.blast, "launch", "migrate", vec![launch.meme.clone(), sui()], vec![
            launch_arg,
            version,
            config,
            currency,
            clock,
        ]))
    }

    /// The creator, the sender, claims both creator capabilities and keeps them; returns the
    /// curve-fee cap.
    fn claim_curve_fee_cap(&mut self, launch: &Launch) -> Result<ObjectID> {
        let mut builder = ProgrammableTransactionBuilder::new();
        let launch_arg = builder.obj(self.h.shared(launch.launch, true))?;
        let version = builder.obj(self.h.shared(self.version, false))?;
        let runtime = builder.obj(self.h.shared(self.runtime, false))?;
        let none = builder.pure(Option::<Vec<u8>>::None)?;
        let clock = builder.obj(self.h.shared(SUI_CLOCK_OBJECT_ID, false))?;
        let Argument::Result(caps) = call(
            &mut builder,
            self.blast,
            "launch",
            "claim_creator_caps",
            vec![launch.meme.clone(), sui()],
            vec![launch_arg, version, runtime, none, clock],
        ) else {
            unreachable!()
        };
        builder.transfer_args(self.h.sender, vec![Argument::NestedResult(caps, 0), Argument::NestedResult(caps, 1)]);
        let claimed = self.h.execute(builder.finish())?;
        claimed.assert_success();
        let cap = claimed.created(&self.h, "creator_authority", "CurveFeeCap");
        assert_eq!(cap.len(), 1);

        Ok(cap[0])
    }
}

/// Launch fixtures and measurements.
impl World {
    fn bps(&self, builder: &mut ProgrammableTransactionBuilder, value: u64) -> Result<Argument> {
        let value = builder.pure(value)?;

        Ok(call(builder, self.core, "bps", "new", vec![], vec![value]))
    }

    /// The fixture plan: 70% of the Meme on the curve, 20% of the Meme and 90% of the Quote to
    /// the pool, and 5% of each to `DESTINATION`; finalization records Blast's 5% of each as the
    /// explicit protocol allocation.
    fn plan_arg(&self, builder: &mut ProgrammableTransactionBuilder) -> Result<Argument> {
        let destination = builder.pure(SuiAddress::from(DESTINATION))?;
        let vesting_terms = parse_sui_type_tag(&format!("{}::payout::VestingTerms", self.core))?;
        let outright = call(builder, sui_types::MOVE_STDLIB_PACKAGE_ID, "option", "none", vec![vesting_terms], vec![]);
        let payee = call(builder, self.core, "payout", "recipient", vec![], vec![destination, outright]);
        let share = self.bps(builder, 500)?;
        let recipient = call(builder, self.blast, "allocation", "recipient_share", vec![], vec![payee, share, share]);
        let recipient_type = parse_sui_type_tag(&format!("{}::allocation::RecipientShare", self.blast))?;
        let recipients = builder.command(Command::make_move_vec(Some(recipient_type), vec![recipient]));
        let curve_meme = self.bps(builder, 7_000)?;
        let lp_meme = self.bps(builder, 2_000)?;
        let lp_quote = self.bps(builder, 9_000)?;

        Ok(call(builder, self.blast, "allocation", "plan", vec![], vec![curve_meme, lp_meme, lp_quote, recipients]))
    }

    /// One measurement: the operation and fixture, the launch object's size afterwards, and the
    /// transaction's resources against the protocol limits.
    fn record(&self, launch: &Launch, operation: &str, fixture: &str, outcome: &Outcome) -> Value {
        json!({
            "operation": operation,
            "fixture": fixture,
            "launch_object": {
                "contents_bytes": self.h.contents(launch.launch).len(),
                "metered_bytes": self.h.object(launch.launch).object_size_for_gas_metering(),
            },
            "resources": self.h.resources(outcome),
        })
    }
}

fn sui() -> TypeTag {
    parse_sui_type_tag("0x2::sui::SUI").expect("SUI type")
}
