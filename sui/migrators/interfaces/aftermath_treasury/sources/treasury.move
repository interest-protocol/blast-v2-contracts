/// Minimal Aftermath Treasury mainnet interface. Link stubs must not execute.
module treasury::treasury;

/// Shared treasury Aftermath's protocol fee pays into.
public struct Treasury has key { id: UID }

#[test_only]
public fun new_for_testing(ctx: &mut TxContext): Treasury {
    Treasury { id: object::new(ctx) }
}
