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
const PINNED_SUI_VERSION = '1.77.2-51d177ad7d65';
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
const VAULT_SELECTORS = {
    lifecycle: '/content/fields/series_state/fields/lifecycle',
    maintenanceReserve: '/content/fields/series_state/fields/maintenance_reserve',
    checkpoint: '/content/fields/venue_account/fields/vec/0/fields/checkpoint/fields',
};
const SELECTOR_KEYS = Object.keys(VAULT_SELECTORS);

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

function eventTypes(adapterPackage, productType) {
    adapterPackage = expectAddress(adapterPackage, 'adapterPackage');
    productType = expectString(productType, 'productType');
    const prefix = `${adapterPackage}::product::Product<`;
    if (!productType.startsWith(prefix) || !productType.endsWith('>')) {
        fail(`productType: expected ${prefix}...>`);
    }
    return {
        funding: `${adapterPackage}::events_wrapper::Event<${adapterPackage}::events::FundingSettled<${productType}>>`,
        health: `${adapterPackage}::events_wrapper::Event<${adapterPackage}::events::HealthSynchronized<${productType}>>`,
    };
}

function vaultType(adapterPackage, productType) {
    return `${adapterPackage}::vault::Vault<${productType}>`;
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

function protocolEvent(event, path, types) {
    const value = expectObject(event, path, ['type', 'parsedJson']);
    expectString(value.type, `${path}.type`);
    const wrapper = expectObject(value.parsedJson, `${path}.parsedJson`, ['pos0']);
    const parsed = expectObject(wrapper.pos0, `${path}.parsedJson.pos0`);
    if (value.type === types.funding) {
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
    } else if (value.type === types.health) {
        expectObject(parsed, `${path}.parsedJson`, [
            'vault_id',
            'reason',
            'lifecycle_changed',
            'checkpoint',
        ]);
        checkpoint(parsed.checkpoint, `${path}.checkpoint`);
    } else fail(`${path}: unexpected protocol event type ${value.type}`);
    return canonical({ type: value.type, parsedJson: parsed });
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

function validateEvidence(evidence, oracle, types, vaultId, path) {
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
        protocolEvent(event, `${path}.events[${index}]`, types));
    const funding = events.filter((event) => event.type === types.funding);
    const health = events.filter((event) => event.type === types.health);
    if (funding.length > 1) fail(`${path}: more than one FundingSettled event`);
    if (health.length > 1) fail(`${path}: more than one HealthSynchronized event`);
    expectObject(oracle, `${path}.oracle`, [
        'classification',
        'lifecycle',
        'fundingEvents',
        'healthEvents',
        'reason',
    ]);
    if (!Number.isInteger(oracle.fundingEvents) || !Number.isInteger(oracle.healthEvents)) {
        fail(`${path}.oracle: event cardinalities must be integers`);
    }
    if (oracle.reason !== null && !Number.isInteger(oracle.reason)) {
        fail(`${path}.oracle.reason: expected integer or null`);
    }
    const observed = {
        classification: classify(
            preCheckpoint,
            postCheckpoint,
            events,
            types,
        ),
        lifecycle: evidence.post.lifecycle,
        fundingEvents: funding.length,
        healthEvents: health.length,
        reason: health.length === 0 ? null : health[0].parsedJson.reason,
    };
    assertEqual(observed, oracle, `${path}.outcome`);

    const normalizedVaultId = expectAddress(vaultId, `${path}.vaultId`);
    for (const event of events) {
        assertEqual(
            expectAddress(event.parsedJson.vault_id, `${path}.event.vault_id`),
            normalizedVaultId,
            `${path}.event.vault_id`,
        );
    }
    if (funding.length === 1) {
        const parsed = funding[0].parsedJson;
        assertEqual(parsed.previous_checkpoint, preCheckpoint, `${path}.funding.previous_checkpoint`);
        assertEqual(parsed.checkpoint, postCheckpoint, `${path}.funding.checkpoint`);
        assertEqual(String(parsed.reserve_after), String(evidence.post.maintenanceReserve), `${path}.funding.reserve_after`);
        assertEqual(parsed.is_cost, observed.classification === 'funding_cost', `${path}.funding.is_cost`);
    }
    if (health.length === 1) {
        const parsed = health[0].parsedJson;
        assertEqual(parsed.checkpoint, postCheckpoint, `${path}.health.checkpoint`);
        assertEqual(
            parsed.lifecycle_changed,
            evidence.pre.lifecycle !== evidence.post.lifecycle,
            `${path}.health.lifecycle_changed`,
        );
    }
    return observed;
}

function validateCaseNames(cases, path) {
    if (!Array.isArray(cases) || cases.length !== CASE_NAMES.length) {
        fail(`${path}: expected the complete ${CASE_NAMES.length}-case matrix`);
    }
    const seen = new Set();
    cases.forEach((entry, index) => {
        const name = expectString(entry?.name, `${path}[${index}].name`);
        if (!CASE_NAMES.includes(name)) fail(`${path}[${index}]: unknown case ${name}`);
        if (seen.has(name)) fail(`${path}[${index}]: duplicate case ${name}`);
        seen.add(name);
    });
    for (const name of CASE_NAMES) {
        if (!seen.has(name)) fail(`${path}: missing case ${name}`);
    }
}

function validateFixture(fixture) {
    expectObject(fixture, 'fixture', [
        'schemaVersion',
        'fixtureKind',
        'adapterPackage',
        'productType',
        'vaultId',
        'checkpoints',
        'eventSets',
        'cases',
    ]);
    if (fixture.schemaVersion !== 2
        || fixture.fixtureKind !== 'controlled-health-validator') {
        fail('fixture: unsupported schema or kind');
    }
    const types = eventTypes(fixture.adapterPackage, fixture.productType);
    expectAddress(fixture.vaultId, 'fixture.vaultId');
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
                const reference = resolved.parsedJson?.pos0?.[field];
                if (typeof reference === 'string') {
                    if (fixture.checkpoints[reference] === undefined) {
                        fail(`fixture.eventSets.${name}[${index}]: unknown ${field} reference`);
                    }
                    resolved.parsedJson.pos0[field] = fixture.checkpoints[reference];
                }
            }
            protocolEvent(
                resolved,
                `fixture.eventSets.${name}[${index}]`,
                types,
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
            'oracle',
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
        validateEvidence({
            pre: { ...entry.pre, checkpoint: pre },
            post: { ...entry.post, checkpoint: post },
            events,
        }, entry.oracle, types, fixture.vaultId, `fixture.cases[${index}]`);
    });
    return {
        types,
        oracleByCase: new Map(fixture.cases.map((entry) => [entry.name, entry.oracle])),
    };
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
    if (Object.hasOwn(fixture, 'eventTypes')) {
        fail('fixture: event types must be derived from the adapter package and Product type');
    }
    for (const entry of fixture.cases ?? []) {
        if (Object.hasOwn(entry, 'expected')) {
            fail('fixture: case expectations must live in the fixed oracle');
        }
    }
    const { oracleByCase } = validateFixture(fixture);
    let passed = CASE_NAMES.length;

    const missing = structuredClone(fixture);
    missing.cases.pop();
    expectFailure('complete', () => validateFixture(missing));
    passed += 1;

    const relabeled = structuredClone(fixture);
    relabeled.cases[0].name = 'short';
    expectFailure('duplicate case short', () => validateFixture(relabeled));
    passed += 1;

    const wrongClassification = structuredClone(fixture);
    wrongClassification.cases[8].oracle.classification = 'unchanged';
    expectFailure('.outcome', () => validateFixture(wrongClassification));
    passed += 1;

    const wrongLifecycle = structuredClone(fixture);
    wrongLifecycle.cases[14].oracle.lifecycle = 'Active';
    expectFailure('.outcome', () => validateFixture(wrongLifecycle));
    passed += 1;

    const missingEvent = structuredClone(fixture);
    missingEvent.cases[5].events = 'none';
    expectFailure('.outcome', () => validateFixture(missingEvent));
    passed += 1;

    const liveConfig = sampleLiveConfig(fixture);
    validateLiveConfig(liveConfig, oracleByCase);
    passed += 1;

    const lyingConfig = structuredClone(liveConfig);
    lyingConfig.cases[0].expected = {
        classification: 'unchanged',
        lifecycle: 'Active',
    };
    expectFailure('field set mismatch', () => validateLiveConfig(
        lyingConfig,
        oracleByCase,
    ));
    passed += 1;

    const wrongSyncVault = structuredClone(liveConfig);
    wrongSyncVault.cases[0].transition.ptbArgs.splice(
        2,
        0,
        '<SyntheticProduct,SyntheticCollateral>',
    );
    wrongSyncVault.cases[0].transition.ptbArgs[3] = `@${liveConfig.cases[1].vaultId}`;
    wrongSyncVault.cases[0].transition.ptbArgs.push(
        '--move-call',
        `${fixture.adapterPackage}::some_module::mention`,
        `@${liveConfig.cases[0].vaultId}`,
    );
    expectFailure('sync_health must receive the case Vault first', () =>
        validateLiveConfig(wrongSyncVault, oracleByCase));
    passed += 1;

    const swappedCases = structuredClone(liveConfig);
    [swappedCases.cases[0].name, swappedCases.cases[1].name] = [
        swappedCases.cases[1].name,
        swappedCases.cases[0].name,
    ];
    expectFailure('scenario call', () => validateLiveConfig(swappedCases, oracleByCase));
    passed += 1;

    process.stdout.write(`controlled_health_cases self-test: PASS ${passed}/${CASE_NAMES.length + 9} cases\n`);
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

function assertPinnedSuiVersion() {
    const observed = runSui(['--version']).output.trim();
    if (observed !== `sui ${PINNED_SUI_VERSION}`) {
        fail(`Sui CLI version mismatch: expected ${PINNED_SUI_VERSION}, got ${observed}`);
    }
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

function snapshotVault(environment, vaultId, expectedType, path) {
    vaultId = expectAddress(vaultId, `${path}.vaultId`);
    const raw = parseJson(runSui([
        'client',
        '--client.env',
        environment,
        'object',
        vaultId,
        '--json',
    ]).output, path);
    if (expectAddress(raw.objectId, `${path}.objectId`) !== vaultId) {
        fail(`${path}: object id mismatch`);
    }
    if (raw.objType !== expectedType) fail(`${path}: object type mismatch`);
    const selected = {};
    for (const key of SELECTOR_KEYS) {
        selected[key] = jsonPointer(
            raw,
            VAULT_SELECTORS[key],
            `${path}.${key}`,
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

function validateRunArgs(run, vaultId, path) {
    expectObject(run, path, ['ptbArgs']);
    const targets = ptbTargets(run.ptbArgs, `${path}.ptbArgs`);
    if (!run.ptbArgs.includes(`@${vaultId}`)) {
        fail(`${path}: does not bind the case Vault`);
    }
    return targets;
}

function validateLiveConfig(config, oracleByCase) {
    expectObject(config, 'config', [
        'schemaVersion',
        'fixtureKind',
        'environment',
        'chainIdentifier',
        'adapterPackage',
        'productType',
        'outputPath',
        'cases',
    ]);
    if (config.schemaVersion !== 2
        || config.fixtureKind !== 'controlled-health-cases'
        || config.environment !== 'testnet'
        || config.chainIdentifier !== TESTNET_CHAIN) {
        fail('config: unsupported schema, kind, environment, or chain');
    }
    const adapterPackage = expectAddress(config.adapterPackage, 'config.adapterPackage');
    const types = eventTypes(adapterPackage, config.productType);
    const expectedVaultType = vaultType(adapterPackage, config.productType);
    expectString(config.outputPath, 'config.outputPath');
    validateCaseNames(config.cases, 'config.cases');
    const vaultIds = new Set();
    config.cases.forEach((entry, index) => {
        const path = `config.cases[${index}]`;
        expectObject(entry, path, ['name', 'vaultId', 'prepare', 'transition']);
        if (!oracleByCase.has(entry.name)) fail(`${path}: no fixed oracle for ${entry.name}`);
        const vaultId = expectAddress(entry.vaultId, `${path}.vaultId`);
        if (vaultIds.has(vaultId)) fail(`${path}: Vault reused across cases`);
        vaultIds.add(vaultId);
        const prepareTargets = validateRunArgs(entry.prepare, vaultId, `${path}.prepare`);
        const scenarioTarget = `::controlled_health_cases::prepare_${entry.name}`;
        if (prepareTargets.filter((target) => target.endsWith(scenarioTarget)).length !== 1) {
            fail(`${path}.prepare: expected exactly one ${scenarioTarget} scenario call`);
        }
        const transitionTargets = validateRunArgs(
            entry.transition,
            vaultId,
            `${path}.transition`,
        );
        const syncTarget = `${adapterPackage}::operations::sync_health`;
        if (transitionTargets.filter((target) => target === syncTarget).length !== 1) {
            fail(`${path}.transition: expected exactly one production ${syncTarget}`);
        }
        const syncIndex = entry.transition.ptbArgs.indexOf(syncTarget);
        const possibleTypeArguments = entry.transition.ptbArgs[syncIndex + 1];
        const vaultArgumentIndex = typeof possibleTypeArguments === 'string'
            && possibleTypeArguments.startsWith('<')
            && possibleTypeArguments.endsWith('>')
            ? syncIndex + 2
            : syncIndex + 1;
        if (entry.transition.ptbArgs[vaultArgumentIndex] !== `@${vaultId}`) {
            fail(`${path}.transition: sync_health must receive the case Vault first`);
        }
    });
    return { adapterPackage, expectedVaultType, types };
}

function sampleLiveConfig(fixture) {
    return {
        schemaVersion: 2,
        fixtureKind: 'controlled-health-cases',
        environment: 'testnet',
        chainIdentifier: TESTNET_CHAIN,
        adapterPackage: fixture.adapterPackage,
        productType: fixture.productType,
        outputPath: '/tmp/controlled-health-evidence.json',
        cases: CASE_NAMES.map((name, index) => {
            const vaultId = `0x${(index + 1).toString(16).padStart(64, '0')}`;
            return {
                name,
                vaultId,
                prepare: {
                    ptbArgs: [
                        '--move-call',
                        `${fixture.adapterPackage}::controlled_health_cases::prepare_${name}`,
                        `@${vaultId}`,
                    ],
                },
                transition: {
                    ptbArgs: [
                        '--move-call',
                        `${fixture.adapterPackage}::operations::sync_health`,
                        `@${vaultId}`,
                    ],
                },
            };
        }),
    };
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
    assertPinnedSuiVersion();
    const config = readJson(resolve(configPath));
    const fixture = readJson(FIXTURE_PATH);
    const { oracleByCase } = validateFixture(fixture);
    const { adapterPackage, expectedVaultType, types } = validateLiveConfig(
        config,
        oracleByCase,
    );
    const chain = parseChainIdentifier(runSui([
        'client',
        '--client.env',
        config.environment,
        'chain-identifier',
    ]).output);
    if (chain !== config.chainIdentifier) fail('config: chain identifier drift');
    const evidence = [];
    config.cases.forEach((entry, index) => {
        const path = `config.cases[${index}]`;
        const preparation = submit(config.environment, entry.prepare.ptbArgs);
        const pre = snapshotVault(
            config.environment,
            entry.vaultId,
            expectedVaultType,
            `${path}.pre`,
        );
        const transition = submit(config.environment, entry.transition.ptbArgs);
        const post = snapshotVault(
            config.environment,
            entry.vaultId,
            expectedVaultType,
            `${path}.post`,
        );
        const protocolEvents = transition.events.filter((event) =>
            typeof event.type === 'string'
            && event.type.startsWith(
                `${adapterPackage}::events_wrapper::Event<${adapterPackage}::events::`,
            ));
        const outcome = validateEvidence({
            pre: pre.selected,
            post: post.selected,
            events: protocolEvents,
        }, oracleByCase.get(entry.name), types, entry.vaultId, path);
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
