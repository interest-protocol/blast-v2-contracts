#!/usr/bin/env node
// Serializes the reviewed activation PTB (issue -> initialize -> share),
// dev-inspects that exact transaction, and validates only standard Sui
// machine-readable results, effects, and events.

import { execFileSync } from 'node:child_process';
import { createHash } from 'node:crypto';
import { readFileSync } from 'node:fs';
import { dirname, join, resolve } from 'node:path';
import { fileURLToPath, pathToFileURL } from 'node:url';
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
const ORDERS_PATH = join(PACKAGE_DIR, 'sources', 'orders.move');
const VENUE_ACCOUNT_PATH = join(PACKAGE_DIR, 'sources', 'venue_account.move');
const MAINNET_CHAIN = '4btiuiMPvEENsttpZC7CZ53DruC3MAgfznDbASZ7DR6S';
const PINNED_SUI_VERSION = '1.77.2-51d177ad7d65';
const PINNED_SURFACE_TRANSACTION = 'AAAAAQAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAgp0eF9jb250ZXh0BnNlbmRlcgAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAKEc4AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAKEc7oAwAAAAAAAAAgPYh5LQAAAA==';
const SUI_FRAMEWORK = `0x${'0'.repeat(63)}2`;
// Every object the activation PTB takes as an input, in the order `initialize`
// reads them after the issuer's admin objects and the Coin Registry.
const OBJECT_ROLES = [
    'acl',
    'adminCap',
    'protocol',
    'coinRegistry',
    'currency',
    'registry',
    'clearingHouse',
    'baseOracle',
    'collateralOracle',
    'seedCoin',
    'clock',
];
const REBALANCE_POLICY_FIELDS = [
    'rebalanceBelowBps',
    'targetLeverageBps',
    'rebalanceAboveBps',
    'maxLeverageBps',
    'maxSlippageBps',
    'emergencyMaxSlippageBps',
    'minLeverageImprovementBps',
];
const PRICE_POLICY_FIELDS = [
    'maxPriceAgeMs',
    'maxPriceAheadMs',
    'maxConfidenceBps',
    'maxMarkDivergenceBps',
];
const VAULT_POLICY_FIELDS = [
    'initialMintFeeBps',
    'initialRedeemFeeBps',
    'mintFeeCapBps',
    'redeemFeeCapBps',
    'adminShareCapBps',
    'minOrderLots',
    'maxReserveBps',
];
const METADATA_FIELDS = ['symbol', 'name', 'description', 'iconUrl'];
const INITIALIZED_FIELDS = [
    'vault_id',
    'binding',
    'seed_amount',
    'seed_venue_equity',
    'seed_reserve',
    'seed_shareholder_nav',
    'locked_shares',
    'position_base',
    'lot_size',
    'position_side',
    'position_imr',
    'checkpoint',
];
const BINDING_FIELDS = [
    'account_object_id',
    'account_number',
    'registry_id',
    'clearing_house_id',
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
// The activation statements, in order, per production module. `initialize`
// is read between its signature and the next public entry; each helper is
// read to its closing brace.
const PHASE_ORDER = [
    {
        path: OPERATIONS_PATH,
        from: 'public fun initialize<',
        to: '\npublic fun mint<',
        markers: [
            'protocol.assert_current()',
            'assert_initialization_inputs(',
            'assert_position_imr(',
            'open_venue_account(',
            'fund_venue_account(',
            'terms.seed_position(',
            'clearing_house.settle_position_funding(',
            'binding.capture(',
            'assert_position_imr_unchanged(',
            'venue_account::new(',
            'issuance.activate(',
            'account.consume_policy_and_share_account(share_policy)',
            'clearing_house.share()',
            'emit_vault_initialized<Product, Collateral>(',
            '\n    vault\n}',
        ],
    },
    {
        path: OPERATIONS_PATH,
        from: 'fun open_venue_account<',
        to: '\n}\n',
        markers: ['account::create_account<Collateral>(', 'venue_account::new_binding('],
    },
    {
        path: OPERATIONS_PATH,
        from: 'fun fund_venue_account<',
        to: '\n}\n',
        markers: [
            'account.deposit_collateral(',
            'clearing_house.create_market_position(',
            'clearing_house.allocate_collateral(',
            'clearing_house.set_position_initial_margin_ratio(',
        ],
    },
    {
        path: ORDERS_PATH,
        from: 'public(package) fun seed_position<',
        to: '\n}\n',
        markers: ['binding.update_funding_when_due(', 'binding.capture(', 'issuance.seed_terms(', 'open_seed_position('],
    },
    {
        path: ORDERS_PATH,
        from: 'fun open_seed_position<',
        to: '\n}\n',
        markers: [
            'venue_account::execute_order_with_cap(',
            'assert_seed_fill(',
            'issuance.assert_seed_execution(',
            'issuance.assert_seed_order_notional_allowed(',
        ],
    },
    {
        path: VENUE_ACCOUNT_PATH,
        from: 'public(package) fun execute_order_with_cap<',
        to: '\n}\n',
        markers: ['clearing_house.start_session(', 'session.place_market_order(', 'session.end_session('],
    },
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

function wrappedEventType(adapterPackage, payloadType) {
    return `${adapterPackage}::blast_events::Event<${payloadType}>`;
}

function unwrapEventPayload(value, path) {
    const wrapper = expectObject(value, path, ['pos0']);
    return expectObject(wrapper.pos0, `${path}.pos0`);
}

function expectDecimal(value, path) {
    const text = expectString(value, path);
    if (!/^(0|[1-9][0-9]*)$/.test(text)) fail(`${path}: expected canonical decimal integer`);
    return text;
}

function expectDecimals(object, path, keys) {
    expectObject(object, path, keys);
    for (const key of keys) expectDecimal(object[key], `${path}.${key}`);
}

function moveString(value, path, allowEmpty = false) {
    const text = allowEmpty
        ? (() => {
            if (typeof value !== 'string') fail(`${path}: expected string`);
            return value;
        })()
        : expectString(value, path);
    if (/["\\\n]/.test(text)) fail(`${path}: metadata strings may not contain quotes, backslashes or newlines`);
    // execFileSync passes each argv item directly to `sui client ptb`; unlike a
    // shell command, it must not include shell-only single-quote delimiters.
    // Including them stores the double quotes as part of the on-chain string.
    return `"${text}"`;
}

function validateBuilderInput(input) {
    expectObject(input, 'builderInput', [
        'sender',
        'adminPackage',
        'corePackage',
        'adapterPackage',
        'adapterOriginalPackage',
        'productType',
        'collateralType',
        'objects',
        'side',
        'rebalancePolicy',
        'pricePolicy',
        'vaultPolicy',
        'maxOrderNotional',
        'navCap',
        'metadata',
        'seedReserve',
        'positionImr',
    ]);
    expectAddress(input.sender, 'builderInput.sender');
    expectAddress(input.adminPackage, 'builderInput.adminPackage');
    expectAddress(input.corePackage, 'builderInput.corePackage');
    expectAddress(input.adapterPackage, 'builderInput.adapterPackage');
    expectAddress(input.adapterOriginalPackage, 'builderInput.adapterOriginalPackage');
    expectString(input.productType, 'builderInput.productType');
    expectString(input.collateralType, 'builderInput.collateralType');
    expectObject(input.objects, 'builderInput.objects', OBJECT_ROLES);
    for (const role of OBJECT_ROLES) expectAddress(input.objects[role], `builderInput.objects.${role}`);
    if (input.side !== 'long' && input.side !== 'short') fail('builderInput.side: expected long or short');
    expectDecimals(input.rebalancePolicy, 'builderInput.rebalancePolicy', REBALANCE_POLICY_FIELDS);
    expectDecimals(input.pricePolicy, 'builderInput.pricePolicy', PRICE_POLICY_FIELDS);
    expectDecimals(input.vaultPolicy, 'builderInput.vaultPolicy', VAULT_POLICY_FIELDS);
    expectDecimal(input.maxOrderNotional, 'builderInput.maxOrderNotional');
    expectDecimal(input.navCap, 'builderInput.navCap');
    expectObject(input.metadata, 'builderInput.metadata', METADATA_FIELDS);
    expectDecimal(input.seedReserve, 'builderInput.seedReserve');
    expectDecimal(input.positionImr, 'builderInput.positionImr');
}

function call(target, typeArguments, args, assign) {
    return { target, typeArguments, arguments: args, assign };
}

/// The issuer's activation PTB: sign in, build the immutable policy, issue the
/// currency, seed and activate the Vault, share it. Every value is a literal
/// or a prior result; nothing is read from the chain to build it.
function buildPlan(input) {
    validateBuilderInput(input);
    const admin = input.adminPackage.toLowerCase();
    const core = input.corePackage.toLowerCase();
    const adapter = input.adapterPackage.toLowerCase();
    const vaultIssuer = `${core}::blast_boosts_core::VaultIssuer`;
    const productArguments = [input.productType, input.collateralType];
    const object = (role) => `@${input.objects[role].toLowerCase()}`;
    const decimals = (record, keys) => keys.map((key) => record[key]);

    return {
        commands: [
            call(`${admin}::blast_acl::sign_in`, [vaultIssuer], [object('acl'), object('adminCap')], 'admin_witness'),
            call(`${core}::policy::new_rebalance_policy`, [], decimals(input.rebalancePolicy, REBALANCE_POLICY_FIELDS), 'rebalance_policy'),
            call(`${core}::policy::new_price_policy`, [], decimals(input.pricePolicy, PRICE_POLICY_FIELDS), 'price_policy'),
            call(`${core}::policy::${input.side}`, [], [], 'side'),
            call(
                `${core}::policy::new_vault_policy`,
                [],
                ['side', 'rebalance_policy', 'price_policy', ...decimals(input.vaultPolicy, VAULT_POLICY_FIELDS)],
                'vault_policy',
            ),
            call(
                `${adapter}::vault::issue`,
                productArguments,
                [
                    object('protocol'),
                    'admin_witness',
                    object('coinRegistry'),
                    'vault_policy',
                    input.maxOrderNotional,
                    input.navCap,
                    ...METADATA_FIELDS.map((key) => moveString(
                        input.metadata[key],
                        `builderInput.metadata.${key}`,
                        key === 'iconUrl',
                    )),
                ],
                'issuance',
            ),
            call(
                `${adapter}::operations::initialize`,
                productArguments,
                [
                    'issuance',
                    object('protocol'),
                    object('currency'),
                    object('registry'),
                    object('clearingHouse'),
                    object('baseOracle'),
                    object('collateralOracle'),
                    object('seedCoin'),
                    input.seedReserve,
                    input.positionImr,
                    object('clock'),
                ],
                'vault',
            ),
            call(`${adapter}::vault::share`, productArguments, ['vault'], null),
        ],
    };
}

/// The `sui client ptb` arguments for a plan, command by command.
function renderMoveCalls(plan) {
    const args = [];
    for (const command of plan.commands) {
        args.push('--move-call', command.target);
        if (command.typeArguments.length > 0) {
            args.push(`<${command.typeArguments.join(',')}>`);
        }
        args.push(...command.arguments);
        if (command.assign !== null) args.push('--assign', command.assign);
    }
    return args;
}

function renderPtbArgs(input, plan) {
    return [
        'client', '--client.env', 'mainnet', 'ptb',
        ...renderMoveCalls(plan),
        '--serialize-unsigned-transaction',
        '--sender',
        `@${input.sender}`,
    ];
}

function renderSerializedInspectArgs(transactionData) {
    return [
        'client',
        '--client.env',
        'mainnet',
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

/// The activation statements appear in order in the production sources; a
/// missing or reordered statement fails here before any chain read.
function verifyProductionPhaseOrder() {
    const sources = new Map();
    for (const span of PHASE_ORDER) {
        if (!sources.has(span.path)) sources.set(span.path, readFileSync(span.path, 'utf8'));
        const source = sources.get(span.path);
        const start = source.indexOf(span.from);
        const end = start < 0 ? -1 : source.indexOf(span.to, start + span.from.length);
        if (start < 0 || end < 0) fail(`${span.path}: ${span.from.trim()} body is unavailable`);
        const body = source.slice(start, end);
        let cursor = 0;
        for (const marker of span.markers) {
            const next = body.indexOf(marker, cursor);
            if (next < 0) fail(`${span.path}: activation phase missing or reordered at ${marker} in ${span.from.trim()}`);
            cursor = next + marker.length;
        }
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

function normalizeTypeTag(value, path) {
    if (typeof value === 'string') return expectString(value, path);
    const type = expectObject(value, path);
    if (type.struct !== undefined) return normalizeTypeTag(type.struct, `${path}.struct`);
    if (type.vector !== undefined) return `vector<${normalizeTypeTag(type.vector, `${path}.vector`)}>`;
    expectObject(type, path, ['address', 'module', 'name', 'type_args']);
    const rawAddress = expectString(type.address, `${path}.address`);
    const address = expectAddress(
        rawAddress.startsWith('0x') ? rawAddress : `0x${rawAddress}`,
        `${path}.address`,
    );
    const module = expectString(type.module, `${path}.module`);
    const name = expectString(type.name, `${path}.name`);
    if (!Array.isArray(type.type_args)) fail(`${path}.type_args: expected list`);
    const arguments_ = type.type_args.map((argument, index) =>
        normalizeTypeTag(argument, `${path}.type_args[${index}]`));
    return `${address}::${module}::${name}${arguments_.length > 0 ? `<${arguments_.join(', ')}>` : ''}`;
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
        const type = normalizeTypeTag(
            raw.type_ ?? raw.type,
            `${path}.events.data[${index}].type_`,
        );
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
    const adapter = input.adapterOriginalPackage.toLowerCase();
    return wrappedEventType(adapter, `${adapter}::events::VaultInitialized<${input.productType}>`);
}

function createdObjectOfType(changedObjects, type, path) {
    const matches = changedObjects.filter((change) =>
        change?.idOperation === 'CREATED'
        && typeof change?.objectType === 'string'
        && change.objectType.replaceAll(' ', '') === type.replaceAll(' ', ''));
    if (matches.length !== 1) fail(`${path}: expected exactly one created ${type}, got ${matches.length}`);
    return expectAddress(matches[0].objectId, `${path}.objectId`);
}

/// The one VaultInitialized event, whose vault and account are the objects this
/// transaction created and whose binding names the input venue objects.
function normalizeInitializedEvent(events, changedObjects, input) {
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
    const binding = expectObject(parsedJson.binding, 'VaultInitialized.binding', BINDING_FIELDS);
    expectObject(parsedJson.checkpoint, 'VaultInitialized.checkpoint', CHECKPOINT_FIELDS);
    const adapter = input.adapterOriginalPackage.toLowerCase();
    const vaultId = createdObjectOfType(
        changedObjects,
        `${adapter}::vault::Vault<${input.productType}, ${input.collateralType}>`,
        'devInspect.changed_objects.vault',
    );
    assertEqual(expectAddress(parsedJson.vault_id, 'VaultInitialized.vault_id'), vaultId, 'VaultInitialized.vault_id');
    const relations = [
        ['registry_id', 'registry'],
        ['clearing_house_id', 'clearingHouse'],
    ];
    for (const [field, role] of relations) {
        assertEqual(
            expectAddress(binding[field], `VaultInitialized.binding.${field}`),
            input.objects[role].toLowerCase(),
            `VaultInitialized.binding.${field}`,
        );
    }
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
        vaultInitialized: normalizeInitializedEvent(standard.events, standard.changedObjects, input),
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
        || fixture.provenance.environment !== 'mainnet'
        || fixture.provenance.capturedOutputSha256
            !== 'd95e7a6cc44eea973f7aff23383b7eb40702276e4957d884da17f413d6c750f1') {
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
        ['sui', ...renderSerializedInspectArgs(transactionData)],
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
    if (fixture.schemaVersion !== 3
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

    const wrongSide = structuredClone(fixture.builderInput);
    wrongSide.side = 'flat';
    expectFailure('long or short', () => buildPlan(wrongSide));
    passed += 1;

    const quotedSymbol = structuredClone(fixture.builderInput);
    quotedSymbol.metadata.symbol = 'SUI"2X';
    expectFailure('metadata strings', () => buildPlan(quotedSymbol));
    passed += 1;

    assertEqual(
        plan.commands[5].arguments.slice(-4),
        ['"SUI2X"', '"SUI 2x Bull"', '"Two times SUI"', '"https://blast.fun/sui2x.png"'],
        'metadata PTB literals',
    );
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
    wrongType.protocol = wrongType.registry;
    expectFailure('objectTypes', () => assertEqual(
        wrongType,
        fixture.objectTypes,
        'objectTypes',
    ));
    passed += 1;

    const wrongEvent = structuredClone(fixture.rawDevInspectResponse);
    wrongEvent.transaction.event_json[0].pos0.locked_shares = '1';
    expectFailure('locked_shares', () => assertEqual(
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

    const foreignVault = structuredClone(fixture.rawDevInspectResponse);
    foreignVault.transaction.event_json[0].pos0.vault_id = fixture.builderInput.objects.protocol;
    expectFailure('VaultInitialized.vault_id', () => normalizeDevInspect(
        foreignVault,
        fixture.builderInput,
        plan,
        fixture.objectTypes,
    ));
    passed += 1;

    const foreignMarket = structuredClone(fixture.rawDevInspectResponse);
    foreignMarket.transaction.event_json[0].pos0.binding.clearing_house_id = fixture.builderInput.objects.registry;
    expectFailure('binding.clearing_house_id', () => normalizeDevInspect(
        foreignMarket,
        fixture.builderInput,
        plan,
        fixture.objectTypes,
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

    const transactionData = parseSerializedTransaction(PINNED_SURFACE_TRANSACTION, 'serializedTransaction');
    const inspectArgs = renderSerializedInspectArgs(transactionData);
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
        ...renderSerializedInspectArgs('AA=='),
    ];
    expectFailure('serialized TransactionData drift', () =>
        validatePinnedSurfaceFixture(changedTransaction));
    passed += 1;

    const testnetCapture = readJson(PINNED_SURFACE_FIXTURE_PATH);
    testnetCapture.provenance.environment = 'testnet';
    expectFailure('pinned capture drift', () =>
        validatePinnedSurfaceFixture(testnetCapture));
    passed += 1;

    process.stdout.write(`dev_inspect_activation self-test: PASS ${passed}/18 cases\n`);
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
    if (config.schemaVersion !== 3
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
    const inspectArgs = renderSerializedInspectArgs(transactionData);
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

export { buildPlan, renderMoveCalls, renderPtbArgs, normalizeDevInspect, verifyProductionPhaseOrder };

if (process.argv[1] && import.meta.url === pathToFileURL(resolve(process.argv[1])).href) {
    try {
        const args = parseArgs(process.argv.slice(2));
        if (args.selfTest) selfTest(); else live(args.config);
    } catch (error) {
        process.stderr.write(`dev_inspect_activation: FAIL ${error.message}\n`);
        process.exitCode = 1;
    }
}
