/// Minimal Turbos interface from cff693265bfc41c7de2233afe31c9d7428adc9e1.
/// Link stubs must not execute.
module turbos_clmm::position_nft;

public struct TurbosPositionNFT has key, store { id: UID }

public fun pool_id(_nft: &TurbosPositionNFT): ID { abort 0 }
