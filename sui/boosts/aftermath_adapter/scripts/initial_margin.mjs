// Offline preflight only. Move repeats this check using live venue parameters.
const ONE = 10n ** 18n;
const SIGN = 1n << 255n;
const MAX = (1n << 256n) - 1n;
const BPS = 10_000n;
const ceil = (n, d) => (n + d - 1n) / d;

function raw(value) {
    if (typeof value !== 'string' || !/^\d+$/.test(value)) throw new Error('initial margin: expected unsigned IFixed decimal');
    const n = BigInt(value);
    if (n > MAX) throw new Error('initial margin: IFixed carrier overflow');
    return n;
}

const positiveFee = (value) => {
    const n = raw(value);
    return n >= SIGN ? 0n : n;
};

export function assertInitialMargin(input) {
    const { positionImr, venueMargin, rebalancePolicy, pricePolicy } = input;
    if (!venueMargin) throw new Error('initial margin: live venueMargin preview is required');
    const r = raw(positionImr);
    const market = raw(venueMargin.marketImr);
    const haircut = raw(venueMargin.collateralHaircut);
    if (r === 0n || r > ONE || market > r || haircut >= ONE) {
        throw new Error('initial margin: invalid position, market or haircut ratio');
    }
    const fee = positiveFee(venueMargin.takerFee)
        + (venueMargin.priorityTakerFee === null ? 0n : positiveFee(venueMargin.priorityTakerFee));
    if (fee > ONE) throw new Error('initial margin: unusable venue fee');
    const marginBps = ceil(r * BPS, ONE);
    const haircutBps = ceil(haircut * BPS, ONE);
    const feeBps = ceil(fee * BPS, ONE);
    const max = BigInt(rebalancePolicy.maxLeverageBps);
    const slip = BigInt(rebalancePolicy.emergencyMaxSlippageBps);
    const divergence = BigInt(pricePolicy.maxMarkDivergenceBps);
    if (max <= 0n || max > 1_000_000n || slip < 0n || slip >= BPS || divergence < 0n || divergence >= BPS) {
        throw new Error('initial margin: invalid policy bounds');
    }
    const cost = slip + ceil((BPS + slip) * feeBps, BPS);
    if (haircutBps >= BPS || max * cost >= BPS * BPS
        || (BPS * BPS - max * cost) * (BPS - haircutBps)
            <= max * divergence * BPS + max * (BPS + divergence) * marginBps) {
        throw new Error('initial margin: insufficient headroom');
    }
}
