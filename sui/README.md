# Sui Move workspace

This directory contains independently deployed or dependency-isolated Move
packages. Build and verify from the directory containing the target
`Move.toml`; use that package's scripts when present.

Core packages do not import venue adapters. Adapters depend inward on the
smallest required core surface. See the repository
[architecture](../docs/architecture.md) and [decision index](../docs/decisions/README.md)
for the durable boundaries.
