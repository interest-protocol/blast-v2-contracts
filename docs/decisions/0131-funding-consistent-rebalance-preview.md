# 0131: Funding-consistent rebalance preview

- Status: accepted
- Date: 2026-10-25

## Context

A2 identifies a keeper preview that combines venue equity after externally
settled funding with a reserve from before settlement. This can request an
unnecessary rebalance or miss a needed one. The original audit recommendation
is to apply classified pre-existing funding to a local reserve before the
band test, or document the mismatch.

## Decision

Follow the auditor's code remedy. The adapter captures the bound venue and
classifies the stored-to-captured checkpoint before preview pricing. Snapshot
admission rejects unexplained or unrepresentable funding before consuming the
economic observation. The classification supplies a core FundingSettlement;
an unchanged checkpoint maps to zero credit.

Core settlement and preview share one private calculation for the resulting
reserve, uncovered deficit and allocation totals. Costs consume reserve first;
credits repay the deficit first. Existing overflow checks, wide conservation
identities and adapter rounding remain. Settlement commits the calculated
reserve and deficit; the immutable preview uses only the projected reserve.

Use that raw projected reserve throughout positive-NAV admission, band checks,
increase sizing, reduction target sizing, emergency affordability and flat-close
preflight. Admit its ceiling at each candidate position under ADRs 0128 and
0129. Do not clamp it once at the opening notional: a larger candidate can admit
more reserve, and flatness retains the full reserve. Execution supplies its
recorded reserve to these same private sizing helpers.

The public adapter endpoint retains its signature and immutable inputs. The
core readiness function adds the authenticated funding value, with all callers
updated under the repository's fresh-source policy. No State or Lifecycle
abilities, stored layouts, errors, event schemas, authority or custody change.
No temporary State or additional lifecycle construction is permitted.

## Alternatives considered

Documentation alone would leave avoidable keeper failures. Changing only the
band calculation would leave stale reserve in positive-NAV admission and order
sizing. Duplicating the funding calculation could let preview and settlement
diverge later. A temporary mutable State would weaken lifecycle construction
boundaries without providing a necessary capability.

## Consequences

The preview neither books funding nor advances the checkpoint nor emits an
event. It covers funding already settled into the account, not additional
funding that execution may update and settle afterward. Actual synchronization
still nets signed raw pre-existing and local funding before rounding once;
the preview must not cause separately rounded bookings of that interval.
Gas, liquidity, actual fills and changing venue or price conditions can still
make the real call differ or abort. This is source preparation, not deployment,
historical-upgrade compatibility evidence or original-auditor acceptance.

## Verification

Require cost and credit regressions for both sides, parity with canonical
settlement, reserve exhaustion and deficit repayment, fractional rounding,
ceiling crossings, increase and emergency/final-close sizing, positive NAV,
overflow and lifecycle precedence, and unchanged state/checkpoints/events.
Run core and adapter package gates and downstream package compilation, update
generated references, and obtain independent review against the audit
restatement. Local venue fixtures do not replace live execution release proof.
