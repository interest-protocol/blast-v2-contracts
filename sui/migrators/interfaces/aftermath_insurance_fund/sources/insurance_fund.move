/// Minimal Aftermath InsuranceFund mainnet interface. Link stubs must not execute.
module insurance_fund::insurance_fund;

/// Shared insurance fund Aftermath's protocol fee pays into.
public struct InsuranceFund has key { id: UID }

#[test_only]
public fun new_for_testing(ctx: &mut TxContext): InsuranceFund {
    InsuranceFund { id: object::new(ctx) }
}
