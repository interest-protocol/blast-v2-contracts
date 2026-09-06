# Research notes: dynamic AMM fees and a volume-driven V2

Research date: 2026-09-05. Scope: primary research useful for a constant-product pool whose percentage swap fee rises with time-weighted trading volume. This note separates published results from proposed derivations; it does not establish production parameters or optimality for Blast.

## What the papers establish

### 1. Revenue optimization with fees outside reserves

Leonardo Baggiani, Martin Herdegen, Leandro Sánchez-Betancourt, *Optimal Dynamic Fees in Automated Market Makers* (2025), especially sections 2–3. [Primary paper](https://arxiv.org/html/2506.02869v1).

The model collects fees in the numéraire asset into an account outside pool reserves. It controls separate buy and sell fees to maximize expected fee revenue, optionally penalizing inventory/price deviations. Trader arrival intensity responds exponentially to the difference between the fee-inclusive AMM execution price and an external price. Approximate optimal controls depend on inventory and external prices; they are not functions of recent gross volume alone.

Useful consequence for Blast: separate fee balances are compatible with a serious dynamic-fee model. Revenue optimization requires a model of how traders respond to execution costs. The paper's oracle, discrete trade grid, fixed liquidity horizon and estimated arrival parameters prevent treating its optimizer as a directly portable permissionless meme-pool algorithm.

### 2. Routed demand can reverse the naive volume argument

Steven Campbell, Philippe Bergault, Jason Milionis, Marcel Nutz, *Optimal Fees for Liquidity Provision in Automated Market Makers* (first posted 2025), especially sections 1.2, 4–5. [Primary paper](https://arxiv.org/html/2508.08152v1), [authors' simulation code](https://github.com/JasonSome/cpmm-trading/tree/master).

This directly models a constant-product AMM competing with a CEX, with fundamental traders routing orders to the better venue and arbitrageurs exploiting discrepancies. Its calibration uses ETH/USDC market data. Across the normal-market regime, the optimal LP-profit fee generally rises with volatility but falls with fundamental demand; low-demand cases are more complicated. Competitive external execution costs matter substantially.

This contradicts a universal claim that higher observed volume necessarily implies a higher economically optimal fee. A rising-volume fee can still be the chosen product policy. Its parameters must be judged against retained routed volume and LP outcomes, rather than justified by volume alone. The calibration is not evidence about new Sui meme coins with no comparable CEX market. The fetched HTML displays an internal manuscript date different from its arXiv version banner; conclusions here are tied to the linked text, not an asserted revision chronology.

### 3. Optimal fees depend on demand elasticity and beneficiary incentives

Austin Adams, Ciamac C. Moallemi, Sara Reynolds, Dan Robinson, *am-AMM: An Auction-Managed Automated Market Maker* (2024), sections 3–4. [Primary paper](https://arxiv.org/html/2403.03367v1).

An auction chooses a temporary pool manager who sets a capped fee, receives swap fees and pays rent to LPs. With demand function `H(f,L)`, retail fee revenue is `f·H(f,L)`; the manager's equilibrium objective additionally subtracts arbitrage excess. This uses market participants to discover demand sensitivity rather than prescribing a universal on-chain fee curve.

The manager effectively recovers fees on its own trades. The authors flag the resulting sandwich incentives. For Blast, an LP or creator can likewise recover a portion of fees on manufactured volume: gross charged fees are not automatically the attacker's net expense. An auction-manager architecture is not needed for the current request; its incentive analysis is useful regardless.

### 4. Why volatility and turnover should not be conflated

Jason Milionis, Ciamac C. Moallemi, Tim Roughgarden, Anthony Lee Zhang, *Automated Market Making and Loss-Versus-Rebalancing*, example 3. [Primary paper](https://arxiv.org/html/2208.06046v5).

Under the paper's frictionless continuous-time model without trading fees, a constant-product pool has instantaneous adverse-selection loss per unit pool value `LVR/value = σ²/8`. The relevant input is price variance, not gross volume. This is a benchmark describing stale-price losses, not a production fee formula, and does not include Blast's burns or recipient split.

Consequently, a volume controller is a measure of trading activity. It may correlate with risk, but cannot distinguish a volatile information event from high balanced retail demand or repeated self-trading using volume alone. Backtesting should measure both fee revenue and execution markouts/LP performance.

### 5. Empirical warning against maximizing the fee counter

Robin Fritsch, Andrea Canidio, *Measuring Arbitrage Losses and Profitability of AMM Liquidity* (WWW 2024 Companion). [Primary paper](https://arxiv.org/html/2404.05803v1).

The study combines historical Uniswap fee data with simulated arbitrage against Binance prices over 2022–2023. Fees fail to cover estimated arbitrage losses in many studied large pools; the studied passive V2 positions perform better than their V3 counterparts. Faster trading opportunities reduce estimated losses, with materially different effects across pairs.

These are observations under the study's assumptions, not proof that V2 always beats concentrated liquidity. More importantly for evaluation, replaying historical swaps at a new higher rate and counting the additional fees is not a credible counterfactual: some trades would reroute or disappear. Blast simulations need responsive traders and competing liquidity, and should report the assumptions separately from empirical evidence.

## Own derivations for evaluating a volume fee

The following are elementary model derivations for this task, not claims of a new optimal AMM mechanism.

### Revenue and elasticity

Let `D(f)` be expected executed volume at percentage fee `f`, holding other conditions fixed. Then

```text
R(f) = f · D(f)
ε(f) = −f · D′(f) / D(f)
R′(f) = D(f) · (1 − ε(f))
```

Increasing the rate increases local gross revenue when elasticity is below one; it decreases revenue above one. For the illustrative demand model `D(f)=A·exp(−κf)`, revenue is maximized at `f=1/κ` within allowed bounds, independently of demand scale `A`. A bigger market is therefore not, by itself, a derivation of a bigger optimal percentage. Changes in elasticity, adverse selection, liquidity supply or a deliberate monetization objective can justify a different policy.

### Time weighting gives a measurable maintenance cost

For quote-volume impulses `qᵢ` at timestamps `tᵢ`, define

```text
V(t) = Σ qᵢ · exp[−λ(t−tᵢ)]
λ = ln(2) / half_life
dV/dt = executed_quote_volume_rate − λV
```

Holding the activity state at `V*` requires executed volume at rate `λV*`. An isolated contribution halves after one half-life. If an attacker recaptures fraction `s` of its swap fees through LP, creator or other entitlements, direct unrecovered fee expense is approximately

```text
(1−s) · f(V*) · λV*    quote units per unit time
```

Add burn expense, gas and execution effects; subtract any arbitrage/MEV or other gains. This is a controlled approximation, not a universal lower bound on attack cost. Fee collection can be profitable for the protocol while the resulting higher rate still harms later routing. Evaluate those separately.

### A bounded candidate curve and what it does prove

For illustrative positive parameters, `f(V)=f₀+Δf·V/(K+V)` has

```text
f(0) = f₀
f(K) = f₀ + Δf/2
lim[V→∞] f(V) = f₀ + Δf
f′(V) = Δf · K / (K+V)² > 0
```

It gives monotone increasing rates and diminishing sensitivity, with no abrupt threshold. The parameters have intelligible meanings: floor, maximum surcharge, and half-surcharge volume. These properties do not establish superior economics. A fixed `K` needs pool/quote scaling; a moving liquidity-based `K` needs defenses against temporary deposits or withdrawals changing the denominator. A short/long volume ratio adapts to a pool's normal activity, but under sustained constant volume both averages converge, so that ratio alone loses a persistent high-volume surcharge.

If the entire trade pays its pre-trade rate, the first large trade after quiet gets the low rate while raising later traders' rates. Including its own volume progressively avoids that particular loophole, but requires explicit fee integration and rounding semantics. A nonlinear integrated curve may add logarithms or an exact-output solver; a piecewise-linear integrated curve can offer simpler exact arithmetic. This choice concerns consistent execution and splitting behavior, not merely computational convenience.

## Suggested evaluation before choosing parameters

- Compare constant, capped linear, saturating, and short/long-volume-ratio policies using the same responsive demand and external-price paths.
- Include quiet-to-burst, sustained activity, balanced churn, directional jumps, and declining activity.
- Sweep fee recapture from zero to nearly all fees, with temporary LP entry, creator ownership, and burn enabled/disabled.
- Test large-first-trade, transaction splitting, same-timestamp trades, delayed updates, and liquidity-denominator changes.
- Report executed routed volume, net LP outcome, protocol/creator revenue, effective all-in trader cost, and manufacture/maintenance cost separately.

This supports selecting a well-defined volume-driven policy and measuring its tradeoffs. None of the reviewed papers validates a particular Blast fee floor, cap, half-life or burn rate without calibration.
