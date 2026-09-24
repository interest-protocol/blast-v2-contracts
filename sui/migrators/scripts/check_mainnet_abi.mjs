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
    integerMate: '09a12d9b171122883d9350039d4ed6e8400033b9',
    integerMateBluefin: '06660f704c4ac1d443ab62346a46b5b60d49df33',
    integerLibrary: '8a534bd1c0b334cd3937c27987f3147a06ba6a18',
    moveStl: '0681fec63a310ae753d03a06f7c05d3e2925bb09',
};

/// The mainnet packages the pinned Git revisions of Cetus's libraries declare as `published-at`:
/// integer-mate 09a12d9b is version 7 and move-stl 0681fec6 is version 5.
const INTEGER_MATE_ORIGINAL =
    '0x714a63a0dba6da4f017b42d5d0fb78867f18bcde904868e51d951a5a6f5b7f57';
const INTEGER_MATE_PUBLISHED =
    '0xdfaadf86be9af246900d1e3f3b996cf549e7948e662a9977bdd7646d8fa3a778';
const MOVE_STL_ORIGINAL = '0xbe21a06129308e0495431d12286127897aff07a8ade3970495a4404d97f9eaaa';
const MOVE_STL_PUBLISHED = '0x8569b7efebec65c73b9dc15c5ac2a9542870d286fa79a3feedffbaa94ed53002';

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
                functions: ['get_tick_range'],
            },
            {
                name: 'pool',
                sha256: 'd1436b0837eab8912797b91ed68755ad6e4228243f188a43c42ea040e844e97c',
                structs: ['Pool'],
                functions: [
                    'add_liquidity_with_fixed_amount',
                    'collect_fee',
                    'create_pool_and_get_object',
                    'current_sqrt_price',
                    'get_tick_manager',
                    'open_position',
                    'share_pool_object',
                    'swap',
                ],
            },
            {
                name: 'position',
                sha256: 'ea83d3b9a65c7f62579dd0a902ddad8ade46cec277e5781ab9e52783c48caaec',
                structs: ['Position'],
                functions: ['liquidity', 'lower_tick', 'pool_id', 'upper_tick'],
            },
            {
                name: 'tick',
                sha256: '2ac4cbe4fa1270ac16e3ffa4716fd745fef0a480dd9685947e17539b269a10f8',
                structs: ['TickInfo', 'TickManager'],
                functions: ['get_tick_from_manager', 'sqrt_price'],
            },
        ],
    },
    {
        key: 'cetus',
        label: 'Cetus CLMM',
        addressName: 'cetus_clmm',
        originalId:
            '0x1eabed72c53feb3805120a081dc15963c204dc8d091542592abaf7a35689b2fb',
        currentId:
            '0x260693ec785a6e6c9d81d58c7d2ff72f1288ae0fa6a9725abe05a6478b11f084',
        version: 15,
        digest: '9rZP5D79m4Yfq9fvtPujtpvU5rhfiYm1JS6LaxcMZVSu',
        previousTransaction: '5sSoTfTiti8kXjJhZeYuFWFcxxvjbZpFQ96rZ3dzeQbC',
        manifest: 'interfaces/cetus/Move.toml',
        // Cetus links the library versions the local interface's pinned Git revisions declare.
        linkage: [
            [STD_ADDRESS, STD_ADDRESS, 25],
            [SUI_ADDRESS, SUI_ADDRESS, 59],
            [INTEGER_MATE_ORIGINAL, INTEGER_MATE_PUBLISHED, 7],
            [MOVE_STL_ORIGINAL, MOVE_STL_PUBLISHED, 5],
        ],
        modules: [
            {
                name: 'clmm_math',
                sha256: '851de164740b305acc2422452e30b34fff80f366113a286719c4ee8f25d41e6f',
                structs: [],
                functions: ['get_liquidity_by_amount'],
            },
            {
                name: 'config',
                sha256: 'd0575fcd8fa5e6d63a779a19fbc1ee276459d151d8045bc7e7a9f5f380adfad5',
                structs: ['GlobalConfig'],
                functions: ['get_fee_rate'],
            },
            {
                name: 'factory',
                sha256: '4cd33aca821e17cccb0004e3c78ec6033b7fec0360fdf17c03393e976efa5e9b',
                structs: ['PoolCreationCap', 'Pools'],
                // Revision 8 introduced the pool-creation capability.
                structOrigins: {
                    PoolCreationCap:
                        '0x157468379cfe5616c063ae39a889dd184ad48350d3e08f8d9b4ade22b8e3fb61',
                },
                functions: [
                    'is_right_order',
                    'mint_pool_creation_cap',
                    'register_permission_pair',
                ],
            },
            {
                name: 'pool',
                sha256: '059cbeeb4502c7e54b1a9ada73709505f9572f4c80c441c1c31fbee64c32c7a1',
                structs: ['AddLiquidityReceipt', 'FlashSwapReceipt', 'Pool'],
                functions: [
                    'add_liquidity_fix_coin',
                    'add_liquidity_pay_amount',
                    'collect_fee',
                    'current_sqrt_price',
                    'current_tick_index',
                    'flash_swap',
                    'open_position',
                    'repay_add_liquidity',
                    'repay_flash_swap',
                    'swap_pay_amount',
                    'tick_spacing',
                ],
            },
            {
                name: 'pool_creator',
                sha256: '23c78096ed45feda5349e098d9827f37cee0fce662544e98ea28de5f6e8c57b6',
                structs: [],
                functions: ['create_pool_v3_with_creation_cap', 'full_range_tick_range'],
            },
            {
                name: 'position',
                sha256: '78f71fd13a5ab6528509d1a2ceb279e4d6616cd8e6877baf4a5ee25627789cc3',
                structs: ['Position'],
                functions: ['liquidity', 'pool_id', 'tick_range'],
            },
        ],
    },
    {
        key: 'lp_burn',
        label: 'Cetus LP Burn',
        addressName: 'lp_burn',
        originalId:
            '0x12d73de9a6bc3cb658ec9dc0fe7de2662be1cea5c76c092fcc3606048cdbac27',
        currentId:
            '0xc4aabc874f5060d3147d8f74c14e3a8a1f9f8d92edea138a51635395ed167cd9',
        version: 8,
        digest: '77pAM8TdzRbHqA4b5ccyLQHZzNNhj3k15cZMtD37qLHH',
        previousTransaction: '6m7WqScGvn4M6n5k9HE5241wGNW8izpdSCs69Smy3EKy',
        manifest: 'interfaces/cetus_lp_burn/Move.toml',
        // LP Burn must call exactly the Cetus, vester, and token revisions this lock resolves.
        linkage: [
            [STD_ADDRESS, STD_ADDRESS, 25],
            [SUI_ADDRESS, SUI_ADDRESS, 59],
            [
                '0x06864a6f921804860930db6ddbe2e16acdf8504495ea7481637a1c8b9a8fe54b',
                '0x06864a6f921804860930db6ddbe2e16acdf8504495ea7481637a1c8b9a8fe54b',
                1,
            ],
            [
                '0x1eabed72c53feb3805120a081dc15963c204dc8d091542592abaf7a35689b2fb',
                '0x260693ec785a6e6c9d81d58c7d2ff72f1288ae0fa6a9725abe05a6478b11f084',
                15,
            ],
            [INTEGER_MATE_ORIGINAL, INTEGER_MATE_PUBLISHED, 7],
            [
                '0x9d2f067d3b9d19ac0f8d2e5c2c393b1760232083e42005b2e5df39c06064d522',
                '0x48dcc51091e692a0c8a64930fc839fb5a8e58de3590c084a8322b9cd34754c36',
                2,
            ],
            [MOVE_STL_ORIGINAL, MOVE_STL_PUBLISHED, 5],
        ],
        modules: [
            {
                name: 'lp_burn',
                sha256: '653b9673273bd5f5e237b3105959410e757abc11b08535481a40c6ae0d88930b',
                structs: ['BurnManager', 'CetusLPBurnProof'],
                functions: ['burn_lp_v2', 'collect_fee'],
            },
        ],
    },
    {
        // Linkage-only dependency of LP Burn; nothing calls it.
        key: 'vester',
        label: 'Cetus CLMM Vester',
        addressName: 'clmm_vester',
        originalId:
            '0x9d2f067d3b9d19ac0f8d2e5c2c393b1760232083e42005b2e5df39c06064d522',
        currentId:
            '0x48dcc51091e692a0c8a64930fc839fb5a8e58de3590c084a8322b9cd34754c36',
        version: 2,
        digest: '8jHEsYqEFhApzrEL1r9oG2gMq2KNgDtni9mJUakQZXwS',
        previousTransaction: 'Gw3d3xwyJtgQ2Qf9GKUnJAwhyiRNGDZwyTMzWbFU8kk5',
        manifest: 'interfaces/cetus_clmm_vester/Move.toml',
        modules: [],
    },
    {
        // Linkage-only dependency of LP Burn and the vester; nothing calls it.
        key: 'token',
        label: 'CETUS token',
        addressName: 'cetus',
        originalId:
            '0x06864a6f921804860930db6ddbe2e16acdf8504495ea7481637a1c8b9a8fe54b',
        currentId:
            '0x06864a6f921804860930db6ddbe2e16acdf8504495ea7481637a1c8b9a8fe54b',
        version: 1,
        digest: '8ySdLMhVG9RRwD4zB3s4JwohqNraxTwbF1RWFSuXvL32',
        previousTransaction: 'CqKi5wdUgWsB3EPDzBtSRasS6hkKZ2TvurLGKVCjc1kC',
        manifest: 'interfaces/cetus_token/Move.toml',
        modules: [],
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
            blast_admin: { local: '../admin' },
            blast_fun: { local: '../launchpad' },
            BluefinSpot: { git: BLUEFIN_GIT, rev: REV.bluefin },
            CetusClmm: { local: 'interfaces/cetus' },
            CetusLpBurn: { local: 'interfaces/cetus_lp_burn' },
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
        path: 'interfaces/cetus_lp_burn/Move.toml',
        packageName: 'CetusLpBurn',
        packageKey: 'lp_burn',
        lockNode: 'CetusLpBurn',
        dependencies: {
            Sui: {
                git: SUI_GIT,
                subdir: SUI_FRAMEWORK_SUBDIR,
                rev: REV.sui,
                override: true,
            },
            CetusClmm: { local: '../cetus' },
            CetusClmmVester: { local: '../cetus_clmm_vester' },
            CetusToken: { local: '../cetus_token' },
            IntegerMate: {
                git: INTEGER_MATE_GIT,
                rev: REV.integerMate,
                override: true,
            },
        },
    },
    {
        path: 'interfaces/cetus_clmm_vester/Move.toml',
        packageName: 'CetusClmmVester',
        packageKey: 'vester',
        lockNode: 'CetusClmmVester',
        dependencies: {
            Sui: {
                git: SUI_GIT,
                subdir: SUI_FRAMEWORK_SUBDIR,
                rev: REV.sui,
                override: true,
            },
            CetusClmm: { local: '../cetus' },
            CetusToken: { local: '../cetus_token' },
            IntegerMate: {
                git: INTEGER_MATE_GIT,
                rev: REV.integerMate,
                override: true,
            },
        },
    },
    {
        path: 'interfaces/cetus_token/Move.toml',
        packageName: 'CetusToken',
        packageKey: 'token',
        lockNode: 'CetusToken',
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
    BluefinSpot: {
        source: { git: BLUEFIN_GIT, subdir: '.', rev: REV.bluefin },
        deps: { IntegerLibrary: 'IntegerLibrary', IntegerMate: 'IntegerMate', Sui: 'Sui_1' },
    },
    CetusClmm: {
        source: { local: 'interfaces/cetus' },
        deps: { IntegerMate: 'IntegerMate_1', MoveSTL: 'MoveSTL', Sui: 'Sui_2' },
    },
    CetusClmmVester: {
        source: { local: 'interfaces/cetus_clmm_vester' },
        deps: {
            CetusClmm: 'CetusClmm',
            CetusToken: 'CetusToken',
            IntegerMate: 'IntegerMate_1',
            Sui: 'Sui_2',
        },
    },
    CetusLpBurn: {
        source: { local: 'interfaces/cetus_lp_burn' },
        deps: {
            CetusClmm: 'CetusClmm',
            CetusClmmVester: 'CetusClmmVester',
            CetusToken: 'CetusToken',
            IntegerMate: 'IntegerMate_1',
            Sui: 'Sui_2',
        },
    },
    CetusToken: {
        source: { local: 'interfaces/cetus_token' },
        deps: { Sui: 'Sui_2' },
    },
    IntegerLibrary: {
        source: { git: INTEGER_LIBRARY_GIT, subdir: '.', rev: REV.integerLibrary },
        deps: { Sui: 'Sui' },
    },
    IntegerMate: {
        source: { git: INTEGER_MATE_GIT, subdir: 'sui', rev: REV.integerMateBluefin },
        deps: { Sui: 'Sui' },
    },
    IntegerMate_1: {
        source: { git: INTEGER_MATE_GIT, subdir: '.', rev: REV.integerMate },
        deps: { std: 'MoveStdlib_2', sui: 'Sui_2' },
    },
    MoveSTL: {
        source: { git: MOVE_STL_GIT, subdir: '.', rev: REV.moveStl },
        deps: { std: 'MoveStdlib_2', sui: 'Sui_2' },
    },
    MoveStdlib: {
        source: { git: SUI_GIT, subdir: MOVE_STDLIB_SUBDIR, rev: REV.suiLegacy },
        deps: {},
    },
    MoveStdlib_1: {
        source: { git: SUI_GIT, subdir: MOVE_STDLIB_SUBDIR, rev: REV.suiBluefin },
        deps: {},
    },
    MoveStdlib_2: {
        source: { git: SUI_GIT, subdir: MOVE_STDLIB_SUBDIR, rev: REV.sui },
        deps: {},
    },
    Sui: {
        source: { git: SUI_GIT, subdir: SUI_FRAMEWORK_SUBDIR, rev: REV.suiLegacy },
        deps: { MoveStdlib: 'MoveStdlib' },
    },
    Sui_1: {
        source: { git: SUI_GIT, subdir: SUI_FRAMEWORK_SUBDIR, rev: REV.suiBluefin },
        deps: { MoveStdlib: 'MoveStdlib_1' },
    },
    Sui_2: {
        source: { git: SUI_GIT, subdir: SUI_FRAMEWORK_SUBDIR, rev: REV.sui },
        deps: { MoveStdlib: 'MoveStdlib_2' },
    },
    // The immutable shared administration package is a local, inward-only edge:
    // it pins the same framework revision and adds no venue dependency.
    blast_admin: {
        source: { local: '../admin' },
        deps: { Sui: 'Sui_2' },
    },
    blast_fun: {
        source: { local: '../launchpad' },
        deps: { blast_admin: 'blast_admin', std: 'MoveStdlib_2', sui: 'Sui_2' },
    },
    blast_fun_migrators: {
        source: { root: true },
        deps: {
            BluefinSpot: 'BluefinSpot',
            CetusClmm: 'CetusClmm',
            CetusLpBurn: 'CetusLpBurn',
            IntegerLibrary: 'IntegerLibrary',
            IntegerMate: 'IntegerMate_1',
            Sui: 'Sui_2',
            blast_admin: 'blast_admin',
            blast_fun: 'blast_fun',
        },
    },
};


/// Normalized public ABI every adapter call site depends on. `@self` is the
/// package's own original address, `@sui` and `@std` are the framework
/// addresses; every other address is compared literally.
const ABI = {
    'bluefin_spot::config::GlobalConfig':
        'struct GlobalConfig has store, key',
    'bluefin_spot::config::get_tick_range':
        'public fun get_tick_range(&@self::config::GlobalConfig): (0x714a63a0dba6da4f017b42d5d0fb78867f18bcde904868e51d951a5a6f5b7f57::i32::I32, 0x714a63a0dba6da4f017b42d5d0fb78867f18bcde904868e51d951a5a6f5b7f57::i32::I32)',
    'bluefin_spot::pool::Pool':
        'struct Pool<phantom $0, phantom $1> has store, key',
    'bluefin_spot::pool::add_liquidity_with_fixed_amount':
        'public fun add_liquidity_with_fixed_amount<$0, $1>(&@sui::clock::Clock, &@self::config::GlobalConfig, &mut @self::pool::Pool<$0, $1>, &mut @self::position::Position, @sui::balance::Balance<$0>, @sui::balance::Balance<$1>, u64, bool): (u64, u64, @sui::balance::Balance<$0>, @sui::balance::Balance<$1>)',
    'bluefin_spot::pool::collect_fee':
        'public fun collect_fee<$0, $1>(&@sui::clock::Clock, &@self::config::GlobalConfig, &mut @self::pool::Pool<$0, $1>, &mut @self::position::Position): (u64, u64, @sui::balance::Balance<$0>, @sui::balance::Balance<$1>)',
    'bluefin_spot::pool::create_pool_and_get_object':
        'public fun create_pool_and_get_object<$0, $1, $2>(&@sui::clock::Clock, &mut @self::config::GlobalConfig, vector<u8>, vector<u8>, vector<u8>, u8, vector<u8>, vector<u8>, u8, vector<u8>, u32, u64, u128, @sui::balance::Balance<$2>, &mut @sui::tx_context::TxContext): @self::pool::Pool<$0, $1>',
    'bluefin_spot::pool::current_sqrt_price':
        'public fun current_sqrt_price<$0, $1>(&@self::pool::Pool<$0, $1>): u128',
    'bluefin_spot::pool::get_tick_manager':
        'public fun get_tick_manager<$0, $1>(&@self::pool::Pool<$0, $1>): &@self::tick::TickManager',
    'bluefin_spot::pool::open_position':
        'public fun open_position<$0, $1>(&@self::config::GlobalConfig, &mut @self::pool::Pool<$0, $1>, u32, u32, &mut @sui::tx_context::TxContext): @self::position::Position',
    'bluefin_spot::pool::share_pool_object':
        'public fun share_pool_object<$0, $1>(@self::pool::Pool<$0, $1>)',
    'bluefin_spot::pool::swap':
        'public fun swap<$0, $1>(&@sui::clock::Clock, &@self::config::GlobalConfig, &mut @self::pool::Pool<$0, $1>, @sui::balance::Balance<$0>, @sui::balance::Balance<$1>, bool, bool, u64, u64, u128): (@sui::balance::Balance<$0>, @sui::balance::Balance<$1>)',
    'bluefin_spot::position::Position':
        'struct Position has store, key',
    'bluefin_spot::position::liquidity':
        'public fun liquidity(&@self::position::Position): u128',
    'bluefin_spot::position::lower_tick':
        'public fun lower_tick(&@self::position::Position): 0x714a63a0dba6da4f017b42d5d0fb78867f18bcde904868e51d951a5a6f5b7f57::i32::I32',
    'bluefin_spot::position::pool_id':
        'public fun pool_id(&@self::position::Position): @sui::object::ID',
    'bluefin_spot::position::upper_tick':
        'public fun upper_tick(&@self::position::Position): 0x714a63a0dba6da4f017b42d5d0fb78867f18bcde904868e51d951a5a6f5b7f57::i32::I32',
    'bluefin_spot::tick::TickInfo':
        'struct TickInfo has copy, drop, store',
    'bluefin_spot::tick::TickManager':
        'struct TickManager has store',
    'bluefin_spot::tick::get_tick_from_manager':
        'public fun get_tick_from_manager(&@self::tick::TickManager, 0x714a63a0dba6da4f017b42d5d0fb78867f18bcde904868e51d951a5a6f5b7f57::i32::I32): &@self::tick::TickInfo',
    'bluefin_spot::tick::sqrt_price':
        'public fun sqrt_price(&@self::tick::TickInfo): u128',
    'cetus_clmm::clmm_math::get_liquidity_by_amount':
        'public fun get_liquidity_by_amount(0x714a63a0dba6da4f017b42d5d0fb78867f18bcde904868e51d951a5a6f5b7f57::i32::I32, 0x714a63a0dba6da4f017b42d5d0fb78867f18bcde904868e51d951a5a6f5b7f57::i32::I32, 0x714a63a0dba6da4f017b42d5d0fb78867f18bcde904868e51d951a5a6f5b7f57::i32::I32, u128, u64, bool): (u128, u64, u64)',
    'cetus_clmm::config::GlobalConfig':
        'struct GlobalConfig has store, key',
    'cetus_clmm::config::get_fee_rate':
        'public fun get_fee_rate(u32, &@self::config::GlobalConfig): u64',
    'cetus_clmm::factory::PoolCreationCap':
        'struct PoolCreationCap has store, key',
    'cetus_clmm::factory::Pools':
        'struct Pools has store, key',
    'cetus_clmm::factory::is_right_order':
        'public fun is_right_order<$0, $1>(): bool',
    'cetus_clmm::factory::mint_pool_creation_cap':
        'public fun mint_pool_creation_cap<$0>(&@self::config::GlobalConfig, &mut @self::factory::Pools, &mut @sui::coin::TreasuryCap<$0>, &mut @sui::tx_context::TxContext): @self::factory::PoolCreationCap',
    'cetus_clmm::factory::register_permission_pair':
        'public fun register_permission_pair<$0, $1>(&@self::config::GlobalConfig, &mut @self::factory::Pools, u32, &@self::factory::PoolCreationCap, &mut @sui::tx_context::TxContext)',
    'cetus_clmm::pool::AddLiquidityReceipt':
        'struct AddLiquidityReceipt<phantom $0, phantom $1>',
    'cetus_clmm::pool::FlashSwapReceipt':
        'struct FlashSwapReceipt<phantom $0, phantom $1>',
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
    'cetus_clmm::pool::current_tick_index':
        'public fun current_tick_index<$0, $1>(&@self::pool::Pool<$0, $1>): 0x714a63a0dba6da4f017b42d5d0fb78867f18bcde904868e51d951a5a6f5b7f57::i32::I32',
    'cetus_clmm::pool::flash_swap':
        'public fun flash_swap<$0, $1>(&@self::config::GlobalConfig, &mut @self::pool::Pool<$0, $1>, bool, bool, u64, u128, &@sui::clock::Clock): (@sui::balance::Balance<$0>, @sui::balance::Balance<$1>, @self::pool::FlashSwapReceipt<$0, $1>)',
    'cetus_clmm::pool::open_position':
        'public fun open_position<$0, $1>(&@self::config::GlobalConfig, &mut @self::pool::Pool<$0, $1>, u32, u32, &mut @sui::tx_context::TxContext): @self::position::Position',
    'cetus_clmm::pool::repay_add_liquidity':
        'public fun repay_add_liquidity<$0, $1>(&@self::config::GlobalConfig, &mut @self::pool::Pool<$0, $1>, @sui::balance::Balance<$0>, @sui::balance::Balance<$1>, @self::pool::AddLiquidityReceipt<$0, $1>)',
    'cetus_clmm::pool::repay_flash_swap':
        'public fun repay_flash_swap<$0, $1>(&@self::config::GlobalConfig, &mut @self::pool::Pool<$0, $1>, @sui::balance::Balance<$0>, @sui::balance::Balance<$1>, @self::pool::FlashSwapReceipt<$0, $1>)',
    'cetus_clmm::pool::swap_pay_amount':
        'public fun swap_pay_amount<$0, $1>(&@self::pool::FlashSwapReceipt<$0, $1>): u64',
    'cetus_clmm::pool::tick_spacing':
        'public fun tick_spacing<$0, $1>(&@self::pool::Pool<$0, $1>): u32',
    'cetus_clmm::pool_creator::create_pool_v3_with_creation_cap':
        'public fun create_pool_v3_with_creation_cap<$0, $1>(&@self::config::GlobalConfig, &mut @self::factory::Pools, &@self::factory::PoolCreationCap, u32, u128, @std::string::String, u32, u32, @sui::coin::Coin<$0>, @sui::coin::Coin<$1>, bool, &@sui::clock::Clock, &mut @sui::tx_context::TxContext): (@self::position::Position, @sui::coin::Coin<$0>, @sui::coin::Coin<$1>)',
    'cetus_clmm::pool_creator::full_range_tick_range':
        'public fun full_range_tick_range(u32): (u32, u32)',
    'cetus_clmm::position::Position':
        'struct Position has store, key',
    'cetus_clmm::position::liquidity':
        'public fun liquidity(&@self::position::Position): u128',
    'cetus_clmm::position::pool_id':
        'public fun pool_id(&@self::position::Position): @sui::object::ID',
    'cetus_clmm::position::tick_range':
        'public fun tick_range(&@self::position::Position): (0x714a63a0dba6da4f017b42d5d0fb78867f18bcde904868e51d951a5a6f5b7f57::i32::I32, 0x714a63a0dba6da4f017b42d5d0fb78867f18bcde904868e51d951a5a6f5b7f57::i32::I32)',
    'lp_burn::lp_burn::BurnManager':
        'struct BurnManager has key',
    'lp_burn::lp_burn::CetusLPBurnProof':
        'struct CetusLPBurnProof has store, key',
    'lp_burn::lp_burn::burn_lp_v2':
        'public fun burn_lp_v2(&mut @self::lp_burn::BurnManager, 0x1eabed72c53feb3805120a081dc15963c204dc8d091542592abaf7a35689b2fb::position::Position, &mut @sui::tx_context::TxContext): @self::lp_burn::CetusLPBurnProof',
    'lp_burn::lp_burn::collect_fee':
        'public fun collect_fee<$0, $1>(&@self::lp_burn::BurnManager, &0x1eabed72c53feb3805120a081dc15963c204dc8d091542592abaf7a35689b2fb::config::GlobalConfig, &mut 0x1eabed72c53feb3805120a081dc15963c204dc8d091542592abaf7a35689b2fb::pool::Pool<$0, $1>, &mut @self::lp_burn::CetusLPBurnProof, &mut @sui::tx_context::TxContext): (@sui::coin::Coin<$0>, @sui::coin::Coin<$1>)',
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

/// The exact revision's linkage table: the dependency revision every call it makes resolves to.
const LINKAGE_QUERY = `query($address: SuiAddress!, $version: UInt53!) {
  package(address: $address, version: $version) {
    linkage { originalId upgradedId version }
  }
}`;

/// Renders a linkage table as sorted `original -> upgraded vN` lines, rejecting a malformed or
/// repeated entry, so a missing, extra, or rebound dependency changes the rendering.
function renderLinkage(value, path) {
    const seen = new Set();
    return expectArray(value, path)
        .map((entry, index) => {
            const entryPath = `${path}[${index}]`;
            const link = expectObject(entry, entryPath, ['originalId', 'upgradedId', 'version']);
            const original = normalizeAddress(link.originalId, `${entryPath}.originalId`);
            if (seen.has(original)) throw shapeError(entryPath, `duplicate linkage for ${original}`);
            seen.add(original);
            const upgraded = normalizeAddress(link.upgradedId, `${entryPath}.upgradedId`);
            return `${original} -> ${upgraded} v${expectInteger(link.version, `${entryPath}.version`)}`;
        })
        .sort();
}

function expectedLinkage(linkage) {
    return linkage
        .map(([original, upgraded, version]) =>
            `${normalizeAddress(original)} -> ${normalizeAddress(upgraded)} v${version}`,
        )
        .sort();
}

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
                    checkEqual(
                        definingId,
                        expectedStructOrigin(expected, module, name),
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

    let checkedLinks = 0;
    if (expected.linkage) {
        const linked = await graphql(LINKAGE_QUERY, {
            address: expected.originalId,
            version: expected.version,
        });
        try {
            const table = expectObject(linked.package, `${label} linkage`, ['linkage']);
            const rendered = renderLinkage(table.linkage, `${label} linkage`);
            if (
                checkEqual(
                    rendered.join('; '),
                    expectedLinkage(expected.linkage).join('; '),
                    `${label}: revision ${expected.version} links other dependency revisions`,
                )
            ) {
                checkedLinks = rendered.length;
            }
        } catch (error) {
            check(false, `${label}: ${error.message}`);
        }
    }

    return { currentId: live.address, checkedOrigins, checkedLinks };
}

/// The package that must define a consumed struct: the original package, unless the expectation
/// pins the id of the later revision that introduced it.
function expectedStructOrigin(expected, module, name) {
    return module.structOrigins?.[name] ?? expected.originalId;
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

/// The committed LP Burn linkage as the live schema returns it, in the live order.
function GOOD_LINKAGE() {
    return packageByKey('lp_burn').linkage.map(([originalId, upgradedId, version]) => ({
        originalId,
        upgradedId,
        version,
    }));
}

/// Throws unless the mutated linkage renders differently from the committed expectation.
function assertLinkage(mutate) {
    const links = GOOD_LINKAGE();
    mutate(links);
    const rendered = renderLinkage(links, 'linkage').join('; ');
    if (rendered !== expectedLinkage(packageByKey('lp_burn').linkage).join('; ')) {
        throw new Error('linkage drift detected');
    }
}

function selfTestCases() {
    const rootManifest = readPackageFile('Move.toml');
    const cetusManifest = readPackageFile('interfaces/cetus/Move.toml');
    const lock = readPackageFile('Move.lock');

    const FIRST_LOCK_DIGEST = lock.match(/manifest_digest = "([^"]*)"/)?.[1];
    if (!FIRST_LOCK_DIGEST) throw new Error('self-test fixture missing: manifest_digest');

    const rootSpec = MANIFESTS.find((spec) => spec.path === 'Move.toml');
    const cetusSpec = MANIFESTS.find(
        (spec) => spec.path === 'interfaces/cetus/Move.toml',
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

        {
            name: 'committed linkage expectation renders canonically',
            expect: 'pass',
            run: () => {
                const expected = packageByKey('lp_burn').linkage;
                const rendered = renderLinkage(GOOD_LINKAGE(), 'linkage');
                if (rendered.join('; ') !== expectedLinkage(expected).join('; ')) {
                    throw new Error(`unexpected rendering: ${rendered.join('; ')}`);
                }
            },
        },

        // --- Negative: linkage ---
        {
            name: 'rebound linkage entry is rejected',
            run: () => assertLinkage((links) => { links[3].upgradedId = links[0].upgradedId; }),
        },
        {
            name: 'older linked version is rejected',
            run: () => assertLinkage((links) => { links[3].version = 14; }),
        },
        {
            name: 'missing linkage entry is rejected',
            run: () => assertLinkage((links) => { links.pop(); }),
        },
        {
            name: 'extra linkage entry is rejected',
            run: () => assertLinkage((links) => {
                links.push({ originalId: '0x3', upgradedId: '0x3', version: 1 });
            }),
        },
        {
            name: 'duplicate linkage entry is rejected',
            run: () => assertLinkage((links) => { links.push({ ...links[2] }); }),
        },
        {
            name: 'linkage entry with an unknown field is rejected',
            run: () => assertLinkage((links) => { links[0].digest = 'x'; }),
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
            name: 'a struct pinned to its introducing revision expects that revision',
            expect: 'pass',
            run: () => {
                const cetus = PACKAGES.find((venue) => venue.key === 'cetus');
                const factory = cetus.modules.find((module) => module.name === 'factory');
                const introducing =
                    '0x157468379cfe5616c063ae39a889dd184ad48350d3e08f8d9b4ade22b8e3fb61';
                if (
                    expectedStructOrigin(cetus, factory, 'PoolCreationCap') !== introducing ||
                    expectedStructOrigin(cetus, factory, 'Pools') !== cetus.originalId
                ) {
                    throw new Error('unexpected struct origin');
                }
            },
        },
        {
            name: 'a struct pinned to its introducing revision rejects the original package',
            run: () => {
                const cetus = PACKAGES.find((venue) => venue.key === 'cetus');
                const factory = cetus.modules.find((module) => module.name === 'factory');
                checkEqual(
                    cetus.originalId,
                    expectedStructOrigin(cetus, factory, 'PoolCreationCap'),
                    'PoolCreationCap origin',
                );
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
                cetusSpec,
                mutateSource(cetusManifest, 'Sui = {', '# Sui = {'),
            ),
        },
        {
            name: 'missing rev is rejected',
            run: manifest(
                cetusSpec,
                mutateSource(cetusManifest, `, rev = "${REV.sui}"`, ''),
            ),
        },
        {
            name: 'branch selector is rejected',
            run: manifest(
                cetusSpec,
                mutateSource(cetusManifest, `rev = "${REV.sui}"`, 'branch = "main"'),
            ),
        },
        {
            name: 'tag selector is rejected',
            run: manifest(
                cetusSpec,
                mutateSource(cetusManifest, `rev = "${REV.sui}"`, 'tag = "mainnet-v1.35.2"'),
            ),
        },
        {
            name: 'wrong-but-40-hex Sui revision is rejected',
            run: manifest(
                cetusSpec,
                mutateSource(cetusManifest, REV.sui, REV.suiLegacy),
            ),
        },
        {
            name: 'root Sui revision change is rejected',
            run: manifest(rootSpec, mutateSource(rootManifest, REV.sui, REV.suiBluefin)),
        },
        {
            name: 'wrong Git repository is rejected',
            run: manifest(
                cetusSpec,
                mutateSource(cetusManifest, SUI_GIT, 'https://github.com/attacker/sui.git'),
            ),
        },
        {
            name: 'wrong Git subdirectory is rejected',
            run: manifest(
                cetusSpec,
                mutateSource(cetusManifest, SUI_FRAMEWORK_SUBDIR, MOVE_STDLIB_SUBDIR),
            ),
        },
        {
            name: 'dropped override rule is rejected',
            run: manifest(
                cetusSpec,
                mutateSource(cetusManifest, ', override = true', ''),
            ),
        },
        {
            name: 'added override rule is rejected',
            run: manifest(
                rootSpec,
                mutateSource(
                    rootManifest,
                    `rev = "${REV.bluefin}" }`,
                    `rev = "${REV.bluefin}", override = true }`,
                ),
            ),
        },
        {
            name: 'extra Git dependency is rejected',
            run: manifest(
                cetusSpec,
                mutateSource(
                    cetusManifest,
                    '[addresses]',
                    `Extra = { git = "${MOVE_STL_GIT}", rev = "main" }\n\n[addresses]`,
                ),
            ),
        },
        {
            name: 'duplicate manifest key is rejected',
            run: manifest(
                cetusSpec,
                mutateSource(cetusManifest, '[addresses]', '[addresses]\ncetus_clmm = "0x1"'),
            ),
        },
        {
            name: 'duplicate manifest table is rejected',
            run: manifest(cetusSpec, `${cetusManifest}\n[addresses]\n`),
        },
        {
            name: 'changed published-at is rejected',
            run: manifest(
                cetusSpec,
                mutateSource(cetusManifest, packageByKey('cetus').currentId, `0x${'a'.repeat(64)}`),
            ),
        },
        {
            name: 'changed named address is rejected',
            run: manifest(
                cetusSpec,
                mutateSource(cetusManifest, packageByKey('cetus').originalId, `0x${'b'.repeat(64)}`),
            ),
        },
        {
            name: 'unexpected manifest table is rejected',
            run: manifest(cetusSpec, `${cetusManifest}\n[dev-dependencies]\nX = { local = "." }\n`),
        },
        {
            name: 'rebound local interface path is rejected',
            run: manifest(
                rootSpec,
                mutateSource(rootManifest, 'local = "interfaces/cetus"', 'local = "../launchpad"'),
            ),
        },

        // --- Negative: lock records ---
        {
            name: 'lock branch selector is rejected',
            run: lockCase(mutateSource(lock, `rev = "${REV.bluefin}"`, 'branch = "main"')),
        },
        {
            name: 'lock tag selector is rejected',
            run: lockCase(mutateSource(lock, `rev = "${REV.moveStl}"`, 'tag = "v1"')),
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
                    `[pinned.testnet.Sui_2]\nsource = { git = "${SUI_GIT}", subdir = "${SUI_FRAMEWORK_SUBDIR}", rev = "${REV.sui}" }`,
                    `[pinned.testnet.Sui_2]\nsource = { git = "${SUI_GIT}", subdir = "${SUI_FRAMEWORK_SUBDIR}", rev = "${REV.suiLegacy}" }`,
                ),
            ),
        },
        {
            name: 'lock rebound Sui edge is rejected',
            run: lockCase(
                mutateSource(
                    lock,
                    'deps = { IntegerMate = "IntegerMate_1", MoveSTL = "MoveSTL", Sui = "Sui_2" }',
                    'deps = { IntegerMate = "IntegerMate_1", MoveSTL = "MoveSTL", Sui = "Sui_1" }',
                ),
            ),
        },
        {
            name: 'lock wrong Git repository is rejected',
            run: lockCase(mutateSource(lock, MOVE_STL_GIT, 'https://github.com/attacker/move-stl.git')),
        },
        {
            name: 'lock wrong subdirectory is rejected',
            run: lockCase(
                mutateSource(
                    lock,
                    `subdir = "sui", rev = "${REV.integerMateBluefin}"`,
                    `subdir = ".", rev = "${REV.integerMateBluefin}"`,
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
                mutateSource(lock, 'source = { local = "interfaces/cetus" }', 'source = { local = "interfaces/bluefin" }'),
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
                `structs ${structs} origins ${resolved.checkedOrigins} ` +
                `links ${resolved.checkedLinks}\n`,
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
