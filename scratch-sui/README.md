# Parked Sui packages

Packages here are on hold. They are not part of `sui/`, have no build, test,
lint, or boundary gate, and must not be published.

- `dex` (`blast_fun_dex`): the native V2 DEX and its locked-LP migration.
- `auto_lp` (`blast_fun_auto_lp`): automatic liquidity deposits into the native
  DEX pool; it depends on `dex`.

Both still target the ADR 0082 launchpad LP-fee ABI and do not compile against
the migrators-owned LP-fee policy and authority from ADR 0083. They will be
redesigned before returning to `sui/`. Their manifests resolve `blast_fun`,
`blast_admin`, and `blast_fun_migrators` from `../../sui/`.
