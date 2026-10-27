# Sui Move workspace

This directory contains independently deployed or dependency-isolated Move
packages. Build and verify from the directory containing the target
`Move.toml`; use that package's scripts when present.

Core packages do not import venue adapters. Adapters depend inward on the
smallest required core surface. See the repository
[architecture](../docs/architecture.md) and [decision index](../docs/decisions/README.md)
for the durable boundaries.

Launchpad, presale, migrators and launch tickets now live in
[blast-v2-move](https://github.com/interest-protocol/blast-v2-move).
Boosts, liquid staking, standalone coin creation and their shared dependencies
remain here. Legacy composition tests use an immutable historical launchpad
revision, with the original shared package identities. Fetching this private Git
dependency requires repository access.

One-off partner packages live under [`vendors/`](https://github.com/interest-protocol/blast-v2-move/blob/main/sui/vendors/README.md), one
directory per contract.
