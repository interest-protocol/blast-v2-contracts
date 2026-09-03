# Perp-backed leveraged tokens and launch curves

- Date: 2026-08-31
- Status: technical research and Blast design recommendation; not a protocol decision
- Scope: alt.fun, ast.fun, Bounce.Tech, TLX/Synthetix, Toros/dHEDGE, and the
  safest way to admit a perp-backed quote asset into the Blast launchpad
- Evidence: official documentation, whitepapers, audits, deployed ABIs, and
  pinned first-party contract source

## Executive conclusion

Blast should not put a perpetual account, keeper, NAV oracle, or rebalancing
engine inside launchpad core. The safer product has two independent layers:

1. A perp-backed leveraged token is a pro-rata share of one isolated strategy
   account. It owns the venue integration, NAV, share issue and redemption,
   leverage bands, queues, and emergency reduction.
2. Blast's existing constant-product launch remains a generic
   `Launch<Meme, Quote>`. Governance may admit one exact leveraged-token coin
   type as `Quote`; each launch fixes that type and its migration witness once.

The curve holds real `Quote` coins and denominates graduation in a fixed amount
of recognized real `Quote`. It must not convert the target to USD from the
leveraged token's instantaneous NAV. The SDK may show USD by multiplying the
Meme/Quote curve price by Quote NAV, but that derived value is not consensus.
This removes an irreversible oracle-timing option and already matches Blast's
bounded Quote whitelist, real-Quote terminal target, pair-typed custody, and
typed migration handoff
([current Quote policy](../protocol-scope.md#decisions-taken-since-this-table-was-written),
[source](../../sui/launchpad/sources/launch_config.move#L23-L108),
[launch state](../../sui/launchpad/sources/launch.move#L39-L66)).

This is viable only when the perp-backed share is native and synchronously
composable on Sui. Blast should not bridge to or remote-control a Hyperliquid
account from Sui. Cross-chain messages cannot make mint, redemption, NAV, and
perp execution atomic; they would turn bridge operators and remote state proofs
into launch-critical authority.

The first release should admit one vetted 2x series, not arbitrary LTs. The
whitelisted type must bind an exact package and upgrade policy, venue, market,
direction, leverage, collateral, and backing account. Use one LT package/account
per series and one typed Quote balance per launch. A Meme sell must always be
able to return LT directly. Conversion of LT to a stablecoin is a separate
action that may use an immediate buffer or queue; stablecoin-buffer exhaustion
must never block the Meme-to-LT exit.

The principal lessons across the projects are:

- alt.fun proves the virtual-reserve and graduation-liquidity algebra, but its
  launched token is quoted in an LT; it is not a pro-rata share of LT NAV.
- ast.fun is the closest second two-layer product and makes the operational
  costs visible: a custodial shared perp account, posted equity, staleness
  controls, an idle redemption buffer, and a queue.
- Bounce shows why complete cross-domain NAV and an explicit async operation
  journal are mandatory. Its public share contract does not make asynchronous
  HyperCore execution atomic.
- TLX shows useful on-chain `canRebalance`, price-impact charging, minimum-out,
  and pending-order exclusion.
- Toros/dHEDGE shows the strongest defensive accounting patterns: enumerate
  every pending venue state, prevent double counting, freshness-gate mints,
  allow over-limit actions only when they reduce risk, and assert value and
  supply after withdrawals.

## Evidence labels and product taxonomy

`Verified` below means a statement follows from a linked primary source.
`Derived` means the equation follows from the verified state and rounding rules.
`Recommendation` is Blast-specific judgment. Availability is a point-in-time
observation on 2026-08-31.

| Product | Holder instrument | What directly backs that instrument | Perp control plane | Evidence level |
| --- | --- | --- | --- | --- |
| alt.fun launch token | ERC-20 Meme | Liquidity quoted in a Bounce LT on a curve, then an LT/Meme AMM | Bounce owns LT strategy | Whitepaper, audit, and current source |
| ast.fun launch token | ERC-20 Meme | Liquidity quoted in an Aster-backed LT on a curve, then an LT/Meme AMM | Shared custodial Aster account and keeper | Current docs, deployments, and ABIs; no public source repo found |
| Bounce LT | ERC-20 strategy share | Pro-rata HyperEVM USDC plus selected HyperCore spot/perp account equity | Off-chain active-active agents | Current source, docs, engineering posts, and audits |
| TLX LT | ERC-20 strategy share | Remaining margin in one Synthetix Perps V2 position | On-chain delayed order plus Chainlink Automation | Pinned source; repository archived |
| Toros perp token | dHEDGE pool share | Pro-rata value of a guarded GMX, Flat Money, or other approved perp strategy | Manager, guards, and venue-specific async handlers | Current Toros docs and current dHEDGE source |

The first two rows are two-layer products. The Meme inherits the LT's USD return
because it is priced in LT, but it is not an LT share. The last three rows are
strategy-share implementations. Confusing those categories produces false NAV
claims and incorrect redemption expectations.

## 1. alt.fun: exact curve and graduation mechanics

### 1.1 Source and architecture

The primary specification is the May 2026
[whitepaper](https://alt.fun/whitepaper.pdf). The direct implementation reviewed
here is
[`alt-fun/contracts@625fd214`](https://github.com/alt-fun/contracts/tree/625fd21454a5232f2c8582d4b1135a9bdeafedec),
which is newer than the audit's remediation commit. The launch contract admits
only tokens registered by the current Bounce factory, deploys a fixed-supply
Meme, creates its curve pair, snapshots the LT exchange rate, and seeds virtual
reserves
([launch and LT admission](https://github.com/alt-fun/contracts/blob/625fd21454a5232f2c8582d4b1135a9bdeafedec/src/Bonding.sol#L354-L448)).

The fixed parameters are:

```text
S = 1,000,000,000 Meme
c = 0.75                         curve inventory fraction
h = 0.25                         graduation reserve fraction
V = $3,000                       launch virtual value
T = $9,000                       default graduation value
p0 = LT USD exchange rate at launch
v = floor(V / p0)                virtual LT units, with implementation scaling
K = S * v
```

The constants and 75/25 partition are in
[`Bonding.sol`](https://github.com/alt-fun/contracts/blob/625fd21454a5232f2c8582d4b1135a9bdeafedec/src/Bonding.sol#L50-L56).
`Token` mints `S` to `Bonding`, and only `Bonding` can burn
([source](https://github.com/alt-fun/contracts/blob/625fd21454a5232f2c8582d4b1135a9bdeafedec/src/Token.sol#L11-L43)).

The key economic fact is often obscured by the word “backed.” At launch the
pair's stored reserves are `(S, v)`, but its real balances are `(0.75S, 0)`.
The `$3,000` LT reserve is virtual. The Meme is liquidity-backed and quoted in
the Bounce LT; it is not a share with a pro-rata claim on LT NAV.

### 1.2 Disambiguated reserve model

Use distinct symbols:

```text
x = stored virtual-inclusive Meme reserve
y = stored virtual-inclusive LT reserve
b = live Meme balance in the curve pair
l = recognized real LT raised by the curve
s = net Meme released by curve accounting
u = s / S
p = current LT USD exchange rate
A = v * p = current USD value of the fixed virtual LT amount
```

In ideal real arithmetic, before graduation and without direct donations:

```text
x = S - s = S(1-u)
y = K/x = S*v/(S-s) = v/(1-u)
l = y-v = v*s/(S-s) = v*u/(1-u)
b = 0.75S-s
x-b = 0.25S
```

Thus the marginal curve price is

```text
P_LT       = y/x = S*v/(S-s)^2 = v/[S(1-u)^2] LT per Meme
P_USD      = P_LT * p
M          = S * P_USD = A/(1-u)^2
L          = l * p = A*u/(1-u)
```

`M` is the full-`S` marginal market capitalization used by the whitepaper and
frontends. It is not the value obtainable by selling all circulating Meme at
the marginal price. The marked value of the `s` circulating tokens is
`s*P_USD = A*u/(1-u)^2`, while the recognized LT in the curve is worth `L`.
Ignoring fees and rounding, a full curve unwind realizes all `L`, so

```text
realizable reserve value / circulating marginal mark = 1-u.
```

That declining ratio is ordinary constant-product slippage, not an accounting
deficit. It is also a compact proof that Meme holders do not own pro-rata LT
shares.

At launch, `u=0` and `A` is approximately `V`, so the full-`S` opening value is
approximately `$3,000`. Integer division in `v = floor(V/p0)` makes this “about
V,” not an exact dollar identity.

### 1.3 Price changes with no Meme trade

With no curve trade, `u`, `x`, `y`, `l`, and `P_LT` do not change. A change in
the LT exchange rate changes `A=v*p`, and therefore changes all USD values in
direct proportion:

```text
M_new / M_old = L_new / L_old = p_new / p_old.
```

For a small underlying move before costs, LT return is approximately target
leverage times the underlying return. The Meme therefore inherits that LT beta
when there are no Meme trades. Curve convexity does not multiply a pure NAV
move: the Meme/LT reserve ratio is unchanged. Trading changes the curve factor;
the LT strategy changes the USD factor.

### 1.4 Exact buy, sell, solvency, and integer rounding

`Router` initializes a virtual Meme reserve and virtual LT reserve while moving
only real Meme inventory
([source](https://github.com/alt-fun/contracts/blob/625fd21454a5232f2c8582d4b1135a9bdeafedec/src/Router.sol#L69-L85)).
For an uncapped buy of `a` LT units:

```text
y' = y + a
x' = floor(K / y')
Meme_out = x - x'
```

If that output exceeds the live Meme balance `b`, the implementation sets
`Meme_out=b`, computes `x_c=x-b`, and charges
`a_used=ceil(K/x_c)-y`. The ceiling prevents a closing buyer from being
undercharged
([buy math](https://github.com/alt-fun/contracts/blob/625fd21454a5232f2c8582d4b1135a9bdeafedec/src/Router.sol#L87-L146)).
`Zap` pre-sizes the LT mint, refunds excess USDC and LT, and prorates its fee to
the consumed amount
([source](https://github.com/alt-fun/contracts/blob/625fd21454a5232f2c8582d4b1135a9bdeafedec/src/Zap.sol#L266-L390)).

For a sell of `q` Meme units:

```text
x' = x + q
y' = floor(K / x')
LT_out = y - y'.
```

The real-LT solvency argument is simple on the canonical path. A seller cannot
return more than the net Meme released, so `x+q <= S`. Since `K=S*v`,
`floor(K/(x+q)) >= v`; therefore `LT_out <= y-v = l`. The curve never promises
the virtual `v` to sellers. Code still checks that the computed output does not
exceed real custody through token transfer success
([sell math](https://github.com/alt-fun/contracts/blob/625fd21454a5232f2c8582d4b1135a9bdeafedec/src/Router.sol#L148-L180)).

The exact contract invariant is not `x*y=K`. `Pair.swap` accepts a state only
when

```text
(x+1)(y+1) >= K.
```

Normal projections use floors and can leave `x*y<K`; a capped closing buy uses
a ceiling and can leave `x*y>=K`. The contract never asserts an upper product
bound
([Pair source](https://github.com/alt-fun/contracts/blob/625fd21454a5232f2c8582d4b1135a9bdeafedec/src/Pair.sol#L55-L78)).
Every ideal equality in this section is therefore a real-number model. Tests
must use the actual floor/ceiling formulas and the relaxed one-atomic-unit
product check.

### 1.5 Correct graduation trigger

The whitepaper reuses `y` for both virtual-inclusive and “real” LT reserve in
its graduation section. The implementation correctly recognizes

```text
l = stored_asset_reserve - launch_virtual_LT = y-v
```

and tests `l*p >= T`. It does not use raw `balanceOf`, so LT donations cannot
advance graduation. The alternative supply trigger is an empty live Meme
balance
([source](https://github.com/alt-fun/contracts/blob/625fd21454a5232f2c8582d4b1135a9bdeafedec/src/Bonding.sol#L605-L675)).
Any Blast implementation of this model must use recognized `l`, never a raw
donation-inflated balance.

In the ideal model the USD trigger is:

```text
A*u/(1-u) = T
u = T/(T+A)
t = S*u(1-u) = S*T*A/(T+A)^2.
```

`A` changes with LT NAV even without a trade. This means the token can cross
and recede from the threshold before phase one starts. Current source exposes a
permissionless `triggerGraduation`; once called, it enters the forward-only
`Curve -> Graduating -> Graduated` lifecycle and freezes the LT-unit close ratio
([trigger and lifecycle](https://github.com/alt-fun/contracts/blob/625fd21454a5232f2c8582d4b1135a9bdeafedec/src/Bonding.sol#L848-L964)).

That creates an irreversible timing option on an instantaneous external NAV.
A transient favorable print can be captured by any caller, while an unfavorable
print can be ignored until it recovers. A design that insists on a USD trigger
needs a sustained threshold, TWAP, or hysteresis and an explicit oracle trust
model. Blast can remove the option entirely by keeping its existing terminal
target in real Quote units and deriving USD off chain.

### 1.6 Graduation-liquidity proof

At curve close, the recognized LT is `l=y-v`. To open an LT/Meme AMM at the
same LT-unit marginal price, its Meme amount `t` must satisfy

```text
l/t = y/x
t = l*x/y.
```

Substitute `x=S-s`, `y=Sv/(S-s)`, and `l=vs/(S-s)`:

```text
t(s) = s(S-s)/S = S*u(1-u).
```

This parabola is at most `S/4`, with equality at `s=S/2`. The 25% reserve is
therefore sufficient for every ideal curve close. The implementation computes
`floor(l*x/y)`, caps defensively at `S/4`, burns all unsold curve Meme, and
burns unused graduation reserve
([source and proof comments](https://github.com/alt-fun/contracts/blob/625fd21454a5232f2c8582d4b1135a9bdeafedec/src/Bonding.sol#L984-L1049)).
Because `t` is floored, the seeded AMM's `l/t` can be microscopically above the
last ideal curve ratio. “Zero gap” is exact in real arithmetic and approximate
within atomic rounding in code.

At a flat LT price, `A=V=$3,000` and `T=$9,000`:

```text
u = 0.75
l*p = $9,000
t = 187,500,000 Meme
last full-S marginal market cap = A/(1-u)^2 = $48,000
LP value at the last mark = $9,000 Meme + $9,000 LT = $18,000
post-burn total supply = s+t = 937,500,000 Meme.
```

The USD and supply triggers coincide only at the unchanged launch exchange
rate. LT appreciation graduates earlier; LT depreciation can leave the USD
trigger beyond the 75% inventory, so supply exhaustion becomes the backstop.

### 1.7 What the whitepaper claims do not guarantee

- **LP lock:** `LPLock` has no withdrawal function in v1, but it is UUPS
  upgradeable and the owner authorizes upgrades. “No governance path” and
  “locked forever” are stronger claims than current code supports
  ([contract declaration](https://github.com/alt-fun/contracts/blob/625fd21454a5232f2c8582d4b1135a9bdeafedec/src/LPLock.sol#L8-L19),
  [upgrade authorization](https://github.com/alt-fun/contracts/blob/625fd21454a5232f2c8582d4b1135a9bdeafedec/src/LPLock.sol#L117-L119)).
- **AMM continuity under hostile pre-mint:** the ratio proof is unconditional
  for a pristine destination pair and for a donation-only pair that can be
  skimmed. If an attacker has already minted V2 LP, current code swaps toward
  the target, retains the attacker's LP, deposits only a balanced subset, burns
  leftover Meme, and sweeps leftover LT to the owner. Its swap uses a no-fee
  estimate against a fee-charging pool and can be budget-capped, so exact
  continuity no longer holds
  ([three regimes](https://github.com/alt-fun/contracts/blob/625fd21454a5232f2c8582d4b1135a9bdeafedec/src/Bonding.sol#L1062-L1158),
  [rebalance limits](https://github.com/alt-fun/contracts/blob/625fd21454a5232f2c8582d4b1135a9bdeafedec/src/Bonding.sol#L1232-L1397)).
  A safer migrator reserves a unique empty pool/fresh salt or aborts on an
  occupied pool. Blast's typed adapters already prefer reservation, fresh
  creation, then bounded adoption.
- **Address suffix:** a suffix is a discovery heuristic, not authenticity.
  Anyone can mine the same suffix. Authenticity requires factory registry,
  code/package provenance, and the canonical launch event.
- **Redemption:** `Zap.sell` always redeems LT to USDC and reverts when Bounce's
  idle buffer is short
  ([source](https://github.com/alt-fun/contracts/blob/625fd21454a5232f2c8582d4b1135a9bdeafedec/src/Zap.sol#L392-L437)).
  A robust product must also expose direct Meme-to-LT exit.

The May 2026
[Phage audit](https://alt.fun/audit.pdf) reviewed an earlier private commit. It
found two medium and eight low issues. The current public commit includes the
cross-graduation `protectedLT` accounting, capped-buy refund logic, and a
standalone graduation trigger. The audit still usefully documents accepted
risks: LT mint pause creates a sell-only market, launch-time exchange-rate
snapshot shapes the whole curve, and Zap omitted a deadline at the audited
revision.

## 2. ast.fun: the closest second launch-plus-LT system

ast.fun is a BNB Chain launchpad whose official docs describe the same two-layer
shape: an Aster perpetual-backed ERC-20 LT, then a Meme/LT curve and PancakeSwap
V2 graduation. Its docs explicitly call the backing custodial and the product
unaudited beta software
([introduction](https://ast.fun/docs/introduction),
[risks](https://ast.fun/docs/risks)).

### 2.1 Documented curve math

The published parameters are `S=1B`, a 75/25 inventory split, `$4,000` virtual
value, `$12,000` graduation value, a 1% curve fee, and a `$1` minimum trade
([curve docs](https://ast.fun/docs/bonding-curve)). If its implementation follows
the documented constant-product and virtual-LT model, the alt.fun derivation
applies with `V=$4,000` and `T=$12,000`. Because `T=3V`, the unchanged-price
case again has:

```text
u = 0.75
t = 3S/16 = 187,500,000 Meme
recognized real LT value = $12,000
last full-S marginal market cap = 16V = $64,000
LP value = 2T = $24,000
post-burn total supply = 937,500,000 Meme.
```

These numbers are a derivation from documented parameters, not a source-code
verification. The docs independently state that 18.75% seeds the pool at the
flat threshold and 6.25% burns
([graduation](https://ast.fun/docs/graduation)).

ast.fun also documents an instantaneous USD trigger and permissionless
`triggerGraduation`. It therefore has the same irreversible timing option as
alt.fun. Its statement that curve convexity amplifies an LT NAV move does not
follow from the fixed-reserve equations: with no Meme trade, Meme/LT price is
fixed and Meme USD return equals LT return. Convexity changes price with Meme
order flow, not with a pure change in `p`.

### 2.2 The LT and keeper trust model

The LT docs define a pro-rata NAV share:

```text
LT NAV = idle USDT in the vault + equity attributed to it on Aster
exchange rate = LT NAV / LT supply.
```

One shared Aster account nets required exposure across every vault. A keeper
runs every 30 seconds, posts per-vault equity and funding on chain, rebalances
outside tolerance bands, maintains about 20% idle USDT, refills redemptions,
and controls the Aster account through an API agent
([LT docs](https://ast.fun/docs/leveraged-tokens),
[keeper](https://ast.fun/docs/keeper)). This is a materially stronger trust
assumption than one native, isolated account per series:

- the keeper allocates shared account equity among fungible vaults;
- cross-vault netting means an allocation error can move value between series;
- published NAV is authoritative for mint and redemption even though backing
  sits in a keeper-operated external account;
- a keeper or Aster failure can impair every series simultaneously.

The stated controls are directionally sound: stale equity blocks buying, sells
stay open, and large redemptions queue when the idle buffer is insufficient
([trading](https://ast.fun/docs/trading)). The essential lesson for Blast is to
keep “risk-increasing action paused, risk-reducing exit open.” The idle buffer
is a latency optimization, not solvency proof.

### 2.3 Deployment, ABI, and runtime evidence

The official [contracts page](https://ast.fun/docs/contracts) lists deployed
BNB Chain addresses, including `Bonding`
`0x76A596E765187CdADA108bf7EE132e69a63B1190`, `Zap`
`0x2820EAe22066a137E6DDF7D3d861062aa98124bd`, and the LT implementation
`0xD9deE8755B631943e3C34fD4b5a3ed074B320dC7`. The published
[Bonding ABI](https://ast.fun/abi/Bonding.abi.json) exposes stored curve state,
recognized raised LT/USD, previews, `canGraduate`, and
`triggerGraduation`. The
[LT ABI](https://ast.fun/abi/LeveragedToken.abi.json) exposes reported equity,
equity age, total assets, exchange rate, deposit cap, mint pause, immediate
redemption, and queued redemption. The
[Zap ABI](https://ast.fun/abi/Zap.abi.json) includes `sellForLt`, which preserves
direct LT exit when stablecoin redemption is unavailable.

An independent BNB Chain RPC inspection adds useful, but weaker, evidence. The
inspection session began at block `119,143,168` on 2026-08-31 at 11:26:12 UTC.
These are SHA-256 digests of the raw runtime returned by `eth_getCode` during
that session; they make the exact bytecode observations reproducible even when
documentation or proxy targets later change.

| Deployment | Raw runtime bytes | SHA-256 |
| --- | ---: | --- |
| `Bonding` | 17,005 | `1e42a8d75c534271b2bbb28d5a46b1aabe8e011e24fdd339a68aea10bcfe56a1` |
| `Zap` | 17,330 | `67fb29261ce4b00b86cb2f19648e601f487f24f56ec5d8cbc64425130176e0bc` |
| `LPLock` | 984 | `12fc61d572ae80119ce086f2225815a1af8719c4c3a8b3f9a8e12939ae5a9ba2` |
| docs-listed LT implementation | 23,703 | `f94decf86fdd69c6c195e4a00f07f233915798f02897a0334a00a550561486e0` |
| live LT implementation | 23,946 | `06300234d6fbc24ff2a511a5a649415965a9170c1ea10d30d610b0dddd8fccf5` |
| example `xAAPL3L` proxy | 291 | `d0ae16033120b8c42c60df0f712bf565a1c666c154ebfd55cd833187c95c6212` |

The `Bonding` runtime contains Solidity 0.8.28 metadata. Selector and constant
recovery found the documented `$4,000` virtual value, `$12,000` graduation
value, 75/25 split, and five-block trade delay. It appears to be a direct,
non-proxy `Ownable` deployment. The deployed `Zap` runtime contains a 1% fee, a
2% maximum, mutable owner fee and signer controls, a `$5` seed amount, and a
`$1` trade minimum.

The deployed 984-byte `LPLock` runtime at
`0xD09FACfCF5376e0AED99ba30d5825e37A922f49c` has a recovered
external surface limited to `addLocker(address)`, `isLocker(address)`,
`locks(address)`, and `recordLock(address,address,uint256)`. No transfer,
withdrawal, ownership-transfer, or upgrade selector was found. This makes its
permanent-lock claim materially stronger than alt.fun's upgradeable `LPLock`,
although bytecode inspection is not a substitute for verified source.

The LT deployment adds a more important upgrade warning. Each series is a
custom delegate proxy. It asks
[`GlobalStorage`](https://bscscan.com/address/0x99a462aB29Da505835173B43929816e651a3CDBD)
for `ltImplementation()`. At the observation time, that lookup returned the
newer
[`0x90A0...b641`](https://bscscan.com/address/0x90A04B0Ea82E39592Ab52fD382eC55F0d016b641).
The docs-listed direct implementation
[`0xD9de...0dC7`](https://bscscan.com/address/0xD9deE8755B631943e3C34fD4b5a3ed074B320dC7)
reports version `v2.1.0`, while the active
[`xAAPL3L` proxy](https://bscscan.com/address/0x1d94f4ff5e1ffe50eec25f951b144c4f3f1761a7)
reports `v2.2.0`. The recovered runtime surface includes `totalAssets`,
`exchangeRate`, `mint`, `redeem`, queued redemption, `depositToAster`,
`settle`, `rebalance`, `currentLeverage`, `depositCap`, and `dead`.

The site's published ABI still lists methods such as `postEquity` and
`forcePostEquity`, which do not describe that active runtime surface. This is a
concrete integration and governance risk: a launchpad must discover the active
implementation through the proxy, verify its version and code digest, and
bind an explicit upgrade policy. It must not assume that a documentation ABI
or implementation address remains current.

The same on-chain snapshot makes the shared-account boundary concrete. The
[ast.fun LT API](https://api.ast.fun/lts) listed 180 LT series and one unique
Aster backing account. The
active xAAPL3L proxy reported approximately `611.3470` total assets, made of
`122.7286` idle assets plus `488.6184` posted equity. It reported a `1.064093`
exchange rate, `574.524` supply, `3.0243x` current leverage against a `3x`
target, and a `$25,000` deposit cap. Across the listed series, reported equity
summed to about `$13,326`, compared with about `$14,162` shared-account equity,
and idle balances summed to about `$3,325`. These values are a point-in-time
observation, not a solvency audit.

The required cross-series invariant is stronger than any one vault equation:

```text
sum(assigned series equity) + unassigned liabilities
    <= independently observed shared-account equity.
```

The keeper must also conserve every reassignment and netted trade across all
series. One allocation error can misprice many mints and redemptions at once.
Blast should copy ast.fun's exit-first stale-data pause and small immutable LP
lock surface, but reject its shared custodial account and off-chain equity
allocation model.

No official public source repository was located, and automated explorer
access did not yield verified source. Published ABIs document intended
interfaces. Runtime selector and constant recovery support deployment claims,
but they do not prove all branches, authorization rules, or accounting
arithmetic. ast.fun therefore informs product and operational design but is not
a verified-source code reference.

## 3. Bounce.Tech: cross-domain perp-backed share accounting

The current source reviewed is
[`bounce-tech/bounce-smart-contracts@b4b39ba4`](https://github.com/bounce-tech/bounce-smart-contracts/tree/b4b39ba4cb8f3155c51cdc6a59ceef953dc45da9).
Each LT fixes a market ID, target asset, target leverage, direction, and selected
perp DEX at initialization. Mutable state includes mint pause, queued
redemptions, per-user credits, same-block bridge accounting, and three API-agent
slots
([storage](https://github.com/bounce-tech/bounce-smart-contracts/blob/b4b39ba4cb8f3155c51cdc6a59ceef953dc45da9/src/LeveragedToken.sol#L21-L101)).

### 3.1 NAV and share invariants

Bounce computes:

```text
N = EVM_USDC
  + EVM_to_Core_USDC_marked_in_this_block
  + HyperCore_spot_USDC
  + selected_perp_dex_account_value

r = N / S_LT
minted_LT = deposit_USDC / r
redeem_USDC = burned_LT * r.
```

The contract reads spot and selected-dex account value from Hyperliquid
precompiles; notional is exposed separately and is never an asset
([NAV and conversion](https://github.com/bounce-tech/bounce-smart-contracts/blob/b4b39ba4cb8f3155c51cdc6a59ceef953dc45da9/src/LeveragedToken.sol#L334-L362),
[handler](https://github.com/bounce-tech/bounce-smart-contracts/blob/b4b39ba4cb8f3155c51cdc6a59ceef953dc45da9/src/HyperliquidHandler.sol#L17-L64)).
The `blockBridging` term covers the one-block observation gap when EVM USDC has
left but HyperCore has not yet credited it. It is counted only in the initiating
block
([source](https://github.com/bounce-tech/bounce-smart-contracts/blob/b4b39ba4cb8f3155c51cdc6a59ceef953dc45da9/src/LeveragedToken.sol#L457-L473)).

Required invariants are:

```text
NAV includes each custody domain and recognized in-flight transfer exactly once.
NAV includes perp account equity, never gross notional.
exchange_rate * total_supply approximates NAV within declared rounding.
negative or unavailable account value enters Degraded state; it is not silently
treated as a harmless zero.
```

Current `HyperliquidHandler` clamps a negative account value to zero. A new
implementation should freeze risk-increasing actions and expose the impairment
rather than convert a liability/error state to apparent zero assets.

The importance is not theoretical. Bounce's March 2026
[Obsidian audit](https://bounce.tech/bounce-obsidian-audit-3.pdf) found a critical
unified-account regression that omitted perp `accountValue` from `totalAssets`.
NAV would have collapsed as margin moved from spot to perps, allowing new users
to mint too many shares. The issue was fixed. Its April 2026
[Phage review](https://bounce.tech/bounce-phage-audit-2.pdf) also found fee-epoch
and global-minimum edge cases, some acknowledged. Complete state enumeration,
fee checkpoint ordering, and per-series dust limits are launch gates.

### 3.2 Leverage and path dependence

Let `P` be signed perp notional, `d` direction (`+1` long, `-1` short), `L`
target leverage, and `N_a` active equity after excluding queued holders whose
positions are being reduced:

```text
P_target = d * L * N_a
delta_P  = P_target - P
effective_leverage = abs(P) / N_a.
```

Before a rebalance, an underlying return `z` changes leverage to:

```text
long:  L' = L(1+z)/(1+Lz)
short: L' = L(1+z)/(1-Lz).
```

Gains lower long leverage and increase short leverage; adverse moves do the
opposite. Rebalancing realizes that path into NAV. Funding, spread, fees, and
slippage add further drag. “No liquidations” can mean no holder-level margin
call; it cannot mean the pooled perp backing is immune to liquidation or
insolvency.

Bounce's helper subtracts queued share credit times exchange rate from active
equity before measuring leverage
([source](https://github.com/bounce-tech/bounce-smart-contracts/blob/b4b39ba4cb8f3155c51cdc6a59ceef953dc45da9/src/helpers/LeveragedTokenHelper.sol#L217-L268)).
That is the correct economic direction: queued exits must drive proportional
notional reduction instead of leaving remaining holders over-levered.

### 3.3 Mint fairness

`mint` checkpoints, calculates shares at the pre-transfer exchange rate, pulls
USDC, and immediately mints ERC-20 shares
([source](https://github.com/bounce-tech/bounce-smart-contracts/blob/b4b39ba4cb8f3155c51cdc6a59ceef953dc45da9/src/LeveragedToken.sol#L168-L185)).
The perp expansion happens asynchronously. If deposit `C` should add notional
`L*C`, its execution spread and fees are caused by that deposit. Minting before
execution makes old holders absorb part of that later cost through the common
exchange rate.

A fair implementation must choose one explicit rule:

1. Execute the perp delta synchronously and mint from realized post-trade
   equity.
2. Create a pending deposit ticket, execute, then finalize shares subject to
   `min_shares` and a deadline.
3. Charge a conservative execution reserve to the depositor and later refund
   unused amount.

Blast should use option 1 with a native synchronous venue or option 2. It should
not present asynchronous mint-now/trade-later as atomic NAV issuance.

### 3.4 Redemption and leverage fairness

Immediate Bounce redemption succeeds only if EVM-side USDC covers the NAV
amount. It burns shares without synchronously reducing the perp
([source](https://github.com/bounce-tech/bounce-smart-contracts/blob/b4b39ba4cb8f3155c51cdc6a59ceef953dc45da9/src/LeveragedToken.sol#L187-L203)).
If the strategy is at leverage `L` with NAV `N` and pays idle cash `R` while
leaving notional unchanged, remaining leverage becomes

```text
L_after = L / (1-R/N).
```

The correct proportional close is approximately `abs(P)*R/N`, adjusted for
realized execution. An idle buffer only bounds the temporary deviation; it does
not remove it.

Large exits call `prepareRedeem`, escrow LT shares, and later execute at the
then-current exchange rate. The shares stay in total supply and remain exposed
until execution. Cancellation is allowed after one hour
([queue source](https://github.com/bounce-tech/bounce-smart-contracts/blob/b4b39ba4cb8f3155c51cdc6a59ceef953dc45da9/src/LeveragedToken.sol#L205-L262)).
A new queue needs a documented price rule, min-out/deadline, FIFO or pro-rata
batch policy, reserved cash accounting, and an idempotent reduce/bridge/claim
state machine.

### 3.5 HyperEVM/HyperCore is asynchronous

Bounce's engineering account documents the critical boundary in
[“Hyperliquid Precompiles: An Inconvenient Truth”](https://bounce.tech/blog/hyperliquid-precompiles-an-inconvenient-truth/):

- a CoreWriter EVM transaction can succeed while HyperCore later rejects the
  action;
- Core-to-EVM USDC requires perp-to-spot and spot-to-EVM steps, so one may
  succeed while the next fails;
- the bridge or destination may lack capacity;
- historical precompile reads are not reliable enough to reconstruct state
  from ordinary RPC calls;
- account activation, API wallets, and fee balances create hidden liveness
  preconditions.

The contract can register three agents and permits them to initiate bridges
([source](https://github.com/bounce-tech/bounce-smart-contracts/blob/b4b39ba4cb8f3155c51cdc6a59ceef953dc45da9/src/LeveragedToken.sol#L271-L328)).
Its resilience design uses active-active multi-zone workers, per-token isolated
workflows, event triggers plus periodic state re-derivation, IOC limit orders,
and independent price/notional/size/rate/time guards
([engineering post](https://bounce.tech/blog/designing-for-resilience-inside-bounces-rebalancing-system/)).

Those operations require a durable journal, not inference from transaction
success:

```text
Operation {
  nonce, series, kind, source_domain, destination_domain,
  requested_amount, observed_amount, submitted_at,
  state: Prepared | Submitted | SourceConfirmed | DestinationConfirmed |
         Completed | Failed | TimedOut
}
```

Each asset unit is counted in exactly one NAV location at a time. Retrying an
operation reuses its nonce and desired effect. Workers always re-read
authoritative state before acting.

## 4. TLX on Synthetix Perps V2

The direct source is the official, now-archived
[`Synthetixio/leverage-token-protocol@309120ec`](https://github.com/Synthetixio/leverage-token-protocol/tree/309120ecea5bab5c91bd4fe04f11a62aee5bb191).
It is not a current venue recommendation. It is valuable because the share,
trade-impact, delayed-order, and rebalance rules are all visible on chain.

### 4.1 Share issue and redemption

TLX values a token as Synthetix `remainingMargin / totalSupply`. A mint:

1. rejects inactive, paused, over-cap, or pending-order state;
2. estimates the fill-price impact of adding `targetLeverage * deposit`;
3. reduces minted shares when the trade impact is adverse;
4. applies user `minLeveragedTokenAmountOut`;
5. deposits margin and mints; and
6. triggers a rebalance when the deviation threshold is reached.

Redemption mirrors the flow, charges a leverage-scaled redemption fee and
adverse price impact, withdraws margin, burns, and may rebalance
([mint and redeem](https://github.com/Synthetixio/leverage-token-protocol/blob/309120ecea5bab5c91bd4fe04f11a62aee5bb191/src/LeveragedToken.sol#L63-L160),
[exchange rate](https://github.com/Synthetixio/leverage-token-protocol/blob/309120ecea5bab5c91bd4fe04f11a62aee5bb191/src/LeveragedToken.sol#L349-L405)).

The reusable lesson is depositor-specific execution accounting. Even though the
eventual delayed order is not atomic with share mint, TLX estimates the marginal
price impact before issuance instead of unquestionably socializing it.

### 4.2 Rebalance and pending-order exclusion

The Synthetix handler computes:

```text
target_position_units = remaining_margin * target_leverage / asset_price
size_delta = signed_target - signed_current
```

and submits an off-chain delayed order with a 2% price tolerance
([source](https://github.com/Synthetixio/leverage-token-protocol/blob/309120ecea5bab5c91bd4fe04f11a62aee5bb191/src/SynthetixHandler.sol#L54-L86)).
While that delayed order is pending, mint, redeem, and another rebalance are all
blocked. `canRebalance` also requires positive remaining margin and deviation
outside the configured band
([source](https://github.com/Synthetixio/leverage-token-protocol/blob/309120ecea5bab5c91bd4fe04f11a62aee5bb191/src/LeveragedToken.sol#L349-L405)).

Chainlink Automation batches only a configured maximum number of tokens and
maintains per-token exponential backoff after a failure, preventing one broken
series from hot-looping every upkeep
([source](https://github.com/Synthetixio/leverage-token-protocol/blob/309120ecea5bab5c91bd4fe04f11a62aee5bb191/src/ChainlinkAutomation.sol#L38-L72),
[selection](https://github.com/Synthetixio/leverage-token-protocol/blob/309120ecea5bab5c91bd4fe04f11a62aee5bb191/src/ChainlinkAutomation.sol#L121-L157)).

Adopt the explicit `canRebalance`, pending-effect exclusion, per-series failure
isolation, and user min-out. Do not copy the fixed 2% tolerance, authorized-only
rebalance entry, or assumptions specific to one delayed-order venue. Slippage
must be market- and size-aware, and any actor should be able to execute a
bounded, pre-validated risk-reducing rebalance.

## 5. Toros and dHEDGE venue guards

Toros documents perp-backed tokens that use GMX positions and automatic
rebalancing around target leverage
([product overview](https://docs.toros.finance/leveraged-tokens/overview)). The
direct code reference, including GMX and Flat Money guards, is the current
[`dhedge/V2-Public@bf36c1ed`](https://github.com/dhedge/V2-Public/tree/bf36c1ed48eee61b6a5b709af74d3b8e97fc06ba),
the generic vault and guard system underlying Toros strategies.

### 5.1 Exhaustive NAV, including pending venue state

The GMX market guard values:

1. position collateral after PnL and price impact;
2. claimable funding;
3. collateral and execution fees in pending orders;
4. pending deposits;
5. market LP tokens;
6. pending withdrawals; and
7. claimable collateral.

It explicitly filters pending deposits and withdrawals by market so the same
cross-market record is not counted once per supported market
([source](https://github.com/dhedge/V2-Public/blob/bf36c1ed48eee61b6a5b709af74d3b8e97fc06ba/contracts/utils/gmx/GmxPerpMarketAssetGuardLib.sol#L34-L218),
[withdrawal filter](https://github.com/dhedge/V2-Public/blob/bf36c1ed48eee61b6a5b709af74d3b8e97fc06ba/contracts/utils/gmx/GmxPerpMarketAssetGuardLib.sol#L240-L271)).

This is the right design standard: a venue adapter ships with a table of every
state that owns value, whether it is spendable, and which other guard excludes
it. “Pending” is an accounting location, not an excuse to omit the asset.

### 5.2 Risk gates and post-operation assertions

The Flat Money guard rejects new positions over its maximum leverage. An
already-over-limit position may be adjusted only when resulting leverage is
strictly lower, so emergency reduction is not blocked by the normal cap
([source](https://github.com/dhedge/V2-Public/blob/bf36c1ed48eee61b6a5b709af74d3b8e97fc06ba/contracts/guards/contractGuards/flatMoney/shared/FlatMoneyBasisContractGuard.sol#L71-L150)).

Pool deposits compute NAV with oracle freshness checks before minting shares
([source](https://github.com/dhedge/V2-Public/blob/bf36c1ed48eee61b6a5b709af74d3b8e97fc06ba/contracts/PoolLogic.sol#L275-L328)).
Withdrawals calculate a proportional share, burn, process every supported asset,
then assert that actual value loss does not exceed the withdrawn entitlement
within tolerance and that total supply equals the expected post-burn supply
([source](https://github.com/dhedge/V2-Public/blob/bf36c1ed48eee61b6a5b709af74d3b8e97fc06ba/contracts/PoolLogic.sol#L425-L525)).

These checks should surround every LT share mutation. Previews are not enough;
post-state NAV and supply must still reconcile after venue callbacks and
rounding.

### 5.3 Hyperliquid-specific warnings and async withdrawal

The current dHEDGE Hyperliquid guard warns that an API wallet can trade
unsupported assets directly on HyperCore. It cannot withdraw, but invisible
positions can still break NAV. The source says such agents should be enabled
only for private vaults where accurate public accounting is not required
([warning](https://github.com/dhedge/V2-Public/blob/bf36c1ed48eee61b6a5b709af74d3b8e97fc06ba/contracts/guards/contractGuards/hyperliquid/HyperliquidCoreWriterContractGuard.sol#L22-L36)).
An agent that cannot steal cash can still destroy a public share token by
opening unvalued risk.

The position guard sums account value across every approved perp DEX, adds
HyperCore spot USDC, and adds recognized in-flight deposits
([source](https://github.com/dhedge/V2-Public/blob/bf36c1ed48eee61b6a5b709af74d3b8e97fc06ba/contracts/guards/assetGuards/hyperliquid/HyperliquidPositionGuard.sol#L38-L81)).
Its withdrawal manager then makes cross-domain exit explicit:

```text
announceAndReduce -> bridge -> settle
                     \-> timeout cancel
```

It locks pool shares, reserves shared free USDC so two exits cannot spend the
same buffer, requires supplied position IDs to cover nearly all open notional,
places proportional reduce-only IOC orders, waits a block, bridges, waits a
block, and settles. A five-minute timeout returns shares if the flow cannot
complete
([state and reservation](https://github.com/dhedge/V2-Public/blob/bf36c1ed48eee61b6a5b709af74d3b8e97fc06ba/contracts/utils/hyperliquid/HyperliquidWithdrawalManager.sol#L35-L126),
[transitions](https://github.com/dhedge/V2-Public/blob/bf36c1ed48eee61b6a5b709af74d3b8e97fc06ba/contracts/utils/hyperliquid/HyperliquidWithdrawalManager.sol#L148-L303),
[coverage and reduce-only orders](https://github.com/dhedge/V2-Public/blob/bf36c1ed48eee61b6a5b709af74d3b8e97fc06ba/contracts/utils/hyperliquid/HyperliquidWithdrawalManager.sol#L378-L466)).

This is substantially safer than treating EVM submission as completed
HyperCore execution. Blast should copy the state-machine discipline, but only
inside a native LT package; it should not import this remote boundary into
launch core.

## 6. Cross-project invariant matrix

| Invariant | alt.fun / ast.fun | Bounce | TLX | Toros/dHEDGE | Blast requirement |
| --- | --- | --- | --- | --- | --- |
| Product identity | Meme is LT-quoted liquidity, not an LT share | ERC-20 is NAV share | ERC-20 is remaining-margin share | ERC-20 is guarded vault share | UI and events distinguish Meme from LT share |
| NAV completeness | Delegated to LT issuer | EVM + in-flight + spot + selected perp equity | Remaining margin | Enumerates positions, pending orders, deposits, withdrawals, fees | LT adapter lists every custody/pending state exactly once |
| Notional separation | Curve does not own perp notional | Notional measured separately | Notional used for target position | Venue guards value equity/collateral, not gross notional | `notional` never enters assets |
| Mint fairness | Zap mints LT before curve trade, but LT issuer economics remain external | Share mint precedes async position expansion | Charges estimated marginal price impact | Fresh NAV and post-value guards | Atomic execution or pending deposit; depositor bears marginal execution |
| Redemption fairness | Meme-to-USDC may fail on LT buffer | Immediate buffer or queued current-rate execution | Margin withdrawal plus price impact then rebalance | Proportional processing plus value/supply assertions | Proportional notional reduction; queue has explicit price and reservation rules |
| Rebalance exclusion | N/A at launch layer | Off-chain workflow responsibility | Pending delayed order blocks overlapping actions | Per-venue guards and async state | One in-flight economic effect per series/nonce |
| Risk-reducing liveness | Sells remain while LT mint can pause | Redeem is not mint-paused, but buffer can empty | Pause blocks mint; rebalance authorization restricted | Over-limit adjustments allowed only if leverage falls | Pauses block risk increase, never bounded reduce/claim/direct Quote exit |
| Graduation authority | Current USD NAV can trigger irreversible transition | N/A | N/A | N/A | Real Quote target only; USD is derived |
| Donation/double-count defense | Recognized `l=y-v`, stored reserves | Explicit same-block bridge term | Single venue pending order | Market filters and shared-buffer reservations | Recognized state, never raw aggregate balance |
| Destination-pool integrity | Exact only when pristine; hostile pre-mint repaired imperfectly | N/A | N/A | N/A | Reserved/fresh pool or bounded abort; no attacker LP adoption by default |
| Upgrade truth | UUPS lock contradicts “forever” claim | Upgradeable share contracts | Upgradeable/system-dependent | Upgradeable guards | Bind package policy and disclose governance; no immutable marketing for upgradeable custody |
| Keeper compromise | Launch depends on LT issuer | API agent can trade backing | Authorized rebalancer submits venue order | Source warns agents can create invisible positions | Venue calls constrained on chain; one isolated account per series |

The matrix yields six non-negotiable invariants for a public LT:

```text
I1  NAV = sum(recognized assets in all domains) - recognized liabilities,
    with each item counted exactly once.

I2  exchange_rate = NAV / live_share_supply within declared rounding;
    share mint/burn cannot transfer execution cost between cohorts.

I3  desired_signed_notional = direction * target_leverage * active_NAV;
    every risk-increasing action stays inside market, slippage, leverage,
    freshness, and size limits.

I4  queued exit value is either still represented by escrowed live shares or
    a fixed liability, never both and never neither.

I5  retries are idempotent and no two pending operations reserve the same cash,
    margin, shares, or notional reduction.

I6  pause, staleness, cap, and keeper failure cannot block a direct
    risk-reducing path or a Meme-to-LT exit.
```

## 7. Recommended Blast architecture

### 7.1 Keep the launch core generic

Blast already has the right launch-layer boundary. `Launch<Meme, Quote>` keeps
typed `Balance<Meme>` and `Balance<Quote>` reserves and snapshots the selected
Quote parameters at creation
([state and creation](../../sui/launchpad/sources/launch.move#L39-L130)). The
curve caps a crossing buy at an exact real-Quote terminal target, gives a
refund, and checks that a sell never returns more than the real Quote reserve
([curve](../../sui/launchpad/sources/curve.move#L11-L169)). Migration sends only
the configured Meme provision and net real Quote to a typed adapter. It burns
or disposes the remaining curve inventory
([migration](../../sui/launchpad/sources/launch.move#L383-L447)).

Keep these rules unchanged for an LT Quote:

- `virtual_quote` and `migration_quote_target` are LT atomic units.
- Graduation depends only on recognized real LT held by the launch.
- The curve does not read LT NAV, perp position, oracle, keeper, or venue state.
- A sell transfers LT directly from the typed Quote reserve.
- The migration adapter accepts the same exact LT type as the launch.

The launch lifecycle remains small:

```text
Live --real LT target reached--> MigrationReady --typed adapter--> Migrated
  ^
  +-- Meme buy/sell changes real LT reserve; LT NAV alone changes no state
```

This boundary prevents an LT failure from corrupting curve accounting. It also
prevents a fast NAV move from choosing the instant when an irreversible
graduation occurs. An LT mint pause can stop new LT acquisition, but it does
not stop a holder from selling Meme for LT already held by the launch.

### 7.2 Put the perp system in a separate series package

Each `LeveragedQuote<Series>` must be one pro-rata share class for one isolated
strategy account. The series identity must bind:

```text
package and version policy
venue and adapter version
market and collateral
long or short direction
target leverage
oracle set and freshness policy
isolated backing account
```

Do not let an owner change the market, direction, target leverage, or backing
account while the same coin type remains live. A governance change that alters
economic identity must create a new series and coin type. Pure security fixes
need a disclosed upgrade policy, a delay, a code-digest allowlist, and an exit
window where practical.

The LT package, not launch core, owns this state machine:

```text
Standby -> Active <-> RebalancePending
             |              |
             v              v
          Degraded -> EmergencyReduce -> Shutdown
```

- `Active` permits bounded mint, redeem, and rebalance.
- `RebalancePending` excludes overlapping economic effects.
- `Degraded` blocks mint and other risk increases, but permits transfer,
  proportional redemption, claim, and bounded risk reduction.
- `EmergencyReduce` is permissionless when its post-state risk can only fall.
- `Shutdown` closes remaining positions and converts the series to pro-rata
  claim on settlement assets.

Use a native Sui perp venue with synchronous programmable-transaction
composition. If no venue can provide atomic collateral transfer, position
change, and authoritative account state, do not launch the product. Do not
control a remote Hyperliquid account or bridge its accounting into Sui. A
message acknowledged on Sui cannot prove that a remote position filled, and a
remote fill cannot atomically determine Sui share supply.

### 7.3 LT share issue, redemption, and queues

For live shares `S_LT` and recognized NAV `N`, the pre-operation share price is
`e=N/S_LT`. A deposit with realized net value `D_net` mints:

```text
shares_out = floor(D_net * S_LT / N).
```

`D_net` must include the depositing user's venue fees, slippage, funding
accrual during execution, and any explicit protocol fee. Do not mint against
cash received and expand the perp later. That gives the new holder exposure at
the old holder's expense. Use one of these two models:

1. atomic expansion, then mint from the realized post-trade value; or
2. a non-transferable pending-deposit receipt, followed by execution and final
   share mint from realized value.

An immediate redemption must close the holder's proportional notional as part
of the same economic operation. Paying only from an idle stablecoin buffer
increases leverage for remaining holders. If a fraction `r=R/N` of NAV leaves
while notional stays fixed, leverage changes from `L` to `L/(1-r)`.

If the venue requires a queue, make every transition and reservation explicit:

```text
Requested -> ReducePending -> SettlementPending -> Claimable -> Claimed
     \------------- timeout/cancel under fixed rules -------------/
```

A request is represented by escrowed live shares or by a fixed liability, but
never both. Free cash, position reduction, and exit capacity are reserved once
per request nonce. Retries are idempotent. Cancellation cannot restore shares
after their value has already become a settlement liability.

### 7.4 Quote admission and upgrade identity

The current whitelist keys Quote by `type_name::with_original_ids` and snapshots
its numeric launch policy
([source](../../sui/launchpad/sources/launch_config.move#L285-L319)). Original
type identity survives compatible package upgrades. It is therefore necessary,
but not sufficient, for an LT.

Add an LT-specific admission record outside generic curve math. It must attest
the expected series configuration, active code digest or immutable dependency,
upgrade authority and delay, and emergency policy. Launch creation must verify
that attestation and store its version or digest. Governance must remove the
Quote from new launches before an incompatible upgrade. Existing launches keep
the exact coin type and disclose the version that they accepted.

Start with one reviewed 2x series. Do not admit arbitrary user-created LTs,
shared multi-series accounts, or a generic factory whose owner can silently
retarget a coin. Use one account per series and one Quote escrow per launch.

### 7.5 SDK and indexer responsibilities

The SDK and indexer derive presentation values:

```text
Meme/LT curve price = (virtual LT + real LT) / curve Meme reserve
Meme USD price      = Meme/LT curve price * LT NAV per share in USD
effective LT leverage = signed perp notional / LT active NAV
```

With no Meme trade, the Meme/LT price is unchanged and Meme USD return equals
LT share return. The LT's target leverage gives the underlying beta. The curve
does not add more leverage to a pure LT NAV move. The UI must not label the Meme
as a leveraged-token share or promise direct pro-rata redemption against the
perp account.

The indexer should show NAV freshness, effective leverage, in-flight operation,
mint availability, immediate redemption capacity, queued liabilities, and
shutdown state. These are observability outputs. They do not authorize launch
trades or graduation.

## 8. Safe launch parameterization

### 8.1 Reuse Blast's curve geometry

Let:

```text
S = initial Meme supply
I = Meme curve inventory after fixed provisions and fees
H = Meme reserved for destination liquidity
v = virtual LT reserve
R = real LT graduation target
q = current recognized real LT reserve
```

Ignoring fees and integer rounding, Blast's buy equation gives:

```text
x(q) = I*v/(v+q)
P_curve_LT(q) = (v+q)/x(q) = (v+q)^2/(I*v).
```

At migration, only `H` Meme and net Quote principal `Q` seed the destination
pool. Exact marginal-price continuity requires:

```text
Q/H = (v+R)/x(R)
H = Q*I*v/(v+R)^2.
```

With zero Quote migration fee, `Q=R`. Blast's recommended geometry
`I=0.8S`, `H=0.2S`, and `v=R` satisfies the identity:

```text
x(R) = 0.4S
P_curve_LT(R) = 5R/S
P_pool_LT = R/(0.2S) = 5R/S.
```

The full-`S` opening Quote valuation is `S*v/I=1.25v`, and the terminal value
is `5R`. These are LT-unit values. The SDK may multiply them by current LT NAV
for a USD display. The contract must not modify `v`, `R`, or lifecycle state
when LT NAV changes.

Keep `v=R` and the 20% destination provision for the first LT lane. It reuses
the existing tested geometry. If governance later adds a nonzero Quote
migration fee, it must solve the continuity equation with net `Q`, publish the
rounding result, and test the actual destination adapter. It must not assume
that the zero-fee provision remains continuous.

### 8.2 LT risk parameters

Use these launch constraints for the first series:

| Control | Initial policy |
| --- | --- |
| Target leverage | One fixed 2x long or short product, selected after venue-liquidity review |
| Backing | One isolated account and one coin type |
| Mint | Atomic position expansion or pending receipt; no pre-execution share mint |
| Redemption | Proportional position reduction; buffer only accelerates settlement |
| Rebalance | Permissionless execution of a deterministic, bounded `canRebalance` action |
| Staleness | Block mint and risk increase; preserve transfer, claim, direct Meme-to-LT sell, and risk reduction |
| Slippage | User `min_out`, deadline, venue price bound, and size-aware maximum |
| Capacity | Bound by executable market depth, open interest, collateral, and emergency unwind depth |
| Dust | Minimum deposit, redemption, and trade values derived from atomic-unit rounding tests |
| Upgrade | Pinned series identity, disclosed delay, monitored implementation digest, and exit plan |

Do not copy a fixed leverage band or fixed 2% slippage tolerance from another
venue. Derive limits from maintenance margin, oracle uncertainty, market depth,
funding, transaction latency, and the largest authorized operation. The
worst-case move during detection and execution must leave enough margin for an
order that reduces risk.

## 9. Failure modes and required responses

| Failure | Detection | Required on-chain response |
| --- | --- | --- |
| Asset or liability omitted from NAV | Reconcile every custody and pending domain against venue state | Freeze mint; keep transfer and risk reduction; repair accounting before new shares |
| Asset counted in two domains | Per-operation nonce and mutually exclusive accounting location | Abort transition; do not mint or pay twice |
| Venue call accepted but position did not fill | Read authoritative post-state and operation status | Keep operation pending; retry idempotently or cancel under fixed rules |
| Partial fill or partial settlement | Compare filled notional, fees, and collateral with requested deltas | Account the realized part; reserve the remainder; do not claim completion |
| Stale or invalid oracle | Bounded age, confidence, and cross-price checks | Block mint and risk increase; permit bounded reduce-only action |
| Deposit execution cost socialized | Compare pre/post NAV and realized position change | Mint from realized net value or issue no shares |
| Idle-buffer redemption raises leverage | Post-redemption notional/NAV assertion | Reduce proportional notional before final payout or queue the exit |
| Two exits reserve the same cash | Global free-cash and nonce reservation accounting | Reject the later reservation or queue it without claim priority |
| Keeper opens wrong market or direction | On-chain market, direction, size, and reduce-only checks | Reject the call; enter degraded mode after repeated failure |
| Liquidation or negative equity | Maintenance-margin and equity threshold | Stop mint; emergency reduce; move to shutdown and pro-rata settlement |
| LT NAV approaches zero | Minimum NAV/share, supply, and output guards | Stop risk increase; prevent divide-by-zero; allow orderly settlement |
| LT code or series identity changes | Code digest, configuration hash, and upgrade event monitor | Stop new launches and LT mint until reviewed; never reinterpret old curve reserves |
| LT mint cap or pause blocks buys | LT state and preflight quote | Do not accept stablecoin for an unavailable path; direct LT-funded buys may remain |
| Stablecoin redemption buffer empties | Immediate-capacity read | Queue LT redemption; preserve direct Meme-to-LT sell |
| Destination pool is pre-created or pre-minted | Check exact pool identity, supply, reserves, and positions before launch/migration | Use a reserved fresh pool or abort; do not adopt attacker LP by default |
| LT NAV moves across a displayed USD milestone | Compare real LT reserve with fixed `R` | Do nothing to lifecycle; update only SDK/indexer USD display |

For Uniswap-V2-style destinations, a pristine or donation-only pair can preserve
the zero-gap proof. A hostile pre-mint can leave attacker LP supply and residual
balances even after a repair swap. Blast should reserve a unique empty pool or
create it during the migration transaction. If the destination cannot prove
freshness, abort. A package-address suffix or symbol heuristic is not
authenticity evidence.

## 10. Tests and launch gates

### 10.1 LT property and scenario tests

The LT package needs property tests for these rules:

1. Every asset, fee, liability, pending order, and settlement value appears in
   NAV exactly once through every operation state.
2. Deposits at the same realized price receive the same shares regardless of
   batching; the depositor bears its own execution loss.
3. A redemption reduces share supply, NAV, and signed notional proportionally,
   subject only to declared fees and rounding.
4. Escrowed shares plus live circulating shares reconcile with total supply.
   Fixed queue liabilities reconcile with reserved settlement assets.
5. Duplicate, reordered, delayed, and failed operation messages cannot mint,
   pay, reserve, or reduce twice.
6. Stale, missing, negative, and zero venue values select the declared degraded
   path instead of becoming zero NAV silently.
7. A risk-reducing action is possible at and above every configured leverage
   limit. A risk-increasing action is impossible outside the safe region.
8. Fee epochs, funding updates, rounding at one atomic unit, minimum outputs,
   and full-supply shutdown all conserve value within a stated bound.

Fault injection must include partial fills, RPC disagreement, stale keeper
data, duplicate calls, transaction success with venue failure, exhausted
buffer, maximum queue concurrency, oracle jumps, funding spikes, and venue
maintenance. Load tests must prove that emergency reduction remains available
when mint and normal rebalance traffic are saturated.

### 10.2 Launch and migration tests

Repeat the existing curve vectors with the LT as Quote and add these cases:

- exact terminal buy, gross-input cap, fee rounding, and excess-LT refund;
- real LT reserve conservation across buy, sell, fees, and migration;
- LT NAV changes with no Meme trade, proving no reserve or lifecycle change;
- direct Meme-to-LT sell while LT mint and stablecoin redemption are paused;
- terminal curve price versus actual post-fee migration seed price;
- destination pool already created, donated to, or pre-minted by an attacker;
- wrong LT type, wrong series attestation, changed code digest, and stale
  implementation version;
- zero/near-zero LT NAV, tiny trade output, and maximum atomic values; and
- migration retry, adapter residual, wrong price, and wrong pool identity.

The migration transaction must verify the actual pool balances, supply, price,
and consumed amounts. Blast's migration math already derives price from the
terminal balances and bounds price deviation and residuals
([source](../../sui/migrators/sources/migration_math.move#L21-L132)). Keep those
checks venue-specific and fail closed.

### 10.3 Public launch gate

Do not enable an LT Quote until all items are true:

- A native Sui perp venue supports the required synchronous composition.
- One 2x series has reviewed source, a threat model, audits, and public code
  identity.
- One isolated account backs one coin type; no agent can trade another market.
- NAV covers every custody and pending state, and independent reconciliation is
  live.
- Mint uses realized execution value; redemption reduces proportional risk.
- Rebalance and emergency-reduce conditions are deterministic and executable
  by any caller within bounds.
- Direct Meme-to-LT sell works when LT mint and stablecoin redemption do not.
- Queue reservations, cancellation, timeout, and claims pass concurrency and
  idempotency tests.
- Launch pins the LT series attestation and uses fixed real-LT `v` and `R`.
- The destination pool is reserved or atomically fresh, and migration
  continuity passes integer test vectors.
- The SDK calls Meme an LT-quoted launch token, not an LT share, and shows NAV
  freshness, leverage, exit capacity, and all degraded states.
- Monitoring and a rehearsed emergency unwind are live before deposits open.

If the first gate is false, the correct launch decision is to wait. A remote
perp account plus bridge is not an acceptable substitute for native atomic
composition.

## 11. Source status and limits

| Project | Direct evidence used | Important limit |
| --- | --- | --- |
| alt.fun | May 2026 whitepaper, audit, and pinned current public source | External LT economics remain delegated to Bounce; destination repair is venue-specific |
| ast.fun | Current docs, deployments, ABIs, BNB Chain runtime and selector inspection | No official public source repo found; proxy, docs, and ABI versions can drift |
| Bounce | Pinned current public source, audits, and engineering posts | Cross-domain liveness depends on Hyperliquid behavior and off-chain agents |
| TLX | Pinned source with on-chain delayed-order logic | Repository is archived and Synthetix Perps V2 assumptions are venue-specific |
| Toros/dHEDGE | Current product docs and pinned public vault/guard source | Strategies and guards vary by venue; generic patterns do not prove one pool safe |
| Blast | Current local launch, curve, graduation, configuration, and migration source | LT issuer and native perp adapter do not yet exist in this design recommendation |

This report establishes a design direction, not a safety claim for any listed
product. Before implementation, Blast still needs a native venue evaluation,
formal LT state and accounting specifications, code-level threat modeling, and
economic simulation under liquidation, funding, liquidity, and queue stress.
