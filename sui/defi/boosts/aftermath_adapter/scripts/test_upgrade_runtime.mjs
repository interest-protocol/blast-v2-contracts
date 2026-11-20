#!/usr/bin/env node
// Run under the workspace heavy-job guard against a disposable, task-owned localnet.
// Required: M3_LOCALNET_CONFIG (directory), M3_OUTPUT_DIR, M3_SDK_PATH (@mysten/sui 2.35.0).
// Stages complete first-party packages with the shared launchpad admin, treasury and partners.
// Rewrites the copied ACL root and shortens the upgrade delay to one second for local publication, disables
// copied interface initializers, and changes successor PACKAGE_VERSION constants.
import assert from 'node:assert/strict';
import { createHash } from 'node:crypto';
import { cpSync, mkdirSync, mkdtempSync, readFileSync, rmSync, writeFileSync } from 'node:fs';
import { dirname, join, resolve } from 'node:path';
import { fileURLToPath, pathToFileURL } from 'node:url';
import { spawnSync } from 'node:child_process';

const repo = resolve(dirname(fileURLToPath(import.meta.url)), '../../../../..');
const config = process.env.M3_LOCALNET_CONFIG;
const output = process.env.M3_OUTPUT_DIR;
const sdk = process.env.M3_SDK_PATH;
assert(config && output && sdk, 'Set the three required M3_* paths.');
const rpc = process.env.M3_RPC ?? 'http://127.0.0.1:52421';
assert.equal(new URL(rpc).hostname, '127.0.0.1', 'Only a disposable loopback localnet is supported.');
assert.equal(JSON.parse(readFileSync(join(sdk, 'package.json'))).version, '2.35.0');
mkdirSync(output, { recursive: true });
const load = (name) => import(pathToFileURL(join(sdk, 'dist', name, 'index.mjs')).href);
const { SuiJsonRpcClient } = await load('jsonRpc');
const { Ed25519Keypair } = await load('keypairs/ed25519');
const { Transaction } = await load('transactions');
// Generated localnet keys stay private and are never written into evidence.
const keystore = resolve(config, 'sui.keystore');
const key = Buffer.from(JSON.parse(readFileSync(keystore))[0], 'base64');
assert.equal(key[0], 0, 'Expected the local genesis Ed25519 key.');
const signer = Ed25519Keypair.fromSecretKey(key.subarray(1));
const address = signer.toSuiAddress();
const client = new SuiJsonRpcClient({ url: rpc, network: 'localnet' });
const pubfile = join(output, 'Published.toml');
const packageRoot = join(output, 'source');
const results = [];

function command(name, args) {
  const result = spawnSync(process.env.SUI ?? 'sui', args, {
    encoding: 'utf8', maxBuffer: 32 * 1024 * 1024,
    env: { ...process.env, TOKIO_WORKER_THREADS: '1', RAYON_NUM_THREADS: '1' },
  });
  writeFileSync(join(output, `${name}.stdout`), result.stdout ?? '');
  writeFileSync(join(output, `${name}.stderr`), result.stderr ?? '');
  assert.equal(result.status, 0, `${name}: see command logs`);
  return result.stdout;
}
function save(name, value) {
  writeFileSync(join(output, `${name}.json`), JSON.stringify(value, null, 2) + '\n');
}
function created(response, suffix) {
  const matches = response.objectChanges.filter((x) => x.type === 'created' && x.objectType.endsWith(suffix));
  assert.equal(matches.length, 1, suffix);
  return matches[0].objectId;
}
function published(response, module) {
  const matches = response.objectChanges.filter((x) => x.type === 'published' && x.modules.includes(module));
  assert.equal(matches.length, 1, module);
  return matches[0].packageId;
}
async function execute(name, tx, abort) {
  tx.setGasBudget(1_000_000_000);
  const response = await client.signAndExecuteTransaction({
    transaction: tx, signer,
    options: { showEffects: true, showEvents: true, showObjectChanges: true },
  });
  await client.waitForTransaction({ digest: response.digest });
  save(name, response);
  const status = response.effects.status;
  if (abort) {
    assert.equal(status.status, 'failure', name);
    assert.match(status.error, abort, name);
    assert.equal(response.events.length, 0, 'Aborted transitions emit no committed events.');
  } else {
    assert.deepEqual(status, { status: 'success' }, name);
  }
  results.push({ name, digest: response.digest, status });
  save('results', results);
  console.log(`${name}: ${status.status}`);
  return response;
}
async function fields(id) {
  const response = await client.getObject({ id, options: { showContent: true, showOwner: true } });
  assert(!response.error, JSON.stringify(response.error));
  return response.data.content.fields;
}
function event(response, suffix) {
  const events = response.events.filter((x) => x.type.includes(suffix));
  assert.equal(events.length, 1, suffix);
  return events[0].parsedJson;
}

const version = command('toolchain', ['--version']).trim();
assert.equal(version, 'sui 1.77.2-51d177ad7d65');
save('protocol-config', await client.getProtocolConfig());

// sui start can update the genesis wallet after RPC starts accepting requests.
// Give the CLI its own wallet with the rehearsal endpoint already active.
const wallet = mkdtempSync(join(config, 'm3-wallet-'));
process.once('exit', () => rmSync(wallet, { recursive: true, force: true }));
const walletConfig = join(wallet, 'client.yaml');
writeFileSync(walletConfig, JSON.stringify({
  keystore: { File: keystore },
  envs: [{ alias: 'localnet', rpc }],
  active_env: 'localnet',
  active_address: address,
}), { mode: 0o600 });
const cli = ['client', '--client.config', walletConfig];

// Keep the Boosts layout while excluding build products and deployment IDs.
for (const path of ['sui/defi/boosts/core', 'sui/defi/boosts/aftermath_adapter', 'sui/governance/admin',
  'sui/launch/core', 'sui/launch/partners', 'sui/utilities/vesting']) {
  cpSync(join(repo, path), join(packageRoot, path), {
    recursive: true,
    filter: (path) => !/(?:^|\/)(?:build|tests|scripts|node_modules|release|Published\.toml)(?:\/|$)/.test(path),
  });
}
const adminPath = join(packageRoot, 'sui/governance/admin');
const corePath = join(packageRoot, 'sui/defi/boosts/core');
const partnersPath = join(packageRoot, 'sui/launch/partners');
const adapterPath = join(packageRoot, 'sui/defi/boosts/aftermath_adapter');

// The Move tests cover the production 48-hour boundary. Shorten only this
// disposable validator fixture to exercise multiple native upgrades in one run.
const delayPath = join(adminPath, 'sources/package/package_admin.move');
const sharedSource = readFileSync(delayPath, 'utf8');
const productionDelay = 'const INITIAL_UPGRADE_DELAY_MS: u64 = 48 * 60 * 60 * 1_000;';
assert(sharedSource.includes(productionDelay));
writeFileSync(delayPath, sharedSource.replace(productionDelay, 'const INITIAL_UPGRADE_DELAY_MS: u64 = 1_000;'));

async function waitForNotice(startedAt) {
  const readyAt = BigInt(startedAt) + 1_000n;
  const deadline = Date.now() + 30_000;
  while (BigInt((await fields('0x6')).timestamp_ms) < readyAt) {
    assert(Date.now() < deadline, 'The disposable validator clock stopped advancing');
    await new Promise((resolve) => setTimeout(resolve, 250));
  }
}

// Upstream link stubs intentionally abort publication. Disable only their three
// initializers in the disposable copy; preserve all first-party logic and ABI.
for (const path of ['vendor/vendor/sources/init.move',
  'oracle-aggregator/oracle-aggregator/sources/utils/init.move',
  'iperps/perpetuals/sources/utils/init.move']) {
  const file = join(adapterPath, 'interfaces/aftermath', path);
  const source = readFileSync(file, 'utf8');
  const initializer = /fun init\(witness: INIT, ctx: &mut TxContext\) \{\s*abort 404\s*\}/;
  assert(initializer.test(source), `Unexpected interface initializer: ${path}`);
  writeFileSync(file, source.replace(initializer, 'fun init(_: INIT, _: &mut TxContext) {}'));
}
const adminManifest = join(adminPath, 'Move.toml');
writeFileSync(adminManifest, readFileSync(adminManifest, 'utf8').replace(/blast_acl_root = "[^"]+"/, `blast_acl_root = "${address}"`));
save('source-provenance', Object.fromEntries(['sources/config/package_admin.move', 'sources/blast_boosts_aftermath.move'].map((path) => {
  const source = readFileSync(join(repo, 'sui/defi/boosts/aftermath_adapter', path));
  assert.deepEqual(readFileSync(join(adapterPath, path)), source);
  return [path, createHash('sha256').update(source).digest('hex')];
})));
function publish(name, path) {
  const response = JSON.parse(command(name, [...cli, 'test-publish', path,
    '--build-env', 'mainnet', '--pubfile-path', pubfile, '--publish-unpublished-deps',
    '--gas-budget', '500000000', '--json']));
  assert.equal(response.effects.status.status, 'success', name);
  save(name, response);
  return response;
}
const adminPublish = publish('publish-admin', adminPath);
const admin = published(adminPublish, 'blast_acl');
const acl = created(adminPublish, '::blast_acl::ACL');
const root = created(adminPublish, '::blast_acl::SuperAdminCap');
publish('publish-core', corePath);
const partners = published(publish('publish-partners', partnersPath), 'blast_partners');
const launchCore = published(publish('publish-launch-core', join(packageRoot, 'sui/launch/core')), 'blast_domain');
const adapterPublish = publish('publish-adapter', adapterPath);
const original = published(adapterPublish, 'blast_boosts_aftermath');
const protocol = created(adapterPublish, '::blast_boosts_aftermath::Protocol');
const otw = `${original}::blast_boosts_aftermath::BLAST_BOOSTS_AFTERMATH`;
const publication = created(adapterPublish, `::package_version::Publication<${otw}>`);
const caps = adapterPublish.objectChanges.filter((change) =>
  change.type === 'created' && change.objectType.endsWith('::package::UpgradeCap'));
const matchingCaps = [];
for (const cap of caps) {
  if ((await fields(cap.objectId)).package === original) matchingCaps.push(cap.objectId);
}
assert.equal(matchingCaps.length, 1, 'Expected the native cap for the adapter');
let tx = new Transaction();
tx.moveCall({ target: `${admin}::package_admin::wrap`, typeArguments: [otw],
  arguments: [tx.object(publication), tx.object(matchingCaps[0])] });
const wrapped = await execute('wrap', tx);
const custody = created(wrapped, `::package_admin::PackageAdmin<${otw}>`);
const packageVersion = created(wrapped, `::package_version::PackageVersion<${otw}>`);
tx = new Transaction();
tx.moveCall({ target: `${admin}::blast_acl::grant_admin`, arguments: [tx.object(acl), tx.object(root), tx.pure.address(address)] });
const adminCap = created(await execute('grant-admin', tx), '::blast_acl::AdminCap');
const upgradeRole = `${admin}::package_admin::UpgradeAdmin<${otw}>`;
const feeRole = `${launchCore}::blast_domain::FeeAdmin`;
const partnerRole = `${partners}::blast_partners::PartnerAdmin`;
function roleChange(tx, action, role) {
  tx.moveCall({ target: `${admin}::blast_acl::${action}`, typeArguments: [role],
    arguments: [tx.object(acl), tx.object(root), tx.pure.id(adminCap)] });
}
tx = new Transaction();
for (const role of [upgradeRole, feeRole, partnerRole]) roleChange(tx, 'grant_role', role);
await execute('grant-roles', tx);
function witness(tx, role = upgradeRole) {
  return tx.moveCall({ target: `${admin}::blast_acl::sign_in`, typeArguments: [role], arguments: [tx.object(acl), tx.object(adminCap)] });
}
async function activeGeneration() {
  return Number((await fields(protocol)).generation);
}
async function ordinaryOperation(name, packageId, abort) {
  const before = await fields(protocol);
  const tx = new Transaction();
  tx.moveCall({ target: `${partners}::blast_partners::register`,
    arguments: [witness(tx, partnerRole), tx.pure.id(adminCap), tx.pure.address(address), tx.pure.u64(0)] });
  const partner = created(await execute(`${name}-partner`, tx), '::blast_partners::Partner');
  const add = new Transaction();
  add.moveCall({ target: `${packageId}::operations::add_partner`, arguments: [add.object(protocol), witness(add, feeRole), add.object(partner)] });
  await execute(name, add, abort);
  if (abort) assert.deepEqual(await fields(protocol), before, 'Failed operation preserves Protocol.');
}
// Assert the defining modules and exact abort codes.
const mismatch = /name: Identifier\("blast_boosts_aftermath"\).*}, 0\)/s;
const noRole = /name: Identifier\("blast_acl"\).*}, 5\)/s;
const unavailableCap = /name: Identifier\("package_admin"\).*}, 12\)/s;
await ordinaryOperation('initial-operation', original);
let latest = original;
let nativeCount = 1;
const markerPath = join(adapterPath, 'sources/blast_boosts_aftermath.move');
const markerSource = readFileSync(markerPath, 'utf8');
async function upgrade(name, generation, abort) {
  writeFileSync(markerPath, markerSource.replace('const PACKAGE_VERSION: u64 = 1;', `const PACKAGE_VERSION: u64 = ${generation};`));
  // The standalone compiler selects mainnet's pinned dependency environment.
  // Its pubfile needs that environment's chain label, while the IDs still refer
  // exclusively to this localnet. Never use this file for publication.
  const compilePubfile = join(output, 'Compile.toml');
  writeFileSync(compilePubfile, readFileSync(pubfile, 'utf8').replace(/^chain-id = "[^"]+"/m, 'chain-id = "35834a8a"'));
  const compiled = JSON.parse(command(`${name}-build`, ['move', 'build', '--path', adapterPath,
    '--build-env', 'mainnet', '--pubfile-path', compilePubfile, '--dump', '--no-tree-shaking']));
  const before = await fields(protocol);
  const proposal = new Transaction();
  proposal.moveCall({ target: `${admin}::package_admin::schedule_upgrade`, typeArguments: [otw],
    arguments: [proposal.object(custody), witness(proposal), proposal.pure.vector('u8', compiled.digest), proposal.object('0x6')] });
  await execute(`${name}-schedule`, proposal, abort);
  if (abort) return latest;
  await waitForNotice((await fields('0x6')).timestamp_ms);
  const tx = new Transaction();
  const authority = witness(tx);
  const ticket = tx.moveCall({ target: `${admin}::package_admin::authorize_upgrade`, typeArguments: [otw],
    arguments: [tx.object(custody), authority, tx.pure.vector('u8', compiled.digest), tx.object('0x6')] });
  const receipt = tx.upgrade({ modules: compiled.modules, dependencies: compiled.dependencies, package: latest, ticket });
  tx.moveCall({ target: `${admin}::package_admin::commit_upgrade_and_advance`, typeArguments: [otw],
    arguments: [tx.object(custody), authority, tx.object(packageVersion), receipt] });
  const response = await execute(name, tx);
  assert.deepEqual(await fields(protocol), before, 'Receipt commit must not advance Protocol.');
  latest = published(response, 'blast_boosts_aftermath');
  nativeCount++;
  assert.equal(response.objectChanges.filter((x) => x.type === 'created' && x.objectType?.endsWith('::Protocol')).length, 0, 'Upgrade must not rerun init.');
  assert.equal(response.events.filter((x) => x.type.includes('::GenerationActivated')).length, 0);
  const committed = event(response, '::UpgradeCommitted<');
  assert.equal(Number(committed.new_upgrade_cap_version), nativeCount);
  assert.equal(committed.new_package_id, latest);
  return latest;
}
async function activate(name, packageId, abort) {
  const before = await fields(protocol);
  const tx = new Transaction();
  tx.moveCall({ target: `${packageId}::package_admin::activate_upgrade`, arguments: [tx.object(protocol), witness(tx)] });
  const response = await execute(name, tx, abort);
  if (abort) assert.deepEqual(await fields(protocol), before, 'Activation abort preserves Protocol.');
  else {
    const advanced = event(response, '::GenerationActivated').pos0;
    assert.equal(Number(advanced.previous), Number(before.generation));
    assert.equal(Number(advanced.current), await activeGeneration());
    assert.equal(advanced.protocol, protocol);
  }
}
await upgrade('wrong-version-upgrade', 1);
await activate('wrong-version-activation', latest, mismatch);
assert.equal(await activeGeneration(), 1);
await ordinaryOperation('old-operation-after-bad-build', original);
await upgrade('skipped-version-upgrade', 3);
await activate('skipped-version-activation', latest, mismatch);
await ordinaryOperation('old-operation-after-skipped-build', original);
const repaired = await upgrade('corrected-upgrade', 2);
await activate('corrected-activation', repaired);
assert.equal(nativeCount, 4);
assert.equal(await activeGeneration(), 2);
await activate('activation-replay', repaired, mismatch);
await ordinaryOperation('old-operation-after-activation', original, mismatch);
await ordinaryOperation('new-operation-after-activation', repaired);

// The shared admin package can install a repair after the serving generation changes.
const next = await upgrade('repair-through-shared-admin', 3);
tx = new Transaction();
tx.moveCall({ target: `${original}::package_admin::make_immutable`, arguments: [tx.object(custody), tx.object(protocol), tx.object(packageVersion), witness(tx), tx.object('0x6')] });
await execute('stale-code-cannot-burn-repair', tx, mismatch);
tx = new Transaction();
roleChange(tx, 'revoke_role', upgradeRole);
await execute('revoke-upgrade-role', tx);
await activate('revoked-role-cannot-activate', next, noRole);
await upgrade('revoked-role-cannot-authorize-old-code', 3, noRole);
tx = new Transaction();
roleChange(tx, 'grant_role', upgradeRole);
await execute('restore-upgrade-role', tx);
await activate('next-activation', next);
await ordinaryOperation('next-operation', next);
tx = new Transaction();
tx.moveCall({ target: `${admin}::package_admin::schedule_make_immutable`, typeArguments: [otw],
  arguments: [tx.object(custody), witness(tx), tx.object('0x6')] });
await execute('schedule-immutability', tx);
await waitForNotice((await fields('0x6')).timestamp_ms);
tx = new Transaction();
tx.moveCall({ target: `${next}::package_admin::make_immutable`, arguments: [tx.object(custody), tx.object(protocol), tx.object(packageVersion), witness(tx), tx.object('0x6')] });
await execute('current-code-makes-immutable', tx);
await ordinaryOperation('operations-survive-immutability', next);
await upgrade('burned-cap-prevents-repair', 4, unavailableCap);
save('summary', { version, sdk: '2.35.0', fixtureUpgradeDelayMs: 1000, original, latest, nativeCount, activeGeneration: await activeGeneration(),
  transactions: results.length, scope: 'Adapter source and real ACL with a one-second rehearsal notice. Partner administration exercises the operational gate. No venue trades or user-fund exits executed.' });
console.log(`PASS: ${results.length} runtime transactions; native ${nativeCount}, operational ${await activeGeneration()}.`);
