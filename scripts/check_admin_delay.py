#!/usr/bin/env python3
"""Check the ADR 0134 authority, storage and pause boundaries against production functions."""
from pathlib import Path
import re
import subprocess

ROOT = Path(__file__).resolve().parents[1]
READER = ROOT / 'sui/launchpad/scripts/move_facts.awk'


def module_path(package, module):
    """The one source file declaring `module`, at any depth under the package's sources."""
    paths = list((ROOT / 'sui' / package / 'sources').rglob(f'{module}.move'))
    assert len(paths) == 1, (package, module, paths)
    return paths[0]


def facts(package, module):
    path = module_path(package, module)
    rows = subprocess.check_output(['awk', '-f', str(READER), str(path)], text=True).splitlines()
    assert not any(row.startswith('MALFORMED') for row in rows), path
    return [row.split('\t') for row in rows]


def functions(package, module):
    return {row[1]: (row[8], row[9]) for row in facts(package, module)
            if row[0] == 'FN' and row[5] == '0'}


def require(text, *parts):
    for part in parts:
        assert part in text, f'missing {part}'


def governed(package, module, fields, version='package_version', shared_delay=(), current='();'):
    """Fields in `shared_delay` wait a delay shared with other entries, so their schedules
    take no delay of their own; the shared delay is governed as `<field>_delay`."""
    fs = functions(package, module)
    for field, role in fields.items():
        for phase in ('schedule', 'apply', 'cancel'):
            name = f'{phase}_{field}'
            signature, body = fs[name]
            assert body.startswith(f'{version}.assert_current{current}'), (package, module, name)
            if phase == 'apply':
                assert 'AdminWitness' not in signature, (module, name)
                require(signature, 'clock: &Clock')
                assert re.search(r'\.apply\([^;]*clock\);', body), (module, name)
            else:
                require(signature, f'&AdminWitness<{role if phase == "schedule" else "CancelAdmin"}>')
                if phase == 'schedule':
                    require(signature, 'clock: &Clock')
                    if field in shared_delay:
                        assert 'delay_ms: u64' not in signature, (module, name)
                    else:
                        require(signature, 'delay_ms: u64')
                require(body, '.schedule(' if phase == 'schedule' else '.cancel(')
        assert f'set_{field}' not in fs, (module, field)


# The launchpad runs on the generic package administration: its version check names its compiled
# version, and Blast's fees go to the core treasury, so it governs no destination of its own.
LAUNCHPAD_CURRENT = '(constants::version!());'
governed('launchpad', 'runtime_config', {'protocol_fee_share': 'FeeAdmin'}, current=LAUNCHPAD_CURRENT)
governed('launchpad', 'launch_config', {'creation_fee': 'FeeAdmin', 'trade_fees': 'FeeAdmin', 'protocol_allocation': 'TreasuryAdmin', 'protocol_lp_fees': 'FeeAdmin'}, current=LAUNCHPAD_CURRENT)
assert 'treasury' not in functions('launchpad', 'runtime_config') and 'schedule_treasury' not in functions('launchpad', 'runtime_config')
for name in ('package_admin', 'blast_fun_domain', 'fees', 'blast_events'):
    assert not list((ROOT / 'sui/launchpad/sources').rglob(f'{name}.move')), name
otw_source = (ROOT / 'sui/launchpad/sources/blast_fun.move').read_text()
require(otw_source, 'public struct BLAST_FUN() has drop;', 'public struct PackageWitness() has drop;',
        'package_version::new_publication<_, PackageWitness>(otw, constants::valid_pause_bits!(), ctx)')
otw_fs = functions('launchpad', 'blast_fun')
assert set(otw_fs) == {'init', 'package_witness'}, otw_fs
assert otw_fs['package_witness'][1] == 'PackageWitness()', otw_fs['package_witness']
# The package witness is constructed only by its module; no launchpad function stores it, takes it,
# or returns it except the package-only constructor.
for path in (ROOT / 'sui/launchpad/sources').rglob('*.move'):
    for name, (signature, _) in functions('launchpad', path.stem).items():
        assert 'PackageWitness' not in signature or (path.stem, name) == ('blast_fun', 'package_witness'), (path, name)
# Only the launchpad's unpause clears bits, after checking every launchpad delay.
callers = [(path, name) for path in (ROOT / 'sui/launchpad/sources').rglob('*.move')
           for name, (_, body) in functions('launchpad', path.stem).items()
           if 'clear_pause_bits(' in body]
assert [(path.stem, name) for path, name in callers] == [('launch_config', 'unpause')], callers
signature, body = functions('launchpad', 'launch_config')['unpause']
assert signature.split('(', 1)[1].replace(' ', '').replace('\n', '') == (
    'self:&LaunchConfig,package_version:&mutPackageVersion<BLAST_FUN>,'
    'unpause_admin:&AdminWitness<UnpauseAdmin<BLAST_FUN>>,package_admin:&PackageAdmin<BLAST_FUN>,'
    'runtime_config:&RuntimeConfig,treasury:&Treasury,bits:u8,)'
), signature
assert body.startswith(f'package_version.assert_current{LAUNCHPAD_CURRENT}'), body
assert body.index('self.is_guarded() && runtime_config.is_guarded() && treasury.is_guarded()') < body.index('clear_pause_bits('), body
require(body, 'package_admin.clear_pause_bits(unpause_admin, package_witness(), package_version, bits)')
# The presale runs on the generic package administration too, and pays Blast's fees to the core
# treasury, so it governs no destination of its own.
PRESALE_CURRENT = '(constants::version!());'
governed('presale', 'fee_policy', {'fees': 'FeeAdmin'}, current=PRESALE_CURRENT)
assert not any('destination' in name for name in functions('presale', 'fee_policy'))
for name in ('package_admin', 'blast_presale_domain', 'cetus', 'bluefin', 'aftermath', 'venue_config', 'migration_math'):
    assert not list((ROOT / 'sui/presale/sources').rglob(f'{name}.move')), name
presale_otw_source = (ROOT / 'sui/presale/sources/blast_presale_package.move').read_text()
require(presale_otw_source, 'public struct BLAST_PRESALE_PACKAGE() has drop;', 'public struct PackageWitness() has drop;',
        'package_version::new_publication<_, PackageWitness>(otw, constants::valid_pause_bits!(), ctx)')
presale_otw_fs = functions('presale', 'blast_presale_package')
assert set(presale_otw_fs) == {'init', 'package_witness'}, presale_otw_fs
assert presale_otw_fs['package_witness'][1] == 'PackageWitness()', presale_otw_fs['package_witness']
for path in (ROOT / 'sui/presale/sources').rglob('*.move'):
    for name, (signature, _) in functions('presale', path.stem).items():
        assert 'PackageWitness' not in signature or (path.stem, name) == ('blast_presale_package', 'package_witness'), (path, name)
# Only the presale's unpause clears bits, after checking every presale delay.
presale_callers = [(path.stem, name) for path in (ROOT / 'sui/presale/sources').rglob('*.move')
                   for name, (_, body) in functions('presale', path.stem).items() if 'clear_pause_bits(' in body]
assert presale_callers == [('creation_policy', 'unpause')], presale_callers
signature, body = functions('presale', 'creation_policy')['unpause']
assert signature.split('(', 1)[1].replace(' ', '').replace('\n', '') == (
    'self:&CreationPolicy,package_version:&mutPackageVersion<BLAST_PRESALE_PACKAGE>,'
    'unpause_admin:&AdminWitness<UnpauseAdmin<BLAST_PRESALE_PACKAGE>>,'
    'package_admin:&PackageAdmin<BLAST_PRESALE_PACKAGE>,fee_policy:&FeePolicy,treasury:&Treasury,bits:u8,)'
), signature
assert body.startswith(f'package_version.assert_current{PRESALE_CURRENT}'), body
assert body.index('self.is_guarded() && fee_policy.is_guarded() && treasury.is_guarded()') < body.index('clear_pause_bits('), body
require(body, 'package_admin.clear_pause_bits(unpause_admin, package_witness(), package_version, bits)')
for path in (ROOT / 'sui/presale/sources').rglob('*.move'):
    production = path.read_text().split('// === Test-Only Functions ===')[0]
    assert 'Bootstrap' not in production and 'set_now' not in production, path
    if path.stem != 'blast_presale_package':
        assert not re.search(r'\bPublication\b', production), path
    for name, (signature, body) in functions('presale', path.stem).items():
        if not re.search(r'\.schedule(_add|_value)?\(', body):
            continue
        require(signature, 'clock: &Clock')
        if name == 'schedule_venue':
            assert 'delay_ms: u64' not in signature, (path, name)
        else:
            require(signature, 'delay_ms: u64')
        assert 'new_pending' not in body and 'take_ready' not in body, (path, name)

for package, module in [('launchpad', 'launch_config'), ('presale', 'creation_policy')]:
    fs = functions(package, module)
    source = module_path(package, module).read_text()
    require(source, 'venues: DelayedSet<VenueKey, TypeName>,')
    assert 'migration_witness' not in source and 'pending_venue' not in source, package
    require(fs['schedule_venue'][0], '&AdminWitness<VenueAdmin>', 'clock: &Clock')
    assert 'delay_ms: u64' not in fs['schedule_venue'][0], package
    body = fs['schedule_venue'][1]
    require(body, 'venue.is_primitive()', 'origin != @0x1 && origin != @0x2', 'self.venues.schedule_add(venue, clock)')
    assert body.index('origin != @0x1') < body.index('schedule_add'), package
    require(fs['apply_venue'][1], 'self.venues.apply_add(')
    assert 'AdminWitness' not in fs['apply_venue'][0]
    require(fs['cancel_venue'][0], '&AdminWitness<CancelAdmin>')
    require(fs['cancel_venue'][1], 'self.venues.cancel_add(')
    require(fs['remove_venue'][0], '&AdminWitness<VenueAdmin>')
    require(fs['remove_venue'][1], 'self.venues.remove(')
    require(fs['schedule_venue_delay'][0], '&AdminWitness<VenueAdmin>', 'delay_ms: u64', 'clock: &Clock')
    require(fs['schedule_venue_delay'][1], 'self.venues.schedule_delay(delay_ms, clock)')
    require(fs['apply_venue_delay'][1], 'self.venues.apply_delay(clock)')
    assert 'AdminWitness' not in fs['apply_venue_delay'][0]
    require(fs['cancel_venue_delay'][0], '&AdminWitness<CancelAdmin>')
    assert 'set_venue_allowed' not in fs

fs = functions('launchpad', 'launch')
source = (ROOT / 'sui/launchpad/sources/launch/launch.move').read_text()
assert 'apply_cap_reassignment_delay' not in fs and '_delay_ms: u64,' not in source.split('public struct Launch<')[1].split('\n}')[0]
for cap in ['curve_fee_cap', 'creator_metadata_cap']:
    require(fs[f'schedule_{cap}_reassignment'][0], '&AdminWitness<CreatorAdmin>', 'clock: &Clock')
    assert 'delay_ms: u64' not in fs[f'schedule_{cap}_reassignment'][0], cap
    require(fs[f'schedule_{cap}_reassignment'][1], f'.schedule(recipient, clock)')
    require(fs[f'cancel_{cap}_reassignment'][0], '&AdminWitness<CancelAdmin>')
    require(fs[f'cancel_{cap}_reassignment'][1], '.cancel()')
    require(fs[f'schedule_{cap}_delay'][0], '&AdminWitness<CreatorAdmin>', 'delay_ms: u64', 'clock: &Clock')
    require(fs[f'schedule_{cap}_delay'][1], '.schedule_delay(delay_ms, clock)')
    require(fs[f'apply_{cap}_reassignment'][1], '.take_action(clock)')
    require(fs[f'apply_{cap}_delay'][1], '.apply_delay(clock)')
    for phase in ('reassignment', 'delay'):
        assert 'AdminWitness' not in fs[f'apply_{cap}_{phase}'][0], (cap, phase)

for package, module, current, actions in [
    ('launchpad', 'launch', LAUNCHPAD_CURRENT, {
        'new': 'constants::create_pause_bit!()',
        'finalize': 'constants::create_pause_bit!()',
        'share': 'constants::create_pause_bit!()',
        'buy': 'constants::trading_pause_bit!()',
        'join_opening_round': 'constants::trading_pause_bit!()',
        'settle_opening_round': 'constants::trading_pause_bit!()',
        'sell': 'constants::trading_pause_bit!()',
        'migrate': 'constants::migration_pause_bit!()',
    }),
    ('presale', 'blast_presale', PRESALE_CURRENT, {
        'new': 'constants::create_pause_bit!()',
        'share': 'constants::create_pause_bit!()',
        'commit_open': 'constants::commit_pause_bit!()',
        'commit_allowlisted': 'constants::commit_pause_bit!()',
        'commit_uncapped': 'constants::commit_pause_bit!()',
        'migrate': 'constants::migration_pause_bit!()',
    }),
]:
    fs = functions(package, module)
    for name, bit in actions.items():
        body = fs[name][1]
        assert body.startswith(f'package_version.assert_current{current} package_version.assert_not_paused({bit});'), (package, name)
    for name, (_, body) in fs.items():
        if name not in actions: assert 'assert_not_paused' not in body, (package, name)

# The generic package administration every upgradeable package shares: role-gated, waits the
# package's own upgrade delay, and keeps the native capabilities sealed.
generic = functions('admin', 'package_admin')
generic_source = (ROOT / 'sui/admin/sources/package/package_admin.move').read_text()
require(generic_source, 'upgrade: DelayedAction<UpgradeKey<OTW>, UpgradeAction>,',
        'upgrade_cap: Option<UpgradeCap>,', 'const INITIAL_UPGRADE_DELAY_MS: u64 = 48 * 60 * 60 * 1_000;')
for name in ('schedule_upgrade', 'schedule_make_immutable', 'authorize_upgrade', 'make_immutable', 'schedule_upgrade_delay'):
    require(generic[name][0], '&AdminWitness<UpgradeAdmin<OTW>>', 'clock: &Clock')
for name in ('schedule_upgrade', 'schedule_make_immutable'):
    assert 'delay_ms: u64' not in generic[name][0], name
    assert generic[name][1].startswith('assert!(self.upgrade_cap.is_some(), blast_admin::errors::upgrade_cap_unavailable!());'), name
require(generic['schedule_upgrade'][1], 'digest.length() == PACKAGE_DIGEST_LENGTH', 'self.upgrade.schedule(UpgradeAction::Upgrade(digest), clock)')
require(generic['schedule_make_immutable'][1], 'self.upgrade.schedule(UpgradeAction::MakeImmutable, clock)')
for name, action, effect in [('authorize_upgrade', 'Upgrade(digest)', 'upgrade_cap.authorize(policy, digest)'),
                             ('make_immutable', 'MakeImmutable', 'package::make_immutable(upgrade_cap)')]:
    body = generic[name][1]
    require(body, 'let action = self.upgrade.take_action(clock);')
    assert body.index('self.upgrade.take_action(clock)') < body.index(f'action == UpgradeAction::{action}') < body.index(effect), name
# Only the package's own code, with its pinned package witness, ends its upgrades; checked first.
require(generic['make_immutable'][0], '_: PackageWitness', 'package_version: &PackageVersion<OTW>')
assert generic['make_immutable'][1].startswith('package_version.assert_package_witness<_, PackageWitness>();')
# The vault (immutable after audit, #195) wraps it on its live version only; the upgradeable
# products add a wrapper only in a later upgrade if they ever need one.
signature, body = functions('vault', 'blast_vault_package')['make_immutable']
require(signature, '&AdminWitness<UpgradeAdmin<BLAST_VAULT_PACKAGE>>', 'package_version: &PackageVersion<BLAST_VAULT_PACKAGE>')
assert body.startswith('package_version.assert_current(constants::version!());'), body
require(body, 'package_admin.make_immutable(upgrade_admin, PackageWitness(), package_version, clock)')
# The vault's unpause runs on its live version only and, like the products', refuses while its
# own admission delay or the core treasury's delay is unguarded.
vault_callers = [(path.stem, name) for path in (ROOT / 'sui/vault/sources').rglob('*.move')
                 for name, (_, body) in functions('vault', path.stem).items() if 'clear_pause_bits(' in body]
assert vault_callers == [('blast_vault_package', 'unpause')], vault_callers
signature, body = functions('vault', 'blast_vault_package')['unpause']
assert signature.split('(', 1)[1].replace(' ', '').replace('\n', '') == (
    'self:&VaultRegistry,unpause_admin:&AdminWitness<UnpauseAdmin<BLAST_VAULT_PACKAGE>>,'
    'package_admin:&PackageAdmin<BLAST_VAULT_PACKAGE>,package_version:&mutPackageVersion<BLAST_VAULT_PACKAGE>,'
    'treasury:&Treasury,bits:u8,)'
), signature
assert body.startswith('package_version.assert_current(constants::version!());'), body
assert body.index('self.witnesses.is_guarded() && treasury.is_guarded()') < body.index('clear_pause_bits('), body
require(body, 'package_admin.clear_pause_bits(unpause_admin, PackageWitness(), package_version, bits)')
for package in ('launchpad', 'presale', 'migrators'):
    for path in (ROOT / 'sui' / package / 'sources').rglob('*.move'):
        assert '.make_immutable(' not in path.read_text(), path
require(generic['cancel_upgrade_action'][0], '&AdminWitness<CancelAdmin<OTW>>')
require(generic['cancel_upgrade_action'][1], 'self.upgrade.cancel()')
require(generic['schedule_upgrade_delay'][1], 'self.upgrade.schedule_delay(delay_ms, clock)')
require(generic['apply_upgrade_delay'][1], 'self.upgrade.apply_delay(clock)')
assert 'AdminWitness' not in generic['apply_upgrade_delay'][0]
commit = generic['commit_upgrade_and_advance']
require(commit[0], '&AdminWitness<UpgradeAdmin<OTW>>', 'package_version: &mut PackageVersion<OTW>')
assert commit[1].index('upgrade_cap.commit(receipt);') < commit[1].index('package_version.advance();')
require(generic['pause'][0], '&AdminWitness<PauseAdmin<OTW>>')
require(generic['clear_pause_bits'][0], '&AdminWitness<UnpauseAdmin<OTW>>', '_: PackageWitness')
# Only the package itself, holding its pinned package witness, borrows its Publisher, by reference.
require(generic['publisher'][0], 'self: &PackageAdmin<OTW>', '_: PackageWitness',
        'package_version: &PackageVersion<OTW>', '): &Publisher')
require(generic['publisher_mut'][0], 'self: &mut PackageAdmin<OTW>', '_: PackageWitness',
        'package_version: &PackageVersion<OTW>', '): &mut Publisher')
for name in ('publisher', 'publisher_mut'):
    assert generic[name][1].startswith('package_version.assert_package_witness<_, PackageWitness>();'), name
clear = generic['clear_pause_bits'][1]
assert clear.index('assert_unpause_witness') < clear.index('self.upgrade.is_guarded()') < clear.index('package_version.clear_pause_bits(bits)')
require(generic['wrap'][0], 'publication: Publication<OTW>', 'upgrade_cap: UpgradeCap')
require(generic['new'][1], 'delayed_action::new(UpgradeKey<OTW>(), &id, INITIAL_UPGRADE_DELAY_MS)')
assert {name for name, (_, body) in generic.items() if 'PackageAdmin {' in body} == {'new'}
assert not any(re.search(r'\):\s*(Publisher|UpgradeCap|&\s*(mut\s+)?UpgradeCap)', signature) for signature, _ in generic.values())
assert {name for name, (signature, _) in generic.items() if re.search(r'\):\s*&\s*mut\s+Publisher', signature)} == {'publisher_mut'}
assert {name for name, (signature, _) in generic.items() if re.search(r'\):\s*&Publisher', signature)} == {'publisher'}
assert not any(word in generic_source for word in ('only_additive_upgrades', 'only_dep_upgrades', 'restrict_to'))

acl = (ROOT / 'sui/admin/sources/blast_acl.move').read_text()
require(acl, 'admins: Table<ID, VecSet<TypeName>>,', 'super_admin_transfer: DelayedAction<SuperAdminTransfer, address>,')
assert 'MAX_ADMINS' not in acl and 'Timelocked' not in acl
print('ADR 0134 administration boundaries: OK')

# Publication proves unique native custody intake; it never authorizes policy changes.
for package, otw_module in [('launchpad', 'blast_fun')]:
    otw_fs = functions(package, otw_module)
    source = module_path(package, otw_module).read_text()
    assert 'admin_delay' not in source
    # The generic `package_version::new_publication` claims the Publisher and seeds the version.
    require(otw_fs['init'][1], '.keep(ctx)')
    assert 'share_object' not in otw_fs['init'][1] and 'public struct Publication' not in source
    assert otw_fs['init'][0].startswith('fun init(')
    for path in (ROOT / 'sui' / package / 'sources').rglob('*.move'):
        production = path.read_text().split('// === Test-Only Functions ===')[0]
        assert 'Bootstrap' not in production, path
        assert 'set_now' not in production, path
        if path.stem not in (otw_module, 'package_admin'):
            assert not re.search(r'\bPublication\b', production), path
        for name, (signature, body) in functions(package, path.stem).items():
            if not re.search(r'\.schedule(_add|_value)?\(', body):
                continue
                continue
            require(signature, 'clock: &Clock')
            action_only = (
                path.stem == 'package_admin' and name in ('schedule_upgrade', 'schedule_make_immutable')
                or path.stem in ('launch_config', 'creation_policy') and name == 'schedule_venue'
                or package == 'launchpad' and path.stem == 'runtime_config'
                and name == 'schedule_creator_claim_signer'
                or package == 'launchpad' and path.stem == 'launch'
                and name in ('schedule_curve_fee_cap_reassignment', 'schedule_creator_metadata_cap_reassignment')
            )
            if action_only:
                assert 'delay_ms: u64' not in signature, (path, name)
            else:
                require(signature, 'delay_ms: u64')
            assert 'admin_delay_ms()' not in body, (path, name)
            assert 'new_pending' not in body and 'take_ready' not in body, (path, name)

primitive = functions('admin', 'delayed')
assert not any(name.startswith(('set_', 'force', 'bypass')) for name in primitive)
assert 'new_pending' not in primitive and 'take_ready' not in primitive
require(primitive['ready_at_ms_after'][1], 'clock.timestamp_ms().checked_add(applied_delay_ms)', '.destroy_or!(abort blast_admin::errors::invalid_delay!())', 'ready_at_ms.checked_add(next_delay_ms).is_some()')
require(primitive['assert_ready_at'][1], 'clock.timestamp_ms() >= ready_at_ms', 'clock.timestamp_ms().checked_add(next_delay_ms).is_some()')
require(primitive['schedule'][1], 'ready_at_ms_after(self.delay_ms, delay_ms, clock)')
require(functions('admin', 'delayed_set')['schedule_add'][1], 'delayed::ready_at_ms_after(self.delay_ms, 0, clock)')
require(functions('admin', 'delayed_map')['schedule'][1], 'delayed::ready_at_ms_after(self.delay_ms, 0, clock)')
for module in ('delayed_action', 'delayed_set', 'delayed_map'):
    assert not any(name.startswith(('set_', 'force', 'bypass')) for name in functions('admin', module)), module
require(primitive['apply'][1], 'self.assert_ready(clock)', 'self.value = value;', 'self.delay_ms = delay_ms;')
for name in ('schedule_value', 'schedule_delay'):
    require(primitive[name][1], 'self.schedule(value, delay_ms, clock)')

# Creator-controlled migrated-vault policy follows the same delayed value invariant,
# but its authority is the operation-specific live creator cap rather than an admin role.
require(primitive['assert_ready'][0], 'self: &Delayed<K, T>', 'clock: &Clock')
require(primitive['assert_ready'][1], 'self.pending.is_some()', 'errors::no_pending!()', 'assert_ready_at(')
assert 'self.pending =' not in primitive['assert_ready'][1]
# The vault's fee split waits its fixed delay under an owner proof the sale's product issues; each
# venue settles accrued fees under the current split before applying the next.
fs = functions('vault', 'vault')
require(module_path('vault', 'vault').read_text(), 'fee_split: Delayed<FeeSplitKey, FeeSplit>,')
for name in ('schedule_fee_split', 'cancel_fee_split'):
    signature, body = fs[name]
    assert body.startswith('package_version.assert_current(constants::version!()); proof.assert_terms(&self.terms);'), name
    require(signature, 'proof: OwnerProof')
    assert 'AdminWitness' not in signature and 'delay_ms' not in signature, name
require(fs['schedule_fee_split'][1], 'self.fee_split.schedule_value(proposed, clock)')
require(fs['cancel_fee_split'][1], 'self.fee_split.cancel()')
require(fs['assert_fee_split_ready'][1], 'self.fee_split.assert_ready(clock)')
require(fs['apply_fee_split'][0], '_: &Venue')
require(fs['apply_fee_split'][1], 'self.assert_position<_, _, Venue>()', 'self.fee_split.apply(clock)')
for package, venue, settlement in (
    ('migrators', 'bluefin', 'self.settle_fees('), ('migrators', 'cetus', 'self.settle_fees('),
):
    signature, body = functions(package, venue)['settle_and_apply_fee_split']
    assert 'FeeSplit' not in signature and 'Cap' not in signature, (package, venue)
    assert body.index('.assert_fee_split_ready(clock)') < body.index(settlement) < body.index(
        '.apply_fee_split(&Venue(), vault_version, clock)'), (package, venue)

# Holder-reward rounds publish only from each vault's delayed action slot: RewardsAdmin schedules
# checked terms and the delay, CancelAdmin cancels either kind, and anyone publishes a ready round
# or applies a ready delay. The vault never lends the slot, and publication re-checks the terms.
package, module, rewards, version = 'vault', 'vault', 'holder_rewards', 'package_version'
error = lambda name: 'blast_vault::errors::' + re.sub(r'(?<!^)(?=[A-Z])', '_', name[1:]).lower() + '!()'
current = 'package_version.assert_current(constants::version!());'
if True:
    source = module_path(package, module).read_text()
    require(source, 'round_publication: DelayedAction<RoundPublicationKey, RoundTerms>,',
            'public struct RoundPublicationKey() has copy, drop, store;', 'constants::round_delay_ms!(),')
    slot = functions(package, module)
    require(slot['schedule_round_publication'][1], 'self.round_publication.schedule(terms, clock)')
    require(slot['take_round_publication'][1], 'self.round_publication.take_action(clock)')
    require(slot['schedule_round_publication_delay'][1], 'self.round_publication.schedule_delay(delay_ms, clock)')
    require(slot['apply_round_publication_delay'][1], 'self.round_publication.apply_delay(clock)')
    for name, kind in (('cancel_round_publication', 'is_some'), ('cancel_round_publication_delay', 'is_none')):
        body = slot[name][1]
        require(body, f'proposal.proposal_value().action().{kind}()', error('EWrongRoundProposal'), 'self.round_publication.cancel()')
        assert body.index(error('EWrongRoundProposal')) < body.index('self.round_publication.cancel()'), name
    require(slot['new_round_terms'][1], error('EInvalidCommitment'), error('EInvalidLeafCount'), error('EEmptyBudget'),
            'start_checkpoint < end_checkpoint', 'quote_amount.checked_add(gas_reserve_amount).is_some()',
            'expected_treasury != @0x0', 'claim_window_duration_ms > 0')
    visibility = {row[1]: row[2] for row in facts(package, module) if row[0] == 'FN' and row[5] == '0'}
    for name in ('new_round_terms', 'schedule_round_publication', 'take_round_publication', 'cancel_round_publication',
                 'schedule_round_publication_delay', 'apply_round_publication_delay', 'cancel_round_publication_delay'):
        assert visibility[name] == 'package', name
    for name, (signature, body) in slot.items():
        assert 'DelayedAction' not in signature and '&mut self.round_publication' not in body, name
    flows = functions(package, rewards)
    roles = {'schedule_round': 'RewardsAdmin', 'schedule_round_delay': 'RewardsAdmin',
             'cancel_round': 'CancelAdmin', 'cancel_round_delay': 'CancelAdmin'}
    for name in ('schedule_round', 'publish_round', 'cancel_round', 'schedule_round_delay', 'apply_round_delay', 'cancel_round_delay'):
        signature, body = flows[name]
        assert body.startswith(current), name
        if name in roles:
            require(signature, f'&AdminWitness<{roles[name]}>')
        else:
            assert 'AdminWitness' not in signature, name
    signature, body = flows['schedule_round']
    require(signature, 'claim_window_duration_ms: u64', 'expected_treasury: address', 'clock: &Clock')
    assert 'delay_ms: u64,' not in signature.replace('claim_window_duration_ms: u64,', '')
    steps = [f'{module}::new_round_terms(', 'assert_fundable(vault, &terms);', 'vault.schedule_round_publication(terms, clock);']
    require(body, *steps)
    assert [body.index(step) for step in steps] == sorted(body.index(step) for step in steps)
    signature, body = flows['publish_round']
    assert not re.search(r'\b(u64|address|vector<u8>)\b', signature), signature
    steps = ['vault.take_round_publication(clock);', 'treasury.destination();', '== terms.expected_treasury(),',
             error('ETreasuryChanged'), 'assert_fundable(vault, &terms);', '.checked_add(terms.claim_window_duration_ms())',
             'vault.fund_round(']
    require(body, *steps)
    assert [body.index(step) for step in steps] == sorted(body.index(step) for step in steps)
    require(flows['cancel_round'][1], 'vault.cancel_round_publication()')
    require(flows['schedule_round_delay'][1], 'vault.schedule_round_publication_delay(delay_ms, clock)')
    require(flows['apply_round_delay'][1], 'vault.apply_round_publication_delay(clock)')
    require(flows['cancel_round_delay'][1], 'vault.cancel_round_publication_delay()')
    assert not any('fund_round(' in body for name, (_, body) in flows.items() if name != 'publish_round')

# Signer admission waits the set's delay and is capped; revocation stays immediate.
signer = functions('launchpad', 'runtime_config')
require((ROOT / 'sui/launchpad/sources/config/runtime_config.move').read_text(),
        'creator_claim_signers: DelayedSet<ClaimSignerKey, vector<u8>>,')
for name in signer:
    if name.endswith(('_creator_claim_signer', '_creator_claim_signer_delay')):
        assert signer[name][1].startswith(f'package_version.assert_current{LAUNCHPAD_CURRENT}'), name
schedule_signature, schedule_body = signer['schedule_creator_claim_signer']
require(schedule_signature, '&AdminWitness<ClaimSignerAdmin>', 'clock: &Clock')
assert 'delay_ms: u64' not in schedule_signature
require(schedule_body, 'constants::ed25519_public_key_length!()',
        'signers.members().length() + signers.pending_count() - replaced',
        '< constants::max_claim_signers!()', 'blast_fun::errors::too_many_claim_signers!()',
        'self.creator_claim_signers.schedule_add(signer_public_key, clock)')
assert schedule_body.index('max_claim_signers') < schedule_body.index('schedule_add')
require(signer['apply_creator_claim_signer'][1], 'self.creator_claim_signers.apply_add(')
require(signer['apply_creator_claim_signer'][0], 'clock: &Clock')
require(signer['cancel_creator_claim_signer'][0], '&AdminWitness<CancelAdmin>')
require(signer['cancel_creator_claim_signer'][1], 'self.creator_claim_signers.cancel_add(')
require(signer['revoke_creator_claim_signer'][0], '&AdminWitness<ClaimSignerAdmin>')
require(signer['revoke_creator_claim_signer'][1], 'self.creator_claim_signers.remove(')
assert 'clock' not in signer['revoke_creator_claim_signer'][0]
require(signer['schedule_creator_claim_signer_delay'][0], '&AdminWitness<ClaimSignerAdmin>', 'delay_ms: u64', 'clock: &Clock')
require(signer['schedule_creator_claim_signer_delay'][1], 'self.creator_claim_signers.schedule_delay(delay_ms, clock)')
require(signer['apply_creator_claim_signer_delay'][1], 'self.creator_claim_signers.apply_delay(clock)')
require(signer['cancel_creator_claim_signer_delay'][0], '&AdminWitness<CancelAdmin>')
require(signer['cancel_creator_claim_signer_delay'][1], 'self.creator_claim_signers.cancel_delay()')
for name in ('apply_creator_claim_signer', 'apply_creator_claim_signer_delay'):
    assert 'AdminWitness' not in signer[name][0], name
assert 'set_creator_claim_signer' not in signer
# The migrators adopt blast_admin's generic administration: the publication defines no pause bits
# and pins a package witness nothing constructs, no local custody or version copy exists, and
# every public venue route checks this package's compiled version before anything else.
migrators_sources = ROOT / 'sui/migrators/sources'
assert not (migrators_sources / 'package_admin.move').exists()
otw_fs = functions('migrators', 'blast_migrators')
assert set(otw_fs) == {'init'}, set(otw_fs)
assert otw_fs['init'][1] == 'package_version::new_publication<_, PackageWitness>(otw, 0, ctx).keep(ctx);', otw_fs['init'][1]
for path in migrators_sources.rglob('*.move'):
    production = path.read_text().split('// === Test-Only Functions ===')[0]
    assert not re.search(r'\b(OperationalVersion|UpgradeCustody|DelayedAction|operational_version|upgrade_custody)\b', production), path
    assert 'PackageWitness()' not in production.replace('public struct PackageWitness() has drop;', ''), path
for venue in ('bluefin', 'cetus'):
    routes = [row for row in facts('migrators', venue) if row[0] == 'FN' and row[2] == 'public' and row[5] == '0']
    assert sorted(row[1] for row in routes) == [
        'buyback_and_burn', 'collect_fees', 'compound_auto_lp', 'migrate', 'prepare', 'settle_and_apply_fee_split',
    ], (venue, routes)
    for row in routes:
        require(row[8], 'migrators_version: &PackageVersion<BLAST_MIGRATORS>')
        assert row[9].startswith('migrators_version.assert_current(constants::version!());'), (venue, row[1])
print('Per-operation delays, no bypass, delayed signer admission, and publication custody: OK')

# Partner share and cap wait one fixed seven-day delay: PartnerAdmin proposes or cancels, anyone
# applies, payments read the applied share with no Clock, and nothing can change the delay.
partners_source = module_path('partners', 'blast_partners').read_text()
partners_production = partners_source.split('// === Test-Only Functions ===')[0]
require(partners_source, 'share_bps: Delayed<ShareKey, u64>,', 'cap_id: Delayed<CapKey, ID>,',
        'public struct ShareKey() has copy, drop, store;', 'public struct CapKey() has copy, drop, store;',
        'const PARTNER_CHANGE_DELAY_MS: u64 = 7 * 24 * 60 * 60 * 1_000;')
for forbidden in (r'\bschedule_delay\b', r'\.schedule\(', r'\bdelayed::schedule\b', r'\bapply_delay\b',
                  r'\bcancel_delay\b', r'\bTimelocked\b', r'\bblast_fun_timelock\b'):
    assert not re.search(forbidden, partners_production), ('blast_partners', forbidden)
assert 'timelock' not in (ROOT / 'sui/partners/Move.toml').read_text()
partner_fs = functions('partners', 'blast_partners')
require(partner_fs['new'][1], 'delayed::new(ShareKey(), &id, share_bps, PARTNER_CHANGE_DELAY_MS)',
        'delayed::new(CapKey(), &id, cap_id, PARTNER_CHANGE_DELAY_MS)')
for field, store in (('share', 'share_bps'), ('cap', 'cap_id')):
    signature, body = partner_fs[f'schedule_{field}']
    require(signature, '_: &AdminWitness<PartnerAdmin>', 'clock: &Clock')
    assert 'delay_ms' not in signature, field
    require(body, f'self.{store}.schedule_value(')
    signature, body = partner_fs[f'apply_{field}']
    assert 'AdminWitness' not in signature, field
    require(signature, 'clock: &Clock')
    require(body, f'self.{store}.apply(clock)')
    signature, body = partner_fs[f'cancel_{field}']
    require(signature, '_: &AdminWitness<PartnerAdmin>')
    require(body, f'self.{store}.cancel()')
for name in ('pay', 'set_recipient', 'register'):
    assert 'Clock' not in partner_fs[name][0], name
require(partner_fs['pay'][1], 'self.share_bps.value()')
require(partner_fs['set_recipient'][1], 'self.cap_id.value()')
assert not any(name.startswith('set_') and name != 'set_recipient' for name in partner_fs)
print('Partner fixed delay, permissionless application, and Clock-free payment: OK')
