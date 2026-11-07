# Security audits

This directory preserves six reports, each tied to its reviewed source:

| Report | Reviewed revision | Coverage |
| --- | --- | --- |
| [Asymptotic - October 2026](blast-launchpad-asymptotic-oct-2026.pdf) | `01d76596` | External audit of the earlier launchpad |
| [Claude (Fable 5.1) - November 2026](blast-launch-stack-claude-nov-2026.pdf) | `4fe8d739` | AI security review of the shared launch stack; findings remediated in #217 |
| [Astra using Trail of Bits skills - November 2026](blast-launch-stack-astra-nov-2026.pdf) | `d80f2834` | AI security review of the shared launch stack; one informational documentation finding corrected in the accompanying documentation changes |
| [GiveRep / Eason Chen - November 2026](blast-launch-stack-giverep-nov-2026.pdf) | `850d8227`, `8c04789d`, `b50d0c3b` | Final launch-stack assessment with targeted remediation review through `af0765da`; supplied final PDF preserved unchanged |
| [Claude (Fable 5.1) using the Cloudflare security-audit skill - November 2026](blast-launch-stack-claude-cloudflare-nov-2026.pdf) | `d80f2834` | AI source-only security review of the shared launch stack's production Move code; no confirmed findings, one operational upgrade-sequencing lead with an owner-defined mitigation |
| [Claude (Fable 5.1) targeted review of #225 - November 2026](blast-launch-stack-claude-pr225-nov-2026.pdf) | `af0765da` (deployed source, identical to `86ee8cf9`) | AI targeted security review of the auto-LP compounding hardening, launchpad seed-price check and context reservations in #225, cross-checked against the GiveRep remediation review; no release blocker, two informational notes, one operational gap; F-1 recorded in ADR 0139 by owner decision |

The Claude and Astra reports are AI-conducted reviews. The Astra review applies
Trail of Bits' public skills; it was not performed or endorsed by Trail of Bits.
The second Claude review applies Cloudflare's public security-audit skill; it was
not performed or endorsed by Cloudflare.
The seven packages of
[ADR 0137](../docs/decisions/0137-shared-launch-stack-core-vault-and-venues.md),
the templates and the vendors are a fresh lineage with external-audit and
quiet-period release gates before vault immutability (#195). The GiveRep report
is the final delivered assessment of its listed revisions; its inclusion alone
does not establish completion of all release gates. The October Asymptotic
report covers the earlier launchpad at the revisions listed below.

Retain published reports when their reviewed code is superseded, and label their
scope and reviewed revisions. Boosts' review record is
[`docs/reviews/boosts-asymptotic-2026-10.md`](../docs/reviews/boosts-asymptotic-2026-10.md).

Add each new report here with its reviewed repository commits, scope, findings
and remediation status, and the SHA-256 of the original file.

## Asymptotic — Blast Launchpad, October 2026

[Download the complete report](blast-launchpad-asymptotic-oct-2026.pdf) (30 pages).
This is the supplied updated report, preserved without modification.

### Reviewed source

- Repository: [interest-protocol/blast-v2-contracts](https://github.com/interest-protocol/blast-v2-contracts), branch `commit-launchpad`.
- Review start: [`b549bb16e02e4c6e8ff59e1958435a638c784973`](https://github.com/interest-protocol/blast-v2-contracts/commit/b549bb16e02e4c6e8ff59e1958435a638c784973).
- Final reviewed commit, including remediation review: [`01d7659617abcd552cece6d05b9db409ec4ff2c0`](https://github.com/interest-protocol/blast-v2-contracts/commit/01d7659617abcd552cece6d05b9db409ec4ff2c0).

### Scope

The report covers only `blast_fun` in `sui/launchpad`: the launch lifecycle and
bonding curve, fee custody and claims, creator authority, configuration, package
administration, and migration handoff.

Presale, Blast SUI, Boosts, migrators, and the generated-coin template are outside
the review. `blast_admin`, `blast_partners`, and `blast_fun_timelock` are treated
as trusted dependencies. Migration adapters, receiving DEX venues, and off-chain
services are also outside scope. See the report's Scope and Coverage and
Limitations sections for the full boundaries.

### Findings and remediation

The report records **0 critical, 0 high, 0 medium, 5 low, and 5 informational**
findings. L-1, L-2, L-5, and I-1 through I-5 are **remediated**. L-3 and L-4,
concerning upgrade and root administrator custody, are **acknowledged**.
These statuses are the auditor's assessment at the final reviewed commit.

This report is retained as the historical external audit of those revisions.
The launchpad has since been rewritten as part of the shared launch stack;
this report does not establish audit coverage of the current stack or a later
deployment. Compare later source with the reviewed commit before relying on
its findings.

### File integrity

SHA-256 of the original PDF:

```text
09d627f8c5e58374ed28f1e1237a8472e3749b19c259fc3da82635e731e7801b
```

## Claude (Fable 5.1) — Blast launch stack, November 2026

[Download the complete report](blast-launch-stack-claude-nov-2026.pdf) (27 pages).
A deep adversarial security review conducted by Claude (Fable 5.1), Anthropic's
model, in an agentic review session for Interest Protocol, written in the format
of the Asymptotic report above. The system map, the function inventory and the
checked-and-holding record are its appendices.

### Reviewed source

- Repository: [interest-protocol/blast-v2-contracts](https://github.com/interest-protocol/blast-v2-contracts), branch `main`.
- Reviewed commit: [`4fe8d739f04bafd0775691795eb9f3727e984089`](https://github.com/interest-protocol/blast-v2-contracts/commit/4fe8d739f04bafd0775691795eb9f3727e984089) (#212).
- Remediation reviewed at [#217](https://github.com/interest-protocol/blast-v2-contracts/pull/217)
  (`claude/deep-audit-fixes`, rebased on `main` at `88951fe9`).

### Scope

`blast_admin`, `blast_core`, `blast_vault`, `blast_fun`, `blast_presale` and
`blast_migrators`, the seams between them, and the fidelity of the Cetus and Bluefin
interface stubs against mainnet bytecode. `blast_partners`, the generated coin
packages, the vesting package, the Sui Framework and the Move Standard Library are
trusted dependencies. The review tests; it does not prove. No venue bytecode ran in
it; the PTB fork gate remains the evidence for venue behaviour.

### Findings and remediation

The report records **0 critical, 0 high, 0 medium, 1 low, and 4 informational**
findings and one hypothesis (H-1, whether Bluefin's auto-LP add can ask more than
the venue's local estimate). All five findings are **remediated** in #217 (ADR 0134,
amendment of 5 November 2026): the vault's `unpause` is version-gated (L-1); every
`unpause` requires the core treasury's notice guarded (I-1);
`MigrationAllocationPaid` carries the vesting schedule IDs (I-2); holder-reward
leaves are documented as account addresses (I-3); auto-LP compounding is the
venues' own `compound_auto_lp`, apart from collection (I-4). H-1 can no longer
block collection, and the launchpad fork gate exercises the add on both venues
after each collection; adversarial pool states are
[#218](https://github.com/interest-protocol/blast-v2-contracts/issues/218).

The proof-of-concept tests and run logs behind the report are held by Blast beside
the report's source, not in this repository.

### File integrity

SHA-256 of the PDF:

```text
f42835edd92decf8501f6d240134a81e96c1d1d93fb365fb54ffcc830a709535
```

## Astra using Trail of Bits skills — Blast launch stack, November 2026

[Download the complete report](blast-launch-stack-astra-nov-2026.pdf) (7 pages).
An AI-conducted security review by the OpenAI Astra audit agent on 6 November
2026, applying selected public Trail of Bits workflows through Codex. This is
not a Trail of Bits company audit or endorsement. The PDF preserves the reviewed
source, original finding and verification results; its cover distinguishes the
later documentation remediation recorded below. Supporting analyses and run logs
are retained separately by Blast, not included in this repository.

### Reviewed source

- Repository: [interest-protocol/blast-v2-contracts](https://github.com/interest-protocol/blast-v2-contracts), branch `main`.
- Reviewed commit: [`d80f2834468ba798df66f36d01fd64eec9d4df91`](https://github.com/interest-protocol/blast-v2-contracts/commit/d80f2834468ba798df66f36d01fd64eec9d4df91).
- Methodology: [Trail of Bits public skills at `470419e16f97e112d01fc32f4898aea1755015d9`](https://github.com/trailofbits/skills/tree/470419e16f97e112d01fc32f4898aea1755015d9).

### Scope

`sui/admin`, `sui/core`, `sui/migrators`, `sui/vault`, `sui/launchpad` and
`sui/presale`, including their authority, custody, accounting, lifecycle and
integration seams. Reached `sui/partners` and irrevocable linear vesting in
`sui/vesting` were included; checkpoint vesting was inventoried without a body
audit. Other products and off-chain systems are outside scope.

The review used context building, entry-point analysis, spec-to-code comparison,
false-positive checking, differential review and variant analysis. Verification
passed **1,312 Move tests** and **37 native PTB tests**, plus source/style/error
gates and live mainnet ABI checks. Native tests used retained compatible binaries
with recorded provenance and committed venue bytecode. The live ABI check was
read-only; no live economic matrix or new full Rust build was performed. See the
report for the remaining evidence boundaries and accepted risks.

### Findings and remediation

The report records **0 critical, 0 high, 0 medium, 0 low, and 1 informational**
finding. I-1 concerns superseded integration documentation: fee collection no
longer compounds auto-LP balances, and product venue delisting does not change
the venue selected by an existing sale.

I-1 is **remediated in the documentation accompanying this record**:
[`sui/migrators/DEPENDENCIES.md`](../sui/migrators/DEPENDENCIES.md) and Bluefin's
API comments now describe separate collection and `compound_auto_lp` calls;
[ADR 0137](../docs/decisions/0137-shared-launch-stack-core-vault-and-venues.md)
distinguishes product admission during preparation/creation from the live vault
registry checks during migration. Generated LLM references were refreshed. No
executable Move behavior was changed. The PDF retains I-1's original open status
at audit completion rather than implying the corrected documentation was reviewed
at `d80f2834`.

No new actionable security vulnerability was confirmed. This does not prove the
absence of defects or replace the fresh lineage's external audit, quiet period
and release-matrix obligations.

### File integrity

SHA-256 of the PDF:

```text
673c0f2938fdfd49f71401447999e70fd2d5a7fa74cc1ea958edec43935bc82c
```

SHA-256 of the original Markdown report, retained separately by Blast:

```text
d5dcf22d239d2dc8a6ffafdf73cb3c9d35263910efa70f076a9c030c5fbea461
```

## GiveRep / Eason Chen — Blast.fun Security Assessment, November 2026

[Download the complete report](blast-launch-stack-giverep-nov-2026.pdf) (13 pages,
including the cover). Prepared by **GiveRep Labs, Eason Chen**, issued **6 November
2026**, for an assessment period of **3–5 November 2026**. The supplied final file,
`Blast_fun_Security_Assessment_final.pdf`, is preserved byte-for-byte under the
existing repository filename, replacing the earlier delivered PDF.

**Report status: Final assessment with remediation review.** GiveRep reviewed
fixes and affected callers through `af0765da`, including the venue-binding fix
at `d80f2834`. This targeted follow-up is not a new full assessment of every
package or a verification of deployed-source parity.

### Reviewed source and chronology

Repository: [interest-protocol/blast-v2-contracts](https://github.com/interest-protocol/blast-v2-contracts).

| Revision | Role in the report |
| --- | --- |
| [`850d8227edce340a6d5d839d30efbd14b707dfc6`](https://github.com/interest-protocol/blast-v2-contracts/commit/850d8227edce340a6d5d839d30efbd14b707dfc6) | Earlier implementation used as the comparison baseline; source reviewed |
| [`8c04789d3f9a8606944717841071a5fe8e4e10d1`](https://github.com/interest-protocol/blast-v2-contracts/commit/8c04789d3f9a8606944717841071a5fe8e4e10d1) | Refactor under primary review; source reviewed |
| [`b50d0c3bee50b637a673d1ccb64b5413af4ba518`](https://github.com/interest-protocol/blast-v2-contracts/commit/b50d0c3bee50b637a673d1ccb64b5413af4ba518) | Incremental follow-up and LOW-01 sealed-cap remediation; final full-assessment source |
| [`af0765dab18de741b130c52831c859717134f2c1`](https://github.com/interest-protocol/blast-v2-contracts/commit/af0765dab18de741b130c52831c859717134f2c1) | Targeted remediation review of fixes and affected callers |

The remediation review includes changes at
[`d80f2834468ba798df66f36d01fd64eec9d4df91`](https://github.com/interest-protocol/blast-v2-contracts/commit/d80f2834468ba798df66f36d01fd64eec9d4df91)
([#222](https://github.com/interest-protocol/blast-v2-contracts/pull/222)) and
[`af0765dab18de741b130c52831c859717134f2c1`](https://github.com/interest-protocol/blast-v2-contracts/commit/af0765dab18de741b130c52831c859717134f2c1)
([#225](https://github.com/interest-protocol/blast-v2-contracts/pull/225), merged
6 November 2026). Both are covered by the final PDF's targeted remediation
review through `af0765da`; the full assessment ends at `b50d0c3b`.

### Scope and methodology

The six primary packages are `blast_admin`, `blast_core`, `blast_vault`,
`blast_migrators`, `blast_fun` (launchpad), and `blast_presale`. Review covers
access control, upgrades, custody, pricing, fees, migration, holder rewards, and
the boundaries between these packages. The reached dependency closure includes
`blast_partners`, `blast_fun_vesting`, `blast_fun_otc`, the launch-ticket,
presale-coin and standalone-coin templates, and the vendored Aftermath DAO
presale adapter. This is broader than the October launchpad-only assessment.

The report describes source review, disassembly of pinned mainnet Cetus v15 and
Bluefin v17 bytecode, arithmetic analysis, and offline simulation using Sui
1.77.2 with Move framework `06734f6f`. Simulation used deterministic fixture
keys and fictitious balances with network access denied; no real wallet, chain
signing, broadcast or chain mutation was used.

`blast_sui` was inventoried and statically compared against liquid-staking risk
classes and public reports, but is **outside the security assurance** because it
does not compile at the frozen revision. Its deployment and live value were
not established. Off-chain services, frontend, infrastructure and key custody
are excluded. The review trusts the Sui framework, pinned venue behavior and
authorized root/role administration, including the documented multisig plan;
it does not independently attest operational key custody.

### Findings and reviewed remediation

The report records **0 critical, 0 high, 0 medium, 5 low, and 15 informational**
items. It establishes no confirmed Critical, High or Medium vulnerability.
The Low count includes potential-authority, economic-exposure, trust and
operational observations; it is not a count of five proven fund-theft exploits.

The following tables preserve every finding ID and distinguish the original
observation from its disposition. The final PDF reviews the relevant fixes in
#222 and #225. Additional project context is identified separately below; no
contract tests were rerun for this file replacement.

| Low item | Original assessment | Final report status and context |
| --- | --- | --- |
| LOW-01: publisher receives raw TreasuryCap before venue preparation | GiveRep identified the mint-authority exposure. Exact supply and Cetus unwind dust already blocked the proposed buyer-stranding chain. | **Resolved** at `b50d0c3b` / [#219](https://github.com/interest-protocol/blast-v2-contracts/pull/219). [ADR 0138](../docs/decisions/0138-sealed-treasury-caps-and-venue-admissions.md) seals mint authority under the product; the final review confirms sealed custody remains present. |
| LOW-02: permissionless auto-LP compounding lacks price bounds | Exposure limited to the auto-LP fee share; a profitable trading sequence was not established. | **Resolved** at `af0765da`. #225 hardens both venues with a live `AutoLpAdmin`, inclusive keeper-approved sqrt-price bounds, private entry, and pool consumption/re-sharing as its last PTB use. [ADR 0139](../docs/decisions/0139-admin-bounded-auto-lp-compounding.md) records the decision. Keeper integrity and independent pricing remain trust assumptions. |
| LOW-03: upgradeable LP custody is not permanent custody | Open trust/documentation boundary; a privileged compatible migrators upgrade could change principal custody after its delay. | **Documentation clarified** at `af0765da`; upgrade trust remains. There is no exposed withdrawal in the existing code, but upgrades remain trusted. Making the vault immutable alone does not freeze migrators; [#195](https://github.com/interest-protocol/blast-v2-contracts/issues/195) remains relevant. |
| LOW-04: ignored funded presale can be settled and cancelled at the LP deadline | Open, documented operational behavior after a week of inaction; full buyer refunds through claims, creator allocations remain locked; no theft. | Retained policy in #225. No early-cancellation exploit was demonstrated; operators must act within the liquidity window. |
| LOW-05: an authorized proposal can reduce future notice to zero | Open administrative trust, by design. The current wait still applies before the new zero delay takes effect. | Retained policy in #225, including zero-notice bootstrap. A permanent minimum would require a separate governance decision. |

| Informational item | Original observation | Final report status and project context |
| --- | --- | --- |
| INFO-01 | Five creator-authority signature fixtures use `0xc` while the manifest uses `0x0`. | **Resolved** at `af0765da`; GiveRep records all 19 creator-authority tests passing at both `0x0` and `0xc`, without weakening production signature checks. |
| INFO-02 | Mutable sealed-cap borrowing gives admitted venues mint/burn authority during preparation. | Retained admitted-venue trust surface; no arbitrary-caller path established. |
| INFO-03 | The report describes unchecked `u64` addition for extreme opening-round Quote amounts. | #225 clarifies that Move VM addition is checked: an extreme amount aborts the caller's transaction and rolls back; no wrapping or conservation defect established. |
| INFO-04 | Launchpad lacks presale's seedable-price check and has no cancellation from `MigrationReady`. | **Missing guard resolved** at `af0765da`; the final review records passing seedable-price rejection coverage. Cancellation was not added; venue availability remains a dependency. |
| INFO-05 | Public generic sealing does not itself establish product provenance. | Retained typed authority: exact product-witness checks prevent a generic seal from becoming a product-issued sale token. Integrators must not infer admission from its wrapper type alone. |
| INFO-06 | Creator can consume its own one-time migration ticket. | Retained self-griefing behavior; no unrelated caller can consume that owned ticket. |
| INFO-07 | Raw-cap presale testkit constructors are incompatible with sealing. | Obsolete constructors **retired** at `af0765da`; the final review records passing faucet and template tests and the documented presale coin-template route. |
| INFO-08 | Protocol-share application does not settle first, unlike fee-split changes. | Retained documented policy: the new share applies on the next collection. |
| INFO-09 | `destroy_cap` lacks a generation check. | Retained cleanup of the caller-owned inert cancelled-sale cap; no asset-protection benefit established for a new gate. |
| INFO-10 | Frozen `venue_fork` test fails during sealed-cap setup before migration assertions. | **Execution coverage restored**: GiveRep's fresh rebuild at `af0765da` passes all 11 venue-fork tests. The earlier setup failure was not reproduced; no separate fixture-lookup source repair is attributed to the project. |
| INFO-11 | `blast_sui` imports deleted admin modules and does not compile. | Remains open in [#223](https://github.com/interest-protocol/blast-v2-contracts/issues/223). Outside #225's launch-stack fixes; no current native liquid-staking coverage claimed. |
| INFO-12 | Boosts' Aftermath adapter has the same stale-admin compile break. | Also tracked in [#223](https://github.com/interest-protocol/blast-v2-contracts/issues/223); not fixed by #225. |
| INFO-13 | Single-validator concentration and monotone-rate assumptions can stop redemptions after a slash. | Retained liquid-staking design concern; no deployed slash or exploitable current state established. |
| INFO-14 | Liquid-staking redemption-fee authority is immediate (100 BPS cap); deleted modules prevent verifying its upgrade policy. | Remains outside launch-stack remediation. [#170](https://github.com/interest-protocol/blast-v2-contracts/pull/170) contains separate proposed work, not a merged fix at this record's source revision. |
| INFO-15 | Near-full liquid-staking redemption fails closed at a residual of at most 3 MIST. | Retained bounded rounding observation, not evidence of inflation or lost conservation; the compile break prevents release assurance. |

REP-01 is a **third-party/maintainer report**, not a GiveRep discovery or an
additional severity-rated finding. The final PDF marks repeated
`vault::share_with_position` calls **resolved at `d80f2834`**, with remediation
reviewed through `af0765da`. #222 binds the exact venue during construction and
checks it before attachment/emission; the existing position key prevents repeat
attachment under the bound venue. GiveRep records five passing Move regressions
and the native rogue-venue regression, including rollback of objects and events.

The report separately refutes five candidates: buyer-stranding through Cetus
pre-creation (REF-01), an unreachable holder-round close based on shared-object
argument assumptions (REF-02), two Bluefin pool-uniqueness claims (REF-03 and
REF-04), and a missing opening-round remainder sweep (REF-05). These are not
confirmed findings. Its single unverified hypothesis, UNV-01, concerns
privileged Cetus delisting/pre-creation causing migration liveness failures;
it was not reproduced and is not an arbitrary-attacker exploit. Broader
adversarial compounding states remain tracked in
[#218](https://github.com/interest-protocol/blast-v2-contracts/issues/218).

### Verification evidence and limits

The final PDF reports **1,333 / 1,333 distinct Move tests** at `af0765da`:

| Suite | Reported result |
| --- | --- |
| `blast_admin` | 198 / 198 |
| `blast_core` | 85 / 85 |
| `blast_vault` | 127 / 127 |
| `blast_fun` (launchpad) | 449 / 449 |
| `blast_presale` | 287 / 287 |
| `blast_migrators` | 40 / 40 |
| `blast_partners` | 74 / 74 |
| `blast_presale_testkit` | 2 / 2 |
| `blast_fun_vesting` | 53 / 53 |
| Presale coin template | 1 / 1 |
| Aftermath DAO presale adapter | 17 / 17 |

Some suites exhausted the initial 10-million-instruction budget. Launchpad
passed with a ten-billion limit; presale, migrators and partners passed with a
one-billion limit. Production source, named addresses and assertions were not
changed to obtain these results. The 19 creator-authority tests also passed at
`0xc`; repeated address runs are excluded from the distinct-test total.

The native PTB targets were rebuilt from the remediation source and passed
**35 / 35 tests**:

| Native target | Reported result |
| --- | --- |
| `venue_fork` | 11 / 11 |
| `presale_venue_fork` | 11 / 11 |
| `atomic_migration` | 12 / 12 |
| `bootstrap` | 1 / 1 |

These cover auto-LP authorization, revocation, price bounds, wrong-pool rejection,
rollback and consumed-input reuse; vault venue binding; migration; holder-reward
close and recovery; and relevant upgrade paths. The earlier `b50d0c3b` setup
failure was not reproduced. The historical Cetus pre-creation reproduction,
across two coin orderings and two seed sizes, is separate from these totals.

All results above are **reported by GiveRep**, not newly rerun for this file
replacement. Execution used offline simulation, deterministic fixture keys and
fictitious balances. Venue bytecode came from the committed mainnet snapshot at
checkpoint `339033808`, with framework linkage adapted for simulation; it was
not current-mainnet replay. `blast_sui` and Boosts' Aftermath adapter still fail
compilation on stale administration APIs; no passing coverage is claimed for
them. SDK integration of the changed compounding ABI is tracked separately in
[SDK #104](https://github.com/interest-protocol/blast-v2-sdk/issues/104).

Neither the report nor this record establishes deployed-source parity, current
on-chain value at risk, or certification of a deployed system. Public audits of
comparable liquid-staking and venue products cited in the PDF provide reference
material, not assurance of Blast's implementation. The full assessment,
targeted remediation review, and still-open follow-ups must be evaluated at
their respective revisions.

### File integrity

SHA-256 of the original supplied PDF and the identical repository copy:

```text
7adf231963d6d6f9f4ec5ca43d027a93e7438ae2716c6bf8f010b382812e0f1b
```

## Claude (Fable 5.1) using the Cloudflare security-audit skill — Blast launch stack, November 2026

[Download the complete report](blast-launch-stack-claude-cloudflare-nov-2026.pdf) (24 pages).
An AI-conducted, source-only security review by Claude Fable 5.1
(`claude-fable-5-1`), Anthropic's model, completed on 6 November 2026. It applies
Cloudflare's public security-audit skill, which is coverage-ledger driven: hunters
review each unit, coverage critics check for gaps, and every candidate is then
validated and its final record verified by fresh, independent reviewers. This is
not a Cloudflare company audit or endorsement. Effort was `xhigh` for
reconnaissance and the first 12 hunters, then `high` for the remaining hunters,
both coverage critics, all verifiers and the reports. Fable made every security
judgement; Codex and then Claude Code (Claude Opus 5.5) only orchestrated the run
and rendered the PDF. Run evidence, transcripts and the Markdown sources of the
PDF are retained separately by Blast, not included in this repository.

### Reviewed source

- Repository: [interest-protocol/blast-v2-contracts](https://github.com/interest-protocol/blast-v2-contracts), branch `main`.
- Reviewed commit: [`d80f2834468ba798df66f36d01fd64eec9d4df91`](https://github.com/interest-protocol/blast-v2-contracts/commit/d80f2834468ba798df66f36d01fd64eec9d4df91), an unmodified source snapshot with an integrity manifest.
- Methodology: [Cloudflare security-audit skill at `c1c8a8c1471069fb0e188eeaff69b8e8db6564a8`](https://github.com/cloudflare/security-audit-skill/tree/c1c8a8c1471069fb0e188eeaff69b8e8db6564a8), `standard` profile, scoped.

Later production changes, including the auto-LP compounding hardening in
[#225](https://github.com/interest-protocol/blast-v2-contracts/pull/225), are
**outside the reviewed revision**.

### Scope

Production Move contract code in `sui/admin`, `sui/core`, `sui/migrators`,
`sui/vault`, `sui/launchpad` and `sui/presale`: their `sources/**/*.move`, the
Cetus and Bluefin interface stubs the migrators link against, and linked
dependency behaviour, including the pinned Sui framework `coin_registry` at
`06734f6f`. Tests, the PTB harness, fixtures, scripts, CI and publishing tooling
were not audit targets, at Blast's direction; they were read only as supporting
evidence for a contract claim.

Coverage closed 55 in-scope contract units across 24 hunter reviews; both the
post-wave and the final-clean coverage critics found no gaps. The review was
**source-only**: no sandbox was provisioned, so nothing was built, tested, run or
probed on chain, and no record could reach `confirmed`. Runtime, venue bytecode
and deployment behaviour are untested.

### Findings and disposition

The report records **0 confirmed findings**, **1 lead needing validation**
(no severity) and **1 rejected candidate**.

- **NV-1: vault version advance is uncoupled from the migrators relink.** After a
  vault upgrade advances the vault's `PackageVersion`, migrators calls into the
  vault (migration, fee collection, compounding, buyback) abort until a relinked
  migrators upgrade commits. A Funded presale cannot migrate during that window
  and its liquidity deadline cannot be extended, so once the deadline passes any
  sender can call `cancel_unlaunched`: participants are refunded in full, while
  raise and token recipients receive nothing. It requires an operator-initiated
  vault upgrade and is an availability hazard, not a theft path. It overlaps
  GiveRep's LOW-04.

  **Project disposition: accepted operational risk with a release procedure.**
  Before any vault upgrade, Blast pauses presale creation and waits until no
  presale is Pending, Open or Funded. Only then does it upgrade the vault and
  land the migrators relink. The vault is to be
  made immutable once it has been battle-tested on mainnet
  ([#195](https://github.com/interest-protocol/blast-v2-contracts/issues/195)),
  which retires this hazard. No code change is made for NV-1.
- **Rejected: Bluefin symbol bound checked only at preparation.** The pinned Sui
  `coin_registry` has no `MetadataCap` symbol setter, so the symbol
  `bluefin::migrate` reads is the one `prepare` bounded.

The report's hardening notes, such as the unbounded Quote symbol and icon URL
passed to Bluefin pool creation and the zero-delay floor on per-launch cap
reassignment, are recommendations, not findings. They are not addressed by this
record.

No new actionable security vulnerability was confirmed. This does not prove the
absence of defects or replace the fresh lineage's external audit, quiet period
and release-matrix obligations.

### File integrity

SHA-256 of the PDF:

```text
b87022751801701f797db0295ddc1f21a9677c4394127a7c3b9b59cff37f8145
```

## Claude (Fable 5.1) targeted review of #225 — Blast launch stack, November 2026

[Download the complete report](blast-launch-stack-claude-pr225-nov-2026.pdf) (8 pages).
An AI-conducted targeted security review by Claude Fable 5.1 (`claude-fable-5-1`),
Anthropic's model, completed on 7 November 2026 at Blast's request, covering only
the changes of [#225](https://github.com/interest-protocol/blast-v2-contracts/pull/225),
their callers and the GiveRep remediation review of the same commit. Fable made every
security judgement and ran the gates itself from a detached worktree. The Markdown
source and the test logs are retained in the Blast workspace, not in this repository.
SHA-256 of the PDF: `6b056a4056fea714c45aee679c1ea4c4d77709db8f048edcc66fc1f5d5f7abf6`.

### Reviewed source

- Repository: [interest-protocol/blast-v2-contracts](https://github.com/interest-protocol/blast-v2-contracts), branch `main`.
- Reviewed commit: [`af0765dab18de741b130c52831c859717134f2c1`](https://github.com/interest-protocol/blast-v2-contracts/commit/af0765dab18de741b130c52831c859717134f2c1),
  the merge of #225 and the last commit that changed the deployed Move source; its `sui/` tree is
  byte-identical to the deployment record's `86ee8cf9`.
- Toolchain: `sui 1.77.2-51d177ad7d65`; native venue fork against the committed mainnet snapshot.

### Scope

The production Move diff of #225 (`blast_core::blast_domain::AutoLpAdmin`, the private
`compound_auto_lp` entries in `blast_migrators::cetus` and `::bluefin`, `EInvalidAutoLpPrice`,
the launchpad `finalize` seed-price preflight, and the trailing `TxContext` reservations in
launchpad, presale, vault and holder rewards), every caller and callee of those functions across
the six connected packages, the venue interfaces and the Sui runtime natives ADR 0139 relies on,
and the structural gates. Tests, fixtures and documentation changes were reviewed to classify
what changed on chain. Packages whose production code #225 did not touch were not re-audited.

### Findings and disposition

No release blocker inside #225's scope. The `AutoLpAdmin` guard and the keeper's inclusive
sqrt-price bounds are enforced in the only path that can move a vault's auto-LP balances, no
other function or PTB composition bypasses them, the pool consume-and-re-share is accepted by the
pinned runtime, and the launchpad preflight checks exactly the amounts migration later hands off.

- **F-1 (informational):** `vault::take_auto_lp` does not check the vault's `admin_pause_bit`,
  so a vault pause stops buybacks and reward publication but not a live `AutoLpAdmin` keeper.
  **Project disposition: record in ADR only.** ADR 0139's 7 November 2026 amendment names
  `AutoLpAdmin` revocation as the stop for compounding; no code change.
- **F-2 (informational):** the launchpad reuses `EInvalidGraduationTarget` for an unseedable
  allocation price where the presale has a dedicated code; documented, no change.
- **F-3 (operational):** the mainnet deployment record grants no `AutoLpAdmin` and no keeper
  builder exists for the new ABI; compounding cannot run until both exist. Release-checklist item.

Checks run and passing: launchpad 449, migrators 40, vault 127, presale 287 and core 85 Move
tests; the 11 native venue-fork tests; the style, error-registry, llms and all six source-boundary
gates. The GiveRep remediation review agrees with this review on every point it covers and does
not record F-1 or F-3.
