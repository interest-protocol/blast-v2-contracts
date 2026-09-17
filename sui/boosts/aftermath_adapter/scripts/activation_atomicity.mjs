#!/usr/bin/env node
// Submits controlled activation transactions and proves both successful final
// state and A1-A7 rollback against canonical Sui transaction/object output.

import { createHash } from 'node:crypto';
import {
    mkdtempSync,
    readFileSync,
    readdirSync,
    rmSync,
    statSync,
    writeFileSync,
} from 'node:fs';
import { tmpdir } from 'node:os';
import { basename, dirname, join, relative, resolve } from 'node:path';
import { fileURLToPath } from 'node:url';
import { spawnSync } from 'node:child_process';
import process from 'node:process';
import { parseMoveCalls } from './lib/ptb.mjs';

const SCRIPT_DIR = dirname(fileURLToPath(import.meta.url));
const PACKAGE_DIR = resolve(SCRIPT_DIR, '..');
const FIXTURE_PATH = join(SCRIPT_DIR, 'fixtures', 'activation-atomicity-vectors.json');
const OPERATIONS_PATH = join(PACKAGE_DIR, 'sources', 'operations.move');
const TESTNET_CHAIN = '69WiPg3DAQiwdxfncX6wYQ2siKwAe6L9BZthQea3JNMD';
const PINNED_SUI_VERSION = '1.77.2-51d177ad7d65';
const PHASES = [
    { case: 'A1', phase: 'vault.initialize_series', marker: '// BLAST_ACTIVATION_BOUNDARY_A1', abortCode: '9101' },
    { case: 'A2', phase: 'vault.mint_locked_shares', marker: '// BLAST_ACTIVATION_BOUNDARY_A2', abortCode: '9102' },
    { case: 'A3', phase: 'venue_account::new', marker: '// BLAST_ACTIVATION_BOUNDARY_A3', abortCode: '9103' },
    { case: 'A4', phase: 'account::consume_policy_and_share_account', marker: '// BLAST_ACTIVATION_BOUNDARY_A4', abortCode: '9104' },
    { case: 'A5', phase: 'vault.install_venue_account', marker: '// BLAST_ACTIVATION_BOUNDARY_A5', abortCode: '9105' },
    { case: 'A6', phase: 'clearing_house::share', marker: '// BLAST_ACTIVATION_BOUNDARY_A6', abortCode: '9106' },
    { case: 'A7', phase: 'events::vault_initialized', marker: '// BLAST_ACTIVATION_BOUNDARY_A7', abortCode: '9107' },
];
const ROLE_POINTERS = {
    vault: {
        lifecycle: '/content/series_state/lifecycle',
        maintenanceReserve: '/content/series_state/maintenance_reserve',
        venueAccount: '/content/venue_account/account_object_id',
        checkpoint: '/content/venue_account/checkpoint',
        adminCap: '/content/venue_account/admin_cap/id',
        seedFacts: '/content/seed_facts',
    },
    share_currency: {
        treasuryCapId: '/content/treasury_cap_id',
    },
    collateral_currency: {},
    treasury_cap: { totalSupply: '/content/total_supply/value' },
    locked_share_coin: { balance: '/content/balance' },
    aftermath_admin_cap: {},
    aftermath_transfer_policy: {},
    aftermath_account: {
        accountNumber: '/content/account_id',
        collateral: '/content/collateral/value',
    },
    registry: {},
    seed_coin: { balance: '/content/balance' },
    collateral_price_info: {
        priceNegative: '/content/price_info/price_feed/price/price/negative',
        priceMagnitude: '/content/price_info/price_feed/price/price/magnitude',
        exponentNegative: '/content/price_info/price_feed/price/expo/negative',
        exponentMagnitude: '/content/price_info/price_feed/price/expo/magnitude',
    },
    clearing_house: { marketState: '/content/market_state' },
    protocol: {},
    base_oracle: {},
    collateral_oracle: {},
    base_price_info: {},
    clock: {},
};
const ROLE_SELECTORS = Object.fromEntries(
    Object.entries(ROLE_POINTERS).map(([role, pointers]) => [role, Object.keys(pointers)]),
);
const OPTION_ROOTS_BY_SELECTOR = {
    'vault.venueAccount': ['/content/venue_account'],
    'vault.checkpoint': ['/content/venue_account'],
    'vault.adminCap': ['/content/venue_account', '/content/venue_account/admin_cap'],
    'vault.seedFacts': ['/content/seed_facts'],
    'share_currency.treasuryCapId': ['/content/treasury_cap_id'],
};
const SELECTOR_VALUE_KIND = {
    'vault.venueAccount': 'address',
    'vault.checkpoint': 'object',
    'vault.adminCap': 'address',
    'vault.seedFacts': 'object',
    'share_currency.treasuryCapId': 'address',
};
const REQUIRED_TRACKED_ROLES = Object.keys(ROLE_SELECTORS);
const SUCCESS_EFFECT_BY_ROLE = {
    vault: 'mutated',
    share_currency: null,
    collateral_currency: null,
    treasury_cap: 'mutated',
    locked_share_coin: 'created',
    aftermath_admin_cap: 'wrapped',
    aftermath_transfer_policy: 'deleted',
    aftermath_account: 'created',
    registry: 'mutated',
    seed_coin: 'deleted',
    collateral_price_info: null,
    clearing_house: 'mutated',
    protocol: null,
    base_oracle: null,
    collateral_oracle: null,
    base_price_info: null,
    clock: null,
};
const BINDING_BY_ROLE = {
    vault: { kind: 'argument' },
    share_currency: { kind: 'originEffect' },
    collateral_currency: { kind: 'argument' },
    treasury_cap: { kind: 'originEffect' },
    locked_share_coin: { kind: 'derived', creationIndex: 3 },
    aftermath_admin_cap: { kind: 'derived', creationIndex: 2 },
    aftermath_transfer_policy: { kind: 'derived', creationIndex: 1 },
    aftermath_account: { kind: 'derived', creationIndex: 0 },
    registry: { kind: 'argument' },
    seed_coin: { kind: 'argument' },
    collateral_price_info: { kind: 'argument' },
    clearing_house: { kind: 'argument' },
    protocol: { kind: 'argument' },
    base_oracle: { kind: 'argument' },
    collateral_oracle: { kind: 'argument' },
    base_price_info: { kind: 'argument' },
    clock: { kind: 'argument' },
};
const INITIALIZER_ARGUMENT_ROLE = {
    vault: 0,
    collateral_currency: 3,
    registry: 4,
    clearing_house: 5,
    collateral_price_info: 9,
    seed_coin: 10,
    protocol: 1,
    base_oracle: 6,
    collateral_oracle: 7,
    base_price_info: 8,
    clock: 14,
};
const ZERO_ADDRESS = `0x${'0'.repeat(64)}`;
const SEED_SHARE_SCALE = 1_000n;
const U256_MODULUS = 1n << 256n;
const U256_SIGN_BIT = 1n << 255n;
const INITIALIZED_FIELDS = [
    'vault_id', 'account_object_id', 'account_number', 'registry_id',
    'clearing_house_id', 'base_oracle_id', 'collateral_oracle_id',
    'collateral_type', 'seed_amount', 'seed_venue_equity', 'seed_reserve',
    'seed_shareholder_nav', 'locked_shares', 'seed_funder', 'absolute_base',
    'absolute_notional', 'lot_size', 'position_side', 'position_imr', 'checkpoint',
];
const CHECKPOINT_FIELDS = [
    'free_collateral', 'allocated_collateral', 'signed_base',
    'signed_quote_notional', 'funding_snapshot_long', 'funding_snapshot_short',
    'market_funding_long', 'market_funding_short', 'lot_size',
    'pending_ask_base', 'pending_bid_base', 'pending_order_count',
    'market_pause_mode', 'market_frozen', 'position_initial_margin_ratio',
    'market_initial_margin_ratio', 'market_maintenance_margin_ratio',
];
const EFFECT_LISTS = [
    'created', 'mutated', 'unwrapped', 'deleted',
    'unwrappedThenDeleted', 'wrapped',
];

function fail(message) {
    throw new Error(message);
}

function readJson(path) {
    try { return JSON.parse(readFileSync(path, 'utf8')); }
    catch (error) { fail(`${path}: ${error.message}`); }
}

function expectObject(value, path, keys = null) {
    if (value === null || typeof value !== 'object' || Array.isArray(value)) {
        fail(`${path}: expected object`);
    }
    if (keys !== null) {
        const actual = Object.keys(value).sort();
        const expected = [...keys].sort();
        if (JSON.stringify(actual) !== JSON.stringify(expected)) {
            fail(`${path}: field set mismatch; expected ${expected.join(', ')}, got ${actual.join(', ')}`);
        }
    }
    return value;
}

function expectString(value, path) {
    if (typeof value !== 'string' || value.length === 0) fail(`${path}: expected non-empty string`);
    return value;
}

function expectAddress(value, path) {
    const address = expectString(value, path);
    if (!/^0x[0-9a-fA-F]{64}$/.test(address)) fail(`${path}: expected canonical 32-byte address`);
    return address.toLowerCase();
}

function expectInteger(value, path) {
    if (!Number.isInteger(value) || value < 0) fail(`${path}: expected non-negative integer`);
    return value;
}

function expectStringList(value, path) {
    if (!Array.isArray(value) || value.some((item) => typeof item !== 'string')) {
        fail(`${path}: expected string list`);
    }
    return value;
}

function canonical(value) {
    if (Array.isArray(value)) return value.map(canonical);
    if (value !== null && typeof value === 'object') {
        return Object.fromEntries(Object.keys(value).sort().map((key) => [key, canonical(value[key])]));
    }
    return value;
}

function assertEqual(actual, expected, path = 'value') {
    const left = JSON.stringify(canonical(actual));
    const right = JSON.stringify(canonical(expected));
    if (left !== right) fail(`${path}: expected ${right}, got ${left}`);
}

function sha256(value) {
    return createHash('sha256').update(value).digest('hex');
}

function walkFiles(root, current = root) {
    const files = [];
    for (const name of readdirSync(current).sort()) {
        const path = join(current, name);
        if (statSync(path).isDirectory()) files.push(...walkFiles(root, path));
        else files.push([relative(root, path).replaceAll('\\', '/'), readFileSync(path)]);
    }
    return files;
}

function buildInputs(root) {
    const entries = [];
    for (const name of ['Move.toml', 'Move.lock']) {
        const path = join(root, name);
        try { entries.push([name, readFileSync(path)]); }
        catch { fail(`${root}: missing ${name}`); }
    }
    const sourceRoot = join(root, 'sources');
    for (const [path, bytes] of walkFiles(sourceRoot)) {
        if (path.endsWith('.move')) entries.push([`sources/${path}`, bytes]);
    }
    return entries.sort(([left], [right]) => left.localeCompare(right));
}

function inputsSha256(entries) {
    const hash = createHash('sha256');
    for (const [path, bytes] of entries) {
        hash.update(path);
        hash.update(Buffer.from([0]));
        hash.update(bytes);
        hash.update(Buffer.from([0]));
    }
    return hash.digest('hex');
}

function run(command, args, options = {}) {
    const result = spawnSync(command, args, {
        cwd: options.cwd ?? PACKAGE_DIR,
        encoding: options.binary ? null : 'utf8',
        input: options.input,
        stdio: ['pipe', 'pipe', 'pipe'],
    });
    if (result.error) fail(`${command}: ${result.error.message}`);
    const stdout = result.stdout ?? (options.binary ? Buffer.alloc(0) : '');
    const stderr = result.stderr ?? (options.binary ? Buffer.alloc(0) : '');
    if (!options.allowFailure && result.status !== 0) {
        const detail = options.binary
            ? Buffer.concat([stdout, stderr]).toString('utf8')
            : `${stdout}${stderr}`;
        fail(`${command} ${args.slice(0, 5).join(' ')} failed: ${detail.trim()}`);
    }
    return { status: result.status, stdout, stderr };
}

function runSui(args, allowFailure = false) {
    return run('sui', args, { allowFailure });
}

function assertPinnedSuiVersion() {
    const observed = runSui(['--version']).stdout.trim();
    if (observed !== `sui ${PINNED_SUI_VERSION}`) {
        fail(`Sui CLI version mismatch: expected ${PINNED_SUI_VERSION}, got ${observed}`);
    }
}

function parseJson(output, path) {
    try { return JSON.parse(output); }
    catch { fail(`${path}: expected canonical JSON`); }
}

function parseChainIdentifier(output) {
    const match = /^Base58:\s+(\S+)$/m.exec(output);
    if (!match) fail('sui chain-identifier: missing Base58 chain identity');
    return match[1];
}

function jsonPointer(root, pointer, path) {
    if (typeof pointer !== 'string' || !pointer.startsWith('/')) {
        fail(`${path}: expected JSON pointer`);
    }
    let value = root;
    for (const encoded of pointer.slice(1).split('/')) {
        const key = encoded.replaceAll('~1', '/').replaceAll('~0', '~');
        if (value === null || typeof value !== 'object' || !Object.hasOwn(value, key)) {
            fail(`${path}: pointer ${pointer} does not exist`);
        }
        value = value[key];
    }
    return canonical(value);
}

function statePointer(root, tracked, name, path) {
    const selector = `${tracked.role}.${name}`;
    for (const pointer of OPTION_ROOTS_BY_SELECTOR[selector] ?? []) {
        const option = jsonPointer(root, pointer, path);
        if (option === null) return null;
        if (pointer !== tracked.selectors[name]
            && (typeof option !== 'object' || Array.isArray(option))) {
            fail(`${path}: malformed Option; expected null or decoded object`);
        }
    }
    const value = jsonPointer(root, tracked.selectors[name], path);
    if (SELECTOR_VALUE_KIND[selector] === 'address') {
        const address = expectAddress(value, path);
        if (value !== address) fail(`${path}: expected canonical address`);
        return address;
    }
    if (SELECTOR_VALUE_KIND[selector] === 'object') return canonical(expectObject(value, path));
    return value;
}

function validateBinding(binding, path) {
    expectObject(binding, path);
    if (binding.kind === 'argument' || binding.kind === 'effect') {
        expectObject(binding, path, ['kind']);
    } else if (binding.kind === 'derived') {
        expectObject(binding, path, ['kind', 'creationIndex']);
        expectInteger(binding.creationIndex, `${path}.creationIndex`);
    } else if (binding.kind === 'originEffect') {
        expectObject(binding, path, ['kind', 'transactionDigest']);
        expectString(binding.transactionDigest, `${path}.transactionDigest`);
    } else {
        fail(`${path}: unsupported binding kind ${binding.kind}`);
    }
}

function validateTrackedObjects(trackedObjects, path) {
    if (!Array.isArray(trackedObjects) || trackedObjects.length !== REQUIRED_TRACKED_ROLES.length) {
        fail(`${path}: expected ${REQUIRED_TRACKED_ROLES.length} tracked roles`);
    }
    trackedObjects.forEach((tracked, index) => {
        const itemPath = `${path}[${index}]`;
        expectObject(tracked, itemPath, ['role', 'id', 'allowAbsent', 'expectedType', 'selectors', 'binding']);
        const role = REQUIRED_TRACKED_ROLES[index];
        if (tracked.role !== role) fail(`${itemPath}.role: expected ${role}`);
        expectAddress(tracked.id, `${itemPath}.id`);
        if (typeof tracked.allowAbsent !== 'boolean') fail(`${itemPath}.allowAbsent: expected boolean`);
        expectString(tracked.expectedType, `${itemPath}.expectedType`);
        expectObject(tracked.selectors, `${itemPath}.selectors`, ROLE_SELECTORS[role]);
        assertEqual(tracked.selectors, ROLE_POINTERS[role], `${itemPath}.selectors`);
        validateBinding(tracked.binding, `${itemPath}.binding`);
        const expectedBinding = BINDING_BY_ROLE[role];
        if (tracked.binding.kind !== expectedBinding.kind) {
            fail(`${itemPath}.binding: ${role} must use ${expectedBinding.kind}`);
        }
        if (expectedBinding.creationIndex !== undefined
            && tracked.binding.creationIndex !== expectedBinding.creationIndex) {
            fail(`${itemPath}.binding: ${role} must use creation index ${expectedBinding.creationIndex}`);
        }
    });
}

function normalizeTypeTag(value, path) {
    const type = expectString(value, path);
    if (/\s/.test(type)) fail(`${path}: type must not contain whitespace`);
    return type.replace(/0x[0-9a-fA-F]+/g, (address) =>
        `0x${BigInt(address).toString(16)}`);
}

function canonicalOwner(owner, path) {
    if (owner === 'Immutable') return owner;
    const value = expectObject(owner, path);
    const keys = Object.keys(value);
    if (keys.length !== 1) fail(`${path}: expected canonical owner variant`);
    const variant = keys[0];
    if (variant === 'AddressOwner' || variant === 'ObjectOwner') {
        return { [variant]: expectAddress(value[variant], `${path}.${variant}`) };
    }
    if (variant === 'Shared') {
        const shared = expectObject(value.Shared, `${path}.Shared`, ['initial_shared_version']);
        const version = String(shared.initial_shared_version);
        if (!/^[1-9][0-9]*$/.test(version)) {
            fail(`${path}.Shared.initial_shared_version: expected positive integer`);
        }
        return { Shared: { initial_shared_version: version } };
    }
    fail(`${path}: expected canonical owner variant`);
}

function validateStateObject(object, tracked, path) {
    expectObject(object, path);
    assertEqual(object.role, tracked.role, `${path}.role`);
    assertEqual(expectAddress(object.id, `${path}.id`), tracked.id, `${path}.id`);
    if (typeof object.exists !== 'boolean') fail(`${path}.exists: expected boolean`);
    if (!object.exists) {
        expectObject(object, path, ['role', 'exists', 'id']);
        if (!tracked.allowAbsent) fail(`${path}: required object is absent`);
        return canonical(object);
    }
    expectObject(object, path, [
        'role', 'exists', 'id', 'version', 'digest', 'owner', 'type', 'content', 'selected',
    ]);
    const version = String(object.version);
    if (!/^[1-9][0-9]*$/.test(version) || version !== object.version) {
        fail(`${path}.version: expected canonical positive integer string`);
    }
    expectString(object.digest, `${path}.digest`);
    const expectedType = normalizeTypeTag(tracked.expectedType, `${path}.expectedType`);
    const observedType = normalizeTypeTag(object.type, `${path}.type`);
    if (object.type !== observedType || observedType !== expectedType) {
        fail(`${path}: expected type ${expectedType}, got ${object.type}`);
    }
    const owner = canonicalOwner(object.owner, `${path}.owner`);
    assertEqual(object.owner, owner, `${path}.owner expected canonical owner`);
    expectObject(object.selected, `${path}.selected`, ROLE_SELECTORS[tracked.role]);
    expectObject(object.content, `${path}.content`);
    const selected = {};
    for (const name of Object.keys(tracked.selectors)) {
        selected[name] = statePointer(
            { content: object.content },
            tracked,
            name,
            `${path}.content.${name}`,
        );
    }
    assertEqual(selected, object.selected, `${path}.content selected fields`);
    return canonical(object);
}

function snapshotObject(environment, tracked, path) {
    const result = runSui([
        'client', '--client.env', environment, 'object', tracked.id, '--json',
    ], true);
    const output = `${result.stdout}${result.stderr}`;
    if (result.status !== 0) {
        if (tracked.allowAbsent && /not found|requested entity was not found|ObjectNotExists/i.test(output)) {
            return validateStateObject(
                { role: tracked.role, exists: false, id: tracked.id },
                tracked,
                path,
            );
        }
        fail(`${path}: object read failed: ${output.trim()}`);
    }
    const object = expectObject(parseJson(result.stdout, path), path);
    const id = expectAddress(object.objectId, `${path}.objectId`);
    if (id !== tracked.id) fail(`${path}: returned the wrong object`);
    const selected = {};
    for (const name of Object.keys(tracked.selectors)) {
        selected[name] = statePointer(object, tracked, name, `${path}.${name}`);
    }
    return validateStateObject(canonical({
        role: tracked.role,
        exists: true,
        id,
        version: String(object.version),
        digest: expectString(object.digest, `${path}.digest`),
        owner: canonicalOwner(object.owner, `${path}.owner`),
        type: normalizeTypeTag(object.objType, `${path}.type`),
        content: object.content,
        selected,
    }), tracked, path);
}

function snapshotState(environment, trackedObjects, path) {
    validateTrackedObjects(trackedObjects, path);
    return {
        objects: trackedObjects.map((tracked, index) =>
            snapshotObject(environment, tracked, `${path}[${index}]`)),
    };
}

function stateObject(state, role, path) {
    expectObject(state, path, ['objects']);
    if (!Array.isArray(state.objects)) fail(`${path}.objects: expected list`);
    const matches = state.objects.filter((object) => object.role === role);
    if (matches.length !== 1) fail(`${path}: expected one ${role}`);
    return matches[0];
}

function trackedObject(runConfig, role, path) {
    const matches = runConfig.trackedObjects.filter((tracked) => tracked.role === role);
    if (matches.length !== 1) fail(`${path}: expected one tracked ${role}`);
    return matches[0];
}

function assertTrackedTypeBindings(runConfig, inputs, path) {
    const leverageType = `${runConfig.packageId}::vault::Vault<${inputs.productType}>`;
    const exact = {
        vault: leverageType,
        protocol: `${runConfig.packageId}::protocol::Protocol`,
        share_currency: `0x2::coin_registry::Currency<${leverageType}>`,
        collateral_currency: `0x2::coin_registry::Currency<${inputs.collateralType}>`,
        treasury_cap: `0x2::coin::TreasuryCap<${leverageType}>`,
        locked_share_coin: `0x2::coin::Coin<${leverageType}>`,
        seed_coin: `0x2::coin::Coin<${inputs.collateralType}>`,
        clock: '0x2::clock::Clock',
    };
    for (const [role, expectedType] of Object.entries(exact)) {
        assertEqual(
            trackedObject(runConfig, role, `${path}.trackedObjects`).expectedType,
            expectedType,
            `${path}.${role}.type`,
        );
    }
    const registryType = trackedObject(runConfig, 'registry', `${path}.trackedObjects`).expectedType;
    const registrySuffix = '::registry::Registry';
    if (!registryType.endsWith(registrySuffix)) fail(`${path}.registry.type: expected ${registrySuffix}`);
    const perpetualsPackage = registryType.slice(0, -registrySuffix.length);
    assertEqual(
        trackedObject(runConfig, 'clearing_house', `${path}.trackedObjects`).expectedType,
        `${perpetualsPackage}::clearing_house::ClearingHouse<${inputs.collateralType}>`,
        `${path}.clearing_house.type`,
    );
    assertEqual(
        trackedObject(runConfig, 'aftermath_account', `${path}.trackedObjects`).expectedType,
        `${perpetualsPackage}::account::Account<${inputs.collateralType}>`,
        `${path}.aftermath_account.type`,
    );
    const baseOracleType = trackedObject(runConfig, 'base_oracle', `${path}.trackedObjects`).expectedType;
    if (!baseOracleType.endsWith('::price_feed_storage::PriceFeedStorage')) {
        fail(`${path}.base_oracle.type: expected PriceFeedStorage`);
    }
    assertEqual(
        trackedObject(runConfig, 'collateral_oracle', `${path}.trackedObjects`).expectedType,
        baseOracleType,
        `${path}.collateral_oracle.type`,
    );
    const basePriceInfoType = trackedObject(runConfig, 'base_price_info', `${path}.trackedObjects`).expectedType;
    if (!basePriceInfoType.endsWith('::price_info::PriceInfoObject')) {
        fail(`${path}.base_price_info.type: expected PriceInfoObject`);
    }
    assertEqual(
        trackedObject(runConfig, 'collateral_price_info', `${path}.trackedObjects`).expectedType,
        basePriceInfoType,
        `${path}.collateral_price_info.type`,
    );
}

function assertInitializerRoleBindings(runConfig, path) {
    for (const [role, index] of Object.entries(INITIALIZER_ARGUMENT_ROLE)) {
        const argument = runConfig.initializer.arguments[index];
        if (typeof argument !== 'string' || !argument.startsWith('@')) {
            fail(`${path}.initializer.arguments[${index}]: ${role} must be an object argument`);
        }
        assertEqual(
            trackedObject(runConfig, role, `${path}.trackedObjects`).id,
            expectAddress(argument.slice(1), `${path}.initializer.${role}`),
            `${path}.initializer role ${role}`,
        );
    }
}

function validateRunConfig(runConfig, path) {
    const packageId = expectAddress(runConfig.packageId, `${path}.packageId`);
    validateTrackedObjects(runConfig.trackedObjects, `${path}.trackedObjects`);
    validateInitializer(runConfig.initializer, packageId, runConfig.ptbArgs, `${path}.initializer`);
    const inputs = initializerBindings(runConfig.initializer, `${path}.initializer`);
    if (!inputs.productType.startsWith(`${packageId}::product::Product<`)
        || !inputs.productType.endsWith('>')) {
        fail(`${path}.initializer.productType: must be an exact Product from the initialized package`);
    }
    const riskType = expectString(runConfig.initializer.typeArguments[1], `${path}.initializer.riskType`);
    if (!riskType.startsWith(`${packageId}::`)) {
        fail(`${path}.initializer.riskType: must originate from the initialized package`);
    }
    assertInitializerRoleBindings(runConfig, path);
    assertTrackedTypeBindings(runConfig, inputs, path);
    return inputs;
}

function validateExpectedFinal(expectedFinal, postState) {
    expectObject(expectedFinal, 'expectedFinal', REQUIRED_TRACKED_ROLES);
    for (const role of REQUIRED_TRACKED_ROLES) {
        const object = stateObject(postState, role, 'postState');
        if (expectedFinal[role] === null) {
            if (object.exists) fail(`expectedFinal.${role}: object must be absent`);
        } else {
            if (!object.exists) fail(`expectedFinal.${role}: object must exist`);
            expectObject(expectedFinal[role], `expectedFinal.${role}`, ROLE_SELECTORS[role]);
            assertEqual(object.selected, expectedFinal[role], `expectedFinal.${role}`);
        }
    }
}

function validateInitializer(initializer, packageId, ptbArgs, path) {
    expectObject(initializer, path, ['target', 'typeArguments', 'arguments']);
    const expectedTarget = `${packageId}::operations::initialize`;
    if (initializer.target !== expectedTarget) fail(`${path}.target: expected ${expectedTarget}`);
    expectStringList(initializer.typeArguments, `${path}.typeArguments`);
    if (initializer.typeArguments.length !== 3) fail(`${path}.typeArguments: expected Product, RiskModule, Collateral`);
    expectStringList(initializer.arguments, `${path}.arguments`);
    if (initializer.arguments.length !== 15) fail(`${path}.arguments: expected 15 explicit arguments`);
    expectStringList(ptbArgs, `${path}.ptbArgs`);
    for (const forbidden of [
        '--dev-inspect', '--dry-run', '--preview',
        '--serialize-unsigned-transaction', '--serialize-signed-transaction',
    ]) {
        if (ptbArgs.includes(forbidden)) fail(`${path}.ptbArgs: submitted proof forbids ${forbidden}`);
    }
    const calls = parseMoveCalls(ptbArgs, `${path}.ptbArgs`);
    const initializers = calls.filter((call) => call.target === expectedTarget);
    if (initializers.length !== 1) {
        fail(`${path}.ptbArgs: expected exactly one ${expectedTarget}`);
    }
    assertEqual(initializers[0].typeArguments, initializer.typeArguments, `${path}.ptbArgs.initializer.typeArguments`);
    assertEqual(initializers[0].arguments, initializer.arguments, `${path}.ptbArgs.initializer.arguments`);
}

function effectBody(raw) {
    const effects = expectObject(raw, 'transaction.effects');
    if (effects.V1 !== undefined || effects.V2 !== undefined) {
        const variants = ['V1', 'V2'].filter((name) => effects[name] !== undefined);
        if (variants.length !== 1) fail('transaction.effects: expected exactly one version');
        return expectObject(effects[variants[0]], `transaction.effects.${variants[0]}`);
    }
    return effects;
}

function objectIdFromChange(change, path) {
    if (typeof change === 'string') return expectAddress(change, path);
    const value = expectObject(change, path);
    const reference = value.reference ?? value.ref ?? value;
    const id = reference.objectId ?? reference.object_id ?? value.objectId ?? value.object_id;
    return expectAddress(id, path);
}

function effectEntry(change, path) {
    const id = objectIdFromChange(change, path);
    if (typeof change === 'string') return { id };
    const value = expectObject(change, path);
    const reference = value.reference ?? value.ref ?? value;
    return canonical({
        id,
        ...(reference.version === undefined ? {} : { version: String(reference.version) }),
        ...(reference.digest === undefined ? {} : { digest: reference.digest }),
        ...(value.owner === undefined ? {} : { owner: value.owner }),
    });
}

function normalizeTransaction(transaction) {
    expectObject(transaction, 'transaction');
    const effects = effectBody(transaction.effects);
    const rawStatus = effects.status;
    const status = String(rawStatus?.status ?? rawStatus).toLowerCase();
    const error = rawStatus?.error ?? effects.error ?? null;
    const gasIdRaw = effects.gasObject?.reference?.objectId
        ?? effects.gasObject?.objectId
        ?? effects.gas_object?.reference?.object_id
        ?? effects.gas_object?.object_id
        ?? null;
    const gasId = gasIdRaw === null ? null : expectAddress(gasIdRaw, 'transaction.gasId');
    const changed = new Set();
    const effectKinds = {};
    for (const name of EFFECT_LISTS) {
        const snake = name.replace(/[A-Z]/g, (letter) => `_${letter.toLowerCase()}`);
        const entries = effects[name] ?? effects[snake] ?? [];
        if (!Array.isArray(entries)) fail(`transaction.effects.${name}: expected list`);
        effectKinds[name] = entries.map((entry, index) => {
            const normalized = effectEntry(entry, `transaction.effects.${name}[${index}]`);
            changed.add(normalized.id);
            return normalized;
        });
    }
    const objectChanges = transaction.objectChanges ?? transaction.object_changes ?? [];
    if (!Array.isArray(objectChanges)) fail('transaction.objectChanges: expected list');
    objectChanges.forEach((change, index) => {
        if (change.objectId !== undefined || change.object_id !== undefined) {
            changed.add(objectIdFromChange(change, `transaction.objectChanges[${index}]`));
        }
    });
    const changedObjects = [...changed].sort().map((id) => ({
        kind: id === gasId ? 'gas' : 'protocol',
        id,
    }));
    const events = transaction.events ?? [];
    if (!Array.isArray(events)) fail('transaction.events: expected list');
    return {
        status,
        error,
        gasId,
        changedObjects,
        effectKinds: canonical(effectKinds),
        events: canonical(events),
    };
}

function parseTransactionDigest(output) {
    try {
        const json = JSON.parse(output);
        if (typeof json.digest === 'string') return json.digest;
        if (typeof json.effects?.transactionDigest === 'string') return json.effects.transactionDigest;
    } catch {}
    const match = /(?:transaction[_ ]digest|digest)["':(\s]+([1-9A-HJ-NP-Za-km-z]{32,})/i.exec(output);
    if (!match) fail('submitted transaction output did not expose a digest');
    return match[1];
}

function submit(environment, runConfig, path) {
    validateRunConfig(runConfig, path);
    const preState = snapshotState(environment, runConfig.trackedObjects, `${path}.trackedObjects`);
    const args = ['client', '--client.env', environment, 'ptb', ...runConfig.ptbArgs];
    if (!args.includes('--json')) args.push('--json');
    const submitted = runSui(args, true);
    const submittedOutput = `${submitted.stdout}${submitted.stderr}`;
    const transactionDigest = parseTransactionDigest(submittedOutput);
    const rawTransaction = parseJson(runSui([
        'client', '--client.env', environment, 'tx-block', transactionDigest, '--json',
    ]).stdout, transactionDigest);
    const effects = normalizeTransaction(rawTransaction);
    const postState = snapshotState(environment, runConfig.trackedObjects, `${path}.trackedObjects`);
    return canonical({
        transactionDigest,
        preState,
        postState,
        rawTransaction,
        ...effects,
    });
}

const BASE58 = '123456789ABCDEFGHJKLMNPQRSTUVWXYZabcdefghijkmnopqrstuvwxyz';

function decodeBase58(value, path) {
    expectString(value, path);
    let number = 0n;
    for (const character of value) {
        const digit = BASE58.indexOf(character);
        if (digit < 0) fail(`${path}: invalid base58`);
        number = number * 58n + BigInt(digit);
    }
    const bytes = [];
    while (number > 0n) {
        bytes.push(Number(number & 255n));
        number >>= 8n;
    }
    bytes.reverse();
    let leading = 0;
    while (value[leading] === '1') leading += 1;
    return Buffer.concat([Buffer.alloc(leading), Buffer.from(bytes)]);
}

function deriveObjectId(transactionDigest, creationIndex) {
    const digest = decodeBase58(transactionDigest, 'transactionDigest');
    if (digest.length !== 32) fail('transactionDigest: expected 32 decoded bytes');
    const count = Buffer.alloc(8);
    count.writeBigUInt64LE(BigInt(creationIndex));
    const result = run('b2sum', ['-l', '256'], {
        binary: true,
        input: Buffer.concat([Buffer.from([0xf1]), digest, count]),
    });
    const hash = result.stdout.toString('utf8').split(/\s+/)[0];
    if (!/^[0-9a-f]{64}$/.test(hash)) fail('b2sum: invalid Blake2b-256 output');
    return `0x${hash}`;
}

function changedIds(transaction) {
    return new Set(transaction.changedObjects.map((change) => change.id));
}

function transactionEffectIds(environment, digest, cache) {
    if (!cache.has(digest)) {
        const raw = parseJson(runSui([
            'client', '--client.env', environment, 'tx-block', digest, '--json',
        ]).stdout, `origin ${digest}`);
        cache.set(digest, changedIds(normalizeTransaction(raw)));
    }
    return cache.get(digest);
}

function collectOriginEffects(environment, runConfig, cache = new Map()) {
    const digests = [...new Set(runConfig.trackedObjects
        .filter((tracked) => tracked.binding.kind === 'originEffect')
        .map((tracked) => tracked.binding.transactionDigest))];
    return digests.map((transactionDigest) => ({
        transactionDigest,
        objectIds: [...transactionEffectIds(environment, transactionDigest, cache)].sort(),
    }));
}

function originEffectMap(originEffects, path) {
    if (!Array.isArray(originEffects)) fail(`${path}: expected origin-effect evidence`);
    const result = new Map();
    originEffects.forEach((entry, index) => {
        const itemPath = `${path}[${index}]`;
        expectObject(entry, itemPath, ['transactionDigest', 'objectIds']);
        const digest = expectString(entry.transactionDigest, `${itemPath}.transactionDigest`);
        if (result.has(digest)) fail(`${itemPath}: duplicate transaction digest`);
        if (!Array.isArray(entry.objectIds)) fail(`${itemPath}.objectIds: expected list`);
        result.set(digest, new Set(entry.objectIds.map((id, objectIndex) =>
            expectAddress(id, `${itemPath}.objectIds[${objectIndex}]`))));
    });
    return result;
}

function bindTrackedObjects(runConfig, evidence, path) {
    const effects = changedIds(evidence);
    const origins = originEffectMap(evidence.originEffects, `${path}.originEffects`);
    for (const tracked of runConfig.trackedObjects) {
        const id = tracked.id;
        const binding = tracked.binding;
        if (binding.kind === 'argument') {
            const argumentIndex = INITIALIZER_ARGUMENT_ROLE[tracked.role];
            if (argumentIndex === undefined) {
                fail(`${path}.${tracked.role}: no canonical initializer argument role`);
            }
            const expected = runConfig.initializer.arguments[argumentIndex];
            if (expected !== `@${id}`) {
                fail(`${path}.${tracked.role}: id is not the canonical initializer argument`);
            }
        } else if (binding.kind === 'effect') {
            if (!effects.has(id)) fail(`${path}.${tracked.role}: id is not in transaction effects`);
        } else if (binding.kind === 'derived') {
            const derived = deriveObjectId(evidence.transactionDigest, binding.creationIndex);
            if (derived !== id) fail(`${path}.${tracked.role}: creation index derives ${derived}, not ${id}`);
        } else if (binding.kind === 'originEffect') {
            const ids = origins.get(binding.transactionDigest);
            if (ids === undefined) {
                fail(`${path}.${tracked.role}: missing origin transaction evidence`);
            }
            if (!ids.has(id)) fail(`${path}.${tracked.role}: id is not in origin transaction effects`);
        }
    }
}

function initializerBindings(initializer, path) {
    const addressArgument = (index, name) => {
        const raw = initializer.arguments[index];
        if (typeof raw !== 'string' || !raw.startsWith('@')) {
            fail(`${path}.arguments[${index}]: ${name} must be an object argument`);
        }
        return expectAddress(raw.slice(1), `${path}.${name}`);
    };
    const seedFunder = addressArgument(12, 'seedFunder');
    if (BigInt(seedFunder) === 0n) fail('seedFunder must not be zero');
    return {
        productType: expectString(initializer.typeArguments[0], `${path}.productType`),
        collateralType: expectString(initializer.typeArguments[2], `${path}.collateralType`),
        vaultId: addressArgument(0, 'vaultId'),
        protocolId: addressArgument(1, 'protocolId'),
        collateralCurrencyId: addressArgument(3, 'collateralCurrencyId'),
        registryId: addressArgument(4, 'registryId'),
        clearingHouseId: addressArgument(5, 'clearingHouseId'),
        baseOracleId: addressArgument(6, 'baseOracleId'),
        collateralOracleId: addressArgument(7, 'collateralOracleId'),
        basePriceInfoId: addressArgument(8, 'basePriceInfoId'),
        collateralPriceInfoId: addressArgument(9, 'collateralPriceInfoId'),
        seedCoinId: addressArgument(10, 'seedCoinId'),
        seedReserve: BigInt(expectString(initializer.arguments[11], `${path}.seedReserve`)),
        seedFunder,
        positionImr: BigInt(expectString(initializer.arguments[13], `${path}.positionImr`)),
        clockId: addressArgument(14, 'clockId'),
    };
}

function typeName(value, path) {
    if (typeof value === 'string') return expectString(value, path);
    const object = expectObject(value, path, ['name']);
    return expectString(object.name, `${path}.name`);
}

function signedMagnitude(value, path) {
    let raw;
    try { raw = BigInt(value); }
    catch { fail(`${path}: expected signed IFixed carrier`); }
    if (raw < 0n) return { negative: true, magnitude: -raw };
    if (raw >= U256_MODULUS) fail(`${path}: u256 overflow`);
    return raw >= U256_SIGN_BIT
        ? { negative: true, magnitude: U256_MODULUS - raw }
        : { negative: false, magnitude: raw };
}

function divideUp(numerator, denominator, path) {
    if (denominator <= 0n) fail(`${path}: denominator must be positive`);
    return numerator / denominator + (numerator % denominator === 0n ? 0n : 1n);
}

function fixedToAtomicUp(value, decimals, path) {
    return divideUp(value, 10n ** BigInt(18 - decimals), path);
}

function normalizedPythPrice(selected, path) {
    const negative = selected.priceNegative;
    const exponentNegative = selected.exponentNegative;
    if (typeof negative !== 'boolean' || typeof exponentNegative !== 'boolean') {
        fail(`${path}: price sign selectors must be boolean`);
    }
    if (negative) fail(`${path}: collateral price must be nonnegative`);
    const magnitude = BigInt(selected.priceMagnitude);
    const exponent = BigInt(selected.exponentMagnitude);
    if (exponent > 18n) fail(`${path}: unsupported Pyth exponent`);
    if (exponentNegative) {
        return exponent <= 9n
            ? magnitude * (10n ** (9n - exponent))
            : magnitude / (10n ** (exponent - 9n));
    }
    return magnitude * (10n ** (9n + exponent));
}

function positionSide(value, path) {
    if (value === 0 || value === 'Long' || value?.variant === 'Long') return 'long';
    if (value === 1 || value === 'Short' || value?.variant === 'Short') return 'short';
    fail(`${path}: unsupported PositionSide JSON`);
}

function assertOwnerKind(owner, expected, path, expectedId = null) {
    const value = expectObject(owner, path);
    const aliases = {
        shared: ['Shared', 'shared'],
        address: ['AddressOwner', 'address_owner'],
        object: ['ObjectOwner', 'object_owner'],
    };
    const keys = aliases[expected] ?? [];
    const found = keys.find((key) => Object.hasOwn(value, key));
    if (found === undefined) fail(`${path}: expected ${expected} owner`);
    if (expectedId !== null) {
        assertEqual(
            expectAddress(value[found], `${path}.${found}`),
            expectAddress(expectedId, `${path}.expectedId`),
            path,
        );
    }
}

function effectIds(evidence, name) {
    const list = evidence.effectKinds?.[name];
    if (!Array.isArray(list)) fail(`success.effectKinds.${name}: expected list`);
    return list;
}

function assertExactSuccessEffects(evidence, runConfig) {
    const expectedEffects = [];
    for (const tracked of runConfig.trackedObjects) {
        const expectedKind = SUCCESS_EFFECT_BY_ROLE[tracked.role];
        if (expectedKind === null) continue;
        expectedEffects.push(`${expectedKind}:${tracked.id}`);
        const matches = effectIds(evidence, expectedKind).filter((entry) => entry.id === tracked.id);
        if (matches.length !== 1) {
            fail(`success.${tracked.role}: expected exactly one ${expectedKind} effect`);
        }
    }
    const observedEffects = [];
    for (const name of EFFECT_LISTS) {
        for (const entry of effectIds(evidence, name)) {
            if (entry.id !== evidence.gasId) observedEffects.push(`${name}:${entry.id}`);
        }
    }
    assertEqual(
        observedEffects.sort(),
        expectedEffects.sort(),
        'success.protocol effects',
    );
}

function assertEffectOutputBindings(evidence, runConfig) {
    for (const tracked of runConfig.trackedObjects) {
        const kind = SUCCESS_EFFECT_BY_ROLE[tracked.role];
        if (!['created', 'mutated', 'unwrapped'].includes(kind)) continue;
        const output = stateObject(evidence.postState, tracked.role, 'success.postState');
        const effect = effectIds(evidence, kind).find((entry) => entry.id === tracked.id);
        if (!output.exists || effect === undefined) {
            fail(`success.${tracked.role}: missing output binding`);
        }
        assertEqual(
            {
                version: expectString(effect.version, `success.${tracked.role}.effect.version`),
                digest: expectString(effect.digest, `success.${tracked.role}.effect.digest`),
                owner: expectObject(effect.owner, `success.${tracked.role}.effect.owner`),
            },
            {
                version: expectString(output.version, `success.${tracked.role}.state.version`),
                digest: expectString(output.digest, `success.${tracked.role}.state.digest`),
                owner: expectObject(output.owner, `success.${tracked.role}.state.owner`),
            },
            `success.${tracked.role}.effect output`,
        );
    }
}

function assertSuccessOwnership(evidence) {
    const vault = stateObject(evidence.postState, 'vault', 'success.postState');
    const currency = stateObject(evidence.postState, 'share_currency', 'success.postState');
    const collateralCurrency = stateObject(evidence.postState, 'collateral_currency', 'success.postState');
    const cap = stateObject(evidence.postState, 'treasury_cap', 'success.postState');
    const locked = stateObject(evidence.postState, 'locked_share_coin', 'success.postState');
    const account = stateObject(evidence.postState, 'aftermath_account', 'success.postState');
    const registry = stateObject(evidence.postState, 'registry', 'success.postState');
    const clearingHouse = stateObject(evidence.postState, 'clearing_house', 'success.postState');
    assertOwnerKind(vault.owner, 'shared', 'success.vault.owner');
    assertOwnerKind(currency.owner, 'shared', 'success.share_currency.owner');
    assertOwnerKind(collateralCurrency.owner, 'shared', 'success.collateral_currency.owner');
    assertOwnerKind(cap.owner, 'object', 'success.treasury_cap.owner', vault.id);
    assertOwnerKind(locked.owner, 'address', 'success.locked_share_coin.owner', ZERO_ADDRESS);
    assertOwnerKind(account.owner, 'shared', 'success.aftermath_account.owner');
    assertOwnerKind(registry.owner, 'shared', 'success.registry.owner');
    assertOwnerKind(clearingHouse.owner, 'shared', 'success.clearing_house.owner');
}

function initializedEvent(evidence, runConfig) {
    const eventPrefix = `${runConfig.packageId}::events_wrapper::Event<${runConfig.packageId}::events::`;
    const expectedType = `${eventPrefix}VaultInitialized<${runConfig.initializer.typeArguments[0]}>>`;
    const protocolEvents = evidence.events.filter((event) =>
        typeof event?.type === 'string'
        && event.type.startsWith(eventPrefix));
    if (protocolEvents.some((event) => event.type !== expectedType)) {
        fail('success.events: unexpected protocol event');
    }
    const matches = protocolEvents.filter((event) => event.type === expectedType);
    if (matches.length !== 1) fail(`success.events: expected exactly one ${expectedType}, got ${matches.length}`);
    const event = expectObject(matches[0], 'success.VaultInitialized');
    const wrapper = expectObject(
        event.parsedJson ?? event.parsed_json,
        'success.VaultInitialized.parsedJson',
        ['pos0'],
    );
    const parsedJson = expectObject(
        wrapper.pos0,
        'success.VaultInitialized.parsedJson.pos0',
        INITIALIZED_FIELDS,
    );
    expectObject(parsedJson.checkpoint, 'success.VaultInitialized.checkpoint', CHECKPOINT_FIELDS);
    return canonical({ type: event.type, parsedJson });
}

function validateSuccess(evidence, runConfig) {
    validateRunConfig(runConfig, 'success.runConfig');
    assertStateTracksRunConfig(evidence.preState, runConfig, 'success.preState');
    assertStateTracksRunConfig(evidence.postState, runConfig, 'success.postState');
    bindTrackedObjects(runConfig, evidence, 'success');
    if (evidence.status !== 'success') fail(`success: transaction failed: ${evidence.error}`);
    validateExpectedFinal(runConfig.expectedFinal, evidence.postState);
    assertExactSuccessEffects(evidence, runConfig);
    assertEffectOutputBindings(evidence, runConfig);
    const event = initializedEvent(evidence, runConfig);
    const fields = event.parsedJson;
    const inputs = initializerBindings(runConfig.initializer, 'success.initializer');
    assertTrackedTypeBindings(runConfig, inputs, 'success');
    const vault = stateObject(evidence.postState, 'vault', 'success.postState');
    const currency = stateObject(evidence.postState, 'share_currency', 'success.postState');
    const cap = stateObject(evidence.postState, 'treasury_cap', 'success.postState');
    const locked = stateObject(evidence.postState, 'locked_share_coin', 'success.postState');
    const admin = stateObject(evidence.postState, 'aftermath_admin_cap', 'success.postState');
    const transferPolicy = stateObject(evidence.postState, 'aftermath_transfer_policy', 'success.postState');
    const account = stateObject(evidence.postState, 'aftermath_account', 'success.postState');
    const registry = stateObject(evidence.postState, 'registry', 'success.postState');
    const seed = stateObject(evidence.postState, 'seed_coin', 'success.postState');
    const seedBefore = stateObject(evidence.preState, 'seed_coin', 'success.preState');
    const collateralPrice = stateObject(evidence.postState, 'collateral_price_info', 'success.postState');
    const clearingHouse = stateObject(evidence.postState, 'clearing_house', 'success.postState');
    if (!vault.exists || !currency.exists || !cap.exists || !locked.exists
        || admin.exists || transferPolicy.exists || !account.exists
        || !registry.exists || seed.exists || !seedBefore.exists
        || !collateralPrice.exists || !clearingHouse.exists) {
        fail('success.postState: final custody/object existence mismatch');
    }
    for (const [role, index] of Object.entries(INITIALIZER_ARGUMENT_ROLE)) {
        const tracked = stateObject(evidence.postState, role, 'success.postState');
        const inputId = expectAddress(
            runConfig.initializer.arguments[index].slice(1),
            `success.initializer.${role}`,
        );
        assertEqual(tracked.id, inputId, `success.${role}.argument`);
    }
    const lockedShares = BigInt(cap.selected.totalSupply);
    if (lockedShares % SEED_SHARE_SCALE !== 0n) {
        fail('success.locked_shares: supply is not an exact seed-share multiple');
    }
    const seedNav = lockedShares / SEED_SHARE_SCALE;
    const seedVenueEquity = seedNav + inputs.seedReserve;
    const signedBase = signedMagnitude(fields.checkpoint.signed_base, 'success.checkpoint.signed_base');
    const signedQuote = signedMagnitude(
        fields.checkpoint.signed_quote_notional,
        'success.checkpoint.signed_quote_notional',
    );
    const expectedSide = signedBase.negative ? 'short' : 'long';
    if (signedBase.magnitude > 0n && signedQuote.negative === signedBase.negative) {
        fail('success.position_side: base and quote signs are incoherent');
    }
    const collateralPrice9 = normalizedPythPrice(
        collateralPrice.selected,
        'success.collateral_price_info',
    );
    const collateralFixed = collateralPrice9 * 1_000_000_000n;
    const absoluteNotional = divideUp(
        signedQuote.magnitude * 1_000_000n,
        collateralFixed,
        'success.absolute_notional',
    );
    const relations = [
        [fields.vault_id, inputs.vaultId, 'vault_id'],
        [fields.account_object_id, account.id, 'account_object_id'],
        [fields.registry_id, inputs.registryId, 'registry_id'],
        [fields.clearing_house_id, inputs.clearingHouseId, 'clearing_house_id'],
        [fields.base_oracle_id, inputs.baseOracleId, 'base_oracle_id'],
        [fields.collateral_oracle_id, inputs.collateralOracleId, 'collateral_oracle_id'],
        [typeName(fields.collateral_type, 'success.collateral_type'), inputs.collateralType, 'collateral_type'],
        [String(fields.account_number), String(account.selected.accountNumber), 'account_number'],
        [String(fields.seed_amount), String(seedBefore.selected.balance), 'seed_amount'],
        [String(fields.seed_venue_equity), String(seedVenueEquity), 'seed_venue_equity'],
        [String(fields.seed_reserve), String(inputs.seedReserve), 'seed_reserve input'],
        [String(fields.seed_reserve), String(vault.selected.maintenanceReserve), 'seed_reserve state'],
        [String(fields.seed_shareholder_nav), String(seedNav), 'seed_shareholder_nav'],
        [fields.checkpoint, vault.selected.checkpoint, 'checkpoint'],
        [String(fields.locked_shares), String(lockedShares), 'locked_shares supply'],
        [String(fields.locked_shares), String(locked.selected.balance), 'locked_shares balance'],
        [fields.seed_funder, inputs.seedFunder, 'seed_funder input'],
        [vault.selected.seedFacts, { locked_shares: String(lockedShares), funder: inputs.seedFunder }, 'immutable seed ownership'],
        [String(fields.absolute_base), String(fixedToAtomicUp(signedBase.magnitude, 9, 'success.absolute_base')), 'absolute_base'],
        [String(fields.absolute_notional), String(absoluteNotional), 'absolute_notional'],
        [String(fields.lot_size), String(fields.checkpoint.lot_size), 'lot_size'],
        [positionSide(fields.position_side, 'success.position_side'), expectedSide, 'position_side'],
        [String(fields.position_imr), String(inputs.positionImr), 'position_imr input'],
        [String(fields.position_imr), String(fields.checkpoint.position_initial_margin_ratio), 'position_imr checkpoint'],
        [currency.selected.treasuryCapId, cap.id, 'currency treasury cap'],
        [vault.selected.venueAccount, account.id, 'venue account'],
        [vault.selected.adminCap, admin.id, 'admin cap custody'],
    ];
    for (const [actual, expected, label] of relations) assertEqual(actual, expected, `success.${label}`);
    assertSuccessOwnership(evidence);
    return event;
}

function resolveState(value, baseline, path) {
    if (value === 'baseline') return baseline;
    if (value === null || typeof value !== 'object' || Array.isArray(value)) fail(`${path}: expected state or baseline`);
    return value;
}

function assertStateTracksRunConfig(state, runConfig, path) {
    expectObject(state, path, ['objects']);
    if (!Array.isArray(state.objects) || state.objects.length !== REQUIRED_TRACKED_ROLES.length) {
        fail(`${path}.objects: expected ${REQUIRED_TRACKED_ROLES.length} canonical tracked objects`);
    }
    runConfig.trackedObjects.forEach((tracked, index) =>
        validateStateObject(state.objects[index], tracked, `${path}.objects[${index}]`));
}

function assertRollback(entry, baseline) {
    if (entry.status !== 'failure') fail(`${entry.case}: transaction did not fail`);
    const preState = resolveState(entry.preState, baseline, `${entry.case}.preState`);
    const postState = resolveState(entry.postState, baseline, `${entry.case}.postState`);
    assertEqual(postState, preState, `${entry.case}.state`);
    if (!Array.isArray(entry.events) || entry.events.length !== 0) fail(`${entry.case}: failed transaction emitted an event`);
    if (!Array.isArray(entry.changedObjects)) fail(`${entry.case}: changedObjects must be a list`);
    for (const change of entry.changedObjects) {
        expectObject(change, `${entry.case}.changedObjects`, ['kind', 'id']);
        if (change.kind !== 'gas') fail(`${entry.case}: non-gas object ${change.id} changed`);
    }
}

function assertExactAbort(error, packageId, phase) {
    const message = typeof error === 'string' ? error : JSON.stringify(error);
    if (!/MoveAbort/.test(message)) fail(`${phase.case}: failure is not a MoveAbort`);
    if (!message.toLowerCase().includes(packageId.slice(2).toLowerCase())) fail(`${phase.case}: abort package mismatch`);
    if (!/(?:operations|Identifier\(["']operations["']\))/.test(message)) fail(`${phase.case}: abort module mismatch`);
    if (!/(?:initialize|function_name[^\n]*initialize)/.test(message)) fail(`${phase.case}: abort function mismatch`);
    const escaped = phase.abortCode.replace(/[.*+?^${}()|[\]\\]/g, '\\$&');
    if (!new RegExp(`(?:abort_code|abortCode|code|,|\\s)\\s*[:=]?\\s*${escaped}(?:\\D|$)`).test(message)) {
        fail(`${phase.case}: expected exact abort code ${phase.abortCode}`);
    }
}

function assertInstrumentedSource(production, instrumented, phase) {
    const productionLines = production.split('\n');
    const instrumentedLines = instrumented.split('\n');
    const markerIndices = productionLines.flatMap((line, index) =>
        line.trim() === phase.marker ? [index] : []);
    if (markerIndices.length !== 1) fail(`${phase.case}: marker must be one standalone line`);
    if (instrumentedLines.length !== productionLines.length + 1) {
        fail(`${phase.case}: instrumented operations must add exactly one line`);
    }
    const insertion = markerIndices[0] + 1;
    const abortLine = `abort ${phase.abortCode};`;
    if (instrumentedLines[insertion].trim() !== abortLine) {
        fail(`${phase.case}: expected ${abortLine} immediately after ${phase.marker}`);
    }
    const restored = [...instrumentedLines];
    restored.splice(insertion, 1);
    assertEqual(restored, productionLines, `${phase.case}.instrumentedOperations`);
}

function validateOfflineFailure(entry, baseline, phase, path) {
    expectObject(entry, path, ['runConfig', 'evidence']);
    const runConfig = expectObject(entry.runConfig, `${path}.runConfig`, [
        'case', 'packageId', 'initializer', 'ptbArgs', 'trackedObjects',
        'instrumentation',
    ]);
    if (runConfig.case !== phase.case) fail(`${path}.runConfig.case: expected ${phase.case}`);
    validateRunConfig(runConfig, `${path}.runConfig`);
    const instrumentation = expectObject(
        runConfig.instrumentation,
        `${path}.runConfig.instrumentation`,
        ['productionSource', 'instrumentedSource'],
    );
    assertInstrumentedSource(
        expectString(instrumentation.productionSource, `${path}.instrumentation.productionSource`),
        expectString(instrumentation.instrumentedSource, `${path}.instrumentation.instrumentedSource`),
        phase,
    );
    const evidence = expectObject(entry.evidence, `${path}.evidence`, [
        'status', 'error', 'transactionDigest', 'originEffects', 'preState',
        'postState', 'changedObjects', 'events',
    ]);
    validateFailureEvidence(runConfig, evidence, baseline, phase, `${path}.evidence`);
}

function validateFailureEvidence(runConfig, evidence, baseline, phase, path) {
    validateRunConfig(runConfig, `${path}.runConfig`);
    const preState = resolveState(evidence.preState, baseline, `${path}.preState`);
    const postState = resolveState(evidence.postState, baseline, `${path}.postState`);
    assertStateTracksRunConfig(preState, runConfig, `${path}.preState`);
    assertStateTracksRunConfig(postState, runConfig, `${path}.postState`);
    bindTrackedObjects(runConfig, evidence, path);
    assertExactAbort(evidence.error, runConfig.packageId, phase);
    assertRollback({ case: phase.case, ...evidence, preState, postState }, preState);
}

function assertInstrumentedTree(instrumentedRoot, phase) {
    const productionEntries = buildInputs(PACKAGE_DIR);
    const instrumentedEntries = buildInputs(instrumentedRoot);
    assertEqual(
        instrumentedEntries.map(([path]) => path),
        productionEntries.map(([path]) => path),
        `${phase.case}.sourceFiles`,
    );
    productionEntries.forEach(([path, bytes], index) => {
        const instrumented = instrumentedEntries[index][1];
        if (path === 'sources/operations.move') {
            assertInstrumentedSource(bytes.toString('utf8'), instrumented.toString('utf8'), phase);
        } else {
            assertEqual(instrumented.toString('hex'), bytes.toString('hex'), `${phase.case}.${path}`);
        }
    });
    return {
        productionSourcesSha256: inputsSha256(productionEntries),
        instrumentedSourcesSha256: inputsSha256(instrumentedEntries),
    };
}

function packageModules(object, path) {
    if (object.objType !== 'package') fail(`${path}: expected package object`);
    const packageContent = object.content?.Package ?? object.content?.package;
    const moduleMap = packageContent?.module_map ?? packageContent?.moduleMap;
    expectObject(moduleMap, `${path}.moduleMap`);
    const modules = {};
    for (const [name, value] of Object.entries(moduleMap)) {
        let bytes;
        if (Array.isArray(value)) bytes = Buffer.from(value);
        else if (typeof value === 'string') bytes = Buffer.from(value, 'base64');
        else fail(`${path}.moduleMap.${name}: expected bytes`);
        modules[name] = sha256(bytes);
    }
    return canonical(modules);
}

function builtModules(installRoot) {
    const moduleRoot = join(
        installRoot, 'build', 'blast_boosts_aftermath', 'bytecode_modules',
    );
    const modules = {};
    for (const name of readdirSync(moduleRoot).sort()) {
        if (!name.endsWith('.mv')) continue;
        modules[basename(name, '.mv')] = sha256(readFileSync(join(moduleRoot, name)));
    }
    if (Object.keys(modules).length === 0) fail('source verification produced no Blast bytecode modules');
    return modules;
}

const verifiedPackages = new Map();

function verifyBlastPackage(environment, sourceRoot, publicationFile, packageId, expectedDigest, path) {
    sourceRoot = resolve(sourceRoot);
    publicationFile = resolve(publicationFile);
    packageId = expectAddress(packageId, `${path}.packageId`);
    expectString(expectedDigest, `${path}.packageObjectDigest`);
    const key = [sourceRoot, publicationFile, packageId, expectedDigest].join('\0');
    if (verifiedPackages.has(key)) return verifiedPackages.get(key);
    if (!readFileSync(publicationFile, 'utf8').toLowerCase().includes(packageId)) {
        fail(`${path}.publicationFile: does not pin ${packageId}`);
    }
    const object = expectObject(parseJson(runSui([
        'client', '--client.env', environment, 'object', packageId, '--json',
    ]).stdout, path), path);
    if (object.digest !== expectedDigest) fail(`${path}: package digest mismatch`);
    const onChainModules = packageModules(object, path);
    const installRoot = mkdtempSync(join(tmpdir(), 'blast-activation-proof-'));
    try {
        runSui([
            'client', '--client.env', environment, 'verify-source', sourceRoot,
            '--build-env', environment, '--pubfile-path', publicationFile,
            '--install-dir', installRoot, '--force', '--json',
        ]);
        const compiledModules = canonical(builtModules(installRoot));
        assertEqual(compiledModules, onChainModules, `${path}.compiledVsOnChainModules`);
        const result = canonical({
            packageId,
            packageObjectDigest: expectedDigest,
            sourcesSha256: inputsSha256(buildInputs(sourceRoot)),
            compiledModules,
            onChainModules,
        });
        verifiedPackages.set(key, result);
        return result;
    } finally {
        rmSync(installRoot, { recursive: true, force: true });
    }
}

function verifyReview(review) {
    expectObject(review, 'config.review', ['commit', 'tree', 'productionSourcesSha256']);
    const repository = run('git', ['-C', PACKAGE_DIR, 'rev-parse', '--show-toplevel']).stdout.trim();
    const commit = run('git', ['-C', repository, 'rev-parse', 'HEAD']).stdout.trim();
    const tree = run('git', ['-C', repository, 'rev-parse', 'HEAD^{tree}']).stdout.trim();
    if (commit !== review.commit || tree !== review.tree) fail('config.review: Git commit/tree drift');
    const dirty = run('git', [
        '-C', repository, 'status', '--porcelain', '--untracked-files=no', '--', PACKAGE_DIR,
    ]).stdout.trim();
    if (dirty !== '') fail('config.review: tracked adapter files are dirty');
    const sourcesSha256 = inputsSha256(buildInputs(PACKAGE_DIR));
    if (sourcesSha256 !== review.productionSourcesSha256) fail('config.review: production source hash drift');
    return { commit, tree, productionSourcesSha256: sourcesSha256 };
}

function verifyProduction(environment, production) {
    expectObject(production, 'config.production', [
        'packageId', 'packageObjectDigest', 'publicationFile',
    ]);
    return verifyBlastPackage(
        environment,
        PACKAGE_DIR,
        production.publicationFile,
        production.packageId,
        production.packageObjectDigest,
        'productionPackage',
    );
}

function verifyInstrumentation(environment, instrumentation, production, phase) {
    expectObject(instrumentation, `${phase.case}.instrumentation`, [
        'instrumentedPackageId', 'instrumentedPackageObjectDigest',
        'instrumentedSources', 'publicationFile',
    ]);
    const sourceProof = assertInstrumentedTree(resolve(instrumentation.instrumentedSources), phase);
    if (sourceProof.productionSourcesSha256 !== production.sourcesSha256) {
        fail(`${phase.case}: production source provenance mismatch`);
    }
    const packageProof = verifyBlastPackage(
        environment,
        instrumentation.instrumentedSources,
        instrumentation.publicationFile,
        instrumentation.instrumentedPackageId,
        instrumentation.instrumentedPackageObjectDigest,
        `${phase.case}.instrumentedPackage`,
    );
    if (packageProof.packageId === production.packageId) fail(`${phase.case}: failpoint package equals production`);
    if (packageProof.sourcesSha256 !== sourceProof.instrumentedSourcesSha256) {
        fail(`${phase.case}: instrumented source provenance mismatch`);
    }
    return canonical({ phase, ...sourceProof, package: packageProof });
}

function validateFixture(fixture) {
    expectObject(fixture, 'fixture', [
        'schemaVersion', 'fixtureKind', 'gasDifferencePolicy',
        'productionOperationsSha256', 'baseline', 'success', 'failures',
    ]);
    if (fixture.schemaVersion !== 4 || fixture.fixtureKind !== 'canonical-evidence-validator') {
        fail('fixture: unsupported schema or kind');
    }
    if (fixture.gasDifferencePolicy !== 'gas-only') fail('fixture: rollback may allow gas changes only');
    const observedSha = sha256(readFileSync(OPERATIONS_PATH));
    if (observedSha !== fixture.productionOperationsSha256) fail('fixture: production operations hash drift');
    expectObject(fixture.success, 'fixture.success', [
        'packageId', 'initializer', 'ptbArgs', 'trackedObjects', 'expectedFinal',
        'transactionDigest', 'status', 'error', 'gasId', 'changedObjects', 'effectKinds',
        'events', 'originEffects', 'preState', 'postState',
    ]);
    validateRunConfig(fixture.success, 'fixture.success');
    const success = {
        ...fixture.success,
        preState: resolveState(fixture.success.preState, fixture.baseline, 'fixture.success.preState'),
    };
    validateSuccess(success, fixture.success);
    if (!Array.isArray(fixture.failures) || fixture.failures.length !== PHASES.length) {
        fail('fixture.failures: expected A1-A7 exactly once');
    }
    fixture.failures.forEach((entry, index) => {
        const phase = PHASES[index];
        validateOfflineFailure(entry, fixture.baseline, phase, `fixture.failures[${index}]`);
    });
}

function expectFailure(message, action) {
    try { action(); }
    catch (error) {
        if (String(error.message).includes(message)) return;
        fail(`expected failure containing ${JSON.stringify(message)}, got ${JSON.stringify(error.message)}`);
    }
    fail(`expected failure containing ${JSON.stringify(message)}`);
}

function selfTest() {
    const fixture = readJson(FIXTURE_PATH);
    validateFixture(fixture);
    fixture.success.preState = resolveState(
        fixture.success.preState,
        fixture.baseline,
        'fixture.success.preState',
    );
    let passed = 3;

    const zeroFunder = structuredClone(fixture.success.initializer);
    zeroFunder.arguments[12] = `@0x${'0'.repeat(64)}`;
    expectFailure('seedFunder must not be zero', () => initializerBindings(zeroFunder, 'zeroFunder'));
    passed += 1;

    const duplicateEvent = structuredClone(fixture.success);
    duplicateEvent.events.push(structuredClone(duplicateEvent.events[0]));
    expectFailure('exactly one', () => validateSuccess(duplicateEvent, duplicateEvent));
    passed += 1;

    const wrongFinal = structuredClone(fixture.success);
    wrongFinal.postState.objects.find((item) => item.role === 'treasury_cap').selected.totalSupply = '1';
    expectFailure('content selected fields', () => validateSuccess(wrongFinal, wrongFinal));
    passed += 1;

    const wrongCheckpoint = structuredClone(fixture.success);
    wrongCheckpoint.events[0].parsedJson.pos0.checkpoint.free_collateral = '999';
    expectFailure('success.checkpoint', () => validateSuccess(wrongCheckpoint, wrongCheckpoint));
    passed += 1;

    const wrongRegistry = structuredClone(fixture.success);
    wrongRegistry.events[0].parsedJson.pos0.registry_id = wrongRegistry.initializer.arguments[6].slice(1);
    expectFailure('success.registry_id', () => validateSuccess(wrongRegistry, wrongRegistry));
    passed += 1;

    const wrongSeedAmount = structuredClone(fixture.success);
    wrongSeedAmount.events[0].parsedJson.pos0.seed_amount = '1';
    expectFailure('success.seed_amount', () => validateSuccess(wrongSeedAmount, wrongSeedAmount));
    passed += 1;

    const unexpectedProtocolEvent = structuredClone(fixture.success);
    unexpectedProtocolEvent.events.push({
        type: `${fixture.success.packageId}::events_wrapper::Event<${fixture.success.packageId}::events::Unexpected>`,
        parsedJson: { pos0: {} },
    });
    expectFailure('unexpected protocol event', () => validateSuccess(
        unexpectedProtocolEvent,
        unexpectedProtocolEvent,
    ));
    passed += 1;

    const wrongLockedOwner = structuredClone(fixture.success);
    wrongLockedOwner.postState.objects.find((item) =>
        item.role === 'locked_share_coin').owner.AddressOwner = fixture.success.initializer.arguments[1].slice(1);
    expectFailure('success.locked_share_coin.effect output', () => validateSuccess(
        wrongLockedOwner,
        wrongLockedOwner,
    ));
    passed += 1;

    const wrongEffect = structuredClone(fixture.success);
    const lockedEffect = wrongEffect.effectKinds.created.shift();
    wrongEffect.effectKinds.mutated.push(lockedEffect);
    expectFailure('locked_share_coin', () => validateSuccess(wrongEffect, wrongEffect));
    passed += 1;

    const unexpectedEffect = structuredClone(fixture.success);
    unexpectedEffect.effectKinds.created.push({
        id: '0x1818181818181818181818181818181818181818181818181818181818181818',
    });
    expectFailure('protocol effects', () => validateSuccess(
        unexpectedEffect,
        unexpectedEffect,
    ));
    passed += 1;

    const duplicateEffectCategory = structuredClone(fixture.success);
    duplicateEffectCategory.effectKinds.mutated.push(structuredClone(
        duplicateEffectCategory.effectKinds.created[0],
    ));
    expectFailure('protocol effects', () => validateSuccess(
        duplicateEffectCategory,
        duplicateEffectCategory,
    ));
    passed += 1;

    const wrongEffectOwner = structuredClone(fixture.success);
    wrongEffectOwner.effectKinds.created[0].owner.AddressOwner = fixture.success.initializer.arguments[1].slice(1);
    expectFailure('locked_share_coin.effect output', () => validateSuccess(
        wrongEffectOwner,
        wrongEffectOwner,
    ));
    passed += 1;

    const wrongEffectDigest = structuredClone(fixture.success);
    wrongEffectDigest.effectKinds.mutated[0].digest = 'WrongVaultDigest';
    expectFailure('vault.effect output', () => validateSuccess(
        wrongEffectDigest,
        wrongEffectDigest,
    ));
    passed += 1;

    const wrongSelector = structuredClone(fixture.success.trackedObjects);
    wrongSelector.find((tracked) => tracked.role === 'treasury_cap')
        .selectors.totalSupply = '/content/fields/unrelated';
    expectFailure('wrongSelector[3].selectors', () => validateTrackedObjects(
        wrongSelector,
        'wrongSelector',
    ));
    passed += 1;

    const wrongDerivedIdentity = structuredClone(fixture.success);
    wrongDerivedIdentity.trackedObjects.find((tracked) =>
        tracked.role === 'locked_share_coin').id = fixture.success.initializer.arguments[1].slice(1);
    expectFailure('creation index derives', () => bindTrackedObjects(
        wrongDerivedIdentity,
        wrongDerivedIdentity,
        'wrongDerivedIdentity',
    ));
    passed += 1;

    const missingOriginIdentity = structuredClone(fixture.success);
    missingOriginIdentity.originEffects[0].objectIds.pop();
    expectFailure('treasury_cap: id is not in origin transaction effects', () =>
        bindTrackedObjects(missingOriginIdentity, missingOriginIdentity, 'missingOriginIdentity'));
    passed += 1;

    const survivingState = structuredClone(fixture.failures[0]);
    survivingState.evidence.postState.objects[0].digest = 'changed';
    expectFailure('.state', () => validateOfflineFailure(
        survivingState, fixture.baseline, PHASES[0], 'survivingState',
    ));
    passed += 1;

    const event = structuredClone(fixture.failures[1]);
    event.evidence.events.push({ type: 'VaultInitialized' });
    expectFailure('emitted an event', () => validateOfflineFailure(
        event, fixture.baseline, PHASES[1], 'event',
    ));
    passed += 1;

    const nonGas = structuredClone(fixture.failures[2]);
    nonGas.evidence.changedObjects.push({ kind: 'protocol', id: fixture.baseline.objects[0].id });
    expectFailure('non-gas object', () => validateOfflineFailure(
        nonGas, fixture.baseline, PHASES[2], 'nonGas',
    ));
    passed += 1;

    const relabeled = structuredClone(fixture.failures[3]);
    relabeled.runConfig.case = 'A5';
    expectFailure('expected A4', () => validateOfflineFailure(
        relabeled, fixture.baseline, PHASES[3], 'relabeled',
    ));
    passed += 1;

    const wrongAbort = structuredClone(fixture.failures[4]);
    wrongAbort.evidence.error = wrongAbort.evidence.error.replace('9105', '9106');
    expectFailure('exact abort code 9105', () => validateOfflineFailure(
        wrongAbort, fixture.baseline, PHASES[4], 'wrongAbort',
    ));
    passed += 1;

    const wrongInitializerArgument = structuredClone(fixture.failures[0]);
    const wrongVault = `0x${'e'.repeat(64)}`;
    const originalVault = wrongInitializerArgument.runConfig.initializer.arguments[0];
    wrongInitializerArgument.runConfig.initializer.arguments[0] = `@${wrongVault}`;
    const initializerVaultIndex = wrongInitializerArgument.runConfig.ptbArgs.indexOf(originalVault);
    wrongInitializerArgument.runConfig.ptbArgs[initializerVaultIndex] = `@${wrongVault}`;
    wrongInitializerArgument.runConfig.ptbArgs.push(
        '--move-call',
        `${wrongInitializerArgument.runConfig.packageId}::decoy::mention`,
        originalVault,
    );
    expectFailure('initializer role vault', () => validateOfflineFailure(
        wrongInitializerArgument, fixture.baseline, PHASES[0], 'wrongInitializerArgument',
    ));
    passed += 1;

    const decoyRegistry = structuredClone(fixture.failures[1]);
    const originalRegistry = decoyRegistry.runConfig.initializer.arguments[4];
    const wrongRegistryId = `@0x${'d'.repeat(64)}`;
    decoyRegistry.runConfig.initializer.arguments[4] = wrongRegistryId;
    decoyRegistry.runConfig.ptbArgs[decoyRegistry.runConfig.ptbArgs.indexOf(originalRegistry)] = wrongRegistryId;
    decoyRegistry.runConfig.ptbArgs.push(
        '--move-call',
        `${decoyRegistry.runConfig.packageId}::decoy::mention`,
        originalRegistry,
    );
    expectFailure('initializer role registry', () => validateOfflineFailure(
        decoyRegistry, fixture.baseline, PHASES[1], 'decoyRegistry',
    ));
    passed += 1;

    const duplicateInitializer = structuredClone(fixture.failures[2]);
    duplicateInitializer.runConfig.ptbArgs.push(
        '--move-call',
        duplicateInitializer.runConfig.initializer.target,
        `<${duplicateInitializer.runConfig.initializer.typeArguments.join(',')}>`,
        ...duplicateInitializer.runConfig.initializer.arguments,
    );
    expectFailure('expected exactly one', () => validateOfflineFailure(
        duplicateInitializer, fixture.baseline, PHASES[2], 'duplicateInitializer',
    ));
    passed += 1;

    const initializerTargetArgument = structuredClone(fixture.failures[3]);
    initializerTargetArgument.runConfig.ptbArgs.push(
        initializerTargetArgument.runConfig.initializer.target,
    );
    expectFailure('target-shaped argument', () => validateOfflineFailure(
        initializerTargetArgument, fixture.baseline, PHASES[3], 'initializerTargetArgument',
    ));
    passed += 1;

    const relabeledMarker = structuredClone(fixture.failures[5]);
    relabeledMarker.runConfig.instrumentation.productionSource =
        relabeledMarker.runConfig.instrumentation.productionSource.replace(
            PHASES[5].marker,
            PHASES[6].marker,
        );
    expectFailure('marker must be one standalone line', () => validateOfflineFailure(
        relabeledMarker, fixture.baseline, PHASES[5], 'relabeledMarker',
    ));
    passed += 1;

    const relabeledInstrumentationCode = structuredClone(fixture.failures[5]);
    relabeledInstrumentationCode.runConfig.instrumentation.instrumentedSource =
        relabeledInstrumentationCode.runConfig.instrumentation.instrumentedSource.replace(
            'abort 9106;',
            'abort 9107;',
        );
    expectFailure('expected abort 9106;', () => validateOfflineFailure(
        relabeledInstrumentationCode,
        fixture.baseline,
        PHASES[5],
        'relabeledInstrumentationCode',
    ));
    passed += 1;

    const invalidInstrumentation = structuredClone(fixture.failures[6]);
    invalidInstrumentation.runConfig.instrumentation.instrumentedSource += '\nextra();';
    expectFailure('add exactly one line', () => validateOfflineFailure(
        invalidInstrumentation, fixture.baseline, PHASES[6], 'invalidInstrumentation',
    ));
    passed += 1;

    const collateralArgumentDecoy = structuredClone(fixture.failures[0]);
    const collateralArgument = collateralArgumentDecoy.runConfig.initializer.arguments[3];
    collateralArgumentDecoy.runConfig.initializer.arguments[3] =
        `@${collateralArgumentDecoy.runConfig.trackedObjects.find((item) => item.role === 'share_currency').id}`;
    collateralArgumentDecoy.runConfig.ptbArgs[
        collateralArgumentDecoy.runConfig.ptbArgs.indexOf(collateralArgument)
    ] = collateralArgumentDecoy.runConfig.initializer.arguments[3];
    collateralArgumentDecoy.runConfig.ptbArgs.push(
        '--move-call',
        `${collateralArgumentDecoy.runConfig.packageId}::decoy::mention`,
        collateralArgument,
    );
    expectFailure('initializer role collateral_currency', () => validateOfflineFailure(
        collateralArgumentDecoy,
        fixture.baseline,
        PHASES[0],
        'collateralArgumentDecoy',
    ));
    passed += 1;

    const wrongCollateralType = structuredClone(fixture.failures[0]);
    wrongCollateralType.runConfig.trackedObjects.find((item) => item.role === 'collateral_currency')
        .expectedType = wrongCollateralType.runConfig.trackedObjects.find((item) => item.role === 'share_currency')
            .expectedType;
    expectFailure('collateral_currency.type', () => validateOfflineFailure(
        wrongCollateralType,
        fixture.baseline,
        PHASES[0],
        'wrongCollateralType',
    ));
    passed += 1;

    const stateCases = [
        ['field set mismatch', (object) => { delete object.type; }],
        ['expected type', (object) => { object.type = '0x2::wrong::Wrong'; }],
        ['field set mismatch', (object) => { delete object.owner; }],
        ['expected canonical owner', (object) => { object.owner = { AddressOwner: 'not-an-address' }; }],
        ['field set mismatch', (object) => { delete object.selected.lifecycle; }],
        ['content selected fields', (object) => { object.selected.lifecycle = 'Active'; }],
        ['field set mismatch', (object) => { delete object.version; }],
        ['canonical positive integer string', (object) => { object.version = 7; }],
        ['field set mismatch', (object) => { delete object.digest; }],
        ['expected non-empty string', (object) => { object.digest = ''; }],
        ['field set mismatch', (object) => { delete object.content; }],
        ['content selected fields', (object) => {
            object.content.series_state.lifecycle = 'Active';
        }],
    ];
    for (const [message, mutate] of stateCases) {
        const state = structuredClone(fixture.baseline);
        mutate(state.objects.find((item) => item.role === 'vault'));
        expectFailure(message, () => assertStateTracksRunConfig(
            state,
            fixture.success,
            `state.${message}`,
        ));
        passed += 1;
    }

    const optionTracked = {
        role: 'vault',
        selectors: {
            venueAccount: '/content/venue_account/account_object_id',
            adminCap: '/content/venue_account/admin_cap/id',
        },
    };
    const optionAccountId = '0x034401905bebdf8c04f3cd5f04f442a39372c8dc321c29edfb4f9cb30b23ab96';
    const optionAdminCapId = '0x5ef2fcf809fb9535ea0aeaea421f683026f06c34569aafc42bcde652ef6dd270';
    const optionSome = {
        content: {
            venue_account: {
                account_object_id: optionAccountId,
                admin_cap: { id: optionAdminCapId },
            },
        },
    };
    assertEqual(
        statePointer(optionSome, optionTracked, 'venueAccount', 'option.some'),
        optionAccountId,
        'option.some',
    );
    passed += 1;
    assertEqual(
        statePointer({ content: { venue_account: null } }, optionTracked, 'venueAccount', 'option.none'),
        null,
        'option.none',
    );
    passed += 1;
    assertEqual(
        statePointer(
            { content: { venue_account: { account_object_id: optionAccountId, admin_cap: null } } },
            optionTracked,
            'adminCap',
            'option.nestedNone',
        ),
        null,
        'option.nestedNone',
    );
    passed += 1;
    expectFailure('does not exist', () => statePointer(
        { content: {} }, optionTracked, 'venueAccount', 'option.missing',
    ));
    passed += 1;
    expectFailure('does not exist', () => statePointer(
        { content: { venue_account: { fields: { vec: [] } } } },
        optionTracked,
        'venueAccount',
        'option.malformed',
    ));
    passed += 1;
    expectFailure('does not exist', () => statePointer(
        { content: { venue_account: { account_object_id: optionAccountId } } },
        optionTracked,
        'adminCap',
        'option.missingNested',
    ));
    passed += 1;

    const production = `statement();\n${PHASES[0].marker}\nnext();`;
    const instrumented = `statement();\n${PHASES[0].marker}\nabort 9101;\nnext();`;
    assertInstrumentedSource(production, instrumented, PHASES[0]);
    passed += 1;
    expectFailure('add exactly one line', () => assertInstrumentedSource(
        production,
        `${instrumented}\nextra`,
        PHASES[0],
    ));
    passed += 1;

    process.stdout.write(`activation_atomicity self-test: PASS ${passed}/53 cases\n`);
}

function live(configPath) {
    if (!configPath) {
        fail('controlled rollback proof requires --config <controlled-submission.json> or BLAST_ATOMICITY_CONFIG; no funded fixture or failpoint deployment is recorded');
    }
    assertPinnedSuiVersion();
    const config = readJson(resolve(configPath));
    expectObject(config, 'config', [
        'schemaVersion', 'fixtureKind', 'environment', 'chainIdentifier', 'outputPath',
        'review', 'production', 'success', 'failures',
    ]);
    if (config.schemaVersion !== 2 || config.fixtureKind !== 'controlled-submission') {
        fail('config: unsupported schema or kind');
    }
    if (config.environment !== 'testnet') fail('config: only controlled testnet submission is accepted');
    if (config.chainIdentifier !== TESTNET_CHAIN) fail('config: testnet chain identifier drift');
    const chain = parseChainIdentifier(runSui([
        'client', '--client.env', config.environment, 'chain-identifier',
    ]).stdout);
    if (chain !== config.chainIdentifier) fail(`testnet chain mismatch: expected ${config.chainIdentifier}, got ${chain}`);

    const review = verifyReview(config.review);
    const production = verifyProduction(config.environment, config.production);
    if (review.productionSourcesSha256 !== production.sourcesSha256) {
        fail('production package does not match reviewed sources');
    }

    expectObject(config.success, 'config.success', [
        'packageId', 'initializer', 'ptbArgs', 'trackedObjects', 'expectedFinal',
    ]);
    if (config.success.packageId !== production.packageId) fail('config.success: initializer must use proven production package');
    const success = submit(config.environment, config.success, 'config.success');
    success.originEffects = collectOriginEffects(config.environment, config.success);
    const vaultInitialized = validateSuccess(success, config.success);

    if (!Array.isArray(config.failures) || config.failures.length !== PHASES.length) {
        fail('config.failures: expected A1-A7 exactly once');
    }
    const failures = [];
    const originCache = new Map();
    config.failures.forEach((runConfig, index) => {
        const phase = PHASES[index];
        expectObject(runConfig, `config.failures[${index}]`, [
            'case', 'packageId', 'initializer', 'ptbArgs', 'trackedObjects', 'instrumentation',
        ]);
        if (runConfig.case !== phase.case) fail(`config.failures[${index}]: expected ${phase.case}`);
        const instrumentation = verifyInstrumentation(
            config.environment,
            runConfig.instrumentation,
            production,
            phase,
        );
        if (runConfig.packageId !== instrumentation.package.packageId) {
            fail(`${phase.case}: initializer must use proven instrumented package`);
        }
        const evidence = submit(config.environment, runConfig, `config.failures[${index}]`);
        evidence.originEffects = collectOriginEffects(
            config.environment,
            runConfig,
            originCache,
        );
        validateFailureEvidence(
            runConfig,
            evidence,
            evidence.preState,
            phase,
            phase.case,
        );
        failures.push(canonical({ phase, instrumentation, ...evidence }));
    });

    const outputPath = resolve(config.outputPath);
    if (outputPath === resolve(FIXTURE_PATH)) fail('live evidence must not overwrite the offline fixture');
    const output = canonical({
        schemaVersion: 2,
        evidenceKind: 'submitted-controlled-testnet',
        chainIdentifier: chain,
        review,
        production,
        success: { ...success, vaultInitialized },
        failures,
    });
    writeFileSync(outputPath, `${JSON.stringify(output, null, 2)}\n`, { flag: 'wx', mode: 0o600 });
    process.stdout.write(`activation_atomicity: PASS submitted success and A1-A7; evidence ${outputPath}\n`);
}

function parseArgs(args) {
    if (args.length === 1 && args[0] === '--self-test') return { selfTest: true, config: null };
    if (args.length === 2 && args[0] === '--config') return { selfTest: false, config: args[1] };
    if (args.length === 0) return { selfTest: false, config: process.env.BLAST_ATOMICITY_CONFIG ?? null };
    fail('usage: activation_atomicity.mjs [--self-test|--config <path>]');
}

try {
    const args = parseArgs(process.argv.slice(2));
    if (args.selfTest) selfTest(); else live(args.config);
} catch (error) {
    process.stderr.write(`activation_atomicity: FAIL ${error.message}\n`);
    process.exitCode = 1;
}
