#!/usr/bin/env node
// Builds the reviewed activation PTB and validates only standard Sui
// dev-inspect command results, effects, and typed events.

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
const INITIALIZED_FIELDS = [
    'vault_id',
    'account_object_id',
    'account_number',
    'registry_id',
    'clearing_house_id',
    'base_oracle_id',
    'collateral_oracle_id',
    'collateral_type',
    'seed_amount',
    'seed_venue_equity',
    'seed_reserve',
    'seed_shareholder_nav',
    'locked_shares',
    'absolute_base',
    'absolute_notional',
    'lot_size',
    'position_side',
    'position_imr',
    'checkpoint',
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
    '// BLAST_ACTIVATION_BOUNDARY_A1',
    'vault.mint_locked_shares(',
    '// BLAST_ACTIVATION_BOUNDARY_A2',
    'venue_account::new(admin_cap, binding, checkpoint)',
    '// BLAST_ACTIVATION_BOUNDARY_A3',
    'account::consume_policy_and_share_account(account, share_policy)',
    '// BLAST_ACTIVATION_BOUNDARY_A4',
    'vault.install_venue_account(venue_account)',
    '// BLAST_ACTIVATION_BOUNDARY_A5',
    'clearing_house::share(clearing_house)',
    '// BLAST_ACTIVATION_BOUNDARY_A6',
    'emit_vault_initialized<Product>(',
    '// BLAST_ACTIVATION_BOUNDARY_A7',
];
const EFFECT_LISTS = [
    'created',
    'mutated',
    'unwrapped',
    'deleted',
    'unwrappedThenDeleted',
    'wrapped',
];

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

function expectStringList(value, path) {
    if (!Array.isArray(value) || value.some((item) => typeof item !== 'string')) {
        fail(`${path}: expected string list`);
    }
    return value;
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

function productType(adapterPackage, tagType) {
    return `${adapterPackage}::product::Product<${tagType}>`;
}

function validateCall(call, path) {
    expectObject(call, path, ['target', 'type', 'typeArguments', 'arguments']);
    expectString(call.target, `${path}.target`);
    expectString(call.type, `${path}.type`);
    expectStringList(call.typeArguments, `${path}.typeArguments`);
    expectStringList(call.arguments, `${path}.arguments`);
}

function buildPlan(input) {
    expectObject(input, 'builderInput', [
        'sender',
        'adapterPackage',
        'productTagType',
        'riskWitness',
        'collateralType',
        'objects',
        'seedReserve',
        'positionImr',
    ]);
    const adapterPackage = expectAddress(
        input.adapterPackage,
        'builderInput.adapterPackage',
    );
    expectAddress(input.sender, 'builderInput.sender');
    expectString(input.productTagType, 'builderInput.productTagType');
    validateCall(input.riskWitness, 'builderInput.riskWitness');
    expectString(input.collateralType, 'builderInput.collateralType');
    expectString(input.seedReserve, 'builderInput.seedReserve');
    expectString(input.positionImr, 'builderInput.positionImr');
    expectObject(input.objects, 'builderInput.objects', OBJECT_ROLES);
    for (const role of OBJECT_ROLES) {
        expectAddress(input.objects[role], `builderInput.objects.${role}`);
    }

    return {
        commands: [
            {
                target: input.riskWitness.target,
                typeArguments: input.riskWitness.typeArguments,
                arguments: input.riskWitness.arguments,
                assign: 'risk_module',
            },
            {
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

function verifyProductionPhaseOrder() {
    const source = readFileSync(OPERATIONS_PATH, 'utf8');
    const start = source.indexOf('public fun initialize<');
    const end = source.indexOf(
        '/// Reconciles one bound Aftermath checkpoint',
        start,
    );
    if (start < 0 || end < 0) {
        fail('operations.move: initialize body is unavailable');
    }
    const body = source.slice(start, end);
    let cursor = 0;
    for (const marker of PHASE_MARKERS) {
        const occurrences = body.split(marker).length - 1;
        if (occurrences !== 1 && marker.startsWith('// BLAST_')) {
            fail(`operations.move: ${marker} must occur exactly once`);
        }
        const next = body.indexOf(marker, cursor);
        if (next < 0) {
            fail(`operations.move: activation phase missing or reordered at ${marker}`);
        }
        cursor = next + marker.length;
    }
}

function effectBody(raw) {
    const effects = expectObject(raw, 'devInspect.effects');
    if (effects.V1 !== undefined || effects.V2 !== undefined) {
        const variants = ['V1', 'V2'].filter((key) => effects[key] !== undefined);
        if (variants.length !== 1) fail('devInspect.effects: expected one version');
        return expectObject(effects[variants[0]], `devInspect.effects.${variants[0]}`);
    }
    return effects;
}

function effectReference(entry, path) {
    if (typeof entry === 'string') return { objectId: entry };
    const value = expectObject(entry, path);
    const reference = value.reference ?? value.ref ?? value;
    const ref = expectObject(reference, `${path}.reference`);
    const objectId = ref.objectId ?? ref.object_id;
    if (typeof objectId !== 'string') fail(`${path}: missing object id`);
    const normalized = { objectId };
    if (ref.version !== undefined) normalized.version = String(ref.version);
    if (ref.digest !== undefined) normalized.digest = ref.digest;
    if (value.owner !== undefined) normalized.owner = value.owner;
    return canonical(normalized);
}

function normalizeResult(result, path) {
    const value = expectObject(result, path);
    const mutableReferenceOutputs = value.mutableReferenceOutputs
        ?? value.mutable_reference_outputs;
    const returnValues = value.returnValues ?? value.return_values;
    if (!Array.isArray(mutableReferenceOutputs) || !Array.isArray(returnValues)) {
        fail(`${path}: expected standard mutableReferenceOutputs and returnValues`);
    }
    return canonical({ mutableReferenceOutputs, returnValues });
}

function initializedEventType(input) {
    return `${input.adapterPackage}::events::VaultInitialized<${productType(
        input.adapterPackage,
        input.productTagType,
    )}>`;
}

function normalizeInitializedEvent(events, input) {
    if (!Array.isArray(events)) fail('devInspect.events: expected list');
    const expectedType = initializedEventType(input);
    const matches = events.filter((event) => event?.type === expectedType);
    if (matches.length !== 1) {
        fail(`devInspect.events: expected exactly one ${expectedType}, got ${matches.length}`);
    }
    const event = expectObject(matches[0], 'VaultInitialized');
    const parsedJson = expectObject(
        event.parsedJson ?? event.parsed_json,
        'VaultInitialized.parsedJson',
        INITIALIZED_FIELDS,
    );
    expectObject(parsedJson.checkpoint, 'VaultInitialized.checkpoint', CHECKPOINT_FIELDS);
    if (String(parsedJson.vault_id).toLowerCase() !== input.objects.vault) {
        fail('VaultInitialized.vault_id: does not match the initialized Vault');
    }
    return canonical({ type: event.type, parsedJson });
}

function normalizeDevInspect(response, input, plan, objectTypes) {
    expectObject(response, 'devInspect');
    const effects = effectBody(response.effects);
    const status = effects.status?.status ?? effects.status;
    if (String(status).toLowerCase() !== 'success') {
        fail(`devInspect.effects.status: expected success, got ${status}`);
    }
    if (!Array.isArray(response.results)) {
        fail('devInspect.results: expected standard command result list');
    }
    if (response.results.length !== plan.commands.length) {
        fail(`devInspect.results: expected ${plan.commands.length} command results, got ${response.results.length}`);
    }
    const commandResults = response.results.map((result, index) =>
        normalizeResult(result, `devInspect.results[${index}]`));
    const normalizedEffects = {};
    for (const name of EFFECT_LISTS) {
        const entries = effects[name] ?? effects[name.replace(/[A-Z]/g, (c) => `_${c.toLowerCase()}`)] ?? [];
        if (!Array.isArray(entries)) fail(`devInspect.effects.${name}: expected list`);
        normalizedEffects[name] = entries.map((entry, index) =>
            effectReference(entry, `devInspect.effects.${name}[${index}]`));
    }
    return canonical({
        status: 'success',
        commandResults,
        effects: normalizedEffects,
        vaultInitialized: normalizeInitializedEvent(response.events, input),
        objectTypes,
    });
}

function validateFixture(fixture) {
    expectObject(fixture, 'fixture', [
        'schemaVersion',
        'fixtureKind',
        'network',
        'builderInput',
        'expectedPlan',
        'expectedPtbArgs',
        'rawDevInspectResponse',
        'expectedObservation',
        'objectTypes',
    ]);
    if (fixture.schemaVersion !== 2
        || fixture.fixtureKind !== 'standard-sui-dev-inspect') {
        fail('fixture: unsupported schema or kind');
    }
    expectObject(fixture.network, 'fixture.network', [
        'environment',
        'chainIdentifier',
    ]);
    if (fixture.network.environment !== 'mainnet'
        || fixture.network.chainIdentifier !== MAINNET_CHAIN) {
        fail('fixture.network: mainnet identity drift');
    }
    expectObject(fixture.objectTypes, 'fixture.objectTypes', OBJECT_ROLES);
    const plan = buildPlan(fixture.builderInput);
    assertEqual(plan, fixture.expectedPlan, 'expectedPlan');
    assertEqual(
        renderPtbArgs(fixture.builderInput, plan),
        fixture.expectedPtbArgs,
        'expectedPtbArgs',
    );
    const observed = normalizeDevInspect(
        fixture.rawDevInspectResponse,
        fixture.builderInput,
        plan,
        fixture.objectTypes,
    );
    assertEqual(observed, fixture.expectedObservation, 'expectedObservation');
    verifyProductionPhaseOrder();
    return { plan, observed };
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
    const { plan } = validateFixture(fixture);
    let passed = 2;

    const malformedResults = structuredClone(fixture.rawDevInspectResponse);
    malformedResults.results.pop();
    expectFailure('command results', () => normalizeDevInspect(
        malformedResults,
        fixture.builderInput,
        plan,
        fixture.objectTypes,
    ));
    passed += 1;

    const wrongType = structuredClone(fixture.objectTypes);
    wrongType.vault = wrongType.protocol;
    expectFailure('objectTypes', () => assertEqual(
        wrongType,
        fixture.objectTypes,
        'objectTypes',
    ));
    passed += 1;

    const wrongEvent = structuredClone(fixture.rawDevInspectResponse);
    wrongEvent.events[0].parsedJson.absolute_notional = '100000001';
    expectFailure('absolute_notional', () => assertEqual(
        normalizeDevInspect(
            wrongEvent,
            fixture.builderInput,
            plan,
            fixture.objectTypes,
        ),
        fixture.expectedObservation,
        'observation',
    ));
    passed += 1;

    const duplicateEvent = structuredClone(fixture.rawDevInspectResponse);
    duplicateEvent.events.push(structuredClone(duplicateEvent.events[0]));
    expectFailure('exactly one', () => normalizeDevInspect(
        duplicateEvent,
        fixture.builderInput,
        plan,
        fixture.objectTypes,
    ));
    passed += 1;

    const missingShape = structuredClone(fixture.rawDevInspectResponse);
    delete missingShape.results[0].returnValues;
    expectFailure('standard mutableReferenceOutputs', () => normalizeDevInspect(
        missingShape,
        fixture.builderInput,
        plan,
        fixture.objectTypes,
    ));
    passed += 1;

    process.stdout.write(`dev_inspect_activation self-test: PASS ${passed}/7 cases\n`);
}

function runSui(args) {
    try {
        return execFileSync('sui', args, {
            cwd: PACKAGE_DIR,
            encoding: 'utf8',
            stdio: ['ignore', 'pipe', 'pipe'],
        });
    } catch (error) {
        const detail = `${error.stdout ?? ''}${error.stderr ?? ''}`.trim();
        fail(`sui ${args.slice(0, 4).join(' ')} failed: ${detail || error.message}`);
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

function parseObject(output, role) {
    const object = expectObject(parseJson(output, role), role);
    return {
        id: expectAddress(object.objectId, `${role}.objectId`),
        type: expectString(object.objType, `${role}.objType`),
    };
}

function live(configPath) {
    if (!configPath) {
        fail('live mainnet proof requires --config <public-object-config.json> or BLAST_ACTIVATION_CONFIG; no deployed Blast activation objects are recorded');
    }
    const config = readJson(resolve(configPath));
    expectObject(config, 'config', [
        'schemaVersion',
        'fixtureKind',
        'builderInput',
        'objectTypes',
        'expectedObservation',
    ]);
    if (config.schemaVersion !== 2
        || config.fixtureKind !== 'live-mainnet-dev-inspect') {
        fail('config: unsupported schema or kind');
    }
    const plan = buildPlan(config.builderInput);
    verifyProductionPhaseOrder();
    const chain = parseChainIdentifier(runSui([
        'client',
        '--client.env',
        'mainnet',
        'chain-identifier',
    ]));
    if (chain !== MAINNET_CHAIN) {
        fail(`mainnet chain mismatch: expected ${MAINNET_CHAIN}, got ${chain}`);
    }

    expectObject(config.objectTypes, 'config.objectTypes', OBJECT_ROLES);
    const objectTypes = {};
    for (const role of OBJECT_ROLES) {
        const observed = parseObject(runSui([
            'client',
            '--client.env',
            'mainnet',
            'object',
            config.builderInput.objects[role],
            '--json',
        ]), role);
        const expectedType = expectString(
            config.objectTypes[role],
            `config.objectTypes.${role}`,
        );
        if (observed.type !== expectedType) {
            fail(`${role}: expected object type ${expectedType}, got ${observed.type}`);
        }
        objectTypes[role] = observed.type;
    }

    const response = parseJson(
        runSui(renderPtbArgs(config.builderInput, plan)),
        'devInspect',
    );
    const observed = normalizeDevInspect(
        response,
        config.builderInput,
        plan,
        objectTypes,
    );
    assertEqual(observed, config.expectedObservation, 'liveObservation');
    process.stdout.write('dev_inspect_activation: PASS mainnet read-only activation\n');
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
            config: process.env.BLAST_ACTIVATION_CONFIG ?? null,
        };
    }
    fail('usage: dev_inspect_activation.mjs [--self-test|--config <path>]');
}

try {
    const args = parseArgs(process.argv.slice(2));
    if (args.selfTest) selfTest(); else live(args.config);
} catch (error) {
    process.stderr.write(`dev_inspect_activation: FAIL ${error.message}\n`);
    process.exitCode = 1;
}
