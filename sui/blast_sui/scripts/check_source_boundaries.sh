#!/usr/bin/env bash
# Mechanical boundary gate for the Blast SUI package.
set -euo pipefail

package_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
fail() { printf '%s\n' "$1" >&2; exit 1; }

# 1. The manifest declares exactly two dependencies: the immutable shared
#    administration package and the pinned SuiSystem framework.
pinned_rev="06734f6ff0af45d8632a14a4dc4b100197f6b1a2"
deps="$(sed -n '/^\[dependencies\]/,/^\[/p' "$package_dir/Move.toml" | grep -E '^[A-Za-z]' || true)"
[ "$(wc -l <<<"$deps")" -eq 2 ] || fail "Move.toml must declare exactly two dependencies."
grep -q '^SuiSystem = ' <<<"$deps" || fail "Move.toml must depend on SuiSystem."
grep -Fq 'blast_admin = { local = "../admin" }' <<<"$deps" \
  || fail "Move.toml must depend on the immutable shared administration package."
grep -q "rev = \"$pinned_rev\"" "$package_dir/Move.toml" || fail "SuiSystem must stay pinned to $pinned_rev."

# 2. This package must not reference the launchpad package.
if grep -rn "blast_fun" "$package_dir/sources" "$package_dir/tests"; then
  fail "blast_sui must not reference blast_fun."
fi

# 3. Administration is the shared blast_admin ACL; this package only names its roles,
#    and every administrator function takes one of them as its witness type.
if [ -e "$package_dir/sources/acl.move" ] || [ -e "$package_dir/sources/blast_acl.move" ]; then
  fail "blast_sui must not define a local ACL implementation."
fi
if rg -n '^public struct (ACL|Authority|ProtocolAuthority|SuperAdminCap|AdminCap|AdminWitness)\b' \
  "$package_dir/sources"; then
  fail "Administration types must come from blast_admin, never from a local copy."
fi
if rg -n 'fun init\(|acl::new\(' "$package_dir/sources/blast_sui_domain.move"; then
  fail "blast_sui must not create administration state; the shared ACL already exists."
fi
[ "$(rg '^public struct ' "$package_dir/sources/blast_sui_domain.move" | sort)" == "$(printf '%s\n' \
  'public struct CancelAdmin()' \
  'public struct FeeAdmin()' \
  'public struct PauseAdmin()' \
  'public struct UnpauseAdmin()' \
  'public struct UpgradeAdmin()' | sort)" ] \
  || fail "blast_sui_domain must declare exactly the reviewed ability-free roles."
if rg -n '^[^/]*AdminWitness<' "$package_dir/sources" \
  | rg -v 'AdminWitness<(UpgradeAdmin|FeeAdmin|CancelAdmin|PauseAdmin|UnpauseAdmin)>|use blast_admin::'; then
  fail "Every administrator witness must name one concrete blast_sui role."
fi

# 4. Publication custody: init keeps the Publisher and generation in an owned proof,
#    only wrap consumes it, and wrap alone shares the usable version.
package_source="$package_dir/sources/blast_sui_package.move"
rg -q 'generation: OperationalVersion<BLAST_SUI_PACKAGE>,' "$package_source" \
  || fail "The generation value must be the shared typed value."
rg -q '^const NEXT_PACKAGE_VERSION: u64 = PACKAGE_VERSION \+ 1;$' "$package_source" \
  || fail "The cutover target must be derived as exactly the next compiled generation."
if rg -n '\.checked_add\(|fun activate\(|claim_and_keep\(' "$package_source"; then
  fail "Generation arithmetic, activation and Publisher release belong elsewhere."
fi
init_body="$(sed -n '/^fun init(otw: BLAST_SUI_PACKAGE, ctx: &mut TxContext) {/,/^}/p' "$package_source")"
grep -Fq 'transfer::transfer(Publication {' <<<"$init_body" \
  || fail "init must transfer the owned Publication."
if grep -Fq 'share_object' <<<"$init_body"; then
  fail "Publication must share no PackageVersion."
fi
if rg -n 'Publication|share_version\(' "$package_dir/sources" \
  | rg -v 'sources/blast_sui_package.move|sources/package_admin.move:'; then
  fail "Only package_admin::wrap may consume Publication or share the package version."
fi
[ "$(rg -c 'publication\.destroy\(\)|generation\.share_version\(ctx\)' "$package_dir/sources/package_admin.move")" -eq 2 ] \
  || fail "wrap must consume Publication and share the version exactly once."

# 5. Package custody: sealed, delayed, no narrowing, and no capability escape.
admin_source="$package_dir/sources/package_admin.move"
admin_production="$(sed '/^\/\/ === Test-Only Functions ===/,$d' "$admin_source")"
rg -q 'custody: UpgradeCustody<BLAST_SUI_PACKAGE>,' <<<"$admin_production" \
  || fail "Package custody must hold the shared typed value."
rg -q 'upgrade: DelayedAction<UpgradeKey, UpgradeAction>,' <<<"$admin_production" \
  || fail "Every upgrade action must wait the delayed slot's notice."
rg -U -q 'public enum UpgradeAction has copy, drop, store \{\n    Upgrade\(vector<u8>\),\n    Repair\(vector<u8>\),\n    MakeImmutable,\n\}' \
  <<<"$admin_production" || fail "Upgrade actions must be exactly Upgrade(digest), Repair(digest) and MakeImmutable."
if rg -n '\brestrict_to_' <<<"$admin_production"; then
  fail "No path may narrow the upgrade policy: a narrowed cap could never cut over again."
fi
rg -q 'public fun commit_upgrade_and_advance\(' <<<"$admin_production" \
  || fail "blast_sui must expose one atomic commit-and-advance finalizer."
if rg -n '^public fun (commit_upgrade|activate|add_capability|share)\(' <<<"$admin_production"; then
  fail "A separate commit, activation, capability attachment or share entry point is forbidden."
fi
if rg -U -n '^public fun [^(]+\([^)]*\): (&)?(Publisher|UpgradeCap)' <<<"$admin_production"; then
  fail "No custody path may release the sealed Publisher or UpgradeCap."
fi
if rg -n 'transfer::(public_)?transfer\(' <<<"$admin_production"; then
  fail "The framework UpgradeCap must never leave sealed custody."
fi
[ "$(rg -c '^    _: &AdminWitness<UpgradeAdmin>,$' <<<"$admin_production")" -eq 9 ] \
  || fail "Every upgrade or repair schedule, notice change, authorization, commit and immutability must require UpgradeAdmin."
# Only the repair path and cancellation skip the package version: they must stay reachable
# when no bytecode matches the stored generation. Each repair authorization reaches only its
# own finalizer, and only a repair finalizer skips the advance.
versionless="$(awk '
  /^public fun / { name = $3; sub(/\(.*/, "", name); in_sig = 1; mutable = 0; versioned = 0 }
  in_sig && /self: &mut PackageAdmin/ { mutable = 1 }
  in_sig && /package_version: &/ { versioned = 1 }
  in_sig && /\{$/ { in_sig = 0; if (mutable && !versioned) print name }
' <<<"$admin_production" | sort | tr '\n' ' ')"
[ "$versionless" == 'authorize_repair cancel_upgrade_action commit_repair schedule_repair ' ] \
  || fail "Only the repair path and cancellation may skip the package version, found: $versionless"
[ "$(rg -c 'self\.repairing = true;' <<<"$admin_production")" -eq 1 ] \
  && [ "$(rg -c 'self\.repairing = false;' <<<"$admin_production")" -eq 1 ] \
  && sed -n '/^public fun authorize_repair(/,/^}/p' "$admin_source" | rg -q 'self\.repairing = true;' \
  && sed -n '/^public fun commit_repair(/,/^}/p' "$admin_source" | rg -q 'self\.repairing = false;' \
  && sed -n '/^public fun commit_upgrade_and_advance(/,/^}/p' "$admin_source" \
    | rg -q 'assert!\(!self\.repairing, ' \
  || fail "Only authorize_repair may open a repair, only commit_repair may close it, and the advancing finalizer must reject one."
if sed -n '/^public fun commit_repair(/,/^}/p' "$admin_source" | rg -q 'advance\('; then
  fail "A repair must never advance the operational generation."
fi
wrap_body="$(sed -n '/^public fun wrap(/,/^}/p' "$admin_source")"
for required in 'id.add_capability(fun_metadata_cap);' 'id.add_capability(blast_metadata_cap);' \
  'id.add_capability(deposit_receipt::new_display(display_registry, ctx));' \
  'delayed_action::new(UpgradeKey(), &id, constants::initial_notice_ms!());'; do
  grep -Fq "$required" <<<"$wrap_body" || fail "wrap must contain: $required"
done
[ "$(tail -2 <<<"$wrap_body" | head -1 | sed 's/^ *//')" == 'generation.share_version(ctx);' ] \
  || fail "wrap must share the usable version last, after custody is sealed."

# 6. Pause flags stop deposits only, and only unpause clears them after every notice is guarded.
vault_source="$package_dir/sources/vault.move"
for deposit in mint_fun_sui request_blast_sui claim_blast_sui; do
  [ "$(sed -n "/^public fun $deposit(/,/^}/p" "$vault_source" | grep -c 'assert_not_paused(')" -eq 1 ] \
    || fail "$deposit must check its pause flag exactly once."
done
[ "$(rg -c 'assert_not_paused\(' "$vault_source")" -eq 3 ] \
  || fail "Only the three deposit paths may check pause flags; exits never pause."
if rg -n 'assert_not_paused\(' "$package_dir/sources" | rg -v 'sources/(vault|blast_sui_package)\.move'; then
  fail "Pause flags gate vault deposits only."
fi
if rg -n 'clear_pause_bits\(' "$package_dir/sources" \
  | rg -v 'sources/blast_sui_package.move|sources/package_admin.move:.*package_version\.clear_pause_bits\(bits\);'; then
  fail "Only package_admin::unpause may clear pause flags."
fi
unpause_body="$(sed -n '/^public fun unpause(/,/^}/p' "$admin_source")"
grep -Fq 'self.upgrade.is_guarded() && vault.is_redeem_fee_guarded(),' <<<"$unpause_body" \
  || fail "unpause must require every notice to be guarded."

# 7. Every public mutation that receives the package version checks it first: the
#    current generation, or the exact next one for the upgrade finalizer.
for source in "$vault_source" "$admin_source" "$package_dir/sources/deposit_receipt.move"; do
  production="$(sed '/^\/\/ === Test-Only Functions ===/,$d' "$source")"
  unguarded="$(awk '
    /^public fun / { name = $3; sub(/\(.*/, "", name); in_sig = 1; has_version = 0 }
    in_sig && /package_version: &/ { has_version = 1 }
    in_sig && /\{$/ { in_sig = 0; want_first = has_version; next }
    want_first && NF > 0 {
      if ($0 !~ /^    package_version\.assert_(current|next)\(\);$/) print name
      want_first = 0
    }
  ' <<<"$production")"
  [ -z "$unguarded" ] || fail "These public functions must check the package version first: $unguarded"
done
if rg -n 'package_version' "$package_dir/sources/deposit_receipt.move"; then
  fail "Receipt keep and cancel must stay independent of the vault and its package version."
fi

# 8. The error registry is sequential and every code has exactly one literal pin.
bash "$package_dir/scripts/check_error_registry.sh"

# 9. Every event goes through the blast_events envelope.
if grep -rn "sui::event::emit" "$package_dir/sources" | grep -v "sources/lib/blast_events.move"; then
  fail "Only blast_events may call sui::event::emit."
fi

# 10. Functions with a natural first receiver use Move 2024 method syntax.
if rg -n 'dynamic_object_field::(add|borrow|borrow_mut|exists_with_type)\(' \
  "$package_dir/sources"; then
  fail "Dynamic-object-field operations must use semantic UID receiver aliases."
fi

if rg -n 'package::test_upgrade\(|test_scenario::return_to_sender\(|\.has_blast_coin\(' \
  "$package_dir/tests"; then
  fail "Test helpers with a natural first receiver must use Move 2024 dot syntax."
fi

if rg -n 'let[[:space:]]+[[:alnum:]_]+:[[:space:]]+&(mut[[:space:]]+)?Capability' \
  "$package_dir/sources"; then
  fail "Local reference types must be inferred from explicit generic arguments."
fi

printf 'Source boundaries hold.\n'
