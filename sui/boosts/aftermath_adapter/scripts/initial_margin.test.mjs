import test from 'node:test';
import assert from 'node:assert/strict';
import { assertInitialMargin } from './initial_margin.mjs';

const ONE = 10n ** 18n;
const B = 10_000n;
const rawBps = (n) => (BigInt(n) * ONE / B).toString();
const input = (r = 1000, h = 0, fee = 0, d = 0, slip = 100) => ({
    positionImr: rawBps(r),
    venueMargin: { marketImr: rawBps(500), collateralHaircut: rawBps(h), takerFee: rawBps(fee), priorityTakerFee: null },
    rebalancePolicy: { maxLeverageBps: '25000', emergencyMaxSlippageBps: String(slip) },
    pricePolicy: { maxMarkDivergenceBps: String(d) },
});

for (const [r, h, f, d, slip, pass] of [
    [3999, 0, 0, 0, 0, true], [4000, 0, 0, 0, 0, false],
    [2999, 0, 0, 0, 1000, true], [3000, 0, 0, 0, 1000, false],
    [2849, 500, 0, 0, 1000, true], [2850, 500, 0, 0, 1000, false],
    [2238, 500, 0, 500, 1000, true], [2239, 500, 0, 500, 1000, false],
    [2138, 500, 100, 500, 1000, true], [2139, 500, 100, 500, 1000, false],
]) {
    test(`strict headroom boundary ${[r, h, f, d, slip]}`, () => {
        if (pass) assert.doesNotThrow(() => assertInitialMargin(input(r, h, f, d, slip)));
        else assert.throws(() => assertInitialMargin(input(r, h, f, d, slip)), /headroom/);
    });
}

test('position lower bound is compared before rounding', () => {
    const x = input();
    x.positionImr = (ONE / 10n + 1n).toString();
    x.venueMargin.marketImr = (ONE / 10n + 2n).toString();
    assert.throws(() => assertInitialMargin(x), /invalid position/);
});

test('one raw atom rounds into the rejected boundary', () => {
    const x = input(3899);
    assertInitialMargin(x);
    x.positionImr = (BigInt(x.positionImr) + 1n).toString();
    assert.throws(() => assertInitialMargin(x), /headroom/);
});

test('priority fee surcharge consumes the cushion, rebates never enlarge it', () => {
    const x = input(2138, 500, 99, 500, 1000);
    x.venueMargin.priorityTakerFee = rawBps(1);
    assertInitialMargin(x);
    x.venueMargin.priorityTakerFee = rawBps(2);
    assert.throws(() => assertInitialMargin(x), /headroom/);
    x.venueMargin.priorityTakerFee = ((1n << 256n) - ONE).toString();
    assertInitialMargin(x);
});

test('invalid carriers and missing live previews fail closed', () => {
    for (const value of ['0', '-1', (ONE + 1n).toString(), (1n << 256n).toString()]) {
        const x = input(); x.positionImr = value;
        assert.throws(() => assertInitialMargin(x), /initial margin/);
    }
    const x = input(); delete x.venueMargin;
    assert.throws(() => assertInitialMargin(x), /preview/);
});

test('accepted configurations cover independently valued stressed cash and positions', () => {
    // Exact rational valuation of the stated model, both position directions.
    // Equity is fully realized and allocated before the stress; no reserve credit.
    let accepted = 0;
    for (const h of [0, 100, 500, 1000, 3000]) for (const d of [0, 100, 500, 1000]) {
        for (const fee of [0, 10, 100]) for (const slip of [0, 100, 500, 1000]) {
            for (const r of [500, 1000, 2000, 3000, 3999]) {
                const x = input(r, h, fee, d, slip);
                try { assertInitialMargin(x); } catch { continue; }
                accepted++;
                const equity = 10n ** 24n;
                const notional = equity * 25000n / B;
                const cost = notional * BigInt(slip) / B
                    + notional * (B + BigInt(slip)) * BigInt(fee) / (B * B);
                const cash = (equity - cost) * (B - BigInt(h)) / B;
                for (const side of [-1n, 1n]) {
                    const markNotional = notional * (B + side * BigInt(d)) / B;
                    const loss = notional * BigInt(d) / B;
                    const requirement = markNotional * BigInt(r) / B;
                    assert.ok(cash - loss > requirement);
                }
            }
        }
    }
    assert.ok(accepted > 500);
});

test('activation builder rejects unsafe or missing preview settings before producing a transaction', async () => {
    const { readFileSync } = await import('node:fs');
    const { buildPlan } = await import('./dev_inspect_activation.mjs');
    const fixture = JSON.parse(readFileSync(new URL('./fixtures/activation-vectors.json', import.meta.url)));
    assert.doesNotThrow(() => buildPlan(fixture.builderInput));
    const unsafe = structuredClone(fixture.builderInput);
    unsafe.positionImr = rawBps(4000);
    assert.throws(() => buildPlan(unsafe), /headroom/);
    const missing = structuredClone(fixture.builderInput);
    delete missing.venueMargin;
    assert.throws(() => buildPlan(missing), /venueMargin|keys/);
});
