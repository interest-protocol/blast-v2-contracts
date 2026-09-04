# Release verification

The vendored Sui Move testing skill owns generic test design and local quality
practice. This document owns only Blast-specific cross-package and release
evidence.

## Package gates

Run every applicable verification script in the package being changed. Where a
package has no wrapper, run the pinned toolchain's build, warning-as-error lint,
tests, and source-boundary check directly from that package. Generated traces
and coverage artifacts are not committed.

## Protocol vectors

The chain-neutral vectors under [`vectors/`](vectors/) are the numerical
compatibility boundary for curve quotes, fees, graduation, quote decimals,
vesting, and creator attestations. Regenerate vectors from the formula that
owns them; do not hand-edit expected results. An unexplained difference is a
release blocker.

## External venue gate

The migrators package contains local interface stubs, so a local build proves
type compatibility only. Before release:

1. Run its offline ABI self-test and live mainnet ABI check.
2. Run the dev-inspect matrix in
   [`sui/migrators/DEPENDENCIES.md`](../sui/migrators/DEPENDENCIES.md).
3. Record the reviewed venue revisions, module fingerprints, normalized ABI,
   route results, residual bounds, and fee-collection results.
4. Describe LP principal as permanently locked only after the aggregate
   migrators `UpgradeCap` is destroyed and that evidence is committed.

## Blast SUI gate

Run the complete `sui/blast_sui/scripts/verify.sh` gate. Publishing and
upgrading additionally follow the package's
[deployment](../sui/blast_sui/DEPLOYING.md) or
[upgrade](../sui/blast_sui/UPGRADING.md) runbook.

## Vesting mainnet gate

Before making vesting immutable on mainnet, create irrevocable and cancellable
schedules with the full 256-checkpoint vector. Decode the complete vectors,
exercise first, middle, and final claims plus cancellation and closure, and
record transaction digests, gas, serialized object size, and the absence of
checkpoint dynamic fields.

## Evidence

Store normalized public evidence under `deployments/<chain>/<network>/` using
[`deployments/README.md`](../deployments/README.md). A passing statement must
name the exact command or live check, its target revision/environment, and its
result. Console output alone is not a release record.
