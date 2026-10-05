import assert from 'node:assert/strict';
import { createHash } from 'node:crypto';
import { execFileSync, spawnSync } from 'node:child_process';
import { chmodSync, cpSync, existsSync, lstatSync, mkdirSync, readFileSync, rmSync, writeFileSync } from 'node:fs';
import { join } from 'node:path';
import test from 'node:test';
import { stageMacCandidate } from './handoff.mjs';
import { macSourceCohort } from './cohort.mjs';
import { macImageTool } from './dmg.mjs';
import { temporary } from './fixture.mjs';
import { sourceFixture } from './source-fixture.mjs';

const mac = { skip: process.platform !== 'darwin' }, hash = value => createHash('sha256').update(value).digest('hex');
function archive(t, candidate) {
  const root = temporary(t), destination = join(root, 'macos-candidate'); cpSync(candidate, destination, { recursive: true }); chmodSync(destination, 0o700);
  const path = join(root, 'candidate.tar');
  execFileSync('/usr/bin/tar', ['--format', 'ustar', '-cf', path, '-C', root, 'macos-candidate'], { env: { ...process.env, COPYFILE_DISABLE: '1' }, timeout: 30_000 }); chmodSync(path, 0o600);
  return { archivePath: path, archiveSha256: hash(readFileSync(path)) };
}
function request(f, transport, architecture = 'arm64') { return { ...f, ...transport, architecture, output: join(f.repository, 'var/received-' + architecture) }; }

test('actual BSD USTAR stages both CPU candidates with exact bytes/modes and no-extraction replay into the source join', mac, async t => {
  const f = await sourceFixture(t), outputs = [];
  for (const [candidate, architecture] of [[f.armCandidate, 'arm64'], [f.intelCandidate, 'x86_64']]) {
    const input = request(f, archive(t, candidate), architecture), first = await stageMacCandidate(input); outputs.push({ input, first });
    assert.equal(first.publicationAuthority, 'none'); assert.equal(first.disposition, 'candidate-archive-staged');
    const path = join(input.output, 'handoff.json'), before = lstatSync(path), bytes = readFileSync(path);
    const replay = await stageMacCandidate(input, { tool: (command, args, timeout) => { assert.notEqual(command, '/usr/bin/tar'); assert.notEqual(command, '/usr/bin/lipo'); assert.equal(args.includes('--sign'), false); return macImageTool(command, args, timeout); } });
    assert.equal(replay.disposition, 'retained-bytes-verified'); assert.equal(replay.recordSha256, first.recordSha256); assert.ok(readFileSync(path).equals(bytes)); assert.equal(lstatSync(path).mtimeMs, before.mtimeMs);
    const retained = join(input.output, 'macos-candidate/candidate.json'); assert.ok(readFileSync(retained).equals(readFileSync(join(candidate, 'candidate.json')))); assert.equal(lstatSync(retained).mode & 0o7777, 0o600);
  }
  const result = await macSourceCohort({ ...f, armCandidate: join(outputs[0].input.output, 'macos-candidate'), armSha256: outputs[0].first.candidateRecordSha256,
    intelCandidate: join(outputs[1].input.output, 'macos-candidate'), intelSha256: outputs[1].first.candidateRecordSha256 });
  assert.equal(result.disposition, 'source-bound-universal-candidate'); assert.equal(result.nativeFiles, 7);
});

test('wrong transport/source/CPU and Ubuntu profile archives refuse without a completed Mac handoff', mac, async t => {
  const f = await sourceFixture(t), input = request(f, archive(t, f.armCandidate));
  await assert.rejects(stageMacCandidate({ ...input, archiveSha256: 'f'.repeat(64) }), /digest/); assert.equal(existsSync(input.output), false);
  await assert.rejects(stageMacCandidate({ ...input, commit: 'f'.repeat(40) })); assert.equal(existsSync(input.output), false);
  const wrongCPU = { ...input, architecture: 'x86_64' }; await assert.rejects(stageMacCandidate(wrongCPU)); assert.ok(existsSync(join(input.output, 'handoff.pending'))); assert.equal(existsSync(join(input.output, 'handoff.json')), false);
  await assert.rejects(stageMacCandidate(input), /incomplete/);
  const parent = temporary(t); mkdirSync(join(parent, 'ubuntu-candidate'), { mode: 0o700 }); const path = join(parent, 'ubuntu.tar');
  execFileSync('/usr/bin/tar', ['--format', 'ustar', '-cf', path, '-C', parent, 'ubuntu-candidate'], { env: { ...process.env, COPYFILE_DISABLE: '1' } });
  await assert.rejects(stageMacCandidate({ ...input, output: join(f.repository, 'var/other'), archivePath: path, archiveSha256: hash(readFileSync(path)) }), /path/);
});

test('same-length retained candidate byte replacement and unknown namespaces refuse without rewriting custody', mac, async t => {
  const f = await sourceFixture(t), input = request(f, archive(t, f.armCandidate)); await stageMacCandidate(input);
  const record = join(input.output, 'handoff.json'), original = readFileSync(record), candidatePath = join(input.output, 'macos-candidate/candidate.json'), candidateBytes = readFileSync(candidatePath);
  const changed = JSON.parse(candidateBytes); changed.material[0].sha256 = 'f'.repeat(64); const substituted = Buffer.from(JSON.stringify(changed) + '\n'); assert.equal(substituted.length, candidateBytes.length); writeFileSync(candidatePath, substituted);
  await assert.rejects(stageMacCandidate(input), /bytes differ/); assert.ok(readFileSync(record).equals(original)); writeFileSync(candidatePath, candidateBytes);
  mkdirSync(join(input.output, 'macos-candidate/unknown-directory')); await assert.rejects(stageMacCandidate(input), /names changed/); assert.ok(readFileSync(record).equals(original));
});

test('source or namespace changes during received app readback retain incomplete output', mac, async t => {
  for (const mutation of ['source', 'namespace']) {
    const f = await sourceFixture(t), input = request(f, archive(t, f.armCandidate)); let changed = false;
    const tool = (command, args, timeout) => {
      const result = macImageTool(command, args, timeout);
      if (command === '/usr/bin/codesign' && args.includes('--deep') && !changed) {
        changed = true;
        if (mutation === 'source') { f.git(['update-index', '--assume-unchanged', 'README.md']); writeFileSync(join(f.repository, 'README.md'), 'hidden source mutation'); }
        else writeFileSync(join(input.output, 'unknown'), 'retain namespace mutation');
      }
      return result;
    };
    await assert.rejects(stageMacCandidate(input, { tool })); assert.ok(existsSync(join(input.output, 'handoff.pending')));
    if (mutation === 'source') assert.equal(existsSync(join(input.output, 'handoff.json')), false);
    else assert.equal(readFileSync(join(input.output, 'unknown'), 'utf8'), 'retain namespace mutation');
  }
});

test('Mac handoff CLI uses fixed usage/refusal and never discloses supplied private paths', t => {
  const cli = new URL('./handoff-cli.mjs', import.meta.url).pathname;
  assert.equal(spawnSync(process.execPath, [cli], { encoding: 'utf8', timeout: 2000 }).status, 64);
  const bad = spawnSync(process.execPath, [cli, 'v0.1.0', 'f'.repeat(40), join(temporary(t), 'secret-source'), 'arm64', 'archive', 'f'.repeat(64), 'unused-output'], { encoding: 'utf8', timeout: 2000 });
  assert.equal(bad.status, 1); assert.equal(bad.stdout, ''); assert.equal(bad.stderr, 'Mac candidate archive handoff refused; existing output retained\n');
});
