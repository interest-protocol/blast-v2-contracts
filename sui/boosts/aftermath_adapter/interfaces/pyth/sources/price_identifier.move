/// Pinned Pyth price-identifier ABI port.
module pyth::price_identifier {

struct PriceIdentifier has copy, drop, store {
    bytes: vector<u8>,
}
}
