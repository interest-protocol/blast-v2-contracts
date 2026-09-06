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
asset in custody.

This package has no administration at all: no control object, no operational
generation of its own, no pause, and no capability of any domain reaches any
entry point. The only version inputs are the external packages' own — Launchpad
for curve fees, Migrators for external LP fees, and the DEX factory for
enrollment, own-fee collection, and compounding — and each of those packages
checks its own generation.

Permanent custody therefore requires immutable publication, which
`scripts/publish_immutable.sh` performs by consuming the returned `UpgradeCap`
with `package::make_immutable` in the same transaction. Publishing this package
any other way leaves an upgrade path that could add a withdrawal route to
custody it was built to make permanent, so the executed transaction must show
one publish command, that same capability consumed in it, and no surviving
`UpgradeCap` in its effects. The dependency on external migrators retains their
live venue publication gates; local compilation does not establish a live
external venue's behavior.
