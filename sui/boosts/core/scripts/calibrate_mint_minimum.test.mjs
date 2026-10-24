import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import test from 'node:test';
import { assertCalibratedPolicy, assertCalibratedSeed, calibrate, simulate, smallestMinimum } from './calibrate_mint_minimum.mjs';

const profile = JSON.parse(readFileSync(new URL('./fixtures/nvda-mint-drift.json', import.meta.url), 'utf8'));
const input = {
    rebalancePolicy: { rebalanceBelowBps: '18000', targetLeverageBps: '20000', rebalanceAboveBps: '22000' },
    vaultPolicy: { minOrderLots: '65' }, navCap: '1000000000',
};
const seed = { seed_shareholder_nav: '998147', position_base: '8810000', lot_size: '10000' };

test('65 is the smallest bound-supported minimum; the next smaller candidate also fails the stress run', () => {
    const result = calibrate(profile);
    assert.equal(result.minimum, '65');
    assert.equal(result.minimumNetDepositAtSeed, '73644');
    assert.deepEqual(result.selected, {
        minimum: '65', mints: 12223, firstBreach: null, finalNav: '999989861', finalLeverageBpsDown: '18022',
    });
    assert.deepEqual(result.previous, {
        minimum: '64', mints: 12394, firstBreach: 12129, finalNav: '999991778', finalLeverageBpsDown: '17993',
    });
});

test('a tighter band or larger growth envelope cannot lower the required minimum', () => {
    assert.ok(smallestMinimum({ ...profile, rebalanceBelowBps: '19000' }) > 65n);
    assert.ok(smallestMinimum({ ...profile, navCap: '10000000000' }) > 65n);
    assert.ok(smallestMinimum({ ...profile, minimumSeedNav: '9981470' }) < 65n);
});

test('the exact growth bound includes equality and rejects one NAV atom beyond it', () => {
    const exact = { ...profile, minimumSeedNav: '729000', navCap: '1000000' };
    assert.equal(smallestMinimum(exact), 2n); // (1.8/2)^3 = 0.729
    assert.equal(smallestMinimum({ ...exact, navCap: '1000001' }), 3n);
});

test('calibration rejects an unreviewed minimum and invalid model inputs', () => {
    assert.throws(() => calibrate({ ...profile, minOrderLots: '64' }), /selected minimum 65/);
    assert.throws(() => calibrate({ ...profile, minOrderLots: '1' }), /invalid minimum/);
    assert.throws(() => calibrate({ ...profile, seedBase: '650000' }), /seed must exceed/);
    assert.throws(() => calibrate({ ...profile, minimumSeedNav: '0' }), /positive decimal/);
    assert.throws(() => calibrate({ ...profile, model: 'changing-prices' }), /unsupported drift model/);
    assert.throws(() => simulate(profile, 65n, 1), /step limit/);
});

test('future issuance inputs must honor the calibrated band, minimum and cap', () => {
    assertCalibratedPolicy(input, profile);
    assertCalibratedPolicy({ ...input, vaultPolicy: { minOrderLots: '66' } }, profile);
    assert.throws(() => assertCalibratedPolicy({ ...input, vaultPolicy: { minOrderLots: '64' } }, profile), /at least 65/);
    assert.throws(() => assertCalibratedPolicy({ ...input, navCap: '1000000001' }, profile), /cap exceeds/);
    assert.throws(() => assertCalibratedPolicy({ ...input,
        rebalancePolicy: { ...input.rebalancePolicy, rebalanceBelowBps: '19000' } }, profile), /band differs/);
});

test('activation checks observable seed premises without claiming to observe starting leverage', () => {
    assertCalibratedSeed(seed, input, profile);
    assert.throws(() => assertCalibratedSeed({ ...seed, seed_shareholder_nav: '998146' }, input, profile), /NAV outside/);
    assert.throws(() => assertCalibratedSeed({ ...seed, lot_size: '10001' }, input, profile), /lot differs/);
    assert.throws(() => assertCalibratedSeed({ ...seed, position_base: '650000' }, input, profile), /exposure/);
    assert.throws(() => assertCalibratedSeed({ ...seed, position_base: '8810001' }, input, profile), /whole lots/);
});
