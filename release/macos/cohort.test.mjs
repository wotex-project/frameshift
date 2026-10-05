import assert from 'node:assert/strict';
import { createHash } from 'node:crypto';
import { spawnSync } from 'node:child_process';
import { existsSync, linkSync, lstatSync, mkdirSync, readFileSync, rmSync, symlinkSync, truncateSync, writeFileSync } from 'node:fs';
import { dirname, join } from 'node:path';
import test from 'node:test';
import { auditMacBundle } from './closure.mjs';
import { macSourceCohort } from './cohort.mjs';
import { macImageTool } from './dmg.mjs';
import { run, temporary } from './fixture.mjs';
import { sourceFixture as fixture } from './source-fixture.mjs';

const mac = { skip: process.platform !== 'darwin' };
const encode = value => Buffer.from(JSON.stringify(value) + '\n');
const hash = value => createHash('sha256').update(value).digest('hex');
function put(root, path, bytes) { const full = join(root, path); mkdirSync(dirname(full), { recursive: true }); writeFileSync(full, bytes); }

function changed(f, record) { const bytes = encode(record); writeFileSync(join(f.intelCandidate, 'candidate.json'), bytes); return { ...f, intelSha256: hash(bytes) }; }

test('one exact source joins separate CPU candidate records and actual universal code with no-effect replay', mac, async t => {
  const f = await fixture(t), first = await macSourceCohort(f);
  assert.equal(first.publicationAuthority, 'none'); assert.equal(first.disposition, 'source-bound-universal-candidate'); assert.equal(first.nativeFiles, 7);
  const path = join(f.output, 'cohort.json'), bytes = readFileSync(path), before = lstatSync(path);
  const replay = await macSourceCohort(f, { tool: (command, args, timeout) => {
    assert.notEqual(command, '/usr/bin/lipo'); assert.equal(args.includes('--sign'), false); return macImageTool(command, args, timeout);
  } });
  assert.equal(replay.disposition, 'retained-bytes-verified'); assert.equal(replay.recordSha256, first.recordSha256); assert.ok(readFileSync(path).equals(bytes)); assert.equal(lstatSync(path).mtimeMs, before.mtimeMs);
  const app = join(f.output, 'universal-candidate/Frameshift.app'); assert.deepEqual(run('/usr/bin/lipo', ['-archs', join(app, 'Contents/MacOS/Frameshift')]).split(' ').sort(), ['arm64', 'x86_64']);
  if (process.arch === 'arm64') run('/usr/bin/arch', ['-arm64', join(app, 'Contents/MacOS/Frameshift')]);
});

test('wrong source/digest and material/compiler/execution claims refuse before output creation', mac, async t => {
  const f = await fixture(t), original = f.candidates[1].record;
  await assert.rejects(macSourceCohort({ ...f, armSha256: 'f'.repeat(64) }), /digest/);
  await assert.rejects(macSourceCohort({ ...f, armSha256: f.armSha256 + '\n' }));
  await assert.rejects(macSourceCohort({ ...f, commit: 'f'.repeat(40) }));
  for (const mutate of [r => r.sourceInputsSha256 = 'f'.repeat(64), r => r.version = '0.2.0', r => r.extra = true,
    r => r.material[0].sha256 = 'f'.repeat(64), r => r.material[0].path = '../escape', r => r.execution.sdkBuild = 'different-sdk',
    r => r.execution.native = false, r => r.execution.swift = 'invalid compiler', r => r.execution.elixir = 'invalid runtime']) {
    const record = structuredClone(original); mutate(record); await assert.rejects(macSourceCohort(changed(f, record))); assert.equal(existsSync(f.output), false);
  }
});

test('candidate aliases, noncanonical/oversized records and changed app refuse as retained inputs', mac, async t => {
  const f = await fixture(t), path = join(f.intelCandidate, 'candidate.json'), original = readFileSync(path);
  rmSync(path); symlinkSync(join(f.intelCandidate, 'Frameshift.app/Contents/Info.plist'), path); await assert.rejects(macSourceCohort(f)); rmSync(path);
  const alias = join(f.repository, 'var/record-alias'); writeFileSync(alias, original, { mode: 0o600 }); linkSync(alias, path); await assert.rejects(macSourceCohort(f), /alias/); rmSync(path);
  writeFileSync(path, Buffer.concat([original, Buffer.from(' ')]), { mode: 0o600 }); await assert.rejects(macSourceCohort(f), /noncanonical/);
  truncateSync(path, 16 * 1024 * 1024 + 1); await assert.rejects(macSourceCohort(f)); writeFileSync(path, original);
  put(f.intelCandidate, 'Frameshift.app/Contents/Resources/changed', 'retained mutation'); await assert.rejects(macSourceCohort(f)); assert.equal(existsSync(f.output), false); assert.ok(readFileSync(path).equals(original));
});

test('an admitted closure with wrong runtime descriptors still refuses the actual version consumer', mac, async t => {
  const f = await fixture(t), record = structuredClone(f.candidates[1].record), app = join(f.intelCandidate, 'Frameshift.app');
  put(app, 'Contents/Resources/core/releases/start_erl.data', '17.1 0.2.0'); run('/usr/bin/codesign', ['--force', '--sign', '-', app]); record.bundle = await auditMacBundle(app, 'x86_64');
  await assert.rejects(macSourceCohort(changed(f, record))); assert.equal(existsSync(f.output), false);
});

test('hidden source or candidate change during actual merge retains the incomplete cohort and refuses replay', mac, async t => {
  for (const mutation of ['source', 'record']) {
    const f = await fixture(t); let changed = false;
    const tool = (command, args, timeout) => {
      const result = macImageTool(command, args, timeout);
      if (command === '/usr/bin/lipo' && !changed) {
        changed = true;
        if (mutation === 'source') { f.git(['update-index', '--assume-unchanged', 'README.md']); put(f.repository, 'README.md', 'hidden mutation'); }
        else writeFileSync(join(f.intelCandidate, 'candidate.json'), 'changed record\n');
      }
      return result;
    };
    await assert.rejects(macSourceCohort(f, { tool })); assert.ok(existsSync(join(f.output, 'build.pending'))); assert.equal(existsSync(join(f.output, 'cohort.json')), false);
    await assert.rejects(macSourceCohort(f));
  }
});

test('completed replay detects parent and universal-output changes without merging or replacing records', mac, async t => {
  const f = await fixture(t); await macSourceCohort(f); const original = readFileSync(join(f.output, 'cohort.json'));
  const app = join(f.output, 'universal-candidate/Frameshift.app'); let merges = 0;
  const tool = (command, args, timeout) => {
    if (command === '/usr/bin/lipo') merges++;
    const result = macImageTool(command, args, timeout);
    if (command === '/usr/bin/codesign' && args.includes('--deep') && args.at(-1) === app) put(f.output, 'unknown', 'retain namespace change');
    return result;
  };
  await assert.rejects(macSourceCohort(f, { tool }), /replay custody/); assert.equal(merges, 0); assert.ok(readFileSync(join(f.output, 'cohort.json')).equals(original));
  rmSync(join(f.output, 'unknown')); let inspectedUniversal = false;
  const lateChange = (command, args, timeout) => {
    assert.notEqual(command, '/usr/bin/lipo');
    const result = macImageTool(command, args, timeout);
    if (command === '/usr/bin/codesign' && args.includes('--deep')) {
      if (args.at(-1) === app) inspectedUniversal = true;
      else if (inspectedUniversal) put(app, 'Contents/Resources/changed', 'retain change during input recheck');
    }
    return result;
  };
  await assert.rejects(macSourceCohort(f, { tool: lateChange }), /universal bytes changed/);
  await assert.rejects(macSourceCohort(f)); assert.ok(readFileSync(join(f.output, 'cohort.json')).equals(original));
});

test('cohort CLI has fixed usage/refusal without exposing private paths', t => {
  const cli = new URL('./cohort-cli.mjs', import.meta.url).pathname;
  assert.equal(spawnSync(process.execPath, [cli], { encoding: 'utf8', timeout: 2000 }).status, 64);
  const bad = spawnSync(process.execPath, [cli, 'v0.1.0', 'f'.repeat(40), join(temporary(t), 'secret-source'), 'arm', 'f'.repeat(64), 'intel', 'f'.repeat(64), 'unused-output'], { encoding: 'utf8', timeout: 2000 });
  assert.equal(bad.status, 1); assert.equal(bad.stdout, ''); assert.equal(bad.stderr, 'source-bound Mac cohort refused; existing output retained\n');
});
