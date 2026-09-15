# Stateful Move Test Fixtures

Apply these rules when tests use `test_scenario`, span transactions, or need to
move and later recover non-copyable state.

Use small, ability-free hot-potato fixtures:

- Create one fixture type per setup family and name it for what it provides.
- Store the `Scenario` plus only the objects that family uses.
- Use `Option<T>` fields only for consuming or replacement flows.
- Hide option access behind `take_*`, `replace_*`, or `retake_*` helpers.
- Provide one uniquely named `start_*` function for all setup choreography.
- Provide one consuming `<fixture>_end` function that returns or destroys every
  object and ends the scenario.
- Provide a receiver-style `<fixture>_next_tx!` macro that advances sender and
  passes one named fixture handle to the closure.
- Provide a fixture `ctx!` macro as the only transaction-context access in test
  bodies.
- Alias helpers with `use fun helper as Fixture.method`, especially when several
  fixture types exist.
- Put fixture macros, setup, and helpers in titled sections after the tests,
  using the repository's section vocabulary. Never interleave helpers with
  tests.
- Limit test bodies to starts, transaction macros, fixture methods and field
  reads, assertions, and one `end`.
- Never touch `test_scenario`, the scenario field, context internals, or fixture
  `Option` internals directly in a test body.

The fixture is complete only when setup has one entry, transaction advancement
and context access use the fixture API, and one consuming end path accounts for
every carried resource.
