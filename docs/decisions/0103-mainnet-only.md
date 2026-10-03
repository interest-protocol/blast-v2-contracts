# 0103: Mainnet only

- Status: accepted
- Date: 2026-10-03
- Amends: [0074](0074-aftermath-vault-activation-and-health.md)'s testnet activation
  evidence, and the testnet builds every package gate and test harness ran

## Context

Every package gate built both the `mainnet` and `testnet` environments, every `Move.lock`
pinned both, the publish scripts took a free-form Sui environment, the in-memory PTB harness
compiled against the `testnet` environment, and the Boosts Aftermath adapter rehearsed its
activation with controlled testnet transactions. Blast is not deployed to testnet and never
will be (owner, 2026-10-03: "no testnet support for any package or code").

## Decision

Blast targets Sui mainnet only.

- Package gates build the `mainnet` environment alone, and every `Move.lock` pins `mainnet`
  alone. The migrators' lock validator rejects any other environment.
- Publish and custody scripts take no environment argument; they run against `mainnet`.
- The PTB harness compiles with `-e mainnet` and links its offline publication records under the
  mainnet chain ID. Packages a harness publishes from source, such as `blast_fun_timelock` and
  `blast_fun_vesting`, are compiled from an unpublished copy and relinked to their simulator IDs,
  as before.
- Rehearsal evidence comes from offline simulation and mainnet-fork tests, never from a testnet
  transaction. Boosts' testnet activation tooling is removed (ADR 0074 records the change).
- Deployment records exist only under `deployments/sui/mainnet/`.

## Consequences

- A package cannot be exercised on a public test network before mainnet; offline simulators and
  the committed mainnet snapshots are the only pre-release execution evidence.
- Building without `--build-env mainnet` against a client whose active environment is not
  mainnet can regenerate foreign pins; the gates and the migrators' lock validator reject them.

## Verification

- `git grep -i testnet` finds no build, lock, script, harness, or SDK path; historical ADRs and
  dated records keep their original wording.
- Each package gate passes with mainnet builds only; the PTB harness suites pass under
  `-e mainnet`; `check_mainnet_abi.mjs --self-test` rejects a testnet lock section.
