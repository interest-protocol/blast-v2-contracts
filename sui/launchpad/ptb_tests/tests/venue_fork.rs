//! Venue-fork gate: the migrators and `blast_vault` against real Cetus CLMM, Cetus LP Burn, and
//! Bluefin Spot mainnet bytecode, offline.
//!
//! `fork/snapshot/` holds, at one pinned mainnet checkpoint, every package those venues load and
//! every live object and dynamic field their code reads (`fork/fetch.py` writes it and records
//! why each entry is there). Each world inserts that snapshot into the in-memory simulator at the
//! real IDs, after checking every object against its recorded digest, then publishes the
//! ACL, partners, vesting, `blast_core`, the launchpad, `blast_vault`, and the migrators linked to
//! the real venue packages exactly as their manifests pin them. The vault package is released with
//! the case's venue listed, and the launchpad admits the same venue. No transaction reaches a
//! network.
//!
//! One test per venue and coin order runs the whole lifecycle through public PTBs: Cetus with Meme
//! as coin A (SUI Quote) and with Meme as coin B (USDC Quote; both Quotes admitted at tick spacing
//! 200 by Cetus's live allowlist), each through Cetus's single routes that take the pool's coin
//! types after the Meme and Quote (ADR 0100), and Bluefin. Each creation PTB runs the venue's
//! `prepare` on the coin's `TreasuryCap` before `launch::new` takes the cap and `finalize` fixes the
//! supply (ADR 0137): `prepare` rejects a tier the venue would refuse, and supply minted between
//! `prepare` and `finalize` is refused. A migration that aborts after pool creation commits
//! nothing, and on Cetus reversed or foreign coin types are refused; one PTB migrates into a new
//! pool at the launch's tier, burns the Cetus position through LP Burn, builds and shares the
//! `blast_vault` vault, pays the allocations, and pays the migration residuals to the treasury;
//! permissionless collections split real swap fees exactly by Blast's vault share (the launch
//! config's, then a per-vault override) and the fee split, and the compounding appended to each
//! collection skips auto-LP while its balances are one-sided or tiny and otherwise adds auto-LP
//! back at the pool price; collections burn the burn route's
//! Meme at `@0x0` (the fixture's supply is fixed); the buyback administrator swaps the waiting burn
//! Quote for Meme and burns it, and a minimum above the pool's output rolls back; collection against
//! another pool of the same type is refused; the settled split is scheduled with an owner proof
//! from the live curve-fee cap and applied permissionlessly after the vault's delay; a retired cap
//! cannot prove ownership to schedule, cancel or claim, and an accepted proposal survives
//! reassignment; the owner claims its balances; and a holder-reward round is published from the
//! rewards balance and paid by Merkle proof. Every venue observation prints as a `VENUE_FORK` line.
//!
//! Run from `sui/launchpad/ptb_tests` with `cargo test --offline --test venue_fork`.

use std::{collections::BTreeMap, sync::OnceLock};

use anyhow::{Context, Result, bail, ensure};
use blake2::{Blake2b, Digest, digest::consts::U32};
use blast_launchpad_ptb_tests::{
    ActionScheduled, Change, CompiledPackage, Delayed, DelayedAction, DelayedApplied, Destination, Expected, FeeSplit,
    GenericPackageVersionContents, Harness, Outcome, RoundTerms, UnlinkedPackage, VaultStack, build, build_unlinked, call,
    fork::{
        BLUEFIN, BLUEFIN_MAX_SQRT_PRICE, BLUEFIN_MIN_SQRT_PRICE, BluefinPoolCreated, BurnPosition, BurnProof,
        BurnRecord, CETUS, CETUS_MAX_SQRT_PRICE, CETUS_MIN_SQRT_PRICE, CetusAddLiquidity, CetusCollectFee,
        CetusOpenPosition, CetusPoolState, CetusPosition, CreatePool, LiquidityProvided, MintPoolCreationCap,
        RegisterPermissionPair, USDC, UserFeeCollected, apportion, cetus_name, expected_sqrt_price, id,
        insert_snapshot, meme_is_cetus_a, sui, tag, venue_dependencies, venue_events,
    },
    publish_stack, sui_dir, unique_bps,
};
use serde::{Deserialize, Serialize, de::DeserializeOwned};
use sui_types::{
    SUI_CLOCK_OBJECT_ID, SUI_COIN_REGISTRY_OBJECT_ID, SUI_FRAMEWORK_PACKAGE_ID, TypeTag,
    base_types::{ObjectID, SuiAddress},
    coin_registry::{Currency, SupplyState},
    digests::TransactionDigest,
    effects::TransactionEffectsAPI,
    object::{MoveObject, OBJECT_START_VERSION, Object, Owner},
    programmable_transaction_builder::ProgrammableTransactionBuilder,
    transaction::{Argument, Command, ObjectArg, ProgrammableTransaction},
};

/// The one spacing Cetus's live allowlist admits for both SUI and USDC, at its registered 1%.
const CETUS_TICK_SPACING: u32 = 200;
const CETUS_FEE_RATE: u64 = 10_000;
/// A Cetus fee tier that does not exist, and one that exists but is not admitted for the Quote.
const CETUS_UNREGISTERED_SPACING: u32 = 7;
const CETUS_UNADMITTED_SPACING: u32 = 60;
const BLUEFIN_TICK_SPACING: u32 = 60;
const BLUEFIN_FEE_RATE: u64 = 3_000;

/// Supply is 10^18 atoms (9 decimals); 20% of the Meme and 90% of the Quote at the target seed
/// the pool, and Blast and the creator's recipient each take 5% of both.
const ATOMIC_SUPPLY: u64 = 1_000_000_000_000_000_000;
const LP_MEME: u64 = ATOMIC_SUPPLY / 5;
const ALLOCATION_BPS: u64 = 500;

/// `launch::Lifecycle` tags in declaration order: `OpeningRound`, `Live`, `MigrationReady`,
/// `Migrated`.
const MIGRATION_READY: u8 = 2;
const MIGRATED: u8 = 3;
/// `blast_fun::errors` codes.
const INVALID_INITIAL_MEME_SUPPLY: u64 = 8;
const INVALID_LAUNCH_LIFECYCLE: u64 = 12;
const CREATOR_CAP_NOT_LIVE: u64 = 18;
/// `blast_core::errors` code for a hand-off redeemed by another venue.
const WRONG_VENUE: u64 = 8;
/// `blast_vault::errors` codes.
const BUYBACK_BELOW_MINIMUM: u64 = 8;
const CLAIMS_CLOSED: u64 = 23;
const ALREADY_CLAIMED: u64 = 25;
const RESERVE_SETTLED: u64 = 30;
const OVER_RESERVE: u64 = 31;
const CLAIMS_STILL_OPEN: u64 = 32;
/// `blast_migrators::errors` codes.
const INVALID_COIN_ORDER: u64 = 0;
const POSITION_POOL_MISMATCH: u64 = 1;
const WRONG_COIN_PAIR: u64 = 2;
const INVALID_TIER: u64 = 3;

/// The `blast_core::blast_domain` roles this world's one `AdminCap` holds, for the launchpad and
/// the vault alike.
const CORE_ROLES: [&str; 7] =
    ["ListingAdmin", "VenueAdmin", "FeeAdmin", "TreasuryAdmin", "CreatorAdmin", "BuybackAdmin", "RewardsAdmin"];

/// Blast's LP-fee share of new vaults from the launch config, then per-vault overrides.
const DEFAULT_SHARES: (u64, u64) = (1_000, 500);
const VAULT_SHARES: (u64, u64) = (2_500, 1_500);
/// A per-vault share at the vault's 30% cap.
const TINY_SHARES: (u64, u64) = (3_000, 1_500);

// Addresses.
const DESTINATION: ObjectID = address(&[0xD5]);
/// The treasury `blast_core` publishes with (`TEST_GENESIS_RECIPIENT`), paid Blast's LP-fee share
/// and the migration residuals.
const LP_PROTOCOL: ObjectID = address(&[0x0A]);
const RECIPIENT_A: ObjectID = address(&[0xA1]);
const RECIPIENT_B: ObjectID = address(&[0xB2]);
const RECIPIENT_C: ObjectID = address(&[0xC3]);
const CAP_HOLDER: ObjectID = address(&[0xCA, 0xFE]);
/// The vault's publication delay between scheduling and publishing a holder-reward round.
const ROUND_DELAY_MS: u64 = 2 * 60 * 60 * 1_000;
/// The vault's fixed delay for fee-split and Blast-share changes.
const VAULT_FEE_DELAY_MS: u64 = 172_800_000;
/// The second round's holder Quote: the least that funds a one-unit gas reserve at the 10% cap.
const SECOND_ROUND_QUOTE: u64 = 10;
const BENEFICIARY_A: ObjectID = address(&[0xBE, 0x01]);
const BENEFICIARY_B: ObjectID = address(&[0xBE, 0x02]);

const fn address(suffix: &[u8]) -> ObjectID {
    let mut bytes = [0u8; 32];
    let mut index = 0;
    while index < suffix.len() {
        bytes[32 - suffix.len() + index] = suffix[index];
        index += 1;
    }
    ObjectID::new(bytes)
}

// === Tests ===

#[test]
fn cetus_meme_a_with_sui_against_mainnet_bytecode() -> Result<()> {
    run(Case::CetusMemeA)
}

#[test]
fn cetus_meme_b_with_usdc_against_mainnet_bytecode() -> Result<()> {
    run(Case::CetusMemeB)
}

#[test]
fn bluefin_with_sui_against_mainnet_bytecode() -> Result<()> {
    run(Case::Bluefin)
}

#[test]
fn bluefin_quote_larger_seed_fixes_quote() -> Result<()> {
    let mut world = World::new(Case::Bluefin)?;
    world.graduation_target = 3 * LP_MEME;
    let launch = world.start_launch(&initial_split())?;
    world.graduate(&launch)?;
    let migration = world.migrate(&launch)?;
    ensure!(migration.residual.0 > 0, "the venue did not need all of Meme");
    ensure!(migration.residual.1 <= 1, "the venue used the fixed Quote side");
    Ok(())
}

#[test]
fn cetus_meme_a_partial_buybacks_burn_native_supply() -> Result<()> {
    buybacks_burn_native_supply(Case::CetusMemeA, false)
}

#[test]
fn cetus_meme_b_partial_buybacks_burn_native_supply() -> Result<()> {
    buybacks_burn_native_supply(Case::CetusMemeB, false)
}

#[test]
fn bluefin_partial_buybacks_burn_native_supply() -> Result<()> {
    buybacks_burn_native_supply(Case::Bluefin, false)
}

#[test]
fn cetus_buyback_returns_unspent_swap_input() -> Result<()> {
    buybacks_burn_native_supply(Case::CetusMemeA, true)
}

#[test]
fn bluefin_buyback_returns_unspent_swap_input() -> Result<()> {
    buybacks_burn_native_supply(Case::Bluefin, true)
}

fn buybacks_burn_native_supply(case: Case, exhaust_liquidity: bool) -> Result<()> {
    let mut world = World::new_with_supply(case, true)?;
    if exhaust_liquidity {
        // Seed a shallow pool so its entire full-range liquidity is reachable with u64 input.
        world.graduation_target = 20;
        if case.is_cetus() {
            world.use_cetus_terminal_tick_tier()?;
        }
    }
    let launch = world.start_launch(&initial_split())?;
    world.graduate(&launch)?;
    let mut migration = world.migrate(&launch)?;
    if exhaust_liquidity {
        // Fund just the vault balance in the simulator. The pool and swap remain real venue state.
        let mut vault = world.vault(&migration)?;
        vault.burn_quote = u64::MAX / 2;
        let mut object = world.h.object(migration.vault);
        object.data.try_as_move_mut().context("vault")?
            .set_contents_unsafe(bcs::to_bytes(&vault)?);
        world.h.insert(object);
    } else {
        world.swap(&launch, &migration, Side::QuoteIn, 3 * case.quote_unit())?;
        world.collect(&launch, &mut migration, None)?;
    }

    let supply = |world: &World| -> Result<u64> {
        let currency: Currency = bcs::from_bytes(&world.h.contents(launch.currency))?;
        match currency.supply {
            Some(SupplyState::BurnOnly(value)) => Ok(value),
            _ => bail!("expected a burn-only currency"),
        }
    };

    let attempts = if exhaust_liquidity { 1 } else { 2 };
    for _ in 0..attempts {
        let mut expected_vault = world.vault(&migration)?;
        let quote_in = if exhaust_liquidity { expected_vault.burn_quote } else { expected_vault.burn_quote / 2 };
        ensure!(quote_in > 0, "the previous buyback left spendable Quote");
        let supply_before = supply(&world)?;
        let pt = world.buyback_pt(&launch, &migration, migration.pool, quote_in, 1)?;
        let outcome = world.h.execute(pt)?;
        outcome.assert_success();

        let events: Vec<BuybackBurned> = world.vault_events(&outcome, "BuybackBurned");
        ensure!(events.len() == 1);
        let burn = &events[0];
        ensure!(burn.vault_id == migration.vault && burn.meme_burned > 0);
        let (module, name) = if case.is_cetus() { ("pool", "SwapEvent") } else { ("events", "AssetSwap") };
        let swaps: Vec<_> = outcome.events.iter()
            .filter(|event| event.type_.module.as_str() == module && event.type_.name.as_str() == name)
            .collect();
        ensure!(swaps.len() == 1, "the buyback ran one venue swap");
        // Decode the fixed prefix through amount_out from each pinned venue's swap event.
        let payload = &swaps[0].contents;
        let (pool, a_to_b, amount_in, amount_out) = if case.is_cetus() {
            let (direction, pool, _, input, output): (bool, ObjectID, ObjectID, u64, u64) =
                bcs::from_bytes(payload.get(..81).context("Cetus swap event prefix")?)?;
            (pool, direction, input, output)
        } else {
            let (pool, direction, input, output): (ObjectID, bool, u64, u64) =
                bcs::from_bytes(payload.get(..49).context("Bluefin swap event prefix")?)?;
            (pool, direction, input, output)
        };
        ensure!(pool == migration.pool && a_to_b != case.meme_is_a(), "the swap bought Meme with Quote");
        if exhaust_liquidity {
            ensure!(amount_in > 0 && amount_in < quote_in, "the venue returned unspent input");
        } else {
            ensure!(amount_in == quote_in, "the venue spent exactly the requested Quote");
        }
        ensure!(burn.quote_spent == amount_in, "the burn records actual venue spend");
        ensure!(burn.meme_burned == amount_out, "the entire venue output was burned");
        expected_vault.burn_quote -= amount_in;
        ensure!(burn.burn_quote_pending == expected_vault.burn_quote);
        ensure!(world.vault(&migration)? == expected_vault, "only the pending burn Quote changed");
        ensure!(supply_before.checked_sub(supply(&world)?) == Some(burn.meme_burned), "Meme was removed from native supply");
        ensure!(outcome.coins_created_for(&world.h, SuiAddress::ZERO).is_empty(), "no disposal transfer");
    }

    Ok(())
}

fn initial_split() -> FeeSplit {
    FeeSplit::new([
        (Destination::Owner, 2_500),
        (Destination::AutoLp, 2_000),
        (Destination::HolderRewards, 1_000),
        (Destination::Burn, 500),
        (Destination::Address(RECIPIENT_A.into()), 2_500),
        (Destination::Address(RECIPIENT_B.into()), 1_500),
    ])
}

/// `split` with `bps` moved from the `from` route to the `to` route.
fn shifted(split: &FeeSplit, from: Destination, to: Destination, bps: u64) -> FeeSplit {
    let mut next = split.clone();
    for route in &mut next.routes {
        if route.destination == from {
            route.bps -= bps;
        } else if route.destination == to {
            route.bps += bps;
        }
    }
    next
}

/// The whole lifecycle of one launch on `case`.
fn run(case: Case) -> Result<()> {
    let mut w = World::new(case)?;
    w.report(format!("snapshot checkpoint {}", w.checkpoint));
    let split = initial_split();

    let launch = w.start_launch(&split)?;
    w.graduate(&launch)?;
    w.migration_failures_commit_nothing(&launch)?;
    let mut m = w.migrate(&launch)?;

    // One-sided: only Quote fees exist, so auto-LP waits. The launch config's share applies.
    w.swap(&launch, &m, Side::QuoteIn, w.case.quote_unit())?;
    let c = w.collect(&launch, &mut m, None)?;
    ensure!(c.fees.gross_meme == 0 && c.fees.gross_quote > 0, "a Quote-only swap left Quote-only fees");
    ensure!(c.added.is_none(), "one-sided auto-LP must wait");
    w.report(format!("collect one-sided, launch-config share {DEFAULT_SHARES:?}: {}", c.line()));

    // Two-sided: auto-LP adds at the pool price and the remainder waits.
    w.swap(&launch, &m, Side::QuoteIn, 5 * w.case.quote_unit())?;
    w.swap(&launch, &m, Side::MemeIn, LP_MEME / 20)?;
    let c = w.collect(&launch, &mut m, None)?;
    ensure!(c.added.is_some(), "two-sided auto-LP must add");
    w.report(format!("collect two-sided, launch-config share: {}", c.line()));

    // Tiny: a per-vault share at the cap applies from the next collection. Bluefin accepts a swap
    // so small that the Meme left to auto-LP cannot carry any venue liquidity, so auto-LP waits.
    // Cetus rejects a swap that pays out nothing, and at this pool price the smallest swap it
    // accepts leaves auto-LP enough Meme to add even beside one waiting Quote atom; there the
    // smallest collectable auto-LP is added.
    w.set_vault_shares(&launch, &m, TINY_SHARES)?;
    let tiny = if w.case.is_cetus() { LP_MEME / w.lp_quote() * 2 } else { LP_MEME / w.lp_quote() * 20 / 7_000 };
    w.swap(&launch, &m, Side::MemeIn, tiny)?;
    let c = w.collect(&launch, &mut m, None)?;
    let vault = w.vault(&m)?;
    ensure!(c.part(&Destination::AutoLp).0 > 0, "the swap left Meme for auto-LP");
    if w.case.is_cetus() {
        ensure!(c.added.is_some(), "Cetus adds the smallest collectable auto-LP");
    } else {
        ensure!(vault.auto_lp_meme > 0 && vault.auto_lp_quote > 0, "tiny Meme and waiting Quote");
        ensure!(c.added.is_none(), "tiny auto-LP must wait");
    }
    w.report(format!(
        "collect tiny, per-vault share {TINY_SHARES:?}, {tiny} Meme swapped: {} pending=({}, {})",
        c.line(),
        vault.auto_lp_meme,
        vault.auto_lp_quote
    ));

    // A later per-vault share replaces it live; auto-LP adds again.
    w.set_vault_shares(&launch, &m, VAULT_SHARES)?;
    w.swap(&launch, &m, Side::QuoteIn, 3 * w.case.quote_unit())?;
    w.swap(&launch, &m, Side::MemeIn, LP_MEME / 40)?;
    let c = w.collect(&launch, &mut m, None)?;
    ensure!(c.added.is_some(), "later auto-LP must add");
    w.report(format!("collect per-vault share {VAULT_SHARES:?}: {}", c.line()));

    // Split update with an owner proof from the live curve-fee cap, settling under the old split
    // first.
    let cap = w.claim_curve_fee_cap(&launch)?;
    let next = FeeSplit::new([
        (Destination::Owner, 3_000),
        (Destination::AutoLp, 3_000),
        (Destination::HolderRewards, 1_000),
        (Destination::Burn, 1_000),
        (Destination::Address(RECIPIENT_C.into()), 2_000),
    ]);
    w.swap(&launch, &m, Side::QuoteIn, 2 * w.case.quote_unit())?;
    w.swap(&launch, &m, Side::MemeIn, LP_MEME / 50)?;
    let c = w.collect(&launch, &mut m, Some((cap, &next)))?;
    w.report(format!("settle_and_apply_fee_split: {} then the new split", c.line()));
    w.swap(&launch, &m, Side::QuoteIn, w.case.quote_unit())?;
    let c = w.collect(&launch, &mut m, None)?;
    ensure!(w.vault(&m)?.fee_split.value == next, "the next collection runs under the new split");
    w.report(format!("collect under the new split: {}", c.line()));
    w.buyback(&launch, &m)?;

    w.other_pool_is_refused(&launch, &m, cap)?;
    w.claim_owner_balances(&launch, &m, cap)?;
    w.retired_cap_is_refused(&launch, &m, cap, &next)?;
    w.holder_rewards(&launch, &m)?;

    w.print_report();
    Ok(())
}

// === Cases ===

#[derive(Clone, Copy, Debug, PartialEq)]
enum Case {
    CetusMemeA,
    CetusMemeB,
    Bluefin,
}

impl Case {
    fn quote(self) -> TypeTag {
        match self {
            Case::CetusMemeB => tag(USDC),
            _ => sui(),
        }
    }

    fn quote_unit(self) -> u64 {
        match self {
            Case::CetusMemeB => 1_000_000,
            _ => 1_000_000_000,
        }
    }

    fn is_cetus(self) -> bool {
        self != Case::Bluefin
    }

    /// Whether Meme is the pool's coin A.
    fn meme_is_a(self) -> bool {
        self != Case::CetusMemeB
    }

    fn module(self) -> &'static str {
        if self.is_cetus() { "cetus" } else { "bluefin" }
    }
}

#[derive(Clone, Copy)]
enum Side {
    QuoteIn,
    MemeIn,
}

/// The migrators compile once per test binary; each world links them to its own packages.
fn migrators() -> &'static UnlinkedPackage {
    static MIGRATORS: OnceLock<UnlinkedPackage> = OnceLock::new();
    MIGRATORS.get_or_init(|| {
        let work = blast_launchpad_ptb_tests::test_work_dir().join(env!("CARGO_PKG_NAME")).join("venue_fork");
        build_unlinked(
            &sui_dir().join("migrators"),
            &["blast_admin", "blast_partners", "blast_fun_vesting", "blast_core", "blast_vault"],
            &work,
        )
            .expect("build the migrators")
    })
}

// === World ===

struct Launch {
    meme: TypeTag,
    launch: ObjectID,
    currency: ObjectID,
    split: FeeSplit,
}

struct Migration {
    pool: ObjectID,
    vault: ObjectID,
    /// Cetus: the `CetusLPBurnProof`; Bluefin: the `Position`.
    position: ObjectID,
    auto_lp_position: Option<ObjectID>,
    liquidity: u128,
    /// The (Meme, Quote) the venue did not take, paid to the treasury at migration.
    residual: (u64, u64),
}

struct Collection {
    fees: FeesCollected,
    split: FeeSplit,
    added: Option<AutoLiquidityAdded>,
}

impl Collection {
    /// The (Meme, Quote) the collection routed to `destination`.
    fn part(&self, destination: &Destination) -> (u64, u64) {
        route_part(&self.split, &self.fees, destination)
    }

    fn line(&self) -> String {
        let f = &self.fees;
        let routes: Vec<_> = self
            .split
            .routes
            .iter()
            .zip(f.route_meme.iter().zip(&f.route_quote))
            .map(|(route, (meme, quote))| format!("{:?}=({meme}, {quote})", route.destination))
            .collect();
        format!(
            "gross=({}, {}) protocol=({}, {}) routes=[{}] added={}",
            f.gross_meme,
            f.gross_quote,
            f.protocol_meme,
            f.protocol_quote,
            routes.join(" "),
            match &self.added {
                Some(a) =>
                    format!("({}, {}) pending=({}, {})", a.meme_amount, a.quote_amount, a.auto_lp_meme_pending, a.auto_lp_quote_pending),
                None => "none".into(),
            },
        )
    }
}

/// The (Meme, Quote) `fees` routed to `destination` under `split`.
fn route_part(split: &FeeSplit, fees: &FeesCollected, destination: &Destination) -> (u64, u64) {
    split
        .routes
        .iter()
        .zip(fees.route_meme.iter().zip(&fees.route_quote))
        .filter(|(route, _)| route.destination == *destination)
        .fold((0, 0), |(meme, quote), (_, (m, q))| (meme + m, quote + q))
}

struct World {
    h: Harness,
    case: Case,
    graduation_target: u64,
    cetus_tier: (u32, u64),
    checkpoint: u64,
    venue: BTreeMap<String, ObjectID>,
    admin: ObjectID,
    core: ObjectID,
    blast: ObjectID,
    migrators: ObjectID,
    vault_stack: VaultStack,
    treasury: ObjectID,
    version: ObjectID,
    migrators_version: ObjectID,
    runtime: ObjectID,
    config: ObjectID,
    /// The shared `launch::LaunchRegistry` every launch ID derives from.
    launch_registry: ObjectID,
    venue_config: ObjectID,
    acl: ObjectID,
    root: ObjectID,
    admin_cap: ObjectID,
    project: CompiledPackage,
    project_token: &'static str,
    burnable: bool,
    coins: u64,
    shares: (u64, u64),
    lines: Vec<String>,
}

impl World {
    /// Inserts the snapshot, publishes the stack, the vault package, and the linked migrators,
    /// and configures them under the production admin path.
    fn new(case: Case) -> Result<Self> {
        Self::new_with_supply(case, false)
    }

    fn new_with_supply(case: Case, burnable: bool) -> Result<Self> {
        let work =
            blast_launchpad_ptb_tests::test_work_dir().join(env!("CARGO_PKG_NAME")).join(format!("venue_fork_{case:?}"));
        let mut h = Harness::new()?;
        let (checkpoint, venue) = insert_snapshot(&mut h)?;

        let stack = publish_stack(&mut h, &work)?;
        let (admin, core, blast) = (stack.admin, stack.core, stack.launchpad);
        let (admin_published, published) = (&stack.admin_publication, &stack.launchpad_publication);
        let (vault, vault_publication) = stack.publish(&mut h, &sui_dir().join("vault"), &work)?;
        let one = |h: &Harness, outcome: &Outcome, module: &str, name: &str| {
            let ids = outcome.created(h, module, name);
            assert_eq!(ids.len(), 1, "{module}::{name}");
            ids[0]
        };
        let acl = one(&h, admin_published, "blast_acl", "ACL");
        let root = one(&h, admin_published, "blast_acl", "SuperAdminCap");
        let config = one(&h, published, "launch_config", "LaunchConfig");
        let runtime = one(&h, published, "runtime_config", "RuntimeConfig");
        let launch_registry = h.derived_registry(published, "launch", "LaunchRegistry")?;

        let mut dependencies = vec![
            ObjectID::from_single_byte(1),
            ObjectID::from_single_byte(2),
            admin,
            stack.partners,
            stack.vesting,
            core,
            vault,
        ];
        dependencies.extend(venue_dependencies(&h)?);
        let linked = migrators().link(
            &[
                ("blast_admin", admin),
                ("blast_partners", stack.partners),
                ("blast_fun_vesting", stack.vesting),
                ("blast_core", core),
                ("blast_vault", vault),
            ],
            dependencies,
        )?;
        let (migrators, migrators_publication) = h.publish(linked)?;
        let venue_config = one(&h, &migrators_publication, "venue_config", "VenueConfig");
        let migrators_version = h.wrap_migrators(admin, migrators, &migrators_publication)?;
        // Both admissions name the case's one venue witness: the vault registry lists it, beside
        // the launchpad's package witness as the issuer of the launch's vault terms, while the
        // vault package is paused, and the launch config admits it.
        let venue_type = tag(&format!("{migrators}::{}::Venue", case.module()));
        let issuer_type = tag(&format!("{blast}::blast_fun::PackageWitness"));
        let vault_stack = h.wrap_vault(admin, vault, &vault_publication)?;
        h.release_vault(admin, admin_published, core, &vault_stack, stack.treasury, &[venue_type.clone(), issuer_type])?;
        let (version, package_admin) = h.wrap_launchpad(blast, published, admin, admin_published, core, case.quote(), venue_type)?;
        h.unpause_launchpad(blast, admin, admin_published, version, package_admin, runtime, config, stack.treasury, 7)?;
        let (fixture, project_token) = if burnable {
            ("fixture/burnable_project", "burnable_token::BURNABLE_TOKEN")
        } else {
            ("fixture/project", "token::TOKEN")
        };
        let project = build(&blast_launchpad_ptb_tests::crate_dir().join(fixture), &stack.linked(), &work)?;

        // Production admin path: the configured root owner's SuperAdminCap grants one AdminCap,
        // then each launchpad and vault role.
        let mut roles = Vec::new();
        for role in CORE_ROLES {
            roles.push(tag(&format!("{core}::blast_domain::{role}")));
        }
        let admin_cap = h.grant_roles(admin, admin_published, &roles)?;

        let mut w = World {
            h,
            case,
            graduation_target: 25 * case.quote_unit(),
            cetus_tier: (CETUS_TICK_SPACING, CETUS_FEE_RATE),
            checkpoint,
            venue,
            admin,
            core,
            blast,
            migrators,
            vault_stack,
            treasury: stack.treasury,
            version,
            migrators_version,
            runtime,
            config,
            launch_registry,
            venue_config,
            acl,
            root,
            admin_cap,
            project,
            project_token,
            burnable,
            coins: 0,
            shares: DEFAULT_SHARES,
            lines: Vec::new(),
        };

        // New vaults take Blast's LP-fee share from the launch config at migration.
        let mut b = ProgrammableTransactionBuilder::new();
        let fee_admin = w.sign_in(&mut b, "FeeAdmin")?;
        let treasury_admin = w.sign_in(&mut b, "TreasuryAdmin")?;
        let config = b.obj(w.h.shared(w.config, true))?;
        let version = b.obj(w.h.shared(w.version, false))?;
        let fee = w.bps(&mut b, 100)?;
        let admin_clock = b.obj(w.h.shared(sui_types::SUI_CLOCK_OBJECT_ID, false))?;
        let next_delay = b.pure(172_800_000u64)?;
        call(&mut b, blast, "launch_config", "schedule_trade_fees", vec![], vec![config, version, fee_admin, fee, fee, next_delay, admin_clock]);
        let share = w.bps(&mut b, ALLOCATION_BPS)?;
        call(&mut b, blast, "launch_config", "schedule_protocol_allocation", vec![], vec![config, version, treasury_admin, share, share, next_delay, admin_clock]);
        let meme_bps = w.bps(&mut b, DEFAULT_SHARES.0)?;
        let quote_bps = w.bps(&mut b, DEFAULT_SHARES.1)?;
        call(&mut b, blast, "launch_config", "schedule_protocol_lp_fees", vec![], vec![config, version, fee_admin, meme_bps, quote_bps, next_delay, admin_clock]);
        w.h.execute(b.finish())?.assert_success();
        blast_launchpad_ptb_tests::apply_admin_changes(&mut w.h, vec![
            (blast, "launch_config", "apply_trade_fees", vec![], w.config, w.version),
            (blast, "launch_config", "apply_protocol_allocation", vec![], w.config, w.version),
            (blast, "launch_config", "apply_protocol_lp_fees", vec![], w.config, w.version),
        ])?;

        Ok(w)
    }

    fn report(&mut self, line: String) {
        let line = format!("{:?} {line}", self.case);
        println!("VENUE_FORK {line}");
        self.lines.push(line);
    }

    fn print_report(&self) {
        println!("==== venue fork report: {:?} ====", self.case);
        for line in &self.lines {
            println!("{line}");
        }
    }

    fn venue(&self, name: &str) -> ObjectID {
        *self.venue.get(name).unwrap_or_else(|| panic!("snapshot object {name}"))
    }

    fn quote(&self) -> TypeTag {
        self.case.quote()
    }

    fn pair(&self, launch: &Launch) -> Vec<TypeTag> {
        vec![launch.meme.clone(), self.quote()]
    }

    /// The pool's type arguments in venue order.
    fn pool_pair(&self, launch: &Launch) -> Vec<TypeTag> {
        if self.case.meme_is_a() {
            vec![launch.meme.clone(), self.quote()]
        } else {
            vec![self.quote(), launch.meme.clone()]
        }
    }

    /// A route's type arguments: Meme and Quote, then on Cetus the pool's coins in venue order.
    fn route_types(&self, launch: &Launch) -> Vec<TypeTag> {
        let mut types = self.pair(launch);
        if self.case.is_cetus() {
            types.extend(self.pool_pair(launch));
        }
        types
    }

    /// Signs the AdminCap in to the ACL as the launchpad's `role`; the witness it returns
    /// authorizes only that role.
    fn sign_in(&self, b: &mut ProgrammableTransactionBuilder, role: &str) -> Result<Argument> {
        self.sign_in_as(b, tag(&format!("{}::blast_domain::{role}", self.core)))
    }

    /// Signs the AdminCap in as `blast_core`'s `role`, which the vault's calls take.
    fn sign_in_core(&self, b: &mut ProgrammableTransactionBuilder, role: &str) -> Result<Argument> {
        self.sign_in_as(b, tag(&format!("{}::blast_domain::{role}", self.core)))
    }

    fn sign_in_as(&self, b: &mut ProgrammableTransactionBuilder, role: TypeTag) -> Result<Argument> {
        let acl = b.obj(self.h.shared(self.acl, false))?;
        let admin_cap = b.obj(self.h.owned(self.admin_cap))?;

        Ok(call(b, self.admin, "blast_acl", "sign_in", vec![role], vec![acl, admin_cap]))
    }

    fn bps(&self, b: &mut ProgrammableTransactionBuilder, value: u64) -> Result<Argument> {
        unique_bps(b, self.core, value)
    }

    fn vault_package(&self) -> ObjectID {
        self.vault_stack.package
    }

    fn vault_version(&self, b: &mut ProgrammableTransactionBuilder) -> Result<Argument> {
        self.shared(b, self.vault_stack.version, false)
    }

    fn shared(&self, b: &mut ProgrammableTransactionBuilder, object: ObjectID, mutable: bool) -> Result<Argument> {
        Ok(b.obj(self.h.shared(object, mutable))?)
    }

    fn clock(&self, b: &mut ProgrammableTransactionBuilder) -> Result<Argument> {
        self.shared(b, SUI_CLOCK_OBJECT_ID, false)
    }

    /// A coin of `coin_type` owned by the sender, inserted directly: the Quote a buyer or trader
    /// brings.
    fn mint(&mut self, coin_type: TypeTag, value: u64) -> ObjectID {
        self.coins += 1;
        let coin_id = ObjectID::derive_id(TransactionDigest::new([0xF0; 32]), self.coins);
        let coin = MoveObject::new_coin(coin_type, OBJECT_START_VERSION, coin_id, value);
        self.h.insert(Object::new_move(coin, Owner::AddressOwner(self.h.sender), TransactionDigest::genesis_marker()));
        coin_id
    }

    /// The sender's largest Meme coin, bought on the curve.
    fn meme_coin(&self, launch: &Launch) -> Result<ObjectID> {
        let meme = launch.meme.to_canonical_string(true);
        self.h
            .owned_by(self.h.sender)
            .into_iter()
            .filter(|object| object.coin_type_maybe().is_some_and(|coin| coin.to_canonical_string(true) == meme))
            .max_by_key(|object| object.get_coin_value_unsafe())
            .map(|object| object.id())
            .context("a bought Meme coin")
    }

    fn quote_coin(&mut self, b: &mut ProgrammableTransactionBuilder, value: u64) -> Result<Argument> {
        let coin = self.mint(self.quote(), value);
        Ok(b.obj(self.h.owned(coin))?)
    }

    /// Events of `package::module::name`, which travel unwrapped.
    fn package_events<T: DeserializeOwned>(&self, outcome: &Outcome, package: ObjectID, module: &str, name: &str) -> Vec<T> {
        outcome
            .events
            .iter()
            .filter(|event| {
                ObjectID::from(event.type_.address) == package
                    && event.type_.module.as_str() == module
                    && event.type_.name.as_str() == name
            })
            .map(|event| bcs::from_bytes(&event.contents).expect("event payload"))
            .collect()
    }

    /// Migrators events of `name`, from its own `events` module.
    fn events<T: DeserializeOwned>(&self, outcome: &Outcome, name: &str) -> Vec<T> {
        self.package_events(outcome, self.migrators, "events", name)
    }

    /// Vault events of `name`, from `blast_vault_events`.
    fn vault_events<T: DeserializeOwned>(&self, outcome: &Outcome, name: &str) -> Vec<T> {
        self.package_events(outcome, self.vault_package(), "blast_vault_events", name)
    }

    /// Launchpad events of `name`, emitted directly by its `events` module.
    fn launchpad_events<T: DeserializeOwned>(&self, outcome: &Outcome, name: &str) -> Vec<T> {
        outcome
            .events_of("events", name)
            .into_iter()
            .map(|contents| bcs::from_bytes(contents).expect("event payload"))
            .collect()
    }

    fn launch_lifecycle(&self, launch: &Launch) -> u8 {
        self.h.contents(launch.launch)[32]
    }

    fn vault(&self, m: &Migration) -> Result<Vault> {
        bcs::from_bytes(&self.h.contents(m.vault)).context("decode Vault")
    }

    /// The liquidity of the migration position: inside the burn proof on Cetus.
    fn position_liquidity(&self, position: ObjectID) -> Result<u128> {
        let contents = self.h.contents(position);
        if self.case.is_cetus() {
            if self.h.is_type(position, "lp_burn", "CetusLPBurnProof") {
                let proof: BurnProof = bcs::from_bytes(&contents)?;
                return Ok(proof.position.liquidity);
            }
            let position: CetusPosition = bcs::from_bytes(&contents)?;
            return Ok(position.liquidity);
        }
        Ok(u128::from_le_bytes(contents[80..96].try_into()?))
    }

    /// Publishes one generated project and finalizes its currency. On the Meme-B route the Meme's
    /// type name must sort below USDC's, so projects are published until one does.
    fn publish_ticket(&mut self) -> Result<Ticket> {
        for _ in 0..16 {
            let (project_id, published) = self.h.publish(self.project.clone())?;
            let meme = tag(&format!("{project_id}::{}", self.project_token));
            if meme_is_cetus_a(&meme, &self.quote()) != self.case.meme_is_a() && self.case.is_cetus() {
                continue;
            }
            let created_for_meme = |module, name| -> Result<ObjectID> {
                published.created(&self.h, module, name).into_iter().find(|id| {
                    self.h.object(*id).data.try_as_move().is_some_and(|object| {
                        object.type_().type_params().first().is_some_and(|coin| coin.as_ref() == &meme)
                    })
                }).with_context(|| format!("published {module}::{name} for {meme}"))
            };
            let ticket = created_for_meme("launch_ticket", "LaunchTicket")?;
            let treasury_cap = created_for_meme("coin", "TreasuryCap")?;
            ensure!(self.h.object(treasury_cap).owner().get_address_owner_address()? == self.h.sender);
            let pending = created_for_meme("coin_registry", "Currency")?;
            let mut b = ProgrammableTransactionBuilder::new();
            let registry = self.shared(&mut b, SUI_COIN_REGISTRY_OBJECT_ID, true)?;
            let receiving = b.obj(ObjectArg::Receiving(self.h.object(pending).compute_object_reference()))?;
            call(
                &mut b,
                SUI_FRAMEWORK_PACKAGE_ID,
                "coin_registry",
                "finalize_registration",
                vec![meme.clone()],
                vec![registry, receiving],
            );
            let finalized = self.h.execute(b.finish())?;
            finalized.assert_success();
            let currency = finalized.created(&self.h, "coin_registry", "Currency")[0];
            return Ok(Ticket { meme, ticket, treasury_cap, currency });
        }
        bail!("no generated Meme had the route's Cetus coin order")
    }

    /// One PTB: the venue's `prepare` at `tier` on the coin's `TreasuryCap`, `launch::new` with
    /// the venue ticket and the cap, the setters, `finalize`, and `share`. With `mint_between`, one
    /// more atom is minted from the cap after `prepare`.
    fn create_launch_pt(
        &self,
        ticket: &Ticket,
        split: &FeeSplit,
        tier: (u32, u64),
        mint_between: bool,
    ) -> Result<ProgrammableTransaction> {
        let mut b = ProgrammableTransactionBuilder::new();
        let pair = vec![ticket.meme.clone(), self.quote()];
        let launch_ticket = b.obj(self.h.owned(ticket.ticket))?;
        let treasury_cap = b.obj(self.h.owned(ticket.treasury_cap))?;
        let migrators_version = self.shared(&mut b, self.migrators_version, false)?;
        let version = self.shared(&mut b, self.version, false)?;
        let config = self.shared(&mut b, self.config, false)?;
        let venue_config = self.shared(&mut b, self.venue_config, true)?;
        let currency = self.shared(&mut b, ticket.currency, true)?;
        let tick_spacing = b.pure(tier.0)?;
        let venue_ticket = if self.case.is_cetus() {
            let cetus_config = self.shared(&mut b, self.venue("cetus_global_config"), false)?;
            let pools = self.shared(&mut b, self.venue("cetus_pools"), true)?;
            call(
                &mut b,
                self.migrators,
                "cetus",
                "prepare",
                pair.clone(),
                vec![migrators_version, venue_config, cetus_config, pools, treasury_cap, tick_spacing],
            )
        } else {
            let fee_rate = b.pure(tier.1)?;
            call(
                &mut b,
                self.migrators,
                "bluefin",
                "prepare",
                pair.clone(),
                vec![migrators_version, venue_config, treasury_cap, currency, tick_spacing, fee_rate],
            )
        };
        if mint_between {
            let one = b.pure(1u64)?;
            let minted = call(&mut b, SUI_FRAMEWORK_PACKAGE_ID, "coin", "mint", vec![ticket.meme.clone()], vec![treasury_cap, one]);
            b.transfer_arg(self.h.sender, minted);
        }
        let initializer = call(
            &mut b,
            self.blast,
            "launch",
            "new",
            pair.clone(),
            vec![launch_ticket, treasury_cap, version, config, venue_ticket],
        );
        let virtual_quote = b.pure(5 * self.case.quote_unit())?;
        call(&mut b, self.blast, "launch", "set_virtual_quote", pair.clone(), vec![initializer, version, virtual_quote]);
        let target = b.pure(self.target())?;
        call(&mut b, self.blast, "launch", "set_graduation_target", pair.clone(), vec![initializer, version, target]);
        let plan = self.plan_arg(&mut b)?;
        call(&mut b, self.blast, "launch", "set_allocation_plan", pair.clone(), vec![initializer, version, plan]);
        let split = split.arg(&mut b, self.core)?;
        call(&mut b, self.blast, "launch", "set_lp_fee_split", pair.clone(), vec![initializer, version, split]);
        let creation_fee = call(&mut b, SUI_FRAMEWORK_PACKAGE_ID, "coin", "zero", vec![sui()], vec![]);
        let registry = self.shared(&mut b, self.launch_registry, true)?;
        let launch = call(&mut b, self.blast, "launch", "finalize", pair.clone(), vec![
            initializer, version,
            registry,
            currency,
            config,
            creation_fee,
        ]);
        let clock = self.clock(&mut b)?;
        call(&mut b, self.blast, "launch", "share", pair, vec![launch, version, clock]);

        Ok(b.finish())
    }

    /// The pinned config already registers spacing 2. Admit SUI at that tier in the fixture
    /// so the final initialized tick is MAX_TICK, beyond the adapter's price limit.
    fn use_cetus_terminal_tick_tier(&mut self) -> Result<()> {
        let config = self.venue("cetus_allowed_pair_config_sui");
        let mut object = self.h.object(config);
        let (field_id, pair, mut spacings): (ObjectID, String, Vec<u32>) =
            bcs::from_bytes(&self.h.contents(config))?;
        ensure!(field_id == config && spacings == [CETUS_TICK_SPACING]);
        let spacing = 2;
        spacings.push(spacing);
        object.data.try_as_move_mut().context("Cetus quote allowlist")?
            .set_contents_unsafe(bcs::to_bytes(&(field_id, pair, spacings))?);
        self.h.insert(object);
        self.cetus_tier = (spacing, 100);
        Ok(())
    }

    fn target(&self) -> u64 {
        self.graduation_target
    }

    fn lp_quote(&self) -> u64 {
        self.target() / 10 * 9
    }

    /// Rejects tiers the venue's `prepare` would refuse and supply minted after `prepare`, each
    /// rolled back, then prepares the venue and starts the launch at a valid tier and checks what
    /// the venue and the launch record.
    fn start_launch(&mut self, split: &FeeSplit) -> Result<Launch> {
        let ticket = self.publish_ticket()?;
        let owners = [self.h.sender];
        let mut watched = vec![ticket.ticket, ticket.treasury_cap, ticket.currency, self.venue_config];
        if self.case.is_cetus() {
            watched.push(self.venue("cetus_pools"));
            let pt = self.create_launch_pt(&ticket, split, (CETUS_UNREGISTERED_SPACING, 0), false)?;
            self.h.assert_rolled_back(pt, self.cetus_abort("config", 2), &watched, &owners)?;
            self.report(format!(
                "cetus::prepare at unregistered tick spacing {CETUS_UNREGISTERED_SPACING}: Cetus config aborts 2, rolled back"
            ));
            let pt = self.create_launch_pt(&ticket, split, (CETUS_UNADMITTED_SPACING, 0), false)?;
            self.h.assert_rolled_back(pt, self.cetus_abort("factory", 8), &watched, &owners)?;
            self.report(format!(
                "cetus::prepare at registered but unadmitted tick spacing {CETUS_UNADMITTED_SPACING}: Cetus factory aborts 8, rolled back"
            ));
        } else {
            for tier in [
                (0, BLUEFIN_FEE_RATE),
                (401, BLUEFIN_FEE_RATE),
                (BLUEFIN_TICK_SPACING, 0),
                (BLUEFIN_TICK_SPACING, 20_001),
            ] {
                let pt = self.create_launch_pt(&ticket, split, tier, false)?;
                let expected = Expected::Abort { package: self.migrators, module: "bluefin", code: INVALID_TIER };
                self.h.assert_rolled_back(pt, expected, &watched, &owners)?;
            }
            self.report(
                "bluefin::prepare at (0, 3000), (401, 3000), (60, 0), (60, 20001): EInvalidTier, rolled back".into(),
            );
        }

        let tier = if self.case.is_cetus() {
            self.cetus_tier
        } else {
            (BLUEFIN_TICK_SPACING, BLUEFIN_FEE_RATE)
        };
        // `prepare` borrows the cap before any supply leaves it; supply minted afterwards is refused
        // when finalization fixes the supply.
        let pt = self.create_launch_pt(&ticket, split, tier, true)?;
        let expected = Expected::Abort { package: self.blast, module: "launch_ticket", code: INVALID_INITIAL_MEME_SUPPLY };
        self.h.assert_rolled_back(pt, expected, &watched, &owners)?;
        self.report(format!(
            "{}::prepare then one atom minted from the TreasuryCap before launch::new: launch_ticket aborts invalid_initial_meme_supply, rolled back",
            self.case.module(),
        ));

        let pt = self.create_launch_pt(&ticket, split, tier, false)?;
        let created = self.h.execute(pt)?;
        created.assert_success();
        let launches = created.created(&self.h, "launch", "Launch");
        ensure!(launches.len() == 1 && self.h.object(launches[0]).is_shared());
        ensure!(
            launches[0] == blast_launchpad_ptb_tests::launch_id(self.blast, self.launch_registry, &ticket.meme)?,
            "the launch ID derives from the LaunchRegistry and the coin type"
        );
        let launch = Launch { meme: ticket.meme.clone(), launch: launches[0], currency: ticket.currency, split: split.clone() };
        let recorded: Vec<LaunchCreated> = self.launchpad_events(&created, "LaunchCreated");
        ensure!(recorded.len() == 1);
        let recorded = &recorded[0];
        ensure!(recorded.lp_fee_split == *split, "the launch records the fee split");
        ensure!(recorded.venue.ends_with(&format!("::{}::Venue", self.case.module())), "the launch records the venue");
        // Finalization consumed the cap the venue prepared with, sealing the whole supply.
        ensure!(created.consumed(ticket.treasury_cap), "finalize takes the cap");
        let currency: Currency = bcs::from_bytes(&self.h.contents(ticket.currency))?;
        let sealed = match currency.supply {
            Some(SupplyState::Fixed(value)) if !self.burnable => value,
            Some(SupplyState::BurnOnly(value)) if self.burnable => value,
            _ => bail!("finalize seals the supply as the ticket asks"),
        };
        ensure!(sealed == ATOMIC_SUPPLY, "the whole supply is sealed");

        // The venue keeps the launch's tier under VenueConfig.
        let tiers: Vec<_> = created
            .created(&self.h, "dynamic_field", "Field")
            .into_iter()
            .filter(|field| {
                *self.h.object(*field).owner() == Owner::ObjectOwner(self.venue_config.into())
                    && self.h.object(*field).data.try_as_move().is_some_and(|object| {
                        object.type_().to_string().contains(&format!("::{}::PoolTierKey<", self.case.module()))
                    })
            })
            .collect();
        ensure!(tiers.len() == 1, "one pool tier under VenueConfig");
        if self.case.is_cetus() {
            let (_, _, spacing): (ObjectID, bool, u32) = bcs::from_bytes(&self.h.contents(tiers[0]))?;
            ensure!(spacing == tier.0, "VenueConfig records the tick spacing");
            // The Meme type's one PoolCreationCap is minted, registered for the pair at the
            // tier, and kept under VenueConfig, all before the launch exists.
            let reserved: Vec<CetusPoolReserved> = self.events(&created, "CetusPoolReserved");
            let registered: Vec<RegisterPermissionPair> =
                venue_events(&created, "factory", "RegisterPermissionPairEvent");
            let minted: Vec<MintPoolCreationCap> = venue_events(&created, "factory", "MintPoolCreationCap");
            ensure!(reserved.len() == 1 && registered.len() == 1 && minted.len() == 1);
            let cap = reserved[0].pool_creation_cap_id;
            ensure!(reserved[0].tick_spacing == tier.0 && registered[0].tick_spacing == tier.0);
            ensure!(registered[0].cap == cap && minted[0].cap == cap);
            ensure!(
                registered[0].coin_type == cetus_name(&launch.meme)
                    && registered[0].coin_pair == cetus_name(&self.quote())
            );
            let position = |name: &str| created.events.iter().position(|event| event.type_.name.as_str() == name);
            let first_launchpad_event =
                created.events.iter().position(|event| ObjectID::from(event.type_.address) == self.blast);
            ensure!(
                position("MintPoolCreationCap").is_some() && position("MintPoolCreationCap") < first_launchpad_event,
                "Cetus mints the pool creation cap before any launchpad event"
            );
            let Owner::ObjectOwner(field) = self.h.object(cap).owner().clone() else { bail!("cap is not a child") };
            ensure!(*self.h.object(field.into()).owner() == Owner::ObjectOwner(self.venue_config.into()));
            // Cetus's permission-pair manager now maps the pair's pool key to this cap.
            let pool_key_to_cap = created
                .created(&self.h, "dynamic_field", "Field")
                .into_iter()
                .filter_map(|field| bcs::from_bytes::<(ObjectID, ObjectID, ObjectID)>(&self.h.contents(field)).ok())
                .filter(|(_, _, value)| *value == cap)
                .count();
            ensure!(pool_key_to_cap == 1, "Cetus records the pair's pool key under the cap");
            self.report(format!(
                "cetus::prepare at tick spacing {} registers fee rate {} from Cetus; PoolCreationCap {cap} minted, pair registered, kept under VenueConfig; then launch::new takes the cap and finalize fixes the supply",
                tier.0, tier.1
            ));
        } else {
            let (_, _, recorded_tier): (ObjectID, bool, (u32, u64)) = bcs::from_bytes(&self.h.contents(tiers[0]))?;
            ensure!(recorded_tier == tier, "VenueConfig records the tier");
            self.report(format!("bluefin::prepare at {tier:?}: VenueConfig records the tier; then launch::new takes the cap"));
        }

        Ok(launch)
    }

    fn graduate(&mut self, launch: &Launch) -> Result<()> {
        let mut b = ProgrammableTransactionBuilder::new();
        let coin = self.quote_coin(&mut b, self.target() / 5 * 6)?;
        let launch_arg = self.shared(&mut b, launch.launch, true)?;
        let version = self.shared(&mut b, self.version, false)?;
        let runtime = self.shared(&mut b, self.runtime, false)?;
        let min_out = b.pure(1u64)?;
        let Argument::Result(bought) = call(
            &mut b,
            self.blast,
            "launch",
            "buy",
            self.pair(launch),
            vec![launch_arg, version, runtime, coin, min_out],
        ) else {
            unreachable!()
        };
        b.transfer_args(self.h.sender, vec![Argument::NestedResult(bought, 0), Argument::NestedResult(bought, 1)]);
        self.h.execute(b.finish())?.assert_success();
        ensure!(self.launch_lifecycle(launch) == MIGRATION_READY, "the launch is MigrationReady");

        Ok(())
    }

    /// The two-call migration: `launch::migrate` returns the launch's `Migration`, and the venue's
    /// `migrate` with `types` as its type arguments redeems it. Bluefin pays `creation_fee` SUI, or
    /// its live fee when none.
    fn migrate_command(
        &self,
        b: &mut ProgrammableTransactionBuilder,
        launch: &Launch,
        types: Vec<TypeTag>,
        creation_fee: Option<u64>,
    ) -> Result<()> {
        let launch_arg = self.shared(b, launch.launch, true)?;
        let migrators_version = self.shared(b, self.migrators_version, false)?;
        let version = self.shared(b, self.version, false)?;
        let config = self.shared(b, self.config, false)?;
        let currency = self.shared(b, launch.currency, true)?;
        let venue_config = self.shared(b, self.venue_config, false)?;
        let registry = self.shared(b, self.vault_stack.registry, true)?;
        let vault_version = self.vault_version(b)?;
        let treasury = self.shared(b, self.treasury, false)?;
        let clock = self.clock(b)?;
        let migration = call(
            b,
            self.blast,
            "launch",
            "migrate",
            self.pair(launch),
            vec![launch_arg, version, config, currency, clock],
        );
        if self.case.is_cetus() {
            let cetus_config = self.shared(b, self.venue("cetus_global_config"), false)?;
            let pools = self.shared(b, self.venue("cetus_pools"), true)?;
            let burn_manager = self.shared(b, self.venue("cetus_burn_manager"), true)?;
            call(
                b,
                self.migrators,
                "cetus",
                "migrate",
                types,
                vec![
                    migration,
                    migrators_version,
                    venue_config,
                    cetus_config,
                    pools,
                    burn_manager,
                    registry,
                    vault_version,
                    treasury,
                    clock,
                ],
            );
        } else {
            let quote_currency = self.shared(b, self.venue("sui_currency"), false)?;
            let bluefin_config = self.shared(b, self.venue("bluefin_global_config"), true)?;
            let fee = b.pure(creation_fee.map_or_else(|| self.bluefin_creation_fee(), Ok)?)?;
            let Argument::Result(fee) = b.command(Command::SplitCoins(Argument::GasCoin, vec![fee])) else {
                unreachable!()
            };
            call(
                b,
                self.migrators,
                "bluefin",
                "migrate",
                types,
                vec![
                    migration,
                    migrators_version,
                    venue_config,
                    currency,
                    quote_currency,
                    bluefin_config,
                    registry,
                    vault_version,
                    treasury,
                    Argument::NestedResult(fee, 0),
                    clock,
                ],
            );
        }

        Ok(())
    }

    /// `launch::migrate`, then the Cetus venue's `migrate` with that Migration, in Cetus's coin
    /// order for the pair.
    fn cetus_migrate_of_bluefin_hand_off(&self, b: &mut ProgrammableTransactionBuilder, launch: &Launch) -> Result<()> {
        let launch_arg = self.shared(b, launch.launch, true)?;
        let version = self.shared(b, self.version, false)?;
        let config = self.shared(b, self.config, false)?;
        let currency = self.shared(b, launch.currency, true)?;
        let clock = self.clock(b)?;
        let migration = call(b, self.blast, "launch", "migrate", self.pair(launch), vec![launch_arg, version, config, currency, clock]);
        let mut types = self.pair(launch);
        if meme_is_cetus_a(&launch.meme, &self.quote()) {
            types.extend([launch.meme.clone(), self.quote()]);
        } else {
            types.extend([self.quote(), launch.meme.clone()]);
        }
        let args = vec![
            migration,
            self.shared(b, self.migrators_version, false)?,
            self.shared(b, self.venue_config, false)?,
            self.shared(b, self.venue("cetus_global_config"), false)?,
            self.shared(b, self.venue("cetus_pools"), true)?,
            self.shared(b, self.venue("cetus_burn_manager"), true)?,
            self.shared(b, self.vault_stack.registry, true)?,
            self.vault_version(b)?,
            self.shared(b, self.treasury, false)?,
            clock,
        ];
        call(b, self.migrators, "cetus", "migrate", types, args);
        Ok(())
    }

    /// Bluefin's live SUI pool-creation fee from the snapshot's fee table.
    fn bluefin_creation_fee(&self) -> Result<u64> {
        let (_, _, fee): (ObjectID, String, u64) =
            bcs::from_bytes(&self.h.contents(self.venue("bluefin_pool_creation_fee_sui")))?;
        Ok(fee)
    }

    /// A migration that aborts after the pool exists commits nothing, and on Cetus coin types in the
    /// reversed order or naming another pair are refused.
    fn migration_failures_commit_nothing(&mut self, launch: &Launch) -> Result<()> {
        let mut watched = vec![launch.launch, launch.currency];
        if self.case.is_cetus() {
            watched.extend([self.venue("cetus_pools"), self.venue("cetus_burn_manager")]);
        } else {
            watched.push(self.venue("bluefin_global_config"));
        }
        let owners = [self.h.sender, DESTINATION.into(), LP_PROTOCOL.into()];
        let mut b = ProgrammableTransactionBuilder::new();
        self.migrate_command(&mut b, launch, self.route_types(launch), None)?;
        self.migrate_command(&mut b, launch, self.route_types(launch), None)?;
        let expected = Expected::Abort { package: self.blast, module: "launch", code: INVALID_LAUNCH_LIFECYCLE };
        self.h.assert_rolled_back(b.finish(), expected, &watched, &owners)?;
        ensure!(self.launch_lifecycle(launch) == MIGRATION_READY, "the launch stays MigrationReady");
        self.report("PTB [migrate (pool created, vault shared, residuals paid), migrate again]: launch aborts invalid_launch_lifecycle, nothing committed, launch MigrationReady".into());

        if !self.case.is_cetus() {
            // Bluefin charges exactly its configured SUI creation fee.
            let fee = self.bluefin_creation_fee()?;
            let mut b = ProgrammableTransactionBuilder::new();
            self.migrate_command(&mut b, launch, self.route_types(launch), Some(fee + 1))?;
            let expected = Expected::Abort { package: id(BLUEFIN), module: "pool", code: 1039 };
            self.h.assert_rolled_back(b.finish(), expected, &watched, &owners)?;
            self.report(format!("migrate paying {} MIST against the live {fee} MIST creation fee: Bluefin pool aborts 1039, rolled back", fee + 1));

            // The Bluefin launch's hand-off into the Cetus venue: the redeem refuses it before
            // the Cetus venue reads any tier or touches Cetus.
            let mut b = ProgrammableTransactionBuilder::new();
            self.cetus_migrate_of_bluefin_hand_off(&mut b, launch)?;
            let expected = Expected::Abort { package: self.core, module: "migration", code: WRONG_VENUE };
            let cetus_watched =
                [watched.clone(), vec![self.venue("cetus_pools"), self.venue("cetus_burn_manager")]].concat();
            self.h.assert_rolled_back(b.finish(), expected, &cetus_watched, &owners)?;
            self.report("launch::migrate then cetus::migrate with the Bluefin launch's Migration: blast_core::migration wrong_venue, rolled back".into());
        } else {
            let mut reversed = self.pool_pair(launch);
            reversed.reverse();
            let mut b = ProgrammableTransactionBuilder::new();
            self.migrate_command(&mut b, launch, [self.pair(launch), reversed].concat(), None)?;
            let expected = Expected::Abort { package: self.migrators, module: "cetus", code: INVALID_COIN_ORDER };
            self.h.assert_rolled_back(b.finish(), expected, &watched, &owners)?;
            self.report("migrate with the pool's coin types reversed: EInvalidCoinOrder, rolled back".into());

            // Another Quote, named in Cetus's own order, passes the order check but not the pair.
            let other = if self.quote() == sui() { tag(USDC) } else { sui() };
            let other_name = cetus_name(&other);
            let mut foreign = vec![launch.meme.clone(), other];
            if !meme_is_cetus_a(&foreign[0], &foreign[1]) {
                foreign.reverse();
            }
            let mut b = ProgrammableTransactionBuilder::new();
            self.migrate_command(&mut b, launch, [self.pair(launch), foreign].concat(), None)?;
            let expected = Expected::Abort { package: self.migrators, module: "cetus", code: WRONG_COIN_PAIR };
            self.h.assert_rolled_back(b.finish(), expected, &watched, &owners)?;
            self.report(format!("migrate naming Meme with {other_name} in Cetus order: EWrongCoinPair, rolled back"));
        }

        Ok(())
    }

    fn migrate(&mut self, launch: &Launch) -> Result<Migration> {
        let mut b = ProgrammableTransactionBuilder::new();
        self.migrate_command(&mut b, launch, self.route_types(launch), None)?;
        let outcome = self.h.execute(b.finish())?;
        outcome.assert_success();
        ensure!(self.launch_lifecycle(launch) == MIGRATED, "the launch is Migrated");
        for (object, owner) in outcome.effects.created() {
            ensure!(owner != Owner::AddressOwner(self.h.sender), "the caller received {}", object.0);
        }

        let migrated: Vec<Migrated> = self.launchpad_events(&outcome, "Migrated");
        ensure!(migrated.len() == 1 && migrated[0].launch_id == launch.launch);
        let migrated = &migrated[0];
        ensure!((migrated.meme, migrated.quote) == (LP_MEME, self.lp_quote()), "the hand-off is the pool share");
        // Project recipients are paid directly; Blast's migration fee enters the launch ledger.
        let paid: Vec<MigrationAllocationPaid> = self.launchpad_events(&outcome, "MigrationAllocationPaid");
        ensure!(paid.len() == 1 && paid[0].destination == DESTINATION.into());
        ensure!((paid[0].meme, paid[0].quote) == (ATOMIC_SUPPLY / 20, self.target() / 20));
        ensure!(
            outcome.coins_created_for(&self.h, DESTINATION.into())
                == self.coins(launch, paid[0].meme, paid[0].quote)
        );
        let accrued: Vec<ProtocolFeesAccrued> = self.launchpad_events(&outcome, "ProtocolFeesAccrued");
        ensure!(
            accrued.len() == 1
                && accrued[0].launch_id == launch.launch
                && (accrued[0].meme_amount, accrued[0].quote_amount)
                    == (ATOMIC_SUPPLY / 20, self.target() / 20)
        );

        let created: Vec<VaultCreated> = self.vault_events(&outcome, "VaultCreated");
        ensure!(created.len() == 1, "one VaultCreated");
        let created = &created[0];
        let venue = outcome
            .events
            .iter()
            .find(|event| event.type_.name.as_str() == "VaultCreated")
            .and_then(|event| event.type_.type_params.get(2))
            .map(|venue| venue.to_canonical_string(true))
            .context("VaultCreated venue")?;
        ensure!(venue.ends_with(&format!("::{}::Venue", self.case.module())), "{venue}");
        // The launch sealed the terms: its fee split, Blast's share from the launch config, no
        // partner, and residuals paid to Blast.
        let terms = &created.terms;
        ensure!(terms.origin == launch.launch && terms.fee_split == launch.split);
        ensure!(terms.package_witness.ends_with("::blast_fun::PackageWitness"), "{}", terms.package_witness);
        ensure!((terms.protocol_meme_bps, terms.protocol_quote_bps) == DEFAULT_SHARES);
        ensure!(terms.partner_id.is_none() && terms.residuals == ResidualPolicy::Protocol);
        let vault_id = created.vault_id;
        let issuer = tag(&format!("{}::blast_fun::PackageWitness", self.blast));
        ensure!(terms.package_witness == issuer.to_canonical_string(false), "{}", terms.package_witness);
        ensure!(
            vault_id == self.vault_stack.vault_id(&issuer, launch.launch)?,
            "the vault ID derives from the VaultRegistry, the launchpad's witness, and the launch"
        );
        ensure!(self.h.object(vault_id).is_shared() && self.h.object(created.pool_id).is_shared());
        let residual = (created.residual_meme_amount, created.residual_quote_amount);
        let supplied = (migrated.meme - residual.0, migrated.quote - residual.1);
        let m = Migration {
            pool: created.pool_id,
            vault: vault_id,
            position: created.position_id,
            auto_lp_position: None,
            liquidity: created.liquidity,
            residual,
        };
        let vault = self.vault(&m)?;
        ensure!(vault.pool_id == m.pool && vault.terms == *terms && vault.fee_split.value == launch.split);
        ensure!(vault.protocol_bps.value == DEFAULT_SHARES && vault.protocol_bps.delay_ms == VAULT_FEE_DELAY_MS);
        ensure!(vault.fee_split.delay_ms == VAULT_FEE_DELAY_MS && vault.fee_split.pending.is_none());
        // Residuals go to the treasury at once: the ledger keeps nothing.
        ensure!((vault.protocol.meme, vault.protocol.quote, vault.protocol.sui) == (0, 0, 0));
        ensure!(outcome.coins_created_for(&self.h, LP_PROTOCOL.into()) == self.coins(launch, residual.0, residual.1));
        let paid_to_treasury: Vec<ProtocolFeesPaid> =
            self.package_events(&outcome, self.core, "blast_core_events", "ProtocolFeesPaid");
        if residual == (0, 0) {
            ensure!(paid_to_treasury.is_empty());
        } else {
            ensure!(paid_to_treasury.len() == 1);
            let paid = &paid_to_treasury[0];
            ensure!(paid.origin == vault_id && paid.treasury == LP_PROTOCOL.into() && paid.partner_id.is_none());
            ensure!((paid.meme_amount, paid.quote_amount, paid.sui_amount) == (residual.0, residual.1, 0));
        }
        // The position (the burn proof on Cetus) is the vault's dynamic object field.
        let Owner::ObjectOwner(field) = self.h.object(m.position).owner().clone() else {
            bail!("position is not a child")
        };
        ensure!(*self.h.object(field.into()).owner() == Owner::ObjectOwner(vault_id.into()));
        let field_type = self.h.object(field.into()).data.try_as_move().context("field")?.type_().to_string();
        ensure!(
            field_type.contains("::vault::PositionKey<")
                && field_type.contains(&format!("::{}::Venue", self.case.module()))
        );
        ensure!(self.position_liquidity(m.position)? == m.liquidity && m.liquidity > 0);

        let (lower, upper, sqrt_price) = if self.case.is_cetus() {
            let pools: Vec<CreatePool> = venue_events(&outcome, "factory", "CreatePoolEvent");
            ensure!(pools.len() == 1 && pools[0].pool_id == m.pool && pools[0].tick_spacing == self.cetus_tier.0);
            let state = self.cetus_pool(&m)?;
            ensure!(
                (state.tick_spacing, state.fee_rate) == self.cetus_tier,
                "pool at the launch's tier"
            );
            ensure!(state.liquidity == m.liquidity);
            let (pool_meme, pool_quote) =
                if self.case.meme_is_a() { (state.coin_a, state.coin_b) } else { (state.coin_b, state.coin_a) };
            ensure!(
                (pool_meme, pool_quote) == supplied,
                "the pool holds exactly the supply"
            );
            let opened: Vec<CetusOpenPosition> = venue_events(&outcome, "pool", "OpenPositionEvent");
            ensure!(opened.len() == 1);
            // Burned: LP Burn wraps the position in the proof the vault holds and records it.
            let proof: BurnProof = bcs::from_bytes(&self.h.contents(m.position))?;
            ensure!(proof.position.id == opened[0].position && proof.position.pool == m.pool);
            ensure!(self.h.is_type(m.position, "lp_burn", "CetusLPBurnProof"));
            let burned: Vec<BurnPosition> = venue_events(&outcome, "lp_burn", "BurnPositionEvent");
            ensure!(burned.len() == 1);
            ensure!(
                (burned[0].position_id, burned[0].burned_position_id, burned[0].pool_id)
                    == (proof.position.id, m.position, m.pool)
            );
            let record = outcome
                .created(&self.h, "dynamic_field", "Field")
                .into_iter()
                .filter_map(|field| bcs::from_bytes::<BurnRecord>(&self.h.contents(field)).ok())
                .find(|record| record.name == proof.position.id)
                .context("BurnManager record")?;
            ensure!(
                (record.burned_position_id, record.position_id, record.pool_id)
                    == (m.position, proof.position.id, m.pool)
            );
            (opened[0].tick_lower as i32, opened[0].tick_upper as i32, state.sqrt_price)
        } else {
            let pools: Vec<BluefinPoolCreated> = venue_events(&outcome, "events", "PoolCreated");
            ensure!(pools.len() == 1 && pools[0].id == m.pool);
            ensure!(
                (pools[0].tick_spacing, pools[0].fee_rate) == (BLUEFIN_TICK_SPACING, BLUEFIN_FEE_RATE),
                "pool at the launch's tier"
            );
            let provided: Vec<LiquidityProvided> = venue_events(&outcome, "events", "LiquidityProvided");
            ensure!(provided.len() == 1 && provided[0].position_id == m.position);
            ensure!(
                (provided[0].coin_a_amount, provided[0].coin_b_amount) == supplied
            );
            ensure!(
                (provided[0].pool_coin_a_amount, provided[0].pool_coin_b_amount) == supplied
            );
            ensure!(provided[0].after_liquidity == m.liquidity);
            ensure!(self.h.is_type(m.position, "position", "Position"));
            (provided[0].lower_tick as i32, provided[0].upper_tick as i32, pools[0].current_sqrt_price)
        };
        let spacing = if self.case.is_cetus() { self.cetus_tier.0 } else { BLUEFIN_TICK_SPACING } as i32;
        ensure!(lower == -(443_636 / spacing * spacing) && upper == 443_636 / spacing * spacing, "full range");
        ensure!(
            sqrt_price == expected_sqrt_price(LP_MEME, self.lp_quote(), self.case.meme_is_a()),
            "the opening price is the exact Q64.64 ratio of the hand-off"
        );

        self.report(format!(
            "migrate ({:?}): pool {} tier ({}, {}) ticks ({lower}, {upper}) sqrt_price {sqrt_price}; supplied=({}, {}) residual=({}, {}) paid to the treasury; liquidity {}; Blast and recipient allocations ({}, {}) each paid; {}",
            self.case,
            m.pool,
            if self.case.is_cetus() { self.cetus_tier.0 } else { BLUEFIN_TICK_SPACING },
            if self.case.is_cetus() { self.cetus_tier.1 } else { BLUEFIN_FEE_RATE },
            supplied.0,
            supplied.1,
            residual.0,
            residual.1,
            m.liquidity,
            paid[0].meme,
            paid[0].quote,
            if self.case.is_cetus() { "position burned by LP Burn, proof in the vault, BurnManager record created" } else { "position in the vault" },
        ));

        Ok(m)
    }

    fn coins(&self, launch: &Launch, meme: u64, quote: u64) -> Vec<(String, u64)> {
        let mut coins =
            vec![(launch.meme.to_canonical_string(true), meme), (self.quote().to_canonical_string(true), quote)];
        coins.retain(|(_, value)| *value > 0);
        coins.sort();
        coins
    }

    fn cetus_pool(&self, m: &Migration) -> Result<CetusPoolState> {
        CetusPoolState::of(&self.h, m.pool)
    }

    /// Swaps `amount` into the pool from a fresh coin, all the way through.
    fn swap(&mut self, launch: &Launch, m: &Migration, side: Side, amount: u64) -> Result<()> {
        let mut b = ProgrammableTransactionBuilder::new();
        let pool_pair = self.pool_pair(launch);
        let input_is_a = matches!(side, Side::MemeIn) == self.case.meme_is_a();
        let source = match side {
            Side::QuoteIn => self.quote_coin(&mut b, amount)?,
            Side::MemeIn => {
                let coin = b.obj(self.h.owned(self.meme_coin(launch)?))?;
                let amount = b.pure(amount)?;
                let Argument::Result(split) = b.command(Command::SplitCoins(coin, vec![amount])) else {
                    unreachable!()
                };
                Argument::NestedResult(split, 0)
            }
        };
        let pool = self.shared(&mut b, m.pool, true)?;
        let clock = self.clock(&mut b)?;
        let a2b = b.pure(input_is_a)?;
        let by_amount_in = b.pure(true)?;
        let amount_arg = b.pure(amount)?;
        let (input_type, other_type) = if input_is_a {
            (pool_pair[0].clone(), pool_pair[1].clone())
        } else {
            (pool_pair[1].clone(), pool_pair[0].clone())
        };
        let input = call(&mut b, SUI_FRAMEWORK_PACKAGE_ID, "coin", "into_balance", vec![input_type], vec![source]);
        let zero = call(&mut b, SUI_FRAMEWORK_PACKAGE_ID, "balance", "zero", vec![other_type], vec![]);
        let (balance_a, balance_b) = if input_is_a { (input, zero) } else { (zero, input) };
        let outputs = if self.case.is_cetus() {
            let config = self.shared(&mut b, self.venue("cetus_global_config"), false)?;
            let limit = b.pure(if input_is_a { CETUS_MIN_SQRT_PRICE } else { CETUS_MAX_SQRT_PRICE })?;
            let Argument::Result(flash) = call(
                &mut b,
                id(CETUS),
                "pool",
                "flash_swap",
                pool_pair.clone(),
                vec![config, pool, a2b, by_amount_in, amount_arg, limit, clock],
            ) else {
                unreachable!()
            };
            call(
                &mut b,
                id(CETUS),
                "pool",
                "repay_flash_swap",
                pool_pair.clone(),
                vec![config, pool, balance_a, balance_b, Argument::NestedResult(flash, 2)],
            );
            vec![Argument::NestedResult(flash, 0), Argument::NestedResult(flash, 1)]
        } else {
            let config = self.shared(&mut b, self.venue("bluefin_global_config"), false)?;
            let limit = b.pure(if input_is_a { BLUEFIN_MIN_SQRT_PRICE + 1 } else { BLUEFIN_MAX_SQRT_PRICE - 1 })?;
            let zero_limit = b.pure(0u64)?;
            let Argument::Result(swapped) = call(
                &mut b,
                id(BLUEFIN),
                "pool",
                "swap",
                pool_pair.clone(),
                vec![clock, config, pool, balance_a, balance_b, a2b, by_amount_in, amount_arg, zero_limit, limit],
            ) else {
                unreachable!()
            };
            vec![Argument::NestedResult(swapped, 0), Argument::NestedResult(swapped, 1)]
        };
        let mut coins = Vec::new();
        for (output, coin_type) in outputs.into_iter().zip(pool_pair) {
            coins.push(call(&mut b, SUI_FRAMEWORK_PACKAGE_ID, "coin", "from_balance", vec![coin_type], vec![output]));
        }
        b.transfer_args(self.h.sender, coins);
        self.h.execute(b.finish())?.assert_success();

        Ok(())
    }

    /// `collect_fees` against `pool`, or with `update` the settled split update under its cap.
    fn collect_pt(
        &self,
        launch: &Launch,
        m: &Migration,
        pool: ObjectID,
        update: Option<(ObjectID, &FeeSplit)>,
    ) -> Result<ProgrammableTransaction> {
        let mut b = ProgrammableTransactionBuilder::new();
        let vault = self.shared(&mut b, m.vault, true)?;
        let migrators_version = self.shared(&mut b, self.migrators_version, false)?;
        let vault_version = self.vault_version(&mut b)?;
        let treasury = self.shared(&mut b, self.treasury, false)?;
        let mut args = vec![vault, migrators_version, vault_version, treasury];
        args.push(self.shared(&mut b, launch.currency, true)?);
        let venue_config = if self.case.is_cetus() {
            let config = self.shared(&mut b, self.venue("cetus_global_config"), false)?;
            args.push(config);
            args.push(self.shared(&mut b, self.venue("cetus_burn_manager"), false)?);
            config
        } else {
            let config = self.shared(&mut b, self.venue("bluefin_global_config"), false)?;
            args.push(config);
            config
        };
        let pool = self.shared(&mut b, pool, true)?;
        args.push(pool);
        let clock = self.clock(&mut b)?;
        let function = match update {
            Some(_) => "settle_and_apply_fee_split",
            None => "collect_fees",
        };
        // Cetus's `collect_fees` neither compounds nor applies a split, so it takes no Clock.
        if !(self.case.is_cetus() && update.is_none()) {
            args.push(clock);
        }
        call(&mut b, self.migrators, self.case.module(), function, self.route_types(launch), args);
        // Collection leaves the auto-LP share waiting; compounding is its own permissionless route,
        // appended here so one PTB collects and adds, as a collection worker would, and the auto-LP
        // assertions read the same outcome.
        call(
            &mut b,
            self.migrators,
            self.case.module(),
            "compound_auto_lp",
            self.route_types(launch),
            vec![vault, migrators_version, vault_version, venue_config, pool, clock],
        );

        Ok(b.finish())
    }

    /// Appends `launch::prove_owner` with the curve-fee cap `cap`, returning the owner proof.
    fn prove_owner(&self, b: &mut ProgrammableTransactionBuilder, launch: &Launch, cap: ObjectID) -> Result<Argument> {
        let launch_arg = self.shared(b, launch.launch, false)?;
        let version = self.shared(b, self.version, false)?;
        let cap = b.obj(self.h.owned(cap))?;

        Ok(call(b, self.blast, "launch", "prove_owner", self.pair(launch), vec![launch_arg, version, cap]))
    }

    /// Proposes `split` on the vault with an owner proof from `cap`; the vault's delay is fixed.
    fn schedule_fee_split_pt(&self, launch: &Launch, m: &Migration, cap: ObjectID, split: &FeeSplit) -> Result<ProgrammableTransaction> {
        let mut b = ProgrammableTransactionBuilder::new();
        let proof = self.prove_owner(&mut b, launch, cap)?;
        let args = vec![self.shared(&mut b, m.vault, true)?, proof, self.vault_version(&mut b)?,
            split.arg(&mut b, self.core)?, self.clock(&mut b)?];
        call(&mut b, self.vault_package(), "vault", "schedule_fee_split", self.pair(launch), args);
        Ok(b.finish())
    }

    /// Cancels the vault's pending split with an owner proof from `cap`.
    fn cancel_fee_split_pt(&self, launch: &Launch, m: &Migration, cap: ObjectID) -> Result<ProgrammableTransaction> {
        let mut b = ProgrammableTransactionBuilder::new();
        let proof = self.prove_owner(&mut b, launch, cap)?;
        let args = vec![self.shared(&mut b, m.vault, true)?, proof, self.vault_version(&mut b)?];
        call(&mut b, self.vault_package(), "vault", "cancel_fee_split", self.pair(launch), args);
        Ok(b.finish())
    }

    /// A permissionless collection, or with `update` an owner-proved schedule followed by ready
    /// settlement; checks every amount against the venue's collection, Blast's vault share, and
    /// the vault's split.
    fn collect(
        &mut self,
        launch: &Launch,
        m: &mut Migration,
        update: Option<(ObjectID, &FeeSplit)>,
    ) -> Result<Collection> {
        let watched_payees = [self.h.sender, LP_PROTOCOL.into(), RECIPIENT_C.into()];
        if let Some((cap, split)) = update {
            let before = self.vault(m)?.fee_split;
            let scheduled = self.schedule_fee_split_pt(launch, m, cap, split)?;
            self.h.execute(scheduled)?.assert_success();
            let pending = self.vault(m)?.fee_split;
            ensure!(pending.value == before.value && pending.delay_ms == before.delay_ms);
            ensure!(pending.pending.as_ref().is_some_and(|p| p.value == *split && p.delay_ms == VAULT_FEE_DELAY_MS));
            // Seed only fixture version bytes; the public wrapper must reject before readiness.
            let original = self.h.object(self.migrators_version);
            let (id, valid, paused, witness, _): GenericPackageVersionContents =
                bcs::from_bytes(&self.h.contents(self.migrators_version))?;
            let mut stale = original.clone();
            stale.data.try_as_move_mut().expect("PackageVersion")
                .set_contents_unsafe(bcs::to_bytes(&(id, valid, paused, witness, 2u64))?);
            self.h.insert(stale);
            let stale_apply = self.collect_pt(launch, m, m.pool, update)?;
            self.h.assert_rolled_back(stale_apply, Expected::Abort {package: self.admin, module: "package_version", code: 9},
                &[m.vault, m.pool, launch.currency], &watched_payees)?;
            self.h.insert(original);
            let early = self.collect_pt(launch, m, m.pool, update)?;
            let expected = Expected::Abort { package: self.admin, module: "delayed", code: 13 };
            self.h.assert_rolled_back(early, expected, &[m.vault, m.pool, launch.currency], &watched_payees)?;
            self.h.sim.advance_clock(std::time::Duration::from_millis(before.delay_ms));
            // A later failing command must roll back the ready application, venue collection,
            // payouts, and proposal consumption together.
            // The apply is the PTB's first command; compounding follows it. A second apply finds
            // no pending proposal.
            let mut rollback = self.collect_pt(launch, m, m.pool, update)?;
            rollback.commands.push(rollback.commands.first().expect("apply").clone());
            let expected = Expected::Abort { package: self.admin, module: "delayed", code: 14 };
            self.h.assert_rolled_back(rollback, expected, &[m.vault, m.pool, launch.currency], &watched_payees)?;
        }
        let before = self.vault(m)?;
        let auto_before = match m.auto_lp_position {
            Some(position) => self.position_liquidity(position)?,
            None => 0,
        };
        let liquidity_before = self.position_liquidity(m.position)?;

        let pt = self.collect_pt(launch, m, m.pool, update)?;
        let outcome = self.h.execute(pt)?;
        outcome.assert_success();

        // Gross: exactly what the venue paid out for the vault's positions.
        let (venue_a, venue_b) = if self.case.is_cetus() {
            let collected: Vec<CetusCollectFee> = venue_events(&outcome, "pool", "CollectFeeEvent");
            let expected = 1 + usize::from(m.auto_lp_position.is_some());
            ensure!(collected.len() == expected, "collects the burned and any auto-LP position");
            ensure!(collected.iter().all(|event| event.pool == m.pool));
            collected.iter().fold((0, 0), |(a, b), event| (a + event.amount_a, b + event.amount_b))
        } else {
            let collected: Vec<UserFeeCollected> = venue_events(&outcome, "events", "UserFeeCollected");
            ensure!(collected.len() == 1 && collected[0].position_id == m.position);
            (collected[0].coin_a_amount, collected[0].coin_b_amount)
        };
        let (venue_meme, venue_quote) = if self.case.meme_is_a() { (venue_a, venue_b) } else { (venue_b, venue_a) };
        let fees: Vec<FeesCollected> = self.vault_events(&outcome, "FeesCollected");
        ensure!(fees.len() == 1, "one FeesCollected");
        let fees = fees[0].clone();
        ensure!((fees.gross_meme, fees.gross_quote) == (venue_meme, venue_quote), "gross is the venue's collection");
        ensure!(fees.vault_id == m.vault);

        // Blast's vault share, rounded up, then the split apportioned exactly in route order.
        ensure!(before.protocol_bps.value == self.shares, "the vault's applied share");
        let expected = expected_fees(&before, venue_meme, venue_quote);
        ensure!(fees == expected, "FeesCollected {fees:?} != expected {expected:?}");
        let split = before.fee_split.value.clone();
        let part = |destination: &Destination| route_part(&split, &fees, destination);
        let mut payees: BTreeMap<SuiAddress, (u64, u64)> = BTreeMap::new();
        // Blast's share goes to the treasury at once, since the launch named no partner.
        *payees.entry(LP_PROTOCOL.into()).or_default() = (fees.protocol_meme, fees.protocol_quote);
        // A fixed supply's burn-route Meme goes to `@0x0`; a burn-only supply burns it natively.
        let burn = part(&Destination::Burn);
        *payees.entry(SuiAddress::ZERO).or_default() = (if self.burnable { 0 } else { burn.0 }, 0);
        for route in &split.routes {
            if let Destination::Address(recipient) = route.destination {
                let entry = payees.entry(recipient).or_default();
                let (meme, quote) = part(&route.destination);
                entry.0 += meme;
                entry.1 += quote;
            }
        }
        for (payee, (meme, quote)) in payees {
            ensure!(outcome.coins_created_for(&self.h, payee) == self.coins(launch, meme, quote), "{payee} paid");
        }
        let after = self.vault(m)?;
        ensure!((after.protocol.meme, after.protocol.quote) == (0, 0), "the ledger pays out at once");

        // Auto-LP: added amounts are what the venue took; the rest waits.
        let added: Vec<AutoLiquidityAdded> = self.vault_events(&outcome, "AutoLiquidityAdded");
        ensure!(added.len() <= 1);
        let added = added.into_iter().next();
        let auto_lp = part(&Destination::AutoLp);
        let offered = (before.auto_lp_meme + auto_lp.0, before.auto_lp_quote + auto_lp.1);
        let taken = added.as_ref().map_or((0, 0), |a| (a.meme_amount, a.quote_amount));
        ensure!(
            (after.auto_lp_meme, after.auto_lp_quote) == (offered.0 - taken.0, offered.1 - taken.1),
            "the rest waits"
        );
        let owner = part(&Destination::Owner);
        ensure!((after.owner_meme, after.owner_quote) == (before.owner_meme + owner.0, before.owner_quote + owner.1));
        let rewards = part(&Destination::HolderRewards);
        ensure!(
            (after.rewards_meme, after.rewards_quote) == (before.rewards_meme + rewards.0, before.rewards_quote + rewards.1)
        );
        ensure!(after.burn_quote == before.burn_quote + burn.1, "the burn Quote waits for a buyback");
        let opened: Vec<AutoLpPositionOpened> = self.vault_events(&outcome, "AutoLpPositionOpened");
        let liquidity_after = self.position_liquidity(m.position)?;
        if let Some(added) = &added {
            ensure!((added.auto_lp_meme_pending, added.auto_lp_quote_pending) == (after.auto_lp_meme, after.auto_lp_quote));
            ensure!(added.meme_amount > 0 || added.quote_amount > 0);
            let position = if self.case.is_cetus() {
                // Cetus: the burned position cannot grow, so auto-LP opens its own position once.
                if m.auto_lp_position.is_none() {
                    ensure!(opened.len() == 1, "the first add opens the auto-LP position");
                    let position = opened[0].position_id;
                    ensure!(outcome.created(&self.h, "position", "Position") == vec![position]);
                    let Owner::ObjectOwner(field) = self.h.object(position).owner().clone() else { bail!("child") };
                    ensure!(*self.h.object(field.into()).owner() == Owner::ObjectOwner(m.vault.into()));
                    m.auto_lp_position = Some(position);
                } else {
                    ensure!(
                        opened.is_empty() && outcome.created(&self.h, "position", "Position").is_empty(),
                        "later adds reuse it"
                    );
                }
                ensure!(liquidity_after == liquidity_before, "the burned position never changes");
                let provided: Vec<CetusAddLiquidity> = venue_events(&outcome, "pool", "AddLiquidityV2Event");
                ensure!(provided.len() == 1 && Some(provided[0].position) == m.auto_lp_position);
                let (meme, quote) = if self.case.meme_is_a() {
                    (provided[0].amount_a, provided[0].amount_b)
                } else {
                    (provided[0].amount_b, provided[0].amount_a)
                };
                ensure!((meme, quote) == (added.meme_amount, added.quote_amount), "added is what Cetus took");
                let position = m.auto_lp_position.expect("auto-LP position");
                ensure!(
                    self.position_liquidity(position)? == auto_before + provided[0].liquidity
                        && provided[0].liquidity > 0
                );
                position
            } else {
                // Bluefin: auto-LP grows the migration position.
                let provided: Vec<LiquidityProvided> = venue_events(&outcome, "events", "LiquidityProvided");
                ensure!(provided.len() == 1 && provided[0].position_id == m.position);
                ensure!(
                    (provided[0].coin_a_amount, provided[0].coin_b_amount) == (added.meme_amount, added.quote_amount)
                );
                ensure!(provided[0].liquidity > 0 && liquidity_after == liquidity_before + provided[0].liquidity);
                m.position
            };
            self.report(format!(
                "auto-LP added ({}, {}) to {position}, pending ({}, {}), position liquidity {}",
                added.meme_amount,
                added.quote_amount,
                added.auto_lp_meme_pending,
                added.auto_lp_quote_pending,
                self.position_liquidity(position)?,
            ));
        } else {
            ensure!(opened.is_empty() && liquidity_after == liquidity_before, "nothing added");
        }
        ensure!(!self.case.is_cetus() || liquidity_after == m.liquidity, "the burned position keeps its liquidity");

        let names = package_event_names(&outcome, self.vault_package());
        if let Some((_, split)) = update {
            // The primitive records the split change after the venue settled the old split's fees.
            let changed: Vec<DelayedApplied<FeeSplit>> = outcome.delayed("DelayedApplied", "vault", "FeeSplitKey")?;
            ensure!(changed.len() == 1, "{names:?}");
            ensure!(names.first().map(String::as_str) == Some("FeesCollected"), "settles first: {names:?}");
            ensure!(fee_split_applied_after_settlement(&outcome, self.vault_package()), "settles before applying");
            let changed = &changed[0];
            ensure!(changed.owner == m.vault && changed.previous_value == before.fee_split.value && changed.value == *split);
            ensure!(after.fee_split.value == *split && after.fee_split.pending.is_none() && changed.delay_ms == after.fee_split.delay_ms);
        } else {
            ensure!(after.fee_split == before.fee_split);
        }

        Ok(Collection { fees, split, added })
    }

    /// Blast's per-vault share: a `blast_core` fee administrator schedules it on the vault, and
    /// anyone applies it after the vault's fixed delay; it applies from the next collection.
    fn set_vault_shares(&mut self, launch: &Launch, m: &Migration, shares: (u64, u64)) -> Result<()> {
        let mut b = ProgrammableTransactionBuilder::new();
        let signed_in = self.sign_in_core(&mut b, "FeeAdmin")?;
        let vault = self.shared(&mut b, m.vault, true)?;
        let vault_version = self.vault_version(&mut b)?;
        let meme_bps = self.bps(&mut b, shares.0)?;
        let quote_bps = self.bps(&mut b, shares.1)?;
        let clock = self.clock(&mut b)?;
        call(&mut b, self.vault_package(), "vault", "schedule_protocol_bps", self.pair(launch),
            vec![vault, signed_in, vault_version, meme_bps, quote_bps, clock]);
        self.h.execute(b.finish())?.assert_success();
        let pending = self.vault(m)?.protocol_bps;
        ensure!(pending.value == self.shares && pending.pending.as_ref().is_some_and(|p| p.value == shares));
        let change = (self.vault_package(), "vault", "apply_protocol_bps", self.pair(launch), m.vault, self.vault_stack.version);
        blast_launchpad_ptb_tests::apply_admin_changes(&mut self.h, vec![change])?;
        ensure!(self.vault(m)?.protocol_bps.value == shares, "the share applies after the delay");

        self.shares = shares;

        Ok(())
    }

    /// The creator claims both capabilities and keeps the live curve-fee cap.
    fn claim_curve_fee_cap(&mut self, launch: &Launch) -> Result<ObjectID> {
        let mut b = ProgrammableTransactionBuilder::new();
        let launch_arg = self.shared(&mut b, launch.launch, true)?;
        let version = self.shared(&mut b, self.version, false)?;
        let runtime = self.shared(&mut b, self.runtime, false)?;
        let none = b.pure(Option::<Vec<u8>>::None)?;
        let clock = self.clock(&mut b)?;
        let Argument::Result(caps) = call(
            &mut b,
            self.blast,
            "launch",
            "claim_creator_caps",
            self.pair(launch),
            vec![launch_arg, version, runtime, none, clock],
        ) else {
            unreachable!()
        };
        b.transfer_args(self.h.sender, vec![Argument::NestedResult(caps, 0), Argument::NestedResult(caps, 1)]);
        let outcome = self.h.execute(b.finish())?;
        outcome.assert_success();
        let cap = outcome.created(&self.h, "creator_authority", "CurveFeeCap");
        ensure!(cap.len() == 1);

        Ok(cap[0])
    }

    /// Claims the vault's owner balances with an owner proof from `cap`.
    fn claim_owner_balances_pt(&self, launch: &Launch, m: &Migration, cap: ObjectID) -> Result<ProgrammableTransaction> {
        let mut b = ProgrammableTransactionBuilder::new();
        let proof = self.prove_owner(&mut b, launch, cap)?;
        let vault = self.shared(&mut b, m.vault, true)?;
        let vault_version = self.vault_version(&mut b)?;
        let Argument::Result(claimed) = call(
            &mut b,
            self.vault_package(),
            "vault",
            "claim_owner_balances",
            self.pair(launch),
            vec![vault, proof, vault_version],
        ) else {
            unreachable!()
        };
        b.transfer_args(self.h.sender, vec![Argument::NestedResult(claimed, 0), Argument::NestedResult(claimed, 1)]);

        Ok(b.finish())
    }

    fn claim_owner_balances(&mut self, launch: &Launch, m: &Migration, cap: ObjectID) -> Result<()> {
        let before = self.vault(m)?;
        ensure!(before.owner_meme > 0 && before.owner_quote > 0, "the owner route accrued");
        let pt = self.claim_owner_balances_pt(launch, m, cap)?;
        let outcome = self.h.execute(pt)?;
        outcome.assert_success();
        let claimed: Vec<OwnerBalancesClaimed> = self.vault_events(&outcome, "OwnerBalancesClaimed");
        ensure!(
            claimed.len() == 1
                && claimed[0].vault_id == m.vault
                && (claimed[0].meme_amount, claimed[0].quote_amount) == (before.owner_meme, before.owner_quote)
        );
        ensure!(
            outcome.coins_created_for(&self.h, self.h.sender)
                == self.coins(launch, before.owner_meme, before.owner_quote)
        );
        let after = self.vault(m)?;
        ensure!((after.owner_meme, after.owner_quote) == (0, 0));
        self.report(format!(
            "claim_owner_balances with a proof from the live cap: ({}, {})",
            before.owner_meme, before.owner_quote
        ));

        Ok(())
    }

    /// An administrator reassigns both caps through recipient-only schedules; the creator's old
    /// curve-fee cap can no longer prove ownership to schedule, cancel or claim, while an accepted
    /// ready split still applies.
    fn retired_cap_is_refused(
        &mut self,
        launch: &Launch,
        m: &Migration,
        cap: ObjectID,
        split: &FeeSplit,
    ) -> Result<()> {
        let next = shifted(split, Destination::Owner, Destination::HolderRewards, 1_000);
        let proposal = self.schedule_fee_split_pt(launch, m, cap, &next)?;
        self.h.execute(proposal)?.assert_success();
        let mut b = ProgrammableTransactionBuilder::new();
        let signed_in = self.sign_in(&mut b, "CreatorAdmin")?;
        let launch_arg = self.shared(&mut b, launch.launch, true)?;
        let version = self.shared(&mut b, self.version, false)?;
        let recipient = b.pure(SuiAddress::from(CAP_HOLDER))?;
        let clock = self.clock(&mut b)?;
        for name in ["schedule_curve_fee_cap_reassignment", "schedule_creator_metadata_cap_reassignment"] {
            call(&mut b, self.blast, "launch", name, self.pair(launch),
                vec![launch_arg, version, signed_in, recipient, clock]);
        }
        let scheduled = self.h.execute(b.finish())?;
        scheduled.assert_success();
        ensure!(scheduled.payload_names(self.blast).is_empty());
        for key in ["CurveFeeCapReassignment", "CreatorMetadataCapReassignment"] {
            let proposals: Vec<ActionScheduled<SuiAddress>> = scheduled.delayed("ActionScheduled", "launch", key)?;
            ensure!(proposals.len() == 1);
            ensure!(proposals[0].owner == launch.launch && proposals[0].change == Change::Action(SuiAddress::from(CAP_HOLDER)));
            ensure!(proposals[0].delay_ms == 172_800_000, "recipient-only schedules retain the applied delay");
        }
        let pair = self.pair(launch);
        blast_launchpad_ptb_tests::apply_admin_changes(&mut self.h, vec![
            (self.blast, "launch", "apply_curve_fee_cap_reassignment", pair.clone(), launch.launch, self.version),
            (self.blast, "launch", "apply_creator_metadata_cap_reassignment", pair, launch.launch, self.version),
        ])?;

        let owners = [self.h.sender, LP_PROTOCOL.into(), RECIPIENT_C.into()];
        let blast = self.blast;
        let refused = || Expected::Abort { package: blast, module: "launch", code: CREATOR_CAP_NOT_LIVE };
        ensure!(self.vault(m)?.fee_split.value == *split, "cap rotation does not activate the ready proposal");
        let pt = self.schedule_fee_split_pt(launch, m, cap, &next)?;
        self.h.assert_rolled_back(pt, refused(), &[m.vault, m.pool, cap, launch.currency], &owners)?;
        let pt = self.cancel_fee_split_pt(launch, m, cap)?;
        self.h.assert_rolled_back(pt, refused(), &[m.vault, cap], &owners)?;
        let pt = self.claim_owner_balances_pt(launch, m, cap)?;
        self.h.assert_rolled_back(pt, refused(), &[m.vault, cap], &owners)?;
        let pt = self.collect_pt(launch, m, m.pool, Some((cap, &next)))?;
        let applied = self.h.execute(pt)?;
        applied.assert_success();
        let changes: Vec<DelayedApplied<FeeSplit>> = applied.delayed("DelayedApplied", "vault", "FeeSplitKey")?;
        ensure!(changes.len() == 1 && changes[0].previous_value == *split && changes[0].value == next);
        let active = self.vault(m)?.fee_split;
        ensure!(active.value == next && active.pending.is_none());
        self.report("after cap reassignment the retired cap cannot prove ownership to schedule, cancel or claim; accepted ready split applies without an owner proof".into());

        Ok(())
    }

    fn buyback_pt(
        &self,
        launch: &Launch,
        m: &Migration,
        pool: ObjectID,
        quote_in: u64,
        min_meme_out: u64,
    ) -> Result<ProgrammableTransaction> {
        let mut b = ProgrammableTransactionBuilder::new();
        let signed_in = self.sign_in_core(&mut b, "BuybackAdmin")?;
        let vault = self.shared(&mut b, m.vault, true)?;
        let migrators_version = self.shared(&mut b, self.migrators_version, false)?;
        let vault_version = self.vault_version(&mut b)?;
        let currency = self.shared(&mut b, launch.currency, true)?;
        let config = if self.case.is_cetus() { "cetus_global_config" } else { "bluefin_global_config" };
        let config = self.shared(&mut b, self.venue(config), false)?;
        let pool = self.shared(&mut b, pool, true)?;
        let quote_in = b.pure(quote_in)?;
        let min_meme_out = b.pure(min_meme_out)?;
        let clock = self.clock(&mut b)?;
        call(
            &mut b,
            self.migrators,
            self.case.module(),
            "buyback_and_burn",
            self.route_types(launch),
            vec![vault, migrators_version, vault_version, signed_in, currency, config, pool, quote_in, min_meme_out, clock],
        );

        Ok(b.finish())
    }

    /// The buyback administrator swaps the vault's burn Quote for Meme in its pool and burns it: a
    /// minimum above what the pool returns rolls back, and a met minimum spends every waiting Quote
    /// and sends the Meme bought to `@0x0`, since the fixture's supply is fixed.
    fn buyback(&mut self, launch: &Launch, m: &Migration) -> Result<()> {
        let before = self.vault(m)?;
        ensure!(before.burn_quote > 0, "burn Quote accrued");
        let owners = [self.h.sender, SuiAddress::ZERO];
        let refused = Expected::Abort { package: self.vault_package(), module: "vault", code: BUYBACK_BELOW_MINIMUM };
        let pt = self.buyback_pt(launch, m, m.pool, before.burn_quote, u64::MAX)?;
        self.h.assert_rolled_back(pt, refused, &[m.vault, m.pool, launch.currency, self.admin_cap], &owners)?;

        let pt = self.buyback_pt(launch, m, m.pool, before.burn_quote, 1)?;
        let outcome = self.h.execute(pt)?;
        outcome.assert_success();
        let burned: Vec<BuybackBurned> = self.vault_events(&outcome, "BuybackBurned");
        ensure!(burned.len() == 1 && burned[0].vault_id == m.vault, "one BuybackBurned");
        let burned = &burned[0];
        ensure!(
            (burned.quote_spent, burned.burn_quote_pending) == (before.burn_quote, 0),
            "the full-range pool takes every waiting Quote"
        );
        ensure!(burned.meme_burned > 0, "the swap returned Meme");
        ensure!(
            outcome.coins_created_for(&self.h, SuiAddress::ZERO) == self.coins(launch, burned.meme_burned, 0),
            "the Meme bought is burned at @0x0"
        );
        let after = self.vault(m)?;
        ensure!(after.burn_quote == 0);
        ensure!(
            (after.owner_meme, after.owner_quote, after.auto_lp_meme, after.auto_lp_quote)
                == (before.owner_meme, before.owner_quote, before.auto_lp_meme, before.auto_lp_quote)
                && (after.rewards_meme, after.rewards_quote) == (before.rewards_meme, before.rewards_quote),
            "a buyback touches only the burn Quote"
        );
        self.report(format!(
            "buyback_and_burn ({:?}): min above the pool's output aborts vault buyback_below_minimum, rolled back; \
             then {} Quote bought and burned {} Meme at @0x0",
            self.case,
            burned.quote_spent,
            burned.meme_burned,
        ));

        Ok(())
    }

    /// Anyone can create another pool of the same type (Cetus at an unreserved tick spacing,
    /// Bluefin at any tier); collecting the vault against it is refused before any venue call.
    fn other_pool_is_refused(&mut self, launch: &Launch, m: &Migration, cap: ObjectID) -> Result<()> {
        let mut b = ProgrammableTransactionBuilder::new();
        let pool_pair = self.pool_pair(launch);
        let clock = self.clock(&mut b)?;
        let meme = b.obj(self.h.owned(self.meme_coin(launch)?))?;
        let meme_amount = b.pure(LP_MEME / 200)?;
        let Argument::Result(meme) = b.command(Command::SplitCoins(meme, vec![meme_amount])) else { unreachable!() };
        let meme = Argument::NestedResult(meme, 0);
        if self.case.is_cetus() {
            let quote = self.quote_coin(&mut b, self.target())?;
            let config = self.shared(&mut b, self.venue("cetus_global_config"), false)?;
            let pools = self.shared(&mut b, self.venue("cetus_pools"), true)?;
            let spacing = b.pure(CETUS_UNADMITTED_SPACING)?;
            let Argument::Result(range) =
                call(&mut b, id(CETUS), "pool_creator", "full_range_tick_range", vec![], vec![spacing])
            else {
                unreachable!()
            };
            let price = b.pure(self.cetus_pool(m)?.sqrt_price)?;
            let url = b.pure(String::new())?;
            let (coin_a, coin_b) = if self.case.meme_is_a() { (meme, quote) } else { (quote, meme) };
            let fix_a = b.pure(self.case.meme_is_a())?;
            let Argument::Result(created) = call(
                &mut b,
                id(CETUS),
                "pool_creator",
                "create_pool_v3",
                pool_pair,
                vec![
                    config,
                    pools,
                    spacing,
                    price,
                    url,
                    Argument::NestedResult(range, 0),
                    Argument::NestedResult(range, 1),
                    coin_a,
                    coin_b,
                    fix_a,
                    clock,
                ],
            ) else {
                unreachable!()
            };
            b.transfer_args(self.h.sender, (0..3).map(|i| Argument::NestedResult(created, i)).collect());
        } else {
            let config = self.shared(&mut b, self.venue("bluefin_global_config"), true)?;
            let fee = call(&mut b, SUI_FRAMEWORK_PACKAGE_ID, "balance", "zero", vec![sui()], vec![]);
            let mut args = vec![clock, config];
            for text in [&b"PTB-SUI"[..], b"", b"PTB"] {
                args.push(b.pure(text.to_vec())?);
            }
            args.push(b.pure(9u8)?);
            args.push(b.pure(Vec::<u8>::new())?);
            args.push(b.pure(b"SUI".to_vec())?);
            args.push(b.pure(9u8)?);
            args.push(b.pure(Vec::<u8>::new())?);
            args.push(b.pure(BLUEFIN_TICK_SPACING)?);
            args.push(b.pure(BLUEFIN_FEE_RATE)?);
            args.push(b.pure(expected_sqrt_price(LP_MEME, self.lp_quote(), true))?);
            args.push(fee);
            call(&mut b, id(BLUEFIN), "pool", "create_pool", vec![launch.meme.clone(), sui(), sui()], args);
            b.transfer_args(self.h.sender, vec![meme]);
        }
        let outcome = self.h.execute(b.finish())?;
        outcome.assert_success();
        let other = outcome.created(&self.h, "pool", "Pool");
        ensure!(other.len() == 1 && other[0] != m.pool && self.h.object(other[0]).is_shared());
        let other = other[0];

        let module = self.case.module();
        let code = POSITION_POOL_MISMATCH;
        let expected = Expected::Abort { package: self.migrators, module, code };
        let pt = self.collect_pt(launch, m, other, None)?;
        let watched = [m.vault, other, launch.currency];
        self.h.assert_rolled_back(pt, expected, &watched, &[self.h.sender, LP_PROTOCOL.into()])?;
        let next = shifted(&self.vault(m)?.fee_split.value, Destination::AutoLp, Destination::HolderRewards, 1);
        let schedule = self.schedule_fee_split_pt(launch, m, cap, &next)?;
        self.h.execute(schedule)?.assert_success();
        self.h.sim.advance_clock(std::time::Duration::from_millis(self.vault(m)?.fee_split.delay_ms));
        let ready_wrong_pool = self.collect_pt(launch, m, other, Some((cap, &next)))?;
        self.h.assert_rolled_back(ready_wrong_pool, Expected::Abort {package: self.migrators, module, code},
            &watched, &[self.h.sender, LP_PROTOCOL.into()])?;
        self.h.execute(self.cancel_fee_split_pt(launch, m, cap)?)?.assert_success();
        let expected = Expected::Abort { package: self.migrators, module, code };
        let pt = self.buyback_pt(launch, m, other, 1, 1)?;
        let watched = [m.vault, other, launch.currency, self.admin_cap];
        self.h.assert_rolled_back(pt, expected, &watched, &[self.h.sender, SuiAddress::ZERO])?;
        self.report(format!(
            "collect and buyback against another {} pool {other}: EPositionPoolMismatch, rolled back",
            if self.case.is_cetus() { "Cetus Pool<A, B> at tick spacing 60" } else { "Bluefin Pool<Meme, SUI>" }
        ));

        Ok(())
    }

    /// An administrator schedules a two-leaf round; after the vault's two-hour round delay anyone
    /// publishes it from the rewards balance, and a relayed proof pays the first beneficiary once.
    fn holder_rewards(&mut self, launch: &Launch, m: &Migration) -> Result<()> {
        let before = self.vault(m)?;
        ensure!(before.rewards_meme > 1 && before.rewards_quote > 1, "rewards accrued");
        let (meme, quote) = (before.rewards_meme / 2, before.rewards_quote / 2);
        let leaves = [(BENEFICIARY_A, meme / 3, quote / 3), (BENEFICIARY_B, meme - meme / 3, quote - quote / 3)];
        let digests: Vec<[u8; 32]> = leaves
            .iter()
            .enumerate()
            .map(|(index, (beneficiary, meme, quote))| {
                reward_leaf(m.vault, 0, index as u64, (*beneficiary).into(), *meme, *quote)
            })
            .collect();
        let root = merkle_node(&digests[0], &digests[1]);
        let (start, end) = (1_000u64, 2_000u64);
        // The gas reserve may be at most 10% of the round's holder Quote.
        ensure!(quote >= 10, "rewards fund a gas reserve");
        let gas_reserve = quote / 10;
        let (_, now_at_ms): (ObjectID, u64) = bcs::from_bytes(&self.h.contents(SUI_CLOCK_OBJECT_ID))?;
        let claim_window_duration_ms = 1_000u64;
        let deadline_at_ms = now_at_ms + ROUND_DELAY_MS + claim_window_duration_ms;
        ensure!(before.round_publication.delay_ms == ROUND_DELAY_MS && before.round_publication.pending.is_none());

        let mut b = ProgrammableTransactionBuilder::new();
        let signed_in = self.sign_in_core(&mut b, "RewardsAdmin")?;
        let vault = self.shared(&mut b, m.vault, true)?;
        let vault_version = self.vault_version(&mut b)?;
        let clock = self.clock(&mut b)?;
        let args = vec![
            vault,
            signed_in,
            vault_version,
            b.pure(0u64)?,
            b.pure(start)?,
            b.pure(end)?,
            b.pure(root.to_vec())?,
            b.pure(vec![0x5Au8; 32])?,
            b.pure(2u64)?,
            b.pure(meme)?,
            b.pure(quote)?,
            b.pure(gas_reserve)?,
            b.pure(claim_window_duration_ms)?,
            b.pure(SuiAddress::from(LP_PROTOCOL))?,
            clock,
        ];
        let meme_type = launch.meme.clone();
        call(&mut b, self.vault_package(), "holder_rewards", "schedule_round", vec![meme_type.clone(), self.quote()], args);
        let outcome = self.h.execute(b.finish())?;
        outcome.assert_success();
        let scheduled: Vec<ActionScheduled<RoundTerms>> = outcome.delayed("ActionScheduled", "vault", "RoundPublicationKey")?;
        ensure!(scheduled.len() == 1 && scheduled[0].owner == m.vault && scheduled[0].ready_at_ms == now_at_ms + ROUND_DELAY_MS);
        ensure!(matches!(&scheduled[0].change, Change::Action(terms) if terms.number == 0
            && terms.root == root.to_vec() && terms.gas_reserve_amount == gas_reserve
            && terms.claim_window_duration_ms == claim_window_duration_ms
            && terms.expected_treasury == LP_PROTOCOL.into()));
        let publish = |w: &Self| -> Result<ProgrammableTransaction> {
            let mut b = ProgrammableTransactionBuilder::new();
            let vault = w.shared(&mut b, m.vault, true)?;
            let version = w.vault_version(&mut b)?;
            let treasury = w.shared(&mut b, w.treasury, false)?;
            let clock = w.clock(&mut b)?;
            call(&mut b, w.vault_package(), "holder_rewards", "publish_round", vec![launch.meme.clone(), w.quote()], vec![vault, version, treasury, clock]);
            Ok(b.finish())
        };
        self.h.sim.advance_clock(std::time::Duration::from_millis(ROUND_DELAY_MS - 1));
        let pt = publish(self)?;
        self.h.assert_rolled_back(pt, Expected::Abort { package: self.admin, module: "delayed", code: 13 }, &[m.vault], &[LP_PROTOCOL.into()])?;
        self.h.sim.advance_clock(std::time::Duration::from_millis(1));
        let outcome = self.h.execute(publish(self)?)?;
        outcome.assert_success();
        let rounds = outcome.created(&self.h, "holder_rewards", "Round");
        ensure!(rounds.len() == 1 && self.h.object(rounds[0]).is_shared());
        let round = rounds[0];
        let published: Vec<RoundPublished> = self.vault_events(&outcome, "RoundPublished");
        ensure!(published.len() == 1 && published[0].round_id == round && published[0].root == root.to_vec());
        ensure!((published[0].meme_amount, published[0].quote_amount) == (meme, quote));
        ensure!(published[0].claim_deadline_at_ms == deadline_at_ms);
        ensure!(published[0].treasury == LP_PROTOCOL.into() && published[0].gas_reserve_amount == gas_reserve);
        let after = self.vault(m)?;
        ensure!(
            (after.rewards_meme, after.rewards_quote) == (before.rewards_meme - meme, before.rewards_quote - quote - gas_reserve)
        );
        ensure!(
            (published[0].meme_unallocated, published[0].quote_unallocated)
                == (after.rewards_meme, after.rewards_quote)
        );
        ensure!(after.next_round == 1 && after.last_checkpoint == Some(end));
        ensure!(after.round_publication.pending.is_none(), "publication consumed the scheduled round");

        let claim = |w: &Self| -> Result<ProgrammableTransaction> {
            let mut b = ProgrammableTransactionBuilder::new();
            let round = w.shared(&mut b, round, true)?;
            let vault_version = w.vault_version(&mut b)?;
            let clock = w.clock(&mut b)?;
            let (beneficiary, meme, quote) = leaves[0];
            let args = vec![
                round,
                vault_version,
                b.pure(0u64)?,
                b.pure(SuiAddress::from(beneficiary))?,
                b.pure(meme)?,
                b.pure(quote)?,
                b.pure(vec![digests[1].to_vec()])?,
                clock,
            ];
            call(&mut b, w.vault_package(), "holder_rewards", "claim", vec![meme_type.clone(), w.quote()], args);
            Ok(b.finish())
        };
        let pt = claim(self)?;
        let outcome = self.h.execute(pt)?;
        outcome.assert_success();
        let paid: Vec<RewardClaimed> = self.vault_events(&outcome, "RewardClaimed");
        let (beneficiary, meme_paid, quote_paid) = leaves[0];
        ensure!(paid.len() == 1 && paid[0].beneficiary == beneficiary.into() && paid[0].index == 0);
        ensure!((paid[0].meme_amount, paid[0].quote_amount) == (meme_paid, quote_paid));
        ensure!((paid[0].meme_remaining, paid[0].quote_remaining) == (meme - meme_paid, quote - quote_paid));
        let mut coins = vec![
            (meme_type.to_canonical_string(true), meme_paid),
            (self.quote().to_canonical_string(true), quote_paid),
        ];
        coins.sort();
        ensure!(outcome.coins_created_for(&self.h, beneficiary.into()) == coins);
        let expected = Expected::Abort { package: self.vault_package(), module: "holder_rewards", code: ALREADY_CLAIMED };
        let pt = claim(self)?;
        self.h.assert_rolled_back(pt, expected, &[round], &[beneficiary.into()])?;
        // A valid settlement followed by a replay in one PTB must roll back both
        // the treasury transfer and returned custody, with no committed event.
        let settlement = |w: &Self, round_id: ObjectID, amount: u64, replay: bool| -> Result<ProgrammableTransaction> {
            let mut b = ProgrammableTransactionBuilder::new();
            let admin = w.sign_in_core(&mut b, "RewardsAdmin")?;
            let round_arg = w.shared(&mut b, round_id, true)?;
            let version = w.vault_version(&mut b)?;
            let vault = w.shared(&mut b, m.vault, true)?;
            let amount = b.pure(amount)?;
            call(&mut b, w.vault_package(), "holder_rewards", "settle_gas_reserve", vec![meme_type.clone(), w.quote()], vec![round_arg, admin, version, vault, amount]);
            if replay {
                let amount = b.pure(0u64)?;
                call(&mut b, w.vault_package(), "holder_rewards", "settle_gas_reserve", vec![meme_type.clone(), w.quote()], vec![round_arg, admin, version, vault, amount]);
            }
            Ok(b.finish())
        };
        let pt = settlement(self, round, gas_reserve + 1, false)?;
        self.h.assert_rolled_back(pt, Expected::Abort { package: self.vault_package(), module: "holder_rewards", code: OVER_RESERVE }, &[round, m.vault, self.admin_cap], &[LP_PROTOCOL.into()])?;
        let reimbursement = gas_reserve / 2;
        let pt = settlement(self, round, reimbursement, true)?;
        self.h.assert_rolled_back(pt, Expected::Abort { package: self.vault_package(), module: "holder_rewards", code: RESERVE_SETTLED }, &[round, m.vault, self.admin_cap], &[LP_PROTOCOL.into()])?;
        let pt = settlement(self, round, reimbursement, false)?;
        let settled = self.h.execute(pt)?;
        settled.assert_success();
        let events: Vec<GasReserveSettled> = self.vault_events(&settled, "GasReserveSettled");
        ensure!(events.len() == 1);
        let event = &events[0];
        ensure!(event.vault_id == m.vault && event.round_id == round && event.number == 0 && event.treasury == LP_PROTOCOL.into());
        ensure!((event.reimbursement_amount, event.reserve_returned) == (reimbursement, gas_reserve - reimbursement));
        ensure!(event.quote_unallocated == before.rewards_quote - quote - reimbursement);
        ensure!(self.vault(m)?.rewards_quote == event.quote_unallocated);

        let close = |w: &Self, round_id: ObjectID| -> Result<ProgrammableTransaction> {
            let mut b = ProgrammableTransactionBuilder::new();
            let round = w.shared(&mut b, round_id, true)?;
            let version = w.vault_version(&mut b)?;
            let vault = w.shared(&mut b, m.vault, true)?;
            let clock = w.clock(&mut b)?;
            call(&mut b, w.vault_package(), "holder_rewards", "close_round", vec![meme_type.clone(), w.quote()], vec![round, version, vault, clock]);
            Ok(b.finish())
        };
        let pt = close(self, round)?;
        self.h.assert_rolled_back(pt, Expected::Abort { package: self.vault_package(), module: "holder_rewards", code: CLAIMS_STILL_OPEN }, &[round, m.vault], &[])?;

        // Publish another funded round after a deliberately skipped holding interval, once its
        // delay has elapsed and the first round's claims have closed. Its reserve, the most a
        // ten-unit Quote budget allows, stays unsettled until recovery after revocation.
        let mut b = ProgrammableTransactionBuilder::new();
        let signed_in = self.sign_in_core(&mut b, "RewardsAdmin")?;
        let vault = self.shared(&mut b, m.vault, true)?;
        let version = self.vault_version(&mut b)?;
        let clock = self.clock(&mut b)?;
        let args = vec![vault, signed_in, version,
            b.pure(1u64)?, b.pure(end + 100)?, b.pure(end + 200)?,
            b.pure(vec![0xAAu8; 32])?, b.pure(vec![0xBBu8; 32])?,
            b.pure(1u64)?, b.pure(1u64)?, b.pure(SECOND_ROUND_QUOTE)?, b.pure(1u64)?,
            b.pure(claim_window_duration_ms)?, b.pure(SuiAddress::from(LP_PROTOCOL))?, clock];
        call(&mut b, self.vault_package(), "holder_rewards", "schedule_round", vec![meme_type.clone(), self.quote()], args);
        self.h.execute(b.finish())?.assert_success();
        self.h.sim.advance_clock(std::time::Duration::from_millis(ROUND_DELAY_MS));
        let (_, second_published_at_ms): (ObjectID, u64) = bcs::from_bytes(&self.h.contents(SUI_CLOCK_OBJECT_ID))?;
        let second = self.h.execute(publish(self)?)?;
        second.assert_success();
        let second_rounds = second.created(&self.h, "holder_rewards", "Round");
        ensure!(second_rounds.len() == 1 && self.h.object(second_rounds[0]).is_shared());
        let second_round = second_rounds[0];
        let second_events: Vec<RoundPublished> = self.vault_events(&second, "RoundPublished");
        ensure!(second_events.len() == 1 && second_events[0].gas_reserve_amount == 1);
        ensure!(second_events[0].treasury == LP_PROTOCOL.into()
            && second_events[0].claim_deadline_at_ms == second_published_at_ms + claim_window_duration_ms);

        // Revoke the live role, prove settlement cannot sign in, then recover
        // all unclaimed holder funds permissionlessly at the exact deadline.
        let mut b = ProgrammableTransactionBuilder::new();
        let acl = self.shared(&mut b, self.acl, true)?;
        let root_cap = b.obj(self.h.owned(self.root))?;
        let cap_id = b.pure(self.admin_cap)?;
        call(&mut b, self.admin, "blast_acl", "revoke_role", vec![tag(&format!("{}::blast_domain::RewardsAdmin", self.core))], vec![acl, root_cap, cap_id]);
        self.h.impersonate_cap_owner(self.root, b.finish())?.assert_success();
        let pt = settlement(self, second_round, 0, false)?;
        self.h.assert_rolled_back(pt, Expected::Abort { package: self.admin, module: "blast_acl", code: 5 }, &[second_round, m.vault, self.admin_cap], &[LP_PROTOCOL.into()])?;
        self.h.sim.advance_clock(std::time::Duration::from_millis(1_000));
        let pt = claim(self)?;
        self.h.assert_rolled_back(pt, Expected::Abort { package: self.vault_package(), module: "holder_rewards", code: CLAIMS_CLOSED }, &[round], &[beneficiary.into()])?;
        let pt = close(self, round)?;
        let closed = self.h.execute(pt)?;
        closed.assert_success();
        let events: Vec<RoundClosed> = self.vault_events(&closed, "RoundClosed");
        ensure!(events.len() == 1);
        let event = &events[0];
        ensure!(event.vault_id == m.vault && event.round_id == round && event.number == 0);
        ensure!((event.meme_returned, event.quote_returned, event.gas_reserve_returned) == (meme - meme_paid, quote - quote_paid, 0));
        let pt = close(self, second_round)?;
        let recovered = self.h.execute(pt)?;
        recovered.assert_success();
        let events: Vec<RoundClosed> = self.vault_events(&recovered, "RoundClosed");
        ensure!(events.len() == 1);
        let event = &events[0];
        ensure!(event.vault_id == m.vault && event.round_id == second_round && event.number == 1);
        ensure!((event.meme_returned, event.quote_returned, event.gas_reserve_returned) == (1, SECOND_ROUND_QUOTE, 1));
        let final_vault = self.vault(m)?;
        ensure!((final_vault.rewards_meme, final_vault.rewards_quote) == (before.rewards_meme - meme_paid, before.rewards_quote - quote_paid - reimbursement));
        self.report(format!("holder rewards: isolated gas={gas_reserve}, reimbursement={reimbursement}, atomic replay rollback, ACL revocation, deadline claim rejection and permissionless close conserve both assets"));

        Ok(())
    }

    fn cetus_abort(&self, module: &'static str, code: u64) -> Expected {
        Expected::Abort { package: id(CETUS), module, code }
    }

    /// The fixture plan: 70% of the Meme on the curve, 20% of the Meme and 90% of the Quote to
    /// the pool, and 5% of each to `DESTINATION`; finalization records Blast's separate 5%
    /// migration fee for each asset.
    fn plan_arg(&self, b: &mut ProgrammableTransactionBuilder) -> Result<Argument> {
        let destination = b.pure(SuiAddress::from(DESTINATION))?;
        let vesting_terms = tag(&format!("{}::payout::VestingTerms", self.core));
        let outright = call(b, sui_types::MOVE_STDLIB_PACKAGE_ID, "option", "none", vec![vesting_terms], vec![]);
        let payee = call(b, self.core, "payout", "recipient", vec![], vec![destination, outright]);
        let share = self.bps(b, ALLOCATION_BPS)?;
        let recipient = call(b, self.blast, "allocation", "recipient_share", vec![], vec![payee, share, share]);
        let recipient_type = tag(&format!("{}::allocation::RecipientShare", self.blast));
        let recipients = b.command(Command::make_move_vec(Some(recipient_type), vec![recipient]));
        let curve_meme = self.bps(b, 7_000)?;
        let lp_meme = self.bps(b, 2_000)?;
        let lp_quote = self.bps(b, 9_000)?;

        Ok(call(b, self.blast, "allocation", "plan", vec![], vec![curve_meme, lp_meme, lp_quote, recipients]))
    }
}

// === Blast arithmetic ===

/// Blast's vault share of each asset, rounded up, then the rest apportioned over the vault's split
/// in route order.
fn expected_fees(vault: &Vault, gross_meme: u64, gross_quote: u64) -> FeesCollected {
    let protocol = |gross: u64, bps: u64| (gross as u128 * bps as u128).div_ceil(10_000) as u64;
    let weights: Vec<u64> = vault.fee_split.value.routes.iter().map(|route| route.bps).collect();
    let (meme_bps, quote_bps) = vault.protocol_bps.value;
    let (protocol_meme, protocol_quote) = (protocol(gross_meme, meme_bps), protocol(gross_quote, quote_bps));
    FeesCollected {
        vault_id: vault.id,
        gross_meme,
        gross_quote,
        protocol_meme,
        protocol_quote,
        route_meme: apportion(&weights, gross_meme - protocol_meme),
        route_quote: apportion(&weights, gross_quote - protocol_quote),
    }
}

/// `holder_rewards::reward_leaf`: `merkle::leaf` (Blake2b-256 over a zero tag, the leaf domain,
/// and the payload) of the BCS of every committed value.
fn reward_leaf(vault: ObjectID, round: u64, index: u64, beneficiary: SuiAddress, meme: u64, quote: u64) -> [u8; 32] {
    let mut bytes = b"\x00blast-holder-rewards-v2".to_vec();
    bytes.extend(bcs::to_bytes(&vault).expect("bcs"));
    bytes.extend(bcs::to_bytes(&round).expect("bcs"));
    bytes.extend(bcs::to_bytes(&index).expect("bcs"));
    bytes.extend(bcs::to_bytes(&beneficiary).expect("bcs"));
    bytes.extend(bcs::to_bytes(&meme).expect("bcs"));
    bytes.extend(bcs::to_bytes(&quote).expect("bcs"));
    Blake2b::<U32>::digest(&bytes).into()
}

fn merkle_node(left: &[u8; 32], right: &[u8; 32]) -> [u8; 32] {
    let mut bytes = vec![1u8];
    bytes.extend(left);
    bytes.extend(right);
    Blake2b::<U32>::digest(&bytes).into()
}

// === Event and object mirrors (BCS field order) ===

/// Whether the vault's split change follows the venue settlement in native event order.
fn fee_split_applied_after_settlement(outcome: &Outcome, vault: ObjectID) -> bool {
    let position = |found: &dyn Fn(&sui_types::event::Event) -> bool| outcome.events.iter().position(found);
    let settled = position(&|event| {
        ObjectID::from(event.type_.address) == vault && event.type_.name.as_str() == "FeesCollected"
    });
    let applied = position(&|event| {
        event.type_.module.as_str() == "delayed"
            && event.type_.name.as_str() == "DelayedApplied"
            && matches!(event.type_.type_params.first(),
                Some(TypeTag::Struct(key)) if key.module.as_str() == "vault" && key.name.as_str() == "FeeSplitKey")
    });
    matches!((settled, applied), (Some(settled), Some(applied)) if settled < applied)
}

fn package_event_names(outcome: &Outcome, package: ObjectID) -> Vec<String> {
    outcome
        .events
        .iter()
        .filter(|event| ObjectID::from(event.type_.address) == package)
        .map(|event| event.type_.name.to_string())
        .collect()
}

/// A generated coin before its launch: the ticket and `TreasuryCap` the sender holds, and its
/// shared Currency.
struct Ticket {
    meme: TypeTag,
    ticket: ObjectID,
    treasury_cap: ObjectID,
    currency: ObjectID,
}

/// Mirrors `blast_core::migration::ResidualPolicy`.
#[derive(Clone, Debug, Deserialize, PartialEq, Serialize)]
enum ResidualPolicy {
    Protocol,
    Owner,
}

/// Mirrors `blast_core::migration::VaultTerms`; each `Bps` is one `u64`.
#[derive(Clone, Debug, Deserialize, PartialEq, Serialize)]
struct VaultTerms {
    origin: ObjectID,
    package_witness: String,
    fee_split: FeeSplit,
    protocol_meme_bps: u64,
    protocol_quote_bps: u64,
    partner_id: Option<ObjectID>,
    residuals: ResidualPolicy,
}

/// Mirrors `blast_core::protocol_fees::Ledger`; each `Balance` is one `u64`.
#[derive(Debug, Deserialize, PartialEq, Serialize)]
struct Ledger {
    _package_witness: String,
    _origin: ObjectID,
    _partner_id: Option<ObjectID>,
    meme: u64,
    quote: u64,
    sui: u64,
}

/// Mirrors `blast_vault::vault::Vault`; each `Balance` is one `u64`.
#[derive(Debug, Deserialize, PartialEq, Serialize)]
struct Vault {
    id: ObjectID,
    terms: VaultTerms,
    pool_id: ObjectID,
    fee_split: Delayed<FeeSplit>,
    protocol_bps: Delayed<(u64, u64)>,
    protocol: Ledger,
    owner_meme: u64,
    owner_quote: u64,
    auto_lp_meme: u64,
    auto_lp_quote: u64,
    rewards_meme: u64,
    rewards_quote: u64,
    burn_quote: u64,
    next_round: u64,
    last_checkpoint: Option<u64>,
    round_publication: DelayedAction<RoundTerms>,
}

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
    _curve_meme_bps: u64,
    _lp_meme_bps: u64,
    _lp_quote_bps: u64,
    _protocol_meme_bps: u64,
    _protocol_quote_bps: u64,
    _allocation_recipients: Vec<((SuiAddress, Option<(u64, u64, u64)>), u64, u64)>,
    _opening_round_ms: u64,
    _creation_fee: u64,
    _partner_id: Option<ObjectID>,
}

#[derive(Deserialize)]
struct Migrated {
    launch_id: ObjectID,
    meme: u64,
    quote: u64,
    _disposed_meme: u64,
    _total_supply_after: u64,
}

#[derive(Deserialize)]
struct MigrationAllocationPaid {
    _launch_id: ObjectID,
    destination: SuiAddress,
    meme: u64,
    quote: u64,
    _meme_vesting_id: Option<ObjectID>,
    _quote_vesting_id: Option<ObjectID>,
}

#[derive(Deserialize)]
struct ProtocolFeesAccrued {
    launch_id: ObjectID,
    meme_amount: u64,
    quote_amount: u64,
}

/// Mirrors `blast_migrators::events::CetusPoolReserved<Meme, Quote>`; the pair is its type.
#[derive(Deserialize)]
struct CetusPoolReserved {
    pool_creation_cap_id: ObjectID,
    tick_spacing: u32,
}

/// Mirrors `blast_vault::blast_vault_events::VaultCreated<Meme, Quote, Venue>`.
#[derive(Deserialize)]
struct VaultCreated {
    vault_id: ObjectID,
    pool_id: ObjectID,
    position_id: ObjectID,
    liquidity: u128,
    terms: VaultTerms,
    residual_meme_amount: u64,
    residual_quote_amount: u64,
}

/// Mirrors `blast_core::blast_core_events::ProtocolFeesPaid<Meme, Quote>`.
#[derive(Deserialize)]
struct ProtocolFeesPaid {
    _package_witness: String,
    origin: ObjectID,
    treasury: SuiAddress,
    meme_amount: u64,
    quote_amount: u64,
    sui_amount: u64,
    partner_id: Option<ObjectID>,
    _partner_meme_amount: u64,
    _partner_quote_amount: u64,
    _partner_sui_amount: u64,
}

/// Mirrors `blast_vault::blast_vault_events::FeesCollected<Meme, Quote>`: route amounts follow
/// the vault's split.
#[derive(Clone, Debug, Deserialize, PartialEq)]
struct FeesCollected {
    vault_id: ObjectID,
    gross_meme: u64,
    gross_quote: u64,
    protocol_meme: u64,
    protocol_quote: u64,
    route_meme: Vec<u64>,
    route_quote: Vec<u64>,
}

#[derive(Deserialize)]
struct BuybackBurned {
    vault_id: ObjectID,
    quote_spent: u64,
    meme_burned: u64,
    burn_quote_pending: u64,
}

#[derive(Deserialize)]
struct AutoLiquidityAdded {
    _vault_id: ObjectID,
    meme_amount: u64,
    quote_amount: u64,
    auto_lp_meme_pending: u64,
    auto_lp_quote_pending: u64,
}

#[derive(Deserialize)]
struct AutoLpPositionOpened {
    _vault_id: ObjectID,
    position_id: ObjectID,
}

#[derive(Deserialize)]
struct OwnerBalancesClaimed {
    vault_id: ObjectID,
    meme_amount: u64,
    quote_amount: u64,
}

#[derive(Deserialize)]
struct RoundPublished {
    _vault_id: ObjectID,
    round_id: ObjectID,
    _number: u64,
    _start_checkpoint: u64,
    _end_checkpoint: u64,
    claim_deadline_at_ms: u64,
    root: Vec<u8>,
    _manifest_digest: Vec<u8>,
    _leaf_count: u64,
    meme_amount: u64,
    quote_amount: u64,
    meme_unallocated: u64,
    quote_unallocated: u64,
    treasury: SuiAddress,
    gas_reserve_amount: u64,
}

#[derive(Deserialize)]
struct GasReserveSettled {
    vault_id: ObjectID,
    round_id: ObjectID,
    number: u64,
    treasury: SuiAddress,
    reimbursement_amount: u64,
    reserve_returned: u64,
    quote_unallocated: u64,
}

#[derive(Deserialize)]
struct RoundClosed {
    vault_id: ObjectID,
    round_id: ObjectID,
    number: u64,
    meme_returned: u64,
    quote_returned: u64,
    gas_reserve_returned: u64,
}

#[derive(Deserialize)]
struct RewardClaimed {
    _round_id: ObjectID,
    index: u64,
    beneficiary: SuiAddress,
    meme_amount: u64,
    quote_amount: u64,
    meme_remaining: u64,
    quote_remaining: u64,
}
