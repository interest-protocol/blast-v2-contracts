# 0080: Provider-independent creator recipients

- Status: accepted
- Date: 2026-09-13
- Amends: [0013](0013-creator-fee-authority-and-x-claims.md),
  [0015](0015-protocol-authority-and-x-signer-state.md),
  [0017](0017-coin-type-domain-for-x-creator-claims.md),
  [0024](0024-generated-coin-launch-ticket.md),
  [0028](0028-hot-cold-runtime-configuration.md),
  [0029](0029-composable-creator-identity.md),
  [0030](0030-singleton-event-identity.md),
  [0038](0038-standard-method-names.md),
  [0051](0051-generated-meme-package-template.md),
  [0059](0059-production-launchpad-abi-and-sdk-parity.md), and
  [0079](0079-compact-launch-state-and-events.md)

## Context

The launcher and the intended creator can be different people. The intended
creator may also authenticate through Google, Facebook, Discord, X, or a later
login method. Binding creator authority to one provider-specific username,
email, or subject would make mutable login details part of the protocol and
would require contract changes whenever authentication options change.

## Decision

Core records a `CreatorRecipient`, independently of the launcher:

- `Address` stores a nonzero wallet address and needs no backend attestation.
- `Account` stores a 32-byte opaque commitment to an immutable Blast account.

External login methods belong to that Blast account off chain. The backend
authenticates a provider's immutable subject, resolves it through a securely
linked Blast account, checks the stored commitment, and signs one
`CreatorClaimMessage` containing the original Meme type, account commitment,
claimant wallet, and expiry. The contract does not receive a provider id,
email, username, display name, or provider token.

If the recipient has never used Blast, the backend may create an unclaimed
account before launch and bind it to a provider's immutable subject. For
example, an X handle must first be resolved to X's stable user ID; the handle
itself remains display metadata because it can be renamed or transferred. The
first matching login activates the account and may request the claim. If a
stable provider subject cannot be resolved safely, the launch must use a
recipient-controlled invitation secret or wait for authentication rather than
assigning authority to mutable profile text.

The transaction sender is the launcher when the ticket is created and the
claimant when authority is claimed. Either may differ from the designated
creator recipient. A successful claim consumes `CreatorAuthority<Meme>`, so
the existing linear resource remains the replay guard.

Account linking and recovery are part of the backend authority boundary.
Providers must never be linked only because their email strings match. A
commitment is an authorization identifier, not a confidentiality guarantee;
the backend must use an opaque account identifier rather than hashing public
or low-entropy profile data directly.

## Consequences

- User A can launch a coin whose creator authority only User B can claim.
- User B can claim through any securely linked login method without changing
  on-chain state or the Move ABI.
- Adding another authentication provider is an off-chain change.
- The one generic creator-claim signer replaces the X-specific signer, events,
  errors, and SDK vocabulary before first publication.
- A compromised signer can authorize any unclaimed account-recipient claim in
  that deployment; keys remain deployment-specific, short-lived attestations
  remain mandatory, and address-recipient claims remain backend-independent.
- No administrative reassignment or sweep path is added. An invalid or
  permanently inaccessible recipient leaves creator authority unclaimable.

## Verification

- Address and account recipients are constructed through distinct validated
  paths, and launch events reconstruct the selected recipient.
- Signatures remain bound to Meme type, account commitment, claimant, expiry,
  and the currently active deployment key.
- Tests reject malformed commitments and attestations, wrong accounts,
  claimants and Meme types, expired signatures, signer rotation, and signer
  revocation.
- The generated Meme template and SDK expose address/account selection only;
  no provider-specific constructor remains.
