# Adversarial Integration Tests

Apply these rules when a transition uses time, an oracle, signatures,
adversarial assets, randomness, callback-like composition, or another external
integration.

- Test deadline units and before, exact, and after-boundary `Clock` values.
- Test oracle source, pair, units, zero or invalid values, stale and future
  updates, confidence or deviation, liquidity, and caller-selectable history.
- For off-chain signatures, submit each action through the intended actor and
  an unrelated third party. Require the latter to fail harmlessly or produce
  exactly the signer-approved result. Test every bound domain and omit domains
  the accepted design does not require.
- Exercise admitted assets under mint, deny, global pause, and action-policy
  powers, and reconcile authoritative balance deltas.
- For irreversible authority destruction or handoff, prove successor usability
  plus every required exit, cancel, refund, claim, unwind, retry, and settlement
  path under pause and version states.
- For `sui::random`, test forbidden composition and selective-commit attacks
  across every outcome-dependent bounded resource, not only gas.
- Using the target network's `ProtocolConfig`, drive each outcome near every
  applicable computation, object-runtime, dynamic-field, event, created or
  deleted object, written-object, and effects-size limit.
- Prove no attacker-controlled budget, input, state, or surrounding PTB can
  make only favorable outcomes commit. Test internal generator construction
  and commit-reveal liveness when applicable.

Coverage is complete only when every untrusted input, bound domain, boundary,
failure mode, and selective-commit sequence has a deterministic test or a
reported environment gap.
