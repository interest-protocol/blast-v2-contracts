# Active leverage release-candidate record

Status: **pre-publication source preparation; not release eligible**. No live
venue, deployment, submitted rollback, production capacity or gas result is
claimed. T-001 implements the active contract; T-002 owns terminal shutdown,
unwind, final cash and claims. Existing immutability requirements remain in force.

## Frozen versus live policy

Each exact `Vault<Product>` currency has its own TreasuryCap, retained venue
account authority, binding, buffer and policy. Core State is venue-neutral;
the adapter checks the exact collateral type, account number/object, registry,
clearing house, both oracle storages and both feed origins before venue
mutation. Position direction, target/public band/hard threshold, valuation rules,
fee ceilings, allocation ceiling, lot minimum and NAV cap are frozen at issuance.
Only bounded current order notional and capped future fee settings can change.

The candidate policy values and deliberately unset NAV, seed/reserve and order
bounds live in the [normalized input template](../sui/boosts/aftermath_adapter/release/active-input.template.json).
It is the single candidate-value record; the governing accounting and health
contract is [ADR 0074](decisions/0074-aftermath-vault-activation-and-health.md).
They require exact market depth, lot, fees, margin, smallest exit and bounded-call
gas evidence. Generic 4x/6x tests prove generic arithmetic and type isolation,
not that either tier is a validated launch configuration.

## Accounting and checkpoint contract

`E` is authenticated venue equity, `R` its buffer allocation, `N=E-R`, `S` the
native treasury supply, and `A` separate local native admin collateral. There is
no second NAV, supply or admin-cash ledger. Current index notional uses absolute
base and the fixed canonical price pair, not historical entry quote.

One Blast interval aggregates authenticated signed funding effects, including
socialized debt carried by the same accumulator, before normalization. A net
credit repays any uncovered deficit to `N` before increasing `R`; a net cost consumes `R` before `N`. Zero-net checkpoint
advancement emits `FundingSettled` once. Identical repeats emit nothing.
Unexplained external changes preserve the accepted checkpoint and block priced
paths. `CheckpointDrifted` is not deduplicated: every sync that finds drift
emits it again. A later sync that explains the interval adopts its checkpoint
like any clean sync; there is no separate recovery event. Neither drift nor a
temporary data fault changes lifecycle.

Protocol fee is ceiling-rounded; admin allocation is floor-rounded from that
fee; the remainder credits `R`. Mint shares derive from actual incremental `N`
after the user's isolated venue cost. Redemption proves exact attributable base
reduction and actual kept-holder NAV, withdraws free cash first, checks final
cash/equity/base/margin and burns the held native shares. No unavailable venue
entry-quote/PnL attribution formula is synthesized. Donation raises `E,R` equally;
buffer release changes only `R`; fee withdrawal spends only `A` without prices.

Rebalance uses exact rational outside-band comparisons. At the endpoints no
maintenance is eligible. Direction and bounded whole-lot size derive on chain;
each actual fill updates the next plan. Increase sizing reserves adverse-fill
and taker-cost headroom from the market's ordinary taker fee, range-checked and
rounded up to basis points. Aftermath's priority taker surcharge is not priced
in: `rebalance` and `unwind`, whose fills holders pay, abort above the reference
gas price. `mint` and `redeem` have no gas-price check. Wider
tolerance is available only for reduction strictly above the hard threshold;
equality and every increase use strict tolerance. Costs reduce holder NAV and
no protocol balance pays a bounty or caller gas.

## Keeper and client contract

An observer uses the accepted checkpoint, current authenticated valuation,
native supply and immutable policy. Submit `operations::rebalance` only when
Active, data/checkpoint/margin are valid and `V*10000 < N*lower` or
`V*10000 > N*upper`, at a gas price no higher than the reference gas price. Submit the same public operation from any keeper or unrelated
caller; do not pass a direction, size, bounty or risk witness. The chain repeats
every eligibility and sizing check, so an observer prediction is not authority.
After a competing success, rebuild only from current objects. If submission is
uncertain, resolve that digest before retrying; never use a numerical shadow
checkpoint. Read-only observation requires no database, queue or new service.

The [offline client planner](../sui/boosts/aftermath_adapter/scripts/active_ptb.mjs)
constructs typed active and composition calls with exact native return-value
references. Its adjacent tests and package-local gate are the executable
contract. It never opens RPC, signs or submits. Rendered call plans/CLI arguments
are not BCS TransactionData: resolving live objects and running the generated unsigned
serialization command belong to the authorized rehearsal and remain unrun.

Mint/redeem clients provide a native input coin, minimum output and inclusive
deadline. A client with a Blast partner code calls `mint_with_partner` or
`redeem_with_partner` with its `blast_partners::Partner` instead
([ADR 0095](decisions/0095-partner-codes.md)); a live partnered mint and redeem
that verifies the recipient's transferred coins, and a deny-listed recipient,
remain to be rehearsed before release. Clients do not provide a fee ceiling: administrators set the live mint
and redeem fee rates through `vault::set_fees`, subject to the immutable caps
fixed at issuance. Clients must read and present those current rates when quoting,
but execution enforces only the administrator-configured rate, the minimum output
and the deadline. Consume returned `Coin<BlastBoost<Product>>` directly as
the launchpad Quote, or consume launchpad's returned Quote directly in redeem.
Exact Quote admission remains launchpad administration; neither module gains
the other's custody authority. The consumer-only composition package compiles
both chains and locally exercises native launchpad custody. Runtime venue fills
are observed on mainnet under the authorized evidence stage below; downstream
rollback rests on Sui transaction atomicity.

## Evidence and release rehearsal

Package verification scripts define the local gates; the implementation handoff
records their exact invocation and outcomes. Official pinned Aftermath ports
abort 404 locally. The pinned dev-inspect surface fixture is a read-only
mainnet capture, not transaction evidence. Blast deploys to mainnet only
(ADR 0103), so there is no testnet rehearsal. The implementation handoff records
exact commands, source revision, logs and limitations.

An authorized combined T-001/T-002 verifier must populate every null input field
and bind it to one stable revision and the exact dependency locks. Required
records include network/chain/toolchain, immutable core and adapter package
digests/IDs, risk-module source and immutable publication, all capability/treasury/
metadata/vault/account/market/oracle IDs, role addresses without secrets,
validated policy/depth/lot/fee/gas evidence and every submitted digest.

Every Aftermath function the adapter calls was read from mainnet bytecode on
2026-09-20 ([record](research/aftermath-venue-bytecode-2026-09-20.md)). Three
findings are applied (funding settlement replayed from the venue's own
arithmetic, quote notional under the base's sign, market collateral scale
checked at initialization). The fourth, that Aftermath's feeds are Pyth Lazer with no on-chain
`PriceInfoObject`, replaced the Pyth cross-check with venue-feed identity
(bound feed origins, the venue's own price functions; ADR 0074 oracle
amendment).

Observe SC-001 through SC-013 on mainnet under the authorized evidence stage
(ADR 0074, A-003): both-direction activation and active flows; funding
sign/net-order/replay cases; bad bindings, prices and ACL; competing keepers,
partial fills and bounded costs; donations, fee changes/withdrawal and full
buffer release; native Quote composition; then T-002 emergency, multi-call
unwind and final claims. Activation rollback rests on Sui transaction atomicity;
the testnet failpoint rehearsal was removed (ADR 0074 mainnet-only amendment).
Do not call the evidence stage complete while any required outcome is
unresolved. AC-023/024/025 market/live/publication evidence remains unrun here.

## Terminal handoff facts (T-002)

Activation stores the immutable `locked_shares` amount on the Vault, emits it in
`VaultInitialized`, and transfers exactly those native shares to `@0x0`. No seed
funder is recorded. Neither later mint nor settings can replace the amount.
Native TreasuryCap supply includes locked shares. Terminal eligible-supply
arithmetic must use that exact amount, not current supply or a recomputed seed
estimate. With zero eligible supply, finalization keeps the recovered cash as
`A`. Local `A` is separate from venue cash and may be withdrawn without an
oracle in terminal states. The accepted checkpoint is the only stored
checkpoint; drift is reported by event, never stored.
This document adds no terminal operation or automatic-retirement path.
