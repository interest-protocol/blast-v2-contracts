# Creator fees redirected to holders: launchpad mechanisms

Research date: 2026-09-05. This is comparative research, not an accepted architecture decision or an audit. Pons Family is a real launchpad on Robinhood Chain; the name does not need correction to pump.fun.

## Finding

Separate **fee collection** from **holder entitlement**. Pons exposes creator-fee routing, while independent projects implement holder distributions on top. The mechanisms found are an operator paying wallet holders, snapshot rounds with a root publisher, and staking with an on-chain reward accumulator. Robinpad separately advertises passive reflection tokens. These are materially different products and trust models.

## Pons core: fee routing is the extension point

Cloned the first-party [Pons repository](https://github.com/ponsdotdev/ponsfamily), pinned at `845bd546b37515621e47b08015ce4f9d374f6eca`, and inspected Solidity rather than inferring implementation from marketing.

The V2 launch token inherits ordinary OpenZeppelin `ERC20` and `ERC20Burnable`; it contains no transfer callback into a holder-reward ledger. Supply initially belongs to the bonding curve. Native token behavior therefore does not implement passive dividends. [Token source](https://github.com/ponsdotdev/ponsfamily/blob/845bd546b37515621e47b08015ce4f9d374f6eca/contractsV2/src/v2/PonsV2LauncherToken.sol).

The factory accepts a separate `creatorFeeRecipient`. The current recipient can transfer that role, and the factory propagates the change to the curve before graduation or the V4 hook afterward. It also changes the buyback beneficiary. Critically, the protocol owner can propose an override of **any** launch's recipient, subject to a timelock; using an immutable downstream vault does not remove that upstream authority. [Factory source, recipient controls](https://github.com/ponsdotdev/ponsfamily/blob/845bd546b37515621e47b08015ce4f9d374f6eca/contractsV2/src/v2/PonsV2LaunchFactory.sol#L879).

After graduation the hook accumulates swap fees, converts launch-token fees into the quote asset, deducts protocol and optional buyback amounts, and credits the remaining creator amount plus creator tax to an escrow. Thus a recipient contract is the natural composition point; neither fee funding nor holder calculation needs to be embedded in the token. [Hook distribution source](https://github.com/ponsdotdev/ponsfamily/blob/845bd546b37515621e47b08015ce4f9d374f6eca/contractsV2/src/v2/hooks/PonsV2MemeHook.sol#L688).

The first-party docs describe the same quote-denominated revenue before and after graduation. Sweeps requiring internal swaps depend on a designated operator; a creator can sweep already-quoted fees when no internal swap is required. Current docs identify factory `0x7eD598BcEf8bd9Edd8C97A195C6d13f40801EC7e`, whereas the repository README lists V2 factory `0x7E1EAbd52Ae29598e6483F72dCf1a70b14284dB8`. Resolve a particular token's originating deployment; do not equate repository HEAD with every deployed generation. [Pons V2 docs](https://docs.ponsfamily.com/v2), [repository deployment table](https://github.com/ponsdotdev/ponsfamily/blob/845bd546b37515621e47b08015ce4f9d374f6eca/README.md).

## Pons ecosystem: wallet-holder payouts by an operator

Cloned the independent [`pons-fee-distributor`](https://github.com/rebateprotocol/pons-fee-distributor) at `24818c411378865eeaad4cf3210962b19b08468c`. This is a TypeScript service using Pons V1's locker, not a native reflection contract.

The loop previews fees, builds a holder set, claims WETH and token-denominated creator fees to its signing wallet, deducts a configurable service fee, pays ETH/WETH, and sends its remaining launch tokens to a dead address. Payouts are weighted by eligible balances, not volume or time held. Defaults are a 10% service fee and a minimum holding of one basis point of total supply; these are configuration defaults, not verified production settings. [Execution source](https://github.com/rebateprotocol/pons-fee-distributor/blob/24818c411378865eeaad4cf3210962b19b08468c/src/fee-distributor/index.ts), [configuration](https://github.com/rebateprotocol/pons-fee-distributor/blob/24818c411378865eeaad4cf3210962b19b08468c/src/core/config.ts#L84).

Source inspection reveals details absent from the README:

- The primary holder path queries paginated Blockscout balances and excludes **every contract address**, as well as known protocol and burn addresses. Smart contract wallets therefore do not qualify through that path.
- Its fallback replays Transfer events to discover addresses and multicalls current balances. That path only applies the explicit exclusion list, so eligibility can differ from the API path.
- Neither path pins all balances to one historical block. The API scan is capped at 400 pages, and the fallback allows failed balance reads to be skipped. It is not an independently verifiable historical snapshot.

These are findings from the [holder-selection implementation](https://github.com/rebateprotocol/pons-fee-distributor/blob/24818c411378865eeaad4cf3210962b19b08468c/src/core/holders.ts), not claims that a particular production payout was wrong.

The arithmetic floors each proportional share and assigns residual rounding to the final holder. Payments use individual transactions or optional batches of 200 through Disperse. Individual failures are skipped; the inspected loop does not provide holders an on-chain entitlement claim. Custody, allocation, availability, and recovery therefore depend on the operator and its database. [Allocation and payout implementation](https://github.com/rebateprotocol/pons-fee-distributor/blob/24818c411378865eeaad4cf3210962b19b08468c/src/core/distributor.ts).

## PonsVault: staking and snapshot dividends

PonsVault explicitly describes itself as an independent layer. Its current documentation offers:

- **Staking:** deposit launch tokens and receive fee rewards proportional to stake, with an optional principal lock.
- **RWA Dividend:** convert creator fees into a selected tokenized stock; wallet holders qualify without staking. A purchase opens a round, allocations use holdings at round opening, and expired unclaimed rewards roll into another round.
- A factory description explicitly identifies a distributor that posts round roots, establishing an external entitlement-publication role.

The same page discloses **shared beacon upgrades**, so fixed parameters do not prove immutable execution. It also contains apparent V1-era locker/WETH explanations alongside V2 escrow/quote-asset descriptions; use it for product semantics, not authoritative current call sequencing. The linked repository returned 404 during this investigation. Root encoding, funding constraints, replay protection, and deployed bytecode remain unverified. [PonsVault first-party docs](https://www.ponsvault.com/docs).

## Robinpad: closer to native passive reflection

Robinpad documents reflection launches directly into hooked V4 pools, with no curve or graduation. A 2% swap tax allocates 0–20% of that fee to the creator, 50–70% to holders, 10% to ROBIN stakers, and 20% to the platform. The holder portion buys a selected tokenized stock, with automatic payments and a `claim()` fallback. These percentages describe shares **of the tax**, not percentages of trade volume. [Robinpad docs](https://www.robinpad.app/docs).

A first-party hook submission includes Solidity for `ReflectionFeeHook` at `0x28cd4Baa8903c95F2525C2D47eF4fB48886060cc`. It takes an ETH-denominated 200-basis-point fee through V4 before/after-swap return deltas and calls the parent factory's `creditGraduatedFee(token)`. This verifies the **published fee-collection design**, not holder accounting. The submission says its source was not verified on the explorer when submitted; its older graduation wording also differs from current instant-launch docs. No complete reflection ledger source or bytecode match was established. [Developer submission and hook source](https://github.com/Uniswap/hooklist/issues/1125).

## Other useful distinctions

Hood.dev documents one staking pool per launch, independent token/WETH `rewardPerShare` accumulators, and rewards proportional to stake when funding arrives. Deposits reset a 24-hour principal lock; claims remain available. Empty-pool rewards queue and are released to the first depositor, explicitly giving that depositor a historical-fee windfall. Existing pool clones have no upgrade/admin path according to these docs; changing the master implementation affects future launches. This is a useful on-chain accumulator reference, but requires a deposit and does not reward every wallet holder. [Hood.dev staking specification](https://hood.dev/docs/staking).

Pump.fun's official cashback documentation instead credits each trader according to their own swap volume. It is not passive holder rewards and should not be used as the entitlement model for this task. [Pump cashback specification](https://github.com/pump-fun/pump-public-docs/blob/main/docs/PUMP_CASHBACK_README.md).

## Implications for the proposed Sui architecture

These are design inferences, not claims about the projects above:

1. Keep fee routing, entitlement computation, and payouts separate. A contract-owned creator entitlement can fund a reward vault without adding holder distribution to each swap.
2. If the product promise is rewards for ordinary wallet holders, staking is a different product. Historical balance indexing plus funded claim rounds preserves wallet ownership but introduces a trusted root publisher.
3. Publish the precise checkpoint range, exclusion rules, balances or balance-time weights, budget, and generated allocation artifact. A Merkle proof proves inclusion under an accepted root; it does not prove the publisher calculated fair allocations.
4. Prefer independently claimable, immutable funded rounds over money held in a bot wallet. Domain-separate leaves by chain/package/vault/round/asset and recipient; bind payment to the leaf beneficiary and track consumed entitlement.
5. Check the entire authority chain. An immutable payout module still depends on who can redirect its upstream creator right, upgrade its execution, replace a root, or block fee collection.
6. Decide reward assets explicitly. Paying both collected assets in kind avoids a conversion operator and trading-price risk; promising only SUI requires a separately specified conversion mechanism.
7. Avoid live paginated snapshots. Historical coherent checkpoints and balance-time eligibility address inconsistent holder sets and reduce rewards captured by briefly buying immediately before a known snapshot. They do not remove publisher trust or all economic manipulation.

## Evidence limits

Pons core and the independent fee-distributor source were fetched and inspected; their checked-out code was not executed. No signing wallet was created and no transaction was sent. Robinhood's public RPC returned HTTP 403 for a read-only chain-ID/code request, and the Blockscout source API did not return usable JSON. Consequently this report does **not** claim deployed bytecode equivalence, live balances, active parameters, or completed security audits. Public source and documentation are sufficient to identify the architectural patterns, but not to approve integration with those deployments.
