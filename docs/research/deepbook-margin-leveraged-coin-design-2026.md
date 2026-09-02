# DeepBook Margin leveraged-coin design for Blast

- Date: 2026-08-31
- Status: architecture recommendation; not an implementation decision
- Scope: standalone LONG and SHORT fungible coins backed by DeepBook Margin,
  then admitted as Quote assets in the Blast meme launchpad

## Executive conclusion

DeepBook Margin can supply the execution, borrowing, oracle checks, interest
accounting, and liquidation engine for a leveraged coin. It is leveraged spot,
not a perpetual: a LONG borrows Quote and buys Base; a SHORT borrows Base and
sells it. LONG and SHORT are separate series and do not hedge one another.

The economic design is viable, but the current public DeepBook interface is not
yet sufficient for a trustless pooled coin. `MarginManager` fixes `owner` to
`tx_context::sender`, and deposit, withdrawal, borrowing, repayment, order, and
cancel paths validate that address. A keeper or multisig that owns a public
coin's manager can therefore bypass the coin protocol and withdraw or trade the
backing directly. The official documentation also describes deposits and
withdrawals as owner-only
([Margin Manager](https://docs.sui.io/onchain-finance/deepbook/deepbook-margin/contract-information/margin-manager)).

There are two honest release lanes:

1. A small, capped meme beta uses one disclosed multisig-owned MarginManager per
   coin. This is custodial strategy management, even though trading,
   collateral, debt, and liquidation are on chain.
2. Production waits for a DeepBook application-owner capability. The
   capability is stored inside the coin's shared `Series`; address-owner paths
   are disabled for that manager. Then users can invoke bounded coin operations
   without any signer being able to withdraw backing directly.

Blast remains independent in either lane. It only holds and trades the
leveraged coin as `Quote`; it never reads DeepBook health, price, debt, or NAV
to authorize a curve trade or graduation.

## 1. Verified DeepBook Margin behavior

DeepBook Margin extends the DeepBook spot order book with three shared objects:

- `MarginManager<Base, Quote>` holds free and order-locked assets and one loan;
- `MarginPool<Asset>` lends one asset and accounts debt through borrow shares;
- `MarginRegistry` controls enabled pools, oracles, risk thresholds, rewards,
  and package versions.

Each manager binds to one DeepBook pool and can borrow from only one margin
pool at a time. Risk is:

```text
risk_ratio = oracle-valued assets / accrued debt.
```

Borrow and withdrawal require higher ratios than liquidation. Anyone may
liquidate below the configured threshold, with no grace period. Debt interest
grows with lending-pool utilization and can move an unchanged position toward
liquidation
([overview](https://docs.sui.io/onchain-finance/deepbook/deepbook-margin/),
[design](https://docs.sui.io/onchain-finance/deepbook/deepbook-margin/design),
[risks](https://docs.sui.io/onchain-finance/deepbook/deepbook-margin/margin-risks)).

The deployed-source pin reviewed here is
[`deepbookv3@c43c84a`](https://github.com/MystenLabs/deepbookv3/tree/c43c84a4826bb765147b08a1fbd1fc92826b85d3),
the commit that registered mainnet Margin package v7. `Published.toml` records
published package
`0x55ee8099674e46266df2bf0ffed9569e1511aa269f2a9b8c63a2c72f16404e72`
with original ID
`0x97d9473771b01f77b0940c589484184b49f6444627ec121314fae6a6d36fb86b`
([source](https://github.com/MystenLabs/deepbookv3/blob/c43c84a4826bb765147b08a1fbd1fc92826b85d3/packages/deepbook_margin/Published.toml)).
A direct Sui mainnet GraphQL read at checkpoint `317191646` returned package
version `7` and digest
`BKr4eTEaS5GQyccczYUf9JGTD578qqwsN8XxwiSyuzDD`.

### 1.1 The current authorization blocker

`MarginManager` stores an address owner. Construction sets that owner to
`ctx.sender()`. The manager is shared, but its sensitive methods compare the
transaction sender with the stored address
([state and construction](https://github.com/MystenLabs/deepbookv3/blob/c43c84a4826bb765147b08a1fbd1fc92826b85d3/packages/deepbook_margin/sources/margin_manager.move#L75-L114),
[owner validation](https://github.com/MystenLabs/deepbookv3/blob/c43c84a4826bb765147b08a1fbd1fc92826b85d3/packages/deepbook_margin/sources/margin_manager.move#L1019-L1155)).

`new_with_initializer` does not solve application custody. Its hot potato only
ensures the manager is shared, and `MarginManager` has `key` but not `store`, so
another package cannot wrap the manager inside its own shared vault
([creation](https://github.com/MystenLabs/deepbookv3/blob/c43c84a4826bb765147b08a1fbd1fc92826b85d3/packages/deepbook_margin/sources/margin_manager.move#L329-L370)).

Consequences for a pooled fungible coin:

```text
keeper owns manager
    -> keeper can call DeepBook directly
    -> Series rules cannot constrain withdrawal, market, or order direction
    -> coin backing is keeper-custodied.
```

A Sui multisig reduces key-person risk but does not change this invariant. The
multisig can still authorize any owner operation.

## 2. LONG and SHORT balance sheets

Let:

```text
P   = safe Base price in Quote units
B   = free plus order-locked Base assets
Q   = free plus order-locked Quote assets
Db  = accrued Base debt
Dq  = accrued Quote debt
N   = coin NAV in Quote units
```

The complete NAV equation is:

```text
N = Q + P*B - Dq - P*Db.
```

DeepBook's `calculate_assets` includes both BalanceManager balances and balances
locked in the DeepBook pool. `calculate_debts` converts borrow shares to the
current interest-accrued amount
([source](https://github.com/MystenLabs/deepbookv3/blob/c43c84a4826bb765147b08a1fbd1fc92826b85d3/packages/deepbook_margin/sources/margin_manager.move#L697-L765)).
The manager permits only one debt side, so a valid series requires exactly one
of `Db` and `Dq` to be nonzero.

For a LONG with target directional leverage `L`:

```text
Dq       = (L-1)N
P*B      = L*N
Db       = 0
risk_ratio_long = L/(L-1).
```

The protocol deposits Quote, borrows `(L-1)` times equity in Quote, and spends
the deposit plus borrow buying Base.

For a SHORT with target directional leverage `L`:

```text
P*Db     = L*N
Q        = (L+1)N
Dq       = 0
risk_ratio_short = (L+1)/L.
```

The protocol deposits Quote, borrows Base worth `L` times equity, and sells the
borrowed Base for Quote.

Therefore identically labelled sides are not equally collateralized:

```text
2x LONG  starts at risk ratio 2.0
2x SHORT starts at risk ratio 1.5.
```

Equal risk-ratio headroom occurs when:

```text
L_short = L_long - 1.
```

Thus `2x LONG / 1x SHORT` or `3x LONG / 2x SHORT` are naturally symmetric under
spot borrowing. A `2x/2x` product is possible, but the SHORT begins closer to
liquidation and needs separate risk disclosure and capacity limits.

No opposite coin is required. Lenders in the Quote margin pool fund the LONG;
lenders in the Base margin pool fund the SHORT. Equal LONG and SHORT positions
inside one protocol account would approximately cancel the desired exposure
while retaining spreads, fees, and borrow costs.

### 2.1 Liquidation boundaries

Let `h` be the pool's liquidation risk ratio and `p=P/P0`. Ignoring interest,
fees, and slippage after opening:

```text
LONG:  RR(p) = [L/(L-1)]p
       liquidatable when p < h(L-1)/L

SHORT: RR(p) = [(L+1)/L]/p
       liquidatable when p > (L+1)/(Lh).
```

Current official documentation uses SUI/USDC examples with a `1.1`
liquidation ratio and 5x maximum gross leverage. Under that example, a 2x LONG
becomes liquidatable after about a 45% fall, while a 2x SHORT becomes
liquidatable after about a 36.4% rise. Borrow interest and execution costs move
both boundaries closer. Runtime registry values are governance-controlled and
must be read on chain for every operation; these example numbers must not be
hardcoded.

DeepBook liquidations cancel orders, repay enough debt to target a healthier
ratio when possible, transfer collateral plus rewards to the liquidator and
pool, and may record pool bad debt when assets are insufficient
([source](https://github.com/MystenLabs/deepbookv3/blob/c43c84a4826bb765147b08a1fbd1fc92826b85d3/packages/deepbook_margin/sources/margin_manager.move#L2205-L2377)).
Liquidation is not guaranteed to close the entire series. The coin protocol
must reconcile the surviving manager assets and debt, stop minting, and either
resume from a reviewed healthy state or shut down pro rata.

## 3. Recommended standalone coin protocol

Deploy the coin protocol independently of Blast. Use one `Series` and one
MarginManager for each side:

```text
LeveragedCoin package
├── Series<SUI, USDC, Long, SUI2L>
│   └── one SUI/USDC MarginManager with Quote debt
└── Series<SUI, USDC, Short, SUI2S>
    └── one SUI/USDC MarginManager with Base debt

Blast launchpad
└── Launch<Meme, SUI2L> or Launch<Meme, SUI2S>
```

Do not share managers, collateral, debt, share supply, or NAV between the two
coins. Do not net LONG and SHORT exposure. Cross-series netting creates an
allocation oracle and lets a failure transfer value between fungible share
classes.

The minimum consensus-critical `Series` state is:

```text
coin treasury capability and total supply authority
exact Base, Quote, side, DeepBook pool, and MarginManager identity
target leverage and bounded rebalance policy
accepted DeepBook original package/version policy
lifecycle: Active | ReduceOnly | Shutdown
fee balances separated from holder backing
application-owner capability, when DeepBook supports it
```

NAV projections, charts, USD displays, capacity forecasts, and transaction
construction stay in the SDK. Contract transitions recompute NAV and health
only when required to protect share issue, redemption, leverage, or settlement.

### 3.1 Required DeepBook application-owner mode

Production requires a non-copyable `ManagerOwnerCap` or equivalent:

```text
ManagerOwnerCap {
    manager_id,
    mode = application_only
}
```

The cap is created with the manager and stored as a private field of the shared
`Series`. Every owner-sensitive DeepBook entry must accept this capability, or
a capability-derived proof, instead of `ctx.sender`. Address-owner withdrawal
and trading must be disabled for application-mode managers. Supporting the cap
on trade while leaving an address withdrawal path would not solve custody.

The change must cover:

- deposit and withdrawal;
- borrow and repay;
- market, limit, modify, cancel, and settle operations;
- conditional-order creation and cancellation;
- DEEP staking or referral actions if enabled.

Liquidation and safe settlement can remain permissionless. A new manager type
or a versioned/dynamic authorization record is safer than trying to reinterpret
existing address-owned managers.

## 4. Atomic share operations

Use no resting orders, DEEP fee asset, referral positions, or cross-pool assets
in the first release. That keeps NAV to Base, Quote, and one accrued debt. All
share mutations must end with zero open orders and use the same safe Pyth
readings and current debt-share conversion as DeepBook.

### 4.1 Mint

For pre-operation NAV `N0` and supply `S0`:

1. Read and validate DeepBook pool enablement, package version, Pyth price,
   margin-pool utilization, risk parameters, and book depth.
2. Deposit the user's Quote collateral.
3. Borrow the required debt-side asset.
4. Execute a price-bounded market order.
5. Re-read actual Base, Quote, debt, open orders, risk ratio, and NAV.
6. Require correct debt side, zero resting orders, target leverage band,
   minimum risk buffer, maximum execution loss, and user deadline.
7. Mint from realized incremental NAV, not input cash.

```text
dN = N_after - N0

shares_out = floor(S0*dN/N0)          when S0 > 0
shares_out = normalized(N_after)      for the bootstrap mint.
```

Require `dN>0` and `shares_out>=min_shares`. Because borrow, trade, post-state
validation, and mint occur in one Sui transaction, any failed assertion rolls
the entire operation back. The depositing user bears its spread, fee, and
slippage instead of transferring them to existing holders.

### 4.2 Redemption

For `x` shares redeemed from pre-operation supply `S0` and NAV `N0`:

1. Calculate the proportional exposure and debt reduction.
2. LONG sells Base and repays Quote debt. SHORT buys Base and repays Base debt.
3. Use DeepBook's market-order-and-repay path and validate the actual post-state.
4. Preserve the non-redeeming cohort's pre-operation NAV per share.

```text
NAV_that_must_remain = ceil(N0*(S0-x)/S0)
payout = N_after_unwind - NAV_that_must_remain.
```

Require `payout>=min_quote_out`, burn `x`, and transfer the realized Quote
payout. This assigns redemption execution cost to the redeemer. A full-supply
redemption is a special close: cancel orders, close all exposure, repay all
debt, burn all shares, and distribute all remaining assets.

Do not pay redemptions solely from an idle Quote buffer while leaving debt and
exposure unchanged. That raises leverage for remaining holders.

### 4.3 Rebalance and emergency reduction

Effective directional leverage is:

```text
LONG:  P*B/N
SHORT: P*Db/N.
```

Expose permissionless `rebalance` only when a deterministic on-chain predicate
is true. Risk-increasing rebalances require fresh prices, enabled pools,
available borrow liquidity, price bounds, an upper size cap, and a healthy
post-state. Risk-reducing rebalances remain available in `ReduceOnly` state.

DeepBook v7 includes market/limit close paths that trade, repay debt, and require
the post-operation risk ratio not to worsen. This is the correct primitive for
emergency reduction
([source](https://github.com/MystenLabs/deepbookv3/blob/c43c84a4826bb765147b08a1fbd1fc92826b85d3/packages/deepbook_margin/sources/pool_proxy.move#L1385-L1545)).
Use a protocol emergency threshold safely above DeepBook liquidation. Derive
the gap from oracle uncertainty, permitted price tolerance, book depth, borrow
interest, and execution latency; do not copy one fixed percentage.

## 5. Blast launchpad integration

Blast admits the exact leveraged coin type as a Quote asset after reviewing its
series identity, manager, owner mode, DeepBook dependency, and risk policy.
The launch remains `Launch<Meme, LeveragedCoin>`:

- virtual Quote and graduation target are fixed coin units;
- the curve holds real leveraged coins;
- Meme sells return the leveraged coin directly;
- graduation does not read leveraged-coin NAV or DeepBook risk ratio;
- migration seeds a Meme/leveraged-coin destination pool;
- stablecoin conversion is an independent leveraged-coin redemption.

An optional Zap can compose `USDC -> mint leveraged coin -> buy Meme` in one
transaction. The direct `leveraged coin -> Meme` path must remain available
when minting is paused. Likewise, `Meme -> leveraged coin` must not depend on
the leveraged coin being redeemable to USDC.

All launches using one Quote coin inherit that coin's liquidation, interest,
oracle, DeepBook governance, and manager-authorization risk. The UI must state
this as shared Quote risk.

If the desired underlying is the newly launched Meme itself, DeepBook Margin is
not a launch-time primitive. The Meme would first need an enabled DeepBook spot
pool, Base lending liquidity, risk parameters, and a supported Pyth price feed.
Use an established underlying such as SUI for the first Quote coin.

## 6. Initial product recommendation

Start with separate `SUI2L` and `SUI2S` series against SUI/USDC, subject to a
fresh on-chain parameter and liquidity review. Cap deposits and outstanding
shares by all of:

```text
safe margin-pool borrow headroom
DeepBook executable depth inside the price bound
emergency unwind depth
oracle confidence and freshness
shared-object throughput
```

`SUI2S` needs a lower cap because it borrows SUI and begins at a lower risk
ratio than `SUI2L`. If symmetric risk headroom matters more than symmetric
labels, launch `SUI2L` and `SUI1S` instead.

For a custodial beta, require one isolated manager and one independent multisig
per series, a low global deposit cap, public manager IDs, continuous accounting
reconciliation, and a rehearsed close procedure. Disclose that the multisig can
withdraw backing. Do not admit the beta Quote to unrestricted launch creation.

For production, do not launch until DeepBook application-owner capability mode
exists and an end-to-end transaction proves that no address can invoke a
backing withdrawal or exposure-changing call outside `Series` rules.

## 7. Non-negotiable invariants and tests

```text
I1  NAV = free assets + locked assets - current accrued debt, exactly once.

I2  LONG has Quote debt only; SHORT has Base debt only.

I3  share mutations use realized post-trade NAV and cannot dilute the other
    cohort through execution cost.

I4  every successful mint, redeem, or rebalance ends with leverage and risk
    inside its declared band and no unintended resting order.

I5  a pause blocks risk increase but not transfer, claim, close, debt repay, or
    bounded risk reduction.

I6  one Series owns one manager; LONG and SHORT never share or reassign equity.

I7  no signer or external package can withdraw backing except through the
    Series accounting transition.

I8  Blast curve reserves and lifecycle depend on real Quote units, never Quote
    NAV or DeepBook health.
```

Property and fault tests must cover:

- floor/ceiling rounding at every coin decimal combination;
- partial and zero fills, empty books, spread jumps, and maximum price bounds;
- borrow-utilization exhaustion and interest jumps;
- stale, high-confidence-width, divergent EWMA, and unavailable Pyth readings;
- partial/full liquidation, liquidation rewards, and pool default;
- fills immediately before mint or redemption ordering;
- DeepBook pool disablement and package-version transition;
- owner or capability bypass attempts on every sensitive DeepBook entry;
- repeated, concurrent, and full-supply redemptions;
- LONG and SHORT price gaps across their derived liquidation boundaries;
- direct Meme-to-Quote exit while leveraged-coin mint/redemption is paused;
- migration with a distressed but transferable Quote coin.

## 8. Go/no-go

The correct current decision is:

```text
economic prototype: yes
small disclosed multisig beta: possible
trustless public fungible coin on current owner API: no
production after cap-only DeepBook manager authorization: yes, subject to audit
```

DeepBook Margin removes the cross-chain and off-chain-NAV problems found in
Hyperliquid-backed tokens. It does not remove liquidation, borrow-interest,
oracle, order-book, upgrade, or manager-authorization risk. The authorization
change is the only architectural blocker; the remaining work is normal but
high-risk leveraged-vault engineering.
