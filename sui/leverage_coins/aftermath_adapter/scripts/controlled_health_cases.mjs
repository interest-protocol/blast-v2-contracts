#!/usr/bin/env node
// Executes the controlled P16-P19 transition matrix against committed state.
// Every case submits production calls, reads the resulting Vault through the
// standard object API, and classifies canonical raw checkpoints and events.

import { createHash } from 'node:crypto';
import {
    mkdirSync,
    mkdtempSync,
    readFileSync,
    realpathSync,
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
    'two_epoch_funding',
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
    lifecycle: '/content/series_state/lifecycle',
    maintenanceReserve: '/content/series_state/maintenance_reserve',
    checkpoint: '/content/venue_account/checkpoint',
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
    const entries = ['Move.toml', 'Move.lock'].map((name) => [name, readFileSync(join(root, name))]);
    for (const [path, bytes] of walkFiles(join(root, 'sources'))) {
        if (path.endsWith('.move')) entries.push([`sources/${path}`, bytes]);
    }
    return entries.sort(([left], [right]) => left.localeCompare(right));
}

function tomlSection(source, section, path) {
    const lines = source.split(/\r?\n/);
    const starts = lines.flatMap((line, index) =>
        line.trim() === `[${section}]` ? [index] : []);
    if (starts.length === 0) fail(`${path}: missing [${section}]`);
    if (starts.length !== 1) fail(`${path}: duplicate [${section}]`);
    const end = lines.findIndex((line, index) =>
        index > starts[0] && /^\s*\[[^\]]+\]\s*(?:#.*)?$/.test(line));
    return lines.slice(starts[0] + 1, end === -1 ? lines.length : end);
}

function tomlString(lines, key, path) {
    const matches = lines.flatMap((line) => {
        const match = new RegExp(`^\\s*${key}\\s*=\\s*"([^"]+)"\\s*(?:#.*)?$`).exec(line);
        return match === null ? [] : [match[1]];
    });
    if (matches.length !== 1) fail(`${path}: expected exactly one ${key} string`);
    return matches[0];
}

function controlledFixtureFiles(sourceRoot, publicationFile, environment, packageId) {
    sourceRoot = realpathSync(resolve(sourceRoot));
    publicationFile = resolve(publicationFile);
    const expectedPublicationFile = join(sourceRoot, 'Published.toml');
    if (publicationFile !== expectedPublicationFile
        || realpathSync(publicationFile) !== expectedPublicationFile) {
        fail('config.controlledFixture.publicationFile: must be the reviewed root Published.toml');
    }
    const manifest = readFileSync(join(sourceRoot, 'Move.toml'), 'utf8');
    const packageName = tomlString(
        tomlSection(manifest, 'package', `${sourceRoot}/Move.toml`),
        'name',
        `${sourceRoot}/Move.toml [package]`,
    );
    if (!/^[A-Za-z][A-Za-z0-9_]*$/.test(packageName)) {
        fail(`${sourceRoot}/Move.toml [package].name: invalid package name`);
    }
    const publication = readFileSync(publicationFile, 'utf8');
    const publishedAt = expectAddress(tomlString(
        tomlSection(publication, `published.${environment}`, publicationFile),
        'published-at',
        `${publicationFile} [published.${environment}]`,
    ), `${publicationFile} [published.${environment}].published-at`);
    if (publishedAt !== packageId) {
        fail(`${publicationFile} [published.${environment}].published-at does not equal packageId`);
    }
    const entries = buildInputs(sourceRoot);
    entries.push(['Published.toml', readFileSync(publicationFile)]);
    entries.sort(([left], [right]) => left.localeCompare(right));
    return { sourceRoot, publicationFile, packageName, entries };
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

function assertEqual(actual, expected, path = 'value') {
    const left = JSON.stringify(canonical(actual));
    const right = JSON.stringify(canonical(expected));
    if (left !== right) fail(`${path}: expected ${right}, got ${left}`);
}

function unsigned(value, bits, path) {
    const text = typeof value === 'number' && Number.isSafeInteger(value)
        ? String(value)
        : value;
    if (typeof text !== 'string' || !/^(0|[1-9][0-9]*)$/.test(text)) {
        fail(`${path}: expected unsigned integer`);
    }
    const parsed = BigInt(text);
    if (parsed >= (1n << BigInt(bits))) fail(`${path}: exceeds u${bits}`);
    return parsed;
}

function atomicFundingAmount(rawAmount, isCost) {
    const scale = 1_000_000_000_000n;
    const down = rawAmount / scale;
    return isCost && rawAmount % scale !== 0n ? down + 1n : down;
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
    if (funding.length > 1) fail('case: more than one aggregate FundingSettled event');
    if (funding.length === 1) {
        const isCost = funding[0].parsedJson.is_cost;
        if (typeof isCost !== 'boolean') {
            fail('case: FundingSettled.is_cost must be boolean');
        }
        if (BigInt(funding[0].parsedJson.raw_amount) === 0n) return 'funding_zero';
        return isCost ? 'funding_cost' : 'funding_credit';
    }
    if (events.some((event) => event.type === eventTypes.health && event.parsedJson.reason === 1)) return 'unexpected';
    return JSON.stringify(canonical(preCheckpoint))
        === JSON.stringify(canonical(postCheckpoint))
        ? 'unchanged'
        : 'unexpected';
}

function validateEvidence(evidence, oracle, types, vaultId, path) {
    expectObject(evidence, path, ['stored', 'pre', 'post', 'events']);
    expectObject(evidence.stored, `${path}.stored`, SELECTOR_KEYS);
    expectObject(evidence.pre, `${path}.pre`, SELECTOR_KEYS);
    expectObject(evidence.post, `${path}.post`, SELECTOR_KEYS);
    const storedCheckpoint = checkpoint(
        evidence.stored.checkpoint,
        `${path}.stored.checkpoint`,
    );
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
    if (funding.length > 1) fail(`${path}: more than one aggregate FundingSettled event`);
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
    assertEqual(evidence.post.lifecycle, evidence.pre.lifecycle, `${path}: ordinary health must preserve lifecycle`);
    assertEqual(observed, oracle, `${path}.outcome`);

    const normalizedVaultId = expectAddress(vaultId, `${path}.vaultId`);
    const preReserve = unsigned(
        evidence.pre.maintenanceReserve,
        64,
        `${path}.pre.maintenanceReserve`,
    );
    const postReserve = unsigned(
        evidence.post.maintenanceReserve,
        64,
        `${path}.post.maintenanceReserve`,
    );
    for (const event of events) {
        assertEqual(
            expectAddress(event.parsedJson.vault_id, `${path}.event.vault_id`),
            normalizedVaultId,
            `${path}.event.vault_id`,
        );
    }
    if (funding.length > 0) {
        const fundingEdges = [[storedCheckpoint, postCheckpoint]];
        let expectedReserve = preReserve;
        funding.forEach((event, index) => {
            const parsed = event.parsedJson;
            const [fundingBefore, fundingAfter] = fundingEdges[index];
            const isCost = parsed.is_cost;
            // Decode the same signed u256 IFixed carrier as activation_atomicity;
            // never order raw negative carriers as collateral assets.
            const preAllocated = BigInt.asIntN(256, unsigned(
                fundingBefore.allocated_collateral,
                256,
                `${path}.funding[${index}].before.allocated_collateral`,
            ));
            const postAllocated = BigInt.asIntN(256, unsigned(
                fundingAfter.allocated_collateral,
                256,
                `${path}.funding[${index}].after.allocated_collateral`,
            ));
            if (isCost ? postAllocated >= preAllocated : postAllocated < preAllocated) {
                fail(`${path}.funding.raw_amount: allocated-collateral direction mismatch`);
            }
            const rawAmount = isCost
                ? preAllocated - postAllocated
                : postAllocated - preAllocated;
            const amount = atomicFundingAmount(rawAmount, isCost);
            const eventPath = `${path}.funding[${index}]`;
            const observedRaw = unsigned(parsed.raw_amount, 256, `${eventPath}.raw_amount`);
            const observedAmount = unsigned(parsed.amount, 64, `${eventPath}.amount`);
            assertEqual(observedRaw.toString(), rawAmount.toString(), `${eventPath}.raw_amount`);
            assertEqual(observedAmount.toString(), amount.toString(), `${eventPath}.amount`);
            const expectedPrevious = storedCheckpoint;
            const expectedCheckpoint = postCheckpoint;
            assertEqual(parsed.previous_checkpoint, expectedPrevious, `${eventPath}.previous_checkpoint`);
            assertEqual(parsed.checkpoint, expectedCheckpoint, `${eventPath}.checkpoint`);
            const absorbed = isCost && amount < expectedReserve
                ? amount
                : isCost ? expectedReserve : 0n;
            const uncovered = isCost ? amount - absorbed : 0n;
            expectedReserve = isCost ? expectedReserve - absorbed : expectedReserve + amount;
            if (expectedReserve > (1n << 64n) - 1n) fail(`${path}: reserve width overflow`);
            assertEqual(
                unsigned(parsed.absorbed_by_reserve, 64, `${eventPath}.absorbed_by_reserve`).toString(),
                absorbed.toString(),
                `${eventPath}.absorbed_by_reserve`,
            );
            assertEqual(
                unsigned(parsed.uncovered_cost, 64, `${eventPath}.uncovered_cost`).toString(),
                uncovered.toString(),
                `${eventPath}.uncovered_cost`,
            );
            assertEqual(
                unsigned(parsed.reserve_after, 64, `${eventPath}.reserve_after`).toString(),
                expectedReserve.toString(),
                `${eventPath}.reserve_after`,
            );
            assertEqual(parsed.is_cost, postAllocated < preAllocated, `${eventPath}.is_cost`);
        });
        assertEqual(postReserve.toString(), expectedReserve.toString(), `${path}.post.maintenanceReserve`);
    } else {
        assertEqual(
            postReserve.toString(),
            preReserve.toString(),
            `${path}: reserve must remain unchanged without funding cost`,
        );
    }
    if (health.length === 1) {
        const parsed = health[0].parsedJson;
        if (parsed.reason === 1) {
            assertEqual(postCheckpoint, storedCheckpoint, `${path}: unresolved observation must preserve accepted checkpoint`);
            if (JSON.stringify(canonical(parsed.checkpoint)) === JSON.stringify(canonical(storedCheckpoint))) {
                fail(`${path}: unresolved observation must identify a changed checkpoint`);
            }
        } else if (parsed.reason === 2) {
            assertEqual(parsed.checkpoint, postCheckpoint, `${path}.health.checkpoint`);
        } else {
            fail(`${path}: unsupported health reason`);
        }
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
    if (fixture.schemaVersion !== 5
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
            'stored',
            'pre',
            'post',
            'events',
            'oracle',
        ]);
        const stored = fixture.checkpoints[entry.stored.checkpoint];
        const pre = fixture.checkpoints[entry.pre.checkpoint];
        const post = fixture.checkpoints[entry.post.checkpoint];
        if (stored === undefined || pre === undefined || post === undefined) {
            fail(`fixture.cases[${index}]: unknown checkpoint reference`);
        }
        const events = eventSets[entry.events];
        if (events === undefined) {
            fail(`fixture.cases[${index}]: unknown event-set reference`);
        }
        validateEvidence({
            stored: { ...entry.stored, checkpoint: stored },
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

    const flatVault = {
        objectId: fixture.vaultId,
        objType: vaultType(fixture.adapterPackage, fixture.productType),
        content: {
            series_state: {
                lifecycle: 'Active',
                maintenance_reserve: '100',
            },
            venue_account: {
                checkpoint: fixture.checkpoints.long,
            },
        },
    };
    assertEqual(selectVaultFields(
        flatVault,
        fixture.vaultId,
        flatVault.objType,
        'flat vault',
    ), {
        lifecycle: 'Active',
        maintenanceReserve: '100',
        checkpoint: fixture.checkpoints.long,
    }, 'flat vault selectors');
    passed += 1;

    const legacyNestedVault = structuredClone(flatVault);
    legacyNestedVault.content = { fields: flatVault.content };
    expectFailure('does not resolve', () => selectVaultFields(
        legacyNestedVault,
        fixture.vaultId,
        flatVault.objType,
        'legacy nested vault',
    ));
    passed += 1;

    const missing = structuredClone(fixture);
    missing.cases.pop();
    expectFailure('complete', () => validateFixture(missing));
    passed += 1;

    const relabeled = structuredClone(fixture);
    relabeled.cases[0].name = 'short';
    expectFailure('duplicate case short', () => validateFixture(relabeled));
    passed += 1;

    const wrongClassification = structuredClone(fixture);
    wrongClassification.cases[9].oracle.classification = 'unchanged';
    expectFailure('.outcome', () => validateFixture(wrongClassification));
    passed += 1;

    const wrongLifecycle = structuredClone(fixture);
    wrongLifecycle.cases[14].oracle.lifecycle = 'ReduceOnly';
    expectFailure('.outcome', () => validateFixture(wrongLifecycle));
    passed += 1;

    const missingEvent = structuredClone(fixture);
    missingEvent.cases[5].events = 'none';
    expectFailure('.outcome', () => validateFixture(missingEvent));
    passed += 1;

    const liveConfig = sampleLiveConfig(fixture);
    const controlledFixtureProof = sampleControlledFixtureProof(liveConfig);
    validateLiveConfig(liveConfig, oracleByCase, controlledFixtureProof);
    passed += 1;

    const lyingConfig = structuredClone(liveConfig);
    lyingConfig.cases[0].expected = {
        classification: 'unchanged',
        lifecycle: 'Active',
    };
    expectFailure('field set mismatch', () => validateLiveConfig(
        lyingConfig,
        oracleByCase,
        controlledFixtureProof,
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
        validateLiveConfig(wrongSyncVault, oracleByCase, controlledFixtureProof));
    passed += 1;

    const swappedCases = structuredClone(liveConfig);
    [swappedCases.cases[0].name, swappedCases.cases[1].name] = [
        swappedCases.cases[1].name,
        swappedCases.cases[0].name,
    ];
    expectFailure('scenario call', () => validateLiveConfig(
        swappedCases, oracleByCase, controlledFixtureProof,
    ));
    passed += 1;

    const wrongPreparePackage = structuredClone(liveConfig);
    wrongPreparePackage.cases[0].prepare.ptbArgs[1] =
        `0x${'f'.repeat(64)}::controlled_health_cases::prepare_long`;
    expectFailure('scenario call', () =>
        validateLiveConfig(wrongPreparePackage, oracleByCase, controlledFixtureProof));
    passed += 1;

    const wrongPrepareVault = structuredClone(liveConfig);
    wrongPrepareVault.cases[0].prepare.ptbArgs[2] =
        `@${liveConfig.cases[1].vaultId}`;
    wrongPrepareVault.cases[0].prepare.ptbArgs.push(
        '--move-call',
        `${fixture.adapterPackage}::some_module::mention`,
        `@${liveConfig.cases[0].vaultId}`,
    );
    expectFailure('scenario call must receive the case Vault first', () =>
        validateLiveConfig(wrongPrepareVault, oracleByCase, controlledFixtureProof));
    passed += 1;

    const targetAsArgument = structuredClone(liveConfig);
    targetAsArgument.cases[0].transition.ptbArgs.push(
        `${fixture.adapterPackage}::operations::sync_health`,
    );
    expectFailure('target-shaped argument', () =>
        validateLiveConfig(targetAsArgument, oracleByCase, controlledFixtureProof));
    passed += 1;

    const duplicateSync = structuredClone(liveConfig);
    duplicateSync.cases[0].transition.ptbArgs.push(
        '--move-call',
        `${fixture.adapterPackage}::operations::sync_health`,
        `@${liveConfig.cases[0].vaultId}`,
    );
    expectFailure('expected exactly one production', () =>
        validateLiveConfig(duplicateSync, oracleByCase, controlledFixtureProof));
    passed += 1;

    const reserveDrift = structuredClone(fixture);
    reserveDrift.cases[0].post.maintenanceReserve = '99';
    expectFailure('reserve must remain unchanged', () => validateFixture(reserveDrift));
    passed += 1;

    const wrongFundingAmount = structuredClone(fixture);
    wrongFundingAmount.eventSets.funding_credit[0].parsedJson.pos0.amount = '2';
    expectFailure('funding[0].amount', () => validateFixture(wrongFundingAmount));
    passed += 1;

    const wrongFundingAccounting = structuredClone(fixture);
    wrongFundingAccounting.eventSets.funding_cost[0].parsedJson.pos0.absorbed_by_reserve = '0';
    wrongFundingAccounting.eventSets.funding_cost[0].parsedJson.pos0.uncovered_cost = '1';
    expectFailure('funding[0].absorbed_by_reserve', () => validateFixture(wrongFundingAccounting));
    passed += 1;

    const equalReserveCost = structuredClone(fixture);
    equalReserveCost.cases[6].pre.maintenanceReserve = '1';
    equalReserveCost.cases[6].post.maintenanceReserve = '0';
    equalReserveCost.eventSets.funding_cost[0].parsedJson.pos0.reserve_after = '0';
    validateFixture(equalReserveCost);
    passed += 1;

    const aboveReserveCost = structuredClone(fixture);
    aboveReserveCost.cases[6].pre.maintenanceReserve = '0';
    aboveReserveCost.cases[6].post.maintenanceReserve = '0';
    aboveReserveCost.eventSets.funding_cost[0].parsedJson.pos0.absorbed_by_reserve = '0';
    aboveReserveCost.eventSets.funding_cost[0].parsedJson.pos0.uncovered_cost = '1';
    aboveReserveCost.eventSets.funding_cost[0].parsedJson.pos0.reserve_after = '0';
    validateFixture(aboveReserveCost);
    passed += 1;

    const wrongRawAmount = structuredClone(fixture);
    wrongRawAmount.eventSets.funding_credit[0].parsedJson.pos0.raw_amount = '1';
    expectFailure('funding[0].raw_amount', () => validateFixture(wrongRawAmount));
    passed += 1;

    const creditReserveDrift = structuredClone(fixture);
    creditReserveDrift.cases[5].post.maintenanceReserve = '99';
    creditReserveDrift.eventSets.funding_credit[0].parsedJson.pos0.reserve_after = '99';
    expectFailure('funding[0].reserve_after', () => validateFixture(creditReserveDrift));
    passed += 1;

    const doubleSettlement = structuredClone(fixture);
    doubleSettlement.eventSets.two_epoch_funding.push(structuredClone(doubleSettlement.eventSets.two_epoch_funding[0]));
    expectFailure('more than one aggregate', () => validateFixture(doubleSettlement));
    passed += 1;

    const automaticRetirement = structuredClone(fixture);
    automaticRetirement.cases[15].post.lifecycle = 'ReduceOnly';
    automaticRetirement.cases[15].oracle.lifecycle = 'ReduceOnly';
    expectFailure('ordinary health must preserve lifecycle', () => validateFixture(automaticRetirement));
    passed += 1;

    const overwrittenCheckpoint = structuredClone(fixture);
    overwrittenCheckpoint.cases[9].post.checkpoint = 'liquidation';
    expectFailure('preserve accepted checkpoint', () => validateFixture(overwrittenCheckpoint));
    passed += 1;

    for (const name of ['funding_credit', 'funding_cost']) {
        const entry = fixture.cases.find((item) => item.name === name);
        const stored = structuredClone(fixture.checkpoints[entry.stored.checkpoint]);
        const before = structuredClone(fixture.checkpoints[entry.pre.checkpoint]);
        const after = structuredClone(fixture.checkpoints[entry.post.checkpoint]);
        const halfAtom = 500_000_000_000n;
        const starting = name === 'funding_credit' ? -halfAtom : halfAtom;
        stored.allocated_collateral = BigInt.asUintN(256, starting).toString();
        before.allocated_collateral = stored.allocated_collateral;
        after.allocated_collateral = BigInt.asUintN(256, -starting).toString();
        const events = structuredClone(fixture.eventSets[name]);
        events[0].parsedJson.pos0.previous_checkpoint = stored;
        events[0].parsedJson.pos0.checkpoint = after;
        validateEvidence({
            stored: {...entry.stored, checkpoint: stored},
            pre: {...entry.pre, checkpoint: before},
            post: {...entry.post, checkpoint: after}, events,
        }, entry.oracle, eventTypes(fixture.adapterPackage, fixture.productType), fixture.vaultId, `signed-zero-crossing.${name}`);
        passed += 1;
    }

    const provenanceRoot = mkdtempSync(join(tmpdir(), 'blast-controlled-health-self-test-'));
    try {
        const packageId = `0x${'c'.repeat(64)}`;
        mkdirSync(join(provenanceRoot, 'sources'));
        mkdirSync(join(provenanceRoot, 'build', 'root_fixture', 'bytecode_modules'), { recursive: true });
        mkdirSync(join(provenanceRoot, 'build', 'dependency', 'bytecode_modules'), { recursive: true });
        writeFileSync(join(provenanceRoot, 'Move.toml'), '[package]\nname = "root_fixture"\n');
        writeFileSync(join(provenanceRoot, 'Move.lock'), '');
        writeFileSync(join(provenanceRoot, 'sources', 'controlled_health_cases.move'), 'module fixture::controlled_health_cases {}\n');
        writeFileSync(join(provenanceRoot, 'Published.toml'), `[published.testnet]\npublished-at = "${packageId}"\n`);
        writeFileSync(join(provenanceRoot, 'build', 'root_fixture', 'bytecode_modules', 'controlled_health_cases.mv'), 'root');
        writeFileSync(join(provenanceRoot, 'build', 'dependency', 'bytecode_modules', 'controlled_health_cases.mv'), 'decoy');

        const files = controlledFixtureFiles(
            provenanceRoot,
            join(provenanceRoot, 'Published.toml'),
            'testnet',
            packageId,
        );
        assertEqual(
            Object.keys(builtControlledModules(provenanceRoot, files.packageName)),
            ['controlled_health_cases'],
            'root package module selection',
        );
        passed += 1;

        expectFailure('must be the reviewed root Published.toml', () => controlledFixtureFiles(
            provenanceRoot,
            join(tmpdir(), 'Published.toml'),
            'testnet',
            packageId,
        ));
        passed += 1;

        writeFileSync(join(provenanceRoot, 'Published.toml'), `[published.mainnet]\npublished-at = "${packageId}"\n`);
        expectFailure('missing [published.testnet]', () => controlledFixtureFiles(
            provenanceRoot,
            join(provenanceRoot, 'Published.toml'),
            'testnet',
            packageId,
        ));
        passed += 1;

        writeFileSync(join(provenanceRoot, 'Published.toml'), `[published.testnet]\npublished-at = "0x${'d'.repeat(64)}"\n`);
        expectFailure('published-at does not equal packageId', () => controlledFixtureFiles(
            provenanceRoot,
            join(provenanceRoot, 'Published.toml'),
            'testnet',
            packageId,
        ));
        passed += 1;
    } finally {
        rmSync(provenanceRoot, { recursive: true, force: true });
    }

    process.stdout.write(`controlled_health_cases self-test: PASS ${passed}/${CASE_NAMES.length + 31} cases\n`);
}

function run(command, args, allowFailure = false, cwd = PACKAGE_DIR) {
    const result = spawnSync(command, args, {
        cwd,
        encoding: 'utf8',
        stdio: ['ignore', 'pipe', 'pipe'],
    });
    if (result.error) fail(`${command} invocation failed: ${result.error.message}`);
    const output = `${result.stdout ?? ''}${result.stderr ?? ''}`;
    if (!allowFailure && result.status !== 0) {
        fail(`${command} ${args.slice(0, 4).join(' ')} failed: ${output.trim()}`);
    }
    return { status: result.status, stdout: result.stdout ?? '', stderr: result.stderr ?? '', output };
}

function runSui(args, allowFailure = false) {
    return run('sui', args, allowFailure);
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

function builtControlledModules(installRoot, packageName) {
    const moduleRoot = join(installRoot, 'build', packageName, 'bytecode_modules');
    try {
        if (!statSync(moduleRoot).isDirectory()) fail('not a directory');
    } catch {
        fail(`controlled fixture build: missing root package output ${packageName}/bytecode_modules`);
    }
    if (!readdirSync(moduleRoot).includes('controlled_health_cases.mv')) {
        fail('controlled fixture build: root package is missing controlled_health_cases.mv');
    }
    const modules = {};
    for (const name of readdirSync(moduleRoot).sort()) {
        if (name.endsWith('.mv')) {
            modules[basename(name, '.mv')] = sha256(readFileSync(join(moduleRoot, name)));
        }
    }
    return canonical(modules);
}

function verifyControlledFixture(environment, value) {
    expectObject(value, 'config.controlledFixture', [
        'packageId', 'packageObjectDigest', 'sourceRoot', 'publicationFile',
        'reviewedCommit', 'reviewedTree', 'sourcesSha256',
    ]);
    const packageId = expectAddress(value.packageId, 'config.controlledFixture.packageId');
    const requestedSourceRoot = resolve(expectString(value.sourceRoot, 'config.controlledFixture.sourceRoot'));
    const requestedPublicationFile = resolve(expectString(
        value.publicationFile,
        'config.controlledFixture.publicationFile',
    ));
    const packageObjectDigest = expectString(
        value.packageObjectDigest,
        'config.controlledFixture.packageObjectDigest',
    );
    const files = controlledFixtureFiles(
        requestedSourceRoot,
        requestedPublicationFile,
        environment,
        packageId,
    );
    const { sourceRoot, publicationFile } = files;
    const repository = run('git', ['-C', sourceRoot, 'rev-parse', '--show-toplevel']).stdout.trim();
    const reviewedCommit = run('git', ['-C', repository, 'rev-parse', 'HEAD']).stdout.trim();
    const reviewedTree = run('git', ['-C', repository, 'rev-parse', 'HEAD^{tree}']).stdout.trim();
    if (reviewedCommit !== value.reviewedCommit || reviewedTree !== value.reviewedTree) {
        fail('config.controlledFixture: reviewed Git commit/tree drift');
    }
    const dirty = run('git', [
        '-C', repository, 'status', '--porcelain', '--untracked-files=all', '--', sourceRoot,
    ]).stdout.trim();
    if (dirty !== '') fail('config.controlledFixture: reviewed source tree is dirty');
    const sourcesSha256 = inputsSha256(files.entries);
    if (sourcesSha256 !== value.sourcesSha256) {
        fail('config.controlledFixture: reviewed source hash drift');
    }
    const object = expectObject(parseJson(runSui([
        'client', '--client.env', environment, 'object', packageId, '--json',
    ]).stdout, 'controlled fixture package'), 'controlled fixture package');
    if (object.digest !== packageObjectDigest) {
        fail('config.controlledFixture: deployed package digest drift');
    }
    const onChainModules = packageModules(object, 'controlled fixture package');
    const installRoot = mkdtempSync(join(tmpdir(), 'blast-controlled-health-proof-'));
    try {
        runSui([
            'client', '--client.env', environment, 'verify-source', sourceRoot,
            '--build-env', environment, '--pubfile-path', publicationFile,
            '--install-dir', installRoot, '--force', '--json',
        ]);
        const compiledModules = builtControlledModules(installRoot, files.packageName);
        assertEqual(compiledModules, onChainModules, 'controlled fixture compiled/on-chain modules');
        return canonical({
            packageId,
            packageObjectDigest,
            reviewedCommit,
            reviewedTree,
            sourcesSha256,
            compiledModules,
            onChainModules,
        });
    } finally {
        rmSync(installRoot, { recursive: true, force: true });
    }
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

function selectVaultFields(raw, vaultId, expectedType, path) {
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
    return canonical(selected);
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
    const selected = selectVaultFields(raw, vaultId, expectedType, path);
    return canonical({ raw, selected });
}

function ptbCalls(args, path) {
    for (const forbidden of [
        '--dev-inspect',
        '--dry-run',
        '--preview',
        '--serialize-unsigned-transaction',
        '--serialize-signed-transaction',
    ]) {
        if (args.includes(forbidden)) fail(`${path}: forbids ${forbidden}`);
    }
    const calls = parseMoveCalls(args, path);
    for (const call of calls) {
        if (/_tests?::|for_testing/.test(call.target)) {
            fail(`${path}: test-only call ${call.target}`);
        }
    }
    return calls;
}

function validateRunArgs(run, path) {
    expectObject(run, path, ['ptbArgs']);
    return ptbCalls(run.ptbArgs, `${path}.ptbArgs`);
}

function validateControlledFixture(value, proof, path) {
    expectObject(value, path, [
        'packageId', 'packageObjectDigest', 'sourceRoot', 'publicationFile',
        'reviewedCommit', 'reviewedTree', 'sourcesSha256',
    ]);
    const packageId = expectAddress(value.packageId, `${path}.packageId`);
    for (const key of ['packageObjectDigest', 'sourceRoot', 'publicationFile']) {
        expectString(value[key], `${path}.${key}`);
    }
    if (!/^[0-9a-f]{40}$/.test(value.reviewedCommit)) {
        fail(`${path}.reviewedCommit: expected full Git commit`);
    }
    if (!/^[0-9a-f]{40}$/.test(value.reviewedTree)) {
        fail(`${path}.reviewedTree: expected full Git tree`);
    }
    if (!/^[0-9a-f]{64}$/.test(value.sourcesSha256)) {
        fail(`${path}.sourcesSha256: expected SHA-256`);
    }
    expectObject(proof, `${path}.proof`, [
        'packageId', 'packageObjectDigest', 'reviewedCommit', 'reviewedTree',
        'sourcesSha256', 'compiledModules', 'onChainModules',
    ]);
    assertEqual({
        packageId,
        packageObjectDigest: value.packageObjectDigest,
        reviewedCommit: value.reviewedCommit,
        reviewedTree: value.reviewedTree,
        sourcesSha256: value.sourcesSha256,
    }, {
        packageId: proof.packageId,
        packageObjectDigest: proof.packageObjectDigest,
        reviewedCommit: proof.reviewedCommit,
        reviewedTree: proof.reviewedTree,
        sourcesSha256: proof.sourcesSha256,
    }, `${path}: controlled fixture package provenance`);
    assertEqual(proof.compiledModules, proof.onChainModules, `${path}.proof.modules`);
    if (!Object.hasOwn(proof.compiledModules, 'controlled_health_cases')) {
        fail(`${path}.proof: controlled_health_cases bytecode is missing`);
    }
    return packageId;
}

function validateConfigEnvelope(config) {
    expectObject(config, 'config', [
        'schemaVersion',
        'fixtureKind',
        'environment',
        'chainIdentifier',
        'adapterPackage',
        'productType',
        'controlledFixture',
        'outputPath',
        'cases',
    ]);
    if (config.schemaVersion !== 3
        || config.fixtureKind !== 'controlled-health-cases'
        || config.environment !== 'testnet'
        || config.chainIdentifier !== TESTNET_CHAIN) {
        fail('config: unsupported schema, kind, environment, or chain');
    }
}

function validateLiveConfig(config, oracleByCase, controlledFixtureProof) {
    validateConfigEnvelope(config);
    const adapterPackage = expectAddress(config.adapterPackage, 'config.adapterPackage');
    const types = eventTypes(adapterPackage, config.productType);
    const expectedVaultType = vaultType(adapterPackage, config.productType);
    const controlledFixturePackage = validateControlledFixture(
        config.controlledFixture,
        controlledFixtureProof,
        'config.controlledFixture',
    );
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
        const prepareCalls = validateRunArgs(entry.prepare, `${path}.prepare`);
        const scenarioTarget = `${controlledFixturePackage}::controlled_health_cases::prepare_${entry.name}`;
        const scenarioCalls = prepareCalls.filter((call) => call.target === scenarioTarget);
        if (scenarioCalls.length !== 1) {
            fail(`${path}.prepare: expected exactly one ${scenarioTarget} scenario call`);
        }
        if (scenarioCalls[0].arguments[0] !== `@${vaultId}`) {
            fail(`${path}.prepare: scenario call must receive the case Vault first`);
        }
        const transitionCalls = validateRunArgs(
            entry.transition,
            `${path}.transition`,
        );
        const syncTarget = `${adapterPackage}::operations::sync_health`;
        const syncCalls = transitionCalls.filter((call) => call.target === syncTarget);
        if (syncCalls.length !== 1) {
            fail(`${path}.transition: expected exactly one production ${syncTarget}`);
        }
        if (syncCalls[0].arguments[0] !== `@${vaultId}`) {
            fail(`${path}.transition: sync_health must receive the case Vault first`);
        }
    });
    return { adapterPackage, expectedVaultType, types };
}

function sampleLiveConfig(fixture) {
    const controlledPackage = `0x${'c'.repeat(64)}`;
    return {
        schemaVersion: 3,
        fixtureKind: 'controlled-health-cases',
        environment: 'testnet',
        chainIdentifier: TESTNET_CHAIN,
        adapterPackage: fixture.adapterPackage,
        productType: fixture.productType,
        controlledFixture: {
            packageId: controlledPackage,
            packageObjectDigest: 'SyntheticControlledFixtureDigest',
            sourceRoot: '/synthetic/controlled-health-fixture',
            publicationFile: '/synthetic/controlled-health-fixture/Published.toml',
            reviewedCommit: 'a'.repeat(40),
            reviewedTree: 'b'.repeat(40),
            sourcesSha256: 'c'.repeat(64),
        },
        outputPath: '/tmp/controlled-health-evidence.json',
        cases: CASE_NAMES.map((name, index) => {
            const vaultId = `0x${(index + 1).toString(16).padStart(64, '0')}`;
            return {
                name,
                vaultId,
                prepare: {
                    ptbArgs: [
                        '--move-call',
                        `${controlledPackage}::controlled_health_cases::prepare_${name}`,
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

function sampleControlledFixtureProof(config) {
    const value = config.controlledFixture;
    return {
        packageId: value.packageId,
        packageObjectDigest: value.packageObjectDigest,
        reviewedCommit: value.reviewedCommit,
        reviewedTree: value.reviewedTree,
        sourcesSha256: value.sourcesSha256,
        compiledModules: { controlled_health_cases: 'synthetic' },
        onChainModules: { controlled_health_cases: 'synthetic' },
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
    validateConfigEnvelope(config);
    const fixture = readJson(FIXTURE_PATH);
    const { oracleByCase } = validateFixture(fixture);
    const controlledFixtureProof = verifyControlledFixture(
        config.environment,
        config.controlledFixture,
    );
    const { adapterPackage, expectedVaultType, types } = validateLiveConfig(
        config,
        oracleByCase,
        controlledFixtureProof,
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
        const stored = snapshotVault(
            config.environment,
            entry.vaultId,
            expectedVaultType,
            `${path}.stored`,
        );
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
            stored: stored.selected,
            pre: pre.selected,
            post: post.selected,
            events: protocolEvents,
        }, oracleByCase.get(entry.name), types, entry.vaultId, path);
        evidence.push(canonical({
            name: entry.name,
            preparation,
            transition,
            stored,
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
        controlledFixtureProof,
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
