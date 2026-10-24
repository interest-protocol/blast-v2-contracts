#!/usr/bin/env node
// Exact-integer calibration for the fixed-price, net-deposits-only rounding model.
// This forecasts rounding drift; State.complete_mint owns the unconditional band check.
import { readFileSync } from 'node:fs';
import { resolve } from 'node:path';
import { pathToFileURL } from 'node:url';

const MAX_MINIMUM = 1_000_000n;
const U64_MAX = (1n << 64n) - 1n;
const DEFAULT_PROFILE = new URL('./fixtures/nvda-mint-drift.json', import.meta.url);

function positive(value, name) {
    if (typeof value !== 'string' || !/^[1-9][0-9]*$/.test(value)) {
        throw new Error(`${name}: expected a positive decimal string`);
    }
    const result = BigInt(value);
    if (result > U64_MAX) throw new Error(`${name}: exceeds u64`);
    return result;
}

function quantities(profile) {
    if (profile.model !== 'fixed-price-net-deposits-only') throw new Error('unsupported drift model');
    const fields = ['minimumSeedNav', 'seedBase', 'lotSize', 'navCap',
        'minimumStartingLeverageBps', 'rebalanceBelowBps', 'rebalanceAboveBps', 'minOrderLots'];
    const p = Object.fromEntries(fields.map(key => [key, positive(profile[key], key)]));
    if (p.minimumSeedNav > p.navCap) throw new Error('seed NAV exceeds cap');
    if (p.rebalanceBelowBps >= p.minimumStartingLeverageBps
        || p.minimumStartingLeverageBps > p.rebalanceAboveBps) throw new Error('invalid starting band');
    if (p.rebalanceAboveBps >= MAX_MINIMUM) throw new Error('band exceeds policy ceiling');
    if (p.minOrderLots < 2n || p.minOrderLots > MAX_MINIMUM) throw new Error('invalid minimum lots');
    if (p.seedBase % p.lotSize !== 0n || p.seedBase <= p.minOrderLots * p.lotSize) {
        throw new Error('seed must exceed the minimum in whole lots');
    }
    return p;
}

// q >= m/(m+1) * Q*D/N implies Q'/Q >= (N'/N)^(m/(m+1)).
// Telescope: L_final >= L_start * (N_start/N_final)^(1/(m+1)).
// Compare powers exactly, without floating-point logs or rounded leverage.
function coversGrowth(p, minimum) {
    const exponent = minimum + 1n;
    return p.minimumStartingLeverageBps ** exponent * p.minimumSeedNav
        >= p.rebalanceBelowBps ** exponent * p.navCap;
}

export function smallestMinimum(profile) {
    const p = quantities(profile);
    let lower = 2n;
    let upper = lower;
    while (!coversGrowth(p, upper)) {
        if (upper === MAX_MINIMUM) throw new Error('growth cannot be covered by a supported minimum');
        lower = upper + 1n;
        upper = upper * 2n > MAX_MINIMUM ? MAX_MINIMUM : upper * 2n;
    }
    while (lower < upper) {
        const middle = (lower + upper) / 2n;
        if (coversGrowth(p, middle)) upper = middle; else lower = middle + 1n;
    }
    return lower;
}

export function simulate(profile, minimum, maxMints = 200_000) {
    const p = quantities(profile);
    if (minimum < 1n || minimum > MAX_MINIMUM) throw new Error('unsupported simulated minimum');
    let nav = p.minimumSeedNav;
    let base = p.seedBase;
    let mints = 0;
    let firstBreach = null;
    while (nav < p.navCap) {
        // Largest integer deposit strictly below the next lot threshold.
        const nextThreshold = (minimum + 1n) * p.lotSize * nav;
        const worstDeposit = (nextThreshold - 1n) / base;
        const deposit = worstDeposit < p.navCap - nav ? worstDeposit : p.navCap - nav;
        const desiredBase = base * deposit / nav;
        if (desiredBase < minimum * p.lotSize) break; // Remaining cap cannot admit a minimum mint.
        if (mints === maxMints) throw new Error('simulation step limit reached');
        base += desiredBase / p.lotSize * p.lotSize;
        nav += deposit;
        mints += 1;
        if (base * p.minimumStartingLeverageBps * p.minimumSeedNav
            < p.rebalanceBelowBps * p.seedBase * nav && firstBreach === null) firstBreach = mints;
    }
    return {
        minimum: minimum.toString(), mints, firstBreach, finalNav: nav.toString(),
        finalLeverageBpsDown: (base * p.minimumStartingLeverageBps * p.minimumSeedNav
            / (p.seedBase * nav)).toString(),
    };
}

export function calibrate(profile) {
    const p = quantities(profile);
    const minimum = smallestMinimum(profile);
    if (minimum !== p.minOrderLots) throw new Error(`profile minimum must equal selected minimum ${minimum}`);
    return {
        model: profile.model, minimum: minimum.toString(),
        minimumNetDepositAtSeed: ((minimum * p.lotSize * p.minimumSeedNav + p.seedBase - 1n)
            / p.seedBase).toString(),
        selected: simulate(profile, minimum), previous: simulate(profile, minimum - 1n),
        condition: 'Starting leverage must be at least minimumStartingLeverageBps; fixed valuation and net deposits only.',
    };
}

// Enforce the reviewed profile on a future activation, without confusing a
// conditional forecast with a proof of live starting leverage.
export function assertCalibratedPolicy(input, profile) {
    const minimum = smallestMinimum(profile);
    const p = quantities(profile);
    if (minimum !== p.minOrderLots) throw new Error('profile minimum is not calibrated');
    const policy = input.rebalancePolicy;
    if (BigInt(policy.rebalanceBelowBps) !== p.rebalanceBelowBps
        || BigInt(policy.rebalanceAboveBps) !== p.rebalanceAboveBps
        || BigInt(policy.targetLeverageBps) !== p.minimumStartingLeverageBps) {
        throw new Error('activation band differs from calibration');
    }
    const configuredMinimum = BigInt(input.vaultPolicy.minOrderLots);
    if (configuredMinimum < minimum || configuredMinimum > MAX_MINIMUM) {
        throw new Error(`activation minimum must be at least ${minimum}`);
    }
    if (BigInt(input.navCap) > p.navCap) throw new Error('activation cap exceeds calibration');
}

export function assertCalibratedSeed(initialized, input, profile) {
    const p = quantities(profile);
    const nav = BigInt(initialized.seed_shareholder_nav);
    const base = BigInt(initialized.position_base);
    if (nav < p.minimumSeedNav || nav > BigInt(input.navCap)) throw new Error('seed NAV outside calibration');
    if (BigInt(initialized.lot_size) !== p.lotSize) throw new Error('seed lot differs from calibration');
    if (base % p.lotSize !== 0n || base <= BigInt(input.vaultPolicy.minOrderLots) * p.lotSize) {
        throw new Error('seed exposure does not exceed minimum in whole lots');
    }
}

if (process.argv[1] && import.meta.url === pathToFileURL(resolve(process.argv[1])).href) {
    try {
        if (process.argv.length > 3) throw new Error('usage: calibrate_mint_minimum.mjs [profile.json]');
        const profile = JSON.parse(readFileSync(process.argv[2] ?? DEFAULT_PROFILE, 'utf8'));
        process.stdout.write(`${JSON.stringify(calibrate(profile), null, 2)}\n`);
    } catch (error) {
        process.stderr.write(`${error.message}\n`);
        process.exitCode = 1;
    }
}
