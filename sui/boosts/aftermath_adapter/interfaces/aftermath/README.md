# Aftermath interface packages

Verbatim copy of `AftermathFinance/move-interfaces` at revision
`f62e74aa862ef65b8950a70d83aac8cb71c19837` (BUSL-1.1, see `LICENSE`): the
callable ABI of the mainnet packages with `abort 404` bodies. `Move.toml`,
`Published.toml` and `sources/` are unchanged, so each package keeps its
published address and `check_mainnet_abi.mjs` keeps gating the modules the
adapter calls against mainnet bytecode.

One deliberate difference, marked in the file: `authority-cap` reads
`AuthorityCap.for` instead of aborting and adds a `#[test_only]` constructor,
so adapter tests can hold real venue custody. Nothing else is edited; refresh
by re-copying the pinned revision and re-applying that one change.
