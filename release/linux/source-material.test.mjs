import assert from 'node:assert/strict';
import { execFileSync, spawnSync } from 'node:child_process';
import { chmodSync, linkSync, lstatSync, mkdirSync, readFileSync, readdirSync, rmSync, rmdirSync, symlinkSync, truncateSync, writeFileSync } from 'node:fs';
import { join, resolve } from 'node:path';
import test from 'node:test';
import { linuxMaterialJoin } from './source-material.mjs';
import { changeInputs, encode, hash, linuxMaterialFixture as fixture, updateCandidate } from './source-material-fixture.mjs';

const owner = resolve(new URL('../..', import.meta.url).pathname);
const inputPath = f => join(f.candidate, 'runtime/root/usr/share/doc/frameshift/build-inputs.json');
function changedReceipt(f, name, change) { const record = JSON.parse(readFileSync(f[name + 'Path'])); change(record); const bytes = encode(record); writeFileSync(f[name + 'Path'], bytes); return { ...f, [name + 'Sha256']: hash(bytes) }; }

test('retained Ubuntu source assertions join both architectures with distinct Git metadata and no-effect CLI replay', async t => {
  const f = await fixture(t), joined = await linuxMaterialJoin(f);
  assert.equal(joined.provedSourceFiles, 3); assert.equal(joined.publicationAuthority, 'none');
  assert.deepEqual(joined.generatedInputs.map(file => file.reason), ['compiler-lock-metadata']);
  assert.deepEqual(joined.retainedGitMetadata.map(file => file.reason), ['retained-git-build-metadata']);
  const path = join(f.output, 'dependency-inputs.json'), before = lstatSync(path);
  assert.equal(before.mode & 0o7777, 0o600); assert.equal(lstatSync(f.output).mode & 0o7777, 0o700);
  const replay = await linuxMaterialJoin(f); assert.equal(replay.recordSha256, joined.recordSha256); assert.equal(replay.disposition, 'retained-bytes-verified');
  assert.equal(lstatSync(path).ino, before.ino); assert.equal(lstatSync(path).mtimeMs, before.mtimeMs);
  const cli = JSON.parse(execFileSync('mise', ['exec', '--', 'node', join(f.repository, 'release/linux/source-material-cli.mjs'), f.tag, f.commit, f.sourcePath, f.architecture, f.candidate, f.candidateSha256, f.corePath, f.coreSha256, f.gleamPath, f.gleamSha256, f.output], { cwd: f.repository, encoding: 'utf8', timeout: 60_000, maxBuffer: 64 * 1024 }));
  assert.equal(cli.recordSha256, joined.recordSha256); assert.equal(cli.disposition, 'retained-bytes-verified');
  const amd = await linuxMaterialJoin(f.candidates[1]); assert.equal(amd.provedSourceFiles, joined.provedSourceFiles);
});

test('independent source/candidate/receipt identities and runtime descriptor conflicts refuse', async t => {
  const f = await fixture(t);
  for (const key of ['coreSha256', 'gleamSha256', 'candidateSha256']) await assert.rejects(() => linuxMaterialJoin({ ...f, [key]: 'f'.repeat(64) }));
  const original = readFileSync(f.corePath);
  for (const change of [r => { r.sourceInputsSha256 = 'f'.repeat(64); }, r => { r.lockSha256 = 'f'.repeat(64); }, r => { r.packages[0].files[0].sha256 = 'f'.repeat(64); }, r => { r.packages[0].files.push(r.packages[0].files[0]); }, r => { r.packages[0].files[0].path = '.git/HEAD'; }, r => { r.extra = true; }]) { await assert.rejects(() => linuxMaterialJoin(changedReceipt(f, 'core', change))); writeFileSync(f.corePath, original); }
  const bytes = readFileSync(join(f.candidate, 'candidate.json'));
  for (const change of [r => { r.architecture = 'amd64'; }, r => { r.buildExecution.emulated = true; }, r => { r.publicationAuthority = 'release'; }]) { const r = JSON.parse(bytes); change(r); writeFileSync(join(f.candidate, 'candidate.json'), encode(r)); await assert.rejects(() => linuxMaterialJoin({ ...f, candidateSha256: hash(encode(r)) })); }
  writeFileSync(join(f.candidate, 'candidate.json'), bytes);
  writeFileSync(join(f.candidate, 'runtime/root/usr/lib/frameshift/core/lib/frameshift_core-0.1.0/ebin/frameshift_core.app'), '{application,frameshift_core,[{vsn,"9.0.0"}]}.\n'); updateCandidate(f);
  await assert.rejects(() => linuxMaterialJoin(f), /version/);
});

test('captured proof, frozen project, metadata, duplicate and unknown Git paths refuse even with updated record digests', async t => {
  const f = await fixture(t), original = structuredClone(f.inputRecord);
  const changes = [r => { r.inputs.find(x => x.path.endsWith('/source.ex')).sha256 = 'f'.repeat(64); }, r => { r.inputs.find(x => x.path.endsWith('/packages.toml')).sha256 = 'f'.repeat(64); }, r => { r.inputs.push(r.inputs[0]); }, r => { r.inputs[0].sha256 = 'f'.repeat(64); }, r => { r.inputs.push({ path: 'apps/core/deps/example/.git/hooks/pre-commit', mode: 0o644, bytes: 1, sha256: 'a'.repeat(64) }); }, r => { r.inputs.push({ path: 'packages/decision-kernel/build/packages/example/.git/HEAD', mode: 0o644, bytes: 1, sha256: 'a'.repeat(64) }); }, r => { r.inputs.push({ path: 'apps/core/deps/example/.git/refs/remotes/other/main', mode: 0o644, bytes: 1, sha256: 'a'.repeat(64) }); }, r => { r.inputs.push({ path: 'apps/core/deps/example/unknown.ex', mode: 0o644, bytes: 1, sha256: 'a'.repeat(64) }); }, r => { r.inputs.push({ path: '../escape', mode: 0o644, bytes: 1, sha256: 'a'.repeat(64) }); }, r => { r.inputs[0].bytes = 128 * 1024 * 1024 + 1; }, r => { r.toolchains.otp = 'other'; }];
  for (const change of changes) { f.inputRecord = structuredClone(original); changeInputs(f, change); await assert.rejects(() => linuxMaterialJoin(f)); }
  assert.equal(readdirSync(join(f.repository, 'var')).includes('join-arm64'), false);
});

test('candidate/receipt byte custody, aliases, modes, special files, limits and unknown directories refuse', async t => {
  const f = await fixture(t), path = inputPath(f), bytes = readFileSync(path), alias = join(f.repository, 'var/alias');
  linkSync(path, alias); await assert.rejects(() => linuxMaterialJoin(f), /unsafe/); rmSync(alias);
  chmodSync(path, 0o666); await assert.rejects(() => linuxMaterialJoin(f), /unsafe/); chmodSync(path, 0o644);
  writeFileSync(path, 'changed'); await assert.rejects(() => linuxMaterialJoin(f), /bytes/); writeFileSync(path, bytes);
  const dir = join(f.candidate, 'runtime/unknown'); mkdirSync(dir); await assert.rejects(() => linuxMaterialJoin(f), /unknown/); rmdirSync(dir);
  symlinkSync(path, join(f.candidate, 'runtime/redirected')); await assert.rejects(() => linuxMaterialJoin(f), /unsafe/); rmSync(join(f.candidate, 'runtime/redirected'));
  execFileSync('mkfifo', [join(f.candidate, 'runtime/fifo')]); await assert.rejects(() => linuxMaterialJoin(f), /unsafe/); rmSync(join(f.candidate, 'runtime/fifo'));
const excessive = join(f.candidate, 'runtime/excessive'); mkdirSync(excessive);
for (let i = 0; i < 8193; i++) writeFileSync(join(excessive, String(i)), '');
await assert.rejects(() => linuxMaterialJoin(f), /namespace limit/); rmSync(excessive, { recursive: true });
  const huge = join(f.candidate, 'runtime/oversized'); writeFileSync(huge, ''); truncateSync(huge, 128 * 1024 * 1024 + 1); await assert.rejects(() => linuxMaterialJoin(f), /excessive/); rmSync(huge);
  linkSync(f.corePath, alias); await assert.rejects(() => linuxMaterialJoin(f), /alias/); rmSync(alias);
  chmodSync(f.gleamPath, 0o644); await assert.rejects(() => linuxMaterialJoin(f), /unsafe/); chmodSync(f.gleamPath, 0o600);
  truncateSync(f.corePath, 16 * 1024 * 1024 + 1); await assert.rejects(() => linuxMaterialJoin(f), /size/);
});

test('partial and conflicting joins preserve retained custody', async t => {
  const f = await fixture(t); mkdirSync(f.output, { mode: 0o700 }); writeFileSync(join(f.output, 'check.pending'), 'retained', { mode: 0o600 });
  await assert.rejects(() => linuxMaterialJoin(f), /incomplete/); assert.deepEqual(readdirSync(f.output), ['check.pending']);
  const other = { ...f, output: join(f.repository, 'var/complete') }; await linuxMaterialJoin(other);
  const path = join(other.output, 'dependency-inputs.json'); writeFileSync(path, 'changed', { mode: 0o600 }); await assert.rejects(() => linuxMaterialJoin(other), /conflicting/);
});

test('runtime child-time receipt/candidate mutation refuses and retains an incomplete join', async t => {
  const f = await fixture(t); let versions = 0;
  const tool = (repository, core, version) => {
    const result = execFileSync('mise', ['exec', '--', 'elixir', join(repository, 'release/linux/verify-version.exs'), core, version], { cwd: repository, timeout: 60_000, maxBuffer: 64 * 1024 });
    assert.match(result.toString(), /verified/);
    if (++versions === 2) writeFileSync(f.corePath, 'changed');
  };
  await assert.rejects(() => linuxMaterialJoin(f, { tool })); assert.deepEqual(readdirSync(f.output), ['check.pending']);
  writeFileSync(f.corePath, encode(f.core)); versions = 0;
  const other = { ...f, output: join(f.repository, 'var/mutated-candidate') };
  await assert.rejects(() => linuxMaterialJoin(other, { tool: () => { if (++versions === 2) writeFileSync(inputPath(f), 'changed'); } }), /candidate|record/);
  assert.deepEqual(readdirSync(other.output), ['check.pending']);
});

test('CLI fixed usage and refusal do not disclose supplied paths', () => {
  const run = args => spawnSync('mise', ['exec', '--', 'node', join(owner, 'release/linux/source-material-cli.mjs'), ...args], { cwd: owner, encoding: 'utf8', timeout: 60_000 });
  assert.equal(run([]).status, 64);
  const result = run(['v1.2.3', 'f'.repeat(40), 'private-path', 'arm64', 'private-path', 'a'.repeat(64), 'private-path', 'b'.repeat(64), 'private-path', 'c'.repeat(64), 'private-path']);
  assert.equal(result.status, 1); assert.equal(result.stdout, ''); assert.equal(result.stderr, 'Ubuntu dependency inputs: unavailable, unsafe or conflicting source/receipt/candidate/output\n');
});
