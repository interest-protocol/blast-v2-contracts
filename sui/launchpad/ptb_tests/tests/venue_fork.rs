//! Venue-fork gate: the migrators against real Cetus CLMM, Cetus LP Burn, and Bluefin Spot
//! mainnet bytecode, offline.
//!
//! `fork/snapshot/` holds, at one pinned mainnet checkpoint, every package those venues load and
//! every live object and dynamic field their code reads (`fork/fetch.py` writes it and records
//! why each entry is there). Each world inserts that snapshot into the in-memory simulator at the
//! real IDs, after checking every object against its recorded digest, then publishes the
//! launchpad and the migrators linked to the real venue packages exactly as their manifests pin
//! them. No transaction reaches a network.
//!
//! One test per venue and coin order runs the whole lifecycle through public PTBs: Cetus with Meme
//! as coin A (SUI Quote) and with Meme as coin B (USDC Quote; both Quotes admitted at tick spacing
//! 200 by Cetus's live allowlist), each through Cetus's single routes that take the pool's coin
//! types after the Meme and Quote (ADR 0100), and Bluefin. Each shows that the adapter's `new` rejects a tier the
//! venue would refuse and then starts the launch at a valid one; a migration that aborts after
//! pool creation commits nothing, and on Cetus reversed or foreign coin types are refused; one PTB migrates into a new pool at the launch's tier, burns
//! the Cetus position through LP Burn, and pays the allocations; permissionless collections split
//! real swap fees exactly by Blast's live share (default, then a per-coin override) and the fee
//! split, skip auto-LP while its balances are one-sided or tiny, and otherwise add auto-LP back
//! at the pool price, and burn the burn part's Meme at `@0x0` (the fixture's supply is fixed); the
//! buyback administrator swaps the waiting burn Quote for Meme and burns it, and a minimum above
//! the pool's output rolls back; collection against another pool of the same type is refused; the settled
//! split update runs under the live curve-fee cap and a retired cap is refused; the creator claims
//! its share; a holder-reward round is published from the rewards balance and paid by Merkle
//! proof; and the administrator claims the migration residuals. Every venue observation prints as a `VENUE_FORK`
//! line.
//!
//! Run from `sui/launchpad/ptb_tests` with `cargo test --offline --test venue_fork`.

use std::{collections::BTreeMap, path::Path, sync::OnceLock};

use anyhow::{Context, Result, bail, ensure};
use blake2::{Blake2b, Digest, digest::consts::U32};
use blast_launchpad_ptb_tests::{
    CompiledPackage, Expected, Harness, Outcome, UnlinkedPackage, build, build_timelock, build_unlinked, call,
    fork::{
        BLUEFIN, BLUEFIN_MAX_SQRT_PRICE, BLUEFIN_MIN_SQRT_PRICE, BluefinPoolCreated, BurnPosition, BurnProof,
        BurnRecord, CETUS, CETUS_MAX_SQRT_PRICE, CETUS_MIN_SQRT_PRICE, CetusAddLiquidity, CetusCollectFee,
        CetusOpenPosition, CetusPoolState, CetusPosition, CreatePool, LiquidityProvided, MintPoolCreationCap,
        RegisterPermissionPair, USDC, UserFeeCollected, apportion, cetus_name, expected_sqrt_price, id,
        insert_snapshot, meme_is_cetus_a, sui, tag, venue_dependencies, venue_events,
    },
    sui_dir, timelock_dir,
};
use serde::{Deserialize, Serialize, de::DeserializeOwned};
use sui_types::{
    SUI_CLOCK_OBJECT_ID, SUI_COIN_REGISTRY_OBJECT_ID, SUI_FRAMEWORK_PACKAGE_ID, TypeTag,
    base_types::{ObjectID, SuiAddress},
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
const INVALID_LAUNCH_LIFECYCLE: u64 = 15;
const CREATOR_CAP_NOT_LIVE: u64 = 22;
/// `blast_fun_migrators::vault` code.
const BUYBACK_BELOW_MINIMUM: u64 = 5;
/// `blast_fun_migrators::cetus` codes.
const INVALID_COIN_ORDER: u64 = 0;
const WRONG_COIN_PAIR: u64 = 2;

/// The `blast_fun_domain` roles this world's one `AdminCap` holds.
const ADMIN_ROLES: [&str; 7] =
    ["ListingAdmin", "AdapterAdmin", "FeeAdmin", "TreasuryAdmin", "CreatorAdmin", "BuybackAdmin", "RewardsAdmin"];

/// Blast's default LP-fee share, then per-coin overrides for the forked Meme.
const DEFAULT_SHARES: (u64, u64) = (1_000, 500);
const COIN_SHARES: (u64, u64) = (2_500, 1_500);
/// A per-coin share that leaves only 0.01% of the Meme fees to split.
const TINY_SHARES: (u64, u64) = (9_999, 1_500);

// Addresses.
const DESTINATION: ObjectID = address(&[0xD5]);
const LP_PROTOCOL: ObjectID = address(&[0xAD, 0x01]);
const RECIPIENT_A: ObjectID = address(&[0xA1]);
const RECIPIENT_B: ObjectID = address(&[0xB2]);
const RECIPIENT_C: ObjectID = address(&[0xC3]);
const CAP_HOLDER: ObjectID = address(&[0xCA, 0xFE]);
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

/// The whole lifecycle of one launch on `case`.
fn run(case: Case) -> Result<()> {
    let mut w = World::new(case)?;
    w.report(format!("snapshot checkpoint {}", w.checkpoint));
    let split = FeeSplit {
        creator_bps: 2_500,
        auto_lp_bps: 2_000,
        rewards_bps: 1_000,
        burn_bps: 500,
        recipients: vec![
            Recipient { destination: RECIPIENT_A.into(), bps: 2_500 },
            Recipient { destination: RECIPIENT_B.into(), bps: 1_500 },
        ],
    };

    let launch = w.start_launch(&split)?;
    w.graduate(&launch)?;
    w.migration_failures_commit_nothing(&launch)?;
    let mut m = w.migrate(&launch)?;

    // One-sided: only Quote fees exist, so auto-LP waits. Blast's default share applies.
    w.swap(&launch, &m, Side::QuoteIn, w.case.quote_unit())?;
    let c = w.collect(&launch, &mut m, None)?;
    ensure!(c.fees.gross_meme == 0 && c.fees.gross_quote > 0, "a Quote-only swap left Quote-only fees");
    ensure!(c.added.is_none(), "one-sided auto-LP must wait");
    w.report(format!("collect one-sided, default share {DEFAULT_SHARES:?}: {}", c.line()));

    // Two-sided: auto-LP adds at the pool price and the remainder waits.
    w.swap(&launch, &m, Side::QuoteIn, 5 * w.case.quote_unit())?;
    w.swap(&launch, &m, Side::MemeIn, LP_MEME / 20)?;
    let c = w.collect(&launch, &mut m, None)?;
    ensure!(c.added.is_some(), "two-sided auto-LP must add");
    w.report(format!("collect two-sided, default share: {}", c.line()));

    // Tiny: a per-coin share that leaves Blast all but 0.01% of the Meme fees applies from the
    // next collection, whose few Meme atoms of auto-LP cannot carry any venue liquidity.
    w.set_coin_shares(&launch, TINY_SHARES)?;
    let tiny = LP_MEME / w.lp_quote() * 20;
    w.swap(&launch, &m, Side::MemeIn, tiny)?;
    let c = w.collect(&launch, &mut m, None)?;
    let vault = w.vault(&m)?;
    ensure!(
        c.fees.auto_lp_meme > 0 && vault.auto_lp_meme > 0 && vault.auto_lp_quote > 0,
        "tiny Meme and waiting Quote"
    );
    ensure!(c.added.is_none(), "tiny auto-LP must wait");
    w.report(format!(
        "collect tiny, per-coin share {TINY_SHARES:?}, {tiny} Meme swapped: {} pending=({}, {})",
        c.line(),
        vault.auto_lp_meme,
        vault.auto_lp_quote
    ));

    // A later per-coin share replaces it live; auto-LP adds again.
    w.set_coin_shares(&launch, COIN_SHARES)?;
    w.swap(&launch, &m, Side::QuoteIn, 3 * w.case.quote_unit())?;
    w.swap(&launch, &m, Side::MemeIn, LP_MEME / 40)?;
    let c = w.collect(&launch, &mut m, None)?;
    ensure!(c.added.is_some(), "later auto-LP must add");
    w.report(format!("collect per-coin share {COIN_SHARES:?}: {}", c.line()));

    // Split update under the live curve-fee cap, settling under the old split first.
    let cap = w.claim_curve_fee_cap(&launch)?;
    let next = FeeSplit {
        creator_bps: 3_000,
        auto_lp_bps: 3_000,
        rewards_bps: 1_000,
        burn_bps: 1_000,
        recipients: vec![Recipient { destination: RECIPIENT_C.into(), bps: 2_000 }],
    };
    w.swap(&launch, &m, Side::QuoteIn, 2 * w.case.quote_unit())?;
    w.swap(&launch, &m, Side::MemeIn, LP_MEME / 50)?;
    let c = w.collect(&launch, &mut m, Some((cap, &next)))?;
    w.report(format!("settle_and_update_fee_split: {} then the new split", c.line()));
    w.swap(&launch, &m, Side::QuoteIn, w.case.quote_unit())?;
    let c = w.collect(&launch, &mut m, None)?;
    ensure!(w.vault(&m)?.fee_split == next, "the next collection runs under the new split");
    w.report(format!("collect under the new split: {}", c.line()));
    w.buyback(&launch, &m)?;

    w.other_pool_is_refused(&launch, &m)?;
    w.claim_creator_fees(&launch, &m, cap)?;
    w.retired_cap_is_refused(&launch, &m, cap, &next)?;
    w.holder_rewards(&launch, &m)?;
    w.claim_protocol_residuals(&launch, &m)?;

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
        let work = Path::new(env!("CARGO_TARGET_TMPDIR")).join(env!("CARGO_PKG_NAME")).join("venue_fork");
        build_unlinked(
            &sui_dir().join("migrators"),
            &["blast_fun_timelock", "blast_admin", "blast_partners", "blast_fun"],
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
}

struct Collection {
    fees: FeesCollected,
    added: Option<AutoLiquidityAdded>,
}

impl Collection {
    fn line(&self) -> String {
        let f = &self.fees;
        format!(
            "gross=({}, {}) protocol=({}, {}) creator=({}, {}) auto_lp=({}, {}) rewards=({}, {}) \
             burn=({}, {}) recipients=({:?}, {:?}) added={}",
            f.gross_meme,
            f.gross_quote,
            f.protocol_meme,
            f.protocol_quote,
            f.creator_meme,
            f.creator_quote,
            f.auto_lp_meme,
            f.auto_lp_quote,
            f.rewards_meme,
            f.rewards_quote,
            f.burn_meme,
            f.burn_quote,
            f.recipient_meme,
            f.recipient_quote,
            match &self.added {
                Some(a) =>
                    format!("({}, {}) pending=({}, {})", a.meme_amount, a.quote_amount, a.meme_pending, a.quote_pending),
                None => "none".into(),
            },
        )
    }
}

struct World {
    h: Harness,
    case: Case,
    checkpoint: u64,
    venue: BTreeMap<String, ObjectID>,
    admin: ObjectID,
    blast: ObjectID,
    migrators: ObjectID,
    version: ObjectID,
    migrators_version: ObjectID,
    runtime: ObjectID,
    config: ObjectID,
    venue_config: ObjectID,
    policy: ObjectID,
    acl: ObjectID,
    admin_cap: ObjectID,
    project: CompiledPackage,
    coins: u64,
    shares: (u64, u64),
    lines: Vec<String>,
}

impl World {
    /// Inserts the snapshot, publishes the launchpad and the linked migrators, and configures
    /// both under the production admin path.
    fn new(case: Case) -> Result<Self> {
        let sui_dir = sui_dir();
        let work =
            Path::new(env!("CARGO_TARGET_TMPDIR")).join(env!("CARGO_PKG_NAME")).join(format!("venue_fork_{case:?}"));
        let mut h = Harness::new()?;
        let (checkpoint, venue) = insert_snapshot(&mut h)?;

        let timelock_dir = timelock_dir()?;
        let admin_dir = sui_dir.join("admin");
        let launchpad_dir = sui_dir.join("launchpad");
        let (timelock, _) = h.publish(build_timelock(&work)?)?;
        let (admin, admin_published) = h.publish(build(&admin_dir, &[(&timelock_dir, timelock)], &work)?)?;
        let partners_dir = sui_dir.join("partners");
        let (partners, _) = h.publish(build(&partners_dir, &[(&timelock_dir, timelock), (&admin_dir, admin)], &work)?)?;
        let core = [(timelock_dir.as_path(), timelock), (admin_dir.as_path(), admin), (partners_dir.as_path(), partners)];
        let (blast, published) = h.publish(build(&launchpad_dir, &core, &work)?)?;
        let one = |h: &Harness, outcome: &Outcome, module: &str, name: &str| {
            let ids = outcome.created(h, module, name);
            assert_eq!(ids.len(), 1, "{module}::{name}");
            ids[0]
        };
        let acl = one(&h, &admin_published, "blast_acl", "ACL");
        let root = one(&h, &admin_published, "blast_acl", "SuperAdminCap");
        let config = one(&h, &published, "launch_config", "LaunchConfig");
        let runtime = one(&h, &published, "runtime_config", "RuntimeConfig");
        let version = h.wrap_launchpad(blast, &published)?;

        let mut dependencies =
            vec![ObjectID::from_single_byte(1), ObjectID::from_single_byte(2), timelock, admin, partners, blast];
        dependencies.extend(venue_dependencies(&h)?);
        let linked = migrators().link(
            &[("blast_fun_timelock", timelock), ("blast_admin", admin), ("blast_partners", partners), ("blast_fun", blast)],
            dependencies,
        )?;
        let (migrators, published) = h.publish(linked)?;
        let migrators_version = one(&h, &published, "blast_fun_migrators", "PackageVersion");
        let venue_config = one(&h, &published, "venue_config", "VenueConfig");
        let policy = one(&h, &published, "lp_fee_policy", "LpFeePolicy");
        let project = build(
            &Path::new(env!("CARGO_MANIFEST_DIR")).join("fixture/project"),
            &[core[0], core[1], core[2], (launchpad_dir.as_path(), blast)],
            &work,
        )?;

        // Production admin path: the configured root owner's SuperAdminCap grants one AdminCap, then each role.
        let mut b = ProgrammableTransactionBuilder::new();
        let acl_arg = b.obj(h.shared(acl, true))?;
        let root_arg = b.obj(h.owned(root))?;
        let recipient = b.pure(h.sender)?;
        call(&mut b, admin, "blast_acl", "grant_admin", vec![], vec![acl_arg, root_arg, recipient]);
        let granted = h.impersonate_cap_owner(root, b.finish())?;
        granted.assert_success();
        let admin_cap = one(&h, &granted, "blast_acl", "AdminCap");

        let mut b = ProgrammableTransactionBuilder::new();
        let acl_arg = b.obj(h.shared(acl, true))?;
        let root_arg = b.obj(h.owned(root))?;
        let admin_cap_id = b.pure(admin_cap)?;
        for role in ADMIN_ROLES {
            let role_tag = tag(&format!("{blast}::blast_fun_domain::{role}"));
            call(&mut b, admin, "blast_acl", "grant_role", vec![role_tag], vec![acl_arg, root_arg, admin_cap_id]);
        }
        h.impersonate_cap_owner(root, b.finish())?.assert_success();

        let mut w = World {
            h,
            case,
            checkpoint,
            venue,
            admin,
            blast,
            migrators,
            version,
            migrators_version,
            runtime,
            config,
            venue_config,
            policy,
            acl,
            admin_cap,
            project,
            coins: 0,
            shares: DEFAULT_SHARES,
            lines: Vec::new(),
        };

        let mut b = ProgrammableTransactionBuilder::new();
        let listing_admin = w.sign_in(&mut b, "ListingAdmin")?;
        let adapter_admin = w.sign_in(&mut b, "AdapterAdmin")?;
        let fee_admin = w.sign_in(&mut b, "FeeAdmin")?;
        let treasury_admin = w.sign_in(&mut b, "TreasuryAdmin")?;
        let config = b.obj(w.h.shared(w.config, true))?;
        let version = b.obj(w.h.shared(w.version, false))?;
        let quote_allowed = b.pure(true)?;
        call(
            &mut b,
            blast,
            "launch_config",
            "set_quote_allowed",
            vec![case.quote()],
            vec![config, version, listing_admin, quote_allowed],
        );
        let witness = tag(&format!("{migrators}::{}::Witness", case.module()));
        let allowed = b.pure(true)?;
        call(
            &mut b,
            blast,
            "launch_config",
            "set_migration_witness_allowed",
            vec![witness],
            vec![config, version, adapter_admin, allowed],
        );
        let fee = w.bps(&mut b, 100)?;
        call(&mut b, blast, "launch_config", "set_trade_fees", vec![], vec![config, version, fee_admin, fee, fee]);
        let share = w.bps(&mut b, ALLOCATION_BPS)?;
        call(
            &mut b,
            blast,
            "launch_config",
            "set_protocol_allocation",
            vec![],
            vec![config, version, treasury_admin, share, share],
        );
        // Blast's LP-fee share goes to its own destination at a nonzero default.
        let policy = b.obj(w.h.shared(w.policy, true))?;
        let migrators_version = b.obj(w.h.shared(w.migrators_version, false))?;
        let destination = b.pure(SuiAddress::from(LP_PROTOCOL))?;
        call(
            &mut b,
            migrators,
            "lp_fee_policy",
            "set_protocol_destination",
            vec![],
            vec![policy, migrators_version, treasury_admin, destination],
        );
        let meme_bps = w.bps(&mut b, DEFAULT_SHARES.0)?;
        let quote_bps = w.bps(&mut b, DEFAULT_SHARES.1)?;
        call(
            &mut b,
            migrators,
            "lp_fee_policy",
            "set_default_shares",
            vec![],
            vec![policy, migrators_version, fee_admin, meme_bps, quote_bps],
        );
        w.h.execute(b.finish())?.assert_success();

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

    /// Signs the AdminCap in to the ACL as `role`; the witness it returns authorizes only that role.
    fn sign_in(&self, b: &mut ProgrammableTransactionBuilder, role: &str) -> Result<Argument> {
        let role_tag = tag(&format!("{}::blast_fun_domain::{role}", self.blast));
        let acl = b.obj(self.h.shared(self.acl, false))?;
        let admin_cap = b.obj(self.h.owned(self.admin_cap))?;

        Ok(call(b, self.admin, "blast_acl", "sign_in", vec![role_tag], vec![acl, admin_cap]))
    }

    fn bps(&self, b: &mut ProgrammableTransactionBuilder, value: u64) -> Result<Argument> {
        let value = b.pure_bytes(bcs::to_bytes(&value)?, true);

        Ok(call(b, self.blast, "bps", "new", vec![], vec![value]))
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

    /// Migrators events of `name`, which travel unwrapped from its own `blast_events`.
    fn events<T: DeserializeOwned>(&self, outcome: &Outcome, name: &str) -> Vec<T> {
        outcome
            .events
            .iter()
            .filter(|event| {
                ObjectID::from(event.type_.address) == self.migrators
                    && event.type_.module.as_str() == "blast_events"
                    && event.type_.name.as_str() == name
            })
            .map(|event| bcs::from_bytes(&event.contents).expect("event payload"))
            .collect()
    }

    /// Launchpad events of `name`, inside the launchpad envelope.
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
        bcs::from_bytes(&self.h.contents(m.vault)).context("decode LpVault")
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
    fn publish_ticket(&mut self) -> Result<(ObjectID, ObjectID, TypeTag)> {
        for _ in 0..16 {
            let (project_id, published) = self.h.publish(self.project.clone())?;
            let meme = tag(&format!("{project_id}::token::TOKEN"));
            if meme_is_cetus_a(&meme, &self.quote()) != self.case.meme_is_a() && self.case.is_cetus() {
                continue;
            }
            let ticket = published.created(&self.h, "launch_ticket", "LaunchTicket")[0];
            let pending = published.created(&self.h, "coin_registry", "Currency")[0];
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
            return Ok((ticket, currency, meme));
        }
        bail!("no generated Meme had the route's Cetus coin order")
    }

    /// One PTB: the adapter's `new` at `tier`, the setters, `finalize`, and `share`.
    fn create_launch_pt(
        &self,
        ticket: ObjectID,
        currency: ObjectID,
        meme: &TypeTag,
        split: &FeeSplit,
        tier: (u32, u64),
    ) -> Result<ProgrammableTransaction> {
        let mut b = ProgrammableTransactionBuilder::new();
        let pair = vec![meme.clone(), self.quote()];
        let ticket = b.obj(self.h.owned(ticket))?;
        let migrators_version = self.shared(&mut b, self.migrators_version, false)?;
        let version = self.shared(&mut b, self.version, false)?;
        let config = self.shared(&mut b, self.config, false)?;
        let tick_spacing = b.pure(tier.0)?;
        let initializer = if self.case.is_cetus() {
            let venue_config = self.shared(&mut b, self.venue_config, true)?;
            let cetus_config = self.shared(&mut b, self.venue("cetus_global_config"), false)?;
            let pools = self.shared(&mut b, self.venue("cetus_pools"), true)?;
            call(
                &mut b,
                self.migrators,
                "cetus",
                "new",
                pair.clone(),
                vec![ticket, migrators_version, version, config, venue_config, cetus_config, pools, tick_spacing],
            )
        } else {
            let fee_rate = b.pure(tier.1)?;
            call(
                &mut b,
                self.migrators,
                "bluefin",
                "new",
                pair.clone(),
                vec![ticket, migrators_version, version, config, tick_spacing, fee_rate],
            )
        };
        let virtual_quote = b.pure(5 * self.case.quote_unit())?;
        call(&mut b, self.blast, "launch", "set_virtual_quote", pair.clone(), vec![initializer, version, virtual_quote]);
        let target = b.pure(self.target())?;
        call(&mut b, self.blast, "launch", "set_graduation_target", pair.clone(), vec![initializer, version, target]);
        let plan = self.plan_arg(&mut b)?;
        call(&mut b, self.blast, "launch", "set_allocation_plan", pair.clone(), vec![initializer, version, plan]);
        let split = self.fee_split_arg(&mut b, split)?;
        call(&mut b, self.blast, "launch", "set_lp_fee_split", pair.clone(), vec![initializer, version, split]);
        let currency = self.shared(&mut b, currency, true)?;
        let creation_fee = call(&mut b, SUI_FRAMEWORK_PACKAGE_ID, "coin", "zero", vec![sui()], vec![]);
        let launch = call(&mut b, self.blast, "launch", "finalize", pair.clone(), vec![
            initializer, version,
            currency,
            config,
            creation_fee,
        ]);
        let clock = self.clock(&mut b)?;
        call(&mut b, self.blast, "launch", "share", pair, vec![launch, version, clock]);

        Ok(b.finish())
    }

    fn target(&self) -> u64 {
        25 * self.case.quote_unit()
    }

    fn lp_quote(&self) -> u64 {
        self.target() / 10 * 9
    }

    /// Rejects tiers the venue would refuse, rolled back, then starts the launch at a valid tier
    /// and checks what it records.
    fn start_launch(&mut self, split: &FeeSplit) -> Result<Launch> {
        let (ticket, currency, meme) = self.publish_ticket()?;
        let owners = [self.h.sender];
        if self.case.is_cetus() {
            let watched = [ticket, currency, self.venue_config, self.venue("cetus_pools")];
            let pt = self.create_launch_pt(ticket, currency, &meme, split, (CETUS_UNREGISTERED_SPACING, 0))?;
            self.h.assert_rolled_back(pt, self.cetus_abort("config", 2), &watched, &owners)?;
            self.report(format!(
                "cetus::new at unregistered tick spacing {CETUS_UNREGISTERED_SPACING}: Cetus config aborts 2, rolled back"
            ));
            let pt = self.create_launch_pt(ticket, currency, &meme, split, (CETUS_UNADMITTED_SPACING, 0))?;
            self.h.assert_rolled_back(pt, self.cetus_abort("factory", 8), &watched, &owners)?;
            self.report(format!(
                "cetus::new at registered but unadmitted tick spacing {CETUS_UNADMITTED_SPACING}: Cetus factory aborts 8, rolled back"
            ));
        } else {
            for tier in [
                (0, BLUEFIN_FEE_RATE),
                (401, BLUEFIN_FEE_RATE),
                (BLUEFIN_TICK_SPACING, 0),
                (BLUEFIN_TICK_SPACING, 20_001),
            ] {
                let pt = self.create_launch_pt(ticket, currency, &meme, split, tier)?;
                let expected = Expected::Abort { package: self.migrators, module: "bluefin", code: 1 };
                self.h.assert_rolled_back(pt, expected, &[ticket, currency], &owners)?;
            }
            self.report(
                "bluefin::new at (0, 3000), (401, 3000), (60, 0), (60, 20001): EInvalidTier, rolled back".into(),
            );
        }

        let tier = if self.case.is_cetus() {
            (CETUS_TICK_SPACING, CETUS_FEE_RATE)
        } else {
            (BLUEFIN_TICK_SPACING, BLUEFIN_FEE_RATE)
        };
        let pt = self.create_launch_pt(ticket, currency, &meme, split, tier)?;
        let created = self.h.execute(pt)?;
        created.assert_success();
        let launches = created.created(&self.h, "launch", "Launch");
        ensure!(launches.len() == 1 && self.h.object(launches[0]).is_shared());
        let launch = Launch { meme, launch: launches[0], currency, split: split.clone() };
        let recorded: Vec<LaunchCreated> = self.launchpad_events(&created, "LaunchCreated");
        ensure!(recorded.len() == 1);
        let recorded = &recorded[0];
        ensure!((recorded.pool_tick_spacing, recorded.pool_fee_rate) == tier, "the launch records the tier");
        ensure!(recorded.lp_fee_split == *split, "the launch records the fee split");
        ensure!(recorded.migration_witness.ends_with(&format!("::{}::Witness", self.case.module())));

        if self.case.is_cetus() {
            // The Meme type's one PoolCreationCap is minted, registered for the pair at the
            // tier, and kept under VenueConfig.
            let reserved: Vec<CetusPoolReserved> = self.events(&created, "CetusPoolReserved");
            let registered: Vec<RegisterPermissionPair> =
                venue_events(&created, "factory", "RegisterPermissionPairEvent");
            let minted: Vec<MintPoolCreationCap> = venue_events(&created, "factory", "MintPoolCreationCap");
            ensure!(reserved.len() == 1 && registered.len() == 1 && minted.len() == 1);
            let cap = reserved[0].pool_creation_cap_id;
            ensure!(reserved[0].tick_spacing == CETUS_TICK_SPACING && registered[0].tick_spacing == CETUS_TICK_SPACING);
            ensure!(registered[0].cap == cap && minted[0].cap == cap);
            ensure!(
                registered[0].coin_type == cetus_name(&launch.meme)
                    && registered[0].coin_pair == cetus_name(&self.quote())
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
                "cetus::new at tick spacing {} registers fee rate {} from Cetus; PoolCreationCap {cap} minted, pair registered, kept under VenueConfig",
                tier.0, tier.1
            ));
        } else {
            self.report(format!("bluefin::new at {tier:?}: launch records the tier"));
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

    /// The migration call with `types` as its type arguments; Bluefin pays `creation_fee` SUI, or
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
        let currency = self.shared(b, launch.currency, true)?;
        let clock = self.clock(b)?;
        if self.case.is_cetus() {
            let venue_config = self.shared(b, self.venue_config, false)?;
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
                    launch_arg,
                    migrators_version,
                    version,
                    currency,
                    venue_config,
                    cetus_config,
                    pools,
                    burn_manager,
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
                    launch_arg,
                    migrators_version,
                    version,
                    currency,
                    quote_currency,
                    bluefin_config,
                    Argument::NestedResult(fee, 0),
                    clock,
                ],
            );
        }

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
        let owners = [self.h.sender, DESTINATION.into()];
        let mut b = ProgrammableTransactionBuilder::new();
        self.migrate_command(&mut b, launch, self.route_types(launch), None)?;
        self.migrate_command(&mut b, launch, self.route_types(launch), None)?;
        let expected = Expected::Abort { package: self.blast, module: "launch", code: INVALID_LAUNCH_LIFECYCLE };
        self.h.assert_rolled_back(b.finish(), expected, &watched, &owners)?;
        ensure!(self.launch_lifecycle(launch) == MIGRATION_READY, "the launch stays MigrationReady");
        self.report("PTB [migrate (pool created, position custodied), migrate again]: launch aborts invalid_launch_lifecycle, nothing committed, launch MigrationReady".into());

        if !self.case.is_cetus() {
            // Bluefin charges exactly its configured SUI creation fee.
            let fee = self.bluefin_creation_fee()?;
            let mut b = ProgrammableTransactionBuilder::new();
            self.migrate_command(&mut b, launch, self.route_types(launch), Some(fee + 1))?;
            let expected = Expected::Abort { package: id(BLUEFIN), module: "pool", code: 1039 };
            self.h.assert_rolled_back(b.finish(), expected, &watched, &owners)?;
            self.report(format!("migrate paying {} MIST against the live {fee} MIST creation fee: Bluefin pool aborts 1039, rolled back", fee + 1));
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

        let created: Vec<VaultCreated> = self.events(&outcome, "VaultCreated");
        ensure!(created.len() == 1 && created[0].fee_split == launch.split);
        let created = &created[0];
        ensure!(created.venue.ends_with(&format!("::{}::Venue", self.case.module())));
        let vault_id = created.vault_id;
        ensure!(self.h.object(vault_id).is_shared() && self.h.object(created.pool_id).is_shared());
        let supplied = (migrated.meme - created.residual_meme, migrated.quote - created.residual_quote);
        let m = Migration {
            pool: created.pool_id,
            vault: vault_id,
            position: created.position_id,
            auto_lp_position: None,
            liquidity: created.liquidity,
        };
        let vault = self.vault(&m)?;
        ensure!(vault.pool_id == m.pool && vault.fee_split == launch.split);
        ensure!(
            (vault.protocol_meme_residual, vault.protocol_quote_residual)
                == (created.residual_meme, created.residual_quote)
        );
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
            ensure!(pools.len() == 1 && pools[0].pool_id == m.pool && pools[0].tick_spacing == CETUS_TICK_SPACING);
            let state = self.cetus_pool(&m)?;
            ensure!(
                (state.tick_spacing, state.fee_rate) == (CETUS_TICK_SPACING, CETUS_FEE_RATE),
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
        let spacing = if self.case.is_cetus() { CETUS_TICK_SPACING } else { BLUEFIN_TICK_SPACING } as i32;
        ensure!(lower == -(443_636 / spacing * spacing) && upper == 443_636 / spacing * spacing, "full range");
        ensure!(
            sqrt_price == expected_sqrt_price(LP_MEME, self.lp_quote(), self.case.meme_is_a()),
            "the opening price is the exact Q64.64 ratio of the hand-off"
        );

        self.report(format!(
            "migrate ({:?}): pool {} tier ({}, {}) ticks ({lower}, {upper}) sqrt_price {sqrt_price}; supplied=({}, {}) residual=({}, {}) liquidity {}; Blast and recipient allocations ({}, {}) each paid; {}",
            self.case,
            m.pool,
            if self.case.is_cetus() { CETUS_TICK_SPACING } else { BLUEFIN_TICK_SPACING },
            if self.case.is_cetus() { CETUS_FEE_RATE } else { BLUEFIN_FEE_RATE },
            supplied.0,
            supplied.1,
            created.residual_meme,
            created.residual_quote,
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
        let policy = self.shared(&mut b, self.policy, false)?;
        let mut args = vec![vault, migrators_version, policy];
        if let Some((cap, _)) = update {
            args.push(self.shared(&mut b, launch.launch, false)?);
            args.push(b.obj(self.h.owned(cap))?);
        }
        args.push(self.shared(&mut b, launch.currency, true)?);
        if self.case.is_cetus() {
            args.push(self.shared(&mut b, self.venue("cetus_global_config"), false)?);
            args.push(self.shared(&mut b, self.venue("cetus_burn_manager"), false)?);
        } else {
            args.push(self.shared(&mut b, self.venue("bluefin_global_config"), false)?);
        }
        args.push(self.shared(&mut b, pool, true)?);
        if let Some((_, split)) = update {
            args.push(self.fee_split_arg(&mut b, split)?);
        }
        args.push(self.clock(&mut b)?);
        let function = match update {
            Some(_) => "settle_and_update_fee_split",
            None => "collect_fees",
        };
        call(&mut b, self.migrators, self.case.module(), function, self.route_types(launch), args);

        Ok(b.finish())
    }

    /// A permissionless collection, or with `update` the settled split update under `cap`; checks
    /// every amount against the venue's collection, Blast's live share, and the vault's split.
    fn collect(
        &mut self,
        launch: &Launch,
        m: &mut Migration,
        update: Option<(ObjectID, &FeeSplit)>,
    ) -> Result<Collection> {
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
        let fees: Vec<FeesCollected> = self.events(&outcome, "FeesCollected");
        ensure!(fees.len() == 1, "one FeesCollected");
        let fees = fees[0].clone();
        ensure!((fees.gross_meme, fees.gross_quote) == (venue_meme, venue_quote), "gross is the venue's collection");
        ensure!(fees.vault_id == m.vault);

        // Blast's live share, rounded up, then the split apportioned exactly.
        let expected = expected_fees(&before, self.shares, venue_meme, venue_quote);
        ensure!(fees == expected, "FeesCollected {fees:?} != expected {expected:?}");
        let mut payees: BTreeMap<SuiAddress, (u64, u64)> = BTreeMap::new();
        *payees.entry(LP_PROTOCOL.into()).or_default() = (fees.protocol_meme, fees.protocol_quote);
        // The fixture's supply is fixed, so the burn share's Meme goes to `@0x0`.
        *payees.entry(SuiAddress::ZERO).or_default() = (fees.burn_meme, 0);
        for (i, recipient) in before.fee_split.recipients.iter().enumerate() {
            let entry = payees.entry(recipient.destination).or_default();
            entry.0 += fees.recipient_meme[i];
            entry.1 += fees.recipient_quote[i];
        }
        for (payee, (meme, quote)) in payees {
            ensure!(outcome.coins_created_for(&self.h, payee) == self.coins(launch, meme, quote), "{payee} paid");
        }

        // Auto-LP: added amounts are what the venue took; the rest waits.
        let added: Vec<AutoLiquidityAdded> = self.events(&outcome, "AutoLiquidityAdded");
        ensure!(added.len() <= 1);
        let added = added.into_iter().next();
        let after = self.vault(m)?;
        let offered = (before.auto_lp_meme + fees.auto_lp_meme, before.auto_lp_quote + fees.auto_lp_quote);
        let taken = added.as_ref().map_or((0, 0), |a| (a.meme_amount, a.quote_amount));
        ensure!(
            (after.auto_lp_meme, after.auto_lp_quote) == (offered.0 - taken.0, offered.1 - taken.1),
            "the rest waits"
        );
        ensure!(
            (after.creator_meme, after.creator_quote)
                == (before.creator_meme + fees.creator_meme, before.creator_quote + fees.creator_quote)
        );
        ensure!(
            (after.rewards_meme, after.rewards_quote)
                == (before.rewards_meme + fees.rewards_meme, before.rewards_quote + fees.rewards_quote)
        );
        ensure!(after.burn_quote == before.burn_quote + fees.burn_quote, "the burn Quote waits for a buyback");
        let opened: Vec<AutoLpPositionOpened> = self.events(&outcome, "AutoLpPositionOpened");
        let liquidity_after = self.position_liquidity(m.position)?;
        if let Some(added) = &added {
            ensure!((added.meme_pending, added.quote_pending) == (after.auto_lp_meme, after.auto_lp_quote));
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
                added.meme_pending,
                added.quote_pending,
                self.position_liquidity(position)?,
            ));
        } else {
            ensure!(opened.is_empty() && liquidity_after == liquidity_before, "nothing added");
        }
        ensure!(!self.case.is_cetus() || liquidity_after == m.liquidity, "the burned position keeps its liquidity");

        let names = migrators_event_names(&outcome, self.migrators);
        if let Some((_, split)) = update {
            let changed: Vec<FeeSplitChanged> = self.events(&outcome, "FeeSplitChanged");
            ensure!(changed.len() == 1 && names.last().map(String::as_str) == Some("FeeSplitChanged"), "{names:?}");
            ensure!(names.first().map(String::as_str) == Some("FeesCollected"), "settles first: {names:?}");
            let changed = &changed[0];
            ensure!(changed.old_fee_split == before.fee_split && changed.new_fee_split == *split);
            ensure!(after.fee_split == *split);
        } else {
            ensure!(after.fee_split == before.fee_split);
        }

        Ok(Collection { fees, added })
    }

    fn set_coin_shares(&mut self, launch: &Launch, shares: (u64, u64)) -> Result<()> {
        let mut b = ProgrammableTransactionBuilder::new();
        let signed_in = self.sign_in(&mut b, "FeeAdmin")?;
        let policy = self.shared(&mut b, self.policy, true)?;
        let migrators_version = self.shared(&mut b, self.migrators_version, false)?;
        let meme_bps = self.bps(&mut b, shares.0)?;
        let quote_bps = self.bps(&mut b, shares.1)?;
        call(
            &mut b,
            self.migrators,
            "lp_fee_policy",
            "set_coin_shares",
            vec![launch.meme.clone()],
            vec![policy, migrators_version, signed_in, meme_bps, quote_bps],
        );
        self.h.execute(b.finish())?.assert_success();
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

    fn claim_creator_fees_pt(&self, launch: &Launch, m: &Migration, cap: ObjectID) -> Result<ProgrammableTransaction> {
        let mut b = ProgrammableTransactionBuilder::new();
        let vault = self.shared(&mut b, m.vault, true)?;
        let migrators_version = self.shared(&mut b, self.migrators_version, false)?;
        let launch_arg = self.shared(&mut b, launch.launch, false)?;
        let cap = b.obj(self.h.owned(cap))?;
        let Argument::Result(claimed) = call(
            &mut b,
            self.migrators,
            "vault",
            "claim_creator_fees",
            self.pair(launch),
            vec![vault, migrators_version, launch_arg, cap],
        ) else {
            unreachable!()
        };
        b.transfer_args(self.h.sender, vec![Argument::NestedResult(claimed, 0), Argument::NestedResult(claimed, 1)]);

        Ok(b.finish())
    }

    fn claim_creator_fees(&mut self, launch: &Launch, m: &Migration, cap: ObjectID) -> Result<()> {
        let before = self.vault(m)?;
        ensure!(before.creator_meme > 0 && before.creator_quote > 0, "the creator share accrued");
        let pt = self.claim_creator_fees_pt(launch, m, cap)?;
        let outcome = self.h.execute(pt)?;
        outcome.assert_success();
        let claimed: Vec<CreatorFeesClaimed> = self.events(&outcome, "CreatorFeesClaimed");
        ensure!(
            claimed.len() == 1
                && (claimed[0].meme_amount, claimed[0].quote_amount) == (before.creator_meme, before.creator_quote)
        );
        ensure!(
            outcome.coins_created_for(&self.h, self.h.sender)
                == self.coins(launch, before.creator_meme, before.creator_quote)
        );
        let after = self.vault(m)?;
        ensure!((after.creator_meme, after.creator_quote) == (0, 0));
        self.report(format!(
            "claim_creator_fees with the live cap: ({}, {})",
            before.creator_meme, before.creator_quote
        ));

        Ok(())
    }

    /// An administrator reassigns the curve-fee cap; the creator's old cap then neither updates
    /// the split nor claims.
    fn retired_cap_is_refused(
        &mut self,
        launch: &Launch,
        m: &Migration,
        cap: ObjectID,
        split: &FeeSplit,
    ) -> Result<()> {
        let mut b = ProgrammableTransactionBuilder::new();
        let signed_in = self.sign_in(&mut b, "CreatorAdmin")?;
        let launch_arg = self.shared(&mut b, launch.launch, true)?;
        let version = self.shared(&mut b, self.version, false)?;
        let recipient = b.pure(SuiAddress::from(CAP_HOLDER))?;
        call(
            &mut b,
            self.blast,
            "launch",
            "reassign_curve_fee_cap",
            self.pair(launch),
            vec![launch_arg, version, signed_in, recipient],
        );
        self.h.execute(b.finish())?.assert_success();

        let owners = [self.h.sender, LP_PROTOCOL.into(), RECIPIENT_C.into()];
        let refused = Expected::Abort { package: self.blast, module: "launch", code: CREATOR_CAP_NOT_LIVE };
        let mut next = split.clone();
        next.creator_bps -= 1_000;
        next.rewards_bps += 1_000;
        let pt = self.collect_pt(launch, m, m.pool, Some((cap, &next)))?;
        self.h.assert_rolled_back(pt, refused, &[m.vault, m.pool, cap, launch.currency], &owners)?;
        let refused = Expected::Abort { package: self.blast, module: "launch", code: CREATOR_CAP_NOT_LIVE };
        let pt = self.claim_creator_fees_pt(launch, m, cap)?;
        self.h.assert_rolled_back(pt, refused, &[m.vault, cap], &owners)?;
        self.report("after reassign_curve_fee_cap the retired cap: settle_and_update_fee_split and claim_creator_fees abort launch creator_cap_not_live, rolled back".into());

        Ok(())
    }

    fn buyback_pt(
        &self,
        launch: &Launch,
        m: &Migration,
        pool: ObjectID,
        min_meme_out: u64,
    ) -> Result<ProgrammableTransaction> {
        let mut b = ProgrammableTransactionBuilder::new();
        let signed_in = self.sign_in(&mut b, "BuybackAdmin")?;
        let vault = self.shared(&mut b, m.vault, true)?;
        let migrators_version = self.shared(&mut b, self.migrators_version, false)?;
        let currency = self.shared(&mut b, launch.currency, true)?;
        let config = if self.case.is_cetus() { "cetus_global_config" } else { "bluefin_global_config" };
        let config = self.shared(&mut b, self.venue(config), false)?;
        let pool = self.shared(&mut b, pool, true)?;
        let min_meme_out = b.pure(min_meme_out)?;
        let clock = self.clock(&mut b)?;
        call(
            &mut b,
            self.migrators,
            self.case.module(),
            "buyback_and_burn",
            self.route_types(launch),
            vec![vault, migrators_version, signed_in, currency, config, pool, min_meme_out, clock],
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
        let refused = Expected::Abort { package: self.migrators, module: "vault", code: BUYBACK_BELOW_MINIMUM };
        let pt = self.buyback_pt(launch, m, m.pool, u64::MAX)?;
        self.h.assert_rolled_back(pt, refused, &[m.vault, m.pool, launch.currency, self.admin_cap], &owners)?;

        let pt = self.buyback_pt(launch, m, m.pool, 1)?;
        let outcome = self.h.execute(pt)?;
        outcome.assert_success();
        let burned: Vec<BuybackBurned> = self.events(&outcome, "BuybackBurned");
        ensure!(burned.len() == 1 && burned[0].vault_id == m.vault, "one BuybackBurned");
        let burned = &burned[0];
        ensure!(
            (burned.quote_spent, burned.quote_pending) == (before.burn_quote, 0),
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
            (after.creator_meme, after.creator_quote, after.auto_lp_meme, after.auto_lp_quote)
                == (before.creator_meme, before.creator_quote, before.auto_lp_meme, before.auto_lp_quote)
                && (after.rewards_meme, after.rewards_quote) == (before.rewards_meme, before.rewards_quote),
            "a buyback touches only the burn Quote"
        );
        self.report(format!(
            "buyback_and_burn ({:?}): min above the pool's output aborts vault EBuybackBelowMinimum, rolled back; \
             then {} Quote bought and burned {} Meme at @0x0",
            self.case,
            burned.quote_spent,
            burned.meme_burned,
        ));

        Ok(())
    }

    /// Anyone can create another pool of the same type (Cetus at an unreserved tick spacing,
    /// Bluefin at any tier); collecting the vault against it is refused before any venue call.
    fn other_pool_is_refused(&mut self, launch: &Launch, m: &Migration) -> Result<()> {
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
        let code = if self.case.is_cetus() { 1 } else { 0 };
        let expected = Expected::Abort { package: self.migrators, module, code };
        let pt = self.collect_pt(launch, m, other, None)?;
        let watched = [m.vault, other, launch.currency];
        self.h.assert_rolled_back(pt, expected, &watched, &[self.h.sender, LP_PROTOCOL.into()])?;
        let expected = Expected::Abort { package: self.migrators, module, code };
        let pt = self.buyback_pt(launch, m, other, 1)?;
        let watched = [m.vault, other, launch.currency, self.admin_cap];
        self.h.assert_rolled_back(pt, expected, &watched, &[self.h.sender, SuiAddress::ZERO])?;
        self.report(format!(
            "collect and buyback against another {} pool {other}: EPositionPoolMismatch, rolled back",
            if self.case.is_cetus() { "Cetus Pool<A, B> at tick spacing 60" } else { "Bluefin Pool<Meme, SUI>" }
        ));

        Ok(())
    }

    /// An administrator claims the migration residuals the venue did not take.
    fn claim_protocol_residuals(&mut self, launch: &Launch, m: &Migration) -> Result<()> {
        let before = self.vault(m)?;
        let mut b = ProgrammableTransactionBuilder::new();
        let signed_in = self.sign_in(&mut b, "TreasuryAdmin")?;
        let vault = self.shared(&mut b, m.vault, true)?;
        let migrators_version = self.shared(&mut b, self.migrators_version, false)?;
        let Argument::Result(claimed) = call(
            &mut b,
            self.migrators,
            "vault",
            "claim_protocol_fees",
            self.pair(launch),
            vec![vault, migrators_version, signed_in],
        ) else {
            unreachable!()
        };
        b.transfer_args(self.h.sender, vec![Argument::NestedResult(claimed, 0), Argument::NestedResult(claimed, 1)]);
        let outcome = self.h.execute(b.finish())?;
        outcome.assert_success();
        let residuals = (before.protocol_meme_residual, before.protocol_quote_residual);
        let claimed: Vec<ProtocolFeesClaimed> = self.events(&outcome, "ProtocolFeesClaimed");
        ensure!(claimed.len() == 1 && (claimed[0].meme_amount, claimed[0].quote_amount) == residuals);
        // Both coins are returned, a zero-value one included.
        let mut coins = vec![
            (launch.meme.to_canonical_string(true), residuals.0),
            (self.quote().to_canonical_string(true), residuals.1),
        ];
        coins.sort();
        ensure!(outcome.coins_created_for(&self.h, self.h.sender) == coins);
        let after = self.vault(m)?;
        ensure!((after.protocol_meme_residual, after.protocol_quote_residual) == (0, 0));
        self.report(format!("claim_protocol_fees pays the migration residuals {residuals:?}"));

        Ok(())
    }

    /// An administrator publishes a two-leaf round from the rewards balance; a relayed proof pays
    /// the first beneficiary once.
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

        let mut b = ProgrammableTransactionBuilder::new();
        let signed_in = self.sign_in(&mut b, "RewardsAdmin")?;
        let vault = self.shared(&mut b, m.vault, true)?;
        let migrators_version = self.shared(&mut b, self.migrators_version, false)?;
        let args = vec![
            vault,
            migrators_version,
            signed_in,
            b.pure(0u64)?,
            b.pure(start)?,
            b.pure(end)?,
            b.pure(root.to_vec())?,
            b.pure(vec![0x5Au8; 32])?,
            b.pure(2u64)?,
            b.pure(meme)?,
            b.pure(quote)?,
        ];
        let meme_type = launch.meme.clone();
        call(
            &mut b,
            self.migrators,
            "blast_holder_rewards",
            "publish_round",
            vec![meme_type.clone(), self.quote()],
            args,
        );
        let outcome = self.h.execute(b.finish())?;
        outcome.assert_success();
        let rounds = outcome.created(&self.h, "blast_holder_rewards", "Round");
        ensure!(rounds.len() == 1 && self.h.object(rounds[0]).is_shared());
        let round = rounds[0];
        let published: Vec<RoundPublished> = self.events(&outcome, "RoundPublished");
        ensure!(published.len() == 1 && published[0].round_id == round && published[0].root == root.to_vec());
        ensure!((published[0].meme_amount, published[0].quote_amount) == (meme, quote));
        let after = self.vault(m)?;
        ensure!(
            (after.rewards_meme, after.rewards_quote) == (before.rewards_meme - meme, before.rewards_quote - quote)
        );
        ensure!(
            (published[0].meme_unallocated, published[0].quote_unallocated)
                == (after.rewards_meme, after.rewards_quote)
        );
        ensure!(after.next_round == 1 && after.last_checkpoint == Some(end));

        let claim = |w: &Self| -> Result<ProgrammableTransaction> {
            let mut b = ProgrammableTransactionBuilder::new();
            let round = w.shared(&mut b, round, true)?;
            let migrators_version = w.shared(&mut b, w.migrators_version, false)?;
            let (beneficiary, meme, quote) = leaves[0];
            let args = vec![
                round,
                migrators_version,
                b.pure(0u64)?,
                b.pure(SuiAddress::from(beneficiary))?,
                b.pure(meme)?,
                b.pure(quote)?,
                b.pure(vec![digests[1].to_vec()])?,
            ];
            call(&mut b, w.migrators, "blast_holder_rewards", "claim", vec![meme_type.clone(), w.quote()], args);
            Ok(b.finish())
        };
        let pt = claim(self)?;
        let outcome = self.h.execute(pt)?;
        outcome.assert_success();
        let paid: Vec<RewardPaid> = self.events(&outcome, "RewardPaid");
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
        let expected = Expected::Abort { package: self.migrators, module: "blast_holder_rewards", code: 6 };
        let pt = claim(self)?;
        self.h.assert_rolled_back(pt, expected, &[round], &[beneficiary.into()])?;
        self.report(format!(
            "publish_round funds ({meme}, {quote}) from rewards; Merkle claim pays {beneficiary} ({meme_paid}, {quote_paid}); a second claim aborts 6"
        ));

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
        let share = self.bps(b, ALLOCATION_BPS)?;
        let recipient = call(b, self.blast, "allocation", "recipient", vec![], vec![destination, share, share]);
        let recipient_type = tag(&format!("{}::allocation::Recipient", self.blast));
        let recipients = b.command(Command::make_move_vec(Some(recipient_type), vec![recipient]));
        let curve_meme = self.bps(b, 7_000)?;
        let lp_meme = self.bps(b, 2_000)?;
        let lp_quote = self.bps(b, 9_000)?;

        Ok(call(b, self.blast, "allocation", "plan", vec![], vec![curve_meme, lp_meme, lp_quote, recipients]))
    }

    fn fee_split_arg(&self, b: &mut ProgrammableTransactionBuilder, split: &FeeSplit) -> Result<Argument> {
        let mut recipients = Vec::new();
        for recipient in &split.recipients {
            let destination = b.pure(recipient.destination)?;
            let bps = self.bps(b, recipient.bps)?;
            recipients.push(call(b, self.blast, "allocation", "route", vec![], vec![destination, bps]));
        }
        let route_type = tag(&format!("{}::allocation::Route", self.blast));
        let recipients = b.command(Command::make_move_vec(Some(route_type), recipients));
        let creator_bps = self.bps(b, split.creator_bps)?;
        let auto_lp_bps = self.bps(b, split.auto_lp_bps)?;
        let rewards_bps = self.bps(b, split.rewards_bps)?;
        let burn_bps = self.bps(b, split.burn_bps)?;

        Ok(call(
            b,
            self.blast,
            "allocation",
            "fee_split",
            vec![],
            vec![creator_bps, auto_lp_bps, rewards_bps, burn_bps, recipients],
        ))
    }
}

// === Blast arithmetic ===

fn expected_fees(vault: &Vault, shares: (u64, u64), gross_meme: u64, gross_quote: u64) -> FeesCollected {
    let protocol = |gross: u64, bps: u64| (gross as u128 * bps as u128).div_ceil(10_000) as u64;
    let split = &vault.fee_split;
    let mut weights = vec![split.creator_bps, split.auto_lp_bps, split.rewards_bps, split.burn_bps];
    weights.extend(split.recipients.iter().map(|route| route.bps));
    let (protocol_meme, protocol_quote) = (protocol(gross_meme, shares.0), protocol(gross_quote, shares.1));
    let meme = apportion(&weights, gross_meme - protocol_meme);
    let quote = apportion(&weights, gross_quote - protocol_quote);
    FeesCollected {
        vault_id: vault.id,
        gross_meme,
        gross_quote,
        protocol_destination: Some(LP_PROTOCOL.into()),
        protocol_meme,
        protocol_quote,
        creator_meme: meme[0],
        creator_quote: quote[0],
        auto_lp_meme: meme[1],
        auto_lp_quote: quote[1],
        rewards_meme: meme[2],
        rewards_quote: quote[2],
        burn_meme: meme[3],
        burn_quote: quote[3],
        recipient_meme: meme[4..].to_vec(),
        recipient_quote: quote[4..].to_vec(),
    }
}

/// `merkle::leaf`: Blake2b-256 over the leaf domain and the BCS of every committed value.
fn reward_leaf(vault: ObjectID, round: u64, index: u64, beneficiary: SuiAddress, meme: u64, quote: u64) -> [u8; 32] {
    let mut bytes = b"\x00blast-holder-rewards-v1".to_vec();
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

fn migrators_event_names(outcome: &Outcome, migrators: ObjectID) -> Vec<String> {
    outcome
        .events
        .iter()
        .filter(|event| ObjectID::from(event.type_.address) == migrators)
        .map(|event| event.type_.name.to_string())
        .collect()
}

#[derive(Clone, Debug, Default, Deserialize, PartialEq, Serialize)]
struct FeeSplit {
    creator_bps: u64,
    auto_lp_bps: u64,
    rewards_bps: u64,
    burn_bps: u64,
    recipients: Vec<Recipient>,
}

/// Mirrors `blast_fun::allocation::Route`.
#[derive(Clone, Debug, Default, Deserialize, PartialEq, Serialize)]
struct Recipient {
    destination: SuiAddress,
    bps: u64,
}

/// Mirrors `blast_fun_migrators::vault::LpVault`; each `Balance` is one `u64`.
#[derive(Debug, Deserialize)]
struct Vault {
    id: ObjectID,
    pool_id: ObjectID,
    _partner_id: Option<ObjectID>,
    protocol_meme_residual: u64,
    protocol_quote_residual: u64,
    _unpaid_protocol_meme: u64,
    _unpaid_protocol_quote: u64,
    fee_split: FeeSplit,
    creator_meme: u64,
    creator_quote: u64,
    auto_lp_meme: u64,
    auto_lp_quote: u64,
    rewards_meme: u64,
    rewards_quote: u64,
    burn_quote: u64,
    next_round: u64,
    last_checkpoint: Option<u64>,
}

#[derive(Deserialize)]
struct LaunchCreated {
    _launch_id: ObjectID,
    _ticket_id: ObjectID,
    _quote: String,
    migration_witness: String,
    pool_tick_spacing: u32,
    pool_fee_rate: u64,
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
    _allocation_recipients: Vec<(SuiAddress, u64, u64)>,
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
}

#[derive(Deserialize)]
struct ProtocolFeesAccrued {
    launch_id: ObjectID,
    meme_amount: u64,
    quote_amount: u64,
}

#[derive(Deserialize)]
struct CetusPoolReserved {
    _meme: String,
    _quote: String,
    pool_creation_cap_id: ObjectID,
    tick_spacing: u32,
}

#[derive(Deserialize)]
struct VaultCreated {
    vault_id: ObjectID,
    pool_id: ObjectID,
    position_id: ObjectID,
    venue: String,
    _meme: String,
    _quote: String,
    residual_meme: u64,
    residual_quote: u64,
    liquidity: u128,
    fee_split: FeeSplit,
}

#[derive(Clone, Debug, Deserialize, PartialEq)]
struct FeesCollected {
    vault_id: ObjectID,
    gross_meme: u64,
    gross_quote: u64,
    /// None when a partnered vault holds Blast's share for the partner claim.
    protocol_destination: Option<SuiAddress>,
    protocol_meme: u64,
    protocol_quote: u64,
    creator_meme: u64,
    creator_quote: u64,
    auto_lp_meme: u64,
    auto_lp_quote: u64,
    rewards_meme: u64,
    rewards_quote: u64,
    burn_meme: u64,
    burn_quote: u64,
    recipient_meme: Vec<u64>,
    recipient_quote: Vec<u64>,
}

#[derive(Deserialize)]
struct BuybackBurned {
    vault_id: ObjectID,
    quote_spent: u64,
    meme_burned: u64,
    quote_pending: u64,
}

#[derive(Deserialize)]
struct AutoLiquidityAdded {
    _vault_id: ObjectID,
    meme_amount: u64,
    quote_amount: u64,
    meme_pending: u64,
    quote_pending: u64,
}

#[derive(Deserialize)]
struct AutoLpPositionOpened {
    _vault_id: ObjectID,
    position_id: ObjectID,
}

#[derive(Deserialize)]
struct FeeSplitChanged {
    _vault_id: ObjectID,
    old_fee_split: FeeSplit,
    new_fee_split: FeeSplit,
}

#[derive(Deserialize)]
struct CreatorFeesClaimed {
    _vault_id: ObjectID,
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
    root: Vec<u8>,
    _manifest_digest: Vec<u8>,
    _leaf_count: u64,
    meme_amount: u64,
    quote_amount: u64,
    meme_unallocated: u64,
    quote_unallocated: u64,
}

#[derive(Deserialize)]
struct ProtocolFeesClaimed {
    _vault_id: ObjectID,
    _meme: String,
    _quote: String,
    _claimant: SuiAddress,
    meme_amount: u64,
    quote_amount: u64,
}

#[derive(Deserialize)]
struct RewardPaid {
    _round_id: ObjectID,
    index: u64,
    beneficiary: SuiAddress,
    meme_amount: u64,
    quote_amount: u64,
    meme_remaining: u64,
    quote_remaining: u64,
}
