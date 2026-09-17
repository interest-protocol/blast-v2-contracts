#!/usr/bin/env node
// Serializes the reviewed activation PTB, dev-inspects that exact transaction,
// and validates only standard Sui machine-readable results, effects, and events.

import { execFileSync } from 'node:child_process';
import { createHash } from 'node:crypto';
import { readFileSync } from 'node:fs';
import { dirname, join, resolve } from 'node:path';
import { fileURLToPath } from 'node:url';
import process from 'node:process';

const SCRIPT_DIR = dirname(fileURLToPath(import.meta.url));
const PACKAGE_DIR = join(SCRIPT_DIR, '..');
const FIXTURE_PATH = join(SCRIPT_DIR, 'fixtures', 'activation-vectors.json');
const PINNED_SURFACE_FIXTURE_PATH = join(
    SCRIPT_DIR,
    'fixtures',
    'sui-1.77.2-serialized-tx-dev-inspect.json',
);
const OPERATIONS_PATH = join(PACKAGE_DIR, 'sources', 'operations.move');
const MAINNET_CHAIN = '4btiuiMPvEENsttpZC7CZ53DruC3MAgfznDbASZ7DR6S';
const PINNED_SUI_VERSION = '1.77.2-51d177ad7d65';
const PINNED_SURFACE_TRANSACTION = 'AAAAAQAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAgp0eF9jb250ZXh0BnNlbmRlcgAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAKEc4AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAKEc7oAwAAAAAAAAAgPYh5LQAAAA==';
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
    'seed_funder',
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

function wrappedEventType(adapterPackage, payloadType) {
    return `${adapterPackage}::blast_events::Event<${payloadType}>`;
}

function unwrapEventPayload(value, path) {
    const wrapper = expectObject(value, path, ['pos0']);
    return expectObject(wrapper.pos0, `${path}.pos0`);
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
        'seedFunder',
        'positionImr',
    ]);
    const adapterPackage = expectAddress(
        input.adapterPackage,
        'builderInput.adapterPackage',
    );
    expectAddress(input.sender, 'builderInput.sender');
    expectAddress(input.seedFunder, 'builderInput.seedFunder');
    if (BigInt(input.seedFunder) === 0n) fail('seedFunder must not be zero');
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
                    `@${input.seedFunder}`,
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
    args.push(
        '--serialize-unsigned-transaction',
        '--sender',
        `@${input.sender}`,
    );
    return args;
}

function renderSerializedInspectArgs(environment, transactionData) {
    return [
        'client',
        '--client.env',
        environment,
        'serialized-tx',
        transactionData,
        '--dev-inspect',
        '--json',
    ];
}

function parseSerializedTransaction(output, path) {
    const value = output.trim();
    if (!/^(?:[A-Za-z0-9+/]{4})*(?:[A-Za-z0-9+/]{2}==|[A-Za-z0-9+/]{3}=)?$/.test(value)) {
        fail(`${path}: expected one canonical base64 TransactionData line`);
    }
    const bytes = Buffer.from(value, 'base64');
    if (bytes.length === 0 || bytes.toString('base64') !== value) {
        fail(`${path}: invalid base64 TransactionData`);
    }
    return value;
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

function normalizeResult(result, path) {
    const value = expectObject(result, path);
    const mutableReferenceOutputs = value.mutatedByRef
        ?? value.mutated_by_ref
        ?? value.mutableReferenceOutputs
        ?? value.mutable_reference_outputs
        ?? [];
    const returnValues = value.returnValues ?? value.return_values ?? [];
    if (!Array.isArray(mutableReferenceOutputs) || !Array.isArray(returnValues)) {
        fail(`${path}: expected standard mutableReferenceOutputs and returnValues`);
    }
    return canonical({ mutableReferenceOutputs, returnValues });
}

function normalizeEvents(transaction, path) {
    const eventJson = transaction.event_json;
    if (!Array.isArray(eventJson)) {
        fail(`${path}.event_json: expected standard parsed-event list`);
    }
    if (transaction.events === null) {
        if (eventJson.length !== 0) fail(`${path}: event_json exists without events`);
        return [];
    }
    const events = expectObject(transaction.events, `${path}.events`);
    if (!Array.isArray(events.data) || events.data.length !== eventJson.length) {
        fail(`${path}: raw and parsed event cardinality mismatch`);
    }
    return events.data.map((event, index) => {
        const raw = expectObject(event, `${path}.events.data[${index}]`);
        const type = raw.type_ ?? raw.type;
        expectString(type, `${path}.events.data[${index}].type_`);
        return canonical({
            type,
            parsedJson: expectObject(
                eventJson[index],
                `${path}.event_json[${index}]`,
            ),
        });
    });
}

function normalizeSimulationResponse(response, path = 'devInspect') {
    expectObject(response, path, [
        'transaction',
        'command_outputs',
        'suggested_gas_price',
    ]);
    const transaction = expectObject(response.transaction, `${path}.transaction`);
    const effects = expectObject(transaction.effects, `${path}.transaction.effects`);
    const events = normalizeEvents(transaction, `${path}.transaction`);
    const changedObjects = transaction.changed_objects;
    if (!Array.isArray(changedObjects)) {
        fail(`${path}.transaction.changed_objects: expected standard changed-object list`);
    }
    if (!Array.isArray(response.command_outputs)) {
        fail(`${path}.command_outputs: expected standard command-output list`);
    }
    return {
        effects,
        events,
        changedObjects: canonical(changedObjects),
        commandResults: response.command_outputs.map((result, index) =>
            normalizeResult(result, `${path}.command_outputs[${index}]`)),
        suggestedGasPrice: response.suggested_gas_price,
        transaction,
    };
}

function initializedEventType(input) {
    return wrappedEventType(
        input.adapterPackage,
        `${input.adapterPackage}::events::VaultInitialized<${productType(
            input.adapterPackage,
            input.productTagType,
        )}>`,
    );
}

function normalizeInitializedEvent(events, input) {
    if (!Array.isArray(events)) fail('devInspect.events: expected list');
    const expectedType = initializedEventType(input);
    const matches = events.filter((event) => event?.type === expectedType);
    if (matches.length !== 1) {
        fail(`devInspect.events: expected exactly one ${expectedType}, got ${matches.length}`);
    }
    const event = expectObject(matches[0], 'VaultInitialized');
    const parsedJson = unwrapEventPayload(
        event.parsedJson ?? event.parsed_json,
        'VaultInitialized.parsedJson',
    );
    expectObject(parsedJson, 'VaultInitialized.parsedJson.pos0', INITIALIZED_FIELDS);
    expectObject(parsedJson.checkpoint, 'VaultInitialized.checkpoint', CHECKPOINT_FIELDS);
    if (String(parsedJson.vault_id).toLowerCase() !== input.objects.vault) {
        fail('VaultInitialized.vault_id: does not match the initialized Vault');
    }
    assertEqual(expectAddress(parsedJson.seed_funder, 'VaultInitialized.seed_funder'),
        input.seedFunder, 'VaultInitialized.seed_funder');
    return canonical({ type: event.type, parsedJson });
}

function normalizeDevInspect(response, input, plan, objectTypes) {
    const standard = normalizeSimulationResponse(response);
    const effects = effectBody(standard.effects);
    const status = effects.status?.status ?? effects.status;
    if (String(status).toLowerCase() !== 'success') {
        fail(`devInspect.effects.status: expected success, got ${status}`);
    }
    if (standard.commandResults.length !== plan.commands.length) {
        fail(`devInspect.command_outputs: expected ${plan.commands.length} command results, got ${standard.commandResults.length}`);
    }
    return canonical({
        status: 'success',
        commandResults: standard.commandResults,
        changedObjects: standard.changedObjects,
        vaultInitialized: normalizeInitializedEvent(standard.events, input),
        objectTypes,
    });
}

function validatePinnedSurfaceFixture(fixture) {
    expectObject(fixture, 'pinnedSurfaceFixture', [
        'schemaVersion',
        'fixtureKind',
        'provenance',
        'rawResponse',
    ]);
    if (fixture.schemaVersion !== 1
        || fixture.fixtureKind !== 'sui-serialized-tx-dev-inspect') {
        fail('pinnedSurfaceFixture: unsupported schema or kind');
    }
    expectObject(fixture.provenance, 'pinnedSurfaceFixture.provenance', [
        'suiVersion',
        'environment',
        'capturedOutputSha256',
        'serializedTransaction',
        'command',
    ]);
    if (fixture.provenance.suiVersion !== PINNED_SUI_VERSION
        || fixture.provenance.environment !== 'testnet'
        || fixture.provenance.capturedOutputSha256
            !== '2ad66f247c5175f64e02861dc85af0f9ee1b9491f0e98267a7fde5c2cb19f8c8') {
        fail('pinnedSurfaceFixture.provenance: pinned capture drift');
    }
    const capturedOutputSha256 = createHash('sha256')
        .update(`${JSON.stringify(fixture.rawResponse, null, 2)}\n`)
        .digest('hex');
    if (capturedOutputSha256 !== fixture.provenance.capturedOutputSha256) {
        fail('pinnedSurfaceFixture.rawResponse: captured output SHA-256 mismatch');
    }
    const transactionData = parseSerializedTransaction(
        fixture.provenance.serializedTransaction,
        'pinnedSurfaceFixture.provenance.serializedTransaction',
    );
    if (transactionData !== PINNED_SURFACE_TRANSACTION) {
        fail('pinnedSurfaceFixture.provenance: serialized TransactionData drift');
    }
    assertEqual(
        fixture.provenance.command,
        ['sui', ...renderSerializedInspectArgs('testnet', transactionData)],
        'pinnedSurfaceFixture.provenance.command',
    );
    const standard = normalizeSimulationResponse(
        fixture.rawResponse,
        'pinnedSurfaceFixture.rawResponse',
    );
    const data = expectObject(
        standard.transaction.transaction?.V1,
        'pinnedSurfaceFixture.rawResponse.transaction.transaction.V1',
    );
    assertEqual(
        data.sender,
        '0x00000000000000000000000000000000000000000000000000000000000a11ce',
        'pinnedSurfaceFixture.sender',
    );
    const programmable = expectObject(
        data.kind?.ProgrammableTransaction,
        'pinnedSurfaceFixture.programmableTransaction',
    );
    if (!Array.isArray(programmable.commands) || programmable.commands.length !== 1) {
        fail('pinnedSurfaceFixture.programmableTransaction: expected one command');
    }
    const call = expectObject(
        programmable.commands[0]?.MoveCall,
        'pinnedSurfaceFixture.moveCall',
    );
    assertEqual({
        package: call.package,
        module: call.module,
        function: call.function,
        typeArguments: call.type_arguments,
        arguments: call.arguments,
    }, {
        package: '0x0000000000000000000000000000000000000000000000000000000000000002',
        module: 'tx_context',
        function: 'sender',
        typeArguments: [],
        arguments: [],
    }, 'pinnedSurfaceFixture.moveCall');
    if (standard.events.length !== 0 || standard.commandResults.length !== 1) {
        fail('pinnedSurfaceFixture: expected one eventless command result');
    }
    assertEqual(
        standard.commandResults[0],
        {
            mutableReferenceOutputs: [],
            returnValues: [{
                value: {
                    name: 'address',
                    value: 'AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAKEc4=',
                },
                json: '0x00000000000000000000000000000000000000000000000000000000000a11ce',
            }],
        },
        'pinnedSurfaceFixture.commandOutput',
    );
    const effects = effectBody(standard.effects);
    const status = effects.status?.status ?? effects.status;
    if (String(status).toLowerCase() !== 'success') {
        fail(`pinnedSurfaceFixture.effects.status: expected success, got ${status}`);
    }
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
    validatePinnedSurfaceFixture(readJson(PINNED_SURFACE_FIXTURE_PATH));
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
    let passed = 3;

    const zeroFunder = structuredClone(fixture.builderInput);
    zeroFunder.seedFunder = `0x${'0'.repeat(64)}`;
    expectFailure('seedFunder must not be zero', () => buildPlan(zeroFunder));
    passed += 1;

    const malformedResults = structuredClone(fixture.rawDevInspectResponse);
    malformedResults.command_outputs.pop();
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
    wrongEvent.transaction.event_json[0].pos0.absolute_notional = '100000001';
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
    duplicateEvent.transaction.events.data.push(structuredClone(
        duplicateEvent.transaction.events.data[0],
    ));
    duplicateEvent.transaction.event_json.push(structuredClone(
        duplicateEvent.transaction.event_json[0],
    ));
    expectFailure('exactly one', () => normalizeDevInspect(
        duplicateEvent,
        fixture.builderInput,
        plan,
        fixture.objectTypes,
    ));
    passed += 1;

    const missingShape = structuredClone(fixture.rawDevInspectResponse);
    delete missingShape.command_outputs[0].returnValues;
    const normalizedMissingShape = normalizeDevInspect(
        missingShape,
        fixture.builderInput,
        plan,
        fixture.objectTypes,
    );
    assertEqual(
        normalizedMissingShape.commandResults[0].returnValues,
        [],
        'omitted returnValues',
    );
    passed += 1;

    const transactionData = parseSerializedTransaction(
        'AAAAAQAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAgp0eF9jb250ZXh0BnNlbmRlcgAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAKEc4AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAKEc7oAwAAAAAAAAAgPYh5LQAAAA==',
        'serializedTransaction',
    );
    const inspectArgs = renderSerializedInspectArgs('mainnet', transactionData);
    assertEqual(inspectArgs[4], transactionData, 'serialized transaction handoff');
    passed += 1;

    expectFailure('canonical base64', () => parseSerializedTransaction(
        'not base64\nsecond line',
        'serializedTransaction',
    ));
    passed += 1;

    const changedCapture = readJson(PINNED_SURFACE_FIXTURE_PATH);
    changedCapture.rawResponse.suggested_gas_price = '1';
    expectFailure('captured output SHA-256 mismatch', () =>
        validatePinnedSurfaceFixture(changedCapture));
    passed += 1;

    const changedTransaction = readJson(PINNED_SURFACE_FIXTURE_PATH);
    changedTransaction.provenance.serializedTransaction = 'AA==';
    changedTransaction.provenance.command = [
        'sui',
        ...renderSerializedInspectArgs('testnet', 'AA=='),
    ];
    expectFailure('serialized TransactionData drift', () =>
        validatePinnedSurfaceFixture(changedTransaction));
    passed += 1;

    process.stdout.write(`dev_inspect_activation self-test: PASS ${passed}/13 cases\n`);
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

function assertPinnedSuiVersion() {
    const observed = runSui(['--version']).trim();
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
    assertPinnedSuiVersion();
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

    const transactionData = parseSerializedTransaction(
        runSui(renderPtbArgs(config.builderInput, plan)),
        'serialized activation TransactionData',
    );
    const inspectArgs = renderSerializedInspectArgs('mainnet', transactionData);
    if (inspectArgs[4] !== transactionData) {
        fail('serialized activation TransactionData handoff changed');
    }
    const response = parseJson(runSui(inspectArgs), 'devInspect');
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
