# Aftermath interface packages

Verbatim copy of `AftermathFinance/move-interfaces` at revision
`f62e74aa862ef65b8950a70d83aac8cb71c19837` (BUSL-1.1, see `LICENSE`): the
callable ABI of the mainnet packages with `abort 404` bodies. `Move.toml`,
`Published.toml` and `sources/` are unchanged, so each package keeps its
published address and `check_mainnet_abi.mjs` keeps gating the modules the
adapter calls against mainnet bytecode.

Two deliberate differences, each marked in its file:

- `authority-cap` reads `AuthorityCap.for` instead of aborting and adds a
  `#[test_only]` constructor, so adapter tests can hold real venue custody.
- `ifixed` gives `one`, `add`, `sub`, `abs` and `is_neg` the bodies of the
  deployed mainnet module, transcribed from its disassembly
  (`docs/research/aftermath-ifixed-bytecode-2026-09-19.md`), so adapter tests
  execute the production sign-decoding paths instead of seams that copy them.
  `tests/ifixed_port_tests.move` pins those bodies to two's-complement
  reference semantics.

Nothing else is edited; refresh by re-copying the pinned revision and
re-applying those changes.
