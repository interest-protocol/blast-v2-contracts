# AutoLP custody

Enroll after the creator's canonical native pool exists. `vault::new` consumes
its `CreatorCap`, creates an empty position in that pool, and fixes a nonzero
executor address; share the returned vault. The creator cap and position remain
discoverable dynamic object children. There is no withdrawal, removal, payout,
or executor replacement path.

Anyone may collect creator fees from the launch, an external migration vault,
or the native migration vault, and collect the AutoLP position's own fees.
External venue harvesting happens upstream before its creator claim; source
version and availability checks still apply. Anyone may contribute either asset.
Quote-only balances wait for Meme rather than triggering a balancing swap.

Only the enrolled executor may compound. It signs maximum Meme and Quote consumption, a minimum share amount and a
millisecond deadline; these bounds must reflect its
accepted reserve ratio. This authorization prevents outsiders from manipulating
the ratio and forcing a deposit. The executor controls timing and execution
price but cannot withdraw custody. Losing that executor makes future deposits
unavailable, so enrollment must choose durable key custody.

Compounding collects own fees, deposits both assets at the current pool ratio,
and retains both refunds. Empty, one-sided, and sub-share deposits keep every
asset in custody. The existing protocol administration may activate the next
compiled operational generation; no pause or additional admin capability exists.

Permanent custody requires immutable deployment. Until then package upgrade
control remains a trust assumption. The dependency on external migrators retains
their live venue publication gates; local compilation does not establish a live
external venue's behavior.
