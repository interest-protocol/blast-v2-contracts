// SPDX-License-Identifier: BUSL-1.1
// Copyright (c) 2026 Jose Manuel Vasconcelos Cerqueira

#[test_only]
/// A simulated perpetuals venue and the adapter that drives the core against it.
///
/// `Venue` is the exchange account as the core would observe it: equity, an
/// unsigned position, oracle prices, and the venue's own fee and slippage.
/// Every fill charges adverse execution and the taker fee exactly the way
/// `rebalance_math::execution_cost_up` reserves for them, so the core's
/// sizing and the venue's cost agree to the atom. `Vault` is a minimal
/// adapter: it owns the core `State`, the share supply, and admin cash, and
/// walks each operation through the same prepare, order, verify, complete
/// sequence the Aftermath adapter uses. Scenario suites drive whole vault
/// lifetimes through it without hand-writing a single observation.
module blast_boosts_core::test_adapter;

// === Constants ===

const BASE_DECIMALS: u8 = 9;

const COLLATERAL_DECIMALS: u8 = 6;

const BASE_UNIT: u64 = 1_000_000_000;

const COLLATERAL_UNIT: u64 = 1_000_000;

const PRICE_SCALE: u64 = 1_000_000_000;

const BPS: u64 = 10_000;

const SEED_SHARE_SCALE: u64 = 1_000;

const MAX_ORDERS: u64 = 16;

const ORACLE_LAG_DURATION_MS: u64 = 1_000;

// === Errors ===

/// The venue cannot serve a priced operation: paused, under margin, orders open, or drifted.
const EVenueNotReady: u64 = 0;

/// A mint or redemption would need more capped orders than one transaction places.
const EOrderLimitExceeded: u64 = 1;

// === Test-Only Types ===

public struct Product {}

/// The exchange account and market as the adapter would read them.
public struct Venue has copy, drop {
    equity: u64,
    base: u64,
    side: PositionSide,
    base_price: u64,
    collateral_price: u64,
    lot_size: u64,
    taker_fee_bps: u64,
    slippage_bps: u64,
    /// Share of each order the book fills, in basis points; the rest is left unfilled.
    fill_ratio_bps: u64,
    pending_orders: u64,
    margin_safe: bool,
    operational: bool,
    checkpoint_clean: bool,
    now_ms: u64,
}

/// An issued product before its seed position exists, as the real adapter holds one.
public struct Issued {
    issuance: Issuance<Product>,
    venue: Venue,
}

/// A vault: the core state, the venue it is bound to, and the adapter's own books.
public struct Vault {
    state: State<Product>,
    venue: Venue,
    supply: u64,
    locked: u64,
    admin_cash: u64,
    terminal_cash: u64,
    /// Orders the most recent mint, redemption, rebalance or unwind placed.
    last_orders: u64,
}

// === Test Helpers ===

// --- Venue ---

/// A calm long market: $2.50 base, $1 collateral, 5 bps taker fee, 20 bps slippage.
public fun calm_venue(): Venue {
    Venue {
        equity: 0,
        base: 0,
        side: policy::long(),
        base_price: 2_500_000_000,
        collateral_price: PRICE_SCALE,
        lot_size: 1_000_000,
        taker_fee_bps: 5,
        slippage_bps: 20,
        fill_ratio_bps: BPS,
        pending_orders: 0,
        margin_safe: true,
        operational: true,
        checkpoint_clean: true,
        now_ms: 100_000,
    }
}

public fun with_side(mut self: Venue, side: PositionSide): Venue { self.side = side; self }

public fun with_fill_ratio_bps(mut self: Venue, fill_ratio_bps: u64): Venue { self.fill_ratio_bps = fill_ratio_bps; self }

public fun with_slippage_bps(mut self: Venue, slippage_bps: u64): Venue { self.slippage_bps = slippage_bps; self }

public fun with_taker_fee_bps(mut self: Venue, taker_fee_bps: u64): Venue { self.taker_fee_bps = taker_fee_bps; self }

public fun equity(self: &Venue): u64 { self.equity }

public fun base(self: &Venue): u64 { self.base }

public fun base_price(self: &Venue): u64 { self.base_price }

public fun lot_size(self: &Venue): u64 { self.lot_size }

public fun now_ms(self: &Venue): u64 { self.now_ms }

/// The position valued at the oracle, rounded up, exactly as the core values it.
public fun notional(self: &Venue): u64 {
    self.notional_of(self.base)
}

public fun notional_of(self: &Venue, base: u64): u64 {
    if (base == 0) return 0;
    rebalance_math::oracle_notional_up(base, self.base_price, self.collateral_price, BASE_UNIT, COLLATERAL_UNIT)
}

/// Whole-lot base worth at most `notional` at the oracle.
public fun base_for_notional(self: &Venue, notional: u64): u64 {
    rebalance_math::base_for_oracle_notional_down(
        notional, self.base_price, self.collateral_price, self.lot_size, BASE_UNIT, COLLATERAL_UNIT,
    )
}

/// One observation of the account at this instant, priced by oracles published `ORACLE_LAG_DURATION_MS` ago.
///
/// Like the real adapter, this refuses a venue that is paused, under margin,
/// carrying orders, or drifted from the last accepted checkpoint before the
/// core sees anything.
public fun observe(self: &Venue): PositionObservation {
    assert!(
        self.pending_orders == 0 && self.margin_safe && self.operational && self.checkpoint_clean,
        EVenueNotReady,
    );

    observation::new_position(
        self.equity,
        self.base,
        self.lot_size,
        self.side,
        self.oracle(self.base_price),
        self.oracle(self.collateral_price),
        self.base_price,
    )
}

public fun oracle(self: &Venue, price: u64): PriceObservation {
    observation::new_price(price, price / 1_000, self.now_ms - ORACLE_LAG_DURATION_MS)
}

/// Moves the oracle and marks the open position to it.
///
/// A loss larger than equity leaves zero equity and unsafe margin, which is
/// what a liquidation-bound account looks like to the core.
public fun set_base_price(self: &mut Venue, base_price: u64) {
    let before = self.notional();
    self.base_price = base_price;
    let after = self.notional();
    let gains = if (self.side == policy::long()) { after >= before } else { before >= after };
    let magnitude = after.diff(before);

    if (gains) {
        self.equity = self.equity + magnitude;
    } else if (magnitude >= self.equity) {
        self.equity = 0;
        self.margin_safe = false;
    } else {
        self.equity = self.equity - magnitude;
    };
}

public fun advance(self: &mut Venue, elapsed_duration_ms: u64) { self.now_ms = self.now_ms + elapsed_duration_ms; }

public fun set_operational(self: &mut Venue, operational: bool) { self.operational = operational; }

public fun set_lot_size(self: &mut Venue, lot_size: u64) {
    assert!(lot_size > 0 && self.base % lot_size == 0);
    self.lot_size = lot_size;
}

public fun set_slippage_bps(self: &mut Venue, slippage_bps: u64) { self.slippage_bps = slippage_bps; }

public fun set_fill_ratio_bps(self: &mut Venue, fill_ratio_bps: u64) { self.fill_ratio_bps = fill_ratio_bps; }

/// The venue force-closes the whole position and keeps every atom of equity.
public fun liquidate(self: &mut Venue) {
    self.base = 0;
    self.equity = 0;
    self.margin_safe = true;
}

public fun set_margin_safe(self: &mut Venue, margin_safe: bool) { self.margin_safe = margin_safe; }

public fun set_pending_orders(self: &mut Venue, pending_orders: u64) { self.pending_orders = pending_orders; }

public fun deposit(self: &mut Venue, amount: u64) { self.equity = self.equity + amount; }

public fun withdraw(self: &mut Venue, amount: u64) { self.equity = self.equity - amount; }

/// Fills a whole-lot order at the oracle plus adverse slippage, charging the taker fee.
///
/// Returns the execution price the adapter proves against the oracle and the
/// whole-lot amount actually filled, at least one lot of any positive order.
public fun fill(self: &mut Venue, base: u64, increase: bool): (u64, u64, u64) {
    assert!(base > 0 && base % self.lot_size == 0);
    let filled = (base.mul_div(self.fill_ratio_bps, BPS) / self.lot_size * self.lot_size).max(self.lot_size);
    let mark = self.notional_of(filled);
    let adverse = mark.mul_div_ceil(self.slippage_bps, BPS);
    let fee = (mark + adverse).mul_div_ceil(self.taker_fee_bps, BPS);

    self.equity = self.equity - adverse - fee;
    self.base = if (increase) { self.base + filled } else { self.base - filled };
    let opens = increase == (self.side == policy::long());
    let executed = if (opens) {
        self.base_price.mul_div(BPS + self.slippage_bps, BPS)
    } else {
        self.base_price.mul_div(BPS - self.slippage_bps, BPS)
    };

    let price_bps = if (opens) { BPS + self.slippage_bps } else { BPS - self.slippage_bps };
    let quote = (filled as u256) * (self.base_price as u256) * (COLLATERAL_UNIT as u256) * (price_bps as u256);
    let denominator = (BASE_UNIT as u256) * (self.collateral_price as u256) * (BPS as u256);
    let actual_notional = quote.div_ceil(denominator) as u64;

    (executed, filled, actual_notional)
}

// --- Vault ---

/// Issues a vault over `venue` with the standard 2x long policy and a wide NAV cap.
public fun issue(self: Venue): Issued {
    let vault_policy = standard_policy(self.side);
    self.issue_with(vault_policy, 5_000_000_000, 1_000_000_000_000)
}

public fun issue_with(self: Venue, vault_policy: VaultPolicy, max_order_notional: u64, nav_cap: u64): Issued {
    let witness = blast_acl::witness_for_testing<VaultIssuer>();
    let issuance = state::issue<Product>(&witness, vault_policy, max_order_notional, nav_cap, BASE_DECIMALS, COLLATERAL_DECIMALS);

    Issued { issuance, venue: self }
}

/// The standard policy: band 1.6x to 2.6x around 2x, 3x hard cap, 1% ordinary and
/// 5% emergency slippage, 10 bps fees, 100-lot minimum orders, reserve at most 10% of notional.
public fun standard_policy(side: PositionSide): VaultPolicy {
    policy::new_vault_policy(
        side,
        policy::new_rebalance_policy(16_000, 20_000, 26_000, 30_000, 100, 500, 10),
        policy::new_price_policy(30_000, 2_000, 100, 500),
        10,
        10,
        100,
        100,
        5_000,
        100,
        1_000,
    )
}

public fun state(self: &Vault): &State<Product> { &self.state }

public fun state_mut(self: &mut Vault): &mut State<Product> { &mut self.state }

public fun venue(self: &Vault): &Venue { &self.venue }

public fun venue_mut(self: &mut Vault): &mut Venue { &mut self.venue }

public fun supply(self: &Vault): u64 { self.supply }

public fun locked(self: &Vault): u64 { self.locked }

public fun admin_cash(self: &Vault): u64 { self.admin_cash }

public fun terminal_cash(self: &Vault): u64 { self.terminal_cash }

public fun reserve(self: &Vault): u64 { self.state.maintenance_reserve() }

public fun last_orders(self: &Vault): u64 { self.last_orders }

/// The stored reserve as the ceiling admits it against the live position.
public fun admitted_reserve(self: &Vault): u64 {
    if (self.venue.base == 0) return self.state.maintenance_reserve();
    self.state.maintenance_reserve().min(self.state.vault_policy_for_testing().reserve_cap(self.venue.notional()))
}

/// Shareholder NAV as the next priced operation would see it: equity less the admitted reserve.
public fun nav(self: &Vault): u64 { self.venue.equity - self.admitted_reserve() }

/// NAV per share scaled by `PRICE_SCALE`, for monotonicity assertions.
public fun nav_per_share(self: &Vault): u128 {
    (self.nav() as u128) * (PRICE_SCALE as u128) / (self.supply as u128)
}

/// Whether the core would open the public trigger on the low side right now.
public fun is_below_band(self: &Vault): bool {
    self.state.vault_policy_for_testing().rebalance_policy().is_leverage_below_band(self.venue.notional(), self.nav())
}

/// Accounting leverage in basis points, rounded up.
public fun leverage_bps(self: &Vault): u64 {
    ((self.venue.notional() as u128) * (BPS as u128)).div_ceil(self.nav() as u128) as u64
}

// --- Activation ---

/// Seeds the account, opens the target position in capped orders, and activates.
///
/// Returns the seed's shareholder NAV; the locked supply is `SEED_SHARE_SCALE` times it.
/// Seeds the venue, opens the target position in capped orders, and activates: the Vault exists from here on.
public fun activate(self: Issued, seed: u64, seed_reserve: u64): Vault {
    let Issued { issuance, mut venue } = self;
    venue.deposit(seed);
    let (mut remaining, max_order_base, seed_position) = issuance.seed_terms(venue.observe(), seed_reserve);

    while (remaining > 0) {
        let (executed, filled, actual_notional) = venue.fill(remaining.min(max_order_base), true);
        issuance.seed_execution_bound().assert_execution(seed_position.base_price(), executed);
        issuance.assert_seed_order_notional_allowed(actual_notional);
        remaining = remaining - filled;
    };
    assert!(seed_position.collateral_price() == venue.collateral_price);

    let (state, seed_nav, _) =
        issuance.activate(venue.observe(), seed_reserve, venue.now_ms);
    let locked = seed_nav * SEED_SHARE_SCALE;

    Vault { state, venue, supply: locked, locked, admin_cash: 0, terminal_cash: 0, last_orders: 0 }
}

// --- Mint ---

/// Deposits cash, executes the sealed proportional or recovery order, and mints shares.
public fun mint(self: &mut Vault, deposit: u64, minimum_shares: u64): u64 {
    assert!(deposit > 0);
    let (fee, admin_fee, reserve_fee) = self.state.fee_allocation_for_testing(deposit, true);
    assert!(fee == admin_fee + reserve_fee);

    let now_at_ms = self.venue.now_ms;
    let plan = self.state.prepare_mint(self.venue.observe(), deposit, self.supply, minimum_shares, self.venue.taker_fee_bps, now_at_ms);
    assert!(plan.admin_fee() == admin_fee);
    let priced = plan.mint_position();
    assert!(priced.lot_size() == self.venue.lot_size);
    let base_price = priced.base_price();

    self.admin_cash = self.admin_cash + plan.admin_fee();
    self.venue.deposit(deposit - plan.admin_fee());

    let mut remaining = plan.base_to_buy();
    let cap_base = self.state.max_order_base(&priced, false);
    let mut orders = 0;
    while (remaining > 0) {
        assert!(orders < MAX_ORDERS, EOrderLimitExceeded);
        let order = remaining.min(cap_base);
        let (executed, filled, actual_notional) = self.venue.fill(order, true);
        self.state.execution_bound().assert_execution(base_price, executed);
        self.state.assert_order_notional_allowed(actual_notional, filled, self.venue.lot_size, false);
        remaining = remaining - filled;
        orders = orders + 1;
    };

    let (shares, _, total_fee, admin, reserve_slice) = self.state.complete_mint(plan, self.venue.observe(), now_at_ms);
    assert!(total_fee == fee && admin == admin_fee && reserve_slice == reserve_fee);
    assert!(self.state.is_within_nav_cap_for_testing(self.venue.equity - self.state.maintenance_reserve()));
    self.supply = self.supply + shares;
    self.last_orders = orders;

    shares
}

// --- Redemption ---

/// Sells the proportional base in capped orders, withdraws the payout, and burns.
public fun redeem(self: &mut Vault, shares: u64, minimum_output: u64): u64 {
    let now_at_ms = self.venue.now_ms;
    let plan = self.state.prepare_redemption(self.venue.observe(), shares, self.supply, minimum_output, now_at_ms);
    let priced = plan.redemption_position();
    assert!(plan.redemption_shares() == shares && priced.lot_size() == self.venue.lot_size);
    let base_price = priced.base_price();

    let mut remaining = plan.base_to_sell();
    let cap_base = self.state.max_order_base(&priced, true);
    let mut orders = 0;
    while (remaining > 0) {
        assert!(orders < MAX_ORDERS, EOrderLimitExceeded);
        let order = remaining.min(cap_base);
        let (executed, filled, actual_notional) = self.venue.fill(order, false);
        self.state.execution_bound().assert_execution(base_price, executed);
        self.state.assert_order_notional_allowed(actual_notional, filled, self.venue.lot_size, true);
        remaining = remaining - filled;
        orders = orders + 1;
    };
    self.last_orders = orders;

    let (net, admin, fee, reserve_slice) = self.state.complete_redemption(plan, self.venue.observe(), now_at_ms);
    assert!(fee == admin + reserve_slice);
    self.venue.withdraw(net + admin);
    self.admin_cash = self.admin_cash + admin;
    self.supply = self.supply - shares;

    net
}

// --- Rebalance ---

/// The keeper's dry run: whether the core would admit a rebalance right now.
public fun needs_rebalance(self: &Vault): bool {
    self.state.needs_rebalance(self.venue.observe(), observation::funding_credit(0), true, self.venue.taker_fee_bps, self.venue.now_ms)
}

/// Runs one complete permissionless rebalance and returns the number of orders it placed.
public fun rebalance(self: &mut Vault): u64 {
    let now_at_ms = self.venue.now_ms;
    let mut plan = self.state.prepare_rebalance(self.venue.observe(), self.venue.taker_fee_bps, now_at_ms);
    let base_price = plan.rebalance_position().base_price();
    let mut orders = 0;
    while (orders < state::max_rebalance_orders()) {
        let order = self.state.next_rebalance_order(&plan);
        if (order.order_base() == 0) break;
        let (executed, filled, actual_notional) = self.venue.fill(order.order_base(), order.is_increase());
        order.bound().assert_execution(base_price, executed);
        self.state.assert_order_notional_allowed(actual_notional, filled, self.venue.lot_size, !order.is_increase());
        self.state.accept_rebalance_fill(&mut plan, order, self.venue.observe(), filled, now_at_ms);
        orders = orders + 1;
    };
    self.state.complete_rebalance(plan);
    self.last_orders = orders;

    orders
}

// --- Funding, Donation, Administration ---

/// The venue charges `cost` of funding; the core settles it against the reserve.
public fun charge_funding(self: &mut Vault, cost: u64): (u64, u64, u64) {
    self.state.assert_can_sync();
    let (absorbed, uncovered, restored) = self.state.settle_funding(observation::funding_cost(cost));
    self.venue.withdraw(cost);

    (absorbed, uncovered, restored)
}

/// The venue pays `credit` of funding; the core settles it into deficit repayment and reserve.
public fun credit_funding(self: &mut Vault, credit: u64): (u64, u64, u64) {
    self.state.assert_can_sync();
    let (absorbed, uncovered, restored) = self.state.settle_funding(observation::funding_credit(credit));
    self.venue.deposit(credit);

    (absorbed, uncovered, restored)
}

public fun donate(self: &mut Vault, amount: u64) {
    self.venue.deposit(amount);
    self.state.donate(self.venue.observe(), amount, self.venue.now_ms);
}

public fun set_fees(self: &mut Vault, mint_bps: u64, redeem_bps: u64, admin_share_bps: u64) {
    self.state.set_fees(mint_bps, redeem_bps, admin_share_bps);
    let (live_mint_bps, live_redeem_bps, live_admin_share_bps) = self.state.fee_settings();
    assert!(live_mint_bps == mint_bps && live_redeem_bps == redeem_bps && live_admin_share_bps == admin_share_bps);
}

public fun set_max_order_notional(self: &mut Vault, max_order_notional: u64) {
    self.state.set_max_order_notional(
        max_order_notional, self.venue.oracle(self.venue.base_price), self.venue.oracle(self.venue.collateral_price),
        self.venue.lot_size, self.venue.now_ms,
    );
    assert!(self.state.max_order_notional_for_testing() == max_order_notional);
}

// --- Shutdown ---

/// Stops ordinary operations, closes the position in capped orders, recovers the cash.
///
/// Returns the terminal cash every eligible share now claims against.
public fun shutdown(self: &mut Vault): u64 {
    self.begin_shutdown();
    while (self.venue.base > 0) { self.unwind(MAX_ORDERS); };

    self.finalize()
}

public fun begin_shutdown(self: &mut Vault) {
    self.state.begin_shutdown(self.venue.now_ms);
    assert!(self.state.is_unwinding_for_testing());
}

/// One unwind transaction: at most `max_orders` close-only orders under the
/// bound the time since shutdown began admits.
public fun unwind(self: &mut Vault, max_orders: u64): u64 {
    self.state.assert_unwinding();
    let now_at_ms = self.venue.now_ms;
    let mut orders = 0;
    while (self.venue.base > 0 && orders < max_orders) {
        let (_, max_order_base, base_price, _, bound) = self.state.unwind_constraints(
            self.venue.oracle(self.venue.base_price), self.venue.oracle(self.venue.collateral_price),
            self.venue.lot_size, now_at_ms,
        );
        let order = self.venue.base.min(max_order_base);
        let (executed, filled, actual_notional) = self.venue.fill(order, false);
        self.state.assert_order_notional_allowed(actual_notional, filled, self.venue.lot_size, true);
        bound.assert_execution(base_price, executed);
        orders = orders + 1;
    };
    self.last_orders = orders;

    orders
}

/// Recovers every atom of venue equity as terminal cash and settles.
public fun finalize(self: &mut Vault): u64 {
    self.state.assert_unwinding();
    let cash = self.venue.equity;
    self.venue.withdraw(cash);
    self.state.finalize_shutdown(self.supply, self.locked, cash);
    self.terminal_cash = cash;

    cash
}

/// Claims `shares` against the terminal cash and burns them.
public fun claim(self: &mut Vault, shares: u64, minimum: u64): u64 {
    self.state.assert_settled();
    let output = self.state.shutdown_claim_quote(self.terminal_cash, self.supply, self.locked, shares, minimum);
    self.terminal_cash = self.terminal_cash - output;
    self.supply = self.supply - shares;

    output
}

// --- Teardown ---

public fun destroy(self: Vault) {
    let Vault { state, venue: _, supply: _, locked: _, admin_cash: _, terminal_cash: _, last_orders: _ } = self;
    state.destroy_for_testing();
}

// === Imports ===

use blast_admin::blast_acl;

use blast_boosts_core::{
    observation::{Self, PositionObservation, PriceObservation},
    policy::{Self, PositionSide, VaultPolicy},
    rebalance_math,
    blast_boosts_core::VaultIssuer,
    state::{Self, Issuance, State},
};
