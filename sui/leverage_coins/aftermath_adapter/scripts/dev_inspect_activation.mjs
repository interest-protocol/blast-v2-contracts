#!/usr/bin/env node
// Builds and checks the read-only activation PTB. Live evidence is never
// inferred from fixture values: the Sui response and object reads must supply it.

import { execFileSync } from 'node:child_process';
import { readFileSync } from 'node:fs';
import { dirname, join, resolve } from 'node:path';
import { fileURLToPath } from 'node:url';
import process from 'node:process';

const SCRIPT_DIR = dirname(fileURLToPath(import.meta.url));
const PACKAGE_DIR = join(SCRIPT_DIR, '..');
const FIXTURE_PATH = join(SCRIPT_DIR, 'fixtures', 'activation-vectors.json');
const OPERATIONS_PATH = join(PACKAGE_DIR, 'sources', 'operations.move');
const MAINNET_CHAIN = '4btiuiMPvEENsttpZC7CZ53DruC3MAgfznDbASZ7DR6S';
const OBJECT_ROLES = [
    'vault',
    'protocol',
    'currency',
    'registry',
    'clearingHouse',
    'baseOracle',
    'collateralOracle',
    'basePriceInfo',
    'collateralPriceInfo',
    'seedCoin',
    'clock',
];
const REQUIRED_CASES = [
    'long', 'short', 'flat', 'positive_pnl', 'negative_pnl',
    'funding_credit', 'funding_cost', 'repeated_funding',
    'partial_liquidation', 'adl_settlement', 'collateral_movement',
    'pending_order', 'pause', 'freeze', 'stale_oracle', 'collateral_depeg',
];
const PHASE_ORDER = [
    'account.create',
    'collateral.deposit',
    'collateral.allocate',
    'position.create',
    'position.set_imr',
    'snapshot.pre',
    'session.start',
    'session.multi_order',
    'session.end',
    'funding.settle',
    'snapshot.final',
    'series.activate',
    'shares.lock',
    'venue_account.seal',
    'account.share',
    'venue_account.install',
    'clearing_house.share',
    'event.vault_initialized',
];
const PHASE_MARKERS = [
    'account::create_account<Collateral>',
    'account::deposit_collateral(',
    'clearing_house::allocate_collateral(',
    'clearing_house::create_market_position(',
    'clearing_house::set_position_initial_margin_ratio(',
    'snapshot::capture_initialization(',
    'clearing_house::start_session(',
    'clearing_house::place_market_order(',
    'clearing_house::end_session(',
    'clearing_house::settle_position_funding(',
    'snapshot::capture_initialization(',
    'vault.initialize_series(',
    'vault.mint_locked_shares(',
    'venue_account::new(admin_cap, binding, checkpoint)',
    'account::consume_policy_and_share_account(account, share_policy)',
    'vault.install_venue_account(venue_account)',
    'clearing_house::share(clearing_house)',
    'emit_vault_initialized<Product>(',
];

function fail(message) {
    throw new Error(message);
}

function readJson(path) {
    let value;
    try {
        value = JSON.parse(readFileSync(path, 'utf8'));
    } catch (error) {
        fail(`${path}: ${error.message}`);
    }
    return value;
}

function expectObject(value, path, keys) {
    if (value === null || typeof value !== 'object' || Array.isArray(value)) {
        fail(`${path}: expected object`);
    }
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

function expectAddress(value, path) {
    const address = expectString(value, path);
    if (!/^0x[0-9a-fA-F]{64}$/.test(address)) fail(`${path}: expected canonical 32-byte address`);
    return address.toLowerCase();
}

function expectDecimal(value, path) {
    const decimal = expectString(value, path);
    if (!/^(0|[1-9][0-9]*)$/.test(decimal)) fail(`${path}: expected canonical unsigned decimal string`);
    return decimal;
}

function productType(adapterPackage, tagType) {
    return `${adapterPackage}::product::Product<${tagType}>`;
}

function buildPlan(input) {
    const fields = [
        'sender', 'adapterPackage', 'productTagType', 'riskWitness',
        'collateralType', 'objects', 'seedReserve', 'positionImr',
    ];
    expectObject(input, 'builderInput', fields);
    const adapterPackage = expectAddress(input.adapterPackage, 'builderInput.adapterPackage');
    expectAddress(input.sender, 'builderInput.sender');
    expectString(input.productTagType, 'builderInput.productTagType');
    expectObject(input.riskWitness, 'builderInput.riskWitness', [
        'target', 'type', 'typeArguments', 'arguments',
    ]);
    expectString(input.riskWitness.target, 'builderInput.riskWitness.target');
    expectString(input.riskWitness.type, 'builderInput.riskWitness.type');
    if (!Array.isArray(input.riskWitness.typeArguments)
        || input.riskWitness.typeArguments.some((item) => typeof item !== 'string')) {
        fail('builderInput.riskWitness.typeArguments: expected string list');
    }
    if (!Array.isArray(input.riskWitness.arguments)
        || input.riskWitness.arguments.some((item) => typeof item !== 'string')) {
        fail('builderInput.riskWitness.arguments: expected string list');
    }
    expectString(input.collateralType, 'builderInput.collateralType');
    expectDecimal(input.seedReserve, 'builderInput.seedReserve');
    expectDecimal(input.positionImr, 'builderInput.positionImr');
    expectObject(input.objects, 'builderInput.objects', OBJECT_ROLES);
    for (const role of OBJECT_ROLES) expectAddress(input.objects[role], `builderInput.objects.${role}`);

    return {
        commands: [
            {
                index: 0,
                target: input.riskWitness.target,
                typeArguments: input.riskWitness.typeArguments,
                arguments: input.riskWitness.arguments,
                assign: 'risk_module',
            },
            {
                index: 1,
                target: `${adapterPackage}::operations::initialize`,
                typeArguments: [
                    productType(adapterPackage, input.productTagType),
                    input.riskWitness.type,
                    input.collateralType,
                ],
                arguments: [
                    `@${input.objects.vault}`,
                    `@${input.objects.protocol}`,
                    'risk_module',
                    `@${input.objects.currency}`,
                    `@${input.objects.registry}`,
                    `@${input.objects.clearingHouse}`,
                    `@${input.objects.baseOracle}`,
                    `@${input.objects.collateralOracle}`,
                    `@${input.objects.basePriceInfo}`,
                    `@${input.objects.collateralPriceInfo}`,
                    `@${input.objects.seedCoin}`,
                    input.seedReserve,
                    input.positionImr,
                    `@${input.objects.clock}`,
                ],
                assign: null,
            },
        ],
        phaseOrder: [...PHASE_ORDER],
    };
}

function renderPtbArgs(input, plan) {
    const args = ['client', '--client.env', 'mainnet', 'ptb'];
    for (const command of plan.commands) {
        args.push('--move-call', command.target);
        if (command.typeArguments.length > 0) {
            args.push(`<${command.typeArguments.join(',')}>`);
        }
        args.push(...command.arguments);
        if (command.assign !== null) args.push('--assign', command.assign);
    }
    args.push('--dev-inspect', '--sender', `@${input.sender}`, '--json');
    return args;
}

function assertEqual(actual, expected, path = 'value') {
    if (actual === null || expected === null || typeof actual !== 'object' || typeof expected !== 'object') {
        if (actual !== expected) fail(`${path}: expected ${JSON.stringify(expected)}, got ${JSON.stringify(actual)}`);
        return;
    }
    if (Array.isArray(actual) !== Array.isArray(expected)) fail(`${path}: collection shape mismatch`);
    const actualKeys = Object.keys(actual).sort();
    const expectedKeys = Object.keys(expected).sort();
    if (JSON.stringify(actualKeys) !== JSON.stringify(expectedKeys)) fail(`${path}: field or result count mismatch`);
    for (const key of expectedKeys) assertEqual(actual[key], expected[key], `${path}.${key}`);
}

function validateCheckpointCases(cases) {
    if (!Array.isArray(cases)) fail('checkpointCases: expected list');
    const names = cases.map((entry, index) => {
        const item = expectObject(entry, `checkpointCases[${index}]`, [
            'name', 'materialCheckpointTransition', 'checkpointChanged', 'classification', 'health',
        ]);
        if (typeof item.materialCheckpointTransition !== 'boolean' || typeof item.checkpointChanged !== 'boolean') {
            fail(`checkpointCases[${index}]: transition flags must be booleans`);
        }
        if (item.materialCheckpointTransition && !item.checkpointChanged) {
            fail(`checkpointCases.${item.name}: material venue transition left the checkpoint unchanged`);
        }
        if (!['unchanged', 'funding_credit', 'funding_cost', 'unexpected'].includes(item.classification)) {
            fail(`checkpointCases.${item.name}: unknown classification ${item.classification}`);
        }
        if (!['active', 'reduce_only'].includes(item.health)) fail(`checkpointCases.${item.name}: unknown health ${item.health}`);
        return expectString(item.name, `checkpointCases[${index}].name`);
    });
    if (new Set(names).size !== names.length) fail('checkpointCases: duplicate case');
    assertEqual([...names].sort(), [...REQUIRED_CASES].sort(), 'checkpointCases.names');
}

function validateFixture(fixture) {
    expectObject(fixture, 'fixture', [
        'schemaVersion', 'fixtureKind', 'network', 'builderInput', 'expectedPlan',
        'expectedPtbArgs', 'expectedObservation', 'mockObservation',
        'checkpointCases',
    ]);
    if (fixture.schemaVersion !== 1 || fixture.fixtureKind !== 'offline-comparator-test') fail('fixture: unsupported schema or kind');
    expectObject(fixture.network, 'fixture.network', ['environment', 'chainIdentifier']);
    if (fixture.network.environment !== 'mainnet' || fixture.network.chainIdentifier !== MAINNET_CHAIN) fail('fixture.network: mainnet identity drift');
    const plan = buildPlan(fixture.builderInput);
    assertEqual(plan, fixture.expectedPlan, 'expectedPlan');
    assertEqual(
        renderPtbArgs(fixture.builderInput, plan),
        fixture.expectedPtbArgs,
        'expectedPtbArgs',
    );
    assertEqual(fixture.mockObservation, fixture.expectedObservation, 'observation');
    validateCheckpointCases(fixture.checkpointCases);
    verifyProductionPhaseOrder();
    return plan;
}

function verifyProductionPhaseOrder() {
    const source = readFileSync(OPERATIONS_PATH, 'utf8');
    const start = source.indexOf('public fun initialize<');
    const end = source.indexOf('/// Reconciles one bound Aftermath checkpoint', start);
    if (start < 0 || end < 0) fail('operations.move: initialize body is unavailable');
    const body = source.slice(start, end);
    let cursor = 0;
    for (const marker of PHASE_MARKERS) {
        const next = body.indexOf(marker, cursor);
        if (next < 0) fail(`operations.move: activation phase missing or reordered at ${marker}`);
        cursor = next + marker.length;
    }
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
    let passed = 2;

    const malformed = structuredClone(fixture.mockObservation);
    malformed.commandResultCount += 1;
    expectFailure('commandResultCount', () => assertEqual(malformed, fixture.expectedObservation, 'observation'));
    passed += 1;

    const wrongType = structuredClone(fixture.mockObservation);
    wrongType.objectTypes.vault = wrongType.objectTypes.protocol;
    expectFailure('objectTypes.vault', () => assertEqual(wrongType, fixture.expectedObservation, 'observation'));
    passed += 1;

    const oneUnit = structuredClone(fixture.mockObservation);
    oneUnit.normalized.absoluteNotional = '100000001';
    expectFailure('absoluteNotional', () => assertEqual(oneUnit, fixture.expectedObservation, 'observation'));
    passed += 1;

    const externalMutation = structuredClone(fixture.checkpointCases);
    externalMutation.find((entry) => entry.name === 'partial_liquidation').checkpointChanged = false;
    expectFailure('material venue transition left the checkpoint unchanged', () => validateCheckpointCases(externalMutation));
    passed += 1;

    process.stdout.write(`dev_inspect_activation self-test: PASS ${passed}/6 cases\n`);
}

function runSui(args) {
    try {
        return execFileSync('sui', args, { cwd: PACKAGE_DIR, encoding: 'utf8', stdio: ['ignore', 'pipe', 'pipe'] });
    } catch (error) {
        const detail = `${error.stdout ?? ''}${error.stderr ?? ''}`.trim();
        fail(`sui ${args.slice(0, 4).join(' ')} failed: ${detail || error.message}`);
    }
}

function parseChainIdentifier(output) {
    const match = /^Base58:\s+(\S+)$/m.exec(output);
    if (!match) fail('sui chain-identifier: missing Base58 chain identity');
    return match[1];
}

function parseObject(output, role) {
    let object;
    try { object = JSON.parse(output); } catch { fail(`${role}: sui object response is not JSON`); }
    expectObject(object, role, ['objectId', 'version', 'digest', 'objType', 'owner', 'prevTx', 'storageRebate', 'content']);
    return { id: expectAddress(object.objectId, `${role}.objectId`), type: expectString(object.objType, `${role}.objType`) };
}

function parseDevInspect(output, objectTypes) {
    let response;
    try { response = JSON.parse(output); } catch {
        const status = /execution status:\s*success/i.test(output) && /status:\s*Success/.test(output);
        if (status) {
            fail('dev-inspect succeeded, but this Sui CLI did not expose canonical JSON results; status-only output cannot prove normalization');
        }
        fail('dev-inspect response is not canonical JSON');
    }
    if (response === null) fail('dev-inspect returned null instead of canonical results');
    const status = response.effects?.status?.status ?? response.effects?.status;
    const results = response.results;
    if (status !== 'success' || !Array.isArray(results)) fail('dev-inspect did not return successful command results');
    if (response.normalized === undefined) {
        fail('dev-inspect response has no decoded normalized activation fields; a deployed observer or BCS decoder is required');
    }
    return {
        status,
        commandResultCount: results.length,
        objectTypes,
        normalized: response.normalized,
    };
}

function live(configPath) {
    if (!configPath) {
        fail('live mainnet proof requires --config <public-object-config.json> or BLAST_ACTIVATION_CONFIG; no deployed Blast activation objects are recorded');
    }
    const config = readJson(resolve(configPath));
    expectObject(config, 'config', ['schemaVersion', 'fixtureKind', 'builderInput', 'objectTypes', 'expectedObservation']);
    if (config.schemaVersion !== 1 || config.fixtureKind !== 'live-mainnet-dev-inspect') fail('config: unsupported schema or kind');
    const plan = buildPlan(config.builderInput);
    verifyProductionPhaseOrder();

    const chain = parseChainIdentifier(runSui(['client', '--client.env', 'mainnet', 'chain-identifier']));
    if (chain !== MAINNET_CHAIN) fail(`mainnet chain mismatch: expected ${MAINNET_CHAIN}, got ${chain}`);

    expectObject(config.objectTypes, 'config.objectTypes', OBJECT_ROLES);
    const objectTypes = {};
    for (const role of OBJECT_ROLES) {
        const observed = parseObject(runSui(['client', '--client.env', 'mainnet', 'object', config.builderInput.objects[role], '--json']), role);
        const expectedType = expectString(config.objectTypes[role], `config.objectTypes.${role}`);
        if (observed.type !== expectedType) fail(`${role}: expected object type ${expectedType}, got ${observed.type}`);
        objectTypes[role] = observed.type;
    }

    const observed = parseDevInspect(runSui(renderPtbArgs(config.builderInput, plan)), objectTypes);
    assertEqual(observed, config.expectedObservation, 'liveObservation');
    process.stdout.write('dev_inspect_activation: PASS mainnet read-only activation\n');
}

function parseArgs(args) {
    if (args.length === 1 && args[0] === '--self-test') return { selfTest: true, config: null };
    if (args.length === 2 && args[0] === '--config') return { selfTest: false, config: args[1] };
    if (args.length === 0) return { selfTest: false, config: process.env.BLAST_ACTIVATION_CONFIG ?? null };
    fail('usage: dev_inspect_activation.mjs [--self-test|--config <path>]');
}

try {
    const args = parseArgs(process.argv.slice(2));
    if (args.selfTest) selfTest(); else live(args.config);
} catch (error) {
    process.stderr.write(`dev_inspect_activation: FAIL ${error.message}\n`);
    process.exitCode = 1;
}
