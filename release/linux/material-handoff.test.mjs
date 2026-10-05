import assert from 'node:assert/strict';
import { createHash } from 'node:crypto';
import { execFileSync, spawnSync } from 'node:child_process';
import { chmodSync, copyFileSync, existsSync, lstatSync, mkdirSync, readFileSync, readdirSync, truncateSync, writeFileSync } from 'node:fs';
import { join } from 'node:path';
import test from 'node:test';
import { mkdtempSync, rmSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { linuxMaterialFixture as materialFixture } from './source-material-fixture.mjs';
import { stageLinuxMaterial } from './material-handoff.mjs';
import { linuxMaterialJoin } from './source-material.mjs';

const portable = {}, hash = value => createHash('sha256').update(value).digest('hex');
function temporary(t) { const path = mkdtempSync(join(tmpdir(), 'frameshift-linux-material-handoff-')); t.after(() => rmSync(path, { recursive: true, force: true })); return path; }
function archive(t, f, joinedPath, change = () => {}) {
  const root = temporary(t), material = join(root, 'ubuntu-material'); mkdirSync(material, { mode: 0o700 });
  for (const [path, name] of [[f.corePath, 'core-material.json'], [f.gleamPath, 'gleam-material.json'], [joinedPath, 'dependency-inputs.json']]) copyFileSync(path, join(material, name));
  change(material);
  const archivePath = join(root, 'material.tar');
  execFileSync('/usr/bin/tar', ['--format', 'ustar', '-cf', archivePath, '-C', root, 'ubuntu-material'], { env: { ...process.env, COPYFILE_DISABLE: '1' }, timeout: 30_000 }); chmodSync(archivePath, 0o600);
  return { archivePath, archiveSha256: hash(readFileSync(archivePath)) };
}
async function fixture(t) {
  const f = await materialFixture(t), result = await linuxMaterialJoin(f), joinedPath = join(f.output, 'dependency-inputs.json');
  return { ...f, ...archive(t, f, joinedPath), joinedPath, joinSha256: result.recordSha256, output: join(f.repository, 'var/received-material') };
}

test('actual POSIX USTAR receipts rejoin both admitted CPU candidates with unchanged private CLI replay', portable, async t => {
  const f = await fixture(t), first = await stageLinuxMaterial(f);
  assert.equal(first.publicationAuthority, 'none'); assert.equal(first.provedSourceFiles, 3); assert.equal(first.generatedInputs, 1);
  assert.equal(first.retainedGitMetadata, 1);
  assert.equal(first.disposition, 'dependency-input-archive-staged');
  const path = join(f.output, 'handoff.json'), before = lstatSync(path), sourceReceipt = join(f.output, 'ubuntu-material/core-material.json'), receiptBefore = lstatSync(sourceReceipt), bytes = readFileSync(path);
  assert.equal(lstatSync(f.output).mode & 0o7777, 0o700); assert.equal(before.mode & 0o7777, 0o600);
  const replay = await stageLinuxMaterial(f);
  assert.equal(replay.disposition, 'retained-bytes-verified'); assert.equal(replay.recordSha256, first.recordSha256);
  assert.equal(lstatSync(path).ino, before.ino); assert.equal(lstatSync(path).mtimeMs, before.mtimeMs); assert.ok(readFileSync(path).equals(bytes));
  assert.equal(lstatSync(sourceReceipt).ino, receiptBefore.ino); assert.equal(lstatSync(sourceReceipt).mtimeMs, receiptBefore.mtimeMs);
  const cli = JSON.parse(execFileSync('mise', ['exec', '--', 'node', join(f.repository, 'release/linux/material-handoff-cli.mjs'), f.tag, f.commit, f.sourcePath, f.architecture, f.candidate, f.candidateSha256, f.archivePath, f.archiveSha256, f.coreSha256, f.gleamSha256, f.joinSha256, f.output], { cwd: f.repository, encoding: 'utf8', timeout: 90_000, maxBuffer: 64 * 1024 }));
  assert.equal(cli.recordSha256, first.recordSha256); assert.equal(cli.disposition, 'retained-bytes-verified');
const amd = f.candidates[1], joined = await linuxMaterialJoin(amd);
const received = await stageLinuxMaterial({ ...amd, ...archive(t, amd, join(amd.output, 'dependency-inputs.json')), joinSha256: joined.recordSha256, output: join(f.repository, 'var/received-amd-material') });
assert.equal(received.architecture, 'amd64'); assert.equal(received.provedSourceFiles, first.provedSourceFiles);

});

test('independent archive/source/receipt/candidate and semantically conflicting joined identities refuse', portable, async t => {
  const f = await fixture(t);
  await assert.rejects(stageLinuxMaterial({ ...f, archiveSha256: 'f'.repeat(64) }), /digest/); assert.equal(existsSync(f.output), false);
  await assert.rejects(stageLinuxMaterial({ ...f, commit: 'f'.repeat(40) })); assert.equal(existsSync(f.output), false);
  for (const key of ['coreSha256', 'gleamSha256', 'joinSha256', 'candidateSha256']) {
    const request = { ...f, [key]: 'f'.repeat(64), output: f.output + '-' + key };
    await assert.rejects(stageLinuxMaterial(request)); assert.ok(existsSync(join(request.output, 'handoff.pending'))); assert.equal(existsSync(join(request.output, 'handoff.json')), false);
    await assert.rejects(stageLinuxMaterial(request), /incomplete/);
  }
  let joinSha256;
  const transport = archive(t, f, f.joinedPath, directory => {
    const path = join(directory, 'dependency-inputs.json'), record = JSON.parse(readFileSync(path)); record.provedSourceFiles++;
    const bytes = Buffer.from(JSON.stringify(record) + '\n'); writeFileSync(path, bytes); joinSha256 = hash(bytes);
  });
  const request = { ...f, ...transport, joinSha256, output: f.output + '-conflicting-join' };
  await assert.rejects(stageLinuxMaterial(request), /join differs/); assert.ok(existsSync(join(request.output, 'handoff.pending')));
});

test('receipt archive member count, exact names, private modes and bounded sizes refuse before extraction', portable, async t => {
  const f = await fixture(t);
  for (const change of [directory => writeFileSync(join(directory, 'unknown'), 'extra'), directory => chmodSync(join(directory, 'core-material.json'), 0o644),
    directory => mkdirSync(join(directory, 'nested'), { mode: 0o700 }), directory => truncateSync(join(directory, 'dependency-inputs.json'), 64 * 1024 + 1),
    directory => truncateSync(join(directory, 'core-material.json'), 0)]) {
    await assert.rejects(stageLinuxMaterial({ ...f, ...archive(t, f, f.joinedPath, change) })); assert.equal(existsSync(f.output), false);
  }
  const sparse = join(temporary(t), 'oversized.tar'); writeFileSync(sparse, '', { mode: 0o600 }); truncateSync(sparse, 33 * 1024 * 1024 + 512);
  await assert.rejects(stageLinuxMaterial({ ...f, archivePath: sparse, archiveSha256: 'f'.repeat(64) }), /custody/); assert.equal(existsSync(f.output), false);
  const wrong = join(temporary(t), 'wrong-root.tar'), root = temporary(t); mkdirSync(join(root, 'macos-candidate'), { mode: 0o700 });
  execFileSync('/usr/bin/tar', ['--format', 'ustar', '-cf', wrong, '-C', root, 'macos-candidate'], { env: { ...process.env, COPYFILE_DISABLE: '1' } });
  await assert.rejects(stageLinuxMaterial({ ...f, archivePath: wrong, archiveSha256: hash(readFileSync(wrong)) }), /path/);
});

test('retained receipt replacement, namespace/record changes and unsafe overlap preserve prior custody', portable, async t => {
  const f = await fixture(t); await stageLinuxMaterial(f);
  const path = join(f.output, 'handoff.json'), original = readFileSync(path), received = join(f.output, 'ubuntu-material/core-material.json'), bytes = readFileSync(received);
  writeFileSync(received, Buffer.from(bytes).fill(32, 0, 1)); await assert.rejects(stageLinuxMaterial(f), /bytes differ/); assert.ok(readFileSync(path).equals(original)); writeFileSync(received, bytes);
  const changed = Buffer.from(original).fill(32, 0, 1); writeFileSync(path, changed);
  await assert.rejects(stageLinuxMaterial(f), /handoff differs/); assert.ok(readFileSync(path).equals(changed)); writeFileSync(path, original);
  chmodSync(f.output, 0o755); await assert.rejects(stageLinuxMaterial(f), /unsafe/); assert.ok(readFileSync(path).equals(original)); chmodSync(f.output, 0o700);
  writeFileSync(join(f.output, 'verification/unknown'), 'keep'); await assert.rejects(stageLinuxMaterial(f), /conflicting/); assert.ok(readFileSync(path).equals(original));
  await assert.rejects(stageLinuxMaterial({ ...f, output: join(f.candidate, 'overlap') }), /overlaps/);
  await assert.rejects(stageLinuxMaterial({ ...f, output: join(f.repository, 'tracked-output') }));
  assert.equal(existsSync(join(f.candidate, 'overlap')), false); assert.equal(existsSync(join(f.repository, 'tracked-output')), false);
});

test('child-time received evidence and output namespace mutation leave incomplete refused custody', portable, async t => {
  for (const mutation of ['receipt', 'namespace']) {
    const f = await fixture(t); let versions = 0;
    await assert.rejects(stageLinuxMaterial(f, { tool: (repository, core, version) => {
      const result = execFileSync('mise', ['exec', '--', 'elixir', join(repository, 'release/linux/verify-version.exs'), core, version], { cwd: repository, timeout: 60_000, maxBuffer: 64 * 1024 });
      if (++versions === 4) {
        if (mutation === 'receipt') {
          const path = join(f.output, 'ubuntu-material/core-material.json'), bytes = readFileSync(path); writeFileSync(path, Buffer.from(bytes).fill(32, 0, 1));
        } else writeFileSync(join(f.output, 'unknown'), 'retain mutation');
      }
      return result;
    } }));
    assert.ok(existsSync(join(f.output, 'handoff.pending'))); assert.equal(existsSync(join(f.output, 'handoff.json')), false);
    if (mutation === 'namespace') assert.equal(readFileSync(join(f.output, 'unknown'), 'utf8'), 'retain mutation');
  }
});

test('receipt transport CLI refuses privately with fixed usage and errors', t => {
  const cli = new URL('./material-handoff-cli.mjs', import.meta.url).pathname;
  assert.equal(spawnSync(process.execPath, [cli], { encoding: 'utf8', timeout: 2000 }).status, 64);
  const result = spawnSync(process.execPath, [cli, 'v0.1.0', 'f'.repeat(40), join(temporary(t), 'private-source'), 'arm64', 'candidate', 'f'.repeat(64), 'archive', 'f'.repeat(64), 'f'.repeat(64), 'f'.repeat(64), 'f'.repeat(64), 'output'], { encoding: 'utf8', timeout: 2000 });
  assert.equal(result.status, 1); assert.equal(result.stdout, ''); assert.equal(result.stderr, 'Ubuntu dependency input archive handoff refused; existing output retained\n');
});
