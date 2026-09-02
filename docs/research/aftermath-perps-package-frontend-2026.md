# Aftermath Perpetuals package and Blast leveraged-coin integration

- Date: 2026-08-31
- Status: primary-source and deployed-package review; no implementation
- Scope: Aftermath Perpetuals contracts, SDK, live frontend, and suitability as
  the backing engine for standalone LONG and SHORT coins used by Blast

Architecture note: this research established that capability custody is
possible. Proposed ADR
[0064](../decisions/0064-aftermath-backed-leverage-coins.md) refines the final
boundary by placing the capability in a one-to-one Aftermath adapter object,
not in venue-independent core Series state.

## Executive conclusion

Aftermath Perpetuals does not have the DeepBook `ctx.sender` blocker. A
perpetuals account is authorized by an
`AuthorityCap<ACCOUNT, ADMIN>`. The cap has `key + store`, account and trading
functions take the cap by reference, and the public interface does not require
the cap holder to equal `tx_context::sender`. Blast can therefore store the
admin cap inside a shared leveraged-coin `Series` and expose only constrained
mint, redeem, and rebalance functions.

The recommended integration is not Aftermath's existing market-making vault.
That vault returns a `UserLpCoin<L>` object containing `Balance<L>`, a deposit
timestamp, and cost basis. It is not a normal `Coin<L>` that Blast can use as a
fungible Quote asset. Use a direct Aftermath `Account<USDC>` per leveraged coin
and issue Blast's own `Coin<SUI2L>` or `Coin<SUI2S>` against the account's NAV.

This is technically viable for markets that Aftermath already supports. It
does not allow a newly launched meme to get a perpetual market automatically.
Market creation is permissioned by Aftermath vendor authority and requires
oracles, risk parameters, open-interest capacity, and an active CLOB. The first
safe product is therefore an established market such as `SUI-USDC`, not a
launch-time `MEME-USDC` market.

## 1. Verified mainnet deployment

The canonical Aftermath address endpoint currently returns:

| Component | Mainnet ID |
| --- | --- |
| Perpetuals package | `0x3ec740df8428aa9c93aaef7f8cc1542ac3194fd014826b51bfe245346d64efc7` |
| Perpetuals registry | `0xda0bd7a60182efd662b70e0de99218bbd2b6c4bbe9de23c0bb5a87ec52b37c37` |
| Authority-cap package | `0x4e2df80a5e2fd0392878298c51ce15164222111ccea05504b9291b158f552677` |
| Market-making vault package | `0xbab1b714c5533a46ee27a9c124d6f9281ca54831fc288d4d0c133dae3a57254a` |

Sources:

- [Aftermath address endpoint](https://aftermath.finance/api/addresses)
- [Perpetuals package on SuiScan](https://suiscan.xyz/mainnet/object/0x3ec740df8428aa9c93aaef7f8cc1542ac3194fd014826b51bfe245346d64efc7/contracts)
- [Vault package on SuiScan](https://suiscan.xyz/mainnet/object/0xbab1b714c5533a46ee27a9c124d6f9281ca54831fc288d4d0c133dae3a57254a/contracts)
- [Published perpetuals metadata](https://github.com/AftermathFinance/move-interfaces/blob/f62e74aa862ef65b8950a70d83aac8cb71c19837/packages/iperps/perpetuals/Published.toml)
- [Published vault metadata](https://github.com/AftermathFinance/move-interfaces/blob/f62e74aa862ef65b8950a70d83aac8cb71c19837/packages/iperps-vaults/market-making-vault/Published.toml)

A direct Sui mainnet GraphQL read at checkpoint `317201550` returned:

- Perpetuals package object version `1`, digest
  `2Fa3q1WFk6oNpStaemJFujknbThnnA89GcneuRwAf4vT`, with modules including
  `account`, `clearing_house`, `market`, `orderbook`, `adl`, `stop_orders`, and
  `twap_orders`.
- Vault package object version `1`, digest
  `Hceoc7emjk1hv7JQnGWXR8zuhkc9sJWC6WZRGqA8aFWz`, with modules including
  `vault`, `interface`, `perpetuals_api`, `config`, and `authority`.
- Authority package object version `1`, digest
  `G2NQi5hicFx8HQxRzYWoeCvuwqFxkQr5KJ1pApJsbhB3`.

The repository files under `move-interfaces` are compilation interfaces, not
the full implementation: function bodies deliberately `abort 404`. Their
public structures and signatures match the deployed bytecode interface checked
through GraphQL, but implementation claims below come from on-chain signatures
and official protocol documentation, not from those stub bodies.

## 2. Why authorization works for a Blast protocol

### 2.1 Account creation returns a capability

`account::create_account<T>` returns:

```move
(Account<T>, AccountSharePolicy, AuthorityCap<ACCOUNT, ADMIN>)
```

The account has `key + store`, and the share policy must be consumed to make it
a shared object. The deployed interface also offers
`create_and_share_account<T>`, which returns the admin cap
([account interface](https://github.com/AftermathFinance/move-interfaces/blob/f62e74aa862ef65b8950a70d83aac8cb71c19837/packages/iperps/perpetuals/sources/account.move#L88-L127)).

The generic authority cap is:

```move
public struct AuthorityCap<phantom Context, phantom Role> has key, store {
    id: UID,
    `for`: ID,
}
```

Because it has `store`, another package can wrap it inside its own shared
`Series` object
([authority interface](https://github.com/AftermathFinance/move-interfaces/blob/f62e74aa862ef65b8950a70d83aac8cb71c19837/packages/authority-cap/authority-cap/sources/authority.move#L67-L128)).

### 2.2 Sensitive operations use the cap, not address ownership

The account interface requires the admin cap for withdrawal. Deposit accepts
admin or assistant authority
([account operations](https://github.com/AftermathFinance/move-interfaces/blob/f62e74aa862ef65b8950a70d83aac8cb71c19837/packages/iperps/perpetuals/sources/account.move#L180-L237)).

Clearing-house operations for allocation, deallocation, position creation,
leverage selection, order cancellation, and session start/end accept an
`AuthorityCap<ACCOUNT, ...>`. Market and limit orders execute inside a
`SessionHotPotato`; the session must end and return the clearing house plus a
`SessionSummary`
([trading interface](https://github.com/AftermathFinance/move-interfaces/blob/f62e74aa862ef65b8950a70d83aac8cb71c19837/packages/iperps/perpetuals/sources/clearing_house.move#L907-L1036)).

`TxContext` is still passed to account creation and session execution, but it
is not the account ownership credential. It supplies object creation and
executor context. The account capability is the authority.

### 2.3 The SDK explicitly supports contract composition

The current SDK supports `deferShare: true`. It returns transaction arguments
for the new account, share policy, and admin cap so a caller can compose more
Move calls before sharing the account. The associated share flow is documented
as supporting cap transfer and agent-wallet composition
([SDK source](https://github.com/AftermathFinance/aftermath-ts-sdk/blob/449f8e6e52a7829fd8b2fe3c9d3145beef5316f5/src/packages/perpetuals/perpetuals.ts#L778-L940)).

A direct call to the live transaction-builder endpoint returned:

```text
accountArg     = NestedResult(0, 0)
sharePolicyArg = NestedResult(0, 1)
adminCapArg    = NestedResult(0, 2)
```

Decoding its transaction kind showed a call to the deployed
`account::create_account<USDC>` package. Blast can call that function directly
from its Series constructor, store `adminCapArg`, and consume the share policy
in the same transaction.

## 3. What the live frontend confirms

The live product is
[Aftermath Perpetuals](https://aftermath.finance/perpetuals/SUI-USDC). The
unauthenticated trading screen exposes:

- long and short;
- market and limit orders;
- selectable leverage;
- reduce-only orders;
- take-profit and stop-loss;
- TWAP and stop-order views;
- a user slippage setting;
- fully visible order book, positions, funding, liquidation price, and margin.

The frontend uses Aftermath HTTP endpoints for market/account reads and
unsigned transaction construction, while the resulting transaction executes
the Move calls on Sui. The public
[TypeScript SDK](https://github.com/AftermathFinance/aftermath-ts-sdk) exposes
the same transaction-building and account/vault interfaces.

At the research snapshot, the live markets endpoint returned 29 USDC markets.
For `SUI-USDC` it returned:

```text
market ID:   0xa97dacdd972a0414363290ec5752cb93ac47443c3e7710df145cc7f337575002
IMR:         10%  (10x market maximum)
MMR:          5%
maker fee:   -0.005%
taker fee:    0.045%
liquidation:  0.5%
funding period: 8 hours
```

These are mutable market parameters. A production integration must read them
from on-chain market state and must not hardcode this snapshot. The official
docs define IMR, MMR, margin, mark price, funding, and liquidations
([margin](https://docs.aftermath.finance/perpetuals/aftermath-perpetuals/architecture/margin),
[funding](https://docs.aftermath.finance/perpetuals/architecture/funding),
[liquidations](https://docs.aftermath.finance/perpetuals/architecture/liquidations)).

The frontend also exposes permissionless managed vault creation and the live
[vault directory](https://aftermath.finance/perpetuals/vaults). The vault UI
shows deposits, requested withdrawals, performance, open positions, orders,
lock period, and forced-withdrawal behavior. These match the
[depositor documentation](https://docs.aftermath.finance/perpetuals/vaults/for-depositors)
and [curator documentation](https://docs.aftermath.finance/perpetuals/vaults/for-curators).

## 4. Why the native Aftermath vault is not the Blast Quote coin

The market-making vault already pools collateral, trades perpetuals, and mints
shares. However, the user share is:

```move
public struct UserLpCoin<phantom L> has key, store {
    id: UID,
    lp_balance: Balance<L>,
    start_timestamp_ms: u64,
    provided_value_usd: u256,
}
```

It is an owned object with cost-basis and lock-time state. It is not
`Coin<L>`, and no public function unwraps it into a freely usable coin
([vault share interface](https://github.com/AftermathFinance/move-interfaces/blob/f62e74aa862ef65b8950a70d83aac8cb71c19837/packages/iperps-vaults/market-making-vault/sources/vault.move#L644-L700)).

Consequences:

- Blast's generic curve cannot use `UserLpCoin<L>` as `Coin<Quote>`.
- A vault withdrawal is request-based and may require position unwinds after a
  lock and force-withdraw delay.
- Vault shares contain per-object cost basis because curator fees apply only to
  profit.
- The vault may trade several markets, while a directional leveraged coin
  should have exactly one permitted market and side.

It is possible to wrap native vault positions in another coin, but that adds a
second share-accounting layer, withdrawal queues, performance-fee cost basis,
and another set of invariants. A direct account is smaller and safer.

## 5. Recommended Blast architecture

Create one isolated Aftermath account and one shared Series per coin:

```text
Series<SUI2L, USDC>                  Series<SUI2S, USDC>
  TreasuryCap<SUI2L>                  TreasuryCap<SUI2S>
  Account admin cap                   Account admin cap
  Aftermath account A                 Aftermath account B
  SUI-USDC market ID                  SUI-USDC market ID
  side = LONG                         side = SHORT
  target leverage = 2x                target leverage = 2x
  lifecycle + fee balances            lifecycle + fee balances
```

The Aftermath accounts remain shared. The admin caps and Blast coin treasury
caps remain wrapped inside their Series. No account assistant cap is issued.
Anyone may call public Series functions, but only Series code can borrow the
admin cap and invoke account operations.

LONG and SHORT do not need matched supply and do not hedge one another.
Aftermath's order book provides the counterparty. Never net their collateral or
positions; liquidation, funding, and insolvency must remain isolated.

### 5.1 Initialization

1. Create `Account<USDC>`, share policy, and account admin cap.
2. Record the account ID and fixed allowed clearing-house ID.
3. Consume the account share policy.
4. Store the admin cap and `TreasuryCap<LeveragedCoin>` inside Series.
5. Share Series with zero assistants and lifecycle `ACTIVE`.
6. Create the single market position and set a conservative position IMR.

### 5.2 Mint

For an accepted USDC deposit:

1. Settle/read funding and calculate conservative pre-mint equity.
2. Deposit USDC using the wrapped account cap.
3. Allocate collateral to the one permitted market.
4. Start an Aftermath session, place only the required market order, and end
   the session.
5. Read actual fills and fees from `SessionSummary`.
6. Abort unless execution price, fees, post-trade leverage, oracle freshness,
   and margin headroom are within user and protocol bounds.
7. Mint shares from the actual incremental NAV, rounded down.

For supply `S`, pre-mint equity `N0`, and fixed-price incremental post-trade
equity `dN`:

```text
shares_out = floor(S * dN / N0)
```

Use a fixed valuation price across the pre/post calculation so the minting
order cannot manipulate the book-derived component of NAV. The user supplies
`min_shares_out` and a deadline.

### 5.3 Redeem

For `x` shares:

1. Calculate `r = x / S` with conservative integer rounding.
2. Cancel any orders; the initial product should normally have none.
3. Close `r` of the position with a reduce-only market order.
4. Deallocate the resulting free collateral.
5. Preserve at least the remaining holders' proportional conservative equity:

```text
equity_keep = ceil(N0 * (S - x) / S)
payout      = max(0, equity_after_unwind - equity_keep)
```

6. Abort below `min_usdc_out`, burn the shares, withdraw USDC through the admin
   cap, and pay the redeemer.

When `x == S`, use a special full-close path that cancels orders, closes all
exposure, settles funding, and withdraws all recoverable collateral.

### 5.4 Rebalance

Define equity and signed leverage from Aftermath's on-chain position math:

```text
equity N = free collateral value
         + allocated collateral value
         + unrealized PnL
         + unrealized funding

leverage = abs(base_position * mark_price) / N
```

Permissionless rebalance is safe only when Series chooses the direction and
maximum order size. The caller must never provide arbitrary side or size.

- If leverage is below the lower band, Series may increase exposure only when
  the oracle is fresh, the market is active, and the post-trade margin buffer
  remains above the configured floor.
- If leverage is above the upper band, Series places a reduce-only order.
- After every order, use `SessionSummary` to enforce an execution-price bound.
- Do not leave resting orders in the first release.
- If Aftermath pauses or settles the market, disable mint and use only the
  available reduce/settlement path.

## 6. Core invariants

1. **Capability confinement:** exactly one live account admin cap exists for
   the Series account, and it remains wrapped by Series. No assistant exists.
2. **Market confinement:** Series may touch only its immutable clearing-house
   ID and collateral type.
3. **Direction confinement:** risk-increasing trades can only increase the
   configured LONG or SHORT direction; opposite trades must be reduce-only.
4. **Share conservation:** only Series holds mint and burn authority, and
   reported supply equals the currency supply.
5. **NAV fairness:** a mint or redeem cannot decrease remaining holders' NAV
   per share beyond the explicitly charged execution and protocol fees.
6. **Execution bound:** actual filled quote, fees, and average execution price
   must satisfy the user's limit after the session, or the entire transaction
   aborts.
7. **Risk bound:** every risk-increasing transition ends inside the target
   leverage band and above a maintenance-margin safety buffer.
8. **Exit proportionality:** redemption reduces exposure and equity in the
   same proportion; it cannot withdraw idle collateral while leaving all risk
   to remaining holders.
9. **No hidden orders:** all share-changing transactions begin and end with no
   pending order unless a later version defines complete locked-order NAV math.
10. **Failure truth:** after liquidation, ADL, settlement, or socialized loss,
    supply does not imply a promised redemption value. NAV is the remaining
    recoverable account equity.

## 7. Liquidation and leveraged-coin math

Let target leverage be `L`, entry price be `P0`, current price ratio be
`p = P/P0`, and Aftermath maintenance margin ratio be `m`. Ignore funding,
fees, slippage, and rebalances for this threshold illustration.

For a LONG:

```text
equity(p)   = N0 * [1 + L(p - 1)]
notional(p) = L * N0 * p

liquidation boundary:
p_long = (L - 1) / [L(1 - m)]
```

For a SHORT:

```text
equity(p)   = N0 * [1 + L(1 - p)]
notional(p) = L * N0 * p

liquidation boundary:
p_short = (L + 1) / [L(1 + m)]
```

Using the snapshot SUI MMR of 5% and `L = 2`:

- `SUI2L` reaches the simplified boundary after about a 47.4% price fall.
- `SUI2S` reaches it after about a 42.9% price rise.

Funding and fees move both boundaries closer over time when the Series is on
the paying side. Rebalancing creates leveraged-token path dependence and
volatility decay. A keeper can reduce liquidation probability but cannot make
the coin non-liquidatable.

Aftermath uses partial liquidation and a loss cascade involving isolated
insurance funds, socialized loss, and auto-deleveraging. A partial liquidation
does not automatically destroy the leveraged coin. Series must sync the actual
remaining position and equity, disable mint if outside its safe band, and enter
`REDUCE_ONLY` or `SHUTDOWN` when recovery is unsafe
([liquidation docs](https://docs.aftermath.finance/perpetuals/architecture/liquidations)).

## 8. Risks and limitations

### Integration risks

- The core perpetuals interface is BUSL-1.1, while the SDK is Apache-2.0 and
  the market-making vault interface declares Apache 2.0. Confirm production
  integration and interface-license terms with Aftermath.
- Published packages have upgrade capabilities. Registry versions, risk
  parameters, pause modes, oracle configuration, and open-interest caps are
  governed dependencies.
- An adapter compiled against one package/version may stop working after a
  required registry version change. Series needs an explicit migration or
  shutdown policy.
- The public `move-interfaces` repo exposes signatures rather than full
  implementation bodies. A production review should include Aftermath's full
  audit materials or a source-assisted integration review.

### Economic and operational risks

- Market orders depend on CLOB depth. Mint and redeem capacity must be capped
  by executable depth, not headline open interest.
- Funding continuously transfers value between longs and shorts.
- Oracle staleness, market pauses, trading schedules, and settlement can block
  normal rebalance or redemption paths.
- ADL can reduce a profitable Series position without its consent.
- Socialized losses can reduce NAV even when Series itself was not the failed
  account.
- Every Blast launch that accepts the same leveraged Quote coin inherits that
  coin's funding, oracle, liquidation, and Aftermath governance risks.

The Aftermath frontend links an OtterSec audit page, but the public record
found during this review identifies an older 2023 Aftermath AMM/staking audit,
not a clearly scoped audit of the current perpetuals and market-making-vault
packages. Do not treat that page as evidence that these exact packages were
audited without a package-specific report.

## 9. Recommendation

Proceed with an Aftermath proof of concept. Unlike DeepBook Margin, its
capability interface can support trustless application custody.

Use this sequence:

1. Build only `SUI2L` and `SUI2S`, each at 2x target leverage and each with a
   separate account and Series.
2. Integrate the direct perpetuals account, not `UserLpCoin` vault shares.
3. Store the account admin cap and leveraged-coin treasury cap inside Series.
4. Expose only atomic mint, proportional redeem, bounded permissionless
   rebalance, and emergency reduce/settle functions.
5. Use market orders with post-session execution assertions and no resting
   orders.
6. Cap supply from real unwind depth and keep the SHORT cap lower if its exit
   book is thinner.
7. Have Aftermath confirm package/version support, audit scope, and intended
   contract-to-contract capability use before mainnet launch.
8. Admit the exact `Coin<SUI2L>` and `Coin<SUI2S>` types into Blast only after
   the Series integration passes invariant, liquidation, pause, settlement,
   ADL, and oracle-staleness tests.

This route preserves the desired product boundary: the leveraged coin is its
own protocol, and Blast merely pairs meme launches against that coin as Quote.
