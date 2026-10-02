# 0103: Shared immutable Merkle proof package

- Status: proposed
- Date: 2026-10-02
- Amends: [0099](0099-standalone-overflow-presale.md), whose presale carried its own `merkle_tree`
  module

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

The proof check lives in `blast_fun_merkle` in
[blast-util-contracts](https://github.com/interest-protocol/blast-util-contracts) (`sui/merkle`),
published immutable like the OTC, vesting, and timelock packages. It is presale's former
`merkle_tree`: `node`, `verify`, and `digest_length`, with no dependency beyond the Sui framework.

Both packages pin it by full commit SHA and call `blast_fun_merkle::verify` and
`blast_fun_merkle::digest_length`. Each keeps its leaf encoding private beside the state that
commits to it: presale's in `blast_presale` (allowlists) and `holder_rewards`, and migrators' in
`blast_holder_rewards`, which absorbs the former `merkle::leaf`. Migrators' `merkle` module and
`constants::digest_length` are removed.

Concentrated-liquidity seed-price math stays in each package's `migration_math`.

## Alternatives considered

- **Presale depends on migrators.** Rejected for the reasons above, and because the shared helpers
  are package-visible and would have to become public.
- **A shared package inside this repository.** Rejected: an immutable dependency-free primitive
  belongs with the other immutable utility packages, and it never needs relinking.

## Consequences

- `blast_fun_merkle` must be published, with its `Published.toml` committed, before presale or
  migrators is published on mainnet.
- Migrators' holder-reward claims now also reject malformed digests and out-of-tree indexes inside
  the proof check; the claim's own index guard still runs first, so its abort is unchanged.
- Leaf and node hashes, and therefore every published root and SDK vector, are unchanged.

## Verification

- `blast_fun_merkle` tests cover single-leaf, positional, odd-node, malformed-input, and
  wrong-depth proofs at 100% coverage.
- Migrators' `reward_leaf_tests` keep the SDK three-holder vector and leaf-field binding against the
  shared check; its source gate pins the private leaf encoding and the claim's call order.
