#[test_only]
module blast_fun_dex_coin_flow_tests::permissions_tests;

// === Tests ===

#[test]
fun callback_permissions_exclude_accounting_and_reserved_bits() {
    let callbacks = permissions::before_initialize_flag!() |
        permissions::after_initialize_flag!() |
        permissions::before_add_liquidity_flag!() |
        permissions::after_add_liquidity_flag!() |
        permissions::before_remove_liquidity_flag!() |
        permissions::after_remove_liquidity_flag!() |
        permissions::before_swap_flag!() |
        permissions::after_swap_flag!() |
        permissions::before_donate_flag!() |
        permissions::after_donate_flag!();

    assert!(callbacks == permissions::all_hook_flags!());
    assert!(callbacks == 0x3ff0);
    assert!((callbacks & 0x000f) == 0);
    assert!((callbacks & 0xc000) == 0);
}

// === Imports ===

use blast_fun_dex::permissions;
