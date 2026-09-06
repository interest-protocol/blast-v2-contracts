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
mapfile -t source_files < <(find sources -type f -name '*.move' -print | sort)

# Deterministic Move reader used by every body-bound check below. It removes
# comments and string contents before parsing, so a token inside a comment, a
# doc comment, or a literal can never satisfy a requirement, and it reports each
# declaration with brace-matched boundaries, so indentation and line breaks
# cannot hide or split one. Records are tab separated:
#   FN    name vis entry macro test_only after_marker line signature body
#   TYPE  name kind vis test_only after_marker line declaration
#   MARKER  first '// === Test-Only ... ===' line, or 0
#   NORM    whole comment-free source with whitespace collapsed
#   MALFORMED  reason (also exits nonzero, so unparsable source fails closed)
move_facts_reader=$(cat <<'MOVE_FACTS_READER'
function blanks(count,   pad) {
    pad = ""
    while (length(pad) < count) pad = pad "                                        "
    return substr(pad, 1, count)
}

function normalize(chunk) {
    gsub(/[ \t\n\r]+/, " ", chunk)
    sub(/^ /, "", chunk)
    sub(/ $/, "", chunk)
    return chunk
}

function fail(reason) {
    printf("MALFORMED\t%s\n", reason)
    broken = 1
    exit 3
}

function line_of(offset,   parts) {
    return split(substr(text, 1, offset - 1), parts, "\n")
}

function match_paren(open, opener, closer,   depth, index_, char_) {
    depth = 0
    for (index_ = open; index_ <= text_length; index_++) {
        char_ = substr(text, index_, 1)
        if (char_ == opener) depth++
        else if (char_ == closer) {
            depth--
            if (depth == 0) return index_
        }
    }
    return 0
}

function modifiers_before(stop,   scan, char_, boundary, between) {
    boundary = 0
    for (scan = stop; scan >= 1; scan--) {
        char_ = substr(text, scan, 1)
        if (char_ == ";" || char_ == "}" || char_ == "]") { boundary = scan; break }
    }
    attribute_text = ""
    if (boundary > 0 && substr(text, boundary, 1) == "]") collect_attributes(boundary)
    between = normalize(substr(text, boundary + 1, stop - boundary))
    return between
}

function collect_attributes(bracket_end,   depth, scan, char_, open) {
    while (1) {
        depth = 0
        open = 0
        for (scan = bracket_end; scan >= 1; scan--) {
            char_ = substr(text, scan, 1)
            if (char_ == "]") depth++
            else if (char_ == "[") {
                depth--
                if (depth == 0) { open = scan; break }
            }
        }
        if (open <= 1 || substr(text, open - 1, 1) != "#") return
        attribute_text = normalize(substr(text, open - 1, bracket_end - open + 2)) " " attribute_text
        bracket_end = 0
        for (scan = open - 2; scan >= 1; scan--) {
            char_ = substr(text, scan, 1)
            if (char_ == " " || char_ == "\t" || char_ == "\n") continue
            if (char_ == "]") { bracket_end = scan }
            break
        }
        if (bracket_end == 0) return
    }
}

{ source_lines[NR] = $0 }

END {
    total_lines = NR
    marker_line = 0
    for (index_ = 1; index_ <= total_lines; index_++) {
        if (source_lines[index_] ~ /^\/\/ === Test-Only (Functions|Types) ===$/) {
            marker_line = index_
            break
        }
    }

    text = ""
    in_block = 0
    block_depth = 0
    in_string = 0
    for (index_ = 1; index_ <= total_lines; index_++) {
        line = source_lines[index_]
        cleaned = ""
        line_length = length(line)
        cursor = 1
        while (cursor <= line_length) {
            char_ = substr(line, cursor, 1)
            pair = substr(line, cursor, 2)
            if (in_block) {
                if (pair == "*/") {
                    block_depth--
                    if (block_depth == 0) in_block = 0
                    cleaned = cleaned "  "
                    cursor += 2
                    continue
                }
                if (pair == "/*") {
                    block_depth++
                    cleaned = cleaned "  "
                    cursor += 2
                    continue
                }
                cleaned = cleaned " "
                cursor++
                continue
            }
            if (in_string) {
                if (char_ == "\\") {
                    cleaned = cleaned blanks(cursor + 1 <= line_length ? 2 : 1)
                    cursor += 2
                    continue
                }
                if (char_ == "\"") {
                    in_string = 0
                    cleaned = cleaned "\""
                    cursor++
                    continue
                }
                cleaned = cleaned "_"
                cursor++
                continue
            }
            if (pair == "//") {
                cleaned = cleaned blanks(line_length - cursor + 1)
                cursor = line_length + 1
                continue
            }
            if (pair == "/*") {
                in_block = 1
                block_depth = 1
                cleaned = cleaned "  "
                cursor += 2
                continue
            }
            if (char_ == "\"") {
                in_string = 1
                cleaned = cleaned "\""
                cursor++
                continue
            }
            cleaned = cleaned char_
            cursor++
        }
        text = text cleaned "\n"
    }
    if (in_block) fail("unterminated block comment")
    if (in_string) fail("unterminated string literal")

    text_length = length(text)

    cursor = 1
    while (cursor <= text_length) {
        remainder = substr(text, cursor)
        if (!match(remainder, /(^|[^A-Za-z0-9_$])fun[ \t\n]/)) break
        hit = substr(remainder, RSTART, 1)
        keyword = cursor + RSTART - 1
        if (hit != "f") keyword++
        cursor = keyword + 3

        if (substr(text, 1, keyword - 1) ~ /use[ \t\n]+$/) continue

        if (!match(substr(text, cursor), /^[ \t\n]+[A-Za-z_][A-Za-z0-9_]*!?/)) {
            fail("function keyword without a name at line " line_of(keyword))
        }
        name = normalize(substr(text, cursor + RSTART - 1, RLENGTH))
        name_end = cursor + RSTART + RLENGTH - 2

        modifiers = modifiers_before(keyword - 1)
        attributes = attribute_text
        if (modifiers != "" \
            && modifiers !~ /^((public(\(package\)|\(friend\))?|entry|macro)( |$))+$/) {
            fail("unrecognized function modifiers '" modifiers "' before " name)
        }

        visibility = "private"
        if (modifiers ~ /(^| )public\(package\)( |$)/) visibility = "package"
        else if (modifiers ~ /(^| )public\(friend\)( |$)/) visibility = "friend"
        else if (modifiers ~ /(^| )public( |$)/) visibility = "public"
        is_entry = (modifiers ~ /(^| )entry( |$)/) ? 1 : 0
        is_macro = (modifiers ~ /(^| )macro( |$)/) ? 1 : 0
        is_test_only = (attributes ~ /test_only/) ? 1 : 0
        function_line = line_of(keyword)
        after_marker = (marker_line > 0 && function_line >= marker_line) ? 1 : 0

        open_paren = index(substr(text, name_end + 1), "(")
        if (open_paren == 0) fail("function " name " has no parameter list")
        open_paren += name_end
        close_paren = match_paren(open_paren, "(", ")")
        if (close_paren == 0) fail("function " name " has an unbalanced parameter list")

        body_open = 0
        for (index_ = close_paren + 1; index_ <= text_length; index_++) {
            char_ = substr(text, index_, 1)
            if (char_ == "{") { body_open = index_; break }
            if (char_ == ";") break
        }
        if (body_open == 0) fail("function " name " has no body")
        body_close = match_paren(body_open, "{", "}")
        if (body_close == 0) fail("function " name " has an unbalanced body")

        printf("FN\t%s\t%s\t%d\t%d\t%d\t%d\t%d\t%s\t%s\n",
            name, visibility, is_entry, is_macro, is_test_only, after_marker,
            function_line,
            normalize(substr(text, keyword, body_open - keyword)),
            normalize(substr(text, body_open + 1, body_close - body_open - 1)))

        cursor = body_close + 1
    }

    cursor = 1
    while (cursor <= text_length) {
        remainder = substr(text, cursor)
        if (!match(remainder, /(^|[^A-Za-z0-9_$])(struct|enum)[ \t\n]/)) break
        hit = substr(remainder, RSTART, 1)
        keyword = cursor + RSTART - 1
        if (hit != "s" && hit != "e") keyword++
        kind = (substr(text, keyword, 6) == "struct") ? "struct" : "enum"
        cursor = keyword + length(kind)

        if (!match(substr(text, cursor), /^[ \t\n]+[A-Za-z_][A-Za-z0-9_]*/)) {
            fail(kind " keyword without a name at line " line_of(keyword))
        }
        name = normalize(substr(text, cursor + RSTART - 1, RLENGTH))

        declaration_end = 0
        for (index_ = cursor; index_ <= text_length; index_++) {
            char_ = substr(text, index_, 1)
            if (char_ == "{") {
                declaration_end = match_paren(index_, "{", "}")
                if (declaration_end == 0) fail(kind " " name " has an unbalanced body")
                break
            }
            if (char_ == ";") { declaration_end = index_; break }
        }
        if (declaration_end == 0) fail(kind " " name " is unterminated")

        modifiers = modifiers_before(keyword - 1)
        attributes = attribute_text
        visibility = (modifiers ~ /(^| )public( |$)/) ? "public" : "private"
        declaration_line = line_of(keyword)

        printf("TYPE\t%s\t%s\t%s\t%d\t%d\t%d\t%s\n",
            name, kind, visibility,
            (attributes ~ /test_only/) ? 1 : 0,
            (marker_line > 0 && declaration_line >= marker_line) ? 1 : 0,
            declaration_line,
            normalize(substr(text, keyword, declaration_end - keyword + 1)))

        cursor = declaration_end + 1
    }

    printf("MARKER\t%d\n", marker_line)
    printf("NORM\t%s\n", normalize(text))
}
MOVE_FACTS_READER
)

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

launchpad_domain_production="$(sed '/^\/\/ === Test-Only Functions ===/,$d' \
  sources/launchpad_domain.move)"

if [[ ! -f sources/launchpad_domain.move ]] \
  || ! rg -Fq 'public struct LAUNCHPAD_DOMAIN has drop {}' sources/launchpad_domain.move \
  || ! rg -Fq 'fun init(otw: LAUNCHPAD_DOMAIN, ctx: &mut TxContext) {' \
    sources/launchpad_domain.move \
  || ! rg -Fq 'blast_admin::acl::new(otw, MAX_ADMINS, ROOT_TRANSFER_DELAY_MS, ctx);' \
    sources/launchpad_domain.move \
  || ! rg -q '^const MAX_ADMINS: u64 = 16;$' sources/launchpad_domain.move \
  || ! rg -q '^const ROOT_TRANSFER_DELAY_MS: u64 = 7 \* 24 \* 60 \* 60 \* 1_000;$' \
    sources/launchpad_domain.move \
  || ! rg -q '^const PACKAGE_ADMIN_ROLE: u64 = 1;$' sources/launchpad_domain.move \
  || [[ "$(rg -c '^public fun ' <<<"$launchpad_domain_production")" != 1 ]] \
  || ! rg -Fq 'public fun package_admin_role(): u64 {' sources/launchpad_domain.move; then
  echo 'launchpad_domain.move must create exactly one typed domain from module constants and export one role.' >&2
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
    'public struct PackageAdmin has key \{\s*id: UID,\s*custody: UpgradeCustody<BLAST>,\s*\}' \
    sources/package_admin.move \
  || [[ "$(rg -c '^public fun ' <<<"$package_admin_production")" != 7 ]] \
  || [[ "$(rg -c '^public fun (wrap|authorize_upgrade|restrict_to_additive|restrict_to_dependency_only|commit_upgrade_and_advance|make_immutable|has_upgrade_cap)\(' <<<"$package_admin_production")" != 7 ]] \
  || rg -n '^public\(package\) fun ' <<<"$package_admin_production" \
  || rg -n '^public fun commit_upgrade\(|^public fun activate' <<<"$package_admin_production" \
  || [[ "$(rg -o 'admin_witness: &AdminWitness<LAUNCHPAD_DOMAIN>' <<<"$package_admin_production" | wc -l)" != 5 ]] \
  || ! rg -U -q \
    'public fun wrap\(publisher: Publisher, upgrade_cap: UpgradeCap, ctx: &mut TxContext\)' \
    sources/package_admin.move \
  || ! rg -U -q \
    'public fun authorize_upgrade\(\s*self: &mut PackageAdmin,\s*package_version: &PackageVersion,\s*admin_witness: &AdminWitness<LAUNCHPAD_DOMAIN>,\s*digest: vector<u8>,\s*\): UpgradeTicket' \
    sources/package_admin.move \
  || ! rg -U -q \
    'public fun commit_upgrade_and_advance\(\s*self: &mut PackageAdmin,\s*package_version: &mut PackageVersion,\s*admin_witness: &AdminWitness<LAUNCHPAD_DOMAIN>,\s*receipt: UpgradeReceipt,\s*\)' \
    sources/package_admin.move; then
  echo 'package_admin.move must expose only validated wrapping, role-gated native administration, and one atomic commit-and-advance finalizer.' >&2
  failures=$((failures + 1))
fi

# Every governed custody transition asserts the current generation, then the one
# exported role, before it reaches the shared custody value. Commit-and-advance
# is the post-upgrade finalizer and instead proves the exact next generation.
if ! rg -Fq 'publisher.from_module<BLAST>()' sources/package_admin.move \
  || ! rg -Fq 'upgrade_custody::new<BLAST>(id.to_inner(), publisher, upgrade_cap)' \
    sources/package_admin.move \
  || [[ "$(rg -c 'package_version\.assert_current\(\);' <<<"$package_admin_production")" != 4 ]] \
  || [[ "$(rg -c 'admin_witness\.assert_role\(launchpad_domain::package_admin_role\(\)\);' <<<"$package_admin_production")" != 5 ]] \
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

fees_facts="$(move_facts sources/fees.move)"
fees_source="$(move_normalized_source <<<"$fees_facts")"

if [[ ! -f sources/fees.move ]] \
  || [[ "$(move_production_functions <<<"$fees_facts")" \
    != 'accrue:package:0 accrue_from_runtime:public:0 accrue_protocol_fees:package:0 claim_creator_fees:public:0 claim_protocol_fees:public:0 new:public:0 totals:public:0 ' ]] \
  || [[ "$(move_production_type FeeLedger <<<"$fees_facts")" \
    != 'struct FeeLedger<phantom Meme, phantom Quote> has store { protocol_meme: Balance<Meme>, creator_meme: Balance<Meme>, protocol_quote: Balance<Quote>, creator_quote: Balance<Quote>, }' ]] \
  || rg -q '\b(UID|key|transfer::|XClaim|ed25519|recipient|launch_id)\b' <<<"$fees_source" \
  || rg -q 'fee_balance_overflow|std::u64::max_value|max_balance' <<<"$fees_source" \
  || rg -q 'set_creator_fee_split|sui::event|events::' <<<"$fees_source"; then
  echo 'fees.move must remain an embedded supply-conserved four-balance ledger exposing only its five approved cross-package functions and two package seams.' >&2
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
# emptiness test, or a drained balance cannot be swapped between the two owners.
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

check_fee_function accrue_from_runtime \
  'fun accrue_from_runtime<Meme, Quote>( self: &mut FeeLedger<Meme, Quote>, meme_fee: Balance<Meme>, quote_fee: Balance<Quote>, runtime_config: &RuntimeConfig, ): (u64, u64, u64, u64, u64, u64, u64, u64)' \
  '' \
  'self.accrue( meme_fee, quote_fee, runtime_config.protocol_fee_share(), )'

check_fee_function totals \
  'fun totals<Meme, Quote>( self: &FeeLedger<Meme, Quote>, ): (u64, u64, u64, u64)' \
  'creator_meme.value creator_quote.value protocol_meme.value protocol_quote.value ' \
  '( self.protocol_meme.value(), self.creator_meme.value(), self.protocol_quote.value(), self.creator_quote.value(), )'

check_fee_function claim_creator_fees \
  'fun claim_creator_fees<Meme, Quote>( self: &mut FeeLedger<Meme, Quote>, _: &CreatorCap<Meme>, ctx: &mut TxContext, ): (Coin<Meme>, Coin<Quote>)' \
  'creator_meme.value creator_meme.withdraw_all creator_quote.value creator_quote.withdraw_all ' \
  'assert!( self.creator_meme.value() > 0 || self.creator_quote.value() > 0, blast_fun::errors::nothing_accrued!(), ); ( self.creator_meme.withdraw_all().into_coin(ctx), self.creator_quote.withdraw_all().into_coin(ctx), )'

check_fee_function claim_protocol_fees \
  'fun claim_protocol_fees<Meme, Quote>( self: &mut FeeLedger<Meme, Quote>, _: &AdminWitness<LAUNCHPAD_DOMAIN>, ctx: &mut TxContext, ): (Coin<Meme>, Coin<Quote>)' \
  'protocol_meme.value protocol_meme.withdraw_all protocol_quote.value protocol_quote.withdraw_all ' \
  'assert!( self.protocol_meme.value() > 0 || self.protocol_quote.value() > 0, blast_fun::errors::nothing_accrued!(), ); ( self.protocol_meme.withdraw_all().into_coin(ctx), self.protocol_quote.withdraw_all().into_coin(ctx), )'

check_fee_function accrue_protocol_fees \
  'fun accrue_protocol_fees<Meme, Quote>( self: &mut FeeLedger<Meme, Quote>, meme_fee: Balance<Meme>, quote_fee: Balance<Quote>, ): (u64, u64, u64, u64)' \
  'protocol_meme.join protocol_quote.join ' \
  'let meme_delta = meme_fee.value(); let quote_delta = quote_fee.value(); let protocol_meme_total = self.protocol_meme.join(meme_fee); let protocol_quote_total = self.protocol_quote.join(quote_fee); ( meme_delta, quote_delta, protocol_meme_total, protocol_quote_total, )'

# The raw accrual keeps a longer body, so it is bound to its guard and to one
# contiguous rounding and custody sequence instead: the protocol share rounds up,
# the creator receives the exact remainder, the protocol amount leaves the
# incoming balances, and each half joins only its own bucket.
check_fee_function accrue \
  'fun accrue<Meme, Quote>( self: &mut FeeLedger<Meme, Quote>, mut meme_fee: Balance<Meme>, mut quote_fee: Balance<Quote>, protocol_fee_share_bps: Bps, ): (u64, u64, u64, u64, u64, u64, u64, u64)' \
  'creator_meme.join creator_quote.join protocol_meme.join protocol_quote.join ' \
  ''

fees_accrue_body="$(move_production_body accrue <<<"$fees_facts")"

if ! rg -Fq 'assert!( meme_fee_amount > 0 || quote_fee_amount > 0, blast_fun::errors::zero_fee_accrual!(), );' \
    <<<"$fees_accrue_body" \
  || ! rg -Fq 'let protocol_meme_amount = protocol_fee_share_bps.apply_up(meme_fee_amount); let protocol_quote_amount = protocol_fee_share_bps.apply_up(quote_fee_amount); let creator_meme_amount = meme_fee_amount - protocol_meme_amount; let creator_quote_amount = quote_fee_amount - protocol_quote_amount; let protocol_meme = meme_fee.split(protocol_meme_amount); let protocol_quote = quote_fee.split(protocol_quote_amount); let protocol_meme_total = self.protocol_meme.join(protocol_meme); let creator_meme_total = self.creator_meme.join(meme_fee); let protocol_quote_total = self.protocol_quote.join(protocol_quote); let creator_quote_total = self.creator_quote.join(quote_fee);' \
    <<<"$fees_accrue_body"; then
  fee_ledger_violations+='  accrue is not bound to the approved guard, round-up split, and per-owner joins'$'\n'
fi

if [[ -n "$fee_ledger_violations" ]]; then
  printf '%s' "$fee_ledger_violations"
  echo 'Fee state stays capability-gated per owner, splits on the live runtime protocol share, and releases balances only through the two authorized full drains.' >&2
  failures=$((failures + 1))
fi

if ! rg -U -q 'macro public\(package\) fun max_launch_fee_bps\(\): u64 \{\s*1_000\s*\}' \
  sources/lib/constants.move \
  || rg -n 'protocol_trade_fee_share_bps' sources; then
  echo 'The fee-rate ceiling is constant, while the protocol share must not be hard-coded.' >&2
  failures=$((failures + 1))
fi

package_version_production="$(sed '/^\/\/ === Test-Only Functions ===/,$d' sources/package_version.move)"

# The container owns only its compiled constants; the generation value, its
# checked arithmetic, and its replay event belong to blast_admin.
if [[ ! -f sources/package_version.move ]] \
  || ! rg -U -q \
    'public struct PackageVersion has key \{\s*id: UID,\s*generation: OperationalVersion<BLAST>,\s*\}' \
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
    != 'assert_x_claim_active:package:0 init:private:0 new:private:0 protocol_fee_share:package:0 protocol_fee_share_bps:public:0 revoke_x_claim_signer:public:0 set_protocol_fee_share:public:0 set_x_claim_signer:public:0 validate_x_claim_public_key:private:0 verify_x_claim_signature:package:0 ' ]] \
  || [[ "$(move_production_type RuntimeConfig <<<"$runtime_config_facts")" \
    != 'struct RuntimeConfig has key { id: UID, x_claim_signer_public_key: vector<u8>, protocol_fee_share_bps: Bps, }' ]] \
  || rg -q '\b(AdminCap|ProtocolAuthority|LaunchConfig|VecMap|VecSet|TypeName)\b' \
    <<<"$runtime_config_source" \
  || rg -q '\b(sequence|schema_version|action_tag|nonce)\b' <<<"$runtime_config_source"; then
  echo 'runtime_config.move must own only version-gated X signer and protocol fee share state.' >&2
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
  'transfer::share_object(new(ctx));'

check_runtime_function new \
  'fun new(ctx: &mut TxContext): RuntimeConfig' \
  'RuntimeConfig { id: object::new(ctx), x_claim_signer_public_key: vector[], protocol_fee_share_bps: bps::new(0), }'

check_runtime_function protocol_fee_share_bps \
  'fun protocol_fee_share_bps(self: &RuntimeConfig): u64' \
  'self.protocol_fee_share_bps.value()'

check_runtime_function protocol_fee_share \
  'fun protocol_fee_share(self: &RuntimeConfig): Bps' \
  'self.protocol_fee_share_bps'

check_runtime_function assert_x_claim_active \
  'fun assert_x_claim_active(self: &RuntimeConfig)' \
  'assert!( !self.x_claim_signer_public_key.is_empty(), blast_fun::errors::x_claim_signer_inactive!(), );'

check_runtime_function validate_x_claim_public_key \
  'fun validate_x_claim_public_key(signer_public_key: &vector<u8>)' \
  'assert!( signer_public_key.length() == constants::ed25519_public_key_length!(), blast_fun::errors::invalid_x_claim_public_key!(), );'

check_runtime_function verify_x_claim_signature \
  'fun verify_x_claim_signature( self: &RuntimeConfig, message: &vector<u8>, signature: &vector<u8>, )' \
  'self.assert_x_claim_active(); assert!( sui::ed25519::ed25519_verify( signature, &self.x_claim_signer_public_key, message, ), blast_fun::errors::invalid_x_claim_signature!(), );'

check_runtime_function set_x_claim_signer \
  'fun set_x_claim_signer( self: &mut RuntimeConfig, package_version: &PackageVersion, _: &AdminWitness<LAUNCHPAD_DOMAIN>, signer_public_key: vector<u8>, )' \
  'package_version.assert_current(); validate_x_claim_public_key(&signer_public_key); assert!( self.x_claim_signer_public_key != signer_public_key, blast_fun::errors::x_claim_signer_unchanged!(), ); let previous_public_key = self.x_claim_signer_public_key; self.x_claim_signer_public_key = signer_public_key; events::x_claim_signer_set( previous_public_key, self.x_claim_signer_public_key, );'

check_runtime_function revoke_x_claim_signer \
  'fun revoke_x_claim_signer( self: &mut RuntimeConfig, package_version: &PackageVersion, _: &AdminWitness<LAUNCHPAD_DOMAIN>, )' \
  'package_version.assert_current(); self.assert_x_claim_active(); let previous_public_key = self.x_claim_signer_public_key; self.x_claim_signer_public_key = vector[]; events::x_claim_signer_revoked(previous_public_key);'

check_runtime_function set_protocol_fee_share \
  'fun set_protocol_fee_share( self: &mut RuntimeConfig, package_version: &PackageVersion, _: &AdminWitness<LAUNCHPAD_DOMAIN>, protocol_fee_share_bps: u64, )' \
  'package_version.assert_current(); assert!( protocol_fee_share_bps != self.protocol_fee_share_bps.value(), blast_fun::errors::protocol_fee_share_unchanged!(), ); let old_protocol_fee_share_bps = self.protocol_fee_share_bps.value(); self.protocol_fee_share_bps = bps::new(protocol_fee_share_bps); events::protocol_fee_share_changed( old_protocol_fee_share_bps, protocol_fee_share_bps, );'

# The three named mutations are the complete set of RuntimeConfig transitions, and
# each one must check the live package version as its first statement rather than
# relying on any aggregate count.
runtime_config_mutations="$(awk -F'\t' '
  $1 == "FN" && $6 == 0 && $10 ~ /self\.(x_claim_signer_public_key|protocol_fee_share_bps) = / {
    print $2
  }
' <<<"$runtime_config_facts" | sort | tr '\n' ' ')"

if [[ "$runtime_config_mutations" \
  != 'revoke_x_claim_signer set_protocol_fee_share set_x_claim_signer ' ]]; then
  runtime_config_violations+="  runtime state is mutated by '${runtime_config_mutations}' instead of the three approved setters"$'\n'
fi

runtime_config_ungated="$(awk -F'\t' '
  $1 == "FN" && $6 == 0 \
    && ($2 == "set_x_claim_signer" || $2 == "revoke_x_claim_signer" \
      || $2 == "set_protocol_fee_share") {
    if ($9 !~ /[(,] package_version: &PackageVersion,/) {
      print "  " $2 " must take the shared PackageVersion under that exact name"
    }
    if ($10 !~ /^package_version\.assert_current\(\);/) {
      print "  " $2 " must check the live package version as its first statement"
    }
    if ($9 !~ /[(,] _: &AdminWitness<LAUNCHPAD_DOMAIN>,/) {
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
      || $2 == "XClaimSignerSet" || $2 == "XClaimSignerRevoked") { print $8 }
' <<<"$events_facts")"

if [[ "$(wc -l <<<"$runtime_config_mutation_event_payloads")" != 3 ]] \
  || rg -q '\b(sequence|schema_version|action_tag|nonce)\b' \
    <<<"$runtime_config_mutation_event_payloads" \
  || rg -q '\bruntime_config_id\b' <<<"$runtime_config_mutation_event_payloads" \
  || rg -q '\bRuntimeConfigCreated\b' <<<"$events_facts"; then
  echo 'Runtime-config creation must stay eventless and every mutation must emit unswapped typed replay facts without repeated singleton, ordering, or schema fields.' >&2
  failures=$((failures + 1))
fi

if [[ -f sources/x_claim_config.move || -f sources/trade_fee_config.move ]] \
  || rg -n '\b(XClaimConfig|TradeFeeConfig)\b' sources tests \
  || [[ "$(rg -o 'transfer::share_object' sources --glob '*.move' --glob '!launch.move' | wc -l)" != 4 ]]; then
  echo 'Core must keep exactly four locally shared protocol singletons; the domain authority is shared by blast_admin.' >&2
  failures=$((failures + 1))
fi

launch_config_production="$(sed '/^\/\/ === Test-Only Functions ===/,$d' sources/launch_config.move)"

if [[ ! -f sources/launch_config.move ]] \
  || ! rg -U -q \
    'public struct LaunchConfig has key \{\s*id: UID,\s*quotes: Table<TypeName, QuoteParameters>,\s*quote_fee_bps: Bps,\s*meme_fee_bps: Bps,\s*quote_migration_fee_bps: Bps,\s*protocol_meme_graduation_fee_bps: Bps,\s*meme_liquidity_provision_bps: Bps,\s*migration_witnesses: VecSet<TypeName>,\s*\}' \
    sources/launch_config.move \
  || ! rg -U -q \
    'public struct QuoteParameters has copy, drop, store \{\s*virtual_quote: u64,\s*migration_quote_target: u64,\s*\}' \
    sources/launch_config.move \
  || rg -n '\b(AdminCap|ProtocolAuthority)\b' <<<"$launch_config_production" \
  || rg -n '\b(sequence|schema_version|action_tag|nonce)\b' <<<"$launch_config_production" \
  || [[ "$(rg -o '_: &AdminWitness<LAUNCHPAD_DOMAIN>' <<<"$launch_config_production" | wc -l)" != 6 ]] \
  || [[ "$(rg -c '^public fun ' <<<"$launch_config_production")" != 6 ]] \
  || [[ "$(rg -c '^public fun (allow_quote|disallow_quote|allow_migration_witness|disallow_migration_witness)<' <<<"$launch_config_production")" != 4 ]] \
  || [[ "$(rg -c '^public fun set_graduation_defaults\(' <<<"$launch_config_production")" != 1 ]] \
  || ! rg -U -q \
    'public fun set_trade_fees\(\s*self: &mut LaunchConfig,\s*package_version: &PackageVersion,\s*_: &AdminWitness<LAUNCHPAD_DOMAIN>,\s*quote_fee_bps: u64,\s*meme_fee_bps: u64,\s*\)' \
    sources/launch_config.move \
  || ! rg -U -q \
    'public fun set_graduation_defaults\(\s*self: &mut LaunchConfig,\s*package_version: &PackageVersion,\s*_: &AdminWitness<LAUNCHPAD_DOMAIN>,\s*quote_migration_fee_bps: u64,\s*protocol_meme_graduation_fee_bps: u64,\s*meme_liquidity_provision_bps: u64,\s*\)' \
    sources/launch_config.move \
  || [[ "$(rg -c '^public\(package\) fun ' <<<"$launch_config_production")" != 1 ]] \
  || ! rg -U -q \
    'public\(package\) fun snapshot_for_launch<Quote, MigrationWitness: drop>\(\s*self: &LaunchConfig,\s*\): \(u64, u64, Bps, Bps, Bps, Bps, Bps, TypeName\)' \
    sources/launch_config.move; then
  echo 'launch_config.move must own only future-launch policy and its AdminWitness-gated mutations.' >&2
  failures=$((failures + 1))
fi

if ! rg -U -q 'macro public\(package\) fun max_migration_witnesses\(\): u64 \{\s*16\s*\}' \
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
  || ! rg -Fq 'quotes: table::new(ctx)' sources/launch_config.move \
  || ! rg -Fq 'self.quotes.add(quote, QuoteParameters {' sources/launch_config.move \
  || rg -n '\b(VecMap|vec_map|max_quote_assets|quote_capacity_reached)\b' \
    sources/launch_config.move sources/lib/constants.move sources/lib/errors.move \
  || ! rg -Fq 'self.migration_witnesses.length()' sources/launch_config.move \
  || ! rg -U -q \
    'quotes: table::new\(ctx\),\s*quote_fee_bps: bps::new\(0\),\s*meme_fee_bps: bps::new\(0\),\s*quote_migration_fee_bps: bps::new\(0\),\s*protocol_meme_graduation_fee_bps: bps::new\(0\),\s*meme_liquidity_provision_bps: bps::new\(0\),\s*migration_witnesses: vec_set::empty\(\)' \
    sources/launch_config.move \
  || ! rg -U -q \
    'protocol_meme_graduation_fee_bps \+ meme_liquidity_provision_bps\s*< constants::basis_points_denominator!\(\)' \
    sources/launch_config.move \
  || ! rg -Fq 'self.meme_liquidity_provision_bps.value() > 0' sources/launch_config.move \
  || rg -n '\bCurrency<Quote>\b|coin_registry' <<<"$launch_config_production"; then
  echo 'Launch policy must use Table-backed quotes, approved economic ceilings, original type identities, zero defaults, a bounded witness registry, and no Coin Registry dependency.' >&2
  failures=$((failures + 1))
fi

if ! rg -U -q \
    'fun init\(ctx: &mut TxContext\) \{\s*transfer::share_object\(new\(ctx\)\);\s*\}' \
    sources/launch_config.move \
  || rg -q '\bLaunchConfigCreated\b' sources/lib/events.move sources/launch_config.move; then
  echo 'Launch-config initialization must share the one cold-policy singleton and emit no creation event.' >&2
  failures=$((failures + 1))
fi

launch_config_event_payloads="$(sed -n \
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
  || ! rg -Fq 'let meme = treasury_cap.mint_balance(constants::meme_total_supply_atomic_units!());' sources/launch_ticket.move \
  || ! rg -U -q \
    'if \(burnable\) \{\s*initializer\.make_supply_burn_only\(treasury_cap\);\s*\} else \{\s*initializer\.make_supply_fixed\(treasury_cap\);\s*\};\s*let metadata_cap = initializer\.finalize\(ctx\);' \
    sources/launch_ticket.move \
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

launch_facts="$(move_facts sources/launch.move)"
launch_production="$(sed '/^\/\/ === Test-Only Functions ===/,$d' sources/launch.move)"
partition_meme_body="$(move_production_body partition_meme <<<"$launch_facts")"
partition_quote_body="$(move_production_body partition_quote <<<"$launch_facts")"

if [[ -e sources/graduation.move ]] \
  || [[ "$(move_production_signature partition_meme <<<"$launch_facts")" \
    != 'fun partition_meme<Meme>( mut meme: Balance<Meme>, protocol_meme_graduation_fee_bps: Bps, meme_liquidity_provision_bps: Bps, ): (Balance<Meme>, Balance<Meme>, Balance<Meme>)' ]] \
  || [[ "$(move_production_signature partition_quote <<<"$launch_facts")" \
    != 'fun partition_quote<Quote>( mut quote: Balance<Quote>, quote_migration_fee_bps: Bps, ): (Balance<Quote>, Balance<Quote>)' ]] \
  || [[ "$(count_occurrences 'partition_meme\(' <<<"$launch_production")" != 1 ]] \
  || [[ "$(count_occurrences 'partition_quote\(' <<<"$launch_production")" != 1 ]] \
  || ! rg -Fq 'protocol_meme_graduation_fee_bps.apply_up(initial_supply)' <<<"$partition_meme_body" \
  || ! rg -Fq 'meme_liquidity_provision_bps.apply_down(initial_supply)' <<<"$partition_meme_body" \
  || ! rg -Fq 'provision_amount > 0' <<<"$partition_meme_body" \
  || ! rg -Fq 'protocol_meme_fee_amount + provision_amount < initial_supply' \
    <<<"$partition_meme_body" \
  || [[ "$(count_occurrences '\.split\(' <<<"${partition_meme_body} ${partition_quote_body}")" != 3 ]] \
  || ! rg -Fq 'quote_migration_fee_bps.apply_up(quote.value())' <<<"$partition_quote_body"; then
  echo 'launch.move must privately own the accepted graduation ceil/floor, positive-bucket, and balance-custody rules.' >&2
  failures=$((failures + 1))
fi

if [[ ! -f sources/launch.move ]] \
  || ! rg -U -q \
    'public struct Launch<phantom Meme, phantom Quote> has key \{\s*id: UID,\s*lifecycle: Lifecycle,\s*sell_burn_bps: Bps,\s*virtual_quote: u64,\s*migration_quote_target: u64,\s*quote_fee_bps: Bps,\s*meme_fee_bps: Bps,\s*quote_migration_fee_bps: Bps,\s*protocol_meme_graduation_fee_bps: Bps,\s*meme_liquidity_provision_bps: Bps,\s*migration_witness: TypeName,\s*meme_reserve: Balance<Meme>,\s*real_quote_reserve: Balance<Quote>,\s*pending_burn: Balance<Meme>,\s*protocol_meme_graduation_fee: Balance<Meme>,\s*meme_liquidity_provision: Balance<Meme>,\s*fee_ledger: FeeLedger<Meme, Quote>,\s*metadata_cap: Option<MetadataCap<Meme>>,\s*creator_authority: Option<CreatorAuthority<Meme>>,\s*\}' \
    sources/launch.move \
  || [[ "$(rg -c '^public fun ' <<<"$launch_production")" != 10 ]] \
  || [[ "$(rg -c '^public fun (new|share|claim_creator_cap|buy|sell|claim_creator_fees|claim_protocol_fees|migrate|assert_migrated|redeem_migration)(<|\()' <<<"$launch_production")" != 10 ]] \
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
    'public fun assert_migrated<Meme, Quote>\(self: &Launch<Meme, Quote>\) \{\s*assert!\(\s*self\.lifecycle == Lifecycle::Migrated,\s*blast_fun::errors::invalid_launch_lifecycle!\(\),\s*\);\s*\}' \
    sources/launch.move \
  || ! rg -U -q \
    'public fun redeem_migration<Meme, Quote, MigrationWitness: drop>\(\s*self: MigrationPayload<Meme, Quote, MigrationWitness>,\s*_: MigrationWitness,\s*\): \(Balance<Meme>, Balance<Quote>\)' \
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

# `package_admin` keeps four `assert_current` guards across authorize, both
# restrictions, and immutability; commit-and-advance instead proves the exact
# next generation, so it contributes the fifth PackageVersion parameter only.
for gate_spec in 'launch_config:6:6' 'runtime_config:3:3' 'package_admin:4:5' 'launch:7:7'; do
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

# Reads call-normalized text, so whitespace around `::` or before an argument
# list cannot disguise a module-form call as anything other than what it is.
receiver_syntax_violations="$(
  for move_file in "${move_files[@]}"; do
    { move_facts "$move_file" \
      | move_normalized_source \
      | sed 's/ *:: */::/g; s/ *(/(/g' \
      | rg -o \
        '\b(acl::(grant_admin|revoke_admin|destroy_admin_cap|begin_super_admin_transfer|cancel_super_admin_transfer|accept_super_admin_transfer|destroy_retired_super_admin_cap|sign_in)|runtime_config::(set_x_claim_signer|revoke_x_claim_signer|set_protocol_fee_share|assert_x_claim_active|verify_x_claim_signature|protocol_fee_share|protocol_fee_share_bps)|launch_config::(allow_quote|disallow_quote|set_trade_fees|set_graduation_defaults|allow_migration_witness|disallow_migration_witness|snapshot_for_launch|allowed_quote_count_for_testing|allowed_migration_witness_count_for_testing)|launch::(share|migrate|redeem_migration)|creator_authority::(into_authority|creator|x_identity_hash|claim_creator_cap)|launch_ticket::destroy|fees::(accrue|accrue_from_runtime|accrue_protocol_fees|totals|claim_creator_fees|claim_protocol_fees)|package::test_upgrade|package_admin::(authorize_upgrade|commit_upgrade|restrict_to_additive|restrict_to_dependency_only|publisher_id_for_testing|upgrade_cap_id_for_testing|package_id_for_testing|version_for_testing|policy_for_testing))(<[^>]+>)?\(' \
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
  'RuntimeConfig|ed25519|x_claim_signer|verify_x_claim|CreatorCap|issue_creator_cap' \
  sources/launchpad_domain.move; then
  echo 'launchpad_domain.move must own only the domain marker, its constants, and its role.' >&2
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
    '(?s)public\(package\) fun claim_creator_cap<Meme>\(\s*self: CreatorAuthority<Meme>,.*\): CreatorCap<Meme> \{' \
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
