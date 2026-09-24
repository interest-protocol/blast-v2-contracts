//! Resource measurements for the launch and protection family: the one-time channel boundary,
//! maximum launch creation with terminal share, the pre-share purchase with linear vesting, and
//! first, later, and expired protected buys.
//!
//! Every Meme comes from the actual `meme_template` source with only its decimals substituted, as
//! the generator does, at both admitted precisions. Each launch is opened by one PTB composed from
//! the public launchpad calls and measured by `Harness::resources` against the simulator's protocol
//! limits. Maximum shapes feed every table in descending order and use a graduation target whose
//! Quote remainders are all distinct, the worst case for intake's insertion sorts and dust ranking.
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
/// One atom over a round target gives every Quote weight a distinct remainder, so intake ranks the
/// whole Quote table for dust.
const MAXIMUM_TARGET: u64 = 25_000_001;
const MAX_IDENTITIES: usize = 16;
const MAX_RECIPIENTS: usize = 16;
const CURVE_BPS: u64 = 7_000;
/// The pool tier every launch starts at, in the mock venue's native units.
const POOL_TICK_SPACING: u32 = 60;
const POOL_FEE_RATE: u64 = 2_500;

/// `launch::set_protection` arguments: window, cumulative BPS, per-transaction BPS. Unprotected
/// shapes leave protection at its disabled default and skip the call.
const UNPROTECTED: [u64; 3] = [0, 0, 0];
const WINDOW_MS: u64 = 60_000;
const PROTECTED: [u64; 3] = [WINDOW_MS, 100, 50];
/// Fits both limits twice at either precision.
const PROTECTED_BUY: u64 = 25_000;
/// Above both limits; bought at the protection end, where nothing is checked.
const EXPIRED_BUY: u64 = 80_000;
/// Far below the graduation target, as the pre-share purchase requires.
const PRE_SHARE_BUY: u64 = 1_000_000;

const PROTOCOL_CHANNEL: u64 = 1;
const LIQUIDITY_CHANNEL: u64 = 2;
const PROTOCOL: ObjectID = address(&[0xAD]);
const BENEFICIARY: ObjectID = address(&[0xBE]);
const REFUND_RECIPIENT: ObjectID = address(&[0xDF]);
const CREATOR: ObjectID = address(&[0xC0, 0xDE]);

const fn address(suffix: &[u8]) -> ObjectID {
    let mut bytes = [0u8; 32];
    let mut index = 0;
    while index < suffix.len() {
        bytes[32 - suffix.len() + index] = suffix[index];
        index += 1;
    }
    ObjectID::new(bytes)
}

/// Without a protocol channel the LP-only plan is the smallest: it and sixteen identities open,
/// and a seventeenth aborts at the allocation capacity check, committing nothing.
#[test]
fn lp_only_through_sixteen_identities_and_maximum_shapes_fit_protocol_limits() -> Result<()> {
    let mut w = World::new("launch_measurements_lp_only", None)?;
    for decimals in [6, 9] {
        w.measure_family(decimals)?;
    }

    w.write()
}

/// The same matrix when the one-time Blast allocation names a protocol channel, which every plan
/// must then carry, so the smallest plan is liquidity plus protocol.
#[test]
fn protocol_channel_plans_and_maximum_shapes_fit_protocol_limits() -> Result<()> {
    let mut w = World::new("launch_measurements_protocol", Some([500, 400]))?;
    for decimals in [6, 9] {
        w.measure_family(decimals)?;
    }

    w.write()
}

#[derive(Clone, Copy, Debug)]
enum Vesting {
    Cancelable,
    Irrevocable,
}

/// One launch-opening PTB.
#[derive(Clone, Copy, Debug)]
struct Shape {
    identities: usize,
    recipients: usize,
    target: u64,
    protection: [u64; 3],
    vesting: Option<Vesting>,
}

impl Shape {
    fn maximum(identities: usize) -> Self {
        Self {
            identities,
            recipients: MAX_RECIPIENTS,
            target: MAXIMUM_TARGET,
            protection: PROTECTED,
            vesting: None,
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
    _decimals: u8,
    _atomic_supply: u64,
    _quote: String,
    _migration_witness: String,
    pool_tick_spacing: u32,
    pool_fee_rate: u64,
    creator_bps: u64,
    auto_lp_bps: u64,
    rewards_bps: u64,
    recipients: Vec<(SuiAddress, u64)>,
    _virtual_quote: u64,
    _graduation_target: u64,
    _quote_fee_bps: u64,
    _meme_fee_bps: u64,
    channels: Vec<(u64, Role, SuiAddress)>,
    meme: Vec<(u64, u64)>,
    quote: Vec<(u64, u64)>,
    meme_amounts: Vec<u64>,
}

#[derive(Deserialize)]
enum Role {
    Liquidity,
    Protocol,
    External,
}

struct World {
    label: &'static str,
    h: Harness,
    blast: ObjectID,
    adapter: ObjectID,
    vesting: ObjectID,
    version: ObjectID,
    runtime: ObjectID,
    config: ObjectID,
    protocol: Option<[u64; 2]>,
    templates: Vec<(u8, CompiledPackage)>,
    environment: Value,
    records: Vec<Value>,
}

impl World {
    /// Publishes the packages, admits SUI and the adapter under the production admin path, fixes
    /// the one-time Blast allocation (none when `protocol` is `None`), and compiles one generated
    /// template per admitted precision.
    fn new(label: &'static str, protocol: Option<[u64; 2]>) -> Result<Self> {
        let sui_dir = sui_dir();
        let fixture = Path::new(env!("CARGO_MANIFEST_DIR")).join("fixture");
        let work = Path::new(env!("CARGO_TARGET_TMPDIR")).join(env!("CARGO_PKG_NAME")).join(label);
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
        let linked = [(admin_dir.as_path(), admin), (launchpad_dir.as_path(), blast)];
        let (adapter, _) = h.publish(build(&fixture.join("adapter"), &linked, &work)?)?;
        let (vesting, _) = h.publish(build(&sui_dir.join("vesting"), &[], &work)?)?;
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
            vesting,
            version,
            runtime,
            config,
            protocol,
            templates,
            environment,
            records: Vec::new(),
        };
        let domain = parse_sui_type_tag(&format!("{blast}::blast_fun_domain::BLAST_FUN_DOMAIN"))?;

        let mut builder = ProgrammableTransactionBuilder::new();
        let authority_arg = builder.obj(w.h.shared(authority, true))?;
        let root = builder.obj(w.h.owned(root))?;
        let roles = builder.pure(u64::MAX)?;
        let recipient = builder.pure(w.h.sender)?;
        call(
            &mut builder,
            admin,
            "acl",
            "grant_admin",
            vec![domain.clone()],
            vec![authority_arg, root, roles, recipient],
        );
        w.h.execute(builder.finish())?.assert_success();
        let admin_cap = w.h.owned_of_type(w.h.sender, "acl", "AdminCap")[0];

        let mut builder = ProgrammableTransactionBuilder::new();
        let authority = builder.obj(w.h.shared(authority, false))?;
        let admin_cap = builder.obj(w.h.owned(admin_cap))?;
        let signed_in = call(&mut builder, admin, "acl", "sign_in", vec![domain], vec![authority, admin_cap]);
        let config_arg = builder.obj(w.h.shared(config, true))?;
        let version_arg = builder.obj(w.h.shared(version, false))?;
        let virtual_quote = builder.pure(5_000_000u64)?;
        call(
            &mut builder,
            blast,
            "launch_config",
            "allow_quote",
            vec![sui()],
            vec![config_arg, version_arg, signed_in, virtual_quote],
        );
        let witness = parse_sui_type_tag(&format!("{adapter}::mock_adapter::Venue"))?;
        call(
            &mut builder,
            blast,
            "launch_config",
            "allow_migration_witness",
            vec![witness],
            vec![config_arg, version_arg, signed_in],
        );
        let fee = w.bps(&mut builder, 100)?;
        call(
            &mut builder,
            blast,
            "launch_config",
            "set_trade_fees",
            vec![],
            vec![config_arg, version_arg, signed_in, fee, fee],
        );
        let [meme_bps, quote_bps] = protocol.unwrap_or([0, 0]);
        let channel = builder.pure(PROTOCOL_CHANNEL)?;
        let destination = builder.pure(SuiAddress::from(PROTOCOL))?;
        let meme_bps = w.bps(&mut builder, meme_bps)?;
        let quote_bps = w.bps(&mut builder, quote_bps)?;
        call(
            &mut builder,
            blast,
            "launch_config",
            "set_protocol_allocation",
            vec![],
            vec![config_arg, version_arg, signed_in, channel, destination, meme_bps, quote_bps],
        );
        w.h.execute(builder.finish())?.assert_success();

        Ok(w)
    }

    /// Every boundary and maximum transaction at one precision.
    fn measure_family(&mut self, decimals: u8) -> Result<()> {
        // A seventeenth identity aborts in allocation intake, before the ticket is consumed, and
        // commits nothing; the same ticket then opens the smallest valid plan.
        let ticket = self.publish_template(decimals, Some("generated_package_published"))?;
        let over = Shape::maximum(MAX_IDENTITIES + 1);
        let pt = self.open(&ticket, over)?;
        let rejected = Expected::Abort { package: self.blast, module: "allocation", code: 46 };
        let sender = self.h.sender;
        self.h.assert_rolled_back(pt, rejected, &[ticket.ticket, ticket.currency], &[sender])?;
        let outcome = self.last_outcome()?;
        self.record("seventeen_identities_rejected", decimals, Some(over), &outcome);

        let smallest = Shape {
            identities: if self.protocol.is_some() { 2 } else { 1 },
            recipients: 0,
            target: TARGET,
            protection: UNPROTECTED,
            vesting: None,
        };
        self.open_and_record("smallest_plan_created_and_shared", &ticket, smallest)?;

        let ticket = self.publish_template(decimals, None)?;
        let maximum = Shape::maximum(MAX_IDENTITIES);
        let opened = self.open_and_record("maximum_plan_created_and_shared", &ticket, maximum)?;
        self.protected_buys(decimals, &opened)?;

        for vesting in [Vesting::Cancelable, Vesting::Irrevocable] {
            let ticket = self.publish_template(decimals, None)?;
            let name = match vesting {
                Vesting::Cancelable => "maximum_plan_pre_share_cancelable_vesting",
                Vesting::Irrevocable => "maximum_plan_pre_share_irrevocable_vesting",
            };
            self.open_and_record(name, &ticket, Shape { vesting: Some(vesting), ..maximum })?;
        }

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
        let expected: &[&str] = match shape.vesting {
            None => &["LaunchCreated", "ProtectionConfigured", "LaunchShared"],
            Some(_) => &[
                "LaunchCreated",
                "ProtectionConfigured",
                "PreShareBought",
                "VestingCreated",
                "LaunchShared",
            ],
        };
        assert_eq!(names, expected, "{name}");
        let created: LaunchCreated = bcs::from_bytes(&outcome.events[0].contents)?;
        assert_eq!(created.channels.len(), shape.identities, "{name}: identities");
        assert_eq!(created.meme.len(), shape.identities + 1, "{name}: every identity and the curve in the Meme table");
        assert_eq!(created.quote.len(), shape.identities, "{name}: every identity in the Quote table");
        assert_eq!(created.meme_amounts.len(), shape.identities + 1, "{name}: Meme amounts");
        assert_eq!((created.pool_tick_spacing, created.pool_fee_rate), (POOL_TICK_SPACING, POOL_FEE_RATE), "{name}");
        let (creator_bps, auto_lp_bps, rewards_bps, recipients) = fee_split(shape.recipients);
        assert_eq!(
            (created.creator_bps, created.auto_lp_bps, created.rewards_bps),
            (creator_bps, auto_lp_bps, rewards_bps),
            "{name}: fee-split parts"
        );
        let expected: Vec<_> = recipients.into_iter().map(|(address, bps)| (SuiAddress::from(address), bps)).collect();
        assert_eq!(created.recipients, expected, "{name}: recipients in canonical order");
        let launch = outcome.created(&self.h, "launch", "Launch");
        assert_eq!(launch.len(), 1);
        assert!(self.h.object(launch[0]).is_shared());
        self.record(name, ticket.decimals, Some(shape), &outcome);

        Ok(Opened { meme: ticket.meme.clone(), launch: launch[0] })
    }

    /// The first protected buy creates the sender's launch-owned record, a later one reads and
    /// raises it, and a buy at the protection end neither checks nor touches it. The launch object
    /// itself never grows.
    fn protected_buys(&mut self, decimals: u8, opened: &Opened) -> Result<()> {
        let launch_bytes = self.h.contents(opened.launch).len();
        let shape = Some(Shape::maximum(MAX_IDENTITIES));

        let first = self.h.execute(self.buy(opened, PROTECTED_BUY)?)?;
        first.assert_success();
        let records = first.created(&self.h, "dynamic_field", "Field");
        assert_eq!(records.len(), 1, "the first protected buy creates one sender record");
        let record = records[0];
        assert_eq!(*self.h.object(record).owner(), Owner::ObjectOwner(opened.launch.into()));
        self.record("first_protected_buy", decimals, shape, &first);

        let later = self.h.execute(self.buy(opened, PROTECTED_BUY)?)?;
        later.assert_success();
        assert!(later.created(&self.h, "dynamic_field", "Field").is_empty());
        assert!(later.effects.mutated().iter().any(|(object, _)| object.0 == record));
        self.record("later_protected_buy", decimals, shape, &later);

        self.h.sim.advance_clock(Duration::from_millis(WINDOW_MS));
        let record_bytes = self.h.contents(record);
        let expired = self.h.execute(self.buy(opened, EXPIRED_BUY)?)?;
        expired.assert_success();
        assert!(expired.created(&self.h, "dynamic_field", "Field").is_empty());
        assert!(expired.effects.mutated().iter().all(|(object, _)| object.0 != record));
        assert_eq!(self.h.contents(record), record_bytes);
        self.record("buy_at_protection_end", decimals, shape, &expired);

        assert_eq!(self.h.contents(opened.launch).len(), launch_bytes, "the launch object grew");

        Ok(())
    }

    /// Composes one launch from the public calls: plan and fee split, the adapter's start, the
    /// settings, finalization, the optional pre-share purchase vested linearly, and terminal share.
    fn open(&self, ticket: &Ticket, shape: Shape) -> Result<ProgrammableTransaction> {
        let mut builder = ProgrammableTransactionBuilder::new();
        let plan = self.plan(&mut builder, shape.identities)?;
        let fee_split = self.fee_split(&mut builder, shape.recipients)?;
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
        let target = builder.pure(shape.target)?;
        call(&mut builder, self.blast, "launch", "set_graduation_target", pair.clone(), vec![initializer, target]);
        call(&mut builder, self.blast, "launch", "set_allocation_plan", pair.clone(), vec![initializer, plan]);
        call(&mut builder, self.blast, "launch", "set_lp_fee_split", pair.clone(), vec![initializer, fee_split]);
        if shape.protection != UNPROTECTED {
            let [window_ms, cumulative_bps, per_transaction_bps] = shape.protection;
            let window_ms = builder.pure(window_ms)?;
            let cumulative_bps = self.bps(&mut builder, cumulative_bps)?;
            let per_transaction_bps = self.bps(&mut builder, per_transaction_bps)?;
            call(
                &mut builder,
                self.blast,
                "launch",
                "set_protection",
                pair.clone(),
                vec![initializer, window_ms, cumulative_bps, per_transaction_bps],
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
                vec![initializer, version, currency, config],
            );
        let clock = builder.obj(self.h.shared(SUI_CLOCK_OBJECT_ID, false))?;
        if let Some(vesting) = shape.vesting {
            let runtime = builder.obj(self.h.shared(self.runtime, false))?;
            let amount = builder.pure(PRE_SHARE_BUY)?;
            let Argument::Result(split) = builder.command(Command::SplitCoins(Argument::GasCoin, vec![amount])) else {
                unreachable!()
            };
            let min_meme_out = builder.pure(1u64)?;
            let Argument::Result(bought) = call(
                &mut builder,
                self.blast,
                "launch",
                "pre_share_buy",
                pair.clone(),
                vec![launch, version, runtime, Argument::NestedResult(split, 0), min_meme_out],
            ) else {
                unreachable!()
            };
            // Only a graduating purchase refunds, and a pre-share purchase cannot graduate.
            call(
                &mut builder,
                SUI_FRAMEWORK_PACKAGE_ID,
                "coin",
                "destroy_zero",
                vec![sui()],
                vec![Argument::NestedResult(bought, 1)],
            );
            let beneficiary = builder.pure(SuiAddress::from(BENEFICIARY))?;
            let start_ms = builder.pure(self.h.sim.store().get_clock().timestamp_ms())?;
            let cliff_ms = builder.pure(0u64)?;
            let period_ms = builder.pure(1_000u64)?;
            let periods = builder.pure(2u64)?;
            let meme = vec![ticket.meme.clone()];
            let funds = Argument::NestedResult(bought, 0);
            let schedule = match vesting {
                Vesting::Cancelable => {
                    let refund_recipient = builder.pure(SuiAddress::from(REFUND_RECIPIENT))?;
                    let Argument::Result(created) = call(
                        &mut builder,
                        self.vesting,
                        "blast_fun_linear_vesting",
                        "new_cancelable",
                        meme.clone(),
                        vec![funds, beneficiary, refund_recipient, start_ms, cliff_ms, period_ms, periods, clock],
                    ) else {
                        unreachable!()
                    };
                    builder.transfer_args(CREATOR.into(), vec![Argument::NestedResult(created, 1)]);
                    Argument::NestedResult(created, 0)
                }
                Vesting::Irrevocable => call(
                    &mut builder,
                    self.vesting,
                    "blast_fun_linear_vesting",
                    "new_irrevocable",
                    meme.clone(),
                    vec![funds, beneficiary, start_ms, cliff_ms, period_ms, periods, clock],
                ),
            };
            call(&mut builder, self.vesting, "blast_fun_linear_vesting", "share", meme, vec![schedule]);
        }
        call(&mut builder, self.blast, "launch", "share", pair, vec![launch, version, clock]);

        Ok(builder.finish())
    }

    /// Builds the allocation plan in descending identity order. Liquidity is channel 2 and a
    /// configured protocol channel is channel 1 with the configured weights; every other weight
    /// is distinct and rises with its channel ID.
    fn plan(&self, builder: &mut ProgrammableTransactionBuilder, identities: usize) -> Result<Argument> {
        let mut ids = vec![LIQUIDITY_CHANNEL];
        ids.extend(self.protocol.map(|_| PROTOCOL_CHANNEL));
        ids.extend((3..).take(identities.saturating_sub(ids.len())));
        ids.sort();
        let [protocol_meme, protocol_quote] = self.protocol.unwrap_or([0, 0]);
        let custom: Vec<_> =
            ids.iter().copied().filter(|id| self.protocol.is_none() || *id != PROTOCOL_CHANNEL).collect();
        let weights = |total: u64, fixed: &[(u64, u64)]| {
            let mut table: Vec<_> = custom.iter().copied().zip(distinct_weights(custom.len(), total)).collect();
            table.extend(fixed.iter().copied().filter(|(_, bps)| *bps > 0));
            table.sort();
            table.reverse();
            table
        };
        let meme = weights(10_000 - CURVE_BPS - protocol_meme, &[(0, CURVE_BPS), (PROTOCOL_CHANNEL, protocol_meme)]);
        let quote = weights(10_000 - protocol_quote, &[(PROTOCOL_CHANNEL, protocol_quote)]);

        let liquidity = call(builder, self.blast, "allocation", "liquidity_role", vec![], vec![]);
        let protocol = call(builder, self.blast, "allocation", "protocol_role", vec![], vec![]);
        let external = call(builder, self.blast, "allocation", "external_role", vec![], vec![]);
        let mut channels = Vec::new();
        for id in ids.iter().rev().copied() {
            let (role, destination) = match id {
                LIQUIDITY_CHANNEL => (liquidity, address(&[0xC1, id as u8])),
                PROTOCOL_CHANNEL if self.protocol.is_some() => (protocol, PROTOCOL),
                _ => (external, address(&[0xC1, id as u8])),
            };
            let id = builder.pure(id)?;
            let destination = builder.pure(SuiAddress::from(destination))?;
            channels.push(call(builder, self.blast, "allocation", "channel", vec![], vec![id, role, destination]));
        }
        let channels = builder.command(Command::MakeMoveVec(Some(self.allocation_type("Channel")?), channels));
        let mut tables = Vec::new();
        for table in [meme, quote] {
            let mut entries = Vec::new();
            for (id, bps) in table {
                let id = builder.pure(id)?;
                let bps = self.bps(builder, bps)?;
                entries.push(call(builder, self.blast, "allocation", "weight", vec![], vec![id, bps]));
            }
            tables.push(builder.command(Command::MakeMoveVec(Some(self.allocation_type("Weight")?), entries)));
        }

        Ok(call(builder, self.blast, "allocation", "new", vec![], vec![channels, tables[0], tables[1]]))
    }

    /// Builds `fee_split(recipients)` through the public constructors, recipients in descending
    /// address order, the canonical sort's worst case.
    fn fee_split(&self, builder: &mut ProgrammableTransactionBuilder, recipients: usize) -> Result<Argument> {
        let (creator_bps, auto_lp_bps, rewards_bps, recipients) = fee_split(recipients);
        let mut routes = Vec::new();
        for (destination, bps) in recipients.into_iter().rev() {
            let destination = builder.pure(SuiAddress::from(destination))?;
            let bps = self.bps(builder, bps)?;
            routes.push(call(builder, self.blast, "allocation", "route", vec![], vec![destination, bps]));
        }
        let routes = builder.command(Command::MakeMoveVec(Some(self.allocation_type("Route")?), routes));
        let creator_bps = self.bps(builder, creator_bps)?;
        let auto_lp_bps = self.bps(builder, auto_lp_bps)?;
        let rewards_bps = self.bps(builder, rewards_bps)?;

        Ok(call(
            builder,
            self.blast,
            "allocation",
            "fee_split",
            vec![],
            vec![creator_bps, auto_lp_bps, rewards_bps, routes],
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
        let clock = builder.obj(self.h.shared(SUI_CLOCK_OBJECT_ID, false))?;
        let Argument::Result(bought) = call(
            &mut builder,
            self.blast,
            "launch",
            "buy",
            vec![opened.meme.clone(), sui()],
            vec![launch, version, runtime, Argument::NestedResult(split, 0), min_meme_out, clock],
        ) else {
            unreachable!()
        };
        builder
            .transfer_args(self.h.sender, vec![Argument::NestedResult(bought, 0), Argument::NestedResult(bought, 1)]);

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
                "protocol_allocation_bps": self.protocol.map(|[meme, quote]| json!({ "meme": meme, "quote": quote })),
                "launch": shape.map(|shape| json!({
                    "identities": shape.identities,
                    "fee_split_recipients": shape.recipients,
                    "graduation_target": shape.target,
                    "protection_window_ms": shape.protection[0],
                    "cumulative_sender_bps": shape.protection[1],
                    "per_transaction_bps": shape.protection[2],
                    "pre_share_vesting": shape.vesting.map(|vesting| format!("{vesting:?}")),
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

/// The fixture fee split with `recipients` recipients, in canonical address order: without
/// recipients the creator takes everything; otherwise every part is set and the recipients share
/// the rest with distinct weights.
fn fee_split(recipients: usize) -> (u64, u64, u64, Vec<(ObjectID, u64)>) {
    if recipients == 0 {
        return (10_000, 0, 0, Vec::new());
    }
    let addresses = (1..=recipients).map(|j| address(&[0xE1, j as u8]));

    (1_000, 600, 400, addresses.zip(distinct_weights(recipients, 8_000)).collect())
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
