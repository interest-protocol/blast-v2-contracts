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
and creator attestations. Regenerate vectors from the formula that
owns them; do not hand-edit expected results. An unexplained difference is a
release blocker.

## External venue gate

The migrators package contains local interface stubs, so a local build proves
type compatibility only. Before release:

1. Run its offline ABI self-test and live mainnet ABI check.
2. Run the replacement Cetus and Bluefin dev-inspect matrix in
   [`sui/migrators/DEPENDENCIES.md`](../sui/migrators/DEPENDENCIES.md).
3. Record the reviewed venue revisions, module fingerprints, normalized ABI,
   route results, residual bounds, and fee-collection results.
4. Describe LP principal as held by an upgradeable package with no exposed
   withdrawal path, never as permanently locked: the migrators package stays
   upgradeable (ADR 0088).

## Blast SUI gate

Run the complete `sui/blast_sui/scripts/verify.sh` gate. Publishing and
upgrading additionally follow the package's
[deployment](../sui/blast_sui/DEPLOYING.md) or
[upgrade](../sui/blast_sui/UPGRADING.md) runbook.

## Evidence

Store normalized public evidence under `deployments/<chain>/<network>/` using
[`deployments/README.md`](../deployments/README.md). A passing statement must
name the exact command or live check, its target revision/environment, and its
result. Console output alone is not a release record.
