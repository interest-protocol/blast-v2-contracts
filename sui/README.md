# Sui Move packages

The Sui implementation is a package workspace. Each independently deployed or
dependency-isolated component owns its own manifest, lockfile, sources, tests,
scripts, and release records.

```text
sui/
├── launchpad/       Blast launchpad core (`blast_fun`)
├── migrators/       venue-specific migration adapter packages
└── vesting/         independently deployed vesting packages
```

The `sui/` root is not a Move package. Run Move commands from the package that
you want to build. For the current core package:

```bash
cd launchpad
sui move build
sui move lint --warnings-are-errors
sui move test --lint
./scripts/check_source_boundaries.sh
```

Core must not import packages from `migrators/` or `vesting/`. Those packages
depend inward on the smallest required public surface from `launchpad/`.
