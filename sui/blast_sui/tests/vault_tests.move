#[test_only]
module blast_sui::vault_tests;

use blast_sui::{
    acl,
    blast_sui::{Self as blast_coin, BLAST_SUI},
    constants,
    deposit_receipt::{Self, BlastSuiDepositReceipt},
    errors,
    events,
    fun_sui::{Self, FUN_SUI},
    math,
    package_version::{Self, PackageVersion},
    vault::{Self, Vault},
};
use std::unit_test::{assert_eq, destroy};
use sui::{coin::{Self, Coin}, test_scenario};
use sui_system::{
    sui_system::SuiSystemState,
    test_runner::{Self, TestRunner},
    validator_builder,
};

use fun create_advance_epoch_safe_mode as CreateFixture.advance_epoch_safe_mode;
use fun create_advance_epoch as CreateFixture.advance_epoch;
use fun create_ctx as CreateFixture.ctx;
use fun create_end as CreateFixture.end;
use fun create_next_tx as CreateFixture.next_tx;
use fun create_remove_validator as CreateFixture.remove_validator;
use fun create_system as CreateFixture.system;
use fun vault_ctx as VaultFixture.ctx;
use fun vault_end as VaultFixture.end;
use fun vault_next_tx as VaultFixture.next_tx;
use fun vault_system as VaultFixture.system;
use fun vault_vault as VaultFixture.vault;

// === Constants ===

const OWNER: address = @0xAD;
const USER: address = @0xA11CE;
/// Holder of the seed shares `vault::create` locks forever.
const ZERO_ADDRESS: address = @0x0;
const MIST_PER_SUI: u64 = 1_000_000_000;
/// OWNER's blast bootstrap: locked blastSUI supply and its permanent backing.
const BOOTSTRAP: u64 = 10 * MIST_PER_SUI;
/// USER's ordinary blast deposit: the only redeemable shares in a funded vault.
const DEPOSIT: u64 = 8 * MIST_PER_SUI;

/// Native system with two genesis validators and no vault yet; exercises `vault::create`.
public struct CreateFixture {
    runner: TestRunner,
    version: PackageVersion,
    system_state: Option<SuiSystemState>,
}

/// Live vault bound to the second genesis validator with OWNER's bootstrap shares locked at `@0x0`.
///
/// `start_vault` holds only that locked supply; `start_vault_with_deposit`
/// adds USER's redeemable `DEPOSIT` shares. `next_tx!` borrows the shared
/// vault and system state for exactly one transaction.
public struct VaultFixture {
    runner: TestRunner,
    version: PackageVersion,
    authority: acl::ProtocolAuthority,
    super_admin_cap: acl::SuperAdminCap,
    vault: Option<Vault>,
    system_state: Option<SuiSystemState>,
}

// === Creation Tests ===

#[test]
fun create_seeds_the_fun_reserve_and_stakes_the_bootstrap_in_blast_custody_only() {
    let mut fixture = start_create();
    let validator = fixture.validator();
    let reserve = constants::fun_rounding_reserve_mist!();
    let created;

    fixture.next_tx!(OWNER, |f| {
        let pool_id = f.system!().validator_staking_pool_id(validator);
        created = f.create_vault(validator, pool_id, BOOTSTRAP, 0);
    });

    let mut fixture = fixture.into_vault_fixture();

    fixture.next_tx!(OWNER, |f| {
        let (
            vault_id,
            emitted_validator,
            emitted_pool_id,
            fun_reserve_sui,
            bootstrap_sui,
            locked_blast_sui,
            fee,
            custody,
        ) = created.vault_created_fields();
        assert_eq!(vault_id, object::id(f.vault!()));
        assert_eq!(emitted_validator, validator);
        assert_eq!(emitted_pool_id, f.vault!().pool_id_for_testing());
        assert_eq!(emitted_pool_id, f.system!().validator_staking_pool_id(validator));
        assert_eq!(fun_reserve_sui, reserve);
        assert_eq!(bootstrap_sui, BOOTSTRAP);
        assert_eq!(locked_blast_sui, BOOTSTRAP);
        assert_eq!(fee, constants::default_redeem_fee_bps!());
        assert_eq!(fee, f.vault!().redeem_fee_bps_for_testing());
        assert_custody_matches(&custody, f.vault!());

        let (fun_custody, blast_custody, rate, fun_supply, blast_supply) =
            custody.vault_custody_fields();
        assert_pool(&fun_custody, reserve, 0, 0, 0);
        assert_pool(&blast_custody, 0, BOOTSTRAP, 0, 0);
        assert_eq!(fun_supply, 0);
        assert_eq!(blast_supply, BOOTSTRAP);
        assert!(!f.vault!().is_unwind_only_for_testing());

        // The cache holds the current epoch's native entry, field for field.
        let (rate_epoch, rate_sui, rate_pool_tokens) = rate.exchange_rate_fields();
        let pool_rate = f.system!().pool_exchange_rates(&emitted_pool_id)[1];
        assert_eq!(rate_epoch, 1);
        assert_eq!(rate_sui, pool_rate.sui_amount());
        assert_eq!(rate_pool_tokens, pool_rate.pool_token_amount());
    });

    fixture.end();
}

/// `create` returns nothing: the whole seed coin lands at `@0x0`, never with the owner.
#[test]
fun create_returns_no_seed_coin_and_locks_every_bootstrap_share_at_the_zero_address() {
    let mut fixture = start_create();
    let validator = fixture.validator();

    fixture.next_tx!(OWNER, |f| {
        let pool_id = f.system!().validator_staking_pool_id(validator);
        f.create_vault(validator, pool_id, BOOTSTRAP, 0);
    });

    let mut fixture = fixture.into_vault_fixture();

    fixture.next_tx!(OWNER, |f| {
        assert!(!f.has_blast_coin(OWNER));
        assert!(!f.has_blast_coin(USER));
        assert_eq!(f.locked_blast_sui(), BOOTSTRAP);
        assert_eq!(f.vault!().blast_supply_for_testing(), BOOTSTRAP);
    });

    fixture.end();
}

/// The seed must fund the fun reserve and still leave a one-SUI blast bootstrap.
#[test]
#[expected_failure(abort_code = errors::EBootstrapBelowNativeMinimum, location = blast_sui::vault)]
fun create_rejects_a_seed_below_the_native_minimum_plus_the_fun_reserve() {
    let mut fixture = start_create();
    let validator = fixture.validator();

    fixture.next_tx!(OWNER, |f| {
        let pool_id = f.system!().validator_staking_pool_id(validator);
        f.create_vault(validator, pool_id, MIST_PER_SUI - 1, 0);
    });

    fixture.end();
}

/// A safe-mode epoch writes no pool entry, so the cache cannot be initialized.
#[test]
#[expected_failure(abort_code = errors::EStaleExchangeRate, location = blast_sui::vault)]
fun create_rejects_a_pool_without_a_current_epoch_exchange_rate() {
    let mut fixture = start_create();
    let validator = fixture.validator();
    fixture.advance_epoch_safe_mode();

    fixture.next_tx!(OWNER, |f| {
        let pool_id = f.system!().validator_staking_pool_id(validator);
        assert!(!f.system!().pool_exchange_rates(&pool_id).contains(f.ctx!().epoch()));
        f.create_vault(validator, pool_id, BOOTSTRAP, 0);
    });

    fixture.end();
}

#[test]
#[expected_failure(abort_code = errors::EValidatorNotActive, location = blast_sui::vault)]
fun create_rejects_an_inactive_validator() {
    let mut fixture = start_create();
    let validator = fixture.validator();
    let pool_id;

    fixture.next_tx!(OWNER, |f| {
        pool_id = f.system!().validator_staking_pool_id(validator);
    });
    fixture.remove_validator(validator);
    fixture.advance_epoch();
    fixture.next_tx!(OWNER, |f| {
        f.create_vault(validator, pool_id, BOOTSTRAP, 0);
    });

    fixture.end();
}

#[test]
#[expected_failure(abort_code = errors::EStaleExchangeRate, location = blast_sui::vault)]
fun create_rejects_a_validator_in_its_first_active_epoch() {
    let mut fixture = start_create();
    let validator = @0xBEEF;
    let candidate = validator_builder::preset(2)
        .sui_address(validator)
        .build(fixture.runner.ctx());
    fixture.runner.add_validator_candidate(candidate);
    fixture.runner.set_sender(USER).stake_with(validator, 100);
    fixture.runner.set_sender(validator).add_validator();
    fixture.advance_epoch();

    fixture.next_tx!(OWNER, |f| {
        let pool_id = f.system!().validator_staking_pool_id(validator);
        f.create_vault(validator, pool_id, BOOTSTRAP, 0);
    });

    fixture.end();
}

#[test]
#[expected_failure(abort_code = errors::ENonzeroInitialSupply, location = blast_sui::vault)]
fun create_rejects_a_treasury_cap_with_existing_supply() {
    let mut fixture = start_create();
    let validator = fixture.validator();

    fixture.next_tx!(OWNER, |f| {
        let pool_id = f.system!().validator_staking_pool_id(validator);
        f.create_vault(validator, pool_id, BOOTSTRAP, 1);
    });

    fixture.end();
}

// === blastSUI Deposit Receipt Tests ===

#[test]
fun blast_request_creates_a_receipt_without_changing_vault_custody_or_supply() {
    let mut fixture = start_vault();
    let (vault_id, pool_id, custody_before, supply_before);
    fixture.next_tx!(USER, |f| {
        vault_id = object::id(f.vault!());
        pool_id = f.vault!().pool_id_for_testing();
        custody_before = f.vault!().blast_custody_for_testing();
        supply_before = f.vault!().blast_supply_for_testing();
    });

    let requested = fixture.request_blast(2 * MIST_PER_SUI);
    let (receipt_id, emitted_vault, emitted_pool, principal, activation_epoch, custody) =
        requested.blast_sui_deposit_requested_fields();
    assert_eq!(emitted_vault, vault_id);
    assert_eq!(emitted_pool, pool_id);
    assert_eq!(principal, 2 * MIST_PER_SUI);
    assert_eq!(activation_epoch, 2);
    fixture.next_tx!(USER, |f| {
        assert_custody_matches(&custody, f.vault!());
        assert_eq!(f.vault!().blast_custody_for_testing(), custody_before);
        assert_eq!(f.vault!().blast_supply_for_testing(), supply_before);
        assert!(receipt_id != object::id(f.vault!()));
    });
    assert_eq!(fixture.cancel_blast(), 2 * MIST_PER_SUI);

    fixture.end();
}

#[test]
fun returned_receipt_composes_into_same_transaction_cancellation_without_keep() {
    let mut fixture = start_vault();
    let principal = 2 * MIST_PER_SUI;
    let returned_sui;

    fixture.next_tx!(USER, |f| {
        let receipt = f.vault!().request_blast_sui(
            &f.version,
            f.system!(),
            coin::mint_for_testing(principal, f.ctx!()),
            f.ctx!(),
        );
        let sui_out = deposit_receipt::cancel(receipt, f.system!(), f.ctx!());
        returned_sui = sui_out.value();
        transfer::public_transfer(sui_out, USER);
    });

    let requested = events::collect_one<events::BlastSuiDepositRequested>(0);
    let cancelled = events::collect_one<events::BlastSuiDepositCancelled>(0);
    let (receipt_id, vault_id, _, emitted_principal, _, _) =
        requested.blast_sui_deposit_requested_fields();
    let (cancelled_receipt_id, cancelled_vault_id, cancelled_principal, emitted_sui) =
        cancelled.blast_sui_deposit_cancelled_fields();
    assert_eq!(cancelled_receipt_id, receipt_id);
    assert_eq!(cancelled_vault_id, vault_id);
    assert_eq!(emitted_principal, principal);
    assert_eq!(cancelled_principal, principal);
    assert_eq!(emitted_sui, principal);
    assert_eq!(returned_sui, principal);

    fixture.end();
}

#[test]
#[expected_failure(abort_code = errors::EBlastDepositBelowNativeMinimum, location = blast_sui::vault)]
fun blast_request_rejects_less_than_the_native_staking_minimum() {
    let mut fixture = start_vault();
    fixture.request_blast(MIST_PER_SUI - 1);
    fixture.end();
}

#[test]
#[expected_failure(abort_code = errors::EBlastDepositNotActive, location = blast_sui::vault)]
fun blast_claim_rejects_the_receipt_before_activation() {
    let mut fixture = start_vault();
    fixture.request_blast(2 * MIST_PER_SUI);
    fixture.claim_blast(0);
    fixture.end();
}

#[test]
fun receipt_cancellation_before_activation_returns_exact_principal() {
    let mut fixture = start_vault();
    fixture.request_blast(2 * MIST_PER_SUI);
    assert_eq!(fixture.cancel_blast(), 2 * MIST_PER_SUI);
    fixture.end();
}

#[test]
fun receipt_cancellation_after_activation_returns_principal_and_its_own_rewards() {
    let mut fixture = start_vault();
    let principal = 10 * MIST_PER_SUI;
    fixture.request_blast(principal);
    fixture.advance_epoch();
    fixture.advance_epoch_with_rewards(130);

    let returned = fixture.cancel_blast();
    assert!(returned > principal);
    fixture.end();
}

#[test]
fun delayed_claim_credits_rewards_earned_by_the_receipts_own_stake() {
    let mut fixture = start_vault();
    let principal = 10 * MIST_PER_SUI;
    fixture.request_blast(principal);
    fixture.advance_epoch();
    fixture.advance_epoch_with_rewards(130);
    fixture.sync();

    let (assets_before, supply_before);
    fixture.next_tx!(USER, |f| {
        assets_before = f.vault!().blast_custody_for_testing().pool_assets();
        supply_before = f.vault!().blast_supply_for_testing();
    });
    let (shares, _) = fixture.claim_blast(0);
    let claimed = events::collect_one<events::BlastSuiDepositClaimed>(0);
    let (_, _, emitted_principal, contributed, _, emitted_shares, _) =
        claimed.blast_sui_deposit_claimed_fields();
    assert_eq!(emitted_principal, principal);
    assert!(contributed > principal);
    assert_eq!(shares, emitted_shares);
    assert_eq!(
        shares,
        math::blast_shares_out_down(contributed, assets_before, supply_before),
    );

    fixture.end();
}

#[test]
fun receipt_cancellation_stays_live_after_the_validator_leaves() {
    let mut fixture = start_vault();
    let principal = 2 * MIST_PER_SUI;
    fixture.request_blast(principal);
    fixture.remove_validator();
    fixture.advance_epoch();

    assert_eq!(fixture.cancel_blast(), principal);
    fixture.end();
}

#[test]
fun multiple_same_epoch_receipts_activate_and_claim_independently() {
    let mut fixture = start_vault();
    fixture.request_blast(2 * MIST_PER_SUI);
    fixture.request_blast(3 * MIST_PER_SUI);
    fixture.advance_epoch();

    let (first_shares, _) = fixture.claim_blast(3 * MIST_PER_SUI);
    let (second_shares, _) = fixture.claim_blast(2 * MIST_PER_SUI);
    assert_eq!(first_shares, 3 * MIST_PER_SUI);
    assert_eq!(second_shares, 2 * MIST_PER_SUI);
    fixture.end();
}

#[test]
#[expected_failure(abort_code = errors::EWrongReceiptVault, location = blast_sui::deposit_receipt)]
fun claim_rejects_a_receipt_bound_to_another_vault_before_refresh() {
    let mut fixture = start_vault();
    fixture.issue_test_receipt(object::id_from_address(@0xBAD), 1, 2 * MIST_PER_SUI);
    fixture.advance_epoch();
    fixture.claim_blast(0);
    fixture.end();
}

#[test]
#[expected_failure(abort_code = errors::EWrongReceiptPool, location = blast_sui::deposit_receipt)]
fun claim_rejects_native_stake_from_another_validator_pool_before_refresh() {
    let mut fixture = start_vault();
    let vault_id = fixture.vault_id();
    fixture.issue_test_receipt(vault_id, 0, 2 * MIST_PER_SUI);
    fixture.advance_epoch();
    fixture.claim_blast(0);
    fixture.end();
}

/// A deposit made immediately before a rewarded epoch owns no blast shares
/// until after that reward is applied to the existing blast and fun stake.
#[test]
fun activation_receipt_prevents_epoch_boundary_reward_sniping() {
    let mut fixture = start_vault();
    fixture.mint_fun(20 * MIST_PER_SUI);
    fixture.advance_epoch();
    fixture.sync();

    let deposit = 10 * MIST_PER_SUI;
    let (assets_before, supply_before);
    fixture.next_tx!(USER, |f| {
        assets_before = f.vault!().blast_custody_for_testing().pool_assets();
        supply_before = f.vault!().blast_supply_for_testing();
    });
    let immediate_shares = math::blast_shares_out_down(deposit, assets_before, supply_before);

    fixture.request_blast(deposit);
    fixture.advance_epoch_with_rewards(130);
    fixture.sync();

    let (assets_after_reward, supply_after_reward, conversion_loss_bound);
    fixture.next_tx!(USER, |f| {
        assets_after_reward = f.vault!().blast_custody_for_testing().pool_assets();
        supply_after_reward = f.vault!().blast_supply_for_testing();
        let (_, rate_sui, rate_pool_tokens) =
            f.vault!().exchange_rate_for_testing().exchange_rate_fields();
        conversion_loss_bound = math::fun_conversion_loss_bound_up(rate_sui, rate_pool_tokens);
    });
    assert!(assets_after_reward > assets_before);
    assert_eq!(supply_after_reward, supply_before);

    let (receipt_shares, _) = fixture.claim_blast(0);
    let claimed = events::collect_one<events::BlastSuiDepositClaimed>(0);
    let (_, _, principal, contributed, _, _, _) = claimed.blast_sui_deposit_claimed_fields();
    assert_eq!(principal, deposit);
    assert!(contributed <= deposit);
    assert!(deposit - contributed <= conversion_loss_bound);
    assert!(receipt_shares < immediate_shares);
    assert_eq!(
        receipt_shares,
        math::blast_shares_out_down(contributed, assets_after_reward, supply_after_reward),
    );

    let (redeemed, _) = fixture.redeem_blast(receipt_shares);
    assert!(redeemed < deposit);
    fixture.end();
}

// === funSUI Tests ===

#[test]
fun fun_sui_mints_one_to_one_into_fun_custody_and_never_touches_blast_custody() {
    let mut fixture = start_vault();
    let reserve = constants::fun_rounding_reserve_mist!();
    let custody = fixture.mint_fun(20 * MIST_PER_SUI);

    let (fun_custody, blast_custody, _, fun_supply, blast_supply) = custody.vault_custody_fields();
    assert_pool(&fun_custody, reserve, 20 * MIST_PER_SUI, 0, 0);
    assert_pool(&blast_custody, 0, BOOTSTRAP, 0, 0);
    assert_eq!(fun_supply, 20 * MIST_PER_SUI);
    assert_eq!(blast_supply, BOOTSTRAP);

    fixture.end();
}

/// The reserve never counts toward the native minimum and never leaves liquid custody.
#[test]
fun sub_threshold_fun_deposits_stay_liquid_until_the_native_minimum_above_the_reserve() {
    let mut fixture = start_vault();
    let reserve = constants::fun_rounding_reserve_mist!();
    let custody = fixture.mint_fun(400_000_000);
    let (fun_custody, _, _, _, _) = custody.vault_custody_fields();
    assert_pool(&fun_custody, 400_000_000 + reserve, 0, 0, 0);

    let custody = fixture.mint_fun(600_000_000);
    let (fun_custody, _, _, _, _) = custody.vault_custody_fields();
    assert_pool(&fun_custody, reserve, MIST_PER_SUI, 0, 0);

    fixture.end();
}

#[test]
fun fun_sui_redeems_exactly_from_liquid_custody() {
    let mut fixture = start_vault();
    let reserve = constants::fun_rounding_reserve_mist!();
    fixture.mint_fun(400_000_000);
    let custody = fixture.redeem_fun(150_000_000);

    let (fun_custody, blast_custody, _, fun_supply, _) = custody.vault_custody_fields();
    assert_pool(&fun_custody, 250_000_000 + reserve, 0, 0, 0);
    assert_pool(&blast_custody, 0, BOOTSTRAP, 0, 0);
    assert_eq!(fun_supply, 250_000_000);

    fixture.end();
}

#[test]
fun fun_sui_redeems_exactly_by_splitting_only_the_needed_pending_stake() {
    let mut fixture = start_vault();
    let reserve = constants::fun_rounding_reserve_mist!();
    fixture.mint_fun(20 * MIST_PER_SUI);
    let custody = fixture.redeem_fun(5 * MIST_PER_SUI);

    let (fun_custody, blast_custody, _, fun_supply, _) = custody.vault_custody_fields();
    assert_pool(&fun_custody, 0, 15 * MIST_PER_SUI + reserve, 0, 0);
    assert_pool(&blast_custody, 0, BOOTSTRAP, 0, 0);
    assert_eq!(fun_supply, 15 * MIST_PER_SUI);

    fixture.end();
}

/// When the deficit is below one SUI, native splitting still withdraws the
/// one-SUI minimum and retains a valid one-SUI-or-larger pending receipt.
#[test]
fun pending_withdrawal_below_one_sui_uses_the_native_minimum_split() {
    let mut fixture = start_vault();
    let reserve = constants::fun_rounding_reserve_mist!();
    fixture.mint_fun(20 * MIST_PER_SUI);

    let redeem = reserve + 1;
    let custody = fixture.redeem_fun(redeem);
    let (fun_custody, _, _, fun_supply, _) = custody.vault_custody_fields();
    let (liquid, pending, tokens, _) = fun_custody.pool_custody_fields();
    assert_eq!(liquid, MIST_PER_SUI - 1);
    assert_eq!(pending, 19 * MIST_PER_SUI);
    assert_eq!(tokens, 0);
    assert_eq!(fun_supply, 20 * MIST_PER_SUI - redeem);
    assert_eq!(fun_custody.pool_assets(), fun_supply + reserve);

    fixture.end();
}

/// A split that would leave less than one SUI is invalid natively, so the vault
/// withdraws the whole receipt and keeps the exact remainder liquid.
#[test]
fun pending_withdrawal_extracts_whole_receipt_when_remainder_would_be_too_small() {
    let mut fixture = start_vault();
    let reserve = constants::fun_rounding_reserve_mist!();
    fixture.mint_fun(20 * MIST_PER_SUI);

    let redeem = 19 * MIST_PER_SUI + reserve + 1;
    let custody = fixture.redeem_fun(redeem);
    let (fun_custody, _, _, fun_supply, _) = custody.vault_custody_fields();
    let (liquid, pending, tokens, _) = fun_custody.pool_custody_fields();
    assert_eq!(liquid, MIST_PER_SUI - 1);
    assert_eq!(pending, 0);
    assert_eq!(tokens, 0);
    assert_eq!(fun_supply, MIST_PER_SUI - reserve - 1);
    assert_eq!(fun_custody.pool_assets(), fun_supply + reserve);

    fixture.end();
}

#[test]
fun fun_sui_redeems_exactly_from_active_stake_after_a_reward_sweep() {
    let mut fixture = start_vault();
    let reserve = constants::fun_rounding_reserve_mist!();
    fixture.mint_fun(20 * MIST_PER_SUI);
    fixture.advance_epoch();
    fixture.sync();
    fixture.advance_epoch_with_rewards(130);
    fixture.sync();

    let blast_assets_before;
    fixture.next_tx!(USER, |f| {
        blast_assets_before = f.vault!().blast_custody_for_testing().pool_assets();
    });
    let custody = fixture.redeem_fun(7 * MIST_PER_SUI);

    let (fun_custody, blast_custody, _, fun_supply, _) = custody.vault_custody_fields();
    let (liquid, pending, tokens, _) = fun_custody.pool_custody_fields();
    assert_eq!(fun_supply, 13 * MIST_PER_SUI);
    assert_eq!(pending, 0);
    assert!(tokens > 0);
    // The liquid reserve funded the exit first; the reserve value now sits in the remaining tokens.
    assert!(liquid <= constants::native_redemption_rounding_margin!() + 2);
    assert!(fun_custody.pool_assets() >= fun_supply);
    assert!(fun_custody.pool_assets() <= fun_supply + reserve + 2);
    assert_eq!(blast_custody.pool_assets(), blast_assets_before);

    fixture.end();
}

#[test]
fun full_fun_exit_after_a_reward_sweep_redeems_every_active_token_exactly() {
    let mut fixture = start_vault();
    let reserve = constants::fun_rounding_reserve_mist!();
    fixture.mint_fun(20 * MIST_PER_SUI);
    fixture.advance_epoch();
    fixture.sync();
    fixture.advance_epoch_with_rewards(130);
    fixture.sync();

    let blast_assets_before;
    fixture.next_tx!(USER, |f| {
        let fun_custody = f.vault!().fun_custody_for_testing();
        let (liquid, pending, tokens, active_sui) = fun_custody.pool_custody_fields();
        assert_eq!(liquid, reserve);
        assert_eq!(pending, 0);
        assert!(tokens > 0);
        assert!(active_sui >= 20 * MIST_PER_SUI);
        assert!(active_sui <= 20 * MIST_PER_SUI + 2);
        blast_assets_before = f.vault!().blast_custody_for_testing().pool_assets();
    });
    let custody = fixture.redeem_fun(20 * MIST_PER_SUI);

    // Only the reserve remains in fun custody, partly as the unredeemed token dust.
    let (fun_custody, blast_custody, _, fun_supply, _) = custody.vault_custody_fields();
    let (_, pending, _, _) = fun_custody.pool_custody_fields();
    assert_eq!(fun_supply, 0);
    assert_eq!(pending, 0);
    assert!(fun_custody.pool_assets() >= reserve - constants::native_redemption_rounding_margin!());
    assert!(fun_custody.pool_assets() <= reserve + 2);
    assert_eq!(blast_custody.pool_assets(), blast_assets_before);

    fixture.end();
}

/// Pinned framework vector: at a 2:1 rate, converting 1_000_000_001 MIST issues
/// 500_000_000 pool tokens worth 1_000_000_000 MIST. The seeded reserve covers
/// the lost MIST, so the full exit is exact before fun custody earned anything.
#[test]
fun full_fun_exit_before_the_first_reward_is_exact_from_the_seeded_reserve() {
    let mut fixture = start_vault_with_bootstrap(MIST_PER_SUI);
    let reserve = constants::fun_rounding_reserve_mist!();
    fixture.advance_epoch_with_rewards(200);

    fixture.next_tx!(USER, |f| {
        let pool_id = f.vault!().pool_id_for_testing();
        let rates = f.system!().pool_exchange_rates(&pool_id);
        let rate = rates[2];
        assert_eq!(rate.sui_amount(), 2 * rate.pool_token_amount());
    });

    let deposit = MIST_PER_SUI + 1;
    let custody = fixture.mint_fun(deposit);
    let (fun_custody, _, _, _, _) = custody.vault_custody_fields();
    assert_pool(&fun_custody, reserve, deposit, 0, 0);

    fixture.advance_epoch();
    let custody = fixture.sync();
    let (fun_custody, _, _, _, _) = custody.vault_custody_fields();
    let (liquid, _, tokens, active_sui) = fun_custody.pool_custody_fields();
    assert_eq!(liquid, reserve);
    assert_eq!(tokens, 500_000_000);
    assert_eq!(active_sui, MIST_PER_SUI);
    assert_eq!(fun_custody.pool_assets(), deposit + reserve - 1);

    let custody = fixture.redeem_fun(deposit);
    let (fun_custody, _, _, fun_supply, _) = custody.vault_custody_fields();
    assert_eq!(fun_supply, 0);
    assert_eq!(fun_custody.pool_assets(), reserve - 1);

    fixture.end();
}

/// After a rounding loss, retained yield restores the reserve to its target instead of being swept.
#[test]
fun retained_yield_replenishes_the_reserve_before_any_sweep() {
    let mut fixture = start_vault();
    let reserve = constants::fun_rounding_reserve_mist!();
    fixture.mint_fun(20 * MIST_PER_SUI);
    fixture.advance_epoch();
    fixture.sync();
    fixture.advance_epoch_with_rewards(130);

    fixture.next_tx!(USER, |f| {
        f.vault!().sync(&f.version, f.system!(), f.ctx!());

        let fun_custody = f.vault!().fun_custody_for_testing();
        let retained = 20 * MIST_PER_SUI + reserve;
        assert!(fun_custody.pool_assets() >= retained);
        assert!(fun_custody.pool_assets() <= retained + 2);
        let (liquid, _, _, _) = fun_custody.pool_custody_fields();
        assert_eq!(liquid, reserve);
    });

    fixture.end();
}

#[test]
fun fun_sui_redemption_stays_live_after_the_validator_left() {
    let mut fixture = start_unwound_vault(20 * MIST_PER_SUI);
    let reserve = constants::fun_rounding_reserve_mist!();

    fixture.next_tx!(USER, |f| {
        assert!(f.vault!().is_unwind_only_for_testing());
        let fun_custody = f.vault!().fun_custody_for_testing();
        let (liquid, pending, tokens, _) = fun_custody.pool_custody_fields();
        assert_eq!(pending, 0);
        assert_eq!(tokens, 0);
        assert_eq!(liquid, fun_custody.pool_assets());
    });

    let custody = fixture.redeem_fun(20 * MIST_PER_SUI);
    let (fun_custody, _, _, fun_supply, _) = custody.vault_custody_fields();
    assert_eq!(fun_supply, 0);
    assert!(fun_custody.pool_assets() >= reserve - constants::native_redemption_rounding_margin!());
    assert!(fun_custody.pool_assets() <= reserve + 2);

    fixture.end();
}

#[test]
fun fun_sui_redeems_exactly_during_a_safe_mode_epoch() {
    let mut fixture = start_vault();
    fixture.mint_fun(20 * MIST_PER_SUI);
    fixture.advance_epoch();
    fixture.sync();
    fixture.advance_epoch_with_rewards(130);
    fixture.sync();
    fixture.advance_epoch_safe_mode();

    let custody = fixture.redeem_fun(5 * MIST_PER_SUI);
    let (fun_custody, _, rate, fun_supply, _) = custody.vault_custody_fields();
    let (rate_epoch, _, _) = rate.exchange_rate_fields();
    assert_eq!(rate_epoch, 3);
    assert_eq!(fun_supply, 15 * MIST_PER_SUI);
    assert!(fun_custody.pool_assets() >= fun_supply);

    fixture.end();
}

/// The current cache predates the pending receipt's rewarded activation epoch.
/// Refresh must keep StakedSui intact so redemption can withdraw its exact principal.
#[test]
fun fun_sui_pending_activation_stays_withdrawable_when_the_current_rate_is_missing() {
    let mut fixture = start_vault();
    fixture.mint_fun(20 * MIST_PER_SUI);
    fixture.advance_epoch_with_rewards(130);
    fixture.advance_epoch_safe_mode();

    fixture.next_tx!(USER, |f| {
        let fun_custody = f.vault!().fun_custody_for_testing();
        let (_, pending, tokens, _) = fun_custody.pool_custody_fields();
        assert_eq!(pending, 20 * MIST_PER_SUI);
        assert_eq!(tokens, 0);
    });

    let custody = fixture.redeem_fun(5 * MIST_PER_SUI);
    let (fun_custody, _, rate, fun_supply, _) = custody.vault_custody_fields();
    let (rate_epoch, _, _) = rate.exchange_rate_fields();
    assert_eq!(rate_epoch, 1);
    assert_eq!(fun_supply, 15 * MIST_PER_SUI);
    assert!(fun_custody.pool_assets() >= fun_supply);

    fixture.end();
}

/// Safe mode retains an activated fun receipt so it cannot forfeit deferred
/// rewards; new deposits stay liquid until a normal epoch can recover it.
#[test]
fun fun_sui_mint_keeps_activated_receipt_during_safe_mode() {
    let mut fixture = start_vault();
    let reserve = constants::fun_rounding_reserve_mist!();
    fixture.mint_fun(20 * MIST_PER_SUI);
    fixture.advance_epoch_with_rewards(130);
    fixture.advance_epoch_safe_mode();

    let custody = fixture.mint_fun(MIST_PER_SUI);
    let (fun_custody, _, rate, fun_supply, _) = custody.vault_custody_fields();
    let (liquid, pending, tokens, _) = fun_custody.pool_custody_fields();
    let (rate_epoch, _, _) = rate.exchange_rate_fields();
    assert_eq!(liquid, reserve + MIST_PER_SUI);
    assert_eq!(pending, 20 * MIST_PER_SUI);
    assert_eq!(tokens, 0);
    assert_eq!(rate_epoch, 1);
    assert_eq!(fun_supply, 21 * MIST_PER_SUI);
    assert!(fun_custody.pool_assets() >= fun_supply);

    fixture.advance_epoch_with_rewards(130);
    let custody = fixture.sync();
    let (fun_custody, blast_custody, rate, fun_supply, _) = custody.vault_custody_fields();
    let (liquid, pending, tokens, _) = fun_custody.pool_custody_fields();
    let (rate_epoch, _, _) = rate.exchange_rate_fields();
    assert_eq!(liquid, reserve);
    assert_eq!(pending, 0);
    assert!(tokens > 0);
    assert_eq!(rate_epoch, 4);
    assert!(fun_custody.pool_assets() >= fun_supply + reserve);
    assert!(fun_custody.pool_assets() <= fun_supply + reserve + 2);
    assert!(blast_custody.pool_assets() > BOOTSTRAP);

    fixture.end();
}

/// One MIST above the low-water mark keeps the active fun position intact.
#[test]
fun buffer_above_the_low_water_mark_keeps_active_fun_stake() {
    let mut fixture = start_vault();
    let reserve = constants::fun_rounding_reserve_mist!();
    let low_water = constants::fun_exit_low_water_mist!();
    fixture.mint_fun(20 * MIST_PER_SUI);
    fixture.advance_epoch();
    fixture.sync();

    fixture.next_tx!(USER, |f| {
        f.vault!().consume_fun_buffer_for_testing(reserve - low_water - 1);
    });

    let custody = fixture.sync();
    let (fun_custody, _, _, fun_supply, _) = custody.vault_custody_fields();
    let (_, pending, tokens, _) = fun_custody.pool_custody_fields();
    assert_eq!(pending, 0);
    assert!(tokens > 0);
    assert_eq!(fun_custody.pool_assets(), fun_supply + low_water + 1);

    fixture.end();
}

/// A depleted fun buffer keeps a newly activated receipt for one full reward
/// epoch, realizes those rewards, restores the reserve, and resumes conversion.
#[test]
fun depleted_fun_buffer_recovers_without_forfeiting_every_activation_epoch() {
    let mut fixture = start_vault();
    let reserve = constants::fun_rounding_reserve_mist!();
    let low_water = constants::fun_exit_low_water_mist!();
    fixture.mint_fun(20 * MIST_PER_SUI);
    fixture.advance_epoch();
    fixture.sync();

    fixture.next_tx!(USER, |f| {
        f.vault!().consume_fun_buffer_for_testing(reserve - low_water);
        let custody = f.vault!().fun_custody_for_testing();
        assert_eq!(custody.pool_assets(), 20 * MIST_PER_SUI + low_water);
    });

    let custody = fixture.sync();
    let (fun_custody, _, _, fun_supply, _) = custody.vault_custody_fields();
    let (liquid, pending, tokens, _) = fun_custody.pool_custody_fields();
    assert_eq!(fun_supply, 20 * MIST_PER_SUI);
    assert_eq!(liquid, reserve);
    assert!(pending >= 19 * MIST_PER_SUI);
    assert_eq!(tokens, 0);
    assert_eq!(fun_custody.pool_assets(), fun_supply + low_water);

    // The receipt has just activated. A sync must retain it rather than
    // withdraw at the activation rate and forfeit this epoch's rewards.
    fixture.advance_epoch_with_rewards(130);
    let custody = fixture.sync();
    let (fun_custody, _, _, fun_supply, _) = custody.vault_custody_fields();
    let (liquid, pending, tokens, _) = fun_custody.pool_custody_fields();
    assert_eq!(liquid, reserve);
    assert!(pending >= 19 * MIST_PER_SUI);
    assert_eq!(tokens, 0);
    assert!(fun_custody.pool_assets() >= fun_supply);

    // New principal can remain liquid for this one epoch because native stake
    // with different activation epochs cannot be joined.
    let custody = fixture.mint_fun(MIST_PER_SUI);
    let (fun_custody, _, _, fun_supply, _) = custody.vault_custody_fields();
    let (liquid, pending, tokens, _) = fun_custody.pool_custody_fields();
    assert_eq!(liquid, reserve + MIST_PER_SUI);
    assert!(pending >= 19 * MIST_PER_SUI);
    assert_eq!(tokens, 0);
    assert_eq!(fun_supply, 21 * MIST_PER_SUI);
    assert!(fun_custody.pool_assets() >= fun_supply);

    // After one complete rewarded epoch, recovery realizes yield, restores the
    // full reserve, and re-stakes all fun principal above it.
    fixture.advance_epoch_with_rewards(130);
    let custody = fixture.sync();
    let (fun_custody, _, _, fun_supply, _) = custody.vault_custody_fields();
    let (liquid, pending, tokens, _) = fun_custody.pool_custody_fields();
    assert_eq!(liquid, reserve);
    assert!(pending >= 21 * MIST_PER_SUI);
    assert_eq!(tokens, 0);
    assert_eq!(fun_custody.pool_assets(), fun_supply + reserve);

    // The recovered buffer now permits ordinary fungible conversion at the
    // next activation epoch.
    fixture.advance_epoch();
    let custody = fixture.sync();
    let (fun_custody, _, _, fun_supply, _) = custody.vault_custody_fields();
    let (_, pending, tokens, _) = fun_custody.pool_custody_fields();
    assert_eq!(pending, 0);
    assert!(tokens > 0);
    assert!(fun_custody.pool_assets() >= fun_supply);

    fixture.end();
}

/// A blast request can refresh and realize fun stake; its request fact must
/// describe the final re-delegated vault state rather than an intermediate one.
#[test]
fun blast_request_restakes_realized_fun_and_emits_final_custody() {
    let mut fixture = start_vault();
    let reserve = constants::fun_rounding_reserve_mist!();
    let low_water = constants::fun_exit_low_water_mist!();
    fixture.mint_fun(20 * MIST_PER_SUI);
    fixture.advance_epoch();
    fixture.sync();

    fixture.next_tx!(USER, |f| {
        f.vault!().consume_fun_buffer_for_testing(reserve - low_water);
    });
    fixture.sync();
    // Keep the recovery receipt through its activation epoch, then let the
    // request perform the first normal current-rate realization.
    fixture.advance_epoch_with_rewards(130);
    fixture.advance_epoch_with_rewards(130);

    let requested = fixture.request_blast(5 * MIST_PER_SUI);
    let (_, _, _, principal, _, custody) = requested.blast_sui_deposit_requested_fields();
    assert_eq!(principal, 5 * MIST_PER_SUI);
    let (fun_custody, _, _, fun_supply, _) = custody.vault_custody_fields();
    let (liquid, pending, tokens, _) = fun_custody.pool_custody_fields();
    assert_eq!(liquid, reserve);
    assert!(pending >= 20 * MIST_PER_SUI);
    assert_eq!(tokens, 0);
    assert_eq!(fun_custody.pool_assets(), fun_supply + reserve);

    fixture.next_tx!(USER, |f| assert_custody_matches(&custody, f.vault!()));
    assert!(fixture.cancel_blast() >= 5 * MIST_PER_SUI);
    fixture.end();
}

#[test]
#[expected_failure(abort_code = errors::EUnwindOnly, location = blast_sui::vault)]
fun fun_sui_mint_is_rejected_after_the_validator_left() {
    let mut fixture = start_unwound_vault(0);
    fixture.mint_fun(MIST_PER_SUI);
    fixture.end();
}

#[test]
#[expected_failure(abort_code = errors::EZeroAmount, location = blast_sui::vault)]
fun zero_fun_sui_mint_is_rejected_before_the_unwind_check() {
    let mut fixture = start_unwound_vault(0);
    fixture.mint_fun(0);
    fixture.end();
}

#[test]
#[expected_failure(abort_code = errors::EZeroAmount, location = blast_sui::vault)]
fun zero_fun_sui_mint_is_rejected() {
    let mut fixture = start_vault();
    fixture.mint_fun(0);
    fixture.end();
}

// === blastSUI Tests ===

#[test]
fun donation_increases_blast_assets_without_minting_shares() {
    let mut fixture = start_vault_with_deposit();
    let donation = 18 * MIST_PER_SUI;
    let (assets_before, supply_before, fun_before);
    fixture.next_tx!(USER, |f| {
        assets_before = f.vault!().blast_custody_for_testing().pool_assets();
        supply_before = f.vault!().blast_supply_for_testing();
        fun_before = f.vault!().fun_custody_for_testing().pool_assets();
    });

    let custody = fixture.donate(donation);
    let (fun_custody, blast_custody, _, _, blast_supply) = custody.vault_custody_fields();
    let (_, pending, tokens, _) = blast_custody.pool_custody_fields();
    assert_eq!(fun_custody.pool_assets(), fun_before);
    assert_eq!(blast_custody.pool_assets(), assets_before + donation);
    assert_eq!(blast_supply, supply_before);
    assert_eq!(pending, donation);
    assert!(tokens > 0);

    // Existing redeemable shares receive their pro-rata part of the donation;
    // the locked bootstrap shares retain the rest permanently.
    let shares = DEPOSIT;
    let (_, _, expected_net) = math::blast_redemption_quote(
        shares,
        assets_before + donation,
        supply_before,
        constants::default_redeem_fee_bps!(),
    );
    let (net, _) = fixture.redeem_blast(shares);
    assert_eq!(net, expected_net);
    assert!(net > DEPOSIT);

    fixture.end();
}

#[test]
fun sub_threshold_donations_accumulate_until_the_native_staking_minimum() {
    let mut fixture = start_vault();
    let half_sui = MIST_PER_SUI / 2;

    let custody = fixture.donate(half_sui);
    let (_, blast_custody, _, _, blast_supply) = custody.vault_custody_fields();
    assert_pool(&blast_custody, half_sui, BOOTSTRAP, 0, 0);
    assert_eq!(blast_supply, BOOTSTRAP);

    let custody = fixture.donate(half_sui);
    let (_, blast_custody, _, _, blast_supply) = custody.vault_custody_fields();
    assert_pool(&blast_custody, 0, BOOTSTRAP + MIST_PER_SUI, 0, 0);
    assert_eq!(blast_supply, BOOTSTRAP);

    fixture.end();
}

#[test]
fun donation_stays_open_during_a_safe_mode_epoch() {
    let mut fixture = start_vault_with_deposit();
    fixture.advance_epoch_safe_mode();

    let custody = fixture.donate(MIST_PER_SUI);
    let (_, blast_custody, rate, _, blast_supply) = custody.vault_custody_fields();
    let (rate_epoch, _, _) = rate.exchange_rate_fields();
    assert_eq!(rate_epoch, 2);
    assert_pool(
        &blast_custody,
        MIST_PER_SUI,
        0,
        BOOTSTRAP + DEPOSIT,
        BOOTSTRAP + DEPOSIT,
    );
    assert_eq!(blast_supply, BOOTSTRAP + DEPOSIT);

    fixture.end();
}

#[test]
fun donation_stays_open_and_liquid_after_the_validator_left() {
    let mut fixture = start_unwound_vault(0);
    let amount = 2 * MIST_PER_SUI;
    let assets_before;
    fixture.next_tx!(USER, |f| {
        assets_before = f.vault!().blast_custody_for_testing().pool_assets();
    });

    let custody = fixture.donate(amount);
    let (_, blast_custody, _, _, blast_supply) = custody.vault_custody_fields();
    let (liquid, pending, tokens, _) = blast_custody.pool_custody_fields();
    assert_eq!(blast_custody.pool_assets(), assets_before + amount);
    assert_eq!(liquid, assets_before + amount);
    assert_eq!(pending, 0);
    assert_eq!(tokens, 0);
    assert_eq!(blast_supply, BOOTSTRAP + DEPOSIT);

    fixture.end();
}

#[test]
fun donation_is_the_first_mutation_that_unwinds_a_departed_validator() {
    let mut fixture = start_vault_with_deposit();
    let amount = 2 * MIST_PER_SUI;
    fixture.remove_validator();
    fixture.advance_epoch();

    let custody = fixture.donate(amount);
    let unwound = events::collect_one<events::NativeStakeUnwound>(0);
    let before_donation = unwound.native_stake_unwound_custody();
    let (_, blast_before, _, _, supply_before) = before_donation.vault_custody_fields();
    let (_, blast_after, _, _, supply_after) = custody.vault_custody_fields();
    assert_eq!(blast_after.pool_assets(), blast_before.pool_assets() + amount);
    assert_eq!(supply_after, supply_before);
    let (liquid, pending, tokens, _) = blast_after.pool_custody_fields();
    assert_eq!(liquid, blast_after.pool_assets());
    assert_eq!(pending, 0);
    assert_eq!(tokens, 0);

    fixture.end();
}

/// The same validator address can return with a different staking pool. A
/// missing current entry for the immutable old pool must defer conversion and
/// delegation, so donation, sync, and redemption remain live without mixing pools.
#[test]
fun validator_address_reuse_cannot_mix_pools_or_brick_mutations() {
    let mut fixture = start_vault_with_deposit();
    let old_pool_id = fixture.pool_id();
    fixture.donate(MIST_PER_SUI);
    fixture.rejoin_validator_at_same_address();

    fixture.next_tx!(USER, |f| {
        let validator = f.runner.genesis_validator_addresses()[1];
        let new_pool_id = f.system!().validator_staking_pool_id(validator);
        assert!(new_pool_id != old_pool_id);
    });

    let custody = fixture.donate(MIST_PER_SUI);
    let (_, blast_custody, rate, _, blast_supply) = custody.vault_custody_fields();
    let (liquid, pending, tokens, _) = blast_custody.pool_custody_fields();
    let (rate_epoch, _, _) = rate.exchange_rate_fields();
    assert_eq!(rate_epoch, 2);
    assert_eq!(liquid, MIST_PER_SUI);
    assert_eq!(pending, MIST_PER_SUI);
    assert!(tokens > 0);
    assert_eq!(blast_supply, BOOTSTRAP + DEPOSIT);

    fixture.advance_epoch();
    let custody = fixture.sync();
    let (_, blast_custody, rate, _, _) = custody.vault_custody_fields();
    let (liquid, pending, tokens, _) = blast_custody.pool_custody_fields();
    let (rate_epoch, _, _) = rate.exchange_rate_fields();
    assert_eq!(rate_epoch, 2);
    assert_eq!(liquid, MIST_PER_SUI);
    assert_eq!(pending, MIST_PER_SUI);
    assert!(tokens > 0);

    let (net, _) = fixture.redeem_blast(DEPOSIT);
    assert!(net > 0);
    fixture.end();
}

#[test]
#[expected_failure(abort_code = errors::EWrongDelegationPool, location = blast_sui::vault)]
fun blast_request_rejects_a_reused_validator_address_with_a_new_pool() {
    let mut fixture = start_vault();
    fixture.rejoin_validator_at_same_address();
    fixture.request_blast(MIST_PER_SUI);
    fixture.end();
}

#[test]
#[expected_failure(abort_code = errors::EStaleExchangeRate, location = blast_sui::vault)]
fun pre_departure_receipt_claim_is_rejected_after_validator_address_reuse() {
    let mut fixture = start_vault();
    fixture.request_blast(2 * MIST_PER_SUI);
    fixture.rejoin_validator_at_same_address();
    fixture.claim_blast(0);
    fixture.end();
}

#[test]
fun pre_departure_receipt_cancellation_stays_live_after_validator_address_reuse() {
    let mut fixture = start_vault();
    fixture.request_blast(2 * MIST_PER_SUI);
    fixture.rejoin_validator_at_same_address();
    assert!(fixture.cancel_blast() >= 2 * MIST_PER_SUI);
    fixture.end();
}

#[test]
fun activated_receipt_claim_prices_after_a_donation_and_honors_minimum_output() {
    let mut fixture = start_vault();
    fixture.donate(10 * MIST_PER_SUI);
    fixture.request_blast(2 * MIST_PER_SUI);
    fixture.advance_epoch();

    let (blast_assets, blast_supply, contributed_sui);
    fixture.next_tx!(USER, |f| {
        blast_assets = f.vault!().blast_custody_for_testing().pool_assets();
        blast_supply = f.vault!().blast_supply_for_testing();
        let receipt = f
            .runner
            .scenario_mut()
            .take_from_sender<BlastSuiDepositReceipt>();
        contributed_sui = receipt.principal_sui();
        test_scenario::return_to_sender(f.runner.scenario_mut(), receipt);
    });
    let expected = math::blast_shares_out_down(contributed_sui, blast_assets, blast_supply);
    let (shares, custody) = fixture.claim_blast(expected);
    let (_, _, _, _, final_supply) = custody.vault_custody_fields();
    assert_eq!(shares, expected);
    assert!(shares < contributed_sui);
    assert_eq!(final_supply, blast_supply + shares);

    fixture.end();
}

#[test]
#[expected_failure(abort_code = errors::EZeroAmount, location = blast_sui::vault)]
fun zero_donation_is_rejected() {
    let mut fixture = start_vault();
    fixture.donate(0);
    fixture.end();
}

#[test]
#[expected_failure(
    abort_code = errors::EPackageVersionMismatch,
    location = blast_sui::package_version,
)]
fun stale_package_version_rejects_donation() {
    let mut fixture = start_vault();

    fixture.next_tx!(USER, |f| {
        f.version.set_for_testing(2);
        f.vault!().donate_sui(
            &f.version,
            f.system!(),
            coin::mint_for_testing(MIST_PER_SUI, f.ctx!()),
            f.ctx!(),
        );
    });

    fixture.end();
}

#[test]
fun rewards_from_both_ledgers_accrue_only_to_blast_custody() {
    let mut fixture = start_vault();
    fixture.mint_fun(20 * MIST_PER_SUI);
    fixture.advance_epoch();
    fixture.sync();
    fixture.advance_epoch_with_rewards(130);

    fixture.next_tx!(USER, |f| {
        f.vault!().sync(&f.version, f.system!(), f.ctx!());

        let swept = events::collect_one<events::FunYieldSwept>(0);
        let (liquid_sui, pool_tokens, swept_sui, _) = swept.fun_yield_swept_fields();
        assert_eq!(liquid_sui, 0);
        assert!(pool_tokens > 0);
        assert!(swept_sui > 0);

        let fun_custody = f.vault!().fun_custody_for_testing();
        let retained = 20 * MIST_PER_SUI + constants::fun_rounding_reserve_mist!();
        assert!(fun_custody.pool_assets() >= retained);
        assert!(fun_custody.pool_assets() <= retained + 2);
        let blast_custody = f.vault!().blast_custody_for_testing();
        assert!(blast_custody.pool_assets() > BOOTSTRAP + swept_sui);
    });

    fixture.end();
}

#[test]
fun later_blast_sui_deposit_prices_on_blast_custody_only() {
    let mut fixture = start_vault();
    fixture.mint_fun(20 * MIST_PER_SUI);
    fixture.advance_epoch();
    fixture.sync();
    fixture.advance_epoch_with_rewards(130);
    fixture.sync();

    let deposit = 4 * MIST_PER_SUI;
    fixture.request_blast(deposit);
    fixture.advance_epoch();

    let (blast_assets, blast_supply);
    fixture.next_tx!(USER, |f| {
        blast_assets = f.vault!().blast_custody_for_testing().pool_assets();
        blast_supply = f.vault!().blast_supply_for_testing();
        assert!(blast_assets > BOOTSTRAP);
    });

    let (shares, custody) = fixture.claim_blast(0);
    let claimed = events::collect_one<events::BlastSuiDepositClaimed>(0);
    let (_, _, principal, contributed, pool_tokens, emitted_shares, _) =
        claimed.blast_sui_deposit_claimed_fields();
    let expected_shares = math::blast_shares_out_down(contributed, blast_assets, blast_supply);
    let (_, blast_custody, _, _, final_supply) = custody.vault_custody_fields();
    let (_, pending, active_tokens, _) = blast_custody.pool_custody_fields();
    assert_eq!(principal, deposit);
    assert_eq!(shares, expected_shares);
    assert_eq!(emitted_shares, shares);
    assert!(shares < deposit);
    assert_eq!(pending, 0);
    assert!(active_tokens >= pool_tokens);
    assert_eq!(final_supply, blast_supply + shares);

    fixture.end();
}

#[test]
fun blast_exit_retains_the_fee_in_blast_custody() {
    let mut fixture = start_vault();
    let deposit = 4 * MIST_PER_SUI;
    let redeem_shares = MIST_PER_SUI;
    let (shares, _) = fixture.mint_blast(deposit);
    assert_eq!(shares, deposit);

    let (net, custody) = fixture.redeem_blast(redeem_shares);
    let (_, blast_custody, _, _, blast_supply) = custody.vault_custody_fields();
    let (gross, fee, expected_net) = math::blast_redemption_quote(
        redeem_shares,
        BOOTSTRAP + deposit,
        BOOTSTRAP + deposit,
        constants::default_redeem_fee_bps!(),
    );
    assert_eq!(gross, redeem_shares);
    assert_eq!(fee, 200_000);
    assert_eq!(net, expected_net);
    assert!(blast_custody.pool_assets() >= BOOTSTRAP + deposit - net);
    assert!(blast_custody.pool_assets() <= BOOTSTRAP + deposit - net + 2);
    assert_eq!(blast_supply, BOOTSTRAP + deposit - redeem_shares);

    fixture.end();
}

#[test]
fun blast_exit_from_active_stake_preserves_the_remainder() {
    let mut fixture = start_vault_with_deposit();
    let (net, custody) = fixture.redeem_blast(4 * MIST_PER_SUI);

    let (_, blast_custody, _, _, blast_supply) = custody.vault_custody_fields();
    assert_eq!(net, 4 * MIST_PER_SUI - 800_000);
    let (_, pending, tokens, _) = blast_custody.pool_custody_fields();
    assert_eq!(pending, 0);
    assert!(tokens > 0);
    assert!(blast_custody.pool_assets() >= BOOTSTRAP + DEPOSIT - net);
    assert!(blast_custody.pool_assets() <= BOOTSTRAP + DEPOSIT - net + 2);
    assert_eq!(blast_supply, BOOTSTRAP + DEPOSIT - 4 * MIST_PER_SUI);

    fixture.end();
}

/// One redemption consumes liquid first, then the whole pending receipt, then
/// only the active tokens needed for the remaining deficit.
#[test]
fun blast_redemption_can_draw_from_liquid_pending_and_active_in_one_call() {
    let mut fixture = start_vault_with_deposit();
    let (active_tokens_before, assets_before, supply_before);
    fixture.next_tx!(USER, |f| {
        f.vault!().add_blast_layers_for_testing(
            f.system!(),
            coin::mint_for_testing(2 * MIST_PER_SUI, f.ctx!()),
            coin::mint_for_testing(MIST_PER_SUI / 2, f.ctx!()),
            f.ctx!(),
        );
        let custody = f.vault!().blast_custody_for_testing();
        let (liquid, pending, active_tokens, _) = custody.pool_custody_fields();
        assert_eq!(liquid, MIST_PER_SUI / 2);
        assert_eq!(pending, 2 * MIST_PER_SUI);
        assert!(active_tokens > 0);
        active_tokens_before = active_tokens;
        assets_before = custody.pool_assets();
        supply_before = f.vault!().blast_supply_for_testing();
    });

    let redeem_shares = 4 * MIST_PER_SUI;
    let (_, _, expected_net) = math::blast_redemption_quote(
        redeem_shares,
        assets_before,
        supply_before,
        constants::default_redeem_fee_bps!(),
    );
    assert!(expected_net > 2 * MIST_PER_SUI + MIST_PER_SUI / 2);
    let (net, custody) = fixture.redeem_blast(redeem_shares);
    let (_, blast_custody, _, _, _) = custody.vault_custody_fields();
    let (liquid, pending, active_tokens, _) = blast_custody.pool_custody_fields();
    assert_eq!(net, expected_net);
    assert_eq!(pending, 0);
    assert!(liquid < MIST_PER_SUI);
    assert!(active_tokens > 0);
    assert!(active_tokens < active_tokens_before);

    fixture.end();
}

#[test]
fun blast_exit_from_active_stake_pays_the_conservative_quote() {
    let mut fixture = start_vault_with_deposit();
    fixture.mint_fun(20 * MIST_PER_SUI);
    fixture.advance_epoch();
    fixture.sync();
    fixture.advance_epoch_with_rewards(130);

    fixture.next_tx!(USER, |f| {
        f.vault!().sync(&f.version, f.system!(), f.ctx!());
        let blast_assets = f.vault!().blast_custody_for_testing().pool_assets();
        let blast_supply = f.vault!().blast_supply_for_testing();
        let fun_assets = f.vault!().fun_custody_for_testing().pool_assets();
        assert!(blast_assets > BOOTSTRAP + DEPOSIT);

        let mut blast_coin = f.take_blast_coin();
        let shares = 5 * MIST_PER_SUI;
        let redeem_coin = blast_coin.split(shares, f.ctx!());
        let (gross, fee, net) = math::blast_redemption_quote(
            shares,
            blast_assets,
            blast_supply,
            constants::default_redeem_fee_bps!(),
        );
        let sui_out = f
            .vault!()
            .redeem_blast_sui(&f.version, f.system!(), redeem_coin, net, f.ctx!());

        assert_eq!(sui_out.value(), net);
        assert!(fee > 0);
        assert!(gross > shares);
        let blast_custody = f.vault!().blast_custody_for_testing();
        assert!(
            blast_custody.pool_assets()
                >= blast_assets - net - constants::native_redemption_rounding_margin!(),
        );
        assert!(blast_custody.pool_assets() <= blast_assets - net + 2);
        assert_eq!(f.vault!().blast_supply_for_testing(), blast_supply - shares);
        assert_eq!(f.vault!().fun_custody_for_testing().pool_assets(), fun_assets);

        transfer::public_transfer(blast_coin, USER);
        transfer::public_transfer(sui_out, USER);
    });

    fixture.end();
}

/// Burning every redeemable share is still a partial, fee-paying exit: the
/// locked seed supply, its pro-rata backing, and the retained fee remain, and
/// fun custody keeps its native position because blast supply never reaches zero.
#[test]
fun redeeming_every_user_share_leaves_the_locked_supply_and_its_backing() {
    let mut fixture = start_vault_with_deposit();
    fixture.mint_fun(20 * MIST_PER_SUI);
    fixture.advance_epoch();
    fixture.sync();
    fixture.advance_epoch_with_rewards(130);
    fixture.sync();

    let (blast_assets, locked_claim);
    fixture.next_tx!(USER, |f| {
        blast_assets = f.vault!().blast_custody_for_testing().pool_assets();
        assert!(blast_assets > BOOTSTRAP + DEPOSIT);
        locked_claim = math::blast_gross_sui_out_down(
            BOOTSTRAP,
            blast_assets,
            BOOTSTRAP + DEPOSIT,
        );
    });
    let (net, custody) = fixture.redeem_blast(DEPOSIT);

    let (fun_custody, blast_custody, _, fun_supply, blast_supply) = custody.vault_custody_fields();
    let (_, _, fun_tokens, _) = fun_custody.pool_custody_fields();
    assert_eq!(blast_supply, BOOTSTRAP);
    assert!(net < blast_assets - locked_claim);
    assert!(blast_custody.pool_assets() > locked_claim);
    assert_eq!(fun_supply, 20 * MIST_PER_SUI);
    assert!(fun_tokens > 0);

    fixture.next_tx!(USER, |f| {
        assert!(!f.has_blast_coin(USER));
        assert_eq!(f.locked_blast_sui(), BOOTSTRAP);
        assert!(!f.vault!().is_unwind_only_for_testing());
    });

    // The locked supply keeps earning both ledgers' yield afterwards.
    fixture.advance_epoch_with_rewards(130);
    let synced = fixture.sync();
    let (_, blast_after, _, _, blast_supply) = synced.vault_custody_fields();
    assert_eq!(blast_supply, BOOTSTRAP);
    assert!(blast_after.pool_assets() > blast_custody.pool_assets());

    fixture.end();
}

/// Even at a zero fee, a user can only ever withdraw its own pro-rata deposit;
/// the seed backing stays in blast custody through repeated full user exits.
#[test]
fun locked_backing_cannot_be_drained_by_user_redemptions() {
    let mut fixture = start_vault_with_deposit();

    fixture.next_tx!(OWNER, |f| {
        f.vault!().set_redeem_fee(
            &f.version,
            &f.authority,
            &f.super_admin_cap,
            0,
        );
    });

    let (net, custody) = fixture.redeem_blast(DEPOSIT);
    let (_, blast_custody, _, _, blast_supply) = custody.vault_custody_fields();
    assert_eq!(net, DEPOSIT);
    let (_, pending, tokens, _) = blast_custody.pool_custody_fields();
    assert_eq!(pending, 0);
    assert!(tokens > 0);
    assert!(blast_custody.pool_assets() >= BOOTSTRAP);
    assert!(blast_custody.pool_assets() <= BOOTSTRAP + 3);
    assert_eq!(blast_supply, BOOTSTRAP);

    let (shares, _) = fixture.mint_blast(DEPOSIT);
    assert_eq!(shares, DEPOSIT);
    let (net, custody) = fixture.redeem_blast(DEPOSIT);
    let (_, blast_custody, _, _, blast_supply) = custody.vault_custody_fields();
    assert_eq!(net, DEPOSIT);
    let (_, pending, tokens, _) = blast_custody.pool_custody_fields();
    assert_eq!(pending, 0);
    assert!(tokens > 0);
    assert!(blast_custody.pool_assets() >= BOOTSTRAP);
    assert!(blast_custody.pool_assets() <= BOOTSTRAP + 3);
    assert_eq!(blast_supply, BOOTSTRAP);

    fixture.next_tx!(USER, |f| {
        assert!(!f.has_blast_coin(USER));
        assert_eq!(f.locked_blast_sui(), BOOTSTRAP);
    });

    fixture.end();
}

#[test]
fun blast_sui_redemption_stays_live_after_the_validator_left() {
    let mut fixture = start_unwound_vault(0);
    let (net, custody) = fixture.redeem_blast(4 * MIST_PER_SUI);

    let (_, blast_custody, _, _, blast_supply) = custody.vault_custody_fields();
    assert!(net > 0);
    assert_eq!(blast_supply, BOOTSTRAP + DEPOSIT - 4 * MIST_PER_SUI);
    let (liquid, pending, tokens, _) = blast_custody.pool_custody_fields();
    assert_eq!(pending, 0);
    assert_eq!(tokens, 0);
    assert_eq!(liquid, blast_custody.pool_assets());

    fixture.end();
}

#[test]
fun validator_removal_unwinds_both_ledgers_and_records_the_unwind() {
    let mut fixture = start_vault();
    fixture.mint_fun(20 * MIST_PER_SUI);
    fixture.advance_epoch();
    fixture.sync();
    fixture.remove_validator();
    fixture.advance_epoch();
    fixture.advance_epoch();

    fixture.next_tx!(USER, |f| {
        f.vault!().sync(&f.version, f.system!(), f.ctx!());

        assert!(f.vault!().is_unwind_only_for_testing());
        let unwound = events::collect_one<events::NativeStakeUnwound>(0);
        let custody = unwound.native_stake_unwound_custody();
        let (fun_custody, blast_custody, rate, fun_supply, blast_supply) =
            custody.vault_custody_fields();
        let (fun_liquid, fun_pending, fun_tokens, _) = fun_custody.pool_custody_fields();
        let (blast_liquid, blast_pending, blast_tokens, _) = blast_custody.pool_custody_fields();
        let (rate_epoch, _, _) = rate.exchange_rate_fields();
        assert_eq!(rate_epoch, 2);
        assert_eq!(fun_pending + fun_tokens + blast_pending + blast_tokens, 0);
        assert!(fun_liquid >= 20 * MIST_PER_SUI);
        assert!(blast_liquid >= BOOTSTRAP);
        assert_eq!(fun_supply, 20 * MIST_PER_SUI);
        assert_eq!(blast_supply, BOOTSTRAP);
        assert_eq!(events::collect<events::VaultSynced>().length(), 1);
    });

    fixture.end();
}

#[test]
fun validator_removal_before_activation_withdraws_pending_principal() {
    let mut fixture = start_vault();
    fixture.mint_fun(20 * MIST_PER_SUI);
    fixture.remove_validator();
    fixture.advance_epoch();
    let synced = fixture.sync();

    let (fun_custody, blast_custody, _, _, _) = synced.vault_custody_fields();
    assert_pool(&fun_custody, 20 * MIST_PER_SUI + constants::fun_rounding_reserve_mist!(), 0, 0, 0);
    assert_pool(&blast_custody, BOOTSTRAP, 0, 0, 0);

    fixture.end();
}

#[test]
#[expected_failure(abort_code = errors::EUnwindOnly, location = blast_sui::vault)]
fun blast_sui_mint_is_rejected_after_the_validator_left() {
    let mut fixture = start_unwound_vault(0);
    fixture.mint_blast(MIST_PER_SUI);
    fixture.end();
}

// === Exchange-Rate Cache Tests ===

/// A rewarded epoch with no vault interaction followed by a safe-mode epoch leaves
/// the cache one rewarded epoch behind. Both ledgers keep that conservative value
/// and no table scan recovers the unobserved entry.
#[test]
fun safe_mode_after_an_unobserved_reward_epoch_keeps_the_cached_conservative_rate() {
    let mut fixture = start_vault();
    fixture.advance_epoch();
    fixture.sync();
    fixture.advance_epoch_with_rewards(130);
    fixture.advance_epoch_safe_mode();

    fixture.next_tx!(USER, |f| {
        let stale_assets = f.vault!().blast_custody_for_testing().pool_assets();
        assert_eq!(stale_assets, BOOTSTRAP);

        f.vault!().sync(&f.version, f.system!(), f.ctx!());

        let pool_id = f.vault!().pool_id_for_testing();
        let rates = f.system!().pool_exchange_rates(&pool_id);
        assert!(!rates.contains(4));
        let cached = rates[2];
        let rewarded = rates[3];
        assert!(
            (rewarded.sui_amount() as u128) * (cached.pool_token_amount() as u128)
                > (cached.sui_amount() as u128) * (rewarded.pool_token_amount() as u128),
        );
        let (rate_epoch, rate_sui, rate_pool_tokens) =
            f.vault!().exchange_rate_for_testing().exchange_rate_fields();
        assert_eq!(rate_epoch, 2);
        assert_eq!(rate_sui, cached.sui_amount());
        assert_eq!(rate_pool_tokens, cached.pool_token_amount());
        assert_eq!(f.vault!().blast_custody_for_testing().pool_assets(), stale_assets);
        assert_eq!(f.ctx!().epoch(), 4);
    });

    fixture.end();
}

#[test]
fun blast_sui_request_stays_open_while_the_cached_rate_is_not_current() {
    let mut fixture = start_vault();
    fixture.advance_epoch();
    fixture.sync();
    fixture.advance_epoch_with_rewards(130);
    fixture.advance_epoch_safe_mode();

    let requested = fixture.request_blast(5 * MIST_PER_SUI);
    let (_, _, pool_id, principal, activation_epoch, _) =
        requested.blast_sui_deposit_requested_fields();
    assert_eq!(pool_id, fixture.pool_id());
    assert_eq!(principal, 5 * MIST_PER_SUI);
    assert_eq!(activation_epoch, 5);
    assert_eq!(fixture.cancel_blast(), 5 * MIST_PER_SUI);
    fixture.end();
}

#[test]
#[expected_failure(abort_code = errors::EStaleExchangeRate, location = blast_sui::vault)]
fun safe_mode_rejects_blast_claims_while_only_the_locked_seed_supply_exists() {
    let mut fixture = start_vault();
    fixture.request_blast(5 * MIST_PER_SUI);
    fixture.advance_epoch_safe_mode();
    fixture.claim_blast(0);
    fixture.end();
}

#[test]
#[expected_failure(abort_code = errors::EStaleExchangeRate, location = blast_sui::vault)]
fun safe_mode_rejects_blast_claims_while_user_shares_are_outstanding() {
    let mut fixture = start_vault_with_deposit();
    fixture.request_blast(5 * MIST_PER_SUI);
    fixture.advance_epoch_safe_mode();
    fixture.claim_blast(0);
    fixture.end();
}

#[test]
fun redemptions_and_fun_mints_stay_live_while_the_cached_rate_is_not_current() {
    let mut fixture = start_vault_with_deposit();
    fixture.mint_fun(20 * MIST_PER_SUI);
    fixture.advance_epoch();
    fixture.sync();
    fixture.advance_epoch_with_rewards(130);
    fixture.advance_epoch_safe_mode();

    let custody = fixture.redeem_fun(6 * MIST_PER_SUI);
    let (fun_custody, _, rate, fun_supply, _) = custody.vault_custody_fields();
    let (rate_epoch, _, _) = rate.exchange_rate_fields();
    assert_eq!(rate_epoch, 3);
    assert_eq!(fun_supply, 14 * MIST_PER_SUI);
    assert!(fun_custody.pool_assets() >= fun_supply);

    let custody = fixture.mint_fun(MIST_PER_SUI);
    let (fun_custody, _, _, fun_supply, _) = custody.vault_custody_fields();
    assert_eq!(fun_supply, 15 * MIST_PER_SUI);
    assert!(fun_custody.pool_assets() >= fun_supply);

    // The blast exit is quoted on the cached conservative valuation.
    fixture.next_tx!(USER, |f| {
        let blast_assets = f.vault!().blast_custody_for_testing().pool_assets();
        let blast_supply = f.vault!().blast_supply_for_testing();
        let shares = 2 * MIST_PER_SUI;
        let (_, _, net) = math::blast_redemption_quote(
            shares,
            blast_assets,
            blast_supply,
            constants::default_redeem_fee_bps!(),
        );

        let mut blast_coin = f.take_blast_coin();
        let redeem_coin = blast_coin.split(shares, f.ctx!());
        let sui_out = f
            .vault!()
            .redeem_blast_sui(&f.version, f.system!(), redeem_coin, net, f.ctx!());

        assert_eq!(sui_out.value(), net);
        assert_eq!(f.vault!().blast_supply_for_testing(), blast_supply - shares);
        transfer::public_transfer(blast_coin, USER);
        transfer::public_transfer(sui_out, USER);
    });

    fixture.end();
}

#[test]
fun a_safe_mode_request_claims_when_the_next_normal_epoch_refreshes_the_cache() {
    let mut fixture = start_vault();
    fixture.advance_epoch();
    fixture.sync();
    fixture.advance_epoch_with_rewards(130);
    fixture.advance_epoch_safe_mode();
    fixture.sync();
    fixture.request_blast(5 * MIST_PER_SUI);
    fixture.advance_epoch_with_rewards(130);

    let (blast_assets, blast_supply);
    fixture.next_tx!(USER, |f| {
        f.vault!().sync(&f.version, f.system!(), f.ctx!());

        let pool_id = f.vault!().pool_id_for_testing();
        let pool_rate = f.system!().pool_exchange_rates(&pool_id)[5];
        let (rate_epoch, rate_sui, rate_pool_tokens) =
            f.vault!().exchange_rate_for_testing().exchange_rate_fields();
        assert_eq!(rate_epoch, 5);
        assert_eq!(rate_sui, pool_rate.sui_amount());
        assert_eq!(rate_pool_tokens, pool_rate.pool_token_amount());
        blast_assets = f.vault!().blast_custody_for_testing().pool_assets();
        blast_supply = f.vault!().blast_supply_for_testing();
        let (_, _, tokens, active_sui) = f.vault!().blast_custody_for_testing().pool_custody_fields();
        assert_eq!(active_sui, tokens.mul_div(pool_rate.sui_amount(), pool_rate.pool_token_amount()));
        assert!(blast_assets > BOOTSTRAP);
    });

    let (shares, _) = fixture.claim_blast(0);
    let claimed = events::collect_one<events::BlastSuiDepositClaimed>(0);
    let (_, _, _, contributed, _, _, _) = claimed.blast_sui_deposit_claimed_fields();
    let fair_shares = math::blast_shares_out_down(contributed, blast_assets, blast_supply);
    assert_eq!(shares, fair_shares);
    assert!(shares < 5 * MIST_PER_SUI);

    fixture.end();
}

#[test]
fun skipped_epochs_refresh_to_the_current_rate_and_convert_pending_stake() {
    let mut fixture = start_vault();
    fixture.mint_fun(20 * MIST_PER_SUI);
    fixture.advance_epoch_with_rewards(130);
    fixture.advance_epoch_with_rewards(130);
    fixture.advance_epoch_with_rewards(130);

    fixture.next_tx!(USER, |f| {
        let fun_custody = f.vault!().fun_custody_for_testing();
        assert_pool(&fun_custody, constants::fun_rounding_reserve_mist!(), 20 * MIST_PER_SUI, 0, 0);
        let blast_custody = f.vault!().blast_custody_for_testing();
        assert_pool(&blast_custody, 0, BOOTSTRAP, 0, 0);
    });

    let synced = fixture.sync();

    let (fun_custody, blast_custody, rate, _, _) = synced.vault_custody_fields();
    let (_, fun_pending, fun_tokens, _) = fun_custody.pool_custody_fields();
    let (_, blast_pending, blast_tokens, _) = blast_custody.pool_custody_fields();
    let (rate_epoch, _, _) = rate.exchange_rate_fields();
    assert_eq!(rate_epoch, 4);
    assert_eq!(fun_pending + blast_pending, 0);
    assert!(fun_tokens > 0 && blast_tokens > 0);
    assert!(blast_custody.pool_assets() > BOOTSTRAP);

    fixture.end();
}

#[test]
#[expected_failure(abort_code = errors::ESlippageExceeded, location = blast_sui::vault)]
fun blast_sui_redemption_rejects_output_below_minimum_before_burning() {
    let mut fixture = start_vault_with_deposit();

    fixture.next_tx!(USER, |f| {
        let mut blast_coin = f.take_blast_coin();
        let redeem_coin = blast_coin.split(5 * MIST_PER_SUI, f.ctx!());
        let sui_out = f
            .vault!()
            .redeem_blast_sui(&f.version, f.system!(), redeem_coin, 5 * MIST_PER_SUI, f.ctx!());

        transfer::public_transfer(blast_coin, USER);
        transfer::public_transfer(sui_out, USER);
    });

    fixture.end();
}

#[test]
#[expected_failure(abort_code = errors::ESlippageExceeded, location = blast_sui::vault)]
fun blast_sui_claim_rejects_shares_below_minimum_without_consuming_the_receipt() {
    let mut fixture = start_vault();
    fixture.advance_epoch();
    fixture.sync();
    fixture.advance_epoch_with_rewards(130);
    fixture.request_blast(MIST_PER_SUI);
    fixture.advance_epoch();
    fixture.claim_blast(MIST_PER_SUI);

    fixture.end();
}

#[test]
#[expected_failure(abort_code = errors::EZeroAmount, location = blast_sui::vault)]
fun zero_blast_sui_redemption_is_rejected() {
    let mut fixture = start_vault();

    fixture.next_tx!(USER, |f| {
        let sui_out = f
            .vault!()
            .redeem_blast_sui(&f.version, f.system!(), coin::zero(f.ctx!()), 0, f.ctx!());

        transfer::public_transfer(sui_out, USER);
    });

    fixture.end();
}

/// The smallest successful post-fee redemption pays exactly one MIST.
#[test]
fun two_mist_blast_redemption_pays_one_mist_after_the_fee() {
    let mut fixture = start_vault_with_deposit();

    fixture.next_tx!(USER, |f| {
        let mut blast_coin = f.take_blast_coin();
        let two_mist = blast_coin.split(2, f.ctx!());
        let sui_out = f
            .vault!()
            .redeem_blast_sui(&f.version, f.system!(), two_mist, 1, f.ctx!());

        assert_eq!(sui_out.value(), 1);
        transfer::public_transfer(blast_coin, USER);
        transfer::public_transfer(sui_out, USER);
    });

    fixture.end();
}

#[test]
#[expected_failure(abort_code = errors::EZeroSuiAfterFee, location = blast_sui::vault)]
fun one_mist_blast_redemption_cannot_burn_for_zero_sui_after_fee() {
    let mut fixture = start_vault_with_deposit();

    fixture.next_tx!(USER, |f| {
        let mut blast_coin = f.take_blast_coin();
        let one_mist = blast_coin.split(1, f.ctx!());
        let sui_out = f
            .vault!()
            .redeem_blast_sui(&f.version, f.system!(), one_mist, 0, f.ctx!());

        transfer::public_transfer(blast_coin, USER);
        transfer::public_transfer(sui_out, USER);
    });

    fixture.end();
}

#[test]
#[expected_failure(
    abort_code = errors::EPackageVersionMismatch,
    location = blast_sui::package_version,
)]
fun stale_package_version_rejects_vault_mutation() {
    let mut fixture = start_vault();

    fixture.next_tx!(USER, |f| {
        f.version.set_for_testing(2);
        f.vault!().sync(&f.version, f.system!(), f.ctx!());
    });

    fixture.end();
}

// === Fee Tests ===

/// A zero rate is the only fee-free user redemption; every other exit retains its fee.
#[test]
fun super_admin_updates_the_fee_and_later_exits_use_and_retain_it() {
    let mut fixture = start_vault();
    fixture.mint_blast(4 * MIST_PER_SUI);

    fixture.next_tx!(OWNER, |f| {
        assert_eq!(f.vault!().redeem_fee_bps_for_testing(), constants::default_redeem_fee_bps!());
        f.vault!().set_redeem_fee(
            &f.version,
            &f.authority,
            &f.super_admin_cap,
            constants::max_redeem_fee_bps!(),
        );

        let changed = events::collect_one<events::RedeemFeeChanged>(0);
        let (old_fee, new_fee) = changed.redeem_fee_changed_fields();
        assert_eq!(old_fee, constants::default_redeem_fee_bps!());
        assert_eq!(new_fee, constants::max_redeem_fee_bps!());
        assert_eq!(f.vault!().redeem_fee_bps_for_testing(), constants::max_redeem_fee_bps!());
    });

    let (assets_before, supply_before);
    fixture.next_tx!(USER, |f| {
        assets_before = f.vault!().blast_custody_for_testing().pool_assets();
        supply_before = f.vault!().blast_supply_for_testing();
    });
    let (_, fee, expected_net) = math::blast_redemption_quote(
        MIST_PER_SUI,
        assets_before,
        supply_before,
        constants::max_redeem_fee_bps!(),
    );
    let (net, custody) = fixture.redeem_blast(MIST_PER_SUI);
    let (_, blast_custody, _, _, _) = custody.vault_custody_fields();
    assert_eq!(fee, 10_000_000);
    assert_eq!(net, expected_net);
    assert!(blast_custody.pool_assets() >= assets_before - net);

    fixture.next_tx!(OWNER, |f| {
        f.vault!().set_redeem_fee(
            &f.version,
            &f.authority,
            &f.super_admin_cap,
            0,
        );
        assert_eq!(f.vault!().redeem_fee_bps_for_testing(), 0);
    });

    // The retained fee raised assets per share, and a zero rate charges nothing.
    let (assets_before, supply_before);
    fixture.next_tx!(USER, |f| {
        assets_before = f.vault!().blast_custody_for_testing().pool_assets();
        supply_before = f.vault!().blast_supply_for_testing();
    });
    let (gross, fee, expected_net) =
        math::blast_redemption_quote(MIST_PER_SUI, assets_before, supply_before, 0);
    let (net, custody) = fixture.redeem_blast(MIST_PER_SUI);
    let (_, blast_custody, _, _, _) = custody.vault_custody_fields();
    assert!(gross > MIST_PER_SUI);
    assert_eq!(fee, 0);
    assert_eq!(net, expected_net);
    assert!(blast_custody.pool_assets() >= assets_before - net);

    fixture.end();
}

#[test]
#[expected_failure(abort_code = errors::EInvalidSuperAdminCap, location = blast_sui::acl)]
fun foreign_super_admin_cap_cannot_change_the_fee() {
    let mut fixture = start_vault();

    fixture.next_tx!(OWNER, |f| {
        let (foreign_cap, foreign_authority) = acl::new_protocol_for_testing(USER, f.ctx!());
        f.vault!().set_redeem_fee(
            &f.version,
            &f.authority,
            &foreign_cap,
            5,
        );
        destroy(foreign_cap);
        destroy(foreign_authority);
    });

    fixture.end();
}

#[test]
#[expected_failure(abort_code = errors::ERedeemFeeAboveMaximum, location = blast_sui::vault)]
fun fee_above_the_immutable_maximum_is_rejected() {
    let mut fixture = start_vault();

    fixture.next_tx!(OWNER, |f| {
        f.vault!().set_redeem_fee(
            &f.version,
            &f.authority,
            &f.super_admin_cap,
            constants::max_redeem_fee_bps!() + 1,
        );
    });

    fixture.end();
}

#[test]
#[expected_failure(abort_code = errors::ERedeemFeeUnchanged, location = blast_sui::vault)]
fun unchanged_fee_is_rejected() {
    let mut fixture = start_vault();

    fixture.next_tx!(OWNER, |f| {
        f.vault!().set_redeem_fee(
            &f.version,
            &f.authority,
            &f.super_admin_cap,
            constants::default_redeem_fee_bps!(),
        );
    });

    fixture.end();
}

#[test]
#[expected_failure(
    abort_code = errors::EPackageVersionMismatch,
    location = blast_sui::package_version,
)]
fun stale_package_version_rejects_fee_changes() {
    let mut fixture = start_vault();

    fixture.next_tx!(OWNER, |f| {
        f.version.set_for_testing(2);
        f.vault!().set_redeem_fee(
            &f.version,
            &f.authority,
            &f.super_admin_cap,
            5,
        );
    });

    fixture.end();
}

// === Replay Tests ===

#[test]
fun every_mutation_emits_a_custody_snapshot_that_replays_to_live_state() {
    let mut fixture = start_vault();
    let after_fun_mint = fixture.mint_fun(20 * MIST_PER_SUI);
    fixture.advance_epoch();
    let after_first_sync = fixture.sync();
    fixture.advance_epoch_with_rewards(130);
    let (shares, after_blast_mint) = fixture.mint_blast(2 * MIST_PER_SUI);
    let after_fun_redeem = fixture.redeem_fun(7 * MIST_PER_SUI);
    let exit_shares = shares / 2;
    let (net, after_blast_redeem) = fixture.redeem_blast(exit_shares);
    let after_donation = fixture.donate(MIST_PER_SUI / 2);
    let after_last_sync = fixture.sync();

    let reserve = constants::fun_rounding_reserve_mist!();
    let (fun_custody, blast_custody, rate, fun_supply, blast_supply) =
        after_fun_mint.vault_custody_fields();
    assert_pool(&fun_custody, reserve, 20 * MIST_PER_SUI, 0, 0);
    assert_pool(&blast_custody, 0, BOOTSTRAP, 0, 0);
    let (rate_epoch, _, _) = rate.exchange_rate_fields();
    assert_eq!(rate_epoch, 1);
    assert_eq!(fun_supply, 20 * MIST_PER_SUI);
    assert_eq!(blast_supply, BOOTSTRAP);

    let (fun_custody, blast_custody, rate, _, _) = after_first_sync.vault_custody_fields();
    let (_, _, fun_tokens, fun_active) = fun_custody.pool_custody_fields();
    let (_, _, blast_tokens, blast_active) = blast_custody.pool_custody_fields();
    assert_eq!(fun_tokens, 20 * MIST_PER_SUI);
    assert_eq!(fun_active, 20 * MIST_PER_SUI);
    assert_eq!(blast_tokens, BOOTSTRAP);
    assert_eq!(blast_active, BOOTSTRAP);
    let (rate_epoch, _, _) = rate.exchange_rate_fields();
    assert_eq!(rate_epoch, 2);

    let (fun_custody, blast_custody, rate, fun_supply, blast_supply) =
        after_blast_mint.vault_custody_fields();
    let (_, blast_pending, blast_tokens, blast_active) = blast_custody.pool_custody_fields();
    let (rate_epoch, _, _) = rate.exchange_rate_fields();
    assert_eq!(rate_epoch, 4);
    assert!(shares < 2 * MIST_PER_SUI);
    assert_eq!(blast_pending, 0);
    assert!(blast_tokens > BOOTSTRAP);
    assert!(blast_active > BOOTSTRAP);
    assert!(fun_custody.pool_assets() >= 20 * MIST_PER_SUI + reserve);
    assert_eq!(fun_supply, 20 * MIST_PER_SUI);
    assert_eq!(blast_supply, BOOTSTRAP + shares);

    let (fun_custody, _, _, fun_supply, _) = after_fun_redeem.vault_custody_fields();
    let (fun_liquid, fun_pending, _, _) = fun_custody.pool_custody_fields();
    assert_eq!(fun_supply, 13 * MIST_PER_SUI);
    assert!(fun_liquid <= constants::native_redemption_rounding_margin!() + 2);
    assert_eq!(fun_pending, 0);

    let (_, blast_before_donation, _, fun_supply, blast_supply) =
        after_blast_redeem.vault_custody_fields();
    assert!(net > 0);
    assert_eq!(fun_supply, 13 * MIST_PER_SUI);
    assert_eq!(blast_supply, BOOTSTRAP + shares - exit_shares);

    let (_, blast_after_donation, _, fun_supply, blast_supply) =
        after_donation.vault_custody_fields();
    assert_eq!(
        blast_after_donation.pool_assets(),
        blast_before_donation.pool_assets() + MIST_PER_SUI / 2,
    );
    assert_eq!(fun_supply, 13 * MIST_PER_SUI);
    assert_eq!(blast_supply, BOOTSTRAP + shares - exit_shares);

    fixture.next_tx!(USER, |f| {
        assert_custody_matches(&after_last_sync, f.vault!());
        assert_eq!(f.vault!().fun_supply_for_testing(), 13 * MIST_PER_SUI);
        assert_eq!(f.vault!().blast_supply_for_testing(), BOOTSTRAP + shares - exit_shares);
    });

    fixture.end();
}

/// The fee rate replays from the creation fact plus ordered change facts.
#[test]
fun fee_rate_replays_from_creation_and_change_facts() {
    let mut fixture = start_create();
    let validator = fixture.validator();
    let created;

    fixture.next_tx!(OWNER, |f| {
        let pool_id = f.system!().validator_staking_pool_id(validator);
        created = f.create_vault(validator, pool_id, BOOTSTRAP, 0);
    });

    let mut fixture = fixture.into_vault_fixture();
    let (_, _, _, _, _, _, mut replayed_fee, _) = created.vault_created_fields();
    let (shares, _) = fixture.mint_blast(DEPOSIT);

    fixture.next_tx!(OWNER, |f| {
        f.vault!().set_redeem_fee(
            &f.version,
            &f.authority,
            &f.super_admin_cap,
            constants::max_redeem_fee_bps!(),
        );
    });
    let changed = events::collect_one<events::RedeemFeeChanged>(0);
    let (old_fee, new_fee) = changed.redeem_fee_changed_fields();
    assert_eq!(old_fee, replayed_fee);
    replayed_fee = new_fee;

    fixture.next_tx!(USER, |f| {
        let mut blast_coin = f.take_blast_coin();
        let redeem_coin = blast_coin.split(shares / 2, f.ctx!());
        let sui_out = f
            .vault!()
            .redeem_blast_sui(&f.version, f.system!(), redeem_coin, 0, f.ctx!());

        transfer::public_transfer(blast_coin, USER);
        transfer::public_transfer(sui_out, USER);
    });
    let redeemed = events::collect_one<events::BlastSuiRedeemed>(0);
    let (_, gross, fee, _, _) = redeemed.blast_sui_redeemed_fields();
    assert_eq!(fee, math::blast_redeem_fee_up(gross, replayed_fee));

    fixture.next_tx!(USER, |f| {
        assert_eq!(f.vault!().redeem_fee_bps_for_testing(), replayed_fee);
    });

    fixture.end();
}

/// Seeded mint, redeem, donate, reward, and sync sequences preserve the fun
/// 1:1 backing everywhere and the sweep retention target after every sync.
#[test]
fun random_sequences_preserve_fun_backing_and_the_sweep_bound() {
    let mut seed = 0x5EED_B1A5_7000_0001;
    let reserve = constants::fun_rounding_reserve_mist!();
    let mut fixture = start_vault_with_deposit();
    // Value of USER's most recent funSUI coin object and the live supply.
    let mut top_fun = 0;
    let mut fun_total = 0;

    30u64.do!(|_| {
        seed = next_random(seed);
        let op = seed % 5;
        let synced = op >= 3;
        let custody = if (op == 0) {
            let amount = 1 + seed % (2 * MIST_PER_SUI);
            top_fun = amount;
            fun_total = fun_total + amount;
            fixture.mint_fun(amount)
        } else if (op == 1 && top_fun > 1) {
            let amount = 1 + seed % (top_fun - 1);
            top_fun = top_fun - amount;
            fun_total = fun_total - amount;
            fixture.redeem_fun(amount)
        } else if (op == 2) {
            fixture.donate(1 + seed % MIST_PER_SUI)
        } else {
            if (op == 3) fixture.advance_epoch_with_rewards(130);
            fixture.sync()
        };

        let (fun_custody, blast_custody, rate, fun_supply, blast_supply) =
            custody.vault_custody_fields();
        assert_eq!(fun_supply, fun_total);
        assert!(fun_custody.pool_assets() >= fun_supply);
        assert!(blast_custody.pool_assets() > 0);
        assert!(blast_supply >= BOOTSTRAP);
        if (synced) {
            // Post-sweep retention: at most one floored pool token of surplus
            // stays behind beyond the supply plus the rounding reserve.
            let (_, rate_sui, rate_pool_tokens) = rate.exchange_rate_fields();
            let slack = math::fun_conversion_loss_bound_up(rate_sui, rate_pool_tokens) + 1;
            assert!(fun_custody.pool_assets() <= fun_supply + reserve + slack);
        };
    });

    fixture.end();
}

// === Fixture Macros ===

/// Runs `$fn` as one transaction with the shared system state borrowed.
macro fun create_next_tx(
    $fixture: &mut CreateFixture,
    $sender: address,
    $fn: |&mut CreateFixture|,
) {
    let fixture = $fixture;

    fixture.runner.set_sender($sender);
    fixture.system_state.fill(fixture.runner.scenario_mut().take_shared<SuiSystemState>());
    $fn(fixture);
    test_scenario::return_shared(fixture.system_state.extract());
}

macro fun create_ctx($fixture: &mut CreateFixture): &mut TxContext {
    let fixture = $fixture;

    fixture.runner.ctx()
}

macro fun create_system($fixture: &mut CreateFixture): &mut SuiSystemState {
    let fixture = $fixture;

    fixture.system_state.borrow_mut()
}

/// Runs `$fn` as one transaction with the shared vault and system state borrowed.
macro fun vault_next_tx(
    $fixture: &mut VaultFixture,
    $sender: address,
    $fn: |&mut VaultFixture|,
) {
    let fixture = $fixture;

    fixture.runner.set_sender($sender);
    fixture.system_state.fill(fixture.runner.scenario_mut().take_shared<SuiSystemState>());
    fixture.vault.fill(fixture.runner.scenario_mut().take_shared<Vault>());
    $fn(fixture);
    test_scenario::return_shared(fixture.vault.extract());
    test_scenario::return_shared(fixture.system_state.extract());
}

macro fun vault_ctx($fixture: &mut VaultFixture): &mut TxContext {
    let fixture = $fixture;

    fixture.runner.ctx()
}

macro fun vault_vault($fixture: &mut VaultFixture): &mut Vault {
    let fixture = $fixture;

    fixture.vault.borrow_mut()
}

macro fun vault_system($fixture: &mut VaultFixture): &mut SuiSystemState {
    let fixture = $fixture;

    fixture.system_state.borrow_mut()
}

// === Fixture Setup ===

/// Two genesis validators with 100 SUI each, advanced once so both pools have a rate entry.
fun start_create(): CreateFixture {
    let mut runner = test_runner::new()
        .validators(
            vector[
                validator_builder::new().initial_stake(100),
                validator_builder::new().initial_stake(100),
            ],
        )
        .build();
    advance_runner_epoch(&mut runner);
    let version = package_version::new_for_testing(runner.ctx());

    CreateFixture { runner, version, system_state: option::none() }
}

/// OWNER seeds the shared vault against the second genesis validator with `bootstrap` plus the fun reserve.
///
/// The `bootstrap` shares are locked at `@0x0`; nobody holds redeemable blastSUI yet.
fun start_vault_with_bootstrap(bootstrap: u64): VaultFixture {
    let mut fixture = start_create();
    let validator = fixture.validator();

    fixture.next_tx!(OWNER, |f| {
        let pool_id = f.system!().validator_staking_pool_id(validator);
        f.create_vault(validator, pool_id, bootstrap, 0);
    });

    fixture.into_vault_fixture()
}

/// The standard vault: ten SUI of locked bootstrap backing and no redeemable shares.
fun start_vault(): VaultFixture {
    start_vault_with_bootstrap(BOOTSTRAP)
}

/// The standard vault plus USER's activated and claimed `DEPOSIT`.
///
/// Both native stakes are active in blast custody, and USER's coin is the only
/// redeemable blastSUI.
fun start_vault_with_deposit(): VaultFixture {
    let mut fixture = start_vault();
    let (shares, custody) = fixture.mint_blast(DEPOSIT);
    let (_, blast_custody, _, _, blast_supply) = custody.vault_custody_fields();
    assert_eq!(shares, DEPOSIT);
    assert_pool(&blast_custody, 0, 0, BOOTSTRAP + DEPOSIT, BOOTSTRAP + DEPOSIT);
    assert_eq!(blast_supply, BOOTSTRAP + DEPOSIT);

    fixture
}

/// A deposit-funded vault with `fun_amount` funSUI whose validator left the active set and was unwound.
fun start_unwound_vault(fun_amount: u64): VaultFixture {
    let mut fixture = start_vault_with_deposit();
    if (fun_amount > 0) {
        fixture.mint_fun(fun_amount);
    };
    fixture.advance_epoch();
    fixture.sync();
    fixture.remove_validator();
    fixture.advance_epoch();
    fixture.sync();

    fixture
}

fun create_end(self: CreateFixture) {
    let CreateFixture { runner, version, system_state } = self;

    destroy(version);
    system_state.destroy_none();
    runner.finish();
}

fun vault_end(self: VaultFixture) {
    let VaultFixture {
        runner,
        version,
        authority,
        super_admin_cap,
        vault,
        system_state,
    } = self;

    destroy(version);
    destroy(authority);
    destroy(super_admin_cap);
    vault.destroy_none();
    system_state.destroy_none();
    runner.finish();
}

// === Fixture Helpers ===

/// The fixed vault validator: the second genesis validator.
fun validator(self: &CreateFixture): address {
    self.runner.genesis_validator_addresses()[1]
}

/// Calls `vault::create` with a seed of `bootstrap` plus the fun reserve, optionally with pre-minted funSUI.
///
/// `create` returns nothing; the minted seed shares are locked at `@0x0` by the vault itself.
fun create_vault(
    self: &mut CreateFixture,
    _validator: address,
    pool_id: ID,
    bootstrap: u64,
    fun_premint: u64,
): events::VaultCreated {
    let mut fun_cap = fun_sui::create_for_testing(self.ctx!());
    let blast_cap = blast_coin::create_for_testing(self.ctx!());
    let premint = fun_cap.mint(fun_premint, self.ctx!());
    vault::create(
        &self.version,
        self.system!(),
        fun_cap,
        blast_cap,
        coin::mint_for_testing(bootstrap + constants::fun_rounding_reserve_mist!(), self.ctx!()),
        pool_id,
        self.ctx!(),
    );

    destroy(premint);
    events::collect_one<events::VaultCreated>(0)
}

fun into_vault_fixture(self: CreateFixture): VaultFixture {
    let CreateFixture { mut runner, version, system_state } = self;
    system_state.destroy_none();
    let (super_admin_cap, authority) = acl::new_protocol_for_testing(OWNER, runner.ctx());

    VaultFixture {
        runner,
        version,
        authority,
        super_admin_cap,
        vault: option::none(),
        system_state: option::none(),
    }
}

fun take_fun_coin(self: &mut VaultFixture): Coin<FUN_SUI> {
    self.runner.scenario_mut().take_from_sender<Coin<FUN_SUI>>()
}

/// The most recently received blastSUI coin of the current sender.
fun take_blast_coin(self: &mut VaultFixture): Coin<BLAST_SUI> {
    self.runner.scenario_mut().take_from_sender<Coin<BLAST_SUI>>()
}

/// Whether `holder` owns any blastSUI coin.
fun has_blast_coin(_self: &VaultFixture, holder: address): bool {
    test_scenario::has_most_recent_for_address<Coin<BLAST_SUI>>(holder)
}

/// The value of the seed coin `create` locked at `@0x0`.
fun locked_blast_sui(self: &mut VaultFixture): u64 {
    let locked = self.runner.scenario_mut().take_from_address<Coin<BLAST_SUI>>(ZERO_ADDRESS);
    let value = locked.value();
    test_scenario::return_to_address(ZERO_ADDRESS, locked);

    value
}

fun pool_id(self: &mut VaultFixture): ID {
    let pool_id;
    self.next_tx!(USER, |f| pool_id = f.vault!().pool_id_for_testing());
    pool_id
}

fun vault_id(self: &mut VaultFixture): ID {
    let vault_id;
    self.next_tx!(USER, |f| vault_id = object::id(f.vault!()));
    vault_id
}

/// Test-only construction of a structurally valid receipt with a chosen immutable binding.
fun issue_test_receipt(
    self: &mut VaultFixture,
    vault_id: ID,
    validator_index: u64,
    amount: u64,
) {
    self.next_tx!(USER, |f| {
        let validator = f.runner.genesis_validator_addresses()[validator_index];
        let staked_sui = f.system!().request_add_stake_non_entry(
            coin::mint_for_testing(amount, f.ctx!()),
            validator,
            f.ctx!(),
        );
        let receipt = deposit_receipt::issue(vault_id, staked_sui, f.ctx!());
        deposit_receipt::keep(receipt, f.ctx!());
    });
}

fun advance_epoch(self: &mut VaultFixture) {
    advance_runner_epoch(&mut self.runner);
}

fun advance_epoch_with_rewards(self: &mut VaultFixture, computation_charge: u64) {
    let options = self.runner.advance_epoch_opts().computation_charge(computation_charge);
    self.runner.advance_epoch(option::some(options)).destroy_for_testing();
}

fun advance_epoch_safe_mode(self: &mut VaultFixture) {
    self.runner.advance_epoch_safe_mode();
}

/// Advances one epoch without writing a pool exchange-rate entry.
fun create_advance_epoch_safe_mode(self: &mut CreateFixture) {
    self.runner.advance_epoch_safe_mode();
}

fun create_advance_epoch(self: &mut CreateFixture) {
    advance_runner_epoch(&mut self.runner);
}

fun create_remove_validator(self: &mut CreateFixture, validator: address) {
    self.runner.set_sender(validator);
    self.runner.remove_validator();
}

/// The vault validator requests its own removal, effective at the next epoch change.
fun remove_validator(self: &mut VaultFixture) {
    let validator = self.runner.genesis_validator_addresses()[1];
    self.runner.set_sender(validator);
    self.runner.remove_validator();
}

/// Removes the fixed validator, then returns its address with a fresh pool.
fun rejoin_validator_at_same_address(self: &mut VaultFixture) {
    let validator = self.runner.genesis_validator_addresses()[1];
    self.remove_validator();
    self.advance_epoch();

    let replacement = validator_builder::preset(2)
        .sui_address(validator)
        .build(self.runner.ctx());
    self.runner.add_validator_candidate(replacement);
    self.runner.set_sender(USER).stake_with(validator, 100);
    self.runner.set_sender(validator).add_validator();
    self.advance_epoch();
}

/// USER mints funSUI and returns the emitted custody snapshot.
fun mint_fun(self: &mut VaultFixture, amount: u64): events::VaultCustody {
    self.next_tx!(USER, |f| {
        let fun_coin = f
            .vault!()
            .mint_fun_sui(
                &f.version,
                f.system!(),
                coin::mint_for_testing(amount, f.ctx!()),
                f.ctx!(),
            );

        assert_eq!(fun_coin.value(), amount);
        transfer::public_transfer(fun_coin, USER);
    });

    let minted = events::collect_one<events::FunSuiMinted>(0);
    let (sui_in, custody) = minted.fun_sui_minted_fields();
    assert_eq!(sui_in, amount);
    custody
}

/// USER delegates SUI and receives one key-only blastSUI deposit receipt.
fun request_blast(self: &mut VaultFixture, amount: u64): events::BlastSuiDepositRequested {
    self.next_tx!(USER, |f| {
        let receipt = f.vault!().request_blast_sui(
            &f.version,
            f.system!(),
            coin::mint_for_testing(amount, f.ctx!()),
            f.ctx!(),
        );
        deposit_receipt::keep(receipt, f.ctx!());
    });

    events::collect_one<events::BlastSuiDepositRequested>(0)
}

/// USER claims its most recent activated receipt and receives blastSUI.
fun claim_blast(
    self: &mut VaultFixture,
    min_blast_out: u64,
): (u64, events::VaultCustody) {
    let shares;
    self.next_tx!(USER, |f| {
        let receipt = f
            .runner
            .scenario_mut()
            .take_from_sender<BlastSuiDepositReceipt>();
        let blast_coin = f
            .vault!()
            .claim_blast_sui(
                &f.version,
                f.system!(),
                receipt,
                min_blast_out,
                f.ctx!(),
            );
        shares = blast_coin.value();

        transfer::public_transfer(blast_coin, USER);
    });

    let claimed = events::collect_one<events::BlastSuiDepositClaimed>(0);
    let (_, _, _, _, _, blast_out, custody) = claimed.blast_sui_deposit_claimed_fields();
    assert_eq!(blast_out, shares);
    (shares, custody)
}

/// USER requests, waits for native activation, and claims blastSUI.
fun mint_blast(self: &mut VaultFixture, amount: u64): (u64, events::VaultCustody) {
    self.request_blast(amount);
    self.advance_epoch();
    self.claim_blast(0)
}

/// USER cancels its most recent receipt directly through the native withdrawal path.
fun cancel_blast(self: &mut VaultFixture): u64 {
    let returned_sui;
    self.next_tx!(USER, |f| {
        let receipt = f
            .runner
            .scenario_mut()
            .take_from_sender<BlastSuiDepositReceipt>();
        let sui_out = deposit_receipt::cancel(receipt, f.system!(), f.ctx!());
        returned_sui = sui_out.value();
        transfer::public_transfer(sui_out, USER);
    });

    let cancelled = events::collect_one<events::BlastSuiDepositCancelled>(0);
    let (_, _, _, emitted_sui) = cancelled.blast_sui_deposit_cancelled_fields();
    assert_eq!(emitted_sui, returned_sui);
    returned_sui
}

/// Adds external SUI to blast custody and returns the emitted final snapshot.
fun donate(self: &mut VaultFixture, amount: u64): events::VaultCustody {
    self.next_tx!(USER, |f| {
        f.vault!().donate_sui(
            &f.version,
            f.system!(),
            coin::mint_for_testing(amount, f.ctx!()),
            f.ctx!(),
        );
    });

    let donated = events::collect_one<events::BlastSuiDonated>(0);
    let (sui_in, custody) = donated.blast_sui_donated_fields();
    assert_eq!(sui_in, amount);
    custody
}

/// USER redeems funSUI one-to-one and returns the emitted custody snapshot.
fun redeem_fun(self: &mut VaultFixture, amount: u64): events::VaultCustody {
    self.next_tx!(USER, |f| {
        let mut fun_coin = f.take_fun_coin();
        let redeem_coin = fun_coin.split(amount, f.ctx!());
        let sui_out = f.vault!().redeem_fun_sui(&f.version, f.system!(), redeem_coin, f.ctx!());

        assert_eq!(sui_out.value(), amount);
        return_or_destroy_zero(fun_coin, USER);
        transfer::public_transfer(sui_out, USER);
    });

    let redeemed = events::collect_one<events::FunSuiRedeemed>(0);
    let (fun_in, custody) = redeemed.fun_sui_redeemed_fields();
    assert_eq!(fun_in, amount);
    custody
}

/// USER redeems `shares` of its deposited blastSUI and returns `(net, custody)`.
fun redeem_blast(self: &mut VaultFixture, shares: u64): (u64, events::VaultCustody) {
    let net;
    self.next_tx!(USER, |f| {
        let mut blast_coin = f.take_blast_coin();
        let redeem_coin = blast_coin.split(shares, f.ctx!());
        let sui_out = f
            .vault!()
            .redeem_blast_sui(&f.version, f.system!(), redeem_coin, 0, f.ctx!());
        net = sui_out.value();

        return_or_destroy_zero(blast_coin, USER);
        transfer::public_transfer(sui_out, USER);
    });

    let redeemed = events::collect_one<events::BlastSuiRedeemed>(0);
    let (blast_in, gross, fee, emitted_net, custody) = redeemed.blast_sui_redeemed_fields();
    assert_eq!(blast_in, shares);
    assert_eq!(emitted_net, gross - fee);
    assert_eq!(emitted_net, net);
    (net, custody)
}

/// USER runs the permissionless sync and returns the emitted custody snapshot.
fun sync(self: &mut VaultFixture): events::VaultCustody {
    self.next_tx!(USER, |f| {
        f.vault!().sync(&f.version, f.system!(), f.ctx!());
    });

    events::collect_one<events::VaultSynced>(0).vault_synced_custody()
}

// === Helpers ===

fun advance_runner_epoch(runner: &mut TestRunner) {
    runner.advance_epoch(option::none()).destroy_for_testing();
}

/// Deterministic 64-bit linear congruential step for the seeded sequence test.
fun next_random(seed: u64): u64 {
    (((seed as u128) * 6364136223846793005 + 1442695040888963407) % 18446744073709551616) as u64
}

/// Returns a remainder coin to `recipient`, deleting it when a full redemption emptied it.
fun return_or_destroy_zero<T>(coin: Coin<T>, recipient: address) {
    if (coin.value() == 0) {
        coin.destroy_zero();
    } else {
        transfer::public_transfer(coin, recipient);
    };
}

fun assert_pool(
    custody: &events::PoolCustody,
    liquid: u64,
    pending: u64,
    tokens: u64,
    active_sui: u64,
) {
    let (actual_liquid, actual_pending, actual_tokens, actual_active_sui) =
        custody.pool_custody_fields();
    assert_eq!(actual_liquid, liquid);
    assert_eq!(actual_pending, pending);
    assert_eq!(actual_tokens, tokens);
    assert_eq!(actual_active_sui, active_sui);
}

fun assert_custody_matches(custody: &events::VaultCustody, vault: &Vault) {
    let (fun_custody, blast_custody, rate, fun_supply, blast_supply) =
        custody.vault_custody_fields();
    assert_eq!(fun_custody, vault.fun_custody_for_testing());
    assert_eq!(blast_custody, vault.blast_custody_for_testing());
    assert_eq!(rate, vault.exchange_rate_for_testing());
    assert_eq!(fun_supply, vault.fun_supply_for_testing());
    assert_eq!(blast_supply, vault.blast_supply_for_testing());
}
