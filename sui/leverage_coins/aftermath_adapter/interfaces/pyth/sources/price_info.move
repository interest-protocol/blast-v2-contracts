/// Pinned Pyth price-info ABI port.
module pyth::price_info {

use pyth::price_feed::PriceFeed;
use sui::object::{UID, ID};

struct PriceInfoObject has key, store {
    id: UID,
    price_info: PriceInfo,
}

struct PriceInfo has copy, drop, store {
    attestation_time: u64,
    arrival_time: u64,
    price_feed: PriceFeed,
}

public fun uid_to_inner(_self: &PriceInfoObject): ID { abort 404 }

public fun get_price_info_from_price_info_object(_self: &PriceInfoObject): PriceInfo { abort 404 }

public fun get_price_feed(_self: &PriceInfo): &PriceFeed { abort 404 }
}
