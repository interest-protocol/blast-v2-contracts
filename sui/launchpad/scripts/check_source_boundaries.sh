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
    sources/launch.move sources/launch_config.move sources/lib/events.move \
    | rg -v ':use fun$' | sed 's/.*use //' | sort -u
)"
if [[ "$core_import_roots" != $'blast_admin\nblast_fun\nblast_partners\nstd\nsui' ]] \
  || [[ "$(sed -n '/^\[dependencies\]/,/^\[/p' Move.toml | rg -o '^[A-Za-z_][A-Za-z0-9_]*[[:space:]]*=' | sed 's/[[:space:]]*=//' | sort)" != $'blast_admin\nblast_partners' ]]; then
  echo 'Provider-neutral launch state, config, and events may import only local core, std, Sui, blast_admin, and blast_partners.' >&2
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

if [[ ! -f sources/lib/bps.move ]] \
  || ! rg -q '^public struct Bps\(u64\) has copy, drop, store;' sources/lib/bps.move \
  || [[ "$(rg -c '^public fun (new|value|apply_up)\(' sources/lib/bps.move)" != 3 ]] \
  || [[ "$(rg -c '^public(\(package\))? fun ' sources/lib/bps.move)" != 3 ]] \
  || rg -n '^(entry|public entry) fun |\b(UID|key|Balance|Coin|TxContext|transfer::|events::)\b' \
    sources/lib/bps.move \
  || ! rg -Fq 'value <= constants::basis_points_denominator!()' sources/lib/bps.move \
  || ! rg -Fq 'amount.mul_div_ceil(self.value(), constants::basis_points_denominator!())' sources/lib/bps.move; then
  echo 'bps.move must keep only a public validated opaque type and its validation, value, and round-up application operations.' >&2
  failures=$((failures + 1))
fi

# Every other module must delegate the inclusive range to bps::new, in either
# operand order; stricter policy bounds stay allowed.
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

# The OTW creates one owned Bootstrap. Only validated custody intake may consume it and share
# PackageVersion; publication must not supply a usable generation before custody is sealed.
if [[ ! -f sources/blast_fun.move ]] \
  || ! rg -Fq 'public struct BLAST_FUN() has drop;' sources/blast_fun.move \
  || ! rg -U -q \
    'public struct PackageVersion has key \{\s*id: UID,\s*generation: OperationalVersion<BLAST_FUN>,\s*\}' \
    sources/blast_fun.move \
  || ! rg -U -q \
    'public struct Bootstrap has key \{\s*id: UID,\s*publisher: Publisher,\s*generation: OperationalVersion<BLAST_FUN>,\s*\}' \
    <<<"$blast_production" \
  || ! rg -q '^const PACKAGE_VERSION: u64 = 1;$' sources/blast_fun.move \
  || ! rg -q '^const NEXT_PACKAGE_VERSION: u64 = 2;$' sources/blast_fun.move \
  || [[ "$(rg -c '^(public struct|fun) ' <<<"$blast_production")" != 4 ]] \
  || [[ "$(rg -c '^fun init\(' <<<"$blast_production")" != 1 ]] \
  || [[ "$(rg -c '^public\(package\) fun (destroy|share_version|assert_current|assert_next|advance)\(' <<<"$blast_production")" != 5 ]] \
  || rg -n '^(public|entry|public entry) fun ' <<<"$blast_production" \
  || rg -n '^public\(package\) fun activate\(' <<<"$blast_production" \
  || ! rg -Fq 'self.generation.assert_current(PACKAGE_VERSION);' sources/blast_fun.move \
  || ! rg -Fq 'self.generation.assert_next(NEXT_PACKAGE_VERSION);' sources/blast_fun.move \
  || ! rg -Fq 'self.generation.advance(&self.id, NEXT_PACKAGE_VERSION);' sources/blast_fun.move \
  || ! rg -Fq 'let generation = operational_version::new(&otw);' sources/blast_fun.move \
  || rg -n '\.checked_add\(|events::' <<<"$blast_production"; then
  echo 'blast_fun.move must own the unique publication bootstrap and the guarded generation container.' >&2
  failures=$((failures + 1))
fi

# Exact construction and intake paths keep a later helper from bypassing bootstrap custody.
if [[ "$(move_production_body init <<<"$(move_facts sources/blast_fun.move)")" \
    != 'let generation = operational_version::new(&otw); let publisher = sui::package::claim(otw, ctx); transfer::transfer(Bootstrap { id: object::new(ctx), publisher, generation }, ctx.sender());' ]] \
  || [[ "$(move_production_body destroy <<<"$(move_facts sources/blast_fun.move)")" \
    != 'let Bootstrap { id, publisher, generation } = self; id.delete(); (publisher, generation)' ]] \
  || [[ "$(move_production_body share_version <<<"$(move_facts sources/blast_fun.move)")" \
    != 'transfer::share_object(PackageVersion { id: object::new(ctx), generation });' ]] \
  || [[ "$(rg -c '^public\(package\) fun ' <<<"$blast_production")" != 5 ]] \
  || [[ "$(rg -l '\bshare_version\(' sources --glob '*.move' | LC_ALL=C sort | tr '\n' ' ')" \
    != 'sources/blast_fun.move sources/package_admin.move ' ]]; then
  echo 'Only wrap may activate the unique bootstrap after sealing native capability custody.' >&2
  failures=$((failures + 1))
fi

# Administration is the shared blast_admin ACL. This package only declares its roles, one
# ability-free type per administrator concern (ADR 0094), and creates no administration state.
if [[ -e sources/acl.move || -e sources/blast_acl.move ]]; then
  echo 'Launchpad must not reintroduce a local ACL implementation.' >&2
  failures=$((failures + 1))
fi

if rg -n '^public struct (ACL|Authority|ProtocolAuthority|SuperAdminCap|AdminCap|AdminWitness)\b' \
  sources --glob '*.move'; then
  echo 'Administration types must come from blast_admin, never from a local copy.' >&2
  failures=$((failures + 1))
fi

launchpad_roles=(
  UpgradeAdmin
  CreatorAdmin
  BuybackAdmin
  TreasuryAdmin
  FeeAdmin
  ListingAdmin
  AdapterAdmin
  ClaimSignerAdmin
  RewardsAdmin
)
launchpad_role_pattern="$(IFS='|'; echo "${launchpad_roles[*]}")"

if [[ ! -f sources/blast_fun_domain.move ]] \
  || [[ "$(move_facts sources/blast_fun_domain.move | move_normalized_source)" \
    != "module blast_fun::blast_fun_domain;$(printf ' public struct %s()' "${launchpad_roles[@]}")" ]]; then
  echo 'blast_fun_domain.move must declare exactly the nine reviewed ability-free roles and nothing else: no init, constant, function, or import.' >&2
  failures=$((failures + 1))
fi

# The witness type is each administrator action's role check, so every witness a source names is
# borrowed and names one concrete Launchpad role; a generic or foreign role fails here.
admin_witness_violations="$(for file in "${source_files[@]}"; do
  move_facts "$file" | move_normalized_source | { rg -o '&?AdminWitness<[^>]*>' || true; } \
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
      while (match(rest, /AdminWitness<[^>]*>/)) {
        roles = roles (roles == "" ? "" : ",") substr(rest, RSTART + 13, RLENGTH - 14)
        rest = substr(rest, RSTART + RLENGTH)
      }
      print module ":" $2 ":" roles
    }
  '
done | LC_ALL=C sort | tr '\n' ' ')"

if [[ "$admin_roles" != \
  'launch:reassign_curve_fee_cap:CreatorAdmin launch:reassign_metadata_cap:CreatorAdmin launch_config:add_partner:FeeAdmin launch_config:remove_partner:FeeAdmin launch_config:set_creation_fee:FeeAdmin launch_config:set_meme_decimals_allowed:ListingAdmin launch_config:set_migration_witness_allowed:AdapterAdmin launch_config:set_protocol_allocation:TreasuryAdmin launch_config:set_quote_allowed:ListingAdmin launch_config:set_trade_fees:FeeAdmin package_admin:authorize_upgrade:UpgradeAdmin package_admin:commit_upgrade_and_advance:UpgradeAdmin package_admin:make_immutable:UpgradeAdmin runtime_config:set_creator_claim_signer:ClaimSignerAdmin runtime_config:set_protocol_fee_share:FeeAdmin runtime_config:set_treasury:TreasuryAdmin ' ]]; then
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

package_admin_production="$(sed '/^\/\/ === Test-Only Functions ===/,$d' sources/package_admin.move)"

if [[ ! -f sources/package_admin.move || -f sources/upgrade.move ]] \
  || ! rg -U -q \
    'public struct PackageAdmin has key \{\s*id: UID,\s*custody: UpgradeCustody<BLAST_FUN>,\s*\}' \
    sources/package_admin.move \
  || [[ "$(rg -c '^public fun ' <<<"$package_admin_production")" != 4 ]] \
  || [[ "$(rg -c '^public fun (wrap|authorize_upgrade|commit_upgrade_and_advance|make_immutable)\(' <<<"$package_admin_production")" != 4 ]] \
  || rg -n '^public\(package\) fun ' <<<"$package_admin_production" \
  || rg -n '^public fun commit_upgrade\(|^public fun activate' <<<"$package_admin_production" \
  || [[ "$(rg -o '_: &AdminWitness<UpgradeAdmin>' <<<"$package_admin_production" | wc -l)" != 3 ]] \
  || ! rg -U -q \
    'public fun wrap\(bootstrap: Bootstrap, upgrade_cap: UpgradeCap, ctx: &mut TxContext\)' \
    sources/package_admin.move \
  || ! rg -U -q \
    'public fun authorize_upgrade\(\s*self: &mut PackageAdmin,\s*package_version: &PackageVersion,\s*_: &AdminWitness<UpgradeAdmin>,\s*digest: vector<u8>,\s*\): UpgradeTicket' \
    sources/package_admin.move \
  || ! rg -U -q \
    'public fun commit_upgrade_and_advance\(\s*self: &mut PackageAdmin,\s*package_version: &mut PackageVersion,\s*_: &AdminWitness<UpgradeAdmin>,\s*receipt: UpgradeReceipt,\s*\)' \
    sources/package_admin.move; then
  echo 'package_admin.move must expose only validated wrapping, upgrade-admin native administration, and one atomic commit-and-advance finalizer.' >&2
  failures=$((failures + 1))
fi

# Every governed custody transition asserts the current generation first, before
# it reaches the shared custody value. Commit-and-advance is the post-upgrade
# finalizer and instead proves the exact next generation first. No path narrows
# the upgrade policy: a narrowed cap could never commit and advance again, which
# would end upgradeability silently.
# Wrapping delegates Publisher and UpgradeCap provenance wholly to shared custody.
if [[ "$(move_production_body wrap <<<"$(move_facts sources/package_admin.move)")" \
    != 'let (publisher, generation) = bootstrap.destroy(); let id = object::new(ctx); let custody = upgrade_custody::new<BLAST_FUN>(id.to_inner(), publisher, upgrade_cap); transfer::share_object(PackageAdmin { id, custody }); blast_fun::blast_fun::share_version(generation, ctx);' ]] \
  || [[ "$(rg -c 'package_version\.assert_current\(\);' <<<"$package_admin_production")" != 2 ]] \
  || [[ "$(move_facts sources/package_admin.move \
    | awk -F'\t' '$1 == "FN" && $2 == "commit_upgrade_and_advance" { print $10 }')" \
    != 'package_version.assert_next();'* ]] \
  || rg -n '\brestrict_to_' sources \
  || move_facts sources/package_admin.move | awk -F'\t' '$1 == "NORM"' | rg -q '\w as \w' \
  || ! rg -Fq 'self.custody.commit_upgrade(custodian_id, receipt);' sources/package_admin.move \
  || ! rg -Fq 'package_version.advance();' sources/package_admin.move \
  || rg -n '\bpackage::(version|only_(additive|dep)_upgrades|make_immutable)\(' \
    <<<"$package_admin_production" \
  || rg -n 'admin_authorization|governance_cutover' sources/package_admin.move \
  || rg -U -n '^(public|entry|public\(package\)) fun [^(]+\([^)]*\): (&)?(Publisher|UpgradeCap)' \
    <<<"$package_admin_production" \
  || rg -n 'transfer::(public_)?transfer|burn_publisher' \
    <<<"$package_admin_production"; then
  echo 'Package administration must seal custody, check the version first, and expose no capability escape.' >&2
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

if rg -n '\b(Coin|Balance|UID|TxContext|transfer::|event::|object::)\b' sources/curve.move \
  || rg -n '^(public|entry) fun ' sources/curve.move \
  || [[ "$(move_facts sources/curve.move | move_production_functions)" \
    != 'amount_out:private:0 cap_buy_quote_input:package:0 quote_buy:package:0 quote_sell:package:0 ' ]]; then
  echo 'curve.move must remain a pure package-only numeric curve module.' >&2
  failures=$((failures + 1))
fi

# The reserves move by exactly the curve's input and its floored output, so the product cannot
# fall and needs no runtime reconciliation.
if [[ "$(rg -c '\bamount_out\(' sources/curve.move)" != 3 ]]; then
  echo 'Buy and sell must share the exact-input constant-product math.' >&2
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
    != 'accrue:package:0 accrue_protocol_fees:package:0 claim_creator_fees:package:0 claim_protocol_fees:package:0 new:package:0 ' ]] \
  || [[ "$(move_production_type FeeLedger <<<"$fees_facts")" \
    != 'struct FeeLedger<phantom Meme, phantom Quote> has store { protocol_meme: Balance<Meme>, creator_meme: Balance<Meme>, protocol_quote: Balance<Quote>, creator_quote: Balance<Quote>, protocol_sui: Balance<SUI>, }' ]] \
  || [[ "$(move_production_signature new <<<"$fees_facts")" \
    != 'fun new<Meme, Quote>(creation_fee: Balance<SUI>): FeeLedger<Meme, Quote>' ]] \
  || rg -q '\b(UID|key|transfer::|CreatorClaim|ed25519|recipient|launch_id)\b' <<<"$fees_source" \
  || rg -q '\b(creator_authority|CreatorCap|CurveFeeCap|BlastMetadataCap)\b' <<<"$fees_source" \
  || rg -q 'fee_balance_overflow|std::u64::max_value|max_balance' <<<"$fees_source" \
  || rg -q 'set_creator_fee_split|sui::event|events::' <<<"$fees_source"; then
  echo 'fees.move must remain an embedded supply-conserved ledger of both parties trade fees and every Blast fee, exposing only its five approved package functions to the embedding launch.' >&2
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
  echo 'fees.move must reach its five stored balances only through the approved receiver-style operations, never through aliases, module-form calls, or destructuring.' >&2
  failures=$((failures + 1))
fi

# Each owner's claim releases only its own two balances, and accrual splits the protocol share
# (rounded up) into the protocol buckets and the exact remainder into the creator's.
fee_ledger_violations=''

check_fee_function() {
  local name="$1" expected_signature="$2" expected_operations="$3" operations

  operations="$(move_production_body "$name" <<<"$fees_facts" | move_balance_operations)"
  if [[ "$(move_production_signature "$name" <<<"$fees_facts")" != "$expected_signature" ]] \
    || [[ "$operations" != "$expected_operations" ]]; then
    fee_ledger_violations+="  ${name} changed its signature or operates on '${operations}' instead of '${expected_operations}'"$'\n'
  fi
}

check_fee_function claim_creator_fees \
  'fun claim_creator_fees<Meme, Quote>( self: &mut FeeLedger<Meme, Quote>, ctx: &mut TxContext, ): (Coin<Meme>, Coin<Quote>)' \
  'creator_meme.value creator_meme.withdraw_all creator_quote.value creator_quote.withdraw_all '

check_fee_function claim_protocol_fees \
  'fun claim_protocol_fees<Meme, Quote>( self: &mut FeeLedger<Meme, Quote>, ): (Balance<Meme>, Balance<Quote>, Balance<SUI>)' \
  'protocol_meme.value protocol_meme.withdraw_all protocol_quote.value protocol_quote.withdraw_all protocol_sui.value protocol_sui.withdraw_all '

check_fee_function accrue \
  'fun accrue<Meme, Quote>( self: &mut FeeLedger<Meme, Quote>, mut meme_fee: Balance<Meme>, mut quote_fee: Balance<Quote>, protocol_fee_share_bps: Bps, ): (u64, u64, u64, u64)' \
  'creator_meme.join creator_quote.join protocol_meme.join protocol_quote.join '

check_fee_function accrue_protocol_fees \
  'fun accrue_protocol_fees<Meme, Quote>( self: &mut FeeLedger<Meme, Quote>, meme: Balance<Meme>, quote: Balance<Quote>, )' \
  'protocol_meme.join protocol_quote.join '

fees_accrue_body="$(move_production_body accrue <<<"$fees_facts")"

if ! rg -Fq 'let protocol_meme_amount = protocol_fee_share_bps.apply_up(meme_fee.value()); let protocol_quote_amount = protocol_fee_share_bps.apply_up(quote_fee.value()); let protocol_meme = meme_fee.split(protocol_meme_amount); let protocol_quote = quote_fee.split(protocol_quote_amount);' \
    <<<"$fees_accrue_body" \
  || ! rg -Fq 'self.protocol_meme.join(protocol_meme); self.creator_meme.join(meme_fee); self.protocol_quote.join(protocol_quote); self.creator_quote.join(quote_fee);' \
    <<<"$fees_accrue_body"; then
  fee_ledger_violations+='  accrue must round the protocol share up and join each half only to its own bucket'$'\n'
fi

if [[ -n "$fee_ledger_violations" ]]; then
  printf '%s' "$fee_ledger_violations"
  echo "Fee state splits on the policy-issued protocol share and releases each owner's balances only through its own full claim." >&2
  failures=$((failures + 1))
fi

runtime_config_facts="$(move_facts sources/runtime_config.move)"
runtime_config_source="$(move_normalized_source <<<"$runtime_config_facts")"

if [[ ! -f sources/runtime_config.move ]] \
  || [[ "$(move_production_functions <<<"$runtime_config_facts")" \
    != 'creator_claim_signer:package:0 init:private:0 new:private:0 protocol_fee_share:package:0 set_creator_claim_signer:public:0 set_protocol_fee_share:public:0 set_treasury:public:0 treasury:package:0 ' ]] \
  || [[ "$(move_production_type RuntimeConfig <<<"$runtime_config_facts")" \
    != 'struct RuntimeConfig has key { id: UID, creator_claim_signer_public_key: vector<u8>, protocol_fee_share_bps: Bps, treasury: address, }' ]] \
  || rg -q '\b(AdminCap|ProtocolAuthority|LaunchConfig|VecMap|VecSet|TypeName)\b' \
    <<<"$runtime_config_source" \
  || rg -q '\b(sequence|schema_version|action_tag|nonce)\b' <<<"$runtime_config_source"; then
  echo 'runtime_config.move must own only the version-gated creator-claim signer, protocol fee share, and treasury.' >&2
  failures=$((failures + 1))
fi

# The three setters are the only RuntimeConfig transitions; each is version-gated first and
# authorized by a borrowed AdminWitness of the role the admin role map pins.
runtime_config_violations=''
runtime_config_mutations="$(awk -F'\t' '
  $1 == "FN" && $6 == 0 && $10 ~ /self\.(creator_claim_signer_public_key|protocol_fee_share_bps|treasury) = / {
    print $2
  }
' <<<"$runtime_config_facts" | sort | tr '\n' ' ')"

if [[ "$runtime_config_mutations" \
  != 'set_creator_claim_signer set_protocol_fee_share set_treasury ' ]]; then
  runtime_config_violations+="  runtime state is mutated by '${runtime_config_mutations}' instead of the three setters"$'\n'
fi

runtime_config_ungated="$(awk -F'\t' '
  $1 == "FN" && $6 == 0 \
    && ($2 == "set_creator_claim_signer" || $2 == "set_protocol_fee_share" || $2 == "set_treasury") {
    if ($9 !~ /[(,] package_version: &PackageVersion,/) {
      print "  " $2 " must take the shared PackageVersion under that exact name"
    }
    if ($10 !~ /^package_version\.assert_current\(\);/) {
      print "  " $2 " must check the live package version as its first statement"
    }
    if ($9 !~ /[(,] _: &AdminWitness<(ClaimSignerAdmin|FeeAdmin|TreasuryAdmin)>,/) {
      print "  " $2 " must be authorized by a borrowed AdminWitness"
    }
  }
' <<<"$runtime_config_facts")"

if [[ -n "$runtime_config_ungated" ]]; then
  runtime_config_violations+="${runtime_config_ungated}"$'\n'
fi

# Every claim pays the treasury live, so its setter refuses the zero address and a no-op before
# the one write and its event.
if [[ "$(move_production_body set_treasury <<<"$runtime_config_facts" | move_semantic_shape)" \
  != 'package_version.assert_current();assert!(treasury != @0x0,blast_fun::errors::invalid_destination!());assert!(treasury != self.treasury,blast_fun::errors::unchanged!());self.treasury = treasury;events::treasury_changed(treasury);' ]]; then
  runtime_config_violations+="  set_treasury must reject the zero and current addresses before it writes and records the treasury"$'\n'
fi

if [[ -n "$runtime_config_violations" ]]; then
  printf '%s' "$runtime_config_violations"
  echo 'RuntimeConfig must change only through its version-gated, AdminWitness-authorized setters.' >&2
  failures=$((failures + 1))
fi

events_facts="$(move_facts sources/lib/events.move)"

runtime_config_mutation_event_payloads="$(awk -F'\t' '
  $1 == "TYPE" && $5 == 0 \
    && ($2 == "ProtocolFeeShareChanged" || $2 == "CreatorClaimSignerSet" || $2 == "TreasuryChanged") {
      print $8
    }
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
  || [[ "$(rg -o 'transfer::share_object' sources --glob '*.move' --glob '!launch.move' | wc -l)" != 4 ]]; then
  echo 'Core must keep exactly its four shared protocol singletons besides the launch terminal sink; the ACL is shared by blast_admin.' >&2
  failures=$((failures + 1))
fi

launch_config_facts="$(move_facts sources/launch_config.move)"
launch_config_source="$(move_normalized_source <<<"$launch_config_facts")"
launch_config_production="$(sed '/^\/\/ === Test-Only Functions ===/,$d' sources/launch_config.move)"

# Blast's allocation always exists, starts at zero, and may change only for future launches while
# leaving room for the curve and the pool.
if [[ ! -f sources/launch_config.move ]] \
  || [[ "$(move_production_function_contract set_protocol_allocation <<<"$launch_config_facts")" != 'public:0:0:fun set_protocol_allocation( self: &mut LaunchConfig, package_version: &PackageVersion, _: &AdminWitness<TreasuryAdmin>,'* ]] \
  || ! rg -Fq 'protocol_allocation: ProtocolAllocation,' sources/launch_config.move \
  || rg -Fq 'protocol_allocation: Option<' sources/launch_config.move \
  || ! rg -Fq 'meme_bps.value() <= 9_998 && quote_bps.value() <= 9_999' <<<"$launch_config_source" \
  || ! rg -Fq 'self.protocol_allocation != protocol_allocation' <<<"$launch_config_source" \
  || ! rg -Fq 'protocol_allocation: allocation::protocol_allocation(bps::new(0), bps::new(0))' <<<"$launch_config_source" \
  || [[ "$(count_occurrences 'self\.protocol_allocation = ' <<<"$launch_config_source")" != 1 ]] \
  || rg -n '\b(set_graduation_defaults|GraduationDefaultsChanged|protocol_(quote_migration|meme_graduation)_fee_bps|meme_liquidity_provision_bps|QuoteParameters|QuoteParametersChanged|min_graduation_target|max_graduation_target)\b' \
    sources/launch_config.move sources/lib/events.move \
  || rg -n '\b(AdminCap|ProtocolAuthority|sequence|schema_version|action_tag|nonce)\b' <<<"$launch_config_production"; then
  echo 'LaunchConfig must own only future-launch settings plus an AdminWitness-gated Blast allocation that always exists and defaults to zero.' >&2
  failures=$((failures + 1))
fi

# ADR 0098: the creation fee and the accepted partners change only through set_creation_fee,
# add_partner, and remove_partner, each version-gated first; creation reads them, nothing else does.
launch_config_fee_writers="$(awk -F'\t' '
  $1 == "FN" && $6 == 0 && $10 ~ /self\.creation_fee = / { print $2 }
' <<<"$launch_config_facts" | sort | tr '\n' ' ')"
launch_config_partner_writers="$(awk -F'\t' '
  $1 == "FN" && $6 == 0 && $10 ~ /self\.id\.(add_dynamic_field|dynamic_field_mut)/ { print $2 }
' <<<"$launch_config_facts" | sort | tr '\n' ' ')"
launch_config_ungated="$(awk -F'\t' '
  $1 == "FN" && $6 == 0 && ($2 == "set_creation_fee" || $2 == "add_partner" || $2 == "remove_partner") \
    && $10 !~ /^package_version\.assert_current\(\);/ { print $2 }
' <<<"$launch_config_facts")"

if [[ "$launch_config_fee_writers" != 'set_creation_fee ' ]] \
  || [[ "$launch_config_partner_writers" != 'add_partner remove_partner ' ]] \
  || [[ -n "$launch_config_ungated" ]] \
  || [[ "$(move_production_type PartnerKey <<<"$launch_config_facts")" != 'struct PartnerKey(ID) has copy, drop, store;' ]] \
  || [[ "$(rg -l '\.(creation_fee|assert_partner)\(' sources | sort | tr '\n' ' ')" \
    != 'sources/launch.move sources/launch_config.move ' ]]; then
  echo 'LaunchConfig must change its creation fee and accepted partners only through their version-gated setters, and only launch creation may read them.' >&2
  failures=$((failures + 1))
fi

constants_facts="$(move_facts sources/lib/constants.move)"

if [[ "$(move_production_body max_recipients <<<"$constants_facts")" != '16' ]] \
  || [[ "$(rg -c 'recipients\.length\(\) <= constants::max_recipients!\(\)' sources/allocation.move)" != 2 ]] \
  || [[ "$(move_production_body max_launch_fee_bps <<<"$constants_facts")" != '1_000' ]] \
  || ! rg -Fq 'quote_fee_bps.value() <= constants::max_launch_fee_bps!()' sources/launch_config.move \
  || ! rg -Fq 'meme_fee_bps.value() <= constants::max_launch_fee_bps!()' sources/launch_config.move \
  || rg -n 'protocol_trade_fee_share_bps' sources \
  || ! rg -Fq 'type_name::with_original_ids<Quote>()' sources/launch_config.move \
  || ! rg -Fq 'type_name::with_original_ids<MigrationWitness>()' sources/launch_config.move \
  || ! rg -Fq 'origin != @0x1 && origin != @0x2' sources/launch_config.move \
  || ! rg -Fq 'self.quotes.contains(type_name::with_original_ids<Quote>())' sources/launch_config.move \
  || ! rg -Fq 'quotes: table::new(ctx)' sources/launch_config.move \
  || ! rg -Fq 'assert!(virtual_quote > 0, blast_fun::errors::invalid_virtual_quote!());' sources/launch.move \
  || rg -n '\bvirtual_quote' sources/launch_config.move \
  || ! rg -Fq 'self.meme_decimals.contains(&decimals)' sources/launch_config.move \
  || rg -n '\b(VecMap|vec_map|max_quote_assets|quote_capacity_reached|Currency<Quote>|coin_registry)\b' \
    sources/launch_config.move sources/lib/errors.move; then
  echo 'Launch policy must keep original-type quote/witness admission, the decimal allowlist, a constant trade-fee ceiling with a configurable protocol share, and one named recipient limit.' >&2
  failures=$((failures + 1))
fi
if ! rg -U -q \
    'fun init\(ctx: &mut TxContext\) \{\s*transfer::share_object\(new\(ctx\)\);\s*\}' \
    sources/launch_config.move \
  || rg -q '\bLaunchConfigCreated\b' sources/lib/events.move sources/launch_config.move; then
  echo 'Launch-config initialization must share the one cold-policy singleton and emit no creation event.' >&2
  failures=$((failures + 1))
fi

protocol_allocation_event_payload="$(sed -n -e '/^public struct ProtocolAllocationSet/,/^}/p' sources/lib/events.move)"

if [[ -z "$protocol_allocation_event_payload" ]] \
  || ! rg -q '^[[:space:]]+meme_bps: u64,' <<<"$protocol_allocation_event_payload" \
  || ! rg -q '^[[:space:]]+quote_bps: u64,' <<<"$protocol_allocation_event_payload" \
  || rg -n '\b(destination|config_id|sequence|schema_version|action_tag|nonce)\b' <<<"$protocol_allocation_event_payload"; then
  echo 'The Blast migration-fee allocation policy must emit its complete primitive replay fact without singleton or ordering noise.' >&2
  failures=$((failures + 1))
fi

launch_ticket_facts="$(move_facts sources/launch_ticket.move)"
launch_ticket_source="$(move_normalized_source <<<"$launch_ticket_facts")"

# The generated package's one-time witness names the currency and the Coin Registry proves it
# is unique, so the constructor needs no package identity, launch policy, or registry borrow.
# The ticket is pure coin custody: it records no adapter or Quote. The treasury capability
# stays in the ticket, lent only through the launch initializer to the adapter that started
# the launch, until finalization re-checks the minted supply and sell burn and fixes the supply mode.
launch_ticket_new_body="$(move_production_body new <<<"$launch_ticket_facts" | move_semantic_shape)"
launch_ticket_destroy_body="$(move_production_body destroy <<<"$launch_ticket_facts" | move_semantic_shape)"

if [[ ! -f sources/launch_ticket.move ]] \
  || [[ "$(move_production_functions <<<"$launch_ticket_facts")" \
    != 'atomic_supply:package:0 decimals:package:0 destroy:package:0 id:package:0 new:public:0 treasury_cap_mut:package:0 ' ]] \
  || [[ "$(move_production_type LaunchTicket <<<"$launch_ticket_facts")" \
    != 'struct LaunchTicket<phantom Meme> has key, store { id: UID, meme: Balance<Meme>, treasury_cap: TreasuryCap<Meme>, metadata_cap: MetadataCap<Meme>, creator: CreatorRecipient, decimals: u8, burnable: bool, sell_burn_bps: Bps, }' ]] \
  || [[ "$(move_production_function_contract new <<<"$launch_ticket_facts")" != 'public:0:0:fun new<Meme: drop>( otw: Meme, decimals: u8,'* ]] \
  || [[ "$(count_occurrences 'coin_registry::new_currency_with_otw\(' <<<"$launch_ticket_source")" != 1 ]] \
  || ! in_order \
    'constants::max_sell_burn_bps!()' \
    'coin_registry::new_currency_with_otw(' \
    'LaunchTicket{' \
    'treasury_cap.mint_balance(atomic_supply(decimals))' \
    'initializer.finalize(ctx)' \
    <<<"$launch_ticket_new_body" \
  || [[ "$(move_production_function_contract treasury_cap_mut <<<"$launch_ticket_facts")" \
    != 'package:0:0:fun treasury_cap_mut<Meme>(self: &mut LaunchTicket<Meme>): &mut TreasuryCap<Meme>' ]] \
  || [[ "$(move_production_body treasury_cap_mut <<<"$launch_ticket_facts")" != '&mut self.treasury_cap' ]] \
  || [[ "$(rg -l '\btreasury_cap_mut\b' sources | sort | tr '\n' ' ')" \
    != 'sources/launch.move sources/launch_ticket.move ' ]] \
  || [[ "$(move_production_function_contract destroy <<<"$launch_ticket_facts")" \
    != 'package:0:0:fun destroy<Meme>( self: LaunchTicket<Meme>, currency: &mut Currency<Meme>, atomic_supply: u64, ): (Balance<Meme>, MetadataCap<Meme>, CreatorRecipient, Bps)' ]] \
  || ! in_order \
    'meme.value()== atomic_supply && treasury_cap.total_supply()== atomic_supply' \
    'invalid_initial_meme_supply!()' \
    'sell_burn_bps.value()<= constants::max_sell_burn_bps!()' \
    'currency.make_supply_burn_only(treasury_cap)' \
    'currency.make_supply_fixed(treasury_cap)' \
    <<<"$launch_ticket_destroy_body" \
  || [[ "$(count_occurrences 'make_supply_' <<<"$launch_ticket_source")" != 2 ]] \
  || [[ "$(count_occurrences '&mut self\.treasury_cap' <<<"$launch_ticket_source")" != 1 ]] \
  || rg -q '\b(UpgradeCap|CoinRegistry|PackageVersion|LaunchConfig|TypeName|make_regulated|DenyCap|CoinMetadata)\b' <<<"$launch_ticket_source" \
  || rg -q '\btransfer::|\bentry fun\b' <<<"$launch_ticket_source"; then
  echo 'launch_ticket.move must create the currency from the generated package one-time witness, mint the canonical supply once, record no adapter or Quote, lend the treasury capability only to the launch initializer, fix the supply mode only at finalization after re-checking the minted supply and sell burn, and custody the metadata cap and creator recipient without package, policy, or registry inputs.' >&2
  failures=$((failures + 1))
fi
if [[ "$(rg -o '\.mint_balance\(' sources | wc -l)" != 1 ]] \
  || rg -n '\bcoin::mint(_balance)?\(' sources \
  || rg -n '\.mint_balance\(' sources --glob '!launch_ticket.move'; then
  echo 'The launch-ticket constructor must remain the only Meme mint site in the package.' >&2
  failures=$((failures + 1))
fi

if [[ "$(move_production_body meme_total_supply_whole_tokens <<<"$constants_facts")" != '1_000_000_000' ]] \
  || ! rg -Fq 'constants::meme_total_supply_whole_tokens!() *' sources/launch_ticket.move; then
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

allocation_facts="$(move_facts sources/allocation.move)"
allocation_source="$(move_normalized_source <<<"$allocation_facts")"
launch_facts="$(move_facts sources/launch.move)"
launch_source="$(move_normalized_source <<<"$launch_facts")"

# The allocation module is pure validation and exact largest-remainder arithmetic: Blast has an
# explicit route, each asset sums to 10,000, and leftover units go to the largest remainders.
if [[ ! -f sources/allocation.move ]] \
  || [[ "$(move_production_type Recipient <<<"$allocation_facts")" != 'struct Recipient has copy, drop, store { destination: address, meme_bps: Bps, quote_bps: Bps, }' ]] \
  || [[ "$(move_production_type ProtocolAllocation <<<"$allocation_facts")" != 'struct ProtocolAllocation has copy, drop, store { meme_bps: Bps, quote_bps: Bps, }' ]] \
  || [[ "$(move_production_type AllocationPlan <<<"$allocation_facts")" != 'struct AllocationPlan has copy, drop, store { curve_meme_bps: Bps, lp_meme_bps: Bps, lp_quote_bps: Bps, protocol_meme_bps: Bps, protocol_quote_bps: Bps, recipients: vector<Recipient>, }' ]] \
  || [[ "$(move_production_body plan <<<"$allocation_facts")" != 'assert!(curve_meme_bps.value() > 0 && lp_meme_bps.value() > 0, blast_fun::errors::invalid_shares!()); AllocationPlan { curve_meme_bps, lp_meme_bps, lp_quote_bps, protocol_meme_bps: bps::new(0), protocol_quote_bps: bps::new(0), recipients, }' ]] \
  || ! rg -Fq 'self.protocol_meme_bps = protocol.meme_bps; self.protocol_quote_bps = protocol.quote_bps;' <<<"$allocation_source" \
  || ! rg -Fq 'let amounts = apportion(bps, supply, option::some(2));' <<<"$allocation_source" \
  || ! rg -Fq 'let amounts = apportion(bps, reserve, option::some(1));' <<<"$allocation_source" \
  || [[ "$(count_occurrences '\) == constants::basis_points_denominator!\(\)' <<<"$allocation_source")" != 3 ]] \
  || ! rg -Fq 'remainder_a > remainder_b || (remainder_a == remainder_b && *a <= *b)' <<<"$allocation_source" \
  || ! rg -Fq 'let leftover = total - amounts.fold!(0, |sum, amount| sum + amount);' <<<"$allocation_source" \
  || rg -q '\b(UID|Balance|Coin|TxContext|transfer::|object::)\b' <<<"$allocation_source"; then
  echo 'allocation.move must validate bounded plans with an explicit Blast route and apportion exactly, without custody, cap, or transfer effects.' >&2
  failures=$((failures + 1))
fi

# Sorted names of production launch functions whose body contains one fixed string.
launch_functions_containing() {
  awk -F'\t' -v needle="$1" '
    $1 == "FN" && $6 == 0 && index($10, needle) > 0 { print $2 }
  ' <<<"$launch_facts" | sort | tr '\n' ' '
}

# A migration adapter starts a launch under its own witness and pool tier: `new` validates the
# pair and this generation's admissions into an ability-less initializer reachable only through
# its setters, the starting adapter's treasury loan, and `finalize`, which checks every setting
# before custody moves and keeps the native MetadataCap inline forever.
launch_new_body="$(move_production_body new <<<"$launch_facts")"
launch_finalize_body="$(move_production_body finalize <<<"$launch_facts")"
launch_initializer_functions="$(awk -F'\t' '
  $1 == "FN" && $6 == 0 && $9 ~ /LaunchInitializer</ { print $2 ":" $3 }
' <<<"$launch_facts" | sort | tr '\n' ' ')"

if [[ ! -f sources/launch.move ]] \
  || [[ "$(move_production_type LaunchInitializer <<<"$launch_facts")" != 'struct LaunchInitializer<phantom Meme, phantom Quote> {'* ]] \
  || [[ "$launch_initializer_functions" != 'finalize:public new:public set_allocation_plan:public set_graduation_target:public set_lp_fee_split:public set_opening_round:public set_partner:public set_virtual_quote:public treasury_cap_mut:public ' ]] \
  || [[ "$(move_production_function_contract new <<<"$launch_facts")" != 'public:0:0:fun new<Meme, Quote, Witness: drop>( ticket: LaunchTicket<Meme>, package_version: &PackageVersion, config: &LaunchConfig, _: Witness, pool_tick_spacing: u32, pool_fee_rate: u64, ): LaunchInitializer<Meme, Quote>' ]] \
  || ! in_order \
    'package_version.assert_current();' \
    'type_name::with_original_ids<Meme>() != type_name::with_original_ids<Quote>()' \
    'let migration_witness = type_name::with_original_ids<Witness>();' \
    '.snapshot_for_launch<Quote>( migration_witness, ticket.decimals(), );' \
    'LaunchInitializer {' \
    <<<"$launch_new_body" \
  || [[ "$(move_production_function_contract treasury_cap_mut <<<"$launch_facts")" != 'public:0:0:fun treasury_cap_mut<Meme, Quote, Witness: drop>( self: &mut LaunchInitializer<Meme, Quote>, _: Witness, ): &mut TreasuryCap<Meme>' ]] \
  || [[ "$(move_production_body treasury_cap_mut <<<"$launch_facts")" != 'assert!( self.migration_witness == type_name::with_original_ids<Witness>(), blast_fun::errors::invalid_migration_witness!(), ); self.ticket.treasury_cap_mut()' ]] \
  || [[ "$(move_production_function_contract finalize <<<"$launch_facts")" != 'public:0:0:fun finalize<Meme, Quote>( self: LaunchInitializer<Meme, Quote>, currency: &mut Currency<Meme>, config: &LaunchConfig, creation_fee: Coin<SUI>, ctx: &mut TxContext, ): Launch<Meme, Quote>' ]] \
  || [[ "$(move_production_function_contract set_partner <<<"$launch_facts")" != 'public:0:0:fun set_partner<Meme, Quote>( self: &mut LaunchInitializer<Meme, Quote>, config: &LaunchConfig, partner: &Partner, clock: &Clock, )' ]] \
  || ! in_order 'config.assert_partner(' 'self.partner_id = option::some(partner_id);' \
    <<<"$(move_production_body set_partner <<<"$launch_facts")" \
  || [[ "$launch_finalize_body" == *'assert_current'* ]] \
  || [[ "$launch_finalize_body" == *'.is_some()'* ]] \
  || ! in_order \
    'invalid_creation_fee!()' \
    'let graduation_target = graduation_target.destroy_some();' \
    'allocation_plan.destroy_some().add_protocol(config.protocol_allocation());' \
    'invalid_opening_round!()' \
    'meme_symbol_too_long!()' \
    'invalid_graduation_target!()' \
    'let atomic_supply = launch_ticket::atomic_supply(ticket.decimals());' \
    'allocation_plan.apportion_meme(atomic_supply)' \
    'ticket.destroy(currency, atomic_supply);' \
    'Launch {' \
    'lp_fee_split: lp_fee_split.destroy_some(),' \
    <<<"$launch_finalize_body" \
  || [[ "$launch_finalize_body" != *'metadata_cap, creator: option::some(creator), curve_fee_cap_id: option::none(), blast_metadata_cap_id: option::none(), partner_id, };'* ]] \
  || [[ "$launch_finalize_body" != *'fee_ledger: fees::new(creation_fee),'* ]] \
  || [[ "$(count_occurrences 'self\.metadata_cap\b' <<<"$launch_source")" \
    != "$(count_occurrences '&self\.metadata_cap\b' <<<"$launch_source")" ]] \
  || rg -q '\bmetadata_cap\.(extract|swap|fill)\(|option::(some|none)\(metadata_cap\)|\bMetadataCap<Meme>\)' \
    <<<"$launch_source" \
  || rg -q 'bps::new\(' <<<"$launch_source" \
  || ! rg -Fq 'let burnable = currency.is_supply_burn_only();' sources/launch.move \
  || rg -q '\b(MigrationChannelCap|LaunchMigrationCap|MigrationChannelBalance|VenueSelection|venue_selection)\b' <<<"$launch_source" \
  || rg -n 'max_launch_fee_bps|invalid_trade_fee_bps' sources/launch.move; then
  echo 'Launch start must be version-gated and validate the pair and admissions; the ability-less initializer must be reachable only through its setters, the adapter loan, and finalize, which checks every setting before custody, keeps the native MetadataCap inline, and carries no venue selection.' >&2
  failures=$((failures + 1))
fi

# The pool tier and LP-fee split are the creator's post-migration settings: set once on the
# initializer, stored unchanged by the launch, and only read back by the migration adapter.
if [[ "$(launch_functions_containing 'self.lp_fee_split = ')" != 'set_lp_fee_split ' ]] \
  || [[ "$(move_production_function_contract set_lp_fee_split <<<"$launch_facts")" != 'public:0:0:fun set_lp_fee_split<Meme, Quote>( self: &mut LaunchInitializer<Meme, Quote>, lp_fee_split: FeeSplit, )' ]] \
  || [[ "$(count_occurrences '\.lp_fee_split = ' <<<"$launch_source")" != 1 ]] \
  || [[ "$(count_occurrences 'self\.pool_(tick_spacing|fee_rate) = ' <<<"$launch_source")" != 0 ]] \
  || [[ "$(move_production_function_contract pool_tier <<<"$launch_facts")" != 'public:0:0:fun pool_tier<Meme, Quote>(self: &Launch<Meme, Quote>): (u32, u64)' ]] \
  || [[ "$(move_production_body pool_tier <<<"$launch_facts")" != '(self.pool_tick_spacing, self.pool_fee_rate)' ]] \
  || [[ "$(move_production_function_contract lp_fee_split <<<"$launch_facts")" != 'public:0:0:fun lp_fee_split<Meme, Quote>(self: &Launch<Meme, Quote>): FeeSplit' ]] \
  || [[ "$(move_production_body lp_fee_split <<<"$launch_facts")" != 'self.lp_fee_split' ]]; then
  echo 'The pool tier and LP-fee split must be set only on the initializer and stored unchanged, with read-only getters for the adapter.' >&2
  failures=$((failures + 1))
fi

launch_authority_violations=''

# Each authority effect has one exact writer and reader set, so a new sibling or helper cannot
# record authority, claim from either ledger owner, retire the pending claim, reach the native
# MetadataCap, or transfer value outside the approved paths (ADR 0082).
for authority_spec in \
  'self.curve_fee_cap_id = |claim_creator_caps reassign_curve_fee_cap ' \
  'self.blast_metadata_cap_id = |claim_creator_caps reassign_metadata_cap ' \
  'self.creator.extract()|claim_creator_caps ' \
  'self.creator = |reassign_curve_fee_cap reassign_metadata_cap ' \
  'self.fee_ledger.claim_creator_fees(|claim_creator_fees ' \
  'self.fee_ledger.claim_protocol_fees(|claim_protocol_fees claim_protocol_fees_with_partner ' \
  'partner.pay(|claim_protocol_fees_with_partner ' \
  'runtime_config.treasury()|claim_protocol_fees claim_protocol_fees_with_partner ' \
  'pay_treasury(|claim_protocol_fees claim_protocol_fees_with_partner ' \
  'self.partner_id = |set_partner ' \
  'self.assert_curve_fee_cap(|claim_creator_fees ' \
  'self.assert_metadata_update(|set_description set_icon_url set_name ' \
  '&self.metadata_cap|set_description set_icon_url set_name ' \
  'transfer::public_transfer(|migrate pay pay_treasury reassign_curve_fee_cap reassign_metadata_cap ' \
  '.opening_round_meme.pay(|deliver_opening_round ' \
  '.opening_round_quote.pay(|deliver_opening_round ' \
  '.allocated_meme.pay(|migrate ' \
  '.real_quote_reserve.pay(|migrate '; do
  authority_needle="${authority_spec%%|*}"
  authority_expected="${authority_spec#*|}"
  authority_actual="$(launch_functions_containing "$authority_needle")"

  if [[ "$authority_actual" != "$authority_expected" ]]; then
    launch_authority_violations+="  '${authority_needle}' is used by '${authority_actual}' instead of '${authority_expected}'"$'\n'
  fi
done
# The package-only cap constructors are reached only from the owning module and the launch that
# records the resulting authority; only the launch claims from the ledger.
if [[ "$(rg -l '\bnew_curve_fee_cap\b' sources | sort | tr '\n' ' ')" \
    != 'sources/creator_authority.move sources/launch.move ' ]] \
  || [[ "$(rg -l '\bnew_metadata_cap\b' sources | sort | tr '\n' ' ')" \
    != 'sources/creator_authority.move sources/launch.move ' ]] \
  || [[ "$(rg -l '\.claim_(creator|protocol)_fees\((ctx)?\)' sources | tr '\n' ' ')" != 'sources/launch.move ' ]]; then
  launch_authority_violations+='  creator capability constructors or ledger claims are reachable outside creator_authority.move and launch.move'$'\n'
fi

# Blast's fee claims are permissionless, so no caller input may choose the payee: each pays the
# partner the launch names and the RuntimeConfig treasury, through one helper that sends only
# positive balances, three payouts before the claim event (ADR 0105).
if [[ "$(move_production_signature claim_protocol_fees <<<"$launch_facts")" \
    != 'fun claim_protocol_fees<Meme, Quote>( self: &mut Launch<Meme, Quote>, package_version: &PackageVersion, runtime_config: &RuntimeConfig, ctx: &mut TxContext, )' ]] \
  || [[ "$(move_production_signature claim_protocol_fees_with_partner <<<"$launch_facts")" \
    != 'fun claim_protocol_fees_with_partner<Meme, Quote>( self: &mut Launch<Meme, Quote>, package_version: &PackageVersion, runtime_config: &RuntimeConfig, partner: &Partner, clock: &Clock, ctx: &mut TxContext, )' ]] \
  || [[ "$(move_production_function_contract pay <<<"$launch_facts")" \
    != 'private:0:0:fun pay<Asset>(self: &mut Balance<Asset>, amount: u64, recipient: address, ctx: &mut TxContext)' ]] \
  || [[ "$(move_production_body pay <<<"$launch_facts")" \
    != 'if (amount > 0) transfer::public_transfer(self.split(amount).into_coin(ctx), recipient);' ]] \
  || [[ "$(move_production_function_contract pay_treasury <<<"$launch_facts")" \
    != 'private:0:0:fun pay_treasury<T>(fee: Balance<T>, treasury: address, ctx: &mut TxContext)' ]] \
  || [[ "$(move_production_body pay_treasury <<<"$launch_facts")" \
    != 'if (fee.value() == 0) return fee.destroy_zero(); transfer::public_transfer(fee.into_coin(ctx), treasury);' ]]; then
  launch_authority_violations+='  a protocol fee claim takes a caller-chosen payee or authority, or the treasury payout changed'$'\n'
fi

# Each claim body is pinned whole, so the payee of every payout is the RuntimeConfig treasury the
# claim reads and records, never the sender or a constant, with all three payouts before the event.
if [[ "$(move_production_body claim_protocol_fees <<<"$launch_facts" | move_semantic_shape)" \
    != 'package_version.assert_current();assert!(self.partner_id.is_none(),blast_fun::errors::partner_mismatch!());let blast_treasury = runtime_config.treasury();let(meme_fees,quote_fees,sui_fees)= self.fee_ledger.claim_protocol_fees();let(treasury_meme,treasury_quote,treasury_sui)=(meme_fees.value(),quote_fees.value(),sui_fees.value());pay_treasury(meme_fees,blast_treasury,ctx);pay_treasury(quote_fees,blast_treasury,ctx);pay_treasury(sui_fees,blast_treasury,ctx);events::protocol_fees_claimed(self.id.to_inner(),blast_treasury,treasury_meme,treasury_quote,treasury_sui,0,0,0);' ]] \
  || [[ "$(move_production_body claim_protocol_fees_with_partner <<<"$launch_facts" | move_semantic_shape)" \
    != 'package_version.assert_current();assert!(self.partner_id.contains(&object::id(partner)),blast_fun::errors::partner_mismatch!());let blast_treasury = runtime_config.treasury();let(mut meme_fees,mut quote_fees,mut sui_fees)= self.fee_ledger.claim_protocol_fees();let partner_meme = partner.pay(&mut meme_fees,clock,ctx);let partner_quote = partner.pay(&mut quote_fees,clock,ctx);let partner_sui = partner.pay(&mut sui_fees,clock,ctx);let(treasury_meme,treasury_quote,treasury_sui)=(meme_fees.value(),quote_fees.value(),sui_fees.value());pay_treasury(meme_fees,blast_treasury,ctx);pay_treasury(quote_fees,blast_treasury,ctx);pay_treasury(sui_fees,blast_treasury,ctx);events::protocol_fees_claimed(self.id.to_inner(),blast_treasury,treasury_meme,treasury_quote,treasury_sui,partner_meme,partner_quote,partner_sui);' ]]; then
  launch_authority_violations+='  a protocol fee claim must pay each balance to the RuntimeConfig treasury it records, after the partner and before the claim event'$'\n'
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
  'clock.timestamp_ms()|has_opening_round_ended set_partner share ' \
  'curve::cap_buy_quote_input(|buy_from_curve ' \
  'curve::quote_buy(|buy_from_curve ' \
  'transfer::share_object(self)|share ' \
  'events::launch_shared(|share ' \
  'events::bought(|buy_from_curve '
if ! in_order \
  'package_version.assert_current();' \
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
  [[ "$move_file" == sources/launch.move || "$move_file" == sources/launch_config.move ]] && continue

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
  echo 'Launch creator authority must stay split per concern: only the recorded CurveFeeCap claims creator fees, only the recorded BlastMetadataCap edits metadata through the retained MetadataCap, and only a version-gated creator admin reassigns.' >&2
  failures=$((failures + 1))
fi

if [[ "$(launch_functions_containing 'events::migration_allocation_paid(')" != 'migrate ' ]] \
  || [[ "$(launch_functions_containing 'events::migrated(')" != 'migrate ' ]]; then
  echo 'Allocation payouts and the migration must be replayed only by migrate.' >&2
  failures=$((failures + 1))
fi
if rg -n '\bstate_version\b|launch_state_version' sources tests; then
  echo 'PackageVersion must remain the only operational version; Launch state and events must not add another one.' >&2
  failures=$((failures + 1))
fi

# Every production function that takes the shared PackageVersion checks it as its first
# statement, directly or by first calling a receiver helper that does, and no public function
# reaching mutable shared state escapes that guard. The one exception consumes the no-ability
# LaunchInitializer, which cannot leave the transaction whose `new` checked the version.
version_guard_violations="$(
  for move_file in "${source_files[@]}"; do
    move_facts "$move_file" | awk -F'\t' -v file="$move_file" '
      $1 == "FN" && $6 == 0 && $9 ~ /[(,] package_version: &PackageVersion,/ {
        if ($10 ~ /^package_version\.assert_current\(\);/) gated[$2] = 1
        else pending[$2] = $10
      }
      $1 == "FN" && $6 == 0 && $3 == "public" \
        && ($9 ~ /: &mut (Launch|Currency)</ || $9 ~ /: &mut (LaunchConfig|RuntimeConfig|PackageAdmin),/) \
        && $9 !~ /[(,] package_version: &(mut )?PackageVersion,/ \
        && $9 !~ /\( ?self: LaunchInitializer</ {
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
        '\b(blast_acl::(grant_admin|revoke_admin|destroy_admin_cap|begin_super_admin_transfer|cancel_super_admin_transfer|accept_super_admin_transfer|destroy_retired_super_admin_cap|sign_in)|runtime_config::(set_creator_claim_signer|set_protocol_fee_share|set_treasury|creator_claim_signer|protocol_fee_share|treasury)|launch_config::(set_meme_decimals_allowed|set_quote_allowed|set_trade_fees|set_protocol_allocation|set_migration_witness_allowed|snapshot_for_launch|protocol_allocation|allowed_meme_decimals_count_for_testing|allowed_quote_count_for_testing|allowed_migration_witness_count_for_testing)|allocation::(recipients|apportion_fee_split|add_protocol|apportion_meme|apportion_quote|destinations|destination)|launch::(treasury_cap_mut|set_virtual_quote|set_graduation_target|set_allocation_plan|set_lp_fee_split|set_protection|finalize|share|pool_tier|lp_fee_split|partner_id|claim_creator_caps|reassign_curve_fee_cap|reassign_metadata_cap|assert_curve_fee_cap|set_name|set_description|set_icon_url)|launch_ticket::(destroy|treasury_cap_mut|decimals)|fees::(accrue|claim_creator_fees|claim_protocol_fees)|package::test_upgrade|package_admin::(authorize_upgrade|commit_upgrade|publisher_id_for_testing|upgrade_cap_id_for_testing|package_id_for_testing|version_for_testing|policy_for_testing))(<[^>]+>)?\(' \
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

creator_authority_facts="$(move_facts sources/creator_authority.move)"

# Each creator capability is an identity-only object whose one production constructor lives in
# this module (ADR 0082). LP-fee capability authority left for `blast_fun_migrators` (ADR 0083).
creator_capability_violations=''
for capability_spec in 'CurveFeeCap|new_curve_fee_cap' 'BlastMetadataCap|new_metadata_cap'; do
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
  echo 'creator_authority.move must own CurveFeeCap<Meme> and BlastMetadataCap<Meme> construction.' >&2
  failures=$((failures + 1))
fi

if ! rg -U -q \
  'public enum CreatorRecipient has copy, drop, store \{\s*Address\(address\),\s*Account\(vector<u8>\),\s*\}' \
  sources/creator_authority.move \
  || ! rg -q 'public fun new_address\(recipient: address\): CreatorRecipient' sources/creator_authority.move \
  || ! rg -q 'public fun new_account\(account_commitment: vector<u8>\): CreatorRecipient' \
    sources/creator_authority.move; then
  echo 'Public creator constructors must return plain CreatorRecipient values.' >&2
  failures=$((failures + 1))
fi

creator_authority_production="$(sed '/^\/\/ === Test-Only Functions ===/,$d' sources/creator_authority.move)"
creator_authority_source="$(move_normalized_source <<<"$creator_authority_facts")"

# Creator authority is neither version- nor admin-gated: claims are signer-authorized and
# reassignment is gated in launch.
if rg -n '\b[a-z_]*claimed:[[:space:]]*bool|\bissue_creator_cap\b|\btransfer::' \
  <<<"$creator_authority_production" \
  || rg -q '\bMetadataCap\b|\bcoin_registry\b' <<<"$creator_authority_source" \
  || rg -q '\b(AdminWitness|blast_fun_domain|PackageVersion|package_version)\b' \
    <<<"$creator_authority_source" \
  || rg -v -Fx 'use blast_fun::constants;' sources/creator_authority.move | rg -q '^use blast_fun::' \
  || [[ "$(move_production_function_contract claim_creator_caps <<<"$creator_authority_facts")" != 'package:0:0:fun claim_creator_caps<Meme>( recipient: CreatorRecipient, signer_public_key: &vector<u8>, attestation: Option<vector<u8>>, clock: &Clock, ctx: &mut TxContext, ): (CurveFeeCap<Meme>, BlastMetadataCap<Meme>)' ]] \
  || [[ "$(move_production_function_contract new_curve_fee_cap <<<"$creator_authority_facts")" \
    != 'package:0:0:fun new_curve_fee_cap<Meme>(ctx: &mut TxContext): CurveFeeCap<Meme>' ]] \
  || [[ "$(move_production_function_contract new_metadata_cap <<<"$creator_authority_facts")" \
    != 'package:0:0:fun new_metadata_cap<Meme>(ctx: &mut TxContext): BlastMetadataCap<Meme>' ]] \
  || [[ "$(move_production_type CreatorClaimMessage <<<"$creator_authority_facts")" \
    != 'struct CreatorClaimMessage has drop { meme: TypeName, account_commitment: vector<u8>, claimant: address, expiry_ms: u64, }' ]] \
  || rg -q '\bed25519_signature_length\b' sources; then
  echo 'Creator claims must return exactly one CurveFeeCap and one BlastMetadataCap, and creator_authority.move must import no Blast module but constants and carry no version or admin gate, native MetadataCap pass-through, flag, or transfer.' >&2
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

# The launchpad holds only the launch-time LP-fee settings and hands them over at migration.
# Recurring LP-fee policy, collection, and split updates live in the migrators package, so no
# router, policy, or LP-fee event may return here, and neither may the retired per-asset route
# tables or the curve-fee custodian lock. `allocation` keeps the canonical FeeSplit value, its
# one public constructor, and the one public apportionment the migrators pay through.
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
  || [[ "$(move_production_type FeeSplit <<<"$allocation_facts")" != 'struct FeeSplit has copy, drop, store { creator_bps: Bps, auto_lp_bps: Bps, rewards_bps: Bps, burn_bps: Bps, recipients: vector<Route>, }' ]] \
  || [[ "$(move_production_type Route <<<"$allocation_facts")" != 'struct Route has copy, drop, store { destination: address, bps: Bps, }' ]] \
  || [[ "$(move_production_function_contract fee_split <<<"$allocation_facts")" \
    != 'public:0:0:fun fee_split( creator_bps: Bps, auto_lp_bps: Bps, rewards_bps: Bps, burn_bps: Bps, recipients: vector<Route>, ): FeeSplit' ]] \
  || [[ "$(move_production_function_contract apportion_fee_split <<<"$allocation_facts")" \
    != 'public:0:0:fun apportion_fee_split(self: &FeeSplit, total: u64): (u64, u64, u64, u64, vector<u64>)' ]] \
  || [[ "$(count_occurrences 'FeeSplit \{ creator_bps, auto_lp_bps, rewards_bps, burn_bps, recipients \}' <<<"$allocation_source")" != 1 ]] \
  || [[ "$(rg -l 'fun (fee_split|apportion_fee_split)\b' sources --glob '*.move' | sort | tr '\n' ' ')" != 'sources/allocation.move ' ]]; then
  echo 'Launchpad must keep only the launch-time LP-fee split, its public constructor, value, and apportionment, and no custodian lock; recurring LP-fee routing, policy, and their events belong to the migrators package.' >&2
  failures=$((failures + 1))
fi

# T-010: one call under the stored adapter witness pays every project recipient, accrues Blast's
# one-time migration fee, hands off exactly the pool share, disposes of the curve's unsold Meme,
# and commits Migrated. Only order anchors are pinned.
if [[ "$(launch_functions_containing 'self.migration_witness == type_name::with_original_ids<Witness>()')" != 'migrate treasury_cap_mut ' ]] \
  || [[ "$(launch_functions_containing 'self.lifecycle = Lifecycle::Migrated;')" != 'migrate ' ]] \
  || [[ "$(move_production_type Migrated <<<"$events_facts")" != 'struct Migrated has copy, drop { launch_id: ID, meme: u64, quote: u64, disposed_meme: u64, total_supply_after: u64, }' ]] \
  || [[ "$(move_production_signature migrate <<<"$launch_facts")" != 'fun migrate<Meme, Quote, Witness: drop>( self: &mut Launch<Meme, Quote>, package_version: &PackageVersion, currency: &mut Currency<Meme>, _: Witness, ctx: &mut TxContext, ): (Balance<Meme>, Balance<Quote>)' ]] \
  || ! in_order \
    'package_version.assert_current();' \
    'Lifecycle::MigrationReady' \
    'self.migration_witness == type_name::with_original_ids<Witness>()' \
    'events::migration_allocation_paid(' \
    'self.fee_ledger.accrue_protocol_fees(' \
    'self.allocated_meme.split(protocol_meme_amount)' \
    'self.real_quote_reserve.split(protocol_quote_amount)' \
    'events::protocol_fees_accrued(' \
    'self.allocated_meme.withdraw_all()' \
    'self.real_quote_reserve.withdraw_all()' \
    'self.pending_burn.withdraw_all()' \
    'self.meme_reserve.withdraw_all()' \
    'self.lifecycle = Lifecycle::Migrated;' \
    'events::migrated(' \
    <<<"$(move_production_body migrate <<<"$launch_facts" | move_semantic_shape)"; then
  echo 'T-010 must check the stored adapter witness, pay every project recipient, accrue Blast migration fees, hand off exactly the pool share, and dispose of the unsold Meme before committing Migrated.' >&2
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

if ! events_follow_mutations sources/launch_ticket.move new 'LaunchTicket{' 'events::launch_ticket_created<' \
  || ! events_follow_mutations sources/launch.move finalize \
    'ticket.destroy(' 'Launch{' 'events::launch_created<' \
  || ! events_follow_mutations sources/launch.move claim_protocol_fees \
    'self.fee_ledger.claim_protocol_fees(' 'events::protocol_fees_claimed(' \
  || ! events_follow_mutations sources/launch.move claim_protocol_fees_with_partner \
    'self.fee_ledger.claim_protocol_fees(' 'events::protocol_fees_claimed(' \
  || ! events_follow_mutations sources/runtime_config.move set_treasury \
    'self.treasury = treasury;' 'events::treasury_changed(' \
  || ! events_follow_mutations sources/launch_config.move set_creation_fee \
    'self.creation_fee = ' 'events::creation_fee_changed(' \
  || ! events_follow_mutations sources/launch_config.move add_partner \
    '.add_dynamic_field(' 'events::partner_added(' \
  || ! events_follow_mutations sources/launch_config.move remove_partner \
    '*current = ' 'events::partner_removed(' \
  || ! events_follow_mutations sources/launch.move buy_from_curve \
    'self.real_quote_reserve.join(' \
    'self.meme_reserve.split(' \
    'self.lifecycle = Lifecycle::MigrationReady;' \
    'self.fee_ledger.accrue(' \
    'events::bought(' \
  || ! events_follow_mutations sources/launch.move share \
    'self.public_start_ms = option::some(' 'events::launch_shared(' 'transfer::share_object(' \
  || ! events_follow_mutations sources/launch.move join_opening_round \
    'self.opening_round_quote.join(' 'events::opening_round_joined(' \
  || ! events_follow_mutations sources/launch.move settle_opening_round \
    'self.lifecycle = Lifecycle::Live;' 'self.opening_round_quote.join(' 'events::opening_round_settled(' \
  || ! events_follow_mutations sources/launch.move deliver_opening_round \
    '.remove_dynamic_field' 'self.opening_round_bids = ' 'self.opening_round_quote.pay(' \
    'events::opening_round_delivered(' \
  || ! events_follow_mutations sources/launch.move migrate \
    'self.allocated_meme.pay(meme,destination,ctx);' \
    'self.real_quote_reserve.pay(quote,destination,ctx);' \
    'events::migration_allocation_paid(' \
    'self.fee_ledger.accrue_protocol_fees(' \
    'events::protocol_fees_accrued(' \
    'currency.burn_balance(' \
    'events::migrated(' \
  || ! events_follow_mutations sources/launch_config.move set_protocol_allocation \
    'self.protocol_allocation = protocol_allocation;' 'events::protocol_allocation_set('; then
  echo 'Every replay-schema success event must follow the state write or native transfer it records.' >&2
  failures=$((failures + 1))
fi

if ((failures != 0)); then
  exit 1
fi

echo 'Source module boundaries and Move style: OK'
