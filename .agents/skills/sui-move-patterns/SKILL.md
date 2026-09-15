---
name: sui-move-patterns
description: Patterns for Sui Move invariant ownership, ephemeral authorization, same-PTB adapter custody, deferred fungibility, and unsafe shared-state retirement. Use when selecting, comparing, implementing, or reviewing a named pattern or reusable design shape; use focused skills for ordinary standards work.
---

# Sui Move Patterns

Choose the smallest reusable design that matches the actual invariant. Pattern
names are mnemonics, not permission to copy a storage layout, authority model,
or public API from another protocol.

## Select the pattern

1. State the problem without naming a proposed solution. The statement is ready
   when it names the failing or required invariant instead of a pattern.
2. Identify the invariant owner, transaction boundary, custody boundary,
   authority source, and publication status. The constraint map is complete only
   when every affected asset, authority, and callable package version is
   accounted for.
3. Use the routing table below. Reject every pattern whose applicability
   boundary does not match; selection is complete only when one row fits or all
   rows are rejected.
4. Read the selected reference completely before recommending or changing the
   implementation. Read more than one reference only when the task genuinely
   combines patterns, and name the seam between them.
5. Apply the focused `$sui-move-architecture`, `$sui-move-security`,
   `$sui-move-source-style`, and `$sui-move-testing` rules that own the
   underlying invariants. This step is complete when every selected pattern
   obligation maps to an owning focused rule or an explicit target decision.
6. Report the chosen or rejected pattern, the invariant and ordered sequence,
   the abilities and visibility it requires, its failure and upgrade boundary,
   and the tests that prove the fit. The recommendation is complete only when
   every verification obligation in the selected reference is covered or
   recorded as a gap.

## Pattern routing

| Problem signal | Select | Reject when |
| --- | --- | --- |
| Core domain logic is exported by a module or package that never consumes it, while one downstream transition owns its invariant. | [Define–Export–Ignore](references/define-export-ignore.md) | The provider owns private representation or canonical policy, or several independent consumers justify a lower-level domain library. |
| A durable capability is valid only against canonical live state, and downstream modules should receive a narrow same-transaction proof instead of depending on that state. | [Validate–Issue–Consume](references/validate-issue-consume.md) | Direct capability validation is already local and simple, or authorization must persist across transactions. |
| Core custody must release assets to one selected external adapter without importing it, and settlement must complete or roll back in the same PTB. | [Bind–Handoff–Redeem](references/bind-handoff-redeem.md) | A fixed dependency is acceptable, or the request must persist, cancel, or recover across transactions. |
| A valid asset must wait across transactions before it can enter pooled backing and create a fungible liability. | [Wrap–Wait–Redeem](references/wrap-wait-redeem.md) | The asset is invalid, the work finishes in one PTB, or a numeric promise would be unbacked. |
| Dangerous old bytecode can still mutate a live shared object and no existing gate can disable every old path. | [Consume–Replace–Retire](references/consume-replace-retire.md) | Old calls are harmless or an existing version, pause, or revocable-capability seam can safely gate all dangerous paths. |

If no row matches, say so and use the focused standards to design the simpler
solution. Do not force a candidate pattern into an unrelated task.

## Combine deliberately

- **Define–Export–Ignore** may accompany any other pattern when the refactor
  also corrects ownership and dependency direction.
- **Validate–Issue–Consume** may authorize creation, redemption, or migration,
  but its witness proves only the scoped authorization at the documented
  validity instant.
- Choose **Bind–Handoff–Redeem** for linear same-PTB custody and
  **Wrap–Wait–Redeem** for persistent cross-transaction custody. Do not use a
  no-ability handoff as a waiting receipt or a persistent receipt as an
  unbounded adapter escape hatch.
- **Consume–Replace–Retire** is an emergency recovery boundary, not the default
  package-upgrade route. Exhaust existing safe gates first.

## Resolve conflicts

- Preserve published ABI and old-version reachability even when the ideal
  unpublished refactor would remove or change a declaration.
- Preserve authority, custody, economic, liveness, event, error, and testing
  rules owned by the focused skills. A pattern supplies a reusable sequence,
  not a waiver.
- Prefer a direct capability check, direct dependency, ordinary private helper,
  or explicit state gate when it satisfies the invariant with less machinery.
- When reviewing an implementation, verify the applicability boundary before
  checking conformance. Correctly implementing the wrong pattern is still a
  design defect.
