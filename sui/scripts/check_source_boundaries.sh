#!/usr/bin/env bash

set -euo pipefail

cd "$(dirname "$0")/.."

failures=0

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
  || [[ "$(rg -c '^public fun ' <<<"$package_admin_production")" != 5 ]] \
  || [[ "$(rg -c '^public fun (wrap|authorize_upgrade|restrict_to_additive|restrict_to_dependency_only|commit_upgrade)\(' <<<"$package_admin_production")" != 5 ]] \
  || rg -n '^public\(package\) fun ' <<<"$package_admin_production" \
  || [[ "$(rg -o '_: &AdminWitness' <<<"$package_admin_production" | wc -l)" != 3 ]] \
  || ! rg -U -q \
    'public fun wrap\(publisher: Publisher, upgrade_cap: UpgradeCap, ctx: &mut TxContext\)' \
    sources/package_admin.move \
  || ! rg -U -q \
    'public fun authorize_upgrade\(\s*self: &mut PackageAdmin,\s*_: &AdminWitness,\s*digest: vector<u8>,\s*\): UpgradeTicket' \
    sources/package_admin.move \
  || ! rg -U -q \
    'public fun commit_upgrade\(self: &mut PackageAdmin, receipt: UpgradeReceipt\)' \
    sources/package_admin.move; then
  echo 'package_admin.move must expose only validated capability wrapping, admin authorization/policy restriction, and receipt commit.' >&2
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
  || [[ "$(rg -c '^public\(package\) fun quote_(buy|sell)\(' sources/curve.move)" != 2 ]]; then
  echo 'curve.move must remain a pure package-only numeric quote module.' >&2
  failures=$((failures + 1))
fi

if [[ "$(rg -c '^[[:space:]]+quote_fee_bps: u64,' sources/curve.move)" != 2 ]] \
  || [[ "$(rg -c '^[[:space:]]+meme_fee_bps: u64,' sources/curve.move)" != 2 ]] \
  || rg -n 'trade_fee_bps|fee_asset|fee_mode' sources/curve.move; then
  echo 'Each curve quote must use independent quote/meme rates; zero rates encode fee-asset choice.' >&2
  failures=$((failures + 1))
fi

fees_production="$(sed '/^\/\/ === Test-Only Functions ===/,$d' sources/fees.move)"

if rg -n '\b(UID|key|transfer::|XClaim|ed25519|recipient|launch_id)\b' \
  <<<"$fees_production" \
  || rg -n 'fee_balance_overflow|std::u64::max_value|max_balance' <<<"$fees_production" \
  || [[ "$(rg -c '^[[:space:]]+(protocol|creator)_(meme|quote): Balance<' sources/fees.move)" != 4 ]] \
  || [[ "$(rg -c '^public\(package\) fun (new|accrue|claim_creator_fees|claim_protocol_fees)' sources/fees.move)" != 4 ]]; then
  echo 'fees.move must remain an embedded supply-conserved four-balance ledger with only its approved package seam.' >&2
  failures=$((failures + 1))
fi

if rg -n '^(public|entry) fun ' <<<"$fees_production" \
  || rg -n 'set_creator_fee_split|sui::event|events::' <<<"$fees_production" \
  || [[ "$(rg -c '^[[:space:]]+self: &mut FeeLedger<Meme, Quote>,' sources/fees.move)" != 3 ]] \
  || ! rg -q '^[[:space:]]+protocol_fee_share_bps: u64,' sources/fees.move \
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

runtime_config_production="$(sed '/^\/\/ === Test-Only Functions ===/,$d' sources/runtime_config.move)"

if [[ ! -f sources/runtime_config.move ]] \
  || ! rg -U -q \
    'public struct RuntimeConfig has key \{\s*id: UID,\s*x_claim_signer_public_key: vector<u8>,\s*protocol_fee_share_bps: u64,\s*\}' \
    sources/runtime_config.move \
  || rg -n '\b(AdminCap|ProtocolAuthority|LaunchConfig|VecMap|VecSet|TypeName)\b' \
    <<<"$runtime_config_production" \
  || rg -n '\b(sequence|schema_version|action_tag|nonce)\b' \
    <<<"$runtime_config_production" \
  || [[ "$(rg -c '^[[:space:]]+_: &AdminWitness,' sources/runtime_config.move)" != 3 ]] \
  || [[ "$(rg -c '^public fun (set_x_claim_signer|revoke_x_claim_signer|set_protocol_fee_share)\(' <<<"$runtime_config_production")" != 3 ]] \
  || [[ "$(rg -c '^public\(package\) fun (assert_x_claim_active|verify_x_claim_signature|protocol_fee_share_bps)\(' <<<"$runtime_config_production")" != 3 ]]; then
  echo 'runtime_config.move must own only the small live X signer and protocol fee-share settings.' >&2
  failures=$((failures + 1))
fi

if ! rg -q 'protocol_fee_share_bps <= constants::basis_points_denominator!()' \
  sources/runtime_config.move \
  || ! rg -q 'protocol_fee_share_bps != self.protocol_fee_share_bps' \
  sources/runtime_config.move \
  || ! rg -Fq 'signer_public_key.length() == constants::ed25519_public_key_length!()' \
    sources/runtime_config.move \
  || ! rg -q 'self.x_claim_signer_public_key != signer_public_key' \
    sources/runtime_config.move \
  || ! rg -U -q \
    'x_claim_signer_public_key: vector\[\],\s*protocol_fee_share_bps: 0,\s*\}' \
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
  || [[ "$(rg -o 'transfer::share_object' sources/*.move | wc -l)" != 4 ]]; then
  echo 'Runtime consolidation plus package-administration custody must keep exactly four protocol-wide shared singletons.' >&2
  failures=$((failures + 1))
fi

launch_config_production="$(sed '/^\/\/ === Test-Only Functions ===/,$d' sources/launch_config.move)"

if [[ ! -f sources/launch_config.move ]] \
  || ! rg -U -q \
    'public struct LaunchConfig has key \{\s*id: UID,\s*quotes: VecMap<TypeName, u64>,\s*quote_migration_fee_bps: u64,\s*meme_graduation_allocation_bps: u64,\s*meme_liquidity_provision_bps: u64,\s*migration_witnesses: VecSet<TypeName>,\s*\}' \
    sources/launch_config.move \
  || rg -n '\b(AdminCap|ProtocolAuthority)\b' <<<"$launch_config_production" \
  || rg -n '\b(sequence|schema_version|action_tag|nonce)\b' <<<"$launch_config_production" \
  || [[ "$(rg -o '_: &AdminWitness' <<<"$launch_config_production" | wc -l)" != 5 ]] \
  || [[ "$(rg -c '^public fun ' <<<"$launch_config_production")" != 5 ]] \
  || [[ "$(rg -c '^public fun (allow_quote|disallow_quote|allow_migration_witness|disallow_migration_witness)<' <<<"$launch_config_production")" != 4 ]] \
  || [[ "$(rg -c '^public fun set_graduation_defaults\(' <<<"$launch_config_production")" != 1 ]] \
  || ! rg -U -q \
    'public fun set_graduation_defaults\(\s*self: &mut LaunchConfig,\s*_: &AdminWitness,\s*quote_migration_fee_bps: u64,\s*meme_graduation_allocation_bps: u64,\s*meme_liquidity_provision_bps: u64,\s*\)' \
    sources/launch_config.move \
  || [[ "$(rg -c '^public\(package\) fun ' <<<"$launch_config_production")" != 1 ]] \
  || ! rg -U -q \
    'public\(package\) fun snapshot_for_launch<Quote, MigrationWitness: drop>\(\s*self: &LaunchConfig,\s*\): \(u64, u64, u64, u64, TypeName\)' \
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
  || ! rg -U -q 'macro public\(package\) fun max_meme_graduation_allocation_bps\(\): u64 \{\s*1_000\s*\}' \
  sources/lib/constants.move \
  || ! rg -U -q 'macro public\(package\) fun max_meme_liquidity_provision_bps\(\): u64 \{\s*9_999\s*\}' \
  sources/lib/constants.move \
  || ! rg -Fq 'type_name::with_original_ids<Quote>()' sources/launch_config.move \
  || ! rg -Fq 'type_name::with_original_ids<MigrationWitness>()' sources/launch_config.move \
  || ! rg -Fq 'self.quotes.length() < constants::max_quote_assets!()' \
    sources/launch_config.move \
  || ! rg -Fq 'self.migration_witnesses.length()' sources/launch_config.move \
  || ! rg -U -q \
    'quote_migration_fee_bps: 0,\s*meme_graduation_allocation_bps: 0,\s*meme_liquidity_provision_bps: 0,\s*migration_witnesses: vec_set::empty\(\)' \
    sources/launch_config.move \
  || ! rg -U -q \
    'meme_graduation_allocation_bps \+ meme_liquidity_provision_bps\s*< constants::basis_points_denominator!\(\)' \
    sources/launch_config.move \
  || ! rg -Fq 'self.meme_liquidity_provision_bps > 0' sources/launch_config.move \
  || rg -n '\bCurrency<Quote>\b|coin_registry' <<<"$launch_config_production"; then
  echo 'Launch policy must use approved ceilings, original type identities, fixed bounds, zero defaults, and no Coin Registry dependency.' >&2
  failures=$((failures + 1))
fi

if ! rg -U -q \
    'let quote_migration_fee_bps = config\.quote_migration_fee_bps;\s*let meme_graduation_allocation_bps = config\.meme_graduation_allocation_bps;\s*let meme_liquidity_provision_bps = config\.meme_liquidity_provision_bps;\s*transfer::share_object\(config\);\s*events::launch_config_created\(\s*config_id,\s*constants::max_quote_assets!\(\),\s*constants::max_migration_witnesses!\(\),\s*quote_migration_fee_bps,\s*meme_graduation_allocation_bps,\s*meme_liquidity_provision_bps,\s*\)' \
    sources/launch_config.move; then
  echo 'Launch-config initialization must emit the three stored defaults read from the constructed config in order, never literal defaults.' >&2
  failures=$((failures + 1))
fi

launch_config_event_payloads="$(sed -n \
  -e '/^public struct LaunchConfigCreated/,/^}/p' \
  -e '/^public struct QuoteAllowed/,/^}/p' \
  -e '/^public struct QuoteMigrationTargetChanged/,/^}/p' \
  -e '/^public struct QuoteDisallowed/,/^}/p' \
  -e '/^public struct GraduationDefaultsChanged/,/^}/p' \
  -e '/^public struct MigrationWitnessAllowed/,/^}/p' \
  -e '/^public struct MigrationWitnessDisallowed/,/^}/p' \
  sources/lib/events.move)"

launch_config_mutation_event_payloads="$(sed -n \
  -e '/^public struct QuoteAllowed/,/^}/p' \
  -e '/^public struct QuoteMigrationTargetChanged/,/^}/p' \
  -e '/^public struct QuoteDisallowed/,/^}/p' \
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

if [[ ! -f sources/launch_ticket.move ]] \
  || ! rg -U -q \
    'public struct LaunchTicket<phantom Meme> has key, store \{\s*id: UID,\s*meme: Balance<Meme>,\s*metadata_cap: MetadataCap<Meme>,\s*creator_authority: CreatorAuthority<Meme>,\s*burnable: bool,\s*\}' \
    sources/launch_ticket.move \
  || [[ "$(rg -c '^public fun new<Meme: drop>\(' sources/launch_ticket.move)" != 1 ]] \
  || [[ "$(rg -c 'creator_identity: CreatorIdentity' sources/launch_ticket.move)" != 1 ]] \
  || rg -n '^public fun new_(address|x)<Meme: drop>\(' sources/launch_ticket.move \
  || [[ "$(rg -c '^public\(package\) fun into_parts<Meme>\(' sources/launch_ticket.move)" != 1 ]] \
  || ! rg -q 'coin_registry::new_currency_with_otw' sources/launch_ticket.move \
  || ! rg -Fq 'let meme = treasury_cap.mint_balance(initial_supply);' sources/launch_ticket.move \
  || ! rg -Fq 'initializer.make_supply_fixed(treasury_cap);' sources/launch_ticket.move \
  || ! rg -Fq 'initializer.make_supply_burn_only(treasury_cap);' sources/launch_ticket.move \
  || ! rg -q 'initializer\.finalize\(ctx\)' sources/launch_ticket.move \
  || ! rg -Fq 'let initial_supply = constants::meme_total_supply_atomic_units!();' sources/launch_ticket.move \
  || ! rg -Fq 'constants::meme_decimals!(),' sources/launch_ticket.move \
  || rg -n '\bdecimals: u8\b' sources/launch_ticket.move \
  || rg -n '\bTreasuryCap<Meme>\b|treasury_cap:' sources/launch_ticket.move \
  || rg -n '\b(make_regulated|DenyCap|CoinMetadata)\b|coin_registry::new_currency\(' \
    sources/launch_ticket.move \
  || rg -n '\btransfer::|^(entry fun|public entry fun)' sources/launch_ticket.move; then
  echo 'launch_ticket.move must mint the fixed inventory, consume supply authority, retain only balance/metadata/creator custody, and return a composable ticket.' >&2
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

if rg -n \
  '\b(acl::(grant_admin|revoke_admin|destroy_admin_cap|begin_super_admin_transfer|cancel_super_admin_transfer|accept_super_admin_transfer|destroy_retired_super_admin_cap|sign_in)|runtime_config::(set_x_claim_signer|revoke_x_claim_signer|set_protocol_fee_share|assert_x_claim_active|verify_x_claim_signature|protocol_fee_share_bps)|launch_config::(allow_quote|disallow_quote|set_graduation_defaults|allow_migration_witness|disallow_migration_witness|snapshot_for_launch|allowed_quote_count_for_testing|allowed_migration_witness_count_for_testing)|creator_authority::(into_authority|event_fields|claim_creator_cap)|launch_ticket::into_parts|fees::(accrue|claim_creator_fees|claim_protocol_fees)|package_admin::(authorize_upgrade|commit_upgrade|restrict_to_additive|restrict_to_dependency_only|publisher_id_for_testing|upgrade_cap_id_for_testing|package_id_for_testing|version_for_testing|policy_for_testing))(<[^>]+>)?\(' \
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
