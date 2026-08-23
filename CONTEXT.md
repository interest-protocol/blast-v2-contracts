# Blast V2 Protocol

This context defines the protocol language for launching an asset and assigning
the authority associated with its creator proceeds.

## Language

**CreatorCap<Meme>**:
The capability parameterized by a launch's unique meme coin type that controls
creator proceeds and the explicitly approved creator operations for that coin,
including after migration.
_Avoid_: fee claimer cap, owner key

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
