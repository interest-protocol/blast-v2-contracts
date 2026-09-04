# Blast migration adapters

This aggregate package redeems the launchpad's typed migration handoff into
supported venue positions and custodies the resulting LP principal and fees.
Venue code depends inward on the launchpad; the launchpad never imports this
package.

Use task-specific sources instead of a duplicated route, event, dependency, or
error inventory:

- [accepted migrator ADRs](../../docs/decisions/README.md) for durable design;
- [DEPENDENCIES.md](DEPENDENCIES.md) for venue package identities, pinned ABI
  evidence, and the mainnet inspection matrix;
- `scripts/check_mainnet_abi.mjs` for live compatibility;
- [release gates](../../docs/testing.md) for repository-wide evidence.

Move source and tests own current routes, events, errors, and custody behavior.
`Move.toml` and `Move.lock` own dependency resolution.
