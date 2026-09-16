#!/usr/bin/env node
// Pins the live Aftermath interfaces consumed by this adapter.
// Uses Node built-ins only and treats every network/local input as untrusted.

import { createHash } from 'node:crypto';
import { readFileSync } from 'node:fs';
import { dirname, join } from 'node:path';
import { fileURLToPath } from 'node:url';
import process from 'node:process';

const ENDPOINT = 'https://graphql.mainnet.sui.io/graphql';
const CHAIN_IDENTIFIER = '4btiuiMPvEENsttpZC7CZ53DruC3MAgfznDbASZ7DR6S';
const AFTERMATH_GIT = 'https://github.com/AftermathFinance/move-interfaces.git';
const AFTERMATH_REV = 'f62e74aa862ef65b8950a70d83aac8cb71c19837';
const SUI_GIT = 'https://github.com/MystenLabs/sui.git';
const SUI_REV = '06734f6ff0af45d8632a14a4dc4b100197f6b1a2';
const STD_ADDRESS = `0x${'0'.repeat(63)}1`;
const SUI_ADDRESS = `0x${'0'.repeat(63)}2`;
const PACKAGE_DIR = join(dirname(fileURLToPath(import.meta.url)), '..');
const ENVIRONMENTS = ['mainnet', 'testnet'];
const REQUEST_TIMEOUT_MS = 30_000;
const REQUEST_ATTEMPTS = 3;

const PACKAGES = [
    {
        label: 'Aftermath perpetuals',
        originalId: '0x3ec740df8428aa9c93aaef7f8cc1542ac3194fd014826b51bfe245346d64efc7',
        currentId: '0x3ec740df8428aa9c93aaef7f8cc1542ac3194fd014826b51bfe245346d64efc7',
        version: 1,
        digest: '2Fa3q1WFk6oNpStaemJFujknbThnnA89GcneuRwAf4vT',
        previousTransaction: 'EwwGij6nQ1R8zHzSTcSsJXpAh45otaGKQNHqCGTM7tFx',
        modules: [
            { name: 'account', sha256: 'e94916287e63c4dbd2c8bb8b4939d306834740e50668eaca1ccc4bf3951ec23e', functions: ['create_account', 'consume_policy_and_share_account', 'deposit_collateral', 'withdraw_collateral', 'account_id', 'collateral_balance'] },
            { name: 'clearing_house', sha256: '56290307f97f6d974b1a4edadd2d62963ac678e76c7b4b3193cbd379c7825eaf', functions: ['allocate_collateral', 'create_market_position', 'set_position_initial_margin_ratio', 'settle_position_funding', 'start_session', 'place_market_order', 'end_session', 'share', 'position', 'market_params', 'market_state', 'market_pause_mode', 'is_frozen', 'filled_base_and_quote', 'base_filled_bid', 'base_filled_ask', 'posted_orders', 'execution_price', 'liquidated_size', 'liquidation_bad_debt', 'mark_price', 'update_funding'] },
            { name: 'market', sha256: '7b48781611318e2fe87686166925780cd0c73517d0f2a474be9d58761c340985', functions: ['lot_size', 'scaling_factor', 'base_storage_id', 'collateral_storage_id', 'base_source_id', 'collateral_source_id', 'margin_ratio_initial', 'margin_ratio_maintenance', 'collateral_haircut', 'cum_funding_rates', 'base_oracle_price', 'collateral_oracle_price', 'calculate_mark_price', 'funding_params', 'funding_last_upd_ms', 'is_time_to_update', 'next_funding_update_time'] },
        ],
    },
    {
        label: 'Aftermath position',
        originalId: '0x9196fffe0341b2f0ca7424926b22d9e9e35b4807a1f625fc20eeea1382d08dec',
        currentId: '0x9196fffe0341b2f0ca7424926b22d9e9e35b4807a1f625fc20eeea1382d08dec',
        version: 1,
        digest: '4xHTNndPFAfEwZHBpY4YdmSs4QYXwM2gKNHKaWyFeVGg',
        previousTransaction: 'CAMhK1PF63EQ9bSRMGriNvyhtM5jTRUsy7YpepMbPwcS',
        modules: [{ name: 'position', sha256: '9dbf0ed53fb6d0628ef821d86d4d63295c6d80efa5e3715735b1dee68bed26e7', functions: ['collateral', 'base_and_quote_amounts', 'pending_base_amounts_by_side', 'pending_order_count', 'funding_rate_snapshots', 'initial_margin_ratio', 'effective_initial_margin_ratio', 'compute_margin_and_requirement', 'is_long_or_flat', 'unrealized_pnl', 'abs_net_base', 'calculate_position_funding_internal'] }],
    },
    {
        label: 'Aftermath authority-cap',
        originalId: '0x4e2df80a5e2fd0392878298c51ce15164222111ccea05504b9291b158f552677',
        currentId: '0x4e2df80a5e2fd0392878298c51ce15164222111ccea05504b9291b158f552677',
        version: 1,
        digest: 'G2NQi5hicFx8HQxRzYWoeCvuwqFxkQr5KJ1pApJsbhB3',
        previousTransaction: 'Ar1jFFDNZpnSsLJSntvvSUBE6RJABDRvHENXRqoyeW45',
        modules: [{ name: 'authority', sha256: 'a8240fd649f5bb1adadc06644795934ac2c4d24a0384872b2aeefc8a84a278f7', functions: ['for'] }],
    },
    {
        label: 'Aftermath oracle-aggregator',
        originalId: '0x9237337d846fc90b0a7acbdee4ab91809298691873d28e1d64d91e6303ff6ba4',
        currentId: '0x9237337d846fc90b0a7acbdee4ab91809298691873d28e1d64d91e6303ff6ba4',
        version: 1,
        digest: '7vcKsEr4mFLgbGzgcVWQbup1mrvx1CVfUni7YbAPVJoZ',
        previousTransaction: '24uiWDWHnZigACZ6n9s5sKUM9PhJxwtcQDXqVUbL3EWf',
        modules: [
            { name: 'price_feed_storage', sha256: 'f9c56ecf9081bb4c4c519eb12350084c34771fd10d76ad52fa7302feb78156c0', functions: ['storage_id', 'price_feed'] },
            { name: 'price_feed', sha256: '6a5dae242c1bb6ff6fb2bf4bb4071990a36688213211c80137d55bd91c893aa8', functions: ['source_id', 'from', 'price_and_timestamp_ms'] },
        ],
    },
    {
        label: 'Aftermath IFixed',
        originalId: '0x4b4703a7581781d74a4c7b0fb0836b2a67f34f1a377fb81aab6f5cad29d78760',
        currentId: '0x4b4703a7581781d74a4c7b0fb0836b2a67f34f1a377fb81aab6f5cad29d78760',
        version: 1,
        digest: 'BX5Yvqhi8d5J866fuzswViwTB6KKxPrxpip9oFFxFjj4',
        previousTransaction: '5G4cZbE56447Dfd5uxL1kP1xDv7u6uCG3t5a5FAks9Zj',
        modules: [{ name: 'ifixed', sha256: 'ab7e23db8976e59a4e63db87c450ab72d70626050094d6a227bfdb11dccb140e', functions: ['decimal_scalar_from_decimals', 'one', 'is_neg', 'abs', 'to_balance'] }],
    },
    {
        label: 'Pyth',
        originalId: '0x8d97f1cd6ac663735be08d1d2b6d02a159e711586461306ce60a2b7a6a565a9e',
        currentId: '0x04e20ddf36af412a4096f9014f4a565af9e812db9a05cc40254846cf6ed0ad91',
        version: 2,
        digest: '4RNrQi2Q86vnviobhgoA3Kj5sgohTbQEsdgqQDGwRY4U',
        previousTransaction: '9aXs2UJPyeQHV8gq15yXHU91LDjaetPvNRZAVonX2TUh',
        modules: [
            { name: 'i64', sha256: 'd5b9c43f407a5f26599dcd809cc0b71c8f358ade0477970ef63dddd4d862bfa3', functions: ['get_is_negative', 'get_magnitude_if_positive', 'get_magnitude_if_negative'] },
            { name: 'price', sha256: '0f304e014ebc52070d84360c1367640d0d20e0adc103820e59abf3b50c711515', functions: ['get_price', 'get_conf', 'get_expo', 'get_timestamp'] },
            { name: 'price_feed', sha256: '0faf8373a5097db4abfac7c76de1ae89110865b1b75eb1eee4b69face9bc6827', functions: ['get_price'] },
            { name: 'price_info', sha256: '8d0d0c64d505cef6fe8db46c80d3d03a70f16405ca0d6da31b6c11105c090fb8', functions: ['uid_to_inner', 'get_price_info_from_price_info_object', 'get_price_feed'] },
        ],
    },
];

// Generated only by --emit after the revision and deployed package have been reviewed.
const ABI = {
    'account::account_id': 'public fun account_id<$0>(&@self::account::Account<$0>): u64',
    'account::collateral_balance': 'public fun collateral_balance<$0>(&@self::account::Account<$0>): u64',
    'account::consume_policy_and_share_account': 'public fun consume_policy_and_share_account<$0>(@self::account::Account<$0>, @self::account::AccountSharePolicy)',
    'account::create_account': 'public fun create_account<$0>(&mut @self::registry::Registry, &mut @sui::tx_context::TxContext): (@self::account::Account<$0>, @self::account::AccountSharePolicy, 0x4e2df80a5e2fd0392878298c51ce15164222111ccea05504b9291b158f552677::authority::AuthorityCap<@self::authority::ACCOUNT, 0x4e2df80a5e2fd0392878298c51ce15164222111ccea05504b9291b158f552677::authority::ADMIN>)',
    'account::deposit_collateral': 'public fun deposit_collateral<$0, $1>(&mut @self::account::Account<$0>, &0x4e2df80a5e2fd0392878298c51ce15164222111ccea05504b9291b158f552677::authority::AuthorityCap<@self::authority::ACCOUNT, $1>, &@self::registry::Registry, @sui::coin::Coin<$0>)',
    'account::withdraw_collateral': 'public fun withdraw_collateral<$0>(&mut @self::account::Account<$0>, &0x4e2df80a5e2fd0392878298c51ce15164222111ccea05504b9291b158f552677::authority::AuthorityCap<@self::authority::ACCOUNT, 0x4e2df80a5e2fd0392878298c51ce15164222111ccea05504b9291b158f552677::authority::ADMIN>, &@self::registry::Registry, u64, &mut @sui::tx_context::TxContext): @sui::coin::Coin<$0>',
    'authority::for': 'public fun for<$0, $1>(&@self::authority::AuthorityCap<$0, $1>): @sui::object::ID',
    'clearing_house::allocate_collateral': 'public fun allocate_collateral<$0, $1>(&mut @self::clearing_house::ClearingHouse<$0>, &0x4e2df80a5e2fd0392878298c51ce15164222111ccea05504b9291b158f552677::authority::AuthorityCap<@self::authority::ACCOUNT, $1>, &mut @self::account::Account<$0>, u64)',
    'clearing_house::base_filled_ask': 'public fun base_filled_ask(&@self::clearing_house::SessionSummary): u256',
    'clearing_house::base_filled_bid': 'public fun base_filled_bid(&@self::clearing_house::SessionSummary): u256',
    'clearing_house::create_market_position': 'public fun create_market_position<$0, $1>(&mut @self::clearing_house::ClearingHouse<$0>, &0x4e2df80a5e2fd0392878298c51ce15164222111ccea05504b9291b158f552677::authority::AuthorityCap<@self::authority::ACCOUNT, $1>, &@self::account::Account<$0>)',
    'clearing_house::end_session': 'public fun end_session<$0, $1>(@self::clearing_house::SessionHotPotato<$0>, &0x4e2df80a5e2fd0392878298c51ce15164222111ccea05504b9291b158f552677::authority::AuthorityCap<@self::authority::ACCOUNT, $1>, &mut @self::account::Account<$0>, bool, bool): (@self::clearing_house::ClearingHouse<$0>, @self::clearing_house::SessionSummary)',
    'clearing_house::execution_price': 'public fun execution_price(&@self::clearing_house::SessionSummary, bool): u256',
    'clearing_house::filled_base_and_quote': 'public fun filled_base_and_quote(&@self::clearing_house::SessionSummary, bool): (u256, u256)',
    'clearing_house::is_frozen': 'public fun is_frozen<$0>(&@self::clearing_house::ClearingHouse<$0>): bool',
    'clearing_house::liquidated_size': 'public fun liquidated_size(&@self::clearing_house::SessionSummary): u64',
    'clearing_house::liquidation_bad_debt': 'public fun liquidation_bad_debt(&@self::clearing_house::SessionSummary): u256',
    'clearing_house::mark_price': 'public fun mark_price<$0>(&@self::clearing_house::ClearingHouse<$0>, &0x9237337d846fc90b0a7acbdee4ab91809298691873d28e1d64d91e6303ff6ba4::price_feed_storage::PriceFeedStorage, &@sui::clock::Clock): u256',
    'clearing_house::market_params': 'public fun market_params<$0>(&@self::clearing_house::ClearingHouse<$0>): &@self::market::MarketParams',
    'clearing_house::market_pause_mode': 'public fun market_pause_mode<$0>(&@self::clearing_house::ClearingHouse<$0>): u8',
    'clearing_house::market_state': 'public fun market_state<$0>(&@self::clearing_house::ClearingHouse<$0>): &@self::market::MarketState',
    'clearing_house::place_market_order': 'public fun place_market_order<$0>(&mut @self::clearing_house::SessionHotPotato<$0>, bool, u64, bool)',
    'clearing_house::posted_orders': 'public fun posted_orders(&@self::clearing_house::SessionSummary): u64',
    'clearing_house::position': 'public fun position<$0>(&@self::clearing_house::ClearingHouse<$0>, u64): &0x9196fffe0341b2f0ca7424926b22d9e9e35b4807a1f625fc20eeea1382d08dec::position::Position',
    'clearing_house::set_position_initial_margin_ratio': 'public fun set_position_initial_margin_ratio<$0, $1>(&mut @self::clearing_house::ClearingHouse<$0>, &0x4e2df80a5e2fd0392878298c51ce15164222111ccea05504b9291b158f552677::authority::AuthorityCap<@self::authority::ACCOUNT, $1>, &@self::account::Account<$0>, u256)',
    'clearing_house::share': 'public fun share<$0>(@self::clearing_house::ClearingHouse<$0>)',
    'clearing_house::settle_position_funding': 'public fun settle_position_funding<$0>(&mut @self::clearing_house::ClearingHouse<$0>, &0x9237337d846fc90b0a7acbdee4ab91809298691873d28e1d64d91e6303ff6ba4::price_feed_storage::PriceFeedStorage, u64, &@sui::clock::Clock)',
    'clearing_house::update_funding': 'public fun update_funding<$0>(&mut @self::clearing_house::ClearingHouse<$0>, &0x9237337d846fc90b0a7acbdee4ab91809298691873d28e1d64d91e6303ff6ba4::price_feed_storage::PriceFeedStorage, &@sui::clock::Clock)',
    'clearing_house::start_session': 'public fun start_session<$0, $1>(@self::clearing_house::ClearingHouse<$0>, &0x4e2df80a5e2fd0392878298c51ce15164222111ccea05504b9291b158f552677::authority::AuthorityCap<@self::authority::ACCOUNT, $1>, &mut @self::account::Account<$0>, &0x9237337d846fc90b0a7acbdee4ab91809298691873d28e1d64d91e6303ff6ba4::price_feed_storage::PriceFeedStorage, &0x9237337d846fc90b0a7acbdee4ab91809298691873d28e1d64d91e6303ff6ba4::price_feed_storage::PriceFeedStorage, @std::option::Option<@self::account::IntegratorInfo>, &@sui::clock::Clock, &@sui::tx_context::TxContext): @self::clearing_house::SessionHotPotato<$0>',
    'ifixed::abs': 'public fun abs(u256): u256',
    'ifixed::decimal_scalar_from_decimals': 'public fun decimal_scalar_from_decimals(u64): u64',
    'ifixed::is_neg': 'public fun is_neg(u256): bool',
    'ifixed::one': 'public fun one(): u256',
    'ifixed::to_balance': 'public fun to_balance(u256, u256): u64',
    'i64::get_is_negative': 'public fun get_is_negative(&@self::i64::I64): bool',
    'i64::get_magnitude_if_negative': 'public fun get_magnitude_if_negative(&@self::i64::I64): u64',
    'i64::get_magnitude_if_positive': 'public fun get_magnitude_if_positive(&@self::i64::I64): u64',
    'market::base_oracle_price': 'public fun base_oracle_price(&@self::market::MarketParams, &0x9237337d846fc90b0a7acbdee4ab91809298691873d28e1d64d91e6303ff6ba4::price_feed_storage::PriceFeedStorage, &@sui::clock::Clock): u256',
    'market::base_source_id': 'public fun base_source_id(&@self::market::MarketParams): u16',
    'market::base_storage_id': 'public fun base_storage_id(&@self::market::MarketParams): u32',
    'market::calculate_mark_price': 'public fun calculate_mark_price(&@self::market::MarketState, &@self::market::MarketParams, u256, u256, u64): u256',
    'market::collateral_oracle_price': 'public fun collateral_oracle_price(&@self::market::MarketParams, &0x9237337d846fc90b0a7acbdee4ab91809298691873d28e1d64d91e6303ff6ba4::price_feed_storage::PriceFeedStorage, &@sui::clock::Clock): u256',
    'market::collateral_haircut': 'public fun collateral_haircut(&@self::market::MarketParams): u256',
    'market::collateral_source_id': 'public fun collateral_source_id(&@self::market::MarketParams): u16',
    'market::collateral_storage_id': 'public fun collateral_storage_id(&@self::market::MarketParams): u32',
    'market::cum_funding_rates': 'public fun cum_funding_rates(&@self::market::MarketState): (u256, u256)',
    'market::funding_last_upd_ms': 'public fun funding_last_upd_ms(&@self::market::MarketState): u64',
    'market::funding_params': 'public fun funding_params(&@self::market::MarketParams): (u64, u64)',
    'market::is_time_to_update': 'public fun is_time_to_update(u64, u64, u64): bool',
    'market::lot_size': 'public fun lot_size(&@self::market::MarketParams): u64',
    'market::margin_ratio_initial': 'public fun margin_ratio_initial(&@self::market::MarketParams): u256',
    'market::margin_ratio_maintenance': 'public fun margin_ratio_maintenance(&@self::market::MarketParams): u256',
    'market::next_funding_update_time': 'public fun next_funding_update_time(u64, u64): u64',
    'market::scaling_factor': 'public fun scaling_factor(&@self::market::MarketParams): u256',
    'position::abs_net_base': 'public fun abs_net_base(&@self::position::Position): u256',
    'position::base_and_quote_amounts': 'public fun base_and_quote_amounts(&@self::position::Position): (u256, u256)',
    'position::calculate_position_funding_internal': 'public fun calculate_position_funding_internal(&@self::position::Position, u256, u256): u256',
    'position::collateral': 'public fun collateral(&@self::position::Position): u256',
    'position::funding_rate_snapshots': 'public fun funding_rate_snapshots(&@self::position::Position): (u256, u256)',
    'position::initial_margin_ratio': 'public fun initial_margin_ratio(&@self::position::Position): u256',
    'position::effective_initial_margin_ratio': 'public fun effective_initial_margin_ratio(&@self::position::Position, u256): u256',
    'position::compute_margin_and_requirement': 'public fun compute_margin_and_requirement(&@self::position::Position, u256, u256, u256, u256): (u256, u256)',
    'position::is_long_or_flat': 'public fun is_long_or_flat(&@self::position::Position): bool',
    'position::pending_base_amounts_by_side': 'public fun pending_base_amounts_by_side(&@self::position::Position): (u256, u256)',
    'position::pending_order_count': 'public fun pending_order_count(&@self::position::Position): u64',
    'position::unrealized_pnl': 'public fun unrealized_pnl(&@self::position::Position, u256): u256',
    'price::get_conf': 'public fun get_conf(&@self::price::Price): u64',
    'price::get_expo': 'public fun get_expo(&@self::price::Price): @self::i64::I64',
    'price::get_price': 'public fun get_price(&@self::price::Price): @self::i64::I64',
    'price::get_timestamp': 'public fun get_timestamp(&@self::price::Price): u64',
    'price_feed::price_and_timestamp_ms': 'public fun price_and_timestamp_ms(&@self::price_feed::PriceFeed): (u128, u64)',
    'price_feed::from': 'public fun from(&@self::price_feed::PriceFeed): @sui::object::ID',
    'price_feed::source_id': 'public fun source_id(&@self::price_feed::PriceFeed): u16',
    'price_feed::get_price': 'public fun get_price(&@self::price_feed::PriceFeed): @self::price::Price',
    'price_feed_storage::price_feed': 'public fun price_feed(&@self::price_feed_storage::PriceFeedStorage, u16): &@self::price_feed::PriceFeed',
    'price_feed_storage::storage_id': 'public fun storage_id(&@self::price_feed_storage::PriceFeedStorage): u32',
    'price_info::get_price_feed': 'public fun get_price_feed(&@self::price_info::PriceInfo): &@self::price_feed::PriceFeed',
    'price_info::get_price_info_from_price_info_object': 'public fun get_price_info_from_price_info_object(&@self::price_info::PriceInfoObject): @self::price_info::PriceInfo',
    'price_info::uid_to_inner': 'public fun uid_to_inner(&@self::price_info::PriceInfoObject): @sui::object::ID',
};

const DIRECT_DEPENDENCIES = {
    blast_admin: { local: '../../admin' },
    blast_leverage_series_one: { local: '../series_one' },
    perpetuals: { git: AFTERMATH_GIT, subdir: 'packages/iperps/perpetuals', rev: AFTERMATH_REV },
    position: { git: AFTERMATH_GIT, subdir: 'packages/iperps/position', rev: AFTERMATH_REV },
    authority_cap: { git: AFTERMATH_GIT, subdir: 'packages/authority-cap/authority-cap', rev: AFTERMATH_REV },
    oracle_aggregator: { git: AFTERMATH_GIT, subdir: 'packages/oracle-aggregator/oracle-aggregator', rev: AFTERMATH_REV },
    ifixed: { git: AFTERMATH_GIT, subdir: 'packages/ifixed/ifixed', rev: AFTERMATH_REV },
    pyth: { local: 'interfaces/pyth' },
};

const LOCK_SOURCES = {
    AftermathControlFlow: { git: AFTERMATH_GIT, subdir: 'packages/control-flow/control-flow', rev: AFTERMATH_REV },
    AftermathOrderedMap: { git: AFTERMATH_GIT, subdir: 'packages/ordered-map/ordered-map', rev: AFTERMATH_REV },
    MoveStdlib: { git: SUI_GIT, subdir: 'crates/sui-framework/packages/move-stdlib', rev: SUI_REV },
    Sui: { git: SUI_GIT, subdir: 'crates/sui-framework/packages/sui-framework', rev: SUI_REV },
    authority_cap: DIRECT_DEPENDENCIES.authority_cap,
    // The immutable shared administration package is a local, inward-only edge:
    // it pins the same framework revision and adds no venue dependency.
    blast_admin: DIRECT_DEPENDENCIES.blast_admin,
    blast_leverage_aftermath: { root: true },
    blast_leverage_series_one: DIRECT_DEPENDENCIES.blast_leverage_series_one,
    ifixed: DIRECT_DEPENDENCIES.ifixed,
    pyth: DIRECT_DEPENDENCIES.pyth,
    oracle_aggregator: DIRECT_DEPENDENCIES.oracle_aggregator,
    perpetuals: DIRECT_DEPENDENCIES.perpetuals,
    position: DIRECT_DEPENDENCIES.position,
    vendor: { git: AFTERMATH_GIT, subdir: 'packages/vendor/vendor', rev: AFTERMATH_REV },
};

const LOCK_DEPS = {
    AftermathControlFlow: { std: 'MoveStdlib', sui: 'Sui' },
    AftermathOrderedMap: { std: 'MoveStdlib', sui: 'Sui' },
    MoveStdlib: {},
    Sui: { MoveStdlib: 'MoveStdlib' },
    authority_cap: { std: 'MoveStdlib', sui: 'Sui' },
    blast_admin: { Sui: 'Sui' },
    blast_leverage_aftermath: { authority_cap: 'authority_cap', blast_admin: 'blast_admin', blast_leverage_series_one: 'blast_leverage_series_one', ifixed: 'ifixed', oracle_aggregator: 'oracle_aggregator', perpetuals: 'perpetuals', position: 'position', pyth: 'pyth', std: 'MoveStdlib', sui: 'Sui' },
    blast_leverage_series_one: { blast_admin: 'blast_admin', std: 'MoveStdlib', sui: 'Sui' },
    ifixed: { std: 'MoveStdlib', sui: 'Sui' },
    pyth: { std: 'MoveStdlib', sui: 'Sui' },
    oracle_aggregator: { authority_cap: 'authority_cap', std: 'MoveStdlib', sui: 'Sui', vendor: 'vendor' },
    perpetuals: { authority_cap: 'authority_cap', control_flow: 'AftermathControlFlow', ifixed: 'ifixed', oracle_aggregator: 'oracle_aggregator', ordered_map: 'AftermathOrderedMap', position: 'position', std: 'MoveStdlib', sui: 'Sui', vendor: 'vendor' },
    position: { control_flow: 'AftermathControlFlow', ifixed: 'ifixed', std: 'MoveStdlib', sui: 'Sui' },
    vendor: { authority_cap: 'authority_cap', std: 'MoveStdlib', sui: 'Sui' },
};

const ABILITY_ORDER = ['copy', 'drop', 'store', 'key'];
const PRIMITIVES = ['bool', 'u8', 'u16', 'u32', 'u64', 'u128', 'u256', 'address', 'signer'];
const VISIBILITY = { PUBLIC: 'public', FRIEND: 'public(package)', PRIVATE: 'private' };

function fail(message) {
    throw new Error(message);
}

function equal(actual, expected, message) {
    if (actual !== expected) fail(`${message}\n    expected: ${expected}\n    actual:   ${actual}`);
}

function expectObject(value, path, keys) {
    if (value === null || typeof value !== 'object' || Array.isArray(value)) {
        fail(`${path}: expected an object, got ${JSON.stringify(value)}`);
    }
    const unexpected = Object.keys(value).filter((key) => !keys.includes(key));
    if (unexpected.length > 0) fail(`${path}: unexpected field(s) ${unexpected.join(', ')}`);
    for (const key of keys) if (!Object.hasOwn(value, key)) fail(`${path}: missing ${key}`);
    return value;
}

function expectString(value, path) {
    if (typeof value !== 'string' || value.length === 0) {
        fail(`${path}: expected a non-empty string, got ${JSON.stringify(value)}`);
    }
    return value;
}

function expectBoolean(value, path) {
    if (typeof value !== 'boolean') fail(`${path}: expected a boolean, got ${JSON.stringify(value)}`);
    return value;
}

function expectInteger(value, path) {
    if (typeof value !== 'number' || !Number.isInteger(value) || value < 0) {
        fail(`${path}: expected a non-negative integer, got ${JSON.stringify(value)}`);
    }
    return value;
}

function expectArray(value, path) {
    if (!Array.isArray(value)) fail(`${path}: expected a list, got ${JSON.stringify(value)}`);
    return value;
}

function normalizeAddress(value, path) {
    const address = expectString(value, path);
    if (!/^0x[0-9a-fA-F]{1,64}$/.test(address)) fail(`${path}: not a Sui address: ${address}`);
    return `0x${address.slice(2).toLowerCase().padStart(64, '0')}`;
}

function renderAbilities(value, path) {
    const abilities = expectArray(value, path).map((ability, index) => {
        const normalized = expectString(ability, `${path}[${index}]`).toLowerCase();
        if (!ABILITY_ORDER.includes(normalized)) fail(`${path}[${index}]: unknown ability ${ability}`);
        return normalized;
    });
    if (new Set(abilities).size !== abilities.length) fail(`${path}: duplicate abilities`);
    return ABILITY_ORDER.filter((ability) => abilities.includes(ability));
}

function renderBody(body, self, path) {
    if (typeof body === 'string') {
        if (!PRIMITIVES.includes(body)) fail(`${path}: unknown primitive type ${body}`);
        return body;
    }
    if (body === null || typeof body !== 'object' || Array.isArray(body)) {
        fail(`${path}: unsupported type body ${JSON.stringify(body)}`);
    }
    const keys = Object.keys(body);
    if (keys.length !== 1) fail(`${path}: expected one type body field, got ${keys.join(', ')}`);
    if (keys[0] === 'typeParameter') return `$${expectInteger(body.typeParameter, `${path}.typeParameter`)}`;
    if (keys[0] === 'vector') return `vector<${renderBody(body.vector, self, `${path}.vector`)}>`;
    if (keys[0] !== 'datatype') fail(`${path}: unsupported type body field ${keys[0]}`);
    const datatype = expectObject(body.datatype, `${path}.datatype`, ['package', 'module', 'type', 'typeParameters']);
    const packageId = normalizeAddress(datatype.package, `${path}.datatype.package`);
    const alias = packageId === self ? '@self' : packageId === SUI_ADDRESS ? '@sui' : packageId === STD_ADDRESS ? '@std' : packageId;
    const args = expectArray(datatype.typeParameters, `${path}.datatype.typeParameters`).map((arg, index) => renderBody(arg, self, `${path}.datatype.typeParameters[${index}]`));
    return `${alias}::${expectString(datatype.module, `${path}.datatype.module`)}::${expectString(datatype.type, `${path}.datatype.type`)}${args.length === 0 ? '' : `<${args.join(', ')}>`}`;
}

function renderType(value, self, path) {
    const wrapper = expectObject(value, path, ['signature']);
    const signature = wrapper.signature;
    if (signature === null || typeof signature !== 'object' || Array.isArray(signature)) {
        fail(`${path}.signature: expected an object, got ${JSON.stringify(signature)}`);
    }
    const unexpected = Object.keys(signature).filter((key) => key !== 'ref' && key !== 'body');
    if (unexpected.length > 0) fail(`${path}.signature: unexpected field(s) ${unexpected.join(', ')}`);
    if (!Object.hasOwn(signature, 'body')) fail(`${path}.signature: missing body`);
    let reference = '';
    if (Object.hasOwn(signature, 'ref')) {
        if (signature.ref === '&') reference = '&';
        else if (signature.ref === '&mut') reference = '&mut ';
        else fail(`${path}.signature.ref: unknown reference kind ${JSON.stringify(signature.ref)}`);
    }
    return `${reference}${renderBody(signature.body, self, `${path}.signature.body`)}`;
}

function renderFunction(name, value, self) {
    const path = `function ${name}`;
    const fn = expectObject(value, path, ['name', 'visibility', 'isEntry', 'typeParameters', 'parameters', 'return']);
    equal(expectString(fn.name, `${path}.name`), name, `${path}.name drift`);
    const visibility = VISIBILITY[expectString(fn.visibility, `${path}.visibility`)];
    if (!visibility) fail(`${path}.visibility: unknown visibility ${fn.visibility}`);
    const generics = expectArray(fn.typeParameters, `${path}.typeParameters`).map((parameter, index) => {
        const item = expectObject(parameter, `${path}.typeParameters[${index}]`, ['constraints']);
        const constraints = renderAbilities(item.constraints, `${path}.typeParameters[${index}].constraints`);
        return `$${index}${constraints.length === 0 ? '' : `: ${constraints.join('+')}`}`;
    });
    const parameters = expectArray(fn.parameters, `${path}.parameters`).map((parameter, index) => renderType(parameter, self, `${path}.parameters[${index}]`));
    const returns = expectArray(fn.return, `${path}.return`).map((item, index) => renderType(item, self, `${path}.return[${index}]`));
    const result = returns.length === 0 ? '' : returns.length === 1 ? `: ${returns[0]}` : `: (${returns.join(', ')})`;
    return `${visibility} ${expectBoolean(fn.isEntry, `${path}.isEntry`) ? 'entry ' : ''}fun ${name}${generics.length === 0 ? '' : `<${generics.join(', ')}>`}(${parameters.join(', ')})${result}`;
}

function stripComment(line, label, lineNumber) {
    let quoted = false;
    for (let index = 0; index < line.length; index += 1) {
        if (line[index] === '\\') fail(`${label}:${lineNumber}: unsupported escape`);
        if (line[index] === '"') quoted = !quoted;
        if (line[index] === '#' && !quoted) return line.slice(0, index);
    }
    if (quoted) fail(`${label}:${lineNumber}: unterminated string`);
    return line;
}

function splitInline(value, label, lineNumber) {
    const entries = [];
    let quoted = false;
    let start = 0;
    for (let index = 0; index < value.length; index += 1) {
        if (value[index] === '"') quoted = !quoted;
        if (value[index] === ',' && !quoted) {
            entries.push(value.slice(start, index).trim());
            start = index + 1;
        }
    }
    if (quoted) fail(`${label}:${lineNumber}: unterminated inline string`);
    entries.push(value.slice(start).trim());
    return entries.filter(Boolean);
}

function parseValue(raw, label, lineNumber) {
    if (/^"[^"\\]*"$/.test(raw)) return raw.slice(1, -1);
    if (/^[0-9]+$/.test(raw)) return Number(raw);
    if (raw === 'true') return true;
    if (raw === 'false') return false;
    if (raw.startsWith('{') && raw.endsWith('}')) {
        const record = new Map();
        for (const entry of splitInline(raw.slice(1, -1), label, lineNumber)) {
            const match = /^([A-Za-z0-9_.-]+)\s*=\s*(.+)$/.exec(entry);
            if (!match) fail(`${label}:${lineNumber}: unsupported inline entry ${entry}`);
            if (record.has(match[1])) fail(`${label}:${lineNumber}: duplicate inline key ${match[1]}`);
            const value = parseValue(match[2].trim(), label, lineNumber);
            if (value instanceof Map) fail(`${label}:${lineNumber}: nested inline tables are unsupported`);
            record.set(match[1], value);
        }
        return record;
    }
    if (raw.startsWith('[') && raw.endsWith(']')) {
        return splitInline(raw.slice(1, -1), label, lineNumber).map((item) => parseValue(item, label, lineNumber));
    }
    fail(`${label}:${lineNumber}: unsupported value ${raw}`);
}

function parseToml(source, label) {
    const tables = new Map();
    let current = null;
    let currentName = null;
    source.split('\n').forEach((raw, index) => {
        const lineNumber = index + 1;
        const line = stripComment(raw, label, lineNumber).trim();
        if (line === '') return;
        const header = /^\[([A-Za-z0-9_.-]+)\]$/.exec(line);
        if (header) {
            if (tables.has(header[1])) fail(`${label}:${lineNumber}: duplicate table [${header[1]}]`);
            currentName = header[1];
            current = new Map();
            tables.set(currentName, current);
            return;
        }
        const match = /^([A-Za-z0-9_.-]+)\s*=\s*(.+?)\s*$/.exec(line);
        if (!match) fail(`${label}:${lineNumber}: unsupported line ${line}`);
        if (current === null) fail(`${label}:${lineNumber}: key outside a table`);
        if (current.has(match[1])) fail(`${label}:${lineNumber}: duplicate key ${match[1]} in [${currentName}]`);
        current.set(match[1], parseValue(match[2], label, lineNumber));
    });
    return tables;
}

function recordString(record) {
    if (!(record instanceof Map)) return JSON.stringify(record);
    return [...record.entries()].sort(([a], [b]) => a.localeCompare(b)).map(([key, value]) => `${key}=${JSON.stringify(value)}`).join(',');
}

function expectedRecordString(record) {
    return Object.entries(record).sort(([a], [b]) => a.localeCompare(b)).map(([key, value]) => `${key}=${JSON.stringify(value)}`).join(',');
}

function assertImmutableGit(label, record) {
    for (const selector of ['branch', 'tag', 'subdir_rev']) {
        if (record.has(selector)) fail(`${label} uses the mutable selector "${selector}"`);
    }
    const rev = record.get('rev');
    if (typeof rev !== 'string' || !/^[0-9a-f]{40}$/.test(rev)) {
        fail(`${label} must pin an immutable 40-hex commit, got ${JSON.stringify(rev)}`);
    }
}

function validateRecord(label, actual, expected) {
    if (!(actual instanceof Map)) fail(`${label} is not a dependency record`);
    if (actual.has('git')) assertImmutableGit(label, actual);
    equal(recordString(actual), expectedRecordString(expected), `${label} dependency record drift`);
}

function validateManifestSource(source) {
    const label = 'Move.toml';
    const tables = parseToml(source, label);
    equal([...tables.keys()].sort().join(','), ['addresses', 'dependencies', 'package'].join(','), `${label}: table set drift`);
    const packageTable = tables.get('package');
    const allowedPackage = ['name', 'version', 'edition', 'license', 'authors', 'published-at'];
    const unknownPackage = [...packageTable.keys()].filter((key) => !allowedPackage.includes(key));
    if (unknownPackage.length > 0) fail(`${label}: unknown [package] key(s) ${unknownPackage.join(', ')}`);
    equal(packageTable.get('name'), 'blast_leverage_aftermath', `${label}: package name drift`);
    equal(packageTable.get('published-at') ?? null, null, `${label}: published-at drift`);
    const dependencies = tables.get('dependencies');
    equal([...dependencies.keys()].sort().join(','), Object.keys(DIRECT_DEPENDENCIES).sort().join(','), `${label}: dependency name set drift`);
    for (const [name, expected] of Object.entries(DIRECT_DEPENDENCIES)) {
        validateRecord(`${label}: ${name}`, dependencies.get(name), expected);
    }
    equal(recordString(tables.get('addresses')), expectedRecordString({ blast_leverage_aftermath: '0x0' }), `${label}: named address drift`);
}

function validateLockSource(source) {
    const label = 'Move.lock';
    const tables = parseToml(source, label);
    equal(tables.get('move')?.get('version'), 4, `${label}: lock format version drift`);
    const expectedNames = Object.keys(LOCK_SOURCES).sort();
    const allowedTables = new Set(['move']);
    for (const environment of ENVIRONMENTS) for (const name of expectedNames) allowedTables.add(`pinned.${environment}.${name}`);
    const unexpected = [...tables.keys()].filter((name) => !allowedTables.has(name));
    if (unexpected.length > 0) fail(`${label}: unexpected pinned node ${unexpected[0]}`);
    for (const environment of ENVIRONMENTS) {
        const prefix = `pinned.${environment}.`;
        const names = [...tables.keys()].filter((name) => name.startsWith(prefix)).map((name) => name.slice(prefix.length)).sort();
        equal(names.join(','), expectedNames.join(','), `${label}: ${environment} pinned node set drift`);
        for (const name of expectedNames) {
            const nodeLabel = `${label}: ${prefix}${name}`;
            const node = tables.get(`${prefix}${name}`);
            equal([...node.keys()].sort().join(','), ['deps', 'manifest_digest', 'source', 'use_environment'].join(','), `${nodeLabel} key set drift`);
            equal(node.get('use_environment'), environment, `${nodeLabel} environment drift`);
            if (!/^[0-9A-F]{64}$/.test(node.get('manifest_digest'))) fail(`${nodeLabel} has malformed manifest_digest`);
            validateRecord(`${nodeLabel} source`, node.get('source'), LOCK_SOURCES[name]);
            const deps = node.get('deps');
            if (!(deps instanceof Map)) fail(`${nodeLabel} deps is not a record`);
            equal(recordString(deps), expectedRecordString(LOCK_DEPS[name]), `${nodeLabel} dependency edge drift`);
        }
    }
}

function validateChainData(data) {
    const root = expectObject(data, 'chain query data', ['chainIdentifier']);
    equal(root.chainIdentifier, CHAIN_IDENTIFIER, `${ENDPOINT} is not Sui mainnet`);
}

function packageQuery() {
    return `query($address: SuiAddress!, $version: UInt53!) {
  latest: package(address: $address) { address version digest previousTransaction { digest } }
  pinned: package(address: $address, version: $version) {
    address version digest previousTransaction { digest }
    packageVersionsAfter(first: 1) { pageInfo { hasNextPage } nodes { address version } }
  }
}`;
}

function moduleQuery(module) {
    const functions = module.functions.map((name, index) => `    f${index}: function(name: "${name}") { name visibility isEntry typeParameters { constraints } parameters { signature } return { signature } }`).join('\n');
    return `query($address: SuiAddress!) {
  package(address: $address) { module(name: "${module.name}") { name bytes
${functions}
  } }
}`;
}

function packageFacts(value, path, later) {
    const keys = later ? ['address', 'version', 'digest', 'previousTransaction', 'packageVersionsAfter'] : ['address', 'version', 'digest', 'previousTransaction'];
    const node = expectObject(value, path, keys);
    const tx = expectObject(node.previousTransaction, `${path}.previousTransaction`, ['digest']);
    return {
        address: normalizeAddress(node.address, `${path}.address`),
        version: expectInteger(node.version, `${path}.version`),
        digest: expectString(node.digest, `${path}.digest`),
        previousTransaction: expectString(tx.digest, `${path}.previousTransaction.digest`),
    };
}

function validatePackageData(expected, data) {
    const root = expectObject(data, `${expected.label} package query data`, ['latest', 'pinned']);
    if (root.latest === null) fail(`${expected.label}: original package id does not resolve`);
    const latest = packageFacts(root.latest, `${expected.label} latest`, false);
    equal(latest.address, expected.currentId, `${expected.label}: current package id drift`);
    equal(latest.version, expected.version, `${expected.label}: package version drift`);
    equal(latest.digest, expected.digest, `${expected.label}: package digest drift`);
    equal(latest.previousTransaction, expected.previousTransaction, `${expected.label}: previous transaction drift`);
    if (root.pinned === null) fail(`${expected.label}: pinned revision ${expected.version} is gone`);
    const pinned = packageFacts(root.pinned, `${expected.label} pinned`, true);
    equal(pinned.address, expected.currentId, `${expected.label}: pinned package id drift`);
    equal(pinned.version, expected.version, `${expected.label}: pinned package version drift`);
    const later = expectObject(root.pinned.packageVersionsAfter, `${expected.label} pinned.packageVersionsAfter`, ['pageInfo', 'nodes']);
    const pageInfo = expectObject(later.pageInfo, `${expected.label} pinned.packageVersionsAfter.pageInfo`, ['hasNextPage']);
    if (expectBoolean(pageInfo.hasNextPage, `${expected.label} pinned.packageVersionsAfter.pageInfo.hasNextPage`) || expectArray(later.nodes, `${expected.label} pinned.packageVersionsAfter.nodes`).length !== 0) {
        fail(`${expected.label}: a later package revision exists beyond v${expected.version}`);
    }
    return latest;
}

function validateModuleData(expected, module, data, emit) {
    const root = expectObject(data, `${expected.label} ${module.name} query data`, ['package']);
    const pkg = expectObject(root.package, `${expected.label} ${module.name}.package`, ['module']);
    if (pkg.module === null) fail(`${expected.label}: module ${module.name} is missing`);
    const keys = ['name', 'bytes', ...module.functions.map((_, index) => `f${index}`)];
    const live = expectObject(pkg.module, `${expected.label} ${module.name}`, keys);
    equal(live.name, module.name, `${expected.label}: module name drift`);
    const bytes = Buffer.from(expectString(live.bytes, `${expected.label} ${module.name}.bytes`), 'base64');
    if (bytes.length < 5 || bytes.readUInt32BE(0) !== 0xa11ceb0b) fail(`${expected.label}: ${module.name} is not Move bytecode`);
    const sha256 = createHash('sha256').update(bytes).digest('hex');
    if (!emit) equal(sha256, module.sha256, `${expected.label}: ${module.name} bytecode drift`);
    const abi = {};
    module.functions.forEach((name, index) => {
        if (live[`f${index}`] === null) fail(`${expected.label}: ${module.name}::${name} is missing`);
        const normalized = renderFunction(name, live[`f${index}`], expected.originalId);
        const key = `${module.name}::${name}`;
        if (!emit) equal(normalized, ABI[key], `${expected.label}: ${key} signature drift`);
        abi[key] = normalized;
    });
    return { sha256, abi };
}

async function graphql(query, variables) {
    let lastError;
    for (let attempt = 1; attempt <= REQUEST_ATTEMPTS; attempt += 1) {
        try {
            const response = await fetch(ENDPOINT, {
                method: 'POST',
                headers: { 'content-type': 'application/json' },
                body: JSON.stringify({ query, variables }),
                signal: AbortSignal.timeout(REQUEST_TIMEOUT_MS),
            });
            const text = await response.text();
            if (response.status >= 500) throw new Error(`HTTP ${response.status}: ${text.slice(0, 200)}`);
            if (!response.ok) fail(`HTTP ${response.status}: ${text.slice(0, 400)}`);
            let body;
            try { body = JSON.parse(text); } catch { fail(`non-JSON GraphQL response: ${text.slice(0, 200)}`); }
            const envelope = expectObject(body, 'GraphQL response', body?.errors === undefined ? ['data'] : ['data', 'errors']);
            if (envelope.errors !== undefined) fail(`GraphQL errors: ${JSON.stringify(envelope.errors)}`);
            return expectObject(envelope.data, 'GraphQL response.data', Object.keys(envelope.data));
        } catch (error) {
            lastError = error;
            if (attempt === REQUEST_ATTEMPTS || !String(error.message).startsWith('HTTP 5')) throw error;
        }
    }
    throw lastError;
}

function goodPackageData(expected) {
    const facts = { address: expected.currentId, version: expected.version, digest: expected.digest, previousTransaction: { digest: expected.previousTransaction } };
    return { latest: structuredClone(facts), pinned: { ...structuredClone(facts), packageVersionsAfter: { pageInfo: { hasNextPage: false }, nodes: [] } } };
}

function goodFunction(name) {
    return { name, visibility: 'PUBLIC', isEntry: false, typeParameters: [], parameters: [], return: [{ signature: { body: 'u64' } }] };
}

function selfTest() {
    const expected = PACKAGES[0];
    const module = { name: 'fixture', sha256: null, functions: ['f'] };
    const bytes = Buffer.alloc(5); bytes.writeUInt32BE(0xa11ceb0b);
    const goodModule = { package: { module: { name: 'fixture', bytes: bytes.toString('base64'), f0: goodFunction('f') } } };
    const tests = [];
    const accept = (name, run) => tests.push({ name, run, message: null });
    const reject = (name, message, run) => tests.push({ name, run, message });
    accept('correct chain identifier', () => validateChainData({ chainIdentifier: CHAIN_IDENTIFIER }));
    reject('wrong original package id', `${expected.label}: original package id does not resolve`, () => validatePackageData(expected, { latest: null, pinned: null }));
    const wrongCurrent = goodPackageData(expected); wrongCurrent.latest.address = `0x${'a'.repeat(64)}`;
    reject('wrong current package id', `${expected.label}: current package id drift\n    expected: ${expected.currentId}\n    actual:   0x${'a'.repeat(64)}`, () => validatePackageData(expected, wrongCurrent));
    const wrongVersion = goodPackageData(expected); wrongVersion.latest.version += 1;
    reject('wrong version', `${expected.label}: package version drift\n    expected: 1\n    actual:   2`, () => validatePackageData(expected, wrongVersion));
    const missing = structuredClone(goodModule); missing.package.module.f0 = null;
    reject('missing function', `${expected.label}: fixture::f is missing`, () => validateModuleData(expected, module, missing, true));
    const changed = structuredClone(goodModule); changed.package.module.f0.return[0].signature.body = 'u128';
    reject('changed function signature', `${expected.label}: fixture::f signature drift\n    expected: public fun f(): u64\n    actual:   public fun f(): u128`, () => {
        const observed = validateModuleData(expected, module, changed, true).abi['fixture::f'];
        equal(observed, 'public fun f(): u64', `${expected.label}: fixture::f signature drift`);
    });
    const publishedAt = `0x${'b'.repeat(64)}`;
    const publishedManifest = readFileSync(join(PACKAGE_DIR, 'Move.toml'), 'utf8').replace(
        '[dependencies]',
        `published-at = "${publishedAt}"\n\n[dependencies]`,
    );
    reject('unexpected published-at', `Move.toml: published-at drift\n    expected: null\n    actual:   ${publishedAt}`, () => validateManifestSource(publishedManifest));
    const manifest = readFileSync(join(PACKAGE_DIR, 'Move.toml'), 'utf8').replace(`rev = "${AFTERMATH_REV}"`, 'rev = "main"');
    reject('mutable Git revision', 'Move.toml: perpetuals must pin an immutable 40-hex commit, got "main"', () => validateManifestSource(manifest));
    const lock = `${readFileSync(join(PACKAGE_DIR, 'Move.lock'), 'utf8')}\n[pinned.mainnet.Rogue]\nsource = { root = true }\nuse_environment = "mainnet"\nmanifest_digest = "${'A'.repeat(64)}"\ndeps = {}\n`;
    reject('unexpected lock node', 'Move.lock: unexpected pinned node pinned.mainnet.Rogue', () => validateLockSource(lock));
    reject('malformed GraphQL response', 'GraphQL response: expected an object, got null', () => expectObject(null, 'GraphQL response', ['data']));
    let passed = 0;
    for (const test of tests) {
        let error = null;
        try { test.run(); } catch (caught) { error = caught; }
        const ok = test.message === null ? error === null : error?.message === test.message;
        if (ok) passed += 1;
        process.stdout.write(`  ${ok ? 'ok  ' : 'FAIL'} ${test.name}${ok ? '' : `: ${error?.message ?? 'accepted unexpectedly'}`}\n`);
    }
    process.stdout.write(`check_mainnet_abi self-test: ${passed === tests.length ? 'PASS' : 'FAIL'} ${passed}/${tests.length} cases\n`);
    process.exit(passed === tests.length ? 0 : 1);
}

function emit(observations) {
    process.stdout.write('const PACKAGE_EVIDENCE = ' + JSON.stringify(observations.map(({ label, currentId, version, digest, previousTransaction, modules }) => ({ label, currentId, version, digest, previousTransaction, modules })), null, 4) + ';\n\n');
    const abi = Object.assign({}, ...observations.map((observation) => observation.abi));
    process.stdout.write('const ABI = ' + JSON.stringify(Object.fromEntries(Object.entries(abi).sort()), null, 4) + ';\n');
}

function printJson(observations) {
    process.stdout.write(`${JSON.stringify({
        schemaVersion: 1,
        chainIdentifier: CHAIN_IDENTIFIER,
        packages: observations.map(({ label, currentId, version, digest, previousTransaction, modules }) => ({
            label,
            currentId,
            version,
            digest,
            previousTransaction,
            modules,
        })),
        functionCount: Object.keys(ABI).length,
    }, null, 2)}\n`);
}

async function main() {
    const args = process.argv.slice(2);
    if (args.some((arg) => !['--self-test', '--emit', '--json'].includes(arg)) || args.length > 1) fail('usage: check_mainnet_abi.mjs [--self-test|--emit|--json]');
    if (args[0] === '--self-test') selfTest();
    validateManifestSource(readFileSync(join(PACKAGE_DIR, 'Move.toml'), 'utf8'));
    validateLockSource(readFileSync(join(PACKAGE_DIR, 'Move.lock'), 'utf8'));
    validateChainData(await graphql('query { chainIdentifier }', {}));
    const observations = [];
    for (const expected of PACKAGES) {
        const facts = validatePackageData(expected, await graphql(packageQuery(), { address: expected.originalId, version: expected.version }));
        const observation = { label: expected.label, currentId: facts.address, version: facts.version, digest: facts.digest, previousTransaction: facts.previousTransaction, modules: {}, abi: {} };
        for (const module of expected.modules) {
            const result = validateModuleData(expected, module, await graphql(moduleQuery(module), { address: expected.currentId }), args[0] === '--emit');
            observation.modules[module.name] = result.sha256;
            Object.assign(observation.abi, result.abi);
        }
        observations.push(observation);
    }
    if (args[0] === '--emit') emit(observations);
    else if (args[0] === '--json') printJson(observations);
    else process.stdout.write(`check_mainnet_abi: PASS ${PACKAGES.length} packages, ${Object.keys(ABI).length} functions\n`);
}

main().catch((error) => {
    process.stderr.write(`check_mainnet_abi: FAIL ${error.message}\n`);
    process.exit(1);
});
