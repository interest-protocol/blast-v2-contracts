# Blast V2 contracts

Source, tests, manifests, and lockfiles own executable facts. Documentation
records decisions and task-specific operations; it must not mirror module,
error, command, version, dependency, or implementation-status inventories.

Add or amend an ADR only when a change settles a durable protocol, authority,
storage, ABI, upgrade, dependency, deployment, or cross-package decision.

Load only the branch the task changes:

- Package or contract/SDK boundary: `docs/architecture.md`.
- Product inclusion or deferral: `docs/protocol-scope.md`.
- Numerical compatibility or release evidence: `docs/testing.md` and
  `docs/vectors/`.
- Leverage contracts: `docs/leverage-implementation-lessons.md` and the
  applicable accepted ADR.
- Venue dependency or live ABI: `sui/migrators/DEPENDENCIES.md`.
- Package publication: `deployments/README.md`; for Blast SUI, also use
  `sui/blast_sui/DEPLOYING.md`.
- Blast SUI upgrade: `sui/blast_sui/UPGRADING.md`.
