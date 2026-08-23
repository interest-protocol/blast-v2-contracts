# Blast V2 on EVM

This directory owns the Solidity/Foundry implementation. Shared protocol
behavior lives in `../docs/`; EVM-specific rules live in `../AGENTS.md`.

The initial project stays single:

```text
evm/
├── foundry.toml
├── src/
├── test/
└── script/
```

Before the first production contract is merged, pin the Solidity compiler,
Foundry release, optimizer/EVM settings, and dependency commits. Decide immutable
versus proxy deployment in an ADR before committing storage layout.

Expected local gate:

```bash
forge fmt --check
forge build
forge test
forge test --gas-report
```

Raw Foundry broadcasts remain generated. Commit normalized, secret-free release
records under `../deployments/` after verifying execution and finality.
