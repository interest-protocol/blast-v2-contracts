#!/usr/bin/env node
// Executes the controlled P16-P19 transition matrix against committed state.
// Every case submits production calls, reads the resulting Vault through the
// standard object API, and classifies canonical raw checkpoints and events.

import { readFileSync, writeFileSync } from 'node:fs';
import { dirname, join, resolve } from 'node:path';
import { fileURLToPath } from 'node:url';
import { spawnSync } from 'node:child_process';
import process from 'node:process';

const SCRIPT_DIR = dirname(fileURLToPath(import.meta.url));
const PACKAGE_DIR = join(SCRIPT_DIR, '..');
const FIXTURE_PATH = join(
    SCRIPT_DIR,
    'fixtures',
    'controlled-health-vectors.json',
);
const TESTNET_CHAIN = '69WiPg3DAQiwdxfncX6wYQ2siKwAe6L9BZthQea3JNMD';
const CASE_NAMES = [
    'long',
    'short',
    'flat',
    'positive_pnl',
    'negative_pnl',
    'funding_credit',
    'funding_cost',
    'repeated_funding',
    'partial_liquidation',
    'adl_settlement',
    'collateral_movement',
    'pending_order',
    'pause',
    'freeze',
    'stale_oracle',
    'collateral_depeg',
];
const CHECKPOINT_FIELDS = [
    'free_collateral',
    'allocated_collateral',
    'signed_base',
    'signed_quote_notional',
    'funding_snapshot_long',
    'funding_snapshot_short',
    'market_funding_long',
    'market_funding_short',
    'lot_size',
    'pending_ask_base',
    'pending_bid_base',
    'pending_order_count',
    'market_pause_mode',
    'market_frozen',
    'position_initial_margin_ratio',
    'market_initial_margin_ratio',
    'market_maintenance_margin_ratio',
];
const SELECTOR_KEYS = ['lifecycle', 'maintenanceReserve', 'checkpoint'];

function fail(message) {
    throw new Error(message);
}

function readJson(path) {
    try {
        return JSON.parse(readFileSync(path, 'utf8'));
    } catch (error) {
        fail(`${path}: ${error.message}`);
    }
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
    if (typeof value !== 'string' || value.length === 0) {
        fail(`${path}: expected non-empty string`);
    }
    return value;
}

function expectAddress(value, path) {
    const address = expectString(value, path);
    if (!/^0x[0-9a-fA-F]{64}$/.test(address)) {
        fail(`${path}: expected canonical 32-byte address`);
    }
    return address.toLowerCase();
}

function canonical(value) {
    if (Array.isArray(value)) return value.map(canonical);
    if (value !== null && typeof value === 'object') {
        return Object.fromEntries(
            Object.keys(value).sort().map((key) => [key, canonical(value[key])]),
        );
    }
    return value;
}

function assertEqual(actual, expected, path = 'value') {
    const left = JSON.stringify(canonical(actual));
    const right = JSON.stringify(canonical(expected));
    if (left !== right) fail(`${path}: expected ${right}, got ${left}`);
}

function checkpoint(value, path) {
    return canonical(expectObject(value, path, CHECKPOINT_FIELDS));
}

function protocolEvent(event, path, eventTypes = null) {
    const value = expectObject(event, path, ['type', 'parsedJson']);
    expectString(value.type, `${path}.type`);
    const parsed = expectObject(value.parsedJson, `${path}.parsedJson`);
    if (eventTypes !== null && value.type === eventTypes.funding) {
        expectObject(parsed, `${path}.parsedJson`, [
            'vault_id',
            'is_cost',
            'raw_amount',
            'amount',
            'absorbed_by_reserve',
            'uncovered_cost',
            'reserve_after',
            'previous_checkpoint',
            'checkpoint',
        ]);
        checkpoint(parsed.previous_checkpoint, `${path}.previous_checkpoint`);
        checkpoint(parsed.checkpoint, `${path}.checkpoint`);
    }
    if (eventTypes !== null && value.type === eventTypes.health) {
        expectObject(parsed, `${path}.parsedJson`, [
            'vault_id',
            'reason',
            'lifecycle_changed',
            'checkpoint',
        ]);
        checkpoint(parsed.checkpoint, `${path}.checkpoint`);
    }
    return canonical(value);
}

function classify(preCheckpoint, postCheckpoint, events, eventTypes) {
    const funding = events.filter((event) => event.type === eventTypes.funding);
    if (funding.length > 1) fail('case: more than one FundingSettled event');
    if (funding.length === 1) {
        const isCost = funding[0].parsedJson.is_cost;
        if (typeof isCost !== 'boolean') {
            fail('case: FundingSettled.is_cost must be boolean');
        }
        return isCost ? 'funding_cost' : 'funding_credit';
    }
    return JSON.stringify(canonical(preCheckpoint))
        === JSON.stringify(canonical(postCheckpoint))
        ? 'unchanged'
        : 'unexpected';
}

function validateEvidence(evidence, expected, eventTypes, path) {
    expectObject(evidence, path, ['pre', 'post', 'events']);
    expectObject(evidence.pre, `${path}.pre`, SELECTOR_KEYS);
    expectObject(evidence.post, `${path}.post`, SELECTOR_KEYS);
    const preCheckpoint = checkpoint(
        evidence.pre.checkpoint,
        `${path}.pre.checkpoint`,
    );
    const postCheckpoint = checkpoint(
        evidence.post.checkpoint,
        `${path}.post.checkpoint`,
    );
    if (!Array.isArray(evidence.events)) fail(`${path}.events: expected list`);
    const events = evidence.events.map((event, index) =>
        protocolEvent(event, `${path}.events[${index}]`, eventTypes));
    const health = events.filter((event) => event.type === eventTypes.health);
    if (health.length > 1) fail(`${path}: more than one HealthSynchronized event`);
    expectObject(expected, `${path}.expected`, [
        'classification',
        'lifecycle',
        'events',
    ]);
    const observed = {
        classification: classify(
            preCheckpoint,
            postCheckpoint,
            events,
            eventTypes,
        ),
        lifecycle: evidence.post.lifecycle,
        events,
    };
    assertEqual(observed, expected, `${path}.outcome`);
    return observed;
}

function validateCaseNames(cases, path) {
    if (!Array.isArray(cases) || cases.length !== CASE_NAMES.length) {
        fail(`${path}: expected the complete ${CASE_NAMES.length}-case matrix`);
    }
    cases.forEach((entry, index) => {
        if (entry.name !== CASE_NAMES[index]) {
            fail(`${path}[${index}]: expected ${CASE_NAMES[index]}`);
        }
    });
}

function validateFixture(fixture) {
    expectObject(fixture, 'fixture', [
        'schemaVersion',
        'fixtureKind',
        'eventTypes',
        'checkpoints',
        'eventSets',
        'cases',
    ]);
    if (fixture.schemaVersion !== 1
        || fixture.fixtureKind !== 'controlled-health-validator') {
        fail('fixture: unsupported schema or kind');
    }
    expectObject(fixture.eventTypes, 'fixture.eventTypes', ['funding', 'health']);
    expectObject(fixture.checkpoints, 'fixture.checkpoints');
    for (const [name, value] of Object.entries(fixture.checkpoints)) {
        checkpoint(value, `fixture.checkpoints.${name}`);
    }
    expectObject(fixture.eventSets, 'fixture.eventSets');
    const eventSets = {};
    for (const [name, events] of Object.entries(fixture.eventSets)) {
        if (!Array.isArray(events)) fail(`fixture.eventSets.${name}: expected list`);
        eventSets[name] = events.map((event, index) => {
            const resolved = structuredClone(event);
            for (const field of ['previous_checkpoint', 'checkpoint']) {
                const reference = resolved.parsedJson?.[field];
                if (typeof reference === 'string') {
                    if (fixture.checkpoints[reference] === undefined) {
                        fail(`fixture.eventSets.${name}[${index}]: unknown ${field} reference`);
                    }
                    resolved.parsedJson[field] = fixture.checkpoints[reference];
                }
            }
            protocolEvent(
                resolved,
                `fixture.eventSets.${name}[${index}]`,
                fixture.eventTypes,
            );
            return resolved;
        });
    }
    validateCaseNames(fixture.cases, 'fixture.cases');
    fixture.cases.forEach((entry, index) => {
        expectObject(entry, `fixture.cases[${index}]`, [
            'name',
            'pre',
            'post',
            'events',
            'expected',
        ]);
        const pre = fixture.checkpoints[entry.pre.checkpoint];
        const post = fixture.checkpoints[entry.post.checkpoint];
        if (pre === undefined || post === undefined) {
            fail(`fixture.cases[${index}]: unknown checkpoint reference`);
        }
        const events = eventSets[entry.events];
        if (events === undefined) {
            fail(`fixture.cases[${index}]: unknown event-set reference`);
        }
        const expectedEvents = eventSets[entry.expected.events];
        if (expectedEvents === undefined) {
            fail(`fixture.cases[${index}]: unknown expected event-set reference`);
        }
        validateEvidence({
            pre: { ...entry.pre, checkpoint: pre },
            post: { ...entry.post, checkpoint: post },
            events,
        }, {
            ...entry.expected,
            events: expectedEvents,
        }, fixture.eventTypes, `fixture.cases[${index}]`);
    });
}

function expectFailure(message, run) {
    try {
        run();
    } catch (error) {
        if (String(error.message).includes(message)) return;
        fail(`expected failure containing ${JSON.stringify(message)}, got ${JSON.stringify(error.message)}`);
    }
    fail(`expected failure containing ${JSON.stringify(message)}`);
}

function selfTest() {
    const fixture = readJson(FIXTURE_PATH);
    validateFixture(fixture);
    let passed = CASE_NAMES.length;

    const missing = structuredClone(fixture);
    missing.cases.pop();
    expectFailure('complete', () => validateFixture(missing));
    passed += 1;

    const relabeled = structuredClone(fixture);
    relabeled.cases[0].name = 'short';
    expectFailure('expected long', () => validateFixture(relabeled));
    passed += 1;

    const wrongClassification = structuredClone(fixture);
    wrongClassification.cases[8].expected.classification = 'unchanged';
    expectFailure('.outcome', () => validateFixture(wrongClassification));
    passed += 1;

    const wrongLifecycle = structuredClone(fixture);
    wrongLifecycle.cases[14].expected.lifecycle = 'Active';
    expectFailure('.outcome', () => validateFixture(wrongLifecycle));
    passed += 1;

    const missingEvent = structuredClone(fixture);
    missingEvent.cases[5].events = 'none';
    expectFailure('.outcome', () => validateFixture(missingEvent));
    passed += 1;

    process.stdout.write(`controlled_health_cases self-test: PASS ${passed}/${CASE_NAMES.length + 5} cases\n`);
}

function runSui(args, allowFailure = false) {
    const result = spawnSync('sui', args, {
        cwd: PACKAGE_DIR,
        encoding: 'utf8',
        stdio: ['ignore', 'pipe', 'pipe'],
    });
    if (result.error) fail(`sui invocation failed: ${result.error.message}`);
    const output = `${result.stdout ?? ''}${result.stderr ?? ''}`;
    if (!allowFailure && result.status !== 0) {
        fail(`sui ${args.slice(0, 4).join(' ')} failed: ${output.trim()}`);
    }
    return { status: result.status, output };
}

function parseJson(output, path) {
    try {
        return JSON.parse(output);
    } catch {
        fail(`${path}: expected canonical JSON from Sui CLI`);
    }
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
    for (const token of pointer.slice(1).split('/')) {
        const key = token.replaceAll('~1', '/').replaceAll('~0', '~');
        if (value === null || typeof value !== 'object' || !(key in value)) {
            fail(`${path}: pointer ${pointer} does not resolve at ${key}`);
        }
        value = value[key];
    }
    return canonical(value);
}

function validateVaultSpec(spec, path) {
    expectObject(spec, path, ['id', 'expectedType', 'selectors']);
    expectAddress(spec.id, `${path}.id`);
    expectString(spec.expectedType, `${path}.expectedType`);
    expectObject(spec.selectors, `${path}.selectors`, SELECTOR_KEYS);
    for (const key of SELECTOR_KEYS) {
        expectString(spec.selectors[key], `${path}.selectors.${key}`);
    }
}

function snapshotVault(environment, spec, path) {
    validateVaultSpec(spec, path);
    const raw = parseJson(runSui([
        'client',
        '--client.env',
        environment,
        'object',
        spec.id,
        '--json',
    ]).output, path);
    if (raw.objectId !== spec.id) fail(`${path}: object id mismatch`);
    if (raw.objType !== spec.expectedType) fail(`${path}: object type mismatch`);
    const selected = {};
    for (const key of SELECTOR_KEYS) {
        selected[key] = jsonPointer(
            raw,
            spec.selectors[key],
            `${path}.selectors.${key}`,
        );
    }
    checkpoint(selected.checkpoint, `${path}.checkpoint`);
    return canonical({ raw, selected });
}

function ptbTargets(args, path) {
    if (!Array.isArray(args) || args.some((arg) => typeof arg !== 'string')) {
        fail(`${path}: expected string list`);
    }
    for (const forbidden of [
        '--dev-inspect',
        '--dry-run',
        '--preview',
        '--serialize-unsigned-transaction',
        '--serialize-signed-transaction',
    ]) {
        if (args.includes(forbidden)) fail(`${path}: forbids ${forbidden}`);
    }
    const targets = [];
    args.forEach((arg, index) => {
        if (arg === '--move-call') {
            const target = expectString(args[index + 1], `${path}[${index + 1}]`);
            if (/_tests?::|for_testing/.test(target)) {
                fail(`${path}: test-only call ${target}`);
            }
            targets.push(target);
        }
    });
    if (targets.length === 0) fail(`${path}: expected executed production calls`);
    return targets;
}

function validateRunArgs(run, adapterPackage, vaultId, path) {
    expectObject(run, path, ['ptbArgs', 'expectedTargets']);
    const targets = ptbTargets(run.ptbArgs, `${path}.ptbArgs`);
    if (!Array.isArray(run.expectedTargets)) {
        fail(`${path}.expectedTargets: expected list`);
    }
    assertEqual(targets, run.expectedTargets, `${path}.targets`);
    if (!run.ptbArgs.includes(`@${vaultId}`)) {
        fail(`${path}: does not bind the case Vault`);
    }
    return targets;
}

function transactionDigest(output) {
    const transaction = parseJson(output, 'submitted transaction');
    const digest = transaction.digest ?? transaction.effects?.transactionDigest;
    if (typeof digest !== 'string') fail('submitted transaction: missing digest');
    return digest;
}

function normalizeTransaction(transaction) {
    const effects = transaction.effects ?? {};
    const status = effects.status?.status ?? effects.status;
    if (String(status).toLowerCase() !== 'success') {
        fail(`controlled transaction failed: ${effects.status?.error ?? effects.error ?? status}`);
    }
    const events = Array.isArray(transaction.events) ? transaction.events : [];
    return canonical({
        status: 'success',
        events: events.map((event) => ({
            type: event.type,
            parsedJson: event.parsedJson ?? event.parsed_json,
        })),
        objectChanges: transaction.objectChanges ?? [],
    });
}

function submit(environment, args) {
    const command = ['client', '--client.env', environment, 'ptb', ...args];
    if (!command.includes('--json')) command.push('--json');
    const digest = transactionDigest(runSui(command).output);
    const transaction = parseJson(runSui([
        'client',
        '--client.env',
        environment,
        'tx-block',
        digest,
        '--json',
    ]).output, digest);
    return { digest, ...normalizeTransaction(transaction) };
}

function live(configPath) {
    if (!configPath) {
        fail('controlled P16-P19 proof requires --config <controlled-health.json> or BLAST_HEALTH_CASES_CONFIG; no funded controlled cases are recorded');
    }
    const config = readJson(resolve(configPath));
    expectObject(config, 'config', [
        'schemaVersion',
        'fixtureKind',
        'environment',
        'chainIdentifier',
        'adapterPackage',
        'eventTypes',
        'outputPath',
        'cases',
    ]);
    if (config.schemaVersion !== 1
        || config.fixtureKind !== 'controlled-health-cases'
        || config.environment !== 'testnet'
        || config.chainIdentifier !== TESTNET_CHAIN) {
        fail('config: unsupported schema, kind, environment, or chain');
    }
    const chain = parseChainIdentifier(runSui([
        'client',
        '--client.env',
        config.environment,
        'chain-identifier',
    ]).output);
    if (chain !== config.chainIdentifier) fail('config: chain identifier drift');
    expectAddress(config.adapterPackage, 'config.adapterPackage');
    expectObject(config.eventTypes, 'config.eventTypes', ['funding', 'health']);
    validateCaseNames(config.cases, 'config.cases');
    const vaultIds = new Set();
    const evidence = [];
    config.cases.forEach((entry, index) => {
        const path = `config.cases[${index}]`;
        expectObject(entry, path, [
            'name',
            'vault',
            'prepare',
            'transition',
            'expected',
        ]);
        validateVaultSpec(entry.vault, `${path}.vault`);
        if (vaultIds.has(entry.vault.id)) fail(`${path}: Vault reused across cases`);
        vaultIds.add(entry.vault.id);
        validateRunArgs(
            entry.prepare,
            config.adapterPackage,
            entry.vault.id,
            `${path}.prepare`,
        );
        const transitionTargets = validateRunArgs(
            entry.transition,
            config.adapterPackage,
            entry.vault.id,
            `${path}.transition`,
        );
        const syncTarget = `${config.adapterPackage}::operations::sync_health`;
        if (transitionTargets.filter((target) => target === syncTarget).length !== 1) {
            fail(`${path}.transition: expected exactly one production ${syncTarget}`);
        }

        const preparation = submit(config.environment, entry.prepare.ptbArgs);
        const pre = snapshotVault(
            config.environment,
            entry.vault,
            `${path}.pre`,
        );
        const transition = submit(config.environment, entry.transition.ptbArgs);
        const post = snapshotVault(
            config.environment,
            entry.vault,
            `${path}.post`,
        );
        const protocolEvents = transition.events.filter((event) =>
            event.type === config.eventTypes.funding
            || event.type === config.eventTypes.health);
        const outcome = validateEvidence({
            pre: pre.selected,
            post: post.selected,
            events: protocolEvents,
        }, entry.expected, config.eventTypes, path);
        evidence.push(canonical({
            name: entry.name,
            preparation,
            transition,
            pre,
            post,
            outcome,
        }));
    });

    const outputPath = resolve(config.outputPath);
    if (outputPath === resolve(FIXTURE_PATH)) {
        fail('live evidence must not overwrite the offline fixture');
    }
    writeFileSync(outputPath, `${JSON.stringify(canonical({
        schemaVersion: 1,
        evidenceKind: 'submitted-controlled-health-cases',
        chainIdentifier: chain,
        evidence,
    }), null, 2)}\n`, { flag: 'wx', mode: 0o600 });
    process.stdout.write(`controlled_health_cases: PASS ${CASE_NAMES.length}/${CASE_NAMES.length} submitted cases; evidence ${outputPath}\n`);
}

function parseArgs(args) {
    if (args.length === 1 && args[0] === '--self-test') {
        return { selfTest: true, config: null };
    }
    if (args.length === 2 && args[0] === '--config') {
        return { selfTest: false, config: args[1] };
    }
    if (args.length === 0) {
        return {
            selfTest: false,
            config: process.env.BLAST_HEALTH_CASES_CONFIG ?? null,
        };
    }
    fail('usage: controlled_health_cases.mjs [--self-test|--config <path>]');
}

try {
    const args = parseArgs(process.argv.slice(2));
    if (args.selfTest) selfTest(); else live(args.config);
} catch (error) {
    process.stderr.write(`controlled_health_cases: FAIL ${error.message}\n`);
    process.exitCode = 1;
}
