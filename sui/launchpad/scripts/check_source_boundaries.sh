#!/usr/bin/env bash

set -euo pipefail

cd "$(dirname "$0")/.."

failures=0

if [[ -e ../Move.toml ]] \
  || [[ ! -f Move.toml ]] \
  || [[ ! -d ../migrators ]] \
  || [[ ! -d ../vesting ]]; then
  echo 'sui/ must remain a package workspace with launchpad core, migrators, and vesting boundaries.' >&2
  failures=$((failures + 1))
fi

if rg -n \
  '(^use std::(vector|option|internal)(::[^;]+)?;|^use std::\{[^;]*(vector|option|internal)|^use sui::(object|transfer|tx_context)(::[^;]+)?;|^use sui::\{[^;]*(object|transfer|tx_context))' \
  sources tests; then
  echo 'Move 2024 implicit prelude modules and types must not be imported explicitly.' >&2
  failures=$((failures + 1))
fi

mapfile -t move_files < <(find sources tests -type f -name '*.move' -print | sort)

duplicate_import_roots="$({
  for file in "${move_files[@]}"; do
    awk '
      /^use fun / { next }
      /^use / {
        root = $2;
        sub(/::.*/, "", root);
        count[root] += 1;
      }
      END {
        for (root in count) {
          if (count[root] > 1) print FILENAME ":" root;
        }
      }
    ' "$file"
  done
} | sort)"

if [[ -n "$duplicate_import_roots" ]]; then
  printf '%s\n' "$duplicate_import_roots"
  echo 'Imports from one root address must use one nested declaration per module.' >&2
  failures=$((failures + 1))
fi

if rg -n '^use blast_fun::errors|^use sui::event::emit' \
  sources tests; then
  echo 'Error macros and one-off event emission must remain fully qualified.' >&2
  failures=$((failures + 1))
fi

if rg -n '\bfun (fields|into_parts)\b|\.(fields|into_parts)\(' sources tests; then
  echo 'APIs must use field-named reads, destination-named conversions, or destroy for consuming wrappers.' >&2
  failures=$((failures + 1))
fi

if rg -n 'std::unit_test::(assert_eq!|destroy\()' tests; then
  echo 'Test modules must import assert_eq and destroy instead of qualifying each call.' >&2
  failures=$((failures + 1))
fi

if rg -n '^[[:space:]]*(public(\(package\))?[[:space:]]+)?fun[[:space:]]+destroy.*for_testing' sources \
  || rg -n '\btest_utils::destroy\b|(\.|::)destroy(_[a-z_]+)?_for_testing\(' tests \
  || rg -n '^fun destroy(_[a-z0-9_]+)?\(' tests; then
  echo 'Tests must use std::unit_test::destroy or Fixture.end, without bespoke production teardown APIs.' >&2
  failures=$((failures + 1))
fi

if rg -n '^[[:space:]]*(assert!|abort\b|public struct\b)' sources/lib/errors.move; then
  echo 'errors.move must contain only diagnostic constants and zero-cost numeric macros.' >&2
  failures=$((failures + 1))
fi

if [[ ! -f sources/lib/bps.move ]] \
  || ! rg -q '^public struct Bps\(u64\) has copy, drop, store;' sources/lib/bps.move \
  || [[ "$(rg -c '^public\(package\) fun (new|value|apply_down|apply_up|complement)\(' sources/lib/bps.move)" != 5 ]] \
  || rg -n '^(public|entry|public entry) fun |\b(UID|key|Balance|Coin|TxContext|transfer::|events::)\b' \
    sources/lib/bps.move \
  || ! rg -Fq 'value <= constants::basis_points_denominator!()' sources/lib/bps.move \
  || ! rg -Fq 'amount.mul_div(self.value(), constants::basis_points_denominator!())' \
    sources/lib/bps.move \
  || ! rg -Fq 'amount.mul_div_ceil(self.value(), constants::basis_points_denominator!())' \
    sources/lib/bps.move \
  || ! rg -Fq 'Bps(constants::basis_points_denominator!() - self.value())' \
    sources/lib/bps.move; then
  echo 'bps.move must keep only a public opaque type and package-visible validation, value, rounded application, and complement operations.' >&2
  failures=$((failures + 1))
fi

if rg -n '<= constants::basis_points_denominator!()' \
    sources --glob '!**/lib/bps.move'; then
  echo 'The inclusive basis-points range must be validated only by bps::new; owners may add stricter policy checks.' >&2
  failures=$((failures + 1))
fi

if rg -n '^[[:space:]]+[a-z_]+_bps: Bps,' sources/lib/events.move; then
  echo 'Replay events must keep basis-points facts as primitive u64 fields.' >&2
  failures=$((failures + 1))
fi

blast_production="$(sed '/^\/\/ === Test-Only Functions ===/,$d' sources/blast.move)"

if [[ ! -f sources/blast.move ]] \
  || ! rg -Fq 'public struct BLAST() has drop;' sources/blast.move \
  || ! rg -U -q \
    'fun init\(otw: BLAST, ctx: &mut TxContext\) \{\s*sui::package::claim_and_keep\(otw, ctx\);\s*\}' \
    <<<"$blast_production" \
  || [[ "$(rg -c '^(public struct|fun) ' <<<"$blast_production")" != 2 ]] \
  || [[ "$(rg -c '^fun init\(' <<<"$blast_production")" != 1 ]] \
  || rg -n '^(public|entry|public\(package\)) fun ' <<<"$blast_production"; then
  echo 'blast.move must own only the package BLAST witness and private Publisher claim.' >&2
  failures=$((failures + 1))
fi

if rg -n '^public struct ACL' sources/acl.move \
  || ! rg -Fq 'fun init(ctx: &mut TxContext) {' sources/acl.move; then
  echo 'acl.move must use a context-only initializer and must not own the package OTW.' >&2
  failures=$((failures + 1))
fi

package_admin_production="$(sed '/^\/\/ === Test-Only Types ===/,$d' sources/package_admin.move)"

if [[ ! -f sources/package_admin.move || -f sources/upgrade.move ]] \
  || ! rg -U -q \
    'public struct PackageAdmin has key \{\s*id: UID,\s*publisher: Publisher,\s*upgrade_cap: UpgradeCap,\s*\}' \
    sources/package_admin.move \
  || [[ "$(rg -c '^public fun ' <<<"$package_admin_production")" != 6 ]] \
  || [[ "$(rg -c '^public fun (wrap|authorize_upgrade|restrict_to_additive|restrict_to_dependency_only|commit_upgrade|activate_package_version)\(' <<<"$package_admin_production")" != 6 ]] \
  || rg -n '^public\(package\) fun ' <<<"$package_admin_production" \
  || [[ "$(rg -o '_: &AdminWitness' <<<"$package_admin_production" | wc -l)" != 4 ]] \
  || ! rg -U -q \
    'public fun wrap\(publisher: Publisher, upgrade_cap: UpgradeCap, ctx: &mut TxContext\)' \
    sources/package_admin.move \
  || ! rg -U -q \
    'public fun authorize_upgrade\(\s*self: &mut PackageAdmin,\s*package_version: &PackageVersion,\s*_: &AdminWitness,\s*digest: vector<u8>,\s*\): UpgradeTicket' \
    sources/package_admin.move \
  || ! rg -U -q \
    'public fun commit_upgrade\(\s*self: &mut PackageAdmin,\s*package_version: &PackageVersion,\s*receipt: UpgradeReceipt,\s*\)' \
    sources/package_admin.move \
  || ! rg -U -q \
    'public fun activate_package_version\(\s*package_version: &mut PackageVersion,\s*_: &AdminWitness,\s*\)' \
    sources/package_admin.move; then
  echo 'package_admin.move must expose only validated capability wrapping, gated native administration, and explicit checked activation.' >&2
  failures=$((failures + 1))
fi

if ! rg -Fq 'publisher.from_package<BLAST>() && publisher.from_module<BLAST>()' \
    sources/package_admin.move \
  || ! rg -Fq 'package_id.to_address() == type_name::original_id<BLAST>()' \
    sources/package_admin.move \
  || ! rg -Fq 'digest.length() == constants::package_digest_length!()' \
    sources/package_admin.move \
  || ! rg -Fq 'self.upgrade_cap.authorize(policy, digest)' sources/package_admin.move \
  || ! rg -Fq 'self.upgrade_cap.commit(receipt)' sources/package_admin.move \
  || ! rg -Fq 'self.upgrade_cap.only_additive_upgrades();' sources/package_admin.move \
  || ! rg -Fq 'self.upgrade_cap.only_dep_upgrades();' sources/package_admin.move \
  || ! rg -Fq 'new_policy > previous_policy' sources/package_admin.move \
  || rg -n '\bpackage::(version|only_(additive|dep)_upgrades)\(' \
    <<<"$package_admin_production" \
  || rg -n 'admin_authorization|governance_cutover' sources/package_admin.move \
  || rg -U -n '^(public|entry|public\(package\)) fun [^(]+\([^)]*\): (&)?(Publisher|UpgradeCap)' \
    <<<"$package_admin_production" \
  || rg -n 'transfer::(public_)?transfer|burn_publisher|make_immutable' \
    <<<"$package_admin_production" \
  || rg -n '\b(ProtocolAuthority|SuperAdminCap|AdminCap)\b' \
    <<<"$package_admin_production"; then
  echo 'Package administration must retain both validated capabilities, use receiver syntax, narrow policy only, and stay free of premature governance state.' >&2
  failures=$((failures + 1))
fi

package_admin_creation_event="$(sed -n \
  '/^public struct PackageAdminCreated/,/^}/p' \
  sources/lib/events.move)"
package_admin_mutation_event_payloads="$(sed -n \
  -e '/^public struct UpgradeAuthorized/,/^}/p' \
  -e '/^public struct UpgradeCommitted/,/^}/p' \
  -e '/^public struct UpgradePolicyRestricted/,/^}/p' \
  sources/lib/events.move)"

if [[ -z "$package_admin_creation_event" || -z "$package_admin_mutation_event_payloads" ]] \
  || [[ "$(rg -c '^[[:space:]]+(package_admin_id|publisher_id|upgrade_cap_id|package_id|package_version|policy):' <<<"$package_admin_creation_event")" != 6 ]] \
  || rg -n 'PackageAdminAuthorizationDisabled|admin_authorization_enabled' \
    sources/lib/events.move \
  || rg -n '\b(manager_id|upgrade_cap_id|sequence|schema_version|action_tag|nonce)\b' \
    <<<"$package_admin_mutation_event_payloads"; then
  echo 'Package-administration mutations must use typed facts without repeated custody, ordering, or schema fields.' >&2
  failures=$((failures + 1))
fi

expected_failure_without_location="$(awk '
  /#\[expected_failure/ {
    attribute = $0;
    while (attribute !~ /\]/ && (getline continuation) > 0) {
      attribute = attribute " " continuation;
    }
    if (attribute !~ /location = /) {
      print FILENAME ": " attribute;
    }
  }
' tests/*.move)"

if [[ -n "$expected_failure_without_location" ]]; then
  printf '%s\n' "$expected_failure_without_location"
  echo 'Every expected_failure must pin an explicit abort location.' >&2
  failures=$((failures + 1))
fi

expected_failure_without_named_abort="$(awk '
  /#\[expected_failure/ {
    attribute = $0;
    while (attribute !~ /\]/ && (getline continuation) > 0) {
      attribute = attribute " " continuation;
    }
    if (attribute !~ /abort_code = ([[:alnum:]_]+::)+E[[:alnum:]_]+/) {
      print FILENAME ": " attribute;
    }
  }
' tests/*.move)"

if [[ -n "$expected_failure_without_named_abort" ]]; then
  printf '%s\n' "$expected_failure_without_named_abort"
  echo 'Every expected_failure must use a qualified named error constant, never a numeric or bare failure.' >&2
  failures=$((failures + 1))
fi

for test_file in tests/*.move; do
  tests_marker_count="$(rg -c '^// === Tests ===$' "$test_file" || true)"
  helpers_marker_count="$(rg -c '^// === Private Test Helpers ===$' "$test_file" || true)"
  tests_marker_count="${tests_marker_count:-0}"
  helpers_marker_count="${helpers_marker_count:-0}"

  if [[ "$tests_marker_count" != 1 ]]; then
    echo "$test_file: exactly one '// === Tests ===' marker is required." >&2
    failures=$((failures + 1))
    continue
  fi

  scenario_backed=0
  if rg -q '\bScenario\b' "$test_file"; then
    scenario_backed=1
  fi

  if [[ "$helpers_marker_count" -gt 1 ]] \
    || [[ "$scenario_backed" == 1 && "$helpers_marker_count" != 1 ]]; then
    echo "$test_file: exactly one '// === Private Test Helpers ===' marker is required for scenario-backed suites and it may never be duplicated." >&2
    failures=$((failures + 1))
    continue
  fi

  tests_marker_line="$(rg -n '^// === Tests ===$' "$test_file" | cut -d: -f1)"
  if [[ "$helpers_marker_count" == 1 ]]; then
    helpers_marker_line="$(rg -n '^// === Private Test Helpers ===$' "$test_file" \
      | cut -d: -f1)"
    if ((helpers_marker_line <= tests_marker_line)); then
      echo "$test_file: the Tests section must precede Private Test Helpers." >&2
      failures=$((failures + 1))
      continue
    fi
    test_bodies="$(sed -n "${tests_marker_line},${helpers_marker_line}p" "$test_file")"
  else
    test_bodies="$(sed -n "${tests_marker_line},\$p" "$test_file")"
  fi

  if ! rg -q '^[[:space:]]*#\[test\]' <<<"$test_bodies"; then
    echo "$test_file: the extracted Tests section contains no standalone '#[test]' attribute lines." >&2
    failures=$((failures + 1))
    continue
  fi

  if rg -n \
    'test_scenario::|\.scenario\b|\.ctx\(|\.next_tx\(|take_from_sender|take_shared|return_to_sender|return_shared|has_most_recent_for_sender|let [A-Za-z0-9_]*Fixture|\.extract\(|\.fill\(|\.swap\(|\.borrow\(|\.borrow_mut\(|option::(borrow|borrow_mut|extract|fill|swap)\(' \
    <<<"$test_bodies"; then
    echo "$test_file: test bodies must reach state only through fixture fields and helpers, never scenario plumbing, fixture destructuring, or receiver- or module-style Option internals." >&2
    failures=$((failures + 1))
  fi

  if [[ "$scenario_backed" == 0 ]]; then
    continue
  fi

  fixture_types="$(rg -o '^public struct ([A-Za-z0-9]*Fixture)\b' -r '$1' "$test_file" \
    | sort -u || true)"

  if [[ -z "$fixture_types" ]]; then
    echo "$test_file: scenario-backed suites need at least one focused '*Fixture' hot-potato type." >&2
    failures=$((failures + 1))
    continue
  fi

  while IFS= read -r fixture_type; do
    fixture_struct="$(awk -v type="$fixture_type" '
      $0 ~ "^public struct " type "([^A-Za-z0-9_]|$)" { collecting = 1 }
      collecting { print }
      collecting && /^}/ { exit }
    ' "$test_file")"
    fixture_header="$(printf '%s\n' "$fixture_struct" | sed '/{/q')"

    if [[ -z "$fixture_struct" ]]; then
      echo "$test_file: ${fixture_type} declaration could not be extracted." >&2
      failures=$((failures + 1))
      continue
    fi
    if rg -q '\bhas\b' <<<"$fixture_header"; then
      echo "$test_file: fixtures must stay ability-free hot potatoes." >&2
      failures=$((failures + 1))
    fi
    if ! rg -q 'scenario: Scenario,' <<<"$fixture_struct"; then
      echo "$test_file: ${fixture_type} must own its Scenario as a direct field." >&2
      failures=$((failures + 1))
    fi
    if ! rg -q "^fun start[a-z_0-9]*\(.*\): ${fixture_type} \{" "$test_file"; then
      echo "$test_file: ${fixture_type} needs a dedicated start helper returning it." >&2
      failures=$((failures + 1))
    fi
    if ! rg -U -q \
      "(^|\n)fun [a-z_0-9]*end\(self: ${fixture_type}\) \{\s*destroy\(self\);\s*\}" \
      "$test_file"; then
      echo "$test_file: ${fixture_type} needs one consuming end helper that destroys it." >&2
      failures=$((failures + 1))
    fi
  done <<<"$fixture_types"

  transaction_macro_pattern='^macro fun ([a-z0-9_]+_)?(run|next_tx(_expecting_events)?)\('
  if ! rg -q "$transaction_macro_pattern" "$test_file"; then
    echo "$test_file: scenario-backed suites need a receiver-style run or next_tx transaction macro." >&2
    failures=$((failures + 1))
  fi

  transaction_macro_lines="$(rg -n "$transaction_macro_pattern" "$test_file" \
    | cut -d: -f1 || true)"
  while IFS= read -r macro_line; do
    [[ -z "$macro_line" ]] && continue

    macro_signature="$(awk -v start="$macro_line" \
      'NR >= start { print; if (/\{/) exit }' "$test_file")"
    macro_declaration="$(awk -v start="$macro_line" \
      'NR >= start { print; if (NR > start && /^}/) exit }' "$test_file")"
    first_parameter="$(rg -o '\$[a-z_]+: [^,)]*' <<<"$macro_signature" | head -1)"
    macro_fixture_type="$(rg -o '^\$fixture: &mut ([A-Za-z0-9]*Fixture)$' -r '$1' \
      <<<"$first_parameter" || true)"
    closure_parameter_count="$(rg -c ': \|' <<<"$macro_signature" || true)"
    fixture_type_mention_count="$(rg -o 'Fixture' <<<"$macro_signature" | wc -l)"

    if [[ -z "$macro_fixture_type" ]]; then
      echo "$test_file:${macro_line}: a transaction macro must take one named &mut fixture handle first." >&2
      failures=$((failures + 1))
      continue
    fi
    if [[ "${closure_parameter_count:-0}" != 1 ]] \
      || ! rg -q "^[[:space:]]*\\\$fn: \\|&mut ${macro_fixture_type}\\|,?$" \
        <<<"$macro_signature" \
      || [[ "$fixture_type_mention_count" != 2 ]]; then
      echo "$test_file:${macro_line}: a transaction macro needs exactly one |&mut ${macro_fixture_type}| closure and no extra fixture or closure values." >&2
      failures=$((failures + 1))
      continue
    fi
    if ! rg -q '\$fn\(fixture\)' <<<"$macro_declaration"; then
      echo "$test_file:${macro_line}: a transaction macro must invoke its closure with the fixture handle." >&2
      failures=$((failures + 1))
    fi
  done <<<"$transaction_macro_lines"
done

if rg -n 'AdminFixture|scenario: Option<' tests \
  || rg -n '\|[A-Za-z0-9_&: <>,]*,[[:space:]]*_' tests; then
  echo 'Legacy fixture patterns are prohibited: no AdminFixture, no option-backed scenario, and no positional closure parameter lists with underscore placeholders.' >&2
  failures=$((failures + 1))
fi

if rg -n '\b(Coin|Balance|UID|TxContext|transfer::|event::|object::)\b' sources/curve.move \
  || rg -n '^(public|entry) fun ' sources/curve.move \
  || [[ "$(rg -c '^public\(package\) fun (cap_buy_quote_input|quote_buy|quote_sell)\(' sources/curve.move)" != 3 ]]; then
  echo 'curve.move must remain a pure package-only numeric quote module.' >&2
  failures=$((failures + 1))
fi

if [[ "$(rg -c '^[[:space:]]+quote_fee_bps: Bps,' sources/curve.move)" != 3 ]] \
  || [[ "$(rg -c '^[[:space:]]+meme_fee_bps: Bps,' sources/curve.move)" != 2 ]] \
  || [[ "$(rg -c '^[[:space:]]+max_burn_bps: Bps,' sources/curve.move)" != 1 ]] \
  || rg -n 'trade_fee_bps|fee_asset|fee_mode' sources/curve.move; then
  echo 'Each curve quote must use independent quote/meme rates; zero rates encode fee-asset choice.' >&2
  failures=$((failures + 1))
fi

fees_production="$(sed '/^\/\/ === Test-Only Functions ===/,$d' sources/fees.move)"

if rg -n '\b(UID|key|transfer::|XClaim|ed25519|recipient|launch_id)\b' \
  <<<"$fees_production" \
  || rg -n 'fee_balance_overflow|std::u64::max_value|max_balance' <<<"$fees_production" \
  || [[ "$(rg -c '^[[:space:]]+(protocol|creator)_(meme|quote): Balance<' sources/fees.move)" != 4 ]] \
  || [[ "$(rg -c '^public\(package\) fun (new|accrue|totals|accrue_protocol_fees|claim_creator_fees|claim_protocol_fees)' sources/fees.move)" != 6 ]]; then
  echo 'fees.move must remain an embedded supply-conserved four-balance ledger with only its approved package seam.' >&2
  failures=$((failures + 1))
fi

if rg -n '^(public|entry) fun ' <<<"$fees_production" \
  || rg -n 'set_creator_fee_split|sui::event|events::' <<<"$fees_production" \
  || [[ "$(rg -c '^[[:space:]]+self: &mut FeeLedger<Meme, Quote>,' sources/fees.move)" != 4 ]] \
  || ! rg -q '^[[:space:]]+protocol_fee_share_bps: Bps,' sources/fees.move \
  || ! rg -q '^[[:space:]]+_: &CreatorCap<Meme>,' sources/fees.move \
  || ! rg -q '^[[:space:]]+_: &AdminWitness,' sources/fees.move; then
  echo 'Fee state is package-only, uses the live protocol split, and is evented by its enclosing launch operation.' >&2
  failures=$((failures + 1))
fi

if ! rg -U -q 'macro public\(package\) fun max_launch_fee_bps\(\): u64 \{\s*1_000\s*\}' \
  sources/lib/constants.move \
  || rg -n 'protocol_trade_fee_share_bps' sources; then
  echo 'The fee-rate ceiling is constant, while the protocol share must not be hard-coded.' >&2
  failures=$((failures + 1))
fi

package_version_production="$(sed '/^\/\/ === Test-Only Functions ===/,$d' sources/package_version.move)"

if [[ ! -f sources/package_version.move ]] \
  || ! rg -U -q \
    'public struct PackageVersion has key \{\s*id: UID,\s*version: u64,\s*\}' \
    sources/package_version.move \
  || ! rg -q '^const PACKAGE_VERSION: u64 = 1;$' sources/package_version.move \
  || rg -n 'package_version|PACKAGE_VERSION' sources/lib/constants.move \
  || [[ "$(rg -c '^public\(package\) fun (assert_current|activate)\(' <<<"$package_version_production")" != 2 ]] \
  || rg -n '^(public|entry|public entry) fun ' <<<"$package_version_production" \
  || ! rg -Fq 'self.version == PACKAGE_VERSION' sources/package_version.move \
  || ! rg -Fq 'new_version == PACKAGE_VERSION' sources/package_version.move \
  || ! rg -Fq 'version: PACKAGE_VERSION' sources/package_version.move \
  || ! rg -Fq '.checked_add(1)' sources/package_version.move \
  || ! rg -Fq 'events::package_version_advanced(previous_version, new_version);' sources/package_version.move; then
  echo 'package_version.move must own the one shared cutover and exact consecutive activation.' >&2
  failures=$((failures + 1))
fi

runtime_config_production="$(sed '/^\/\/ === Test-Only Functions ===/,$d' sources/runtime_config.move)"

if [[ ! -f sources/runtime_config.move ]] \
  || ! rg -U -q \
    'public struct RuntimeConfig has key \{\s*id: UID,\s*x_claim_signer_public_key: vector<u8>,\s*protocol_fee_share_bps: Bps,\s*\}' \
    sources/runtime_config.move \
  || rg -n '\b(AdminCap|ProtocolAuthority|LaunchConfig|VecMap|VecSet|TypeName)\b' \
    <<<"$runtime_config_production" \
  || rg -n '\b(sequence|schema_version|action_tag|nonce)\b' \
    <<<"$runtime_config_production" \
  || [[ "$(rg -c '^[[:space:]]+_: &AdminWitness,' sources/runtime_config.move)" != 3 ]] \
  || [[ "$(rg -c '^public fun (set_x_claim_signer|revoke_x_claim_signer|set_protocol_fee_share)\(' <<<"$runtime_config_production")" != 3 ]] \
  || [[ "$(rg -c '^[[:space:]]+package_version: &PackageVersion,' sources/runtime_config.move)" != 3 ]] \
  || [[ "$(rg -c '^public\(package\) fun (assert_x_claim_active|verify_x_claim_signature|protocol_fee_share_bps)\(' <<<"$runtime_config_production")" != 3 ]]; then
  echo 'runtime_config.move must own only version-gated X signer and protocol fee share state.' >&2
  failures=$((failures + 1))
fi

if ! rg -Fq 'protocol_fee_share_bps != self.protocol_fee_share_bps.value()' \
  sources/runtime_config.move \
  || ! rg -Fq 'self.protocol_fee_share_bps = bps::new(protocol_fee_share_bps);' \
    sources/runtime_config.move \
  || ! rg -Fq 'signer_public_key.length() == constants::ed25519_public_key_length!()' \
    sources/runtime_config.move \
  || ! rg -q 'self.x_claim_signer_public_key != signer_public_key' \
    sources/runtime_config.move \
  || ! rg -U -q \
    'x_claim_signer_public_key: vector\[\],\s*protocol_fee_share_bps: bps::new\(0\),\s*\}' \
    sources/runtime_config.move; then
  echo 'Runtime configuration must start disabled and at zero, with exact signer and fee-share guards.' >&2
  failures=$((failures + 1))
fi

runtime_config_event_payloads="$(sed -n \
  -e '/^public struct RuntimeConfigCreated/,/^}/p' \
  -e '/^public struct ProtocolFeeShareChanged/,/^}/p' \
  -e '/^public struct XClaimSignerSet/,/^}/p' \
  -e '/^public struct XClaimSignerRevoked/,/^}/p' \
  sources/lib/events.move)"

runtime_config_mutation_event_payloads="$(sed -n \
  -e '/^public struct ProtocolFeeShareChanged/,/^}/p' \
  -e '/^public struct XClaimSignerSet/,/^}/p' \
  -e '/^public struct XClaimSignerRevoked/,/^}/p' \
  sources/lib/events.move)"

if [[ -z "$runtime_config_event_payloads" ]] \
  || rg -n '\b(sequence|schema_version|action_tag|nonce)\b' \
    <<<"$runtime_config_event_payloads" \
  || rg -n '\bruntime_config_id\b' <<<"$runtime_config_mutation_event_payloads"; then
  echo 'Runtime-config mutations must use typed replay facts without repeated singleton, ordering, or schema fields.' >&2
  failures=$((failures + 1))
fi

if [[ -f sources/x_claim_config.move || -f sources/trade_fee_config.move ]] \
  || rg -n '\b(XClaimConfig|TradeFeeConfig)\b' sources tests \
  || [[ "$(rg -o 'transfer::share_object' sources --glob '*.move' --glob '!launch.move' | wc -l)" != 5 ]]; then
  echo 'Core must keep exactly five protocol-wide shared singletons, including the one package cutover.' >&2
  failures=$((failures + 1))
fi

launch_config_production="$(sed '/^\/\/ === Test-Only Functions ===/,$d' sources/launch_config.move)"

if [[ ! -f sources/launch_config.move ]] \
  || ! rg -U -q \
    'public struct LaunchConfig has key \{\s*id: UID,\s*quotes: VecMap<TypeName, QuoteParameters>,\s*quote_fee_bps: Bps,\s*meme_fee_bps: Bps,\s*quote_migration_fee_bps: Bps,\s*protocol_meme_graduation_fee_bps: Bps,\s*meme_liquidity_provision_bps: Bps,\s*migration_witnesses: VecSet<TypeName>,\s*\}' \
    sources/launch_config.move \
  || ! rg -U -q \
    'public struct QuoteParameters has copy, drop, store \{\s*virtual_quote: u64,\s*migration_quote_target: u64,\s*\}' \
    sources/launch_config.move \
  || rg -n '\b(AdminCap|ProtocolAuthority)\b' <<<"$launch_config_production" \
  || rg -n '\b(sequence|schema_version|action_tag|nonce)\b' <<<"$launch_config_production" \
  || [[ "$(rg -o '_: &AdminWitness' <<<"$launch_config_production" | wc -l)" != 6 ]] \
  || [[ "$(rg -c '^public fun ' <<<"$launch_config_production")" != 6 ]] \
  || [[ "$(rg -c '^public fun (allow_quote|disallow_quote|allow_migration_witness|disallow_migration_witness)<' <<<"$launch_config_production")" != 4 ]] \
  || [[ "$(rg -c '^public fun set_graduation_defaults\(' <<<"$launch_config_production")" != 1 ]] \
  || ! rg -U -q \
    'public fun set_trade_fees\(\s*self: &mut LaunchConfig,\s*package_version: &PackageVersion,\s*_: &AdminWitness,\s*quote_fee_bps: u64,\s*meme_fee_bps: u64,\s*\)' \
    sources/launch_config.move \
  || ! rg -U -q \
    'public fun set_graduation_defaults\(\s*self: &mut LaunchConfig,\s*package_version: &PackageVersion,\s*_: &AdminWitness,\s*quote_migration_fee_bps: u64,\s*protocol_meme_graduation_fee_bps: u64,\s*meme_liquidity_provision_bps: u64,\s*\)' \
    sources/launch_config.move \
  || [[ "$(rg -c '^public\(package\) fun ' <<<"$launch_config_production")" != 1 ]] \
  || ! rg -U -q \
    'public\(package\) fun snapshot_for_launch<Quote, MigrationWitness: drop>\(\s*self: &LaunchConfig,\s*\): \(u64, u64, Bps, Bps, Bps, Bps, Bps, TypeName\)' \
    sources/launch_config.move; then
  echo 'launch_config.move must own only bounded future-launch policy and its AdminWitness-gated mutations.' >&2
  failures=$((failures + 1))
fi

if ! rg -U -q 'macro public\(package\) fun max_quote_assets\(\): u64 \{\s*16\s*\}' \
  sources/lib/constants.move \
  || ! rg -U -q 'macro public\(package\) fun max_migration_witnesses\(\): u64 \{\s*16\s*\}' \
    sources/lib/constants.move \
  || ! rg -U -q 'macro public\(package\) fun max_quote_migration_fee_bps\(\): u64 \{\s*500\s*\}' \
    sources/lib/constants.move \
  || ! rg -U -q 'macro public\(package\) fun max_protocol_meme_graduation_fee_bps\(\): u64 \{\s*1_000\s*\}' \
  sources/lib/constants.move \
  || ! rg -U -q 'macro public\(package\) fun max_meme_liquidity_provision_bps\(\): u64 \{\s*9_999\s*\}' \
  sources/lib/constants.move \
  || ! rg -Fq 'type_name::with_original_ids<Quote>()' sources/launch_config.move \
  || ! rg -Fq 'type_name::with_original_ids<MigrationWitness>()' sources/launch_config.move \
  || ! rg -Fq '!migration_witness.is_primitive()' sources/launch_config.move \
  || ! rg -Fq 'virtual_quote > 0' sources/launch_config.move \
  || ! rg -Fq 'quote_fee_bps <= constants::max_launch_fee_bps!()' sources/launch_config.move \
  || ! rg -Fq 'meme_fee_bps <= constants::max_launch_fee_bps!()' sources/launch_config.move \
  || ! rg -Fq 'self.quotes.length() < constants::max_quote_assets!()' \
    sources/launch_config.move \
  || ! rg -Fq 'self.migration_witnesses.length()' sources/launch_config.move \
  || ! rg -U -q \
    'quote_fee_bps: bps::new\(0\),\s*meme_fee_bps: bps::new\(0\),\s*quote_migration_fee_bps: bps::new\(0\),\s*protocol_meme_graduation_fee_bps: bps::new\(0\),\s*meme_liquidity_provision_bps: bps::new\(0\),\s*migration_witnesses: vec_set::empty\(\)' \
    sources/launch_config.move \
  || ! rg -U -q \
    'protocol_meme_graduation_fee_bps \+ meme_liquidity_provision_bps\s*< constants::basis_points_denominator!\(\)' \
    sources/launch_config.move \
  || ! rg -Fq 'self.meme_liquidity_provision_bps.value() > 0' sources/launch_config.move \
  || rg -n '\bCurrency<Quote>\b|coin_registry' <<<"$launch_config_production"; then
  echo 'Launch policy must use approved ceilings, original type identities, fixed bounds, zero defaults, and no Coin Registry dependency.' >&2
  failures=$((failures + 1))
fi

if ! rg -U -q \
    'events::launch_config_created\(\s*config_id,\s*constants::max_quote_assets!\(\),\s*constants::max_migration_witnesses!\(\),\s*config\.quote_fee_bps\.value\(\),\s*config\.meme_fee_bps\.value\(\),\s*config\.quote_migration_fee_bps\.value\(\),\s*config\.protocol_meme_graduation_fee_bps\.value\(\),\s*config\.meme_liquidity_provision_bps\.value\(\),\s*\);\s*transfer::share_object\(config\);' \
    sources/launch_config.move; then
  echo 'Launch-config initialization must emit the five stored defaults directly before sharing consumes the config.' >&2
  failures=$((failures + 1))
fi

launch_config_event_payloads="$(sed -n \
  -e '/^public struct LaunchConfigCreated/,/^}/p' \
  -e '/^public struct QuoteAllowed/,/^}/p' \
  -e '/^public struct QuoteParametersChanged/,/^}/p' \
  -e '/^public struct QuoteDisallowed/,/^}/p' \
  -e '/^public struct LaunchTradeFeesChanged/,/^}/p' \
  -e '/^public struct GraduationDefaultsChanged/,/^}/p' \
  -e '/^public struct MigrationWitnessAllowed/,/^}/p' \
  -e '/^public struct MigrationWitnessDisallowed/,/^}/p' \
  sources/lib/events.move)"

launch_config_mutation_event_payloads="$(sed -n \
  -e '/^public struct QuoteAllowed/,/^}/p' \
  -e '/^public struct QuoteParametersChanged/,/^}/p' \
  -e '/^public struct QuoteDisallowed/,/^}/p' \
  -e '/^public struct LaunchTradeFeesChanged/,/^}/p' \
  -e '/^public struct GraduationDefaultsChanged/,/^}/p' \
  -e '/^public struct MigrationWitnessAllowed/,/^}/p' \
  -e '/^public struct MigrationWitnessDisallowed/,/^}/p' \
  sources/lib/events.move)"

if [[ -z "$launch_config_event_payloads" ]] \
  || rg -n '\b(sequence|schema_version|action_tag|nonce)\b' \
    <<<"$launch_config_event_payloads" \
  || rg -n '\bconfig_id\b' <<<"$launch_config_mutation_event_payloads"; then
  echo 'Launch-config mutations must use typed replay facts without repeated singleton, ordering, or schema fields.' >&2
  failures=$((failures + 1))
fi

graduation_production="$(sed '/^\/\/ === Test-Only Functions ===/,$d' sources/graduation.move)"

if [[ ! -f sources/graduation.move ]] \
  || [[ "$(rg -c '^public\(package\) fun ' <<<"$graduation_production")" != 2 ]] \
  || ! rg -U -q \
    'public\(package\) fun partition_meme<Meme>\(\s*mut meme: Balance<Meme>,\s*protocol_meme_graduation_fee_bps: Bps,\s*meme_liquidity_provision_bps: Bps,\s*\): \(Balance<Meme>, Balance<Meme>, Balance<Meme>\)' \
    sources/graduation.move \
  || ! rg -U -q \
    'public\(package\) fun partition_quote<Quote>\(\s*mut quote: Balance<Quote>,\s*quote_migration_fee_bps: Bps,\s*\): \(Balance<Quote>, Balance<Quote>\)' \
    sources/graduation.move \
  || rg -n '^public struct|^public fun|^entry fun|^public entry fun' \
    <<<"$graduation_production" \
  || rg -n '\b(events::|transfer::|Coin<|TxContext|UID|ID)\b' \
    <<<"$graduation_production" \
  || rg -n '\b(derive_outcome|opening_valuation|curve_terminal_valuation|dex_opening_valuation)\b' \
    <<<"$graduation_production"; then
  echo 'graduation.move must expose only package-level balance partitions without forecasts, state, events, transfers, or venue dependencies.' >&2
  failures=$((failures + 1))
fi

if ! rg -Fq 'protocol_meme_graduation_fee_bps.apply_up(initial_supply)' sources/graduation.move \
  || ! rg -Fq 'meme_liquidity_provision_bps.apply_down(initial_supply)' sources/graduation.move \
  || ! rg -Fq 'quote_migration_fee_bps.apply_up(quote.value())' sources/graduation.move \
  || ! rg -Fq 'provision_amount > 0' sources/graduation.move \
  || ! rg -Fq 'protocol_meme_fee_amount + provision_amount < initial_supply' \
    sources/graduation.move \
  || [[ "$(rg -c '\.split\(' sources/graduation.move)" != 3 ]]; then
  echo 'Graduation partitions must preserve the accepted ceil/floor, positive-bucket, and balance-custody rules.' >&2
  failures=$((failures + 1))
fi

if [[ ! -f sources/launch_ticket.move ]] \
  || ! rg -U -q \
    'public struct LaunchTicket<phantom Meme> has key, store \{\s*id: UID,\s*meme: Balance<Meme>,\s*metadata_cap: MetadataCap<Meme>,\s*creator_authority: CreatorAuthority<Meme>,\s*sell_burn_bps: Bps,\s*\}' \
    sources/launch_ticket.move \
  || [[ "$(rg -c '^public fun new<Meme: drop>\(' sources/launch_ticket.move)" != 1 ]] \
  || [[ "$(rg -c 'creator_identity: CreatorIdentity' sources/launch_ticket.move)" != 1 ]] \
  || rg -n '^public fun new_(address|x)<Meme: drop>\(' sources/launch_ticket.move \
  || ! rg -U -q \
    'public\(package\) fun destroy<Meme>\(\s*self: LaunchTicket<Meme>,\s*\): \(\s*Balance<Meme>,\s*MetadataCap<Meme>,\s*CreatorAuthority<Meme>,\s*Bps,\s*\)' \
    sources/launch_ticket.move \
  || ! rg -q 'coin_registry::new_currency_with_otw' sources/launch_ticket.move \
  || ! rg -Fq 'let meme = treasury_cap.mint_balance(initial_supply);' sources/launch_ticket.move \
  || ! rg -U -q \
    'if \(burnable\) \{\s*initializer\.make_supply_burn_only\(treasury_cap\);\s*\} else \{\s*initializer\.make_supply_fixed\(treasury_cap\);\s*\};\s*let metadata_cap = initializer\.finalize\(ctx\);' \
    sources/launch_ticket.move \
  || ! rg -Fq 'let initial_supply = constants::meme_total_supply_atomic_units!();' sources/launch_ticket.move \
  || ! rg -Fq 'let sell_burn_bps = bps::new(sell_burn_bps);' sources/launch_ticket.move \
  || ! rg -Fq 'constants::meme_decimals!(),' sources/launch_ticket.move \
  || rg -n '\bdecimals: u8\b' sources/launch_ticket.move \
  || [[ "$(rg -c '^[[:space:]]+sell_burn_bps: Bps,' <<<"$(sed -n '/^public struct LaunchTicket/,/^}/p' sources/launch_ticket.move)")" != 1 ]] \
  || rg -n '^[[:space:]]+burnable: bool,' <<<"$(sed -n '/^public struct LaunchTicket/,/^}/p' sources/launch_ticket.move)" \
  || rg -n '\bTreasuryCap<Meme>\b|treasury_cap:' sources/launch_ticket.move \
  || rg -n '\b(make_regulated|DenyCap|CoinMetadata)\b|coin_registry::new_currency\(' \
    sources/launch_ticket.move \
  || rg -n '\btransfer::|^(entry fun|public entry fun)' sources/launch_ticket.move; then
  echo 'launch_ticket.move must mint fixed inventory, finalize native supply mode, retain only sell burn, and return composable custody.' >&2
  failures=$((failures + 1))
fi

if [[ "$(rg -o '\.mint_balance\(' sources | wc -l)" != 1 ]] \
  || rg -n '\bcoin::mint(_balance)?\(' sources \
  || rg -n '\.mint_balance\(' sources --glob '!launch_ticket.move'; then
  echo 'The OTW launch-ticket constructor must remain the only Meme mint site in the package.' >&2
  failures=$((failures + 1))
fi

if ! rg -U -q 'macro public\(package\) fun meme_decimals\(\): u8 \{\s*9\s*\}' \
    sources/lib/constants.move \
  || ! rg -U -q 'macro public\(package\) fun meme_total_supply_atomic_units\(\): u64 \{\s*1_000_000_000__000_000_000\s*\}' \
    sources/lib/constants.move; then
  echo 'Generated Meme supply must remain exactly one billion coins at the canonical nine-decimal precision.' >&2
  failures=$((failures + 1))
fi

launch_ticket_event_payload="$(sed -n \
  -e '/^public struct LaunchTicketCreated/,/^}/p' \
  sources/lib/events.move)"

if [[ -z "$launch_ticket_event_payload" ]] \
  || ! rg -q '^[[:space:]]+initial_supply: u64,' <<<"$launch_ticket_event_payload" \
  || rg -n '\b(treasury_cap_id|sequence|schema_version|action_tag|nonce)\b' \
    <<<"$launch_ticket_event_payload"; then
  echo 'Launch-ticket creation must record minted supply, omit its consumed cap, and avoid duplicate ordering or schema fields.' >&2
  failures=$((failures + 1))
fi

launch_production="$(sed '/^\/\/ === Test-Only Functions ===/,$d' sources/launch.move)"

if [[ ! -f sources/launch.move ]] \
  || ! rg -U -q \
    'public struct Launch<phantom Meme, phantom Quote> has key \{\s*id: UID,\s*lifecycle: Lifecycle,\s*sell_burn_bps: Bps,\s*virtual_quote: u64,\s*migration_quote_target: u64,\s*quote_fee_bps: Bps,\s*meme_fee_bps: Bps,\s*quote_migration_fee_bps: Bps,\s*protocol_meme_graduation_fee_bps: Bps,\s*meme_liquidity_provision_bps: Bps,\s*migration_witness: TypeName,\s*meme_reserve: Balance<Meme>,\s*real_quote_reserve: Balance<Quote>,\s*pending_burn: Balance<Meme>,\s*protocol_meme_graduation_fee: Balance<Meme>,\s*meme_liquidity_provision: Balance<Meme>,\s*fee_ledger: FeeLedger<Meme, Quote>,\s*metadata_cap: Option<MetadataCap<Meme>>,\s*creator_authority: Option<CreatorAuthority<Meme>>,\s*\}' \
    sources/launch.move \
  || [[ "$(rg -c '^public fun ' <<<"$launch_production")" != 9 ]] \
  || [[ "$(rg -c '^public fun (new|share|claim_creator_cap|buy|sell|claim_creator_fees|claim_protocol_fees|migrate|redeem_migration)(<|\()' <<<"$launch_production")" != 9 ]] \
  || ! rg -U -q \
    'public fun new<Meme, Quote, MigrationWitness: drop>\(\s*ticket: LaunchTicket<Meme>,\s*package_version: &PackageVersion,\s*config: &LaunchConfig,\s*ctx: &mut TxContext,\s*\): Launch<Meme, Quote>' \
    sources/launch.move \
  || ! rg -U -q \
    'public fun share<Meme, Quote>\(self: Launch<Meme, Quote>\)' \
    sources/launch.move \
  || ! rg -U -q \
    'public fun claim_creator_cap<Meme, Quote>\(\s*self: &mut Launch<Meme, Quote>,\s*package_version: &PackageVersion,\s*config: &RuntimeConfig,\s*x_attestation: Option<vector<u8>>,\s*clock: &Clock,\s*ctx: &mut TxContext,\s*\): \(CreatorCap<Meme>, MetadataCap<Meme>\)' \
    sources/launch.move \
  || ! rg -U -q \
    'public fun migrate<Meme, Quote, MigrationWitness: drop>\(\s*self: &mut Launch<Meme, Quote>,\s*package_version: &PackageVersion,\s*currency: &mut Currency<Meme>,\s*ctx: &mut TxContext,\s*\): MigrationPayload<Meme, Quote, MigrationWitness>' \
    sources/launch.move \
  || ! rg -U -q \
    'public fun redeem_migration<Meme, Quote, MigrationWitness: drop>\(\s*payload: MigrationPayload<Meme, Quote, MigrationWitness>,\s*_: MigrationWitness,\s*\): \(Balance<Meme>, Balance<Quote>\)' \
    sources/launch.move \
  || rg -n '\b(creation_fee|max_burn_bps|route|venue|Display|valuation|expected_release)\b' \
    <<<"$launch_production" \
  || [[ "$(rg -o '\btransfer::' <<<"$launch_production" | wc -l)" != 2 ]]; then
  echo 'launch.move must own versioned key-only custody, trading, claims, and the witness-bound terminal handoff.' >&2
  failures=$((failures + 1))
fi

if ! rg -Fq 'config.snapshot_for_launch<Quote, MigrationWitness>()' sources/launch.move \
  || ! rg -Fq 'transfer::share_object(self);' sources/launch.move \
  || ! rg -Fq 'ticket.destroy();' sources/launch.move \
  || ! rg -Fq 'ticket.initial_supply() == constants::meme_total_supply_atomic_units!()' sources/launch.move \
  || ! rg -Fq 'type_name::with_original_ids<Meme>() != type_name::with_original_ids<Quote>()' sources/launch.move \
  || ! rg -Fq 'graduation::partition_meme(' sources/launch.move \
  || ! rg -Fq 'fee_ledger: fees::new(),' sources/launch.move \
  || ! rg -Fq 'real_quote_reserve: balance::zero(),' sources/launch.move \
  || ! rg -Fq 'pending_burn: balance::zero(),' sources/launch.move \
  || ! rg -Fq 'self.creator_authority.extract()' sources/launch.move \
  || ! rg -Fq 'self.metadata_cap.extract()' sources/launch.move \
  || rg -n '\bbps::new\(' sources/launch.move \
  || ! rg -Fq 'let burnable = currency.is_supply_burn_only();' sources/launch.move \
  || rg -n 'is_supply_fixed|supply_mode_mismatch' <<<"$launch_production" \
  || rg -n 'self\.burnable|^[[:space:]]+burnable: bool,' <<<"$launch_production" \
  || rg -n 'max_launch_fee_bps|invalid_(quote|meme)_fee_bps' sources/launch.move; then
  echo 'Launch construction must snapshot configured fees, consume reviewed seams, initialize zero balances, and remove both claim resources.' >&2
  failures=$((failures + 1))
fi

launch_created_event_payload="$(sed -n \
  -e '/^public struct LaunchCreated/,/^}/p' \
  sources/lib/events.move)"

if [[ -z "$launch_created_event_payload" ]] \
  || [[ "$(rg -c '^[[:space:]]+[a-z_]+:' <<<"$launch_created_event_payload")" != 25 ]] \
  || ! rg -q '^[[:space:]]+ticket_id: ID,' <<<"$launch_created_event_payload" \
  || ! rg -q '^[[:space:]]+metadata_cap_id: ID,' <<<"$launch_created_event_payload" \
  || [[ "$(rg -c '^[[:space:]]+(protocol|creator)_(meme|quote)_trade_fees: u64,' <<<"$launch_created_event_payload")" != 4 ]] \
  || rg -n '\b(burnable|state_version|supply_mode|sequence|schema_version|action_tag|nonce|valuation|expected_release)\b' \
    <<<"$launch_created_event_payload"; then
  echo 'LaunchCreated must expose source identity, primitive policy, named balances, and zero ledger totals without duplicated or derived state.' >&2
  failures=$((failures + 1))
fi

migrated_event_payload="$(sed -n \
  -e '/^public struct Migrated/,/^}/p' \
  sources/lib/events.move)"

if [[ -z "$migrated_event_payload" ]] \
  || ! rg -q '^[[:space:]]+native_supply_burned: bool,' <<<"$migrated_event_payload" \
  || rg -q '^[[:space:]]+burnable: bool,' <<<"$migrated_event_payload"; then
  echo 'Migrated must record the completed native burn action without a duplicate supply-mode field.' >&2
  failures=$((failures + 1))
fi

if rg -n '\bstate_version\b|launch_state_version' sources tests; then
  echo 'PackageVersion must remain the only operational version; Launch state and events must not add another one.' >&2
  failures=$((failures + 1))
fi

for gate_spec in 'acl:7:7' 'launch_config:6:6' 'runtime_config:3:3' 'package_admin:4:5' 'launch:7:7'; do
  IFS=: read -r gate_module expected_guards expected_parameters <<<"$gate_spec"
  actual_guards="$(rg -c '^[[:space:]]+package_version\.assert_current\(\);' "sources/${gate_module}.move" || true)"
  actual_parameters="$(rg -c '^[[:space:]]+package_version: &(mut )?PackageVersion,' "sources/${gate_module}.move" || true)"

  if [[ "${actual_guards:-0}" != "$expected_guards" ]] \
    || [[ "${actual_parameters:-0}" != "$expected_parameters" ]]; then
    echo "${gate_module}.move must keep PackageVersion on every accepted mutable shared-object operation." >&2
    failures=$((failures + 1))
  fi
done

if [[ "$(rg -c '^[[:space:]]+package_version\.assert_current\(\);' sources/launch.move)" != 7 ]]; then
  echo 'Launch construction and every Launch mutation must check the one PackageVersion before other work.' >&2
  failures=$((failures + 1))
fi

if rg -n \
  '\b(acl::(grant_admin|revoke_admin|destroy_admin_cap|begin_super_admin_transfer|cancel_super_admin_transfer|accept_super_admin_transfer|destroy_retired_super_admin_cap|sign_in)|runtime_config::(set_x_claim_signer|revoke_x_claim_signer|set_protocol_fee_share|assert_x_claim_active|verify_x_claim_signature|protocol_fee_share_bps)|launch_config::(allow_quote|disallow_quote|set_trade_fees|set_graduation_defaults|allow_migration_witness|disallow_migration_witness|snapshot_for_launch|allowed_quote_count_for_testing|allowed_migration_witness_count_for_testing)|launch::(share|migrate|redeem_migration)|creator_authority::(into_authority|creator|x_identity_hash|claim_creator_cap)|launch_ticket::destroy|fees::(accrue|claim_creator_fees|claim_protocol_fees)|package_admin::(authorize_upgrade|commit_upgrade|restrict_to_additive|restrict_to_dependency_only|publisher_id_for_testing|upgrade_cap_id_for_testing|package_id_for_testing|version_for_testing|policy_for_testing))(<[^>]+>)?\(' \
  sources tests; then
  echo 'Blast-owned receiver functions must use Move 2024 dot syntax.' >&2
  failures=$((failures + 1))
fi

if rg -n '^[[:space:]]+assert_super_admin\(' sources/acl.move \
  || rg -n '\bsui::tx_context::TxContext\b' sources tests; then
  echo 'Natural framework and private receivers must use implicit types and dot syntax.' >&2
  failures=$((failures + 1))
fi

if rg -n \
  'RuntimeConfig|ed25519|x_claim_signer|verify_x_claim|CreatorCap|issue_creator_cap' \
  sources/acl.move; then
  echo 'acl.move must own only protocol-admin membership and root rotation.' >&2
  failures=$((failures + 1))
fi

if ! rg -q '^public struct AdminWitness\(\) has drop;' sources/acl.move \
  || ! rg -q '^public fun sign_in\(' sources/acl.move; then
  echo 'acl.move must expose sign_in through an unforgeable drop-only AdminWitness.' >&2
  failures=$((failures + 1))
fi

if ! rg -q '^public fun grant_admin\(' sources/acl.move \
  || rg -n '\b(add_admin|AdminAdded|QuoteRemoved|MigrationWitnessRemoved)\b' sources tests \
  || rg -n '\b(active_quote_count_for_testing|migration_witness_count_for_testing)\b' sources tests; then
  echo 'Package interfaces must use grant/revoke authority and allow/disallow whitelist vocabulary.' >&2
  failures=$((failures + 1))
fi

if ! rg -q '^public fun destroy_admin_cap\(' sources/acl.move \
  || rg -n 'destroy_admin_cap_for_testing' sources tests; then
  echo 'AdminCap holders must use the production self-destruction path.' >&2
  failures=$((failures + 1))
fi

acl_mutation_event_payloads="$(sed -n \
  -e '/^public struct AdminGranted/,/^}/p' \
  -e '/^public struct AdminRevoked/,/^}/p' \
  -e '/^public struct AdminDestroyed/,/^}/p' \
  -e '/^public struct SuperAdminTransferStarted/,/^}/p' \
  -e '/^public struct SuperAdminTransferCancelled/,/^}/p' \
  -e '/^public struct SuperAdminTransferred/,/^}/p' \
  sources/lib/events.move)"

if [[ -z "$acl_mutation_event_payloads" ]] \
  || rg -n '\b(authority_id|current_super_admin_cap_id)\b' \
    <<<"$acl_mutation_event_payloads" \
  || ! rg -U -q \
    '(?s)let previous = authority\.pending_super_admin\.extract\(\);\s*events::super_admin_transfer_cancelled\(previous\.recipient\);.*authority\.pending_super_admin = option::some\(PendingSuperAdminTransfer.*events::super_admin_transfer_started\(' \
    sources/acl.move; then
  echo 'ACL mutations must omit repeated singleton ids and emit replacement cancellation before the new transfer starts.' >&2
  failures=$((failures + 1))
fi

if ! rg -q '^public struct CreatorCap<phantom Meme> has key, store' \
  sources/creator_authority.move; then
  echo 'creator_authority.move must own CreatorCap<Meme> construction.' >&2
  failures=$((failures + 1))
fi

if ! rg -U -q \
  'public enum CreatorIdentity has drop, store \{\s*Address\(address\),\s*X\(vector<u8>\),\s*\}' \
  sources/creator_authority.move \
  || ! rg -U -q \
    'public struct CreatorAuthority<phantom Meme> has store \{\s*identity: CreatorIdentity,\s*\}' \
    sources/creator_authority.move \
  || ! rg -U -q \
    'public fun new_address\(creator: address\): CreatorIdentity' \
    sources/creator_authority.move \
  || ! rg -U -q \
    'public fun new_x\(x_identity_hash: vector<u8>\): CreatorIdentity' \
    sources/creator_authority.move \
  || ! rg -U -q \
    'public\(package\) fun into_authority<Meme>\(\s*self: CreatorIdentity,\s*\): CreatorAuthority<Meme>' \
    sources/creator_authority.move \
  || rg -U -n 'public fun new_(address|x).*CreatorAuthority' \
    sources/creator_authority.move; then
  echo 'Public creator constructors must create freely composable identities; only package code may mint linear coin-typed creator authority.' >&2
  failures=$((failures + 1))
fi

creator_authority_production="$(sed '/^\/\/ === Test-Only Functions ===/,$d' sources/creator_authority.move)"

if rg -n '\bcreator_cap_claimed:[[:space:]]*bool|\bissue_creator_cap\b|\btransfer::' \
  <<<"$creator_authority_production" \
  || ! rg -U -q \
    '(?s)public\(package\) fun claim_creator_cap<Meme>\(\s*authority: CreatorAuthority<Meme>,.*\): CreatorCap<Meme> \{' \
    sources/creator_authority.move \
  || ! rg -U -q \
    'public struct CreatorCap<phantom Meme> has key, store \{\s*id: UID,\s*\}' \
    sources/creator_authority.move \
  || rg -n '\bMetadataCap\b|\bmetadata_cap\b' \
    sources/creator_authority.move; then
  echo 'Creator-authority claims must consume CreatorAuthority and return only CreatorCap without unrelated capability pass-through, a flag, wrapper, or transfer.' >&2
  failures=$((failures + 1))
fi

if rg -n 'schema_version|action_tag|nonce' sources/creator_authority.move; then
  echo 'The one-time X creator claim must not duplicate its fixed type and consumed marker.' >&2
  failures=$((failures + 1))
fi

if rg -l '^public struct RuntimeConfig has key' sources \
  | rg -v '^sources/runtime_config\.move$'; then
  echo 'RuntimeConfig is declared outside its owning module.' >&2
  failures=$((failures + 1))
fi

if rg -l '^public struct CreatorCap<phantom Meme> has key, store' sources \
  | rg -v '^sources/creator_authority\.move$'; then
  echo 'CreatorCap<Meme> is declared outside its owning module.' >&2
  failures=$((failures + 1))
fi

if ((failures != 0)); then
  exit 1
fi

echo 'Source module boundaries and Move style: OK'
