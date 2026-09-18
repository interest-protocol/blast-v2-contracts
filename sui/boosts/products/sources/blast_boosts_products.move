/// Blast-owned product tags for Series1 Boost currencies.
///
/// A Boost currency is `blast_boost::BlastBoost<Product>` in the
/// issuing adapter, and its `Product` argument is what a holder reads inside
/// the coin type. Declaring every tag in this module keeps that inner type
/// under the Blast name: `blast_boosts_products::NVDA_BULL_2X`.
///
/// Each product is one empty `drop` struct named `<TICKER>_<SIDE>_<LEVERAGE>`,
/// for example `public struct NVDA_BULL_2X() has drop;`. `BULL` tracks the
/// perp long and `BEAR` the inverse; the ticker is the Aftermath base asset
/// without its USD suffix. A tag carries no authority and no state: Coin
/// Registry admits one currency per tag type, and the Series1 issuer role is
/// the only authority that can issue it. Adding a tag is a compatible upgrade
/// of this package; nothing here is ever removed. A declared tag is not a
/// live product until an adapter issues its currency.
module blast_boosts_products::blast_boosts_products;

// === Public Structs ===

/// One-time witness used only to claim this package's Publisher.
public struct BLAST_BOOSTS_PRODUCTS() has drop;

// === Product Tags ===
//
// One bull and one bear tag per Aftermath perpetual market, as listed by
// `POST https://aftermath.finance/api/perpetuals/markets` on 2026-09-18.

// Crypto
public struct BTC_BULL_2X() has drop;
public struct BTC_BEAR_2X() has drop;
public struct CARDS_BULL_2X() has drop;
public struct CARDS_BEAR_2X() has drop;
public struct CHIP_BULL_2X() has drop;
public struct CHIP_BEAR_2X() has drop;
public struct ETH_BULL_2X() has drop;
public struct ETH_BEAR_2X() has drop;
public struct HYPE_BULL_2X() has drop;
public struct HYPE_BEAR_2X() has drop;
public struct LIT_BULL_2X() has drop;
public struct LIT_BEAR_2X() has drop;
public struct MON_BULL_2X() has drop;
public struct MON_BEAR_2X() has drop;
public struct NEAR_BULL_2X() has drop;
public struct NEAR_BEAR_2X() has drop;
public struct PUMP_BULL_2X() has drop;
public struct PUMP_BEAR_2X() has drop;
public struct SOL_BULL_2X() has drop;
public struct SOL_BEAR_2X() has drop;
public struct SUI_BULL_2X() has drop;
public struct SUI_BEAR_2X() has drop;
public struct UNI_BULL_2X() has drop;
public struct UNI_BEAR_2X() has drop;
public struct XMR_BULL_2X() has drop;
public struct XMR_BEAR_2X() has drop;
public struct XRP_BULL_2X() has drop;
public struct XRP_BEAR_2X() has drop;
public struct ZEC_BULL_2X() has drop;
public struct ZEC_BEAR_2X() has drop;

// Equities
public struct AMC_BULL_2X() has drop;
public struct AMC_BEAR_2X() has drop;
public struct CRCL_BULL_2X() has drop;
public struct CRCL_BEAR_2X() has drop;
public struct CYPH_BULL_2X() has drop;
public struct CYPH_BEAR_2X() has drop;
public struct DRAM_BULL_2X() has drop;
public struct DRAM_BEAR_2X() has drop;
public struct GOOGL_BULL_2X() has drop;
public struct GOOGL_BEAR_2X() has drop;
public struct INTC_BULL_2X() has drop;
public struct INTC_BEAR_2X() has drop;
public struct IOVA_BULL_2X() has drop;
public struct IOVA_BEAR_2X() has drop;
public struct LLY_BULL_2X() has drop;
public struct LLY_BEAR_2X() has drop;
public struct META_BULL_2X() has drop;
public struct META_BEAR_2X() has drop;
public struct MRVL_BULL_2X() has drop;
public struct MRVL_BEAR_2X() has drop;
public struct MU_BULL_2X() has drop;
public struct MU_BEAR_2X() has drop;
public struct NVDA_BULL_2X() has drop;
public struct NVDA_BEAR_2X() has drop;
public struct SAMSUNG_BULL_2X() has drop;
public struct SAMSUNG_BEAR_2X() has drop;
public struct SKHYNIX_BULL_2X() has drop;
public struct SKHYNIX_BEAR_2X() has drop;
public struct SNDK_BULL_2X() has drop;
public struct SNDK_BEAR_2X() has drop;
public struct SPCX_BULL_2X() has drop;
public struct SPCX_BEAR_2X() has drop;
public struct TSLA_BULL_2X() has drop;
public struct TSLA_BEAR_2X() has drop;
public struct US500_BULL_2X() has drop;
public struct US500_BEAR_2X() has drop;

// Commodities
public struct BRENT_BULL_2X() has drop;
public struct BRENT_BEAR_2X() has drop;
public struct WTI_BULL_2X() has drop;
public struct WTI_BEAR_2X() has drop;
public struct XAG_BULL_2X() has drop;
public struct XAG_BEAR_2X() has drop;
public struct XAUT_BULL_2X() has drop;
public struct XAUT_BEAR_2X() has drop;

// === Private Initialization ===

fun init(otw: BLAST_BOOSTS_PRODUCTS, ctx: &mut TxContext) {
    sui::package::claim_and_keep(otw, ctx);
}

// === Test-Only Functions ===

#[test_only]
/// Runs package initialization with a genuine test one-time witness.
public fun init_for_testing(ctx: &mut TxContext) {
    init(sui::test_utils::create_one_time_witness<BLAST_BOOSTS_PRODUCTS>(), ctx);
}
