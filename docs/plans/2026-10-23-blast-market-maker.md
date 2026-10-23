# Blast Market Maker across bonding launches and presales

This implementation plan targets a new side package on the public extension
points at baseline `01d7659617abcd552cece6d05b9db409ec4ff2c0`. Existing Launchpad,
Migrators, Presale, Admin and Partners sources remain unchanged. The latest
accepted requirements integrate the package into Blast ACL and replace mandatory
80/20 distribution with creator-directed received-fee allocation. This supersedes
the earlier standalone-governance recipe. Source/tests own executable interfaces;
verification and review artifacts record evidence separately from this plan.

## 1. Establish the package and authority boundary

Build a package with one shared generic Meme/Quote vault and two adapters. Curve
Quote is SUI; presale Quote is its exact admitted asset. Share capital custody,
fee arithmetic, backer claims, risk authorization, treasury routing and Cetus
execution. Adapter-owned sealed dynamic fields hold route-specific terms, core
capabilities and migration configuration. Only the defining adapter can construct
its migration witness. Constructors complete initialization and share internally;
no raw initializer or owned vault escapes.

Use existing Blast ACL with package-defined FeeAdmin, TreasuryAdmin and
UpgradeAdmin role markers and typed witnesses. Do not add another root or
address-role registry. Keep canonical package-owned fee policy, typed treasury and
native upgrade custody; ACL authority does not make a foreign object canonical.
Treasury withdrawals pay only its configured destination from earned balances.
Fee policy starts at zero and is capped by both the compiled ceiling and each
vault's creation-time ceiling.

Give creators a transferable cap independent of coin types. Each vault binds its
cap ID, so one cap may manage several vaults. Use this authority for fee allocation,
idle-capital withdrawals, pause and operator/signer changes. Permit rebinding one vault to another existing
cap without moving all the others. Native transfer changes control of all bound
vaults. Existing operators and signatures survive transfer/rebinding until explicit
operator/signer rotation; disclose that fact. Keep delegated per-vault trading
caps and independent risk signatures separate from creator and ACL authority.

## 2. Construct and activate the curve route

Require a genuine LaunchTicket, Currency, immutable target/deadline/initial-buy
terms, risk limits, creator cap and selected upstream Partner. Commit the Partner
object ID before funding and require the same object at activation. Bound the
fundraising deadline to seven days and enforce exact-fill funding, returned change,
10,000-backers capacity and a target-derived new-address minimum. Cap recipients,
initial signer and terms must be inspectable before contributions.

Activation requires exact fill before the exclusive deadline. The adapter reserves
Cetus pool creation, calls the real core constructor, configures its own migration
witness and selected Partner, finalizes, performs the committed initial purchase,
and shares the core object in one atomic transaction. Creation fees come from a
separate caller-supplied coin. Charge the committed 5% local raise fee into its own
balance and event; the remaining funding and all purchase outputs stay in capital.
An initial buy may graduate immediately. Invalid admission/configuration/venue
conditions abort atomically; at the deadline an unsuccessful launch allows full
principal refunds and return of the unused ticket to its original supplier.

Ticket creator/burn settings have no usable public getters. Name stored hints as
unverified, preflight the exact real finalize/buy PTB, and do not invent on-chain
promises from them. The real core creator must later claim and voluntarily escrow
its authentic live CurveFeeCap. Support narrowly typed Receiving for a cap sent to
the vault address. Upstream CreatorAdmin may replace it; curve fee income remains
contingent. Core creator/metadata powers remain governed upstream.

## 3. Construct and settle the presale route

Require the exact upstream versions/policies, admitted Quote and sealed witness,
selected Partner, creator cap, zero-supply TreasuryCap and unregulated Currency.
Mint the pool-creation reservation before core construction consumes TreasuryCap;
it must not mint supply. Use hard-cap mode with early close, open eligibility and
bounded participants. Core finalization validates token and protocol allocations.
LP-fee metadata must not be mistaken for custody routing under an external witness.
Commit optional team token and team raise shares to the vault address through core
recipient allocations. They must satisfy upstream allocation and rounding rules;
zero disables each. Successful migration releases them as vault-owned coins.
After atomic pool activation, narrow typed Receiving joins those coins into capital.
Native Receiving verifies the vault owner, not the sending transaction; same-asset
donations are therefore capital too, without fee weight or redemption rights.
Cancelled sales retain allocations in core and cannot receive team coins.

Wrapper commitments call core and record only accepted Quote; change is returned.
Core holds participant principal and owns token claims, refunds and cancellation.
Direct core buyers keep those rights without receiving wrapper fee weight. Freeze
wrapper weights on successful migration, including the zero-wrapper-buyers case.
Commit retention of at most half of each actual net Meme/Quote migration handoff,
after upstream allocations. Participant token entitlements stay unchanged. Require
a zero idle Quote floor because future net handoff is unknown. There is no extra
local presale raise fee. Test both non-SUI Quote decimals and direct-only sales.

Both routes use existing permissionless upstream partner settlement. Curve partner
payout covers eligible creation/trading/migration protocol fees; presale partner
payout follows migration and the core's actual raise-fee allocation. The selected
Partner identity is fixed, while upstream share/recipient settings remain mutable.
These upstream fees do not enter creator allocation or backer claims.

## 4. Migrate and manage liquidity

Consume only the authentic core handoff through the adapter's sealed witness.
Create a positive full-range base LP and permanently burn it through Cetus LP Burn;
escrow the resulting fee proof under a sealed child key. No function releases it
or withdraws/adds principal from the graduated base. Preserve pool identity and
reservation/tick-spacing binding without introducing a mutable fee-tier veto over
already funded migration.

Retain other inventory, including actual unused pool-seeding coins, as capital
and allow up to eight ordinary managed ranges. Seed residuals create no fee rights
and must not be credited as protocol revenue.
Opening funds a new position atomically. Support independent adds, partial/full
removals and fully settled empty-position close, with slot reuse. Every removal
returns actual principal to vault capital. Settle actual fees before changing
principal, and quarantine unknown typed rewards without an external withdrawal.

Permit anyone to deposit capital after launch without acquiring weight. Permit the
bound creator cap to withdraw idle Meme/Quote as composable coins and transfer them
to users or another destination in the same PTB. No new distribution ledger is
needed for direct transfers. This creator authority can exhaust idle capital and
is outside delegated risk/idle-floor limits; it cannot spend prelaunch funding,
unallocated fees, allocated user reserves, treasury buckets or positions. Removing
managed liquidity first returns it to idle capital; the burned base remains locked.
Capital deposits/withdrawals emit per-asset deltas, independently from fee accounting.

Each discretionary delegated action needs a live delegated operator and Ed25519 signature
binding exact action parameters, assets, vault/external/pool/operator identities,
nonce, signer epoch and at most 15 seconds of validity. Keep immutable per-action,
rolling token-bucket, lifetime turnover, self-fee conversion and action-count
limits. Fee reinvestment does not reset those budgets. A signed full-position
unwind remains permissionless when paused or discretionary budgets are exhausted;
output remains capital and the nonce advances. Pause preserves fee collection,
claims, refunds and migration.

## 5. Account for fees and creator choices

For each asset, maintain three independent balances: trading capital, unallocated
received fees and reserved backer fees. Curve creator-fee receipts and LP receipts
after configured local LP deductions enter the unallocated balance. Do not classify
swap outputs, LP principal, migration handoffs or donations as fee revenue.

Expose public per-vault available/reserved and per-backer claimable views. The
creator supplies explicit atom amounts to keep, share and reinvest independently
for Meme and Quote. Validate the sum, available funds, current generation and bound
creator cap. Keep returns two composable coins. Share transfers only actual fees
into irrevocable reserves and advances independent Q64 accumulators. Reinvest moves
only unallocated fees into capital. Leave unselected amounts available. Sharing
requires frozen weights and positive total weight; with no backers the creator can
choose keep or reinvest, without an implicit fallback.

Backers claim both assets using their frozen weight, independent per-asset paid
indices and fractional remainders. Preserve global division dust and each personal
remainder across repeated receipts/claims. There is no creator/treasury/dust sweep
of reserves, no NAV or principal redemption and no guaranteed backer percentage
before allocation. Transferring or rebinding creator authority cannot reduce
already-funded claims. Events distinguish actual fee receipts, allocations,
claims, treasury credits and capital actions for independent reconciliation.

Keep local LP deductions and curve raise fees as distinct protocol treasury
sources. Unused migration seed coins belong to vault capital. Creator allocation replaces the old 20% platform cut;
it does not remove upstream fees or the configured local LP/curve raise fees.
Trading can lose capital, and fees generated by the vault's own trades can be
allocated to its creator within the immutable conversion/turnover bounds. Avoid
promising profits or protection against governance replacing reviewed bytecode.

## 6. Seal native custody and upgrade safely

Publication creates a unique bootstrap. Wrap the matching original Publisher and
UpgradeCap before any usable generation. Bind canonical custody, policy and
treasury IDs in the generation object. Typed Blast UpgradeAdmin authorization
must also pass canonical-object and current-bytecode checks.

Authorize/commit native compatible upgrades through old active bytecode without
advancing operational generation. Newly installed bytecode activates only its
checked-next compiled generation after a fresh native commit. A wrong-generation
build leaves old bytecode usable for a repair upgrade. After cutover all economic
and governance paths, including refunds/claims, require current generation; do not
leave old exit mutations open. A current dependency version object alone cannot
repair a stale bytecode dependency link. Use a reviewed compatible relink and
preserve dependency type origins. Direct core presale claims/refunds retain their
independent upstream liveness while wrapper integrations need relinking.

## 7. Verification and release evidence

Run affected-package build/tests with warnings-as-errors and lint under the shared
host memory guard, then style, frozen-source boundary and generated-reference
checks. Exercise these material boundaries:

| Boundary | Required cases |
| --- | --- |
| Creator authority | One cap across multiple vaults; foreign cap rejection; native transfer; single-vault rebind; old cap rejection after rebind; explicit operator/signer rotation; creator has no ACL privileges |
| Fee solvency | Both assets, partial mixed allocation, unallocated remainder, interleaved claims, last atom, global/personal dust, zero-weight rejection, pre-freeze rejection, repeated claim, overflow, fee/principal classification and reserve extraction rejection |
| Capital | Active deposits without weight, creator-only withdrawals, both assets, user transfers while paused, delegated floor separation, funding/cancel/version/foreign-cap rejection, fee reserve isolation and event replay |
| Blast ACL | Real grants/sign-in, revoked admin, wrong role, distinct package role types, canonical custody/policy/treasury checks, witnesses cannot bypass version gates |
| Curve | Minimum/tail/change, target/deadline boundaries, full refunds, real initial construction/buy/creator-fee cap, partner mismatch/admission/settlement |
| Presale | Real construction and accepted change, wrapper/direct buyer mix, cancellation/refunds, frozen/zero weights, actual net retention, explicit team allocations and vault-owned receipt, zero allocations, foreign-sale/owner/version rejection, non-SUI Quote, partner settlement |
| Liquidity/risk | Multiple ranges, slot reuse, burned-base separation, actual add/remove/unwind/close/swap, fee/principal separation, rewards, exact signature domains/replay/expiry, all risk budgets |
| Upgrades | Bootstrap/native custody, compatible receipt flow, generation mismatch repair, cutover, stale bytecode, dependency relink and core-generation change |

Local Cetus stubs prove interface linkage only. Actual pinned-venue PTBs, rollback,
shared-parent Receiving, native object discovery, 10,000-backer/eight-position gas,
distinct-bytecode publication/upgrades and complete event/signature matrices remain
release evidence gates until executed. Keep review artifacts immutable and bind
new verification to source hashes. No deployment or production ACL mutation is
implied by local implementation work.

## Research and review provenance

Use the requested [Sui Move engineering suite at
`a6c14e46e6cb33dcaf8d765499c268002cb559d5`](https://github.com/josemvcerqueira/sui-move-engineering-skills/tree/a6c14e46e6cb33dcaf8d765499c268002cb559d5):
architecture, security, source style, testing and review, including custody,
events, DeFi, signatures, PTBs and upgrades. Repository decisions take precedence.
Astra reviews the implementation because the user replaced the unavailable Fable
reviewer. A review score cannot substitute for missing native execution evidence.

Mosh's [introduction](https://mosh.trade/docs), [custody](https://mosh.trade/docs/custody)
and [fees](https://mosh.trade/docs/fees) motivated the original investigation. This
is a Sui-specific design; Blast's actual public contracts and accepted creator-fee
requirements control its behavior. [ADR 0118](../decisions/0118-blast-market-maker-vaults.md)
records the durable boundary. The integration guide and generated references own
current caller choreography.
