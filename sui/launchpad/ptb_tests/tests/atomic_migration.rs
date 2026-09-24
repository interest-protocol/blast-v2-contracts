//! Programmable-transaction integration tests for launch creation, the atomic migration seam, and
//! protected buys.
//!
//! Every launch is opened by one PTB composed from public calls: the mock adapter starts it under
//! its own witness and pool tier, the launchpad setters configure the initializer, and `finalize`
//! and `share` consume it, so the ability-less initializer crosses commands of one transaction.
//!
//! Two independent one-time-witness launches reach MigrationReady through public PTBs. Every
//! failing migration PTB must commit nothing (see `Harness::assert_rolled_back`): no allocation
//! reaches its destination, and launch A stays migratable through the whole failure matrix before
//! completing in one successful PTB. Every event travels in the launchpad envelope.
//!
//! A protected launch shows the launch-owned sender record the first protected buy creates, the
//! storage cost of that buy and of a later one, and that every failing protected buy commits
//! nothing.
//!
//! LP-fee splits that sum to zero or name seventeen recipients abort in the fee-split constructor
//! before the launch exists, while sixteen recipients commit unchanged into the launch. A split
//! with every part and sixteen distinct recipient weights is measured at creation and migration;
//! each record prints as one `LAUNCH_FEE_SPLIT_CAPACITY` JSON line with its margins to the
//! simulator's protocol limits. Recurring LP-fee collection and split updates belong to the
//! migrators package.
//!
//! Run from `sui/launchpad/ptb_tests` with `cargo test` (needs the pinned `sui` on PATH).

use std::{path::Path, time::Duration};

use anyhow::Result;
use blast_launchpad_ptb_tests::{
    CompiledPackage, Expected, Harness, Outcome, build, call, sui_dir,
};
use serde::{Deserialize, Serialize};
use serde_json::{Value, json};
use sui_types::{
    SUI_CLOCK_OBJECT_ID, SUI_COIN_REGISTRY_OBJECT_ID, SUI_FRAMEWORK_PACKAGE_ID, TypeTag,
    base_types::{ObjectID, SuiAddress},
    effects::TransactionEffectsAPI,
    object::Owner,
    parse_sui_type_tag,
    programmable_transaction_builder::ProgrammableTransactionBuilder,
    transaction::{Argument, Command, ObjectArg, ProgrammableTransaction},
};

const TARGET: u64 = 25_000_000;
const BUY: u64 = 30_000_000;

/// The pool tier every launch starts at, in the mock venue's native units.
const POOL_TICK_SPACING: u32 = 60;
const POOL_FEE_RATE: u64 = 2_500;

/// Protection arguments: window, cumulative BPS, per-transaction BPS. Unprotected launches leave
/// protection at its disabled default.
const UNPROTECTED: [u64; 3] = [0, 0, 0];
const WINDOW_MS: u64 = 60_000;
/// One percent of the 10^18-atom supply per sender, half a percent per buy.
const PROTECTED: [u64; 3] = [WINDOW_MS, 100, 50];
const CUMULATIVE_LIMIT: u64 = 10_000_000_000_000_000;
/// About 3.4 * 10^15 gross atoms: two fit the cumulative limit, a third does not.
const SMALL_BUY: u64 = 25_000;
/// About 5.4 * 10^15 gross atoms after two small buys: above the per-transaction limit.
const OVERSIZED_BUY: u64 = 40_000;
/// About 1.1 * 10^16 gross atoms: above both limits.
const EXCESSIVE_BUY: u64 = 80_000;

const CUSTODY_FAILURE: u8 = 1;
const ZERO_LIQUIDITY: u8 = 2;
const UNDERFUND_MEME: u8 = 3;
const POST_FINALIZER_FAILURE: u8 = 4;

const DESTINATION: ObjectID = address(&[0xD5]);
const PROTOCOL: ObjectID = address(&[0xAD]);
/// Where the underfunding failpoint sends the missing unit.
const SINK: ObjectID = address(&[0xDE, 0xAD]);

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

struct World {
    h: Harness,
    blast: ObjectID,
    adapter: ObjectID,
    version: ObjectID,
    runtime: ObjectID,
    config: ObjectID,
    project: CompiledPackage,
}

#[test]
fn failed_migration_ptbs_commit_nothing_and_one_ptb_completes_atomically() -> Result<()> {
    let (mut w, a, b) = setup()?;
    let b_ready = w.h.snapshot(&[b.launch, b.currency], &[]);
    let watched = [a.launch, a.currency];
    let owners = [w.h.sender, DESTINATION.into(), SINK.into()];

    for (failpoint, expected) in [
        (CUSTODY_FAILURE, Expected::Abort { package: w.adapter, module: "mock_adapter", code: 0 }),
        (ZERO_LIQUIDITY, Expected::Abort { package: w.blast, module: "launch", code: 56 }),
        (UNDERFUND_MEME, Expected::Abort { package: w.blast, module: "launch", code: 56 }),
        (POST_FINALIZER_FAILURE, Expected::Abort { package: w.adapter, module: "mock_adapter", code: 1 }),
    ] {
        let pt = w.migrate(&a, &a, failpoint)?;
        w.h.assert_rolled_back(pt, expected, &watched, &owners)?;
    }

    // VM type-rule evidence, not a launch check: launch B's currency cannot stand in for launch
    // A's because distinct one-time-witness types fail PTB type checking before any Move code runs.
    let pt = w.migrate(&a, &b, 0)?;
    w.h.assert_rolled_back(
        pt,
        Expected::Error("TypeMismatch"),
        &[a.launch, a.currency, b.currency],
        &owners,
    )?;

    // VM type-rule evidence, not a launch check: a PTB cannot pass pure bytes as the adapter
    // witness that opens migration.
    let pt = {
        let mut builder = ProgrammableTransactionBuilder::new();
        let launch = builder.obj(w.h.shared(a.launch, true))?;
        let version = builder.obj(w.h.shared(w.version, false))?;
        let forged = builder.pure_bytes(vec![], true);
        let begun = call(
            &mut builder,
            w.blast,
            "launch",
            "begin_migration",
            vec![a.meme.clone(), sui(), w.adapter_type("Venue")?],
            vec![launch, version, forged],
        );
        let Argument::Result(begun) = begun else { unreachable!() };
        // Taking the Meme principal is the only other command, so a forged witness surfaces
        // as its own error rather than behind a static transfer check.
        let coin = call(
            &mut builder,
            SUI_FRAMEWORK_PACKAGE_ID,
            "coin",
            "from_balance",
            vec![a.meme.clone()],
            vec![Argument::NestedResult(begun, 0)],
        );
        builder.transfer_args(w.h.sender, vec![coin]);
        builder.finish()
    };
    w.h.assert_rolled_back(pt, Expected::Error("InvalidUsageOfPureArg"), &[a.launch], &owners)?;
    assert_eq!(w.launch_lifecycle(&a)?, LaunchLifecycle::MigrationReady);

    // The complete migration succeeds in one PTB, pays the external allocation to its destination,
    // and leaves the caller with nothing.
    let pt = w.migrate(&a, &a, 0)?;
    let outcome = w.h.execute(pt)?;
    outcome.assert_success();
    assert_eq!(outcome.wrapped_payloads(w.blast), ["MigrationAllocationPaid", "Migrated"]);
    assert_eq!(w.launch_lifecycle(&a)?, LaunchLifecycle::Migrated);
    let migrated = outcome.events_of("events", "Migrated");
    assert_eq!(migrated.len(), 1);
    let migrated: Migrated = bcs::from_bytes(migrated[0])?;
    assert_eq!(migrated.launch_id, a.launch);
    assert!(migrated.supplied_meme > 0 && migrated.supplied_quote > 0);
    assert_eq!((migrated.residual_meme, migrated.residual_quote), (1, 1));
    assert!(migrated.liquidity > 0);
    let vaults = outcome.created(&w.h, "mock_adapter", "MockVault");
    assert_eq!(vaults.len(), 1);
    assert!(w.h.object(vaults[0]).is_shared());
    let paid = outcome.events_of("events", "MigrationAllocationPaid");
    assert_eq!(paid.len(), 1);
    let paid: MigrationAllocationPaid = bcs::from_bytes(paid[0])?;
    assert_eq!((paid.launch_id, paid.channel_id), (a.launch, 3));
    assert_eq!(SuiAddress::from(DESTINATION), paid.destination);
    assert!(paid.meme > 0 && paid.quote > 0);
    assert_eq!(outcome.coins_created_for(&w.h, DESTINATION.into()), w.coins(&a, paid.meme, paid.quote));
    assert!(
        outcome
            .effects
            .created()
            .iter()
            .all(|(_, owner)| *owner != Owner::AddressOwner(w.h.sender)),
        "the caller received an object"
    );

    // A migrated launch cannot migrate again, and launch B was never touched.
    let pt = w.migrate(&a, &a, 0)?;
    let lifecycle = Expected::Abort { package: w.blast, module: "launch", code: 29 };
    w.h.assert_rolled_back(pt, lifecycle, &watched, &owners)?;
    assert_eq!(w.h.snapshot(&[b.launch, b.currency], &[]), b_ready);

    Ok(())
}

#[test]
fn zero_sum_and_seventeen_recipient_fee_splits_abort_before_the_launch_exists() -> Result<()> {
    let mut w = world("fee_split_boundaries")?;
    let sixteen = FeeSplit::sixteen(0xA0, 10);
    // An empty split fails the 10,000 sum (`route_sum_invalid`); a seventeenth distinct recipient
    // fails capacity (`route_capacity_reached`) while the sum stays whole.
    let rejected = [(FeeSplit::default(), 58), (sixteen.clone().with_seventeenth(), 57)];
    let blast = w.blast;
    let abort = |code| Expected::Abort { package: blast, module: "allocation", code };
    let owners = [w.h.sender, DESTINATION.into()];

    // Each rejected split aborts before the ticket is consumed; the same ticket then opens with
    // sixteen recipients, which the launch records unchanged.
    let (ticket, currency, meme) = w.publish_ticket()?;
    for (fee_split, code) in &rejected {
        let pt = w.create_launch(ticket, currency, &meme, fee_split, UNPROTECTED)?;
        w.h.assert_rolled_back(pt, abort(*code), &[ticket, currency], &owners)?;
    }
    let (_, created) = w.open_split_launch(ticket, currency, meme, &sixteen)?;
    assert_eq!(w.launch_created(&created)?.lp_fee_split, sixteen);

    Ok(())
}

#[test]
fn maximum_fee_split_fits_protocol_limits_at_creation_and_migration() -> Result<()> {
    let mut w = world("fee_split_capacity")?;
    let fee_split = FeeSplit::sixteen(0xA0, 10);
    let mut records = Vec::new();

    let (ticket, currency, meme) = w.publish_ticket()?;
    let (a, created) = w.open_split_launch(ticket, currency, meme, &fee_split)?;
    let launch_created = w.launch_created(&created)?;
    assert_eq!(launch_created.lp_fee_split, fee_split);
    assert_eq!(
        (launch_created.pool_tick_spacing, launch_created.pool_fee_rate),
        (POOL_TICK_SPACING, POOL_FEE_RATE),
    );
    records.push(w.record(&a, "create_launch", "3 parts + 16 recipients", &created));

    // The launch carries the split unchanged to migration, which neither reads nor pays it.
    w.buy_to_migration(&a)?;
    let migrated = w.h.execute(w.migrate(&a, &a, 0)?)?;
    migrated.assert_success();
    assert_eq!(migrated.wrapped_payloads(w.blast), ["MigrationAllocationPaid", "Migrated"]);
    records.push(w.record(&a, "migrate", "3 parts + 16 recipients", &migrated));

    println!(
        "LAUNCH_FEE_SPLIT_CAPACITY {}",
        json!({ "limits": w.h.protocol_limits(), "fixture": { "fee_split": fee_split }, "records": records })
    );

    Ok(())
}

#[test]
fn protected_buys_keep_one_record_per_sender_and_failed_buys_commit_nothing() -> Result<()> {
    let mut w = world("protected_buys")?;
    let launch = w.open_launch(PROTECTED)?;
    let owners = [w.h.sender];

    // The first protected buy creates the sender's launch-owned record; later buys only mutate it.
    let pt = w.buy(&launch, SMALL_BUY, 1)?;
    let first = w.h.execute(pt)?;
    first.assert_success();
    let records = first.created(&w.h, "dynamic_field", "Field");
    assert_eq!(records.len(), 1, "the first protected buy creates one sender record");
    let record = records[0];
    assert_eq!(*w.h.object(record).owner(), Owner::ObjectOwner(launch.launch.into()));
    let pt = w.buy(&launch, SMALL_BUY, 1)?;
    let second = w.h.execute(pt)?;
    second.assert_success();
    assert!(second.created(&w.h, "dynamic_field", "Field").is_empty());
    assert!(second.effects.mutated().iter().any(|(object, _)| object.0 == record));
    let purchases: ProtectedPurchases = bcs::from_bytes(&w.h.contents(record))?;
    assert_eq!(purchases.sender, w.h.sender);
    assert_eq!(purchases.purchases, bought_gross(&first)? + bought_gross(&second)?);

    // Slippage, then the per-transaction limit, then the cumulative limit: each failure leaves the
    // launch reserves, fee ledger, record, and the buyer's coins exactly as they were.
    for (quote_in, min_meme_out, code) in [
        (SMALL_BUY, u64::MAX, 30),
        (OVERSIZED_BUY, 1, 51),
        (SMALL_BUY, 1, 52),
    ] {
        let pt = w.buy(&launch, quote_in, min_meme_out)?;
        let expected = Expected::Abort { package: w.blast, module: "launch", code };
        w.h.assert_rolled_back(pt, expected, &[launch.launch, record], &owners)?;
    }

    // At exactly the protection end, a buy above both limits is neither checked nor recorded.
    w.h.sim.advance_clock(Duration::from_millis(WINDOW_MS));
    let record_before = w.h.contents(record);
    let pt = w.buy(&launch, EXCESSIVE_BUY, 1)?;
    let open = w.h.execute(pt)?;
    open.assert_success();
    assert!(bought_gross(&open)? > CUMULATIVE_LIMIT);
    assert!(open.created(&w.h, "dynamic_field", "Field").is_empty());
    assert!(open.effects.mutated().iter().all(|(object, _)| object.0 != record));
    assert_eq!(w.h.contents(record), record_before);

    // Capacity evidence: net storage charged by the first and a later protected buy, and by an
    // unprotected buy of the same launch. Only the first buy leaves a new object behind.
    let net_storage = |outcome: &Outcome| {
        let cost = outcome.effects.gas_cost_summary();
        println!(
            "storage_cost {} storage_rebate {} non_refundable {} net {}",
            cost.storage_cost,
            cost.storage_rebate,
            cost.non_refundable_storage_fee,
            cost.storage_cost as i64 - cost.storage_rebate as i64,
        );
        cost.storage_cost as i64 - cost.storage_rebate as i64
    };
    print!("first protected buy: ");
    let first_net = net_storage(&first);
    print!("later protected buy: ");
    let later_net = net_storage(&second);
    print!("unprotected buy: ");
    let unprotected_net = net_storage(&open);
    assert!(first_net > later_net && later_net >= unprotected_net);

    Ok(())
}

fn bought_gross(outcome: &Outcome) -> Result<u64> {
    let bought = outcome.events_of("events", "Bought");
    assert_eq!(bought.len(), 1);
    let bought: Bought = bcs::from_bytes(bought[0])?;

    Ok(bought.meme_out_gross)
}

/// Mirrors `blast_fun::events::Bought` field order for BCS decoding.
#[derive(Deserialize)]
struct Bought {
    _launch_id: ObjectID,
    _quote_in: u64,
    meme_out_gross: u64,
    _protocol_meme_fee_delta: u64,
    _creator_meme_fee_delta: u64,
    _protocol_quote_fee_delta: u64,
    _creator_quote_fee_delta: u64,
    _meme_reserve: u64,
    _real_quote_reserve: u64,
}

/// Mirrors `0x2::dynamic_field::Field<blast_fun::launch::ProtectedPurchasesKey, u64>`.
#[derive(Deserialize)]
struct ProtectedPurchases {
    _id: ObjectID,
    sender: SuiAddress,
    purchases: u64,
}

/// Mirrors `blast_fun::events::LaunchCreated`, its allocation plan's fields inline.
#[derive(Deserialize)]
struct LaunchCreated {
    _launch_id: ObjectID,
    _ticket_id: ObjectID,
    _decimals: u8,
    _atomic_supply: u64,
    _quote: String,
    _migration_witness: String,
    pool_tick_spacing: u32,
    pool_fee_rate: u64,
    lp_fee_split: FeeSplit,
    _virtual_quote: u64,
    _graduation_target: u64,
    _quote_fee_bps: u64,
    _meme_fee_bps: u64,
    _channels: Vec<(u64, Role, SuiAddress)>,
    _meme_weights: Vec<(u64, u64)>,
    _quote_weights: Vec<(u64, u64)>,
    _meme_amounts: Vec<u64>,
}

#[derive(Deserialize)]
enum Role {
    Liquidity,
    Protocol,
    External,
}

/// Mirrors `blast_fun::events::Migrated` field order for BCS decoding.
#[derive(Deserialize)]
struct Migrated {
    launch_id: ObjectID,
    supplied_meme: u64,
    supplied_quote: u64,
    residual_meme: u64,
    residual_quote: u64,
    liquidity: u128,
    _disposed_meme: u64,
    _native_supply_burned: bool,
    _total_supply_after: u64,
}

/// `blast_fun::launch::Launch` begins with its UID and this fieldless enum, whose BCS tag is one
/// byte; the rest of the launch is not mirrored.
#[derive(Debug, Deserialize, PartialEq)]
enum LaunchLifecycle {
    Live,
    MigrationReady,
    Migrating,
    Migrated,
}

/// Mirrors `blast_fun::allocation::FeeSplit`; each `Bps` is one `u64` in BCS.
#[derive(Clone, Debug, Default, Deserialize, PartialEq, Serialize)]
struct FeeSplit {
    creator_bps: u64,
    auto_lp_bps: u64,
    rewards_bps: u64,
    recipients: Vec<Route>,
}

impl FeeSplit {
    /// Every collection wholly to one recipient.
    fn single(destination: ObjectID) -> Self {
        let recipients = vec![Route { destination: destination.into(), bps: 10_000 }];
        Self { recipients, ..Self::default() }
    }

    /// Every part set, and sixteen recipients in canonical order whose weights fall by `step`, so
    /// they are distinct; the whole split sums to 10,000.
    fn sixteen(tag: u8, step: u64) -> Self {
        let (creator_bps, auto_lp_bps, rewards_bps) = (1_000, 600, 400);
        let shared = 10_000 - creator_bps - auto_lp_bps - rewards_bps;
        assert_eq!((shared - 120 * step) % 16, 0);
        let lowest = (shared - 120 * step) / 16;
        let recipients = (0..16u8)
            .map(|i| Route { destination: address(&[tag, i]).into(), bps: lowest + step * u64::from(15 - i) })
            .collect();

        Self { creator_bps, auto_lp_bps, rewards_bps, recipients }
    }

    /// Moves the rewards share to a seventeenth distinct recipient; the sum stays whole.
    fn with_seventeenth(mut self) -> Self {
        let bps = std::mem::take(&mut self.rewards_bps);
        self.recipients.push(Route { destination: address(&[0x17, 0x17]).into(), bps });
        self
    }
}

#[derive(Clone, Debug, Deserialize, PartialEq, Serialize)]
struct Route {
    destination: SuiAddress,
    bps: u64,
}

/// Mirrors `blast_fun::events::MigrationAllocationPaid`.
#[derive(Deserialize)]
struct MigrationAllocationPaid {
    launch_id: ObjectID,
    channel_id: u64,
    destination: SuiAddress,
    meme: u64,
    quote: u64,
}

/// Two unprotected launches at MigrationReady.
fn setup() -> Result<(World, Launch, Launch)> {
    let mut w = world("atomic_migration")?;
    let mut launches = Vec::new();
    for _ in 0..2 {
        let launch = w.open_launch(UNPROTECTED)?;
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
    let sui_dir = sui_dir();
    let fixture = Path::new(env!("CARGO_MANIFEST_DIR")).join("fixture");
    let work = Path::new(env!("CARGO_TARGET_TMPDIR")).join(env!("CARGO_PKG_NAME")).join(work);
    let mut h = Harness::new()?;

    let admin_dir = sui_dir.join("admin");
    let launchpad_dir = sui_dir.join("launchpad");
    let (admin, _) = h.publish(build(&admin_dir, &[], &work)?)?;
    let (blast, published) = h.publish(build(&launchpad_dir, &[(&admin_dir, admin)], &work)?)?;
    let one = |module: &str, name: &str| {
        let ids = published.created(&h, module, name);
        assert_eq!(ids.len(), 1, "{module}::{name}");
        ids[0]
    };
    let authority = one("acl", "Authority");
    let root = one("acl", "SuperAdminCap");
    let config = one("launch_config", "LaunchConfig");
    let version = one("package_version", "PackageVersion");
    let runtime = one("runtime_config", "RuntimeConfig");
    let (adapter, _) = h.publish(build(
        &fixture.join("adapter"),
        &[(&admin_dir, admin), (&launchpad_dir, blast)],
        &work,
    )?)?;
    let project = build(
        &fixture.join("project"),
        &[(&admin_dir, admin), (&launchpad_dir, blast)],
        &work,
    )?;
    let mut w = World { h, blast, adapter, version, runtime, config, project };
    let domain = parse_sui_type_tag(&format!("{blast}::blast_fun_domain::BLAST_FUN_DOMAIN"))?;

    // Production admin path: the publisher's SuperAdminCap grants an AdminCap.
    let mut builder = ProgrammableTransactionBuilder::new();
    let authority_arg = builder.obj(w.h.shared(authority, true))?;
    let root = builder.obj(w.h.owned(root))?;
    let roles = builder.pure(u64::MAX)?;
    let recipient = builder.pure(w.h.sender)?;
    call(&mut builder, admin, "acl", "grant_admin", vec![domain.clone()], vec![
        authority_arg,
        root,
        roles,
        recipient,
    ]);
    w.h.execute(builder.finish())?.assert_success();
    let admin_cap = w.h.owned_of_type(w.h.sender, "acl", "AdminCap")[0];

    let mut builder = ProgrammableTransactionBuilder::new();
    let authority = builder.obj(w.h.shared(authority, false))?;
    let admin_cap = builder.obj(w.h.owned(admin_cap))?;
    let signed_in = call(&mut builder, admin, "acl", "sign_in", vec![domain], vec![authority, admin_cap]);
    let config_arg = builder.obj(w.h.shared(config, true))?;
    let version_arg = builder.obj(w.h.shared(version, false))?;
    let virtual_quote = builder.pure(5_000_000u64)?;
    call(&mut builder, blast, "launch_config", "allow_quote", vec![sui()], vec![
        config_arg,
        version_arg,
        signed_in,
        virtual_quote,
    ]);
    call(&mut builder, blast, "launch_config", "allow_migration_witness", vec![w.adapter_type("Venue")?], vec![
        config_arg,
        version_arg,
        signed_in,
    ]);
    let hundred = builder.pure(100u64)?;
    let fee = call(&mut builder, blast, "bps", "new", vec![], vec![hundred]);
    call(&mut builder, blast, "launch_config", "set_trade_fees", vec![], vec![
        config_arg,
        version_arg,
        signed_in,
        fee,
        fee,
    ]);
    let zero = builder.pure(0u64)?;
    let none = call(&mut builder, blast, "bps", "new", vec![], vec![zero]);
    let channel = builder.pure(1u64)?;
    let protocol = builder.pure(SuiAddress::from(PROTOCOL))?;
    call(&mut builder, blast, "launch_config", "set_protocol_allocation", vec![], vec![
        config_arg,
        version_arg,
        signed_in,
        channel,
        protocol,
        none,
        none,
    ]);
    w.h.execute(builder.finish())?.assert_success();

    Ok(w)
}

impl World {
    /// Publishes one generated project and opens its SUI-quoted launch under `protection`, with
    /// the LP-fee split paying `DESTINATION` wholly.
    fn open_launch(&mut self, protection: [u64; 3]) -> Result<Launch> {
        let (ticket, currency, meme) = self.publish_ticket()?;
        let pt = self.create_launch(ticket, currency, &meme, &FeeSplit::single(DESTINATION), protection)?;
        let created = self.h.execute(pt)?;

        Ok(self.created_launch(&created, meme, currency))
    }

    /// Opens `ticket`'s unprotected launch with `fee_split` and returns it with the creation outcome.
    fn open_split_launch(
        &mut self,
        ticket: ObjectID,
        currency: ObjectID,
        meme: TypeTag,
        fee_split: &FeeSplit,
    ) -> Result<(Launch, Outcome)> {
        let created = self.h.execute(self.create_launch(ticket, currency, &meme, fee_split, UNPROTECTED)?)?;

        Ok((self.created_launch(&created, meme, currency), created))
    }

    /// One PTB that starts `ticket`'s launch through the adapter, sets the graduation target, the
    /// allocation plan, `fee_split`, and any protection, then finalizes and shares it. Every
    /// non-liquidity allocation pays `DESTINATION`.
    fn create_launch(
        &self,
        ticket: ObjectID,
        currency: ObjectID,
        meme: &TypeTag,
        fee_split: &FeeSplit,
        protection: [u64; 3],
    ) -> Result<ProgrammableTransaction> {
        let mut builder = ProgrammableTransactionBuilder::new();
        let fee_split = self.fee_split_arg(&mut builder, fee_split)?;
        let plan = self.plan_arg(&mut builder)?;
        let ticket = builder.obj(self.h.owned(ticket))?;
        let version = builder.obj(self.h.shared(self.version, false))?;
        let config = builder.obj(self.h.shared(self.config, false))?;
        let tick_spacing = builder.pure(POOL_TICK_SPACING)?;
        let fee_rate = builder.pure(POOL_FEE_RATE)?;
        let initializer = call(&mut builder, self.adapter, "mock_adapter", "new", vec![meme.clone()], vec![
            ticket,
            version,
            config,
            tick_spacing,
            fee_rate,
        ]);
        let pair = vec![meme.clone(), sui()];
        let target = builder.pure(TARGET)?;
        call(&mut builder, self.blast, "launch", "set_graduation_target", pair.clone(), vec![initializer, target]);
        call(&mut builder, self.blast, "launch", "set_allocation_plan", pair.clone(), vec![initializer, plan]);
        call(&mut builder, self.blast, "launch", "set_lp_fee_split", pair.clone(), vec![initializer, fee_split]);
        if protection != UNPROTECTED {
            let [window_ms, cumulative_bps, per_transaction_bps] = protection;
            let window_ms = builder.pure(window_ms)?;
            let cumulative_bps = self.bps(&mut builder, cumulative_bps)?;
            let per_transaction_bps = self.bps(&mut builder, per_transaction_bps)?;
            call(&mut builder, self.blast, "launch", "set_protection", pair.clone(), vec![
                initializer,
                window_ms,
                cumulative_bps,
                per_transaction_bps,
            ]);
        }
        let currency = builder.obj(self.h.shared(currency, true))?;
        let launch = call(&mut builder, self.blast, "launch", "finalize", pair.clone(), vec![
            initializer,
            version,
            currency,
            config,
        ]);
        let clock = builder.obj(self.h.shared(SUI_CLOCK_OBJECT_ID, false))?;
        call(&mut builder, self.blast, "launch", "share", pair, vec![launch, version, clock]);

        Ok(builder.finish())
    }

    /// Publishes one generated project, which runs its OTW init: the ticket goes to the publisher
    /// and the Currency to the registry, which must finalize it into its shared form. Returns the
    /// ticket, the shared currency, and the Meme type.
    fn publish_ticket(&mut self) -> Result<(ObjectID, ObjectID, TypeTag)> {
        let (project_id, published) = self.h.publish(self.project.clone())?;
        assert_eq!(published.wrapped_payloads(self.blast), ["LaunchTicketCreated"]);
        let ticket = published.created(&self.h, "launch_ticket", "LaunchTicket")[0];
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

        Ok((ticket, currency, meme))
    }

    /// The launch a successful creation shared.
    fn created_launch(&self, created: &Outcome, meme: TypeTag, currency: ObjectID) -> Launch {
        created.assert_success();
        assert_eq!(
            created.wrapped_payloads(self.blast),
            ["LaunchCreated", "ProtectionConfigured", "LaunchShared"],
        );
        let launch = created.created(&self.h, "launch", "Launch");
        assert_eq!(launch.len(), 1, "launch::Launch");
        assert!(self.h.object(launch[0]).is_shared());

        Launch { meme, launch: launch[0], currency }
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
        assert_eq!(bought.wrapped_payloads(self.blast), ["Bought"]);
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
        let clock = builder.obj(self.h.shared(SUI_CLOCK_OBJECT_ID, false))?;
        let Argument::Result(bought) = call(
            &mut builder,
            self.blast,
            "launch",
            "buy",
            vec![launch.meme.clone(), sui()],
            vec![launch_arg, version, runtime, Argument::NestedResult(split, 0), min_out, clock],
        ) else {
            unreachable!()
        };
        builder.transfer_args(self.h.sender, vec![
            Argument::NestedResult(bought, 0),
            Argument::NestedResult(bought, 1),
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

    /// The adapter entry point with `launch`'s launch and `currency_owner`'s currency.
    fn migrate(&self, launch: &Launch, currency_owner: &Launch, failpoint: u8) -> Result<ProgrammableTransaction> {
        let mut builder = ProgrammableTransactionBuilder::new();
        let launch_arg = builder.obj(self.h.shared(launch.launch, true))?;
        let version = builder.obj(self.h.shared(self.version, false))?;
        let currency = builder.obj(self.h.shared(currency_owner.currency, true))?;
        let failpoint = builder.pure(failpoint)?;
        call(&mut builder, self.adapter, "mock_adapter", "migrate", vec![launch.meme.clone()], vec![
            launch_arg,
            version,
            currency,
            failpoint,
        ]);

        Ok(builder.finish())
    }
}

/// Launch fixtures and measurements.
impl World {
    fn bps(&self, builder: &mut ProgrammableTransactionBuilder, value: u64) -> Result<Argument> {
        let value = builder.pure(value)?;

        Ok(call(builder, self.blast, "bps", "new", vec![], vec![value]))
    }

    /// The fixture plan: 70% of the Meme on the curve, liquidity channel 2 with 20% of the Meme
    /// and 90% of the Quote, and external channel 3 with the rest, both paying `DESTINATION`.
    fn plan_arg(&self, builder: &mut ProgrammableTransactionBuilder) -> Result<Argument> {
        let destination = SuiAddress::from(DESTINATION);
        let liquidity = call(builder, self.blast, "allocation", "liquidity_role", vec![], vec![]);
        let external = call(builder, self.blast, "allocation", "external_role", vec![], vec![]);
        let mut channels = Vec::new();
        for (id, role) in [(2u64, liquidity), (3, external)] {
            let id = builder.pure(id)?;
            let destination = builder.pure(destination)?;
            channels.push(call(builder, self.blast, "allocation", "channel", vec![], vec![id, role, destination]));
        }
        let channel = parse_sui_type_tag(&format!("{}::allocation::Channel", self.blast))?;
        let channels = builder.command(Command::make_move_vec(Some(channel), channels));
        let mut tables = Vec::new();
        for table in [vec![(0u64, 7_000u64), (2, 2_000), (3, 1_000)], vec![(2, 9_000), (3, 1_000)]] {
            let mut weights = Vec::new();
            for (id, bps) in table {
                let id = builder.pure(id)?;
                let bps = self.bps(builder, bps)?;
                weights.push(call(builder, self.blast, "allocation", "weight", vec![], vec![id, bps]));
            }
            let weight = parse_sui_type_tag(&format!("{}::allocation::Weight", self.blast))?;
            tables.push(builder.command(Command::make_move_vec(Some(weight), weights)));
        }

        Ok(call(builder, self.blast, "allocation", "new", vec![], vec![channels, tables[0], tables[1]]))
    }

    /// Builds `fee_split` through the public constructors, as a client would: recipients in
    /// descending destination order, the canonical sort's worst case, with every value its own
    /// pure input.
    fn fee_split_arg(&self, builder: &mut ProgrammableTransactionBuilder, fee_split: &FeeSplit) -> Result<Argument> {
        let mut recipients = Vec::new();
        for route in fee_split.recipients.iter().rev() {
            let bps = self.unique_bps(builder, route.bps)?;
            let destination = builder.pure_bytes(bcs::to_bytes(&route.destination)?, true);
            recipients.push(call(builder, self.blast, "allocation", "route", vec![], vec![destination, bps]));
        }
        let route = parse_sui_type_tag(&format!("{}::allocation::Route", self.blast))?;
        let recipients = builder.command(Command::make_move_vec(Some(route), recipients));
        let creator_bps = self.unique_bps(builder, fee_split.creator_bps)?;
        let auto_lp_bps = self.unique_bps(builder, fee_split.auto_lp_bps)?;
        let rewards_bps = self.unique_bps(builder, fee_split.rewards_bps)?;

        Ok(call(builder, self.blast, "allocation", "fee_split", vec![], vec![
            creator_bps,
            auto_lp_bps,
            rewards_bps,
            recipients,
        ]))
    }

    /// A `Bps` from its own pure input, never shared with an equal value.
    fn unique_bps(&self, builder: &mut ProgrammableTransactionBuilder, value: u64) -> Result<Argument> {
        let value = builder.pure_bytes(bcs::to_bytes(&value)?, true);

        Ok(call(builder, self.blast, "bps", "new", vec![], vec![value]))
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
