import assert from 'node:assert/strict';
import { createHash } from 'node:crypto';
import { execFileSync, spawnSync } from 'node:child_process';
import { chmodSync, copyFileSync, existsSync, lstatSync, mkdirSync, readFileSync, readdirSync, truncateSync, writeFileSync } from 'node:fs';
import { join } from 'node:path';
import test from 'node:test';
import { macImageTool } from './dmg.mjs';
import { temporary } from './fixture.mjs';
import { materialFixture } from './material-fixture.mjs';
import { stageMacMaterial } from './material-handoff.mjs';
import { macMaterialJoin } from './material.mjs';

const mac = { skip: process.platform !== 'darwin' }, hash = value => createHash('sha256').update(value).digest('hex');
function archive(t, f, joinedPath, change = () => {}) {
  const root = temporary(t), material = join(root, 'macos-material'); mkdirSync(material, { mode: 0o700 });
  for (const [path, name] of [[f.corePath, 'core-material.json'], [f.gleamPath, 'gleam-material.json'], [joinedPath, 'dependency-inputs.json']]) copyFileSync(path, join(material, name));
  change(material);
  const archivePath = join(root, 'material.tar');
  execFileSync('/usr/bin/tar', ['--format', 'ustar', '-cf', archivePath, '-C', root, 'macos-material'], { env: { ...process.env, COPYFILE_DISABLE: '1' }, timeout: 30_000 }); chmodSync(archivePath, 0o600);
  return { archivePath, archiveSha256: hash(readFileSync(archivePath)) };
}
async function fixture(t) {
  const f = await materialFixture(t), result = await macMaterialJoin(f), joinedPath = join(f.output, 'dependency-inputs.json');
  return { ...f, ...archive(t, f, joinedPath), joinedPath, joinSha256: result.recordSha256, output: join(f.repository, 'var/received-material') };
}

test('actual BSD USTAR receipts rejoin both admitted CPU candidates with unchanged private CLI replay', mac, async t => {
  const f = await fixture(t), first = await stageMacMaterial(f);
  assert.equal(first.publicationAuthority, 'none'); assert.equal(first.provedSourceFiles, 5); assert.equal(first.generatedInputs, 3);
  assert.equal(first.disposition, 'dependency-input-archive-staged');
  const path = join(f.output, 'handoff.json'), before = lstatSync(path), sourceReceipt = join(f.output, 'macos-material/core-material.json'), receiptBefore = lstatSync(sourceReceipt), bytes = readFileSync(path);
  assert.equal(lstatSync(f.output).mode & 0o7777, 0o700); assert.equal(before.mode & 0o7777, 0o600);
  const replay = await stageMacMaterial(f, { tool: (command, args, timeout) => { assert.notEqual(command, '/usr/bin/tar'); assert.notEqual(command, '/usr/bin/lipo'); assert.equal(args.includes('--sign'), false); return macImageTool(command, args, timeout); } });
  assert.equal(replay.disposition, 'retained-bytes-verified'); assert.equal(replay.recordSha256, first.recordSha256);
  assert.equal(lstatSync(path).ino, before.ino); assert.equal(lstatSync(path).mtimeMs, before.mtimeMs); assert.ok(readFileSync(path).equals(bytes));
  assert.equal(lstatSync(sourceReceipt).ino, receiptBefore.ino); assert.equal(lstatSync(sourceReceipt).mtimeMs, receiptBefore.mtimeMs);
  const cli = JSON.parse(execFileSync('mise', ['exec', '--', 'node', join(f.repository, 'release/macos/material-handoff-cli.mjs'), f.tag, f.commit, f.sourcePath, f.architecture, f.candidate, f.candidateSha256, f.archivePath, f.archiveSha256, f.coreSha256, f.gleamSha256, f.joinSha256, f.output], { cwd: f.repository, encoding: 'utf8', timeout: 90_000, maxBuffer: 64 * 1024 }));
  assert.equal(cli.recordSha256, first.recordSha256); assert.equal(cli.disposition, 'retained-bytes-verified');
  const intel = { ...f, architecture: 'x86_64', candidate: f.intelCandidate, candidateSha256: f.intelSha256, output: join(f.repository, 'var/intel-material') }, joined = await macMaterialJoin(intel);
  const received = await stageMacMaterial({ ...intel, ...archive(t, f, join(intel.output, 'dependency-inputs.json')), joinSha256: joined.recordSha256, output: join(f.repository, 'var/received-intel-material') });
  assert.equal(received.architecture, 'x86_64'); assert.equal(received.provedSourceFiles, first.provedSourceFiles);
});

test('independent archive/source/receipt/candidate and semantically conflicting joined identities refuse', mac, async t => {
  const f = await fixture(t);
  await assert.rejects(stageMacMaterial({ ...f, archiveSha256: 'f'.repeat(64) }), /digest/); assert.equal(existsSync(f.output), false);
  await assert.rejects(stageMacMaterial({ ...f, commit: 'f'.repeat(40) })); assert.equal(existsSync(f.output), false);
  for (const key of ['coreSha256', 'gleamSha256', 'joinSha256', 'candidateSha256']) {
    const request = { ...f, [key]: 'f'.repeat(64), output: f.output + '-' + key };
    await assert.rejects(stageMacMaterial(request)); assert.ok(existsSync(join(request.output, 'handoff.pending'))); assert.equal(existsSync(join(request.output, 'handoff.json')), false);
    await assert.rejects(stageMacMaterial(request), /incomplete/);
  }
  let joinSha256;
  const transport = archive(t, f, f.joinedPath, directory => {
    const path = join(directory, 'dependency-inputs.json'), record = JSON.parse(readFileSync(path)); record.provedSourceFiles++;
    const bytes = Buffer.from(JSON.stringify(record) + '\n'); writeFileSync(path, bytes); joinSha256 = hash(bytes);
  });
  const request = { ...f, ...transport, joinSha256, output: f.output + '-conflicting-join' };
  await assert.rejects(stageMacMaterial(request), /join differs/); assert.ok(existsSync(join(request.output, 'handoff.pending')));
});

test('receipt archive member count, exact names, private modes and bounded sizes refuse before extraction', mac, async t => {
  const f = await fixture(t);
  for (const change of [directory => writeFileSync(join(directory, 'unknown'), 'extra'), directory => chmodSync(join(directory, 'core-material.json'), 0o644),
    directory => mkdirSync(join(directory, 'nested'), { mode: 0o700 }), directory => truncateSync(join(directory, 'dependency-inputs.json'), 64 * 1024 + 1),
    directory => truncateSync(join(directory, 'core-material.json'), 0)]) {
    await assert.rejects(stageMacMaterial({ ...f, ...archive(t, f, f.joinedPath, change) })); assert.equal(existsSync(f.output), false);
  }
  const sparse = join(temporary(t), 'oversized.tar'); writeFileSync(sparse, '', { mode: 0o600 }); truncateSync(sparse, 33 * 1024 * 1024 + 512);
  await assert.rejects(stageMacMaterial({ ...f, archivePath: sparse, archiveSha256: 'f'.repeat(64) }), /custody/); assert.equal(existsSync(f.output), false);
  const wrong = join(temporary(t), 'wrong-root.tar'), root = temporary(t); mkdirSync(join(root, 'macos-candidate'), { mode: 0o700 });
  execFileSync('/usr/bin/tar', ['--format', 'ustar', '-cf', wrong, '-C', root, 'macos-candidate'], { env: { ...process.env, COPYFILE_DISABLE: '1' } });
  await assert.rejects(stageMacMaterial({ ...f, archivePath: wrong, archiveSha256: hash(readFileSync(wrong)) }), /path/);
});

test('retained receipt replacement, namespace/record changes and unsafe overlap preserve prior custody', mac, async t => {
  const f = await fixture(t); await stageMacMaterial(f);
  const path = join(f.output, 'handoff.json'), original = readFileSync(path), received = join(f.output, 'macos-material/core-material.json'), bytes = readFileSync(received);
  writeFileSync(received, Buffer.from(bytes).fill(32, 0, 1)); await assert.rejects(stageMacMaterial(f), /bytes differ/); assert.ok(readFileSync(path).equals(original)); writeFileSync(received, bytes);
  const changed = Buffer.from(original).fill(32, 0, 1); writeFileSync(path, changed);
  await assert.rejects(stageMacMaterial(f), /handoff differs/); assert.ok(readFileSync(path).equals(changed)); writeFileSync(path, original);
  chmodSync(f.output, 0o755); await assert.rejects(stageMacMaterial(f), /unsafe/); assert.ok(readFileSync(path).equals(original)); chmodSync(f.output, 0o700);
  writeFileSync(join(f.output, 'verification/unknown'), 'keep'); await assert.rejects(stageMacMaterial(f), /conflicting/); assert.ok(readFileSync(path).equals(original));
  await assert.rejects(stageMacMaterial({ ...f, output: join(f.candidate, 'overlap') }), /overlaps/);
  await assert.rejects(stageMacMaterial({ ...f, output: join(f.repository, 'tracked-output') }));
  assert.equal(existsSync(join(f.candidate, 'overlap')), false); assert.equal(existsSync(join(f.repository, 'tracked-output')), false);
});

test('child-time received evidence and output namespace mutation leave incomplete refused custody', mac, async t => {
  for (const mutation of ['receipt', 'namespace']) {
    const f = await fixture(t); let versions = 0;
    await assert.rejects(stageMacMaterial(f, { tool: (command, args, timeout) => {
      const result = macImageTool(command, args, timeout);
      if (args.includes(join(f.repository, 'release/linux/verify-version.exs')) && ++versions === 4) {
        if (mutation === 'receipt') {
          const path = join(f.output, 'macos-material/core-material.json'), bytes = readFileSync(path); writeFileSync(path, Buffer.from(bytes).fill(32, 0, 1));
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
  assert.equal(result.status, 1); assert.equal(result.stdout, ''); assert.equal(result.stderr, 'Mac dependency input archive handoff refused; existing output retained\n');
});
