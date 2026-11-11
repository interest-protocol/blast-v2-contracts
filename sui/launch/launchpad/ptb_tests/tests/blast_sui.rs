//! `blast_sui` composition through the transaction runtime, on a several-validator simulator:
//! each changed entry point's result feeds a later command, and each misuse rolls back.

use anyhow::Result;
use blast_launchpad_ptb_tests::{Harness, Outcome, blast_sui::*, call, test_work_dir};
use sui_types::{
    TypeTag, effects::TransactionEffectsAPI, gas_coin::MIST_PER_SUI,
    programmable_transaction_builder::ProgrammableTransactionBuilder,
};

const LISTED: usize = 3;

/// A deployment listing the first three of five validators, enough that one can still leave
/// the minimum committee; the others stay unlisted.
fn deploy(name: &str) -> Result<(Harness, BlastSui, Vec<Pool>)> {
    let mut h = Harness::with_committee(LISTED + 2)?;
    advance_epoch(&mut h);
    let pools = active_pools(&h);
    let stack = BlastSui::deploy(&mut h, &test_work_dir().join(name), &pools[..LISTED])?;

    Ok((h, stack, pools))
}

fn receipts(h: &Harness) -> Vec<sui_types::base_types::ObjectID> {
    h.owned_of_type(h.sender, "deposit_receipt", "BlastSuiDepositReceipt")
}

/// How many events of payload `name` the transaction emitted through the package envelope.
fn emitted(outcome: &Outcome, name: &str) -> usize {
    outcome
        .events
        .iter()
        .filter(|event| {
            event.type_.name.as_str() == "Event"
                && matches!(
                    event.type_.type_params.first(),
                    Some(TypeTag::Struct(payload)) if payload.name.as_str() == name
                )
        })
        .count()
}

fn assert_failed_with(outcome: &Outcome, expected: &str) {
    let status = format!("{:?}", outcome.effects.status());
    assert!(status.contains(expected), "expected {expected}, got {status}");
}

#[test]
fn a_request_feeds_keep_and_a_claim_feeds_a_redemption_in_one_ptb() -> Result<()> {
    let (mut h, stack, pools) = deploy("blast_sui_request_claim")?;

    stack.request_and_keep(&mut h, pools[1].pool_id, 3 * MIST_PER_SUI)?.assert_success();
    let kept = receipts(&h);
    assert_eq!(kept.len(), 1, "keep delivers the receipt to the sender");

    advance_epoch(&mut h);
    let mut b = ProgrammableTransactionBuilder::new();
    let (vault, version, system) = stack.inputs(&h, &mut b)?;
    let receipt = b.obj(h.owned(kept[0]))?;
    let min_blast_out = b.pure(0u64)?;
    let blast_coin = call(
        &mut b,
        stack.package,
        "vault",
        "claim_blast_sui",
        vec![],
        vec![vault, version, system, receipt, min_blast_out],
    );
    let min_sui_out = b.pure(1u64)?;
    let sui_out = call(
        &mut b,
        stack.package,
        "vault",
        "redeem_blast_sui",
        vec![],
        vec![vault, version, system, blast_coin, min_sui_out],
    );
    b.transfer_arg(h.sender, sui_out);
    let outcome = h.execute(b.finish())?;

    outcome.assert_success();
    assert!(outcome.consumed(kept[0]), "the claim consumes the receipt");
    assert_eq!(emitted(&outcome, "BlastSuiDepositClaimed"), 1);
    assert_eq!(emitted(&outcome, "BlastSuiRedeemed"), 1);
    assert!(stack.coins_of(&h, "blast_sui::BLAST_SUI").is_empty(), "the claimed coin was spent");

    Ok(())
}

#[test]
fn a_minted_coin_feeds_a_redemption_in_one_ptb() -> Result<()> {
    let (mut h, stack, pools) = deploy("blast_sui_mint_redeem")?;

    let mut b = ProgrammableTransactionBuilder::new();
    let fun_coin = stack.mint_fun(&h, &mut b, pools[2].pool_id, 2 * MIST_PER_SUI)?;
    let (vault, version, system) = stack.inputs(&h, &mut b)?;
    let sui_out = call(
        &mut b,
        stack.package,
        "vault",
        "redeem_fun_sui",
        vec![],
        vec![vault, version, system, fun_coin],
    );
    b.transfer_arg(h.sender, sui_out);
    let outcome = h.execute(b.finish())?;

    outcome.assert_success();
    assert_eq!(emitted(&outcome, "FunSuiMinted"), 1);
    assert_eq!(emitted(&outcome, "FunSuiRedeemed"), 1);
    assert!(stack.coins_of(&h, "fun_sui::FUN_SUI").is_empty(), "the minted coin was spent");

    Ok(())
}

#[test]
fn misuse_rolls_back_and_leaves_the_vault_unchanged() -> Result<()> {
    let (mut h, stack, pools) = deploy("blast_sui_negatives")?;
    let before = h.contents(stack.vault);

    // A pick outside the list aborts in the vault.
    let unlisted = stack.request_and_keep(&mut h, pools[LISTED].pool_id, 2 * MIST_PER_SUI)?;
    assert_failed_with(&unlisted, "MoveAbort");
    assert_eq!(h.contents(stack.vault), before);
    assert!(receipts(&h).is_empty());

    let unlisted = stack.mint_and_keep(&mut h, pools[LISTED].pool_id, 2 * MIST_PER_SUI)?;
    assert_failed_with(&unlisted, "MoveAbort");
    assert_eq!(h.contents(stack.vault), before);

    // A receipt is linear: leaving it unused fails the transaction.
    let mut b = ProgrammableTransactionBuilder::new();
    stack.request_blast(&h, &mut b, pools[0].pool_id, 2 * MIST_PER_SUI)?;
    let unused = h.execute(b.finish())?;
    assert_failed_with(&unused, "UnusedValueWithoutDrop");
    assert_eq!(h.contents(stack.vault), before);

    // A receipt has no `store`: only `deposit_receipt::keep` can deliver it.
    let mut b = ProgrammableTransactionBuilder::new();
    let receipt = stack.request_blast(&h, &mut b, pools[0].pool_id, 2 * MIST_PER_SUI)?;
    b.transfer_arg(h.sender, receipt);
    let transferred = h.execute(b.finish())?;
    assert_failed_with(&transferred, "InvalidTransferObject");
    assert_eq!(h.contents(stack.vault), before);
    assert!(receipts(&h).is_empty());

    Ok(())
}

#[test]
fn a_departed_validator_leaves_the_list_and_the_rest_keep_running() -> Result<()> {
    let (mut h, stack, pools) = deploy("blast_sui_departure")?;

    stack.mint_and_keep(&mut h, pools[1].pool_id, 3 * MIST_PER_SUI)?.assert_success();
    advance_epoch(&mut h);
    stack.sync(&mut h)?.assert_success();
    stack.remove_from_active_set(&mut h, pools[1].validator)?;
    advance_epoch(&mut h);

    let synced = stack.sync(&mut h)?;
    synced.assert_success();
    assert_eq!(emitted(&synced, "PoolUnwound"), 1);

    let departed = stack.mint_and_keep(&mut h, pools[1].pool_id, 2 * MIST_PER_SUI)?;
    assert_failed_with(&departed, "MoveAbort");
    stack.mint_and_keep(&mut h, pools[2].pool_id, 2 * MIST_PER_SUI)?.assert_success();

    Ok(())
}
