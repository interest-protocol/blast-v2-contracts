/// Minimal Aftermath ReferralVault mainnet interface. Link stubs must not execute.
module referral_vault::referral_vault;

/// Shared referral registry Aftermath's protocol fee consults for the sender's referrer.
public struct ReferralVault has key { id: UID }

#[test_only]
public fun new_for_testing(ctx: &mut TxContext): ReferralVault {
    ReferralVault { id: object::new(ctx) }
}
