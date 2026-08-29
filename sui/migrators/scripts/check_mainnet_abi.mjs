#!/usr/bin/env node
// Release gate for the Blast aggregate migrators package.
//
// Verifies, against the official Sui mainnet GraphQL endpoint, that every
// external venue package the adapters link to is still the exact immutable
// revision this repository pins, and that the public ABI the adapters consume
// has not drifted. Uses Node built-ins only.
//
// Run `node scripts/check_mainnet_abi.mjs` from `sui/migrators/`.
// Run with `--emit` to print the observed facts as a paste-ready expectation
// block when a reviewed venue upgrade is adopted.

import { createHash } from 'node:crypto';
import { readFileSync } from 'node:fs';
import { dirname, join } from 'node:path';
import { fileURLToPath } from 'node:url';
import process from 'node:process';

// === Constants ===

const ENDPOINT = 'https://graphql.mainnet.sui.io/graphql';

/// Genesis checkpoint digest of Sui mainnet; its first four bytes are 35834a8a.
const CHAIN_IDENTIFIER = '4btiuiMPvEENsttpZC7CZ53DruC3MAgfznDbASZ7DR6S';

const STD_ADDRESS = `0x${'0'.repeat(63)}1`;
const SUI_ADDRESS = `0x${'0'.repeat(63)}2`;

/// The one Sui framework revision every local normalized interface must bind.
const SUI_FRAMEWORK_REV = '06734f6ff0af45d8632a14a4dc4b100197f6b1a2';

const LOCK_ENVIRONMENTS = ['mainnet', 'testnet'];

const ABILITY_ORDER = ['copy', 'drop', 'store', 'key'];

const PACKAGE_DIR = join(dirname(fileURLToPath(import.meta.url)), '..');

// === Expected Packages ===

/// One entry per external package the aggregate migrators package links to.
/// `modules` lists every module that declares an adapter-consumed type or
/// function, with the SHA-256 of its decoded on-chain bytecode.
const PACKAGES = [
    {
        key: 'bluefin',
        label: 'Bluefin Spot',
        addressName: 'bluefin_spot',
        originalId:
            '0x3492c874c1e3b3e2984e8c41b589e642d4d0a5d6459e5a9cfc2d52fd7c89c267',
        currentId:
            '0xd075338d105482f1527cbfd363d6413558f184dec36d9138a70261e87f486e9c',
        version: 17,
        digest: '4tyboYqrPbZzN6V5Lh2TccW8j9nbH65mJeQFynoQGxut',
        previousTransaction: 'CShZDVqJQrXm4SYiCgDe49kKnFzadwhFV5viqHLgRfaX',
        manifest: null,
        modules: [
            {
                name: 'config',
                sha256: 'e896bcbdab23bf5c04eb38b12306f8d6ced8bb9194c789cd1f7f09c78e595cab',
                structs: ['GlobalConfig'],
                functions: ['get_pool_creation_fee_amount', 'get_tick_range'],
            },
            {
                name: 'pool',
                sha256: 'd1436b0837eab8912797b91ed68755ad6e4228243f188a43c42ea040e844e97c',
                structs: ['Pool'],
                functions: ['collect_fee', 'create_pool_with_liquidity'],
            },
            {
                name: 'position',
                sha256: 'ea83d3b9a65c7f62579dd0a902ddad8ade46cec277e5781ab9e52783c48caaec',
                structs: ['Position'],
                functions: ['liquidity', 'pool_id'],
            },
        ],
    },
    {
        key: 'mmt',
        label: 'MMT V3',
        addressName: 'mmt_v3',
        originalId:
            '0x70285592c97965e811e0c6f98dccc3a9c2b4ad854b3594faab9597ada267b860',
        currentId:
            '0xcf60a40f45d46fc1e828871a647c1e25a0915dec860d2662eb10fdb382c3c1d1',
        version: 5,
        digest: '3muHEfy71LYEbjYSuvJ1i8y2XcFJPzctyaTFCkatfEqd',
        previousTransaction: '9ugrBxCA9yLJ4qrRDFoMnHSLbk1bP3N1A7cZ4DKvos5L',
        manifest: null,
        modules: [
            { name: 'collect', sha256: '90e1f0a43280d678fef070be10afd190808cd24330af061d5e291fc51eb62647', structs: [], functions: ['fee'] },
            {
                name: 'create_pool',
                sha256: '1e2d7986ba2c67db9916faf028b65376db99e5f956dc735ed432b1661572f1ad',
                structs: [],
                functions: ['check_coin_order', 'new'],
            },
            {
                name: 'global_config',
                sha256: '7d017415c735d25cdca6c3ba3c0351a047a9d25bcb6dc6fe0bab80b3971619b6',
                structs: ['GlobalConfig'],
                functions: [],
            },
            { name: 'i32', sha256: 'a497795e96c4eeff5558b945926b2a97229d691d30452340f989d441128ded72', structs: ['I32'], functions: ['as_u32'] },
            {
                name: 'liquidity',
                sha256: '3c9b457444c43b8ebea2f1ba3daf9a370400d9ad3149654ea11123d3e9447bdb',
                structs: [],
                functions: ['add_liquidity', 'open_position'],
            },
            {
                name: 'pool',
                sha256: '0b1a2e676c909d3cac300d644c05b470418bd7b630ff57e14fab23afe15f002a',
                structs: ['Pool'],
                functions: [
                    'get_friendly_ticks',
                    'initialize',
                    'tick_spacing',
                    'transfer',
                ],
            },
            {
                name: 'position',
                sha256: '7cceacd04adbe6a9955df17b2ca1738a77b27e9a4a681f5ce3621d1a92083a24',
                structs: ['Position'],
                functions: ['liquidity', 'pool_id'],
            },
            {
                name: 'tick_math',
                sha256: 'cb44cb32351dc86766ad76c433faad6a4fd20e97ce51c6bb5a1c68502ac59939',
                structs: [],
                functions: ['max_sqrt_price', 'min_sqrt_price'],
            },
            { name: 'version', sha256: '65ee05b54cbd66c35a20498b758990ba0c154ac1dd489037a6af81eea82ffba1', structs: ['Version'], functions: [] },
        ],
    },
    {
        key: 'cetus',
        label: 'Cetus CLMM',
        addressName: 'cetus_clmm',
        originalId:
            '0x1eabed72c53feb3805120a081dc15963c204dc8d091542592abaf7a35689b2fb',
        currentId:
            '0x25ebb9a7c50eb17b3fa9c5a30fb8b5ad8f97caaf4928943acbcff7153dfee5e3',
        version: 14,
        digest: 'FEdn2yRh28atu7tANr6gCWQ3gtDSD2EZmyEeryTuokoi',
        previousTransaction: '9feeN5tyxKLPPt1nRERtddp8xzxMVefNufkhxWAT1Jja',
        manifest: 'interfaces/cetus/Move.toml',
        modules: [
            {
                name: 'config',
                sha256: '8a1610d8e4f02ae48dcf0594f3553f26a6503721c00c3b775c9a1d7bdfa26016',
                structs: ['GlobalConfig'],
                functions: ['get_fee_rate'],
            },
            {
                name: 'factory',
                sha256: '324c4e4ef1fdd079f22b2088cabe8cae86772ceae87c5873b3d636a92fe06e68',
                structs: ['Pools'],
                functions: ['is_right_order', 'new_pool_key'],
            },
            {
                name: 'pool',
                sha256: 'aba0e2edaa3769e752a44acf314e8ac10850129e1cc7732ed93a6d4e2b9f35b5',
                structs: ['AddLiquidityReceipt', 'Pool'],
                functions: [
                    'add_liquidity_fix_coin',
                    'add_liquidity_pay_amount',
                    'collect_fee',
                    'current_sqrt_price',
                    'fee_rate',
                    'open_position',
                    'repay_add_liquidity',
                    'tick_spacing',
                ],
            },
            {
                name: 'pool_creator',
                sha256: 'bd52696c635f93ef334818763a1c7f4a4cefc77851e18af3e8b1bf463041d38c',
                structs: [],
                functions: ['create_pool_v3', 'full_range_tick_range'],
            },
            {
                name: 'position',
                sha256: '3719452b1462b1b8dd59877eed3bb188bd3d154a10def3026ad3252f660947da',
                structs: ['Position'],
                functions: ['liquidity', 'pool_id'],
            },
        ],
    },
    {
        key: 'turbos',
        label: 'Turbos CLMM',
        addressName: 'turbos_clmm',
        originalId:
            '0x91bfbc386a41afcfd9b2533058d7e915a1d3829089cc268ff4333d54d6339ca1',
        currentId:
            '0xa5a0c25c79e428eba04fb98b3fb2a34db45ab26d4c8faf0d7e39d66a63891e64',
        version: 22,
        digest: 'FxTpAy2BbjFLWXF2Ddd4pmiBizrU27us4CwNHo9DtzVn',
        previousTransaction: '4iZ5nMJbgU6VtoDXg8TsuAEg6K6y4zovDgcMqxNn4diS',
        manifest: 'interfaces/turbos/Move.toml',
        modules: [
            {
                name: 'fee',
                sha256: '0113ca7935faf508e936f6d74dfa6fa62c967f8f414572a9327b44c887a65141',
                structs: ['Fee'],
                functions: ['get_fee', 'get_tick_spacing'],
            },
            {
                name: 'i32',
                sha256: 'c2b649feed67ef880be3ae6fac1c729d7e65f9bcc03be74e1d2243968d968680',
                structs: ['I32'],
                functions: ['abs_u32', 'is_neg'],
            },
            {
                name: 'math_tick',
                sha256: '78a692af161feb4dedc3e0bd281f9fb792b83e022d5a1cc06a92168585263bcb',
                structs: [],
                functions: ['get_max_tick', 'get_min_tick'],
            },
            {
                name: 'pool',
                sha256: '4a44d2dc2f0920d1253a20c5cd1471d5f3a0d03c1812781b816d372789728d36',
                structs: ['Pool', 'Versioned'],
                functions: [
                    'get_pool_fee',
                    'get_pool_sqrt_price',
                    'get_pool_tick_spacing',
                ],
            },
            {
                name: 'pool_factory',
                sha256: 'ea8ef02d0fd0700daa020ba37360ad6a8f8dc8067af3ee99052b530494a53fef',
                structs: ['PoolConfig'],
                functions: ['deploy_pool_and_mint_with_return_'],
            },
            {
                name: 'position_manager',
                sha256: 'badc1be2ee1ba12fb56eb8332f412a58ba279b80f85144862656ceea6c0fa5fe',
                structs: ['Positions'],
                functions: [
                    'collect_with_return_',
                    'get_position_info',
                    'mint_with_return_',
                ],
            },
            {
                name: 'position_nft',
                sha256: '1c9264b0145915da01c3a072876ffbd753d5697b56d5f2bedb79d92136d3cbea',
                structs: ['TurbosPositionNFT'],
                functions: ['pool_id'],
            },
        ],
    },
    {
        key: 'fullsail',
        label: 'Full Sail CLMM',
        addressName: 'clmm_pool',
        originalId:
            '0xe74104c66dd9f16b3096db2cc00300e556aa92edc871be4bc052b5dfb80db239',
        currentId:
            '0x497a144ba3d93ae44d9fd23d4ff4761c329d87a505136d2269c743b2297fa881',
        version: 4,
        digest: 'CWkTsBks7SsYsvDQ9QQxkHqgDAKdvuDkh4DAd9DHo3nF',
        previousTransaction: '3rbk2g4FuuqFGKBLyNYLkqJjv2XKvgnSans6EpPaRCSd',
        manifest: 'interfaces/fullsail/Move.toml',
        modules: [
            {
                name: 'config',
                sha256: 'fa727813c54f77a7c16c4a76d334a5f5477bd785685b3d6539de85fde49de5be',
                structs: ['GlobalConfig'],
                functions: ['get_fee_rate'],
            },
            {
                name: 'factory',
                sha256: 'b13f70d07a91f192045152a367a073b06b520cc71458e3e78ce7b2e82e5f2906',
                structs: ['Pools'],
                functions: ['create_pool_with_liquidity', 'new_pool_key'],
            },
            {
                name: 'pool',
                sha256: '3332e1a5db68034668dd36acf3b63dd0545d0fc193f251af192842d91b91be59',
                structs: ['AddLiquidityReceipt', 'Pool'],
                functions: [
                    'add_liquidity_fix_coin',
                    'add_liquidity_pay_amount',
                    'collect_fee',
                    'current_sqrt_price',
                    'fee_rate',
                    'open_position',
                    'repay_add_liquidity',
                    'tick_spacing',
                ],
            },
            {
                name: 'position',
                sha256: '4d61ff120ba2988afc2dc8c1729ccccb0541adf7e0b0864da09e227ce8301f99',
                structs: ['Position'],
                functions: ['liquidity', 'pool_id'],
            },
            {
                name: 'rewarder',
                sha256: '8aec3da2ff2194faf69df8e2e033505dc5a464601514a790075c43ee0aedfe07',
                structs: ['RewarderGlobalVault'],
                functions: [],
            },
            {
                name: 'tick_math',
                sha256: '25c2ea22ad657e05c8949c5767efcc7b6b8b33e014f2f5999d185d70a7ebaad4',
                structs: [],
                functions: ['max_tick', 'min_tick'],
            },
        ],
    },
    {
        key: 'fullsail_integer_mate',
        label: 'Full Sail IntegerMate',
        addressName: 'fullsail_integer_mate',
        originalId:
            '0x6b904ae739b2baad330aae14991abcd3b7354d3dc3db72507ed8dabeeb7a36de',
        currentId:
            '0x6b904ae739b2baad330aae14991abcd3b7354d3dc3db72507ed8dabeeb7a36de',
        version: 1,
        digest: 'sJBBNfgrAEwYvUxzbM8y7yHYdHTE5no2Urg4B3eJR1s',
        previousTransaction: 'CWQ5cMDkAGu6o8nCWDix25KGpnBXRLt2bZdVchacjRVN',
        manifest: 'interfaces/fullsail_integer_mate/Move.toml',
        modules: [
            {
                name: 'i32',
                sha256: '9be3bdeba386cf882d90603fa8decbe8a477e5a5d39341bbc940577b4393412f',
                structs: ['I32'],
                functions: ['abs_u32', 'as_u32', 'neg_from'],
            },
        ],
    },
];

/// Normalized public ABI every adapter call site depends on. `@self` is the
/// package's own original address, `@sui` and `@std` are the framework
/// addresses; every other address is compared literally.
const ABI = {
    'bluefin_spot::config::GlobalConfig':
        'struct GlobalConfig has store, key',
    'bluefin_spot::config::get_pool_creation_fee_amount':
        'public fun get_pool_creation_fee_amount<$0>(&@self::config::GlobalConfig): (bool, u64)',
    'bluefin_spot::config::get_tick_range':
        'public fun get_tick_range(&@self::config::GlobalConfig): (0x714a63a0dba6da4f017b42d5d0fb78867f18bcde904868e51d951a5a6f5b7f57::i32::I32, 0x714a63a0dba6da4f017b42d5d0fb78867f18bcde904868e51d951a5a6f5b7f57::i32::I32)',
    'bluefin_spot::pool::Pool':
        'struct Pool<phantom $0, phantom $1> has store, key',
    'bluefin_spot::pool::collect_fee':
        'public fun collect_fee<$0, $1>(&@sui::clock::Clock, &@self::config::GlobalConfig, &mut @self::pool::Pool<$0, $1>, &mut @self::position::Position): (u64, u64, @sui::balance::Balance<$0>, @sui::balance::Balance<$1>)',
    'bluefin_spot::pool::create_pool_with_liquidity':
        'public fun create_pool_with_liquidity<$0, $1, $2>(&@sui::clock::Clock, &mut @self::config::GlobalConfig, vector<u8>, vector<u8>, vector<u8>, u8, vector<u8>, vector<u8>, u8, vector<u8>, u32, u64, u128, @sui::balance::Balance<$2>, u32, u32, @sui::balance::Balance<$0>, @sui::balance::Balance<$1>, u64, bool, &mut @sui::tx_context::TxContext): (@sui::object::ID, @self::position::Position, u64, u64, @sui::balance::Balance<$0>, @sui::balance::Balance<$1>)',
    'bluefin_spot::position::Position':
        'struct Position has store, key',
    'bluefin_spot::position::liquidity':
        'public fun liquidity(&@self::position::Position): u128',
    'bluefin_spot::position::pool_id':
        'public fun pool_id(&@self::position::Position): @sui::object::ID',
    'mmt_v3::collect::fee':
        'public fun fee<$0, $1>(&mut @self::pool::Pool<$0, $1>, &mut @self::position::Position, &@sui::clock::Clock, &@self::version::Version, &mut @sui::tx_context::TxContext): (@sui::coin::Coin<$0>, @sui::coin::Coin<$1>)',
    'mmt_v3::create_pool::check_coin_order':
        'public fun check_coin_order<$0, $1>(): bool',
    'mmt_v3::create_pool::new':
        'public fun new<$0, $1>(&mut @self::global_config::GlobalConfig, u64, &@self::version::Version, &mut @sui::tx_context::TxContext): @self::pool::Pool<$0, $1>',
    'mmt_v3::global_config::GlobalConfig':
        'struct GlobalConfig has store, key',
    'mmt_v3::i32::I32':
        'struct I32 has copy, drop, store',
    'mmt_v3::i32::as_u32':
        'public fun as_u32(@self::i32::I32): u32',
    'mmt_v3::liquidity::add_liquidity':
        'public fun add_liquidity<$0, $1>(&mut @self::pool::Pool<$0, $1>, &mut @self::position::Position, @sui::coin::Coin<$0>, @sui::coin::Coin<$1>, u64, u64, &@sui::clock::Clock, &@self::version::Version, &mut @sui::tx_context::TxContext): (@sui::coin::Coin<$0>, @sui::coin::Coin<$1>)',
    'mmt_v3::liquidity::open_position':
        'public fun open_position<$0, $1>(&mut @self::pool::Pool<$0, $1>, @self::i32::I32, @self::i32::I32, &@self::version::Version, &mut @sui::tx_context::TxContext): @self::position::Position',
    'mmt_v3::pool::Pool':
        'struct Pool<phantom $0, phantom $1> has key',
    'mmt_v3::pool::get_friendly_ticks':
        'public fun get_friendly_ticks<$0, $1>(&@self::pool::Pool<$0, $1>, u128, u128): (@self::i32::I32, @self::i32::I32)',
    'mmt_v3::pool::initialize':
        'public fun initialize<$0, $1>(&mut @self::pool::Pool<$0, $1>, u128, &@sui::clock::Clock)',
    'mmt_v3::pool::tick_spacing':
        'public fun tick_spacing<$0, $1>(&@self::pool::Pool<$0, $1>): u32',
    'mmt_v3::pool::transfer':
        'public fun transfer<$0, $1>(@self::pool::Pool<$0, $1>)',
    'mmt_v3::position::Position':
        'struct Position has store, key',
    'mmt_v3::position::liquidity':
        'public fun liquidity(&@self::position::Position): u128',
    'mmt_v3::position::pool_id':
        'public fun pool_id(&@self::position::Position): @sui::object::ID',
    'mmt_v3::tick_math::max_sqrt_price':
        'public fun max_sqrt_price(): u128',
    'mmt_v3::tick_math::min_sqrt_price':
        'public fun min_sqrt_price(): u128',
    'mmt_v3::version::Version':
        'struct Version has store, key',
    'cetus_clmm::config::GlobalConfig':
        'struct GlobalConfig has store, key',
    'cetus_clmm::config::get_fee_rate':
        'public fun get_fee_rate(u32, &@self::config::GlobalConfig): u64',
    'cetus_clmm::factory::Pools':
        'struct Pools has store, key',
    'cetus_clmm::factory::is_right_order':
        'public fun is_right_order<$0, $1>(): bool',
    'cetus_clmm::factory::new_pool_key':
        'public fun new_pool_key<$0, $1>(u32): @sui::object::ID',
    'cetus_clmm::pool::AddLiquidityReceipt':
        'struct AddLiquidityReceipt<phantom $0, phantom $1>',
    'cetus_clmm::pool::Pool':
        'struct Pool<phantom $0, phantom $1> has store, key',
    'cetus_clmm::pool::add_liquidity_fix_coin':
        'public fun add_liquidity_fix_coin<$0, $1>(&@self::config::GlobalConfig, &mut @self::pool::Pool<$0, $1>, &mut @self::position::Position, u64, bool, &@sui::clock::Clock): @self::pool::AddLiquidityReceipt<$0, $1>',
    'cetus_clmm::pool::add_liquidity_pay_amount':
        'public fun add_liquidity_pay_amount<$0, $1>(&@self::pool::AddLiquidityReceipt<$0, $1>): (u64, u64)',
    'cetus_clmm::pool::collect_fee':
        'public fun collect_fee<$0, $1>(&@self::config::GlobalConfig, &mut @self::pool::Pool<$0, $1>, &@self::position::Position, bool): (@sui::balance::Balance<$0>, @sui::balance::Balance<$1>)',
    'cetus_clmm::pool::current_sqrt_price':
        'public fun current_sqrt_price<$0, $1>(&@self::pool::Pool<$0, $1>): u128',
    'cetus_clmm::pool::fee_rate':
        'public fun fee_rate<$0, $1>(&@self::pool::Pool<$0, $1>): u64',
    'cetus_clmm::pool::open_position':
        'public fun open_position<$0, $1>(&@self::config::GlobalConfig, &mut @self::pool::Pool<$0, $1>, u32, u32, &mut @sui::tx_context::TxContext): @self::position::Position',
    'cetus_clmm::pool::repay_add_liquidity':
        'public fun repay_add_liquidity<$0, $1>(&@self::config::GlobalConfig, &mut @self::pool::Pool<$0, $1>, @sui::balance::Balance<$0>, @sui::balance::Balance<$1>, @self::pool::AddLiquidityReceipt<$0, $1>)',
    'cetus_clmm::pool::tick_spacing':
        'public fun tick_spacing<$0, $1>(&@self::pool::Pool<$0, $1>): u32',
    'cetus_clmm::pool_creator::create_pool_v3':
        'public fun create_pool_v3<$0, $1>(&@self::config::GlobalConfig, &mut @self::factory::Pools, u32, u128, @std::string::String, u32, u32, @sui::coin::Coin<$0>, @sui::coin::Coin<$1>, bool, &@sui::clock::Clock, &mut @sui::tx_context::TxContext): (@self::position::Position, @sui::coin::Coin<$0>, @sui::coin::Coin<$1>)',
    'cetus_clmm::pool_creator::full_range_tick_range':
        'public fun full_range_tick_range(u32): (u32, u32)',
    'cetus_clmm::position::Position':
        'struct Position has store, key',
    'cetus_clmm::position::liquidity':
        'public fun liquidity(&@self::position::Position): u128',
    'cetus_clmm::position::pool_id':
        'public fun pool_id(&@self::position::Position): @sui::object::ID',
    'turbos_clmm::fee::Fee':
        'struct Fee<phantom $0> has store, key',
    'turbos_clmm::fee::get_fee':
        'public fun get_fee<$0>(&@self::fee::Fee<$0>): u32',
    'turbos_clmm::fee::get_tick_spacing':
        'public fun get_tick_spacing<$0>(&@self::fee::Fee<$0>): u32',
    'turbos_clmm::i32::I32':
        'struct I32 has copy, drop, store',
    'turbos_clmm::i32::abs_u32':
        'public fun abs_u32(@self::i32::I32): u32',
    'turbos_clmm::i32::is_neg':
        'public fun is_neg(@self::i32::I32): bool',
    'turbos_clmm::math_tick::get_max_tick':
        'public fun get_max_tick(u32): @self::i32::I32',
    'turbos_clmm::math_tick::get_min_tick':
        'public fun get_min_tick(u32): @self::i32::I32',
    'turbos_clmm::pool::Pool':
        'struct Pool<phantom $0, phantom $1, phantom $2> has store, key',
    'turbos_clmm::pool::Versioned':
        'struct Versioned has store, key',
    'turbos_clmm::pool::get_pool_fee':
        'public fun get_pool_fee<$0, $1, $2>(&@self::pool::Pool<$0, $1, $2>): u32',
    'turbos_clmm::pool::get_pool_sqrt_price':
        'public fun get_pool_sqrt_price<$0, $1, $2>(&@self::pool::Pool<$0, $1, $2>): u128',
    'turbos_clmm::pool::get_pool_tick_spacing':
        'public fun get_pool_tick_spacing<$0, $1, $2>(&@self::pool::Pool<$0, $1, $2>): u32',
    'turbos_clmm::pool_factory::PoolConfig':
        'struct PoolConfig has store, key',
    'turbos_clmm::pool_factory::deploy_pool_and_mint_with_return_':
        'public fun deploy_pool_and_mint_with_return_<$0, $1, $2>(&mut @self::pool_factory::PoolConfig, &@self::fee::Fee<$2>, u128, &mut @self::position_manager::Positions, vector<@sui::coin::Coin<$0>>, vector<@sui::coin::Coin<$1>>, u32, bool, u32, bool, u64, u64, u64, u64, u64, &@sui::clock::Clock, &@self::pool::Versioned, &mut @sui::tx_context::TxContext): (@self::position_nft::TurbosPositionNFT, @sui::coin::Coin<$0>, @sui::coin::Coin<$1>, @sui::object::ID)',
    'turbos_clmm::position_manager::Positions':
        'struct Positions has store, key',
    'turbos_clmm::position_manager::collect_with_return_':
        'public fun collect_with_return_<$0, $1, $2>(&mut @self::pool::Pool<$0, $1, $2>, &mut @self::position_manager::Positions, &mut @self::position_nft::TurbosPositionNFT, u64, u64, address, u64, &@sui::clock::Clock, &@self::pool::Versioned, &mut @sui::tx_context::TxContext): (@sui::coin::Coin<$0>, @sui::coin::Coin<$1>)',
    'turbos_clmm::position_manager::get_position_info':
        'public fun get_position_info(&@self::position_manager::Positions, address): (@self::i32::I32, @self::i32::I32, u128)',
    'turbos_clmm::position_manager::mint_with_return_':
        'public fun mint_with_return_<$0, $1, $2>(&mut @self::pool::Pool<$0, $1, $2>, &mut @self::position_manager::Positions, vector<@sui::coin::Coin<$0>>, vector<@sui::coin::Coin<$1>>, u32, bool, u32, bool, u64, u64, u64, u64, u64, &@sui::clock::Clock, &@self::pool::Versioned, &mut @sui::tx_context::TxContext): (@self::position_nft::TurbosPositionNFT, @sui::coin::Coin<$0>, @sui::coin::Coin<$1>)',
    'turbos_clmm::position_nft::TurbosPositionNFT':
        'struct TurbosPositionNFT has store, key',
    'turbos_clmm::position_nft::pool_id':
        'public fun pool_id(&@self::position_nft::TurbosPositionNFT): @sui::object::ID',
    'clmm_pool::config::GlobalConfig':
        'struct GlobalConfig has store, key',
    'clmm_pool::config::get_fee_rate':
        'public fun get_fee_rate(u32, &@self::config::GlobalConfig): u64',
    'clmm_pool::factory::Pools':
        'struct Pools has store, key',
    'clmm_pool::factory::create_pool_with_liquidity':
        'public fun create_pool_with_liquidity<$0, $1>(&mut @self::factory::Pools, &@self::config::GlobalConfig, &mut @self::rewarder::RewarderGlobalVault, u32, u128, @std::string::String, u32, u32, @sui::coin::Coin<$0>, @sui::coin::Coin<$1>, u64, u64, bool, address, address, bool, &@sui::clock::Clock, &mut @sui::tx_context::TxContext): (@self::position::Position, @sui::coin::Coin<$0>, @sui::coin::Coin<$1>)',
    'clmm_pool::factory::new_pool_key':
        'public fun new_pool_key<$0, $1>(u32): @sui::object::ID',
    'clmm_pool::pool::AddLiquidityReceipt':
        'struct AddLiquidityReceipt<phantom $0, phantom $1>',
    'clmm_pool::pool::Pool':
        'struct Pool<phantom $0, phantom $1> has store, key',
    'clmm_pool::pool::add_liquidity_fix_coin':
        'public fun add_liquidity_fix_coin<$0, $1>(&@self::config::GlobalConfig, &mut @self::rewarder::RewarderGlobalVault, &mut @self::pool::Pool<$0, $1>, &mut @self::position::Position, u64, bool, &@sui::clock::Clock): @self::pool::AddLiquidityReceipt<$0, $1>',
    'clmm_pool::pool::add_liquidity_pay_amount':
        'public fun add_liquidity_pay_amount<$0, $1>(&@self::pool::AddLiquidityReceipt<$0, $1>): (u64, u64)',
    'clmm_pool::pool::collect_fee':
        'public fun collect_fee<$0, $1>(&@self::config::GlobalConfig, &mut @self::pool::Pool<$0, $1>, &@self::position::Position, bool): (@sui::balance::Balance<$0>, @sui::balance::Balance<$1>)',
    'clmm_pool::pool::current_sqrt_price':
        'public fun current_sqrt_price<$0, $1>(&@self::pool::Pool<$0, $1>): u128',
    'clmm_pool::pool::fee_rate':
        'public fun fee_rate<$0, $1>(&@self::pool::Pool<$0, $1>): u64',
    'clmm_pool::pool::open_position':
        'public fun open_position<$0, $1>(&@self::config::GlobalConfig, &mut @self::pool::Pool<$0, $1>, u32, u32, &mut @sui::tx_context::TxContext): @self::position::Position',
    'clmm_pool::pool::repay_add_liquidity':
        'public fun repay_add_liquidity<$0, $1>(&@self::config::GlobalConfig, &mut @self::pool::Pool<$0, $1>, @sui::balance::Balance<$0>, @sui::balance::Balance<$1>, @self::pool::AddLiquidityReceipt<$0, $1>)',
    'clmm_pool::pool::tick_spacing':
        'public fun tick_spacing<$0, $1>(&@self::pool::Pool<$0, $1>): u32',
    'clmm_pool::position::Position':
        'struct Position has store, key',
    'clmm_pool::position::liquidity':
        'public fun liquidity(&@self::position::Position): u128',
    'clmm_pool::position::pool_id':
        'public fun pool_id(&@self::position::Position): @sui::object::ID',
    'clmm_pool::rewarder::RewarderGlobalVault':
        'struct RewarderGlobalVault has store, key',
    'clmm_pool::tick_math::max_tick':
        'public fun max_tick(): 0x6b904ae739b2baad330aae14991abcd3b7354d3dc3db72507ed8dabeeb7a36de::i32::I32',
    'clmm_pool::tick_math::min_tick':
        'public fun min_tick(): 0x6b904ae739b2baad330aae14991abcd3b7354d3dc3db72507ed8dabeeb7a36de::i32::I32',
    'fullsail_integer_mate::i32::I32':
        'struct I32 has copy, drop, store',
    'fullsail_integer_mate::i32::abs_u32':
        'public fun abs_u32(@self::i32::I32): u32',
    'fullsail_integer_mate::i32::as_u32':
        'public fun as_u32(@self::i32::I32): u32',
    'fullsail_integer_mate::i32::neg_from':
        'public fun neg_from(u32): @self::i32::I32',
};

// === Failures ===

const failures = [];

function check(ok, message) {
    if (!ok) failures.push(message);
    return ok;
}

function checkEqual(actual, expected, message) {
    return check(
        actual === expected,
        `${message}\n    expected: ${expected}\n    actual:   ${actual}`,
    );
}

// === GraphQL ===

async function graphql(query, variables) {
    let lastError;
    for (let attempt = 1; attempt <= 3; attempt += 1) {
        let response;
        try {
            response = await fetch(ENDPOINT, {
                method: 'POST',
                headers: { 'content-type': 'application/json' },
                body: JSON.stringify({ query, variables }),
            });
        } catch (error) {
            lastError = error;
            await new Promise((resolve) => setTimeout(resolve, 500 * attempt));
            continue;
        }

        const text = await response.text();
        if (response.status >= 500) {
            lastError = new Error(`HTTP ${response.status}: ${text.slice(0, 200)}`);
            await new Promise((resolve) => setTimeout(resolve, 500 * attempt));
            continue;
        }
        if (!response.ok) {
            throw new Error(`HTTP ${response.status}: ${text.slice(0, 400)}`);
        }

        let body;
        try {
            body = JSON.parse(text);
        } catch {
            throw new Error(`non-JSON GraphQL response: ${text.slice(0, 200)}`);
        }
        if (body.errors) {
            throw new Error(`GraphQL errors: ${JSON.stringify(body.errors)}`);
        }
        if (!body.data) throw new Error('GraphQL response has no data');
        return body.data;
    }
    throw new Error(`GraphQL request failed after 3 attempts: ${lastError}`);
}

// === Normalization ===

function normalizeAddress(address) {
    const hex = address.replace(/^0x/, '').toLowerCase();
    return `0x${hex.padStart(64, '0')}`;
}

function aliasAddress(address, selfOriginal) {
    const normalized = normalizeAddress(address);
    if (normalized === selfOriginal) return '@self';
    if (normalized === SUI_ADDRESS) return '@sui';
    if (normalized === STD_ADDRESS) return '@std';
    return normalized;
}

function renderBody(body, selfOriginal) {
    if (typeof body === 'string') return body;
    if (body === null || typeof body !== 'object') {
        throw new Error(`unsupported type body: ${JSON.stringify(body)}`);
    }
    if (typeof body.typeParameter === 'number') return `$${body.typeParameter}`;
    if (body.vector !== undefined) {
        return `vector<${renderBody(body.vector, selfOriginal)}>`;
    }
    if (body.datatype) {
        const { package: pkg, module, type, typeParameters } = body.datatype;
        const args = (typeParameters ?? []).map((parameter) =>
            renderBody(parameter, selfOriginal),
        );
        const suffix = args.length > 0 ? `<${args.join(', ')}>` : '';
        return `${aliasAddress(pkg, selfOriginal)}::${module}::${type}${suffix}`;
    }
    throw new Error(`unsupported type body: ${JSON.stringify(body)}`);
}

function renderType(signature, selfOriginal) {
    const reference = signature.ref === '&mut' ? '&mut ' : (signature.ref ?? '');
    return `${reference}${renderBody(signature.body, selfOriginal)}`;
}

function renderAbilities(abilities) {
    const lowered = abilities.map((ability) => ability.toLowerCase());
    return ABILITY_ORDER.filter((ability) => lowered.includes(ability));
}

function renderConstraints(constraints) {
    const ordered = renderAbilities(constraints ?? []);
    return ordered.length > 0 ? `: ${ordered.join('+')}` : '';
}

function renderFunction(name, fn, selfOriginal) {
    const visibility = {
        PUBLIC: 'public',
        FRIEND: 'public(package)',
        PRIVATE: 'private',
    }[fn.visibility];
    if (!visibility) throw new Error(`unknown visibility: ${fn.visibility}`);

    const typeParameters = (fn.typeParameters ?? []).map(
        (parameter, index) => `$${index}${renderConstraints(parameter.constraints)}`,
    );
    const generics =
        typeParameters.length > 0 ? `<${typeParameters.join(', ')}>` : '';
    const parameters = (fn.parameters ?? []).map((parameter) =>
        renderType(parameter.signature, selfOriginal),
    );
    const returns = (fn.return ?? []).map((value) =>
        renderType(value.signature, selfOriginal),
    );
    const returned =
        returns.length === 0
            ? ''
            : returns.length === 1
              ? `: ${returns[0]}`
              : `: (${returns.join(', ')})`;
    const entry = fn.isEntry ? 'entry ' : '';

    return `${visibility} ${entry}fun ${name}${generics}(${parameters.join(', ')})${returned}`;
}

function renderStruct(name, struct) {
    const typeParameters = (struct.typeParameters ?? []).map(
        (parameter, index) =>
            `${parameter.isPhantom ? 'phantom ' : ''}$${index}${renderConstraints(parameter.constraints)}`,
    );
    const generics =
        typeParameters.length > 0 ? `<${typeParameters.join(', ')}>` : '';
    const abilities = renderAbilities(struct.abilities ?? []);
    const has = abilities.length > 0 ? ` has ${abilities.join(', ')}` : '';

    return `struct ${name}${generics}${has}`;
}

// === Chain Queries ===

const PACKAGE_QUERY = `query($address: SuiAddress!, $version: UInt53!) {
  latest: package(address: $address) {
    address
    version
    digest
    previousTransaction { digest }
    typeOrigins { module struct definingId }
  }
  pinned: package(address: $address, version: $version) {
    address
    version
    digest
    previousTransaction { digest }
    packageVersionsAfter(first: 5) {
      pageInfo { hasNextPage }
      nodes { address version }
    }
  }
}`;

function moduleQuery(module) {
    const structFields = module.structs
        .map(
            (name, index) =>
                `    s${index}: struct(name: "${name}") { name abilities typeParameters { isPhantom constraints } }`,
        )
        .join('\n');
    const functionFields = module.functions
        .map(
            (name, index) =>
                `    f${index}: function(name: "${name}") { name visibility isEntry typeParameters { constraints } parameters { signature } return { signature } }`,
        )
        .join('\n');

    return `query($address: SuiAddress!) {
  package(address: $address) {
    module(name: "${module.name}") {
      name
      bytes
${structFields}
${functionFields}
    }
  }
}`;
}

async function verifyPackage(expected, observed) {
    const label = expected.label;
    const data = await graphql(PACKAGE_QUERY, {
        address: expected.originalId,
        version: expected.version,
    });

    // `package(address:)` resolves any address in a lineage to its current
    // revision; `package(address:, version:)` returns exactly the pinned one,
    // so `packageVersionsAfter` there reports any newer tip.
    const live = data.latest;
    if (!check(live != null, `${label}: original package id does not resolve`)) {
        return null;
    }

    const currentId = normalizeAddress(live.address);
    const previousTransaction = live.previousTransaction?.digest ?? null;
    observed.currentId = currentId;
    observed.version = live.version;
    observed.digest = live.digest;
    observed.previousTransaction = previousTransaction;

    checkEqual(currentId, expected.currentId, `${label}: current package id drift`);
    checkEqual(live.version, expected.version, `${label}: package version drift`);
    checkEqual(live.digest, expected.digest, `${label}: package digest drift`);
    checkEqual(
        previousTransaction,
        expected.previousTransaction,
        `${label}: previous transaction drift`,
    );

    const pinned = data.pinned;
    if (
        check(pinned != null, `${label}: pinned revision ${expected.version} is gone`)
    ) {
        checkEqual(
            normalizeAddress(pinned.address),
            expected.currentId,
            `${label}: revision ${expected.version} is not the expected package id`,
        );
        checkEqual(
            pinned.digest,
            expected.digest,
            `${label}: revision ${expected.version} digest drift`,
        );
        checkEqual(
            pinned.previousTransaction?.digest ?? null,
            expected.previousTransaction,
            `${label}: revision ${expected.version} previous transaction drift`,
        );

        const later = pinned.packageVersionsAfter;
        check(
            later.nodes.length === 0 && later.pageInfo.hasNextPage === false,
            `${label}: a later package revision exists beyond the expected tip ` +
                `v${expected.version}: ${JSON.stringify(later.nodes)}`,
        );
    }

    const origins = new Map(
        live.typeOrigins.map((origin) => [
            `${origin.module}::${origin.struct}`,
            normalizeAddress(origin.definingId),
        ]),
    );
    let checkedOrigins = 0;
    for (const module of expected.modules) {
        for (const name of module.structs) {
            const key = `${module.name}::${name}`;
            const definingId = origins.get(key);
            if (
                check(
                    definingId !== undefined,
                    `${label}: missing type origin for ${key}`,
                )
            ) {
                checkEqual(
                    definingId,
                    expected.originalId,
                    `${label}: ${key} is not defined by the original package`,
                );
                checkedOrigins += 1;
            }
        }
    }

    return { currentId, checkedOrigins };
}

async function verifyModule(expected, module, currentId, observed) {
    const label = `${expected.label} ${module.name}`;
    const data = await graphql(moduleQuery(module), { address: currentId });
    const live = data.package?.module;
    if (!check(live != null, `${label}: module is missing from the package`)) {
        return { functions: 0, structs: 0 };
    }

    const bytes = Buffer.from(live.bytes, 'base64');
    check(
        bytes.length > 4 && bytes.readUInt32BE(0) === 0xa11ceb0b,
        `${label}: decoded module bytes are not Move bytecode`,
    );
    const sha256 = createHash('sha256').update(bytes).digest('hex');
    observed.modules.push({ name: module.name, sha256 });
    checkEqual(sha256, module.sha256, `${label}: module bytecode fingerprint drift`);

    let structs = 0;
    module.structs.forEach((name, index) => {
        const struct = live[`s${index}`];
        if (!check(struct != null, `${label}::${name}: struct is missing`)) return;
        const normalized = renderStruct(name, struct);
        observed.abi[`${expected.addressName}::${module.name}::${name}`] = normalized;
        checkEqual(
            normalized,
            ABI[`${expected.addressName}::${module.name}::${name}`],
            `${label}::${name}: struct declaration drift`,
        );
        structs += 1;
    });

    let functions = 0;
    module.functions.forEach((name, index) => {
        const fn = live[`f${index}`];
        if (!check(fn != null, `${label}::${name}: function is missing`)) return;
        const normalized = renderFunction(name, fn, expected.originalId);
        observed.abi[`${expected.addressName}::${module.name}::${name}`] = normalized;
        checkEqual(
            normalized,
            ABI[`${expected.addressName}::${module.name}::${name}`],
            `${label}::${name}: function signature drift`,
        );
        functions += 1;
    });

    return { functions, structs };
}

// === Local Manifests And Lock ===

function readPackageFile(relativePath) {
    return readFileSync(join(PACKAGE_DIR, relativePath), 'utf8');
}

function verifyManifests() {
    let manifests = 0;
    for (const expected of PACKAGES) {
        if (!expected.manifest) continue;
        const source = readPackageFile(expected.manifest);
        const label = `${expected.manifest}`;
        check(
            source.includes(`published-at = "${expected.currentId}"`),
            `${label}: published-at must be ${expected.currentId}`,
        );
        check(
            source.includes(`${expected.addressName} = "${expected.originalId}"`),
            `${label}: ${expected.addressName} must stay ${expected.originalId}`,
        );
        check(
            source.includes(`rev = "${SUI_FRAMEWORK_REV}"`),
            `${label}: Sui framework dependency must pin ${SUI_FRAMEWORK_REV}`,
        );
        manifests += 1;
    }

    const root = readPackageFile('Move.toml');
    for (const expected of PACKAGES) {
        if (!expected.manifest) continue;
        const local = dirname(expected.manifest).replace(/^\.\//, '');
        check(
            root.includes(`local = "${local}"`),
            `Move.toml: must depend on the local ${local} interface`,
        );
    }
    const rootRevisions = [...root.matchAll(/rev = "([^"]+)"/g)].map(
        (match) => match[1],
    );
    check(rootRevisions.length > 0, 'Move.toml: no Git revisions found');
    for (const revision of rootRevisions) {
        check(
            /^[0-9a-f]{40}$/.test(revision),
            `Move.toml: revision ${revision} is not an immutable 40-hex commit`,
        );
    }
    manifests += 1;

    return { manifests, rootRevisions: rootRevisions.length };
}

function parseLock(source) {
    const sections = new Map();
    let current = null;
    for (const rawLine of source.split('\n')) {
        const line = rawLine.trim();
        const header = line.match(/^\[([^\]]+)\]$/);
        if (header) {
            current = [];
            sections.set(header[1], current);
            continue;
        }
        if (current && line.length > 0) current.push(line);
    }
    return sections;
}

function verifyLock() {
    const source = readPackageFile('Move.lock');
    const sections = parseLock(source);

    const lockRevisions = [...source.matchAll(/rev = "([^"]+)"/g)].map(
        (match) => match[1],
    );
    check(lockRevisions.length > 0, 'Move.lock: no pinned Git revisions found');
    for (const revision of lockRevisions) {
        check(
            /^[0-9a-f]{40}$/.test(revision),
            `Move.lock: revision ${revision} is not an immutable 40-hex commit`,
        );
    }

    let suiEdges = 0;
    for (const environment of LOCK_ENVIRONMENTS) {
        for (const expected of PACKAGES) {
            if (!expected.manifest) continue;
            const local = dirname(expected.manifest).replace(/^\.\//, '');
            const entry = [...sections.entries()].find(
                ([name, lines]) =>
                    name.startsWith(`pinned.${environment}.`) &&
                    lines.some((line) => line.includes(`source = { local = "${local}" }`)),
            );
            if (
                !check(
                    entry !== undefined,
                    `Move.lock: ${environment} has no pinned entry for ${local}`,
                )
            ) {
                continue;
            }

            const deps = entry[1].find((line) => line.startsWith('deps = '));
            const suiNode = deps?.match(/Sui = "([^"]+)"/)?.[1];
            if (
                !check(
                    suiNode !== undefined,
                    `Move.lock: ${entry[0]} does not bind a Sui framework dependency`,
                )
            ) {
                continue;
            }

            const suiSection = sections.get(`pinned.${environment}.${suiNode}`);
            const suiSource = suiSection?.find((line) => line.startsWith('source = '));
            checkEqual(
                suiSource?.match(/rev = "([^"]+)"/)?.[1],
                SUI_FRAMEWORK_REV,
                `Move.lock: ${entry[0]} resolves ${suiNode} to the wrong Sui framework revision`,
            );
            check(
                suiSource?.includes(
                    'subdir = "crates/sui-framework/packages/sui-framework"',
                ) === true,
                `Move.lock: ${entry[0]} resolves ${suiNode} outside the Sui framework package`,
            );
            suiEdges += 1;
        }
    }

    return { lockRevisions: lockRevisions.length, suiEdges };
}

// === Emit ===

function emit(observations) {
    const lines = [];
    for (const observation of observations) {
        lines.push(`// ${observation.label}`);
        lines.push(`currentId: '${observation.currentId}',`);
        lines.push(`version: ${observation.version},`);
        lines.push(`digest: '${observation.digest}',`);
        lines.push(`previousTransaction: '${observation.previousTransaction}',`);
        for (const module of observation.modules) {
            lines.push(`${module.name}: '${module.sha256}',`);
        }
    }
    lines.push('');
    lines.push('const ABI = {');
    for (const observation of observations) {
        for (const [key, value] of Object.entries(observation.abi)) {
            lines.push(`    '${key}':`);
            lines.push(`        '${value.replace(/'/g, "\\'")}',`);
        }
    }
    lines.push('};');
    process.stdout.write(`${lines.join('\n')}\n`);
}

// === Main ===

async function main() {
    const shouldEmit = process.argv.includes('--emit');

    const identifier = await graphql('query { chainIdentifier }', {});
    checkEqual(
        identifier.chainIdentifier,
        CHAIN_IDENTIFIER,
        `${ENDPOINT} is not Sui mainnet`,
    );
    if (failures.length > 0) report(shouldEmit, []);

    const observations = [];
    let totalModules = 0;
    let totalFunctions = 0;
    let totalStructs = 0;

    for (const expected of PACKAGES) {
        const observed = {
            label: expected.label,
            currentId: null,
            version: null,
            digest: null,
            previousTransaction: null,
            modules: [],
            abi: {},
        };
        observations.push(observed);

        const before = failures.length;
        const resolved = await verifyPackage(expected, observed);
        if (!resolved) continue;

        let functions = 0;
        let structs = 0;
        for (const module of expected.modules) {
            const counts = await verifyModule(
                expected,
                module,
                resolved.currentId,
                observed,
            );
            functions += counts.functions;
            structs += counts.structs;
        }
        totalModules += expected.modules.length;
        totalFunctions += functions;
        totalStructs += structs;

        process.stdout.write(
            `${status(before)} ${expected.label.padEnd(21)} ` +
                `original ${short(expected.originalId)} -> v${observed.version} ` +
                `${short(observed.currentId)} digest ${observed.digest} ` +
                `tx ${observed.previousTransaction} | ` +
                `modules ${expected.modules.length} functions ${functions} ` +
                `structs ${structs} origins ${resolved.checkedOrigins}\n`,
        );
    }

    const before = failures.length;
    const manifests = verifyManifests();
    const lock = verifyLock();
    process.stdout.write(
        `${status(before)} ${'local pins'.padEnd(21)} ` +
            `manifests ${manifests.manifests} manifest revisions ` +
            `${manifests.rootRevisions} lock revisions ${lock.lockRevisions} ` +
            `local-interface Sui edges ${lock.suiEdges}\n`,
    );

    report(shouldEmit, observations, {
        totalModules,
        totalFunctions,
        totalStructs,
    });
}

function status(failuresBefore) {
    return failures.length === failuresBefore ? '  ok ' : '  FAIL';
}

function short(address) {
    return `${address.slice(0, 10)}…${address.slice(-6)}`;
}

function report(shouldEmit, observations, totals) {
    if (shouldEmit) emit(observations);

    if (failures.length > 0) {
        process.stderr.write(`\ncheck_mainnet_abi: FAIL (${failures.length})\n`);
        for (const failure of failures) process.stderr.write(`  - ${failure}\n`);
        process.exit(1);
    }

    process.stdout.write(
        `check_mainnet_abi: PASS ${PACKAGES.length} packages, ` +
            `${totals.totalModules} modules, ${totals.totalFunctions} functions, ` +
            `${totals.totalStructs} structs\n`,
    );
    process.exit(0);
}

main().catch((error) => {
    process.stderr.write(`check_mainnet_abi: FAIL ${error.message}\n`);
    process.exit(1);
});
