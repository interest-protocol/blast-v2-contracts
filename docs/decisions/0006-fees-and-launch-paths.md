# 0006: Asset provenance, seed mode, and creator fees

- Status: proposed
- Date: 2026-08-22
- Amended by: [0023](0023-generated-coin-supply-and-metadata-custody.md), [0041](0041-launch-config-owned-trade-fees.md)

## Sources

| Ref | Full commit | Repository |
| --- | --- | --- |
| `sui@ae60d06` | `ae60d065ed27576d25ac1c94145e5ffe3ddcf89e` | MystenLabs/sui |
| `bluefin@91ce930` | `91ce930575b2aa3decab9b7e129b8002deba80c1` | fireflyprotocol/bluefin-spot-contract-interface |
| `memez@00596fd` | `00596fdac4dd11f427c7bc594e566ce36160db93` | interest-protocol/memez-gg |

## Context

"Launcher contributes one or both coins" conflates two independent questions. Separating them is the
substance of this ADR:

- **Where does the meme supply come from?** — asset provenance.
- **How is the curve initially funded?** — seed mode.

Both must be answered against the selected custom quote asset of
[ADR 0005](0005-quote-asset-generalisation.md), not against an assumed SUI.

## Decision

### Axis A — asset provenance

**A1. Generated Coin Registry currency. Default, and the only provenance in scope.** The full supply is
minted in the template package's `init` and no mint path survives
([ADR 0002](0002-coin-creation-and-currency-authority.md),
[ADR 0003](0003-treasury-cap-lifetime-and-burn.md)).

**A2. Existing coin. Out of scope for the first release.** The exclusion is stated as invariants, not
preference. An existing coin is admissible only if all three hold:

1. **supply authority** — Blast can hold the `TreasuryCap`, or the coin is already `BurnOnly`;
2. **metadata authority** — the `MetadataCap` is available or provably deleted;
3. **burn capability** — sell-side burn is reachable.

A coin whose `TreasuryCap` is third-party-held fails (1) and therefore cannot support sell-side burn. A
coin already in the `Fixed` supply state cannot burn at all: `coin_registry::burn` aborts unless the
state is `BurnOnly`
(`sui@ae60d06:crates/sui-framework/packages/sui-framework/sources/registries/coin_registry.move:399-411`).
Re-entry requires its own ADR that shows each invariant satisfied.

### Axis B — seed mode

**B1. Standard virtual-quote fair launch. Default.** The curve holds all meme inventory, quote
accumulates from buyers, and virtual quote liquidity sets the opening price. No party contributes quote
at creation.

```text
quote atomic units:  quote_in_total = quote_out_total + Q + accrued_fees_quote
meme atomic units:   M0 = M + meme_outstanding + burned_sell_side
```

The two identities are in different units and are never combined; the full pair is in
[ADR 0003](0003-treasury-cap-lifetime-and-burn.md).

**B2. Creator quote contribution (dev-buy).** Optional. The creator's quote enters as an **ordinary trade
at the same curve price as any other buyer**, in the same transaction as the launch or after it. It
produces an ordinary meme position with ordinary provenance and no privileged terms.

It advances the terminal threshold, because the threshold counts real quote
([ADR 0004](0004-bonding-curve.md)). That is a disclosed consequence, and the contribution is emitted as
a distinct event so an indexer can separate creator-supplied progress from market-supplied progress.

```text
quote atomic units:  quote_in_total = quote_out_total + Q + accrued_fees_quote
                     where quote_in_total includes the creator contribution as a normal buy
meme atomic units:   unchanged from B1
```

**B3. Dual-asset contribution.** Permitted only with **explicit provenance and explicit claim ownership**
recorded on-chain:

- which party contributed which asset, and how much of each;
- whether contributed meme is **curve inventory** (priced by the curve, indistinguishable from `M0`) or a
  **named claim** (outside the curve, withdrawable under stated rules);
- who owns the resulting claim and under what conditions it can be withdrawn.

**Every contributed unit is either curve inventory or a named claim. There is no third category.** A
balance that is neither priced nor claimable would be a hidden reserve, and this design does not have
one. The invariant is executable:

```text
meme atomic units:   total_meme_held_by_launch  = M + accrued_fees_meme + named_meme_claims
quote atomic units:  total_quote_held_by_launch = Q + accrued_fees_quote + named_quote_claims
```

with a test asserting no residual on either line.

### Fees

| Fee | Charged on | Asset | Ceiling | Recipient |
| --- | --- | --- | --- | --- |
| creation fee | launch | quote | hard ceiling in config | protocol |
| trade fees | every buy and sell | quote, meme, both, or neither under cold launch policy | independently bounded `LaunchConfig` rates | split protocol / creator |
| migration fee | terminal settlement | quote | hard ceiling in config | protocol |

Admins set fixed `quote_fee_bps` and `meme_fee_bps` as cold `LaunchConfig`
policy, and each launch snapshots the current pair
([ADR 0004](0004-bonding-curve.md), [ADR 0021](0021-pure-constant-product-curve-quotes.md),
[ADR 0041](0041-launch-config-owned-trade-fees.md)). Zero disables the
corresponding asset; either or both may be positive up to the independently
enforced 1,000-basis-point ceiling accepted by [ADR 0022](0022-dual-asset-fee-ledger-and-claims.md). Fees
**accrue** into separate named balances of their charged assets and are **claimed** separately; they are
never routed to an arbitrary recipient during a trade. Every fee division rounds **up** in the
protocol's favour, per `../engineering-principles.md`, and the rounding beneficiary is named at each
division site.

Proposed vector fixture: `QUOTE_FEE_BPS = 100` and `MEME_FEE_BPS = 0`. These are examples, not launch
defaults or protocol-wide rates. The protocol/creator split reads the current global configuration on
every trade, with ceiling rounding on the protocol amount, as accepted by ADR 0022.

Proposed: `MIGRATION_FEE_BPS = 100` and `MIGRATION_FEE_CEILING_BPS = 300`. **Proposed, not accepted.**
These are the two values [`../vectors/curve.json`](../vectors/curve.json) sources from this ADR for its
`terminal_disposition` case, so the vector's parameter block and this ADR must be changed together.

**There is no referrer argument and no referral discount in the curve fee path.** The historical design
took `referrer: Option<address>` on every trade and funded the referrer by discounting the protocol share
(`memez@00596fd:fun/sources/structs/constant_product.move:73-99`;
`memez@00596fd:fun/sources/structs/fees.move:122-168`). Blast settles referral economics entirely
out-of-band ([ADR 0009](0009-referrals-and-revshare.md)), so both curve fee assets split only between
protocol and creator.

### Venue-side fees are not Blast fees

> Amended by [ADR 0027](0027-graduation-economics-and-migration-witnesses.md):
> the Bluefin charge below remains a pinned external-interface fact, but a DEX
> requiring any pool-opening payment is ineligible for Blast. No such cost or fee
> asset enters core accounting.

Bluefin charges a pool creation fee paid as a `Balance<CoinTypeFee>`, with the amount read from
`config::get_pool_creation_fee_amount`
(`bluefin@91ce930:sources/pool.move:186-202`, the `creation_fee: Balance<CoinTypeFee>` parameter at `:200`; `bluefin@91ce930:sources/config.move:66`). The interface comment documents the protocol share of swap fees on creator-created pools as **fixed at
25%**, not settable by the pool creator
(`bluefin@91ce930:sources/pool.move:157`). That is the cited fact. Premise **P7** is narrower: whether
the **live mainnet `GlobalConfig` still matches that documented 25%**, since the comment is source prose
in an interface package whose bodies `abort 0` and cannot be executed to confirm it. This is not a
Blast fee line and is not supported by the accepted V2 design.

## Alternatives considered

**Restrict fees to one asset.** Rejected by ADR 0021 and ADR 0022: independent
quote and meme rates let policy configure neither, either, or both while every
charged asset remains explicitly accounted.

**Route fees directly to recipients during a trade.** Rejected: it makes a trade depend on an arbitrary
recipient's ability to receive, and `../architecture.md` keeps arbitrary recipient execution out of the
fee component.

**Privileged creator allocation at launch.** Rejected for the first release: a creator position obtained
at a better-than-market price is an unpriced transfer from later buyers, and B2 obtains the same exposure
at the honest price.

**Allow contributed balances outside both categories.** Rejected: that is the hidden-reserve failure mode
this ADR exists to prevent.

## Consequences

- A1 plus B1 is the default launch, and it is the simplest possible accounting.
- B2 makes creator-driven threshold progress visible rather than disguised.
- B3 requires the claim model to be specified and tested before it can ship; until then only A1 with B1
  or B2 is releasable.
- Existing-coin launches are a documented specification gap with named re-entry conditions, not an
  omission.
- Creator fee economics are entirely on-curve and out-of-band referral economics never touch them.

## Verification

- Provenance × seed-mode matrix, with a conservation equation and a test per cell.
- "No unlabelled balance" invariant test after every operation and every sequence.
- Fee-ceiling tests: a configuration above the ceiling aborts with a named error.
- Rounding tests: the odd atomic unit in a fee split goes to the stated beneficiary.
- B2 test: a creator contribution receives exactly the same meme amount as an identical third-party buy
  at the same state.
- A2 negative test: attempting a launch against a `Fixed`-supply coin aborts, demonstrating the burn
  invariant that keeps A2 out of scope.
- Premise **P7** — whether the live Bluefin `GlobalConfig` matches the 25% protocol share documented at
  `bluefin@91ce930:sources/pool.move:157`. Test: read the live `GlobalConfig` on mainnet and compare.
