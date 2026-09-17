/// Pinned Pyth price-feed ABI port.
module pyth::price_feed {

use pyth::{price::Price, price_identifier::PriceIdentifier};

struct PriceFeed has copy, drop, store {
    price_identifier: PriceIdentifier,
    price: Price,
    ema_price: Price,
}

public fun get_price(_self: &PriceFeed): Price { abort 404 }
}
