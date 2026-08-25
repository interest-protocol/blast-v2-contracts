# Blast V2 Protocol

This context defines the protocol language for launching an asset and assigning
the authority associated with its creator proceeds.

## Language

**CreatorCap<Meme>**:
The capability parameterized by a launch's unique meme coin type that controls
creator proceeds and the explicitly approved creator operations for that coin,
including after migration. It does not contain or proxy the native Coin Registry
metadata capability.
_Avoid_: fee claimer cap, owner key

**MetadataCap<Meme>**:
The unique native Coin Registry capability held by Blast until the one-time
creator claim, then returned as a separate object alongside `CreatorCap<Meme>`.
Its holder uses the Coin Registry's native metadata functions directly. It does
not pass through the creator-authority claim helper.
_Avoid_: creator metadata wrapper, metadata slot, capability pass-through

**Generated coin supply mode**:
The coin owner chooses `Fixed` (neither mintable nor burnable) or `BurnOnly`
(burnable but never mintable). The generated package records the selection;
the OTW initializer mints exactly one billion whole coins and immediately
consumes the unique treasury capability into that final state. Generated Meme
precision is always nine decimals, so the stored supply is exactly
`1_000_000_000__000_000_000` atomic units.
_Avoid_: mutable supply, retained mint authority

**LaunchTicket<Meme>**:
The transferable object created from the generated coin package's one-time
witness. It holds the complete fixed `Balance<Meme>`, native
`MetadataCap<Meme>`, and unissued `CreatorAuthority<Meme>` after mint authority
has been irreversibly consumed. Supply mode lives authoritatively in the Coin
Registry rather than being duplicated in ticket storage.
_Avoid_: coin receipt, mint ticket, capability bundle

**Creator identity**:
The launch-time rule that identifies who may claim an unissued
`CreatorCap<Meme>`: either a concrete address or an immutable X account
commitment.
_Avoid_: creator owner, social owner

**CreatorCap claim**:
The one-time issuance of an unissued `CreatorCap<Meme>` to a wallet that
satisfies the launch's creator identity.
_Avoid_: creator assignment, cap mint

**Address creator claim**:
A `CreatorCap` claim authorized by equality between the stored creator address
and the claiming transaction's sender. The address may have been entered
directly or resolved from SuiNS when the launch was created.
_Avoid_: direct creator assignment, SuiNS claim

**X creator claim**:
The one-time claim of an unissued `CreatorCap` after Blast's backend verifies
the authenticated X account and attests the claimant's wallet address.
_Avoid_: protected launch, private launch, generic social claim

**X claim attestation**:
A short-lived backend signature binding one X identity commitment and one meme
coin type to the wallet address that will receive the `CreatorCap`.
_Avoid_: frontend signature, claimant signature

**SuiNS creator resolution**:
Resolution of a SuiNS name to a concrete creator address by a dependency-bearing
periphery before core launch state is created. Later name changes do not change
the creator identity.
_Avoid_: SuiNS claim, dynamic creator name

**Curve quote**:
A pure numeric buy or sell result derived from launch reserves and configured
economic parameters. It moves no assets and mutates no launch state; the launch
operation validates lifecycle and slippage before applying it.
_Avoid_: trade, swap, curve execution

**Quote whitelist**:
The bounded set of quote coin types that protocol administrators currently
allow for new launches. Each original quote type maps directly to one migration
quote target. The whitelist itself is the admission decision; launch lookup does
not require a `Currency<Quote>` registry object.
_Avoid_: permissionless quote, quote registry proof

**Migration quote target**:
The nonzero amount of real quote reserve, in that quote's atomic units, that a
new launch snapshots from the quote whitelist. Reaching it closes bonding;
later whitelist updates do not move an existing launch's target.
_Avoid_: live global threshold, quote percentage

**Launch config**:
The cold shared policy object read only when a launch is created. It combines
quote admission and targets with bounded graduation defaults and a bounded
whitelist of external migration witness types because those values are checked
in the same transaction. Each launch stores one selected witness type. Existing
launches never read the config again.
_Avoid_: global protocol config, live launch config, quote config

**Quote migration fee**:
The snapshotted percentage of gross terminal Quote reserved as Blast protocol
revenue only after successful migration. It is SUI only when Quote is SUI and is
capped at 500 basis points.
_Avoid_: SUI migration fee, DEX creation cost, trade fee

**Meme graduation allocation**:
The snapshotted percentage of initial Meme supply reserved before curve
inventory is created and made protocol-claimable only after successful
migration. It is capped at 1,000 basis points and never enters the curve, pending
burn, trade-fee ledger, or venue liquidity.
_Avoid_: migration meme fee, creator allocation, curve reserve

**Meme liquidity provision**:
The nonzero snapshotted percentage of initial Meme supply reserved before curve
inventory for destination-pool principal. It is capped at 9,999 basis points,
must leave a positive rate for curve inventory after protocol Meme allocation,
and never becomes protocol or creator revenue. Zero means the launch policy is
not configured; it never means migrate all terminal curve inventory.
_Avoid_: Meme migration fee, platform allocation, terminal curve remainder

**Migration witness whitelist**:
The bounded set of sealed witness types owned by supported external migrator
packages. A new launch must select one allowed original `TypeName`; the future
core handoff will accept only a value of that selected type. Removing a witness
blocks future selection without rewriting existing launches.
_Avoid_: migrator address whitelist, DEX dependency in core, live migration revocation

**DEX pool-opening cost**:
Unsupported. Blast will integrate only venues whose pool can be opened without
a protocol-level creation payment. Transaction gas is not launch accounting.
_Avoid_: venue cost policy, fee coin, third asset, reimbursement path

**Launch quote**:
A public, read-only buy or sell calculation derived from one actual launch's
live reserves and fixed parameters. Frontends use this boundary; they do not
supply raw reserve or fee inputs to the package-only curve arithmetic.
_Avoid_: configurable frontend quote, raw curve quote

**Launch fee rates**:
The fixed `quote_fee_bps` and `meme_fee_bps` selected independently by the
launcher, each capped at 1,000 basis points (10%). A zero rate disables fees in
that asset; the two rates represent no fees, quote-only, meme-only, or both
without a separate mode.
_Avoid_: fee mode, global trade fee

**Fee ledger**:
The four-balance accounting value embedded in a launch: creator and protocol
balances for both the meme and quote assets. Every accrued fee uses the current
global protocol share, with an indivisible remainder assigned to the protocol.
_Avoid_: fee vault, fee recipient registry

**Protocol fee share**:
The globally configured protocol percentage of every meme-asset and quote-asset
trade fee, expressed in basis points from 0 through 10,000. Every trade reads the
current shared runtime configuration, so an update applies to the next accrual
of every existing and future launch without reallocating fees already accrued.
_Avoid_: fixed fee split, launch fee share

**Creator fee share**:
The implied complement of the protocol fee share: `10,000 - protocol_fee_share_bps`.
It is never independently configured or stored; the creator receives the exact
fee remainder after the protocol amount is rounded.
_Avoid_: creator fee rate, creator split config, launch creator share

**Runtime config**:
The small shared live-settings object containing the dedicated X-claim signer
key and global protocol fee share. Both values apply immediately to the next
operation in their own domain. It contains no ACL membership, creator identity,
cold launch policy, balances, generic signer registry, or arbitrary settings map.
_Avoid_: global protocol state, generic settings registry, signer registry

**Pending burn**:
Meme balance separated from sell input by the burn curve and held in the launch
until migration. It is excluded from curve reserves, fees, claims, and migration
liquidity, but remains in total supply until a burnable launch destroys the
complete balance through the Coin Registry at migration.
_Avoid_: burned-on-sell, zero-address burn, fee balance
