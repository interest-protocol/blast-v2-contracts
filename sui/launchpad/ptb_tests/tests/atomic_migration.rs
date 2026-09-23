//! Programmable-transaction integration tests for the atomic migration seam, fee routing, and
//! protected buys.
//!
//! Two independent one-time-witness launches reach MigrationReady through public PTBs. Every
//! failing migration PTB must commit nothing (see `Harness::assert_rolled_back`): no allocation
//! reaches its destination, and launch A stays migratable through the whole failure matrix before
//! completing in one successful PTB. After migration, collection and settled route-update PTBs
//! pay every destination before their events, in native order, and a failure after payment
//! commits no payment and no event. Every event travels in the launchpad envelope.
//!
//! A protected launch shows the launch-owned sender record the first protected buy creates, the
//! storage cost of that buy and of a later one, and that every failing protected buy commits
//! nothing.
//!
//! Route proposals with zero or seventeen destinations abort in the route constructor before any
//! router mutation at creation, pending configuration, and settlement, while one and sixteen
//! commit. Sixteen-destination tables with distinct Meme and Quote weights are measured at
//! creation, pending replacement, activation, the largest and a zero collection, and a settled
//! full replacement; each record prints as one `ROUTER_CAPACITY` JSON line with its margins to the
//! simulator's protocol limits.
//!
//! Run from `sui/launchpad/ptb_tests` with `cargo test` (needs the pinned `sui` on PATH).

use std::{collections::BTreeSet, path::Path, time::Duration};

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

/// `create_launch` protection arguments: window, cumulative BPS, per-transaction BPS.
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

/// Default LP-fee shares the measured router freezes at activation, different per asset.
const MEME_SHARE: u64 = 333;
const QUOTE_SHARE: u64 = 1_667;

const DESTINATION: ObjectID = address(&[0xD5]);
/// Where the settled route update sends both assets.
const NEXT_DESTINATION: ObjectID = address(&[0xD6]);
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
    router: ObjectID,
    currency: ObjectID,
}

struct World {
    h: Harness,
    admin: ObjectID,
    authority: ObjectID,
    blast: ObjectID,
    adapter: ObjectID,
    version: ObjectID,
    runtime: ObjectID,
    policy: ObjectID,
    config: ObjectID,
    project: CompiledPackage,
}

#[test]
fn failed_migration_ptbs_commit_nothing_and_one_ptb_completes_atomically() -> Result<()> {
    let (mut w, a, b) = setup()?;
    let b_ready = w.h.snapshot(&[b.launch, b.router, b.currency], &[]);
    let watched = [a.launch, a.router, a.currency];
    let owners = [w.h.sender, DESTINATION.into(), SINK.into()];

    for (failpoint, expected) in [
        (CUSTODY_FAILURE, Expected::Abort { package: w.adapter, module: "mock_adapter", code: 0 }),
        (ZERO_LIQUIDITY, Expected::Abort { package: w.blast, module: "launch", code: 59 }),
        (UNDERFUND_MEME, Expected::Abort { package: w.blast, module: "launch", code: 59 }),
        (POST_FINALIZER_FAILURE, Expected::Abort { package: w.adapter, module: "mock_adapter", code: 1 }),
    ] {
        let pt = w.migrate(&a, &a, failpoint)?;
        w.h.assert_rolled_back(pt, expected, &watched, &owners)?;
    }

    // VM type-rule evidence, not a launch check: launch B's router cannot stand in for launch A's
    // because distinct one-time-witness types fail PTB type checking before any Move code runs.
    // This is why core keeps no launch/router ID binding.
    let pt = w.migrate(&a, &b, 0)?;
    w.h.assert_rolled_back(
        pt,
        Expected::Error("TypeMismatch"),
        &[a.launch, a.router, a.currency, b.router],
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
    assert_eq!(outcome.wrapped_payloads(w.blast), ["RouterActivated", "MigrationAllocationPaid", "Migrated"]);
    assert_eq!(w.launch_lifecycle(&a)?, LaunchLifecycle::Migrated);
    let router: Router = bcs::from_bytes(&w.h.contents(a.router))?;
    assert_eq!(router.launch_id, a.launch);
    let RouterLifecycle::Active { binding, .. } = router.lifecycle else {
        panic!("migration did not activate the router");
    };
    assert_eq!(outcome.events_of("events", "RouterActivated").len(), 1);
    let migrated = outcome.events_of("events", "Migrated");
    assert_eq!(migrated.len(), 1);
    let migrated: Migrated = bcs::from_bytes(migrated[0])?;
    assert_eq!(migrated.launch_id, a.launch);
    assert!(migrated.supplied_meme > 0 && migrated.supplied_quote > 0);
    assert_eq!((migrated.residual_meme, migrated.residual_quote), (1, 1));
    assert!(migrated.liquidity > 0);
    let vaults = outcome.created(&w.h, "mock_adapter", "MockVault");
    let pools = outcome.created(&w.h, "mock_adapter", "MockPool");
    assert_eq!(vaults, vec![binding.vault_id]);
    assert_eq!(pools, vec![binding.pool_id]);
    assert!(w.h.object(binding.vault_id).is_shared() && w.h.object(binding.pool_id).is_shared());
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
    assert_eq!(w.h.snapshot(&[b.launch, b.router, b.currency], &[]), b_ready);

    Ok(())
}

#[test]
fn collection_and_route_update_ptbs_pay_before_their_events_and_failures_commit_nothing() -> Result<()> {
    let mut w = world("fee_routing")?;
    let a = w.open_launch(UNPROTECTED)?;
    w.buy_to_migration(&a)?;
    let outcome = w.h.execute(w.migrate(&a, &a, 0)?)?;
    outcome.assert_success();
    let vault = outcome.created(&w.h, "mock_adapter", "MockVault")[0];
    let config_cap = w.claim_router_config_cap(&a)?;
    let meme_coin = w.meme_coin(&a);
    let owners = [w.h.sender, DESTINATION.into(), NEXT_DESTINATION.into()];
    let post_payment = || Expected::Abort { package: w.adapter, module: "mock_adapter", code: 1 };

    // The router pays and emits before the adapter aborts; the failure keeps neither.
    let pt = w.collect(&a, vault, meme_coin, 1_000, 2_000, POST_FINALIZER_FAILURE)?;
    w.h.assert_rolled_back(pt, post_payment(), &[a.router, meme_coin], &owners)?;

    let outcome = w.h.execute(w.collect(&a, vault, meme_coin, 1_000, 2_000, 0)?)?;
    outcome.assert_success();
    assert_eq!(outcome.wrapped_payloads(w.blast), ["FeesCollected"]);
    let collected = w.fees_collected(&outcome, &a, 0)?;
    assert_eq!((collected.gross_meme, collected.gross_quote), (1_000, 2_000));
    assert_eq!((collected.meme_amounts, collected.quote_amounts), (vec![1_000], vec![2_000]));
    assert_eq!(outcome.coins_created_for(&w.h, DESTINATION.into()), w.coins(&a, 1_000, 2_000));

    // Proposing the live routes aborts in core before any payment.
    let pt = w.settle(&a, vault, config_cap, meme_coin, 300, 400, DESTINATION, 0)?;
    let unchanged = Expected::Abort { package: w.blast, module: "fee_router", code: 67 };
    w.h.assert_rolled_back(pt, unchanged, &[a.router, meme_coin, config_cap], &owners)?;
    // Payment, route commitment, and both events are all discarded with the adapter's abort.
    let pt = w.settle(&a, vault, config_cap, meme_coin, 300, 400, NEXT_DESTINATION, POST_FINALIZER_FAILURE)?;
    w.h.assert_rolled_back(pt, post_payment(), &[a.router, meme_coin, config_cap], &owners)?;

    // The update pays the outstanding fees under generation zero, then commits generation one.
    let outcome = w.h.execute(w.settle(&a, vault, config_cap, meme_coin, 300, 400, NEXT_DESTINATION, 0)?)?;
    outcome.assert_success();
    assert_eq!(outcome.wrapped_payloads(w.blast), ["FeesCollected", "RoutesChanged"]);
    let settled = w.fees_collected(&outcome, &a, 0)?;
    assert_eq!((settled.meme_amounts, settled.quote_amounts), (vec![300], vec![400]));
    assert_eq!(outcome.coins_created_for(&w.h, DESTINATION.into()), w.coins(&a, 300, 400));
    assert!(outcome.coins_created_for(&w.h, NEXT_DESTINATION.into()).is_empty());
    let changed = outcome.events_of("events", "RoutesChanged");
    let changed: RoutesChanged = bcs::from_bytes(changed[0])?;
    assert_eq!(changed.router_id, a.router);
    assert_eq!((changed.old_generation, changed.new_generation), (0, 1));
    assert_eq!(changed.old_routes, Routes::single(DESTINATION));
    assert_eq!(changed.new_routes, Routes::single(NEXT_DESTINATION));

    let outcome = w.h.execute(w.collect(&a, vault, meme_coin, 5, 6, 0)?)?;
    outcome.assert_success();
    assert_eq!(outcome.wrapped_payloads(w.blast), ["FeesCollected"]);
    let collected = w.fees_collected(&outcome, &a, 1)?;
    assert_eq!((collected.meme_amounts, collected.quote_amounts), (vec![5], vec![6]));
    assert_eq!(outcome.coins_created_for(&w.h, NEXT_DESTINATION.into()), w.coins(&a, 5, 6));
    assert!(outcome.coins_created_for(&w.h, DESTINATION.into()).is_empty());

    // The object read agrees with the replayed generation and routes.
    let router: Router = bcs::from_bytes(&w.h.contents(a.router))?;
    assert_eq!(router.generation, 1);
    assert_eq!(router.routes, Routes::single(NEXT_DESTINATION));

    Ok(())
}

#[test]
fn zero_and_seventeen_route_destinations_abort_before_any_router_mutation() -> Result<()> {
    let mut w = world("route_boundaries")?;
    let one = Routes::single(DESTINATION);
    let sixteen = Routes::sixteen(0xA0, 10);
    // Zero destinations fail both tables' 10,000 sum; a seventeenth distinct Quote destination
    // fails capacity before the sum.
    let rejected = [(Routes::default(), 64), (sixteen.clone().with_seventeenth(), 63)];
    let blast = w.blast;
    let abort = |code| Expected::Abort { package: blast, module: "allocation", code };
    let owners = [w.h.sender, DESTINATION.into()];

    // Creation: each rejected proposal aborts before the launch or router exists.
    let (ticket, currency, meme) = w.publish_ticket()?;
    for (routes, code) in &rejected {
        let pt = w.create_routed_launch(ticket, currency, &meme, routes)?;
        w.h.assert_rolled_back(pt, abort(*code), &[ticket, currency], &owners)?;
    }
    let (launch, _) = w.open_routed_launch(ticket, currency, meme, &sixteen)?;
    assert_eq!(w.router(&launch)?.routes, sixteen);

    // Pending configuration: rejected proposals leave the router untouched; one and sixteen commit.
    let config_cap = w.claim_router_config_cap(&launch)?;
    for (routes, code) in &rejected {
        let pt = w.configure(&launch, config_cap, routes)?;
        w.h.assert_rolled_back(pt, abort(*code), &[launch.router, config_cap], &owners)?;
    }
    for (generation, routes) in [(1, &one), (2, &sixteen)] {
        w.h.execute(w.configure(&launch, config_cap, routes)?)?.assert_success();
        let router = w.router(&launch)?;
        assert_eq!((router.generation, &router.routes), (generation, routes));
    }

    // Settlement: rejected proposals commit no payment and no route; one and sixteen commit.
    w.buy_to_migration(&launch)?;
    let migrated = w.h.execute(w.migrate(&launch, &launch, 0)?)?;
    migrated.assert_success();
    let vault = migrated.created(&w.h, "mock_adapter", "MockVault")[0];
    let meme_coin = w.meme_coin(&launch);
    for (routes, code) in &rejected {
        let pt = w.settle_routes(&launch, vault, config_cap, meme_coin, 7, 9, routes)?;
        w.h.assert_rolled_back(pt, abort(*code), &[launch.router, config_cap, meme_coin], &owners)?;
    }
    for (generation, routes) in [(3, &one), (4, &sixteen)] {
        let pt = w.settle_routes(&launch, vault, config_cap, meme_coin, 7, 9, routes)?;
        let settled = w.h.execute(pt)?;
        settled.assert_success();
        assert_eq!(settled.wrapped_payloads(w.blast), ["FeesCollected", "RoutesChanged"]);
        let router = w.router(&launch)?;
        assert_eq!((router.generation, &router.routes), (generation, routes));
    }

    Ok(())
}

#[test]
fn maximum_router_shapes_pay_exactly_within_protocol_limits() -> Result<()> {
    let mut w = world("router_capacity")?;
    w.set_lp_fee_policy(MEME_SHARE, QUOTE_SHARE)?;
    let created_routes = Routes::sixteen(0xA0, 10);
    let pending_routes = Routes::sixteen(0xB0, 20);
    let active_routes = Routes::sixteen(0xC0, 30);
    let one = Routes::single(DESTINATION);
    let (gross_meme, gross_quote) = worst_case_gross();
    let mut records = Vec::new();

    // Creation and a complete pending replacement, each with sixteen routes per table.
    let (ticket, currency, meme) = w.publish_ticket()?;
    let (a, created) = w.open_routed_launch(ticket, currency, meme, &created_routes)?;
    let router_created = created.events_of("events", "FeeRouterCreated");
    let router_created: FeeRouterCreated = bcs::from_bytes(router_created[0])?;
    assert_eq!((router_created.router_id, router_created.launch_id), (a.router, a.launch));
    assert_eq!(router_created.routes, created_routes);
    records.push(w.record(&a, "create_launch", "16+16 routes", &created));
    let config_cap = w.claim_router_config_cap(&a)?;
    let configured = w.h.execute(w.configure(&a, config_cap, &pending_routes)?)?;
    w.assert_routes_changed(&a, &configured, 0, &created_routes, &pending_routes)?;
    records.push(w.record(&a, "configure_pending", "16+16 -> disjoint 16+16 routes", &configured));

    // Activation freezes both shares and the sixteen-destination routes.
    w.buy_to_migration(&a)?;
    let migrated = w.h.execute(w.migrate(&a, &a, 0)?)?;
    migrated.assert_success();
    let activated = migrated.events_of("events", "RouterActivated");
    let activated: RouterActivated = bcs::from_bytes(activated[0])?;
    assert_eq!(activated.router_id, a.router);
    assert_eq!((activated.meme_bps, activated.quote_bps), (MEME_SHARE, QUOTE_SHARE));
    assert_eq!((activated.generation, &activated.routes), (1, &pending_routes));
    records.push(w.record(&a, "migrate_and_activate", "16+16 routes", &migrated));
    let vault = migrated.created(&w.h, "mock_adapter", "MockVault")[0];
    let meme_coin = w.meme_coin(&a);

    // The largest collection pays 2 protocol and 16 + 16 route coins; a zero one moves nothing.
    let collected = w.h.execute(w.collect(&a, vault, meme_coin, gross_meme, gross_quote, 0)?)?;
    w.assert_paid(&a, &collected, 1, &pending_routes, gross_meme, gross_quote)?;
    assert_eq!(collected.effects.created().len(), 34);
    records.push(w.record(&a, "collect", "16+16 routes, nonzero", &collected));
    let empty = w.h.execute(w.collect(&a, vault, meme_coin, 0, 0, 0)?)?;
    empty.assert_success();
    assert!(empty.events.is_empty() && empty.effects.created().is_empty());
    records.push(w.record(&a, "collect", "16+16 routes, zero", &empty));

    // A settled full replacement pays the outstanding fees under the old sixteen routes, then
    // commits sixteen disjoint ones that alone receive later fees.
    let pt = w.settle_routes(&a, vault, config_cap, meme_coin, gross_meme, gross_quote, &active_routes)?;
    let settled = w.h.execute(pt)?;
    w.assert_paid(&a, &settled, 1, &pending_routes, gross_meme, gross_quote)?;
    w.assert_routes_changed(&a, &settled, 1, &pending_routes, &active_routes)?;
    assert_eq!(settled.effects.created().len(), 34);
    let fixture = "16+16 -> disjoint 16+16 routes, nonzero";
    records.push(w.record(&a, "settle_and_update_routes", fixture, &settled));
    let later = w.h.execute(w.collect(&a, vault, meme_coin, gross_meme, gross_quote, 0)?)?;
    w.assert_paid(&a, &later, 2, &active_routes, gross_meme, gross_quote)?;

    // One-destination baselines for the same operations.
    let pt = w.settle_routes(&a, vault, config_cap, meme_coin, gross_meme, gross_quote, &one)?;
    let settled = w.h.execute(pt)?;
    w.assert_paid(&a, &settled, 2, &active_routes, gross_meme, gross_quote)?;
    w.assert_routes_changed(&a, &settled, 2, &active_routes, &one)?;
    records.push(w.record(&a, "settle_and_update_routes", "16+16 -> 1+1 routes, nonzero", &settled));
    let collected = w.h.execute(w.collect(&a, vault, meme_coin, gross_meme, gross_quote, 0)?)?;
    w.assert_paid(&a, &collected, 3, &one, gross_meme, gross_quote)?;
    records.push(w.record(&a, "collect", "1+1 routes, nonzero", &collected));

    let fixture = json!({
        "shares_bps": { "meme": MEME_SHARE, "quote": QUOTE_SHARE },
        "gross": { "meme": gross_meme, "quote": gross_quote },
        "routes": { "created": created_routes, "pending": pending_routes, "active": active_routes },
    });
    println!(
        "ROUTER_CAPACITY {}",
        json!({ "limits": w.h.protocol_limits(), "fixture": fixture, "records": records })
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
        (OVERSIZED_BUY, 1, 54),
        (SMALL_BUY, 1, 55),
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

/// Mirrors `blast_fun::fee_router::FeeRouter` and the types it stores.
#[derive(Deserialize)]
struct Router {
    _id: ObjectID,
    launch_id: ObjectID,
    lifecycle: RouterLifecycle,
    generation: u64,
    routes: Routes,
}

#[derive(Deserialize)]
enum RouterLifecycle {
    Pending,
    Active { _policy: PolicySnapshot, binding: SettlementBinding },
}

#[derive(Deserialize)]
struct PolicySnapshot {
    _partner: bool,
    _meme_bps: u64,
    _quote_bps: u64,
}

#[derive(Deserialize)]
struct SettlementBinding {
    _settlement_witness: String,
    vault_id: ObjectID,
    pool_id: ObjectID,
    _position_id: ObjectID,
}

#[derive(Clone, Debug, Default, Deserialize, PartialEq, Serialize)]
struct Routes {
    meme: Vec<Route>,
    quote: Vec<Route>,
}

impl Routes {
    /// The mock adapter's routes: both assets wholly to one destination.
    fn single(destination: ObjectID) -> Self {
        let route = || vec![Route { destination: destination.into(), bps: 10_000 }];
        Self { meme: route(), quote: route() }
    }

    /// The same sixteen destinations in both canonical tables. Weights fall along canonical order,
    /// by `step` for Meme and twice as steeply for Quote, so they are distinct within each table,
    /// differ between the assets for every destination, and each table sums to 10,000.
    fn sixteen(tag: u8, step: u64) -> Self {
        let table = |step: u64| {
            assert_eq!((10_000 - 120 * step) % 16, 0);
            let lowest = (10_000 - 120 * step) / 16;
            (0..16u8)
                .map(|i| Route {
                    destination: address(&[tag, i]).into(),
                    bps: lowest + step * u64::from(15 - i),
                })
                .collect()
        };

        let routes = Self { meme: table(step), quote: table(2 * step) };
        assert!(routes.meme.iter().zip(&routes.quote).all(|(meme, quote)| meme.bps != quote.bps));

        routes
    }

    /// Replaces the last Quote destination with a seventeenth distinct one; both sums stay whole.
    fn with_seventeenth(mut self) -> Self {
        self.quote[15].destination = address(&[0x17, 0x17]).into();
        self
    }
}

#[derive(Clone, Debug, Deserialize, PartialEq, Serialize)]
struct Route {
    destination: SuiAddress,
    bps: u64,
}

/// Mirrors `blast_fun::events::FeeRouterCreated`.
#[derive(Deserialize)]
struct FeeRouterCreated {
    router_id: ObjectID,
    launch_id: ObjectID,
    _config_cap_id: ObjectID,
    routes: Routes,
}

/// Mirrors `blast_fun::events::RouterActivated`.
#[derive(Deserialize)]
struct RouterActivated {
    router_id: ObjectID,
    _launch_id: ObjectID,
    _partner: bool,
    meme_bps: u64,
    quote_bps: u64,
    _settlement_witness: String,
    _vault_id: ObjectID,
    _pool_id: ObjectID,
    _position_id: ObjectID,
    generation: u64,
    routes: Routes,
}

/// Mirrors `blast_fun::events::FeesCollected`.
#[derive(Deserialize)]
struct FeesCollected {
    router_id: ObjectID,
    launch_id: ObjectID,
    generation: u64,
    gross_meme: u64,
    gross_quote: u64,
    protocol_destination: SuiAddress,
    protocol_meme: u64,
    protocol_quote: u64,
    meme_amounts: Vec<u64>,
    quote_amounts: Vec<u64>,
}

/// Mirrors `blast_fun::events::RoutesChanged`.
#[derive(Deserialize)]
struct RoutesChanged {
    router_id: ObjectID,
    old_generation: u64,
    new_generation: u64,
    old_routes: Routes,
    new_routes: Routes,
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
    let policy = one("lp_fee_policy", "LpFeePolicy");
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
    let mut w = World { h, admin, authority, blast, adapter, version, runtime, policy, config, project };
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
    /// Publishes one generated project and opens its SUI-quoted launch under `protection`.
    fn open_launch(&mut self, protection: [u64; 3]) -> Result<Launch> {
        let (ticket, currency, meme) = self.publish_ticket()?;
        let mut builder = ProgrammableTransactionBuilder::new();
        let ticket = builder.obj(self.h.owned(ticket))?;
        let currency_arg = builder.obj(self.h.shared(currency, true))?;
        let version = builder.obj(self.h.shared(self.version, false))?;
        let config = builder.obj(self.h.shared(self.config, false))?;
        let clock = builder.obj(self.h.shared(SUI_CLOCK_OBJECT_ID, false))?;
        let target = builder.pure(TARGET)?;
        let destination = builder.pure(SuiAddress::from(DESTINATION))?;
        let [window_ms, cumulative_bps, per_transaction_bps] = protection;
        let window_ms = builder.pure(window_ms)?;
        let cumulative_bps = builder.pure(cumulative_bps)?;
        let per_transaction_bps = builder.pure(per_transaction_bps)?;
        call(&mut builder, self.adapter, "mock_adapter", "create_launch", vec![meme.clone()], vec![
            ticket,
            currency_arg,
            version,
            config,
            clock,
            target,
            destination,
            window_ms,
            cumulative_bps,
            per_transaction_bps,
        ]);
        let created = self.h.execute(builder.finish())?;

        Ok(self.created_launch(&created, meme, currency))
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

    /// The launch and router a successful creation shared.
    fn created_launch(&self, created: &Outcome, meme: TypeTag, currency: ObjectID) -> Launch {
        created.assert_success();
        assert_eq!(
            created.wrapped_payloads(self.blast),
            ["LaunchCreated", "ProtectionConfigured", "FeeRouterCreated", "LaunchShared"],
        );
        let only = |module: &str, name: &str| {
            let ids = created.created(&self.h, module, name);
            assert_eq!(ids.len(), 1, "{module}::{name}");
            ids[0]
        };

        Launch {
            meme,
            launch: only("launch", "Launch"),
            router: only("fee_router", "FeeRouter"),
            currency,
        }
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
        let Argument::Result(split) = builder.command(sui_types::transaction::Command::SplitCoins(
            Argument::GasCoin,
            vec![amount],
        )) else {
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

    /// The Meme coin the sender bought on `launch`, which funds the mock venue fees.
    fn meme_coin(&self, launch: &Launch) -> ObjectID {
        let coins: Vec<_> = self
            .h
            .owned_by(self.h.sender)
            .into_iter()
            .filter(|object| object.coin_type_maybe().as_ref() == Some(&launch.meme))
            .map(|object| object.id())
            .collect();
        assert_eq!(coins.len(), 1, "one Meme coin per launch");
        coins[0]
    }

    /// The creator recipient, which is the sender, claims its setup capabilities and keeps them.
    fn claim_router_config_cap(&mut self, launch: &Launch) -> Result<ObjectID> {
        let mut builder = ProgrammableTransactionBuilder::new();
        let launch_arg = builder.obj(self.h.shared(launch.launch, true))?;
        let version = builder.obj(self.h.shared(self.version, false))?;
        let runtime = builder.obj(self.h.shared(self.runtime, false))?;
        let attestation = builder.pure(Option::<Vec<u8>>::None)?;
        let clock = builder.obj(self.h.shared(SUI_CLOCK_OBJECT_ID, false))?;
        let Argument::Result(caps) = call(
            &mut builder,
            self.blast,
            "launch",
            "claim_setup_caps",
            vec![launch.meme.clone(), sui()],
            vec![launch_arg, version, runtime, attestation, clock],
        ) else {
            unreachable!()
        };
        builder.transfer_args(self.h.sender, (0..3).map(|i| Argument::NestedResult(caps, i)).collect());
        let outcome = self.h.execute(builder.finish())?;
        outcome.assert_success();
        assert_eq!(outcome.wrapped_payloads(self.blast), ["CreatorCapsClaimed", "RouterConfigCapReleased"]);
        let caps = self.h.owned_of_type(self.h.sender, "fee_router", "RouterConfigCap");
        assert_eq!(caps.len(), 1);

        Ok(caps[0])
    }

    /// Venue fees split from the sender's Meme coin and the gas coin for one adapter call.
    fn fees(
        &self,
        builder: &mut ProgrammableTransactionBuilder,
        meme_coin: ObjectID,
        meme: u64,
        quote: u64,
    ) -> Result<(Argument, Argument)> {
        let meme_coin = builder.obj(self.h.owned(meme_coin))?;
        let meme = builder.pure(meme)?;
        let Argument::Result(meme) = builder.command(Command::SplitCoins(meme_coin, vec![meme])) else {
            unreachable!()
        };
        let quote = builder.pure(quote)?;
        let Argument::Result(quote) = builder.command(Command::SplitCoins(Argument::GasCoin, vec![quote]))
        else {
            unreachable!()
        };

        Ok((Argument::NestedResult(meme, 0), Argument::NestedResult(quote, 0)))
    }

    fn collect(
        &self,
        launch: &Launch,
        vault: ObjectID,
        meme_coin: ObjectID,
        meme: u64,
        quote: u64,
        failpoint: u8,
    ) -> Result<ProgrammableTransaction> {
        let mut builder = ProgrammableTransactionBuilder::new();
        let (meme, quote) = self.fees(&mut builder, meme_coin, meme, quote)?;
        let vault = builder.obj(self.h.shared(vault, false))?;
        let router = builder.obj(self.h.shared(launch.router, true))?;
        let version = builder.obj(self.h.shared(self.version, false))?;
        let policy = builder.obj(self.h.shared(self.policy, false))?;
        let failpoint = builder.pure(failpoint)?;
        call(&mut builder, self.adapter, "mock_adapter", "collect", vec![launch.meme.clone()], vec![
            vault, router, version, policy, meme, quote, failpoint,
        ]);

        Ok(builder.finish())
    }

    fn settle(
        &self,
        launch: &Launch,
        vault: ObjectID,
        config_cap: ObjectID,
        meme_coin: ObjectID,
        meme: u64,
        quote: u64,
        destination: ObjectID,
        failpoint: u8,
    ) -> Result<ProgrammableTransaction> {
        let mut builder = ProgrammableTransactionBuilder::new();
        let (meme, quote) = self.fees(&mut builder, meme_coin, meme, quote)?;
        let vault = builder.obj(self.h.shared(vault, false))?;
        let router = builder.obj(self.h.shared(launch.router, true))?;
        let version = builder.obj(self.h.shared(self.version, false))?;
        let policy = builder.obj(self.h.shared(self.policy, false))?;
        let config_cap = builder.obj(self.h.owned(config_cap))?;
        let destination = builder.pure(SuiAddress::from(destination))?;
        let failpoint = builder.pure(failpoint)?;
        call(&mut builder, self.adapter, "mock_adapter", "settle", vec![launch.meme.clone()], vec![
            vault, router, version, policy, config_cap, meme, quote, destination, failpoint,
        ]);

        Ok(builder.finish())
    }

    /// Decodes the one `FeesCollected`; the zero default policy pays the publisher nothing.
    fn fees_collected(&self, outcome: &Outcome, launch: &Launch, generation: u64) -> Result<FeesCollected> {
        let collected = outcome.events_of("events", "FeesCollected");
        assert_eq!(collected.len(), 1);
        let collected: FeesCollected = bcs::from_bytes(collected[0])?;
        assert_eq!((collected.router_id, collected.launch_id), (launch.router, launch.launch));
        assert_eq!(collected.generation, generation);
        assert_eq!(collected.protocol_destination, self.h.sender);
        assert_eq!((collected.protocol_meme, collected.protocol_quote), (0, 0));

        Ok(collected)
    }

    fn launch_lifecycle(&self, launch: &Launch) -> Result<LaunchLifecycle> {
        let contents = self.h.contents(launch.launch);
        let (_, lifecycle): (ObjectID, LaunchLifecycle) = bcs::from_bytes(&contents[..33])?;

        Ok(lifecycle)
    }

    /// The adapter entry point with `launch`'s launch and currency and `router_owner`'s router.
    fn migrate(&self, launch: &Launch, router_owner: &Launch, failpoint: u8) -> Result<ProgrammableTransaction> {
        let mut builder = ProgrammableTransactionBuilder::new();
        let launch_arg = builder.obj(self.h.shared(launch.launch, true))?;
        let router = builder.obj(self.h.shared(router_owner.router, true))?;
        let version = builder.obj(self.h.shared(self.version, false))?;
        let policy = builder.obj(self.h.shared(self.policy, false))?;
        let currency = builder.obj(self.h.shared(launch.currency, true))?;
        let failpoint = builder.pure(failpoint)?;
        call(&mut builder, self.adapter, "mock_adapter", "migrate", vec![launch.meme.clone()], vec![
            launch_arg,
            router,
            version,
            policy,
            currency,
            failpoint,
        ]);

        Ok(builder.finish())
    }
}

/// Route fixtures and measurements.
impl World {
    /// Sets the default LP-fee shares later activations freeze and pays the protocol share to
    /// `PROTOCOL`.
    fn set_lp_fee_policy(&mut self, meme_bps: u64, quote_bps: u64) -> Result<()> {
        let admin_cap = self.h.owned_of_type(self.h.sender, "acl", "AdminCap")[0];
        let domain = parse_sui_type_tag(&format!("{}::blast_fun_domain::BLAST_FUN_DOMAIN", self.blast))?;
        let mut builder = ProgrammableTransactionBuilder::new();
        let authority = builder.obj(self.h.shared(self.authority, false))?;
        let admin_cap = builder.obj(self.h.owned(admin_cap))?;
        let signed_in =
            call(&mut builder, self.admin, "acl", "sign_in", vec![domain], vec![authority, admin_cap]);
        let policy = builder.obj(self.h.shared(self.policy, true))?;
        let version = builder.obj(self.h.shared(self.version, false))?;
        let meme_bps = builder.pure(meme_bps)?;
        let meme_bps = call(&mut builder, self.blast, "bps", "new", vec![], vec![meme_bps]);
        let quote_bps = builder.pure(quote_bps)?;
        let quote_bps = call(&mut builder, self.blast, "bps", "new", vec![], vec![quote_bps]);
        call(&mut builder, self.blast, "lp_fee_policy", "set_default_shares", vec![], vec![
            policy, version, signed_in, meme_bps, quote_bps,
        ]);
        let destination = builder.pure(SuiAddress::from(PROTOCOL))?;
        call(&mut builder, self.blast, "lp_fee_policy", "set_protocol_destination", vec![], vec![
            policy,
            version,
            signed_in,
            destination,
        ]);
        self.h.execute(builder.finish())?.assert_success();

        Ok(())
    }

    /// Builds `routes` through the public constructors, as a client would.
    fn routes_arg(&self, builder: &mut ProgrammableTransactionBuilder, routes: &Routes) -> Result<Argument> {
        let meme = self.route_table(builder, &routes.meme)?;
        let quote = self.route_table(builder, &routes.quote)?;

        Ok(call(builder, self.blast, "allocation", "routes", vec![], vec![meme, quote]))
    }

    /// One table in descending destination order, the canonical sort's worst case, with every
    /// value its own pure input.
    fn route_table(&self, builder: &mut ProgrammableTransactionBuilder, table: &[Route]) -> Result<Argument> {
        let mut routes = Vec::new();
        for route in table.iter().rev() {
            let bps = builder.pure_bytes(bcs::to_bytes(&route.bps)?, true);
            let bps = call(builder, self.blast, "bps", "new", vec![], vec![bps]);
            let destination = builder.pure_bytes(bcs::to_bytes(&route.destination)?, true);
            routes.push(call(builder, self.blast, "allocation", "route", vec![], vec![destination, bps]));
        }
        let route = parse_sui_type_tag(&format!("{}::allocation::Route", self.blast))?;

        Ok(builder.command(Command::make_move_vec(Some(route), routes)))
    }

    /// The adapter's creation of `ticket`'s unprotected launch with `routes`.
    fn create_routed_launch(
        &self,
        ticket: ObjectID,
        currency: ObjectID,
        meme: &TypeTag,
        routes: &Routes,
    ) -> Result<ProgrammableTransaction> {
        let mut builder = ProgrammableTransactionBuilder::new();
        let routes = self.routes_arg(&mut builder, routes)?;
        let mut arguments = vec![
            builder.obj(self.h.owned(ticket))?,
            builder.obj(self.h.shared(currency, true))?,
            builder.obj(self.h.shared(self.version, false))?,
            builder.obj(self.h.shared(self.config, false))?,
            builder.obj(self.h.shared(SUI_CLOCK_OBJECT_ID, false))?,
            builder.pure(TARGET)?,
            builder.pure(SuiAddress::from(DESTINATION))?,
        ];
        for protection in UNPROTECTED {
            arguments.push(builder.pure(protection)?);
        }
        arguments.push(routes);
        let meme = vec![meme.clone()];
        call(&mut builder, self.adapter, "mock_adapter", "create_routed_launch", meme, arguments);

        Ok(builder.finish())
    }

    /// Opens `ticket`'s launch with `routes` and returns it with the creation outcome.
    fn open_routed_launch(
        &mut self,
        ticket: ObjectID,
        currency: ObjectID,
        meme: TypeTag,
        routes: &Routes,
    ) -> Result<(Launch, Outcome)> {
        let created = self.h.execute(self.create_routed_launch(ticket, currency, &meme, routes)?)?;

        Ok((self.created_launch(&created, meme, currency), created))
    }

    /// Replaces the pending router's routes directly through the core.
    fn configure(
        &self,
        launch: &Launch,
        config_cap: ObjectID,
        routes: &Routes,
    ) -> Result<ProgrammableTransaction> {
        let mut builder = ProgrammableTransactionBuilder::new();
        let routes = self.routes_arg(&mut builder, routes)?;
        let router = builder.obj(self.h.shared(launch.router, true))?;
        let version = builder.obj(self.h.shared(self.version, false))?;
        let config_cap = builder.obj(self.h.owned(config_cap))?;
        call(&mut builder, self.blast, "fee_router", "configure", vec![launch.meme.clone(), sui()], vec![
            router, version, config_cap, routes,
        ]);

        Ok(builder.finish())
    }

    /// Settles `meme` and `quote` under the current routes, then commits `routes`.
    fn settle_routes(
        &self,
        launch: &Launch,
        vault: ObjectID,
        config_cap: ObjectID,
        meme_coin: ObjectID,
        meme: u64,
        quote: u64,
        routes: &Routes,
    ) -> Result<ProgrammableTransaction> {
        let mut builder = ProgrammableTransactionBuilder::new();
        let (meme, quote) = self.fees(&mut builder, meme_coin, meme, quote)?;
        let routes = self.routes_arg(&mut builder, routes)?;
        let vault = builder.obj(self.h.shared(vault, false))?;
        let router = builder.obj(self.h.shared(launch.router, true))?;
        let version = builder.obj(self.h.shared(self.version, false))?;
        let policy = builder.obj(self.h.shared(self.policy, false))?;
        let config_cap = builder.obj(self.h.owned(config_cap))?;
        let failpoint = builder.pure(0u8)?;
        call(&mut builder, self.adapter, "mock_adapter", "settle_routes", vec![launch.meme.clone()], vec![
            vault, router, version, policy, config_cap, meme, quote, routes, failpoint,
        ]);

        Ok(builder.finish())
    }

    fn router(&self, launch: &Launch) -> Result<Router> {
        Ok(bcs::from_bytes(&self.h.contents(launch.router))?)
    }

    /// Asserts the one `FeesCollected` under `generation` paid exactly the oracle's protected-first
    /// amounts of `routes`, and that those coins alone reached the protocol and each destination.
    fn assert_paid(
        &self,
        launch: &Launch,
        outcome: &Outcome,
        generation: u64,
        routes: &Routes,
        gross_meme: u64,
        gross_quote: u64,
    ) -> Result<()> {
        outcome.assert_success();
        let collected = outcome.events_of("events", "FeesCollected");
        assert_eq!(collected.len(), 1);
        let collected: FeesCollected = bcs::from_bytes(collected[0])?;
        let (protocol_meme, meme_amounts) = payouts(gross_meme, MEME_SHARE, &routes.meme);
        let (protocol_quote, quote_amounts) = payouts(gross_quote, QUOTE_SHARE, &routes.quote);
        assert_eq!(protocol_meme + meme_amounts.iter().sum::<u64>(), gross_meme);
        assert_eq!(protocol_quote + quote_amounts.iter().sum::<u64>(), gross_quote);
        assert_eq!((collected.router_id, collected.launch_id), (launch.router, launch.launch));
        assert_eq!(collected.generation, generation);
        assert_eq!((collected.gross_meme, collected.gross_quote), (gross_meme, gross_quote));
        assert_eq!(collected.protocol_destination, SuiAddress::from(PROTOCOL));
        assert_eq!((collected.protocol_meme, collected.protocol_quote), (protocol_meme, protocol_quote));
        assert_eq!((&collected.meme_amounts, &collected.quote_amounts), (&meme_amounts, &quote_amounts));

        let protocol = self.coins(launch, protocol_meme, protocol_quote);
        let mut payments = protocol.len();
        assert_eq!(outcome.coins_created_for(&self.h, PROTOCOL.into()), protocol);
        let destinations: BTreeSet<_> =
            routes.meme.iter().chain(&routes.quote).map(|route| route.destination).collect();
        for destination in destinations {
            let amount = |table: &[Route], amounts: &[u64]| {
                table.iter().position(|route| route.destination == destination).map_or(0, |i| amounts[i])
            };
            let coins = self.coins(
                launch,
                amount(&routes.meme, &meme_amounts),
                amount(&routes.quote, &quote_amounts),
            );
            payments += coins.len();
            assert_eq!(outcome.coins_created_for(&self.h, destination), coins);
        }
        assert_eq!(outcome.effects.created().len(), payments, "an object other than a payment was created");

        Ok(())
    }

    /// Asserts `outcome` replaced `old` with `new` as generation `old_generation + 1`.
    fn assert_routes_changed(
        &self,
        launch: &Launch,
        outcome: &Outcome,
        old_generation: u64,
        old: &Routes,
        new: &Routes,
    ) -> Result<()> {
        outcome.assert_success();
        let changed = outcome.events_of("events", "RoutesChanged");
        assert_eq!(changed.len(), 1);
        let changed: RoutesChanged = bcs::from_bytes(changed[0])?;
        assert_eq!(changed.router_id, launch.router);
        assert_eq!((changed.old_generation, changed.new_generation), (old_generation, old_generation + 1));
        assert_eq!((&changed.old_routes, &changed.new_routes), (old, new));
        let router = self.router(launch)?;
        assert_eq!((router.generation, &router.routes), (old_generation + 1, new));

        Ok(())
    }

    /// One measurement: the operation and fixture, the router object's size afterwards, and the
    /// transaction's resources against the protocol limits.
    fn record(&self, launch: &Launch, operation: &str, fixture: &str, outcome: &Outcome) -> Value {
        json!({
            "operation": operation,
            "fixture": fixture,
            "router_object": {
                "contents_bytes": self.h.contents(launch.router).len(),
                "metered_bytes": self.h.object(launch.router).object_size_for_gas_metering(),
            },
            "resources": self.h.resources(outcome),
        })
    }
}

/// Independent protected-first oracle: the protocol takes the ceiling of its share; each route the
/// floor of its weight of the rest; the leftover units go one each by descending remainder, ties
/// to the earlier canonical route.
fn payouts(gross: u64, share_bps: u64, table: &[Route]) -> (u64, Vec<u64>) {
    let protocol = protocol_share(gross, share_bps);
    let project = u128::from(gross - protocol);
    let mut amounts: Vec<_> =
        table.iter().map(|route| (project * u128::from(route.bps) / 10_000) as u64).collect();
    let mut ranked: Vec<_> = (0..table.len()).collect();
    ranked.sort_by_key(|&i| std::cmp::Reverse(project * u128::from(table[i].bps) % 10_000));
    let leftover = gross - protocol - amounts.iter().sum::<u64>();
    ranked[..leftover as usize].iter().for_each(|&i| amounts[i] += 1);

    (protocol, amounts)
}

fn protocol_share(gross: u64, share_bps: u64) -> u64 {
    (u128::from(gross) * u128::from(share_bps)).div_ceil(10_000) as u64
}

/// Gross amounts from 10^15 Meme atoms and 10^9 MIST that leave 9,999 modulo 10,000 after the
/// protocol share. Each route's remainder is then 10,000 minus its weight: falling weights give
/// rising remainders, the worst case for the router's descending-remainder insertion sort, and
/// the remainders leave 15 units of dust, the most sixteen routes can receive.
fn worst_case_gross() -> (u64, u64) {
    let first_from = |start: u64, share_bps| {
        (start..)
            .find(|gross| (gross - protocol_share(*gross, share_bps)) % 10_000 == 9_999)
            .expect("gross")
    };

    (first_from(1_000_000_000_000_000, MEME_SHARE), first_from(1_000_000_000, QUOTE_SHARE))
}

fn sui() -> TypeTag {
    parse_sui_type_tag("0x2::sui::SUI").expect("SUI type")
}
