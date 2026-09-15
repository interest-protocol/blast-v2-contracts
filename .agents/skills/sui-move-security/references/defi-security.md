# Sui Move DeFi Security

Apply these rules to shares, vaults, liquid staking, farms, reward programs, AMMs, lending, liquidation, and other economic accounting. Apply the core security skill at the same time.

## Threat-model DeFi as adversarial accounting

- For every economic unit, define who funds it, who owns its claim, when eligibility starts and ends, the numerator and denominator that allocate it, and the transition that checkpoints it. A caller must not acquire value earned before eligibility, retain value after exit, or create a redeemable claim without matching assets or liability.
- Review profitable sequences, not isolated calls. Assume arbitrary identities, transaction ordering, flash-sized capital, same-PTB composition, donations or reward injections, position transfer, split, merge, boundary timing, and repeated calls. Account for every attacker input, output, fee, and remaining liability.
- Give every price, exchange rate, utilization value, reward index, health factor, and liquidity value one authoritative formula and state source. Recompute independent economic postconditions at custody boundaries; a math helper returning successfully does not prove that its result is economically possible.
- Checkpoint time- and state-dependent accounting before any deposit, withdrawal, mint, burn, borrow, repay, liquidation, claim, position transfer, split, merge, weight change, fee change, or reward-schedule change that can alter an entitlement or its denominator.

## Secure shares, vaults, and liquid staking

- Compute mint and burn conversions from a named pre-operation snapshot of accounted assets, liabilities, and total shares after settling rewards, fees, losses, and slashing that economically precede the operation. Enforce minimum shares or assets, maximum input, and deadline; reject zero output.
- Define zero- and near-zero-supply behavior. Prevent first-depositor and donation or injection manipulation with explicit internal accounting and an accepted bootstrap defense such as virtual assets and shares, locked minimum liquidity, or a minimum initial deposit. Prove the defense still holds after almost all shares are redeemed.
- On Sui, trace actual public donation, capital-injection, receive, child-object, and synchronization paths. Do not assume that sending a `Coin<T>` to an object's address joins its private `Balance<T>`; apply donation defenses to value that a real protocol path includes in accounted assets.
- Separate principal, realized rewards, pending deposits, pending exits, protocol fees, reserves, donated or unaccounted assets, and losses whenever their claims or eligibility differ. State exactly which components change the exchange rate and when; never let a raw balance or external report silently reprice claims.
- For epoch or queued staking, bind each position to its activation and exit snapshots. Exclude pending stake from earlier rewards, reserve pending withdrawals before admitting later claims, and prove that reward reporting, deposits, redemptions, fees, and slashing cannot be ordered to transfer value between cohorts.
- Bind each external reward, fee, or slashing report to the exact pool, validator or strategy, epoch, sequence, and authoritative balance delta. Reject duplicate, skipped, stale, future, or out-of-order settlement unless the accepted model defines a safe reconciliation path.
- Permit an exchange rate to fall when the accepted model includes slashing or loss. Do not clamp a real loss into apparent solvency, and charge performance fees only under the declared realized-yield or high-water-mark policy.
- Write a solvency identity covering redeemable shares, pending exits, accrued fees, reserves, and realizable assets. Define final redemption and dust treatment so the last users cannot extract prior cohorts' value or strand an unpayable claim.

## Secure farms and reward programs

- Use a global cumulative reward-per-eligible-unit index plus a per-position checkpoint or debt, or prove an equivalent construction. Settle the global index and position accrual before changing stake, weight, ownership, or schedule, and allocate elapsed rewards using the pre-change eligible stake.
- Define zero eligible stake, program start and end, top-up, rate or allocation change, and leftover behavior. Do not assign an empty interval's rewards or rewards earned before activation to the first later participant; settle the old schedule before installing a new one.
- Fund rewards before they become liabilities and conserve `funded = claimed + claimable + undistributed + remaining` independently for each reward type. Separate staked principal from funded rewards even when they use the same coin type; recovery or administration must not withdraw principal or accrued claims.
- Prevent deposit-then-claim, flash-stake, same-PTB, epoch-boundary, self-referral, and boost sequences from capturing rewards without the intended time or risk. Position transfer, split, merge, and identity splitting must preserve combined claim and eligibility.
- Bind every claim checkpoint or receipt to every varying domain: reward program, pool, position, reward asset, epoch or schedule, and claimant or approved beneficiary. Advance claimed amounts or nonces monotonically before payout.
- Bound boost multipliers and total weighted stake. Update every affected numerator, denominator, and checkpoint atomically; reject duplicate registration and receipts from the wrong pool or reward program.
- Define global and per-position rounding dust. Prove that claiming more often, splitting stake, or repeating minimum-value operations cannot increase rewards beyond the documented bound.

## Prove AMM and lending solvency

- Treat a mutable pool spot price, reserve ratio, or share redemption rate as attacker-influenceable within a PTB. Do not use it to value collateral, rewards, shares, or liquidations without an accepted manipulation-resistant construction and the oracle checks in the core skill.
- For every swap, liquidity mint or burn, fee collection, and flash path, reconcile actual balance deltas and prove the reserve invariant plus fees. Bound minted liquidity by the assets actually supplied and independently assert semantic output bounds around custom fixed-point or wide-integer math.
- For lending, accrue interest, reward, and reserve indices before changing supply, debt, collateral, or configuration. Round debt against the borrower, validate final health after every collateral or liability change, and reconcile cash, supplier claims, collectible debt, reserves, and recognized bad debt. Name whether reserves, insurance, suppliers, or frozen claims absorb each shortfall; never hide loss with a clamp or silent debt deletion.
- Make liquidation reduce debt and seize only the bounded collateral and fee justified by a fresh price. Define close and dust behavior, and prove that a borrower controlling the liquidator cannot manufacture profit by first corrupting its own collateral, debt, or health accounting.

## Treat rounding as value transfer

- Document who receives each remainder.
- Round user payouts and collateral values down by default.
- Round user obligations, protocol fees, and debt up by default.
- Reject zero-output trades, zero-share deposits, and other silent value loss.
- Use wider intermediates and prove the narrowing boundary.
- Prefer pinned standard-library `checked_*`, `mul_div`, `mul_div_ceil`, `div_ceil`, min/max, and integer bounds.
- Include rounding direction in function names.
- Test zero, one atomic unit, maximum supported values, both sides of thresholds, intermediate overflow, exact division, and one-unit remainders.
- Test inverse operations against a documented dust bound.

## Completion gate

The DeFi review is complete only when every economic unit has one authority and
formula, every profitable sequence preserves solvency and cohort eligibility,
every remainder has an owner, and operation and sequence tests reconcile each
asset independently.
