//! Generic delayed UpgradeCap management exercised through native publication, upgrade and burn commands.
//! The simulator is entirely local; no RPC, wallets or chain transactions are used.
use std::{path::PathBuf, sync::OnceLock, time::Duration};

use anyhow::Result;
use blast_launchpad_ptb_tests::{CompiledPackage, Expected, Harness, Outcome, build, call, crate_dir};
use move_binary_format::{CompiledModule, file_format::Bytecode};
use serde::{Deserialize, Serialize};
use sui_types::{
    MOVE_STDLIB_PACKAGE_ID, SUI_CLOCK_OBJECT_ID, SUI_FRAMEWORK_PACKAGE_ID, TypeTag,
    base_types::ObjectID,
    dynamic_field::derive_dynamic_field_id,
    effects::TransactionEffectsAPI,
    move_package::MovePackage,
    object::Owner,
    programmable_transaction_builder::ProgrammableTransactionBuilder,
    transaction::{Argument, ProgrammableTransaction},
};

const DELAY: u64 = 172_800_000;
const MODULE: &str = "blast_upgrade_cap_manager";

struct World {
    h: Harness,
    wrapper: ObjectID,
    target: ObjectID,
    native_cap: ObjectID,
    lock: ObjectID,
    controller: ObjectID,
    code: CompiledPackage,
}

#[derive(Debug, Deserialize, Serialize, PartialEq)]
enum Action {
    Upgrade { digest: Vec<u8> },
    MakeImmutable,
}

#[derive(Debug, Deserialize, PartialEq)]
struct Request {
    action: Action,
    ready_at_ms: u64,
}

#[derive(Debug, Deserialize, PartialEq)]
struct Lock {
    id: ObjectID,
    caps: ObjectTable,
}

#[derive(Debug, Deserialize, PartialEq)]
struct ObjectTable {
    id: ObjectID,
    size: u64,
}

fn packages() -> &'static (CompiledPackage, CompiledPackage) {
    static PACKAGES: OnceLock<(CompiledPackage, CompiledPackage)> = OnceLock::new();
    PACKAGES.get_or_init(|| {
        let source = crate_dir().join("../../upgrade_cap_manager");
        let work: PathBuf = crate_dir().join("target/ptb-fixtures/upgrade-cap-manager");
        std::fs::create_dir_all(&work).unwrap();
        (build(&source, &[], &work).unwrap(), build(&source.join("fixtures/upgrade_target"), &[], &work).unwrap())
    })
}

fn world() -> Result<World> {
    let (wrapper_code, target_code) = packages();
    let mut h = Harness::new()?;
    let (wrapper, published) = h.publish(wrapper_code.clone())?;
    let own_cap = published.created(&h, "package", "UpgradeCap")[0];
    let (target, target_publication) = h.publish(target_code.clone())?;
    let native_cap = target_publication.created(&h, "package", "UpgradeCap")[0];

    // Immutability is an operational prerequisite, verified from native cap deletion effects.
    let mut b = ProgrammableTransactionBuilder::new();
    let cap = b.obj(h.owned(own_cap))?;
    call(&mut b, SUI_FRAMEWORK_PACKAGE_ID, "package", "make_immutable", vec![], vec![cap]);
    let sealed = h.execute(b.finish())?;
    sealed.assert_success();
    assert!(sealed.effects.deleted().iter().any(|(id, _, _)| *id == own_cap));

    let mut b = ProgrammableTransactionBuilder::new();
    let cap = b.obj(h.owned(native_cap))?;
    let enrolled = call(&mut b, wrapper, MODULE, "new", vec![], vec![cap]);
    let Argument::Result(index) = enrolled else { panic!("enrollment result") };
    call(&mut b, wrapper, MODULE, "share", vec![], vec![Argument::NestedResult(index, 0)]);
    b.transfer_arg(h.sender, Argument::NestedResult(index, 1));
    let enrolled = h.execute(b.finish())?;
    enrolled.assert_success();
    let lock = enrolled.created(&h, MODULE, "UpgradeCapManager")[0];
    let controller = enrolled.created(&h, MODULE, "ManagerCap")[0];
    assert!(h.object(lock).is_shared());
    assert_custody(&h, lock, native_cap)?;
    assert_eq!(enrolled.events_of(MODULE, "ManagerCreated"), [bcs::to_bytes(&(lock, controller))?.as_slice()]);
    assert_eq!(
        enrolled.events_of(MODULE, "UpgradeCapAdded"),
        [bcs::to_bytes(&(lock, native_cap, target, 0u8))?.as_slice()]
    );
    Ok(World { h, wrapper, target, native_cap, lock, controller, code: target_code.clone() })
}

impl World {
    fn request_make_immutable(&self) -> Result<ProgrammableTransaction> {
        let mut b = ProgrammableTransactionBuilder::new();
        let lock = b.obj(self.h.shared(self.lock, true))?;
        let cap_id = b.pure(self.native_cap)?;
        let controller = b.obj(self.h.owned(self.controller))?;
        let clock = b.obj(self.h.shared(SUI_CLOCK_OBJECT_ID, false))?;
        call(&mut b, self.wrapper, MODULE, "request_make_immutable", vec![], vec![lock, controller, cap_id, clock]);
        Ok(b.finish())
    }

    fn make_immutable(&self) -> Result<ProgrammableTransaction> {
        let mut b = ProgrammableTransactionBuilder::new();
        let lock = b.obj(self.h.shared(self.lock, true))?;
        let cap_id = b.pure(self.native_cap)?;
        let clock = b.obj(self.h.shared(SUI_CLOCK_OBJECT_ID, false))?;
        call(&mut b, self.wrapper, MODULE, "make_immutable", vec![], vec![lock, cap_id, clock]);
        Ok(b.finish())
    }

    fn request(&self, digest: Vec<u8>) -> Result<ProgrammableTransaction> {
        let mut b = ProgrammableTransactionBuilder::new();
        let lock = b.obj(self.h.shared(self.lock, true))?;
        let cap_id = b.pure(self.native_cap)?;
        let controller = b.obj(self.h.owned(self.controller))?;
        let digest = b.pure(digest)?;
        let clock = b.obj(self.h.shared(SUI_CLOCK_OBJECT_ID, false))?;
        call(&mut b, self.wrapper, MODULE, "request_upgrade", vec![], vec![lock, controller, cap_id, digest, clock]);
        Ok(b.finish())
    }

    fn cancel(&self) -> Result<ProgrammableTransaction> {
        let mut b = ProgrammableTransactionBuilder::new();
        let lock = b.obj(self.h.shared(self.lock, true))?;
        let cap_id = b.pure(self.native_cap)?;
        let controller = b.obj(self.h.owned(self.controller))?;
        call(&mut b, self.wrapper, MODULE, "cancel_request", vec![], vec![lock, controller, cap_id]);
        Ok(b.finish())
    }

    fn upgrade(&self, code: &CompiledPackage, commit: bool) -> Result<ProgrammableTransaction> {
        let mut b = ProgrammableTransactionBuilder::new();
        let lock = b.obj(self.h.shared(self.lock, true))?;
        let cap_id = b.pure(self.native_cap)?;
        let clock = b.obj(self.h.shared(SUI_CLOCK_OBJECT_ID, false))?;
        let ticket = call(&mut b, self.wrapper, MODULE, "authorize_upgrade", vec![], vec![lock, cap_id, clock]);
        let receipt = b.upgrade(self.target, ticket, code.dependencies.clone(), code.modules.clone());
        if commit {
            call(&mut b, self.wrapper, MODULE, "commit_upgrade", vec![], vec![lock, receipt]);
        }
        Ok(b.finish())
    }

    fn reject(&mut self, tx: ProgrammableTransaction, expected: Expected) -> Result<Outcome> {
        self.h.assert_rolled_back(tx, expected, &[self.lock, self.native_cap, self.controller], &[self.h.sender])
    }

    fn abort(&mut self, tx: ProgrammableTransaction, code: u64) -> Result<Outcome> {
        self.reject(tx, Expected::Abort { package: self.wrapper, module: MODULE, code })
    }

    fn state(&self) -> Result<Lock> {
        Ok(bcs::from_bytes(&self.h.contents(self.lock))?)
    }

    fn pending(&self) -> Result<Option<Request>> {
        pending(&self.h, self.lock, self.native_cap)
    }

    fn native_state(&self) -> Result<(ObjectID, ObjectID, u64, u8)> {
        Ok(bcs::from_bytes(&self.h.contents(self.native_cap))?)
    }
}

fn upgraded(code: &CompiledPackage) -> Result<CompiledPackage> {
    upgraded_to(code, 2)
}

fn upgraded_to(code: &CompiledPackage, return_value: u64) -> Result<CompiledPackage> {
    let mut code = code.clone();
    let mut module = CompiledModule::deserialize_with_defaults(&code.modules[0])?;
    let mut changed = 0;
    for function in &mut module.function_defs {
        if let Some(body) = &mut function.code {
            for instruction in &mut body.code {
                if *instruction == Bytecode::LdU64(1) {
                    *instruction = Bytecode::LdU64(return_value);
                    changed += 1;
                }
            }
        }
    }
    assert_eq!(changed, 1);
    code.modules[0].clear();
    module.serialize_with_version(module.version, &mut code.modules[0])?;
    Ok(code)
}

fn digest(code: &CompiledPackage) -> Vec<u8> {
    MovePackage::compute_digest_for_modules_and_deps(&code.modules, &code.dependencies, true).to_vec()
}

#[test]
fn exact_deadline_native_upgrade_and_replay() -> Result<()> {
    let mut w = world()?;
    let code = upgraded(&w.code)?;
    let (_, now): (ObjectID, u64) = bcs::from_bytes(&w.h.contents(SUI_CLOCK_OBJECT_ID))?;
    let requested = w.h.execute(w.request(digest(&code))?)?;
    requested.assert_success();
    assert_eq!(
        requested.events_of(MODULE, "UpgradeRequested"),
        [bcs::to_bytes(&(w.lock, w.native_cap, digest(&code), now, now + DELAY))?.as_slice()]
    );
    assert_eq!(
        w.pending()?,
        Some(Request { action: Action::Upgrade { digest: digest(&code) }, ready_at_ms: now + DELAY })
    );
    w.abort(w.request(digest(&code))?, 2)?;
    w.abort(w.upgrade(&code, true)?, 7)?;
    w.h.sim.advance_clock(Duration::from_millis(DELAY - 1));
    w.abort(w.upgrade(&code, true)?, 7)?;
    w.h.sim.advance_clock(Duration::from_millis(1));
    // No controller input at execution: moving authority away does not block a mature proposal.
    let recipient = sui_types::base_types::SuiAddress::from(ObjectID::from_hex_literal("0xbeef")?);
    let mut b = ProgrammableTransactionBuilder::new();
    let controller = b.obj(w.h.owned(w.controller))?;
    b.transfer_arg(recipient, controller);
    w.h.execute(b.finish())?.assert_success();
    let applied = w.h.execute(w.upgrade(&code, true)?)?;
    applied.assert_success();
    let new_package = applied.effects.published_packages()[0];
    assert_eq!(
        applied.events_of(MODULE, "UpgradeAuthorized"),
        [bcs::to_bytes(&(w.lock, w.native_cap, digest(&code), now + DELAY))?.as_slice()]
    );
    assert_eq!(
        applied.events_of(MODULE, "UpgradeCommitted"),
        [bcs::to_bytes(&(w.lock, w.native_cap, new_package, 2u64))?.as_slice()]
    );
    assert_eq!(w.native_state()?, (w.native_cap, new_package, 2, 0));
    assert!(w.pending()?.is_none());
    assert_custody(&w.h, w.lock, w.native_cap)?;
    w.target = new_package;
    w.abort(w.upgrade(&code, true)?, 5)?;
    Ok(())
}

#[test]
fn digest_mismatch_and_uncommitted_receipt_roll_back_then_retry() -> Result<()> {
    let mut w = world()?;
    let code = upgraded(&w.code)?;
    w.h.execute(w.request(digest(&code))?)?.assert_success();
    w.h.sim.advance_clock(Duration::from_millis(DELAY));
    w.reject(w.upgrade(&w.code, true)?, Expected::Error("DigestDoesNotMatch"))?;
    w.reject(w.upgrade(&code, false)?, Expected::Error("UnusedValueWithoutDrop"))?;
    let mut b = ProgrammableTransactionBuilder::new();
    let lock = b.obj(w.h.shared(w.lock, true))?;
    let cap_id = b.pure(w.native_cap)?;
    let clock = b.obj(w.h.shared(SUI_CLOCK_OBJECT_ID, false))?;
    call(&mut b, w.wrapper, MODULE, "authorize_upgrade", vec![], vec![lock, cap_id, clock]);
    w.reject(b.finish(), Expected::Error("UnusedValueWithoutDrop"))?;
    assert!(w.pending()?.is_some());
    w.h.execute(w.upgrade(&code, true)?)?.assert_success();
    Ok(())
}

#[test]
fn cancellation_restarts_full_delay_and_next_upgrade_waits_again() -> Result<()> {
    let mut w = world()?;
    let code = upgraded(&w.code)?;
    w.h.execute(w.request(digest(&code))?)?.assert_success();
    let ready_at_ms = w.pending()?.expect("pending upgrade").ready_at_ms;
    w.h.sim.advance_clock(Duration::from_millis(DELAY + 1));
    let cancelled = w.h.execute(w.cancel()?)?;
    cancelled.assert_success();
    let (_, cancelled_at): (ObjectID, u64) = bcs::from_bytes(&w.h.contents(SUI_CLOCK_OBJECT_ID))?;
    assert!(cancelled_at > ready_at_ms);
    assert_eq!(
        cancelled.events_of(MODULE, "RequestCancelled"),
        [bcs::to_bytes(&(w.lock, w.native_cap, Action::Upgrade { digest: digest(&code) }, ready_at_ms))?.as_slice()],
    );
    w.abort(w.upgrade(&code, true)?, 5)?;
    w.h.execute(w.request(digest(&code))?)?.assert_success();
    w.abort(w.upgrade(&code, true)?, 7)?;
    w.h.sim.advance_clock(Duration::from_millis(DELAY));
    let applied = w.h.execute(w.upgrade(&code, true)?)?;
    applied.assert_success();
    w.target = applied.effects.published_packages()[0];
    w.h.execute(w.request(digest(&code))?)?.assert_success();
    w.abort(w.upgrade(&code, true)?, 7)?;
    w.h.sim.advance_clock(Duration::from_millis(DELAY));
    w.h.execute(w.upgrade(&code, true)?)?.assert_success();
    assert_eq!(w.native_state()?.2, 3);
    Ok(())
}

#[test]
fn enrollment_cannot_launder_a_pre_authorized_ticket() -> Result<()> {
    let mut w = world()?;
    let (target, published) = w.h.publish(w.code.clone())?;
    let native_cap = published.created(&w.h, "package", "UpgradeCap")[0];
    let code = upgraded(&w.code)?;
    let mut b = ProgrammableTransactionBuilder::new();
    let cap = b.obj(w.h.owned(native_cap))?;
    let policy = b.pure(0u8)?;
    let hash = b.pure(digest(&code))?;
    let ticket =
        call(&mut b, SUI_FRAMEWORK_PACKAGE_ID, "package", "authorize_upgrade", vec![], vec![cap, policy, hash]);
    let result = call(&mut b, w.wrapper, MODULE, "new", vec![], vec![cap]);
    let Argument::Result(index) = result else { panic!("enrollment result") };
    let new_lock = Argument::NestedResult(index, 0);
    let receipt = b.upgrade(target, ticket, code.dependencies, code.modules);
    call(&mut b, w.wrapper, MODULE, "commit_upgrade", vec![], vec![new_lock, receipt]);
    call(&mut b, w.wrapper, MODULE, "share", vec![], vec![new_lock]);
    b.transfer_arg(w.h.sender, Argument::NestedResult(index, 1));
    w.h.assert_rolled_back(
        b.finish(),
        Expected::Abort { package: w.wrapper, module: MODULE, code: 0 },
        &[native_cap],
        &[w.h.sender],
    )?;
    Ok(())
}

#[test]
fn controller_and_receipt_cannot_cross_timelocks() -> Result<()> {
    let mut w = world()?;
    let (other_target, published) = w.h.publish(w.code.clone())?;
    let other_cap = published.created(&w.h, "package", "UpgradeCap")[0];
    let mut b = ProgrammableTransactionBuilder::new();
    let cap = b.obj(w.h.owned(other_cap))?;
    let result = call(&mut b, w.wrapper, MODULE, "new", vec![], vec![cap]);
    let Argument::Result(index) = result else { panic!("enrollment result") };
    call(&mut b, w.wrapper, MODULE, "share", vec![], vec![Argument::NestedResult(index, 0)]);
    b.transfer_arg(w.h.sender, Argument::NestedResult(index, 1));
    let enrolled = w.h.execute(b.finish())?;
    enrolled.assert_success();
    let other_lock = enrolled.created(&w.h, MODULE, "UpgradeCapManager")[0];
    let other_controller = enrolled.created(&w.h, MODULE, "ManagerCap")[0];
    let code = upgraded(&w.code)?;
    let mut b = ProgrammableTransactionBuilder::new();
    let lock = b.obj(w.h.shared(other_lock, true))?;
    let cap_id = b.pure(other_cap)?;
    let wrong = b.obj(w.h.owned(w.controller))?;
    let hash = b.pure(digest(&code))?;
    let clock = b.obj(w.h.shared(SUI_CLOCK_OBJECT_ID, false))?;
    call(&mut b, w.wrapper, MODULE, "request_upgrade", vec![], vec![lock, wrong, cap_id, hash, clock]);
    w.h.assert_rolled_back(
        b.finish(),
        Expected::Abort { package: w.wrapper, module: MODULE, code: 1 },
        &[other_lock, other_cap, w.controller],
        &[w.h.sender],
    )?;

    for function in ["request_make_immutable", "cancel_request"] {
        let mut b = ProgrammableTransactionBuilder::new();
        let lock = b.obj(w.h.shared(other_lock, true))?;
        let cap_id = b.pure(other_cap)?;
        let wrong = b.obj(w.h.owned(w.controller))?;
        let mut args = vec![lock, wrong, cap_id];
        if function == "request_make_immutable" {
            args.push(b.obj(w.h.shared(SUI_CLOCK_OBJECT_ID, false))?);
        }
        call(&mut b, w.wrapper, MODULE, function, vec![], args);
        w.h.assert_rolled_back(
            b.finish(),
            Expected::Abort { package: w.wrapper, module: MODULE, code: 1 },
            &[other_lock, other_cap, w.controller],
            &[w.h.sender],
        )?;
    }

    w.h.execute(w.request(digest(&code))?)?.assert_success();
    let mut b = ProgrammableTransactionBuilder::new();
    let lock = b.obj(w.h.shared(other_lock, true))?;
    let cap_id = b.pure(other_cap)?;
    let controller = b.obj(w.h.owned(other_controller))?;
    let hash = b.pure(digest(&code))?;
    let clock = b.obj(w.h.shared(SUI_CLOCK_OBJECT_ID, false))?;
    call(&mut b, w.wrapper, MODULE, "request_upgrade", vec![], vec![lock, controller, cap_id, hash, clock]);
    w.h.execute(b.finish())?.assert_success();
    w.h.sim.advance_clock(Duration::from_millis(DELAY));

    let mut b = ProgrammableTransactionBuilder::new();
    let lock = b.obj(w.h.shared(w.lock, true))?;
    let cap_id = b.pure(w.native_cap)?;
    let other = b.obj(w.h.shared(other_lock, true))?;
    let clock = b.obj(w.h.shared(SUI_CLOCK_OBJECT_ID, false))?;
    let first_ticket = call(&mut b, w.wrapper, MODULE, "authorize_upgrade", vec![], vec![lock, cap_id, clock]);
    let other_id = b.pure(other_cap)?;
    let second_ticket = call(&mut b, w.wrapper, MODULE, "authorize_upgrade", vec![], vec![other, other_id, clock]);
    let first_receipt = b.upgrade(w.target, first_ticket, code.dependencies.clone(), code.modules.clone());
    let second_receipt = b.upgrade(other_target, second_ticket, code.dependencies, code.modules);
    call(&mut b, w.wrapper, MODULE, "commit_upgrade", vec![], vec![lock, second_receipt]);
    call(&mut b, w.wrapper, MODULE, "commit_upgrade", vec![], vec![other, first_receipt]);
    w.h.assert_rolled_back(
        b.finish(),
        Expected::Abort { package: w.wrapper, module: MODULE, code: 8 },
        &[w.lock, w.native_cap, other_lock, other_cap],
        &[w.h.sender],
    )?;
    assert!(w.pending()?.is_some());
    Ok(())
}

#[test]
fn target_immutability_destroys_only_native_cap_field_and_request() -> Result<()> {
    let mut w = world()?;
    w.abort(w.make_immutable()?, 5)?;
    let (_, now): (ObjectID, u64) = bcs::from_bytes(&w.h.contents(SUI_CLOCK_OBJECT_ID))?;
    let requested = w.h.execute(w.request_make_immutable()?)?;
    requested.assert_success();
    assert_eq!(
        requested.events_of(MODULE, "ImmutabilityRequested"),
        [bcs::to_bytes(&(w.lock, w.native_cap, now, now + DELAY))?.as_slice()],
    );
    assert_eq!(w.pending()?, Some(Request { action: Action::MakeImmutable, ready_at_ms: now + DELAY }));
    w.abort(w.request(digest(&w.code))?, 2)?;
    w.abort(w.upgrade(&w.code, true)?, 6)?;
    w.abort(w.make_immutable()?, 7)?;
    w.h.sim.advance_clock(Duration::from_millis(DELAY - 1));
    w.abort(w.make_immutable()?, 7)?;
    w.h.sim.advance_clock(Duration::from_millis(1));
    let field = ObjectID::from(w.h.object(w.native_cap).owner().get_owner_address()?);
    let tx = w.make_immutable()?;
    let made_immutable = w.h.execute(tx.clone())?;
    made_immutable.assert_success();
    assert_eq!(
        made_immutable.events_of(MODULE, "PackageMadeImmutable"),
        [bcs::to_bytes(&(w.lock, w.native_cap, w.target, now + DELAY))?.as_slice()],
    );
    for id in [field, w.native_cap, request_field(w.lock, w.native_cap)?] {
        assert!(made_immutable.effects.deleted().iter().any(|(deleted, _, _)| *deleted == id));
        assert!(w.h.sim.store().get_object(&id).is_none());
    }
    assert!(w.h.sim.store().get_object(&w.target).is_some());
    assert_eq!(w.h.object(w.controller).owner(), &Owner::AddressOwner(w.h.sender));
    assert!(w.h.object(w.lock).is_shared());
    assert_eq!(w.state()?.caps.size, 0);
    assert!(w.pending()?.is_none());
    w.h.assert_rolled_back(
        tx,
        Expected::Abort { package: w.wrapper, module: MODULE, code: 8 },
        &[w.lock, w.controller],
        &[w.h.sender],
    )?;
    // A manager whose last cap was burned still accepts caps and new delayed work.
    let (_, replacement) = enroll_target(&mut w)?;
    w.h.execute(request_for(&w, replacement, Action::MakeImmutable)?)?.assert_success();
    assert_eq!(w.state()?.caps.size, 1);
    assert_eq!(pending(&w.h, w.lock, replacement)?.unwrap().action, Action::MakeImmutable);
    w.h.sim.advance_clock(Duration::from_millis(DELAY));
    w.h.execute(burn_for(&w, replacement)?)?.assert_success();
    assert_eq!(w.state()?.caps.size, 0);

    let mut b = ProgrammableTransactionBuilder::new();
    let controller = b.obj(w.h.owned(w.controller))?;
    call(&mut b, w.wrapper, MODULE, "destroy_cap", vec![], vec![controller]);
    let cleaned = w.h.execute(b.finish())?;
    cleaned.assert_success();
    assert!(cleaned.effects.deleted().iter().any(|(deleted, _, _)| *deleted == w.controller));
    Ok(())
}

#[test]
fn pending_immutability_survives_controller_destruction() -> Result<()> {
    let mut w = world()?;
    w.h.execute(w.request_make_immutable()?)?.assert_success();
    let pending = w.pending()?;
    let mut b = ProgrammableTransactionBuilder::new();
    let controller = b.obj(w.h.owned(w.controller))?;
    call(&mut b, w.wrapper, MODULE, "destroy_cap", vec![], vec![controller]);
    w.h.execute(b.finish())?.assert_success();
    assert_eq!(w.pending()?, pending);
    w.h.sim.advance_clock(Duration::from_millis(DELAY));
    w.h.execute(w.make_immutable()?)?.assert_success();
    assert!(w.h.sim.store().get_object(&w.native_cap).is_none());
    Ok(())
}

#[test]
fn failure_after_native_burn_restores_manager_cap_field_and_pending_request() -> Result<()> {
    let mut w = world()?;
    w.h.execute(w.request_make_immutable()?)?.assert_success();
    w.h.sim.advance_clock(Duration::from_millis(DELAY));
    let field = ObjectID::from(w.h.object(w.native_cap).owner().get_owner_address()?);
    let mut b = ProgrammableTransactionBuilder::new();
    let lock = b.obj(w.h.shared(w.lock, true))?;
    let cap_id = b.pure(w.native_cap)?;
    let clock = b.obj(w.h.shared(SUI_CLOCK_OBJECT_ID, false))?;
    call(&mut b, w.wrapper, MODULE, "make_immutable", vec![], vec![lock, cap_id, clock]);
    let none = b.pure(Vec::<u8>::new())?;
    call(&mut b, MOVE_STDLIB_PACKAGE_ID, "option", "destroy_some", vec![TypeTag::U8], vec![none]);
    w.h.assert_rolled_back(
        b.finish(),
        Expected::Abort { package: MOVE_STDLIB_PACKAGE_ID, module: "option", code: 0x40001 },
        &[w.lock, w.native_cap, field, w.controller],
        &[w.h.sender],
    )?;
    assert_custody(&w.h, w.lock, w.native_cap)?;
    assert_eq!(w.pending()?.expect("restored pending request").action, Action::MakeImmutable);
    w.h.execute(w.make_immutable()?)?.assert_success();
    Ok(())
}

#[test]
fn cancelling_immutability_preserves_original_deadline_and_switching_actions_restarts_delay() -> Result<()> {
    let mut w = world()?;
    w.h.execute(w.request_make_immutable()?)?.assert_success();
    let original_deadline = w.pending()?.expect("pending immutability").ready_at_ms;
    w.h.sim.advance_clock(Duration::from_millis(DELAY + 1));
    let cancelled = w.h.execute(w.cancel()?)?;
    cancelled.assert_success();
    assert_eq!(
        cancelled.events_of(MODULE, "RequestCancelled"),
        [bcs::to_bytes(&(w.lock, w.native_cap, Action::MakeImmutable, original_deadline))?.as_slice()],
    );
    let code = upgraded(&w.code)?;
    w.h.execute(w.request(digest(&code))?)?.assert_success();
    let next_deadline = w.pending()?.expect("pending upgrade").ready_at_ms;
    assert_eq!(next_deadline, original_deadline + DELAY + 1);
    w.abort(w.make_immutable()?, 6)?;
    w.abort(w.upgrade(&code, true)?, 7)?;
    w.h.execute(w.cancel()?)?.assert_success();
    w.h.execute(w.request_make_immutable()?)?.assert_success();
    w.abort(w.make_immutable()?, 7)?;
    w.h.sim.advance_clock(Duration::from_millis(DELAY));
    w.h.execute(w.make_immutable()?)?.assert_success();
    Ok(())
}

#[test]
fn outstanding_native_authorization_blocks_both_requests_until_commit() -> Result<()> {
    let mut w = world()?;
    let code = upgraded(&w.code)?;
    w.h.execute(w.request(digest(&code))?)?.assert_success();
    w.h.sim.advance_clock(Duration::from_millis(DELAY));
    for function in ["request_upgrade", "request_make_immutable"] {
        let mut b = ProgrammableTransactionBuilder::new();
        let lock = b.obj(w.h.shared(w.lock, true))?;
        let cap_id = b.pure(w.native_cap)?;
        let controller = b.obj(w.h.owned(w.controller))?;
        let clock = b.obj(w.h.shared(SUI_CLOCK_OBJECT_ID, false))?;
        let ticket = call(&mut b, w.wrapper, MODULE, "authorize_upgrade", vec![], vec![lock, cap_id, clock]);
        let mut args = vec![lock, controller, cap_id];
        if function == "request_upgrade" {
            args.push(b.pure(digest(&code))?);
        }
        args.push(clock);
        call(&mut b, w.wrapper, MODULE, function, vec![], args);
        let receipt = b.upgrade(w.target, ticket, code.dependencies.clone(), code.modules.clone());
        call(&mut b, w.wrapper, MODULE, "commit_upgrade", vec![], vec![lock, receipt]);
        w.abort(b.finish(), 0)?;
    }

    // A committed upgrade can start a new immutability notice in the same PTB.
    let mut b = ProgrammableTransactionBuilder::new();
    let lock = b.obj(w.h.shared(w.lock, true))?;
    let cap_id = b.pure(w.native_cap)?;
    let controller = b.obj(w.h.owned(w.controller))?;
    let clock = b.obj(w.h.shared(SUI_CLOCK_OBJECT_ID, false))?;
    let ticket = call(&mut b, w.wrapper, MODULE, "authorize_upgrade", vec![], vec![lock, cap_id, clock]);
    let receipt = b.upgrade(w.target, ticket, code.dependencies, code.modules);
    call(&mut b, w.wrapper, MODULE, "commit_upgrade", vec![], vec![lock, receipt]);
    call(&mut b, w.wrapper, MODULE, "request_make_immutable", vec![], vec![lock, controller, cap_id, clock]);
    let applied = w.h.execute(b.finish())?;
    applied.assert_success();
    w.target = applied.effects.published_packages()[0];
    let (_, now): (ObjectID, u64) = bcs::from_bytes(&w.h.contents(SUI_CLOCK_OBJECT_ID))?;
    assert_eq!(w.pending()?, Some(Request { action: Action::MakeImmutable, ready_at_ms: now + DELAY }));
    w.abort(w.make_immutable()?, 7)?;
    w.h.sim.advance_clock(Duration::from_millis(DELAY));
    let made_immutable = w.h.execute(w.make_immutable()?)?;
    made_immutable.assert_success();
    assert_eq!(
        made_immutable.events_of(MODULE, "PackageMadeImmutable"),
        [bcs::to_bytes(&(w.lock, w.native_cap, w.target, now + DELAY))?.as_slice()],
    );
    Ok(())
}

fn enroll_target(w: &mut World) -> Result<(ObjectID, ObjectID)> {
    let (target, published) = w.h.publish(w.code.clone())?;
    let native = published.created(&w.h, "package", "UpgradeCap")[0];
    let mut b = ProgrammableTransactionBuilder::new();
    let lock = b.obj(w.h.shared(w.lock, true))?;
    let controller = b.obj(w.h.owned(w.controller))?;
    let cap = b.obj(w.h.owned(native))?;
    call(&mut b, w.wrapper, MODULE, "add_upgrade_cap", vec![], vec![lock, controller, cap]);
    let enrolled = w.h.execute(b.finish())?;
    enrolled.assert_success();
    assert_custody(&w.h, w.lock, native)?;
    assert_eq!(
        enrolled.events_of(MODULE, "UpgradeCapAdded"),
        [bcs::to_bytes(&(w.lock, native, target, 0u8))?.as_slice()]
    );
    assert!(pending(&w.h, w.lock, native)?.is_none());
    Ok((target, native))
}

fn append_request(
    w: &World,
    b: &mut ProgrammableTransactionBuilder,
    lock: Argument,
    controller: Argument,
    clock: Argument,
    cap: ObjectID,
    action: &Action,
) -> Result<()> {
    let cap = b.pure(cap)?;
    match action {
        Action::Upgrade { digest } => {
            let hash = b.pure(digest.clone())?;
            call(b, w.wrapper, MODULE, "request_upgrade", vec![], vec![lock, controller, cap, hash, clock]);
        }
        Action::MakeImmutable => {
            call(b, w.wrapper, MODULE, "request_make_immutable", vec![], vec![lock, controller, cap, clock]);
        }
    }
    Ok(())
}

fn request_for(w: &World, cap: ObjectID, action: Action) -> Result<ProgrammableTransaction> {
    let mut b = ProgrammableTransactionBuilder::new();
    let lock = b.obj(w.h.shared(w.lock, true))?;
    let controller = b.obj(w.h.owned(w.controller))?;
    let clock = b.obj(w.h.shared(SUI_CLOCK_OBJECT_ID, false))?;
    append_request(w, &mut b, lock, controller, clock, cap, &action)?;
    Ok(b.finish())
}

fn burn_for(w: &World, cap: ObjectID) -> Result<ProgrammableTransaction> {
    let mut b = ProgrammableTransactionBuilder::new();
    let lock = b.obj(w.h.shared(w.lock, true))?;
    let cap = b.pure(cap)?;
    let clock = b.obj(w.h.shared(SUI_CLOCK_OBJECT_ID, false))?;
    call(&mut b, w.wrapper, MODULE, "make_immutable", vec![], vec![lock, cap, clock]);
    Ok(b.finish())
}

#[test]
fn several_upgrades_and_immutability_requests_queue_and_execute_together() -> Result<()> {
    let mut w = world()?;
    let (second_target, second) = enroll_target(&mut w)?;
    let (third_target, third) = enroll_target(&mut w)?;
    let (fourth_target, fourth) = enroll_target(&mut w)?;
    let code = upgraded(&w.code)?;
    let third_code = upgraded_to(&w.code, 3)?;
    let hash = digest(&code);
    let third_hash = digest(&third_code);
    assert_ne!(hash, third_hash);
    let (_, now): (ObjectID, u64) = bcs::from_bytes(&w.h.contents(SUI_CLOCK_OBJECT_ID))?;
    let mut b = ProgrammableTransactionBuilder::new();
    let lock = b.obj(w.h.shared(w.lock, true))?;
    let controller = b.obj(w.h.owned(w.controller))?;
    let clock = b.obj(w.h.shared(SUI_CLOCK_OBJECT_ID, false))?;
    for cap in [w.native_cap, second, third, fourth] {
        let action = if cap == second || cap == fourth {
            Action::MakeImmutable
        } else {
            Action::Upgrade { digest: if cap == third { third_hash.clone() } else { hash.clone() } }
        };
        append_request(&w, &mut b, lock, controller, clock, cap, &action)?;
    }
    let queued = w.h.execute(b.finish())?;
    queued.assert_success();
    assert_eq!(
        queued.events_of(MODULE, "UpgradeRequested"),
        [
            bcs::to_bytes(&(w.lock, w.native_cap, &hash, now, now + DELAY))?.as_slice(),
            bcs::to_bytes(&(w.lock, third, &third_hash, now, now + DELAY))?.as_slice()
        ]
    );
    assert_eq!(
        queued.events_of(MODULE, "ImmutabilityRequested"),
        [
            bcs::to_bytes(&(w.lock, second, now, now + DELAY))?.as_slice(),
            bcs::to_bytes(&(w.lock, fourth, now, now + DELAY))?.as_slice()
        ]
    );
    for cap in [w.native_cap, second, third, fourth] {
        assert_eq!(pending(&w.h, w.lock, cap)?.unwrap().ready_at_ms, now + DELAY);
    }
    assert_eq!(w.state()?.caps.size, 4);
    w.h.sim.advance_clock(Duration::from_millis(DELAY));
    // One cap cannot execute the other cap's distinct, valid queued upgrade bytes.
    w.h.assert_rolled_back(
        w.upgrade(&third_code, true)?,
        Expected::Error("DigestDoesNotMatch"),
        &[w.lock, w.native_cap, third, request_field(w.lock, w.native_cap)?, request_field(w.lock, third)?],
        &[w.h.sender],
    )?;
    let mut b = ProgrammableTransactionBuilder::new();
    let lock = b.obj(w.h.shared(w.lock, true))?;
    let clock = b.obj(w.h.shared(SUI_CLOCK_OBJECT_ID, false))?;
    let first_id = b.pure(w.native_cap)?;
    let second_id = b.pure(second)?;
    let third_id = b.pure(third)?;
    let fourth_id = b.pure(fourth)?;
    let first_ticket = call(&mut b, w.wrapper, MODULE, "authorize_upgrade", vec![], vec![lock, first_id, clock]);
    call(&mut b, w.wrapper, MODULE, "make_immutable", vec![], vec![lock, second_id, clock]);
    let third_ticket = call(&mut b, w.wrapper, MODULE, "authorize_upgrade", vec![], vec![lock, third_id, clock]);
    call(&mut b, w.wrapper, MODULE, "make_immutable", vec![], vec![lock, fourth_id, clock]);
    let first_receipt = b.upgrade(w.target, first_ticket, code.dependencies.clone(), code.modules.clone());
    let third_receipt = b.upgrade(third_target, third_ticket, third_code.dependencies, third_code.modules);
    // Receipt identity chooses the cap. Reverse order cannot redirect either receipt.
    call(&mut b, w.wrapper, MODULE, "commit_upgrade", vec![], vec![lock, third_receipt]);
    call(&mut b, w.wrapper, MODULE, "commit_upgrade", vec![], vec![lock, first_receipt]);
    let applied = w.h.execute(b.finish())?;
    applied.assert_success();
    assert_eq!(w.state()?.caps.size, 2);
    for cap in [w.native_cap, third] {
        let (_, _, version, _): (ObjectID, ObjectID, u64, u8) = bcs::from_bytes(&w.h.contents(cap))?;
        assert_eq!(version, 2);
        assert_custody(&w.h, w.lock, cap)?;
    }
    for cap in [second, fourth] {
        assert!(w.h.sim.store().get_object(&cap).is_none());
    }
    for cap in [w.native_cap, second, third, fourth] {
        assert!(pending(&w.h, w.lock, cap)?.is_none());
    }
    assert_eq!(
        applied.events_of(MODULE, "PackageMadeImmutable"),
        [
            bcs::to_bytes(&(w.lock, second, second_target, now + DELAY))?.as_slice(),
            bcs::to_bytes(&(w.lock, fourth, fourth_target, now + DELAY))?.as_slice()
        ]
    );
    Ok(())
}

#[test]
fn cancelling_and_replacing_one_cap_preserves_another_caps_later_deadline() -> Result<()> {
    let mut w = world()?;
    let (_, second) = enroll_target(&mut w)?;
    let code = upgraded(&w.code)?;
    w.h.execute(w.request(digest(&code))?)?.assert_success();
    let original = w.pending()?.unwrap().ready_at_ms;
    w.h.sim.advance_clock(Duration::from_millis(1_000));
    w.h.execute(request_for(&w, second, Action::MakeImmutable)?)?.assert_success();
    let other_request = pending(&w.h, w.lock, second)?;
    assert_eq!(other_request.as_ref().unwrap().ready_at_ms, original + 1_000);
    w.h.sim.advance_clock(Duration::from_millis(DELAY - 1_000));
    w.h.assert_rolled_back(
        burn_for(&w, second)?,
        Expected::Abort { package: w.wrapper, module: MODULE, code: 7 },
        &[w.lock, w.native_cap, second, request_field(w.lock, second)?],
        &[w.h.sender],
    )?;
    w.h.execute(w.cancel()?)?.assert_success();
    w.h.execute(w.request(digest(&code))?)?.assert_success();
    assert_eq!(pending(&w.h, w.lock, second)?, other_request);
    let replaced = w.pending()?.unwrap().ready_at_ms;
    assert_eq!(replaced, original + DELAY);
    w.h.sim.advance_clock(Duration::from_millis(1_000));
    w.h.execute(burn_for(&w, second)?)?.assert_success();
    assert_eq!(w.pending()?.unwrap().ready_at_ms, replaced);
    w.abort(w.upgrade(&code, true)?, 7)?;
    w.h.sim.advance_clock(Duration::from_millis(DELAY - 1_000));
    w.h.execute(w.upgrade(&code, true)?)?.assert_success();
    Ok(())
}

#[test]
fn native_ticket_for_one_cap_allows_other_caps_requests_and_burns_before_commit() -> Result<()> {
    let mut w = world()?;
    let (_, second) = enroll_target(&mut w)?;
    let (_, third) = enroll_target(&mut w)?;
    let code = upgraded(&w.code)?;
    w.h.execute(w.request(digest(&code))?)?.assert_success();
    w.h.execute(request_for(&w, second, Action::MakeImmutable)?)?.assert_success();
    w.h.sim.advance_clock(Duration::from_millis(DELAY));
    let (_, now): (ObjectID, u64) = bcs::from_bytes(&w.h.contents(SUI_CLOCK_OBJECT_ID))?;
    let mut b = ProgrammableTransactionBuilder::new();
    let lock = b.obj(w.h.shared(w.lock, true))?;
    let controller = b.obj(w.h.owned(w.controller))?;
    let clock = b.obj(w.h.shared(SUI_CLOCK_OBJECT_ID, false))?;
    let first_id = b.pure(w.native_cap)?;
    let second_id = b.pure(second)?;
    let ticket = call(&mut b, w.wrapper, MODULE, "authorize_upgrade", vec![], vec![lock, first_id, clock]);
    append_request(&w, &mut b, lock, controller, clock, third, &Action::Upgrade { digest: digest(&code) })?;
    call(&mut b, w.wrapper, MODULE, "make_immutable", vec![], vec![lock, second_id, clock]);
    let receipt = b.upgrade(w.target, ticket, code.dependencies, code.modules);
    call(&mut b, w.wrapper, MODULE, "commit_upgrade", vec![], vec![lock, receipt]);
    w.h.execute(b.finish())?.assert_success();
    assert_eq!(pending(&w.h, w.lock, third)?.unwrap().ready_at_ms, now + DELAY);
    assert_eq!(w.native_state()?.2, 2);
    assert_eq!(w.state()?.caps.size, 2);
    assert!(w.h.sim.store().get_object(&second).is_none());
    Ok(())
}

#[test]
fn later_abort_after_one_burn_restores_all_caps_requests_custody_and_count() -> Result<()> {
    let mut w = world()?;
    let (_, second) = enroll_target(&mut w)?;
    let code = upgraded(&w.code)?;
    w.h.execute(w.request(digest(&code))?)?.assert_success();
    w.h.execute(request_for(&w, second, Action::MakeImmutable)?)?.assert_success();
    w.h.sim.advance_clock(Duration::from_millis(DELAY));
    let first_field = ObjectID::from(w.h.object(w.native_cap).owner().get_owner_address()?);
    let second_field = ObjectID::from(w.h.object(second).owner().get_owner_address()?);
    let mut b = ProgrammableTransactionBuilder::new();
    let lock = b.obj(w.h.shared(w.lock, true))?;
    let clock = b.obj(w.h.shared(SUI_CLOCK_OBJECT_ID, false))?;
    let second_id = b.pure(second)?;
    call(&mut b, w.wrapper, MODULE, "make_immutable", vec![], vec![lock, second_id, clock]);
    let none = b.pure(Vec::<u8>::new())?;
    call(&mut b, MOVE_STDLIB_PACKAGE_ID, "option", "destroy_some", vec![TypeTag::U8], vec![none]);
    w.h.assert_rolled_back(
        b.finish(),
        Expected::Abort { package: MOVE_STDLIB_PACKAGE_ID, module: "option", code: 0x40001 },
        &[
            w.lock,
            w.native_cap,
            second,
            first_field,
            second_field,
            w.controller,
            request_field(w.lock, w.native_cap)?,
            request_field(w.lock, second)?,
        ],
        &[w.h.sender],
    )?;
    assert_custody(&w.h, w.lock, w.native_cap)?;
    assert_custody(&w.h, w.lock, second)?;
    assert_eq!(w.state()?.caps.size, 2);
    w.h.execute(burn_for(&w, second)?)?.assert_success();
    w.h.execute(w.upgrade(&code, true)?)?.assert_success();
    Ok(())
}

#[test]
fn unknown_cap_ids_reject_without_touching_other_pending_actions() -> Result<()> {
    let mut w = world()?;
    w.h.execute(w.request(digest(&w.code))?)?.assert_success();
    for function in
        ["request_upgrade", "request_make_immutable", "cancel_request", "authorize_upgrade", "make_immutable"]
    {
        let mut b = ProgrammableTransactionBuilder::new();
        let lock = b.obj(w.h.shared(w.lock, true))?;
        let unknown = b.pure(ObjectID::from_hex_literal("0xdead")?)?;
        let mut args = vec![lock];
        if function.starts_with("request_") || function == "cancel_request" {
            args.push(b.obj(w.h.owned(w.controller))?);
        }
        args.push(unknown);
        if function == "request_upgrade" {
            args.push(b.pure(Vec::<u8>::new())?);
        }
        if function != "cancel_request" {
            args.push(b.obj(w.h.shared(SUI_CLOCK_OBJECT_ID, false))?);
        }
        let result = call(&mut b, w.wrapper, MODULE, function, vec![], args);
        if function == "authorize_upgrade" {
            let receipt = b.upgrade(w.target, result, w.code.dependencies.clone(), w.code.modules.clone());
            call(&mut b, w.wrapper, MODULE, "commit_upgrade", vec![], vec![lock, receipt]);
        }
        w.abort(b.finish(), 8)?;
    }
    assert!(w.pending()?.is_some());
    Ok(())
}

#[test]
fn additional_enrollment_cannot_launder_a_pre_authorized_ticket() -> Result<()> {
    let mut w = world()?;
    let (target, published) = w.h.publish(w.code.clone())?;
    let native = published.created(&w.h, "package", "UpgradeCap")[0];
    let code = upgraded(&w.code)?;
    let mut b = ProgrammableTransactionBuilder::new();
    let lock = b.obj(w.h.shared(w.lock, true))?;
    let controller = b.obj(w.h.owned(w.controller))?;
    let cap = b.obj(w.h.owned(native))?;
    let policy = b.pure(0u8)?;
    let hash = b.pure(digest(&code))?;
    let ticket =
        call(&mut b, SUI_FRAMEWORK_PACKAGE_ID, "package", "authorize_upgrade", vec![], vec![cap, policy, hash]);
    call(&mut b, w.wrapper, MODULE, "add_upgrade_cap", vec![], vec![lock, controller, cap]);
    let receipt = b.upgrade(target, ticket, code.dependencies, code.modules);
    call(&mut b, w.wrapper, MODULE, "commit_upgrade", vec![], vec![lock, receipt]);
    w.h.assert_rolled_back(
        b.finish(),
        Expected::Abort { package: w.wrapper, module: MODULE, code: 0 },
        &[w.lock, w.native_cap, native, w.controller],
        &[w.h.sender],
    )?;
    Ok(())
}

fn request_field(lock: ObjectID, cap: ObjectID) -> Result<ObjectID> {
    let key: TypeTag = "0x2::object::ID".parse()?;
    Ok(derive_dynamic_field_id(lock, &key, &bcs::to_bytes(&cap)?)?)
}

fn pending(h: &Harness, lock: ObjectID, cap: ObjectID) -> Result<Option<Request>> {
    let field = request_field(lock, cap)?;
    if h.sim.store().get_object(&field).is_none() {
        return Ok(None);
    }
    let (id, key, request): (ObjectID, ObjectID, Request) = bcs::from_bytes(&h.contents(field))?;
    assert_eq!((id, key), (field, cap));
    assert_eq!(h.object(field).owner(), &Owner::ObjectOwner(lock.into()));
    Ok(Some(request))
}

fn assert_custody(h: &Harness, lock: ObjectID, cap: ObjectID) -> Result<()> {
    let manager: Lock = bcs::from_bytes(&h.contents(lock))?;
    let field = ObjectID::from(h.object(cap).owner().get_owner_address()?);
    assert_eq!(h.object(field).owner(), &Owner::ObjectOwner(manager.caps.id.into()));
    let (id, key, child): (ObjectID, ObjectID, ObjectID) = bcs::from_bytes(&h.contents(field))?;
    assert_eq!((id, key, child), (field, cap, cap));
    Ok(())
}
