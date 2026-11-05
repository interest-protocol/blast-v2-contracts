#!/usr/bin/env bash

set -euo pipefail

cd "$(dirname "$0")/.."

failures=0
python3 ../../scripts/check_admin_delay.py

if ! bash scripts/check_error_registry.sh; then
  failures=$((failures + 1))
fi

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
mapfile -t test_files < <(find tests -type f -name '*.move' -print | sort)

# Launchpad errors have one registry; raw event payloads are constructed and emitted only in
# events.move, with no envelope.
for move_file in "${source_files[@]}"; do
  if [[ "$move_file" != sources/lib/errors.move ]] \
    && rg -n '#\[error\(|^[[:space:]]*const E[A-Z]' "$move_file"; then
    echo "${move_file}: define launchpad errors in sources/lib/errors.move." >&2
    failures=$((failures + 1))
  fi
  if [[ "$move_file" != sources/lib/events.move ]] \
    && rg -n '\bevent::emit\b|\bblast_events\b|\bemit_event\b' "$move_file"; then
    echo "${move_file}: construct event payloads only in sources/lib/events.move." >&2
    failures=$((failures + 1))
  fi
done

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
  { rg -o 'self\.(protocol|creator)_(meme|quote|sui)\.[a-z_0-9]+\(' || true; } \
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
      /^use fun / { previous = $0; next }
      /^use / && previous != "#[test_only]" {
        root = $2;
        sub(/::.*/, "", root);
        count[root] += 1;
      }
      { previous = $0 }
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
  echo 'Imports from one root address must use one nested declaration per module; a #[test_only] import stands alone.' >&2
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
    sources/launch/launch.move sources/config/launch_config.move sources/lib/events.move \
    | rg -v ':use fun$' | sed 's/.*use //' | sort -u
)"
if [[ "$core_import_roots" != $'blast_admin\nblast_core\nblast_fun\nblast_partners\nstd\nsui' ]] \
  || [[ "$(sed -n '/^\[dependencies\]/,/^\[/p' Move.toml | rg -o '^[A-Za-z_][A-Za-z0-9_]*[[:space:]]*=' | sed 's/[[:space:]]*=//' | sort)" != $'blast_admin\nblast_core\nblast_partners' ]]; then
  echo 'Provider-neutral launch state, config, and events may import only local modules, std, Sui, blast_admin, blast_core, and blast_partners.' >&2
  failures=$((failures + 1))
fi

if rg -ni '\b(referral|referrer|affiliate)\b' sources --glob '*.move'; then
  echo 'Launch config, state, and events must not depend on referral attribution.' >&2
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

# Basis points and their exact apportionment are blast_core's (its own gate pins them): the
# launchpad declares no rate type or apportionment of its own and imports `Bps` only from there.
if [[ -e sources/lib/bps.move ]] \
  || rg -n '^public struct Bps\b|^(public(\(package\))? )?fun apportion\(' sources --glob '*.move' \
  || [[ -n "$(for move_file in "${move_files[@]}"; do
    rate_source="$(move_facts "$move_file" | move_normalized_source)"
    if rg -q '\bblast_fun::bps\b|use blast_fun::\{[^;]*\bbps\b' <<<"$rate_source" \
      || { rg -q '\bBps\b' <<<"$rate_source" \
        && ! rg -q 'use blast_core::bps::' <<<"$rate_source" \
        && ! rg -q 'use blast_core::\{[^;]*\bbps::' <<<"$rate_source"; }; then
      echo "$move_file"
    fi
  done)" ]]; then
  echo 'Launchpad rates must be blast_core::bps::Bps, with no local rate type, copy, or apportionment.' >&2
  failures=$((failures + 1))
fi

# Every module must delegate the inclusive range to bps::new, in either
# operand order; stricter policy bounds stay allowed.
for move_file in "${source_files[@]}"; do
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

blast_facts="$(move_facts sources/blast_fun.move)"

# The OTW hands the deployer one owned generic Publication pinning the package witness;
# blast_admin::package_admin::wrap seals the native capabilities and shares
# PackageVersion<BLAST_FUN>, fully paused. This package keeps no publication, version, pause, or
# custody state of its own; its one-time-witness module owns the package witness and its one package-only
# constructor.
if [[ ! -f sources/blast_fun.move ]] \
  || [[ -e sources/package_admin.move || -e sources/blast_fun_domain.move ]] \
  || [[ "$(move_production_type BLAST_FUN <<<"$blast_facts")" != 'struct BLAST_FUN() has drop;' ]] \
  || [[ "$(move_production_type PackageWitness <<<"$blast_facts")" != 'struct PackageWitness() has drop;' ]] \
  || [[ "$(awk -F'\t' '$1 == "TYPE" && $5 == 0 { print $2 }' <<<"$blast_facts" | LC_ALL=C sort | tr '\n' ' ')" != 'BLAST_FUN PackageWitness ' ]] \
  || [[ "$(move_production_functions <<<"$blast_facts")" != 'init:private:0 package_witness:package:0 ' ]] \
  || [[ "$(move_production_body init <<<"$blast_facts")" \
    != 'package_version::new_publication<_, PackageWitness>(otw, constants::valid_pause_bits!(), ctx).keep(ctx);' ]] \
  || [[ "$(move_production_function_contract package_witness <<<"$blast_facts")" \
    != 'package:0:0:fun package_witness(): PackageWitness' ]] \
  || [[ "$(move_production_body package_witness <<<"$blast_facts")" != 'PackageWitness()' ]] \
  || rg -n '\b(OperationalVersion|operational_version|upgrade_custody|UpgradeCustody|UnpauseWitness|Publication \{)\b' sources --glob '*.move' \
  || rg -n '^public struct (Publication|PackageVersion|PackageAdmin)\b' sources --glob '*.move'; then
  echo 'blast_fun.move must own the package witness and its one package-only constructor over the generic publication, version, and administration.' >&2
  failures=$((failures + 1))
fi

# Administration is the shared blast_admin ACL. Package roles are blast_admin's generic
# `{Upgrade,Pause,Unpause,Cancel}Admin<BLAST_FUN>`; product roles are blast_core::blast_domain's.
if [[ -e sources/acl.move || -e sources/blast_acl.move ]]; then
  echo 'Launchpad must not reintroduce a local ACL implementation.' >&2
  failures=$((failures + 1))
fi

if rg -n '^public struct (ACL|Authority|ProtocolAuthority|SuperAdminCap|AdminCap|AdminWitness|UpgradeAdmin|CreatorAdmin|TreasuryAdmin|FeeAdmin|ListingAdmin|VenueAdmin|ClaimSignerAdmin|PauseAdmin|UnpauseAdmin|CancelAdmin)\b' \
  sources --glob '*.move'; then
  echo 'Administration types and roles must come from blast_admin and blast_core, never from a local copy.' >&2
  failures=$((failures + 1))
fi

launchpad_roles=(
  CreatorAdmin
  TreasuryAdmin
  FeeAdmin
  ListingAdmin
  VenueAdmin
  ClaimSignerAdmin
  CancelAdmin
  'UnpauseAdmin<BLAST_FUN>'
)
launchpad_role_pattern="$(IFS='|'; echo "${launchpad_roles[*]}")"

# Product roles resolve to blast_core::blast_domain and the package role to blast_admin's generic
# one, so a same-named local or foreign role fails here.
role_import_violations="$(for file in "${source_files[@]}"; do
  role_source="$(sed '/^\/\/ === Test-Only Functions ===/,/^\/\/ === Imports ===/d' "$file" | tr '\n' ' ')"
  if rg -q 'AdminWitness<(CreatorAdmin|TreasuryAdmin|FeeAdmin|ListingAdmin|VenueAdmin|ClaimSignerAdmin|CancelAdmin)>' <<<"$role_source" \
    && ! rg -q 'use blast_core::\{[^;]*\bblast_domain::' <<<"$role_source"; then
    echo "  ${file}: product roles must come from blast_core::blast_domain"
  fi
  if rg -q 'UnpauseAdmin<BLAST_FUN>' <<<"$role_source" \
    && ! rg -q 'use blast_admin::\{[^;]*\bpackage_admin::\{[^}]*\bUnpauseAdmin\b' <<<"$role_source"; then
    echo "  ${file}: the unpause role must be blast_admin::package_admin::UnpauseAdmin<BLAST_FUN>"
  fi
done)"

if [[ -n "$role_import_violations" ]]; then
  printf '%s\n' "$role_import_violations"
  echo 'Launchpad roles must be blast_core product roles and blast_admin generic package roles.' >&2
  failures=$((failures + 1))
fi

# The witness type is each administrator action's role check, so every witness a source names is
# borrowed and names one concrete Launchpad role; a generic or foreign role fails here.
admin_witness_violations="$(for file in "${source_files[@]}"; do
  move_facts "$file" | move_normalized_source | { rg -o '&?AdminWitness<[A-Za-z]*(<BLAST_FUN>)?>' || true; } \
    | { rg -v -x "&AdminWitness<(${launchpad_role_pattern})>" || true; } | sed "s|^|  ${file}: |"
done)"

if [[ -n "$admin_witness_violations" ]]; then
  printf '%s\n' "$admin_witness_violations"
  echo 'Every administrator witness must be a borrowed AdminWitness of one concrete Launchpad role.' >&2
  failures=$((failures + 1))
fi

# Every administrator action takes exactly one role, the one pinned here, so no role reaches
# another role's action. A new function that takes a witness fails until it is mapped deliberately.
admin_roles="$(for file in "${source_files[@]}"; do
  move_facts "$file" | awk -F'\t' -v module="$(basename "$file" .move)" '
    $1 == "FN" && $6 == 0 && index($9, "AdminWitness<") > 0 {
      rest = $9
      roles = ""
      while (match(rest, /AdminWitness<[A-Za-z]*(<BLAST_FUN>)?>/)) {
        roles = roles (roles == "" ? "" : ",") substr(rest, RSTART + 13, RLENGTH - 14)
        rest = substr(rest, RSTART + RLENGTH)
      }
      print module ":" $2 ":" roles
    }
  '
done | LC_ALL=C sort | tr '\n' ' ')"

if [[ "$admin_roles" != \
  'launch:cancel_creator_metadata_cap_reassignment:CancelAdmin launch:cancel_curve_fee_cap_reassignment:CancelAdmin launch:schedule_creator_metadata_cap_delay:CreatorAdmin launch:schedule_creator_metadata_cap_reassignment:CreatorAdmin launch:schedule_curve_fee_cap_delay:CreatorAdmin launch:schedule_curve_fee_cap_reassignment:CreatorAdmin launch_config:add_partner:FeeAdmin launch_config:cancel_creation_fee:CancelAdmin launch_config:cancel_protocol_allocation:CancelAdmin launch_config:cancel_protocol_lp_fees:CancelAdmin launch_config:cancel_trade_fees:CancelAdmin launch_config:cancel_venue:CancelAdmin launch_config:cancel_venue_delay:CancelAdmin launch_config:remove_partner:FeeAdmin launch_config:remove_venue:VenueAdmin launch_config:schedule_creation_fee:FeeAdmin launch_config:schedule_protocol_allocation:TreasuryAdmin launch_config:schedule_protocol_lp_fees:FeeAdmin launch_config:schedule_trade_fees:FeeAdmin launch_config:schedule_venue:VenueAdmin launch_config:schedule_venue_delay:VenueAdmin launch_config:set_meme_decimals_allowed:ListingAdmin launch_config:set_quote_allowed:ListingAdmin launch_config:unpause:UnpauseAdmin<BLAST_FUN> runtime_config:cancel_creator_claim_signer:CancelAdmin runtime_config:cancel_creator_claim_signer_delay:CancelAdmin runtime_config:cancel_protocol_fee_share:CancelAdmin runtime_config:revoke_creator_claim_signer:ClaimSignerAdmin runtime_config:schedule_creator_claim_signer:ClaimSignerAdmin runtime_config:schedule_creator_claim_signer_delay:ClaimSignerAdmin runtime_config:schedule_protocol_fee_share:FeeAdmin ' ]]; then
  printf '  %s\n' $admin_roles
  echo 'Every administrator action must take exactly its pinned role witness.' >&2
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

# Unpausing is the release gate: only launch_config::unpause clears pause bits, with the package
# witness, after the version check and the guarded-delay check over both configurations and the
# core treasury.
if [[ "$(for file in "${source_files[@]}"; do
      move_facts "$file" | awk -F'\t' -v module="$(basename "$file" .move)" \
        '$1 == "FN" && $6 == 0 && index($10, "clear_pause_bits(") > 0 { print module ":" $2 }'
    done | LC_ALL=C sort | tr '\n' ' ')" != 'launch_config:unpause ' ]] \
  || [[ "$(move_production_function_contract unpause <<<"$(move_facts sources/config/launch_config.move)")" \
    != 'public:0:0:fun unpause( self: &LaunchConfig, package_version: &mut PackageVersion<BLAST_FUN>, unpause_admin: &AdminWitness<UnpauseAdmin<BLAST_FUN>>, package_admin: &PackageAdmin<BLAST_FUN>, runtime_config: &RuntimeConfig, treasury: &Treasury, bits: u8, )' ]] \
  || [[ "$(move_production_body unpause <<<"$(move_facts sources/config/launch_config.move)")" \
    != 'package_version.assert_current(constants::version!()); assert!( self.is_guarded() && runtime_config.is_guarded() && treasury.is_guarded(), blast_fun::errors::unguarded_delay!(), ); package_admin.clear_pause_bits(unpause_admin, package_witness(), package_version, bits);' ]] \
  || rg -n '\bpackage_admin::pause\(|\bset_pause_bits\(' sources --glob '*.move'; then
  echo 'Only launch_config::unpause may clear pause bits, after every delay is guarded; pausing is blast_admin::package_admin::pause.' >&2
  failures=$((failures + 1))
fi

# Reusable custody, version, pause, policy, and immutability facts are emitted by
# blast_admin. No copy may reappear in this package's event registry.
if rg -n '^public struct (Paused|Unpaused|PackageAdminCreated|UpgradeAuthorized|UpgradeCommitted|UpgradePolicyRestricted|UpgradeCapDestroyed|PackageVersionAdvanced)\b' \
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
' "${test_files[@]}")"

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
' "${test_files[@]}")"

if [[ -n "$expected_failure_without_named_abort" ]]; then
  printf '%s\n' "$expected_failure_without_named_abort"
  echo 'Every expected_failure must use a qualified named error constant, never a numeric or bare failure.' >&2
  failures=$((failures + 1))
fi

for test_file in "${test_files[@]}"; do
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
    'test_scenario::[a-z][a-z0-9_]*|\.scenario\b|\.ctx\(|\.next_tx\(|take_from_sender|take_shared|return_to_sender|return_shared|has_most_recent_for_sender|let [A-Za-z0-9_]*Fixture|\.extract\(|\.fill\(|\.swap\(|\.borrow\(|\.borrow_mut\(|option::(borrow|borrow_mut|extract|fill|swap)\(' \
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

if rg -n '\b(Coin|Balance|UID|TxContext|transfer::|event::|object::)\b' sources/math/curve.move \
  || rg -n '^(public|entry) fun ' sources/math/curve.move \
  || [[ "$(move_facts sources/math/curve.move | move_production_functions)" \
    != 'amount_out:private:0 cap_buy_quote_input:package:0 quote_buy:package:0 quote_sell:package:0 ' ]]; then
  echo 'curve.move must remain a pure package-only numeric curve module.' >&2
  failures=$((failures + 1))
fi

# The reserves move by exactly the curve's input and its floored output, so the product cannot
# fall and needs no runtime reconciliation.
if [[ "$(rg -c '\bamount_out\(' sources/math/curve.move)" != 3 ]]; then
  echo 'Buy and sell must share the exact-input constant-product math.' >&2
  failures=$((failures + 1))
fi

if [[ "$(rg -c '^[[:space:]]+quote_fee_bps: Bps,' sources/math/curve.move)" != 3 ]] \
  || [[ "$(rg -c '^[[:space:]]+meme_fee_bps: Bps,' sources/math/curve.move)" != 2 ]] \
  || [[ "$(rg -c '^[[:space:]]+sell_burn_bps: Bps,' sources/math/curve.move)" != 1 ]] \
  || rg -n 'trade_fee_bps|fee_asset|fee_mode' sources/math/curve.move; then
  echo 'Each curve quote must use independent quote/meme rates; zero rates encode fee-asset choice.' >&2
  failures=$((failures + 1))
fi

# Blast's fees on a launch live in blast_core's protocol-fee Ledger, sealed by the launch's
# PackageWitness and bound to its partner at creation; the creator's trade-fee share stays in two
# launch balances. Only the trade accrual, the creator claim, and migration touch them, and each
# trade rounds Blast's share up through `Ledger::take_cut`.
launch_fee_facts="$(move_facts sources/launch/launch.move)"
if [[ -e sources/fees.move ]] \
  || rg -n '\bFeeLedger\b|\bfee_ledger\b' sources --glob '*.move' \
  || ! rg -Fq 'protocol_fees: Ledger<Meme, Quote>,' sources/launch/launch.move \
  || ! rg -Fq 'creator_meme_fees: Balance<Meme>,' sources/launch/launch.move \
  || ! rg -Fq 'creator_quote_fees: Balance<Quote>,' sources/launch/launch.move \
  || [[ "$(move_production_body accrue_trade_fees <<<"$launch_fee_facts")" \
    != 'let (protocol_meme, protocol_quote) = self.protocol_fees.take_cut(&mut meme_fee, &mut quote_fee, protocol_fee_share_bps, protocol_fee_share_bps); let (creator_meme, creator_quote) = (meme_fee.value(), quote_fee.value()); self.creator_meme_fees.join(meme_fee); self.creator_quote_fees.join(quote_fee); (protocol_meme, creator_meme, protocol_quote, creator_quote)' ]] \
  || [[ "$(awk -F'\t' '$1 == "FN" && $6 == 0 && $10 ~ /self\.creator_(meme|quote)_fees\./ { print $2 }' <<<"$launch_fee_facts" | LC_ALL=C sort | tr '\n' ' ')" \
    != 'accrue_trade_fees claim_creator_fees ' ]] \
  || [[ "$(awk -F'\t' '$1 == "FN" && $6 == 0 && $10 ~ /self\s*\.protocol_fees\s*\./ { print $2 }' <<<"$launch_fee_facts" | LC_ALL=C sort | tr '\n' ' ')" \
    != 'accrue_trade_fees claim_protocol_fees claim_protocol_fees_with_partner migrate ' ]] \
  || [[ "$(count_occurrences 'protocol_fees::new\(package_witness\(\), id\.to_inner\(\), partner_id\)' <<<"$(move_production_body finalize <<<"$launch_fee_facts")")" != 1 ]]; then
  echo "Blast's launch fees must sit in the core Ledger sealed by PackageWitness and the creator's in its own balances, each reached only by its accrual, claim, and migration." >&2
  failures=$((failures + 1))
fi

runtime_config_facts="$(move_facts sources/config/runtime_config.move)"
runtime_config_source="$(move_normalized_source <<<"$runtime_config_facts")"

# Delayed RuntimeConfig mutations are checked by check_admin_delay.py.

events_facts="$(move_facts sources/lib/events.move)"

# Every RuntimeConfig setting, the claim-signer set included, stores the primitive keyed by its own
# operation, whose lifecycle events (delayed_set's for the signers) replace any consumer copy.
if rg -q '\b(RuntimeConfigCreated|CreatorClaimSigner[A-Z]\w*|ProtocolFeeShare[A-Z]\w*|Treasury(Scheduled|Changed|Cancelled))\b' <<<"$events_facts" \
  || ! rg -Fq 'creator_claim_signers: DelayedSet<ClaimSignerKey, vector<u8>>,' sources/config/runtime_config.move \
  || ! rg -Fq 'protocol_fee_share_bps: Delayed<ProtocolFeeShareKey, Bps>,' sources/config/runtime_config.move \
  || rg -q '\b(treasury|Treasury)' <<<"$runtime_config_source" \
  || rg -q '\bcreator_claim_signer_public_key\b' sources \
  || rg -n 'events::' <<<"$runtime_config_source"; then
  echo 'Runtime config must emit no consumer event and hold no treasury: the claim signers and protocol fee share each store the primitive keyed by its own operation.' >&2
  failures=$((failures + 1))
fi

# Test-only fixture publication does not add a production singleton.
core_singleton_bodies="$(
  for source_file in "${source_files[@]}"; do
    [[ "$source_file" == sources/launch/launch.move ]] && continue
    move_facts "$source_file" | awk -F'\t' '$1 == "FN" && $6 == 0 { print $10 }'
  done
)"

if [[ -f sources/creator_claim_config.move || -f sources/trade_fee_config.move ]] \
  || rg -n '\b(CreatorClaimConfig|TradeFeeConfig)\b' sources tests \
  || [[ "$(count_occurrences 'transfer::share_object' <<<"$core_singleton_bodies")" != 2 ]]; then
  echo 'Core must keep exactly its two shared configuration singletons besides the launch registry and terminal sink; the ACL, version, and package administration are shared by blast_admin.' >&2
  failures=$((failures + 1))
fi

launch_config_facts="$(move_facts sources/config/launch_config.move)"
launch_config_source="$(move_normalized_source <<<"$launch_config_facts")"
launch_config_production="$(sed '/^\/\/ === Test-Only Functions ===/,$d' sources/config/launch_config.move)"

# Blast's allocation starts at the map's 250/150 BPS and may change only for future launches, each
# asset at most the constructor's 1,000 BPS maximum. Blast's LP-fee share of new vaults starts at
# 1,500/1,500 BPS, each asset at most the private constructor's 3,000 BPS, and only migration reads
# it. Every delayed policy, venue admission included, stores the primitive keyed by its own
# operation, and every one of them is in the unpause guard.
if [[ ! -f sources/config/launch_config.move ]] \
  || [[ "$(move_production_function_contract schedule_protocol_allocation <<<"$launch_config_facts")" != 'public:0:0:fun schedule_protocol_allocation( self: &mut LaunchConfig, package_version: &PackageVersion<BLAST_FUN>, _: &AdminWitness<TreasuryAdmin>,'* ]] \
  || [[ "$(move_production_type LaunchConfig <<<"$launch_config_facts")" \
    != 'struct LaunchConfig has key { id: UID, meme_decimals: VecSet<u8>, quotes: VecSet<TypeName>, trade_fees: Delayed<TradeFeesKey, TradeFees>, venues: DelayedSet<VenueKey, TypeName>, protocol_allocation: Delayed<ProtocolAllocationKey, ProtocolAllocation>, protocol_lp_fees: Delayed<ProtocolLpFeesKey, ProtocolLpFees>, creation_fee: Delayed<CreationFeeKey, u64>, partners: PartnerList, }' ]] \
  || [[ "$(move_production_type ProtocolLpFees <<<"$launch_config_facts")" \
    != 'struct ProtocolLpFees has copy, drop, store { meme_bps: Bps, quote_bps: Bps, }' ]] \
  || [[ "$(move_production_function_contract new_protocol_lp_fees <<<"$launch_config_facts")" \
    != 'private:0:0:fun new_protocol_lp_fees(meme_bps: Bps, quote_bps: Bps): ProtocolLpFees' ]] \
  || [[ "$(move_production_body new_protocol_lp_fees <<<"$launch_config_facts")" \
    != 'assert!( meme_bps.value() <= blast_core::constants::max_lp_fee_bps!() && quote_bps.value() <= blast_core::constants::max_lp_fee_bps!(), blast_fun::errors::invalid_lp_fee_bps!(), ); ProtocolLpFees { meme_bps, quote_bps }' ]] \
  || rg -n 'fun (max_lp_fee_bps|basis_points_denominator|max_meme_symbol_length)\(' sources/lib/constants.move \
  || [[ "$(count_occurrences 'ProtocolLpFees \{ meme_bps, quote_bps \}' <<<"$launch_config_source")" != 2 ]] \
  || [[ "$(move_production_body schedule_protocol_lp_fees <<<"$launch_config_facts")" \
    != 'package_version.assert_current(constants::version!()); self.protocol_lp_fees.schedule(new_protocol_lp_fees(meme_bps, quote_bps), delay_ms, clock);' ]] \
  || ! rg -Fq 'protocol_lp_fees: delayed::new(ProtocolLpFeesKey(), &id, protocol_lp_fees, delay_ms)' <<<"$launch_config_source" \
  || ! rg -Fq 'new_protocol_lp_fees(bps::new(1_500), bps::new(1_500))' <<<"$(move_production_body init <<<"$launch_config_facts")" \
  || [[ "$(move_production_function_contract protocol_lp_fees <<<"$launch_config_facts")" \
    != 'package:0:0:fun protocol_lp_fees(self: &LaunchConfig): (Bps, Bps)' ]] \
  || [[ "$(rg -l '\.protocol_lp_fees\(\)' sources --glob '*.move' | LC_ALL=C sort | tr '\n' ' ')" \
    != 'sources/launch/launch.move ' ]] \
  || [[ "$(move_production_body is_guarded <<<"$launch_config_facts")" \
    != 'self.trade_fees.is_guarded() && self.venues.is_guarded() && self.protocol_allocation.is_guarded() && self.protocol_lp_fees.is_guarded() && self.creation_fee.is_guarded()' ]] \
  || rg -Fq 'protocol_allocation: Option<' sources/config/launch_config.move \
  || ! rg -Fq 'meme_bps.value() <= constants::max_protocol_allocation_bps!()' sources/math/allocation.move \
  || ! rg -Fq 'quote_bps.value() <= constants::max_protocol_allocation_bps!()' sources/math/allocation.move \
  || ! rg -Fq 'self.protocol_allocation.schedule(value, delay_ms, clock);' <<<"$launch_config_source" \
  || ! rg -Fq 'protocol_allocation: delayed::new(ProtocolAllocationKey(), &id, protocol_allocation, delay_ms)' <<<"$launch_config_source" \
  || ! rg -Fq 'allocation::protocol_allocation(bps::new(250), bps::new(150))' <<<"$(move_production_body init <<<"$launch_config_facts")" \
  || rg -n '\b(set_graduation_defaults|GraduationDefaultsChanged|protocol_(quote_migration|meme_graduation)_fee_bps|meme_liquidity_provision_bps|QuoteParameters|QuoteParametersChanged|min_graduation_target|max_graduation_target)\b' \
    sources/config/launch_config.move sources/lib/events.move \
  || rg -n '\b(AdminCap|ProtocolAuthority|sequence|schema_version|action_tag|nonce)\b' <<<"$launch_config_production"; then
  echo 'LaunchConfig must own only future-launch settings plus AdminWitness-gated Blast allocation (default 250/150 BPS) and vault LP-fee share (default 1,500/1,500, at most 3,000 BPS), both always present and both in the unpause guard.' >&2
  failures=$((failures + 1))
fi

# ADR 0098: the creation fee and the accepted partners change only through apply_creation_fee,
# add_partner, and remove_partner, each version-gated first; creation reads them, nothing else does.
# The acceptance window is blast_partners::partner_list's, embedded once.
launch_config_fee_writers="$(awk -F'\t' '
  $1 == "FN" && $6 == 0 && $10 ~ /self\.creation_fee\.apply/ { print $2 }
' <<<"$launch_config_facts" | sort | tr '\n' ' ')"
launch_config_partner_writers="$(awk -F'\t' '
  $1 == "FN" && $6 == 0 && $10 ~ /self\.partners\.(add|remove)\(/ { print $2 }
' <<<"$launch_config_facts" | sort | tr '\n' ' ')"
launch_config_ungated="$(awk -F'\t' '
  $1 == "FN" && $6 == 0 && ($2 == "apply_creation_fee" || $2 == "add_partner" || $2 == "remove_partner") \
    && $10 !~ /^package_version\.assert_current\(constants::version!\(\)\);/ { print $2 }
' <<<"$launch_config_facts")"

if [[ "$launch_config_fee_writers" != 'apply_creation_fee ' ]] \
  || [[ "$launch_config_partner_writers" != 'add_partner remove_partner ' ]] \
  || [[ -n "$launch_config_ungated" ]] \
  || [[ -n "$(move_production_type PartnerKey <<<"$launch_config_facts")" ]] \
  || rg -n 'dynamic_field' sources/config/launch_config.move \
  || ! rg -Fq 'partners: partner_list::new(&id, ctx),' sources/config/launch_config.move \
  || [[ "$(move_production_body assert_partner <<<"$launch_config_facts")" != 'self.partners.assert_accepted(partner_id, clock);' ]] \
  || [[ "$(rg -l '\.(creation_fee|assert_partner)\(' sources | sort | tr '\n' ' ')" \
    != 'sources/launch/launch.move ' ]]; then
  echo 'LaunchConfig must change its creation fee and accepted partners only through their version-gated setters, and only launch creation may read them.' >&2
  failures=$((failures + 1))
fi

constants_facts="$(move_facts sources/lib/constants.move)"

if [[ "$(move_production_body max_recipients <<<"$constants_facts")" != '16' ]] \
  || [[ "$(rg -c 'recipients\.length\(\) <= constants::max_recipients!\(\)' sources/math/allocation.move)" != 1 ]] \
  || [[ "$(move_production_body max_trade_fee_bps <<<"$constants_facts")" != '1_000' ]] \
  || ! rg -Fq 'quote_fee_bps.value() <= constants::max_trade_fee_bps!()' sources/config/launch_config.move \
  || ! rg -Fq 'meme_fee_bps.value() <= constants::max_trade_fee_bps!()' sources/config/launch_config.move \
  || rg -n 'protocol_trade_fee_share_bps' sources \
  || ! rg -Fq 'type_name::with_original_ids<Quote>()' sources/config/launch_config.move \
  || [[ "$(count_occurrences 'type_name::with_original_ids<Venue>\(\)' <<<"$launch_config_source")" != 4 ]] \
  || ! rg -Fq 'assert!( self.venues.contains(&venue), blast_fun::errors::venue_not_allowed!(), );' \
    <<<"$(move_production_body snapshot_for_launch <<<"$launch_config_facts")" \
  || ! in_order 'assert!(!venue.is_primitive(), blast_fun::errors::invalid_venue!());' \
    'assert!(origin != @0x1 && origin != @0x2, blast_fun::errors::invalid_venue!());' \
    'self.venues.schedule_add(venue, clock);' \
    <<<"$(move_production_body schedule_venue <<<"$launch_config_facts")" \
  || rg -q '\b(MigrationWitness|migration_witness(es)?|MigrationWitnessKey)\b' <<<"$launch_config_source" \
  || ! rg -Fq 'origin != @0x1 && origin != @0x2' sources/config/launch_config.move \
  || ! rg -Fq 'self.quotes.contains(&type_name::with_original_ids<Quote>())' sources/config/launch_config.move \
  || ! rg -Fq 'quotes: vec_set::empty()' sources/config/launch_config.move \
  || ! rg -Fq 'assert!(virtual_quote > 0, blast_fun::errors::invalid_virtual_quote!());' sources/launch/launch.move \
  || rg -n '\bvirtual_quote' sources/config/launch_config.move \
  || ! rg -Fq 'self.meme_decimals.contains(&decimals)' sources/config/launch_config.move \
  || rg -n '\b(max_quote_assets|quote_capacity_reached|Currency<Quote>|coin_registry)\b' \
    sources/config/launch_config.move sources/lib/errors.move; then
  echo 'Launch policy must keep original-type Quote and venue admission, the decimal allowlist, a constant trade-fee ceiling with a configurable protocol share, and one named recipient limit.' >&2
  failures=$((failures + 1))
fi
if ! rg -U -q \
    'fun init\(ctx: &mut TxContext\) \{\s*transfer::share_object\(new\(\s*TradeFees \{ quote_fee_bps: bps::new\(150\), meme_fee_bps: bps::new\(0\) \},\s*allocation::protocol_allocation\(bps::new\(250\), bps::new\(150\)\),\s*new_protocol_lp_fees\(bps::new\(1_500\), bps::new\(1_500\)\),\s*0,\s*ctx,?\s*\)\);\s*\}' \
    sources/config/launch_config.move \
  || rg -q '\bLaunchConfigCreated\b' sources/lib/events.move sources/config/launch_config.move; then
  echo 'Launch-config initialization must share the one cold-policy singleton and emit no creation event.' >&2
  failures=$((failures + 1))
fi

# The allocation's replay fact is the primitive's keyed lifecycle event, whose value is the
# allocation itself; no consumer copy may restate it.
protocol_allocation_payload="$(sed -n -e '/^public struct ProtocolAllocation has/,/^}/p' sources/math/allocation.move)"

if [[ -z "$protocol_allocation_payload" ]] \
  || ! rg -q '^[[:space:]]+meme_bps: Bps,' <<<"$protocol_allocation_payload" \
  || ! rg -q '^[[:space:]]+quote_bps: Bps,' <<<"$protocol_allocation_payload" \
  || [[ "$(rg -c ':' <<<"$protocol_allocation_payload")" != 2 ]] \
  || rg -n '^public struct ProtocolAllocation\w*' sources/lib/events.move; then
  echo 'The Blast migration-fee allocation must be replayed only from its keyed primitive events, whose value carries both shares without singleton or ordering noise.' >&2
  failures=$((failures + 1))
fi

launch_ticket_facts="$(move_facts sources/launch/launch_ticket.move)"
launch_ticket_source="$(move_normalized_source <<<"$launch_ticket_facts")"

# The generated package's one-time witness names the currency and the Coin Registry proves it
# is unique, so the constructor needs no package identity, launch policy, or registry borrow.
# The ticket is pure coin custody: it records no venue or Quote and holds no TreasuryCap, which
# `new` returns beside it so a venue can prepare the coin. The ticket therefore cannot leak supply:
# finalization takes the cap back and re-checks that the ticket holds the whole minted supply and
# that nothing else was minted, re-checks the sell burn, and only then fixes the supply mode.
launch_ticket_new_body="$(move_production_body new <<<"$launch_ticket_facts" | move_semantic_shape)"
launch_ticket_destroy_body="$(move_production_body destroy <<<"$launch_ticket_facts" | move_semantic_shape)"

if [[ ! -f sources/launch/launch_ticket.move ]] \
  || [[ "$(move_production_functions <<<"$launch_ticket_facts")" \
    != 'atomic_supply:package:0 decimals:package:0 destroy:package:0 id:package:0 new:public:0 ' ]] \
  || [[ "$(move_production_type LaunchTicket <<<"$launch_ticket_facts")" \
    != 'struct LaunchTicket<phantom Meme> has key, store { id: UID, meme: Balance<Meme>, metadata_cap: MetadataCap<Meme>, creator: CreatorRecipient, decimals: u8, burnable: bool, sell_burn_bps: Bps, }' ]] \
  || [[ "$(move_production_function_contract new <<<"$launch_ticket_facts")" != 'public:0:0:fun new<Meme: drop>( otw: Meme, decimals: u8,'* ]] \
  || [[ "$(move_production_function_contract new <<<"$launch_ticket_facts")" != *'ctx: &mut TxContext, ): (LaunchTicket<Meme>, TreasuryCap<Meme>)' ]] \
  || [[ "$(count_occurrences 'coin_registry::new_currency_with_otw\(' <<<"$launch_ticket_source")" != 1 ]] \
  || ! in_order \
    'constants::max_sell_burn_bps!()' \
    'coin_registry::new_currency_with_otw(' \
    'LaunchTicket{' \
    'treasury_cap.mint_balance(atomic_supply(decimals))' \
    'initializer.finalize(ctx)' \
    <<<"$launch_ticket_new_body" \
  || [[ "$launch_ticket_new_body" != *';(ticket,treasury_cap)' ]] \
  || [[ "$(count_occurrences '\btreasury_cap\b' <<<"$launch_ticket_new_body")" != 3 ]] \
  || [[ "$(move_production_function_contract destroy <<<"$launch_ticket_facts")" \
    != 'package:0:0:fun destroy<Meme>( self: LaunchTicket<Meme>, treasury_cap: TreasuryCap<Meme>, currency: &mut Currency<Meme>, atomic_supply: u64, ): (Balance<Meme>, MetadataCap<Meme>, CreatorRecipient, Bps)' ]] \
  || ! in_order \
    'meme.value()== atomic_supply && treasury_cap.total_supply()== atomic_supply' \
    'invalid_initial_meme_supply!()' \
    'sell_burn_bps.value()<= constants::max_sell_burn_bps!()' \
    'currency.make_supply_burn_only(treasury_cap)' \
    'currency.make_supply_fixed(treasury_cap)' \
    <<<"$launch_ticket_destroy_body" \
  || [[ "$(count_occurrences '\btreasury_cap\b' <<<"$launch_ticket_destroy_body")" != 3 ]] \
  || [[ "$(count_occurrences 'make_supply_' <<<"$launch_ticket_source")" != 2 ]] \
  || rg -q 'self\.treasury_cap|treasury_cap_mut|&(mut )?TreasuryCap' <<<"$launch_ticket_source" \
  || rg -q '\b(UpgradeCap|CoinRegistry|PackageVersion|LaunchConfig|TypeName|make_regulated|DenyCap|CoinMetadata)\b' <<<"$launch_ticket_source" \
  || rg -q '\btransfer::|\bentry fun\b' <<<"$launch_ticket_source"; then
  echo 'launch_ticket.move must create the currency from the generated package one-time witness, mint the canonical supply once into a ticket that records no venue or Quote, return the TreasuryCap beside it without holding or lending it, fix the supply mode only at finalization after taking the cap back and re-checking the whole minted supply and sell burn, and custody the metadata cap and creator recipient without package, policy, or registry inputs.' >&2
  failures=$((failures + 1))
fi
if [[ "$(rg -o '\.mint_balance\(' sources | wc -l)" != 1 ]] \
  || rg -n '\bcoin::mint(_balance)?\(' sources \
  || rg -n '\.mint_balance\(' sources --glob '!launch_ticket.move'; then
  echo 'The launch-ticket constructor must remain the only Meme mint site in the package.' >&2
  failures=$((failures + 1))
fi

if [[ "$(move_production_body meme_total_supply_whole_tokens <<<"$constants_facts")" != '1_000_000_000' ]] \
  || ! rg -Fq 'constants::meme_total_supply_whole_tokens!() *' sources/launch/launch_ticket.move; then
  echo 'Generated Meme supply must remain exactly one billion whole tokens at every admitted precision.' >&2
  failures=$((failures + 1))
fi

launch_ticket_event_payload="$(sed -n \
  -e '/^public struct LaunchTicketCreated/,/^}/p' \
  sources/lib/events.move)"

if [[ -z "$launch_ticket_event_payload" ]] \
  || ! rg -q '^[[:space:]]+decimals: u8,' <<<"$launch_ticket_event_payload" \
  || rg -n '\b(treasury_cap_id|sequence|schema_version|action_tag|nonce)\b' \
    <<<"$launch_ticket_event_payload"; then
  echo 'Launch-ticket creation must record its decimals, omit its consumed cap, and avoid ordering or schema fields.' >&2
  failures=$((failures + 1))
fi

allocation_facts="$(move_facts sources/math/allocation.move)"
allocation_source="$(move_normalized_source <<<"$allocation_facts")"
launch_facts="$(move_facts sources/launch/launch.move)"
launch_source="$(move_normalized_source <<<"$launch_facts")"

# The allocation module is pure validation over blast_core's exact largest-remainder
# apportionment: Blast has an explicit route, each asset sums to 10,000, and Blast's part is the
# one rounded up. The apportionment itself is pinned by blast_core's gate.
if [[ ! -f sources/math/allocation.move ]] \
  || [[ "$(move_production_type RecipientShare <<<"$allocation_facts")" != 'struct RecipientShare has copy, drop, store { recipient: Recipient, meme_bps: Bps, quote_bps: Bps, }' ]] \
  || [[ "$(move_production_type ProtocolAllocation <<<"$allocation_facts")" != 'struct ProtocolAllocation has copy, drop, store { meme_bps: Bps, quote_bps: Bps, }' ]] \
  || [[ "$(move_production_type AllocationPlan <<<"$allocation_facts")" != 'struct AllocationPlan has copy, drop, store { curve_meme_bps: Bps, lp_meme_bps: Bps, lp_quote_bps: Bps, protocol_meme_bps: Bps, protocol_quote_bps: Bps, recipients: vector<RecipientShare>, }' ]] \
  || [[ "$(move_production_body plan <<<"$allocation_facts")" != 'assert!( curve_meme_bps.value() > 0 && lp_meme_bps.value() > 0 && lp_quote_bps.value() > 0, blast_fun::errors::invalid_shares!(), ); AllocationPlan { curve_meme_bps, lp_meme_bps, lp_quote_bps, protocol_meme_bps: bps::new(0), protocol_quote_bps: bps::new(0), recipients, }' ]] \
  || ! rg -Fq 'self.protocol_meme_bps = protocol.meme_bps; self.protocol_quote_bps = protocol.quote_bps;' <<<"$allocation_source" \
  || [[ "$(move_production_body apportion_meme <<<"$allocation_facts")" \
    != 'let mut bps = vector[self.curve_meme_bps, self.lp_meme_bps, self.protocol_meme_bps]; bps.append(self.recipients.map_ref!(|share| share.meme_bps)); let amounts = bps::apportion(bps, supply, option::some(2)); let recipients = vector::tabulate!(amounts.length() - 3, |i| amounts[i + 3]); (amounts[0], amounts[1], amounts[2], recipients)' ]] \
  || [[ "$(move_production_body apportion_quote <<<"$allocation_facts")" \
    != 'let mut bps = vector[self.lp_quote_bps, self.protocol_quote_bps]; bps.append(self.recipients.map_ref!(|share| share.quote_bps)); let amounts = bps::apportion(bps, reserve, option::some(1)); let recipients = vector::tabulate!(amounts.length() - 2, |i| amounts[i + 2]); (amounts[0], amounts[1], recipients)' ]] \
  || [[ "$(count_occurrences 'bps::apportion\(' <<<"$allocation_source")" != 2 ]] \
  || [[ "$(count_occurrences '\) == blast_core::constants::basis_points_denominator!\(\)' <<<"$allocation_source")" != 2 ]] \
  || rg -q '\b(UID|Balance|Coin|TxContext|TreasuryCap|transfer::|object::|dynamic_field|events::)\b' <<<"$allocation_source"; then
  echo 'allocation.move must validate bounded plans with an explicit Blast route and apportion exactly, without custody, cap, or transfer effects.' >&2
  failures=$((failures + 1))
fi

# Sorted names of production launch functions whose body contains one fixed string.
launch_functions_containing() {
  awk -F'\t' -v needle="$1" '
    $1 == "FN" && $6 == 0 && index($10, needle) > 0 { print $2 }
  ' <<<"$launch_facts" | sort | tr '\n' ' '
}

# A venue's pair-typed ticket starts a launch: `new` checks the version, then the create pause,
# then the distinct pair, then redeems the ticket and checks this version's Quote, venue, and
# decimal admissions, into an ability-less initializer reachable only through its setters and
# `finalize`. The initializer holds the TreasuryCap without lending it; only `finalize` hands it
# back to the ticket's re-checking `destroy`, after checking every setting, and keeps the native
# MetadataCap inline forever.
launch_new_body="$(move_production_body new <<<"$launch_facts")"
launch_finalize_body="$(move_production_body finalize <<<"$launch_facts")"
launch_creation_ungated="$(awk -F'\t' '
  $1 == "FN" && $6 == 0 && $2 ~ /^(set_virtual_quote|set_graduation_target|set_allocation_plan|set_lp_fee_split|set_opening_round|set_partner|finalize|share)$/ {
    if ($9 !~ /[(,] package_version: &PackageVersion<BLAST_FUN>,/ || $10 !~ /^package_version\.assert_current\(constants::version!\(\)\);/) print $2
  }
' <<<"$launch_facts")"
launch_initializer_functions="$(awk -F'\t' '
  $1 == "FN" && $6 == 0 && $9 ~ /LaunchInitializer</ { print $2 ":" $3 }
' <<<"$launch_facts" | sort | tr '\n' ' ')"

if [[ ! -f sources/launch/launch.move ]] \
  || [[ -n "$launch_creation_ungated" ]] \
  || [[ "$(move_production_type LaunchInitializer <<<"$launch_facts")" != 'struct LaunchInitializer<phantom Meme, phantom Quote> {'* ]] \
  || [[ "$launch_initializer_functions" != 'finalize:public new:public set_allocation_plan:public set_graduation_target:public set_lp_fee_split:public set_opening_round:public set_partner:public set_virtual_quote:public ' ]] \
  || [[ "$(move_production_type LaunchInitializer <<<"$launch_facts")" != 'struct LaunchInitializer<phantom Meme, phantom Quote> { ticket: LaunchTicket<Meme>, treasury_cap: TreasuryCap<Meme>, venue: TypeName,'* ]] \
  || [[ "$(move_production_function_contract new <<<"$launch_facts")" != 'public:0:0:fun new<Meme, Quote>( ticket: LaunchTicket<Meme>, treasury_cap: TreasuryCap<Meme>, package_version: &PackageVersion<BLAST_FUN>, config: &LaunchConfig, venue_ticket: VenueTicket<Meme, Quote>, ): LaunchInitializer<Meme, Quote>' ]] \
  || [[ "$launch_new_body" != 'package_version.assert_current(constants::version!()); package_version.assert_not_paused(constants::create_pause_bit!()); assert!( type_name::with_original_ids<Meme>() != type_name::with_original_ids<Quote>(), blast_fun::errors::invalid_meme_quote_pair!(), ); let venue = venue_ticket.redeem_ticket(); let (quote_fee_bps, meme_fee_bps) = config.snapshot_for_launch<Quote>(venue, ticket.decimals()); LaunchInitializer {'* ]] \
  || [[ "$(launch_functions_containing 'treasury_cap')" != 'finalize new ' ]] \
  || [[ "$(launch_functions_containing '.redeem_ticket(')" != 'new ' ]] \
  || [[ "$(count_occurrences 'let LaunchInitializer \{' <<<"$launch_source")" != 1 ]] \
  || rg -q 'self\.treasury_cap|&(mut )?TreasuryCap|\.ticket\.' <<<"$launch_source" \
  || [[ "$launch_finalize_body" != *'ticket.destroy(treasury_cap, currency, atomic_supply);'* ]] \
  || rg -q '\b(Witness|migration_witness|MigrationWitness|pool_tick_spacing|pool_fee_rate|pool_tier|treasury_cap_mut|invalid_migration_witness)\b' \
    <<<"$launch_source$(move_normalized_source <<<"$events_facts")" \
  || [[ "$(move_production_function_contract finalize <<<"$launch_facts")" != 'public:0:0:fun finalize<Meme, Quote>( self: LaunchInitializer<Meme, Quote>, package_version: &PackageVersion<BLAST_FUN>, registry: &mut LaunchRegistry, currency: &mut Currency<Meme>, config: &LaunchConfig, creation_fee: Coin<SUI>, ): Launch<Meme, Quote>' ]] \
  || [[ "$(move_production_function_contract set_partner <<<"$launch_facts")" != 'public:0:0:fun set_partner<Meme, Quote>( self: &mut LaunchInitializer<Meme, Quote>, package_version: &PackageVersion<BLAST_FUN>, config: &LaunchConfig, partner: &Partner, clock: &Clock, )' ]] \
  || ! in_order 'config.assert_partner(' 'self.partner_id = option::some(partner_id);' \
    <<<"$(move_production_body set_partner <<<"$launch_facts")" \
  || [[ "$launch_finalize_body" != 'package_version.assert_current(constants::version!()); package_version.assert_not_paused(constants::create_pause_bit!());'* ]] \
  || [[ "$launch_finalize_body" == *'.is_some()'* ]] \
  || ! in_order \
    'invalid_creation_fee!()' \
    'let graduation_target = graduation_target.destroy_some();' \
    'allocation_plan.destroy_some().add_protocol(config.protocol_allocation());' \
    'invalid_opening_round!()' \
    'invalid_graduation_target!()' \
    'let atomic_supply = launch_ticket::atomic_supply(ticket.decimals());' \
    'allocation_plan.apportion_meme(atomic_supply)' \
    'ticket.destroy(treasury_cap, currency, atomic_supply);' \
    'Launch {' \
    'lp_fee_split: lp_fee_split.destroy_some(),' \
    <<<"$launch_finalize_body" \
  || [[ "$launch_finalize_body" != *'metadata_cap, creator: option::some(creator), curve_fee_cap_reassignment, creator_metadata_cap_reassignment, curve_fee_cap_id: option::none(), creator_metadata_cap_id: option::none(), partner_id, };'* ]] \
  || [[ "$launch_finalize_body" != *'let id = derived_object::claim(&mut registry.id, LaunchKey<Meme>()); let mut protocol_fees = protocol_fees::new(package_witness(), id.to_inner(), partner_id); protocol_fees.accrue_sui(creation_fee); let curve_fee_cap_reassignment = delayed_action::new( CurveFeeCapReassignment(), &id, DEFAULT_CAP_REASSIGNMENT_DELAY_MS, ); let creator_metadata_cap_reassignment = delayed_action::new( CreatorMetadataCapReassignment(), &id, DEFAULT_CAP_REASSIGNMENT_DELAY_MS, ); let launch = Launch { id,'* ]] \
  || [[ "$launch_finalize_body" != *'protocol_fees, creator_meme_fees: balance::zero(), creator_quote_fees: balance::zero(),'* ]] \
  || [[ "$(count_occurrences 'self\.metadata_cap\b' <<<"$launch_source")" \
    != "$(count_occurrences '&self\.metadata_cap\b' <<<"$launch_source")" ]] \
  || rg -q '\bmetadata_cap\.(extract|swap|fill)\(|option::(some|none)\(metadata_cap\)|\bMetadataCap<Meme>\)' \
    <<<"$launch_source" \
  || rg -q 'bps::new\(' <<<"$launch_source" \
  || ! rg -Fq 'let burnable = currency.is_supply_burn_only();' sources/launch/launch.move \
  || rg -q '\b(MigrationChannelCap|LaunchMigrationCap|MigrationChannelBalance|VenueSelection|venue_selection)\b' <<<"$launch_source" \
  || rg -n 'max_trade_fee_bps|invalid_trade_fee_bps' sources/launch/launch.move; then
  echo 'Launch start must check the version, the create pause, the pair, then redeem the venue ticket and check admissions; the ability-less initializer must be reachable only through its setters and finalize, hold the TreasuryCap without lending it, and finalize must check every setting before returning the cap to the ticket'"'"'s re-check, keep the native MetadataCap inline, and carry no venue selection.' >&2
  failures=$((failures + 1))
fi

# The LP-fee split is the creator's post-migration setting and the venue and partner are fixed at
# creation: the split is set once on the initializer, and finalize stores all three unchanged. No
# getter exposes them; only `migrate` reads them, into the vault terms and the hand-off it seals.
if [[ "$(launch_functions_containing 'self.lp_fee_split = ')" != 'set_lp_fee_split ' ]] \
  || [[ "$(move_production_function_contract set_lp_fee_split <<<"$launch_facts")" != 'public:0:0:fun set_lp_fee_split<Meme, Quote>( self: &mut LaunchInitializer<Meme, Quote>, package_version: &PackageVersion<BLAST_FUN>, lp_fee_split: FeeSplit, )' ]] \
  || [[ "$(count_occurrences '\.lp_fee_split = ' <<<"$launch_source")" != 1 ]] \
  || [[ "$(count_occurrences '\.(venue|partner_id) = ' <<<"$launch_source")" != 1 ]] \
  || [[ "$(launch_functions_containing 'self.lp_fee_split')" != 'migrate set_lp_fee_split ' ]] \
  || [[ "$(launch_functions_containing 'self.venue')" != 'migrate ' ]] \
  || [[ "$(launch_functions_containing 'self.partner_id')" != 'migrate set_partner ' ]] \
  || ! rg -Fq 'bps::Bps, fee_split::FeeSplit,' <<<"$launch_source" \
  || [[ -n "$(move_facts sources/launch/launch.move | awk -F'\t' '
    $1 == "FN" && $6 == 0 && $3 == "public" && $9 ~ /\): (FeeSplit|TypeName|Option<ID>|\(u32, u64\))$/ { print $2 }
  ')" ]] \
  || [[ -n "$(move_production_function_contract pool_tier <<<"$launch_facts")$(move_production_function_contract lp_fee_split <<<"$launch_facts")$(move_production_function_contract partner_id <<<"$launch_facts")$(move_production_function_contract venue <<<"$launch_facts")" ]]; then
  echo 'The LP-fee split must be set only on the initializer, and the split, venue, and partner stored unchanged with no getter, read only by migrate into the sealed hand-off.' >&2
  failures=$((failures + 1))
fi

launch_authority_violations=''

# Each authority effect has one exact writer and reader set, so a new sibling or helper cannot
# record authority, claim from either ledger owner, retire the pending claim, reach the native
# MetadataCap, or transfer value outside the approved paths (ADR 0082).
for authority_spec in \
  'self.curve_fee_cap_id = |apply_curve_fee_cap_reassignment claim_creator_caps ' \
  'self.creator_metadata_cap_id = |apply_creator_metadata_cap_reassignment claim_creator_caps ' \
  'self.creator.extract()|claim_creator_caps ' \
  'self.creator = |apply_creator_metadata_cap_reassignment apply_curve_fee_cap_reassignment ' \
  'self.creator_meme_fees.withdraw_all(|claim_creator_fees ' \
  'self.creator_quote_fees.withdraw_all(|claim_creator_fees ' \
  'self.protocol_fees.pay(|claim_protocol_fees ' \
  'self.protocol_fees.pay_with_partner(|claim_protocol_fees_with_partner ' \
  'self.partner_id = |set_partner ' \
  'self.assert_curve_fee_cap(|claim_creator_fees prove_owner ' \
  'owner_proof::new(|prove_owner ' \
  'package_witness()|finalize migrate prove_owner ' \
  'self.assert_metadata_update(|set_description set_icon_url set_name ' \
  '&self.metadata_cap|set_description set_icon_url set_name ' \
  'transfer::public_transfer(|apply_creator_metadata_cap_reassignment apply_curve_fee_cap_reassignment migrate ' \
  '.opening_round_meme.pay(|deliver_opening_round ' \
  '.opening_round_quote.pay(|deliver_opening_round ' \
  'payout::pay_or_vest(&mut self.allocated_meme,|migrate ' \
  'payout::pay_or_vest(&mut self.real_quote_reserve,|migrate '; do
  authority_needle="${authority_spec%%|*}"
  authority_expected="${authority_spec#*|}"
  authority_actual="$(launch_functions_containing "$authority_needle")"

  if [[ "$authority_actual" != "$authority_expected" ]]; then
    launch_authority_violations+="  '${authority_needle}' is used by '${authority_actual}' instead of '${authority_expected}'"$'\n'
  fi
done
# The owner proof is the curve-fee cap's only reach outside the launch: `prove_owner` checks the
# version, then the live cap through the private `assert_curve_fee_cap`, before it seals a proof
# for this launch under the package witness. The witness is the one-time-witness module's drop-only struct,
# which no launch function returns or takes; launch.move obtains it only inside `finalize` (to seal
# the launch's fee ledger), `migrate`, and `prove_owner`, and launch_config only inside `unpause`,
# so no other package can seal this launchpad's ledger, terms, hand-offs, proofs, or pause release.
if [[ "$(move_production_function_contract prove_owner <<<"$launch_facts")" \
    != 'public:0:0:fun prove_owner<Meme, Quote>( self: &Launch<Meme, Quote>, package_version: &PackageVersion<BLAST_FUN>, curve_fee_cap: &CurveFeeCap<Meme>, ): OwnerProof' ]] \
  || [[ "$(move_production_body prove_owner <<<"$launch_facts")" \
    != 'package_version.assert_current(constants::version!()); self.assert_curve_fee_cap(curve_fee_cap); owner_proof::new(package_witness(), self.id.to_inner())' ]] \
  || [[ "$(move_production_function_contract assert_curve_fee_cap <<<"$launch_facts")" \
    != 'private:0:0:fun assert_curve_fee_cap<Meme, Quote>( self: &Launch<Meme, Quote>, curve_fee_cap: &CurveFeeCap<Meme>, )' ]] \
  || [[ "$(move_production_body assert_curve_fee_cap <<<"$launch_facts")" \
    != 'assert!( self.curve_fee_cap_id.contains(&object::id(curve_fee_cap)), blast_fun::errors::creator_cap_not_live!(), );' ]] \
  || [[ -n "$(move_production_type PackageWitness <<<"$launch_facts")" ]] \
  || [[ "$(count_occurrences '\bpackage_witness\(\)' <<<"$launch_source")" != 4 ]] \
  || [[ -n "$(awk -F'\t' '$1 == "FN" && $9 ~ /PackageWitness/ { print $2 }' <<<"$launch_facts")" ]] \
  || [[ "$(rg -l '\bPackageWitness\b' sources --glob '*.move' | tr '\n' ' ')" != 'sources/blast_fun.move ' ]] \
  || [[ "$(rg -l '\bpackage_witness\(\)' sources --glob '*.move' | LC_ALL=C sort | tr '\n' ' ')" != 'sources/blast_fun.move sources/config/launch_config.move sources/launch/launch.move ' ]] \
  || [[ "$(rg -l '\bowner_proof::' sources --glob '*.move' | tr '\n' ' ')" != 'sources/launch/launch.move ' ]]; then
  launch_authority_violations+='  the owner proof must check the version and the live curve-fee cap, and the package witness must be obtained only by finalize, migrate, prove_owner, and unpause'$'\n'
fi
# Each creator-cap reassignment stores the primitive's one-shot action slot, whose action is the
# recipient; only the ready action reaches the reassignment that records new authority.
if ! rg -Fq 'curve_fee_cap_reassignment: DelayedAction<CurveFeeCapReassignment, address>,' sources/launch/launch.move \
  || ! rg -Fq 'creator_metadata_cap_reassignment: DelayedAction<CreatorMetadataCapReassignment, address>,' sources/launch/launch.move \
  || rg -n '\b(cap_delay_ms|pending_(curve_fee|metadata)_cap_recipient|apply_cap_reassignment_delay)\b' sources/launch/launch.move \
  || [[ "$(launch_functions_containing 'self.curve_fee_cap_reassignment.take_action(clock)')" != 'apply_curve_fee_cap_reassignment ' ]] \
  || [[ "$(launch_functions_containing 'self.creator_metadata_cap_reassignment.take_action(clock)')" != 'apply_creator_metadata_cap_reassignment ' ]]; then
  launch_authority_violations+='  creator-cap reassignments must store the primitive action slot and take its ready recipient only on reassignment'$'\n'
fi
# The package-only cap constructors are reached only from the owning module and the launch that
# records the resulting authority; only the launch claims from the ledger.
if [[ "$(rg -l '\bnew_curve_fee_cap\b' sources | sort | tr '\n' ' ')" \
    != 'sources/launch/creator_authority.move sources/launch/launch.move ' ]] \
  || [[ "$(rg -l '\bnew_creator_metadata_cap\b' sources | sort | tr '\n' ' ')" \
    != 'sources/launch/creator_authority.move sources/launch/launch.move ' ]] \
  || [[ "$(rg -l '\.(protocol|creator_(meme|quote))_fees\.' sources | tr '\n' ' ')" != 'sources/launch/launch.move ' ]]; then
  launch_authority_violations+='  creator capability constructors or ledger claims are reachable outside creator_authority.move and launch.move'$'\n'
fi

# Blast's fee claims are permissionless, so no caller input may choose the payee: each pays the
# launch's sealed core Ledger to the core Treasury, the partner bound at creation first (ADR 0105),
# and every transfer the launch makes goes through blast_core::payout.
if [[ "$(move_production_signature claim_protocol_fees <<<"$launch_facts")" \
    != 'fun claim_protocol_fees<Meme, Quote>( self: &mut Launch<Meme, Quote>, package_version: &PackageVersion<BLAST_FUN>, treasury: &Treasury, ctx: &mut TxContext, )' ]] \
  || [[ "$(move_production_signature claim_protocol_fees_with_partner <<<"$launch_facts")" \
    != 'fun claim_protocol_fees_with_partner<Meme, Quote>( self: &mut Launch<Meme, Quote>, package_version: &PackageVersion<BLAST_FUN>, treasury: &Treasury, partner: &Partner, ctx: &mut TxContext, )' ]] \
  || [[ "$(move_production_body claim_protocol_fees <<<"$launch_facts" | move_semantic_shape)" \
    != 'package_version.assert_current(constants::version!());self.protocol_fees.pay(treasury,ctx);' ]] \
  || [[ "$(move_production_body claim_protocol_fees_with_partner <<<"$launch_facts" | move_semantic_shape)" \
    != 'package_version.assert_current(constants::version!());self.protocol_fees.pay_with_partner(treasury,partner,ctx);' ]] \
  || ! rg -Fxq 'use fun payout::pay as Balance.pay;' sources/launch/launch.move \
  || [[ -n "$(move_production_function_contract pay <<<"$launch_facts")$(move_production_function_contract pay_treasury <<<"$launch_facts")" ]]; then
  launch_authority_violations+='  a protocol fee claim must pay the sealed core Ledger to the core Treasury with no caller-chosen payee, and launch payouts must use blast_core::payout'$'\n'
fi

# Records a violation, labelled with its ticket, for every needle not used by exactly the
# expected launch.move production functions.
check_launch_needles() {
  local ticket="$1" spec needle expected actual
  shift

  for spec in "$@"; do
    needle="${spec%%|*}"
    expected="${spec#*|}"
    actual="$(launch_functions_containing "$needle")"
    if [[ "$actual" != "$expected" ]]; then
      launch_authority_violations+="  ${ticket} '${needle}' is used by '${actual}' instead of '${expected}'"$'\n'
    fi
  done
}

# T-004 keeps owned construction permissionless while creator authentication remains
# post-share: only a shared launch releases the creator claim, and the claim itself issues both
# creator capabilities to the caller.
check_launch_needles T-004 \
  'creator_authority::claim_creator_caps<|claim_creator_caps ' \
  'clock.timestamp_ms()|has_opening_round_ended share ' \
  'curve::cap_buy_quote_input(|buy_from_curve ' \
  'curve::quote_buy(|buy_from_curve ' \
  'transfer::share_object(self)|share ' \
  'events::launch_shared<Meme, Quote>(|share ' \
  'events::bought<Meme, Quote>(|buy_from_curve '
if ! in_order \
  'package_version.assert_current(constants::version!());' \
  'self.public_start_ms.is_some()' \
  'self.creator.extract()' \
  <<<"$(move_production_body claim_creator_caps <<<"$launch_facts")"; then
  launch_authority_violations+='  T-004 claim_creator_caps must be version-gated and release the creator claim only after share'$'\n'
fi

# ADR 0093 starts public time at share and keeps one opening-round bid record per bidder, written
# only by joining and removed only by delivery; the whole pot buys through the one curve path.
check_launch_needles 'ADR 0093' \
  'self.public_start_ms = |share ' \
  '.add_dynamic_field(|join_opening_round ' \
  '.dynamic_field_mut|join_opening_round ' \
  '.remove_dynamic_field|deliver_opening_round ' \
  'self.buy_from_curve(|buy settle_opening_round ' \
  'dynamic_field::|'

for setup_visibility in \
  T-004:share:public T-004:claim_creator_caps:public T-004:buy:public \
  'ADR 0093:join_opening_round:public' 'ADR 0093:settle_opening_round:public' \
  'ADR 0093:deliver_opening_round:public' 'ADR 0093:buy_from_curve:private'; do
  setup_ticket="${setup_visibility%%:*}"
  setup_rest="${setup_visibility#*:}"
  setup_name="${setup_rest%%:*}"
  setup_contract="$(move_production_function_contract "$setup_name" <<<"$launch_facts")"
  if [[ "$setup_contract" != "${setup_rest#*:}:0:0:fun "* ]]; then
    launch_authority_violations+="  ${setup_ticket} ${setup_name} has widened or missing visibility"$'\n'
  fi
done

launch_owned_sinks="$(awk -F'\t' '
  $1 == "FN" && $6 == 0 && $9 ~ /[(,] ?(mut )?[A-Za-z_][A-Za-z0-9_]*: Launch</ { print $2 }
' <<<"$launch_facts" | sort | tr '\n' ' ')"
launch_buy_body="$(move_semantic_shape <<<"$(move_production_body buy_from_curve <<<"$launch_facts")")"

if [[ "$launch_owned_sinks" != 'share ' ]]; then
  launch_authority_violations+='  T-004 must share through one key-only sink'$'\n'
fi
if ! in_order 'slippage_exceeded!()' 'self.real_quote_reserve.join(quote_in);' \
  <<<"$launch_buy_body"; then
  launch_authority_violations+='  ADR 0093 curve purchases must check slippage before custody'$'\n'
fi
# ADR 0093 reaches bid records only through these module-local aliases (production bodies name
# no dynamic_field:: call, per the needle above), and launch.move is the only source naming
# dynamic_field. Only delivery removes a record, per the needle above.
launch_dynamic_field_aliases="$(rg -o 'use fun [^;]*dynamic_field[^;]*;' <<<"$launch_source" \
  | LC_ALL=C sort | tr '\n' ' ')"
if [[ "$launch_dynamic_field_aliases" != 'use fun dynamic_field::add as UID.add_dynamic_field; use fun dynamic_field::borrow_mut as UID.dynamic_field_mut; use fun dynamic_field::exists as UID.has_dynamic_field; use fun dynamic_field::remove as UID.remove_dynamic_field; ' ]] \
  || rg -q '\bdynamic_field as\b' <<<"$launch_source"; then
  launch_authority_violations+='  ADR 0093 must reach bid records only through the add, borrow_mut, exists, and remove aliases'$'\n'
fi
for move_file in "${source_files[@]}"; do
  # ADR 0098 keeps the accepted partners as dynamic fields of LaunchConfig.
  [[ "$move_file" == sources/launch/launch.move || "$move_file" == sources/config/launch_config.move ]] && continue

  if move_facts "$move_file" | move_normalized_source | rg -q '\bdynamic_field\b'; then
    launch_authority_violations+="  ADR 0093 ${move_file} must not name dynamic_field; only launch.move and launch_config.move keep records"$'\n'
  fi
done
for move_file in "${source_files[@]}"; do
  setup_source="$(move_facts "$move_file" | move_normalized_source)"
  if rg -q '\bCreatorSetupReceipt\b' <<<"$setup_source"; then
    launch_authority_violations+="  ${move_file} introduces a setup receipt"$'\n'
  fi
done

if [[ -n "$launch_authority_violations" ]]; then
  printf '%s' "$launch_authority_violations"
  echo 'Launch creator authority must stay split per concern: only the recorded CurveFeeCap claims creator fees, only the recorded CreatorMetadataCap edits metadata through the retained MetadataCap, and only a version-gated creator admin reassigns.' >&2
  failures=$((failures + 1))
fi

if [[ "$(launch_functions_containing 'events::migration_allocation_paid<Meme, Quote>(')" != 'migrate ' ]] \
  || [[ "$(launch_functions_containing 'events::migrated<Meme, Quote>(')" != 'migrate ' ]]; then
  echo 'Allocation payouts and the migration must be replayed only by migrate.' >&2
  failures=$((failures + 1))
fi
if rg -n '\bstate_version\b|launch_state_version' sources tests; then
  echo 'PackageVersion must remain the only version; Launch state and events must not add another one.' >&2
  failures=$((failures + 1))
fi

# Every production function that takes the shared PackageVersion checks it as its first
# statement, directly or by first calling a receiver helper that does, and no public function
# reaching mutable shared state escapes that guard. Creation calls also check individually:
# one PTB can mix versions even though the initializer cannot leave that transaction.
version_guard_violations="$(
  for move_file in "${source_files[@]}"; do
    move_facts "$move_file" | awk -F'\t' -v file="$move_file" '
      $1 == "FN" && $6 == 0 && $9 ~ /[(,] package_version: &PackageVersion<BLAST_FUN>,/ {
        if ($10 ~ /^package_version\.assert_current\(constants::version!\(\)\);/) gated[$2] = 1
        else pending[$2] = $10
      }
      $1 == "FN" && $6 == 0 && $3 == "public" \
        && ($9 ~ /: &mut (Launch|Currency)</ || $9 ~ /: &mut (LaunchConfig|RuntimeConfig|PackageAdmin),/) \
        && $9 !~ /[(,] package_version: &(mut )?PackageVersion<BLAST_FUN>,/ {
        print "  " file ": " $2 " reaches mutable shared state without PackageVersion"
      }
      END {
        for (name in pending) {
          delegated = 0
          for (helper in gated) {
            if (index(pending[name], "self." helper "(package_version,") == 1) delegated = 1
          }
          if (!delegated) print "  " file ": " name " must check the live package version as its first statement"
        }
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
        '\b(blast_acl::(grant_admin|revoke_admin|destroy_admin_cap|begin_super_admin_transfer|cancel_super_admin_transfer|accept_super_admin_transfer|destroy_retired_super_admin_cap|sign_in)|runtime_config::((schedule|apply|cancel)_(creator_claim_signer|creator_claim_signer_delay|protocol_fee_share|treasury)|revoke_creator_claim_signer|creator_claim_signers|protocol_fee_share|treasury)|launch_config::(set_meme_decimals_allowed|set_quote_allowed|(schedule|apply|cancel)_(trade_fees|protocol_allocation|protocol_lp_fees|venue|venue_delay|creation_fee)|remove_venue|snapshot_for_launch|protocol_allocation|protocol_lp_fees|is_guarded|allowed_meme_decimals_count_for_testing|allowed_quote_count_for_testing|allowed_venue_count_for_testing)|allocation::(add_protocol|apportion_meme|apportion_quote|destinations)|launch::(set_virtual_quote|set_graduation_target|set_allocation_plan|set_lp_fee_split|set_opening_round|set_partner|finalize|share|claim_creator_caps|apply_curve_fee_cap_(reassignment|delay)|apply_metadata_cap_(reassignment|delay)|migrate|prove_owner|set_name|set_description|set_icon_url)|launch_ticket::(destroy|decimals)|fees::(accrue|claim_creator_fees|claim_protocol_fees)|package::test_upgrade|package_admin::(authorize_upgrade|commit_upgrade|publisher_id_for_testing|upgrade_cap_id_for_testing|package_id_for_testing|version_for_testing|policy_for_testing))(<[^>]+>)?\(' \
      || true; } | sed "s|^|  ${move_file}: |"
  done
)"

if [[ -n "$receiver_syntax_violations" ]]; then
  printf '%s\n' "$receiver_syntax_violations"
  echo 'Blast-owned receiver functions must use Move 2024 dot syntax.' >&2
  failures=$((failures + 1))
fi

if rg -n '^[[:space:]]+assert_launch_snapshot\(&|=[[:space:]]*reach_migration_after_sell\(' \
  tests/launch/launch_tests.move; then
  echo 'Launch test helpers with a natural Launch receiver must use dot syntax.' >&2
  failures=$((failures + 1))
fi

if rg -n '\bsui::tx_context::TxContext\b' sources tests; then
  echo 'Natural framework and private receivers must use implicit types and dot syntax.' >&2
  failures=$((failures + 1))
fi

if rg -n '\b(add_admin|AdminAdded|QuoteRemoved|MigrationWitnessRemoved)\b' sources tests \
  || rg -n '\b(active_quote_count_for_testing|migration_witness_count_for_testing)\b' sources tests; then
  echo 'Package interfaces must use grant/revoke authority and set-style allowlist vocabulary.' >&2
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

creator_authority_facts="$(move_facts sources/launch/creator_authority.move)"

# Each creator capability is an identity-only object whose one production constructor lives in
# this module (ADR 0082). After migration the curve-fee cap proves ownership to the launch's
# `blast_vault` vault through `launch::prove_owner`; LP-fee authority lives there (ADR 0137).
creator_capability_violations=''
for capability_spec in 'CurveFeeCap|new_curve_fee_cap' 'CreatorMetadataCap|new_creator_metadata_cap'; do
  IFS='|' read -r capability_type capability_constructor <<<"$capability_spec"

  if [[ "$(move_production_type "$capability_type" <<<"$creator_authority_facts")" \
      != "struct ${capability_type}<phantom Meme> has key, store { id: UID, }" ]]; then
    creator_capability_violations+="  ${capability_type} is not an identity-only key, store capability"$'\n'
  fi
  if [[ "$(awk -F'\t' -v needle="${capability_type} { id: object::new(ctx) }" '
      $1 == "FN" && $6 == 0 && index($10, needle) > 0 { print $2 }
    ' <<<"$creator_authority_facts" | tr '\n' ' ')" != "${capability_constructor} " ]]; then
    creator_capability_violations+="  ${capability_type} is not constructed only by ${capability_constructor}"$'\n'
  fi
done

if [[ -n "$creator_capability_violations" ]]; then
  printf '%s' "$creator_capability_violations"
  echo 'creator_authority.move must own CurveFeeCap<Meme> and CreatorMetadataCap<Meme> construction.' >&2
  failures=$((failures + 1))
fi

if ! rg -U -q \
  'public enum CreatorRecipient has copy, drop, store \{\s*Address\(address\),\s*Account\(vector<u8>\),\s*\}' \
  sources/launch/creator_authority.move \
  || ! rg -q 'public fun new_address\(recipient: address\): CreatorRecipient' sources/launch/creator_authority.move \
  || ! rg -q 'public fun new_account\(account_commitment: vector<u8>\): CreatorRecipient' \
    sources/launch/creator_authority.move; then
  echo 'Public creator constructors must return plain CreatorRecipient values.' >&2
  failures=$((failures + 1))
fi

creator_authority_production="$(sed '/^\/\/ === Test-Only Functions ===/,$d' sources/launch/creator_authority.move)"
creator_authority_source="$(move_normalized_source <<<"$creator_authority_facts")"

# Creator authority is neither version- nor admin-gated: claims are signer-authorized and
# reassignment is gated in launch.
if rg -n '\b[a-z_]*claimed:[[:space:]]*bool|\bissue_creator_cap\b|\btransfer::' \
  <<<"$creator_authority_production" \
  || rg -q '\bMetadataCap\b|\bcoin_registry\b' <<<"$creator_authority_source" \
  || rg -q '\b(AdminWitness|blast_fun_domain|PackageVersion|package_version)\b' \
    <<<"$creator_authority_source" \
  || rg -v -Fx 'use blast_fun::constants;' sources/launch/creator_authority.move | rg -q '^use blast_fun::' \
  || [[ "$(move_production_function_contract claim_creator_caps <<<"$creator_authority_facts")" != 'package:0:0:fun claim_creator_caps<Meme>( recipient: CreatorRecipient, signer_public_keys: &vector<vector<u8>>, attestation: Option<vector<u8>>, clock: &Clock, ctx: &mut TxContext, ): (CurveFeeCap<Meme>, CreatorMetadataCap<Meme>)' ]] \
  || [[ "$(move_production_function_contract new_curve_fee_cap <<<"$creator_authority_facts")" \
    != 'package:0:0:fun new_curve_fee_cap<Meme>(ctx: &mut TxContext): CurveFeeCap<Meme>' ]] \
  || [[ "$(move_production_function_contract new_creator_metadata_cap <<<"$creator_authority_facts")" \
    != 'package:0:0:fun new_creator_metadata_cap<Meme>(ctx: &mut TxContext): CreatorMetadataCap<Meme>' ]] \
  || [[ "$(move_production_type CreatorClaimMessage <<<"$creator_authority_facts")" \
    != 'struct CreatorClaimMessage has drop { meme: TypeName, account_commitment: vector<u8>, claimant: address, expiry_ms: u64, }' ]] \
  || rg -q '\bed25519_signature_length\b' sources; then
  echo 'Creator claims must return exactly one CurveFeeCap and one CreatorMetadataCap, and creator_authority.move must import no Blast module but constants and carry no version or admin gate, native MetadataCap pass-through, flag, or transfer.' >&2
  failures=$((failures + 1))
fi
if rg -n 'schema_version|action_tag|nonce' sources/launch/creator_authority.move; then
  echo 'The one-time creator claim must not duplicate its fixed type and consumed marker.' >&2
  failures=$((failures + 1))
fi

if rg -l '^public struct RuntimeConfig has key' sources \
  | rg -v '^sources/config/runtime_config\.move$'; then
  echo 'RuntimeConfig is declared outside its owning module.' >&2
  failures=$((failures + 1))
fi

if rg -l '^public struct (CurveFeeCap|CreatorMetadataCap)\b' sources \
  | rg -v '^sources/launch/creator_authority\.move$' \
  || rg -n '\bCreatorCap\b|\bclaim_creator_cap\b|\bcreator_cap_claimed\b|\bCreatorCapClaimed\b' sources; then
  echo 'Creator capabilities are declared outside their owning module, or the irrevocable possession-only CreatorCap was reintroduced.' >&2
  failures=$((failures + 1))
fi

# The launchpad holds only the launch-time LP-fee split and hands it over in the vault terms at
# migration. Recurring LP-fee policy, collection, and split updates live in the vault, so no
# router, policy, or LP-fee event may return here, and neither may the retired per-asset route
# tables or the curve-fee custodian lock. The split is blast_core's FeeSplit: the launchpad
# declares no split, route, constructor, or apportionment of its own.
launchpad_production_source="$(for move_file in "${source_files[@]}"; do move_facts "$move_file" | move_normalized_source; done)"
if [[ -e sources/fee_router.move || -e sources/lp_fee_policy.move ]] \
  || rg -q '\b(FeeRouter|RouterConfigCap|LpFeePolicy|PolicySnapshot|SettlementBinding|fee_router|lp_fee_policy|new_fee_router|fee_router_id)\b' \
    <<<"$launchpad_production_source" \
  || rg -q '\b(Routes|routes|meme_routes|quote_routes|apportion_routes|lp_fee_routes|set_lp_fee_routes)\b' \
    <<<"$launchpad_production_source" \
  || rg -q '\b(CurveFeeAuthority|lock_creator_fees|claim_custodied_creator_fees|assert_fee_custodian|custodian_type|CreatorFeesLocked|creator_fees_locked|creator_custodian_mismatch|invalid_fee_custodian)\b' \
    <<<"$launchpad_production_source" \
  || rg -n '^public struct (LpFeePolicyChanged|LpFeeDestinationChanged|FeeRouterCreated|RouterActivated|FeesCollected|RouterConfigCapReleased|RouterConfigCapDelivered|RoutesChanged|FeeSplitChanged|CreatorFeesLocked)\b' \
    sources/lib/events.move \
  || rg -n '^public (struct|enum) (FeeSplit|Route|Destination)\b' sources --glob '*.move' \
  || rg -n '^(public(\(package\))? )?fun (fee_split|route|apportion_fee_split|recipients|destination)\(' \
    sources --glob '*.move' \
  || [[ "$(rg -l '\bFeeSplit\b' sources --glob '*.move' | LC_ALL=C sort | tr '\n' ' ')" \
    != 'sources/launch/launch.move sources/lib/events.move ' ]] \
  || ! rg -Fxq 'use blast_core::fee_split::FeeSplit;' sources/lib/events.move \
  || rg -q '\bfee_split::(new|route|apportion)\b|\.apportion\(' <<<"$launch_source"; then
  echo 'Launchpad must keep only the launch-time blast_core FeeSplit, with no local split, route, or apportionment and no custodian lock; recurring LP-fee routing, policy, and their events belong to the vault.' >&2
  failures=$((failures + 1))
fi

# T-010: one permissionless call checks the version, the migration pause, and MigrationReady, reads
# Blast's applied LP-fee share before any payout, then pays every project recipient, accrues Blast's one-time
# migration fee, disposes of the curve's unsold Meme, commits Migrated, and returns a hand-off
# sealed by this package's witness: exactly the pool share, for the stored venue, with vault terms
# carrying the stored split and partner and the residuals paid to Blast. The stored venue is the
# only party that can redeem it, so no caller witness is checked. Only order anchors are pinned.
launch_migrate_shape="$(move_production_body migrate <<<"$launch_facts" | move_semantic_shape)"
if [[ "$(launch_functions_containing 'self.lifecycle = Lifecycle::Migrated;')" != 'migrate ' ]] \
  || [[ "$(move_production_type Migrated <<<"$events_facts")" != 'struct Migrated<phantom Meme, phantom Quote> has copy, drop { launch_id: ID, meme_amount: u64, quote_amount: u64, disposed_meme: u64, total_supply_after: u64, }' ]] \
  || [[ "$(move_production_function_contract migrate <<<"$launch_facts")" != 'public:0:0:fun migrate<Meme, Quote>( self: &mut Launch<Meme, Quote>, package_version: &PackageVersion<BLAST_FUN>, config: &LaunchConfig, currency: &mut Currency<Meme>, clock: &Clock, ctx: &mut TxContext, ): Migration<Meme, Quote>' ]] \
  || [[ "$launch_migrate_shape" != 'package_version.assert_current(constants::version!());package_version.assert_not_paused(constants::migration_pause_bit!());assert!(self.lifecycle == Lifecycle::MigrationReady,blast_fun::errors::invalid_launch_lifecycle!());let(protocol_meme_bps,protocol_quote_bps)= config.protocol_lp_fees();let plan = self.allocation_plan;'* ]] \
  || [[ "$(count_occurrences 'config\.protocol_lp_fees\(\)' <<<"$launch_migrate_shape")" != 1 ]] \
  || ! in_order \
    'let plan = self.allocation_plan;' \
    'events::migration_allocation_paid<Meme,Quote>(' \
    'self.protocol_fees.accrue(' \
    'self.allocated_meme.split(protocol_meme_amount)' \
    'self.real_quote_reserve.split(protocol_quote_amount)' \
    'events::protocol_fees_accrued<Meme,Quote>(' \
    'let meme = self.allocated_meme.withdraw_all();' \
    'let quote = self.real_quote_reserve.withdraw_all();' \
    'self.pending_burn.withdraw_all()' \
    'self.meme_reserve.withdraw_all()' \
    'self.lifecycle = Lifecycle::Migrated;' \
    'events::migrated<Meme,Quote>(' \
    'let terms = migration::vault_terms(package_witness(),self.id.to_inner(),self.lp_fee_split,protocol_meme_bps,protocol_quote_bps,self.partner_id,migration::residuals_to_protocol());' \
    <<<"$launch_migrate_shape" \
  || [[ "$launch_migrate_shape" != *';migration::new(package_witness(),meme,quote,self.venue,terms)' ]] \
  || [[ "$(count_occurrences 'migration::(new|vault_terms|residuals_to_protocol)\(' <<<"$launch_source")" != 3 ]] \
  || rg -q '\bresiduals_to_owner\b|\bmigration::(redeem|issue_ticket)\b|\bVaultTerms\b' <<<"$launch_source" \
  || [[ "$(rg -l '\bmigration::' sources --glob '*.move' | tr '\n' ' ')" != 'sources/launch/launch.move ' ]]; then
  echo 'T-010 must check the version, migration pause, and MigrationReady first, pay every project recipient, accrue Blast migration fees, dispose of the unsold Meme, and commit Migrated before returning a PackageWitness-sealed hand-off of exactly the pool share for the stored venue, with protocol residuals.' >&2
  failures=$((failures + 1))
fi

# T-013: each success event in the replay schema is emitted only after the state write or native
# transfer it records, inside its writer's own production body. Only order anchors are pinned:
# the written field, the called operation, or the constructed type, never a local or argument name.
# Delayed settings have no consumer success event: the primitive emits after its own write.
events_follow_mutations() {
  local file="$1" function="$2"
  shift 2

  in_order "$@" <<<"$(move_facts "$file" | move_production_body "$function" | move_semantic_shape)"
}

if ! events_follow_mutations sources/launch/launch_ticket.move new 'LaunchTicket{' 'events::launch_ticket_created<' \
  || ! events_follow_mutations sources/launch/launch.move finalize \
    'ticket.destroy(' 'Launch{' 'events::launch_created<' \
  || ! events_follow_mutations sources/launch/launch.move apply_curve_fee_cap_reassignment \
    'self.curve_fee_cap_id = option::some(' 'transfer::public_transfer(' 'events::curve_fee_cap_reassigned<Meme,Quote>(' \
  || ! events_follow_mutations sources/launch/launch.move apply_creator_metadata_cap_reassignment \
    'self.creator_metadata_cap_id = option::some(' 'transfer::public_transfer(' 'events::creator_metadata_cap_reassigned<Meme,Quote>(' \
  || ! events_follow_mutations sources/launch/launch.move buy_from_curve \
    'self.real_quote_reserve.join(' \
    'self.meme_reserve.split(' \
    'self.lifecycle = Lifecycle::MigrationReady;' \
    'self.accrue_trade_fees(' \
    'events::bought<Meme,Quote>(' \
  || ! events_follow_mutations sources/launch/launch.move share \
    'self.public_start_ms = option::some(' 'events::launch_shared<Meme,Quote>(' 'transfer::share_object(' \
  || ! events_follow_mutations sources/launch/launch.move join_opening_round \
    'self.opening_round_quote.join(' 'events::opening_round_joined<Meme,Quote>(' \
  || ! events_follow_mutations sources/launch/launch.move settle_opening_round \
    'self.lifecycle = Lifecycle::Live;' 'self.opening_round_quote.join(' 'events::opening_round_settled<Meme,Quote>(' \
  || ! events_follow_mutations sources/launch/launch.move deliver_opening_round \
    '.remove_dynamic_field' 'self.opening_round_bids = ' 'self.opening_round_quote.pay(' \
    'events::opening_round_delivered<Meme,Quote>(' \
  || ! events_follow_mutations sources/launch/launch.move migrate \
    'payout::pay_or_vest(&mut self.allocated_meme,meme,payee,clock,ctx);' \
    'payout::pay_or_vest(&mut self.real_quote_reserve,quote,payee,clock,ctx);' \
    'events::migration_allocation_paid<Meme,Quote>(' \
    'self.protocol_fees.accrue(' \
    'events::protocol_fees_accrued<Meme,Quote>(' \
    'currency.burn_balance(' \
    'events::migrated<Meme,Quote>('; then
  echo 'Every replay-schema success event must follow the state write or native transfer it records.' >&2
  failures=$((failures + 1))
fi

if ((failures != 0)); then
  exit 1
fi

echo 'Source module boundaries and Move style: OK'
