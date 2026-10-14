# 0088: Authenticated market margin updates

- Status: accepted
- Date: 2026-10-14
- Amends: [0074](0074-aftermath-vault-activation-and-health.md)

The Aftermath market may change its initial and maintenance margin ratios while
leaving a Boosts account unchanged. Treat those values as live venue policy,
read from the vault's bound clearing house, rather than immutable account facts.

Only the stored-to-current preexisting checkpoint classifier adopts these two
ratios. It still requires exact account, position, order, lot, pause, freeze,
and position-specific margin fields, and the existing funding settlement shape.
Checks around an atomic venue mutation continue to require exact market ratios.

Every priced operation synchronizes first and evaluates the live venue margin,
oracle, lifecycle, leverage, and slippage gates. A higher margin requirement may
therefore block trading for a real safety reason. The SDK mirrors this boundary;
it does not substitute cached or hardcoded venue settings.

The governed adapter upgrade advances its operational generation while retaining
all existing layouts, capabilities, share identity, and dependencies. The old
mutators must fail after cutover. Existing checkpoint settlement events record
the previous and accepted checkpoint, including a zero funding delta when only
market policy changed; identical retries remain quiet.
