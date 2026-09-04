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

const SCRIPT_DIR = dirname(fileURLToPath(import.meta.url));
const PACKAGE_DIR = resolve(SCRIPT_DIR, '..');
const FIXTURE_PATH = join(SCRIPT_DIR, 'fixtures', 'activation-atomicity-vectors.json');
const OPERATIONS_PATH = join(PACKAGE_DIR, 'sources', 'operations.move');
const TESTNET_CHAIN = '69WiPg3DAQiwdxfncX6wYQ2siKwAe6L9BZthQea3JNMD';
const PHASES = [
    { case: 'A1', phase: 'vault.initialize_series', marker: '// BLAST_ACTIVATION_BOUNDARY_A1', abortCode: '9101' },
    { case: 'A2', phase: 'vault.mint_locked_shares', marker: '// BLAST_ACTIVATION_BOUNDARY_A2', abortCode: '9102' },
    { case: 'A3', phase: 'venue_account::new', marker: '// BLAST_ACTIVATION_BOUNDARY_A3', abortCode: '9103' },
    { case: 'A4', phase: 'account::consume_policy_and_share_account', marker: '// BLAST_ACTIVATION_BOUNDARY_A4', abortCode: '9104' },
    { case: 'A5', phase: 'vault.install_venue_account', marker: '// BLAST_ACTIVATION_BOUNDARY_A5', abortCode: '9105' },
    { case: 'A6', phase: 'clearing_house::share', marker: '// BLAST_ACTIVATION_BOUNDARY_A6', abortCode: '9106' },
    { case: 'A7', phase: 'events::vault_initialized', marker: '// BLAST_ACTIVATION_BOUNDARY_A7', abortCode: '9107' },
];
const ROLE_SELECTORS = {
    vault: ['lifecycle', 'maintenanceReserve', 'venueAccount', 'checkpoint', 'adminCap'],
    share_currency: ['treasuryCapId'],
    treasury_cap: ['totalSupply'],
    locked_share_coin: ['balance'],
    aftermath_admin_cap: [],
    aftermath_account: ['accountId', 'collateral'],
    clearing_house: ['marketState'],
};
const REQUIRED_TRACKED_ROLES = Object.keys(ROLE_SELECTORS);
const INITIALIZED_FIELDS = [
    'vault_id', 'account_object_id', 'account_number', 'registry_id',
    'clearing_house_id', 'base_oracle_id', 'collateral_oracle_id',
    'collateral_type', 'seed_amount', 'seed_venue_equity', 'seed_reserve',
    'seed_shareholder_nav', 'locked_shares', 'absolute_base',
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
        for (const key of ROLE_SELECTORS[role]) {
            const pointer = expectString(tracked.selectors[key], `${itemPath}.selectors.${key}`);
            if (!pointer.startsWith('/')) fail(`${itemPath}.selectors.${key}: expected JSON pointer`);
        }
        validateBinding(tracked.binding, `${itemPath}.binding`);
    });
}

function snapshotObject(environment, tracked, path) {
    const result = runSui([
        'client', '--client.env', environment, 'object', tracked.id, '--json',
    ], true);
    const output = `${result.stdout}${result.stderr}`;
    if (result.status !== 0) {
        if (tracked.allowAbsent && /not found|requested entity was not found|ObjectNotExists/i.test(output)) {
            return { role: tracked.role, exists: false, id: tracked.id };
        }
        fail(`${path}: object read failed: ${output.trim()}`);
    }
    const object = expectObject(parseJson(result.stdout, path), path);
    const id = expectAddress(object.objectId, `${path}.objectId`);
    if (id !== tracked.id) fail(`${path}: returned the wrong object`);
    if (object.objType !== tracked.expectedType) {
        fail(`${path}: expected type ${tracked.expectedType}, got ${object.objType}`);
    }
    const selected = {};
    for (const [name, pointer] of Object.entries(tracked.selectors)) {
        selected[name] = jsonPointer(object, pointer, `${path}.${name}`);
    }
    return canonical({
        role: tracked.role,
        exists: true,
        id,
        version: String(object.version),
        digest: expectString(object.digest, `${path}.digest`),
        owner: object.owner,
        type: object.objType,
        content: object.content,
        selected,
    });
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
    if (initializer.arguments.length !== 14) fail(`${path}.arguments: expected 14 explicit arguments`);
    expectStringList(ptbArgs, `${path}.ptbArgs`);
    for (const forbidden of [
        '--dev-inspect', '--dry-run', '--preview',
        '--serialize-unsigned-transaction', '--serialize-signed-transaction',
    ]) {
        if (ptbArgs.includes(forbidden)) fail(`${path}.ptbArgs: submitted proof forbids ${forbidden}`);
    }
    const targetIndices = ptbArgs.flatMap((token, index) => token === expectedTarget ? [index] : []);
    if (targetIndices.length !== 1) fail(`${path}.ptbArgs: expected exactly one ${expectedTarget}`);
    const targetIndex = targetIndices[0];
    if (ptbArgs[targetIndex - 1] !== '--move-call') fail(`${path}.ptbArgs: initializer is not a move call`);
    const expected = [
        `<${initializer.typeArguments.join(',')}>`,
        ...initializer.arguments,
    ];
    assertEqual(
        ptbArgs.slice(targetIndex + 1, targetIndex + 1 + expected.length),
        expected,
        `${path}.ptbArgs.initializer`,
    );
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
    for (const name of EFFECT_LISTS) {
        const snake = name.replace(/[A-Z]/g, (letter) => `_${letter.toLowerCase()}`);
        const entries = effects[name] ?? effects[snake] ?? [];
        if (!Array.isArray(entries)) fail(`transaction.effects.${name}: expected list`);
        entries.forEach((entry, index) => changed.add(objectIdFromChange(entry, `transaction.effects.${name}[${index}]`)));
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
    return { status, error, gasId, changedObjects, events: canonical(events) };
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
    validateInitializer(runConfig.initializer, runConfig.packageId, runConfig.ptbArgs, `${path}.initializer`);
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

function bindTrackedObjects(environment, runConfig, evidence, path, originCache = new Map()) {
    const effects = changedIds(evidence);
    for (const tracked of runConfig.trackedObjects) {
        const id = tracked.id;
        const binding = tracked.binding;
        if (binding.kind === 'argument') {
            if (!runConfig.ptbArgs.includes(`@${id}`)) fail(`${path}.${tracked.role}: id is not a PTB argument`);
        } else if (binding.kind === 'effect') {
            if (!effects.has(id)) fail(`${path}.${tracked.role}: id is not in transaction effects`);
        } else if (binding.kind === 'derived') {
            const derived = deriveObjectId(evidence.transactionDigest, binding.creationIndex);
            if (derived !== id) fail(`${path}.${tracked.role}: creation index derives ${derived}, not ${id}`);
        } else if (binding.kind === 'originEffect') {
            const ids = transactionEffectIds(environment, binding.transactionDigest, originCache);
            if (!ids.has(id)) fail(`${path}.${tracked.role}: id is not in origin transaction effects`);
        }
    }
}

function initializedEvent(evidence, runConfig) {
    const expectedType = `${runConfig.packageId}::events::VaultInitialized<${runConfig.initializer.typeArguments[0]}>`;
    const matches = evidence.events.filter((event) => event?.type === expectedType);
    if (matches.length !== 1) fail(`success.events: expected exactly one ${expectedType}, got ${matches.length}`);
    const event = expectObject(matches[0], 'success.VaultInitialized');
    const parsedJson = expectObject(
        event.parsedJson ?? event.parsed_json,
        'success.VaultInitialized.parsedJson',
        INITIALIZED_FIELDS,
    );
    expectObject(parsedJson.checkpoint, 'success.VaultInitialized.checkpoint', CHECKPOINT_FIELDS);
    return canonical({ type: event.type, parsedJson });
}

function validateSuccess(evidence, runConfig) {
    if (evidence.status !== 'success') fail(`success: transaction failed: ${evidence.error}`);
    validateExpectedFinal(runConfig.expectedFinal, evidence.postState);
    const event = initializedEvent(evidence, runConfig);
    const fields = event.parsedJson;
    const vault = stateObject(evidence.postState, 'vault', 'success.postState');
    const currency = stateObject(evidence.postState, 'share_currency', 'success.postState');
    const cap = stateObject(evidence.postState, 'treasury_cap', 'success.postState');
    const locked = stateObject(evidence.postState, 'locked_share_coin', 'success.postState');
    const admin = stateObject(evidence.postState, 'aftermath_admin_cap', 'success.postState');
    const account = stateObject(evidence.postState, 'aftermath_account', 'success.postState');
    const clearingHouse = stateObject(evidence.postState, 'clearing_house', 'success.postState');
    if (!vault.exists || !currency.exists || !cap.exists || !locked.exists
        || admin.exists || !account.exists || !clearingHouse.exists) {
        fail('success.postState: final custody/object existence mismatch');
    }
    const relations = [
        [fields.vault_id, vault.id, 'vault_id'],
        [fields.account_object_id, account.id, 'account_object_id'],
        [fields.clearing_house_id, clearingHouse.id, 'clearing_house_id'],
        [String(fields.account_number), String(account.selected.accountId), 'account_number'],
        [String(fields.seed_reserve), String(vault.selected.maintenanceReserve), 'seed_reserve'],
        [fields.checkpoint, vault.selected.checkpoint, 'checkpoint'],
        [String(fields.locked_shares), String(cap.selected.totalSupply), 'treasury supply'],
        [String(fields.locked_shares), String(locked.selected.balance), 'locked balance'],
        [currency.selected.treasuryCapId, cap.id, 'currency treasury cap'],
        [vault.selected.venueAccount, account.id, 'venue account'],
        [vault.selected.adminCap, admin.id, 'admin cap custody'],
    ];
    for (const [actual, expected, label] of relations) assertEqual(actual, expected, `success.${label}`);
    return event;
}

function resolveState(value, baseline, path) {
    if (value === 'baseline') return baseline;
    if (value === null || typeof value !== 'object' || Array.isArray(value)) fail(`${path}: expected state or baseline`);
    return value;
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
        installRoot, 'build', 'blast_leverage_aftermath', 'bytecode_modules',
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
    if (fixture.schemaVersion !== 2 || fixture.fixtureKind !== 'canonical-evidence-validator') {
        fail('fixture: unsupported schema or kind');
    }
    if (fixture.gasDifferencePolicy !== 'gas-only') fail('fixture: rollback may allow gas changes only');
    const observedSha = sha256(readFileSync(OPERATIONS_PATH));
    if (observedSha !== fixture.productionOperationsSha256) fail('fixture: production operations hash drift');
    expectObject(fixture.success, 'fixture.success', [
        'packageId', 'initializer', 'ptbArgs', 'trackedObjects', 'expectedFinal',
        'transactionDigest', 'status', 'error', 'gasId', 'changedObjects',
        'events', 'preState', 'postState',
    ]);
    validateTrackedObjects(fixture.success.trackedObjects, 'fixture.success.trackedObjects');
    validateInitializer(
        fixture.success.initializer,
        fixture.success.packageId,
        fixture.success.ptbArgs,
        'fixture.success.initializer',
    );
    validateSuccess(fixture.success, fixture.success);
    if (!Array.isArray(fixture.failures) || fixture.failures.length !== PHASES.length) {
        fail('fixture.failures: expected A1-A7 exactly once');
    }
    fixture.failures.forEach((entry, index) => {
        expectObject(entry, `fixture.failures[${index}]`, [
            'case', 'packageId', 'status', 'error', 'transactionDigest', 'preState',
            'postState', 'changedObjects', 'events',
        ]);
        const phase = PHASES[index];
        if (entry.case !== phase.case) fail(`fixture.failures[${index}]: expected ${phase.case}`);
        assertExactAbort(entry.error, expectAddress(entry.packageId, `fixture.failures[${index}].packageId`), phase);
        assertRollback(entry, fixture.baseline);
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
    let passed = 3;

    const duplicateEvent = structuredClone(fixture.success);
    duplicateEvent.events.push(structuredClone(duplicateEvent.events[0]));
    expectFailure('exactly one', () => validateSuccess(duplicateEvent, duplicateEvent));
    passed += 1;

    const wrongFinal = structuredClone(fixture.success);
    wrongFinal.postState.objects.find((item) => item.role === 'treasury_cap').selected.totalSupply = '1';
    expectFailure('expectedFinal.treasury_cap', () => validateSuccess(wrongFinal, wrongFinal));
    passed += 1;

    const wrongCheckpoint = structuredClone(fixture.success);
    wrongCheckpoint.events[0].parsedJson.checkpoint.free_collateral = '999';
    expectFailure('success.checkpoint', () => validateSuccess(wrongCheckpoint, wrongCheckpoint));
    passed += 1;

    const survivingState = structuredClone(fixture.failures[0]);
    survivingState.postState = structuredClone(fixture.baseline);
    survivingState.postState.objects[0].digest = 'changed';
    expectFailure('.state', () => assertRollback(survivingState, fixture.baseline));
    passed += 1;

    const event = structuredClone(fixture.failures[1]);
    event.events.push({ type: 'VaultInitialized' });
    expectFailure('emitted an event', () => assertRollback(event, fixture.baseline));
    passed += 1;

    const nonGas = structuredClone(fixture.failures[2]);
    nonGas.changedObjects.push({ kind: 'protocol', id: fixture.baseline.objects[0].id });
    expectFailure('non-gas object', () => assertRollback(nonGas, fixture.baseline));
    passed += 1;

    const relabeled = structuredClone(fixture.failures[3]);
    relabeled.case = 'A5';
    expectFailure('expected A4', () => {
        const index = 3;
        if (relabeled.case !== PHASES[index].case) fail(`fixture.failures[${index}]: expected ${PHASES[index].case}`);
    });
    passed += 1;

    const wrongAbort = structuredClone(fixture.failures[4]);
    wrongAbort.error = wrongAbort.error.replace('9105', '9106');
    expectFailure('exact abort code 9105', () => assertExactAbort(
        wrongAbort.error,
        wrongAbort.packageId,
        PHASES[4],
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

    process.stdout.write(`activation_atomicity self-test: PASS ${passed}/13 cases\n`);
}

function live(configPath) {
    if (!configPath) {
        fail('controlled rollback proof requires --config <controlled-submission.json> or BLAST_ATOMICITY_CONFIG; no funded fixture or failpoint deployment is recorded');
    }
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
    bindTrackedObjects(config.environment, config.success, success, 'success');
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
        bindTrackedObjects(config.environment, runConfig, evidence, phase.case, originCache);
        assertExactAbort(evidence.error, runConfig.packageId, phase);
        assertRollback({ case: phase.case, ...evidence }, evidence.preState);
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
