# Aftermath interface packages

Verbatim copy of `AftermathFinance/move-interfaces` at revision
`f62e74aa862ef65b8950a70d83aac8cb71c19837` (BUSL-1.1, see `LICENSE`): the
callable ABI of the mainnet packages with `abort 404` bodies. `Move.toml`,
`Published.toml` and `sources/` are unchanged apart from the differences below,
so each package keeps its mainnet published address and `check_mainnet_abi.mjs`
keeps gating the modules the adapter calls against mainnet bytecode.

Four deliberate differences:

- Each `Published.toml` drops the upstream `[published.testnet]` section;
  Blast deploys only to mainnet.
- `iperps/perpetuals` points at Aftermath's version 2 upgrade: `Move.toml` and
  `Published.toml` carry `published-at = 0xe5475743…226c1b` and `version = 2`,
  while `original-id` and the `[addresses]` entry stay `0x3ec740df…`, where
  every type keeps its origin. The public ABI the adapter calls is identical
  to version 1; only the `clearing_house` bytecode changed.
- `authority-cap` reads `AuthorityCap.for` instead of aborting and adds a
  `#[test_only]` constructor, so adapter tests can hold real venue custody.
  Marked in its file.
- `ifixed` gives `one`, `add`, `sub`, `abs` and `is_neg` the bodies of the
  deployed mainnet module, transcribed from its disassembly
  (`docs/research/aftermath-ifixed-bytecode-2026-09-19.md`), so adapter tests
  execute the production sign-decoding paths instead of seams that copy them.
  `tests/math/ifixed_port_tests.move` pins those bodies to two's-complement
  reference semantics. Marked in its file.

Nothing else is edited; refresh by re-copying the pinned revision and
re-applying those changes.
