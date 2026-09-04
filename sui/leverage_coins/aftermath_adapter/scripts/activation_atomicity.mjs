#!/usr/bin/env node
// Submits controlled activation transactions and proves failed executions keep
// all tracked protocol state unchanged. Read-only inspection is never accepted
// as rollback evidence.

import { createHash } from 'node:crypto';
import { readFileSync, readdirSync, statSync, writeFileSync } from 'node:fs';
import { dirname, join, resolve } from 'node:path';
import { fileURLToPath } from 'node:url';
import { spawnSync } from 'node:child_process';
import process from 'node:process';

const SCRIPT_DIR = dirname(fileURLToPath(import.meta.url));
const PACKAGE_DIR = join(SCRIPT_DIR, '..');
const FIXTURE_PATH = join(SCRIPT_DIR, 'fixtures', 'activation-atomicity-vectors.json');
const OPERATIONS_PATH = join(PACKAGE_DIR, 'sources', 'operations.move');
const TESTNET_CHAIN = '69WiPg3DAQiwdxfncX6wYQ2siKwAe6L9BZthQea3JNMD';
const PHASES = [
    ['A1', 'vault.initialize_series'],
    ['A2', 'vault.mint_locked_shares'],
    ['A3', 'venue_account::new'],
    ['A4', 'account::consume_policy_and_share_account'],
    ['A5', 'vault.install_venue_account'],
    ['A6', 'clearing_house::share'],
    ['A7', 'events::vault_initialized'],
];
const REQUIRED_TRACKED_ROLES = [
    'vault',
    'share_currency',
    'treasury_cap',
    'locked_share_coin',
    'aftermath_admin_cap',
    'aftermath_account',
    'clearing_house',
];

function fail(message) {
    throw new Error(message);
}

function readJson(path) {
    try { return JSON.parse(readFileSync(path, 'utf8')); }
    catch (error) { fail(`${path}: ${error.message}`); }
}

function expectObject(value, path, keys) {
    if (value === null || typeof value !== 'object' || Array.isArray(value)) fail(`${path}: expected object`);
    const actual = Object.keys(value).sort();
    const expected = [...keys].sort();
    if (JSON.stringify(actual) !== JSON.stringify(expected)) {
        fail(`${path}: field set mismatch; expected ${expected.join(', ')}, got ${actual.join(', ')}`);
    }
    return value;
}

function expectString(value, path) {
    if (typeof value !== 'string' || value.length === 0) fail(`${path}: expected non-empty string`);
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

function sha256(source) {
    return createHash('sha256').update(source).digest('hex');
}

function moveSources(root, prefix = '') {
    const entries = [];
    for (const name of readdirSync(root).sort()) {
        const path = join(root, name);
        const relative = prefix === '' ? name : `${prefix}/${name}`;
        if (statSync(path).isDirectory()) entries.push(...moveSources(path, relative));
        else if (name.endsWith('.move')) entries.push([relative, readFileSync(path, 'utf8')]);
    }
    return entries;
}

function resolveState(value, baseline, path) {
    if (value === 'baseline') return baseline;
    if (value === null || typeof value !== 'object' || Array.isArray(value)) fail(`${path}: expected full state or baseline reference`);
    return value;
}

function assertRollback(entry, baseline) {
    if (entry.status !== 'failure') fail(`${entry.case}: transaction did not fail`);
    assertEqual(resolveState(entry.postState, baseline, `${entry.case}.postState`), resolveState(entry.preState, baseline, `${entry.case}.preState`), `${entry.case}.state`);
    if (!Array.isArray(entry.events) || entry.events.length !== 0) fail(`${entry.case}: failed transaction emitted an event`);
    if (!Array.isArray(entry.changedObjects)) fail(`${entry.case}: changedObjects must be a list`);
    for (const change of entry.changedObjects) {
        expectObject(change, `${entry.case}.changedObjects`, ['kind', 'id']);
        if (change.kind !== 'gas') fail(`${entry.case}: non-gas object ${change.id} changed`);
    }
}

function validatePhaseCases(cases) {
    if (!Array.isArray(cases) || cases.length !== PHASES.length) fail('phaseCases: expected A1-A7 exactly once');
    cases.forEach((entry, index) => {
        expectObject(entry, `phaseCases[${index}]`, ['case', 'lastPhase', 'abortImmediatelyAfter']);
        const [expectedCase, expectedPhase] = PHASES[index];
        if (entry.case !== expectedCase || entry.lastPhase !== expectedPhase || entry.abortImmediatelyAfter !== true) {
            fail(`phaseCases[${index}]: expected ${expectedCase} immediately after ${expectedPhase}`);
        }
    });
}

function validateFixture(fixture) {
    expectObject(fixture, 'fixture', [
        'schemaVersion', 'fixtureKind', 'gasDifferencePolicy',
        'productionOperationsSha256', 'baseline', 'success', 'phaseCases', 'failures',
    ]);
    if (fixture.schemaVersion !== 1 || fixture.fixtureKind !== 'offline-comparator-test') fail('fixture: unsupported schema or kind');
    if (fixture.gasDifferencePolicy !== 'gas-only') fail('fixture: rollback may allow gas changes only');
    const observedSha = sha256(readFileSync(OPERATIONS_PATH));
    if (observedSha !== fixture.productionOperationsSha256) fail(`fixture: production operations hash drift; expected ${fixture.productionOperationsSha256}, got ${observedSha}`);
    validatePhaseCases(fixture.phaseCases);
    if (fixture.success.status !== 'success' || fixture.success.vaultInitializedEvents !== 1) fail('success: expected one successful activation event');
    if (!Array.isArray(fixture.failures) || fixture.failures.length !== PHASES.length) fail('failures: expected A1-A7 exactly once');
    fixture.failures.forEach((entry, index) => {
        expectObject(entry, `failures[${index}]`, ['case', 'status', 'transactionDigest', 'preState', 'postState', 'changedObjects', 'events']);
        if (entry.case !== PHASES[index][0]) fail(`failures[${index}]: expected ${PHASES[index][0]}`);
        assertRollback(entry, fixture.baseline);
    });
}

function assertInstrumentedSource(production, instrumented, marker, abortLine) {
    const productionLines = production.split('\n');
    const instrumentedLines = instrumented.split('\n');
    const markerIndices = productionLines.flatMap((line, index) => line.includes(marker) ? [index] : []);
    if (markerIndices.length !== 1) fail(`instrumentation marker must occur once, got ${markerIndices.length}`);
    if (instrumentedLines.length !== productionLines.length + 1) fail('instrumented source must add exactly one line');
    const insertion = markerIndices[0] + 1;
    if (instrumentedLines[insertion].trim() !== abortLine) fail('instrumented source must abort immediately after the named boundary');
    const restored = [...instrumentedLines];
    restored.splice(insertion, 1);
    assertEqual(restored, productionLines, 'instrumentedSource');
}

function expectFailure(message, run) {
    try { run(); }
    catch (error) {
        if (String(error.message).includes(message)) return;
        fail(`expected failure containing ${JSON.stringify(message)}, got ${JSON.stringify(error.message)}`);
    }
    fail(`expected failure containing ${JSON.stringify(message)}`);
}

function selfTest() {
    const fixture = readJson(FIXTURE_PATH);
    validateFixture(fixture);
    let passed = 2;

    const survivingState = structuredClone(fixture.failures[0]);
    survivingState.postState = structuredClone(fixture.baseline);
    survivingState.postState.supply.totalShares = '1';
    expectFailure('.state', () => assertRollback(survivingState, fixture.baseline));
    passed += 1;

    const movedCap = structuredClone(fixture.failures[1]);
    movedCap.postState = structuredClone(fixture.baseline);
    movedCap.postState.custody.adminCap = 'vault';
    expectFailure('.state', () => assertRollback(movedCap, fixture.baseline));
    passed += 1;

    const createdObject = structuredClone(fixture.failures[2]);
    createdObject.postState = structuredClone(fixture.baseline);
    createdObject.postState.objects.find((item) => item.role === 'aftermath_account').exists = true;
    expectFailure('.state', () => assertRollback(createdObject, fixture.baseline));
    passed += 1;

    const event = structuredClone(fixture.failures[3]);
    event.events.push({ type: 'VaultInitialized' });
    expectFailure('emitted an event', () => assertRollback(event, fixture.baseline));
    passed += 1;

    const nonGas = structuredClone(fixture.failures[4]);
    nonGas.changedObjects.push({ kind: 'protocol', id: fixture.baseline.objects[0].id });
    expectFailure('non-gas object', () => assertRollback(nonGas, fixture.baseline));
    passed += 1;

    const wrongStatus = structuredClone(fixture.failures[5]);
    wrongStatus.status = 'success';
    expectFailure('transaction did not fail', () => assertRollback(wrongStatus, fixture.baseline));
    passed += 1;

    const production = 'before\n    vault.initialize_series(\nafter';
    const instrumented = 'before\n    vault.initialize_series(\n    abort 9001;\nafter';
    assertInstrumentedSource(production, instrumented, 'vault.initialize_series(', 'abort 9001;');
    passed += 1;
    expectFailure('add exactly one line', () => assertInstrumentedSource(production, `${instrumented}\nextra`, 'vault.initialize_series(', 'abort 9001;'));
    passed += 1;

    process.stdout.write(`activation_atomicity self-test: PASS ${passed}/10 cases\n`);
}

function runSui(args, allowFailure = false) {
    const result = spawnSync('sui', args, {
        cwd: PACKAGE_DIR,
        encoding: 'utf8',
        stdio: ['ignore', 'pipe', 'pipe'],
    });
    if (result.error) fail(`sui invocation failed: ${result.error.message}`);
    const output = `${result.stdout ?? ''}${result.stderr ?? ''}`;
    if (!allowFailure && result.status !== 0) fail(`sui ${args.slice(0, 4).join(' ')} failed: ${output.trim()}`);
    return { status: result.status, output };
}

function parseChainIdentifier(output) {
    const match = /^Base58:\s+(\S+)$/m.exec(output);
    if (!match) fail('sui chain-identifier: missing Base58 chain identity');
    return match[1];
}

function parseJson(output, path) {
    try { return JSON.parse(output); }
    catch { fail(`${path}: expected canonical JSON from Sui CLI`); }
}

function snapshotObject(environment, tracked) {
    expectObject(tracked, 'trackedObject', ['role', 'id', 'allowAbsent']);
    const result = runSui(['client', '--client.env', environment, 'object', tracked.id, '--json'], true);
    if (result.status !== 0) {
        if (tracked.allowAbsent && /not found|Some requested entity was not found/i.test(result.output)) {
            return { role: tracked.role, exists: false, id: tracked.id };
        }
        fail(`${tracked.role}: object read failed: ${result.output.trim()}`);
    }
    const object = parseJson(result.output, tracked.role);
    const required = ['objectId', 'version', 'digest', 'objType', 'owner', 'prevTx', 'storageRebate', 'content'];
    expectObject(object, tracked.role, required);
    return canonical({
        role: tracked.role,
        exists: true,
        id: object.objectId,
        version: String(object.version),
        digest: object.digest,
        owner: object.owner,
        type: object.objType,
        content: object.content,
    });
}

function snapshotState(environment, trackedObjects) {
    if (!Array.isArray(trackedObjects) || trackedObjects.length === 0) fail('trackedObjects: expected non-empty list');
    const roles = trackedObjects.map((item) => item.role);
    if (new Set(roles).size !== roles.length) fail('trackedObjects: duplicate role');
    assertEqual([...roles].sort(), [...REQUIRED_TRACKED_ROLES].sort(), 'trackedObjects.roles');
    return { objects: trackedObjects.map((item) => snapshotObject(environment, item)) };
}

function parseTransactionDigest(output) {
    try {
        const json = JSON.parse(output);
        if (typeof json.digest === 'string') return json.digest;
        if (typeof json.effects?.transactionDigest === 'string') return json.effects.transactionDigest;
    } catch {}
    const patterns = [
        /transaction[_ ]digest[":(\s]+([1-9A-HJ-NP-Za-km-z]{32,})/i,
        /digest[":\s]+([1-9A-HJ-NP-Za-km-z]{32,})/i,
    ];
    for (const pattern of patterns) {
        const match = pattern.exec(output);
        if (match) return match[1];
    }
    fail('submitted transaction output did not expose a digest');
}

function normalizeTransaction(transaction) {
    const effects = transaction.effects ?? {};
    const status = effects.status?.status ?? effects.status;
    const error = effects.status?.error ?? effects.error ?? null;
    const gasId = effects.gasObject?.reference?.objectId ?? effects.gasObject?.objectId ?? null;
    const changes = transaction.objectChanges ?? effects.changedObjects ?? effects.changed_objects ?? [];
    if (!Array.isArray(changes)) fail('transaction effects: object changes are not a list');
    const changedObjects = changes.map((change) => {
        const id = change.objectId ?? change.object_id ?? change.reference?.objectId;
        if (typeof id !== 'string') fail('transaction effects: changed object lacks id');
        return { kind: id === gasId ? 'gas' : 'protocol', id };
    });
    const events = transaction.events ?? [];
    if (!Array.isArray(events)) fail('transaction effects: events are not a list');
    return { status, error, gasId, changedObjects, events: canonical(events) };
}

function validatePtbArgs(args, packageId) {
    if (!Array.isArray(args) || args.some((arg) => typeof arg !== 'string')) fail('ptbArgs: expected string list');
    for (const forbidden of ['--dev-inspect', '--dry-run', '--preview', '--serialize-unsigned-transaction', '--serialize-signed-transaction']) {
        if (args.includes(forbidden)) fail(`ptbArgs: submitted proof forbids ${forbidden}`);
    }
    const target = `${packageId}::operations::initialize`;
    if (!args.includes(target)) fail(`ptbArgs: missing exact production initializer ${target}`);
}

function verifyInstrumentation(environment, instrumentation) {
    expectObject(instrumentation, 'instrumentation', [
        'productionPackageId', 'productionPackageObjectDigest',
        'instrumentedPackageId', 'instrumentedPackageObjectDigest',
        'productionSources', 'instrumentedSources', 'operationsRelativePath',
        'marker', 'abortLine',
    ]);
    const productionRoot = resolve(instrumentation.productionSources);
    const instrumentedRoot = resolve(instrumentation.instrumentedSources);
    const productionEntries = moveSources(productionRoot);
    const instrumentedEntries = moveSources(instrumentedRoot);
    assertEqual(productionEntries.map(([path]) => path), instrumentedEntries.map(([path]) => path), 'instrumentation.sourceFiles');
    const operationsIndex = productionEntries.findIndex(([path]) => path === instrumentation.operationsRelativePath);
    if (operationsIndex < 0) fail(`instrumentation: missing ${instrumentation.operationsRelativePath}`);
    productionEntries.forEach(([path, source], index) => {
        if (index !== operationsIndex) assertEqual(instrumentedEntries[index][1], source, `instrumentation.${path}`);
    });
    const production = productionEntries[operationsIndex][1];
    const instrumented = instrumentedEntries[operationsIndex][1];
    assertInstrumentedSource(production, instrumented, instrumentation.marker, instrumentation.abortLine);
    if (instrumentation.productionPackageObjectDigest === instrumentation.instrumentedPackageObjectDigest) fail('instrumentation: production and failpoint package digests must differ');
    for (const [role, id, expectedDigest] of [
        ['productionPackage', instrumentation.productionPackageId, instrumentation.productionPackageObjectDigest],
        ['instrumentedPackage', instrumentation.instrumentedPackageId, instrumentation.instrumentedPackageObjectDigest],
    ]) {
        const object = parseJson(runSui(['client', '--client.env', environment, 'object', id, '--json']).output, role);
        if (object.objType !== 'package' || object.digest !== expectedDigest) fail(`${role}: package type or digest mismatch`);
    }
    return {
        productionPackageId: instrumentation.productionPackageId,
        productionPackageObjectDigest: instrumentation.productionPackageObjectDigest,
        productionSourcesSha256: sha256(productionEntries.map(([path, source]) => `${path}\0${source}`).join('\0')),
        instrumentedPackageId: instrumentation.instrumentedPackageId,
        instrumentedPackageObjectDigest: instrumentation.instrumentedPackageObjectDigest,
        instrumentedSourcesSha256: sha256(instrumentedEntries.map(([path, source]) => `${path}\0${source}`).join('\0')),
        operationsRelativePath: instrumentation.operationsRelativePath,
        marker: instrumentation.marker,
        abortLine: instrumentation.abortLine,
    };
}

function submit(environment, run) {
    const preState = snapshotState(environment, run.trackedObjects);
    const args = ['client', '--client.env', environment, 'ptb', ...run.ptbArgs];
    if (!args.includes('--json')) args.push('--json');
    const submitted = runSui(args, true);
    const digest = parseTransactionDigest(submitted.output);
    const transaction = parseJson(runSui(['client', '--client.env', environment, 'tx-block', digest, '--json']).output, digest);
    const effects = normalizeTransaction(transaction);
    const postState = snapshotState(environment, run.trackedObjects);
    return { transactionDigest: digest, preState, postState, ...effects };
}

function live(configPath) {
    if (!configPath) {
        fail('controlled rollback proof requires --config <controlled-submission.json> or BLAST_ATOMICITY_CONFIG; no funded fixture or failpoint deployment is recorded');
    }
    const config = readJson(resolve(configPath));
    expectObject(config, 'config', [
        'schemaVersion', 'fixtureKind', 'environment', 'chainIdentifier',
        'outputPath', 'success', 'failures',
    ]);
    if (config.schemaVersion !== 1 || config.fixtureKind !== 'controlled-submission') fail('config: unsupported schema or kind');
    if (config.environment !== 'testnet') fail('config: only controlled testnet submission is accepted');
    if (config.chainIdentifier !== TESTNET_CHAIN) fail('config: testnet chain identifier drift');
    const chain = parseChainIdentifier(runSui(['client', '--client.env', config.environment, 'chain-identifier']).output);
    if (chain !== config.chainIdentifier) fail(`testnet chain mismatch: expected ${config.chainIdentifier}, got ${chain}`);
    if (!Array.isArray(config.failures) || config.failures.length !== PHASES.length) fail('config.failures: expected A1-A7');

    expectObject(config.success, 'config.success', ['packageId', 'ptbArgs', 'trackedObjects']);
    validatePtbArgs(config.success.ptbArgs, config.success.packageId);
    const success = submit(config.environment, config.success);
    if (success.status !== 'success') fail(`success activation failed: ${success.error}`);
    if (!success.events.some((event) => String(event.type ?? '').includes('::events::VaultInitialized<'))) {
        fail('success activation did not emit VaultInitialized');
    }

    const failures = [];
    config.failures.forEach((run, index) => {
        expectObject(run, `config.failures[${index}]`, [
            'case', 'lastPhase', 'abortCode', 'ptbArgs', 'trackedObjects', 'instrumentation',
        ]);
        const [caseName, phase] = PHASES[index];
        if (run.case !== caseName || run.lastPhase !== phase) fail(`config.failures[${index}]: expected ${caseName} after ${phase}`);
        validatePtbArgs(run.ptbArgs, run.instrumentation.instrumentedPackageId);
        const instrumentation = verifyInstrumentation(config.environment, run.instrumentation);
        const evidence = submit(config.environment, run);
        if (evidence.error === null || !String(evidence.error).includes(run.abortCode)) fail(`${caseName}: expected abort ${run.abortCode}`);
        assertRollback({ case: caseName, ...evidence }, evidence.preState);
        failures.push({ case: caseName, lastPhase: phase, instrumentation, ...evidence });
    });

    const outputPath = resolve(config.outputPath);
    if (outputPath === resolve(FIXTURE_PATH)) fail('live evidence must not overwrite the offline fixture');
    const output = canonical({
        schemaVersion: 1,
        evidenceKind: 'submitted-controlled-testnet',
        chainIdentifier: chain,
        success,
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
