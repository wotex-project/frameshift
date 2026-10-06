import assert from 'node:assert/strict';
import { execFileSync, spawnSync } from 'node:child_process';
import { chmodSync, copyFileSync, linkSync, lstatSync, mkdirSync, mkdtempSync, readFileSync, rmSync, symlinkSync, writeFileSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join, resolve } from 'node:path';
import test from 'node:test';
import { readReleaseInput } from '../files.mjs';
import { checkSDKResources } from './sdk-resources.mjs';
const custody = stat => ['dev', 'ino', 'mode', 'uid', 'gid', 'nlink', 'size', 'mtimeNs', 'ctimeNs'].map(key => stat[key]);
const owner = resolve(new URL('../..', import.meta.url).pathname), live = process.env.FRAMESHIFT_SDK_RESOURCES_FIXTURE;
function fixture(t, actual = false) {
  const root = mkdtempSync(join(tmpdir(), 'frameshift-sdk-resource-test-')); chmodSync(root, 0o700); t.after(() => rmSync(root, { recursive: true, force: true }));
  for (const name of ['configs.json', 'models.json']) { if (actual) copyFileSync(join(live, name), join(root, name)); else writeFileSync(join(root, name), '{}\n'); chmodSync(join(root, name), 0o600); } return root;
}
test('actual pinned resource bytes pass private unchanged CLI replay without SDK or model IO', { skip: !live && 'FRAMESHIFT_SDK_RESOURCES_FIXTURE is required for exact upstream resource bytes' }, async t => {
  const root = fixture(t, true), before = ['', 'configs.json', 'models.json'].map(name => custody(lstatSync(join(root, name), { bigint: true }))), result = await checkSDKResources(root);
  assert.equal(result.publicationAuthority, 'none'); assert.equal(result.resources.length, 2); assert.equal(JSON.stringify(result).includes(root), false);
  const cli = JSON.parse(execFileSync('mise', ['exec', '--', 'node', join(owner, 'release/macos/sdk-resources-cli.mjs'), root], { cwd: owner, encoding: 'utf8', timeout: 5000 })); assert.deepEqual(cli, result);
  if (process.platform === 'darwin') {
    const env = { ...process.env, PATH: '/usr/bin:/bin:/usr/sbin:/sbin', NODE_OPTIONS: '--frameshift-wrapper-must-not-start-node' }, expected = Buffer.from(JSON.stringify(result) + '\n');
    for (const input of [root, '.']) assert.deepEqual(execFileSync(join(owner, 'scripts/check-sdk-resources'), [input], { cwd: root, env, timeout: 180000, maxBuffer: 64 * 1024 }), expected);
  }
  assert.deepEqual(['', 'configs.json', 'models.json'].map(name => custody(lstatSync(join(root, name), { bigint: true }))), before);
});
test('missing, changed and oversized inputs refuse without repairing bytes', async t => {
  const root = fixture(t), path = join(root, 'configs.json'); await assert.rejects(() => checkSDKResources(root)); assert.equal(readFileSync(path, 'utf8'), '{}\n');
  writeFileSync(path, Buffer.alloc(256 * 1024 + 1)); await assert.rejects(() => checkSDKResources(root), /size/); assert.equal(lstatSync(path).size, 256 * 1024 + 1); rmSync(path); await assert.rejects(() => checkSDKResources(root));
});
test('unsafe root, additional names, aliases, modes, links and special files refuse before any descriptor read', async t => {
  const root = fixture(t), path = join(root, 'configs.json'), alias = root + '-alias'; t.after(() => rmSync(alias, { force: true })); let calls = 0;
  const check = () => checkSDKResources(root, { read: () => { calls++; throw Error('must not read'); } });
  chmodSync(root, 0o755); await assert.rejects(check); chmodSync(root, 0o700); writeFileSync(join(root, 'unknown'), 'retained'); await assert.rejects(check); rmSync(join(root, 'unknown'));
  linkSync(path, alias); await assert.rejects(check); rmSync(alias); chmodSync(path, 0o644); await assert.rejects(check); chmodSync(path, 0o600);
  rmSync(path); symlinkSync('models.json', path); await assert.rejects(check); rmSync(path); execFileSync('mkfifo', [path]); await assert.rejects(check); rmSync(path); mkdirSync(path); await assert.rejects(check); assert.equal(calls, 0);
});
test('actual resources refuse file or namespace mutation during descriptor reads', { skip: !live && 'Exact upstream resource input is required' }, async t => {
  for (const mutation of ['file', 'namespace']) { const root = fixture(t, true); let calls = 0;
    await assert.rejects(() => checkSDKResources(root, { read: async (...args) => { const bytes = await readReleaseInput(...args); if (++calls === 2) { const path = join(root, mutation === 'file' ? 'configs.json' : 'unknown'); writeFileSync(path, mutation === 'file' ? readFileSync(path) : 'retained'); } return bytes; } }));
  }
});
test('fixed CLI usage/refusal contains no supplied private path or SDK details', () => {
  const run = args => spawnSync('mise', ['exec', '--', 'node', join(owner, 'release/macos/sdk-resources-cli.mjs'), ...args], { cwd: owner, encoding: 'utf8', timeout: 5000 }); assert.equal(run([]).status, 64);
  const result = run(['private-sdk-resource-root']); assert.equal(result.status, 1); assert.equal(result.stdout, ''); assert.equal(result.stderr, 'generation SDK resources: unavailable, unsafe or changed custody\n');
  if (process.platform === 'darwin') {
    const wrapper = args => spawnSync(join(owner, 'scripts/check-sdk-resources'), args, { cwd: owner, env: { ...process.env, PATH: '/usr/bin:/bin:/usr/sbin:/sbin', NODE_OPTIONS: '--frameshift-wrapper-must-not-start-node' }, encoding: 'utf8', timeout: 180000, maxBuffer: 64 * 1024 });
    for (const args of [[], [''], ['root', 'extra']]) { const usage = wrapper(args); assert.equal(usage.status, 64); assert.equal(usage.stdout, ''); assert.equal(usage.stderr, 'usage: check-sdk-resources RESOURCE_ROOT\n'); }
    const refused = wrapper(['private-sdk-resource-root']); assert.equal(refused.status, 1); assert.equal(refused.stdout, ''); assert.equal(refused.stderr, result.stderr);
  }
});
