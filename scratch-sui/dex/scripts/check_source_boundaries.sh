#!/usr/bin/env bash
# Mechanical boundary gate for the native DEX.
#
# The DEX owns an independent administration domain, an independent operational
# generation, and sealed framework custody. The two deliberate Launchpad-witness
# calls (protocol-fee claims and LP-fee capability issuance) are product-fee
# custody, not DEX administration.
set -euo pipefail

package_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
sources="$package_dir/sources"

fail() { printf 'DEX source boundary failed: %s\n' "$1" >&2; exit 1; }

# --- Manifest: the inward administration edge ---

grep -Fq 'blast_admin = { local = "../admin" }' "$package_dir/Move.toml" \
  || fail "the manifest must depend on the immutable shared administration package"
grep -Fq 'blast_fun = { local = "../launchpad" }' "$package_dir/Move.toml" \
  || fail "the manifest must keep its Launchpad product dependency"

# --- No local administration implementation ---

for forbidden in acl.move upgrade.move; do
  [[ -e "$sources/$forbidden" ]] && fail "the DEX must not define a local $forbidden"
done

if rg -n '^public struct (Authority|ProtocolAuthority|SuperAdminCap|AdminCap|AdminWitness|OperationalVersion|UpgradeCustody)\b' \
  "$sources"; then
  fail "administration types must come from blast_admin, never from a local copy"
fi

if rg -n 'fun (grant_admin|revoke_admin|grant_role|revoke_role|sign_in)\(' "$sources"; then
  fail "the DEX must not reimplement administrator membership"
fi

# --- Its own domain, package marker, generation, and custody ---

for required in dex_domain.move package_marker.move package_admin.move pool.move; do
  [[ -f "$sources/$required" ]] || fail "the DEX must own $required"
done

dex_domain_production="$(sed '/^\/\/ === Test-Only Functions ===/,$d' "$sources/dex_domain.move")"

rg -Fq 'public struct DEX_DOMAIN has drop {}' "$sources/dex_domain.move" \
  || fail "dex_domain.move must own the domain one-time witness"
rg -Fq 'fun init(otw: DEX_DOMAIN, ctx: &mut TxContext) {' "$sources/dex_domain.move" \
  || fail "the DEX domain must be created from its own one-time witness"
rg -Fq 'blast_admin::acl::new(otw, MAX_ADMINS, ROOT_TRANSFER_DELAY_MS, ctx);' \
  "$sources/dex_domain.move" \
  || fail "the DEX domain must be created through the shared ACL constructor"
rg -q '^const MAX_ADMINS: u64 = 16;$' "$sources/dex_domain.move" \
  || fail "the DEX domain must keep its bounded administrator registry"
rg -q '^const ROOT_TRANSFER_DELAY_MS: u64 = 7 \* 24 \* 60 \* 60 \* 1_000;$' \
  "$sources/dex_domain.move" \
  || fail "the DEX domain must keep its seven-day root-transfer delay"
rg -q '^const PACKAGE_ADMIN_ROLE: u64 = 1;$' "$sources/dex_domain.move" \
  || fail "the DEX package-admin role must remain bit 1"
[[ "$(rg -c '^public fun ' <<<"$dex_domain_production")" == 1 ]] \
  || fail "the DEX domain must export exactly one role accessor"

# Exactly one module may create the shared authority.
[[ "$(rg -l 'acl::new\(' "$sources" | wc -l)" -eq 1 ]] \
  || fail "exactly one module may call the shared ACL constructor"

# --- The Factory carries the shared generation value and nothing else ---

rg -U -q \
  'public struct Factory has key \{\s*id: UID,\s*generation: OperationalVersion<PACKAGE_MARKER>,\s*pools: Table<TypeName, ID>,\s*\}' \
  "$sources/pool.move" \
  || fail "the Factory must embed the shared typed generation beside its pool registry"
rg -q '^const PACKAGE_VERSION: u64 = 1;$' "$sources/pool.move" \
  || fail "the DEX must compile its current generation constant"
rg -q '^const NEXT_PACKAGE_VERSION: u64 = 2;$' "$sources/pool.move" \
  || fail "the DEX must compile its cutover target constant"
if rg -n '\.checked_add\(1\)|^public fun activate\(|VersionActivated' "$sources/pool.move"; then
  fail "generation arithmetic, separate activation, and its event belong to blast_admin"
fi
rg -U -q \
  'public fun assert_current\(self: &Factory\) \{ self\.generation\.assert_current\(PACKAGE_VERSION\); \}' \
  "$sources/pool.move" \
  || fail "the generation guard must delegate to the shared value"
rg -q '^public\(package\) fun assert_next\(self: &Factory\) \{$' "$sources/pool.move" \
  || fail "the cutover proof must stay package-internal to the finalizer"
rg -q '^public\(package\) fun advance\(self: &mut Factory\) \{$' "$sources/pool.move" \
  || fail "the generation advance must stay package-internal to the finalizer"

# --- Every administered DEX operation uses the DEX domain ---

dex_witness_uses="$(rg -c '&AdminWitness<DEX_DOMAIN>' "$sources/pool.move" || true)"
[[ "${dex_witness_uses:-0}" -eq 1 ]] \
  || fail "pool policy must take exactly one typed DEX witness"
rg -U -q \
  'public fun set_max_fee<Meme, Quote>\(\s*self: &mut Pool<Meme, Quote>,\s*factory: &Factory,\s*_: &AdminWitness<DEX_DOMAIN>,\s*maximum_bps: u64,\s*\) \{\s*factory\.assert_current\(\);' \
  "$sources/pool.move" \
  || fail "pool-policy administration must be generic DEX administration after the generation check"

# --- The two deliberate Launchpad-witness exceptions ---
#
# claim_protocol_fees and issue_lp_fee_cap govern balances in a Launchpad-owned
# FeeLedger, so they stay under Launchpad product-fee custody (ADR 0082). Every
# other Launchpad-witness use is rejected, and each exception may forward the
# witness only to its single Launchpad call.
migration_production="$(sed '/^\/\/ === Test-Only Functions ===/,$d' "$sources/migration.move")"

launchpad_witness_uses="$(rg -o --no-filename '&AdminWitness<BLAST_FUN_DOMAIN>' "$sources" \
  | wc -l)"
[[ "${launchpad_witness_uses:-0}" -eq 2 ]] \
  || fail "exactly two calls may accept a Launchpad witness"
[[ "$(rg -o -F '&AdminWitness<BLAST_FUN_DOMAIN>' <<<"$migration_production" | wc -l)" -eq 2 ]] \
  || fail "both Launchpad-witness exceptions must live in production migration.move"
rg -U -q \
  'public fun claim_protocol_fees<Meme, Quote>\(\s*self: &mut LockedLpVault<Meme, Quote>,\s*witness: &AdminWitness<BLAST_FUN_DOMAIN>,\s*factory: &Factory,\s*ctx: &mut TxContext,\s*\): \(Coin<Meme>, Coin<Quote>\) \{\s*factory\.assert_current\(\);\s*let \(meme, quote\) = self\.fees\.claim_protocol_fees\(witness, ctx\);' \
  <<<"$migration_production" \
  || fail "migration::claim_protocol_fees must take the Launchpad witness with its exact signature and forward it only to the ledger claim after the generation check"
rg -U -q \
  'public fun issue_lp_fee_cap<Meme, Quote>\(\s*self: &mut LockedLpVault<Meme, Quote>,\s*witness: &AdminWitness<BLAST_FUN_DOMAIN>,\s*factory: &Factory,\s*version: &PackageVersion,\s*recipient: address,\s*ctx: &mut TxContext,\s*\) \{\s*factory\.assert_current\(\);\s*assert!\(!self\.lp_fee_authority\.is_custodian\(\), ELpFeesLocked\);\s*assert!\(recipient != @0x0, EInvalidLpFeeCapRecipient\);\s*let lp_fee_cap = creator_authority::new_lp_fee_cap<Meme>\(version, witness, ctx\);' \
  <<<"$migration_production" \
  || fail "migration::issue_lp_fee_cap must take the Launchpad witness with its exact signature and check generation, terminal lock, and nonzero recipient before role-gated minting"
for forwarded in 'self.fees.claim_protocol_fees(witness, ctx)' \
  'creator_authority::new_lp_fee_cap<Meme>(version, witness, ctx)'; do
  [[ "$(rg -o -F "$forwarded" "$sources" | wc -l)" -eq 1 ]] \
    || fail "the Launchpad witness must reach each Launchpad call from exactly one exception"
done
[[ "$(rg -o -F 'new_lp_fee_cap<' "$sources" | wc -l)" -eq 1 ]] \
  || fail "migration::issue_lp_fee_cap must be the only LP-fee capability issuance path"
if rg -n 'AdminWitness<BLAST_FUN_DOMAIN>' "$sources/pool.move" "$sources/package_admin.move" \
  "$sources/dex_domain.move" "$sources/package_marker.move" "$sources/math.move"; then
  fail "factory, pool-policy, and package administration must never take a Launchpad witness"
fi

# --- LP-fee authority: unassigned at migration, one live cap, terminal custodian ---

[[ "$(rg -o -F 'lp_fee_authority: LpFeeAuthority::' <<<"$migration_production" | wc -l)" -eq 1 ]] \
  && rg -Fq 'lp_fee_authority: LpFeeAuthority::Unassigned,' <<<"$migration_production" \
  || fail "migration must be the only LP-fee authority initializer and must leave it unassigned"
[[ "$(rg -o -F 'self.lp_fee_authority = LpFeeAuthority::' <<<"$migration_production" | wc -l)" -eq 2 ]] \
  || fail "only LP-fee issuance and custodian locking may write LP-fee authority"
rg -U -q \
  'let lp_fee_cap_id = object::id\(&lp_fee_cap\);\s*let revoked_lp_fee_cap_id = match \(self\.lp_fee_authority\) \{\s*LpFeeAuthority::Cap\(revoked_id\) => option::some\(revoked_id\),\s*_ => option::none\(\),\s*\};\s*self\.lp_fee_authority = LpFeeAuthority::Cap\(lp_fee_cap_id\);\s*transfer::public_transfer\(lp_fee_cap, recipient\);\s*event::emit\(LpFeeCapIssued \{\s*vault_id: self\.id\.to_inner\(\),\s*revoked_lp_fee_cap_id,\s*lp_fee_cap_id,\s*recipient,\s*\}\);\s*\}' \
  <<<"$migration_production" \
  || fail "LP-fee issuance must retire the previous cap, deliver the new one, and emit both identities"
rg -U -q \
  'public fun claim_creator_fees<Meme, Quote>\(\s*self: &mut LockedLpVault<Meme, Quote>,\s*lp_fee_cap: &LpFeeCap<Meme>,\s*factory: &Factory,\s*ctx: &mut TxContext,\s*\): \(Coin<Meme>, Coin<Quote>\) \{\s*factory\.assert_current\(\);\s*self\.assert_lp_fee_cap\(lp_fee_cap\);\s*self\.claim_ledger_creator_fees\(ctx\)\s*\}' \
  <<<"$migration_production" \
  || fail "migration::claim_creator_fees must assert the live LP-fee cap before claiming"
rg -U -q \
  'public fun lock_creator_fees<Meme, Quote>\(\s*self: &mut LockedLpVault<Meme, Quote>,\s*lp_fee_cap: LpFeeCap<Meme>,\s*custodian: &UID,\s*factory: &Factory,\s*\) \{\s*factory\.assert_current\(\);\s*self\.assert_lp_fee_cap\(&lp_fee_cap\);\s*let lp_fee_cap_id = object::id\(&lp_fee_cap\);\s*let custodian_id = custodian\.to_inner\(\);\s*lp_fee_cap\.destroy_lp_fee_cap\(\);\s*self\.lp_fee_authority = LpFeeAuthority::Custodian\(custodian_id\);\s*event::emit\(LpFeesLocked \{ vault_id: self\.id\.to_inner\(\), lp_fee_cap_id, custodian_id \}\);\s*\}' \
  <<<"$migration_production" \
  || fail "migration::lock_creator_fees must assert and destroy the live LP-fee cap before binding a terminal custodian"
rg -U -q \
  'public fun claim_custodied_creator_fees<Meme, Quote>\(\s*self: &mut LockedLpVault<Meme, Quote>,\s*custodian: &UID,\s*factory: &Factory,\s*ctx: &mut TxContext,\s*\): \(Coin<Meme>, Coin<Quote>\) \{\s*factory\.assert_current\(\);\s*assert!\(\s*self\.lp_fee_authority == LpFeeAuthority::Custodian\(custodian\.to_inner\(\)\),\s*ELpFeeCustodianMismatch,\s*\);\s*self\.claim_ledger_creator_fees\(ctx\)\s*\}' \
  <<<"$migration_production" \
  || fail "migration::claim_custodied_creator_fees must match the bound custodian before claiming"
rg -U -q \
  'public fun assert_lp_fee_cap<Meme, Quote>\(\s*self: &LockedLpVault<Meme, Quote>,\s*lp_fee_cap: &LpFeeCap<Meme>,\s*\) \{\s*assert!\(self\.lp_fee_authority == LpFeeAuthority::Cap\(object::id\(lp_fee_cap\)\), ELpFeeCapNotLive\);\s*\}' \
  <<<"$migration_production" \
  || fail "migration::assert_lp_fee_cap must be a read-only exact live-cap identity assertion"
rg -q '^fun claim_ledger_creator_fees<Meme, Quote>\($' <<<"$migration_production" \
  || fail "migration::claim_ledger_creator_fees must stay private"
[[ "$(rg -o -F 'self.claim_ledger_creator_fees(ctx)' <<<"$migration_production" | wc -l)" -eq 2 ]] \
  || fail "creator fees may be claimed only through the live-cap and custodian paths"
[[ "$(rg -o -F '.claim_creator_fees(ctx)' "$sources" | wc -l)" -eq 1 ]] \
  || fail "creator ledger withdrawal must stay inside the private ledger claim"

# --- Sealed custody, atomic finalizer, no capability escape ---

package_admin_production="$(sed '/^\/\/ === Test-Only Functions ===/,$d' \
  "$sources/package_admin.move")"

rg -U -q \
  'public struct PackageAdmin has key \{\s*id: UID,\s*custody: UpgradeCustody<PACKAGE_MARKER>,\s*\}' \
  "$sources/package_admin.move" \
  || fail "DEX custody must be the shared sealed value and nothing else"
rg -Fq 'publisher.from_module<PACKAGE_MARKER>()' "$sources/package_admin.move" \
  || fail "custody must validate the canonical DEX Publisher"
rg -Fq 'upgrade_custody::new<PACKAGE_MARKER>(id.to_inner(), publisher, upgrade_cap)' \
  "$sources/package_admin.move" \
  || fail "custody must seal both capabilities through the shared constructor"
rg -q '^public fun commit_upgrade_and_advance\(' "$sources/package_admin.move" \
  || fail "the DEX must expose one atomic commit-and-advance finalizer"
if rg -n '^public fun commit_upgrade\(|^public fun activate' "$sources/package_admin.move"; then
  fail "a separate receipt commit or activation entry point is forbidden"
fi
rg -Fq 'factory.assert_next();' "$sources/package_admin.move" \
  || fail "the finalizer must prove the exact next generation before committing"
rg -Fq 'factory.advance();' "$sources/package_admin.move" \
  || fail "the finalizer must advance the generation in the same transaction"
current_guards="$(rg -c 'factory\.assert_current\(\);' <<<"$package_admin_production" || true)"
[[ "${current_guards:-0}" -eq 4 ]] \
  || fail "every non-finalizer custody transition must check the current generation first"
custody_role_assertions="$(rg -c \
  'admin_witness\.assert_role\(dex_domain::package_admin_role\(\)\);' \
  <<<"$package_admin_production" || true)"
[[ "${custody_role_assertions:-0}" -eq 5 ]] \
  || fail "every governed custody transition must assert the DEX package-admin role"
if rg -U -n '^public fun [^(]+\([^)]*\): (&)?(Publisher|UpgradeCap)' \
  "$sources/package_admin.move"; then
  fail "no custody path may release the sealed Publisher or UpgradeCap"
fi
if rg -n 'transfer::(public_)?transfer\(' "$sources/package_admin.move"; then
  fail "the framework UpgradeCap must never be address-owned"
fi
if rg -n '\bpackage::(version|only_(additive|dep)_upgrades|make_immutable)\(' \
  <<<"$package_admin_production"; then
  fail "native upgrade transitions belong to blast_admin, not to this package"
fi

# --- Economics stay where they are ---

rg -q '^const MAX_FEE_BPS: u64 = 500;$' "$sources/pool.move" \
  || fail "the pool fee ceiling must not move"
rg -q '^const MAX_BURN_BPS: u64 = 500;$' "$sources/pool.move" \
  || fail "the burn ceiling must not move"
rg -q '^const MINIMUM_SHARES: u128 = 1_000;$' "$sources/pool.move" \
  || fail "the minimum share floor must not move"
if rg -n 'sui::event::emit|event::emit' "$sources/package_admin.move" \
  "$sources/dex_domain.move" "$sources/package_marker.move"; then
  fail "administration replay facts must come from blast_admin"
fi

printf 'DEX source boundaries passed\n'
