#!/usr/bin/env bash
# Mechanical boundary gate for the Blast SUI package.
set -euo pipefail

package_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
sources="$package_dir/sources"
vault="$sources/vault.move"
fail() { printf '%s\n' "$1" >&2; exit 1; }

# The body of top-level function $2 in file $1, signature included.
function_text() {
  sed -n "/^\(public \|public(package) \)\?fun $2[<(]/,/^}/p" "$1"
}

# 1. The manifest declares exactly two dependencies: the workspace administration package
#    and the pinned SuiSystem framework.
pinned_rev="06734f6ff0af45d8632a14a4dc4b100197f6b1a2"
deps="$(sed -n '/^\[dependencies\]/,/^\[/p' "$package_dir/Move.toml" | grep -E '^[A-Za-z]' || true)"
[ "$(wc -l <<<"$deps")" -eq 2 ] || fail "Move.toml must declare exactly two dependencies."
grep -q '^SuiSystem = ' <<<"$deps" || fail "Move.toml must depend on SuiSystem."
grep -Fxq 'blast_admin = { local = "../../governance/admin" }' <<<"$deps" \
  || fail "Move.toml must use the workspace blast_admin package."
grep -q "rev = \"$pinned_rev\"" "$package_dir/Move.toml" || fail "SuiSystem must stay pinned to $pinned_rev."

# 2. This package must not reference the launchpad package.
if grep -rn "blast_fun" "$sources" "$package_dir/tests"; then
  fail "blast_sui must not reference blast_fun."
fi

# 3. Administration is the shared blast_admin package; this package only names its roles,
#    and every administrator function takes one of them as its witness type.
for local_copy in acl blast_acl package_admin; do
  [ ! -e "$sources/$local_copy.move" ] || fail "blast_sui must not define a local $local_copy."
done
if rg -n '^public struct (ACL|Authority|ProtocolAuthority|SuperAdminCap|AdminCap|AdminWitness|PackageAdmin|PackageVersion|Publication)\b' \
  "$sources"; then
  fail "Administration types must come from blast_admin, never from a local copy."
fi
if rg -n 'fun init\(|acl::new\(' "$sources/blast_sui_domain.move"; then
  fail "blast_sui must not create administration state; the shared ACL already exists."
fi
[ "$(rg '^public struct ' "$sources/blast_sui_domain.move" | sort)" == "$(printf '%s\n' \
  'public struct CancelAdmin()' \
  'public struct FeeAdmin()' \
  'public struct ValidatorAdmin()' | sort)" ] \
  || fail "blast_sui_domain must declare exactly the reviewed ability-free roles."
if rg -n '^[^/]*AdminWitness<' "$sources" \
  | rg -v 'AdminWitness<(FeeAdmin|CancelAdmin|ValidatorAdmin|UnpauseAdmin<BLAST_SUI_PACKAGE>)>'; then
  fail "Every administrator witness must name one concrete blast_sui role."
fi

# 4. Publication hands over a generic Publication pinned to the package witness, and only
#    the vault's guarded release borrows that witness.
rg -q 'package_version::new_publication<_, PackageWitness>\(otw, constants::valid_pause_bits!\(\), ctx\)' \
  "$sources/blast_sui_package.move" || fail "init must create the generic publication."
rg -q '^public\(package\) fun package_witness\(\): PackageWitness \{$' "$sources/blast_sui_package.move" \
  || fail "The package witness must stay package-only."
[ "$(rg -l 'package_witness\(\)' "$sources" | sort)" == "$(printf '%s\n' \
  "$sources/blast_sui_package.move" "$vault" | sort)" ] \
  || fail "Only the vault may borrow the package witness."

# 5. The receipt Display is created once, inside vault creation, and its cap stays sealed.
rg -q '^public\(package\) fun create_display\(' "$sources/deposit_receipt.move" \
  || fail "create_display must be package-only."
[ "$(rg -c 'create_display\(' "$vault")" -eq 1 ] \
  && function_text "$vault" create | grep -q 'create_display(' \
  || fail "Only vault::create may create the receipt Display."

# 6. Pause covers exactly the three deposit paths, each with its own bit, directly after the
#    version check. Every exit stays live.
[ "$(rg -c 'assert_not_paused\(' "$vault")" -eq 3 ] || fail "Exactly three paths may check pause."
[ "$(rg -l 'assert_not_paused\(' "$sources")" == "$vault" ] || fail "Only the vault may check pause."
for pair in mint_fun_sui:fun_mint_pause_bit request_blast_sui:blast_request_pause_bit \
  claim_blast_sui:blast_claim_pause_bit; do
  function_text "$vault" "${pair%%:*}" | grep -A1 'package_version.assert_current(constants::version!());' \
    | grep -Fq "package_version.assert_not_paused(constants::${pair##*:}!());" \
    || fail "${pair%%:*} must check ${pair##*:} directly after its version check."
done

# 7. Only vault::unpause clears pause bits, and only once the delay is guarded.
[ "$(rg -l 'clear_pause_bits\(' "$sources")" == "$vault" ] || fail "Only the vault may clear pause bits."
[ "$(rg -c 'clear_pause_bits\(' "$vault")" -eq 1 ] || fail "The vault must clear pause bits once."
unpause_body="$(function_text "$vault" unpause)"
grep -Fq 'self.redeem_fee.is_guarded()' <<<"$unpause_body" || fail "unpause must require a guarded fee delay."
grep -Fq 'clear_pause_bits(' <<<"$unpause_body" || fail "unpause must clear through the package admin."

# 8. Every public function that takes the package version checks it first.
awk '
  /^public fun / { in_signature = 1; name = $3; sub(/[<(].*/, "", name); takes_version = 0 }
  in_signature && /package_version: &/ { takes_version = 1 }
  in_signature && /\{$/ { in_signature = 0; if (takes_version) { pending = name; next } }
  pending != "" {
    if ($0 !~ /^    package_version\.assert_current\(constants::version!\(\)\);$/) {
      printf "%s must check the package version first.\n", pending > "/dev/stderr"; failed = 1
    }
    pending = ""
  }
  END { exit failed }
' "$vault" || fail "A vault function reads state before its version check."

# 9. An unusable rate never prices stake: the rate read uses the one predicate.
function_text "$vault" exchange_rate_at | grep -q 'math::is_usable_rate(' \
  || fail "exchange_rate_at must reject unusable rates."

# 10. The error registry is sequential and pinned.
bash "$package_dir/scripts/check_error_registry.sh"

# 11. Every package event goes through the blast_events envelope; the delayed values emit their
#     own events inside blast_admin.
if grep -rn "sui::event::emit" "$sources" | grep -v "sources/lib/blast_events.move"; then
  fail "Only blast_events may call sui::event::emit."
fi

# 12. Functions with a natural first receiver use Move 2024 method syntax.
if rg -n 'dynamic_object_field::(add|borrow|borrow_mut|exists_with_type)\(' "$sources"; then
  fail "Dynamic-object-field operations must use semantic UID receiver aliases."
fi

if rg -n 'package::test_upgrade\(|test_scenario::return_to_sender\(|\.has_blast_coin\(' \
  "$package_dir/tests"; then
  fail "Test helpers with a natural first receiver must use Move 2024 dot syntax."
fi

if rg -n 'let[[:space:]]+[[:alnum:]_]+:[[:space:]]+&(mut[[:space:]]+)?Capability' "$sources"; then
  fail "Local reference types must be inferred from explicit generic arguments."
fi

printf 'Source boundaries hold.\n'
