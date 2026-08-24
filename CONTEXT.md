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
launch mints once and consumes the unique treasury capability after permissionless
Coin Registry finalization. Initial supply is nonzero and capped at one billion
whole coins.
_Avoid_: mutable supply, retained mint authority

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
current shared configuration, so an update applies to the next accrual of every
existing and future launch without reallocating fees already accrued.
_Avoid_: fixed fee split, launch fee share
