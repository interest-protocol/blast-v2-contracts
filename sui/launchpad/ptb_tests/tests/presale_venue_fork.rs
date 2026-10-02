//! Venue-fork gate for `blast_presale`: the presale's Cetus and Bluefin adapters against real
//! Cetus CLMM, Cetus LP Burn, and Bluefin Spot mainnet bytecode, offline.
//!
//! Each world inserts the committed mainnet snapshot (`fork/`, see `blast_launchpad_ptb_tests::fork`)
//! into the in-memory simulator at the real IDs, then publishes `blast_admin` and `blast_presale`
//! linked to the real venue packages exactly as the presale manifest pins them. No transaction
//! reaches a network.
//!
//! One lifecycle test per route runs through public PTBs: Cetus with Meme as coin A (SUI Quote),
//! Cetus with Meme as coin B (USDC Quote), and Bluefin (SUI Quote). Each creates a presale with
//! open eligibility, commits with overflow, settles after the window, and shows that a migration
//! aborting after pool creation commits nothing, that Cetus refuses the reversed coin order and a
//! foreign pair, and that Bluefin charges exactly its configured creation fee. One PTB then
//! migrates into a new full-range pool at the configured tier, pays the recipient allocations, and
//! seals the position (the LP Burn proof on Cetus) in a shared `PresaleVault`; supplied plus
//! residual reconciles exactly with the hand-off. The participant claims its tokens and overflow,
//! real swaps accrue fees, permissionless collections pay every fee recipient and grow the vault's
//! holder-reward share by the exact apportionment, collection against another pool of the same type
//! is refused, and the creator claims the migration residuals.
//!
//! The fix-side tests seed each route with a raise and LP allocation of about 2^62 atoms whose
//! larger side, if fixed, makes the venue demand one atom more of the smaller side than the
//! hand-off holds. Against the same venue bytecode, a direct pool creation fixing the larger side
//! aborts, while the presale migration falls back to the smaller side and succeeds.
//!
//! Run from `sui/launchpad/ptb_tests` with `cargo test --offline --test presale_venue_fork`.

use std::{collections::BTreeMap, path::Path, sync::OnceLock, time::Duration};

use anyhow::{Context, Result, bail, ensure};
use blast_launchpad_ptb_tests::{
    CompiledPackage, Expected, Harness, Outcome, UnlinkedPackage, build, build_timelock, build_unlinked, call,
    fork::{
        BLUEFIN, BLUEFIN_MAX_SQRT_PRICE, BLUEFIN_MIN_SQRT_PRICE, BluefinPoolCreated, BurnPosition, BurnProof,
        BurnRecord, CETUS, CETUS_MAX_SQRT_PRICE, CETUS_MIN_SQRT_PRICE, CetusCollectFee, CetusOpenPosition,
        CetusPoolState, CreatePool, LiquidityProvided, MAX_TICK, MintPoolCreationCap, RegisterPermissionPair, USDC,
        UserFeeCollected, apportion, cetus_name, expected_sqrt_price, id, insert_snapshot, meme_is_cetus_a, sui, tag,
        venue_dependencies, venue_events,
    },
    sui_dir, timelock_dir,
};
use serde::{Deserialize, de::DeserializeOwned};
use sui_types::{
    SUI_CLOCK_OBJECT_ID, SUI_COIN_REGISTRY_OBJECT_ID, SUI_FRAMEWORK_PACKAGE_ID, TypeTag,
    base_types::{ObjectID, SuiAddress},
    digests::TransactionDigest,
    effects::TransactionEffectsAPI,
    object::{MoveObject, OBJECT_START_VERSION, Object, Owner},
    programmable_transaction_builder::ProgrammableTransactionBuilder,
    transaction::{Argument, Command, ObjectArg, ProgrammableTransaction},
};

/// The one spacing Cetus's live allowlist admits for both SUI and USDC, at its registered 1%, and
/// a registered spacing that a presale does not reserve.
const CETUS_TICK_SPACING: u32 = 200;
const CETUS_FEE_RATE: u64 = 10_000;
const CETUS_OTHER_SPACING: u32 = 60;
const BLUEFIN_TICK_SPACING: u32 = 60;
const BLUEFIN_FEE_RATE: u64 = 3_000;

/// A 10^18-atom supply: 40% sold, 40% seeds the pool, and two recipients take 15% and 5%.
const SUPPLY: u64 = 1_000_000_000_000_000_000;
const SALE_BPS: u64 = 4_000;
const LP_BPS: u64 = 4_000;
/// LP fees: two recipients (the creator is the first) and the holder-reward share.
const FEE_BPS: [u64; 2] = [6_000, 2_500];
const HOLDER_REWARDS_BPS: u64 = 1_500;
const DURATION_MS: u64 = 3_600_000;
/// The shortest LP window `blast_presale::new` accepts: seven days.
const LIQUIDITY_WINDOW_MS: u64 = 604_800_000;

/// Near-equal seed atoms from `fixside_sim.py`: fixing the larger side makes both venues demand
/// `SMALL + 1` of the smaller side.
const SMALL: u64 = 1 << 62;
const LARGE: u64 = SMALL + 1;
/// The liquidity each venue's own math gives when the smaller side is fixed (same model).
const CETUS_NEAR_EQUAL_LIQUIDITY: u128 = 4_611_686_019_503_084_323;
const BLUEFIN_NEAR_EQUAL_LIQUIDITY: u128 = 4_611_686_019_504_160_504;

/// `blast_presale::blast_presale` code.
const INVALID_LIFECYCLE: u64 = 5;
/// `blast_presale::cetus` codes.
const INVALID_COIN_ORDER: u64 = 0;
const CETUS_POSITION_POOL_MISMATCH: u64 = 1;
const WRONG_COIN_PAIR: u64 = 2;
/// `blast_presale::bluefin` code.
const BLUEFIN_POSITION_POOL_MISMATCH: u64 = 0;
/// Bluefin `pool` code for a creation fee other than the configured amount.
const BLUEFIN_WRONG_CREATION_FEE: u64 = 1039;
/// Cetus `factory::create_pool_v3_` code when the fixed coin B needs more coin A than supplied, and
/// Bluefin `utils::deposit_balance` `EInsufficientCoinBalance`.
const CETUS_AMOUNT_A_ABOVE_LIMIT: u64 = 5;
const BLUEFIN_INSUFFICIENT_COIN_BALANCE: u64 = 1004;

// Addresses.
const RECIPIENT_A: ObjectID = address(&[0xA1]);
const RECIPIENT_B: ObjectID = address(&[0xB2]);
const CREATOR: ObjectID = address(&[0xC0]);
const FEE_B: ObjectID = address(&[0xFB]);

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
fn presale_cetus_meme_a_with_sui_against_mainnet_bytecode() -> Result<()> {
    run(Route::CetusMemeA)
}

#[test]
fn presale_cetus_meme_b_with_usdc_against_mainnet_bytecode() -> Result<()> {
    run(Route::CetusMemeB)
}

#[test]
fn presale_bluefin_with_sui_against_mainnet_bytecode() -> Result<()> {
    run(Route::Bluefin)
}

#[test]
fn presale_cetus_meme_a_near_equal_seed_migrates_where_larger_side_fix_aborts() -> Result<()> {
    run_near_equal(Route::CetusMemeA)
}

#[test]
fn presale_cetus_meme_b_near_equal_seed_migrates_where_larger_side_fix_aborts() -> Result<()> {
    run_near_equal(Route::CetusMemeB)
}

#[test]
fn presale_bluefin_near_equal_seed_migrates_where_larger_side_fix_aborts() -> Result<()> {
    run_near_equal(Route::Bluefin)
}

/// The whole lifecycle of one presale on `route`.
fn run(route: Route) -> Result<()> {
    let mut w = World::new(route)?;
    w.report(format!("snapshot checkpoint {}", w.checkpoint));
    let terms = Terms::standard(route);

    let sale = w.open_sale(&terms)?;
    w.migration_failures_commit_nothing(&sale)?;
    let m = w.migrate(&sale, &terms)?;
    w.claim(&sale, &terms)?;

    // One-sided: a Quote-in swap leaves only Quote fees.
    w.swap(&sale, &m, Side::QuoteIn, 2 * route.quote_unit())?;
    let fees = w.collect(&sale, &m)?;
    ensure!(fees.gross_meme == 0 && fees.gross_quote > 0, "a Quote-only swap leaves Quote-only fees");
    w.report(format!("collect_fees one-sided: {}", fees.line()));

    // Two-sided.
    w.swap(&sale, &m, Side::QuoteIn, 3 * route.quote_unit())?;
    w.swap(&sale, &m, Side::MemeIn, terms.lp_tokens() / 40)?;
    let fees = w.collect(&sale, &m)?;
    ensure!(fees.gross_meme > 0 && fees.gross_quote > 0, "both sides accrued fees");
    w.report(format!("collect_fees two-sided: {}", fees.line()));

    w.other_pool_is_refused(&sale, &m, &terms)?;
    w.claim_residuals(&sale, &m)?;

    w.print_report();
    Ok(())
}

/// A near-equal seed on `route`: fixing the larger side aborts in the venue, and the presale's
/// fallback migrates with the smaller side fixed.
fn run_near_equal(route: Route) -> Result<()> {
    let mut w = World::new(route)?;
    w.report(format!("snapshot checkpoint {}", w.checkpoint));
    let terms = Terms::near_equal(route);
    let (meme, quote) = (terms.lp_tokens(), terms.raise);
    ensure!(meme.max(quote) == LARGE && meme.min(quote) == SMALL, "the seed is ({meme}, {quote})");

    w.larger_side_fix_aborts(meme, quote)?;

    let sale = w.open_sale(&terms)?;
    let m = w.migrate(&sale, &terms)?;
    let larger_is_meme = meme > quote;
    let (larger_residual, smaller_residual) =
        if larger_is_meme { (m.residual.0, m.residual.1) } else { (m.residual.1, m.residual.0) };
    ensure!(smaller_residual == 0, "the smaller side is fixed and fully supplied");
    ensure!(larger_residual == 1, "the larger side keeps its one surplus atom");
    ensure!(m.supplied == (SMALL, SMALL), "the venue took {:?}", m.supplied);
    let expected_liquidity =
        if route.is_cetus() { CETUS_NEAR_EQUAL_LIQUIDITY } else { BLUEFIN_NEAR_EQUAL_LIQUIDITY };
    ensure!(m.liquidity == expected_liquidity, "liquidity {} matches the venue model", m.liquidity);
    w.report(format!(
        "near-equal seed meme={meme} quote={quote}: migrate fixed the smaller {} side, supplied {:?}, residual {:?}, liquidity {}",
        if larger_is_meme { "Quote" } else { "Meme" },
        m.supplied,
        m.residual,
        m.liquidity,
    ));

    w.print_report();
    Ok(())
}

/// Production admin path: the publisher's SuperAdminCap grants one AdminCap the presale
/// `FeeAdmin` role, which allows the route's Quote type and migration witness for new presales.
fn allow_route(
    h: &mut Harness,
    admin: ObjectID,
    admin_published: &Outcome,
    presale: ObjectID,
    creation_policy: ObjectID,
    route: Route,
) -> Result<()> {
    let acl = admin_published.created(h, "blast_acl", "ACL");
    let root = admin_published.created(h, "blast_acl", "SuperAdminCap");
    ensure!(acl.len() == 1 && root.len() == 1);
    let (acl, root) = (acl[0], root[0]);

    let mut b = ProgrammableTransactionBuilder::new();
    let acl_arg = b.obj(h.shared(acl, true))?;
    let root_arg = b.obj(h.owned(root))?;
    let recipient = b.pure(h.sender)?;
    call(&mut b, admin, "blast_acl", "grant_admin", vec![], vec![acl_arg, root_arg, recipient]);
    let granted = h.execute(b.finish())?;
    granted.assert_success();
    let admin_cap = granted.created(h, "blast_acl", "AdminCap");
    ensure!(admin_cap.len() == 1);
    let admin_cap = admin_cap[0];

    let fee_admin = tag(&format!("{presale}::blast_presale_domain::FeeAdmin"));
    let mut b = ProgrammableTransactionBuilder::new();
    let acl_arg = b.obj(h.shared(acl, true))?;
    let root_arg = b.obj(h.owned(root))?;
    let admin_cap_id = b.pure(admin_cap)?;
    call(&mut b, admin, "blast_acl", "grant_role", vec![fee_admin.clone()], vec![acl_arg, root_arg, admin_cap_id]);
    h.execute(b.finish())?.assert_success();

    let mut b = ProgrammableTransactionBuilder::new();
    let acl_arg = b.obj(h.shared(acl, false))?;
    let admin_cap_arg = b.obj(h.owned(admin_cap))?;
    let witness = call(&mut b, admin, "blast_acl", "sign_in", vec![fee_admin], vec![acl_arg, admin_cap_arg]);
    let policy = b.obj(h.shared(creation_policy, true))?;
    let allowed = b.pure(true)?;
    call(&mut b, presale, "creation_policy", "set_quote_allowed", vec![route.quote()], vec![policy, witness, allowed]);
    let migration_witness = tag(&format!("{presale}::{}::Witness", route.module()));
    call(
        &mut b,
        presale,
        "creation_policy",
        "set_migration_witness_allowed",
        vec![migration_witness],
        vec![policy, witness, allowed],
    );
    h.execute(b.finish())?.assert_success();

    Ok(())
}

// === Routes and terms ===

#[derive(Clone, Copy, Debug, PartialEq)]
enum Route {
    CetusMemeA,
    CetusMemeB,
    Bluefin,
}

impl Route {
    fn quote(self) -> TypeTag {
        match self {
            Route::CetusMemeB => tag(USDC),
            _ => sui(),
        }
    }

    fn quote_unit(self) -> u64 {
        match self {
            Route::CetusMemeB => 1_000_000,
            _ => 1_000_000_000,
        }
    }

    fn is_cetus(self) -> bool {
        self != Route::Bluefin
    }

    /// Whether Meme is the pool's coin A.
    fn meme_is_a(self) -> bool {
        self != Route::CetusMemeB
    }

    fn module(self) -> &'static str {
        if self.is_cetus() { "cetus" } else { "bluefin" }
    }

    fn tier(self) -> (u32, u64) {
        if self.is_cetus() {
            (CETUS_TICK_SPACING, CETUS_FEE_RATE)
        } else {
            (BLUEFIN_TICK_SPACING, BLUEFIN_FEE_RATE)
        }
    }
}

#[derive(Clone, Copy)]
enum Side {
    QuoteIn,
    MemeIn,
}

/// One presale's creation terms and its single participant's commitment.
struct Terms {
    supply: u64,
    sale_bps: u64,
    lp_bps: u64,
    recipients: Vec<(ObjectID, u64)>,
    raise: u64,
    wallet_cap: u64,
    max_participants: u64,
    min_commitment: u64,
    commitment: u64,
}

impl Terms {
    /// A 25-unit raise, oversubscribed to 30 units.
    fn standard(route: Route) -> Self {
        let unit = route.quote_unit();
        Terms {
            supply: SUPPLY,
            sale_bps: SALE_BPS,
            lp_bps: LP_BPS,
            recipients: vec![(RECIPIENT_A, 1_500), (RECIPIENT_B, 500)],
            raise: 25 * unit,
            wallet_cap: 40 * unit,
            max_participants: 5,
            min_commitment: 5 * unit,
            commitment: 30 * unit,
        }
    }

    /// Half the supply seeds the pool; the seed and raise are `SMALL` and `LARGE` in the order
    /// where fixing the larger side overdraws the smaller one.
    fn near_equal(route: Route) -> Self {
        // Cetus Meme-B fixes Quote (coin A) when Meme is larger; the others fix Meme (coin A).
        let (lp, raise) = if route == Route::CetusMemeB { (LARGE, SMALL) } else { (SMALL, LARGE) };
        Terms {
            supply: 2 * lp,
            sale_bps: 5_000,
            lp_bps: 5_000,
            recipients: vec![],
            raise,
            wallet_cap: raise,
            max_participants: 1,
            min_commitment: raise,
            commitment: raise,
        }
    }

    fn allocations(&self) -> Vec<u64> {
        let mut weights = vec![self.sale_bps, self.lp_bps];
        weights.extend(self.recipients.iter().map(|(_, bps)| *bps));
        apportion(&weights, self.supply)
    }

    fn sale_tokens(&self) -> u64 {
        self.allocations()[0]
    }

    fn lp_tokens(&self) -> u64 {
        self.allocations()[1]
    }

    fn recipient_tokens(&self) -> Vec<u64> {
        self.allocations()[2..].to_vec()
    }
}

/// `blast_presale` compiles once per test binary; each world links it to its own packages.
fn presale() -> &'static UnlinkedPackage {
    static PRESALE: OnceLock<UnlinkedPackage> = OnceLock::new();
    PRESALE.get_or_init(|| {
        let work = Path::new(env!("CARGO_TARGET_TMPDIR")).join(env!("CARGO_PKG_NAME")).join("presale_venue_fork");
        build_unlinked(&sui_dir().join("presale"), &["blast_fun_timelock", "blast_admin"], &work)
            .expect("build the presale")
    })
}

// === World ===

struct Sale {
    meme: TypeTag,
    presale: ObjectID,
    cap: ObjectID,
    currency: ObjectID,
}

struct Migration {
    pool: ObjectID,
    vault: ObjectID,
    /// Cetus: the `CetusLPBurnProof`; Bluefin: the `Position`.
    position: ObjectID,
    liquidity: u128,
    /// (Meme, Quote) the venue took and the vault kept.
    supplied: (u64, u64),
    residual: (u64, u64),
}

struct World {
    h: Harness,
    route: Route,
    checkpoint: u64,
    venue: BTreeMap<String, ObjectID>,
    presale: ObjectID,
    venue_config: ObjectID,
    creation_policy: ObjectID,
    fee_policy: ObjectID,
    token: CompiledPackage,
    coins: u64,
    lines: Vec<String>,
}

impl World {
    /// Inserts the snapshot and publishes the timelock, `blast_admin`, and `blast_presale` linked
    /// to the real venue packages.
    fn new(route: Route) -> Result<Self> {
        let work =
            Path::new(env!("CARGO_TARGET_TMPDIR")).join(env!("CARGO_PKG_NAME")).join(format!("presale_fork_{route:?}"));
        let mut h = Harness::new()?;
        let (checkpoint, venue) = insert_snapshot(&mut h)?;

        let timelock_dir = timelock_dir()?;
        let (timelock, _) = h.publish(build_timelock(&work)?)?;
        let (admin, admin_published) =
            h.publish(build(&sui_dir().join("admin"), &[(&timelock_dir, timelock)], &work)?)?;
        let mut dependencies = vec![ObjectID::from_single_byte(1), ObjectID::from_single_byte(2), timelock, admin];
        dependencies.extend(venue_dependencies(&h)?);
        let linked = presale().link(&[("blast_fun_timelock", timelock), ("blast_admin", admin)], dependencies)?;
        let (presale, published) = h.publish(linked)?;
        let venue_config = published.created(&h, "venue_config", "VenueConfig");
        ensure!(venue_config.len() == 1 && h.object(venue_config[0]).is_shared());
        let fee_policy = published.created(&h, "fee_policy", "FeePolicy");
        ensure!(fee_policy.len() == 1 && h.object(fee_policy[0]).is_shared());
        let creation_policy = published.created(&h, "creation_policy", "CreationPolicy");
        ensure!(creation_policy.len() == 1 && h.object(creation_policy[0]).is_shared());
        allow_route(&mut h, admin, &admin_published, presale, creation_policy[0], route)?;
        let token = build(&Path::new(env!("CARGO_MANIFEST_DIR")).join("fixture/presale_token"), &[], &work)?;

        Ok(World {
            h,
            route,
            checkpoint,
            venue,
            presale,
            venue_config: venue_config[0],
            creation_policy: creation_policy[0],
            fee_policy: fee_policy[0],
            token,
            coins: 0,
            lines: Vec::new(),
        })
    }

    fn report(&mut self, line: String) {
        let line = format!("{:?} {line}", self.route);
        println!("PRESALE_VENUE_FORK {line}");
        self.lines.push(line);
    }

    fn print_report(&self) {
        println!("==== presale venue fork report: {:?} ====", self.route);
        for line in &self.lines {
            println!("{line}");
        }
    }

    fn venue(&self, name: &str) -> ObjectID {
        *self.venue.get(name).unwrap_or_else(|| panic!("snapshot object {name}"))
    }

    fn quote(&self) -> TypeTag {
        self.route.quote()
    }

    fn pair(&self, sale: &Sale) -> Vec<TypeTag> {
        vec![sale.meme.clone(), self.quote()]
    }

    /// The pool's type arguments in venue order.
    fn pool_pair(&self, meme: &TypeTag) -> Vec<TypeTag> {
        if self.route.meme_is_a() { vec![meme.clone(), self.quote()] } else { vec![self.quote(), meme.clone()] }
    }

    fn shared(&self, b: &mut ProgrammableTransactionBuilder, object: ObjectID, mutable: bool) -> Result<Argument> {
        Ok(b.obj(self.h.shared(object, mutable))?)
    }

    fn clock(&self, b: &mut ProgrammableTransactionBuilder) -> Result<Argument> {
        self.shared(b, SUI_CLOCK_OBJECT_ID, false)
    }

    /// A `blast_presale::bps::Bps` built in the PTB, since a `Bps` cannot be a pure argument.
    fn bps(&self, b: &mut ProgrammableTransactionBuilder, value: u64) -> Result<Argument> {
        let value = b.pure(value)?;

        Ok(call(b, self.presale, "bps", "new", vec![], vec![value]))
    }

    fn presale_tag(&self, module: &str, name: &str) -> TypeTag {
        tag(&format!("{}::{module}::{name}", self.presale))
    }

    /// A coin of `coin_type` owned by the sender, inserted directly: the Quote a participant or
    /// trader brings.
    fn mint(&mut self, coin_type: TypeTag, value: u64) -> ObjectID {
        self.coins += 1;
        let coin_id = ObjectID::derive_id(TransactionDigest::new([0xE0; 32]), self.coins);
        let coin = MoveObject::new_coin(coin_type, OBJECT_START_VERSION, coin_id, value);
        self.h.insert(Object::new_move(coin, Owner::AddressOwner(self.h.sender), TransactionDigest::genesis_marker()));
        coin_id
    }

    fn quote_coin(&mut self, b: &mut ProgrammableTransactionBuilder, value: u64) -> Result<Argument> {
        let coin = self.mint(self.quote(), value);
        Ok(b.obj(self.h.owned(coin))?)
    }

    /// The sender's largest coin of `coin_type`.
    fn largest_coin(&self, coin_type: &TypeTag) -> Result<ObjectID> {
        let wanted = coin_type.to_canonical_string(true);
        self.h
            .owned_by(self.h.sender)
            .into_iter()
            .filter(|object| object.coin_type_maybe().is_some_and(|coin| coin.to_canonical_string(true) == wanted))
            .max_by_key(|object| object.get_coin_value_unsafe())
            .map(|object| object.id())
            .with_context(|| format!("a {wanted} coin"))
    }

    /// Presale events of `module::name`.
    fn events<T: DeserializeOwned>(&self, outcome: &Outcome, module: &str, name: &str) -> Vec<T> {
        outcome
            .events
            .iter()
            .filter(|event| {
                ObjectID::from(event.type_.address) == self.presale
                    && event.type_.module.as_str() == module
                    && event.type_.name.as_str() == name
            })
            .map(|event| bcs::from_bytes(&event.contents).expect("presale event payload"))
            .collect()
    }

    fn sale_state(&self, sale: &Sale) -> Result<PresaleState> {
        Ok(bcs::from_bytes(&self.h.contents(sale.presale))?)
    }

    fn vault(&self, m: &Migration) -> Result<VaultState> {
        Ok(bcs::from_bytes(&self.h.contents(m.vault))?)
    }

    fn coins(&self, meme: &TypeTag, meme_amount: u64, quote_amount: u64) -> Vec<(String, u64)> {
        let mut coins = vec![
            (meme.to_canonical_string(true), meme_amount),
            (self.quote().to_canonical_string(true), quote_amount),
        ];
        coins.retain(|(_, value)| *value > 0);
        coins.sort();
        coins
    }

    /// Publishes one presale-token package and finalizes its currency. On Cetus the Meme type name
    /// must sort on the route's side of the Quote, so tokens are published until one does.
    fn publish_token(&mut self) -> Result<(ObjectID, ObjectID, TypeTag)> {
        for _ in 0..16 {
            let (package, published) = self.h.publish(self.token.clone())?;
            let meme = tag(&format!("{package}::token::TOKEN"));
            if self.route.is_cetus() && meme_is_cetus_a(&meme, &self.quote()) != self.route.meme_is_a() {
                continue;
            }
            let treasury_cap = published.created(&self.h, "coin", "TreasuryCap");
            let pending = published.created(&self.h, "coin_registry", "Currency");
            ensure!(treasury_cap.len() == 1 && pending.len() == 1);
            let mut b = ProgrammableTransactionBuilder::new();
            let registry = self.shared(&mut b, SUI_COIN_REGISTRY_OBJECT_ID, true)?;
            let receiving = b.obj(ObjectArg::Receiving(self.h.object(pending[0]).compute_object_reference()))?;
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
            let currency = finalized.created(&self.h, "coin_registry", "Currency");
            ensure!(currency.len() == 1);
            return Ok((treasury_cap[0], currency[0], meme));
        }
        bail!("no published token had the route's Cetus coin order")
    }

    /// One PTB: the route's `new` with open eligibility, then `share`; the cap goes to the sender.
    fn create_presale_pt(
        &self,
        treasury_cap: ObjectID,
        currency: ObjectID,
        meme: &TypeTag,
        terms: &Terms,
    ) -> Result<ProgrammableTransaction> {
        let mut b = ProgrammableTransactionBuilder::new();
        let pair = vec![meme.clone(), self.quote()];
        let mut recipients = Vec::new();
        for (recipient, bps) in &terms.recipients {
            let args = vec![b.pure(SuiAddress::from(*recipient))?, self.bps(&mut b, *bps)?];
            recipients.push(call(&mut b, self.presale, "blast_presale", "recipient_share", vec![], args));
        }
        let allocation_type = self.presale_tag("blast_presale", "RecipientShare");
        let recipients = b.command(Command::make_move_vec(Some(allocation_type.clone()), recipients));
        // No share of the raise goes to recipients, and there is no uncapped phase.
        let raise_allocations = b.command(Command::make_move_vec(Some(allocation_type), vec![]));
        let uncapped_type = self.presale_tag("blast_presale", "UncappedPhase");
        let std = ObjectID::from_hex_literal("0x1")?;
        let uncapped = call(&mut b, std, "option", "none", vec![uncapped_type], vec![]);
        let mut fee_recipients = Vec::new();
        for (recipient, bps) in [(CREATOR, FEE_BPS[0]), (FEE_B, FEE_BPS[1])] {
            let args = vec![b.pure(SuiAddress::from(recipient))?, self.bps(&mut b, bps)?];
            fee_recipients.push(call(&mut b, self.presale, "blast_presale", "recipient_share", vec![], args));
        }
        let fee_type = self.presale_tag("blast_presale", "RecipientShare");
        let fee_recipients = b.command(Command::make_move_vec(Some(fee_type), fee_recipients));
        let eligibility_args =
            vec![b.pure(terms.wallet_cap)?, b.pure(terms.max_participants)?, b.pure(terms.min_commitment)?];
        let eligibility = call(&mut b, self.presale, "blast_presale", "open_eligibility", vec![], eligibility_args);

        let mut args = vec![
            b.obj(self.h.owned(treasury_cap))?,
            self.shared(&mut b, currency, true)?,
            b.pure(terms.supply)?,
            self.bps(&mut b, terms.sale_bps)?,
            self.bps(&mut b, terms.lp_bps)?,
            recipients,
            b.pure(false)?,
            b.pure(terms.raise)?,
            raise_allocations,
            b.pure(DURATION_MS)?,
            b.pure(LIQUIDITY_WINDOW_MS)?,
            eligibility,
            uncapped,
            fee_recipients,
            self.bps(&mut b, HOLDER_REWARDS_BPS)?,
            self.shared(&mut b, self.creation_policy, false)?,
            self.shared(&mut b, self.fee_policy, false)?,
        ];
        let (tick_spacing, fee_rate) = self.route.tier();
        if self.route.is_cetus() {
            args.push(self.shared(&mut b, self.venue_config, true)?);
            args.push(self.shared(&mut b, self.venue("cetus_global_config"), false)?);
            args.push(self.shared(&mut b, self.venue("cetus_pools"), true)?);
            args.push(b.pure(tick_spacing)?);
        } else {
            args.push(b.pure(tick_spacing)?);
            args.push(b.pure(fee_rate)?);
        }
        let Argument::Result(created) = call(&mut b, self.presale, self.route.module(), "new", pair.clone(), args)
        else {
            unreachable!()
        };
        let clock = self.clock(&mut b)?;
        call(&mut b, self.presale, "blast_presale", "share", pair, vec![Argument::NestedResult(created, 0), clock]);
        b.transfer_arg(self.h.sender, Argument::NestedResult(created, 1));

        Ok(b.finish())
    }

    /// Creates and shares the presale, commits past the raise, and settles it after the window.
    fn open_sale(&mut self, terms: &Terms) -> Result<Sale> {
        let (treasury_cap, currency, meme) = self.publish_token()?;
        let pt = self.create_presale_pt(treasury_cap, currency, &meme, terms)?;
        let created = self.h.execute(pt)?;
        created.assert_success();
        let presales = created.created(&self.h, "blast_presale", "Presale");
        let caps = self.h.owned_of_type(self.h.sender, "blast_presale", "PresaleCap");
        ensure!(presales.len() == 1 && self.h.object(presales[0]).is_shared() && caps.len() == 1);
        let sale = Sale { meme, presale: presales[0], cap: caps[0], currency };

        let state = self.sale_state(&sale)?;
        ensure!(state.lifecycle == Lifecycle::Open && state.presale_cap_id == sale.cap);
        ensure!((state.protocol_quote, state.protocol_tokens) == (0, 0), "a zero-rate policy reserves Blast nothing");
        ensure!((state.tick_spacing, state.pool_fee_rate) == self.route.tier(), "the sale records the venue's tier");
        ensure!(state.migration_witness.ends_with(&format!("::{}::Witness", self.route.module())));
        ensure!(
            (state.sale_tokens, state.liquidity_tokens, state.recipient_tokens)
                == (terms.sale_tokens(), terms.lp_tokens(), terms.recipient_tokens().iter().sum()),
            "the supply is apportioned"
        );
        if self.route.is_cetus() {
            // The Meme type's one PoolCreationCap is minted, registered for the pair at the tier,
            // and kept under VenueConfig.
            let registered: Vec<RegisterPermissionPair> =
                venue_events(&created, "factory", "RegisterPermissionPairEvent");
            let minted: Vec<MintPoolCreationCap> = venue_events(&created, "factory", "MintPoolCreationCap");
            ensure!(registered.len() == 1 && minted.len() == 1);
            let cap = minted[0].cap;
            ensure!(registered[0].cap == cap && registered[0].tick_spacing == CETUS_TICK_SPACING);
            ensure!(
                registered[0].coin_type == cetus_name(&sale.meme) && registered[0].coin_pair == cetus_name(&self.quote())
            );
            let Owner::ObjectOwner(field) = self.h.object(cap).owner().clone() else { bail!("cap is not a child") };
            ensure!(*self.h.object(field.into()).owner() == Owner::ObjectOwner(self.venue_config.into()));
        }
        self.report(format!(
            "{}::new at {:?}: sale {} LP {} recipients {:?}, raise {}{}",
            self.route.module(),
            self.route.tier(),
            terms.sale_tokens(),
            terms.lp_tokens(),
            terms.recipient_tokens(),
            terms.raise,
            if self.route.is_cetus() { "; PoolCreationCap registered for the pair and kept under VenueConfig" } else { "" },
        ));

        let mut b = ProgrammableTransactionBuilder::new();
        let presale = self.shared(&mut b, sale.presale, true)?;
        let coin = self.quote_coin(&mut b, terms.commitment)?;
        let clock = self.clock(&mut b)?;
        let change = call(&mut b, self.presale, "blast_presale", "commit_open", self.pair(&sale), vec![presale, coin, clock]);
        b.transfer_arg(self.h.sender, change);
        self.h.execute(b.finish())?.assert_success();

        self.h.sim.advance_clock(Duration::from_millis(DURATION_MS));
        let mut b = ProgrammableTransactionBuilder::new();
        let presale = self.shared(&mut b, sale.presale, true)?;
        let clock = self.clock(&mut b)?;
        call(&mut b, self.presale, "blast_presale", "settle", self.pair(&sale), vec![presale, clock]);
        let settled = self.h.execute(b.finish())?;
        settled.assert_success();
        let funded: Vec<PresaleFunded> = self.events(&settled, "blast_presale", "PresaleFunded");
        ensure!(funded.len() == 1 && funded[0].presale_id == sale.presale);
        ensure!(
            (funded[0].total_commitments, funded[0].accepted_quote, funded[0].refundable_quote, funded[0].token_allocation)
                == (terms.commitment, terms.raise, terms.commitment - terms.raise, terms.sale_tokens())
        );
        ensure!(self.sale_state(&sale)?.lifecycle == Lifecycle::Funded);
        self.report(format!("commit_open {} then settle: Funded", terms.commitment));

        Ok(sale)
    }

    /// The route's migration; on Cetus with `order` as `(CoinA, CoinB)` (the pool's order when
    /// none), on Bluefin paying `creation_fee` SUI (the live fee when none).
    fn migrate_command(
        &self,
        b: &mut ProgrammableTransactionBuilder,
        sale: &Sale,
        order: Option<(TypeTag, TypeTag)>,
        creation_fee: Option<u64>,
    ) -> Result<()> {
        let presale = self.shared(b, sale.presale, true)?;
        let clock = self.clock(b)?;
        if self.route.is_cetus() {
            let (coin_a, coin_b) = order.unwrap_or_else(|| {
                let pool_pair = self.pool_pair(&sale.meme);
                (pool_pair[0].clone(), pool_pair[1].clone())
            });
            let args = vec![
                presale,
                self.shared(b, self.fee_policy, false)?,
                self.shared(b, self.venue_config, false)?,
                self.shared(b, self.venue("cetus_global_config"), false)?,
                self.shared(b, self.venue("cetus_pools"), true)?,
                self.shared(b, self.venue("cetus_burn_manager"), true)?,
                clock,
            ];
            call(b, self.presale, "cetus", "migrate", vec![sale.meme.clone(), self.quote(), coin_a, coin_b], args);
        } else {
            let fee = b.pure(creation_fee.map_or_else(|| self.bluefin_creation_fee(), Ok)?)?;
            let Argument::Result(fee) = b.command(Command::SplitCoins(Argument::GasCoin, vec![fee])) else {
                unreachable!()
            };
            let args = vec![
                presale,
                self.shared(b, self.fee_policy, false)?,
                self.shared(b, sale.currency, false)?,
                self.shared(b, self.venue("sui_currency"), false)?,
                self.shared(b, self.venue("bluefin_global_config"), true)?,
                Argument::NestedResult(fee, 0),
                clock,
            ];
            call(b, self.presale, "bluefin", "migrate", self.pair(sale), args);
        }

        Ok(())
    }

    /// Bluefin's live SUI pool-creation fee from the snapshot's fee table.
    fn bluefin_creation_fee(&self) -> Result<u64> {
        let (_, _, fee): (ObjectID, String, u64) =
            bcs::from_bytes(&self.h.contents(self.venue("bluefin_pool_creation_fee_sui")))?;
        Ok(fee)
    }

    /// A migration that aborts after the pool exists commits nothing; Cetus refuses the reversed
    /// coin order and a foreign pair, and Bluefin any creation fee but its configured one.
    fn migration_failures_commit_nothing(&mut self, sale: &Sale) -> Result<()> {
        let mut watched = vec![sale.presale, sale.currency];
        if self.route.is_cetus() {
            watched.extend([self.venue_config, self.venue("cetus_pools"), self.venue("cetus_burn_manager")]);
        } else {
            watched.push(self.venue("bluefin_global_config"));
        }
        let owners = [self.h.sender, RECIPIENT_A.into(), RECIPIENT_B.into()];
        let before = self.sale_state(sale)?;

        let mut b = ProgrammableTransactionBuilder::new();
        self.migrate_command(&mut b, sale, None, None)?;
        self.migrate_command(&mut b, sale, None, None)?;
        let expected = Expected::Abort { package: self.presale, module: "blast_presale", code: INVALID_LIFECYCLE };
        self.h.assert_rolled_back(b.finish(), expected, &watched, &owners)?;
        self.report("PTB [migrate (pool created, position sealed), migrate again]: EInvalidLifecycle, nothing committed".into());

        if self.route.is_cetus() {
            let pool_pair = self.pool_pair(&sale.meme);
            let reversed = (pool_pair[1].clone(), pool_pair[0].clone());
            let mut b = ProgrammableTransactionBuilder::new();
            self.migrate_command(&mut b, sale, Some(reversed), None)?;
            let expected = Expected::Abort { package: self.presale, module: "cetus", code: INVALID_COIN_ORDER };
            self.h.assert_rolled_back(b.finish(), expected, &watched, &owners)?;

            // (USDC, SUI) is in Cetus order and shares one coin with either route's pair.
            ensure!(meme_is_cetus_a(&tag(USDC), &sui()));
            let mut b = ProgrammableTransactionBuilder::new();
            self.migrate_command(&mut b, sale, Some((tag(USDC), sui())), None)?;
            let expected = Expected::Abort { package: self.presale, module: "cetus", code: WRONG_COIN_PAIR };
            self.h.assert_rolled_back(b.finish(), expected, &watched, &owners)?;
            self.report(
                "cetus::migrate with the reversed coin order: EInvalidCoinOrder; with (USDC, SUI): EWrongCoinPair; both rolled back"
                    .into(),
            );
        } else {
            let fee = self.bluefin_creation_fee()?;
            let mut b = ProgrammableTransactionBuilder::new();
            self.migrate_command(&mut b, sale, None, Some(fee + 1))?;
            let expected = Expected::Abort { package: id(BLUEFIN), module: "pool", code: BLUEFIN_WRONG_CREATION_FEE };
            self.h.assert_rolled_back(b.finish(), expected, &watched, &owners)?;
            self.report(format!(
                "bluefin::migrate paying {} MIST against the live {fee} MIST fee: Bluefin pool aborts 1039, rolled back",
                fee + 1
            ));
        }
        let after = self.sale_state(sale)?;
        ensure!(after.lifecycle == Lifecycle::Funded && after == before, "the sale is untouched");

        Ok(())
    }

    fn migrate(&mut self, sale: &Sale, terms: &Terms) -> Result<Migration> {
        let mut b = ProgrammableTransactionBuilder::new();
        self.migrate_command(&mut b, sale, None, None)?;
        let outcome = self.h.execute(b.finish())?;
        outcome.assert_success();
        for (object, owner) in outcome.effects.created() {
            ensure!(owner != Owner::AddressOwner(self.h.sender), "the caller received {}", object.0);
        }
        let (lp, raise) = (terms.lp_tokens(), terms.raise);

        // The sale released exactly the raise and the LP allocation and paid every recipient.
        let state = self.sale_state(sale)?;
        ensure!(state.lifecycle == Lifecycle::Migrated);
        ensure!(
            (state.quote, state.liquidity_tokens, state.recipient_tokens, state.sale_tokens)
                == (terms.commitment - raise, 0, 0, terms.sale_tokens()),
            "the sale keeps only the overflow and the sold tokens"
        );
        let migrated: Vec<PresaleMigrated> = self.events(&outcome, "blast_presale", "PresaleMigrated");
        ensure!(migrated.len() == 1 && migrated[0].presale_id == sale.presale);
        let recipient_total: u64 = terms.recipient_tokens().iter().sum();
        ensure!(
            (migrated[0].liquidity_quote, migrated[0].liquidity_tokens, migrated[0].recipient_tokens) == (raise, lp, recipient_total),
            "the hand-off is the raise and the LP allocation"
        );
        ensure!(migrated[0].migration_witness.ends_with(&format!("::{}::Witness", self.route.module())));
        let allocated: Vec<RecipientAllocated> = self.events(&outcome, "blast_presale", "RecipientAllocated");
        ensure!(allocated.len() == terms.recipients.len());
        for (((recipient, _), amount), event) in terms.recipients.iter().zip(terms.recipient_tokens()).zip(&allocated) {
            let recipient = SuiAddress::from(*recipient);
            ensure!((event.recipient, event.tokens) == (recipient, amount));
            ensure!(outcome.coins_created_for(&self.h, recipient) == self.coins(&sale.meme, amount, 0));
        }

        // The vault holds the position as a dynamic object field and the residuals.
        let created: Vec<VaultCreated> = self.events(&outcome, "presale_vault", "PresaleVaultCreated");
        ensure!(created.len() == 1 && created[0].presale_id == sale.presale);
        let created = &created[0];
        let venue_marker = outcome
            .events
            .iter()
            .find(|event| event.type_.name.as_str() == "PresaleVaultCreated")
            .and_then(|event| event.type_.type_params.get(2).cloned())
            .context("vault venue marker")?;
        ensure!(venue_marker == self.presale_tag(self.route.module(), "Venue"), "venue marker {venue_marker}");
        ensure!(
            created.fee_recipients == vec![SuiAddress::from(CREATOR), FEE_B.into()]
                && created.fee_recipient_bps == FEE_BPS.to_vec()
                && created.holder_rewards_bps == HOLDER_REWARDS_BPS
                && (created.protocol_lp_fee_meme_bps, created.protocol_lp_fee_quote_bps) == (0, 0)
        );
        let residual = (created.migration_meme_residual, created.migration_quote_residual);
        let m = Migration {
            pool: created.pool_id,
            vault: created.vault_id,
            position: created.position_id,
            liquidity: created.liquidity,
            supplied: (lp - residual.0, raise - residual.1),
            residual,
        };
        ensure!(self.h.object(m.vault).is_shared() && self.h.object(m.pool).is_shared());
        let vault = self.vault(&m)?;
        ensure!(
            (vault.presale_id, vault.presale_cap_id, vault.pool_id) == (sale.presale, sale.cap, m.pool)
                && (vault.migration_meme_residual, vault.migration_quote_residual) == residual
                && (vault.holder_rewards_meme, vault.holder_rewards_quote, vault.next_round) == (0, 0, 0)
        );
        let Owner::ObjectOwner(field) = self.h.object(m.position).owner().clone() else {
            bail!("position is not a child")
        };
        ensure!(*self.h.object(field.into()).owner() == Owner::ObjectOwner(m.vault.into()));
        let field_type = self.h.object(field.into()).data.try_as_move().context("field")?.type_().to_string();
        ensure!(
            field_type.contains("::presale_vault::PositionKey<")
                && field_type.contains(&format!("::{}::Venue", self.route.module())),
            "{field_type}"
        );
        ensure!(m.liquidity > 0 && self.position_liquidity(m.position)? == m.liquidity);
        // Cetus takes the fixed side in full; Bluefin rederives both sides from the liquidity.
        ensure!(!self.route.is_cetus() || residual.0 == 0 || residual.1 == 0, "residual {residual:?}");

        let (lower, upper, sqrt_price) = if self.route.is_cetus() {
            let pools: Vec<CreatePool> = venue_events(&outcome, "factory", "CreatePoolEvent");
            ensure!(pools.len() == 1 && pools[0].pool_id == m.pool && pools[0].tick_spacing == CETUS_TICK_SPACING);
            let state = CetusPoolState::of(&self.h, m.pool)?;
            ensure!((state.tick_spacing, state.fee_rate) == (CETUS_TICK_SPACING, CETUS_FEE_RATE));
            ensure!(state.liquidity == m.liquidity);
            let pool_amounts =
                if self.route.meme_is_a() { (state.coin_a, state.coin_b) } else { (state.coin_b, state.coin_a) };
            ensure!(pool_amounts == m.supplied, "the pool holds exactly the supply");
            let opened: Vec<CetusOpenPosition> = venue_events(&outcome, "pool", "OpenPositionEvent");
            ensure!(opened.len() == 1);
            // Burned: LP Burn wraps the position in the proof the vault holds and records it.
            ensure!(self.h.is_type(m.position, "lp_burn", "CetusLPBurnProof"));
            let proof: BurnProof = bcs::from_bytes(&self.h.contents(m.position))?;
            ensure!(proof.position.id == opened[0].position && proof.position.pool == m.pool);
            let burned: Vec<BurnPosition> = venue_events(&outcome, "lp_burn", "BurnPositionEvent");
            ensure!(
                burned.len() == 1
                    && (burned[0].position_id, burned[0].burned_position_id, burned[0].pool_id)
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
            ensure!((pools[0].tick_spacing, pools[0].fee_rate) == (BLUEFIN_TICK_SPACING, BLUEFIN_FEE_RATE));
            let provided: Vec<LiquidityProvided> = venue_events(&outcome, "events", "LiquidityProvided");
            ensure!(provided.len() == 1 && provided[0].position_id == m.position);
            ensure!((provided[0].coin_a_amount, provided[0].coin_b_amount) == m.supplied);
            ensure!((provided[0].pool_coin_a_amount, provided[0].pool_coin_b_amount) == m.supplied);
            ensure!(provided[0].after_liquidity == m.liquidity);
            ensure!(self.h.is_type(m.position, "position", "Position"));
            (provided[0].lower_tick as i32, provided[0].upper_tick as i32, pools[0].current_sqrt_price)
        };
        let spacing = self.route.tier().0 as i32;
        ensure!(lower == -(MAX_TICK / spacing * spacing) && upper == MAX_TICK / spacing * spacing, "full range");
        ensure!(
            sqrt_price == expected_sqrt_price(lp, raise, self.route.meme_is_a()),
            "the opening price is the exact Q64.64 ratio of the hand-off"
        );

        self.report(format!(
            "{}::migrate: pool {} ticks ({lower}, {upper}) sqrt_price {sqrt_price}; hand-off ({lp}, {raise}) = supplied {:?} + residual {:?}; liquidity {}; recipients paid {:?}; {}",
            self.route.module(),
            m.pool,
            m.supplied,
            m.residual,
            m.liquidity,
            terms.recipient_tokens(),
            if self.route.is_cetus() {
                "position burned by LP Burn, proof sealed in the vault, BurnManager record created"
            } else {
                "position sealed in the vault"
            },
        ));

        Ok(m)
    }

    /// The liquidity of the migration position: inside the burn proof on Cetus.
    fn position_liquidity(&self, position: ObjectID) -> Result<u128> {
        let contents = self.h.contents(position);
        if self.route.is_cetus() {
            let proof: BurnProof = bcs::from_bytes(&contents)?;
            return Ok(proof.position.liquidity);
        }
        Ok(u128::from_le_bytes(contents[80..96].try_into()?))
    }

    /// The participant's one claim: every sold token and the whole overflow.
    fn claim(&mut self, sale: &Sale, terms: &Terms) -> Result<()> {
        let mut b = ProgrammableTransactionBuilder::new();
        let presale = self.shared(&mut b, sale.presale, true)?;
        let participant = b.pure(self.h.sender)?;
        call(&mut b, self.presale, "blast_presale", "claim", self.pair(sale), vec![presale, participant]);
        let outcome = self.h.execute(b.finish())?;
        outcome.assert_success();
        let claimed: Vec<Claimed> = self.events(&outcome, "blast_presale", "Claimed");
        let refund = terms.commitment - terms.raise;
        ensure!(
            claimed.len() == 1
                && (claimed[0].wallet_commitment, claimed[0].tokens, claimed[0].quote_refund, claimed[0].remaining_commitments)
                    == (terms.commitment, terms.sale_tokens(), refund, 0)
        );
        ensure!(outcome.coins_created_for(&self.h, self.h.sender) == self.coins(&sale.meme, terms.sale_tokens(), refund));
        let state = self.sale_state(sale)?;
        ensure!((state.quote, state.sale_tokens, state.remaining_commitments) == (0, 0, 0), "the sale is drained");
        self.report(format!("claim: {} tokens and {refund} overflow Quote", terms.sale_tokens()));

        Ok(())
    }

    /// Swaps `amount` into the pool from a fresh Quote coin or the claimed Meme, all the way
    /// through.
    fn swap(&mut self, sale: &Sale, m: &Migration, side: Side, amount: u64) -> Result<()> {
        let mut b = ProgrammableTransactionBuilder::new();
        let pool_pair = self.pool_pair(&sale.meme);
        let input_is_a = matches!(side, Side::MemeIn) == self.route.meme_is_a();
        let source = match side {
            Side::QuoteIn => self.quote_coin(&mut b, amount)?,
            Side::MemeIn => {
                let coin = b.obj(self.h.owned(self.largest_coin(&sale.meme)?))?;
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
        let outputs = if self.route.is_cetus() {
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

    /// `collect_fees` against `pool`.
    fn collect_pt(&self, sale: &Sale, m: &Migration, pool: ObjectID) -> Result<ProgrammableTransaction> {
        let mut b = ProgrammableTransactionBuilder::new();
        let vault = self.shared(&mut b, m.vault, true)?;
        if self.route.is_cetus() {
            let args = vec![
                vault,
                self.shared(&mut b, self.fee_policy, false)?,
                self.shared(&mut b, self.venue("cetus_global_config"), false)?,
                self.shared(&mut b, self.venue("cetus_burn_manager"), false)?,
                self.shared(&mut b, pool, true)?,
            ];
            let mut types = self.pair(sale);
            types.extend(self.pool_pair(&sale.meme));
            call(&mut b, self.presale, "cetus", "collect_fees", types, args);
        } else {
            let args = vec![
                vault,
                self.shared(&mut b, self.fee_policy, false)?,
                self.shared(&mut b, self.venue("bluefin_global_config"), false)?,
                self.shared(&mut b, pool, true)?,
                self.clock(&mut b)?,
            ];
            call(&mut b, self.presale, "bluefin", "collect_fees", self.pair(sale), args);
        }

        Ok(b.finish())
    }

    /// A permissionless collection: the gross is exactly what the venue paid the vault's
    /// position, every fee recipient is paid its apportioned share, and the rest grows the vault's
    /// holder-reward balances.
    fn collect(&mut self, sale: &Sale, m: &Migration) -> Result<FeesCollected> {
        let before = self.vault(m)?;
        let pt = self.collect_pt(sale, m, m.pool)?;
        let outcome = self.h.execute(pt)?;
        outcome.assert_success();

        let (venue_a, venue_b) = if self.route.is_cetus() {
            let collected: Vec<CetusCollectFee> = venue_events(&outcome, "pool", "CollectFeeEvent");
            ensure!(collected.len() == 1 && collected[0].pool == m.pool, "collects the burned position");
            (collected[0].amount_a, collected[0].amount_b)
        } else {
            let collected: Vec<UserFeeCollected> = venue_events(&outcome, "events", "UserFeeCollected");
            ensure!(collected.len() == 1 && collected[0].position_id == m.position);
            (collected[0].coin_a_amount, collected[0].coin_b_amount)
        };
        let (gross_meme, gross_quote) =
            if self.route.meme_is_a() { (venue_a, venue_b) } else { (venue_b, venue_a) };
        let fees: Vec<FeesCollected> = self.events(&outcome, "presale_vault", "FeesCollected");
        ensure!(fees.len() == 1, "one FeesCollected");
        let fees = fees[0].clone();
        ensure!(fees.vault_id == m.vault && (fees.gross_meme, fees.gross_quote) == (gross_meme, gross_quote));
        // The publisher's zero-rate policy takes no Blast share.
        ensure!(
            (fees.protocol_destination, fees.protocol_meme, fees.protocol_quote) == (self.h.sender, 0, 0),
            "a zero-rate policy pays Blast nothing"
        );

        let weights = [FEE_BPS[0], FEE_BPS[1], HOLDER_REWARDS_BPS];
        let meme = apportion(&weights, gross_meme);
        let quote = apportion(&weights, gross_quote);
        ensure!(
            fees.fee_recipient_meme == meme[..2] && fees.fee_recipient_quote == quote[..2]
                && (fees.holder_rewards_meme, fees.holder_rewards_quote) == (meme[2], quote[2]),
            "FeesCollected {fees:?} is the exact apportionment"
        );
        for (i, recipient) in [CREATOR, FEE_B].into_iter().enumerate() {
            ensure!(
                outcome.coins_created_for(&self.h, recipient.into()) == self.coins(&sale.meme, meme[i], quote[i]),
                "{recipient} paid"
            );
        }
        let after = self.vault(m)?;
        ensure!(
            (after.holder_rewards_meme, after.holder_rewards_quote)
                == (before.holder_rewards_meme + fees.holder_rewards_meme, before.holder_rewards_quote + fees.holder_rewards_quote),
            "the holder-reward share accrues in the vault"
        );
        ensure!(after.holder_rewards_meme + after.holder_rewards_quote > before.holder_rewards_meme + before.holder_rewards_quote);
        ensure!(
            (after.migration_meme_residual, after.migration_quote_residual)
                == (before.migration_meme_residual, before.migration_quote_residual)
        );
        ensure!(self.position_liquidity(m.position)? == m.liquidity, "collection keeps the liquidity");

        Ok(fees)
    }

    /// Anyone can create another pool of the same type (Cetus at an unreserved tick spacing,
    /// Bluefin at any tier); collecting the vault against it is refused before any venue call.
    fn other_pool_is_refused(&mut self, sale: &Sale, m: &Migration, terms: &Terms) -> Result<()> {
        let mut b = ProgrammableTransactionBuilder::new();
        let pool_pair = self.pool_pair(&sale.meme);
        let clock = self.clock(&mut b)?;
        let meme = b.obj(self.h.owned(self.largest_coin(&sale.meme)?))?;
        let meme_amount = b.pure(terms.lp_tokens() / 200)?;
        let Argument::Result(meme) = b.command(Command::SplitCoins(meme, vec![meme_amount])) else { unreachable!() };
        let meme = Argument::NestedResult(meme, 0);
        if self.route.is_cetus() {
            let quote = self.quote_coin(&mut b, terms.raise)?;
            let config = self.shared(&mut b, self.venue("cetus_global_config"), false)?;
            let pools = self.shared(&mut b, self.venue("cetus_pools"), true)?;
            let spacing = b.pure(CETUS_OTHER_SPACING)?;
            let Argument::Result(range) =
                call(&mut b, id(CETUS), "pool_creator", "full_range_tick_range", vec![], vec![spacing])
            else {
                unreachable!()
            };
            let price = b.pure(CetusPoolState::of(&self.h, m.pool)?.sqrt_price)?;
            let url = b.pure(String::new())?;
            let (coin_a, coin_b) = if self.route.meme_is_a() { (meme, quote) } else { (quote, meme) };
            let fix_a = b.pure(self.route.meme_is_a())?;
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
            args.push(b.pure(expected_sqrt_price(terms.lp_tokens(), terms.raise, true))?);
            args.push(fee);
            call(&mut b, id(BLUEFIN), "pool", "create_pool", vec![sale.meme.clone(), sui(), sui()], args);
            b.transfer_args(self.h.sender, vec![meme]);
        }
        let outcome = self.h.execute(b.finish())?;
        outcome.assert_success();
        let other = outcome.created(&self.h, "pool", "Pool");
        ensure!(other.len() == 1 && other[0] != m.pool && self.h.object(other[0]).is_shared());
        let other = other[0];

        let code = if self.route.is_cetus() { CETUS_POSITION_POOL_MISMATCH } else { BLUEFIN_POSITION_POOL_MISMATCH };
        let expected = Expected::Abort { package: self.presale, module: self.route.module(), code };
        let pt = self.collect_pt(sale, m, other)?;
        let owners = [self.h.sender, CREATOR.into(), FEE_B.into()];
        self.h.assert_rolled_back(pt, expected, &[m.vault, other], &owners)?;
        self.report(format!("collect_fees against another pool {other} of the same type: EPositionPoolMismatch, rolled back"));

        Ok(())
    }

    /// The creator claims the residuals the venue did not take with its `PresaleCap`.
    fn claim_residuals(&mut self, sale: &Sale, m: &Migration) -> Result<()> {
        let mut b = ProgrammableTransactionBuilder::new();
        let vault = self.shared(&mut b, m.vault, true)?;
        let cap = b.obj(self.h.owned(sale.cap))?;
        let Argument::Result(claimed) = call(
            &mut b,
            self.presale,
            "presale_vault",
            "claim_migration_residuals",
            self.pair(sale),
            vec![vault, cap],
        ) else {
            unreachable!()
        };
        b.transfer_args(self.h.sender, vec![Argument::NestedResult(claimed, 0), Argument::NestedResult(claimed, 1)]);
        let outcome = self.h.execute(b.finish())?;
        outcome.assert_success();
        let claimed: Vec<ResidualsClaimed> = self.events(&outcome, "presale_vault", "MigrationResidualsClaimed");
        ensure!(claimed.len() == 1 && (claimed[0].meme, claimed[0].quote) == m.residual);
        let mut coins = vec![
            (sale.meme.to_canonical_string(true), m.residual.0),
            (self.quote().to_canonical_string(true), m.residual.1),
        ];
        coins.sort();
        ensure!(outcome.coins_created_for(&self.h, self.h.sender) == coins, "both coins, a zero one included");
        let vault = self.vault(m)?;
        ensure!((vault.migration_meme_residual, vault.migration_quote_residual) == (0, 0));
        self.report(format!("claim_migration_residuals with the PresaleCap: {:?}", m.residual));

        Ok(())
    }

    /// A fresh token seeded at the near-equal amounts straight into the venue: fixing the larger
    /// side aborts in the venue, and fixing the smaller side succeeds, at the same price and range
    /// the presale migration uses.
    fn larger_side_fix_aborts(&mut self, meme: u64, quote: u64) -> Result<()> {
        let (treasury_cap, _, token) = self.publish_token()?;
        let meme_is_a = self.route.meme_is_a();
        let larger_is_a = (meme > quote) == meme_is_a;
        let sqrt_price = expected_sqrt_price(meme, quote, meme_is_a);
        for fix_a in [larger_is_a, !larger_is_a] {
            let quote_id = self.mint(self.quote(), quote);
            let mut b = ProgrammableTransactionBuilder::new();
            let cap = b.obj(self.h.owned(treasury_cap))?;
            let amount = b.pure(meme)?;
            let meme_coin = call(&mut b, SUI_FRAMEWORK_PACKAGE_ID, "coin", "mint", vec![token.clone()], vec![cap, amount]);
            let quote_coin = b.obj(self.h.owned(quote_id))?;
            let (coin_a, coin_b) = if meme_is_a { (meme_coin, quote_coin) } else { (quote_coin, meme_coin) };
            let clock = self.clock(&mut b)?;
            let pool_pair = self.pool_pair(&token);
            let created = if self.route.is_cetus() {
                let config = self.shared(&mut b, self.venue("cetus_global_config"), false)?;
                let pools = self.shared(&mut b, self.venue("cetus_pools"), true)?;
                let spacing = b.pure(CETUS_TICK_SPACING)?;
                let Argument::Result(range) =
                    call(&mut b, id(CETUS), "pool_creator", "full_range_tick_range", vec![], vec![spacing])
                else {
                    unreachable!()
                };
                let args = vec![
                    config,
                    pools,
                    spacing,
                    b.pure(sqrt_price)?,
                    b.pure(String::new())?,
                    Argument::NestedResult(range, 0),
                    Argument::NestedResult(range, 1),
                    coin_a,
                    coin_b,
                    b.pure(fix_a)?,
                    clock,
                ];
                let Argument::Result(created) =
                    call(&mut b, id(CETUS), "pool_creator", "create_pool_v3", pool_pair, args)
                else {
                    unreachable!()
                };
                (0..3).map(|i| Argument::NestedResult(created, i)).collect::<Vec<_>>()
            } else {
                let fee = b.pure(self.bluefin_creation_fee()?)?;
                let Argument::Result(fee) = b.command(Command::SplitCoins(Argument::GasCoin, vec![fee])) else {
                    unreachable!()
                };
                let fee = call(&mut b, SUI_FRAMEWORK_PACKAGE_ID, "coin", "into_balance", vec![sui()], vec![
                    Argument::NestedResult(fee, 0),
                ]);
                let balance_a =
                    call(&mut b, SUI_FRAMEWORK_PACKAGE_ID, "coin", "into_balance", vec![token.clone()], vec![coin_a]);
                let balance_b = call(&mut b, SUI_FRAMEWORK_PACKAGE_ID, "coin", "into_balance", vec![sui()], vec![coin_b]);
                let spacing = BLUEFIN_TICK_SPACING as i32;
                let lower = (-(MAX_TICK / spacing * spacing)) as u32;
                let upper = (MAX_TICK / spacing * spacing) as u32;
                let mut args = vec![clock, self.shared(&mut b, self.venue("bluefin_global_config"), true)?];
                for text in [&b"PTB-SUI"[..], b"", b"PTB"] {
                    args.push(b.pure(text.to_vec())?);
                }
                args.extend([
                    b.pure(9u8)?,
                    b.pure(Vec::<u8>::new())?,
                    b.pure(b"SUI".to_vec())?,
                    b.pure(9u8)?,
                    b.pure(Vec::<u8>::new())?,
                    b.pure(BLUEFIN_TICK_SPACING)?,
                    b.pure(BLUEFIN_FEE_RATE)?,
                    b.pure(sqrt_price)?,
                    fee,
                    b.pure(lower)?,
                    b.pure(upper)?,
                    balance_a,
                    balance_b,
                    b.pure(if fix_a { meme } else { quote })?,
                    b.pure(fix_a)?,
                ]);
                let Argument::Result(created) = call(
                    &mut b,
                    id(BLUEFIN),
                    "pool",
                    "create_pool_with_liquidity",
                    vec![token.clone(), sui(), sui()],
                    args,
                ) else {
                    unreachable!()
                };
                let residual_a = call(&mut b, SUI_FRAMEWORK_PACKAGE_ID, "coin", "from_balance", vec![token.clone()], vec![
                    Argument::NestedResult(created, 4),
                ]);
                let residual_b = call(&mut b, SUI_FRAMEWORK_PACKAGE_ID, "coin", "from_balance", vec![sui()], vec![
                    Argument::NestedResult(created, 5),
                ]);
                vec![Argument::NestedResult(created, 1), residual_a, residual_b]
            };
            b.transfer_args(self.h.sender, created);
            if fix_a != larger_is_a {
                self.h.execute(b.finish())?.assert_success();
                continue;
            }
            let (expected, watched) = if self.route.is_cetus() {
                ensure!(!fix_a, "both Cetus routes fix coin B when fixing the larger side");
                let expected = Expected::Abort { package: id(CETUS), module: "factory", code: CETUS_AMOUNT_A_ABOVE_LIMIT };
                (expected, [treasury_cap, quote_id, self.venue("cetus_pools")])
            } else {
                let expected =
                    Expected::Abort { package: id(BLUEFIN), module: "utils", code: BLUEFIN_INSUFFICIENT_COIN_BALANCE };
                (expected, [treasury_cap, quote_id, self.venue("bluefin_global_config")])
            };
            self.h.assert_rolled_back(b.finish(), expected, &watched, &[self.h.sender])?;
        }
        self.report(format!(
            "direct {} pool for a fresh token at meme={meme} quote={quote}, same price and full range: fixing the larger side aborts ({}), rolled back; fixing the smaller side succeeds",
            self.route.module(),
            if self.route.is_cetus() { "Cetus factory 5: coin A below the amount the fixed coin B needs" } else { "Bluefin utils 1004 EInsufficientCoinBalance" },
        ));

        Ok(())
    }

}

// === Presale object and event mirrors (BCS field order) ===

#[derive(Debug, Deserialize, PartialEq)]
enum Lifecycle {
    Pending,
    Open,
    Funded,
    Migrated,
    Cancelled,
}

#[derive(Debug, Deserialize, PartialEq)]
enum Eligibility {
    Open { wallet_cap: u64, max_participants: u64, min_commitment: u64 },
    Allowlisted { root: Vec<u8>, leaf_count: u64 },
}

/// Mirrors `blast_presale::blast_presale::RecipientShare`.
#[derive(Debug, Deserialize, PartialEq)]
struct RecipientShare {
    recipient: SuiAddress,
    bps: u64,
}

/// Mirrors `blast_presale::blast_presale::UncappedPhase`.
#[derive(Debug, Deserialize, PartialEq)]
struct UncappedPhase {
    _starts_after_ms: u64,
    _access: UncappedAccess,
    _hard_cap: bool,
}

/// Mirrors `blast_presale::blast_presale::UncappedAccess`.
#[derive(Debug, Deserialize, PartialEq)]
enum UncappedAccess {
    _Eligible,
    _Anyone { _max_participants: u64, _min_commitment: u64 },
}

/// Mirrors `blast_presale::blast_presale::Presale`; each `Balance` is one `u64` and the
/// `TypeName` one string.
#[derive(Debug, Deserialize, PartialEq)]
struct PresaleState {
    id: ObjectID,
    presale_cap_id: ObjectID,
    lifecycle: Lifecycle,
    duration_ms: u64,
    liquidity_window_ms: u64,
    end_ms: u64,
    liquidity_deadline_ms: u64,
    raise_target: u64,
    eligibility: Eligibility,
    _uncapped: Option<UncappedPhase>,
    _uncapped_from_ms: u64,
    migration_witness: String,
    tick_spacing: u32,
    pool_fee_rate: u64,
    fee_recipients: Vec<RecipientShare>,
    holder_rewards_bps: u64,
    total_commitments: u64,
    remaining_commitments: u64,
    participants: u64,
    quote: u64,
    token_allocation: u64,
    sale_tokens: u64,
    liquidity_tokens: u64,
    _recipient_payouts: Vec<(SuiAddress, u64)>,
    recipient_tokens: u64,
    _raise_payouts: Vec<(SuiAddress, u64)>,
    _protocol_fees: ProtocolFees,
    protocol_quote: u64,
    protocol_tokens: u64,
}

/// Mirrors `blast_presale::fee_policy::ProtocolFees`.
#[derive(Debug, Deserialize, PartialEq)]
struct ProtocolFees {
    _raise_bps: u64,
    _token_bps: u64,
    _lp_fee_meme_bps: u64,
    _lp_fee_quote_bps: u64,
}

/// Mirrors `blast_presale::presale_vault::PresaleVault`.
#[derive(Debug, Deserialize)]
struct VaultState {
    _id: ObjectID,
    presale_id: ObjectID,
    presale_cap_id: ObjectID,
    pool_id: ObjectID,
    _fee_recipients: Vec<RecipientShare>,
    _holder_rewards_bps: u64,
    _protocol_fees: ProtocolFees,
    migration_meme_residual: u64,
    migration_quote_residual: u64,
    holder_rewards_meme: u64,
    holder_rewards_quote: u64,
    next_round: u64,
    _last_checkpoint: Option<u64>,
}

#[derive(Deserialize)]
struct PresaleFunded {
    presale_id: ObjectID,
    total_commitments: u64,
    accepted_quote: u64,
    refundable_quote: u64,
    token_allocation: u64,
}

#[derive(Deserialize)]
struct PresaleMigrated {
    presale_id: ObjectID,
    migration_witness: String,
    liquidity_quote: u64,
    liquidity_tokens: u64,
    recipient_tokens: u64,
}

#[derive(Deserialize)]
struct RecipientAllocated {
    _presale_id: ObjectID,
    recipient: SuiAddress,
    tokens: u64,
}

#[derive(Deserialize)]
struct Claimed {
    _presale_id: ObjectID,
    _participant: SuiAddress,
    wallet_commitment: u64,
    tokens: u64,
    quote_refund: u64,
    remaining_commitments: u64,
}

#[derive(Deserialize)]
struct VaultCreated {
    vault_id: ObjectID,
    presale_id: ObjectID,
    pool_id: ObjectID,
    position_id: ObjectID,
    liquidity: u128,
    fee_recipients: Vec<SuiAddress>,
    fee_recipient_bps: Vec<u64>,
    holder_rewards_bps: u64,
    protocol_lp_fee_meme_bps: u64,
    protocol_lp_fee_quote_bps: u64,
    migration_meme_residual: u64,
    migration_quote_residual: u64,
}

#[derive(Clone, Debug, Deserialize)]
struct FeesCollected {
    vault_id: ObjectID,
    gross_meme: u64,
    gross_quote: u64,
    protocol_destination: SuiAddress,
    protocol_meme: u64,
    protocol_quote: u64,
    fee_recipient_meme: Vec<u64>,
    fee_recipient_quote: Vec<u64>,
    holder_rewards_meme: u64,
    holder_rewards_quote: u64,
}

impl FeesCollected {
    fn line(&self) -> String {
        format!(
            "gross=({}, {}) recipients=({:?}, {:?}) holder rewards=({}, {})",
            self.gross_meme, self.gross_quote, self.fee_recipient_meme, self.fee_recipient_quote, self.holder_rewards_meme, self.holder_rewards_quote,
        )
    }
}

#[derive(Deserialize)]
struct ResidualsClaimed {
    _vault_id: ObjectID,
    meme: u64,
    quote: u64,
}
