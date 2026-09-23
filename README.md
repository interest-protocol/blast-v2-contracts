# Blast V2 contracts

Sui Move contracts for Blast V2. Each directory containing a `Move.toml` is an
independently built package; the `sui/` directory itself is only a workspace.

Start with [AGENTS.md](AGENTS.md) for task routing. Load deeper documentation
only when the task requires it:

- [architecture](docs/architecture.md)
- [product scope](docs/protocol-scope.md)
- [architecture decisions](docs/decisions/README.md)
- [release verification](docs/testing.md)
- [deployment records](deployments/README.md)
- [Sui packages](sui/README.md)

Package source, tests, manifests, and lockfiles are authoritative for current
implementation and dependency details.

## License

First-party Blast V2 contract code is licensed under the
[Business Source License 1.1](LICENSE) (`BUSL-1.1`). Non-production use, including
development and testing, is permitted. Production use requires a separate
commercial license from the licensor; there is no Additional Use Grant.

The Change License is **GPL-2.0-or-later**. It takes effect on **September 23,
2030**, or the fourth anniversary of the first publicly available distribution
of the specific version under BUSL-1.1, whichever comes first. This is a
source-available license with a time-limited production-use restriction, not a
permanent prohibition on all business use.

Third-party dependencies and the venue interfaces under
`sui/migrators/interfaces/` and
`sui/boosts/aftermath_adapter/interfaces/` retain their own licensing terms and
are excluded from this license grant. This change does not revoke rights in
copies previously distributed under MIT or another license.
