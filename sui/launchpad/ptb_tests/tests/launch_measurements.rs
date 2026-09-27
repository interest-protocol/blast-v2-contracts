//! Resource measurements for the launch and opening-round family: the allocation-recipient capacity
//! boundary, maximum launch creation with terminal share, the creator's purchase or bid before
//! sharing, and the first and a later bid, settlement, delivery, and the first buy after it.
//!
//! Every Meme comes from the actual `meme_template` source with only its decimals substituted, as
//! the generator does, at both admitted precisions. Each launch is opened by one PTB composed from
//! the public launchpad calls and measured by `Harness::resources` against the simulator's protocol
//! limits. Maximum shapes give every creator share a distinct weight rising with its position and
//! use a graduation target whose Quote remainders are all distinct, the worst case for
//! apportionment's remainder ranking.
//!
//! Records are JSON in `$BLAST_MEASUREMENTS_DIR`, by default
//! `<cargo target tmp>/<package>/launch_measurements/`, never in the repository.
//!
//! Run from `sui/launchpad/ptb_tests` with
//! `cargo test --test launch_measurements -- --nocapture` (needs the pinned `sui` on PATH).

use std::{
    path::{Path, PathBuf},
    time::Duration,
};

use anyhow::{Context, Result, ensure};
use base64::Engine;
use blast_launchpad_ptb_tests::{CompiledPackage, Expected, Harness, Outcome, build, call, sui_dir};
use serde::Deserialize;
use serde_json::{Value, json};
use sui_types::{
    SUI_CLOCK_OBJECT_ID, SUI_COIN_REGISTRY_OBJECT_ID, SUI_FRAMEWORK_PACKAGE_ID, TypeTag,
    base_types::{ObjectID, SuiAddress},
    effects::TransactionEffectsAPI,
    object::Owner,
    parse_sui_type_tag,
    programmable_transaction_builder::ProgrammableTransactionBuilder,
    transaction::{Argument, Command, ObjectArg, ProgrammableTransaction},
    type_input::TypeInput,
};

const COMMAND: &str = "cd sui/launchpad/ptb_tests && cargo test --test launch_measurements -- --nocapture";
const NOT_MEASURED: [&str; 5] = [
    "IDs created and destroyed or wrapped within one transaction are absent from effects, so \
     resources.effects.created is a lower bound for max_num_new_move_object_ids",
    "effects do not record Move transfers, so the transferred-ID count that \
     max_num_transferred_move_object_ids limits is not measured",
    "a Cetus-started launch creation: every launch here starts through the fixture adapter's `new`, \
     which makes no venue call, as Bluefin's does not; Cetus's `new`, which also mints the Meme's \
     pool creation cap and registers the pair in Cetus, runs only in the Cetus venue fork, whose \
     measurements cover migration",
    "per-object consensus congestion budgets schedule throughput; they do not bound one transaction",
    "the live mainnet protocol version is not read; every limit is the simulator's",
];

const TARGET: u64 = 25_000_000;
/// One atom over a round target gives every distinct Quote share a distinct remainder, so
/// apportionment ranks them all.
const MAXIMUM_TARGET: u64 = 25_000_001;
/// Allocation recipients per launch, Blast's included.
const MAX_PLAN_RECIPIENTS: usize = 16;
const MAX_FEE_RECIPIENTS: usize = 16;
const CURVE_BPS: u64 = 7_000;
/// The pool tier every launch starts at, in the mock venue's native units.
const POOL_TICK_SPACING: u32 = 60;
const POOL_FEE_RATE: u64 = 2_500;

/// `launch::set_opening_round` argument; zero leaves the launch without one and skips the call.
const NO_OPENING_ROUND: u64 = 0;
const OPENING_ROUND_MS: u64 = 60_000;
/// One public bid, and the purchase after settlement.
const BID: u64 = 25_000;
/// Far below the graduation target, so the creator's purchase before sharing refunds nothing.
const BUY_BEFORE_SHARE: u64 = 1_000_000;

const PROTOCOL: ObjectID = address(&[0xAD]);
const BENEFICIARY: ObjectID = address(&[0xBE]);

const fn address(suffix: &[u8]) -> ObjectID {
    let mut bytes = [0u8; 32];
    let mut index = 0;
    while index < suffix.len() {
        bytes[32 - suffix.len() + index] = suffix[index];
        index += 1;
    }
    ObjectID::new(bytes)
}

/// A zero Blast allocation: the Blast-only plan and sixteen recipients open, and a seventeenth
/// aborts at the allocation capacity check, committing nothing.
#[test]
fn zero_blast_allocation_through_sixteen_recipients_and_maximum_shapes_fit_protocol_limits() -> Result<()> {
    let mut w = World::new("launch_measurements_zero_blast", [0, 0])?;
    for decimals in [6, 9] {
        w.measure_family(decimals)?;
    }

    w.write()
}

/// The same matrix with a nonzero Blast allocation, which every plan pays first.
#[test]
fn blast_allocation_plans_and_maximum_shapes_fit_protocol_limits() -> Result<()> {
    let mut w = World::new("launch_measurements_blast", [500, 400])?;
    for decimals in [6, 9] {
        w.measure_family(decimals)?;
    }

    w.write()
}

/// One launch-opening PTB.
#[derive(Clone, Copy, Debug)]
struct Shape {
    /// Allocation recipients, Blast's included.
    plan_recipients: usize,
    fee_recipients: usize,
    target: u64,
    opening_round_ms: u64,
    /// The creator's purchase before sharing: a curve buy without an opening round, a bid with one.
    creator_purchase: bool,
}

impl Shape {
    fn maximum(plan_recipients: usize) -> Self {
        Self {
            plan_recipients,
            fee_recipients: MAX_FEE_RECIPIENTS,
            target: MAXIMUM_TARGET,
            opening_round_ms: OPENING_ROUND_MS,
            creator_purchase: false,
        }
    }
}

/// A generated currency whose ticket the sender holds.
struct Ticket {
    decimals: u8,
    meme: TypeTag,
    ticket: ObjectID,
    currency: ObjectID,
}

struct Opened {
    meme: TypeTag,
    launch: ObjectID,
}

/// `blast_fun::events::LaunchCreated`, its fee split's and allocation plan's fields inline, as BCS
/// lays them out.
#[derive(Deserialize)]
struct LaunchCreated {
    _launch_id: ObjectID,
    _ticket_id: ObjectID,
    _quote: String,
    _migration_witness: String,
    pool_tick_spacing: u32,
    pool_fee_rate: u64,
    creator_bps: u64,
    auto_lp_bps: u64,
    rewards_bps: u64,
    burn_bps: u64,
    fee_recipients: Vec<(SuiAddress, u64)>,
    _virtual_quote: u64,
    _graduation_target: u64,
    _quote_fee_bps: u64,
    _meme_fee_bps: u64,
    _curve_meme_bps: u64,
    _lp_meme_bps: u64,
    _lp_quote_bps: u64,
    plan_recipients: Vec<(SuiAddress, u64, u64)>,
    opening_round_ms: u64,
}

struct World {
    label: &'static str,
    h: Harness,
    blast: ObjectID,
    adapter: ObjectID,
    version: ObjectID,
    runtime: ObjectID,
    config: ObjectID,
    protocol: [u64; 2],
    templates: Vec<(u8, CompiledPackage)>,
    environment: Value,
    records: Vec<Value>,
}

impl World {
    /// Publishes the packages, admits SUI and the adapter under the production admin path, fixes
    /// the one-time Blast allocation at `protocol` (Meme, Quote) BPS, and compiles one generated
    /// template per admitted precision.
    fn new(label: &'static str, protocol: [u64; 2]) -> Result<Self> {
        let sui_dir = sui_dir();
        let fixture = Path::new(env!("CARGO_MANIFEST_DIR")).join("fixture");
        let work = Path::new(env!("CARGO_TARGET_TMPDIR")).join(env!("CARGO_PKG_NAME")).join(label);
        let mut h = Harness::new()?;
        let admin_dir = sui_dir.join("admin");
        let launchpad_dir = sui_dir.join("launchpad");
        let (admin, admin_published) = h.publish(build(&admin_dir, &[], &work)?)?;
        let (blast, published) = h.publish(build(&launchpad_dir, &[(&admin_dir, admin)], &work)?)?;
        let one = |outcome: &Outcome, module: &str, name: &str| {
            let ids = outcome.created(&h, module, name);
            assert_eq!(ids.len(), 1, "{module}::{name}");
            ids[0]
        };
        let acl = one(&admin_published, "blast_acl", "ACL");
        let root = one(&admin_published, "blast_acl", "SuperAdminCap");
        let config = one(&published, "launch_config", "LaunchConfig");
        let version = one(&published, "package_version", "PackageVersion");
        let runtime = one(&published, "runtime_config", "RuntimeConfig");
        let linked = [(admin_dir.as_path(), admin), (launchpad_dir.as_path(), blast)];
        let (adapter, _) = h.publish(build(&fixture.join("adapter"), &linked, &work)?)?;
        let mut templates = Vec::new();
        for decimals in [6u8, 9] {
            templates.push((decimals, build(&generate_template(&work, decimals)?, &linked, &work)?));
        }

        let environment = json!({
            "command": COMMAND,
            "sui_cli": sui_version()?,
            "build": "sui move build --dump -e testnet --no-tree-shaking, linked offline to simulator IDs",
            "executor": "simulacrum in-memory chain at the pinned sui revision, no network",
            "host": format!("{}-{}", std::env::consts::OS, std::env::consts::ARCH),
            "revision": source_revision(),
            "protocol_limits": h.protocol_limits(),
        });
        let mut w = Self {
            label,
            h,
            blast,
            adapter,
            version,
            runtime,
            config,
            protocol,
            templates,
            environment,
            records: Vec::new(),
        };

        // Production admin path: the publisher's SuperAdminCap grants one AdminCap and each role the
        // setters below take; the cap then signs in once per role.
        let mut roles = Vec::new();
        for role in ["ListingAdmin", "AdapterAdmin", "FeeAdmin", "TreasuryAdmin"] {
            roles.push(parse_sui_type_tag(&format!("{blast}::blast_fun_domain::{role}"))?);
        }
        let mut builder = ProgrammableTransactionBuilder::new();
        let acl_arg = builder.obj(w.h.shared(acl, true))?;
        let root_arg = builder.obj(w.h.owned(root))?;
        let recipient = builder.pure(w.h.sender)?;
        call(&mut builder, admin, "blast_acl", "grant_admin", vec![], vec![acl_arg, root_arg, recipient]);
        let granted = w.h.execute(builder.finish())?;
        granted.assert_success();
        let admin_cap = granted.created(&w.h, "blast_acl", "AdminCap")[0];

        let mut builder = ProgrammableTransactionBuilder::new();
        let acl_arg = builder.obj(w.h.shared(acl, true))?;
        let root_arg = builder.obj(w.h.owned(root))?;
        let admin_cap_id = builder.pure(admin_cap)?;
        for role in &roles {
            call(&mut builder, admin, "blast_acl", "grant_role", vec![role.clone()], vec![acl_arg, root_arg, admin_cap_id]);
        }
        w.h.execute(builder.finish())?.assert_success();

        let mut builder = ProgrammableTransactionBuilder::new();
        let acl_arg = builder.obj(w.h.shared(acl, false))?;
        let admin_cap = builder.obj(w.h.owned(admin_cap))?;
        let mut witnesses = Vec::new();
        for role in roles {
            witnesses.push(call(&mut builder, admin, "blast_acl", "sign_in", vec![role], vec![acl_arg, admin_cap]));
        }
        let [listing_admin, adapter_admin, fee_admin, treasury_admin]: [Argument; 4] =
            witnesses.try_into().expect("one witness per role");
        let config_arg = builder.obj(w.h.shared(config, true))?;
        let version_arg = builder.obj(w.h.shared(version, false))?;
        let quote_allowed = builder.pure(true)?;
        call(
            &mut builder,
            blast,
            "launch_config",
            "set_quote_allowed",
            vec![sui()],
            vec![config_arg, version_arg, listing_admin, quote_allowed],
        );
        let witness = parse_sui_type_tag(&format!("{adapter}::mock_adapter::Venue"))?;
        let allowed = builder.pure(true)?;
        call(
            &mut builder,
            blast,
            "launch_config",
            "set_migration_witness_allowed",
            vec![witness],
            vec![config_arg, version_arg, adapter_admin, allowed],
        );
        let fee = w.bps(&mut builder, 100)?;
        call(
            &mut builder,
            blast,
            "launch_config",
            "set_trade_fees",
            vec![],
            vec![config_arg, version_arg, fee_admin, fee, fee],
        );
        let [meme_bps, quote_bps] = protocol;
        let destination = builder.pure(SuiAddress::from(PROTOCOL))?;
        let meme_bps = w.bps(&mut builder, meme_bps)?;
        let quote_bps = w.bps(&mut builder, quote_bps)?;
        call(
            &mut builder,
            blast,
            "launch_config",
            "set_protocol_allocation",
            vec![],
            vec![config_arg, version_arg, treasury_admin, destination, meme_bps, quote_bps],
        );
        w.h.execute(builder.finish())?.assert_success();

        Ok(w)
    }

    /// Every boundary and maximum transaction at one precision.
    fn measure_family(&mut self, decimals: u8) -> Result<()> {
        // A seventeenth recipient aborts when finalization adds Blast's allocation and commits
        // nothing; the same ticket then opens the smallest valid plan.
        let ticket = self.publish_template(decimals, Some("generated_package_published"))?;
        let over = Shape::maximum(MAX_PLAN_RECIPIENTS + 1);
        let pt = self.open(&ticket, over)?;
        // `blast_fun::errors::recipient_capacity_reached`.
        let rejected = Expected::Abort { package: self.blast, module: "allocation", code: 8 };
        let sender = self.h.sender;
        self.h.assert_rolled_back(pt, rejected, &[ticket.ticket, ticket.currency], &[sender])?;
        let outcome = self.last_outcome()?;
        self.record("seventeen_recipients_rejected", decimals, Some(over), &outcome);

        let smallest = Shape {
            plan_recipients: 1,
            fee_recipients: 0,
            target: TARGET,
            opening_round_ms: NO_OPENING_ROUND,
            creator_purchase: false,
        };
        self.open_and_record("smallest_plan_created_and_shared", &ticket, smallest)?;

        let ticket = self.publish_template(decimals, None)?;
        let maximum = Shape::maximum(MAX_PLAN_RECIPIENTS);
        let opened = self.open_and_record("maximum_plan_created_and_shared", &ticket, maximum)?;
        self.opening_round(decimals, &opened)?;

        let ticket = self.publish_template(decimals, None)?;
        let buy_before_share = Shape { opening_round_ms: NO_OPENING_ROUND, creator_purchase: true, ..maximum };
        self.open_and_record("maximum_plan_buy_before_share", &ticket, buy_before_share)?;

        let ticket = self.publish_template(decimals, None)?;
        self.open_and_record("maximum_plan_bid_before_share", &ticket, Shape { creator_purchase: true, ..maximum })?;

        Ok(())
    }

    /// Publishes one generated package, whose initializer hands the sender its ticket, and
    /// finalizes the currency's registration into its shared form. Every publication at one
    /// precision is identical, so only a named one is recorded.
    fn publish_template(&mut self, decimals: u8, record: Option<&str>) -> Result<Ticket> {
        let package = self
            .templates
            .iter()
            .find(|(template, _)| *template == decimals)
            .map(|(_, package)| package.clone())
            .context("template")?;
        let mut builder = ProgrammableTransactionBuilder::new();
        let cap = builder.publish_upgradeable(package.modules, package.dependencies);
        builder.transfer_arg(self.h.sender, cap);
        let published = self.h.execute(builder.finish())?;
        published.assert_success();
        let project = published.effects.published_packages()[0];
        let ticket = published.created(&self.h, "launch_ticket", "LaunchTicket")[0];
        let pending = published.created(&self.h, "coin_registry", "Currency")[0];
        let meme = parse_sui_type_tag(&format!("{project}::meme::MEME"))?;
        if let Some(name) = record {
            self.record(name, decimals, None, &published);
        }

        let mut builder = ProgrammableTransactionBuilder::new();
        let registry = builder.obj(self.h.shared(SUI_COIN_REGISTRY_OBJECT_ID, true))?;
        let receiving = builder.obj(ObjectArg::Receiving(self.h.object(pending).compute_object_reference()))?;
        call(
            &mut builder,
            SUI_FRAMEWORK_PACKAGE_ID,
            "coin_registry",
            "finalize_registration",
            vec![meme.clone()],
            vec![registry, receiving],
        );
        let finalized = self.h.execute(builder.finish())?;
        finalized.assert_success();
        let currency = finalized.created(&self.h, "coin_registry", "Currency")[0];

        Ok(Ticket { decimals, meme, ticket, currency })
    }

    /// The last transaction the sender executed, read back from the simulator; used for one that
    /// `Harness::assert_rolled_back` ran.
    fn last_outcome(&self) -> Result<Outcome> {
        let digest = self.h.object(self.h.gas_id()).previous_transaction;
        let store = self.h.sim.store();

        Ok(Outcome {
            transaction: store.get_transaction(&digest).context("transaction")?.clone().into_inner(),
            effects: store.get_transaction_effects(&digest).context("effects")?.clone(),
            error: None,
            events: store.get_transaction_events(&digest).map(|events| events.data.clone()).unwrap_or_default(),
        })
    }

    /// Opens, measures, and checks one launch; maximum shapes must carry every table at capacity.
    fn open_and_record(&mut self, name: &str, ticket: &Ticket, shape: Shape) -> Result<Opened> {
        let outcome = self.h.execute(self.open(ticket, shape)?)?;
        outcome.assert_success();
        let names: Vec<_> = outcome.events.iter().map(payload_name).collect();
        let expected: &[&str] = match (shape.creator_purchase, shape.opening_round_ms) {
            (false, _) => &["LaunchCreated", "LaunchShared"],
            (true, NO_OPENING_ROUND) => &["LaunchCreated", "Bought", "LaunchShared"],
            (true, _) => &["LaunchCreated", "OpeningRoundJoined", "LaunchShared"],
        };
        assert_eq!(names, expected, "{name}");
        let created: LaunchCreated = bcs::from_bytes(&outcome.events[0].contents)?;
        assert_eq!(created.opening_round_ms, shape.opening_round_ms, "{name}: opening round");
        assert_eq!(created.plan_recipients.len(), shape.plan_recipients, "{name}: plan recipients");
        let [meme_bps, quote_bps] = self.protocol;
        assert_eq!(created.plan_recipients[0], (PROTOCOL.into(), meme_bps, quote_bps), "{name}: Blast first");
        assert_eq!((created.pool_tick_spacing, created.pool_fee_rate), (POOL_TICK_SPACING, POOL_FEE_RATE), "{name}");
        let (creator_bps, auto_lp_bps, rewards_bps, burn_bps, recipients) = fee_split(shape.fee_recipients);
        assert_eq!(
            (created.creator_bps, created.auto_lp_bps, created.rewards_bps, created.burn_bps),
            (creator_bps, auto_lp_bps, rewards_bps, burn_bps),
            "{name}: fee-split parts"
        );
        let expected: Vec<_> = recipients.into_iter().map(|(address, bps)| (SuiAddress::from(address), bps)).collect();
        assert_eq!(created.fee_recipients, expected, "{name}: fee-split recipients");
        let launch = outcome.created(&self.h, "launch", "Launch");
        assert_eq!(launch.len(), 1);
        assert!(self.h.object(launch[0]).is_shared());
        self.record(name, ticket.decimals, Some(shape), &outcome);

        Ok(Opened { meme: ticket.meme.clone(), launch: launch[0] })
    }

    /// The first bid creates the bidder's launch-owned record and a later one raises it; at the
    /// end, settlement buys once with the pot, delivery deletes the record, and the curve trades.
    /// The launch object itself never grows.
    fn opening_round(&mut self, decimals: u8, opened: &Opened) -> Result<()> {
        let launch_bytes = self.h.contents(opened.launch).len();
        let shape = Some(Shape::maximum(MAX_PLAN_RECIPIENTS));

        let first = self.h.execute(self.join(opened, BID)?)?;
        first.assert_success();
        let records = first.created(&self.h, "dynamic_field", "Field");
        assert_eq!(records.len(), 1, "the first bid creates one bidder record");
        let record = records[0];
        assert_eq!(*self.h.object(record).owner(), Owner::ObjectOwner(opened.launch.into()));
        self.record("first_bid", decimals, shape, &first);

        let later = self.h.execute(self.join(opened, BID)?)?;
        later.assert_success();
        assert!(later.created(&self.h, "dynamic_field", "Field").is_empty());
        assert!(later.effects.mutated().iter().any(|(object, _)| object.0 == record));
        self.record("later_bid", decimals, shape, &later);

        self.h.sim.advance_clock(Duration::from_millis(OPENING_ROUND_MS));
        let settled = self.h.execute(self.settle(opened)?)?;
        settled.assert_success();
        self.record("opening_round_settled", decimals, shape, &settled);

        let delivered = self.h.execute(self.deliver(opened)?)?;
        delivered.assert_success();
        assert!(delivered.effects.deleted().iter().any(|(object, _, _)| *object == record));
        self.record("opening_round_delivered", decimals, shape, &delivered);

        let bought = self.h.execute(self.buy(opened, BID)?)?;
        bought.assert_success();
        self.record("buy_after_settlement", decimals, shape, &bought);

        assert_eq!(self.h.contents(opened.launch).len(), launch_bytes, "the launch object grew");

        Ok(())
    }

    /// Composes one launch from the public calls: plan and fee split, the adapter's start, the
    /// settings, finalization, the creator's optional purchase before sharing (a curve buy
    /// delivered to the beneficiary, or a bid), and terminal share.
    fn open(&self, ticket: &Ticket, shape: Shape) -> Result<ProgrammableTransaction> {
        let mut builder = ProgrammableTransactionBuilder::new();
        let plan = self.plan(&mut builder, shape.plan_recipients)?;
        let fee_split = self.fee_split(&mut builder, shape.fee_recipients)?;
        let ticket_arg = builder.obj(self.h.owned(ticket.ticket))?;
        let version = builder.obj(self.h.shared(self.version, false))?;
        let config = builder.obj(self.h.shared(self.config, false))?;
        let tick_spacing = builder.pure(POOL_TICK_SPACING)?;
        let fee_rate = builder.pure(POOL_FEE_RATE)?;
        let initializer = call(
            &mut builder,
            self.adapter,
            "mock_adapter",
            "new",
            vec![ticket.meme.clone()],
            vec![ticket_arg, version, config, tick_spacing, fee_rate],
        );
        let pair = vec![ticket.meme.clone(), sui()];
        let virtual_quote = builder.pure(5_000_000u64)?;
        call(&mut builder, self.blast, "launch", "set_virtual_quote", pair.clone(), vec![initializer, virtual_quote]);
        let target = builder.pure(shape.target)?;
        call(&mut builder, self.blast, "launch", "set_graduation_target", pair.clone(), vec![initializer, target]);
        call(&mut builder, self.blast, "launch", "set_allocation_plan", pair.clone(), vec![initializer, plan]);
        call(&mut builder, self.blast, "launch", "set_lp_fee_split", pair.clone(), vec![initializer, fee_split]);
        if shape.opening_round_ms != NO_OPENING_ROUND {
            let opening_round_ms = builder.pure(shape.opening_round_ms)?;
            call(
                &mut builder,
                self.blast,
                "launch",
                "set_opening_round",
                pair.clone(),
                vec![initializer, opening_round_ms],
            );
        }
        let currency = builder.obj(self.h.shared(ticket.currency, true))?;
        let launch =
            call(
                &mut builder,
                self.blast,
                "launch",
                "finalize",
                pair.clone(),
                vec![initializer, currency, config],
            );
        let clock = builder.obj(self.h.shared(SUI_CLOCK_OBJECT_ID, false))?;
        if shape.creator_purchase && shape.opening_round_ms != NO_OPENING_ROUND {
            let amount = builder.pure(BUY_BEFORE_SHARE)?;
            let Argument::Result(split) = builder.command(Command::SplitCoins(Argument::GasCoin, vec![amount])) else {
                unreachable!()
            };
            call(
                &mut builder,
                self.blast,
                "launch",
                "join_opening_round",
                pair.clone(),
                vec![launch, version, Argument::NestedResult(split, 0), clock],
            );
        } else if shape.creator_purchase {
            let runtime = builder.obj(self.h.shared(self.runtime, false))?;
            let amount = builder.pure(BUY_BEFORE_SHARE)?;
            let Argument::Result(split) = builder.command(Command::SplitCoins(Argument::GasCoin, vec![amount])) else {
                unreachable!()
            };
            let min_meme_out = builder.pure(1u64)?;
            let Argument::Result(bought) = call(
                &mut builder,
                self.blast,
                "launch",
                "buy",
                pair.clone(),
                vec![launch, version, runtime, Argument::NestedResult(split, 0), min_meme_out],
            ) else {
                unreachable!()
            };
            // Only a graduating purchase refunds, and this one is far below the target.
            call(
                &mut builder,
                SUI_FRAMEWORK_PACKAGE_ID,
                "coin",
                "destroy_zero",
                vec![sui()],
                vec![Argument::NestedResult(bought, 1)],
            );
            builder.transfer_args(BENEFICIARY.into(), vec![Argument::NestedResult(bought, 0)]);
        }
        call(&mut builder, self.blast, "launch", "share", pair, vec![launch, clock]);

        Ok(builder.finish())
    }

    /// Builds the creator's plan for `plan_recipients` recipients, Blast's included, which
    /// finalization adds first: 70% of the Meme on the curve, and the pool and each creator
    /// recipient sharing the rest of each asset with distinct weights rising in that order.
    fn plan(&self, builder: &mut ProgrammableTransactionBuilder, plan_recipients: usize) -> Result<Argument> {
        let [protocol_meme, protocol_quote] = self.protocol;
        let meme = distinct_weights(plan_recipients, 10_000 - CURVE_BPS - protocol_meme);
        let quote = distinct_weights(plan_recipients, 10_000 - protocol_quote);
        let mut recipients = Vec::new();
        for i in 1..plan_recipients {
            let destination = builder.pure(SuiAddress::from(address(&[0xC1, i as u8])))?;
            let meme_bps = self.bps(builder, meme[i])?;
            let quote_bps = self.bps(builder, quote[i])?;
            recipients.push(call(builder, self.blast, "allocation", "recipient", vec![], vec![
                destination,
                meme_bps,
                quote_bps,
            ]));
        }
        let recipients = builder.command(Command::MakeMoveVec(Some(self.allocation_type("Recipient")?), recipients));
        let curve_meme_bps = self.bps(builder, CURVE_BPS)?;
        let lp_meme_bps = self.bps(builder, meme[0])?;
        let lp_quote_bps = self.bps(builder, quote[0])?;

        Ok(call(builder, self.blast, "allocation", "plan", vec![], vec![
            curve_meme_bps,
            lp_meme_bps,
            lp_quote_bps,
            recipients,
        ]))
    }

    /// Builds `fee_split(recipients)` through the public constructors.
    fn fee_split(&self, builder: &mut ProgrammableTransactionBuilder, recipients: usize) -> Result<Argument> {
        let (creator_bps, auto_lp_bps, rewards_bps, burn_bps, recipients) = fee_split(recipients);
        let mut routes = Vec::new();
        for (destination, bps) in recipients {
            let destination = builder.pure(SuiAddress::from(destination))?;
            let bps = self.bps(builder, bps)?;
            routes.push(call(builder, self.blast, "allocation", "route", vec![], vec![destination, bps]));
        }
        let routes = builder.command(Command::MakeMoveVec(Some(self.allocation_type("Route")?), routes));
        let creator_bps = self.bps(builder, creator_bps)?;
        let auto_lp_bps = self.bps(builder, auto_lp_bps)?;
        let rewards_bps = self.bps(builder, rewards_bps)?;
        let burn_bps = self.bps(builder, burn_bps)?;

        Ok(call(
            builder,
            self.blast,
            "allocation",
            "fee_split",
            vec![],
            vec![creator_bps, auto_lp_bps, rewards_bps, burn_bps, routes],
        ))
    }

    fn bps(&self, builder: &mut ProgrammableTransactionBuilder, value: u64) -> Result<Argument> {
        let value = builder.pure(value)?;

        Ok(call(builder, self.blast, "bps", "new", vec![], vec![value]))
    }

    fn allocation_type(&self, name: &str) -> Result<TypeInput> {
        Ok(parse_sui_type_tag(&format!("{}::allocation::{name}", self.blast))?.into())
    }

    /// Buys from `opened` with `quote_in` MIST split from gas and keeps both returned coins.
    fn buy(&self, opened: &Opened, quote_in: u64) -> Result<ProgrammableTransaction> {
        let mut builder = ProgrammableTransactionBuilder::new();
        let amount = builder.pure(quote_in)?;
        let Argument::Result(split) = builder.command(Command::SplitCoins(Argument::GasCoin, vec![amount])) else {
            unreachable!()
        };
        let launch = builder.obj(self.h.shared(opened.launch, true))?;
        let version = builder.obj(self.h.shared(self.version, false))?;
        let runtime = builder.obj(self.h.shared(self.runtime, false))?;
        let min_meme_out = builder.pure(1u64)?;
        let Argument::Result(bought) = call(
            &mut builder,
            self.blast,
            "launch",
            "buy",
            vec![opened.meme.clone(), sui()],
            vec![launch, version, runtime, Argument::NestedResult(split, 0), min_meme_out],
        ) else {
            unreachable!()
        };
        builder
            .transfer_args(self.h.sender, vec![Argument::NestedResult(bought, 0), Argument::NestedResult(bought, 1)]);

        Ok(builder.finish())
    }

    /// Joins `opened`'s opening round with `quote_in` MIST split from gas.
    fn join(&self, opened: &Opened, quote_in: u64) -> Result<ProgrammableTransaction> {
        let mut builder = ProgrammableTransactionBuilder::new();
        let amount = builder.pure(quote_in)?;
        let Argument::Result(split) = builder.command(Command::SplitCoins(Argument::GasCoin, vec![amount])) else {
            unreachable!()
        };
        let launch = builder.obj(self.h.shared(opened.launch, true))?;
        let version = builder.obj(self.h.shared(self.version, false))?;
        let clock = builder.obj(self.h.shared(SUI_CLOCK_OBJECT_ID, false))?;
        call(
            &mut builder,
            self.blast,
            "launch",
            "join_opening_round",
            vec![opened.meme.clone(), sui()],
            vec![launch, version, Argument::NestedResult(split, 0), clock],
        );

        Ok(builder.finish())
    }

    /// Settles `opened`'s opening round.
    fn settle(&self, opened: &Opened) -> Result<ProgrammableTransaction> {
        let mut builder = ProgrammableTransactionBuilder::new();
        let launch = builder.obj(self.h.shared(opened.launch, true))?;
        let version = builder.obj(self.h.shared(self.version, false))?;
        let runtime = builder.obj(self.h.shared(self.runtime, false))?;
        let clock = builder.obj(self.h.shared(SUI_CLOCK_OBJECT_ID, false))?;
        call(
            &mut builder,
            self.blast,
            "launch",
            "settle_opening_round",
            vec![opened.meme.clone(), sui()],
            vec![launch, version, runtime, clock],
        );

        Ok(builder.finish())
    }

    /// Delivers the sender's share of `opened`'s settled opening round.
    fn deliver(&self, opened: &Opened) -> Result<ProgrammableTransaction> {
        let mut builder = ProgrammableTransactionBuilder::new();
        let launch = builder.obj(self.h.shared(opened.launch, true))?;
        let version = builder.obj(self.h.shared(self.version, false))?;
        let bidder = builder.pure(self.h.sender)?;
        call(
            &mut builder,
            self.blast,
            "launch",
            "deliver_opening_round",
            vec![opened.meme.clone(), sui()],
            vec![launch, version, bidder],
        );

        Ok(builder.finish())
    }

    /// One record: the fixture and environment, every written object's size, the transaction's
    /// resources against the protocol limits (a limit exceeded fails the test), and the raw effects
    /// and event bytes.
    fn record(&mut self, name: &str, decimals: u8, shape: Option<Shape>, outcome: &Outcome) {
        let effects = &outcome.effects;
        let written =
            [("created", effects.created()), ("mutated", effects.mutated()), ("unwrapped", effects.unwrapped())];
        let objects: Vec<_> = written
            .into_iter()
            .flat_map(|(change, refs)| refs.into_iter().map(move |reference| (change, reference)))
            .map(|(change, ((id, version, _), owner))| {
                let object = self.h.sim.store().get_object_at_version(&id, version).expect("written object");
                json!({
                    "change": change,
                    "type": object.data.type_().map_or("package".into(), |ty| ty.to_string()),
                    "owner": match owner {
                        Owner::AddressOwner(_) => "address",
                        Owner::ObjectOwner(_) => "object",
                        Owner::Shared { .. } => "shared",
                        _ => "other",
                    },
                    "contents_bytes": object.data.try_as_move().map_or(0, |object| object.contents().len()),
                    "metered_bytes": object.object_size_for_gas_metering(),
                })
            })
            .collect();
        let record = json!({
            "id": format!("{name}.decimals_{decimals}"),
            "status": "measured",
            "environment": self.environment,
            "fixture": {
                "meme": "actual meme_template with DECIMALS substituted",
                "decimals": decimals,
                "protocol_allocation_bps": json!({ "meme": self.protocol[0], "quote": self.protocol[1] }),
                "launch": shape.map(|shape| json!({
                    "plan_recipients": shape.plan_recipients,
                    "fee_split_recipients": shape.fee_recipients,
                    "graduation_target": shape.target,
                    "opening_round_ms": shape.opening_round_ms,
                    "creator_purchase_before_share": shape.creator_purchase,
                })),
            },
            "units": "MIST, bytes, and gas units as each field names; an event's emit_size is the abstract \
                      size sui::event::emit limits (type tag plus value)",
            "objects": objects,
            "resources": self.h.resources(outcome),
            "raw": {
                "digest": effects.transaction_digest().to_string(),
                "effects_bcs_base64": base64(&bcs::to_bytes(effects).expect("effects")),
                "events": outcome.events.iter().map(|event| json!({
                    "type": event.type_.to_canonical_string(true),
                    "contents_base64": base64(&event.contents),
                })).collect::<Vec<_>>(),
            },
            "not_measured": NOT_MEASURED,
        });
        self.records.push(record);
    }

    /// Writes every record and a summary of each record's margins to the isolated output directory.
    fn write(&self) -> Result<()> {
        let dir = std::env::var_os("BLAST_MEASUREMENTS_DIR").map(PathBuf::from).unwrap_or_else(|| {
            Path::new(env!("CARGO_TARGET_TMPDIR")).join(env!("CARGO_PKG_NAME")).join("launch_measurements")
        });
        std::fs::create_dir_all(&dir)?;
        let summary: Vec<_> = self
            .records
            .iter()
            .map(|record| {
                let mut margins = serde_json::Map::new();
                collect_margins(&record["resources"], String::new(), &mut margins);
                json!({
                    "id": record["id"],
                    "status": record["resources"]["status"],
                    "gas": record["resources"]["gas"],
                    "margins": margins,
                })
            })
            .collect();
        let skipped = json!({
            "id": "sui_client_dry_run_and_dev_inspect",
            "status": "skipped",
            "reason": "no network or local validator is approved; the simulator executes the same PTBs",
            "environment": self.environment,
        });
        let path = dir.join(format!("{}.json", self.label));
        let output = json!({ "summary": summary, "records": self.records, "skipped": [skipped] });
        std::fs::write(&path, serde_json::to_string_pretty(&output)?)?;
        println!("wrote {}", path.display());

        Ok(())
    }
}

/// Every bounded quantity in `value` by its path, with its margin to the limit.
fn collect_margins(value: &Value, path: String, margins: &mut serde_json::Map<String, Value>) {
    match value {
        Value::Object(fields) if fields.contains_key("margin") => {
            margins.insert(path, fields["margin"].clone());
        }
        Value::Object(fields) => {
            fields.iter().for_each(|(key, field)| collect_margins(field, format!("{path}.{key}"), margins))
        }
        Value::Array(items) => items
            .iter()
            .enumerate()
            .for_each(|(index, item)| collect_margins(item, format!("{path}[{index}]"), margins)),
        _ => {}
    }
}

/// Copies the actual template with only `DECIMALS` substituted, as the generator does.
fn generate_template(work: &Path, decimals: u8) -> Result<PathBuf> {
    let template = sui_dir().join("meme_template");
    let source = std::fs::read_to_string(template.join("sources/meme.move"))?;
    let constant = "const DECIMALS: u8 = 9;";
    ensure!(source.matches(constant).count() == 1, "the template no longer declares {constant}");
    let dir = work.join(format!("meme_template_{decimals}"));
    std::fs::create_dir_all(dir.join("sources"))?;
    std::fs::write(
        dir.join("sources/meme.move"),
        source.replace(constant, &format!("const DECIMALS: u8 = {decimals};")),
    )?;
    let manifest = format!(
        "[package]\nname = \"meme_template\"\nedition = \"2024\"\n\n\
         [dependencies]\nblast_fun = {{ local = \"{}\" }}\n\n\
         [addresses]\nmeme_template = \"0x0\"\n",
        sui_dir().join("launchpad").display(),
    );
    std::fs::write(dir.join("Move.toml"), manifest)?;

    Ok(dir)
}

/// The fixture fee split with `recipients` recipients: without recipients the creator takes everything; otherwise every part is set and the recipients share
/// the rest with distinct weights.
fn fee_split(recipients: usize) -> (u64, u64, u64, u64, Vec<(ObjectID, u64)>) {
    if recipients == 0 {
        return (10_000, 0, 0, 0, Vec::new());
    }
    let addresses = (1..=recipients).map(|j| address(&[0xE1, j as u8]));

    (1_000, 600, 400, 500, addresses.zip(distinct_weights(recipients, 7_500)).collect())
}

/// `count` distinct positive weights rising by one and summing to `total`.
fn distinct_weights(count: usize, total: u64) -> Vec<u64> {
    let count = count as u64;
    let steps = count * count.saturating_sub(1) / 2;
    let base = (total - steps) / count;
    let mut weights: Vec<_> = (0..count).map(|step| base + step).collect();
    *weights.last_mut().expect("one weight") += total - base * count - steps;
    weights
}

/// An event's payload name, looking through the Blast envelope.
fn payload_name(event: &sui_types::event::Event) -> String {
    match &event.type_.type_params[..] {
        [TypeTag::Struct(payload)] if event.type_.module.as_str() == "blast_events" => payload.name.to_string(),
        _ => event.type_.name.to_string(),
    }
}

fn sui_version() -> Result<String> {
    let binary = std::env::var("SUI_BINARY").unwrap_or_else(|_| "sui".into());
    let output = std::process::Command::new(binary).arg("--version").output()?;

    Ok(String::from_utf8(output.stdout)?.trim().to_string())
}

/// The repository revision the packages were built from, when the tree is a git checkout.
fn source_revision() -> Value {
    let git = |args: &[&str]| {
        let output = std::process::Command::new("git").arg("-C").arg(sui_dir()).args(args).output().ok()?;
        output.status.success().then(|| String::from_utf8_lossy(&output.stdout).trim().to_string())
    };

    json!({
        "git_head": git(&["rev-parse", "HEAD"]),
        "uncommitted_paths_under_sui": git(&["status", "--porcelain", "--", "."]).map(|status| status.lines().count()),
    })
}

fn base64(bytes: &[u8]) -> String {
    base64::engine::general_purpose::STANDARD.encode(bytes)
}

fn sui() -> TypeTag {
    parse_sui_type_tag("0x2::sui::SUI").expect("SUI type")
}
