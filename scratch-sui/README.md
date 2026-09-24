# Parked Sui packages

Packages here are on hold. They are not part of `sui/`, have no build, test,
lint, or boundary gate, and must not be published.

- `dex` (`blast_fun_dex`): the native V2 DEX and its locked-LP migration.

Auto-LP now lives in the migrators package (ADR 0089); its native-DEX
predecessor was deleted. The DEX still targets the ADR 0082 launchpad LP-fee ABI and do not compile against
the migrators-owned LP-fee policy and authority from ADR 0083. It will be
redesigned before returning to `sui/`. Its manifest resolves `blast_fun`,
`blast_admin`, and `blast_fun_migrators` from `../../sui/`.
