# Euphoria Finance Tap Trading

- Date: 2026-08-31
- Status: product and risk research; not a protocol decision or investment advice
- Scope: Euphoria's current public documentation and its March 2026 Sherlock audit
- Evidence: first-party Euphoria documentation and the audit report Euphoria publishes

## Executive summary

Euphoria is a mobile-first market for very short-lived price predictions. Its
interface shows a grid of price bands across time. A user selects a stake and
taps a band. The tap wins if the reference price enters that band before its
five-second time window ends; one touch is sufficient. Otherwise, the complete
stake for that tap is lost
([trading guide](https://docs.euphoria.finance/euphoria/how-to-tap-trade)).

The underlying instrument is a fully collateralized exotic derivative that the
audit calls a "box option." It is closer to a touch/no-touch digital option than
to spot trading or a perpetual future. The user does not buy the underlying
asset. The user buys a binary payoff on the path of its price during one short
window
([audit report](https://docs.euphoria.finance/euphoria/audit-report)).

Professional market makers submit live multiplier quotes for each square. The
best quote is displayed. Distance from the current price, time remaining, and
market volatility affect the quote. A user-defined slippage limit rejects a
trade when the multiplier deteriorates too much before execution
([platform description](https://docs.euphoria.finance/euphoria/about-the-platform)).

The product currently advertises zero explicit trading fees. This does not mean
that trading has zero economic cost. A market maker can include its spread,
risk premium, and expected edge in the multiplier. Deposits and withdrawals can
also incur gas, swap, bridge, or fiat-provider charges
([fees and limits](https://docs.euphoria.finance/euphoria/fees-and-trading-limits)).

## User and settlement flow

```text
market maker quotes each square
            |
            v
user selects a stake and taps one square
            |
            v
smart contracts lock the two sides' collateral
            |
            v
RedStone supplies the reference low/high price data
            |
            v
price touched the square? -- yes --> multiplier payout
            |
            no
            v
the user's stake expires worthless
```

The docs describe the flow as follows:

1. Market makers publish live quotes.
2. The user submits a trade from an account wallet.
3. Euphoria contracts record and collateralize the position.
4. A custom RedStone oracle supplies external prices for settlement
   ([architecture](https://docs.euphoria.finance/euphoria/architecture-and-technology)).

The audit's contract description confirms that a winning taker receives the
taker and maker collateral, less any configured fee. This supports reading the
displayed multiplier as a total-return multiplier. If a square displays `m x`,
the implied break-even hit probability is approximately `1 / m` before all
other costs. For example, a `4x` total payout requires a true hit probability
above 25% to have positive expected value. Euphoria does not publish the market
makers' probability model, spread, or expected edge in its current docs.

## Product details in the current docs

- Each square represents a price band during a five-second window. A touch at
  any time during the window wins; the price does not need to remain there.
- Closer squares normally have lower multipliers, while farther squares have
  higher multipliers.
- The default stake is $0.10. New accounts have a maximum $5 trade and $25 total
  stake per square. Standard accounts have a maximum $10 trade and $50 per
  square. The criteria for becoming Standard are not documented
  ([fees and limits](https://docs.euphoria.finance/euphoria/fees-and-trading-limits)).
- The FAQ currently lists Ethereum as the supported underlying. It says Bitcoin
  and Solana are planned. Assets can change
  ([FAQ](https://docs.euphoria.finance/euphoria/faq)).
- Funding options include crypto swaps, USDM on MegaETH, cards, Apple Pay, and
  Google Pay. Third parties provide several of these routes.
- Euphoria says it has no token and no current token-generation event
  ([FAQ](https://docs.euphoria.finance/euphoria/faq)).

## Custody and account nuance

Euphoria describes the platform as non-custodial and says it cannot move funds
without user authorization. The FAQ also says that a login wallet is only used
for authentication and that Euphoria automatically creates a separate embedded
wallet, whose address is the deposit address
([platform description](https://docs.euphoria.finance/euphoria/about-the-platform),
[FAQ](https://docs.euphoria.finance/euphoria/faq)).

Those claims are not necessarily inconsistent, because an embedded wallet can
be self-custodial. The docs do not explain the wallet provider, key custody,
recovery model, export path, account-abstraction permissions, or what happens if
the authentication provider is unavailable. A user should verify those details
before depositing a material amount.

## Architecture and trust boundaries

Euphoria runs on the EVM-compatible MegaETH network. The docs attribute its
choice to low latency and low costs. Quotes are produced off chain by market
makers, positions and collateral are handled by smart contracts, and settlement
uses a custom RedStone oracle
([architecture](https://docs.euphoria.finance/euphoria/architecture-and-technology)).

This is therefore not a trustless automated-market-maker design. Its important
dependencies are:

- market makers for quote availability and multiplier quality;
- Euphoria's order, signer, and operational infrastructure;
- the exchange and vault contracts;
- RedStone data and Euphoria's custom oracle integration;
- MegaETH execution and availability;
- USDM as collateral; and
- wallet, bridge, swap, card, and fiat providers used around the core trade.

The current docs do not publish the pricing algorithm, market-maker identities,
oracle feed construction and outage rules, full privileged-role map,
upgradeability policy, or detailed solvency telemetry.

## Audit findings

The published Sherlock review covered the exchange, vault, two access-control
contracts, position storage, and a modified Solady red-black-tree library. It
reviewed an audited commit and a stated final remediation commit from March
12-16, 2026
([audit report](https://docs.euphoria.finance/euphoria/audit-report)).

The report records:

| Severity | Found | Marked unresolved and unacknowledged |
| --- | ---: | ---: |
| High | 0 | 0 |
| Medium | 1 | 0 |
| Low/informational | 5 | 0 |

The medium issue could permanently lock both sides' collateral when the winning
address was blacklisted by the collateral token. The low findings included an
unsafe one-step vault-leader transfer, a privileged manual-settlement path that
could settle before expiry with supplied prices, inefficient position storage,
dead expiry validation, and an ERC-4626 first-deposit inflation scenario. The
report marks all findings resolved.

The manual-settlement finding is especially useful for understanding the trust
model. Euphoria signers retain an operational fallback for oracle failures. The
reported missing expiry guard was fixed, but the existence, security, and
governance of privileged signers remain a trust assumption.

An audit is not a guarantee. The report covers named source files and commits,
not every component in the product. It does not establish the security of the
web application, embedded wallet, market makers, live oracle operations, third-
party funding routes, or code deployed after the reviewed commit. Sherlock's
own report disclaims any security warranty.

## Principal user risks

1. **Binary-loss risk.** Each unsuccessful tap loses its complete stake. Rapid,
   repeated small trades can accumulate into a large loss.
2. **Embedded pricing edge.** Zero explicit fees do not establish fair odds.
   Market makers choose the multipliers and can price in a spread or edge.
3. **Path and oracle risk.** Settlement depends on whether a very short price
   interval touched a band. Feed sampling, latency, precision, and outage rules
   are economically important but not fully specified.
4. **Liquidity risk.** Quotes can disappear, move before execution, or support
   only small size. The product documents slippage failures, missing quotes,
   rate limits, and account limits.
5. **Smart-contract and privileged-role risk.** The contracts can have defects,
   and operational signers and leaders have authority. The audit reduces but
   does not remove these risks.
6. **Collateral and network risk.** USDM, MegaETH, bridges, and other providers
   add depeg, blacklist, chain, and integration risk.
7. **Behavioral risk.** The product intentionally uses one-tap execution,
   leaderboards, streaks, and social sharing to encourage frequent use.
   Simplicity of interaction does not make the derivative simple or low-risk.
8. **Legal and access risk.** These are real-money crypto derivatives. User
   eligibility and regulatory treatment depend on jurisdiction. Public program
   terms place responsibility on the user and exclude restricted jurisdictions
   ([program terms and disclaimer](https://docs.euphoria.finance/euphoria/euphoric-mondays)).

## Bottom line

Euphoria is a polished interface over a high-frequency exotic-options market.
Its innovation is interaction design: it converts a collateralized, oracle-
settled touch option into a square that can be bought with one tap. The simple
interface does not simplify the economics. A user is still accepting market-
maker odds, oracle rules, contract and signer risk, and a binary loss on each
attempt.
