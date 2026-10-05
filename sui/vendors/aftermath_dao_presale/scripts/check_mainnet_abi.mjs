#!/usr/bin/env node
// Release gate for blast_aftermath_dao_presale's two Aftermath dependencies.
//
// Verifies, against the official Sui mainnet GraphQL endpoint, that the Aftermath AMM and DAO-fee
// packages the local interface stubs link to are still the exact revisions pinned here, that every
// consumed struct keeps its defining package, module bytecode, and normalized ABI, and that each
// stub's Move.toml names the same package ids. The response validation and ABI rendering are the
// migrators package's former Aftermath gate (ADR 0063, ADR 0066), narrowed to the consumed surface.
// Uses Node built-ins only.
//
// Run `node scripts/check_mainnet_abi.mjs` from the package directory. Run with `--emit` to print
// the observed facts as a paste-ready expectation block when a reviewed venue upgrade is adopted.

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

const PACKAGE_DIR = join(dirname(fileURLToPath(import.meta.url)), '..');

// === Expected Packages ===

/// Facts recorded on 2026-09-02 for the migrators' Aftermath adapter (ADR 0066), the last live
/// read. A newer revision fails the gate until it is reviewed and adopted with `--emit`.
const PACKAGES = [
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
        manifest: 'interfaces/aftermath_amm/Move.toml',
        modules: [
            {
                name: 'pool',
                sha256: 'f952884b3e6ea275911ae488e9d1e3f4b2a4409cdd30e8bed69e98fd7d0f7d78',
                structs: ['CreatePoolCapV2', 'Pool'],
                structOrigins: { CreatePoolCapV2: 'current' },
                functions: ['balance_of'],
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
                functions: [],
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
                functions: ['fee_bps', 'fee_recipient', 'new'],
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

// === Expected ABI ===

const ABI = {
    'amm::pool::CreatePoolCapV2':
        'struct CreatePoolCapV2 has store, key',
    'amm::pool::Pool':
        'struct Pool<phantom $0> has store, key',
    'amm::pool::balance_of':
        'public fun balance_of<$0, $1>(&@self::pool::Pool<$0>): u64',
    'amm::pool_factory::create_pool_2_coins_v2':
        'public fun create_pool_2_coins_v2<$0, $1, $2>(@self::pool::CreatePoolCapV2, &mut @self::pool_registry::PoolRegistry, vector<u8>, vector<u64>, u64, vector<u64>, vector<u64>, vector<u64>, vector<u64>, @sui::coin::Coin<$1>, @sui::coin::Coin<$2>, @std::option::Option<vector<u8>>, bool, &mut @sui::tx_context::TxContext): (@self::pool::Pool<$0>, @sui::coin::Coin<$0>)',
    'amm::pool_registry::PoolRegistry':
        'struct PoolRegistry has store, key',
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

// === Local Pins ===

/// Each interface stub must link the pinned current revision and bind its address to the original
/// package id, so a build cannot silently target another lineage.
function verifyLocalPins() {
    for (const expected of PACKAGES) {
        const label = `${expected.label} ${expected.manifest}`;
        const manifest = readFileSync(join(PACKAGE_DIR, expected.manifest), 'utf8');
        const publishedAt = manifest.match(/^published-at = "(0x[0-9a-f]{64})"$/m)?.[1];
        const address = manifest.match(
            new RegExp(`^${expected.addressName} = "(0x[0-9a-f]{64})"$`, 'm'),
        )?.[1];
        checkEqual(publishedAt, expected.currentId, `${label}: published-at drift`);
        checkEqual(address, expected.originalId, `${label}: address drift`);
    }
}

// === Main ===

async function main() {
    const shouldEmit = process.argv.includes('--emit');

    const before = failures.length;
    verifyLocalPins();
    process.stdout.write(`${status(before)} local pins\n`);

    const identifier = await graphql('query { chainIdentifier }', {});
    checkEqual(
        identifier.chainIdentifier,
        CHAIN_IDENTIFIER,
        `${ENDPOINT} is not Sui mainnet`,
    );
    if (failures.length > 0) report(shouldEmit, []);

    const observations = [];
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

        const packageBefore = failures.length;
        const resolved = await verifyPackage(expected, observed);
        if (!resolved) continue;

        let functions = 0;
        let structs = 0;
        for (const module of expected.modules) {
            const counts = await verifyModule(expected, module, resolved.currentId, observed);
            functions += counts.functions;
            structs += counts.structs;
        }

        process.stdout.write(
            `${status(packageBefore)} ${expected.label} v${observed.version} ` +
                `${observed.currentId} | modules ${expected.modules.length} ` +
                `functions ${functions} structs ${structs} origins ${resolved.checkedOrigins}\n`,
        );
    }

    report(shouldEmit, observations);
}

function status(failuresBefore) {
    return failures.length === failuresBefore ? '  ok ' : '  FAIL';
}

function emit(observations) {
    process.stdout.write(`\n${JSON.stringify(observations, null, 4)}\n`);
}

function report(shouldEmit, observations) {
    if (shouldEmit) emit(observations);

    if (failures.length > 0) {
        process.stderr.write(`\ncheck_mainnet_abi: FAIL (${failures.length})\n`);
        for (const failure of failures) process.stderr.write(`  - ${failure}\n`);
        process.exit(1);
    }

    process.stdout.write(`check_mainnet_abi: PASS ${PACKAGES.length} packages\n`);
    process.exit(0);
}

main().catch((error) => {
    process.stderr.write(`check_mainnet_abi: FAIL ${error.message}\n`);
    process.exit(1);
});
