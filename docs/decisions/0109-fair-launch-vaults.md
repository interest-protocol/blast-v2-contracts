# 0109: Fair-launch vaults

- Status: proposed
- Date: 2026-10-06
- Amends: [0101](0101-presale-protocol-fees.md), whose vaults existed only after a
  presale migration

## Context

A team that launches without a presale adds its liquidity to Cetus or Bluefin
itself. It still wants what a migrated presale gets after migration: its
liquidity locked for good, its LP fees split among its own recipients and
holder-reward rounds, and Blast taking its LP-fee share.

## Decision

`blast_presale::cetus::create_fair_launch_vault` and
`blast_presale::bluefin::create_fair_launch_vault` take the team's own position,
the pool holding it, and a `FeeSplit`, and share an ordinary `PresaleVault`.
Cetus burns the position for its LP-burn proof first; Bluefin seals the position
itself. Either way no path removes it.

- **No presale.** The vault's `presale_id` and `presale_cap_id` are the zero ID.
  No `PresaleCap` can have that ID, so `claim_migration_residuals` is
  unreachable, and there are no residuals: the team keeps whatever its own
  liquidity transaction did not take. `PresaleVaultCreated` carries the zero
  `presale_id`, which is how indexers tell a fair launch apart.
- **Real pool.** `pool_id` is the pool the position belongs to, checked against
  the passed pool, so `collect_fees` works unchanged. The pool's type proves the
  vault's `Meme` and `Quote`: Cetus accepts either coin order; Bluefin requires
  `Pool<Meme, Quote>`, the order its `collect_fees` takes.
- **Blast's terms.** The vault snapshots the `FeePolicy`'s current LP-fee rates,
  which the `AdminCap` may change per vault as for any vault. The
  `CreationPolicy` must allow `Quote` and the venue's migrator witness, the same
  check a presale passes, so Blast's Quote allowlist and venue switches cover
  fair launches too. No partner: `partner_id` is none.
- **Permissionless.** Anyone may lock their own position. Holder-reward rounds
  still need the `AdminCap`, so Blast decides which vaults get rounds.

## Consequences

One vault type, one collection path, and one rewards path serve both products;
the SDK's vault layout is unchanged. The zero IDs are a sentinel, chosen over an
`Option` field so the published layout and every reader stay as they are.
