# Time, Oracles, and Randomness

Apply these rules to deadlines, time-dependent authorization, slippage,
oracles, price feeds, or random outcomes.

## Treat transaction shape as untrusted

- Enforce every invariant on chain. Treat each public function as directly
  callable and PTB-composable; an SDK, UI, or expected transaction shape is not
  authority.
- When execution can change between signing and inclusion, bind the transition
  to user- or signer-approved maximum input, minimum output, and deadline.
  Assume adversarial transaction ordering.

## Bind time precisely

- Use the canonical immutable `Clock` for near-real-time security decisions.
- Define units and inclusive or exclusive deadline semantics. Reject stale or
  impossible future timestamps where relevant.
- Use epoch-start time only when its coarse granularity matches the invariant.

## Validate oracle meaning

Before economic use, validate the oracle source and feed identity, original
type, pair, units or exponent, valid range, update time and freshness,
confidence or deviation, liquidity assumptions, and whether a caller can select
among historical updates. Define fail-closed or bounded fallback behavior.

## Make random outcomes commit-safe

- Derive economic randomness from an accepted randomness source rather than
  object IDs, sender, `Clock`, or transaction data.
- For `sui::random`, keep the economic endpoint private `entry`, create
  `RandomGenerator` inside the consuming module, obey post-random PTB
  restrictions, and balance resource use across outcomes.
- Use commit-reveal with inputs fixed before reveal when atomic abort selection
  remains unsafe.

The design is complete only when every time and oracle input has an identity,
unit, validity boundary, and fallback, and no caller-controlled transaction
shape can selectively commit a favorable random or economic result.
