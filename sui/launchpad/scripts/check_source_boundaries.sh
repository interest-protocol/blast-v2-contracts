#!/usr/bin/env bash

set -euo pipefail

cd "$(dirname "$0")/.."

failures=0

if [[ -e ../Move.toml ]] \
  || [[ ! -f Move.toml ]] \
  || [[ ! -d ../migrators ]]; then
  echo 'sui/ must remain a package workspace with launchpad core and migrators boundaries.' >&2
  failures=$((failures + 1))
fi

if rg -n \
  '(^use std::(vector|option|internal)(::[^;]+)?;|^use std::\{[^;]*(vector|option|internal)|^use sui::(object|transfer|tx_context)(::[^;]+)?;|^use sui::\{[^;]*(object|transfer|tx_context))' \
  sources tests; then
  echo 'Move 2024 implicit prelude modules and types must not be imported explicitly.' >&2
  failures=$((failures + 1))
fi

mapfile -t move_files < <(find sources tests -type f -name '*.move' -print | sort)
mapfile -t source_files < <(find sources -type f -name '*.move' -print | sort)

# Deterministic Move reader shared with the migrator gate; see move_facts.awk for
# the record format. Parser failures fail closed as MALFORMED records.
move_facts_reader="$(<scripts/move_facts.awk)"

move_facts_cache="$(mktemp -d)"
trap 'rm -rf "$move_facts_cache"' EXIT

# Parses one Move file once and caches its records. A parser failure is recorded
# as a MALFORMED line so every consumer of the facts fails closed.
move_facts() {
  local file="$1"
  local cached="${move_facts_cache}/${file//\//__}.facts"

  if [[ ! -f "$cached" ]]; then
    if ! awk "$move_facts_reader" "$file" >"$cached"; then
      printf 'MALFORMED\tparser rejected %s\n' "$file" >>"$cached"
    fi
  fi

  cat "$cached"
}

# Sorted "name:visibility:entry" inventory of the production functions, so extra,
# duplicated, renamed, or re-scoped declarations are all rejected by one compare.
move_production_functions() {
  awk -F'\t' '$1 == "FN" && $6 == 0 { print $2 ":" $3 ":" $4 }' | sort | tr '\n' ' '
}

# Emits the exact production body of one named function, and nothing when the
# name is absent, duplicated, or only present as a #[test_only] declaration.
move_production_body() {
  awk -F'\t' -v name="$1" '
    $1 == "FN" && $2 == name && $6 == 0 { body = $10; found += 1 }
    END { if (found == 1) print body }
  '
}

# Emits the exact production signature of one named function under the same rule.
move_production_signature() {
  awk -F'\t' -v name="$1" '
    $1 == "FN" && $2 == name && $6 == 0 { signature = $9; found += 1 }
    END { if (found == 1) print signature }
  '
}

# Emits visibility, entry/macro flags, and the normalized signature so checks
# can pin ABI-relevant modifiers without depending on their formatted order.
move_production_function_contract() {
  awk -F'\t' -v name="$1" '
    $1 == "FN" && $2 == name && $6 == 0 {
      contract = $3 ":" $4 ":" $5 ":" $9
      found += 1
    }
    END { if (found == 1) print contract }
  '
}

# Emits the exact production declaration of one named struct or enum.
move_production_type() {
  awk -F'\t' -v name="$1" '
    $1 == "TYPE" && $2 == name && $5 == 0 { declaration = $8; found += 1 }
    END { if (found == 1) print declaration }
  '
}

# Emits the comment-free source with whitespace collapsed.
move_normalized_source() {
  awk -F'\t' '$1 == "NORM" { print $2 }'
}

# Counts pattern occurrences on stdin, not matching lines, because normalized
# source is one long line.
count_occurrences() {
  { rg -o "$1" || true; } | wc -l | tr -d ' '
}

# Succeeds when every literal needle occurs exactly once in stdin, in the given order.
in_order() {
  local text needle rest offset=-1
  text="$(cat)"
  for needle in "$@"; do
    rest="${text//"$needle"/}"
    (( ${#text} - ${#rest} == ${#needle} )) || return 1
    rest="${text%%"$needle"*}"
    (( ${#rest} > offset )) || return 1
    offset=${#rest}
  done
}

# Compares parser-isolated signatures and bodies independently of formatter-only
# whitespace and optional trailing commas. The reader has already stripped
# comments and string contents and brace-matched the declaration boundary.
move_semantic_shape() {
  tr '\n' ' ' | sed -E \
    -e 's/[[:space:]]+/ /g' \
    -e 's/^ //; s/ $//' \
    -e 's/ *:: */::/g' \
    -e 's/ *\. */./g' \
    -e ':punctuation' \
    -e 's/ +([(),{};])/\1/g' -e 't punctuation' \
    -e 's/([(),{};]) +/\1/g' -e 't punctuation' \
    -e ':trailing' -e 's/,([)}])/\1/g' -e 't trailing'
}

# Sorted list of every `self.<ledger balance>.<operation>(` in one body, so an
# unauthorized or duplicated balance operation changes the compared value.
move_balance_operations() {
  { rg -o 'self\.(protocol|creator)_(meme|quote)\.[a-z_0-9]+\(' || true; } \
    | tr -d '(' | sed 's/^self\.//' | sort | tr '\n' ' '
}

for move_file in "${move_files[@]}"; do
  if move_facts "$move_file" | rg -q '^MALFORMED'; then
    move_facts "$move_file" | rg '^MALFORMED'
    echo "${move_file}: the boundary reader could not parse this source; every body-bound check fails closed." >&2
    failures=$((failures + 1))
  fi
done

# The '// === Test-Only Functions ===' comment is a section label, never an
# authority. The body-bound checks classify by attribute, and this gate proves the
# marker and the attributes agree in both directions for every production module,
# which is what lets the remaining marker-scoped scans below stay sound.
for move_file in "${source_files[@]}"; do
  demarcation_violations="$(move_facts "$move_file" | awk -F'\t' '
    $1 == "FN" && $7 == 1 && $6 == 0 {
      print "  function " $2 " (line " $8 ") sits below the test-only marker without #[test_only]"
    }
    $1 == "FN" && $7 == 0 && $6 == 1 {
      print "  function " $2 " (line " $8 ") is #[test_only] above the test-only marker"
    }
    $1 == "TYPE" && $6 == 1 && $5 == 0 {
      print "  " $3 " " $2 " (line " $7 ") sits below the test-only marker without #[test_only]"
    }
    $1 == "TYPE" && $6 == 0 && $5 == 1 {
      print "  " $3 " " $2 " (line " $7 ") is #[test_only] above the test-only marker"
    }
  ')"

  if [[ -n "$demarcation_violations" ]]; then
    printf '%s\n' "$demarcation_violations"
    echo "${move_file}: every declaration below the test-only marker must carry #[test_only], and every #[test_only] declaration must sit below it." >&2
    failures=$((failures + 1))
  fi
done
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

if rg -ni '\b(cetus|bluefin|aftermath|turbos|flowx|deepbook|momentum|kriya|haedal|scallop|navi|mmt)\b' \
  sources --glob '*.move'; then
  echo 'Launchpad core must remain provider-neutral and name no venue-specific policy or package.' >&2
  failures=$((failures + 1))
fi

core_import_roots="$(
  rg -o '^use [A-Za-z_][A-Za-z0-9_]*' \
    sources/launch.move sources/launch_config.move sources/lp_fee_policy.move \
    sources/fee_router.move sources/lib/events.move \
    | rg -v ':use fun$' | sed 's/.*use //' | sort -u
)"
if [[ "$core_import_roots" != $'blast_admin\nblast_fun\nstd\nsui' ]] \
  || [[ "$(sed -n '/^\[dependencies\]/,/^\[/p' Move.toml | rg -o '^[A-Za-z_][A-Za-z0-9_]*[[:space:]]*=' | sed 's/[[:space:]]*=//' | sort)" != 'blast_admin' ]]; then
  echo 'Provider-neutral launch state, config, router, selection, and events may import only local core, std, Sui, and blast_admin.' >&2
  failures=$((failures + 1))
fi

if rg -ni '\b(referral|referrer|affiliate)\b' sources --glob '*.move'; then
  echo 'Launch config, state, router, selection, and events must not depend on referral attribution.' >&2
  failures=$((failures + 1))
fi

if rg -n '^public(\(package\))? fun [^(]+\([^)]*\):[^\n]*(VenueWitness|CustodyWitness)|^public struct (VenueWitness|CustodyWitness)\b' \
  sources --glob '*.move' \
  || rg -ni '^public(\(package\))? fun (new|create|issue)_[a-z_]*witness[a-z_]*\(' sources --glob '*.move'; then
  echo 'Provider-neutral core must expose no venue/custody witness constructor or witness-return escape.' >&2
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
  || [[ "$(rg -c '^public fun (new|value|apply_up|complement)\(' sources/lib/bps.move)" != 4 ]] \
  || [[ "$(rg -c '^public(\(package\))? fun ' sources/lib/bps.move)" != 4 ]] \
  || rg -n '^(entry|public entry) fun |\b(UID|key|Balance|Coin|TxContext|transfer::|events::)\b' \
    sources/lib/bps.move \
  || ! rg -Fq 'value <= constants::basis_points_denominator!()' sources/lib/bps.move \
  || ! rg -Fq 'amount.mul_div_ceil(self.value(), constants::basis_points_denominator!())' \
    sources/lib/bps.move \
  || ! rg -Fq 'Bps(constants::basis_points_denominator!() - self.value())' \
    sources/lib/bps.move; then
  echo 'bps.move must keep only a public validated opaque type and its four public validation, value, round-up application, and complement operations.' >&2
  failures=$((failures + 1))
fi

# Every other module must delegate the inclusive range to bps::new. Both operand
# orders of the inclusive comparison are rejected, so a reversed spelling cannot
# reintroduce the duplicate validation, while a strictly-below policy check such
# as the graduation partition sum stays allowed. The scan reads comment-free
# normalized text, so formatting and comments cannot hide or fake it.
for move_file in "${source_files[@]}"; do
  [[ "$move_file" == sources/lib/bps.move ]] && continue

  if move_facts "$move_file" | move_normalized_source \
    | rg -q '<= *constants::basis_points_denominator|constants::basis_points_denominator!\(\) *>='; then
    echo "${move_file}: the inclusive basis-points range must be validated only by bps::new; owners may add stricter policy checks." >&2
    failures=$((failures + 1))
  fi
done

if rg -n '^[[:space:]]+[a-z_]+_bps: Bps,' sources/lib/events.move; then
  echo 'Replay events must keep basis-points facts as primitive u64 fields.' >&2
  failures=$((failures + 1))
fi

blast_production="$(sed '/^\/\/ === Test-Only Functions ===/,$d' sources/blast_fun.move)"

if [[ ! -f sources/blast_fun.move ]] \
  || ! rg -Fq 'public struct BLAST_FUN() has drop;' sources/blast_fun.move \
  || ! rg -U -q \
    'fun init\(otw: BLAST_FUN, ctx: &mut TxContext\) \{\s*sui::package::claim_and_keep\(otw, ctx\);\s*\}' \
    <<<"$blast_production" \
  || [[ "$(rg -c '^(public struct|fun) ' <<<"$blast_production")" != 2 ]] \
  || [[ "$(rg -c '^fun init\(' <<<"$blast_production")" != 1 ]] \
  || rg -n '^(public|entry|public\(package\)) fun ' <<<"$blast_production"; then
  echo 'blast_fun.move must own only the package BLAST_FUN witness and private Publisher claim.' >&2
  failures=$((failures + 1))
fi

# The reusable ACL lifecycle belongs to the immutable blast_admin package. This
# package may own only its domain marker, its governance constants, and the one
# exported role value.
if [[ -e sources/acl.move ]]; then
  echo 'Launchpad must not reintroduce a local ACL implementation.' >&2
  failures=$((failures + 1))
fi

if rg -n '^public struct (ProtocolAuthority|Authority|SuperAdminCap|AdminCap|AdminWitness)\b' \
  sources --glob '*.move'; then
  echo 'Administration types must come from blast_admin, never from a local copy.' >&2
  failures=$((failures + 1))
fi

blast_fun_domain_facts="$(move_facts sources/blast_fun_domain.move)"

# The domain exports exactly two distinct role bits: package administration and
# the creator administration that alone may reassign creator fee authority.
if [[ ! -f sources/blast_fun_domain.move ]] \
  || [[ "$(move_production_type BLAST_FUN_DOMAIN <<<"$blast_fun_domain_facts")" \
    != 'struct BLAST_FUN_DOMAIN() has drop;' ]] \
  || [[ "$(move_production_functions <<<"$blast_fun_domain_facts")" \
    != 'creator_admin_role:public:0 init:private:0 package_admin_role:public:0 ' ]] \
  || [[ "$(move_production_signature init <<<"$blast_fun_domain_facts")" \
    != 'fun init(otw: BLAST_FUN_DOMAIN, ctx: &mut TxContext)' ]] \
  || [[ "$(move_production_body init <<<"$blast_fun_domain_facts")" \
    != 'blast_admin::acl::new(otw, MAX_ADMINS, ROOT_TRANSFER_DELAY_MS, ctx);' ]] \
  || [[ "$(move_production_signature package_admin_role <<<"$blast_fun_domain_facts")" \
    != 'fun package_admin_role(): u64' ]] \
  || [[ "$(move_production_body package_admin_role <<<"$blast_fun_domain_facts")" \
    != 'PACKAGE_ADMIN_ROLE' ]] \
  || [[ "$(move_production_signature creator_admin_role <<<"$blast_fun_domain_facts")" \
    != 'fun creator_admin_role(): u64' ]] \
  || [[ "$(move_production_body creator_admin_role <<<"$blast_fun_domain_facts")" \
    != 'CREATOR_ADMIN_ROLE' ]] \
  || ! rg -q '^const MAX_ADMINS: u64 = 16;$' sources/blast_fun_domain.move \
  || ! rg -q '^const ROOT_TRANSFER_DELAY_MS: u64 = 7 \* 24 \* 60 \* 60 \* 1_000;$' \
    sources/blast_fun_domain.move \
  || ! rg -q '^const PACKAGE_ADMIN_ROLE: u64 = 1;$' sources/blast_fun_domain.move \
  || ! rg -q '^const CREATOR_ADMIN_ROLE: u64 = 2;$' sources/blast_fun_domain.move \
  || [[ "$(rg -c '^const ' sources/blast_fun_domain.move)" != 4 ]]; then
  echo 'blast_fun_domain.move must create exactly one typed domain from module constants and export exactly the package-admin and creator-admin role bits.' >&2
  failures=$((failures + 1))
fi

# Exactly one call site may create the shared authority.
if [[ "$(rg -c 'acl::new\(' sources --glob '*.move' | wc -l)" != 1 ]]; then
  echo 'Exactly one module may call the shared ACL constructor.' >&2
  failures=$((failures + 1))
fi

# Publication effects natively record every shared singleton, the delivered root
# capability, and the publishing sender, and each initializer commits compiled
# constants only. No `init` may therefore emit a creation event. See ADR 0058.
if rg -U -n 'fun init\([^)]*\) \{[^}]*events::' sources --glob '*.move' \
  || rg -n '\b(ProtocolAuthorityCreated|PackageVersionCreated|RuntimeConfigCreated|LaunchConfigCreated)\b' \
    sources tests; then
  echo 'Package initialization must stay eventless: native publication effects are the discovery fact.' >&2
  failures=$((failures + 1))
fi

package_admin_production="$(sed '/^\/\/ === Test-Only Types ===/,$d' sources/package_admin.move)"

if [[ ! -f sources/package_admin.move || -f sources/upgrade.move ]] \
  || ! rg -U -q \
    'public struct PackageAdmin has key \{\s*id: UID,\s*custody: UpgradeCustody<BLAST_FUN>,\s*\}' \
    sources/package_admin.move \
  || [[ "$(rg -c '^public fun ' <<<"$package_admin_production")" != 7 ]] \
  || [[ "$(rg -c '^public fun (wrap|authorize_upgrade|restrict_to_additive|restrict_to_dependency_only|commit_upgrade_and_advance|make_immutable|has_upgrade_cap)\(' <<<"$package_admin_production")" != 7 ]] \
  || rg -n '^public\(package\) fun ' <<<"$package_admin_production" \
  || rg -n '^public fun commit_upgrade\(|^public fun activate' <<<"$package_admin_production" \
  || [[ "$(rg -o 'admin_witness: &AdminWitness<BLAST_FUN_DOMAIN>' <<<"$package_admin_production" | wc -l)" != 5 ]] \
  || ! rg -U -q \
    'public fun wrap\(publisher: Publisher, upgrade_cap: UpgradeCap, ctx: &mut TxContext\)' \
    sources/package_admin.move \
  || ! rg -U -q \
    'public fun authorize_upgrade\(\s*self: &mut PackageAdmin,\s*package_version: &PackageVersion,\s*admin_witness: &AdminWitness<BLAST_FUN_DOMAIN>,\s*digest: vector<u8>,\s*\): UpgradeTicket' \
    sources/package_admin.move \
  || ! rg -U -q \
    'public fun commit_upgrade_and_advance\(\s*self: &mut PackageAdmin,\s*package_version: &mut PackageVersion,\s*admin_witness: &AdminWitness<BLAST_FUN_DOMAIN>,\s*receipt: UpgradeReceipt,\s*\)' \
    sources/package_admin.move; then
  echo 'package_admin.move must expose only validated wrapping, role-gated native administration, and one atomic commit-and-advance finalizer.' >&2
  failures=$((failures + 1))
fi

# Every governed custody transition asserts the current generation, then the one
# exported role, before it reaches the shared custody value. Commit-and-advance
# is the post-upgrade finalizer and instead proves the exact next generation.
if ! rg -Fq 'publisher.from_module<BLAST_FUN>()' sources/package_admin.move \
  || ! rg -Fq 'upgrade_custody::new<BLAST_FUN>(id.to_inner(), publisher, upgrade_cap)' \
    sources/package_admin.move \
  || [[ "$(rg -c 'package_version\.assert_current\(\);' <<<"$package_admin_production")" != 4 ]] \
  || [[ "$(rg -c 'admin_witness\.assert_role\(blast_fun_domain::package_admin_role\(\)\);' <<<"$package_admin_production")" != 5 ]] \
  || ! rg -Fq 'package_version.assert_next();' sources/package_admin.move \
  || ! rg -Fq 'self.custody.commit_upgrade(custodian_id, receipt);' sources/package_admin.move \
  || ! rg -Fq 'package_version.advance();' sources/package_admin.move \
  || rg -n '\bpackage::(version|only_(additive|dep)_upgrades|make_immutable)\(' \
    <<<"$package_admin_production" \
  || rg -n 'admin_authorization|governance_cutover' sources/package_admin.move \
  || rg -U -n '^(public|entry|public\(package\)) fun [^(]+\([^)]*\): (&)?(Publisher|UpgradeCap)' \
    <<<"$package_admin_production" \
  || rg -n 'transfer::(public_)?transfer|burn_publisher' \
    <<<"$package_admin_production"; then
  echo 'Package administration must seal custody, keep version-then-role guard order, and expose no capability escape.' >&2
  failures=$((failures + 1))
fi

# Reusable custody, generation, policy, and immutability facts are emitted by
# blast_admin. No copy may reappear in this package's event registry.
if rg -n '^public struct (PackageAdminCreated|UpgradeAuthorized|UpgradeCommitted|UpgradePolicyRestricted|UpgradeCapDestroyed|PackageVersionAdvanced)\b' \
  sources/lib/events.move \
  || rg -n 'PackageAdminAuthorizationDisabled|admin_authorization_enabled' \
    sources/lib/events.move; then
  echo 'Reusable administration events must come from blast_admin, not a consumer copy.' >&2
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
  helpers_marker_count="$(rg -c '^// === Test Helpers ===$' "$test_file" || true)"
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
    echo "$test_file: exactly one '// === Test Helpers ===' marker is required for scenario-backed suites and it may never be duplicated." >&2
    failures=$((failures + 1))
    continue
  fi

  tests_marker_line="$(rg -n '^// === Tests ===$' "$test_file" | cut -d: -f1)"
  if [[ "$helpers_marker_count" == 1 ]]; then
    helpers_marker_line="$(rg -n '^// === Test Helpers ===$' "$test_file" \
      | cut -d: -f1)"
    if ((helpers_marker_line <= tests_marker_line)); then
      echo "$test_file: the Tests section must precede Test Helpers." >&2
      failures=$((failures + 1))
      continue
    fi
    test_bodies="$(sed -n "${tests_marker_line},${helpers_marker_line}p" "$test_file")"
  else
    test_bodies="$(sed -n "${tests_marker_line},\$p" "$test_file")"
  fi

  if ! rg -q '^[[:space:]]*#\[test([,\]])' <<<"$test_bodies"; then
    echo "$test_file: the extracted Tests section contains no '#[test]' attribute lines." >&2
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
      "(^|\n)fun [a-z_0-9]*end\(self: ${fixture_type}\) \{\s*(destroy\(self\);|let ${fixture_type} \{)" \
      "$test_file"; then
      echo "$test_file: ${fixture_type} needs one consuming end helper that destroys or destructures it." >&2
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
    closure_parameter_count="$({ rg -o ': \|' <<<"$macro_signature" || true; } | wc -l | tr -d ' ')"
    fixture_type_mention_count="$(rg -o 'Fixture' <<<"$macro_signature" | wc -l)"

    if [[ -z "$macro_fixture_type" ]]; then
      echo "$test_file:${macro_line}: a transaction macro must take one named &mut fixture handle first." >&2
      failures=$((failures + 1))
      continue
    fi
    if [[ "${closure_parameter_count:-0}" != 1 ]] \
      || ! rg -q "\\\$fn: \\|&mut ${macro_fixture_type}\\|[,)]" \
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
  || [[ "$(rg -c '^public\(package\) fun (get_amount_out|k|cap_buy_quote_input|quote_buy|quote_sell)\(' sources/curve.move)" != 5 ]] \
  || rg -n '\bget_amount_in\b' sources/curve.move; then
  echo 'curve.move must remain a pure package-only numeric curve module.' >&2
  failures=$((failures + 1))
fi

if [[ "$(rg -c '\bget_amount_out\(' sources/curve.move)" != 3 ]] \
  || [[ "$(rg -c '\bcurve::k\(' sources/launch.move)" != 1 ]] \
  || [[ "$(rg -c '\blet k_before = self\.curve_k\(\);' sources/launch.move)" != 2 ]] \
  || [[ "$(rg -c '\bself\.curve_k\(\) >= k_before' sources/launch.move)" != 2 ]] \
  || [[ "$(rg -c '\bconstant_product_invariant_decreased!\(' sources/launch.move)" != 2 ]]; then
  echo 'Buy and sell must share exact-input math and reconcile actual reserve products.' >&2
  failures=$((failures + 1))
fi

if [[ "$(rg -c '^[[:space:]]+quote_fee_bps: Bps,' sources/curve.move)" != 3 ]] \
  || [[ "$(rg -c '^[[:space:]]+meme_fee_bps: Bps,' sources/curve.move)" != 2 ]] \
  || [[ "$(rg -c '^[[:space:]]+sell_burn_bps: Bps,' sources/curve.move)" != 1 ]] \
  || rg -n 'trade_fee_bps|fee_asset|fee_mode' sources/curve.move; then
  echo 'Each curve quote must use independent quote/meme rates; zero rates encode fee-asset choice.' >&2
  failures=$((failures + 1))
fi

fees_facts="$(move_facts sources/fees.move)"
fees_source="$(move_normalized_source <<<"$fees_facts")"

if [[ ! -f sources/fees.move ]] \
  || [[ "$(move_production_functions <<<"$fees_facts")" \
    != 'accrue:public:0 claim_creator_fees:public:0 claim_protocol_fees:public:0 has_protocol_fees:public:0 new:public:0 ' ]] \
  || [[ "$(move_production_type FeeLedger <<<"$fees_facts")" \
    != 'struct FeeLedger<phantom Meme, phantom Quote> has store { protocol_meme: Balance<Meme>, creator_meme: Balance<Meme>, protocol_quote: Balance<Quote>, creator_quote: Balance<Quote>, }' ]] \
  || rg -q '\b(UID|key|transfer::|CreatorClaim|ed25519|recipient|launch_id)\b' <<<"$fees_source" \
  || rg -q '\b(creator_authority|CreatorCap|CurveFeeCap|BlastMetadataCap)\b' <<<"$fees_source" \
  || rg -q 'fee_balance_overflow|std::u64::max_value|max_balance' <<<"$fees_source" \
  || rg -q 'set_creator_fee_split|sui::event|events::' <<<"$fees_source"; then
  echo 'fees.move must remain an embedded supply-conserved four-balance ledger exposing only its five approved cross-package functions.' >&2
  failures=$((failures + 1))
fi

# Ledger custody has exactly one release path per owner, so the module may not
# reach a stored balance through an alias, a module-form call, a destructuring
# bind, or any framework helper other than the zero constructor.
if rg -q '(^| )use fun ' <<<"$fees_source" \
  || rg -q '\blet FeeLedger\b' <<<"$fees_source" \
  || [[ "$(count_occurrences 'FeeLedger \{' <<<"$fees_source")" != 1 ]] \
  || [[ "$(count_occurrences 'balance::[a-z_0-9]+\(' <<<"$fees_source")" \
    != "$(count_occurrences 'balance::zero\(\)' <<<"$fees_source")" ]] \
  || rg -q '\b(into_balance|borrow_mut|destroy_zero|withdraw)\(' <<<"$fees_source"; then
  echo 'fees.move must reach its four stored balances only through the approved receiver-style operations, never through aliases, module-form calls, or destructuring.' >&2
  failures=$((failures + 1))
fi

# Each authorized transition is bound to its own named body, so a capability, an
# emptiness test, or a claimed balance cannot be swapped between the two owners.
# Creator authority is revocable per embedding owner (ADR 0082): the ledger's
# creator claim takes no capability, stays unreachable without `&mut` access to
# its store-only embedding, and each owner checks the capability or custodian it
# currently records before claiming. The launch side is pinned further below.
fee_ledger_violations=''

check_fee_function() {
  local name="$1" expected_signature="$2" expected_operations="$3" expected_body="$4"
  local signature body operations

  signature="$(move_production_signature "$name" <<<"$fees_facts")"
  body="$(move_production_body "$name" <<<"$fees_facts")"
  operations="$(move_balance_operations <<<"$body")"

  if [[ -z "$signature" || -z "$body" ]]; then
    fee_ledger_violations+="  ${name} has no single production declaration"$'\n'
    return
  fi
  if [[ "$signature" != "$expected_signature" ]]; then
    fee_ledger_violations+="  ${name} does not keep its approved authorization and result signature"$'\n'
  fi
  if [[ "$operations" != "$expected_operations" ]]; then
    fee_ledger_violations+="  ${name} operates on '${operations}' instead of the authorized '${expected_operations}'"$'\n'
  fi
  if [[ -n "$expected_body" && "$body" != "$expected_body" ]]; then
    fee_ledger_violations+="  ${name} body is not the approved transition"$'\n'
  fi
}

check_fee_function new \
  'fun new<Meme, Quote>(): FeeLedger<Meme, Quote>' \
  '' \
  'FeeLedger { protocol_meme: balance::zero(), creator_meme: balance::zero(), protocol_quote: balance::zero(), creator_quote: balance::zero(), }'

check_fee_function has_protocol_fees \
  'fun has_protocol_fees<Meme, Quote>(self: &FeeLedger<Meme, Quote>): bool' \
  'protocol_meme.value protocol_quote.value ' \
  'self.protocol_meme.value() > 0 || self.protocol_quote.value() > 0'

check_fee_function claim_creator_fees \
  'fun claim_creator_fees<Meme, Quote>( self: &mut FeeLedger<Meme, Quote>, ctx: &mut TxContext, ): (Coin<Meme>, Coin<Quote>)' \
  'creator_meme.value creator_meme.withdraw_all creator_quote.value creator_quote.withdraw_all ' \
  'assert!( self.creator_meme.value() > 0 || self.creator_quote.value() > 0, blast_fun::errors::nothing_accrued!(), ); ( self.creator_meme.withdraw_all().into_coin(ctx), self.creator_quote.withdraw_all().into_coin(ctx), )'

check_fee_function claim_protocol_fees \
  'fun claim_protocol_fees<Meme, Quote>( self: &mut FeeLedger<Meme, Quote>, _: &AdminWitness<BLAST_FUN_DOMAIN>, ctx: &mut TxContext, ): (Coin<Meme>, Coin<Quote>)' \
  'protocol_meme.withdraw_all protocol_quote.withdraw_all ' \
  'assert!( self.has_protocol_fees(), blast_fun::errors::nothing_accrued!(), ); ( self.protocol_meme.withdraw_all().into_coin(ctx), self.protocol_quote.withdraw_all().into_coin(ctx), )'


# The raw accrual keeps a longer body, so it is bound to its guard and to one
# contiguous rounding and custody sequence instead: the protocol share rounds up,
# the creator receives the exact remainder, the protocol amount leaves the
# incoming balances, and each half joins only its own bucket.
check_fee_function accrue \
  'fun accrue<Meme, Quote>( self: &mut FeeLedger<Meme, Quote>, mut meme_fee: Balance<Meme>, mut quote_fee: Balance<Quote>, protocol_fee_share_bps: Bps, ): (u64, u64, u64, u64)' \
  'creator_meme.join creator_quote.join protocol_meme.join protocol_quote.join ' \
  ''

fees_accrue_body="$(move_production_body accrue <<<"$fees_facts")"

if ! rg -Fq 'assert!( meme_fee_amount > 0 || quote_fee_amount > 0, blast_fun::errors::zero_fee_accrual!(), );' \
    <<<"$fees_accrue_body" \
  || ! rg -Fq 'let protocol_meme_amount = protocol_fee_share_bps.apply_up(meme_fee_amount); let protocol_quote_amount = protocol_fee_share_bps.apply_up(quote_fee_amount); let creator_meme_amount = meme_fee_amount - protocol_meme_amount; let creator_quote_amount = quote_fee_amount - protocol_quote_amount; let protocol_meme = meme_fee.split(protocol_meme_amount); let protocol_quote = quote_fee.split(protocol_quote_amount); self.protocol_meme.join(protocol_meme); self.creator_meme.join(meme_fee); self.protocol_quote.join(protocol_quote); self.creator_quote.join(quote_fee);' \
    <<<"$fees_accrue_body"; then
  fee_ledger_violations+='  accrue is not bound to the approved guard, round-up split, and per-owner joins'$'\n'
fi

if [[ -n "$fee_ledger_violations" ]]; then
  printf '%s' "$fee_ledger_violations"
  echo 'Fee state releases creator balances only under its embedding owner authorization and protocol balances only under AdminWitness, splits on a sealed policy-issued protocol share, and releases balances only through the two full claims.' >&2
  failures=$((failures + 1))
fi

constants_facts="$(move_facts sources/lib/constants.move)"

if [[ "$(move_production_function_contract max_launch_fee_bps <<<"$constants_facts")" != 'package:0:1:fun max_launch_fee_bps(): u64' ]] \
  || [[ "$(move_production_body max_launch_fee_bps <<<"$constants_facts")" != '1_000' ]] \
  || rg -n 'protocol_trade_fee_share_bps' sources; then
  echo 'The fee-rate ceiling is constant, while the protocol share must not be hard-coded.' >&2
  failures=$((failures + 1))
fi

package_version_production="$(sed '/^\/\/ === Test-Only Functions ===/,$d' sources/package_version.move)"

# The container owns only its compiled constants; the generation value, its
# checked arithmetic, and its replay event belong to blast_admin.
if [[ ! -f sources/package_version.move ]] \
  || ! rg -U -q \
    'public struct PackageVersion has key \{\s*id: UID,\s*generation: OperationalVersion<BLAST_FUN>,\s*\}' \
    sources/package_version.move \
  || ! rg -q '^const PACKAGE_VERSION: u64 = 1;$' sources/package_version.move \
  || ! rg -q '^const NEXT_PACKAGE_VERSION: u64 = 2;$' sources/package_version.move \
  || rg -n 'package_version|PACKAGE_VERSION' sources/lib/constants.move \
  || [[ "$(rg -c '^public\(package\) fun (assert_current|assert_next|advance)\(' <<<"$package_version_production")" != 3 ]] \
  || rg -n '^(public|entry|public entry) fun ' <<<"$package_version_production" \
  || rg -n '^public\(package\) fun activate\(' <<<"$package_version_production" \
  || ! rg -Fq 'self.generation.assert_current(PACKAGE_VERSION);' sources/package_version.move \
  || ! rg -Fq 'self.generation.assert_next(NEXT_PACKAGE_VERSION);' sources/package_version.move \
  || ! rg -Fq 'self.generation.advance(container_id, NEXT_PACKAGE_VERSION);' \
    sources/package_version.move \
  || ! rg -Fq 'generation: operational_version::new(),' sources/package_version.move \
  || rg -n '\.checked_add\(|events::' <<<"$package_version_production"; then
  echo 'package_version.move must own only the shared generation container and its two compiled constants.' >&2
  failures=$((failures + 1))
fi

runtime_config_facts="$(move_facts sources/runtime_config.move)"
runtime_config_source="$(move_normalized_source <<<"$runtime_config_facts")"

if [[ ! -f sources/runtime_config.move ]] \
  || [[ "$(move_production_functions <<<"$runtime_config_facts")" \
    != 'assert_creator_claim_active:package:0 assert_creator_claim_signature:package:0 init:private:0 new:private:0 protocol_fee_share:package:0 revoke_creator_claim_signer:public:0 set_creator_claim_signer:public:0 set_protocol_fee_share:public:0 validate_creator_claim_public_key:private:0 ' ]] \
  || [[ "$(move_production_type RuntimeConfig <<<"$runtime_config_facts")" \
    != 'struct RuntimeConfig has key { id: UID, creator_claim_signer_public_key: vector<u8>, protocol_fee_share_bps: Bps, }' ]] \
  || rg -q '\b(AdminCap|ProtocolAuthority|LaunchConfig|VecMap|VecSet|TypeName)\b' \
    <<<"$runtime_config_source" \
  || rg -q '\b(sequence|schema_version|action_tag|nonce)\b' <<<"$runtime_config_source"; then
  echo 'runtime_config.move must own only the version-gated creator-claim signer and protocol fee share.' >&2
  failures=$((failures + 1))
fi

# Every runtime transition is bound to its own named production body, so a guard,
# an assignment, or a completed-fact event cannot be satisfied by a comment, by a
# sibling function, by a dead helper, or by a #[test_only] decoy.
runtime_config_violations=''

check_runtime_function() {
  local name="$1" expected_signature="$2" expected_body="$3"
  local signature body

  signature="$(move_production_signature "$name" <<<"$runtime_config_facts")"
  body="$(move_production_body "$name" <<<"$runtime_config_facts")"

  if [[ -z "$signature" || -z "$body" ]]; then
    runtime_config_violations+="  ${name} has no single production declaration"$'\n'
    return
  fi
  if [[ "$signature" != "$expected_signature" ]]; then
    runtime_config_violations+="  ${name} does not keep its approved authorization signature"$'\n'
  fi
  if [[ -n "$expected_body" && "$body" != "$expected_body" ]]; then
    runtime_config_violations+="  ${name} body is not the approved transition"$'\n'
  fi
}

check_runtime_function init \
  'fun init(ctx: &mut TxContext)' \
  ''

check_runtime_function new \
  'fun new(ctx: &mut TxContext): RuntimeConfig' \
  ''

check_runtime_function protocol_fee_share \
  'fun protocol_fee_share(self: &RuntimeConfig): Bps' \
  ''

check_runtime_function assert_creator_claim_active \
  'fun assert_creator_claim_active(self: &RuntimeConfig)' \
  ''

check_runtime_function validate_creator_claim_public_key \
  'fun validate_creator_claim_public_key(signer_public_key: &vector<u8>)' \
  ''

check_runtime_function assert_creator_claim_signature \
  'fun assert_creator_claim_signature( self: &RuntimeConfig, message: &vector<u8>, signature: &vector<u8>, )' \
  ''

check_runtime_function set_creator_claim_signer \
  'fun set_creator_claim_signer( self: &mut RuntimeConfig, package_version: &PackageVersion, _: &AdminWitness<BLAST_FUN_DOMAIN>, signer_public_key: vector<u8>, )' \
  ''

check_runtime_function revoke_creator_claim_signer \
  'fun revoke_creator_claim_signer( self: &mut RuntimeConfig, package_version: &PackageVersion, _: &AdminWitness<BLAST_FUN_DOMAIN>, )' \
  ''

check_runtime_function set_protocol_fee_share \
  'fun set_protocol_fee_share( self: &mut RuntimeConfig, package_version: &PackageVersion, _: &AdminWitness<BLAST_FUN_DOMAIN>, protocol_fee_share_bps: Bps, )' \
  ''
# The three named mutations are the complete set of RuntimeConfig transitions, and
# each one must check the live package version as its first statement rather than
# relying on any aggregate count.
runtime_config_mutations="$(awk -F'\t' '
  $1 == "FN" && $6 == 0 && $10 ~ /self\.(creator_claim_signer_public_key|protocol_fee_share_bps) = / {
    print $2
  }
' <<<"$runtime_config_facts" | sort | tr '\n' ' ')"

if [[ "$runtime_config_mutations" \
  != 'revoke_creator_claim_signer set_creator_claim_signer set_protocol_fee_share ' ]]; then
  runtime_config_violations+="  runtime state is mutated by '${runtime_config_mutations}' instead of the three approved setters"$'\n'
fi

runtime_config_ungated="$(awk -F'\t' '
  $1 == "FN" && $6 == 0 \
    && ($2 == "set_creator_claim_signer" || $2 == "revoke_creator_claim_signer" \
      || $2 == "set_protocol_fee_share") {
    if ($9 !~ /[(,] package_version: &PackageVersion,/) {
      print "  " $2 " must take the shared PackageVersion under that exact name"
    }
    if ($10 !~ /^package_version\.assert_current\(\);/) {
      print "  " $2 " must check the live package version as its first statement"
    }
    if ($9 !~ /[(,] _: &AdminWitness<BLAST_FUN_DOMAIN>,/) {
      print "  " $2 " must be authorized by a borrowed AdminWitness"
    }
  }
' <<<"$runtime_config_facts")"

if [[ -n "$runtime_config_ungated" ]]; then
  runtime_config_violations+="${runtime_config_ungated}"$'\n'
fi

if [[ -n "$runtime_config_violations" ]]; then
  printf '%s' "$runtime_config_violations"
  echo 'Runtime configuration must start disabled at zero, and every mutation must keep its version gate, guards, assignment, and completed-fact event in order.' >&2
  failures=$((failures + 1))
fi

events_facts="$(move_facts sources/lib/events.move)"

runtime_config_mutation_event_payloads="$(awk -F'\t' '
  $1 == "TYPE" && $5 == 0 \
    && ($2 == "ProtocolFeeShareChanged" \
      || $2 == "CreatorClaimSignerSet" || $2 == "CreatorClaimSignerRevoked") { print $8 }
' <<<"$events_facts")"

if [[ "$(wc -l <<<"$runtime_config_mutation_event_payloads")" != 3 ]] \
  || rg -q '\b(sequence|schema_version|action_tag|nonce)\b' \
    <<<"$runtime_config_mutation_event_payloads" \
  || rg -q '\bruntime_config_id\b' <<<"$runtime_config_mutation_event_payloads" \
  || rg -q '\bRuntimeConfigCreated\b' <<<"$events_facts"; then
  echo 'Runtime-config creation must stay eventless and every mutation must emit unswapped typed replay facts without repeated singleton, ordering, or schema fields.' >&2
  failures=$((failures + 1))
fi

if [[ -f sources/creator_claim_config.move || -f sources/trade_fee_config.move ]] \
  || rg -n '\b(CreatorClaimConfig|TradeFeeConfig)\b' sources tests \
  || [[ "$(rg -o 'transfer::share_object' sources --glob '*.move' --glob '!launch.move' | wc -l)" != 6 ]]; then
  echo 'Core must keep its five shared protocol singletons plus the FeeRouter terminal sink; the domain authority is shared by blast_admin.' >&2
  failures=$((failures + 1))
fi

launch_config_facts="$(move_facts sources/launch_config.move)"
launch_config_source="$(move_normalized_source <<<"$launch_config_facts")"
launch_config_production="$(sed '/^\/\/ === Test-Only Functions ===/,$d' sources/launch_config.move)"

# T-003 replaces the mutable graduation partition knobs with a single-write
# Blast allocation policy. The policy is cold: a launch copies only its
# validated allocation plan, never a mutable partition default or target range.
if [[ ! -f sources/launch_config.move ]] \
  || [[ "$(move_production_function_contract set_protocol_allocation <<<"$launch_config_facts")" != 'public:0:0:fun set_protocol_allocation( self: &mut LaunchConfig, package_version: &PackageVersion, _: &AdminWitness<BLAST_FUN_DOMAIN>,'* ]] \
  || ! rg -Fq 'assert!(self.protocol_allocation.is_none(),' <<<"$launch_config_source" \
  || ! rg -Fq 'self.protocol_allocation = option::some(ProtocolAllocation {' <<<"$launch_config_source" \
  || ! rg -Fq 'plan.assert_protocol_policy(' <<<"$launch_config_source" \
  || rg -n '\b(set_graduation_defaults|GraduationDefaultsChanged|protocol_(quote_migration|meme_graduation)_fee_bps|meme_liquidity_provision_bps|QuoteParameters|QuoteParametersChanged|min_graduation_target|max_graduation_target)\b' \
    sources/launch_config.move sources/lib/events.move \
  || rg -n '\b(AdminCap|ProtocolAuthority|sequence|schema_version|action_tag|nonce)\b' <<<"$launch_config_production"; then
  echo 'LaunchConfig must own only future-launch settings plus an AdminWitness-gated, single-write Blast allocation policy; graduation partition defaults and target ranges are retired.' >&2
  failures=$((failures + 1))
fi

if [[ "$(move_production_function_contract max_migration_channels <<<"$constants_facts")" != 'package:0:1:fun max_migration_channels(): u64' ]] \
  || [[ "$(move_production_body max_migration_channels <<<"$constants_facts")" != '16' ]] \
  || ! rg -Fq 'constants::max_migration_channels!()' sources/allocation.move \
  || ! rg -Fq 'type_name::with_original_ids<Quote>()' sources/launch_config.move \
  || ! rg -Fq 'type_name::with_original_ids<MigrationWitness>()' sources/launch_config.move \
  || ! rg -Fq '!migration_witness.is_primitive()' sources/launch_config.move \
  || ! rg -Fq 'virtual_quote > 0' sources/launch_config.move \
  || ! rg -Fq 'quote_fee_bps.value() <= constants::max_launch_fee_bps!()' sources/launch_config.move \
  || ! rg -Fq 'meme_fee_bps.value() <= constants::max_launch_fee_bps!()' sources/launch_config.move \
  || ! rg -Fq 'quotes: table::new(ctx)' sources/launch_config.move \
  || ! rg -Fq 'self.meme_decimals.contains(&decimals)' sources/launch_config.move \
  || rg -n '\b(VecMap|vec_map|max_quote_assets|quote_capacity_reached|Currency<Quote>|coin_registry)\b' \
    sources/launch_config.move sources/lib/constants.move sources/lib/errors.move; then
  echo 'Launch policy must retain bounded original-type quote/witness admission and the decimal allowlist while allocation identity capacity has one named limit.' >&2
  failures=$((failures + 1))
fi
if ! rg -U -q \
    'fun init\(ctx: &mut TxContext\) \{\s*transfer::share_object\(new\(ctx\)\);\s*\}' \
    sources/launch_config.move \
  || rg -q '\bLaunchConfigCreated\b' sources/lib/events.move sources/launch_config.move; then
  echo 'Launch-config initialization must share the one cold-policy singleton and emit no creation event.' >&2
  failures=$((failures + 1))
fi

protocol_allocation_event_payload="$(sed -n -e '/^public struct ProtocolAllocationConfigured/,/^}/p' sources/lib/events.move)"

if [[ -z "$protocol_allocation_event_payload" ]] \
  || ! rg -q '^[[:space:]]+channel_id: u64,' <<<"$protocol_allocation_event_payload" \
  || ! rg -q '^[[:space:]]+destination: address,' <<<"$protocol_allocation_event_payload" \
  || ! rg -q '^[[:space:]]+meme_bps: u64,' <<<"$protocol_allocation_event_payload" \
  || ! rg -q '^[[:space:]]+quote_bps: u64,' <<<"$protocol_allocation_event_payload" \
  || rg -n '\b(config_id|sequence|schema_version|action_tag|nonce)\b' <<<"$protocol_allocation_event_payload"; then
  echo 'The one-time Blast allocation policy must emit its complete primitive replay fact without singleton or ordering noise.' >&2
  failures=$((failures + 1))
fi

launch_ticket_facts="$(move_facts sources/launch_ticket.move)"
launch_ticket_source="$(move_normalized_source <<<"$launch_ticket_facts")"

# The generated package's one-time witness names the currency and the Coin Registry proves it
# is unique, so the constructor needs no package identity, launch policy, or registry borrow.
# Binding reads launch policy only to require an admitted adapter and records the Quote with it.
# The treasury capability stays in the ticket, lent only to the bound adapter witness, until
# intake checks the whole minted supply and fixes the supply mode.
launch_ticket_new_body="$(move_production_body new <<<"$launch_ticket_facts" | move_semantic_shape)"
launch_ticket_destroy_body="$(move_production_body destroy <<<"$launch_ticket_facts" | move_semantic_shape)"

if [[ ! -f sources/launch_ticket.move ]] \
  || [[ "$(move_production_function_contract new <<<"$launch_ticket_facts")" != 'public:0:0:fun new<Meme: drop>( otw: Meme, decimals: u8,'* ]] \
  || [[ "$(count_occurrences 'coin_registry::new_currency_with_otw\(' <<<"$launch_ticket_source")" != 1 ]] \
  || ! in_order \
    'constants::max_sell_burn_bps!()' \
    'coin_registry::new_currency_with_otw(' \
    'treasury_cap.mint_balance(atomic_supply)' \
    'initializer.finalize(ctx)' \
    'migration_witness: option::none()' \
    'migration_quote: option::none()' \
    <<<"$launch_ticket_new_body" \
  || [[ "$(move_production_function_contract bind_migration_witness <<<"$launch_ticket_facts")" \
    != 'public:0:0:fun bind_migration_witness<Meme, Quote, Witness: drop>( self: &mut LaunchTicket<Meme>, config: &LaunchConfig, _: Witness, )' ]] \
  || ! in_order \
    '.assert_migration_witness_allowed(' \
    'self.migration_witness = option::some(' \
    'self.migration_quote = option::some(type_name::with_original_ids<Quote>())' \
    <<<"$(move_production_body bind_migration_witness <<<"$launch_ticket_facts" | move_semantic_shape)" \
  || ! in_order \
    'self.migration_quote == option::some(type_name::with_original_ids<Quote>())' \
    'self.migration_witness' \
    'option::none()' \
    <<<"$(move_production_body migration_witness <<<"$launch_ticket_facts" | move_semantic_shape)" \
  || [[ "$(move_production_function_contract treasury_cap_mut <<<"$launch_ticket_facts")" \
    != 'public:0:0:fun treasury_cap_mut<Meme, Witness: drop>( self: &mut LaunchTicket<Meme>, config: &LaunchConfig, _: Witness, ): &mut TreasuryCap<Meme>' ]] \
  || [[ "$(count_occurrences 'self\.migration_(witness|quote) = ' <<<"$launch_ticket_source")" != 2 ]] \
  || [[ "$(move_production_function_contract destroy <<<"$launch_ticket_facts")" \
    != 'package:0:0:fun destroy<Meme>( self: LaunchTicket<Meme>, currency: &mut Currency<Meme>, atomic_supply: u64, ): ( Balance<Meme>, MetadataCap<Meme>, CreatorAuthority<Meme>, Bps, )' ]] \
  || ! in_order \
    'meme.value()== atomic_supply && treasury_cap.total_supply()== atomic_supply' \
    'invalid_initial_meme_supply!()' \
    'currency.make_supply_burn_only(treasury_cap)' \
    'currency.make_supply_fixed(treasury_cap)' \
    <<<"$launch_ticket_destroy_body" \
  || [[ "$(count_occurrences 'make_supply_' <<<"$launch_ticket_source")" != 2 ]] \
  || ! in_order 'self.migration_witness == option::some(' 'invalid_migration_witness!()' '.assert_migration_witness_allowed(' '&mut self.treasury_cap' \
    <<<"$(move_production_body treasury_cap_mut <<<"$launch_ticket_facts" | move_semantic_shape)" \
  || [[ "$(count_occurrences '&mut self\.treasury_cap' <<<"$launch_ticket_source")" != 1 ]] \
  || rg -q '\b(UpgradeCap|CoinRegistry|PackageVersion|make_regulated|DenyCap|CoinMetadata)\b' <<<"$launch_ticket_source" \
  || rg -q '\btransfer::|\bentry fun\b' <<<"$launch_ticket_source"; then
  echo 'launch_ticket.move must create the currency from the generated package one-time witness, mint the canonical supply once, bind only an admitted adapter together with its Quote, lend the treasury capability only to the bound, still-admitted adapter, fix the supply mode only at intake after checking the whole minted supply, and custody the metadata cap and creator authority without package or registry inputs.' >&2
  failures=$((failures + 1))
fi
if [[ "$(rg -o '\.mint_balance\(' sources | wc -l)" != 1 ]] \
  || rg -n '\bcoin::mint(_balance)?\(' sources \
  || rg -n '\.mint_balance\(' sources --glob '!launch_ticket.move'; then
  echo 'The launch-ticket constructor must remain the only Meme mint site in the package.' >&2
  failures=$((failures + 1))
fi

if [[ "$(move_production_function_contract meme_total_supply_whole_tokens <<<"$constants_facts")" != 'package:0:1:fun meme_total_supply_whole_tokens(): u64' ]] \
  || [[ "$(move_production_body meme_total_supply_whole_tokens <<<"$constants_facts")" != '1_000_000_000' ]]; then
  echo 'Generated Meme supply must remain exactly one billion whole tokens at every admitted precision.' >&2
  failures=$((failures + 1))
fi

launch_ticket_event_payload="$(sed -n \
  -e '/^public struct LaunchTicketCreated/,/^}/p' \
  sources/lib/events.move)"

if [[ -z "$launch_ticket_event_payload" ]] \
  || ! rg -q '^[[:space:]]+decimals: u8,' <<<"$launch_ticket_event_payload" \
  || ! rg -q '^[[:space:]]+atomic_supply: u64,' <<<"$launch_ticket_event_payload" \
  || rg -n '\b(treasury_cap_id|sequence|schema_version|action_tag|nonce)\b' \
    <<<"$launch_ticket_event_payload"; then
  echo 'Launch-ticket creation must record minted supply, omit its consumed cap, and avoid duplicate ordering or schema fields.' >&2
  failures=$((failures + 1))
fi

allocation_facts="$(move_facts sources/allocation.move)"
allocation_source="$(move_normalized_source <<<"$allocation_facts")"
errors_facts="$(move_facts sources/lib/errors.move)"
launch_facts="$(move_facts sources/launch.move)"
launch_source="$(move_normalized_source <<<"$launch_facts")"
launch_production_bodies="$(awk -F'\t' '$1 == "FN" && $6 == 0 { print $10 }' <<<"$launch_facts")"
launch_production="$(sed '/^\/\/ === Test-Only Functions ===/,$d' sources/launch.move)"

# The allocation module is pure, canonical value validation and exact arithmetic.
# It cannot custody an asset, issue a cap, or choose an external recipient.
if [[ ! -f sources/allocation.move ]] \
  || [[ "$(move_production_type Channel <<<"$allocation_facts")" != 'struct Channel has copy, drop, store { channel_id: u64, role: ChannelRole, destination: address, }' ]] \
  || [[ "$(move_production_type Weight <<<"$allocation_facts")" != 'struct Weight has copy, drop, store { channel_id: u64, bps: Bps, }' ]] \
  || [[ "$(move_production_type AllocationPlan <<<"$allocation_facts")" != 'struct AllocationPlan has copy, drop, store { channels: vector<Channel>, meme: vector<Weight>, quote: vector<Weight>, }' ]] \
  || ! rg -Fq 'channels.insertion_sort_by!' sources/allocation.move \
  || ! rg -Fq 'meme.insertion_sort_by!' sources/allocation.move \
  || ! rg -Fq 'quote.insertion_sort_by!' sources/allocation.move \
  || ! rg -Fq 'sum == 10_000' sources/allocation.move \
  || ! rg -Fq 'liquidity_count == 1' sources/allocation.move \
  || ! rg -Fq 'protocol_count <= 1' sources/allocation.move \
  || ! rg -Fq 'product.div_ceil(10_000)' sources/allocation.move \
  || ! rg -Fq 'product / 10_000' sources/allocation.move \
  || ! rg -Fq 'remainder_a > remainder_b || (remainder_a == remainder_b && table[*a].channel_id <= table[*b].channel_id)' sources/allocation.move \
  || ! rg -Fq 'amounts.fold!(0, |sum, amount| sum + amount) == total' sources/allocation.move \
  || rg -q '\b(UID|Balance|Coin|TxContext|transfer::|object::)\b' <<<"$allocation_source"; then
  echo 'allocation.move must canonically validate the bounded plan and protect exact apportionment without custody, cap, or transfer effects.' >&2
  failures=$((failures + 1))
fi

# Intake validates the ticket against this generation's policy before any custody moves, keeps
# the native MetadataCap inline forever, and partitions Meme into the curve and pooled allocations.
launch_new_body="$(move_production_body new <<<"$launch_facts")"

if [[ ! -f sources/launch.move ]] \
  || [[ "$(move_production_function_contract new <<<"$launch_facts")" != 'public:0:0:fun new<Meme, Quote>( ticket: LaunchTicket<Meme>, currency: &mut Currency<Meme>, package_version: &PackageVersion, config: &LaunchConfig, graduation_target: u64, allocation_plan: AllocationPlan, protection_window_ms: u64, cumulative_sender_bps: Bps, per_transaction_bps: Bps, ctx: &mut TxContext, ): Launch<Meme, Quote>' ]] \
  || [[ "$launch_new_body" != *'.snapshot_for_launch<Quote>(ticket.migration_witness<'*'Quote>())'* ]] \
  || [[ "$launch_new_body" != *'type_name::with_original_ids<Meme>() != type_name::with_original_ids<Quote>()'* ]] \
  || [[ "$launch_new_body" != *'ticket.sell_burn_bps().value() <= constants::max_sell_burn_bps!()'* ]] \
  || [[ "$launch_new_body" != *'config.assert_allocation_policy(&allocation_plan);'* ]] \
  || [[ "$launch_new_body" != *'config.assert_decimals_allowed(decimals);'* ]] \
  || [[ "$launch_new_body" != *'let atomic_supply = launch_ticket::atomic_supply(decimals);'* ]] \
  || [[ "$launch_new_body" != *'ticket.destroy('*'atomic_supply'* ]] \
  || [[ "$launch_new_body" != *'let meme_amounts = allocation_plan.apportion_meme(atomic_supply);'* ]] \
  || [[ "$launch_new_body" != *'metadata_cap, creator_authority: option::some(creator_authority), curve_fee_authority: CurveFeeAuthority::Unassigned, blast_metadata_cap_id: option::none(), };'* ]] \
  || [[ "$(count_occurrences 'self\.creator_authority\.extract\(\)' <<<"$launch_source")" != 2 ]] \
  || [[ "$(count_occurrences 'self\.metadata_cap\b' <<<"$launch_source")" \
    != "$(count_occurrences '&self\.metadata_cap\b' <<<"$launch_source")" ]] \
  || rg -q '\bmetadata_cap\.(extract|swap|fill)\(|option::(some|none)\(metadata_cap\)|\bMetadataCap<Meme>\)' \
    <<<"$launch_source" \
  || rg -n '\bbps::new\(' sources/launch.move \
  || ! rg -Fq 'let burnable = currency.is_supply_burn_only();' sources/launch.move \
  || rg -q '\b(MigrationChannelCap|LaunchMigrationCap|MigrationChannelBalance|VenueSelection|venue_selection|vesting_id)\b' <<<"$launch_source" \
  || rg -n 'max_launch_fee_bps|invalid_(quote|meme)_fee_bps' sources/launch.move; then
  echo 'Launch intake must validate the pair, sell burn, allocation policy, decimals, and canonical supply before custody, keep the native MetadataCap inline, and carry no venue selection, per-channel custody, or vesting disclosure.' >&2
  failures=$((failures + 1))
fi

launch_authority_violations=''

# Sorted names of production launch functions whose body contains one fixed string.
launch_functions_containing() {
  awk -F'\t' -v needle="$1" '
    $1 == "FN" && $6 == 0 && index($10, needle) > 0 { print $2 }
  ' <<<"$launch_facts" | sort | tr '\n' ' '
}
# The custodian binding is published indexing API: the payload names the witness type.
if ! rg -U -q 'public struct CreatorFeesLocked has copy, drop \{\n    launch_id: ID,\n    curve_fee_cap_id: ID,\n    custodian: TypeName,\n\}' sources/lib/events.move; then
  echo 'CreatorFeesLocked must publish the launch, the destroyed curve-fee cap, and the custodian witness type.' >&2
  failures=$((failures + 1))
fi

# Each authority effect has one exact writer and reader set, so a new sibling or helper cannot
# record authority, claim from the creator ledger, revoke the pending claim, reach the native
# MetadataCap, or transfer value outside the approved paths (ADR 0082).
for authority_spec in \
  'self.curve_fee_authority = |claim_creator_caps lock_creator_fees reassign_curve_fee_cap ' \
  'self.blast_metadata_cap_id = |claim_creator_caps reassign_metadata_cap ' \
  'self.creator_authority.extract()|claim_creator_caps revoke_creator_authority ' \
  'self.revoke_creator_authority()|reassign_curve_fee_cap reassign_metadata_cap ' \
  'self.fee_ledger.claim_creator_fees(|claim_ledger_creator_fees ' \
  'self.claim_ledger_creator_fees(|claim_creator_fees claim_custodied_creator_fees ' \
  'self.assert_curve_fee_cap(|claim_creator_fees lock_creator_fees ' \
  'self.assert_fee_custodian(|claim_custodied_creator_fees ' \
  'CurveFeeAuthority::Custodian(|assert_fee_custodian is_custodian lock_creator_fees ' \
  'custodian_type<Custodian>()|lock_creator_fees ' \
  'self.assert_blast_metadata_cap(|set_description set_icon_url set_name ' \
  '&self.metadata_cap|set_description set_icon_url set_name ' \
  'transfer::public_transfer(|deliver_pending_setup_caps dispose_meme pay_allocations reassign_curve_fee_cap reassign_metadata_cap '; do
  authority_needle="${authority_spec%%|*}"
  authority_expected="${authority_spec#*|}"
  authority_actual="$(launch_functions_containing "$authority_needle")"

  if [[ "$authority_actual" != "$authority_expected" ]]; then
    launch_authority_violations+="  '${authority_needle}' is used by '${authority_actual}' instead of '${authority_expected}'"$'\n'
  fi
done
# The package-only cap constructors and claim revocation are reached only from the
# owning module and the launch that records the resulting authority.
if [[ "$(rg -l '\bnew_curve_fee_cap\b' sources | sort | tr '\n' ' ')" \
    != 'sources/creator_authority.move sources/launch.move ' ]] \
  || [[ "$(rg -l '\bnew_metadata_cap\b' sources | sort | tr '\n' ' ')" \
    != 'sources/creator_authority.move sources/launch.move ' ]] \
  || [[ "$(rg -o '\.revoke\(\)' sources | wc -l | tr -d ' ')" != 1 ]] \
  || [[ "$(rg -l '\.claim_creator_fees\(ctx\)' sources | tr '\n' ' ')" != 'sources/launch.move ' ]]; then
  launch_authority_violations+='  package-only creator capability constructors, claim revocation, or the ledger creator claim are reachable outside creator_authority.move and launch.move'$'\n'
fi

# T-004 keeps owned construction permissionless while creator authentication
# remains post-share. The exact config cap is wrapped, never replaced, and only
# an authenticated claim or the existing first takeover can remove it.
for setup_spec in \
  'self.router_config_cap.fill(|share ' \
  'self.router_config_cap.extract()|claim_setup_caps deliver_pending_setup_caps ' \
  'self.deliver_pending_setup_caps(|reassign_curve_fee_cap reassign_metadata_cap ' \
  'self.claim_creator_caps(|claim_setup_caps ' \
  'self.public_start_ms = |share ' \
  'self.pre_share_buy_completed = |execute_buy ' \
  'clock.timestamp_ms()|buy share ' \
  'self.execute_buy(|buy pre_share_buy ' \
  'curve::cap_buy_quote_input(|execute_buy ' \
  'curve::quote_buy(|execute_buy ' \
  'transfer::share_object(self)|share ' \
  'events::launch_shared(|share ' \
  'events::pre_share_bought(|execute_buy ' \
  'events::bought(|execute_buy ' \
  'events::router_config_cap_released(|claim_setup_caps ' \
  'events::router_config_cap_delivered(|deliver_pending_setup_caps ' \
  'self.protection_end_ms = |share ' \
  'events::protection_configured(|new ' \
  'self.assert_protected_purchase(|execute_buy ' \
  'self.record_protected_purchase(|execute_buy ' \
  '.add_dynamic_field(|record_protected_purchase ' \
  '.dynamic_field_mut|record_protected_purchase ' \
  'dynamic_field::|'; do
  setup_needle="${setup_spec%%|*}"
  setup_expected="${setup_spec#*|}"
  setup_actual="$(launch_functions_containing "$setup_needle")"
  if [[ "$setup_actual" != "$setup_expected" ]]; then
    launch_authority_violations+="  T-004 '${setup_needle}' is used by '${setup_actual}' instead of '${setup_expected}'"$'\n'
  fi
done

for setup_visibility in \
  'share:public' 'claim_setup_caps:public' 'pre_share_buy:public' \
  'public_start_ms:public' 'pre_share_buy_completed:public' \
  'claim_creator_caps:private' 'deliver_pending_setup_caps:private' 'execute_buy:private' \
  'assert_protected_purchase:private' 'record_protected_purchase:private'; do
  setup_name="${setup_visibility%%:*}"
  setup_contract="$(move_production_function_contract "$setup_name" <<<"$launch_facts")"
  if [[ "$setup_contract" != "${setup_visibility#*:}:0:0:fun "* ]]; then
    launch_authority_violations+="  T-004 ${setup_name} has widened or missing visibility"$'\n'
  fi
done

launch_owned_sinks="$(awk -F'\t' '
  $1 == "FN" && $6 == 0 && $9 ~ /[(,] (mut )?[A-Za-z_][A-Za-z0-9_]*: Launch</ { print $2 }
' <<<"$launch_facts" | sort | tr '\n' ' ')"
launch_buy_body="$(move_semantic_shape <<<"$(move_production_body execute_buy <<<"$launch_facts")")"

if [[ "$launch_owned_sinks" != 'share ' ]] \
  || ! in_order 'pre_share_buy_would_graduate!()' 'quote_in.into_balance()' <<<"$launch_buy_body"; then
  launch_authority_violations+='  T-004 must share through one key-only sink and reject graduation before any pre-share balance movement'$'\n'
fi
# T-005 checks a protected purchase after slippage and before any balance moves, and records it
# only after the curve mutation.
if ! in_order 'slippage_exceeded!()' 'self.assert_protected_purchase(' 'quote_in.into_balance()' \
  'self.record_protected_purchase(' <<<"$launch_buy_body"; then
  launch_authority_violations+='  T-005 must check protected purchases after slippage and before custody, and record them after the curve mutation'$'\n'
fi
# T-005 reaches sender records only through these four module-local aliases. With no remove alias,
# module-form call, member import, or module alias, no path can delete a record.
launch_dynamic_field_aliases="$(rg -o 'use fun [^;]*dynamic_field[^;]*;' <<<"$launch_source" \
  | LC_ALL=C sort | tr '\n' ' ')"
if [[ "$launch_dynamic_field_aliases" != 'use fun dynamic_field::add as UID.add_dynamic_field; use fun dynamic_field::borrow as UID.dynamic_field; use fun dynamic_field::borrow_mut as UID.dynamic_field_mut; use fun dynamic_field::exists as UID.has_dynamic_field; ' ]] \
  || [[ "$(count_occurrences 'dynamic_field::' <<<"$launch_source")" != 4 ]] \
  || rg -q '\bdynamic_field as\b' <<<"$launch_source"; then
  launch_authority_violations+='  T-005 must reach sender records only through the add, borrow, borrow_mut, and exists aliases'$'\n'
fi
for move_file in "${source_files[@]}"; do
  setup_source="$(move_facts "$move_file" | move_normalized_source)"
  if rg -q '\b(CreatorSetupReceipt|blast_fun_vesting|blast_fun_linear_vesting|blast_fun_checkpoint_vesting)\b' <<<"$setup_source"; then
    launch_authority_violations+="  ${move_file} introduces a setup receipt or vesting dependency"$'\n'
  fi
done
if rg -q 'vesting' Move.toml; then
  launch_authority_violations+='  launchpad must not import the independently composed vesting package'$'\n'
fi

if [[ -n "$launch_authority_violations" ]]; then
  printf '%s' "$launch_authority_violations"
  echo 'Launch creator authority must stay split per concern: only the recorded CurveFeeCap or bound custodian claims creator fees, only the recorded BlastMetadataCap edits metadata through the retained MetadataCap, and only a version-gated creator admin reassigns, rejecting locked fees first.' >&2
  failures=$((failures + 1))
fi

if [[ "$(launch_functions_containing 'events::migration_allocation_paid(')" != 'pay_allocations ' ]] \
  || [[ "$(launch_functions_containing 'events::migrated(')" != 'complete_migration ' ]]; then
  echo 'Allocation payouts and migration completion must be replayed only by their owning functions.' >&2
  failures=$((failures + 1))
fi
if rg -n '\bstate_version\b|launch_state_version' sources tests; then
  echo 'PackageVersion must remain the only operational version; Launch state and events must not add another one.' >&2
  failures=$((failures + 1))
fi

# Every production function that takes the shared PackageVersion checks it as its first
# statement, and no public function reaching mutable shared state escapes that guard.
version_guard_violations="$(
  for move_file in "${source_files[@]}"; do
    move_facts "$move_file" | awk -F'\t' -v file="$move_file" '
      $1 == "FN" && $6 == 0 && $9 ~ /[(,] package_version: &PackageVersion,/ \
        && $10 !~ /^package_version\.assert_current\(\);/ {
        print "  " file ": " $2 " must check the live package version as its first statement"
      }
      $1 == "FN" && $6 == 0 && $3 == "public" \
        && ($9 ~ /: &mut (Launch|Currency|FeeRouter)</ || $9 ~ /: &mut (LaunchConfig|RuntimeConfig|LpFeePolicy|PackageAdmin),/) \
        && $9 !~ /[(,] package_version: &(mut )?PackageVersion,/ {
        print "  " file ": " $2 " reaches mutable shared state without PackageVersion"
      }
    '
  done
)"

if [[ -n "$version_guard_violations" ]]; then
  printf '%s\n' "$version_guard_violations"
  echo 'Every accepted shared-object mutation and every launch-held metadata edit must check the one PackageVersion as its first statement.' >&2
  failures=$((failures + 1))
fi
# Reads call-normalized text, so whitespace around `::` or before an argument
# list cannot disguise a module-form call as anything other than what it is.
receiver_syntax_violations="$(
  for move_file in "${move_files[@]}"; do
    { move_facts "$move_file" \
      | move_normalized_source \
      | sed 's/ *:: */::/g; s/ *(/(/g' \
      | rg -o \
        '\b(acl::(grant_admin|revoke_admin|destroy_admin_cap|begin_super_admin_transfer|cancel_super_admin_transfer|accept_super_admin_transfer|destroy_retired_super_admin_cap|sign_in)|runtime_config::(set_creator_claim_signer|revoke_creator_claim_signer|set_protocol_fee_share|assert_creator_claim_active|assert_creator_claim_signature|protocol_fee_share)|launch_config::(allow_meme_decimals|disallow_meme_decimals|allow_quote|disallow_quote|set_trade_fees|set_protocol_allocation|allow_migration_witness|disallow_migration_witness|assert_allocation_policy|assert_migration_witness_allowed|snapshot_for_launch|allowed_meme_decimals_count_for_testing|allowed_quote_count_for_testing|allowed_migration_witness_count_for_testing)|allocation::(channels|meme_weights|quote_weights|liquidity_channel_id|assert_protocol_policy|apportion_meme|apportion_quote|channel_id|destination|weight_channel_id|weight_bps)|launch::(share|allocation_plan|claim_creator_caps|reassign_curve_fee_cap|reassign_metadata_cap|lock_creator_fees|claim_custodied_creator_fees|assert_fee_custodian|assert_curve_fee_cap|set_name|set_description|set_icon_url)|creator_authority::(into_authority|recipient_address|account_commitment|claim_creator_caps|revoke|destroy_curve_fee_cap|destroy_metadata_cap)|launch_ticket::(destroy|bind_migration_witness|treasury_cap_mut|migration_witness)|fees::(accrue|accrue_protocol_fees|has_protocol_fees|claim_creator_fees|claim_protocol_fees)|package::test_upgrade|package_admin::(authorize_upgrade|commit_upgrade|restrict_to_additive|restrict_to_dependency_only|publisher_id_for_testing|upgrade_cap_id_for_testing|package_id_for_testing|version_for_testing|policy_for_testing))(<[^>]+>)?\(' \
      || true; } | sed "s|^|  ${move_file}: |"
  done
)"

if [[ -n "$receiver_syntax_violations" ]]; then
  printf '%s\n' "$receiver_syntax_violations"
  echo 'Blast-owned receiver functions must use Move 2024 dot syntax.' >&2
  failures=$((failures + 1))
fi

if rg -n '^[[:space:]]+assert_launch_snapshot\(&|=[[:space:]]*reach_migration_after_sell\(' \
  tests/launch_tests.move; then
  echo 'Launch test helpers with a natural Launch receiver must use dot syntax.' >&2
  failures=$((failures + 1))
fi

if rg -n '\bsui::tx_context::TxContext\b' sources tests; then
  echo 'Natural framework and private receivers must use implicit types and dot syntax.' >&2
  failures=$((failures + 1))
fi

if rg -n \
  'RuntimeConfig|ed25519|creator_claim_signer|verify_creator_claim|CreatorCap|CurveFeeCap|BlastMetadataCap|issue_creator_cap' \
  sources/blast_fun_domain.move; then
  echo 'blast_fun_domain.move must own only the domain marker, its constants, and its role.' >&2
  failures=$((failures + 1))
fi

if rg -n '\b(add_admin|AdminAdded|QuoteRemoved|MigrationWitnessRemoved)\b' sources tests \
  || rg -n '\b(active_quote_count_for_testing|migration_witness_count_for_testing)\b' sources tests; then
  echo 'Package interfaces must use grant/revoke authority and allow/disallow whitelist vocabulary.' >&2
  failures=$((failures + 1))
fi

if rg -n 'destroy_admin_cap_for_testing' sources tests; then
  echo 'AdminCap holders must use the production self-destruction path.' >&2
  failures=$((failures + 1))
fi

# The reusable ACL replay schema now belongs to blast_admin; this package must
# not re-declare or re-emit any part of it.
if rg -n '^public struct (AdminGranted|AdminRevoked|AdminDestroyed|SuperAdminTransferStarted|SuperAdminTransferCancelled|SuperAdminTransferred|AuthorityCreated)\b' \
  sources/lib/events.move \
  || rg -n 'events::(admin_granted|admin_revoked|admin_destroyed|super_admin_)' sources; then
  echo 'Reusable ACL events must come from blast_admin, not a consumer copy.' >&2
  failures=$((failures + 1))
fi

creator_authority_facts="$(move_facts sources/creator_authority.move)"

# Each creator capability is an identity-only object whose one production
# constructor and one destructor live in this module (ADR 0082). LP-fee
# capability authority left for `blast_fun_migrators` (ADR 0083).
creator_capability_violations=''
for capability_spec in \
  'CurveFeeCap|new_curve_fee_cap|destroy_curve_fee_cap' \
  'BlastMetadataCap|new_metadata_cap|destroy_metadata_cap'; do
  IFS='|' read -r capability_type capability_constructor capability_destructor <<<"$capability_spec"

  if [[ "$(move_production_type "$capability_type" <<<"$creator_authority_facts")" \
      != "struct ${capability_type}<phantom Meme> has key, store { id: UID, }" ]]; then
    creator_capability_violations+="  ${capability_type} is not an identity-only key, store capability"$'\n'
  fi
  if [[ "$(awk -F'\t' -v needle="${capability_type} { id: object::new(ctx) }" '
      $1 == "FN" && $6 == 0 && index($10, needle) > 0 { print $2 }
    ' <<<"$creator_authority_facts" | tr '\n' ' ')" != "${capability_constructor} " ]]; then
    creator_capability_violations+="  ${capability_type} is not constructed only by ${capability_constructor}"$'\n'
  fi
  if [[ "$(move_production_signature "$capability_destructor" <<<"$creator_authority_facts")" \
      != "fun ${capability_destructor}<Meme>(self: ${capability_type}<Meme>)" ]] \
    || [[ "$(move_semantic_shape <<<"$(move_production_body "$capability_destructor" <<<"$creator_authority_facts")")" \
      != "$(move_semantic_shape <<<"let ${capability_type} { id } = self; id.delete();")" ]]; then
    creator_capability_violations+="  ${capability_destructor} is not the approved holder self-destruction"$'\n'
  fi
done

if [[ -n "$creator_capability_violations" ]]; then
  printf '%s' "$creator_capability_violations"
  echo 'creator_authority.move must own CurveFeeCap<Meme> and BlastMetadataCap<Meme> construction and holder destruction.' >&2
  failures=$((failures + 1))
fi

if ! rg -U -q \
  'public enum CreatorRecipient has drop, store \{\s*Address\(address\),\s*Account\(vector<u8>\),\s*\}' \
  sources/creator_authority.move \
  || ! rg -U -q \
    'public struct CreatorAuthority<phantom Meme> has store \{\s*recipient: CreatorRecipient,\s*\}' \
    sources/creator_authority.move \
  || ! rg -U -q \
    'public fun new_address\(recipient: address\): CreatorRecipient' \
    sources/creator_authority.move \
  || ! rg -U -q \
    'public fun new_account\(account_commitment: vector<u8>\): CreatorRecipient' \
    sources/creator_authority.move \
  || ! rg -U -q \
    'public\(package\) fun into_authority<Meme>\(\s*self: CreatorRecipient,\s*\): CreatorAuthority<Meme>' \
    sources/creator_authority.move \
  || rg -U -n 'public fun new_(address|account).*CreatorAuthority' \
    sources/creator_authority.move; then
  echo 'Public creator constructors must create composable recipients; only package code may mint linear coin-typed creator authority.' >&2
  failures=$((failures + 1))
fi

creator_authority_production="$(sed '/^\/\/ === Test-Only Functions ===/,$d' sources/creator_authority.move)"
creator_authority_source="$(move_normalized_source <<<"$creator_authority_facts")"

# Without LP-fee issuance (ADR 0083) creator authority is neither version- nor
# admin-gated: claims are signer-authorized and reassignment is gated in launch.
if rg -n '\b[a-z_]*claimed:[[:space:]]*bool|\bissue_creator_cap\b|\btransfer::' \
  <<<"$creator_authority_production" \
  || rg -q '\bMetadataCap\b|\bcoin_registry\b' <<<"$creator_authority_source" \
  || rg -q '\b(AdminWitness|BLAST_FUN_DOMAIN|blast_fun_domain|PackageVersion|package_version|assert_role)\b' \
    <<<"$creator_authority_source" \
  || [[ "$(rg -c '^use blast_fun::' sources/creator_authority.move)" != 1 ]] \
  || ! rg -Fxq 'use blast_fun::{constants, events, runtime_config::RuntimeConfig};' sources/creator_authority.move \
  || [[ "$(move_production_function_contract claim_creator_caps <<<"$creator_authority_facts")" != 'package:0:0:fun claim_creator_caps<Meme>( self: CreatorAuthority<Meme>, config: &RuntimeConfig, account_attestation: Option<vector<u8>>, clock: &Clock, ctx: &mut TxContext, ): (CurveFeeCap<Meme>, BlastMetadataCap<Meme>)' ]] \
  || [[ "$(move_production_function_contract new_curve_fee_cap <<<"$creator_authority_facts")" \
    != 'package:0:0:fun new_curve_fee_cap<Meme>(ctx: &mut TxContext): CurveFeeCap<Meme>' ]] \
  || [[ "$(move_production_function_contract new_metadata_cap <<<"$creator_authority_facts")" \
    != 'package:0:0:fun new_metadata_cap<Meme>(ctx: &mut TxContext): BlastMetadataCap<Meme>' ]] \
  || [[ "$(move_production_function_contract revoke <<<"$creator_authority_facts")" \
    != 'package:0:0:fun revoke<Meme>(self: CreatorAuthority<Meme>)' ]]; then
  echo 'Creator-authority claims must consume CreatorAuthority and return exactly one CurveFeeCap and one BlastMetadataCap, and the module must import only constants, events, and RuntimeConfig, with no version or admin gate, native MetadataCap pass-through, flag, wrapper, or transfer.' >&2
  failures=$((failures + 1))
fi
if rg -n 'schema_version|action_tag|nonce' sources/creator_authority.move; then
  echo 'The one-time creator claim must not duplicate its fixed type and consumed marker.' >&2
  failures=$((failures + 1))
fi

if rg -l '^public struct RuntimeConfig has key' sources \
  | rg -v '^sources/runtime_config\.move$'; then
  echo 'RuntimeConfig is declared outside its owning module.' >&2
  failures=$((failures + 1))
fi

if rg -l '^public struct (CurveFeeCap|BlastMetadataCap)\b' sources \
  | rg -v '^sources/creator_authority\.move$' \
  || rg -n '\bCreatorCap\b|\bclaim_creator_cap\b|\bcreator_cap_claimed\b|\bCreatorCapClaimed\b' sources; then
  echo 'Creator capabilities are declared outside their owning module, or the irrevocable possession-only CreatorCap was reintroduced.' >&2
  failures=$((failures + 1))
fi

# T-007/T-008/T-009: the recurring router custodies nothing. Every collection pays the protocol
# destination and every route destination in the same call, configuration is Pending-only
# through the one config capability, and active route changes settle through the bound
# adapter's private witness. The one-time-witness Meme type makes the launch, router, and
# capability unique, so no cross-object ID check is pinned.
fee_router_facts="$(move_facts sources/fee_router.move)"
fee_router_source="$(move_normalized_source <<<"$fee_router_facts")"
lp_fee_policy_facts="$(move_facts sources/lp_fee_policy.move)"
lp_fee_policy_source="$(move_normalized_source <<<"$lp_fee_policy_facts")"

router_public_mutations="$(awk -F'\t' '
  $1 == "FN" && $6 == 0 && $3 == "public" && $9 ~ /self: &mut FeeRouter</ { print $2 }
' <<<"$fee_router_facts" | sort | tr '\n' ' ')"
router_public_sinks="$(
  for move_file in "${source_files[@]}"; do
    move_facts "$move_file" | awk -F'\t' -v file="$move_file" '
      $1 == "FN" && $6 == 0 && $3 == "public" \
        && $9 ~ /[,(] [A-Za-z_][A-Za-z0-9_]*: FeeRouter</ {
        print file ":" $2
      }
    '
  done | sort
)"
router_payers="$(awk -F'\t' '
  $1 == "FN" && $6 == 0 && index($10, "transfer::public_transfer(") > 0 { print $2 }
' <<<"$fee_router_facts" | sort | tr '\n' ' ')"
router_distributors="$(awk -F'\t' '
  $1 == "FN" && $6 == 0 && index($10, "self.distribute(") > 0 { print $2 }
' <<<"$fee_router_facts" | sort | tr '\n' ' ')"
router_config_cap_issuers="$(awk -F'\t' '
  $1 == "FN" && $6 == 0 && $10 ~ /RouterConfigCap \{ id: object::new/ { print $2 }
' <<<"$fee_router_facts" | sort | tr '\n' ' ')"
router_activators="$(awk -F'\t' '
  $1 == "FN" && $6 == 0 && index($10, "self.lifecycle = Lifecycle::Active") > 0 { print $2 }
' <<<"$fee_router_facts" | sort | tr '\n' ' ')"

if [[ ! -f sources/fee_router.move || ! -f sources/lp_fee_policy.move ]] \
  || rg -q 'Balance<|Table<|Bag\b|dynamic_field' <<<"$(move_production_type FeeRouter <<<"$fee_router_facts")" \
  || [[ "$(move_production_type RouterConfigCap <<<"$fee_router_facts")" != *' has key, store {'* ]] \
  || [[ "$router_public_mutations" != 'collect configure settle_and_update_routes ' ]] \
  || [[ "$router_public_sinks" != 'sources/launch.move:share' ]] \
  || [[ "$(rg -l '\bfee_router::new\(' sources --glob '*.move' | sort | tr '\n' ' ')" != 'sources/launch.move ' ]] \
  || [[ "$router_config_cap_issuers" != 'new ' ]] \
  || [[ "$router_activators" != 'activate ' ]] \
  || [[ "$(move_production_function_contract activate <<<"$fee_router_facts")" != package:0:0:fun\ activate* ]] \
  || [[ "$(launch_functions_containing 'router.activate<')" != 'complete_migration ' ]] \
  || [[ "$(launch_functions_containing 'router.share()')" != 'share ' ]]; then
  echo 'Only Launch may create, activate, and terminally share a FeeRouter; the router custodies no balances, issues one config capability, and admits public mutation only through Pending configuration and the bound adapter witness.' >&2
  failures=$((failures + 1))
fi

# Collection is exact and immediate: the protocol share rounds up, both route tables are
# apportioned by the one allocation implementation, every destination is paid in the same call,
# and nothing stays behind. Routes are replaced only after the outstanding collection is paid.
if [[ "$router_payers" != 'pay ' ]] \
  || [[ "$router_distributors" != 'collect settle_and_update_routes ' ]] \
  || [[ "$(count_occurrences 'self\.assert_settlement<' <<<"$fee_router_source")" != 2 ]] \
  || [[ "$(count_occurrences 'transfer::public_transfer\(' <<<"$fee_router_source")" != 1 ]] \
  || [[ "$(rg -l 'fun apportion_routes' sources --glob '*.move' | sort | tr '\n' ' ')" != 'sources/allocation.move ' ]] \
  || ! in_order 'self.assert_settlement<' 'self.distribute(' 'self.commit_routes(' \
    <<<"$(move_production_body settle_and_update_routes <<<"$fee_router_facts")"; then
  echo 'FeeRouter collection must pay the round-up protocol share and every route destination immediately through one apportionment implementation, leave no custody behind, and settle outstanding fees under the old routes before committing new ones.' >&2
  failures=$((failures + 1))
fi

# Policy is future-only administration keyed by original Meme identity. It selects one complete
# default-or-partner pair at activation and names the live protocol destination. The three
# readers take the policy immutably, so the four admin setters stay its only mutations.
policy_state_functions="$(awk -F'\t' '
  $1 == "FN" && $6 == 0 && $10 ~ /self\.(defaults|partners|destination)/ { print $2 }
' <<<"$lp_fee_policy_facts" | sort | tr '\n' ' ')"

if [[ "$policy_state_functions" != 'clear_partner_shares default_shares protocol_destination set_default_shares set_partner_shares set_protocol_destination snapshot ' ]] \
  || [[ "$(move_production_function_contract snapshot <<<"$lp_fee_policy_facts")" \
    != 'public:0:0:fun snapshot<Meme>(self: &LpFeePolicy): PolicySnapshot' ]] \
  || [[ "$(move_production_function_contract default_shares <<<"$lp_fee_policy_facts")" \
    != 'public:0:0:fun default_shares(self: &LpFeePolicy): (Bps, Bps)' ]] \
  || [[ "$lp_fee_policy_source" != *'type_name::with_original_ids<Meme>()'* ]] \
  || [[ "$lp_fee_policy_source" != *'destination != @0x0 && destination != self.destination'* ]] \
  || [[ "$(move_production_function_contract protocol_destination <<<"$lp_fee_policy_facts")" \
    != 'public:0:0:fun protocol_destination(self: &LpFeePolicy): address' ]]; then
  echo 'LP-fee policy must be an original-Meme-keyed, admin/version-gated future policy that snapshots one complete default-or-partner pair at router activation and redirects only future protocol payouts.' >&2
  failures=$((failures + 1))
fi

# T-010: one linear migration value, the stored adapter witness checked on both ends, vault
# and position identities derived from the actual key objects (the adapter reads the pool
# identity from its venue position), every handed-off unit accounted for, and
# Migrated committed last. Only order anchors are pinned, never whole statements.
migration_returners="$(for file in "${source_files[@]}"; do move_facts "$file"; done \
  | awk -F'\t' '$1 == "FN" && $6 == 0 && $9 ~ /\):.*Migration</ { print $2 }' | sort | tr '\n' ' ')"
complete_migration_signature="$(move_production_signature complete_migration <<<"$launch_facts")"
complete_migration_body="$(move_production_body complete_migration <<<"$launch_facts" | move_semantic_shape)"
begin_migration_body="$(move_production_body begin_migration <<<"$launch_facts" | move_semantic_shape)"

if [[ "$(move_production_type Migration <<<"$launch_facts")" == *' has '* ]] \
  || [[ "$migration_returners" != 'begin_migration ' ]] \
  || [[ "$(launch_functions_containing 'Migration {')" != 'begin_migration complete_migration ' ]] \
  || [[ "$(launch_functions_containing 'self.assert_migration_witness<')" != 'begin_migration complete_migration ' ]] \
  || [[ "$(launch_functions_containing 'self.lifecycle = Lifecycle::Migrating;')" != 'begin_migration ' ]] \
  || [[ "$(launch_functions_containing 'self.lifecycle = Lifecycle::Migrated;')" != 'complete_migration ' ]] \
  || ! in_order \
    'package_version.assert_current();' \
    'Lifecycle::MigrationReady' \
    'self.assert_migration_witness<' \
    'self.allocated_meme.split(' \
    'self.real_quote_reserve.split(' \
    'self.lifecycle = Lifecycle::Migrating;' \
    'Migration{' \
    <<<"$begin_migration_body" \
  || [[ "$complete_migration_signature" =~ (vault|position)_id:\ ID ]] \
  || [[ "$complete_migration_signature" != *' pool_id: ID,'* ]] \
  || ! in_order \
    'package_version.assert_current();' \
    'self.assert_migration_witness<' \
    'Migration{' \
    'migration_settlement_mismatch!()' \
    'router.activate<' \
    'object::id(vault)' \
    'pool_id' \
    'object::id(position)' \
    'self.pay_allocations(' \
    'dispose_meme(' \
    'self.lifecycle = Lifecycle::Migrated;' \
    'events::migrated(' \
    <<<"$complete_migration_body" \
  || [[ ! "${complete_migration_body#*self.lifecycle = Lifecycle::Migrated;}" =~ ^events::migrated\([^\;]*\)\;$ ]] \
  || ! in_order '.do_ref!(' 'allocation_sum_invalid!()' \
    <<<"$(move_production_body pay_allocations <<<"$launch_facts" | move_semantic_shape)"; then
  echo 'T-010 must keep the migration value linear, check the stored adapter witness at begin and completion, derive vault and position identities from the actual objects and take the pool identity from the adapter, account for every handed-off unit, pay every other allocation, and commit Migrated last.' >&2
  failures=$((failures + 1))
fi

# T-013: each success event in the replay schema is emitted only after the state write or native
# transfer it records, inside its writer's own production body. Only order anchors are pinned:
# the written field, the called operation, or the constructed type, never a local or argument name.
events_follow_mutations() {
  local file="$1" function="$2"
  shift 2

  in_order "$@" <<<"$(move_facts "$file" | move_production_body "$function" | move_semantic_shape)"
}

# FeesCollected follows both drained balances, whichever local names hold them.
fees_collected_body="$(move_facts sources/fee_router.move | move_production_body distribute | move_semantic_shape)"

if ! events_follow_mutations sources/launch_ticket.move new 'LaunchTicket{' 'events::launch_ticket_created<' \
  || ! events_follow_mutations sources/launch.move new 'Launch{' 'events::launch_created<' \
  || ! events_follow_mutations sources/launch.move new_fee_router \
    'self.fee_router_id = option::some(' 'events::fee_router_created(' \
  || ! events_follow_mutations sources/launch.move execute_buy \
    'self.real_quote_reserve.join(' \
    'self.meme_reserve.split(' \
    'self.accrue_trade_fees(' \
    'self.pre_share_buy_completed = true;' \
    'events::pre_share_bought(' \
    'events::bought(' \
  || ! events_follow_mutations sources/launch.move share 'transfer::share_object(' 'events::launch_shared(' \
  || ! events_follow_mutations sources/launch.move claim_setup_caps \
    'self.router_config_cap.extract()' 'events::router_config_cap_released(' \
  || ! events_follow_mutations sources/launch.move deliver_pending_setup_caps \
    'transfer::public_transfer(' 'events::router_config_cap_delivered(' \
  || ! events_follow_mutations sources/launch.move pay_allocations \
    'self.allocated_meme.split(' \
    'self.real_quote_reserve.split(' \
    'events::migration_allocation_paid(' \
  || ! events_follow_mutations sources/fee_router.move activate \
    'self.lifecycle = Lifecycle::Active{' 'events::router_activated(' \
  || ! events_follow_mutations sources/fee_router.move distribute 'events::fees_collected(' \
  || [[ "$(count_occurrences '\.destroy_zero\(\);' <<<"${fees_collected_body%%"events::fees_collected("*}")" != 2 ]] \
  || ! events_follow_mutations sources/fee_router.move commit_routes \
    'self.routes = ' 'self.generation = ' 'events::routes_changed(' \
  || ! events_follow_mutations sources/lp_fee_policy.move set_protocol_destination \
    'self.destination = ' 'events::lp_fee_destination_changed(' \
  || ! events_follow_mutations sources/lp_fee_policy.move set_default_shares \
    'self.defaults = ' 'events::lp_fee_policy_changed(' \
  || ! events_follow_mutations sources/lp_fee_policy.move set_partner_shares \
    'self.partners.add(' 'events::lp_fee_policy_changed(' \
  || ! events_follow_mutations sources/lp_fee_policy.move clear_partner_shares \
    'self.partners.remove(' 'events::lp_fee_policy_changed(' \
  || ! events_follow_mutations sources/launch_config.move set_protocol_allocation \
    'self.protocol_allocation = option::some(' 'events::protocol_allocation_configured('; then
  echo 'Every replay-schema success event must follow the state write or native transfer it records.' >&2
  failures=$((failures + 1))
fi

if ((failures != 0)); then
  exit 1
fi

echo 'Source module boundaries and Move style: OK'
