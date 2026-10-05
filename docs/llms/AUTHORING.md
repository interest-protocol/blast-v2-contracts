# Writing the integrator guides

The files in this directory are the hand-written half of `llms-full.txt`, the
single self-contained file Blast hands to integrators, who give it to their AI
agent and ask it anything. `scripts/gen_llms.py` joins these guides with an API
reference it generates from the Move packages (every public function, type,
event, and error) and checks every function these guides name.

## Reader

An integrator's AI agent that may see only `llms-full.txt`. It must be able to explain any behavior, build a working
programmable transaction block (PTB), decode an event or an abort, and say
honestly when something is not supported.

## Rules

- **Self-contained.** The guide must answer without the reader opening the
  repository, which is public: many agents cannot browse. Link a source file or
  ADR only for depth or rationale, as an absolute GitHub URL on `main`. Leave out
  internal process (deploy runbooks, tickets, reviews). No package IDs or object
  IDs: the generator prints deployment status and addresses.
- **Source-true.** Every statement must be verified in the Move source of the
  package (read every source file of your package in full). When unsure, omit
  the claim rather than guess. Describe the current source, not history.
- **Exact names.** Name every call, type, and event exactly as in source, in
  backticks. Write `module::member` (for example `presale_vault::collect_fees`).
  When the module name is one of `blast_events`, `bluefin`, `bps`, `cetus`,
  `constants`, `errors`, `events`, `migration_math`, `package_admin`, `vault`,
  or `venue_config` (each exists in more than one package), write
  `package::module::member` (for example `blast_presale::cetus::migrate`). The
  generator fails on any name it cannot resolve.
- **Who may call.** Mark every call as one of: *anyone* (permissionless), *cap
  holder* (name the capability object), or *Blast admin* (name the role or cap).
  Integrators cannot call admin functions; say what they do so the agent can
  explain them.
- **Signatures live in the reference.** In flows, give each call's purpose, its
  type arguments, the objects it takes (shared, owned, or a value from an
  earlier PTB command), and what it returns or emits. Do not paste full
  signatures.
- **Mainnet only.** Blast has no testnet deployment.
- **Positive voice, plain words.** Short sentences. Define a term once.

## Structure of each guide

Start the file with one `##` heading naming the product; use `###` and `####`
below it. Cover, in this order, omitting what does not apply:

1. **What it is**: one paragraph a newcomer understands.
2. **Objects and authority**: every shared object, owned object, and capability;
   who holds each; what each authorizes.
3. **Lifecycle**: the state machine, what moves it, and what each state allows.
4. **Flows**: each user or integrator journey as numbered PTB steps, from the
   first call to the last, including how values thread between commands
   (non-droppable values that must be consumed in the same PTB, coins to
   split or merge, `Clock` at `0x6`).
5. **Economics**: every fee, share, and split, with formulas, units (atomic
   units, BPS out of 10,000), rounding direction, and who receives dust.
6. **Time rules**: windows, deadlines, delays, and what happens at each edge.
7. **Reading state**: which getters and object fields answer common questions.
8. **Events**: which event each flow emits and what an indexer derives from it.
9. **Aborts**: the errors a caller commonly hits, by flow, with the fix.
10. **Pitfalls**: what integrators get wrong.
11. **Q&A**: the ten questions an integrator most likely asks, each answered in
    two to four sentences.

## Regenerating

After editing a guide or any public Move interface, run
`python3 scripts/gen_llms.py` and commit `llms-full.txt` with the change. CI
runs it with `--check` and fails when the committed file is stale or a guide
names a member that no longer resolves.
