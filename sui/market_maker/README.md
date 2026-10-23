# Blast Market Maker

Blast Market Maker manages trading inventory and liquidity across launches. It shares
vault custody, ACL governance, fee accounting and Cetus
strategy operations across bonding-curve and presale launch adapters. Existing
Launchpad, Migrators and Presale packages remain unchanged.

Each creator selects a required Blast partner code when creating a market maker. The
choice is fixed for that market maker; upstream core admission and partner-fee settlement
apply to both routes. Partner payouts divide eligible Blast fees and remain
separate from this protocol's capital and funded fee accounting.

Start with the [integration guide](../../docs/llms/market-maker.md). The
[architecture decision](../../docs/decisions/0118-blast-market-maker-vaults.md)
records the authority and custody boundaries; the
[implementation plan](../../docs/plans/2026-10-23-blast-market-maker.md) records the design
and remaining release evidence. Source, tests and generated references own the
executable interface.

Run the package-owned [verification script](scripts/verify.sh) for the guarded
build, tests, style, frozen-source boundaries and generated-reference checks.
Local external-venue stubs establish linkage, not successful Cetus execution.
Actual venue transactions, shared-parent Receiving, native publication/upgrade
and dependency-relink evidence remain release gates. Nothing here authorizes
publication or changes production ACL grants.

Protocol administration uses Blast ACL with package-defined roles. Creators use a
reusable cap that may control several vaults. Received Meme and Quote fees remain
unallocated until the creator chooses amounts to keep, share with backers or
reinvest; allocated backer reserves cannot be reclaimed. Native transfer of the
creator cap moves control of all bound vaults and does not revoke existing trading
delegates. Rebinding can move one vault to another existing cap.

Publication and native Publisher/UpgradeCap wrapping require reviewed deployment
choreography. Operational generation activates only after custody is sealed;
compatible upgrade authority belongs under Blast governance custody.

Additional Cetus remove/close/reward declarations were checked against the official
interface at immutable revision
[5ef409e5aa97cf0c545c5ff64560cb65eaa981e7](https://github.com/CetusProtocol/cetus-clmm-interface/tree/5ef409e5aa97cf0c545c5ff64560cb65eaa981e7/sui/cetus_clmm/sources)
and normalized mainnet revision15 bytecode. Before release, confirm exact deployed
package/type origins, normalized signatures, module fingerprints and revision drift.

Before public fundraising, record runtime evidence for both admitted routes, base
pool creation/burn, separate managed LP add/remove/unwind/close, both swap
directions, actual fees and reward quarantine, pool reservation/pre-creation,
shared-parent Receiving, object-child lookup, maximum-cardinality/gas, signature
replay/domain boundaries, and native upgrade/cutover/dependency relink. Verify that
participant claims/refunds and independent fee claims survive tested pause/version
cases. Signed prices rely on a trusted risk signer without independent on-chain
oracle checks; capital management has no guarantee of profit.
