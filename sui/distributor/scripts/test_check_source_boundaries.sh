#!/usr/bin/env bash
# Self-tests the distributor source-boundary checker against unsafe variants.
set -euo pipefail

package_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
checker="$package_dir/scripts/check_source_boundaries.sh"
tmp_root="$(mktemp -d)"
trap 'rm -rf -- "$tmp_root"' EXIT

fail() { printf '%s\n' "$1" >&2; exit 1; }

new_case() {
  local name="$1"
  local case_dir="$tmp_root/$name"
  mkdir -p "$case_dir"
  cp -R "$package_dir/sources" "$case_dir/sources"
  printf '%s\n' "$case_dir"
}

expect_rejected() {
  local case_dir="$1"
  if bash "$checker" "$case_dir" >/dev/null 2>&1; then
    fail "Boundary checker accepted unsafe fixture: $case_dir"
  fi
}

source_of() { printf '%s\n' "$1/sources/blast_fun_distributor.move"; }

[[ -x "$checker" ]] || fail "Boundary checker must exist and be executable."

bash "$checker" "$package_dir" >/dev/null

# Any caller could redirect another launch's creator fees into this custody.
case_dir="$(new_case drops_curve_collection_source_check)"
sed -i '/assert!(object::id(launch) == self.launch, EWrongSource);/d' \
  "$(source_of "$case_dir")"
expect_rejected "$case_dir"

# Allocating before the lock reintroduces the checked-late enrollment defect.
case_dir="$(new_case allocates_before_locking)"
python3 - "$(source_of "$case_dir")" <<'PY'
import sys
p = sys.argv[1]
s = open(p).read()
lock = "    launch.lock_creator_fees(package_version, curve_fee_cap, Witness());\n"
after = "    let publisher = PublisherCap { id: object::new(ctx), distributor: distributor.id.to_inner() };"
assert s.count(lock) == 1 and s.count(after) == 1
s = s.replace(lock, "", 1).replace(after, lock + after, 1)
open(p, "w").write(s)
PY
expect_rejected "$case_dir"

# A constructible witness lets any package claim the fees bound to this one.
case_dir="$(new_case exposes_the_custody_witness)"
printf '\npublic fun witness(): Witness { Witness() }\n' >> "$(source_of "$case_dir")"
expect_rejected "$case_dir"

# A witness carrying state is no longer proof that the caller is this module.
case_dir="$(new_case gives_the_witness_a_field)"
sed -i 's/^public struct Witness() has drop;$/public struct Witness has drop { id: u64 }/' \
  "$(source_of "$case_dir")"
expect_rejected "$case_dir"

# Skipping the pause check keeps fees moving after an emergency stop.
case_dir="$(new_case unpausable_curve_collection)"
python3 - "$(source_of "$case_dir")" <<'PY'
import sys
p = sys.argv[1]
s = open(p).read()
marker = "    ctx: &mut TxContext,\n) {\n    version.assert_enabled();\n    assert!(object::id(launch) == self.launch, EWrongSource);\n\n    let (meme, quote) = launch.claim_custodied_creator_fees("
assert s.count(marker) == 1
s = s.replace(marker, "    ctx: &mut TxContext,\n) {\n    assert!(object::id(launch) == self.launch, EWrongSource);\n\n    let (meme, quote) = launch.claim_custodied_creator_fees(", 1)
open(p, "w").write(s)
PY
expect_rejected "$case_dir"

# An unpausable intake keeps moving pushed coins into custody after an emergency stop.
case_dir="$(new_case unpausable_intake)"
python3 - "$(source_of "$case_dir")" <<'PY'
import sys
p = sys.argv[1]
s = open(p).read()
old = "    version.assert_enabled();\n    let batch_size = meme_receivings.length()"
assert s.count(old) == 1
open(p, "w").write(s.replace(old, "    let batch_size = meme_receivings.length()"))
PY
expect_rejected "$case_dir"

# An unbounded batch lets one call grow work without limit; an empty one emits a no-op fact.
case_dir="$(new_case unbounded_intake)"
python3 - "$(source_of "$case_dir")" <<'PY'
import sys
p = sys.argv[1]
s = open(p).read()
old = "batch_size > 0 && batch_size <= MAX_RECEIVING_COIN_BATCH_SIZE"
assert s.count(old) == 1
open(p, "w").write(s.replace(old, "batch_size <= 1_000_000"))
PY
expect_rejected "$case_dir"

# A second receiver bypasses the intake's gates, bound and event.
case_dir="$(new_case adds_an_ungated_receiver)"
python3 - "$(source_of "$case_dir")" <<'PY'
import sys
p = sys.argv[1]
s = open(p).read()
marker = "// === Test-Only Functions ===\n"
sweep = (
    "public fun sweep<Meme, Quote>(self: &mut Distributor<Meme, Quote>, coin: Receiving<Coin<Meme>>) {\n"
    "    self.meme.join(transfer::public_receive(&mut self.id, coin).into_balance());\n"
    "}\n\n"
)
assert s.count(marker) == 1
open(p, "w").write(s.replace(marker, sweep + marker))
PY
expect_rejected "$case_dir"

# Router configuration authority must never reach the distributor.
case_dir="$(new_case imports_router_authority)"
printf '\nuse blast_fun::fee_router::RouterConfigCap;\n' >> "$(source_of "$case_dir")"
expect_rejected "$case_dir"

# A migrator-vault intake would reopen a second recurring LP-fee exit beside the router.
case_dir="$(new_case reintroduces_a_vault_fee_intake)"
printf '\npublic fun take_vault_fees<Meme, Quote>(_: &blast_fun_migrators::vault::LpVault<Meme, Quote>) {}\n' \
  >> "$(source_of "$case_dir")"
expect_rejected "$case_dir"

# Renumbering a code silently changes what every existing client believes.
case_dir="$(new_case renumbers_an_error)"
sed -i 's/^#\[error(code = 15)\]$/#[error(code = 16)]/' "$(source_of "$case_dir")"
expect_rejected "$case_dir"

# Reordering a payload rewrites history for every indexer replaying it.
case_dir="$(new_case reorders_the_enrollment_event)"
python3 - "$(source_of "$case_dir")" <<'PY'
import sys
p = sys.argv[1]
s = open(p).read()
old = "public struct Enrolled has copy, drop {\n    distributor: ID,\n    launch: ID,\n"
new = "public struct Enrolled has copy, drop {\n    launch: ID,\n    distributor: ID,\n"
assert s.count(old) == 1
open(p, "w").write(s.replace(old, new))
PY
expect_rejected "$case_dir"

# An entry function is an unreviewed public surface on custodied funds.
case_dir="$(new_case adds_an_entry_path)"
printf '\nentry fun rogue<Meme, Quote>(_: &mut Distributor<Meme, Quote>) {}\n' \
  >> "$(source_of "$case_dir")"
expect_rejected "$case_dir"

# A test-only borrow of custody is a production hole once the flag is dropped.
case_dir="$(new_case leaks_mutable_custody)"
printf '\n#[test_only]\npublic fun custody_for_testing<Meme, Quote>(self: &mut Distributor<Meme, Quote>): &mut Balance<Meme> { &mut self.meme }\n' \
  >> "$(source_of "$case_dir")"
expect_rejected "$case_dir"

# Paying before the bit is recorded allows the same leaf to be claimed twice.
case_dir="$(new_case pays_before_recording_the_claim)"
python3 - "$(source_of "$case_dir")" <<'PY'
import sys
p = sys.argv[1]
s = open(p).read()
record = "    *&mut self.claimed[word] = self.claimed[word] | bit;\n"
emit = "    event::emit(RewardPaid {"
assert s.count(record) == 1 and s.count(emit) == 1
s = s.replace(record, "", 1).replace(emit, record + emit, 1)
open(p, "w").write(s)
PY
expect_rejected "$case_dir"

printf 'blast_fun_distributor boundary checker self-tests passed\n'
