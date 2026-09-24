# 0048: Sui package workspace

- Status: accepted
- Date: 2026-08-29
- Amends: [0001](0001-sui-package-and-module-layout.md)

## Context

The `blast_fun` launchpad package previously occupied the `sui/` root. Blast
also needs migration adapters with venue-specific dependencies. Those adapters
must not enter the launchpad package merely because they use Sui Move.

## Decision

The `sui/` directory is a package workspace, not a Move package:

```text
sui/
├── launchpad/       blast_fun core package
└── migrators/       one independently reviewed package per venue adapter
```

The existing manifest, lockfile, sources, tests, scripts, and package README
move together into `sui/launchpad/`. The workspace root has no `Move.toml`.

`migrators/` is a category directory. A component receives a
child Move package only after its protocol and dependency boundary is accepted.
Each child package owns its own manifest, lockfile, tests, and release records.

Dependencies point inward. Migrators may depend on the smallest required
public launchpad interface. The launchpad package does not import them.

## Consequences

- Core commands run from `sui/launchpad/`.
- A venue dependency cannot silently enter the launchpad lockfile.
- Migrators can have independent upgrade, testing, and release lifecycles.
- Moving the package changes repository paths only. It does not change Move
  module names, named addresses, bytecode, storage, events, or public API.

## Verification

- The launchpad package builds, lints, and passes its full test suite from its
  new root.
- The source-boundary script runs from `sui/launchpad/`.
- Repository references use the new package paths.
- The `sui/` root contains no Move manifest.
