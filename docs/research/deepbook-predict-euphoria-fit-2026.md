# DeepBook Predict and one-minute self-directed trading

- Date checked: 2026-09-01 UTC
- Status: research only; not an implementation or launch decision
- Scope: official Sui/DeepBook documentation, MystenLabs source repositories,
  and the official Sui Testnet GraphQL endpoint

## Conclusion

**Users cannot trade a live, production one-minute DeepBook Predict market
today.** There are two different Predict surfaces, and neither supplies that
product now:

1. The officially documented package is an older Testnet deployment. Its Move
   API lets a wallet owner create a `PredictManager`, deposit test DUSDC, mint an
   UP/DOWN position, and redeem it. However, users can only trade an active
   operator-created oracle; they cannot create an expiry market themselves. The
   deployment has no Mainnet counterpart, its documented server hostname was
   `NXDOMAIN` when checked, and all seven market/oracle matrices still retained
   as live state were already expired. It is therefore not a currently usable
   one-minute market.
   ([Testnet quickstart](https://docs.sui.io/onchain-finance/deepbook/deepbook-predict),
   [Testnet contract IDs](https://docs.sui.io/onchain-finance/deepbook/deepbook-predict/contract-information),
   [Testnet workflow](https://docs.sui.io/onchain-finance/deepbook/deepbook-predict/tutorial))
2. The redesigned protocol on `deepbookv3/main` explicitly implements a
   one-minute cadence and lets account owners mint and redeem positions in a
   pre-created, funded market. That package is still marked **in development,
   not deployed, no published addresses, changing ABI**. It is design evidence,
   not something users can trade against today.
   ([current README at `f0f563a`](https://github.com/MystenLabs/deepbookv3/blob/f0f563a2600f32ab2c6050fe34487027b6ee63ce/packages/predict/README.md#L1-L14))

If "themselves" means **direct wallet execution**, the intended answer is yes:
an owner-authenticated account can mint and live-redeem without a broker, and a
settled position can be redeemed by its owner or by a permissionless keeper.
If it means **create arbitrary one-minute markets**, the answer is no: market
creation needs protocol lifecycle authority. If it means **trade the position
peer-to-peer**, the answer is also no in the current design: the LP pool writes
the position and buys it back on live redemption; the position is an account
record/order ID, not a CLOB-listed coin or NFT.
([current lifecycle and account model](https://github.com/MystenLabs/deepbookv3/blob/f0f563a2600f32ab2c6050fe34487027b6ee63ce/packages/predict/docs/concepts/markets-and-positions.md#L75-L124),
[current protocol overview](https://github.com/MystenLabs/deepbookv3/blob/f0f563a2600f32ab2c6050fe34487027b6ee63ce/packages/predict/docs/overview.md#L21-L59))

## Do not confuse DeepBook's CLOB with Predict

DeepBookV3 is Sui's production central limit order book. It matches bids and
asks for token spot trading and supports market and limit orders. It does not
turn a token order into an expiring binary prediction position. It also does
not provide its own end-user trading interface; apps, wallets, and protocols
call the public Move functions or `@mysten/deepbook-v3` SDK.
([DeepBookV3 documentation](https://docs.sui.io/onchain-finance/deepbook/deepbookv3/deepbook))

DeepBook Predict is a separate expiry-based options/prediction primitive. Its
payoff depends on one oracle price at expiry. The redesigned protocol is not a
second CLOB: one shared LP-backed pool is counterparty to every contract, and a
position is a European cash-or-nothing range digital `(lower, higher]`.
([Predict README](https://github.com/MystenLabs/deepbookv3/blob/f0f563a2600f32ab2c6050fe34487027b6ee63ce/packages/predict/README.md#L1-L12),
[Predict overview](https://github.com/MystenLabs/deepbookv3/blob/f0f563a2600f32ab2c6050fe34487027b6ee63ce/packages/predict/docs/overview.md#L1-L25))

## What exists on Testnet

The current Sui documentation points to this provisional Testnet deployment:

| Item | Official value |
| --- | --- |
| Predict package | `0xf5ea2b3749c65d6e56507cc35388719aadb28f9cab873696a2f8687f5c785138` |
| Registry | `0x43af14fed5480c20ff77e2263d5f794c35b9fab7e2212903127062f4fe2a6e64` |
| Predict shared object | `0xc8736204d12f0a7277c86388a68bf8a194b0a14c5538ad13f22cbd8e2a38028a` |
| Quote asset | Testnet DUSDC |
| Source | `predict-testnet-4-16` branch |
| Mainnet deployment | None |

These values and the Mainnet absence are stated on the
[official contract-information page](https://docs.sui.io/onchain-finance/deepbook/deepbook-predict/contract-information).
The package and both shared objects still existed when queried through the
[official Sui Testnet GraphQL endpoint](https://graphql.testnet.sui.io/graphql)
on 2026-09-01. Existence does not mean the service has a tradeable market.

The older Testnet flow is genuinely self-directed at the transaction layer:

- each user creates and reuses a `PredictManager`;
- the user selects an **active** oracle exposed by the protocol, deposits DUSDC,
  and signs a transaction that calls `predict::mint`;
- UP wins strictly above the strike, while DOWN wins at or below it;
- the owner can call `predict::redeem`; after settlement any address may call
  `redeem_permissionless`, but the payout still goes to the owner's manager.

The official tutorial provides the wallet-signed TypeScript transactions and
states these gates directly.
([manager and active-oracle flow](https://docs.sui.io/onchain-finance/deepbook/deepbook-predict/tutorial#understand-the-oracle),
[binary mint](https://docs.sui.io/onchain-finance/deepbook/deepbook-predict/tutorial#deposit-and-mint-a-binary-position),
[redemption](https://docs.sui.io/onchain-finance/deepbook/deepbook-predict/tutorial#redeem-and-settlement))

Market/oracle supply is not self-service. In the deployed branch,
`registry::create_oracle` takes `AdminCap` and an oracle operator capability,
while `predict::mint` is public but checks that the transaction sender owns the
manager and that the oracle is live.
([Testnet registry source](https://github.com/MystenLabs/deepbookv3/blob/b63a565c6f867103553557912f87ef35574eef42/packages/predict/sources/registry.move#L99-L132),
[Testnet mint source](https://github.com/MystenLabs/deepbookv3/blob/b63a565c6f867103553557912f87ef35574eef42/packages/predict/sources/predict.move#L192-L267))

### Dated operational check

On 2026-09-01 at approximately 22:18 UTC:

- DNS returned `NXDOMAIN` for the official documented host
  `predict-server.testnet.mystenlabs.com` (A and AAAA), so the documented market
  discovery API could not list an active oracle.
- Direct queries to the official Sui Testnet GraphQL endpoint still resolved the
  package, registry, and Predict shared object. The Predict object was unpaused,
  but all seven oracle matrices that remained in its live/uncompacted matrix
  table were already expired. Their latest expiry was `1785484800000`
  (2026-07-31 00:00 UTC). Those objects still reported `active = true`, no
  settlement price, and stale June/July update timestamps, but the deployed
  mint guard also requires the current time to be before expiry. None was
  tradeable on 2026-09-01.

This is a dated operational observation, not a claim that the Testnet package
was deleted. It means the old deployment should not be presented as a live
market without a fresh oracle/API check. The official tutorial itself requires
clients to fetch a live oracle and fail when none is active.
([official server and verification instructions](https://docs.sui.io/onchain-finance/deepbook/deepbook-predict),
[official Testnet GraphQL endpoint](https://graphql.testnet.sui.io/graphql))

## What the redesigned, undeployed protocol supports

The current `deepbookv3/main` source at
[`f0f563a`](https://github.com/MystenLabs/deepbookv3/tree/f0f563a2600f32ab2c6050fe34487027b6ee63ce/packages/predict)
has a materially different object model: `Registry`, `ProtocolConfig`,
`PoolVault`, one `ExpiryMarket` per underlying/expiry, account-package
`AccountWrapper`/`Account`, and separate Propbook oracle objects.
([architecture](https://github.com/MystenLabs/deepbookv3/blob/f0f563a2600f32ab2c6050fe34487027b6ee63ce/packages/predict/docs/design/architecture.md))

It has a native one-minute cadence:

- `one_minute_ms = 60_000`, and the exact settlement grid is one minute;
- cadence ID `0` is one minute, followed by five-minute, hourly, daily, weekly,
  and fixed 30-day cadences;
- the next one-minute expiry is the next common 60-second boundary, not a
  private timer started by each click. A trade placed partway through a minute
  has only the remaining time to that boundary.

([time constants](https://github.com/MystenLabs/deepbookv3/blob/f0f563a2600f32ab2c6050fe34487027b6ee63ce/packages/predict/sources/constants.move#L101-L149),
[cadence selection](https://github.com/MystenLabs/deepbookv3/blob/f0f563a2600f32ab2c6050fe34487027b6ee63ce/packages/predict/sources/registry/market_manager.move#L73-L89),
[next-boundary calculation](https://github.com/MystenLabs/deepbookv3/blob/f0f563a2600f32ab2c6050fe34487027b6ee63ce/packages/predict/sources/registry/market_manager.move#L164-L217))

The permission split is clear:

| Action | Who can do it in the current source? |
| --- | --- |
| Configure an underlying/cadence | Admin |
| Create the next expiry market | Holder of an allowlisted `MarketLifecycleCap` |
| Fund/rebalance market cash | Permissionless call, using pool policy/capital |
| Quote | Any caller/read path |
| Mint exact quantity or exact spend | Account owner or authorized app with valid `Auth` |
| Live close, full or partial | Account owner or authorized app with valid `Auth` |
| Settle after expiry | Anyone, if an exact allowed oracle observation exists |
| Redeem after settlement | Owner-auth path or permissionless keeper path |

([privileged market creation](https://github.com/MystenLabs/deepbookv3/blob/f0f563a2600f32ab2c6050fe34487027b6ee63ce/packages/predict/sources/registry/registry.move#L225-L275),
[trade and redeem API](https://github.com/MystenLabs/deepbookv3/blob/f0f563a2600f32ab2c6050fe34487027b6ee63ce/packages/predict/sources/expiry_market.move#L304-L610),
[permissionless settlement](https://github.com/MystenLabs/deepbookv3/blob/f0f563a2600f32ab2c6050fe34487027b6ee63ce/packages/predict/sources/expiry_market.move#L666-L719))

UP and DOWN need no separate outcome-token contract:

```text
UP at strike K   = (K, +infinity]  -> settlement > K
DOWN at strike K = (-infinity, K]  -> settlement <= K
```

The result is terminal-only. A price touch before expiry does not win. Current
source also fixes the minimum pre-fee premium at 1 DUSDC and the quantity lot at
0.01 DUSDC, so a $0.10 default tap is not supported by this revision.
([range semantics](https://github.com/MystenLabs/deepbookv3/blob/f0f563a2600f32ab2c6050fe34487027b6ee63ce/packages/predict/docs/overview.md#L7-L15),
[position constants](https://github.com/MystenLabs/deepbookv3/blob/f0f563a2600f32ab2c6050fe34487027b6ee63ce/packages/predict/sources/constants.move#L23-L30))

## SDK and app readiness

There is no currently usable SDK matching the redesigned public source. The
Predict README links `@mysten/deepbook-predict`, but that package is absent from
the `ts-sdks` main tree at
[`f4f533b`](https://github.com/MystenLabs/ts-sdks/tree/f4f533b6e4c0e896bff6c146239726e92efb2285/packages).
The only first-party implementation found is an unmerged branch at
[`639635d`](https://github.com/MystenLabs/ts-sdks/tree/639635d0b5cdfea89f6751d2966274ac330a9e90/packages/deepbook-predict).
That branch declares version `0.0.0` and calls itself pre-launch/unstable with no
package IDs.
([branch README](https://github.com/MystenLabs/ts-sdks/blob/639635d0b5cdfea89f6751d2966274ac330a9e90/packages/deepbook-predict/README.md#L1-L30),
[package manifest](https://github.com/MystenLabs/ts-sdks/blob/639635d0b5cdfea89f6751d2966274ac330a9e90/packages/deepbook-predict/package.json#L1-L6))

It is also ABI-stale: its trade builder still passes `leverage` to mint and
Pyth plus `closeQuantity` to settled redemption, while current Move main has
none of those arguments. Do not build against it without regeneration after an
actual deployment.
([stale SDK trade builder](https://github.com/MystenLabs/ts-sdks/blob/639635d0b5cdfea89f6751d2966274ac330a9e90/packages/deepbook-predict/src/transactions/trade.ts#L71-L110),
[stale settled redeem builder](https://github.com/MystenLabs/ts-sdks/blob/639635d0b5cdfea89f6751d2966274ac330a9e90/packages/deepbook-predict/src/transactions/trade.ts#L186-L247),
[current Move signatures](https://github.com/MystenLabs/deepbookv3/blob/f0f563a2600f32ab2c6050fe34487027b6ee63ce/packages/predict/sources/expiry_market.move#L429-L610))

The May 2026 Sui announcement said the first-party trader app would arrive with
Mainnet and would let traders interact with Predict directly for the first
time. Current Sui docs still say there is no Mainnet deployment, and the public
Testnet tutorial uses raw Sui TypeScript SDK transactions rather than a Predict
SDK. Treat DeepBook's website descriptions as product direction, not evidence
that a retail one-minute market is open.
([launch announcement](https://www.sui.io/blog/introducing-deepbook-predict),
[current Testnet tutorial](https://docs.sui.io/onchain-finance/deepbook/deepbook-predict/tutorial),
[DeepBook builder description](https://www.deepbook.tech/builder-hub))

## Decision for Blast

DeepBook Predict is a strong architectural fit for terminal-price one-minute
UP/DOWN positions, but it is not a production dependency yet. Blast should wait
for all of these before integrating:

1. a published Mainnet package and immutable package/object IDs;
2. an active one-minute cadence with funded markets and working oracle feeds;
3. a released SDK regenerated against that exact ABI;
4. audits and deployment records for the redesigned package; and
5. a live end-to-end mint, settle, and redeem verification.

Do not create a parallel Blast contract merely to store derived odds,
multipliers, or UI squares. If the deployed Predict ABI preserves the current
design, Blast's SDK should discover markets, convert strikes to ticks, quote,
build owner-signed transactions, and derive display multipliers; the web app
should own countdowns, entry cutoffs, sponsored/session UX, and disclosures.

## Banana Zone product reference

- Observed: 2026-09-02 UTC
- First-party product: [Banana Zone](https://www.bananazone.app/)
- Capture: [live product screenshot](./banana-zone-reference-2026-09-02.png)

Banana Zone is a useful interaction reference for Blast, separate from the
DeepBook compatibility findings above. The live product presents a full-screen
price/time grid. A yellow price trace ends at a vertical present-time boundary,
while future cells show multipliers. Selecting a cell reveals its price range,
multiplier, and a second-tap confirmation prompt. A persistent bottom rail keeps
practice/live mode, wager amount, positions, leaderboard, sound, and rewards
available without leaving the grid.

The product also reduces entry friction with a practice allowance, fixed wager
presets, a separate position ledger, and visible rank/streak progression. These
are good references for Blast's practice mode, transaction confirmation,
position monitoring, and social feedback. Blast should express them with its
own cream, ink, hot-pink, square-border visual system rather than copy Banana
Zone's visual treatment.

These observations do **not** establish Banana Zone's oracle, execution,
settlement, custody, or expiry semantics. They also do not change DeepBook's
requirements. A Blast cell must still map to one DeepBook `ExpiryMarket` and a
terminal range `(lowerTick, higherTick]`; its displayed multiplier must come
from a DeepBook quote; and one-minute expiries must use the protocol's shared
minute boundaries. Banana Zone supplies interaction inspiration only. DeepBook
source and deployed ABI remain the authority for transaction behavior.
