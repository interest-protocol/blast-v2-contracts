# Native V2

Full-range Meme/Quote constant-product pools with separately claimable Quote
fees. The accepted policy and trust boundaries are in
[ADR 0076](../../docs/decisions/0076-native-v2-and-auto-lp.md).

The DEX administers itself. It creates its own domain through the immutable
shared administration package and governs the factory, pool policy, and its own
sealed package custody with that domain's capabilities; a Launchpad, Blast SUI,
or Series One capability is a different type and reaches nothing here. Pool
policy is generic administration, so a live administrator with no role may set
it, while upgrade custody additionally requires the exported package-admin role.
The single deliberate exception is `migration::claim_protocol_fees`, which
claims from a Launchpad-owned fee ledger and therefore stays under Launchpad
product-fee custody.

Its operational generation is independent too: advancing the DEX leaves
Launchpad, Migrators, and Distributor on their own generations, and a governed
upgrade commits its receipt and advances the generation in one transaction.

A pool starts with a zero-to-200-bps volume fee ramp. Protocol administrators
can change its maximum up to 500 bps. Recent Quote principal decays with a
30-minute half-life; the initial Quote seed fixes the volume target. Each trade
pays the integral along the ramp, rounded up once. Fees never enter reserves.

The native migration witness is an optional launch destination. Allow
`blast_fun_dex::migration::Witness` in launch configuration and select it when
creating the launch. Anyone may execute migration after graduation. The adapter
uses the core migration amounts and preserves configured migration fees; it
locks the issued LP position in a shared vault. Its fees use the existing live
protocol/creator split. No new migration discount is applied.

For an already migrated launch, its CreatorCap owner may instead create and
seed the canonical pool with both assets. Call `pool::create`, then `pool::share`
and transfer the returned position in the same transaction. Each original Meme
has one pool and keeps its launch Quote orientation. Pool creation may opt into
an immutable Meme burn up to 500 bps with a BurnOnly Currency; native migration
starts with burn disabled.

Trades pass an effective fee limit, net minimum receipt and millisecond
Clock deadline. Buys return Meme and any unused Quote; sells return net Quote.
Burn-enabled pools require the corresponding `buy_and_burn` or `sell_and_burn`
function with the actual mutable Currency. The burn is outside the Quote fee
limit. Fee rounding matters: 21 atoms on a 1,001-atom principal exceeds a
200-bps effective limit even when the marginal cap is 200 bps.

Create a position with `new_position`, then call `add_liquidity` with both
maximum asset amounts, minimum shares and a deadline. Consume or return both
refund coins. `deposit_amounts` provides the exact supported deposit and shares
for on-chain composition. `remove_liquidity` returns principal only;
`claim_fees` separately returns accrued Quote. Transfer of a position transfers
both entitlements. `destroy_empty` accepts no remaining shares or whole-atom
fees. Rounding dust and fees allocated to the 1,000 unrepresented initial
shares remain in the pool fee pot.

The separate [auto-LP package](../auto_lp/README.md) permanently holds a creator
cap and position, collects fees, and uses a creator-selected executor to deposit
supported paired balances. It makes no balancing swaps.

Verify locally from the repository root:

```sh
sui move build --path sui/dex --lint --warnings-are-errors
sui move test --path sui/dex --lint
bash sui/dex/scripts/check_source_boundaries.sh
python3 docs/vectors/generate_dex_fees.py
```

These packages are unpublished. Local tests and model review do not constitute
an independent security audit. Deployment, package-upgrade custody and live
object/indexer checks remain release work. SDK, frontend and executor service
integration are not included in this contract change.
