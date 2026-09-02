#!/usr/bin/env node
// Release gate for the Blast aggregate migrators package.
//
// Verifies, against the official Sui mainnet GraphQL endpoint, that every
// external venue package the adapters link to is still the exact immutable
// revision this repository pins, and that the public ABI the adapters consume
// has not drifted. It also validates the committed manifest and lock records
// strictly, so no dependency can become mutable, rebound, or re-sourced.
// Uses Node built-ins only.
//
// Run `node scripts/check_mainnet_abi.mjs` from `sui/migrators/`.
// Run with `--self-test` to exercise the strict response, manifest, and lock
// validators offline; that mode makes no network request.
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

/// Whole-request deadline, applied to connection and body read together.
const REQUEST_TIMEOUT_MS = 30_000;

const REQUEST_ATTEMPTS = 3;

const STD_ADDRESS = `0x${'0'.repeat(63)}1`;
const SUI_ADDRESS = `0x${'0'.repeat(63)}2`;

const SUI_GIT = 'https://github.com/MystenLabs/sui.git';
const SUI_FRAMEWORK_SUBDIR = 'crates/sui-framework/packages/sui-framework';
const MOVE_STDLIB_SUBDIR = 'crates/sui-framework/packages/move-stdlib';
const BLUEFIN_GIT =
    'https://github.com/fireflyprotocol/bluefin-spot-contract-interface.git';
const MMT_GIT = 'https://github.com/mmt-finance/mmt-contract-interface.git';
const INTEGER_MATE_GIT = 'https://github.com/CetusProtocol/integer-mate.git';
const INTEGER_LIBRARY_GIT =
    'https://github.com/fireflyprotocol/integer-library.git';
const MOVE_STL_GIT = 'https://github.com/CetusProtocol/move-stl.git';

/// Every Git revision the built graph is allowed to resolve to.
const REV = {
    sui: '06734f6ff0af45d8632a14a4dc4b100197f6b1a2',
    suiLegacy: '17a9eb8e19146cac2f1fd8921c85911054d29e50',
    suiBluefin: '4e46da89efd5c5e59fe2b8e877bd960896601ec9',
    bluefin: '91ce930575b2aa3decab9b7e129b8002deba80c1',
    mmt: 'e27d14caed53e1b7c4e1c12ea89b2ff87c58ee82',
    integerMate: '09a12d9b171122883d9350039d4ed6e8400033b9',
    integerMateBluefin: '06660f704c4ac1d443ab62346a46b5b60d49df33',
    integerLibrary: '8a534bd1c0b334cd3937c27987f3147a06ba6a18',
    moveStl: '0681fec63a310ae753d03a06f7c05d3e2925bb09',
};

/// The one Sui framework revision every local normalized interface must bind.
const SUI_FRAMEWORK_REV = REV.sui;

const LOCK_ENVIRONMENTS = ['mainnet', 'testnet'];

const LOCK_VERSION = 4;

const ABILITY_ORDER = ['copy', 'drop', 'store', 'key'];

const PRIMITIVE_TYPES = [
    'bool',
    'u8',
    'u16',
    'u32',
    'u64',
    'u128',
    'u256',
    'address',
    'signer',
];

const VISIBILITIES = {
    PUBLIC: 'public',
    FRIEND: 'public(package)',
    PRIVATE: 'private',
};

/// Keys a `[package]` table may declare. Anything else fails the gate.
const PACKAGE_TABLE_KEYS = [
    'name',
    'version',
    'edition',
    'license',
    'authors',
    'published-at',
];

const MANIFEST_TABLES = ['package', 'dependencies', 'addresses'];

const LOCK_NODE_KEYS = ['source', 'use_environment', 'manifest_digest', 'deps'];

/// Shape the Move CLI generates for `manifest_digest`: 64 uppercase hex digits.
const LOCK_DIGEST_PATTERN = /^[0-9A-F]{64}$/;

const PACKAGE_DIR = join(dirname(fileURLToPath(import.meta.url)), '..');

// === Expected Packages ===

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
        key: 'aftermath',
        label: 'Aftermath AMM',
        addressName: 'amm',
        originalId:
            '0xefe170ec0be4d762196bedecd7a065816576198a6527c99282a2551aaa7da38c',
        currentId:
            '0xf948935b111990c2b604900c9b2eeb8f24dcf9868a45d1ea1653a5f282c10e29',
        version: 3,
        digest: 'Gxia3EZSdQeCXGPkmhXRzXWfmV6bnw7oRvSXNxNLQ9T1',
        previousTransaction: '7qeJhR15a6jqo7xujZMMe5Bcm11vR7cSBiFHypW3VQ3J',
        manifest: 'interfaces/aftermath/Move.toml',
        modules: [
            {
                name: 'pool',
                sha256: 'f952884b3e6ea275911ae488e9d1e3f4b2a4409cdd30e8bed69e98fd7d0f7d78',
                structs: ['CreatePoolCapV2', 'Pool'],
                structOrigins: { CreatePoolCapV2: 'current' },
                functions: [
                    'balance_of',
                    'fees_deposit_for',
                    'fees_swap_in_for',
                    'fees_swap_out_for',
                    'fees_withdraw_for',
                    'flatness',
                    'lp_decimals',
                    'lp_supply_value',
                    'share',
                    'size',
                    'weight_of',
                ],
            },
            {
                name: 'pool_factory',
                sha256: 'e2601c8181d142cb10bf10bbbe90adbd9545688238cbc3ba8b1bf9cf0809b17d',
                structs: [],
                functions: ['create_pool_2_coins_v2'],
            },
            {
                name: 'pool_registry',
                sha256: '9d4f76ef56e619111d94b41bac54641f2012d16a7e796a83436479b319dc6a62',
                structs: ['PoolRegistry'],
                functions: ['contains_lp_coin', 'lp_type_to_pool_id'],
            },
        ],
    },
    {
        key: 'aftermath_dao_fee',
        label: 'Aftermath DAO Fee Pools',
        addressName: 'dao_fee_amm',
        originalId:
            '0x6f60a091637054e23915b8745c0c0d47b1d49618ee3435b5f68eccf6a44fb53d',
        currentId:
            '0x5ad6890968efcf3d20899e0cec735214f1067b96e77e77d86408989998468bb2',
        version: 2,
        digest: 'AeSpba79KZ8Ge8nGk2Li2c2tkLy7eC93wTGhgjEVHVpZ',
        previousTransaction: '9eMeoFRPGDW1TUvbhtstVu2bAaWCCM7VCgbgkEkCUR4c',
        manifest: 'interfaces/aftermath_dao_fee/Move.toml',
        modules: [
            {
                name: 'pool',
                sha256: '029b3e6e0a11a249147cdd0b7b3ea78556d399e03228cae9424529a06cd58f3e',
                structs: ['DaoFeePool', 'OwnerCap'],
                functions: [
                    'fee_bps',
                    'fee_recipient',
                    'new',
                    'update_fee_bps',
                ],
            },
            {
                name: 'version',
                sha256: '6fbb4c1b78af3fa68654af6eb29be6fdbc945e9d715a46ac1ca9bc3f3f8920f2',
                structs: ['Version'],
                functions: [],
            },
        ],
    },
];

// === Expected Local Pins ===

function packageByKey(key) {
    const found = PACKAGES.find((candidate) => candidate.key === key);
    if (!found) throw new Error(`unknown package key ${key}`);
    return found;
}

/// Every committed manifest, bound to its exact dependency records. Each record
/// is compared key-for-key and value-for-value, so an added `branch`/`tag`, a
/// dropped `rev`, a changed repository or subdirectory, a changed override rule,
/// or an extra dependency all fail.
const MANIFESTS = [
    {
        path: 'Move.toml',
        packageName: 'blast_fun_migrators',
        publishedAt: null,
        addresses: { blast_fun_migrators: '0x0' },
        dependencies: {
            blast_fun: { local: '../launchpad' },
            BluefinSpot: { git: BLUEFIN_GIT, rev: REV.bluefin },
            mmt_v3: { git: MMT_GIT, subdir: 'mmt_v3', rev: REV.mmt },
            CetusClmm: { local: 'interfaces/cetus' },
            TurbosCLMM: { local: 'interfaces/turbos' },
            AftermathAmm: { local: 'interfaces/aftermath' },
            AftermathDaoFeePools: { local: 'interfaces/aftermath_dao_fee' },
            Sui: {
                git: SUI_GIT,
                subdir: SUI_FRAMEWORK_SUBDIR,
                rev: REV.sui,
                override: true,
            },
            IntegerMate: {
                git: INTEGER_MATE_GIT,
                rev: REV.integerMate,
                override: true,
            },
            IntegerLibrary: {
                git: INTEGER_LIBRARY_GIT,
                rev: REV.integerLibrary,
                override: true,
            },
        },
    },
    {
        path: 'interfaces/aftermath/Move.toml',
        packageName: 'AftermathAmm',
        packageKey: 'aftermath',
        lockNode: 'AftermathAmm',
        dependencies: {
            Sui: {
                git: SUI_GIT,
                subdir: SUI_FRAMEWORK_SUBDIR,
                rev: REV.sui,
                override: true,
            },
        },
    },
    {
        path: 'interfaces/aftermath_dao_fee/Move.toml',
        packageName: 'AftermathDaoFeePools',
        packageKey: 'aftermath_dao_fee',
        lockNode: 'AftermathDaoFeePools',
        dependencies: {
            AftermathAmm: { local: '../aftermath' },
            Sui: {
                git: SUI_GIT,
                subdir: SUI_FRAMEWORK_SUBDIR,
                rev: REV.sui,
                override: true,
            },
        },
    },
    {
        path: 'interfaces/cetus/Move.toml',
        packageName: 'CetusClmm',
        packageKey: 'cetus',
        lockNode: 'CetusClmm',
        dependencies: {
            Sui: {
                git: SUI_GIT,
                subdir: SUI_FRAMEWORK_SUBDIR,
                rev: REV.sui,
                override: true,
            },
            IntegerMate: {
                git: INTEGER_MATE_GIT,
                rev: REV.integerMate,
                override: true,
            },
            MoveSTL: { git: MOVE_STL_GIT, rev: REV.moveStl, override: true },
        },
    },
    {
        path: 'interfaces/turbos/Move.toml',
        packageName: 'TurbosCLMM',
        packageKey: 'turbos',
        lockNode: 'TurbosCLMM',
        dependencies: {
            Sui: {
                git: SUI_GIT,
                subdir: SUI_FRAMEWORK_SUBDIR,
                rev: REV.sui,
                override: true,
            },
        },
    },
];

/// Every pinned node the lock is allowed to contain, in both environments,
/// bound to its exact source record and its exact resolved dependency edges.
/// Both environments resolve identical edges, so one table covers both.
const LOCK_NODES = {
    AftermathAmm: {
        source: { local: 'interfaces/aftermath' },
        deps: { Sui: 'Sui' },
    },
    AftermathDaoFeePools: {
        source: { local: 'interfaces/aftermath_dao_fee' },
        deps: { AftermathAmm: 'AftermathAmm', Sui: 'Sui' },
    },
    BluefinSpot: {
        source: { git: BLUEFIN_GIT, subdir: '.', rev: REV.bluefin },
        deps: { IntegerLibrary: 'IntegerLibrary', IntegerMate: 'IntegerMate', Sui: 'Sui_2' },
    },
    CetusClmm: {
        source: { local: 'interfaces/cetus' },
        deps: { IntegerMate: 'IntegerMate_1', MoveSTL: 'MoveSTL', Sui: 'Sui' },
    },
    IntegerLibrary: {
        source: { git: INTEGER_LIBRARY_GIT, subdir: '.', rev: REV.integerLibrary },
        deps: { Sui: 'Sui_1' },
    },
    IntegerMate: {
        source: { git: INTEGER_MATE_GIT, subdir: 'sui', rev: REV.integerMateBluefin },
        deps: { Sui: 'Sui_1' },
    },
    IntegerMate_1: {
        source: { git: INTEGER_MATE_GIT, subdir: '.', rev: REV.integerMate },
        deps: { std: 'MoveStdlib', sui: 'Sui' },
    },
    MoveSTL: {
        source: { git: MOVE_STL_GIT, subdir: '.', rev: REV.moveStl },
        deps: { std: 'MoveStdlib', sui: 'Sui' },
    },
    MoveStdlib: {
        source: { git: SUI_GIT, subdir: MOVE_STDLIB_SUBDIR, rev: REV.sui },
        deps: {},
    },
    MoveStdlib_1: {
        source: { git: SUI_GIT, subdir: MOVE_STDLIB_SUBDIR, rev: REV.suiLegacy },
        deps: {},
    },
    MoveStdlib_2: {
        source: { git: SUI_GIT, subdir: MOVE_STDLIB_SUBDIR, rev: REV.suiBluefin },
        deps: {},
    },
    Sui: {
        source: { git: SUI_GIT, subdir: SUI_FRAMEWORK_SUBDIR, rev: REV.sui },
        deps: { MoveStdlib: 'MoveStdlib' },
    },
    Sui_1: {
        source: { git: SUI_GIT, subdir: SUI_FRAMEWORK_SUBDIR, rev: REV.suiLegacy },
        deps: { MoveStdlib: 'MoveStdlib_1' },
    },
    Sui_2: {
        source: { git: SUI_GIT, subdir: SUI_FRAMEWORK_SUBDIR, rev: REV.suiBluefin },
        deps: { MoveStdlib: 'MoveStdlib_2' },
    },
    TurbosCLMM: {
        source: { local: 'interfaces/turbos' },
        deps: { Sui: 'Sui' },
    },
    blast_fun: {
        source: { local: '../launchpad' },
        deps: { std: 'MoveStdlib', sui: 'Sui' },
    },
    blast_fun_migrators: {
        source: { root: true },
        deps: {
            AftermathAmm: 'AftermathAmm',
            AftermathDaoFeePools: 'AftermathDaoFeePools',
            BluefinSpot: 'BluefinSpot',
            CetusClmm: 'CetusClmm',
            IntegerLibrary: 'IntegerLibrary',
            IntegerMate: 'IntegerMate_1',
            Sui: 'Sui',
            TurbosCLMM: 'TurbosCLMM',
            blast_fun: 'blast_fun',
            mmt_v3: 'mmt_v3',
        },
    },
    mmt_v3: {
        source: { git: MMT_GIT, subdir: 'mmt_v3', rev: REV.mmt },
        deps: { std: 'MoveStdlib', sui: 'Sui' },
    },
};


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
    'amm::pool::CreatePoolCapV2':
        'struct CreatePoolCapV2 has store, key',
    'amm::pool::Pool':
        'struct Pool<phantom $0> has store, key',
    'amm::pool::balance_of':
        'public fun balance_of<$0, $1>(&@self::pool::Pool<$0>): u64',
    'amm::pool::fees_deposit_for':
        'public fun fees_deposit_for<$0, $1>(&@self::pool::Pool<$0>): u64',
    'amm::pool::fees_swap_in_for':
        'public fun fees_swap_in_for<$0, $1>(&@self::pool::Pool<$0>): u64',
    'amm::pool::fees_swap_out_for':
        'public fun fees_swap_out_for<$0, $1>(&@self::pool::Pool<$0>): u64',
    'amm::pool::fees_withdraw_for':
        'public fun fees_withdraw_for<$0, $1>(&@self::pool::Pool<$0>): u64',
    'amm::pool::flatness':
        'public fun flatness<$0>(&@self::pool::Pool<$0>): u64',
    'amm::pool::lp_decimals':
        'public fun lp_decimals<$0>(&@self::pool::Pool<$0>): u8',
    'amm::pool::lp_supply_value':
        'public fun lp_supply_value<$0>(&@self::pool::Pool<$0>): u64',
    'amm::pool::share':
        'public fun share<$0>(@self::pool::Pool<$0>)',
    'amm::pool::size':
        'public fun size<$0>(&@self::pool::Pool<$0>): u64',
    'amm::pool::weight_of':
        'public fun weight_of<$0, $1>(&@self::pool::Pool<$0>): u64',
    'amm::pool_factory::create_pool_2_coins_v2':
        'public fun create_pool_2_coins_v2<$0, $1, $2>(@self::pool::CreatePoolCapV2, &mut @self::pool_registry::PoolRegistry, vector<u8>, vector<u64>, u64, vector<u64>, vector<u64>, vector<u64>, vector<u64>, @sui::coin::Coin<$1>, @sui::coin::Coin<$2>, @std::option::Option<vector<u8>>, bool, &mut @sui::tx_context::TxContext): (@self::pool::Pool<$0>, @sui::coin::Coin<$0>)',
    'amm::pool_registry::PoolRegistry':
        'struct PoolRegistry has store, key',
    'amm::pool_registry::contains_lp_coin':
        'public fun contains_lp_coin<$0>(&@self::pool_registry::PoolRegistry): bool',
    'amm::pool_registry::lp_type_to_pool_id':
        'public fun lp_type_to_pool_id<$0>(&@self::pool_registry::PoolRegistry): @sui::object::ID',
    'dao_fee_amm::pool::DaoFeePool':
        'struct DaoFeePool<phantom $0> has store, key',
    'dao_fee_amm::pool::OwnerCap':
        'struct OwnerCap<phantom $0> has store, key',
    'dao_fee_amm::pool::fee_bps':
        'public fun fee_bps<$0>(&@self::pool::DaoFeePool<$0>): u16',
    'dao_fee_amm::pool::fee_recipient':
        'public fun fee_recipient<$0>(&@self::pool::DaoFeePool<$0>): address',
    'dao_fee_amm::pool::new':
        'public fun new<$0>(0xefe170ec0be4d762196bedecd7a065816576198a6527c99282a2551aaa7da38c::pool::Pool<$0>, &@self::version::Version, u16, address, &mut @sui::tx_context::TxContext): (@self::pool::DaoFeePool<$0>, @self::pool::OwnerCap<$0>)',
    'dao_fee_amm::pool::update_fee_bps':
        'public fun update_fee_bps<$0>(&@self::pool::OwnerCap<$0>, &mut @self::pool::DaoFeePool<$0>, &@self::version::Version, u16)',
    'dao_fee_amm::version::Version':
        'struct Version has key',
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

// === Response Shape Validation ===

// The GraphQL response is untrusted input to a release gate. Every scalar and
// list is validated before rendering, so a partial, null, or novel response can
// never normalize into a value that happens to match an expectation.

function shapeError(path, detail) {
    return new Error(`${path}: ${detail}`);
}

function expectObject(value, path, allowedKeys) {
    if (value === null || typeof value !== 'object' || Array.isArray(value)) {
        throw shapeError(path, `expected an object, got ${JSON.stringify(value)}`);
    }
    const unexpected = Object.keys(value).filter(
        (key) => !allowedKeys.includes(key),
    );
    if (unexpected.length > 0) {
        throw shapeError(path, `unexpected field(s) ${unexpected.join(', ')}`);
    }
    for (const key of allowedKeys) {
        if (!Object.hasOwn(value, key)) throw shapeError(path, `missing ${key}`);
    }
    return value;
}

function expectString(value, path) {
    if (typeof value !== 'string' || value.length === 0) {
        throw shapeError(path, `expected a non-empty string, got ${JSON.stringify(value)}`);
    }
    return value;
}

function expectBoolean(value, path) {
    if (typeof value !== 'boolean') {
        throw shapeError(path, `expected a boolean, got ${JSON.stringify(value)}`);
    }
    return value;
}

function expectInteger(value, path) {
    if (typeof value !== 'number' || !Number.isInteger(value) || value < 0) {
        throw shapeError(path, `expected a non-negative integer, got ${JSON.stringify(value)}`);
    }
    return value;
}

function expectArray(value, path) {
    if (!Array.isArray(value)) {
        throw shapeError(path, `expected a list, got ${JSON.stringify(value)}`);
    }
    return value;
}

function expectAbilities(value, path) {
    const abilities = expectArray(value, path).map((ability, index) => {
        const name = expectString(ability, `${path}[${index}]`).toLowerCase();
        if (!ABILITY_ORDER.includes(name)) {
            throw shapeError(`${path}[${index}]`, `unknown ability ${ability}`);
        }
        return name;
    });
    const unique = new Set(abilities);
    if (unique.size !== abilities.length) {
        throw shapeError(path, `duplicate abilities in ${abilities.join(', ')}`);
    }
    return ABILITY_ORDER.filter((ability) => unique.has(ability));
}

// === Normalization ===

function normalizeAddress(address, path = 'address') {
    expectString(address, path);
    if (!/^0x[0-9a-fA-F]{1,64}$/.test(address)) {
        throw shapeError(path, `not a Sui address: ${address}`);
    }
    return `0x${address.slice(2).toLowerCase().padStart(64, '0')}`;
}

function aliasAddress(address, selfOriginal, path) {
    const normalized = normalizeAddress(address, path);
    if (normalized === selfOriginal) return '@self';
    if (normalized === SUI_ADDRESS) return '@sui';
    if (normalized === STD_ADDRESS) return '@std';
    return normalized;
}

function renderBody(body, selfOriginal, path) {
    if (typeof body === 'string') {
        if (!PRIMITIVE_TYPES.includes(body)) {
            throw shapeError(path, `unknown primitive type ${body}`);
        }
        return body;
    }
    if (body === null || typeof body !== 'object' || Array.isArray(body)) {
        throw shapeError(path, `unsupported type body ${JSON.stringify(body)}`);
    }

    const keys = Object.keys(body);
    if (keys.length !== 1) {
        throw shapeError(path, `expected exactly one type body field, got ${keys.join(', ')}`);
    }

    if (keys[0] === 'typeParameter') {
        return `$${expectInteger(body.typeParameter, `${path}.typeParameter`)}`;
    }
    if (keys[0] === 'vector') {
        return `vector<${renderBody(body.vector, selfOriginal, `${path}.vector`)}>`;
    }
    if (keys[0] === 'datatype') {
        const datatype = expectObject(body.datatype, `${path}.datatype`, [
            'package',
            'module',
            'type',
            'typeParameters',
        ]);
        const args = expectArray(
            datatype.typeParameters,
            `${path}.datatype.typeParameters`,
        ).map((parameter, index) =>
            renderBody(parameter, selfOriginal, `${path}.datatype.typeParameters[${index}]`),
        );
        const address = aliasAddress(
            datatype.package,
            selfOriginal,
            `${path}.datatype.package`,
        );
        const module = expectString(datatype.module, `${path}.datatype.module`);
        const type = expectString(datatype.type, `${path}.datatype.type`);
        const suffix = args.length > 0 ? `<${args.join(', ')}>` : '';
        return `${address}::${module}::${type}${suffix}`;
    }
    throw shapeError(path, `unsupported type body field ${keys[0]}`);
}

function renderType(value, selfOriginal, path) {
    const wrapper = expectObject(value, path, ['signature']);
    const signature = wrapper.signature;
    if (signature === null || typeof signature !== 'object' || Array.isArray(signature)) {
        throw shapeError(`${path}.signature`, `expected an object, got ${JSON.stringify(signature)}`);
    }

    const keys = Object.keys(signature);
    const unexpected = keys.filter((key) => key !== 'ref' && key !== 'body');
    if (unexpected.length > 0) {
        throw shapeError(`${path}.signature`, `unexpected field(s) ${unexpected.join(', ')}`);
    }
    if (!Object.hasOwn(signature, 'body')) {
        throw shapeError(`${path}.signature`, 'missing body');
    }

    // The live schema omits `ref` for a by-value type, so absence is the known
    // shape and every present value — including an explicit null — must be one
    // of the two known reference kinds.
    let reference = '';
    if (Object.hasOwn(signature, 'ref')) {
        if (signature.ref === '&') reference = '&';
        else if (signature.ref === '&mut') reference = '&mut ';
        else {
            throw shapeError(
                `${path}.signature.ref`,
                `unknown reference kind ${JSON.stringify(signature.ref)}`,
            );
        }
    }

    return `${reference}${renderBody(signature.body, selfOriginal, `${path}.signature.body`)}`;
}

function renderConstraints(value, path) {
    const ordered = expectAbilities(value, path);
    return ordered.length > 0 ? `: ${ordered.join('+')}` : '';
}

function renderFunction(name, value, selfOriginal) {
    const path = `function ${name}`;
    const fn = expectObject(value, path, [
        'name',
        'visibility',
        'isEntry',
        'typeParameters',
        'parameters',
        'return',
    ]);

    checkNameMatches(fn.name, name, `${path}.name`);

    const visibility = VISIBILITIES[expectString(fn.visibility, `${path}.visibility`)];
    if (!visibility) {
        throw shapeError(`${path}.visibility`, `unknown visibility ${fn.visibility}`);
    }
    const entry = expectBoolean(fn.isEntry, `${path}.isEntry`) ? 'entry ' : '';

    const typeParameters = expectArray(
        fn.typeParameters,
        `${path}.typeParameters`,
    ).map((parameter, index) => {
        const declared = expectObject(
            parameter,
            `${path}.typeParameters[${index}]`,
            ['constraints'],
        );
        return `$${index}${renderConstraints(declared.constraints, `${path}.typeParameters[${index}].constraints`)}`;
    });
    const generics = typeParameters.length > 0 ? `<${typeParameters.join(', ')}>` : '';

    const parameters = expectArray(fn.parameters, `${path}.parameters`).map(
        (parameter, index) =>
            renderType(parameter, selfOriginal, `${path}.parameters[${index}]`),
    );
    const returns = expectArray(fn.return, `${path}.return`).map((value, index) =>
        renderType(value, selfOriginal, `${path}.return[${index}]`),
    );
    const returned =
        returns.length === 0
            ? ''
            : returns.length === 1
              ? `: ${returns[0]}`
              : `: (${returns.join(', ')})`;

    return `${visibility} ${entry}fun ${name}${generics}(${parameters.join(', ')})${returned}`;
}

function renderStruct(name, value) {
    const path = `struct ${name}`;
    const struct = expectObject(value, path, [
        'name',
        'abilities',
        'typeParameters',
    ]);

    checkNameMatches(struct.name, name, `${path}.name`);

    const typeParameters = expectArray(
        struct.typeParameters,
        `${path}.typeParameters`,
    ).map((parameter, index) => {
        const declared = expectObject(
            parameter,
            `${path}.typeParameters[${index}]`,
            ['isPhantom', 'constraints'],
        );
        const phantom = expectBoolean(
            declared.isPhantom,
            `${path}.typeParameters[${index}].isPhantom`,
        )
            ? 'phantom '
            : '';
        return `${phantom}$${index}${renderConstraints(declared.constraints, `${path}.typeParameters[${index}].constraints`)}`;
    });
    const generics = typeParameters.length > 0 ? `<${typeParameters.join(', ')}>` : '';

    const abilities = expectAbilities(struct.abilities, `${path}.abilities`);
    const has = abilities.length > 0 ? ` has ${abilities.join(', ')}` : '';

    return `struct ${name}${generics}${has}`;
}

function checkNameMatches(actual, expected, path) {
    if (expectString(actual, path) !== expected) {
        throw shapeError(path, `expected ${expected}, got ${actual}`);
    }
}

// === GraphQL ===

async function graphql(query, variables) {
    let lastError;
    for (let attempt = 1; attempt <= REQUEST_ATTEMPTS; attempt += 1) {
        let status = null;
        let text = null;
        try {
            const response = await fetch(ENDPOINT, {
                method: 'POST',
                headers: { 'content-type': 'application/json' },
                body: JSON.stringify({ query, variables }),
                signal: AbortSignal.timeout(REQUEST_TIMEOUT_MS),
            });
            status = response.status;
            // Read the body inside the retry boundary so a stream failure or a
            // body-read timeout retries like any other transport error.
            text = await response.text();
        } catch (error) {
            lastError = error;
            await new Promise((resolve) => setTimeout(resolve, 500 * attempt));
            continue;
        }

        if (status >= 500) {
            lastError = new Error(`HTTP ${status}: ${text.slice(0, 200)}`);
            await new Promise((resolve) => setTimeout(resolve, 500 * attempt));
            continue;
        }
        if (status < 200 || status >= 300) {
            throw new Error(`HTTP ${status}: ${text.slice(0, 400)}`);
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
    throw new Error(
        `GraphQL request failed after ${REQUEST_ATTEMPTS} attempts: ${lastError}`,
    );
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

function packageFacts(node, path, extraKeys) {
    const facts = expectObject(node, path, [
        'address',
        'version',
        'digest',
        'previousTransaction',
        ...extraKeys,
    ]);
    const previousTransaction = expectObject(
        facts.previousTransaction,
        `${path}.previousTransaction`,
        ['digest'],
    );

    return {
        address: normalizeAddress(facts.address, `${path}.address`),
        version: expectInteger(facts.version, `${path}.version`),
        digest: expectString(facts.digest, `${path}.digest`),
        previousTransaction: expectString(
            previousTransaction.digest,
            `${path}.previousTransaction.digest`,
        ),
    };
}

/// Validates every type-origin record and rejects a repeated `module::struct`
/// key before insertion.
///
/// A plain `new Map` would let a later entry overwrite an earlier one, so a
/// conflicting defining id followed by the expected id would read as correct.
/// Any repeat fails, including one that repeats the same defining id.
function buildTypeOrigins(path, value) {
    const origins = new Map();
    expectArray(value, path).forEach((origin, index) => {
        const entryPath = `${path}[${index}]`;
        const record = expectObject(origin, entryPath, [
            'module',
            'struct',
            'definingId',
        ]);
        const key =
            `${expectString(record.module, `${entryPath}.module`)}::` +
            `${expectString(record.struct, `${entryPath}.struct`)}`;
        if (origins.has(key)) {
            throw shapeError(entryPath, `duplicate type origin ${key}`);
        }
        origins.set(key, normalizeAddress(record.definingId, `${entryPath}.definingId`));
    });

    return origins;
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
    if (!check(data.latest != null, `${label}: original package id does not resolve`)) {
        return null;
    }

    let live;
    try {
        live = packageFacts(data.latest, `${label} latest`, ['typeOrigins']);
    } catch (error) {
        check(false, `${label}: ${error.message}`);
        return null;
    }

    observed.currentId = live.address;
    observed.version = live.version;
    observed.digest = live.digest;
    observed.previousTransaction = live.previousTransaction;

    checkEqual(live.address, expected.currentId, `${label}: current package id drift`);
    checkEqual(live.version, expected.version, `${label}: package version drift`);
    checkEqual(live.digest, expected.digest, `${label}: package digest drift`);
    checkEqual(
        live.previousTransaction,
        expected.previousTransaction,
        `${label}: previous transaction drift`,
    );

    if (check(data.pinned != null, `${label}: pinned revision ${expected.version} is gone`)) {
        try {
            const pinned = packageFacts(data.pinned, `${label} pinned`, [
                'packageVersionsAfter',
            ]);
            checkEqual(
                pinned.address,
                expected.currentId,
                `${label}: revision ${expected.version} is not the expected package id`,
            );
            checkEqual(
                pinned.digest,
                expected.digest,
                `${label}: revision ${expected.version} digest drift`,
            );
            checkEqual(
                pinned.previousTransaction,
                expected.previousTransaction,
                `${label}: revision ${expected.version} previous transaction drift`,
            );

            const later = expectObject(
                data.pinned.packageVersionsAfter,
                `${label} pinned.packageVersionsAfter`,
                ['pageInfo', 'nodes'],
            );
            const pageInfo = expectObject(
                later.pageInfo,
                `${label} pinned.packageVersionsAfter.pageInfo`,
                ['hasNextPage'],
            );
            const nodes = expectArray(
                later.nodes,
                `${label} pinned.packageVersionsAfter.nodes`,
            );
            check(
                nodes.length === 0 &&
                    expectBoolean(
                        pageInfo.hasNextPage,
                        `${label} pinned.packageVersionsAfter.pageInfo.hasNextPage`,
                    ) === false,
                `${label}: a later package revision exists beyond the expected tip ` +
                    `v${expected.version}: ${JSON.stringify(nodes)}`,
            );
        } catch (error) {
            check(false, `${label}: ${error.message}`);
        }
    }

    let checkedOrigins = 0;
    try {
        const origins = buildTypeOrigins(`${label} typeOrigins`, data.latest.typeOrigins);
        for (const module of expected.modules) {
            for (const name of module.structs) {
                const key = `${module.name}::${name}`;
                const definingId = origins.get(key);
                if (check(definingId !== undefined, `${label}: missing type origin for ${key}`)) {
                    const origin = module.structOrigins?.[name];
                    const expectedOrigin = origin === 'current'
                        ? expected.currentId
                        : expected.originalId;
                    checkEqual(
                        definingId,
                        expectedOrigin,
                        `${label}: ${key} has the wrong defining package`,
                    );
                    checkedOrigins += 1;
                }
            }
        }
    } catch (error) {
        check(false, `${label}: ${error.message}`);
        return null;
    }

    return { currentId: live.address, checkedOrigins };
}

async function verifyModule(expected, module, currentId, observed) {
    const label = `${expected.label} ${module.name}`;
    const data = await graphql(moduleQuery(module), { address: currentId });
    const live = data.package?.module;
    if (!check(live != null, `${label}: module is missing from the package`)) {
        return { functions: 0, structs: 0 };
    }

    try {
        checkNameMatches(live.name, module.name, `${label}.name`);
        const encoded = expectString(live.bytes, `${label}.bytes`);
        const bytes = Buffer.from(encoded, 'base64');
        check(
            bytes.length > 4 && bytes.readUInt32BE(0) === 0xa11ceb0b,
            `${label}: decoded module bytes are not Move bytecode`,
        );
        const sha256 = createHash('sha256').update(bytes).digest('hex');
        observed.modules.push({ name: module.name, sha256 });
        checkEqual(sha256, module.sha256, `${label}: module bytecode fingerprint drift`);
    } catch (error) {
        check(false, `${label}: ${error.message}`);
    }

    let structs = 0;
    module.structs.forEach((name, index) => {
        const key = `${expected.addressName}::${module.name}::${name}`;
        if (!check(live[`s${index}`] != null, `${label}::${name}: struct is missing`)) return;
        try {
            const normalized = renderStruct(name, live[`s${index}`]);
            observed.abi[key] = normalized;
            checkEqual(normalized, ABI[key], `${label}::${name}: struct declaration drift`);
            structs += 1;
        } catch (error) {
            check(false, `${label}::${name}: ${error.message}`);
        }
    });

    let functions = 0;
    module.functions.forEach((name, index) => {
        const key = `${expected.addressName}::${module.name}::${name}`;
        if (!check(live[`f${index}`] != null, `${label}::${name}: function is missing`)) return;
        try {
            const normalized = renderFunction(name, live[`f${index}`], expected.originalId);
            observed.abi[key] = normalized;
            checkEqual(normalized, ABI[key], `${label}::${name}: function signature drift`);
            functions += 1;
        } catch (error) {
            check(false, `${label}::${name}: ${error.message}`);
        }
    });

    return { functions, structs };
}

// === Strict TOML Records ===

// A deliberately small TOML reader for the exact shapes these committed files
// use. Anything outside that shape — an escape, a nested inline table, a
// duplicate key, a duplicate table, an unknown value form — is an error, so a
// dependency can never slip through as unparsed text. Comments are removed
// before any comparison, so commented-out text cannot satisfy an expectation.

function stripComment(line, label, lineNumber) {
    let inString = false;
    for (let index = 0; index < line.length; index += 1) {
        const character = line[index];
        if (character === '\\') {
            throw new Error(`${label}:${lineNumber}: unsupported escape`);
        }
        if (character === '"') inString = !inString;
        else if (character === '#' && !inString) return line.slice(0, index);
    }
    if (inString) throw new Error(`${label}:${lineNumber}: unterminated string`);
    return line;
}

function splitInline(inner) {
    const parts = [];
    let inString = false;
    let start = 0;
    for (let index = 0; index < inner.length; index += 1) {
        const character = inner[index];
        if (character === '"') inString = !inString;
        else if (character === ',' && !inString) {
            parts.push(inner.slice(start, index));
            start = index + 1;
        }
    }
    parts.push(inner.slice(start));
    return parts;
}

function parseScalar(text, label, lineNumber) {
    if (/^"[^"]*"$/.test(text)) return text.slice(1, -1);
    if (text === 'true') return true;
    if (text === 'false') return false;
    if (/^[0-9]+$/.test(text)) return Number(text);
    throw new Error(`${label}:${lineNumber}: unsupported value ${text}`);
}

function parseInlineTable(text, label, lineNumber) {
    const inner = text.slice(1, -1).trim();
    const record = new Map();
    if (inner === '') return record;
    for (const part of splitInline(inner)) {
        const match = /^\s*([A-Za-z0-9_.-]+)\s*=\s*(.+?)\s*$/.exec(part);
        if (!match) {
            throw new Error(`${label}:${lineNumber}: unsupported inline entry ${part.trim()}`);
        }
        if (record.has(match[1])) {
            throw new Error(`${label}:${lineNumber}: duplicate key ${match[1]} in inline table`);
        }
        if (match[2].startsWith('{') || match[2].startsWith('[')) {
            throw new Error(`${label}:${lineNumber}: nested inline structures are not supported`);
        }
        record.set(match[1], parseScalar(match[2], label, lineNumber));
    }
    return record;
}

function parseValue(text, label, lineNumber) {
    if (text.startsWith('{')) {
        if (!text.endsWith('}')) {
            throw new Error(`${label}:${lineNumber}: unterminated inline table`);
        }
        return parseInlineTable(text, label, lineNumber);
    }
    if (text.startsWith('[')) {
        if (!text.endsWith(']')) {
            throw new Error(`${label}:${lineNumber}: unterminated array`);
        }
        const inner = text.slice(1, -1).trim();
        if (inner === '') return [];
        return splitInline(inner).map((part) =>
            parseScalar(part.trim(), label, lineNumber),
        );
    }
    return parseScalar(text, label, lineNumber);
}

function parseToml(source, label) {
    const tables = new Map();
    let current = null;
    let currentName = null;

    source.split('\n').forEach((rawLine, index) => {
        const lineNumber = index + 1;
        const line = stripComment(rawLine, label, lineNumber).trim();
        if (line === '') return;

        const header = /^\[([A-Za-z0-9_.-]+)\]$/.exec(line);
        if (header) {
            if (tables.has(header[1])) {
                throw new Error(`${label}:${lineNumber}: duplicate table [${header[1]}]`);
            }
            current = new Map();
            currentName = header[1];
            tables.set(currentName, current);
            return;
        }

        const match = /^([A-Za-z0-9_.-]+)\s*=\s*(.+?)\s*$/.exec(line);
        if (!match) throw new Error(`${label}:${lineNumber}: unsupported line ${line}`);
        if (current === null) {
            throw new Error(`${label}:${lineNumber}: key ${match[1]} outside a table`);
        }
        if (current.has(match[1])) {
            throw new Error(`${label}:${lineNumber}: duplicate key ${match[1]} in [${currentName}]`);
        }
        current.set(match[1], parseValue(match[2], label, lineNumber));
    });

    return tables;
}

// === Local Manifest And Lock Validation ===

function recordToString(record) {
    return [...record.entries()]
        .map(([key, value]) => `${key} = ${JSON.stringify(value)}`)
        .sort()
        .join(', ');
}

function expectedToString(expected) {
    return Object.entries(expected)
        .map(([key, value]) => `${key} = ${JSON.stringify(value)}`)
        .sort()
        .join(', ');
}

/// Rejects every mutable Git selector regardless of what the expectation says.
function assertImmutableGitRecord(label, name, record) {
    for (const selector of ['branch', 'tag', 'subdir_rev']) {
        check(
            !record.has(selector),
            `${label}: ${name} uses the mutable selector "${selector}"`,
        );
    }
    const revision = record.get('rev');
    check(
        typeof revision === 'string' && /^[0-9a-f]{40}$/.test(revision),
        `${label}: ${name} must pin an immutable 40-hex commit, got ${JSON.stringify(revision)}`,
    );
}

function validateRecord(label, name, actual, expected) {
    if (!(actual instanceof Map)) {
        check(false, `${label}: ${name} is not a dependency record`);
        return false;
    }
    if (actual.has('git')) assertImmutableGitRecord(label, name, actual);
    return checkEqual(
        recordToString(actual),
        expectedToString(expected),
        `${label}: ${name} dependency record drift`,
    );
}

function validateManifestSource(spec, source) {
    const label = spec.path;
    const counts = { records: 0, gitRecords: 0 };

    let tables;
    try {
        tables = parseToml(source, label);
    } catch (error) {
        check(false, error.message);
        return counts;
    }

    const unexpectedTables = [...tables.keys()].filter(
        (name) => !MANIFEST_TABLES.includes(name),
    );
    check(
        unexpectedTables.length === 0,
        `${label}: unexpected table(s) ${unexpectedTables.join(', ')}`,
    );

    const packageTable = tables.get('package');
    if (check(packageTable !== undefined, `${label}: missing [package]`)) {
        const unknown = [...packageTable.keys()].filter(
            (key) => !PACKAGE_TABLE_KEYS.includes(key),
        );
        check(unknown.length === 0, `${label}: unknown [package] key(s) ${unknown.join(', ')}`);
        checkEqual(packageTable.get('name'), spec.packageName, `${label}: package name drift`);

        const expectedPublishedAt = spec.packageKey
            ? packageByKey(spec.packageKey).currentId
            : null;
        checkEqual(
            packageTable.get('published-at') ?? null,
            expectedPublishedAt,
            `${label}: published-at drift`,
        );
    }

    const dependencies = tables.get('dependencies');
    if (check(dependencies !== undefined, `${label}: missing [dependencies]`)) {
        checkEqual(
            [...dependencies.keys()].sort().join(', '),
            Object.keys(spec.dependencies).sort().join(', '),
            `${label}: dependency name set drift`,
        );
        for (const [name, expected] of Object.entries(spec.dependencies)) {
            const actual = dependencies.get(name);
            if (!check(actual !== undefined, `${label}: missing dependency ${name}`)) continue;
            validateRecord(label, name, actual, expected);
            counts.records += 1;
            if (actual instanceof Map && actual.has('git')) counts.gitRecords += 1;
        }
        // Any dependency the spec does not name is still held to immutability.
        for (const [name, actual] of dependencies) {
            if (Object.hasOwn(spec.dependencies, name)) continue;
            if (actual instanceof Map && actual.has('git')) {
                assertImmutableGitRecord(label, name, actual);
                counts.gitRecords += 1;
            }
        }
    }

    const expectedAddresses = spec.packageKey
        ? { [packageByKey(spec.packageKey).addressName]: packageByKey(spec.packageKey).originalId }
        : spec.addresses;
    const addresses = tables.get('addresses');
    if (check(addresses !== undefined, `${label}: missing [addresses]`)) {
        checkEqual(
            recordToString(addresses),
            expectedToString(expectedAddresses),
            `${label}: named address drift`,
        );
    }

    return counts;
}

function validateLockSource(source) {
    const label = 'Move.lock';
    const counts = { nodes: 0, gitRecords: 0, suiEdges: 0 };

    let tables;
    try {
        tables = parseToml(source, label);
    } catch (error) {
        check(false, error.message);
        return counts;
    }

    const move = tables.get('move');
    if (check(move !== undefined, `${label}: missing [move]`)) {
        checkEqual(move.get('version'), LOCK_VERSION, `${label}: lock format version drift`);
    }

    const expectedNames = Object.keys(LOCK_NODES).sort();
    const unexpectedTables = [...tables.keys()].filter(
        (name) =>
            name !== 'move' &&
            !LOCK_ENVIRONMENTS.some((environment) => name.startsWith(`pinned.${environment}.`)),
    );
    check(
        unexpectedTables.length === 0,
        `${label}: unexpected table(s) ${unexpectedTables.join(', ')}`,
    );

    for (const environment of LOCK_ENVIRONMENTS) {
        const prefix = `pinned.${environment}.`;
        const present = [...tables.keys()]
            .filter((name) => name.startsWith(prefix))
            .map((name) => name.slice(prefix.length));
        if (
            !checkEqual(
                present.sort().join(', '),
                expectedNames.join(', '),
                `${label}: ${environment} pinned node set drift`,
            )
        ) {
            continue;
        }

        for (const name of expectedNames) {
            const node = tables.get(`${prefix}${name}`);
            const nodeLabel = `${label}: ${prefix}${name}`;
            const unknown = [...node.keys()].filter((key) => !LOCK_NODE_KEYS.includes(key));
            check(unknown.length === 0, `${nodeLabel} has unknown key(s) ${unknown.join(', ')}`);
            for (const key of LOCK_NODE_KEYS) {
                check(node.has(key), `${nodeLabel} is missing ${key}`);
            }
            checkEqual(
                node.get('use_environment'),
                environment,
                `${nodeLabel} declares the wrong environment`,
            );

            const digest = node.get('manifest_digest');
            check(
                typeof digest === 'string' && LOCK_DIGEST_PATTERN.test(digest),
                `${nodeLabel} manifest_digest must be 64 uppercase hex digits, got ` +
                    `${JSON.stringify(digest)}`,
            );

            const source = node.get('source');
            const sourceOk = validateRecord(
                nodeLabel,
                'source',
                source,
                LOCK_NODES[name].source,
            );
            if (source instanceof Map && source.has('git')) counts.gitRecords += 1;

            const deps = node.get('deps');
            let depsOk = false;
            if (deps instanceof Map) {
                depsOk = checkEqual(
                    recordToString(deps),
                    expectedToString(LOCK_NODES[name].deps),
                    `${nodeLabel} resolved dependency drift`,
                );
            } else {
                check(false, `${nodeLabel} has no deps record`);
            }

            if (sourceOk && depsOk) counts.nodes += 1;
        }

        // Each local normalized interface must resolve its Sui edge to the one
        // pinned framework revision, by node name and by that node's source.
        for (const spec of MANIFESTS) {
            if (!spec.lockNode) continue;
            const nodeLabel = `${label}: ${prefix}${spec.lockNode}`;
            const deps = tables.get(`${prefix}${spec.lockNode}`)?.get('deps');
            if (!(deps instanceof Map)) {
                check(false, `${nodeLabel} has no deps record`);
                continue;
            }
            const suiNode = deps.get('Sui');
            if (!check(typeof suiNode === 'string', `${nodeLabel} does not bind a Sui dependency`)) {
                continue;
            }
            const suiSource = tables.get(`${prefix}${suiNode}`)?.get('source');
            if (!(suiSource instanceof Map)) {
                check(false, `${nodeLabel} binds Sui to the unknown node ${suiNode}`);
                continue;
            }
            if (
                checkEqual(
                    recordToString(suiSource),
                    expectedToString({
                        git: SUI_GIT,
                        subdir: SUI_FRAMEWORK_SUBDIR,
                        rev: SUI_FRAMEWORK_REV,
                    }),
                    `${nodeLabel} resolves Sui through ${suiNode} to the wrong framework record`,
                )
            ) {
                counts.suiEdges += 1;
            }
        }
    }

    return counts;
}

function readPackageFile(relativePath) {
    return readFileSync(join(PACKAGE_DIR, relativePath), 'utf8');
}

function verifyLocalPins() {
    const totals = { manifests: 0, records: 0, gitRecords: 0, nodes: 0, suiEdges: 0 };
    for (const spec of MANIFESTS) {
        const counts = validateManifestSource(spec, readPackageFile(spec.path));
        totals.manifests += 1;
        totals.records += counts.records;
        totals.gitRecords += counts.gitRecords;
    }

    const lock = validateLockSource(readPackageFile('Move.lock'));
    totals.nodes = lock.nodes;
    totals.gitRecords += lock.gitRecords;
    totals.suiEdges = lock.suiEdges;

    return totals;
}

// === Self Test ===

// Offline regression cover for the two trust boundaries this gate depends on:
// the GraphQL response shape and the committed dependency records. It makes no
// network request and mutates no file; every negative case runs against an
// in-memory copy of a committed file or a synthetic response object.

const GOOD_FUNCTION = {
    name: 'collect_fee',
    visibility: 'PUBLIC',
    isEntry: false,
    typeParameters: [{ constraints: [] }, { constraints: ['COPY', 'DROP'] }],
    parameters: [
        {
            signature: {
                ref: '&mut',
                body: {
                    datatype: {
                        package: SUI_ADDRESS,
                        module: 'balance',
                        type: 'Balance',
                        typeParameters: [{ typeParameter: 0 }],
                    },
                },
            },
        },
        { signature: { ref: '&', body: 'address' } },
    ],
    return: [{ signature: { body: 'u64' } }],
};

const GOOD_STRUCT = {
    name: 'Pool',
    abilities: ['KEY', 'STORE'],
    typeParameters: [
        { isPhantom: true, constraints: [] },
        { isPhantom: false, constraints: ['STORE'] },
    ],
};

function clone(value) {
    return structuredClone(value);
}

function withFunction(mutate) {
    const value = clone(GOOD_FUNCTION);
    mutate(value);
    return value;
}

function withStruct(mutate) {
    const value = clone(GOOD_STRUCT);
    mutate(value);
    return value;
}

/// Replaces the first literal occurrence, asserting that it was present.
function mutateSource(source, from, to) {
    const index = source.indexOf(from);
    if (index === -1) throw new Error(`self-test fixture missing: ${from}`);
    return source.slice(0, index) + to + source.slice(index + from.length);
}

function selfTestCases() {
    const rootManifest = readPackageFile('Move.toml');
    const turbosManifest = readPackageFile('interfaces/turbos/Move.toml');
    const lock = readPackageFile('Move.lock');

    const FIRST_LOCK_DIGEST = lock.match(/manifest_digest = "([^"]*)"/)?.[1];
    if (!FIRST_LOCK_DIGEST) throw new Error('self-test fixture missing: manifest_digest');

    const rootSpec = MANIFESTS.find((spec) => spec.path === 'Move.toml');
    const turbosSpec = MANIFESTS.find(
        (spec) => spec.path === 'interfaces/turbos/Move.toml',
    );
    const manifest = (spec, source) => () => validateManifestSource(spec, source);
    const lockCase = (source) => () => validateLockSource(source);

    return [
        // --- Positive: the committed files and a well-formed response ---
        {
            name: 'committed manifests and lock validate clean',
            expect: 'pass',
            run: () => verifyLocalPins(),
        },
        {
            name: 'well-formed function renders canonically',
            expect: 'pass',
            run: () => {
                const rendered = renderFunction('collect_fee', GOOD_FUNCTION, STD_ADDRESS);
                if (
                    rendered !==
                    'public fun collect_fee<$0, $1: copy+drop>' +
                        '(&mut @sui::balance::Balance<$0>, &address): u64'
                ) {
                    throw new Error(`unexpected rendering: ${rendered}`);
                }
            },
        },
        {
            name: 'well-formed struct renders canonically',
            expect: 'pass',
            run: () => {
                const rendered = renderStruct('Pool', GOOD_STRUCT);
                if (rendered !== 'struct Pool<phantom $0, $1: store> has store, key') {
                    throw new Error(`unexpected rendering: ${rendered}`);
                }
            },
        },

        // --- Negative: ABI response shape ---
        {
            name: 'null parameter list is rejected',
            run: () => renderFunction('collect_fee', withFunction((f) => { f.parameters = null; }), STD_ADDRESS),
        },
        {
            name: 'null return list is rejected',
            run: () => renderFunction('collect_fee', withFunction((f) => { f.return = null; }), STD_ADDRESS),
        },
        {
            name: 'null type-parameter list is rejected',
            run: () => renderFunction('collect_fee', withFunction((f) => { f.typeParameters = null; }), STD_ADDRESS),
        },
        {
            name: 'null struct ability list is rejected',
            run: () => renderStruct('Pool', withStruct((s) => { s.abilities = null; })),
        },
        {
            name: 'missing isEntry is rejected',
            run: () => renderFunction('collect_fee', withFunction((f) => { delete f.isEntry; }), STD_ADDRESS),
        },
        {
            name: 'null isEntry is rejected',
            run: () => renderFunction('collect_fee', withFunction((f) => { f.isEntry = null; }), STD_ADDRESS),
        },
        {
            name: 'unknown ability is rejected',
            run: () => renderStruct('Pool', withStruct((s) => { s.abilities = ['KEY', 'SEAL']; })),
        },
        {
            name: 'duplicate ability is rejected',
            run: () => renderStruct('Pool', withStruct((s) => { s.abilities = ['KEY', 'KEY']; })),
        },
        {
            name: 'unknown constraint is rejected',
            run: () => renderFunction('collect_fee', withFunction((f) => { f.typeParameters[1].constraints = ['SEAL']; }), STD_ADDRESS),
        },
        {
            name: 'duplicate constraint is rejected',
            run: () => renderFunction('collect_fee', withFunction((f) => { f.typeParameters[1].constraints = ['COPY', 'COPY']; }), STD_ADDRESS),
        },
        {
            name: 'unknown visibility is rejected',
            run: () => renderFunction('collect_fee', withFunction((f) => { f.visibility = 'PACKAGE'; }), STD_ADDRESS),
        },
        {
            name: 'renamed function is rejected',
            run: () => renderFunction('collect_fee', withFunction((f) => { f.name = 'collect_fee_v2'; }), STD_ADDRESS),
        },
        {
            name: 'missing signature body is rejected',
            run: () => renderFunction('collect_fee', withFunction((f) => { delete f.parameters[1].signature.body; }), STD_ADDRESS),
        },
        {
            name: 'unknown reference kind is rejected',
            run: () => renderFunction('collect_fee', withFunction((f) => { f.parameters[1].signature.ref = '&imm'; }), STD_ADDRESS),
        },
        {
            // The live schema omits `ref` for by-value; explicit null is novel.
            name: 'explicit null reference is rejected',
            run: () =>
                renderFunction(
                    'f',
                    {
                        name: 'f',
                        visibility: 'PUBLIC',
                        isEntry: false,
                        typeParameters: [],
                        parameters: [{ signature: { ref: null, body: 'u64' } }],
                        return: [],
                    },
                    STD_ADDRESS,
                ),
        },
        {
            name: 'absent reference still renders by value',
            expect: 'pass',
            run: () => {
                const rendered = renderFunction(
                    'f',
                    {
                        name: 'f',
                        visibility: 'PUBLIC',
                        isEntry: false,
                        typeParameters: [],
                        parameters: [{ signature: { body: 'u64' } }],
                        return: [],
                    },
                    STD_ADDRESS,
                );
                if (rendered !== 'public fun f(u64)') {
                    throw new Error(`unexpected rendering: ${rendered}`);
                }
            },
        },
        {
            name: 'well-formed type origins build cleanly',
            expect: 'pass',
            run: () => {
                const origins = buildTypeOrigins('origins', [
                    { module: 'm', struct: 'S', definingId: STD_ADDRESS },
                    { module: 'm', struct: 'T', definingId: SUI_ADDRESS },
                ]);
                if (origins.size !== 2 || origins.get('m::S') !== STD_ADDRESS) {
                    throw new Error('unexpected origin map');
                }
            },
        },
        {
            // A wrong defining id followed by the expected one must not be
            // overwritten into a passing lookup.
            name: 'duplicate type origin with a conflicting defining id is rejected',
            run: () =>
                buildTypeOrigins('origins', [
                    { module: 'm', struct: 'S', definingId: `0x${'0'.repeat(63)}3` },
                    { module: 'm', struct: 'S', definingId: STD_ADDRESS },
                ]),
        },
        {
            name: 'duplicate type origin with the same defining id is rejected',
            run: () =>
                buildTypeOrigins('origins', [
                    { module: 'm', struct: 'S', definingId: STD_ADDRESS },
                    { module: 'm', struct: 'S', definingId: STD_ADDRESS },
                ]),
        },
        {
            name: 'novel type body shape is rejected',
            run: () => renderFunction('collect_fee', withFunction((f) => { f.parameters[1].signature.body = { enumType: 'X' }; }), STD_ADDRESS),
        },
        {
            name: 'unknown primitive type is rejected',
            run: () => renderFunction('collect_fee', withFunction((f) => { f.parameters[1].signature.body = 'u512'; }), STD_ADDRESS),
        },
        {
            name: 'extra response field is rejected',
            run: () => renderFunction('collect_fee', withFunction((f) => { f.attributes = []; }), STD_ADDRESS),
        },
        {
            name: 'missing datatype type parameters are rejected',
            run: () => renderFunction('collect_fee', withFunction((f) => { delete f.parameters[0].signature.body.datatype.typeParameters; }), STD_ADDRESS),
        },
        {
            name: 'missing struct phantom flag is rejected',
            run: () => renderStruct('Pool', withStruct((s) => { delete s.typeParameters[0].isPhantom; })),
        },

        // --- Negative: manifest records ---
        {
            name: 'commented-out dependency cannot satisfy an expectation',
            run: manifest(
                turbosSpec,
                mutateSource(turbosManifest, 'Sui = {', '# Sui = {'),
            ),
        },
        {
            name: 'missing rev is rejected',
            run: manifest(
                turbosSpec,
                mutateSource(turbosManifest, `, rev = "${REV.sui}"`, ''),
            ),
        },
        {
            name: 'branch selector is rejected',
            run: manifest(
                turbosSpec,
                mutateSource(turbosManifest, `rev = "${REV.sui}"`, 'branch = "main"'),
            ),
        },
        {
            name: 'tag selector is rejected',
            run: manifest(
                turbosSpec,
                mutateSource(turbosManifest, `rev = "${REV.sui}"`, 'tag = "mainnet-v1.35.2"'),
            ),
        },
        {
            name: 'wrong-but-40-hex Sui revision is rejected',
            run: manifest(
                turbosSpec,
                mutateSource(turbosManifest, REV.sui, REV.suiLegacy),
            ),
        },
        {
            name: 'root Sui revision change is rejected',
            run: manifest(rootSpec, mutateSource(rootManifest, REV.sui, REV.suiBluefin)),
        },
        {
            name: 'wrong Git repository is rejected',
            run: manifest(
                turbosSpec,
                mutateSource(turbosManifest, SUI_GIT, 'https://github.com/attacker/sui.git'),
            ),
        },
        {
            name: 'wrong Git subdirectory is rejected',
            run: manifest(
                turbosSpec,
                mutateSource(turbosManifest, SUI_FRAMEWORK_SUBDIR, MOVE_STDLIB_SUBDIR),
            ),
        },
        {
            name: 'dropped override rule is rejected',
            run: manifest(
                turbosSpec,
                mutateSource(turbosManifest, ', override = true', ''),
            ),
        },
        {
            name: 'added override rule is rejected',
            run: manifest(
                rootSpec,
                mutateSource(
                    rootManifest,
                    `rev = "${REV.mmt}" }`,
                    `rev = "${REV.mmt}", override = true }`,
                ),
            ),
        },
        {
            name: 'extra Git dependency is rejected',
            run: manifest(
                turbosSpec,
                mutateSource(
                    turbosManifest,
                    '[addresses]',
                    `Extra = { git = "${MOVE_STL_GIT}", rev = "main" }\n\n[addresses]`,
                ),
            ),
        },
        {
            name: 'duplicate manifest key is rejected',
            run: manifest(
                turbosSpec,
                mutateSource(turbosManifest, '[addresses]', '[addresses]\nturbos_clmm = "0x1"'),
            ),
        },
        {
            name: 'duplicate manifest table is rejected',
            run: manifest(turbosSpec, `${turbosManifest}\n[addresses]\n`),
        },
        {
            name: 'changed published-at is rejected',
            run: manifest(
                turbosSpec,
                mutateSource(turbosManifest, packageByKey('turbos').currentId, `0x${'a'.repeat(64)}`),
            ),
        },
        {
            name: 'changed named address is rejected',
            run: manifest(
                turbosSpec,
                mutateSource(turbosManifest, packageByKey('turbos').originalId, `0x${'b'.repeat(64)}`),
            ),
        },
        {
            name: 'unexpected manifest table is rejected',
            run: manifest(turbosSpec, `${turbosManifest}\n[dev-dependencies]\nX = { local = "." }\n`),
        },
        {
            name: 'rebound local interface path is rejected',
            run: manifest(
                rootSpec,
                mutateSource(rootManifest, 'local = "interfaces/turbos"', 'local = "interfaces/cetus"'),
            ),
        },

        // --- Negative: lock records ---
        {
            name: 'lock branch selector is rejected',
            run: lockCase(mutateSource(lock, `rev = "${REV.bluefin}"`, 'branch = "main"')),
        },
        {
            name: 'lock tag selector is rejected',
            run: lockCase(mutateSource(lock, `rev = "${REV.mmt}"`, 'tag = "v1"')),
        },
        {
            name: 'lock missing rev is rejected',
            run: lockCase(mutateSource(lock, `, rev = "${REV.bluefin}"`, '')),
        },
        {
            name: 'lock wrong-but-40-hex Sui revision is rejected',
            run: lockCase(
                mutateSource(
                    lock,
                    `[pinned.testnet.Sui]\nsource = { git = "${SUI_GIT}", subdir = "${SUI_FRAMEWORK_SUBDIR}", rev = "${REV.sui}" }`,
                    `[pinned.testnet.Sui]\nsource = { git = "${SUI_GIT}", subdir = "${SUI_FRAMEWORK_SUBDIR}", rev = "${REV.suiLegacy}" }`,
                ),
            ),
        },
        {
            name: 'lock rebound Sui edge is rejected',
            run: lockCase(
                mutateSource(
                    lock,
                    '[pinned.mainnet.TurbosCLMM]\nsource = { local = "interfaces/turbos" }\nuse_environment = "mainnet"',
                    '[pinned.mainnet.TurbosCLMM]\nsource = { local = "interfaces/turbos" }\nuse_environment = "mainnet"',
                ).replace(
                    /(\[pinned\.mainnet\.TurbosCLMM\][\s\S]*?deps = \{ Sui = ")Sui(" \})/,
                    '$1Sui_1$2',
                ),
            ),
        },
        {
            name: 'lock wrong Git repository is rejected',
            run: lockCase(mutateSource(lock, MMT_GIT, 'https://github.com/attacker/mmt.git')),
        },
        {
            name: 'lock wrong subdirectory is rejected',
            run: lockCase(
                mutateSource(
                    lock,
                    `subdir = "mmt_v3", rev = "${REV.mmt}"`,
                    `subdir = ".", rev = "${REV.mmt}"`,
                ),
            ),
        },
        {
            name: 'lock duplicate section is rejected',
            run: lockCase(`${lock}\n[pinned.mainnet.Sui_2]\nsource = { root = true }\n`),
        },
        {
            name: 'lock duplicate key is rejected',
            run: lockCase(
                mutateSource(lock, '[pinned.mainnet.MoveStdlib]\n', '[pinned.mainnet.MoveStdlib]\ndeps = {}\n'),
            ),
        },
        {
            name: 'extra lock node is rejected',
            run: lockCase(
                `${lock}\n[pinned.mainnet.Rogue]\nsource = { git = "${MOVE_STL_GIT}", subdir = ".", rev = "main" }\nuse_environment = "mainnet"\nmanifest_digest = "00"\ndeps = {}\n`,
            ),
        },
        {
            name: 'missing lock node is rejected',
            run: lockCase(lock.replace(/\[pinned\.testnet\.MoveSTL\][\s\S]*?\n\n/, '')),
        },
        {
            name: 'rebound root dependency is rejected',
            run: lockCase(
                mutateSource(lock, 'IntegerMate = "IntegerMate_1"', 'IntegerMate = "IntegerMate"'),
            ),
        },
        {
            name: 'lock format version change is rejected',
            run: lockCase(mutateSource(lock, 'version = 4', 'version = 5')),
        },
        {
            name: 'lock local path change is rejected',
            run: lockCase(
                mutateSource(lock, 'source = { local = "interfaces/cetus" }', 'source = { local = "interfaces/turbos" }'),
            ),
        },
        {
            name: 'boolean lock manifest digest is rejected',
            run: lockCase(
                mutateSource(lock, `manifest_digest = "${FIRST_LOCK_DIGEST}"`, 'manifest_digest = false'),
            ),
        },
        {
            name: 'malformed lock manifest digest is rejected',
            run: lockCase(
                mutateSource(
                    lock,
                    `manifest_digest = "${FIRST_LOCK_DIGEST}"`,
                    'manifest_digest = "not-a-digest"',
                ),
            ),
        },
        {
            name: 'lowercase lock manifest digest is rejected',
            run: lockCase(
                mutateSource(
                    lock,
                    `manifest_digest = "${FIRST_LOCK_DIGEST}"`,
                    `manifest_digest = "${FIRST_LOCK_DIGEST.toLowerCase()}"`,
                ),
            ),
        },
    ];
}

function runSelfTest() {
    let passed = 0;
    let failed = 0;

    for (const testCase of selfTestCases()) {
        const before = failures.length;
        let thrown = null;
        try {
            testCase.run();
        } catch (error) {
            thrown = error;
        }
        const recorded = failures.splice(before).length;
        const rejected = thrown !== null || recorded > 0;
        const wantPass = testCase.expect === 'pass';
        const ok = wantPass ? !rejected : rejected;

        if (ok) passed += 1;
        else failed += 1;
        process.stdout.write(
            `  ${ok ? 'ok  ' : 'FAIL'} ${wantPass ? 'accepts' : 'rejects'}: ${testCase.name}` +
                `${ok || wantPass ? '' : ' (accepted)'}` +
                `${ok || !wantPass ? '' : ` (${thrown?.message ?? `${recorded} failure(s)`})`}\n`,
        );
    }

    process.stdout.write(
        `check_mainnet_abi self-test: ${failed === 0 ? 'PASS' : 'FAIL'} ` +
            `${passed}/${passed + failed} cases\n`,
    );
    process.exit(failed === 0 ? 0 : 1);
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
    if (process.argv.includes('--self-test')) {
        runSelfTest();
        return;
    }

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
    const pins = verifyLocalPins();
    process.stdout.write(
        `${status(before)} ${'local pins'.padEnd(21)} ` +
            `manifests ${pins.manifests} dependency records ${pins.records} ` +
            `lock nodes ${pins.nodes} immutable Git records ${pins.gitRecords} ` +
            `local-interface Sui edges ${pins.suiEdges}\n`,
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
