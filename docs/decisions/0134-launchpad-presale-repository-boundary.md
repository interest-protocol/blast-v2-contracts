# 0134: Launchpad and presale repository boundary

- Status: accepted
- Date: 2026-10-27

Launchpad, presale, migrators, the launch-ticket template, presale testkit and
vendor presale adapters are maintained in `interest-protocol/blast-v2-move`.
Their Move sources, tests, interface dependencies, related design documents,
contributor skills and generated agent references move together. Utilities remain
immutable Git pins into `blast-util-contracts`.

The new repository starts without first-party publication metadata or configured
ACL recipients. External venue ABI addresses, fingerprints and offline fixtures
remain dependency inputs. The original LICENSE and third-party notices remain
intact. This relocation does not publish, upgrade or migrate any on-chain object.

Boosts, liquid staking, standalone coin creation and the parked DEX remain in
`blast-v2-contracts`. Its existing admin and partner sources remain in place for
those lineages. Its composition tests and parked DEX consume the historical launchpad through
an immutable Git revision of `blast-v2-contracts`, overriding admin and partner
dependencies with that consumer repository's existing shared packages. These
legacy consumers require the original published type identities; the new
repository intentionally has none. New launch development belongs in the new
repository.

The new repository's source graph is self-contained through local packages and
pinned external dependencies. First-party published-address files, release
records and configured production recipients are rejected by
`scripts/check_repository.py`. Agent references describe source APIs without
deployment tables. Environment-specific publication records stay outside this
repository.

See [import provenance](https://github.com/interest-protocol/blast-v2-move/blob/main/docs/repository-migration.md) for the original source
revision and the imported boundary.
