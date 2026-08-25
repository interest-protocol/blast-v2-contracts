// `blast_fun::errors` intentionally centralizes package-wide abort codes through zero-cost
// macros. W04005 sees the expanded literal; this narrow suppression preserves caller-local abort
// locations and the stable code map documented in `docs/error-codes.md`.
#[allow(lint(abort_without_constant))]
/// Pure graduation arithmetic and named asset partitioning.
module blast_fun::graduation;

use blast_fun::constants;
use sui::balance::Balance;

// === Package Functions ===

/// Partitions one initial Meme balance before curve construction.
///
/// Inputs and outputs are Meme atomic units. Rates are validated basis points. The protocol
/// protocol Meme graduation fee is `ceil(initial * fee_bps / 10_000)`, so its indivisible
/// remainder
/// satisfies the protocol obligation. The destination-pool provision is
/// `floor(initial * provision_bps / 10_000)`, so its remainder stays in curve inventory.
/// MoveStdlib widens both u64 products to u128; bounded rates keep each result within the input.
///
/// The returned order is `(curve_inventory, protocol_meme_fee, pool_provision)`. Every valid
/// result conserves the complete input and requires positive atomic curve and pool balances. A
/// zero or too-small supply aborts with the named zero-provision or zero-curve error after all
/// rate guards; maximum-u64 input remains representable under the accepted ceilings.
public(package) fun partition_meme<Meme>(
    mut meme: Balance<Meme>,
    protocol_meme_graduation_fee_bps: u64,
    meme_liquidity_provision_bps: u64,
): (Balance<Meme>, Balance<Meme>, Balance<Meme>) {
    assert!(
        protocol_meme_graduation_fee_bps
            <= constants::max_protocol_meme_graduation_fee_bps!(),
        blast_fun::errors::invalid_protocol_meme_graduation_fee_bps!(),
    );
    assert!(
        meme_liquidity_provision_bps > 0
            && meme_liquidity_provision_bps
                <= constants::max_meme_liquidity_provision_bps!(),
        blast_fun::errors::invalid_meme_liquidity_provision_bps!(),
    );
    assert!(
        protocol_meme_graduation_fee_bps + meme_liquidity_provision_bps
            < constants::basis_points_denominator!(),
        blast_fun::errors::invalid_meme_supply_partition_bps!(),
    );

    let initial_supply = meme.value();
    let protocol_meme_fee_amount = initial_supply.mul_div_ceil(
        protocol_meme_graduation_fee_bps,
        constants::basis_points_denominator!(),
    );
    let provision_amount = initial_supply.mul_div(
        meme_liquidity_provision_bps,
        constants::basis_points_denominator!(),
    );

    assert!(
        provision_amount > 0,
        blast_fun::errors::zero_meme_liquidity_provision!(),
    );
    assert!(
        protocol_meme_fee_amount + provision_amount < initial_supply,
        blast_fun::errors::zero_meme_curve_inventory!(),
    );

    let protocol_meme_fee = meme.split(protocol_meme_fee_amount);
    let provision = meme.split(provision_amount);

    (meme, protocol_meme_fee, provision)
}

/// Partitions gross terminal Quote into net migration principal and protocol revenue.
///
/// Inputs and outputs are Quote atomic units. The fee is
/// `ceil(gross_quote * fee_bps / 10_000)` and therefore assigns any indivisible remainder to the
/// protocol obligation. MoveStdlib widens the u64 product to u128. A zero amount or rate produces
/// a zero fee; for every input, `net_quote + migration_fee == gross_quote`.
public(package) fun partition_quote<Quote>(
    mut quote: Balance<Quote>,
    quote_migration_fee_bps: u64,
): (Balance<Quote>, Balance<Quote>) {
    assert!(
        quote_migration_fee_bps <= constants::max_quote_migration_fee_bps!(),
        blast_fun::errors::invalid_quote_migration_fee_bps!(),
    );

    let fee_amount = quote.value().mul_div_ceil(
        quote_migration_fee_bps,
        constants::basis_points_denominator!(),
    );
    let migration_fee = quote.split(fee_amount);

    (quote, migration_fee)
}
