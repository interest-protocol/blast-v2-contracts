import test from 'node:test';
import assert from 'node:assert/strict';
import { buildActivePlan, buildTerminalPlan, emergencyDecision, renderUnsignedPtbArgs, keeperDecision } from './active_ptb.mjs';

const address = (n) => `0x${n.toString(16).padStart(64, '0')}`;
const input = (operation) => ({
    operation, adapterPackage: address(1), sender: address(2), network: 'mainnet',
    productType: `${address(1)}::product::Product<${address(1)}::tags::Long2x>`,
    collateralType: `${address(3)}::usdc::USDC`,
    objects: Object.fromEntries(['vault', 'protocol', 'account', 'registry', 'clearingHouse',
        'baseOracle', 'collateralOracle', 'clock', 'inputCoin']
        .map((role, i) => [role, address(10 + i)])),
    minimumOutput: '1', deadlineMs: '100000',
});

const terminal = (operation) => {
    const value = input(operation);
    value.corePackage = address(40);
    value.adminPackage = address(43);
    value.reason = 'observed_venue_change';
    value.objects.acl = address(41);
    value.objects.adminCap = address(42);
    const keys = operation === 'begin_shutdown' ? ['vault', 'protocol', 'acl', 'adminCap', 'clock']
        : operation === 'redeem_shutdown' ? ['vault', 'protocol', 'inputCoin', 'clock']
        : operation === 'finalize_shutdown' ? ['vault', 'protocol', 'account', 'registry', 'clearingHouse', 'baseOracle', 'collateralOracle', 'clock']
        : ['vault', 'protocol', 'account', 'registry', 'clearingHouse', 'baseOracle', 'collateralOracle', 'clock'];
    value.objects = Object.fromEntries(keys.map((key) => [key, value.objects[key]]));
    return value;
};

test('shutdown requires the shutdown-admin witness and a declared reason, without venue data', () => {
    const value = terminal('begin_shutdown');
    const plan = buildTerminalPlan(value);
    assert.deepEqual(plan.commands.map((command) => command.target),
        [`${address(43)}::blast_acl::sign_in`, `${address(40)}::lifecycle::observed_venue_change_reason`,
            `${address(1)}::vault::begin_shutdown`]);
    assert.deepEqual(plan.commands[0].typeArguments, [`${address(40)}::blast_boosts_core::ShutdownAdmin`]);
    assert.deepEqual(plan.commands[0].arguments, [`@${value.objects.acl}`, `@${value.objects.adminCap}`]);
    assert.deepEqual(plan.commands[2].typeArguments, [value.productType, value.collateralType]);
    assert.deepEqual(plan.commands[2].arguments, [`@${value.objects.vault}`, `@${value.objects.protocol}`, 'witness', 'reason', `@${value.objects.clock}`]);
    assert.throws(() => buildTerminalPlan({...value, adminPackage: undefined}), /address/);
    assert.throws(() => buildTerminalPlan({...value, reason: 'liquidation'}), /declared reason/);
});

test('permissionless terminal plans exclude caller direction, size, dust write-off and claim fees', () => {
    for (const operation of ['unwind', 'finalize_shutdown', 'redeem_shutdown']) {
        const value = terminal(operation);
        const plan = buildTerminalPlan(value);
        assert.equal(plan.commands.length, 1);
        assert.equal(plan.commands[0].target.split('::').at(-1), operation);
        assert.throws(() => buildTerminalPlan({...value, side: 'short'}), /unexpected field/);
        assert.throws(() => buildTerminalPlan({...value, maximumFeeBps: '1'}), /unexpected field/);
        const args = renderUnsignedPtbArgs(value);
        assert(args.includes('--serialize-unsigned-transaction'));
        assert(!args.includes('--gas-budget'));
        if (operation === 'unwind') {
            assert.equal(plan.commands[0].assign, null);
            assert.deepEqual(plan.transfers, []);
            assert(!args.includes('--assign'));
        }
        if (operation === 'redeem_shutdown') {
            assert.equal(plan.commands[0].arguments.length, 6);
            assert.deepEqual(plan.transfers, ['result']);
        }
    }
});

test('full liquidation, partial liquidation and ADL observations require human witness review, never automatic shutdown', () => {
    for (const classification of ['full_liquidation', 'partial_liquidation', 'adl', 'unknown']) {
        assert.equal(emergencyDecision({active: true, authenticatedUnexpectedChange: true, classification}), 'shutdown_role_review');
    }
    assert.equal(emergencyDecision({active: true, authenticatedUnexpectedChange: false, classification: 'full_liquidation'}), 'no_change');
    assert.equal(emergencyDecision({active: false, authenticatedUnexpectedChange: true}), 'no_change');
});

test('mint and redemption bind public argument order and transfer only the returned native coin', () => {
    for (const operation of ['mint', 'redeem']) {
        const value = input(operation);
        const plan = buildActivePlan(value);
        assert.equal(plan.commands[0].target, `${address(1)}::operations::${operation}`);
        assert.deepEqual(plan.commands[0].arguments, [
            ...['vault', 'protocol', 'account', 'registry', 'clearingHouse', 'baseOracle', 'collateralOracle']
                .map((key) => `@${value.objects[key]}`),
            `@${value.objects.inputCoin}`, '1', '100000', `@${value.objects.clock}`,
        ]);
        assert.throws(() => buildActivePlan({...value, maximumFeeBps: '30'}), /unexpected field/);
        const args = renderUnsignedPtbArgs(value);
        assert.deepEqual(args.slice(-3), ['--serialize-unsigned-transaction', '--sender', `@${address(2)}`]);
        assert(!args.includes('--gas-budget'));
        assert(args.includes('[result.0]'));
        assert.deepEqual(plan.commands[1].arguments, ['result.1']);
        assert.match(plan.commands[1].target, /::clearing_house::share$/);
    }
});

test('naming a partner switches mint and redemption to the partner entry points, partner after protocol', () => {
    for (const operation of ['mint', 'redeem']) {
        const value = input(operation);
        value.objects.partner = address(40);
        const plan = buildActivePlan(value);
        assert.equal(plan.commands[0].target, `${address(1)}::operations::${operation}_with_partner`);
        assert.deepEqual(plan.commands[0].arguments, [
            ...['vault', 'protocol', 'partner', 'account', 'registry', 'clearingHouse', 'baseOracle', 'collateralOracle']
                .map((key) => `@${value.objects[key]}`),
            `@${value.objects.inputCoin}`, '1', '100000', `@${value.objects.clock}`,
        ]);
        assert.throws(() => buildActivePlan({...value, objects: {...value.objects, partner: 'not-an-address'}}), /address/);
    }
    const rebalance = input('rebalance');
    assert.throws(() => buildActivePlan({...rebalance, objects: {...rebalance.objects, partner: address(40)}}), /unexpected object field partner/);
});

test('rebalance ends market use without returning a result or a separate share command', () => {
    const value = input('rebalance');
    const plan = buildActivePlan(value);
    assert.equal(plan.commands[0].arguments.length, 8);
    assert.equal(plan.commands.length, 1);
    assert.equal(plan.commands[0].assign, null);
    assert(!renderUnsignedPtbArgs(value).includes('--assign'));
    assert.deepEqual(plan.transfers, []);
    assert.throws(() => buildActivePlan({...value, side: 'short'}), /unexpected field/);
});

test('profit realization is one endpoint with no caller sizing, reward, partner or returned market', () => {
    const value = input('realize_profit');
    const plan = buildActivePlan(value);
    assert.equal(plan.commands.length, 1);
    assert.equal(plan.commands[0].arguments.length, 8);
    assert.equal(plan.commands[0].target, `${address(1)}::operations::realize_profit`);
    assert.equal(plan.commands[0].assign, null);
    assert.deepEqual(plan.transfers, []);
    assert(!renderUnsignedPtbArgs(value).includes('--assign'));
    assert.throws(() => buildActivePlan({...value, base: '10'}), /unexpected field/);
    assert.throws(() => buildActivePlan({...value, objects: {...value.objects, partner: address(40)}}), /unexpected object field/);
});

test('both direction types compose returned values through mint-buy and sell-redeem', () => {
    for (const direction of ['Long2x', 'Short2x']) {
        for (const operation of ['mint_buy', 'sell_redeem']) {
            const value = input(operation);
            value.productType = `${address(1)}::product::Product<${address(1)}::tags::${direction}>`;
            value.launch = { package: address(30), memeType: `${address(31)}::meme::MEME`,
                launch: address(32), version: address(33), runtime: address(34), minimumOutput: '2' };
            const plan = buildActivePlan(value);
            assert.equal(plan.commands.length, 3);
            if (operation === 'mint_buy') {
                assert.equal(plan.commands[1].arguments[3], 'shares.0');
                assert.deepEqual(plan.transfers, ['purchase.0', 'purchase.1']);
            } else {
                assert.equal(plan.commands[1].arguments[7], 'shares');
                assert.deepEqual(plan.transfers, ['result.0']);
            }
            assert(plan.commands.some((c) => c.typeArguments.includes(`${address(1)}::blast_boost::BlastBoost<${value.productType}>`)));
        }
    }
});

test('builders reject unsafe or unrepresentable input instead of emitting submission arguments', () => {
    assert.throws(() => buildActivePlan({...input('mint'), minimumOutput: '18446744073709551616'}), /u64/);
    assert.throws(() => buildActivePlan({...input('mint'), adapterPackage: '--gas-budget'}), /address/);
    assert.throws(() => buildActivePlan({...input('mint'), productType: 'type; injected'}), /type/);
    assert.throws(() => buildActivePlan({...input('shutdown')}), /operation/);
    assert.throws(() => buildActivePlan({...input('mint'), network: 'testnet'}), /network must be mainnet/);
    assert.throws(() => buildTerminalPlan({...terminal('unwind'), network: 'testnet'}), /network must be mainnet/);
});

test('keeper trigger uses exact rational endpoints and fails closed on missing economic validity', () => {
    const facts = {active: true, pricingValid: true, checkpointClean: true,
        equity: '1000000', reserve: '0', notional: '1800000', lowerBps: '18000', upperBps: '22000'};
    assert.equal(keeperDecision(facts), 'no_change');
    assert.equal(keeperDecision({...facts, notional: '2200000'}), 'no_change');
    assert.equal(keeperDecision({...facts, notional: '1799999'}), 'rebalance');
    assert.equal(keeperDecision({...facts, notional: '2200001'}), 'rebalance');
    assert.equal(keeperDecision({...facts, equity: '1000001'}), 'rebalance');
    assert.equal(keeperDecision({...facts, pricingValid: false}), 'blocked');
    assert.equal(keeperDecision({...facts, checkpointClean: false}), 'blocked');
    assert.equal(keeperDecision({...facts, active: false}), 'blocked');
    assert.equal(keeperDecision({...facts, reserve: '1000000'}), 'blocked');
});
