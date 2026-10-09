// SPDX-License-Identifier: BUSL-1.1
// Copyright (c) 2026 Jose Manuel Vasconcelos Cerqueira

/// Fresh sale-token types for the presale mainnet end-to-end run, one per presale.
///
/// Each `new_sale_*` registers its type in the Coin Registry, shares the `Currency`, and returns
/// the zero-supply `TreasuryCap` a presale consumes. The registry admits a type once, so each
/// function succeeds once.
module blast_presale_testkit::sale_tokens;

// === Public Types ===

public struct SALE_A has key {
    id: UID,
}

public struct SALE_B has key {
    id: UID,
}

public struct SALE_C has key {
    id: UID,
}

public struct SALE_D has key {
    id: UID,
}

public struct SALE_E has key {
    id: UID,
}

public struct SALE_F has key {
    id: UID,
}

public struct SALE_G has key {
    id: UID,
}

public struct SALE_H has key {
    id: UID,
}

public struct SALE_I has key {
    id: UID,
}

public struct SALE_J has key {
    id: UID,
}

public struct SALE_K has key {
    id: UID,
}

public struct SALE_L has key {
    id: UID,
}

public struct SALE_M has key {
    id: UID,
}

public struct SALE_N has key {
    id: UID,
}

public struct SALE_O has key {
    id: UID,
}

public struct SALE_P has key {
    id: UID,
}

/// A sale token whose 33-byte symbol exceeds Bluefin's bound.
public struct SALE_Q has key {
    id: UID,
}

public struct SALE_R has key {
    id: UID,
}

public struct SALE_S has key {
    id: UID,
}

public struct SALE_T has key {
    id: UID,
}

public struct SALE_U has key {
    id: UID,
}

public struct SALE_V has key {
    id: UID,
}

public struct SALE_W has key {
    id: UID,
}

public struct SALE_X has key {
    id: UID,
}

public struct SALE_Y has key {
    id: UID,
}

public struct SALE_Z has key {
    id: UID,
}

public struct SALE_AA has key {
    id: UID,
}

public struct SALE_AB has key {
    id: UID,
}

public struct SALE_AC has key {
    id: UID,
}

public struct SALE_AD has key {
    id: UID,
}

public struct SALE_AE has key {
    id: UID,
}

public struct SALE_AF has key {
    id: UID,
}

public struct SALE_AG has key {
    id: UID,
}

public struct SALE_AH has key {
    id: UID,
}

public struct SALE_AI has key {
    id: UID,
}

public struct SALE_AJ has key {
    id: UID,
}

public struct SALE_AK has key {
    id: UID,
}

public struct SALE_AL has key {
    id: UID,
}

public struct SALE_AM has key {
    id: UID,
}

public struct SALE_AN has key {
    id: UID,
}

public struct SALE_LONG_SYMBOL has key {
    id: UID,
}

// === Public Functions ===

public fun new_sale_a(registry: &mut CoinRegistry, ctx: &mut TxContext): TreasuryCap<SALE_A> {
    new!<SALE_A>(registry, b"BPTA", ctx)
}

public fun new_sale_b(registry: &mut CoinRegistry, ctx: &mut TxContext): TreasuryCap<SALE_B> {
    new!<SALE_B>(registry, b"BPTB", ctx)
}

public fun new_sale_c(registry: &mut CoinRegistry, ctx: &mut TxContext): TreasuryCap<SALE_C> {
    new!<SALE_C>(registry, b"BPTC", ctx)
}

public fun new_sale_d(registry: &mut CoinRegistry, ctx: &mut TxContext): TreasuryCap<SALE_D> {
    new!<SALE_D>(registry, b"BPTD", ctx)
}

public fun new_sale_e(registry: &mut CoinRegistry, ctx: &mut TxContext): TreasuryCap<SALE_E> {
    new!<SALE_E>(registry, b"BPTE", ctx)
}

public fun new_sale_f(registry: &mut CoinRegistry, ctx: &mut TxContext): TreasuryCap<SALE_F> {
    new!<SALE_F>(registry, b"BPTF", ctx)
}

public fun new_sale_g(registry: &mut CoinRegistry, ctx: &mut TxContext): TreasuryCap<SALE_G> {
    new!<SALE_G>(registry, b"BPTG", ctx)
}

public fun new_sale_h(registry: &mut CoinRegistry, ctx: &mut TxContext): TreasuryCap<SALE_H> {
    new!<SALE_H>(registry, b"BPTH", ctx)
}

public fun new_sale_i(registry: &mut CoinRegistry, ctx: &mut TxContext): TreasuryCap<SALE_I> {
    new!<SALE_I>(registry, b"BPTI", ctx)
}

public fun new_sale_j(registry: &mut CoinRegistry, ctx: &mut TxContext): TreasuryCap<SALE_J> {
    new!<SALE_J>(registry, b"BPTJ", ctx)
}

public fun new_sale_k(registry: &mut CoinRegistry, ctx: &mut TxContext): TreasuryCap<SALE_K> {
    new!<SALE_K>(registry, b"BPTK", ctx)
}

public fun new_sale_l(registry: &mut CoinRegistry, ctx: &mut TxContext): TreasuryCap<SALE_L> {
    new!<SALE_L>(registry, b"BPTL", ctx)
}

public fun new_sale_m(registry: &mut CoinRegistry, ctx: &mut TxContext): TreasuryCap<SALE_M> {
    new!<SALE_M>(registry, b"BPTM", ctx)
}

public fun new_sale_n(registry: &mut CoinRegistry, ctx: &mut TxContext): TreasuryCap<SALE_N> {
    new!<SALE_N>(registry, b"BPTN", ctx)
}

public fun new_sale_o(registry: &mut CoinRegistry, ctx: &mut TxContext): TreasuryCap<SALE_O> {
    new!<SALE_O>(registry, b"BPTO", ctx)
}

public fun new_sale_p(registry: &mut CoinRegistry, ctx: &mut TxContext): TreasuryCap<SALE_P> {
    new!<SALE_P>(registry, b"BPTP", ctx)
}

public fun new_sale_q(registry: &mut CoinRegistry, ctx: &mut TxContext): TreasuryCap<SALE_Q> {
    new!<SALE_Q>(registry, b"BPTQ", ctx)
}

public fun new_sale_r(registry: &mut CoinRegistry, ctx: &mut TxContext): TreasuryCap<SALE_R> {
    new!<SALE_R>(registry, b"BPTR", ctx)
}

public fun new_sale_s(registry: &mut CoinRegistry, ctx: &mut TxContext): TreasuryCap<SALE_S> {
    new!<SALE_S>(registry, b"BPTS", ctx)
}

public fun new_sale_t(registry: &mut CoinRegistry, ctx: &mut TxContext): TreasuryCap<SALE_T> {
    new!<SALE_T>(registry, b"BPTT", ctx)
}

public fun new_sale_u(registry: &mut CoinRegistry, ctx: &mut TxContext): TreasuryCap<SALE_U> {
    new!<SALE_U>(registry, b"BPTU", ctx)
}

public fun new_sale_v(registry: &mut CoinRegistry, ctx: &mut TxContext): TreasuryCap<SALE_V> {
    new!<SALE_V>(registry, b"BPTV", ctx)
}

public fun new_sale_w(registry: &mut CoinRegistry, ctx: &mut TxContext): TreasuryCap<SALE_W> {
    new!<SALE_W>(registry, b"BPTW", ctx)
}

public fun new_sale_x(registry: &mut CoinRegistry, ctx: &mut TxContext): TreasuryCap<SALE_X> {
    new!<SALE_X>(registry, b"BPTX", ctx)
}

public fun new_sale_y(registry: &mut CoinRegistry, ctx: &mut TxContext): TreasuryCap<SALE_Y> {
    new!<SALE_Y>(registry, b"BPTY", ctx)
}

public fun new_sale_z(registry: &mut CoinRegistry, ctx: &mut TxContext): TreasuryCap<SALE_Z> {
    new!<SALE_Z>(registry, b"BPTZ", ctx)
}

public fun new_sale_aa(registry: &mut CoinRegistry, ctx: &mut TxContext): TreasuryCap<SALE_AA> {
    new!<SALE_AA>(registry, b"BPTAA", ctx)
}

public fun new_sale_ab(registry: &mut CoinRegistry, ctx: &mut TxContext): TreasuryCap<SALE_AB> {
    new!<SALE_AB>(registry, b"BPTAB", ctx)
}

public fun new_sale_ac(registry: &mut CoinRegistry, ctx: &mut TxContext): TreasuryCap<SALE_AC> {
    new!<SALE_AC>(registry, b"BPTAC", ctx)
}

public fun new_sale_ad(registry: &mut CoinRegistry, ctx: &mut TxContext): TreasuryCap<SALE_AD> {
    new!<SALE_AD>(registry, b"BPTAD", ctx)
}

public fun new_sale_ae(registry: &mut CoinRegistry, ctx: &mut TxContext): TreasuryCap<SALE_AE> {
    new!<SALE_AE>(registry, b"BPTAE", ctx)
}

public fun new_sale_af(registry: &mut CoinRegistry, ctx: &mut TxContext): TreasuryCap<SALE_AF> {
    new!<SALE_AF>(registry, b"BPTAF", ctx)
}

public fun new_sale_ag(registry: &mut CoinRegistry, ctx: &mut TxContext): TreasuryCap<SALE_AG> {
    new!<SALE_AG>(registry, b"BPTAG", ctx)
}

public fun new_sale_ah(registry: &mut CoinRegistry, ctx: &mut TxContext): TreasuryCap<SALE_AH> {
    new!<SALE_AH>(registry, b"BPTAH", ctx)
}

public fun new_sale_ai(registry: &mut CoinRegistry, ctx: &mut TxContext): TreasuryCap<SALE_AI> {
    new!<SALE_AI>(registry, b"BPTAI", ctx)
}

public fun new_sale_aj(registry: &mut CoinRegistry, ctx: &mut TxContext): TreasuryCap<SALE_AJ> {
    new!<SALE_AJ>(registry, b"BPTAJ", ctx)
}

public fun new_sale_ak(registry: &mut CoinRegistry, ctx: &mut TxContext): TreasuryCap<SALE_AK> {
    new!<SALE_AK>(registry, b"BPTAK", ctx)
}

public fun new_sale_al(registry: &mut CoinRegistry, ctx: &mut TxContext): TreasuryCap<SALE_AL> {
    new!<SALE_AL>(registry, b"BPTAL", ctx)
}

public fun new_sale_am(registry: &mut CoinRegistry, ctx: &mut TxContext): TreasuryCap<SALE_AM> {
    new!<SALE_AM>(registry, b"BPTAM", ctx)
}

public fun new_sale_an(registry: &mut CoinRegistry, ctx: &mut TxContext): TreasuryCap<SALE_AN> {
    new!<SALE_AN>(registry, b"BPTAN", ctx)
}

public fun new_sale_long_symbol(
    registry: &mut CoinRegistry,
    ctx: &mut TxContext,
): TreasuryCap<SALE_LONG_SYMBOL> {
    new!<SALE_LONG_SYMBOL>(registry, b"BPTLONGSYMBOLXXXXXXXXXXXXXXXXXXXX", ctx)
}

// === Private Functions ===

/// Registers `$T` with `$symbol`, shares its `Currency`, and returns its `TreasuryCap`.
macro fun new<$T: key>(
    $registry: &mut CoinRegistry,
    $symbol: vector<u8>,
    $ctx: &mut TxContext,
): TreasuryCap<$T> {
    let (initializer, treasury_cap) = coin_registry::new_currency<$T>(
        $registry,
        DECIMALS,
        std::string::utf8($symbol),
        b"Blast presale test token".to_string(),
        b"Sale token for Blast presale mainnet tests.".to_string(),
        b"".to_string(),
        $ctx,
    );

    initializer.finalize_and_delete_metadata_cap($ctx);
    treasury_cap
}

// === Constants ===

const DECIMALS: u8 = 9;

// === Imports ===

use sui::{coin::TreasuryCap, coin_registry::{Self, CoinRegistry}};
