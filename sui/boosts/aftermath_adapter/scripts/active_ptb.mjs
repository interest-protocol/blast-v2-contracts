// Pure reviewed call-plan construction. This module never opens RPC, signs or submits.
// Plans and CLI arguments are not serialized TransactionData or live execution evidence.
import { AFTERMATH_PACKAGE } from './aftermath.mjs';

const BOUND_OBJECTS = ['vault', 'protocol', 'account', 'registry', 'clearingHouse',
    'baseOracle', 'collateralOracle'];
const INPUT_FIELDS = new Set(['operation', 'adapterPackage', 'sender', 'network',
    'productType', 'collateralType', 'objects', 'minimumOutput', 'deadlineMs', 'launch']);

function address(value) {
    if (typeof value !== 'string' || !/^0x[0-9a-fA-F]{64}$/.test(value)) throw Error('canonical address required');
    return value.toLowerCase();
}

function type(value) {
    if (typeof value !== 'string' || !/^0x[0-9a-fA-F]{64}::[A-Za-z_][A-Za-z_0-9]*::[A-Za-z_][A-Za-z_0-9]*(?:<[A-Za-z_0-9:,<>]+>)?$/.test(value)) {
        throw Error('canonical Move type required');
    }
    return value;
}

function u64(value) {
    if (typeof value !== 'string' || !/^(0|[1-9][0-9]*)$/.test(value) || BigInt(value) > 18446744073709551615n) {
        throw Error('canonical decimal u64 required');
    }
    return value;
}

function call(target, typeArguments, args, assign) {
    return {target, typeArguments, arguments: args, assign};
}

export function buildActivePlan(input) {
    if (!input || typeof input !== 'object' || Array.isArray(input)) throw Error('input object required');
    for (const key of Object.keys(input)) if (!INPUT_FIELDS.has(key)) throw Error(`unexpected field ${key}`);
    const operation = input.operation;
    if (!['mint', 'redeem', 'rebalance', 'mint_buy', 'sell_redeem'].includes(operation)) throw Error('unsupported active operation');
    const adapter = address(input.adapterPackage);
    address(input.sender);
    if (input.network !== 'mainnet') throw Error('network must be mainnet');
    const product = type(input.productType), collateral = type(input.collateralType);
    const objects = input.objects;
    if (!objects || typeof objects !== 'object' || Array.isArray(objects)) throw Error('bound objects required');
    // A mint or redeem may name a Blast partner, which switches it to the `_with_partner` entry
    // point with the partner right after the protocol object; rebalance takes none.
    const allowed = [...BOUND_OBJECTS, 'clock', 'inputCoin', ...(operation === 'rebalance' ? [] : ['partner'])];
    for (const key of Object.keys(objects)) {
        if (!allowed.includes(key)) throw Error(`unexpected object field ${key}`);
    }
    const bound = BOUND_OBJECTS.map((role) => `@${address(objects[role])}`);
    const clock = `@${address(objects.clock)}`;
    if (operation === 'rebalance') {
        return {commands: [
            call(`${adapter}::operations::rebalance`, [product, collateral], [...bound, clock], 'clearing_house'),
            call(`${AFTERMATH_PACKAGE}::clearing_house::share`, [collateral], ['clearing_house'], null),
        ], transfers: []};
    }
    const partnered = objects.partner !== undefined;
    const traded = partnered ? [...bound.slice(0, 2), `@${address(objects.partner)}`, ...bound.slice(2)] : bound;
    const entry = (name) => `${adapter}::operations::${name}${partnered ? '_with_partner' : ''}`;
    const coin = `@${address(objects.inputCoin)}`;
    const limits = [u64(input.minimumOutput), u64(input.deadlineMs), clock];
    const composed = operation === 'mint_buy' || operation === 'sell_redeem';
    let launchArgs, launchTypes, launchPackage, launchMinimum;
    if (composed) {
        const launch = input.launch;
        if (!launch || typeof launch !== 'object' || Array.isArray(launch)) throw Error('launch objects required');
        const keys = ['package', 'memeType', 'launch', 'version', 'runtime', 'minimumOutput'];
        if (Object.keys(launch).length !== keys.length || Object.keys(launch).some((key) => !keys.includes(key))) throw Error('unexpected launch field');
        launchPackage = address(launch.package);
        launchTypes = [type(launch.memeType), `${adapter}::blast_boost::BlastBoost<${product}>`];
        launchArgs = ['launch', 'version', 'runtime'].map((role) => `@${address(launch[role])}`);
        launchMinimum = u64(launch.minimumOutput);
    }
    if (operation === 'mint_buy') {
        return {commands: [
            call(entry('mint'), [product, collateral], [...traded, coin, ...limits], 'shares'),
            call(`${launchPackage}::launch::buy`, launchTypes, [...launchArgs, 'shares.0', launchMinimum], 'purchase'),
            call(`${AFTERMATH_PACKAGE}::clearing_house::share`, [collateral], ['shares.1'], null),
        ], transfers: ['purchase.0', 'purchase.1']};
    }
    if (operation === 'sell_redeem') {
        return {commands: [
            call(`${launchPackage}::launch::sell`, launchTypes, [...launchArgs, coin, launchMinimum], 'shares'),
            call(entry('redeem'), [product, collateral], [...traded, 'shares', ...limits], 'result'),
            call(`${AFTERMATH_PACKAGE}::clearing_house::share`, [collateral], ['result.1'], null),
        ], transfers: ['result.0']};
    }
    return {commands: [
        call(entry(operation), [product, collateral], [...traded, coin, ...limits], 'result'),
        call(`${AFTERMATH_PACKAGE}::clearing_house::share`, [collateral], ['result.1'], null),
    ], transfers: ['result.0']};
}

export function renderUnsignedPtbArgs(input) {
    const plan = ['begin_shutdown', 'unwind', 'finalize_shutdown', 'redeem_shutdown'].includes(input.operation)
        ? buildTerminalPlan(input) : buildActivePlan(input);
    const args = ['client', '--client.env', input.network, 'ptb'];
    for (const command of plan.commands) {
        args.push('--move-call', command.target, `<${command.typeArguments.join(',')}>`, ...command.arguments);
        if (command.assign !== null) args.push('--assign', command.assign);
    }
    if (plan.transfers.length) args.push('--transfer-objects', `[${plan.transfers.join(',')}]`, `@${input.sender}`);
    return [...args, '--serialize-unsigned-transaction', '--sender', `@${input.sender}`];
}

// Current terminal ABI. These plans are inert descriptions, not authorization or submission.
export function buildTerminalPlan(input) {
    const allowed = new Set(['operation', 'adapterPackage', 'corePackage', 'adminPackage', 'sender', 'network',
        'productType', 'collateralType', 'objects', 'minimumOutput', 'deadlineMs', 'reason']);
    if (!input || typeof input !== 'object' || Array.isArray(input)) throw Error('input object required');
    for (const key of Object.keys(input)) if (!allowed.has(key)) throw Error(`unexpected field ${key}`);
    const operation = input.operation;
    if (!['begin_shutdown', 'unwind', 'finalize_shutdown', 'redeem_shutdown'].includes(operation)) throw Error('unsupported terminal operation');
    const adapter = address(input.adapterPackage), product = type(input.productType);
    address(input.sender);
    if (input.network !== 'mainnet') throw Error('network must be mainnet');
    const roles = operation === 'begin_shutdown' ? ['vault', 'protocol', 'acl', 'adminCap']
        : operation === 'redeem_shutdown' ? ['vault', 'protocol', 'inputCoin', 'clock']
        : operation === 'finalize_shutdown' ? [...BOUND_OBJECTS.slice(0, 7), 'clock']
        : [...BOUND_OBJECTS, 'clock'];
    const objects = input.objects;
    if (!objects || typeof objects !== 'object' || Array.isArray(objects)) throw Error('bound objects required');
    for (const key of Object.keys(objects)) if (!roles.includes(key)) throw Error(`unexpected object field ${key}`);
    const args = roles.map((role) => `@${address(objects[role])}`);
    if (operation === 'begin_shutdown') {
        const core = address(input.corePackage), admin = address(input.adminPackage);
        if (!['emergency', 'observed_venue_change'].includes(input.reason)) throw Error('explicit declared reason required');
        return {commands: [
            call(`${admin}::blast_acl::sign_in`, [`${core}::blast_boosts_core::ShutdownAdmin`], args.slice(2), 'witness'),
            call(`${core}::lifecycle::${input.reason}_reason`, [], [], 'reason'),
            call(`${adapter}::vault::begin_shutdown`, [product, type(input.collateralType)],
                [...args.slice(0, 2), 'witness', 'reason'], null),
        ], transfers: []};
    }
    const types = [product, type(input.collateralType)];
    if (operation === 'redeem_shutdown') {
        return {commands: [call(`${adapter}::vault::redeem_shutdown`, types,
            [...args.slice(0, 3), u64(input.minimumOutput), u64(input.deadlineMs), args[3]], 'result')], transfers: ['result']};
    }
    if (operation === 'unwind') {
        return {commands: [
            call(`${adapter}::operations::unwind`, types, args, 'clearing_house'),
            call(`${AFTERMATH_PACKAGE}::clearing_house::share`, [types[1]], ['clearing_house'], null),
        ], transfers: []};
    }
    return {commands: [call(`${adapter}::operations::${operation}`, types, args, null)], transfers: []};
}

// Observer classifications are advisory. Only a shutdown-role witness can retire a Vault.
export function emergencyDecision(facts) {
    return facts.active === true && facts.authenticatedUnexpectedChange === true
        ? 'shutdown_role_review' : 'no_change';
}

// Observation-side trigger only. The on-chain public call independently authenticates
// bindings, funding, prices, margin and policy, then derives its own side and size.
export function keeperDecision(facts) {
    if (facts.active !== true || facts.pricingValid !== true || facts.checkpointClean !== true) return 'blocked';
    const equity = BigInt(u64(facts.equity)), reserve = BigInt(u64(facts.reserve));
    const notional = BigInt(u64(facts.notional));
    const lower = BigInt(u64(facts.lowerBps)), upper = BigInt(u64(facts.upperBps));
    if (equity <= reserve || lower >= upper) return 'blocked';
    const nav = equity - reserve, scaled = notional * 10000n;
    return scaled < nav * lower || scaled > nav * upper ? 'rebalance' : 'no_change';
}
