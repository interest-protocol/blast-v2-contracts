//! Venue-fork gate for `blast_presale` against pinned Cetus CLMM, Cetus LP Burn and Bluefin Spot
//! mainnet bytecode, offline.
//!
//! Each world inserts the committed mainnet snapshot (`fork/`, see `blast_launchpad_ptb_tests::fork`)
//! into the in-memory simulator at the real IDs, then publishes the local admin, partner, vesting,
//! `blast_core`, `blast_vault`, `blast_presale` and `blast_migrators` packages, the migrators linked
//! to the real venue packages. The vault package is released with the route's venue and the
//! presale's package witness listed, and the presale's creation policy admits the same venue. No
//! transaction reaches a network.
//!
//! Every route runs through `blast_migrators`, the venues both products share: the presale's own
//! `migrate` returns the sale's `Migration` and the venue's `migrate` redeems it in the same PTB.
//!
//! One lifecycle test per route runs through public PTBs: Cetus with Meme as coin A (SUI Quote),
//! Cetus with Meme as coin B (USDC Quote), and Bluefin (SUI Quote). Each creation PTB runs the
//! venue's `prepare` on the sale token's `TreasuryCap`, then `blast_presale::new` takes the cap and
//! the venue ticket (ADR 0137). Each creates a presale with open eligibility, commits with
//! overflow, settles after the window, and shows that a migration aborting after pool creation
//! commits nothing, that Cetus refuses the reversed coin order and a foreign pair, and that Bluefin
//! charges exactly its configured creation fee. One PTB then migrates into a new full-range pool at
//! the configured tier, pays the recipient allocations, and seals the position (the LP Burn proof
//! on Cetus) in a shared `blast_vault` vault that keeps the migration residuals for the owner;
//! supplied plus residual reconciles exactly with the hand-off. The participant claims its tokens
//! and overflow, real swaps accrue fees, permissionless collections pay every address route and
//! grow the vault's holder-reward balances by the exact apportionment. A split change is proved
//! with the `PresaleCap` and applied after the vault's delay; collection against another pool of
//! the same type is refused, and the owner claims the migration residuals with an owner proof.
//!
//! A partnered Bluefin sale under nonzero Blast rates shows the fee ledger's two paths as PTB
//! commands: the migration holds Blast's raise and token fees, and
//! `pay_protocol_fees_with_partner` pays the partner its cut of each and the treasury the rest.
//!
//! The fix-side tests seed each route with a raise and LP allocation of about 2^62 atoms whose
//! larger side, if fixed, makes the venue demand one atom more of the smaller side than the
//! hand-off holds. Against the same venue bytecode, a direct pool creation fixing the larger side
//! aborts, while the presale migration falls back to the smaller side and succeeds.
//!
//! Run from `sui/launchpad/ptb_tests` with `cargo test --offline --test presale_venue_fork`.

use std::{collections::{BTreeMap, BTreeSet}, sync::OnceLock, time::Duration};

use anyhow::{Context, Result, bail, ensure};
use blast_launchpad_ptb_tests::{
    CompiledPackage, Delayed, DelayedAction, DelayedApplied, Destination, Expected, FeeSplit,
    GenericPackageVersionContents, Harness, Outcome, PUBLICATION_UPGRADE_DELAY_MS, RoundTerms, UnlinkedPackage, VaultStack, append_presale_unpause, build,
    build_unlinked, call,
    fork::{
        BLUEFIN, BLUEFIN_MAX_SQRT_PRICE, BLUEFIN_MIN_SQRT_PRICE, BluefinPoolCreated, BurnPosition, BurnProof,
        BurnRecord, CETUS, CETUS_MAX_SQRT_PRICE, CETUS_MIN_SQRT_PRICE, CetusCollectFee, CetusOpenPosition,
        CetusPoolState, CreatePool, LiquidityProvided, MAX_TICK, MintPoolCreationCap, RegisterPermissionPair, USDC,
        UserFeeCollected, apportion, cetus_name, expected_sqrt_price, id, insert_snapshot, meme_is_cetus_a, sui, tag,
        venue_dependencies, venue_events,
    },
    presale_otw, presale_role, publish_core_stack, sui_dir, unique_bps,
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
/// LP fees: two address routes (the creator is the first) and the holder-reward route.
const FEE_BPS: [u64; 2] = [6_000, 2_500];
const HOLDER_REWARDS_BPS: u64 = 1_500;
const DURATION_MS: u64 = 3_600_000;
/// The shortest LP window `blast_presale::finalize` accepts: seven days.
const LIQUIDITY_WINDOW_MS: u64 = 604_800_000;
/// The vault's fixed delay for fee-split changes.
const VAULT_FEE_DELAY_MS: u64 = 172_800_000;

/// Near-equal seed atoms from `fixside_sim.py`: fixing the larger side makes both venues demand
/// `SMALL + 1` of the smaller side.
const SMALL: u64 = 1 << 62;
const LARGE: u64 = SMALL + 1;
/// The liquidity each venue's own math gives when the smaller side is fixed (same model).
const CETUS_NEAR_EQUAL_LIQUIDITY: u128 = 4_611_686_019_503_084_323;
const BLUEFIN_NEAR_EQUAL_LIQUIDITY: u128 = 4_611_686_019_504_160_504;

/// `blast_presale::errors` registry code, raised by `blast_presale`.
const INVALID_LIFECYCLE: u64 = 11;
/// `blast_admin::errors` codes, raised by the generic `package_version`.
const INVALID_PAUSE_BITS: u64 = 19;
const PAUSE_UNCHANGED: u64 = 20;
/// `blast_migrators::errors` registry codes, raised by its `cetus` and `bluefin` modules.
const MIGRATORS_INVALID_COIN_ORDER: u64 = 0;
const MIGRATORS_POSITION_POOL_MISMATCH: u64 = 1;
const MIGRATORS_WRONG_COIN_PAIR: u64 = 2;
/// `blast_vault::errors` code.
const NOTHING_TO_CLAIM: u64 = 6;
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
const PARTNER: ObjectID = address(&[0x9A]);

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

/// Every reachable pause state against every u8 input, through unmodified production bytecode.
/// Pausing is `blast_admin`'s and reads no consumer version; unpausing is the presale's
/// `creation_policy::unpause`, which rejects a stale version first.
#[test]
fn presale_pause_exhaustively_checks_masks_events_rollback_and_version_precedence() -> Result<()> {
    let mut w = World::new(Route::Bluefin)?;
    w.change_role("PauseAdmin", true)?;
    w.change_role("UnpauseAdmin", true)?;
    // A set oracle keeps expected transitions independent of the contract's bitwise formulas.
    let states: [&[u8]; 8] = [&[], &[1], &[2], &[1, 2], &[4], &[1, 4], &[2, 4], &[1, 2, 4]];
    let sale = w.open_sale(&Terms::standard(Route::Bluefin))?;
    let watched = [w.version, w.acl, w.admin_cap, w.creation_policy, w.fee_policy,
        w.venue_config, w.package_admin, sale.presale, sale.cap, sale.currency];
    let mut successes = 0;
    let mut invalid = 0;
    let mut unchanged = 0;
    let mut stale = 0;
    for version in [1, 2] {
        for flags in states {
            let mask: u8 = flags.iter().sum();
            w.set_pause_version_for_fixture(1)?;
            w.replace_pause_mask(mask)?;
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
                        w.replace_pause_mask(mask)?;
                        w.set_pause_version_for_fixture(version)?;
                        successes += 1;
                    }
                    assert_eq!(w.pause_state()?, (w.version, mask, version),
                        "pausing={pausing}, bits={bits}, initial={mask}, version={version}");
                }
            }
        }
    }
    assert_eq!((successes, invalid, unchanged, stale), (111, 5976, 57, 2048));
    Ok(())
}

#[test]
fn presale_pause_roles_revocation_and_failed_sequences_preserve_state_and_events() -> Result<()> {
    let mut w = World::new(Route::Bluefin)?;
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

#[test]
fn presale_bluefin_with_an_arbitrary_meme_quote_against_mainnet_bytecode() -> Result<()> {
    run_world(World::new_with_quote(Route::Bluefin, true)?)
}

#[test]
fn presale_bluefin_quote_larger_seed_fixes_quote() -> Result<()> {
    let mut world = World::new_with_quote(Route::Bluefin, true)?;
    let mut terms = Terms::standard(Route::Bluefin);
    terms.supply = terms.raise;
    let sale = world.open_sale(&terms)?;
    let migration = world.migrate(&sale, &terms)?;
    ensure!(migration.residual.0 > 0, "the venue did not need all of Meme");
    ensure!(migration.residual.1 <= 1, "the venue used the fixed Quote side");
    Ok(())
}

/// A partnered sale under nonzero Blast rates: migration holds Blast's raise and token fees in the
/// sale's ledger, and `pay_protocol_fees_with_partner` then pays the partner its cut of each and
/// the treasury the rest, every amount checked against the coins sent.
#[test]
fn presale_bluefin_partnered_sale_pays_blast_and_its_partner_from_the_ledger() -> Result<()> {
    const RAISE_BPS: u64 = 300;
    const TOKEN_BPS: u64 = 100;
    const PARTNER_CUT_BPS: u64 = 4_000;
    let mut w = World::new(Route::Bluefin)?;
    w.set_protocol_rates(RAISE_BPS, TOKEN_BPS)?;
    let partner = w.register_partner(PARTNER, PARTNER_CUT_BPS)?;
    let terms = Terms::with_protocol_rates(Route::Bluefin, RAISE_BPS, TOKEN_BPS);
    let sale = w.open_partnered_sale(&terms, Some(partner))?;
    let (tokens, quote) = (terms.protocol_tokens(), terms.protocol_quote());
    ensure!(tokens > 0 && quote > 0, "Blast reserves a share of both");

    let mut b = ProgrammableTransactionBuilder::new();
    w.migrate_command(&mut b, &sale, None, None)?;
    let migrated = w.h.execute(b.finish())?;
    migrated.assert_success();
    let paid: Vec<ProtocolFeesPaid> = w.package_events(&migrated, w.core, "blast_core_events", "ProtocolFeesPaid");
    ensure!(paid.is_empty(), "a partnered migration holds Blast's fees");
    let held = w.sale_state(&sale)?.fee_ledger;
    ensure!((held.meme, held.quote, held.sui) == (tokens, quote, 0), "the ledger holds {held:?}");
    let releases: Vec<PresaleMigrated> = w.events(&migrated, "events", "PresaleMigrated");
    ensure!(releases.len() == 1 && releases[0].liquidity_quote == terms.raise - quote, "the LP keeps the rest of the raise");

    let mut b = ProgrammableTransactionBuilder::new();
    let args = vec![
        w.shared(&mut b, sale.presale, true)?,
        w.shared(&mut b, w.version, false)?,
        w.shared(&mut b, w.treasury, false)?,
        w.shared(&mut b, partner, false)?,
    ];
    call(&mut b, w.presale, "blast_presale", "pay_protocol_fees_with_partner", w.pair(&sale), args);
    let outcome = w.h.execute(b.finish())?;
    outcome.assert_success();
    // `blast_partners::pay`: the cut of each asset, rounded down.
    let cut = |amount: u64| (amount as u128 * PARTNER_CUT_BPS as u128 / 10_000) as u64;
    let (partner_tokens, partner_quote) = (cut(tokens), cut(quote));
    let paid: Vec<ProtocolFeesPaid> = w.package_events(&outcome, w.core, "blast_core_events", "ProtocolFeesPaid");
    ensure!(paid.len() == 1, "one ProtocolFeesPaid");
    let treasury: SuiAddress = id(blast_launchpad_ptb_tests::TEST_GENESIS_RECIPIENT).into();
    ensure!(
        paid[0] == ProtocolFeesPaid {
            package_witness: paid[0].package_witness.clone(),
            origin: sale.presale,
            treasury,
            meme_amount: tokens - partner_tokens,
            quote_amount: quote - partner_quote,
            sui_amount: 0,
            partner_id: Some(partner),
            partner_meme_amount: partner_tokens,
            partner_quote_amount: partner_quote,
            partner_sui_amount: 0,
        },
        "{:?}",
        paid[0]
    );
    ensure!(paid[0].package_witness.ends_with("::blast_presale_package::PackageWitness"), "{}", paid[0].package_witness);
    let partner_paid: Vec<(ObjectID, u64)> = outcome
        .events
        .iter()
        .filter(|event| ObjectID::from(event.type_.address) == w.partners && event.type_.name.as_str() == "PartnerPaid")
        .map(|event| bcs::from_bytes(&event.contents).expect("PartnerPaid"))
        .collect();
    ensure!(partner_paid == vec![(partner, partner_tokens), (partner, partner_quote)], "{partner_paid:?}");
    ensure!(outcome.coins_created_for(&w.h, PARTNER.into()) == w.coins(&sale.meme, partner_tokens, partner_quote));
    ensure!(outcome.coins_created_for(&w.h, treasury) == w.coins(&sale.meme, tokens - partner_tokens, quote - partner_quote));
    let after = w.sale_state(&sale)?.fee_ledger;
    ensure!((after.meme, after.quote, after.sui) == (0, 0, 0), "the ledger is drained");
    w.report(format!(
        "partnered Bluefin sale at {RAISE_BPS}/{TOKEN_BPS} BPS: ledger held ({tokens}, {quote}); partner paid ({partner_tokens}, {partner_quote}), treasury the rest"
    ));
    w.print_report();
    Ok(())
}

/// The whole lifecycle of one presale on `route`.
fn run(route: Route) -> Result<()> {
    run_world(World::new(route)?)
}

fn run_world(mut w: World) -> Result<()> {
    let route = w.route;
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

    w.delayed_fee_split(&sale, &m, &terms)?;
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

fn finalize_currency(h: &mut Harness, pending: ObjectID, coin: &TypeTag) -> Result<ObjectID> {
    let mut b = ProgrammableTransactionBuilder::new();
    let registry = b.obj(h.shared(SUI_COIN_REGISTRY_OBJECT_ID, true))?;
    let receiving = b.obj(ObjectArg::Receiving(h.object(pending).compute_object_reference()))?;
    call(
        &mut b,
        SUI_FRAMEWORK_PACKAGE_ID,
        "coin_registry",
        "finalize_registration",
        vec![coin.clone()],
        vec![registry, receiving],
    );
    let finalized = h.execute(b.finish())?;
    finalized.assert_success();
    let currency = finalized.created(h, "coin_registry", "Currency");
    ensure!(currency.len() == 1);
    Ok(currency[0])
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
        matches!(self, Route::CetusMemeA | Route::CetusMemeB)
    }

    /// Whether Meme is the pool's coin A.
    fn meme_is_a(self) -> bool {
        self != Route::CetusMemeB
    }

    fn module(self) -> &'static str {
        match self {
            Self::CetusMemeA | Self::CetusMemeB => "cetus",
            Self::Bluefin => "bluefin",
        }
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
    /// Blast's rates the fee policy charges, of the supply and of the raise.
    protocol_token_bps: u64,
    protocol_raise_bps: u64,
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
            protocol_token_bps: 0,
            protocol_raise_bps: 0,
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
            protocol_token_bps: 0,
            protocol_raise_bps: 0,
            recipients: vec![],
            raise,
            wallet_cap: raise,
            max_participants: 1,
            min_commitment: raise,
            commitment: raise,
        }
    }

    /// The standard sale under Blast rates of `protocol_raise_bps` and `protocol_token_bps`, the
    /// second recipient giving up Blast's token share.
    fn with_protocol_rates(route: Route, protocol_raise_bps: u64, protocol_token_bps: u64) -> Self {
        let mut terms = Terms::standard(route);
        terms.protocol_raise_bps = protocol_raise_bps;
        terms.protocol_token_bps = protocol_token_bps;
        terms.recipients[1].1 -= protocol_token_bps;
        terms
    }

    /// The supply apportioned as creation does: buyers, the LP, Blast, then each recipient.
    fn allocations(&self) -> Vec<u64> {
        let mut weights = vec![self.sale_bps, self.lp_bps, self.protocol_token_bps];
        weights.extend(self.recipients.iter().map(|(_, bps)| *bps));
        apportion(&weights, self.supply)
    }

    /// Blast's share of the supply.
    fn protocol_tokens(&self) -> u64 {
        self.allocations()[2]
    }

    /// Blast's share of the raise, apportioned with the LP's (no raise recipients).
    fn protocol_quote(&self) -> u64 {
        apportion(&[self.protocol_raise_bps, 10_000 - self.protocol_raise_bps], self.raise)[0]
    }

    fn sale_tokens(&self) -> u64 {
        self.allocations()[0]
    }

    fn lp_tokens(&self) -> u64 {
        self.allocations()[1]
    }

    fn recipient_tokens(&self) -> Vec<u64> {
        self.allocations()[3..].to_vec()
    }
}

/// `blast_presale` compiles once per test binary; each world links it to its own packages.
fn presale() -> &'static UnlinkedPackage {
    static PRESALE: OnceLock<UnlinkedPackage> = OnceLock::new();
    PRESALE.get_or_init(|| {
        let work = blast_launchpad_ptb_tests::test_work_dir().join(env!("CARGO_PKG_NAME")).join("presale_venue_fork");
        build_unlinked(&sui_dir().join("presale"), &["blast_admin", "blast_partners", "blast_fun_vesting", "blast_core"], &work)
            .expect("build the presale")
    })
}

/// `blast_migrators` compiles once per test binary; each world links it to its own packages.
fn migrators() -> &'static UnlinkedPackage {
    static MIGRATORS: OnceLock<UnlinkedPackage> = OnceLock::new();
    MIGRATORS.get_or_init(|| {
        let work = blast_launchpad_ptb_tests::test_work_dir().join(env!("CARGO_PKG_NAME")).join("presale_venue_fork_migrators");
        build_unlinked(
            &sui_dir().join("migrators"),
            &["blast_admin", "blast_partners", "blast_fun_vesting", "blast_core", "blast_vault"],
            &work,
        )
        .expect("build the migrators")
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
    /// (Meme, Quote) the venue took and the vault kept for the owner.
    supplied: (u64, u64),
    residual: (u64, u64),
}

struct World {
    h: Harness,
    route: Route,
    checkpoint: u64,
    venue: BTreeMap<String, ObjectID>,
    presale: ObjectID,
    /// `blast_migrators`, which hosts the route's venue module.
    venues: ObjectID,
    /// The migrators' own package version.
    venue_version: ObjectID,
    core: ObjectID,
    partners: ObjectID,
    vault_stack: VaultStack,
    treasury: ObjectID,
    version: ObjectID,
    admin: ObjectID,
    acl: ObjectID,
    root: ObjectID,
    admin_cap: ObjectID,
    package_admin: ObjectID,
    venue_config: ObjectID,
    creation_policy: ObjectID,
    fee_policy: ObjectID,
    /// The shared `blast_presale::PresaleRegistry` every presale ID derives from.
    presale_registry: ObjectID,
    token: CompiledPackage,
    quote_type: TypeTag,
    quote_currency: ObjectID,
    coins: u64,
    /// The vault's applied split, which every collection's payout oracle reads.
    split: FeeSplit,
    lines: Vec<String>,
}

impl World {
    /// Inserts the snapshot and publishes the local presale, the migrators and their dependencies,
    /// the migrators linked to the real venue packages.
    fn new(route: Route) -> Result<Self> {
        Self::new_with_quote(route, false)
    }

    fn new_with_quote(route: Route, custom_quote: bool) -> Result<Self> {
        let work =
            blast_launchpad_ptb_tests::test_work_dir().join(env!("CARGO_PKG_NAME")).join(format!("presale_fork_{route:?}"));
        let mut h = Harness::new()?;
        let (checkpoint, venue) = insert_snapshot(&mut h)?;

        let stack = publish_core_stack(&mut h, &work)?;
        let (admin, core) = (stack.admin, stack.core);
        let admin_published = &stack.admin_publication;
        let (vault, vault_publication) = stack.publish(&mut h, &sui_dir().join("vault"), &work)?;
        let base = [ObjectID::from_single_byte(1), ObjectID::from_single_byte(2), admin, stack.partners, stack.vesting, core];
        let linked = presale().link(
            &[
                ("blast_admin", admin),
                ("blast_partners", stack.partners),
                ("blast_fun_vesting", stack.vesting),
                ("blast_core", core),
            ],
            base.to_vec(),
        )?;
        let (presale, published) = h.publish(linked)?;
        let mut dependencies = base.to_vec();
        dependencies.push(vault);
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
        let (venues, migrators_publication) = h.publish(linked)?;
        let venue_config = migrators_publication.created(&h, "venue_config", "VenueConfig");
        ensure!(venue_config.len() == 1 && h.object(venue_config[0]).is_shared());
        let venue_version = h.wrap_migrators(admin, venues, &migrators_publication)?;
        let fee_policy = published.created(&h, "fee_policy", "FeePolicy");
        ensure!(fee_policy.len() == 1 && h.object(fee_policy[0]).is_shared());
        let creation_policy = published.created(&h, "creation_policy", "CreationPolicy");
        ensure!(creation_policy.len() == 1 && h.object(creation_policy[0]).is_shared());
        let presale_registry = h.derived_registry(&published, "blast_presale", "PresaleRegistry")?;
        let token = build(&blast_launchpad_ptb_tests::crate_dir().join("fixture/presale_token"), &[], &work)?;
        let (quote_type, quote_currency) = if custom_quote {
            let (package, published) = h.publish(token.clone())?;
            let quote = tag(&format!("{package}::token::TOKEN"));
            let pending = published.created(&h, "coin_registry", "Currency");
            ensure!(pending.len() == 1);
            let currency = finalize_currency(&mut h, pending[0], &quote)?;
            (quote, currency)
        } else {
            (route.quote(), *venue.get("sui_currency").context("SUI currency")?)
        };
        // Both admissions name the route's one venue witness: the vault registry lists it, beside
        // the presale's package witness as the issuer of the sale's vault terms, while the vault
        // package is paused, and the creation policy admits it.
        let venue_type = tag(&format!("{venues}::{}::Venue", route.module()));
        let issuer_type = tag(&format!("{presale}::blast_presale_package::PackageWitness"));
        let vault_stack = h.wrap_vault(admin, vault, &vault_publication)?;
        h.release_vault(admin, admin_published, core, &vault_stack, stack.treasury, &[venue_type.clone(), issuer_type])?;

        // Publication keeps an owned generic Publication; `blast_admin::package_admin::wrap` seals
        // the UpgradeCap and shares the version with every presale bit paused.
        ensure!(published.created(&h, "package_version", "PackageVersion").is_empty(), "no version before custody");
        let clock_before = h.contents(SUI_CLOCK_OBJECT_ID);
        let bootstrap = published.created(&h, "package_version", "Publication");
        let upgrade_cap = published.created(&h, "package", "UpgradeCap");
        ensure!(bootstrap.len() == 1 && upgrade_cap.len() == 1);
        let mut b = ProgrammableTransactionBuilder::new();
        let bootstrap_arg = b.obj(h.owned(bootstrap[0]))?;
        let upgrade_cap_arg = b.obj(h.owned(upgrade_cap[0]))?;
        call(&mut b, admin, "package_admin", "wrap", vec![presale_otw(presale)?], vec![bootstrap_arg, upgrade_cap_arg]);
        let wrapped = h.execute(b.finish())?;
        wrapped.assert_success();
        ensure!(wrapped.effects.deleted().iter().any(|object| object.0 == bootstrap[0]), "wrap consumes the publication");
        ensure!(wrapped.effects.wrapped().iter().map(|object| object.0).collect::<Vec<_>>() == upgrade_cap, "custody seals the cap");
        let versions = wrapped.created(&h, "package_version", "PackageVersion");
        ensure!(versions.len() == 1 && h.object(versions[0]).is_shared());
        let version = versions[0];
        let (_, valid, paused, package_witness, stored_version): GenericPackageVersionContents =
            bcs::from_bytes(&h.contents(version))?;
        ensure!((valid, paused, stored_version) == (7, 7, 1), "the presale starts fully paused at version 1");
        ensure!(package_witness.ends_with("::blast_presale_package::PackageWitness"), "{package_witness}");
        let package_admin = wrapped.created(&h, "package_admin", "PackageAdmin");
        ensure!(package_admin.len() == 1);
        h.assert_publication_upgrade_delay(package_admin[0])?;
        let config_cap = h.configuration_admin(admin, admin_published, core, "blast_domain", &["ListingAdmin", "VenueAdmin", "FeeAdmin"])?;
        let mut b = ProgrammableTransactionBuilder::new();
        let listing = h.configuration_witness(&mut b, admin, admin_published, config_cap, core, "blast_domain", "ListingAdmin")?;
        let adapter = h.configuration_witness(&mut b, admin, admin_published, config_cap, core, "blast_domain", "VenueAdmin")?;
        let fee_admin = h.configuration_witness(&mut b, admin, admin_published, config_cap, core, "blast_domain", "FeeAdmin")?;
        let policy = b.obj(h.shared(creation_policy[0], true))?;
        let version_arg = b.obj(h.shared(version, false))?;
        let clock = b.obj(h.shared(SUI_CLOCK_OBJECT_ID, false))?;
        let allowed = b.pure(true)?;
        call(&mut b, presale, "creation_policy", "set_quote_allowed", vec![quote_type.clone()], vec![policy, version_arg, listing, allowed]);
        call(&mut b, presale, "creation_policy", "schedule_venue", vec![venue_type.clone()], vec![policy, version_arg, adapter, clock]);
        call(&mut b, presale, "creation_policy", "apply_venue", vec![venue_type], vec![policy, version_arg, clock]);
        let delay = b.pure(PUBLICATION_UPGRADE_DELAY_MS)?;
        call(&mut b, presale, "creation_policy", "schedule_venue_delay", vec![], vec![policy, version_arg, adapter, delay, clock]);
        call(&mut b, presale, "creation_policy", "apply_venue_delay", vec![], vec![policy, version_arg, clock]);
        let fees = b.obj(h.shared(fee_policy[0], true))?;
        // Venue arithmetic cases use an explicit zero-fee policy rather than publication defaults.
        let zero = b.pure(0u64)?;
        let zero_bps = call(&mut b, core, "bps", "new", vec![], vec![zero]);
        call(&mut b, presale, "fee_policy", "schedule_fees", vec![], vec![fees, version_arg, fee_admin, zero_bps, zero_bps, zero_bps, zero_bps, delay, clock]);
        call(&mut b, presale, "fee_policy", "apply_fees", vec![], vec![fees, version_arg, clock]);
        h.execute(b.finish())?.assert_success();
        h.unpause_presale(presale, admin, admin_published, version, package_admin[0], creation_policy[0], fee_policy[0], stack.treasury, 7)?;
        ensure!(h.contents(SUI_CLOCK_OBJECT_ID) == clock_before);

        Ok(World {
            route,
            checkpoint,
            venue,
            presale,
            venues,
            venue_version,
            presale_registry,
            core,
            partners: stack.partners,
            vault_stack,
            treasury: stack.treasury,
            version,
            admin,
            acl: admin_published.created(&h, "blast_acl", "ACL")[0],
            root: admin_published.created(&h, "blast_acl", "SuperAdminCap")[0],
            admin_cap: config_cap,
            package_admin: package_admin[0],
            venue_config: venue_config[0],
            creation_policy: creation_policy[0],
            fee_policy: fee_policy[0],
            token,
            quote_type,
            quote_currency,
            coins: 0,
            split: initial_split(),
            lines: Vec::new(),
            h,
        })
    }

    fn sign_in(&self, b: &mut ProgrammableTransactionBuilder, role: &str) -> Result<Argument> {
        let acl = b.obj(self.h.shared(self.acl, false))?;
        let cap = b.obj(self.h.owned(self.admin_cap))?;
        let role = presale_role(self.admin, self.core, self.presale, role)?;
        Ok(call(b, self.admin, "blast_acl", "sign_in", vec![role], vec![acl, cap]))
    }

    fn change_role(&mut self, role: &str, grant: bool) -> Result<()> {
        let mut b = ProgrammableTransactionBuilder::new();
        let acl = b.obj(self.h.shared(self.acl, true))?;
        let root = b.obj(self.h.owned(self.root))?;
        let cap = b.pure(self.admin_cap)?;
        let role = presale_role(self.admin, self.core, self.presale, role)?;
        call(&mut b, self.admin, "blast_acl", if grant { "grant_role" } else { "revoke_role" }, vec![role], vec![acl, root, cap]);
        self.h.impersonate_cap_owner(self.root, b.finish())?.assert_success();
        Ok(())
    }

    /// Schedules Blast's raise and token rates under the 48-hour delay, waits it out, and applies
    /// them; LP-fee rates stay zero.
    fn set_protocol_rates(&mut self, raise_bps: u64, token_bps: u64) -> Result<()> {
        let mut b = ProgrammableTransactionBuilder::new();
        let witness = self.sign_in(&mut b, "FeeAdmin")?;
        let fees = self.shared(&mut b, self.fee_policy, true)?;
        let version = self.shared(&mut b, self.version, false)?;
        let raise = self.bps(&mut b, raise_bps)?;
        let token = self.bps(&mut b, token_bps)?;
        let zero = self.bps(&mut b, 0)?;
        let delay = b.pure(PUBLICATION_UPGRADE_DELAY_MS)?;
        let clock = self.clock(&mut b)?;
        call(&mut b, self.presale, "fee_policy", "schedule_fees", vec![], vec![fees, version, witness, raise, token, zero, zero, delay, clock]);
        self.h.execute(b.finish())?.assert_success();
        self.h.sim.advance_clock(Duration::from_millis(PUBLICATION_UPGRADE_DELAY_MS));
        let mut b = ProgrammableTransactionBuilder::new();
        let fees = self.shared(&mut b, self.fee_policy, true)?;
        let version = self.shared(&mut b, self.version, false)?;
        let clock = self.clock(&mut b)?;
        call(&mut b, self.presale, "fee_policy", "apply_fees", vec![], vec![fees, version, clock]);
        self.h.execute(b.finish())?.assert_success();
        Ok(())
    }

    /// Registers a Blast partner paid at `recipient` with `share_bps` of Blast's fees, through a
    /// `PartnerAdmin` granted to the world's administrator, and lets new presales name it.
    fn register_partner(&mut self, recipient: ObjectID, share_bps: u64) -> Result<ObjectID> {
        let role = tag(&format!("{}::blast_partners::PartnerAdmin", self.partners));
        let mut b = ProgrammableTransactionBuilder::new();
        let acl = b.obj(self.h.shared(self.acl, true))?;
        let root = b.obj(self.h.owned(self.root))?;
        let cap = b.pure(self.admin_cap)?;
        call(&mut b, self.admin, "blast_acl", "grant_role", vec![role.clone()], vec![acl, root, cap]);
        self.h.impersonate_cap_owner(self.root, b.finish())?.assert_success();
        let mut b = ProgrammableTransactionBuilder::new();
        let acl = b.obj(self.h.shared(self.acl, false))?;
        let admin_cap = b.obj(self.h.owned(self.admin_cap))?;
        let witness = call(&mut b, self.admin, "blast_acl", "sign_in", vec![role], vec![acl, admin_cap]);
        let partner_cap = call(&mut b, self.partners, "blast_partners", "new_cap", vec![], vec![]);
        let cap_type = tag(&format!("{}::blast_partners::PartnerCap", self.partners));
        let cap_id = call(&mut b, SUI_FRAMEWORK_PACKAGE_ID, "object", "id", vec![cap_type], vec![partner_cap]);
        let recipient = b.pure(SuiAddress::from(recipient))?;
        let share = b.pure(share_bps)?;
        call(&mut b, self.partners, "blast_partners", "register", vec![], vec![witness, cap_id, recipient, share]);
        b.transfer_arg(self.h.sender, partner_cap);
        let registered = self.h.execute(b.finish())?;
        registered.assert_success();
        let partner = registered.created(&self.h, "blast_partners", "Partner");
        ensure!(partner.len() == 1 && self.h.object(partner[0]).is_shared());

        let mut b = ProgrammableTransactionBuilder::new();
        let witness = self.sign_in(&mut b, "FeeAdmin")?;
        let policy = self.shared(&mut b, self.creation_policy, true)?;
        let version = self.shared(&mut b, self.version, false)?;
        let partner_arg = self.shared(&mut b, partner[0], false)?;
        call(&mut b, self.presale, "creation_policy", "add_partner", vec![], vec![policy, version, witness, partner_arg]);
        self.h.execute(b.finish())?.assert_success();
        Ok(partner[0])
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

    /// Appends `blast_admin::package_admin::pause` or the presale's `creation_policy::unpause`
    /// under `role`'s witness.
    fn append_pause(&self, b: &mut ProgrammableTransactionBuilder, pause: bool, bits: u8, role: &str) -> Result<()> {
        let witness = self.sign_in(b, role)?;
        if !pause {
            return append_presale_unpause(&self.h, b, self.presale, self.package_admin, self.version, witness,
                self.creation_policy, self.fee_policy, self.treasury, bits);
        }
        let version = b.obj(self.h.shared(self.version, true))?;
        let bits = b.pure(bits)?;
        call(b, self.admin, "package_admin", "pause", vec![presale_otw(self.presale)?], vec![version, witness, bits]);
        Ok(())
    }

    /// The version's ID, paused bits and version.
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

    /// Seeds the stored version of the migrators' generic `PackageVersion`.
    fn set_venue_version_for_fixture(&mut self, version: u64) -> Result<()> {
        let (id, valid, paused, witness, _): GenericPackageVersionContents =
            bcs::from_bytes(&self.h.contents(self.venue_version))?;
        let mut object = self.h.object(self.venue_version);
        object.data.try_as_move_mut().context("migrators PackageVersion")?
            .set_contents_unsafe(bcs::to_bytes(&(id, valid, paused, witness, version))?);
        self.h.insert(object);
        Ok(())
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
        self.quote_type.clone()
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

    /// A `blast_core::bps::Bps` built in the PTB, since a `Bps` cannot be a pure argument.
    fn bps(&self, b: &mut ProgrammableTransactionBuilder, value: u64) -> Result<Argument> {
        unique_bps(b, self.core, value)
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
            .filter(|object| {
                object.coin_type_maybe().is_some_and(|coin| coin.to_canonical_string(true) == wanted)
            })
            .max_by_key(|object| object.get_coin_value_unsafe())
            .map(|object| object.id())
            .with_context(|| format!("a {wanted} coin"))
    }

    /// Presale events of `module::name`.
    /// Events of `name` that `package`'s `module` emitted.
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

    /// Vault events of `name`, from `blast_vault_events`.
    fn vault_events<T: DeserializeOwned>(&self, outcome: &Outcome, name: &str) -> Vec<T> {
        outcome
            .events
            .iter()
            .filter(|event| {
                ObjectID::from(event.type_.address) == self.vault_stack.package
                    && event.type_.module.as_str() == "blast_vault_events"
                    && event.type_.name.as_str() == name
            })
            .map(|event| bcs::from_bytes(&event.contents).expect("vault event payload"))
            .collect()
    }

    /// The ID `vault::new` claims for `sale`'s one vault, from the presale's package witness and
    /// the sale.
    fn vault_id(&self, sale: &Sale) -> Result<ObjectID> {
        self.vault_stack.vault_id(&self.presale_tag("blast_presale_package", "PackageWitness"), sale.presale)
    }

    fn sale_state(&self, sale: &Sale) -> Result<PresaleState> {
        bcs::from_bytes(&self.h.contents(sale.presale)).context("decode Presale")
    }

    fn vault(&self, m: &Migration) -> Result<VaultState> {
        self.vault_at(m.vault)
    }

    fn vault_at(&self, vault: ObjectID) -> Result<VaultState> {
        bcs::from_bytes(&self.h.contents(vault)).context("decode Vault")
    }

    /// Appends `blast_presale::prove_owner` with the sale's `PresaleCap`, returning the proof.
    fn prove_owner(&self, b: &mut ProgrammableTransactionBuilder, sale: &Sale) -> Result<Argument> {
        let presale = self.shared(b, sale.presale, false)?;
        let version = self.shared(b, self.version, false)?;
        let cap = b.obj(self.h.owned(sale.cap))?;
        Ok(call(b, self.presale, "blast_presale", "prove_owner", self.pair(sale), vec![presale, version, cap]))
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
            let currency = finalize_currency(&mut self.h, pending[0], &meme)?;
            return Ok((treasury_cap[0], currency, meme));
        }
        bail!("no published token had the route's Cetus coin order")
    }

    /// One PTB: the venue's `prepare` on the token's `TreasuryCap`, `blast_presale::new` with the
    /// cap and the venue ticket, the setters, `finalize`, and `share`.
    fn create_presale_pt(
        &self,
        treasury_cap: ObjectID,
        currency: ObjectID,
        meme: &TypeTag,
        terms: &Terms,
        partner: Option<ObjectID>,
    ) -> Result<ProgrammableTransaction> {
        let mut b = ProgrammableTransactionBuilder::new();
        let pair = vec![meme.clone(), self.quote()];
        let vesting_terms = tag(&format!("{}::payout::VestingTerms", self.core));
        let mut recipients = Vec::new();
        for (recipient, bps) in &terms.recipients {
            // Each recipient is paid outright: a `blast_core::payout::Recipient` with no vesting.
            let destination = b.pure(SuiAddress::from(*recipient))?;
            let no_vesting = call(&mut b, ObjectID::from_single_byte(1), "option", "none", vec![vesting_terms.clone()], vec![]);
            let payee = call(&mut b, self.core, "payout", "recipient", vec![], vec![destination, no_vesting]);
            let args = vec![payee, self.bps(&mut b, *bps)?];
            recipients.push(call(&mut b, self.presale, "blast_presale", "recipient_share", vec![], args));
        }
        let allocation_type = self.presale_tag("blast_presale", "RecipientShare");
        let recipients = b.command(Command::make_move_vec(Some(allocation_type.clone()), recipients));
        // No share of the raise goes to recipients, and there is no uncapped phase.
        let raise_allocations = b.command(Command::make_move_vec(Some(allocation_type), vec![]));
        let eligibility_args =
            vec![b.pure(terms.wallet_cap)?, b.pure(terms.max_participants)?, b.pure(terms.min_commitment)?];
        let eligibility = call(&mut b, self.presale, "blast_presale", "open_eligibility", vec![], eligibility_args);

        let version = self.shared(&mut b, self.version, false)?;
        let venue_version = self.shared(&mut b, self.venue_version, false)?;
        let cap = b.obj(self.h.owned(treasury_cap))?;
        let venue_config = self.shared(&mut b, self.venue_config, true)?;
        let currency = self.shared(&mut b, currency, true)?;
        let registry = self.shared(&mut b, self.presale_registry, true)?;
        let (tick_spacing, fee_rate) = self.route.tier();
        let venue_ticket = if self.route.is_cetus() {
            let args = vec![
                venue_version,
                venue_config,
                self.shared(&mut b, self.venue("cetus_global_config"), false)?,
                self.shared(&mut b, self.venue("cetus_pools"), true)?,
                cap,
                b.pure(tick_spacing)?,
            ];
            call(&mut b, self.venues, "cetus", "prepare", pair.clone(), args)
        } else {
            let args = vec![venue_version, venue_config, cap, currency, b.pure(tick_spacing)?, b.pure(fee_rate)?];
            call(&mut b, self.venues, "bluefin", "prepare", pair.clone(), args)
        };
        let creation_policy = self.shared(&mut b, self.creation_policy, false)?;
        let fee_policy = self.shared(&mut b, self.fee_policy, false)?;
        let init = call(&mut b, self.presale, "blast_presale", "new", pair.clone(),
            vec![cap, version, venue_ticket, creation_policy, fee_policy]);
        let supply = b.pure(terms.supply)?;
        let burnable = b.pure(false)?;
        let sale_bps = self.bps(&mut b, terms.sale_bps)?;
        let lp_bps = self.bps(&mut b, terms.lp_bps)?;
        let raise = b.pure(terms.raise)?;
        let duration = b.pure(DURATION_MS)?;
        let window = b.pure(LIQUIDITY_WINDOW_MS)?;
        let split = initial_split().arg(&mut b, self.core)?;
        for (function, arguments) in [
            ("set_supply", vec![init, version, supply, burnable]),
            ("set_token_allocations", vec![init, version, sale_bps, lp_bps, recipients]),
            ("set_raise", vec![init, version, raise, raise_allocations]),
            ("set_windows", vec![init, version, duration, window]),
            ("set_eligibility", vec![init, version, eligibility]),
            ("set_fee_split", vec![init, version, split]),
        ] {
            call(&mut b, self.presale, "blast_presale", function, pair.clone(), arguments);
        }
        if let Some(partner) = partner {
            let partner = self.shared(&mut b, partner, false)?;
            let clock = self.clock(&mut b)?;
            call(&mut b, self.presale, "blast_presale", "set_partner", pair.clone(), vec![init, version, creation_policy, partner, clock]);
        }
        let Argument::Result(created) =
            call(&mut b, self.presale, "blast_presale", "finalize", pair.clone(), vec![init, version, registry, currency])
        else {
            unreachable!()
        };
        let clock = self.clock(&mut b)?;
        let start = b.pure(0u64)?;
        call(&mut b, self.presale, "blast_presale", "share", pair, vec![Argument::NestedResult(created, 0), version, start, clock]);
        b.transfer_arg(self.h.sender, Argument::NestedResult(created, 1));

        Ok(b.finish())
    }

    /// Creates and shares the presale, commits past the raise, and settles it after the window.
    fn open_sale(&mut self, terms: &Terms) -> Result<Sale> {
        self.open_partnered_sale(terms, None)
    }

    fn open_partnered_sale(&mut self, terms: &Terms, partner: Option<ObjectID>) -> Result<Sale> {
        let (treasury_cap, currency, meme) = self.publish_token()?;
        let pt = self.create_presale_pt(treasury_cap, currency, &meme, terms, partner)?;
        let created = self.h.execute(pt)?;
        self.fund_sale(created, meme, currency, terms)
    }

    fn fund_sale(&mut self, created: Outcome, meme: TypeTag, currency: ObjectID, terms: &Terms) -> Result<Sale> {
        created.assert_success();
        let presales = created.created(&self.h, "blast_presale", "Presale");
        let caps = self.h.owned_of_type(self.h.sender, "blast_presale", "PresaleCap");
        ensure!(presales.len() == 1 && self.h.object(presales[0]).is_shared() && caps.len() == 1);
        ensure!(
            presales[0] == blast_launchpad_ptb_tests::presale_id(self.presale, self.presale_registry, &meme)?,
            "the presale ID derives from the PresaleRegistry and the sale token"
        );
        let sale = Sale { meme, presale: presales[0], cap: caps[0], currency };

        let state = self.sale_state(&sale)?;
        ensure!(state.lifecycle == Lifecycle::Open && state.presale_cap_id == sale.cap);
        ensure!(
            (state.protocol_quote, state.protocol_tokens) == (terms.protocol_quote(), terms.protocol_tokens()),
            "the sale reserves Blast its snapshotted shares"
        );
        ensure!(state.venue.ends_with(&format!("::{}::Venue", self.route.module())), "the sale records its venue");
        ensure!(state.fee_split == initial_split(), "the sale records its vault's fee split");
        let tiers: Vec<(u32, u64)> = match self.route.is_cetus() {
            // Cetus fixes the fee rate of a registered tick spacing; the reservation names the spacing.
            true => self
                .package_events::<CetusPoolReserved>(&created, self.venues, "events", "CetusPoolReserved")
                .into_iter()
                .map(|reserved| (reserved.tick_spacing, CETUS_FEE_RATE))
                .collect(),
            false => self
                .package_events::<BluefinPoolTierRecorded>(&created, self.venues, "events", "BluefinPoolTierRecorded")
                .into_iter()
                .map(|tier| (tier.tick_spacing, tier.fee_rate))
                .collect(),
        };
        ensure!(tiers == vec![self.route.tier()], "the sale records its exact venue tier");
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
            "{}::prepare at {:?} then blast_presale::new: sale {} LP {} recipients {:?}, raise {}{}",
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
        let version = self.shared(&mut b, self.version, false)?;
        let change = call(&mut b, self.presale, "blast_presale", "commit_open", self.pair(&sale), vec![presale, version, coin, clock]);
        b.transfer_arg(self.h.sender, change);
        self.h.execute(b.finish())?.assert_success();

        self.h.sim.advance_clock(Duration::from_millis(DURATION_MS));
        let mut b = ProgrammableTransactionBuilder::new();
        let presale = self.shared(&mut b, sale.presale, true)?;
        let clock = self.clock(&mut b)?;
        let version = self.shared(&mut b, self.version, false)?;
        call(&mut b, self.presale, "blast_presale", "settle", self.pair(&sale), vec![presale, version, clock]);
        let settled = self.h.execute(b.finish())?;
        settled.assert_success();
        let funded: Vec<PresaleFunded> = self.events(&settled, "events", "PresaleFunded");
        ensure!(funded.len() == 1 && funded[0].presale_id == sale.presale);
        ensure!(
            (funded[0].total_commitments, funded[0].accepted_quote, funded[0].refundable_quote, funded[0].token_allocation)
                == (terms.commitment, terms.raise, terms.commitment - terms.raise, terms.sale_tokens())
        );
        ensure!(self.sale_state(&sale)?.lifecycle == Lifecycle::Funded);
        self.report(format!("commit_open {} then settle: Funded", terms.commitment));

        Ok(sale)
    }

    /// The route's two-call migration: `blast_presale::migrate` returns the sale's `Migration`, and
    /// the venue's `migrate` in `blast_migrators` redeems it; on Cetus with `order` as
    /// `(CoinA, CoinB)` (the pool's order when none), on Bluefin paying `creation_fee` SUI (the
    /// live fee when none).
    fn migrate_command(
        &self,
        b: &mut ProgrammableTransactionBuilder,
        sale: &Sale,
        order: Option<(TypeTag, TypeTag)>,
        creation_fee: Option<u64>,
    ) -> Result<()> {
        let presale = self.shared(b, sale.presale, true)?;
        let version = self.shared(b, self.version, false)?;
        let treasury = self.shared(b, self.treasury, false)?;
        let clock = self.clock(b)?;
        let migration = call(b, self.presale, "blast_presale", "migrate", self.pair(sale), vec![presale, version, treasury, clock]);
        let migrators_version = self.shared(b, self.venue_version, false)?;
        let venue_config = self.shared(b, self.venue_config, false)?;
        let registry = self.shared(b, self.vault_stack.registry, true)?;
        let vault_version = self.shared(b, self.vault_stack.version, false)?;
        if self.route.is_cetus() {
            let (coin_a, coin_b) = order.unwrap_or_else(|| {
                let pool_pair = self.pool_pair(&sale.meme);
                (pool_pair[0].clone(), pool_pair[1].clone())
            });
            let args = vec![
                migration,
                migrators_version,
                venue_config,
                self.shared(b, self.venue("cetus_global_config"), false)?,
                self.shared(b, self.venue("cetus_pools"), true)?,
                self.shared(b, self.venue("cetus_burn_manager"), true)?,
                registry,
                vault_version,
                treasury,
                clock,
            ];
            call(b, self.venues, "cetus", "migrate", vec![sale.meme.clone(), self.quote(), coin_a, coin_b], args);
        } else {
            let fee = b.pure(creation_fee.map_or_else(|| self.bluefin_creation_fee(), Ok)?)?;
            let Argument::Result(fee) = b.command(Command::SplitCoins(Argument::GasCoin, vec![fee])) else {
                unreachable!()
            };
            let args = vec![
                migration,
                migrators_version,
                venue_config,
                self.shared(b, sale.currency, false)?,
                self.shared(b, self.quote_currency, false)?,
                self.shared(b, self.venue("bluefin_global_config"), true)?,
                registry,
                vault_version,
                treasury,
                Argument::NestedResult(fee, 0),
                clock,
            ];
            call(b, self.venues, "bluefin", "migrate", self.pair(sale), args);
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
        self.report("PTB [migrate (pool created, vault shared), migrate again]: EInvalidLifecycle, nothing committed".into());

        if self.route.is_cetus() {
            let pool_pair = self.pool_pair(&sale.meme);
            let reversed = (pool_pair[1].clone(), pool_pair[0].clone());
            let mut b = ProgrammableTransactionBuilder::new();
            self.migrate_command(&mut b, sale, Some(reversed), None)?;
            let expected = Expected::Abort { package: self.venues, module: "cetus", code: MIGRATORS_INVALID_COIN_ORDER };
            self.h.assert_rolled_back(b.finish(), expected, &watched, &owners)?;

            // (USDC, SUI) is in Cetus order and shares one coin with either route's pair.
            ensure!(meme_is_cetus_a(&tag(USDC), &sui()));
            let mut b = ProgrammableTransactionBuilder::new();
            self.migrate_command(&mut b, sale, Some((tag(USDC), sui())), None)?;
            let expected = Expected::Abort { package: self.venues, module: "cetus", code: MIGRATORS_WRONG_COIN_PAIR };
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
        let ledger = &state.fee_ledger;
        ensure!((ledger.meme, ledger.quote, ledger.sui) == (0, 0, 0), "a zero-rate sale holds and pays Blast nothing");
        let migrated: Vec<PresaleMigrated> = self.events(&outcome, "events", "PresaleMigrated");
        ensure!(migrated.len() == 1 && migrated[0].presale_id == sale.presale);
        let recipient_total: u64 = terms.recipient_tokens().iter().sum();
        ensure!(
            (migrated[0].liquidity_quote, migrated[0].liquidity_tokens, migrated[0].recipient_tokens) == (raise, lp, recipient_total),
            "the hand-off is the raise and the LP allocation"
        );
        ensure!(migrated[0].venue.ends_with(&format!("::{}::Venue", self.route.module())));
        let allocated: Vec<RecipientAllocated> = self.events(&outcome, "events", "RecipientAllocated");
        ensure!(allocated.len() == terms.recipients.len());
        for (((recipient, _), amount), event) in terms.recipients.iter().zip(terms.recipient_tokens()).zip(&allocated) {
            let recipient = SuiAddress::from(*recipient);
            ensure!((event.recipient, event.tokens, event.vesting_id) == (recipient, amount, None));
            ensure!(outcome.coins_created_for(&self.h, recipient) == self.coins(&sale.meme, amount, 0));
        }

        // The vault holds the position as a dynamic object field and keeps the residuals for the
        // sale's owner.
        let created: Vec<VaultCreated> = self.vault_events(&outcome, "VaultCreated");
        ensure!(created.len() == 1 && created[0].terms.origin == sale.presale);
        let created = &created[0];
        let venue_marker = outcome
            .events
            .iter()
            .find(|event| event.type_.name.as_str() == "VaultCreated")
            .and_then(|event| event.type_.type_params.get(2).cloned())
            .context("vault venue marker")?;
        ensure!(venue_marker == tag(&format!("{}::{}::Venue", self.venues, self.route.module())), "venue marker {venue_marker}");
        let terms_sealed = &created.terms;
        ensure!(terms_sealed.package_witness.ends_with("::blast_presale_package::PackageWitness"), "{}", terms_sealed.package_witness);
        ensure!(
            created.vault_id == self.vault_id(sale)?,
            "the vault ID derives from the VaultRegistry, the presale's witness, and the sale"
        );
        ensure!(
            terms_sealed.fee_split == initial_split()
                && (terms_sealed.protocol_meme_bps, terms_sealed.protocol_quote_bps) == (0, 0)
                && terms_sealed.partner_id.is_none()
                && terms_sealed.residuals == ResidualPolicy::Owner
        );
        let residual = (created.residual_meme_amount, created.residual_quote_amount);
        let m = Migration {
            pool: created.pool_id,
            vault: created.vault_id,
            position: created.position_id,
            liquidity: created.liquidity,
            supplied: (lp - residual.0, raise - residual.1),
            residual,
        };
        ensure!(self.h.object(m.vault).is_shared() && self.h.object(m.pool).is_shared());
        let pool_types: Vec<TypeTag> = self
            .h
            .object(m.pool)
            .data
            .try_as_move()
            .context("pool object")?
            .type_()
            .type_params()
            .into_iter()
            .map(|ty| ty.into_owned())
            .collect();
        ensure!(pool_types == self.pool_pair(&sale.meme), "the pool stores the exact coin A/B order");
        let vault = self.vault(&m)?;
        ensure!(
            vault.terms == *terms_sealed
                && vault.pool_id == m.pool
                && (vault.owner_meme, vault.owner_quote) == residual
                && (vault.rewards_quote, vault.next_round) == (0, 0)
                && (vault.protocol.meme, vault.protocol.quote, vault.protocol.sui) == (0, 0, 0)
        );
        let Owner::ObjectOwner(field) = self.h.object(m.position).owner().clone() else {
            bail!("position is not a child")
        };
        ensure!(*self.h.object(field.into()).owner() == Owner::ObjectOwner(m.vault.into()));
        let field_type = self.h.object(field.into()).data.try_as_move().context("field")?.type_().to_string();
        ensure!(
            field_type.contains("::vault::PositionKey<")
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
        let version = self.shared(&mut b, self.version, false)?;
        let clock = self.clock(&mut b)?;
        call(&mut b, self.presale, "blast_presale", "claim", self.pair(sale), vec![presale, version, participant, clock]);
        let outcome = self.h.execute(b.finish())?;
        outcome.assert_success();
        let claimed: Vec<Claimed> = self.events(&outcome, "events", "Claimed");
        let refund = terms.commitment - terms.raise;
        ensure!(
            claimed.len() == 1
                && (claimed[0].wallet_commitment, claimed[0].tokens, claimed[0].quote_refund, claimed[0].remaining_participants)
                    == (terms.commitment, terms.sale_tokens(), refund, 0)
        );
        ensure!(claimed[0].vesting_id.is_none());
        ensure!(outcome.coins_created_for(&self.h, self.h.sender) == self.coins(&sale.meme, terms.sale_tokens(), refund));
        let state = self.sale_state(sale)?;
        ensure!((state.quote, state.sale_tokens, state.participants) == (0, 0, 0), "the sale is drained");
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
        self.collect_route_pt(sale, m, pool, false)
    }

    fn collect_route_pt(&self, sale: &Sale, m: &Migration, pool: ObjectID, apply: bool) -> Result<ProgrammableTransaction> {
        let mut b = ProgrammableTransactionBuilder::new();
        let mut args = vec![
            self.shared(&mut b, m.vault, true)?,
            self.shared(&mut b, self.venue_version, false)?,
            self.shared(&mut b, self.vault_stack.version, false)?,
            self.shared(&mut b, self.treasury, false)?,
            self.shared(&mut b, sale.currency, true)?,
        ];
        let function = if apply { "settle_and_apply_fee_split" } else { "collect_fees" };
        if self.route.is_cetus() {
            args.extend([
                self.shared(&mut b, self.venue("cetus_global_config"), false)?,
                self.shared(&mut b, self.venue("cetus_burn_manager"), false)?,
                self.shared(&mut b, pool, true)?,
            ]);
            let mut types = self.pair(sale);
            types.extend(self.pool_pair(&sale.meme));
            // Cetus's `collect_fees` neither compounds nor applies a split, so it takes no Clock.
            if apply {
                args.push(self.clock(&mut b)?);
            }
            call(&mut b, self.venues, "cetus", function, types, args);
        } else {
            args.extend([
                self.shared(&mut b, self.venue("bluefin_global_config"), false)?,
                self.shared(&mut b, pool, true)?,
                self.clock(&mut b)?,
            ]);
            call(&mut b, self.venues, "bluefin", function, self.pair(sale), args);
        }

        Ok(b.finish())
    }

    /// A permissionless collection: the gross is exactly what the venue paid the vault's
    /// position, each address route is paid its apportioned share, and the holder-reward route
    /// grows the vault's reward balances.
    fn collect(&mut self, sale: &Sale, m: &Migration) -> Result<FeesCollected> {
        self.collect_impl(sale, m, false)
    }

    fn collect_impl(&mut self, sale: &Sale, m: &Migration, apply: bool) -> Result<FeesCollected> {
        let before = self.vault(m)?;
        let pt = self.collect_route_pt(sale, m, m.pool, apply)?;
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
        let fees: Vec<FeesCollected> = self.vault_events(&outcome, "FeesCollected");
        ensure!(fees.len() == 1, "one FeesCollected");
        let fees = fees[0].clone();
        ensure!(fees.vault_id == m.vault && (fees.gross_meme, fees.gross_quote) == (gross_meme, gross_quote));
        // The zero-rate policy sealed no Blast share into the vault's terms.
        ensure!((fees.protocol_meme, fees.protocol_quote) == (0, 0), "a zero-rate policy pays Blast nothing");

        // Collection runs under the split applied before it, even when it applies a new one.
        ensure!(before.fee_split.value == self.split, "the oracle tracks the applied split");
        let weights: Vec<u64> = self.split.routes.iter().map(|route| route.bps).collect();
        let meme = apportion(&weights, gross_meme);
        let quote = apportion(&weights, gross_quote);
        ensure!(fees.route_meme == meme && fees.route_quote == quote, "FeesCollected {fees:?} is the exact apportionment");
        let mut rewards = (0, 0);
        for (i, route) in self.split.routes.iter().enumerate() {
            match route.destination {
                Destination::Address(recipient) => ensure!(
                    outcome.coins_created_for(&self.h, recipient) == self.coins(&sale.meme, meme[i], quote[i]),
                    "{recipient} paid"
                ),
                Destination::HolderRewards => rewards = (meme[i], quote[i]),
                _ => bail!("the fixture split routes only to addresses and holder rewards"),
            }
        }
        ensure!(outcome.coins_created_for(&self.h, self.h.sender).is_empty(), "nothing is paid to the sender");
        let after = self.vault(m)?;
        ensure!(
            (after.rewards_meme, after.rewards_quote) == (before.rewards_meme + rewards.0, before.rewards_quote + rewards.1),
            "the holder-reward route accrues in the vault"
        );
        if apply {
            let changes: Vec<DelayedApplied<FeeSplit>> = outcome.delayed("DelayedApplied", "vault", "FeeSplitKey")?;
            ensure!(changes.len() == 1 && changes[0].owner == m.vault);
            ensure!(changes[0].previous_value == before.fee_split.value && changes[0].value == after.fee_split.value);
            ensure!(changes[0].delay_ms == after.fee_split.delay_ms && after.fee_split.pending.is_none());
            self.split = after.fee_split.value.clone();
        } else {
            ensure!(after.fee_split == before.fee_split);
        }
        ensure!(after.rewards_quote > before.rewards_quote);
        ensure!((after.owner_meme, after.owner_quote) == (before.owner_meme, before.owner_quote), "the residuals wait");
        ensure!(self.position_liquidity(m.position)? == m.liquidity, "collection keeps the liquidity");

        Ok(fees)
    }

    /// The owner proposes `split` with an owner proof; the vault's delay is fixed.
    fn schedule_split_pt(&self, sale: &Sale, m: &Migration, split: &FeeSplit) -> Result<ProgrammableTransaction> {
        let mut b = ProgrammableTransactionBuilder::new();
        let proof = self.prove_owner(&mut b, sale)?;
        let args = vec![self.shared(&mut b, m.vault, true)?, proof, self.shared(&mut b, self.vault_stack.version, false)?,
            split.arg(&mut b, self.core)?, self.clock(&mut b)?];
        call(&mut b, self.vault_stack.package, "vault", "schedule_fee_split", self.pair(sale), args);
        Ok(b.finish())
    }

    fn delayed_fee_split(&mut self, sale: &Sale, m: &Migration, terms: &Terms) -> Result<()> {
        let old = self.vault(m)?.fee_split;
        let pt = self.schedule_split_pt(sale, m, &next_split())?;
        let scheduled = self.h.execute(pt)?;
        scheduled.assert_success();
        let pending = self.vault(m)?.fee_split;
        ensure!(pending.value == old.value, "scheduling retains the old routes");
        ensure!(pending.pending.as_ref().is_some_and(|p| p.value == next_split() && p.delay_ms == VAULT_FEE_DELAY_MS));
        let owners = [self.h.sender, CREATOR.into(), FEE_B.into()];
        let watched = [m.vault, m.pool, sale.currency];
        self.set_venue_version_for_fixture(2)?;
        let stale = self.collect_route_pt(sale, m, m.pool, true)?;
        self.h.assert_rolled_back(stale, Expected::Abort {package: self.admin, module: "package_version", code: 9}, &watched, &owners)?;
        self.set_venue_version_for_fixture(1)?;
        let early = self.collect_route_pt(sale, m, m.pool, true)?;
        self.h.assert_rolled_back(early, Expected::Abort {package: self.admin, module: "delayed", code: 13}, &watched, &owners)?;
        self.h.sim.advance_clock(std::time::Duration::from_millis(old.delay_ms));
        self.swap(sale, m, Side::QuoteIn, self.route.quote_unit())?;
        self.swap(sale, m, Side::MemeIn, terms.lp_tokens() / 100)?;
        let mut rollback = self.collect_route_pt(sale, m, m.pool, true)?;
        rollback.commands.push(rollback.commands.last().expect("apply").clone());
        self.h.assert_rolled_back(rollback, Expected::Abort {package: self.admin, module: "delayed", code: 14}, &watched, &owners)?;
        self.collect_impl(sale, m, true)?; // Settles under the OLD split, then applies the new one.
        let active = self.vault(m)?.fee_split;
        ensure!(active.value == next_split() && active.delay_ms == VAULT_FEE_DELAY_MS && active.pending.is_none());
        self.swap(sale, m, Side::QuoteIn, self.route.quote_unit())?;
        self.collect(sale, m)?; // The same oracle now reads the applied split.
        self.report("48-hour owner-proved split: early apply rejected; later PTB abort restores fees/proposal; settled apply pays old routes; next collection uses new split".into());
        Ok(())
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
            call(&mut b, id(BLUEFIN), "pool", "create_pool", vec![sale.meme.clone(), self.quote(), sui()], args);
            b.transfer_args(self.h.sender, vec![meme]);
        }
        let outcome = self.h.execute(b.finish())?;
        outcome.assert_success();
        let other = outcome.created(&self.h, "pool", "Pool");
        ensure!(other.len() == 1 && other[0] != m.pool && self.h.object(other[0]).is_shared());
        let other = other[0];

        let code = MIGRATORS_POSITION_POOL_MISMATCH;
        let expected = Expected::Abort { package: self.venues, module: self.route.module(), code };
        let pt = self.collect_pt(sale, m, other)?;
        let owners = [self.h.sender, CREATOR.into(), FEE_B.into()];
        self.h.assert_rolled_back(pt, expected, &[m.vault, other, sale.currency], &owners)?;
        // Proposing the applied split is refused as unchanged, so propose one basis point moved.
        let mut moved = next_split();
        moved.routes[0].bps -= 1;
        moved.routes[1].bps += 1;
        let schedule = self.schedule_split_pt(sale, m, &moved)?;
        self.h.execute(schedule)?.assert_success();
        self.h.sim.advance_clock(std::time::Duration::from_millis(VAULT_FEE_DELAY_MS));
        let ready_wrong_pool = self.collect_route_pt(sale, m, other, true)?;
        self.h.assert_rolled_back(ready_wrong_pool, Expected::Abort {package: self.venues, module: self.route.module(), code}, &[m.vault, other, sale.currency], &owners)?;
        let mut b = ProgrammableTransactionBuilder::new();
        let proof = self.prove_owner(&mut b, sale)?;
        let args = vec![self.shared(&mut b, m.vault, true)?, proof, self.shared(&mut b, self.vault_stack.version, false)?];
        call(&mut b, self.vault_stack.package, "vault", "cancel_fee_split", self.pair(sale), args);
        self.h.execute(b.finish())?.assert_success();
        self.report(format!("collect_fees against another pool {other} of the same type: EPositionPoolMismatch, rolled back"));

        Ok(())
    }

    /// The owner claims the residuals the venue did not take, which the vault holds as its owner
    /// balances, with an owner proof from the `PresaleCap`.
    fn claim_residuals(&mut self, sale: &Sale, m: &Migration) -> Result<()> {
        let mut b = ProgrammableTransactionBuilder::new();
        let proof = self.prove_owner(&mut b, sale)?;
        let vault = self.shared(&mut b, m.vault, true)?;
        let vault_version = self.shared(&mut b, self.vault_stack.version, false)?;
        let Argument::Result(claimed) = call(
            &mut b,
            self.vault_stack.package,
            "vault",
            "claim_owner_balances",
            self.pair(sale),
            vec![vault, proof, vault_version],
        ) else {
            unreachable!()
        };
        b.transfer_args(self.h.sender, vec![Argument::NestedResult(claimed, 0), Argument::NestedResult(claimed, 1)]);
        if m.residual == (0, 0) {
            let expected = Expected::Abort { package: self.vault_stack.package, module: "vault", code: NOTHING_TO_CLAIM };
            self.h.assert_rolled_back(b.finish(), expected, &[m.vault, sale.cap], &[self.h.sender])?;
            self.report("claim_owner_balances with no residuals: nothing_to_claim, rolled back".into());
            return Ok(());
        }
        let outcome = self.h.execute(b.finish())?;
        outcome.assert_success();
        let claimed: Vec<OwnerBalancesClaimed> = self.vault_events(&outcome, "OwnerBalancesClaimed");
        ensure!(claimed.len() == 1 && claimed[0].vault_id == m.vault && (claimed[0].meme_amount, claimed[0].quote_amount) == m.residual);
        let mut coins = vec![
            (sale.meme.to_canonical_string(true), m.residual.0),
            (self.quote().to_canonical_string(true), m.residual.1),
        ];
        coins.sort();
        ensure!(outcome.coins_created_for(&self.h, self.h.sender) == coins, "both coins, a zero one included");
        let vault = self.vault(m)?;
        ensure!((vault.owner_meme, vault.owner_quote) == (0, 0));
        self.report(format!("claim_owner_balances with a PresaleCap owner proof: residuals {:?}", m.residual));

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
        let mut direct_position = false;
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
                let outcome = self.h.execute(b.finish())?;
                outcome.assert_success();
                let pools = outcome.created(&self.h, "pool", "Pool");
                let positions = outcome.created(&self.h, "position", "Position");
                ensure!(pools.len() == 1 && positions.len() == 1);
                direct_position = true;
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

        ensure!(direct_position, "the direct venue pool and position");
        Ok(())
    }
}

// === Fee splits ===

/// The vault's starting split: the creator's and a second address route, then holder rewards.
fn initial_split() -> FeeSplit {
    FeeSplit::new([
        (Destination::Address(CREATOR.into()), FEE_BPS[0]),
        (Destination::Address(FEE_B.into()), FEE_BPS[1]),
        (Destination::HolderRewards, HOLDER_REWARDS_BPS),
    ])
}

/// The split the owner proposes.
fn next_split() -> FeeSplit {
    FeeSplit::new([
        (Destination::Address(CREATOR.into()), 3_000),
        (Destination::Address(FEE_B.into()), 2_000),
        (Destination::HolderRewards, 5_000),
    ])
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

/// Mirrors `blast_core::payout::VestingTerms`.
#[derive(Debug, Deserialize, PartialEq)]
struct VestingTerms {
    _cliff_delay_ms: u64,
    _period_duration_ms: u64,
    _periods: u64,
}

/// Mirrors `blast_core::payout::Recipient`.
#[derive(Debug, Deserialize, PartialEq)]
struct Recipient {
    _destination: SuiAddress,
    _vesting_terms: Option<VestingTerms>,
}

/// Mirrors `blast_presale::blast_presale::UncappedPhase`.
#[derive(Debug, Deserialize, PartialEq)]
struct UncappedPhase {
    _starts_after_ms: u64,
    _access: UncappedAccess,
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
    start_ms: u64,
    raise_target: u64,
    eligibility: Eligibility,
    _uncapped: Option<UncappedPhase>,
    _hard_cap: Option<(u64, bool)>,
    venue: String,
    fee_split: FeeSplit,
    total_commitments: u64,
    participants: u64,
    quote: u64,
    token_allocation: u64,
    _participant_vesting: Option<VestingTerms>,
    sale_tokens: u64,
    liquidity_tokens: u64,
    _recipient_payouts: Vec<(Recipient, u64)>,
    recipient_tokens: u64,
    _raise_payouts: Vec<(Recipient, u64)>,
    _protocol_fees: ProtocolFees,
    protocol_quote: u64,
    protocol_tokens: u64,
    _partner_id: Option<ObjectID>,
    fee_ledger: Ledger,
}

/// Mirrors `blast_presale::fee_policy::ProtocolFees`.
#[derive(Debug, Deserialize, PartialEq)]
struct ProtocolFees {
    _raise_bps: u64,
    _token_bps: u64,
    _lp_fee_meme_bps: u64,
    _lp_fee_quote_bps: u64,
}

/// Mirrors `blast_core::migration::ResidualPolicy`.
#[derive(Clone, Debug, Deserialize, PartialEq)]
enum ResidualPolicy {
    Protocol,
    Owner,
}

/// Mirrors `blast_core::migration::VaultTerms`; each `Bps` is one `u64`.
#[derive(Clone, Debug, Deserialize, PartialEq)]
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
#[derive(Debug, Deserialize, PartialEq)]
struct Ledger {
    _package_witness: String,
    _origin: ObjectID,
    _partner_id: Option<ObjectID>,
    meme: u64,
    quote: u64,
    sui: u64,
}

/// Mirrors `blast_vault::vault::Vault`; each `Balance` is one `u64`.
#[derive(Debug, Deserialize)]
struct VaultState {
    _id: ObjectID,
    terms: VaultTerms,
    pool_id: ObjectID,
    fee_split: Delayed<FeeSplit>,
    _protocol_bps: Delayed<(u64, u64)>,
    protocol: Ledger,
    owner_meme: u64,
    owner_quote: u64,
    _auto_lp_meme: u64,
    _auto_lp_quote: u64,
    rewards_meme: u64,
    rewards_quote: u64,
    _burn_quote: u64,
    next_round: u64,
    _last_checkpoint: Option<u64>,
    _round_publication: DelayedAction<RoundTerms>,
}

/// Mirrors `blast_migrators::events::CetusPoolReserved<Meme, Quote>`; the pair is its type.
#[derive(Deserialize)]
struct CetusPoolReserved {
    _pool_creation_cap_id: ObjectID,
    tick_spacing: u32,
}

/// Mirrors `blast_migrators::events::BluefinPoolTierRecorded<Meme, Quote>`.
#[derive(Deserialize)]
struct BluefinPoolTierRecorded {
    tick_spacing: u32,
    fee_rate: u64,
}

#[derive(Deserialize)]
struct PresaleFunded {
    presale_id: ObjectID,
    total_commitments: u64,
    accepted_quote: u64,
    refundable_quote: u64,
    token_allocation: u64,
    _end_ms: u64,
    _liquidity_deadline_ms: u64,
}

#[derive(Deserialize)]
struct PresaleMigrated {
    presale_id: ObjectID,
    venue: String,
    liquidity_quote: u64,
    liquidity_tokens: u64,
    recipient_tokens: u64,
}

#[derive(Deserialize)]
struct RecipientAllocated {
    _presale_id: ObjectID,
    recipient: SuiAddress,
    tokens: u64,
    vesting_id: Option<ObjectID>,
}

#[derive(Deserialize)]
struct Claimed {
    _presale_id: ObjectID,
    _participant: SuiAddress,
    wallet_commitment: u64,
    tokens: u64,
    quote_refund: u64,
    remaining_participants: u64,
    vesting_id: Option<ObjectID>,
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

/// Mirrors `blast_vault::blast_vault_events::FeesCollected<Meme, Quote>`: route amounts follow
/// the vault's split.
#[derive(Clone, Debug, Deserialize)]
struct FeesCollected {
    vault_id: ObjectID,
    gross_meme: u64,
    gross_quote: u64,
    protocol_meme: u64,
    protocol_quote: u64,
    route_meme: Vec<u64>,
    route_quote: Vec<u64>,
}

impl FeesCollected {
    fn line(&self) -> String {
        format!(
            "gross=({}, {}) protocol=({}, {}) routes=({:?}, {:?})",
            self.gross_meme, self.gross_quote, self.protocol_meme, self.protocol_quote, self.route_meme, self.route_quote,
        )
    }
}

/// Mirrors `blast_core::blast_core_events::ProtocolFeesPaid<Meme, Quote>`.
#[derive(Debug, Deserialize, PartialEq)]
struct ProtocolFeesPaid {
    package_witness: String,
    origin: ObjectID,
    treasury: SuiAddress,
    meme_amount: u64,
    quote_amount: u64,
    sui_amount: u64,
    partner_id: Option<ObjectID>,
    partner_meme_amount: u64,
    partner_quote_amount: u64,
    partner_sui_amount: u64,
}

#[derive(Deserialize)]
struct OwnerBalancesClaimed {
    vault_id: ObjectID,
    meme_amount: u64,
    quote_amount: u64,
}
