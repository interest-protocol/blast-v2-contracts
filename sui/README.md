# Sui Move packages

The Sui implementation is a package workspace. Each independently deployed or
dependency-isolated component owns its own manifest, lockfile, sources, tests,
scripts, and release records.

```text
sui/
├── blast_sui/       Single-validator `funSUI` and `blastSUI` package
├── launchpad/       Blast launchpad core (`blast_fun`)
├── migrators/       venue-specific migration adapter packages
├── meme_template/   generated per-launch Meme package template
└── vesting/         independent Blast vesting package
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

The generated Meme package template has its own manifest and lockfile. Verify it
from `meme_template/` with `sui move build`, strict lint, and
`bash scripts/check_source_boundaries.sh`.

The Blast SUI package lives at `blast_sui/`. It depends only on the pinned
`SuiSystem` framework and owns its own ACL, version gate, and error registry.
Run `sui move build`, `sui move lint --warnings-are-errors`, and
`sui move test --lint --warnings-are-errors` from that directory, or
`bash scripts/verify.sh`.

The Blast vesting package lives at `vesting/` and contains `linear` and
`checkpoints` modules. Run `sui move build`,
`sui move lint --warnings-are-errors`, `sui move test --lint`, and
`bash scripts/check_coverage.sh` from that directory.

Core must not import packages from `migrators/` or `vesting/`. Those packages
depend inward on the smallest required public surface from `launchpad/`.
