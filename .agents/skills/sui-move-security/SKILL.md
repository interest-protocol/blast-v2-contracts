---
name: sui-move-security
description: Secure Sui Move transitions, authority, canonical object and type identity, signed actions, replay controls, bounded state, received and derived objects, arithmetic, asset custody, DeFi shares, rewards, staking, farms, lending, AMMs, adapters, time, oracles, randomness, pauses, versions, and upgrades. Use for any privileged, stateful, economic, cryptographic, shared-object, or external-integration Move change or review.
---

# Sui Move Security

Make invalid transitions unrepresentable where possible and reject the rest before mutation.

Target repository instructions, accepted design records, pinned toolchain behavior, and published compatibility commitments take precedence over this standard's examples.

Before code, name the assets and safety, conservation, liveness, and exit invariants; authorities and worst-case compromise; untrusted callers, composition, and dependencies; and required failure behavior.

For each public or entry function, same-PTB composition, and reachable multi-transaction sequence, prove that a valid pre-state produces a valid post-state, an abort commits no partial effects, and returned objects, capabilities, witnesses, receipts, or other values cannot be recombined to violate an invariant. Security is not established until every callable path and composition preserves the package's safety, conservation, authority, liveness, and exit invariants.

Validate every `TxContext`-bearing callable signature against the target protocol. Where protocol-135 rules are active, permit at most one `&mut TxContext` or multiple immutable `&TxContext` parameters, never a by-value parameter or any returned value or reference. Keep context last as repository style, not as the security proof.

Before any irreversible or state-gating transition, prove that every required exit, settlement, cleanup, retry, cancellation, authority rotation, and recovery operation remains reachable. Reject a transition that can leave shared state permanently paused, locked, full, orphaned, version-incompatible, or dependent on an unavailable capability, object, or external system, unless it is a deliberate terminal state with all obligations already discharged.

## Fail fast and mutate last

Abort on the cheapest decisive condition. Exhaust checks available from current information before allocation, cryptography, dependency work, mutation, asset movement, or event construction. Use this order:

1. package version, pause, or an active seam lock;
2. cheap lifecycle, input, identity, deadline, and authorization checks, including rejection of identical type arguments for roles that must differ;
3. bounds, available-balance, and other economic checks that need no proposed value;
4. required read-only external data, signature work, deserialization, or expensive math;
5. compute each fallible proposed final value once before mutation, naming it when checks or later mutation reuse it;
6. validate all fallible postconditions, including minimum output and maximum input, against the proposed values;
7. mutate state and move assets;
8. emit the final-state event;
9. return owned values.

The numbered order applies when dependency calls are read-only or can be last. A result-bearing composable handoff is a deliberate exception: finish every local check, acquire the narrowest lock or issue a linear receipt, interact, validate exact receipts and balance deltas, commit core state and asset movements, clear the lock, then emit. Do not postpone a check that could have preceded an effect or interaction.

Guard order is observable API. Test overlapping invalid conditions. Abort rollback does not justify avoidable late checks: early failure saves gas, preserves diagnostic precedence, and shrinks the reasoning surface.

Reject a setter whose new value equals the current value before mutation, with its own stable error, so every emitted old/new pair records a real transition. A non-mutating authorization or discovery fact may still emit the value it newly commits.

## Express authority with types

- Use a typed capability or witness instead of an address check for privileged operations.
- Inventory every authority constructor, issuance, transfer, share, receive, rotation, revocation, and destruction path. Prove each use is bound to the exact object and domain, and that abilities match intended custody.
- Verify a revocable cap against live registry state before issuing a drop-only witness.
- Let the concern-owning module validate that witness locally.
- Keep a global cap minimal. Store target IDs only in a deliberately per-instance cap.
- Separate root authority from routine administration.
- Use delayed, explicit, test-covered root rotation. Add cancellation or recipient acceptance when the threat model requires it. Before burning, renouncing, or irreversibly handing off the last root or upgrade authority, prove successor usability and required exit and recovery liveness.
- Never infer broad authority from unrelated object possession or transaction sender alone.
- Do not pass overlapping capabilities to one setter or transition.
- Give capability holders a production lifecycle for safe destruction or revocation when stranded objects are possible.
- Reject zero addresses for recipients and authorities unless the zero address has an explicit protocol meaning.
- For a permissionless irreversible transition, take economic parameters from accepted stored policy, derived state, a sealed adapter type, or a compiled value that is itself the accepted immutable policy, never from caller choice. Otherwise fail closed.

## Bind canonical identity, not only shape

- A protocol-defined object type does not by itself prove that the caller supplied the canonical instance. Prove unique construction and custody, or compare its ID or original type against authoritative state before trusting its balances, configuration, price, or authority.
- Bind every per-instance capability to the exact target it governs. A deliberately protocol-global capability can omit a target ID only when singleton construction and live registry checks make cross-instance use impossible.
- Treat caller-selected generic type arguments as untrusted. A bare `<T>`, `<T: drop>`, `Coin<T>`, or `TypeName` does not prove asset identity, witness sealing, package origin, or construction rights.
- At every generic asset or witness boundary, bind the caller-selected type to authoritative state through the target and capability signatures, or verify the expected original type, package, sealed constructor, and target domain before accounting or authorization.

## If the contract verifies off-chain signatures

- Bind authorization to the exact action, actor or beneficiary, target object or original type, expiry, and any domain not already fixed by a dedicated key.
- Reject malformed or non-canonical messages before verification. Prevent replay, and make third-party submission fail harmlessly or produce only the approved effect.
- If one key spans actions, deployments, or networks, use explicit domain separation and document the shared compromise scope.

## Prevent replay with linearity

- Prefer consuming a unique authorization resource over storing `claimed: bool` or a parallel nonce.
- Validate first, consume the resource, construct the result, emit the final-state event, then return the result.
- Use non-copyable, non-droppable payloads for migration, flash, or settlement handoffs.
- Require the exact sealed witness type to redeem a cross-package handoff.
- When admitting a witness by `TypeName`, reject primitive and vector types and prove its constructor is sealed in the approved module; `TypeName` alone cannot prove construction rights.
- Treat events as index facts, never replay guards.
- For a repeatable signed operation, consume a nonce, digest, or linear authorization exactly once and define bounded storage, eviction, and cleanup. Permit intentional replay only when it is documented and safe.

## Bound state and work

- Bound every persistent collection with a named protocol constant, and record the reachable maximum plus intentional slack.
- Bound every loop whose input can grow on chain.
- Check duplicates before consuming capacity.
- Define behavior at capacity. When bounded work is optional, prefer a safe liveness-preserving fallback over aborting the user's primary transition.
- Test empty, full, first-over-capacity, duplicate, removal, and re-addition cases.
- Avoid public inputs that cause unbounded deserialization, iteration, event size, or dynamic-field growth.
- Keep pending work and retry state bounded and explicitly releasable.
- Identify every shared-object write hotspot. Shard independent state or use a different ownership mode when one global mutable object lets unrelated callers serialize or deny progress; use immutable shared reads when mutation is unnecessary.

## Defend time, prices, and randomness

- Enforce every invariant on chain. Treat each public function as directly callable and PTB-composable; an SDK, UI, or expected transaction shape is never authority.
- Use the canonical immutable `Clock` for near-real-time security decisions. Define units and inclusive or exclusive deadline semantics, and reject stale or impossible future timestamps where relevant; epoch-start time is only a coarse source.
- When execution can change between signing and inclusion, bind the transition to user- or signer-approved maximum input, minimum output, and deadline. Never assume favorable transaction ordering.
- Before economic use, validate oracle source and feed identity, original type, pair, units or exponent, valid range, update time and freshness, confidence or deviation, liquidity assumptions, and whether a caller can select among historical updates. Define fail-closed or bounded fallback behavior.
- Never derive economic randomness from object IDs, sender, `Clock`, or transaction data. For `sui::random`, keep the economic endpoint private `entry`, create `RandomGenerator` inside the consuming module, obey post-random PTB restrictions, balance resource use across outcomes, and use commit-reveal with inputs fixed before reveal when atomic abort selection remains unsafe.

## Threat-model DeFi as adversarial accounting

- For every economic unit, define who funds it, who owns its claim, when eligibility starts and ends, the numerator and denominator that allocate it, and the transition that checkpoints it. A caller must not acquire value earned before eligibility, retain value after exit, or create a redeemable claim without matching assets or liability.
- Review profitable sequences, not isolated calls. Assume arbitrary identities, transaction ordering, flash-sized capital, same-PTB composition, donations or reward injections, position transfer, split, and merge, boundary timing, and repeated calls. Account for every attacker input, output, fee, and remaining liability.
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

- Treat a mutable pool spot price, reserve ratio, or share redemption rate as attacker-influenceable within a PTB. Do not use it to value collateral, rewards, shares, or liquidations without an accepted manipulation-resistant construction and the oracle checks above.
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

## Preserve conservation and custody

Write and test one operation-specific identity per asset type, never a mixed-unit equation, derived from:

```text
assets in = assets out + reserves + accrued fees + pending custody + explicitly burned amount
```

- Keep reserves, fees, pending burns, allocations, residuals, and claims separate when their owner or terminal treatment differs.
- For every admitted asset, document original type, mint and supply authority, deny, pause, or action restrictions, units, and the authoritative balance delta. Reject assets whose controls can break mandatory settlement or exit invariants unless an accepted admission decision records and bounds that risk explicitly.
- Use actual balances as authority, never event-only counters or SDK previews.
- Reconcile after every operation and multi-operation sequence.
- Make burn, disposal, refund, fee, residual, and rounding treatment explicit.
- Do not call disposal a burn unless native supply authority confirms destruction.
- Reject unexpected residuals or clamps that could conceal a broken invariant.

## Defend external seams

- Perform every locally available check before external reads, calls, or asset handoffs.
- Validate returned object identity, original type, package, pair, tier, units, amounts, actual balance deltas, liquidity, price deviation, freshness, and residual bounds.
- Keep external dependency and failure surfaces in adapters, not core.
- Do not cargo-cult an EVM reentrancy guard onto ordinary statically resolved Move calls. Threat-model PTB composition and flash, hot-potato, or explicit callback-like handoffs; lock only the smallest shared seam until exact receipt and repayment validation completes.
- Do not support an external venue whose required payment or custody model violates core invariants.
- Verify deployed bytecode and ABI; a local link stub proves type compatibility only.
- Treat `Receiving<T>` as proof that the referenced object is owned by the supplied parent at the recorded version, not proof that the object satisfies protocol admission or provenance. Validate expected type and identity, bound intake, and define unreceived-object cleanup before accepting it.
- For derived objects, namespace and validate caller-controlled keys, prevent unauthorized first-claim races, bound permanent claim-marker growth, and account for assets or objects sent to the deterministic address before the derived UID is claimed. Child deletion does not release the claimed key and can strand pre-sent assets.

## Define pause, version, and upgrade behavior

- Define pause scope exactly and preserve user exits and mandatory settlement unless explicitly rejected by the design. Emergency authority may reduce risk, not seize, reprice, or rewrite user accounting.
- Model an upgrade as publication of a new immutable package version, not in-place mutation. Old package versions remain callable, module initializers do not rerun, existing public function signatures must remain unchanged except for permitted relaxation of generic ability constraints, and struct and enum layouts and abilities must remain unchanged.
- Check the diff against the active `UpgradeCap` policy. `compatible` may change implementations and non-public signatures, relax generic ability constraints, add declarations, and change dependencies while preserving link and layout compatibility; `additive` may only add declarations and change dependencies; `dep_only` may only change dependencies.
- When stored shape must change, introduce a new type and an authorized migration, or use a dynamic-extension seam designed before publication; never assume upgraded code can add a field to an existing object.
- For an upgradeable package with operational activation, gate every mutation of shared protocol state at its own use site with an explicit package version before other guards; a witness minted before cutover must not unlock an old mutator.
- Keep native upgrade commit separate from operational activation. Activate only the expected next compiled generation so a wrong build leaves the previous generation able to authorize repair.
- A dependent package stays linked to the dependency generation it was published or upgraded against. Before activation or destroying its `UpgradeCap`, prove every dependent route survives or schedule an explicit dependency re-link; never make a dependent immutable while it calls a seam the cutover closes.
- Do not version-gate a self-custodial exit or deletion of a caller-owned inert object when it mutates no shared state.
- Validate that `Publisher` and `UpgradeCap` belong to the original package before custody.
- When the pinned framework provides `package::original_package_id(&UpgradeCap)`, use it for a cap that may have crossed upgrades and reject in-progress or inconsistent lineage. Do not assume that API exists on an older pin.
- Validate exact upgrade digests and matching framework receipts.
- Permit upgrade-policy changes only toward more restrictive settings; the framework exposes no loosening operation, so stop at the strictest policy that preserves any required rescue path.
- Keep wrapped upgrade custody and shared-state version gates; neither replaces the other.
- Do not add speculative governance cutovers, disable paths, or replacement-authority hooks.
- Keep secrets, private transaction material, and deployment credentials out of source, logs, fixtures, and summaries.
