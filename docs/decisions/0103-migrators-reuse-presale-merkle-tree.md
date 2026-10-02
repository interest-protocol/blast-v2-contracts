# 0103: Migrators reuse the presale's Merkle proof check

- Status: proposed
- Date: 2026-10-02
- Relates to: [0099](0099-standalone-overflow-presale.md), whose presale owns `merkle_tree`

## Context

`blast_presale` and `blast_fun_migrators` each carried a copy of the same positional Blake2b-256
Merkle proof check: `merkle_tree` in presale (allowlists and holder-reward rounds) and `merkle` in
migrators (holder-reward rounds). The copies had drifted. Presale's rejected malformed roots and
digests, an empty tree, and an out-of-tree index itself; migrators' relied on every caller to bound
them. Each package also hashes its own leaves, and those encodings differ by domain.

Presale cannot depend on migrators for this. Migrators imports the launchpad and upgrades under a
compatible policy, so presale would inherit the launchpad and its proof check could change after
publication, which ADR 0099's dependency-only custody rules out.

## Decision

Presale's `merkle_tree` is the one copy. Its `node` and `verify` are already public, and ADR 0099's
dependency-only custody means presale logic never changes, so another package may rely on them.

Migrators depends on `../presale` and calls `merkle_tree::verify` for holder-reward claims. Its
`merkle` module is removed, and its leaf encoding moves, private, into `blast_holder_rewards` beside
the round state that commits to it, as presale's `holder_rewards` does. Migrators keeps
`constants::digest_length!()` for its own commitment check, because presale's `digest_length` is
package-visible.

The presale package resolves onto the venue and framework revisions migrators already pins, so the
dependency adds no external package.

## Alternatives considered

- **Presale depends on migrators.** Rejected for the reasons above, and because migrators' helpers
  are package-visible and would have to become public.
- **A separate immutable Merkle package** (in blast-util-contracts or this repository). Rejected: it
  adds a package that must be published before the presale launch, for one small primitive the
  presale already exposes.

## Consequences

- Presale must be published before migrators, which is the planned launch order.
- Migrators' holder-reward claims now also reject malformed digests and out-of-tree indexes inside
  the proof check; the claim's own index guard still runs first, so its abort is unchanged.
- Leaf and node hashes, and therefore every published root and SDK vector, are unchanged.

## Verification

- Migrators' `reward_leaf_tests` keep the SDK three-holder vector and leaf-field binding against
  presale's check; its source gate pins the private leaf encoding and the claim's call order.
- `check_mainnet_abi.mjs` pins the presale lock node and its edges.
