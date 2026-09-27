#!/usr/bin/env node
// Submits controlled activation transactions and proves both the successful
// final state and A1-A5 rollback against canonical Sui transaction/object
// output. The activation PTB is the reviewed issue -> initialize -> share plan
// that dev_inspect_activation builds; nothing here composes calls by hand.

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
import { fileURLToPath, pathToFileURL } from 'node:url';
import { spawnSync } from 'node:child_process';
import process from 'node:process';
import { buildPlan, renderMoveCalls } from './dev_inspect_activation.mjs';

const SCRIPT_DIR = dirname(fileURLToPath(import.meta.url));
const PACKAGE_DIR = resolve(SCRIPT_DIR, '..');
const FIXTURE_PATH = join(SCRIPT_DIR, 'fixtures', 'activation-atomicity-vectors.json');
const OPERATIONS_PATH = join(PACKAGE_DIR, 'sources', 'operations.move');
const TESTNET_CHAIN = '69WiPg3DAQiwdxfncX6wYQ2siKwAe6L9BZthQea3JNMD';
const PINNED_SUI_VERSION = '1.77.2-51d177ad7d65';
// The five activation boundaries of ADR 0087, in `operations::initialize`.
// A failpoint package aborts immediately after one marker; the proof shows
// every object the transaction touched rolled back.
const PHASES = [
    { case: 'A1', phase: 'state::activate', marker: '// BLAST_ACTIVATION_BOUNDARY_A1', abortCode: '9101' },
    { case: 'A2', phase: 'account::consume_policy_and_share_account', marker: '// BLAST_ACTIVATION_BOUNDARY_A2', abortCode: '9102' },
    { case: 'A3', phase: 'clearing_house::share', marker: '// BLAST_ACTIVATION_BOUNDARY_A3', abortCode: '9103' },
    { case: 'A4', phase: 'events::vault_initialized', marker: '// BLAST_ACTIVATION_BOUNDARY_A4', abortCode: '9104' },
    { case: 'A5', phase: 'return Vault', marker: '// BLAST_ACTIVATION_BOUNDARY_A5', abortCode: '9105' },
];
// Tracked roles: every activation input, then every object the transaction
// creates, wraps or deletes. Input roles name their builderInput object.
const INPUT_ROLE_OBJECT = {
    acl: 'acl',
    admin_cap: 'adminCap',
    protocol: 'protocol',
    coin_registry: 'coinRegistry',
    collateral_currency: 'currency',
    registry: 'registry',
    clearing_house: 'clearingHouse',
    base_oracle: 'baseOracle',
    collateral_oracle: 'collateralOracle',
    seed_coin: 'seedCoin',
    clock: 'clock',
};
const ROLE_POINTERS = {
    acl: {},
    admin_cap: {},
    protocol: {},
    coin_registry: {},
    collateral_currency: {},
    registry: {},
    clearing_house: { marketState: '/content/market_state' },
    base_oracle: {},
    collateral_oracle: {},
    seed_coin: { balance: '/content/balance' },
    clock: {},
    vault: {
        lifecycle: '/content/state/lifecycle',
        maintenanceReserve: '/content/state/maintenance_reserve',
        venueAccount: '/content/venue_account/binding/account_object_id',
        checkpoint: '/content/venue_account/checkpoint',
        adminCap: '/content/venue_account/admin_cap/id',
        lockedShares: '/content/locked_shares',
    },
    treasury_cap: { totalSupply: '/content/total_supply/value' },
    metadata_cap: {},
    locked_share_coin: { balance: '/content/balance' },
    aftermath_account: {
        accountNumber: '/content/account_id',
        collateral: '/content/collateral/value',
    },
    aftermath_admin_cap: {},
    aftermath_transfer_policy: {},
};
const ROLE_SELECTORS = Object.fromEntries(
    Object.entries(ROLE_POINTERS).map(([role, pointers]) => [role, Object.keys(pointers)]),
);
const OPTION_ROOTS_BY_SELECTOR = {};
const SELECTOR_VALUE_KIND = {
    'vault.venueAccount': 'address',
    'vault.checkpoint': 'object',
    'vault.adminCap': 'address',
};
const REQUIRED_TRACKED_ROLES = Object.keys(ROLE_SELECTORS);
// What the successful activation does to each tracked object; null is untouched.
const SUCCESS_EFFECT_BY_ROLE = {
    acl: null,
    admin_cap: null,
    protocol: null,
    coin_registry: 'mutated',
    collateral_currency: null,
    registry: 'mutated',
    clearing_house: 'mutated',
    base_oracle: null,
    collateral_oracle: null,
    seed_coin: 'deleted',
    clock: null,
    vault: 'created',
    treasury_cap: 'created',
    metadata_cap: 'created',
    locked_share_coin: 'created',
    aftermath_account: 'created',
    aftermath_admin_cap: 'wrapped',
    aftermath_transfer_policy: 'deleted',
};
// Created objects are bound by their creation index in the transaction, which
// the recorded evidence carries; inputs are bound to the builder input.
const BINDING_BY_ROLE = Object.fromEntries(REQUIRED_TRACKED_ROLES.map((role) =>
    [role, { kind: INPUT_ROLE_OBJECT[role] === undefined ? 'derived' : 'argument' }]));
const ZERO_ADDRESS = `0x${'0'.repeat(64)}`;
const SEED_SHARE_SCALE = 1_000n;
const U256_MODULUS = 1n << 256n;
const U256_SIGN_BIT = 1n << 255n;
const INITIALIZED_FIELDS = [
    'vault_id', 'binding', 'seed_amount', 'seed_venue_equity', 'seed_reserve',
    'seed_shareholder_nav', 'locked_shares', 'position_base', 'lot_size',
    'position_side', 'position_imr', 'checkpoint',
];
const BINDING_FIELDS = [
    'account_object_id', 'account_number', 'registry_id', 'clearing_house_id',
    'base_oracle_id', 'collateral_oracle_id', 'base_feed_id', 'collateral_feed_id',
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
    const creationIndices = new Set();
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
        if (tracked.binding.kind === 'derived') {
            if (!tracked.allowAbsent) fail(`${itemPath}: a created object is absent before activation`);
            if (creationIndices.has(tracked.binding.creationIndex)) {
                fail(`${itemPath}.binding: creation index ${tracked.binding.creationIndex} is bound twice`);
            }
            creationIndices.add(tracked.binding.creationIndex);
        }
    });
}

/// One spelling for a type tag: no whitespace, short-form addresses. Sui
/// prints generic parameters as `A, B`; the config may write `A,B`.
function normalizeTypeTag(value, path) {
    const type = expectString(value, path);
    if (/\s(?!\S)|^\s|\s$|[^,]\s/.test(type)) fail(`${path}: whitespace may only follow a comma`);
    return type.replace(/,\s+/g, ',').replace(/0x[0-9a-fA-F]+/g, (address) =>
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
    if (observedType !== expectedType) {
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

function assertTrackedTypeBindings(runConfig, path) {
    const input = runConfig.builderInput;
    const adapter = runConfig.packageId;
    const vaultIssuer = `${input.corePackage.toLowerCase()}::blast_boosts_core::VaultIssuer`;
    const boostType = `${adapter}::blast_boost::BlastBoost<${input.productType}>`;
    const exact = {
        acl: `${input.adminPackage.toLowerCase()}::blast_acl::ACL`,
        admin_cap: `${input.adminPackage.toLowerCase()}::blast_acl::AdminCap<${vaultIssuer}>`,
        protocol: `${adapter}::protocol::Protocol`,
        coin_registry: '0x2::coin_registry::CoinRegistry',
        collateral_currency: `0x2::coin_registry::Currency<${input.collateralType}>`,
        seed_coin: `0x2::coin::Coin<${input.collateralType}>`,
        clock: '0x2::clock::Clock',
        vault: `${adapter}::vault::Vault<${input.productType}, ${input.collateralType}>`,
        treasury_cap: `0x2::coin::TreasuryCap<${boostType}>`,
        metadata_cap: `0x2::coin_registry::MetadataCap<${boostType}>`,
        locked_share_coin: `0x2::coin::Coin<${boostType}>`,
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
        `${perpetualsPackage}::clearing_house::ClearingHouse<${input.collateralType}>`,
        `${path}.clearing_house.type`,
    );
    assertEqual(
        trackedObject(runConfig, 'aftermath_account', `${path}.trackedObjects`).expectedType,
        `${perpetualsPackage}::account::Account<${input.collateralType}>`,
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
}

function assertInputRoleBindings(runConfig, path) {
    for (const [role, inputRole] of Object.entries(INPUT_ROLE_OBJECT)) {
        assertEqual(
            trackedObject(runConfig, role, `${path}.trackedObjects`).id,
            runConfig.builderInput.objects[inputRole].toLowerCase(),
            `${path}.activation input ${role}`,
        );
    }
}

/// A run is the reviewed activation plan for one adapter package over one set
/// of tracked objects; the plan is rebuilt here, never read from the config.
function validateRunConfig(runConfig, path) {
    const packageId = expectAddress(runConfig.packageId, `${path}.packageId`);
    const plan = buildPlan(runConfig.builderInput);
    if (runConfig.builderInput.adapterPackage.toLowerCase() !== packageId) {
        fail(`${path}.builderInput.adapterPackage: must be the run's package`);
    }
    if (!runConfig.builderInput.productType.startsWith('0x')) {
        fail(`${path}.builderInput.productType: expected a canonical product tag type`);
    }
    validateTrackedObjects(runConfig.trackedObjects, `${path}.trackedObjects`);
    assertInputRoleBindings(runConfig, path);
    assertTrackedTypeBindings(runConfig, path);
    return { packageId, plan };
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
    const { plan } = validateRunConfig(runConfig, path);
    const preState = snapshotState(environment, runConfig.trackedObjects, `${path}.trackedObjects`);
    const args = ['client', '--client.env', environment, 'ptb', ...renderMoveCalls(plan), '--json'];
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
            const inputRole = INPUT_ROLE_OBJECT[tracked.role];
            if (inputRole === undefined) {
                fail(`${path}.${tracked.role}: no canonical activation input role`);
            }
            if (runConfig.builderInput.objects[inputRole].toLowerCase() !== id) {
                fail(`${path}.${tracked.role}: id is not the canonical activation input`);
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
    const collateralCurrency = stateObject(evidence.postState, 'collateral_currency', 'success.postState');
    const cap = stateObject(evidence.postState, 'treasury_cap', 'success.postState');
    const metadata = stateObject(evidence.postState, 'metadata_cap', 'success.postState');
    const locked = stateObject(evidence.postState, 'locked_share_coin', 'success.postState');
    const account = stateObject(evidence.postState, 'aftermath_account', 'success.postState');
    const registry = stateObject(evidence.postState, 'registry', 'success.postState');
    const clearingHouse = stateObject(evidence.postState, 'clearing_house', 'success.postState');
    assertOwnerKind(vault.owner, 'shared', 'success.vault.owner');
    assertOwnerKind(collateralCurrency.owner, 'shared', 'success.collateral_currency.owner');
    assertOwnerKind(cap.owner, 'object', 'success.treasury_cap.owner', vault.id);
    assertOwnerKind(metadata.owner, 'object', 'success.metadata_cap.owner', vault.id);
    assertOwnerKind(locked.owner, 'address', 'success.locked_share_coin.owner', ZERO_ADDRESS);
    assertOwnerKind(account.owner, 'shared', 'success.aftermath_account.owner');
    assertOwnerKind(registry.owner, 'shared', 'success.registry.owner');
    assertOwnerKind(clearingHouse.owner, 'shared', 'success.clearing_house.owner');
}

function initializedEvent(evidence, runConfig) {
    const eventPrefix = `${runConfig.packageId}::blast_events::Event<${runConfig.packageId}::events::`;
    const expectedType = `${eventPrefix}VaultInitialized<${runConfig.builderInput.productType}>>`;
    const protocolEvents = evidence.events.filter((event) =>
        typeof event?.type === 'string'
        && event.type.startsWith(eventPrefix));
    const foreign = protocolEvents.filter((event) => event.type !== expectedType
        && !event.type.startsWith(`${eventPrefix}VaultIssued<`));
    if (foreign.length !== 0) fail('success.events: unexpected protocol event');
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
    expectObject(parsedJson.binding, 'success.VaultInitialized.binding', BINDING_FIELDS);
    expectObject(parsedJson.checkpoint, 'success.VaultInitialized.checkpoint', CHECKPOINT_FIELDS);
    return canonical({ type: event.type, parsedJson });
}

/// The successful activation: every tracked object ends in its expected
/// custody, the effects are exactly the expected ones, and the one
/// VaultInitialized event agrees with the inputs and with the objects it
/// names.
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
    const input = runConfig.builderInput;
    const vault = stateObject(evidence.postState, 'vault', 'success.postState');
    const cap = stateObject(evidence.postState, 'treasury_cap', 'success.postState');
    const metadata = stateObject(evidence.postState, 'metadata_cap', 'success.postState');
    const locked = stateObject(evidence.postState, 'locked_share_coin', 'success.postState');
    const admin = stateObject(evidence.postState, 'aftermath_admin_cap', 'success.postState');
    const transferPolicy = stateObject(evidence.postState, 'aftermath_transfer_policy', 'success.postState');
    const account = stateObject(evidence.postState, 'aftermath_account', 'success.postState');
    const seed = stateObject(evidence.postState, 'seed_coin', 'success.postState');
    const seedBefore = stateObject(evidence.preState, 'seed_coin', 'success.preState');
    const vaultBefore = stateObject(evidence.preState, 'vault', 'success.preState');
    if (!vault.exists || vaultBefore.exists || !cap.exists || !metadata.exists || !locked.exists
        || admin.exists || transferPolicy.exists || !account.exists || seed.exists || !seedBefore.exists) {
        fail('success.postState: final custody/object existence mismatch');
    }
    const lockedShares = BigInt(cap.selected.totalSupply);
    if (lockedShares % SEED_SHARE_SCALE !== 0n) {
        fail('success.locked_shares: supply is not an exact seed-share multiple');
    }
    const seedNav = lockedShares / SEED_SHARE_SCALE;
    const seedReserve = BigInt(input.seedReserve);
    const signedBase = signedMagnitude(fields.checkpoint.signed_base, 'success.checkpoint.signed_base');
    const signedQuote = signedMagnitude(
        fields.checkpoint.signed_quote_notional,
        'success.checkpoint.signed_quote_notional',
    );
    if (signedBase.magnitude === 0n) fail('success.checkpoint.signed_base: the seed must open a position');
    // The venue carries the quote notional under the base's sign (position bytecode, 2026-09-20).
    if (signedQuote.magnitude === 0n || signedQuote.negative !== signedBase.negative) {
        fail('success.position_side: base and quote signs are incoherent');
    }
    const expectedSide = signedBase.negative ? 'short' : 'long';
    const relations = [
        [fields.vault_id, vault.id, 'vault_id'],
        [fields.binding.account_object_id, account.id, 'binding.account_object_id'],
        [String(fields.binding.account_number), String(account.selected.accountNumber), 'binding.account_number'],
        [fields.binding.registry_id, input.objects.registry.toLowerCase(), 'binding.registry_id'],
        [fields.binding.clearing_house_id, input.objects.clearingHouse.toLowerCase(), 'binding.clearing_house_id'],
        [fields.binding.base_oracle_id, input.objects.baseOracle.toLowerCase(), 'binding.base_oracle_id'],
        [fields.binding.collateral_oracle_id, input.objects.collateralOracle.toLowerCase(), 'binding.collateral_oracle_id'],
        [String(fields.seed_amount), String(seedBefore.selected.balance), 'seed_amount'],
        [String(fields.seed_venue_equity), String(seedNav + seedReserve), 'seed_venue_equity'],
        [String(fields.seed_reserve), String(seedReserve), 'seed_reserve input'],
        [String(fields.seed_reserve), String(vault.selected.maintenanceReserve), 'seed_reserve state'],
        [String(fields.seed_shareholder_nav), String(seedNav), 'seed_shareholder_nav'],
        [String(fields.locked_shares), String(lockedShares), 'locked_shares supply'],
        [String(fields.locked_shares), String(locked.selected.balance), 'locked_shares balance'],
        [String(fields.locked_shares), String(vault.selected.lockedShares), 'locked_shares state'],
        [String(fields.position_base), String(fixedToAtomicUp(signedBase.magnitude, 9, 'success.position_base')), 'position_base'],
        [String(fields.lot_size), String(fields.checkpoint.lot_size), 'lot_size'],
        [positionSide(fields.position_side, 'success.position_side'), expectedSide, 'position_side'],
        [positionSide(fields.position_side, 'success.position_side'), input.side, 'position_side input'],
        [String(fields.position_imr), input.positionImr, 'position_imr input'],
        [String(fields.position_imr), String(fields.checkpoint.position_initial_margin_ratio), 'position_imr checkpoint'],
        [fields.checkpoint, vault.selected.checkpoint, 'checkpoint'],
        [vault.selected.lifecycle, 'Active', 'lifecycle'],
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

/// The production operations source with one abort line after the phase marker:
/// what a failpoint package for that phase must contain.
function instrumentedSource(production, phase) {
    return production.replace(phase.marker, `${phase.marker}\n    abort ${phase.abortCode};`);
}

/// A recorded failpoint run: its evidence is a rolled-back MoveAbort with that
/// phase's code. The instrumented source itself is provenance of the live run
/// and is checked against the deployed tree there, not stored offline.
function validateOfflineFailure(entry, baseline, phase, path) {
    expectObject(entry, path, ['runConfig', 'evidence']);
    const runConfig = expectObject(entry.runConfig, `${path}.runConfig`, [
        'case', 'packageId', 'builderInput', 'trackedObjects',
    ]);
    if (runConfig.case !== phase.case) fail(`${path}.runConfig.case: expected ${phase.case}`);
    validateRunConfig(runConfig, `${path}.runConfig`);
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
        'schemaVersion', 'fixtureKind', 'gasDifferencePolicy', 'baseline', 'success', 'failures',
    ]);
    if (fixture.schemaVersion !== 5 || fixture.fixtureKind !== 'canonical-evidence-validator') {
        fail('fixture: unsupported schema or kind');
    }
    if (fixture.gasDifferencePolicy !== 'gas-only') fail('fixture: rollback may allow gas changes only');
    expectObject(fixture.success, 'fixture.success', [
        'packageId', 'builderInput', 'trackedObjects', 'expectedFinal',
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
        fail('fixture.failures: expected A1-A5 exactly once');
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
    const success = {
        ...fixture.success,
        preState: resolveState(fixture.success.preState, fixture.baseline, 'fixture.success.preState'),
    };
    let passed = 3;
    const failing = (label, mutate, message) => {
        const evidence = structuredClone(success);
        mutate(evidence);
        expectFailure(message, () => validateSuccess(evidence, evidence));
        passed += 1;
    };
    const stateObjectOf = (evidence, state, role) => evidence[state].objects.find((item) => item.role === role);

    const initialized = (e) => e.events.find((event) => event.type.includes('::events::VaultInitialized<'));
    failing('duplicate event', (e) => e.events.push(structuredClone(initialized(e))), 'exactly one');
    failing('foreign event', (e) => e.events.push({
        type: `${e.packageId}::blast_events::Event<${e.packageId}::events::Minted<${e.builderInput.productType}>>`,
        parsedJson: { pos0: {} },
    }), 'unexpected protocol event');
    failing('final vault absent', (e) => { e.expectedFinal.vault = null; }, 'object must be absent');
    failing('checkpoint drift', (e) => {
        stateObjectOf(e, 'postState', 'vault').content.venue_account.checkpoint.lot_size = '1';
    }, 'content selected fields');
    failing('wrong reserve', (e) => { e.builderInput.seedReserve = '1'; }, 'seed_venue_equity');
    failing('wrong side', (e) => { e.builderInput.side = 'short'; }, 'position_side input');
    failing('wrong imr', (e) => { e.builderInput.positionImr = '1'; }, 'position_imr input');
    failing('wrong seed amount', (e) => {
        const seed = stateObjectOf(e, 'preState', 'seed_coin');
        seed.content.balance = '1'; seed.selected.balance = '1';
    }, 'seed_amount');
    failing('locked owner', (e) => {
        stateObjectOf(e, 'postState', 'locked_share_coin').owner.AddressOwner = e.builderInput.sender;
    }, 'locked_share_coin.effect output');
    failing('missing vault effect', (e) => { e.effectKinds.created = e.effectKinds.created.filter((c) => c.id !== fixture.success.trackedObjects.find((t) => t.role === 'vault').id); }, 'expected exactly one created effect');
    failing('extra effect', (e) => { e.effectKinds.mutated.push({ id: `0x${'f'.repeat(64)}`, version: '2', digest: 'X', owner: 'Immutable' }); }, 'protocol effects');
    failing('vault not shared', (e) => {
        const vault = stateObjectOf(e, 'postState', 'vault');
        const owner = { AddressOwner: e.builderInput.sender };
        vault.owner = owner;
        e.effectKinds.created.find((c) => c.id === vault.id).owner = owner;
    }, 'expected shared owner');
    failing('lifecycle not active', (e) => {
        const vault = stateObjectOf(e, 'postState', 'vault');
        vault.content.state.lifecycle = 'Unwinding'; vault.selected.lifecycle = 'Unwinding';
    }, 'lifecycle');
    failing('binding oracle drift', (e) => {
        initialized(e).parsedJson.pos0.binding.base_oracle_id = e.builderInput.objects.collateralOracle;
    }, 'binding.base_oracle_id');
    failing('supply not a share multiple', (e) => {
        const cap = stateObjectOf(e, 'postState', 'treasury_cap');
        cap.content.total_supply.value = '1001'; cap.selected.totalSupply = '1001';
        e.expectedFinal.treasury_cap.totalSupply = '1001';
    }, 'exact seed-share multiple');
    failing('input drift', (e) => { e.builderInput.objects.registry = e.builderInput.objects.protocol; }, 'activation input registry');
    failing('package drift', (e) => { e.builderInput.adapterPackage = e.builderInput.corePackage; }, 'adapterPackage: must be the run');
    failing('creation index bound twice', (e) => {
        const derived = e.trackedObjects.filter((t) => t.binding.kind === 'derived');
        derived[1].binding.creationIndex = derived[0].binding.creationIndex;
    }, 'is bound twice');
    failing('wrong derived id', (e) => {
        e.trackedObjects.find((t) => t.role === 'aftermath_account').binding.creationIndex += 40;
    }, 'creation index derives');
    failing('created object present before', (e) => {
        const before = stateObjectOf(e, 'preState', 'vault');
        Object.assign(before, structuredClone(stateObjectOf(e, 'postState', 'vault')));
    }, 'existence mismatch');

    const rolledBack = structuredClone(fixture.failures[0]);
    rolledBack.evidence.postState = structuredClone(rolledBack.evidence.preState);
    const seed = rolledBack.evidence.postState.objects.find((item) => item.role === 'seed_coin');
    seed.content.balance = '1'; seed.selected.balance = '1';
    expectFailure('.state', () => validateOfflineFailure(rolledBack, fixture.baseline, PHASES[0], 'rolledBack'));
    passed += 1;

    const emitted = structuredClone(fixture.failures[1]);
    emitted.evidence.events.push({ type: 'anything', parsedJson: {} });
    expectFailure('emitted an event', () => validateOfflineFailure(emitted, fixture.baseline, PHASES[1], 'emitted'));
    passed += 1;

    const touched = structuredClone(fixture.failures[2]);
    touched.evidence.changedObjects.push({ kind: 'protocol', id: `0x${'e'.repeat(64)}` });
    expectFailure('non-gas object', () => validateOfflineFailure(touched, fixture.baseline, PHASES[2], 'touched'));
    passed += 1;

    const relabeled = structuredClone(fixture.failures[3]);
    expectFailure('expected A5', () => validateOfflineFailure(relabeled, fixture.baseline, PHASES[4], 'relabeled'));
    passed += 1;

    const wrongCode = structuredClone(fixture.failures[4]);
    wrongCode.evidence.error = wrongCode.evidence.error.replace('9105', '9104');
    expectFailure('exact abort code 9105', () => validateOfflineFailure(wrongCode, fixture.baseline, PHASES[4], 'wrongCode'));
    passed += 1;

    const wrongModule = structuredClone(fixture.failures[0]);
    wrongModule.evidence.error = wrongModule.evidence.error.replace('operations', 'orders');
    expectFailure('abort module mismatch', () => validateOfflineFailure(wrongModule, fixture.baseline, PHASES[0], 'wrongModule'));
    passed += 1;

    const production = readFileSync(OPERATIONS_PATH, 'utf8');
    for (const phase of PHASES) assertInstrumentedSource(production, instrumentedSource(production, phase), phase);
    passed += 1;

    expectFailure('add exactly one line', () => assertInstrumentedSource(
        production,
        instrumentedSource(production, PHASES[0]).replace('abort 9101;', 'abort 9101;\n    abort 9101;'),
        PHASES[0],
    ));
    passed += 1;

    expectFailure('expected abort 9102; immediately after', () => assertInstrumentedSource(
        production,
        production.replace(PHASES[0].marker, `${PHASES[0].marker}\n    abort 9102;`),
        PHASES[1],
    ));
    passed += 1;

    expectFailure('instrumentedOperations', () => assertInstrumentedSource(
        production,
        instrumentedSource(production, PHASES[2]).replace('protocol.assert_current();', 'protocol.assert_current(); // edited'),
        PHASES[2],
    ));
    passed += 1;

    expectFailure('does not exist', () => statePointer(
        { content: { state: {} } },
        { role: 'vault', selectors: ROLE_POINTERS.vault },
        'lifecycle',
        'pointer',
    ));
    passed += 1;

    process.stdout.write(`activation_atomicity self-test: PASS ${passed}/${passed} cases\n`);
}

/// Submits the reviewed activation on testnet with the production package and
/// once per phase with a failpoint package, then validates every result the
/// way the fixture is validated and writes the evidence.
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
    if (config.schemaVersion !== 3 || config.fixtureKind !== 'controlled-submission') {
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
        'packageId', 'builderInput', 'trackedObjects', 'expectedFinal',
    ]);
    if (config.success.packageId !== production.packageId) fail('config.success: activation must use proven production package');
    const success = submit(config.environment, config.success, 'config.success');
    success.originEffects = collectOriginEffects(config.environment, config.success);
    const vaultInitialized = validateSuccess(success, config.success);

    if (!Array.isArray(config.failures) || config.failures.length !== PHASES.length) {
        fail('config.failures: expected A1-A5 exactly once');
    }
    const failures = [];
    const originCache = new Map();
    config.failures.forEach((runConfig, index) => {
        const phase = PHASES[index];
        expectObject(runConfig, `config.failures[${index}]`, [
            'case', 'packageId', 'builderInput', 'trackedObjects', 'instrumentation',
        ]);
        if (runConfig.case !== phase.case) fail(`config.failures[${index}]: expected ${phase.case}`);
        const instrumentation = verifyInstrumentation(
            config.environment,
            runConfig.instrumentation,
            production,
            phase,
        );
        if (runConfig.packageId !== instrumentation.package.packageId) {
            fail(`${phase.case}: activation must use proven instrumented package`);
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
        schemaVersion: 3,
        evidenceKind: 'submitted-controlled-testnet',
        chainIdentifier: chain,
        review,
        production,
        success: { ...success, vaultInitialized },
        failures,
    });
    writeFileSync(outputPath, `${JSON.stringify(output, null, 2)}\n`, { flag: 'wx', mode: 0o600 });
    process.stdout.write(`activation_atomicity: PASS submitted success and A1-A5; evidence ${outputPath}\n`);
}

function parseArgs(args) {
    if (args.length === 1 && args[0] === '--self-test') return { selfTest: true, config: null };
    if (args.length === 2 && args[0] === '--config') return { selfTest: false, config: args[1] };
    if (args.length === 0) return { selfTest: false, config: process.env.BLAST_ATOMICITY_CONFIG ?? null };
    fail('usage: activation_atomicity.mjs [--self-test|--config <path>]');
}

export { PHASES, ROLE_POINTERS, REQUIRED_TRACKED_ROLES, validateFixture, normalizeTransaction };

if (process.argv[1] && import.meta.url === pathToFileURL(resolve(process.argv[1])).href) {
    try {
        const args = parseArgs(process.argv.slice(2));
        if (args.selfTest) selfTest(); else live(args.config);
    } catch (error) {
        process.stderr.write(`activation_atomicity: FAIL ${error.message}\n`);
        process.exitCode = 1;
    }
}
