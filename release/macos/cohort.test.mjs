import assert from 'node:assert/strict';
import { createHash } from 'node:crypto';
import { execFileSync, spawnSync } from 'node:child_process';
import { copyFileSync, existsSync, linkSync, lstatSync, mkdirSync, readFileSync, renameSync, rmSync, symlinkSync, truncateSync, writeFileSync } from 'node:fs';
import { dirname, join, resolve } from 'node:path';
import test from 'node:test';
import { recordInputs, verifyInputs } from '../inputs.mjs';
import { macMaterial } from './candidate.mjs';
import { auditMacBundle } from './closure.mjs';
import { inspectMacCandidate, macSourceCohort } from './cohort.mjs';
import { macImageTool } from './dmg.mjs';
import { fixture as nativeFixture, run, temporary } from './fixture.mjs';
import { prepareDevelopmentBundle } from './prepare.mjs';

const owner = resolve(new URL('../..', import.meta.url).pathname), mac = { skip: process.platform !== 'darwin' };
const encode = value => Buffer.from(JSON.stringify(value) + '\n');
const hash = value => createHash('sha256').update(value).digest('hex');
function put(root, path, bytes) { const full = join(root, path); mkdirSync(dirname(full), { recursive: true }); writeFileSync(full, bytes); }
async function fixture(t) {
  const repository = temporary(t), git = args => execFileSync('git', args, { cwd: repository, encoding: 'utf8', stdio: 'pipe' }).trim();
  for (const path of ['.mise.toml', 'release/read-version.exs', 'release/linux/verify-version.exs']) { mkdirSync(dirname(join(repository, path)), { recursive: true }); copyFileSync(join(owner, path), join(repository, path)); }
  put(repository, '.gitignore', 'var/\n_build/\ndeps/\nbuild/\n'); put(repository, 'README.md', 'exact source\n');
  put(repository, 'apps/core/mix.exs', 'defmodule Fixture do\n  @moduledoc false\n\n  use Mix.Project\n  def project, do: [app: :frameshift_core, version: "0.1.0"]\nend\n');
  git(['init', '-b', 'main']); git(['add', '.']); git(['-c', 'user.name=Fixture', '-c', 'user.email=fixture@example.invalid', 'commit', '-m', 'test(mac): define source-bound compiler fixture']);
  const commit = git(['rev-parse', 'HEAD']), tag = 'v0.1.0'; git(['tag', tag]); mkdirSync(join(repository, 'var'), { mode: 0o700 });
  await recordInputs(repository, tag, commit, join(repository, 'var/inputs'));
  const sourcePath = join(repository, 'var/inputs/source-inputs.json'), source = await verifyInputs(repository, tag, commit, sourcePath);
  put(repository, 'apps/core/deps/example/source.c', 'dependency source\n'); put(repository, 'packages/decision-kernel/build/packages/example/source.gleam', 'Gleam source\n');
  const material = await macMaterial(repository), candidates = [];
  for (const architecture of ['arm64', 'x86_64']) {
    const f = nativeFixture(t, architecture), candidate = join(repository, 'var', architecture); mkdirSync(candidate, { mode: 0o700 });
    const app = f.root;
    const plist = join(app, 'Contents/Info.plist'); writeFileSync(plist, readFileSync(plist, 'utf8').replace('io.frameshift.closure-fixture', 'io.frameshift.app'));
    const core = join(app, 'Contents/Resources/core'); renameSync(join(core, 'erts-fixture'), join(core, 'erts-17.1'));
    put(core, 'releases/start_erl.data', '17.1 0.1.0');
    put(core, 'releases/0.1.0/frameshift_core.rel', '{release,{"frameshift_core","0.1.0"},{erts,"17.1"},[{frameshift_core,"0.1.0",permanent}]}.\n');
    put(core, 'lib/frameshift_core-0.1.0/ebin/frameshift_core.app', '{application,frameshift_core,[{vsn,"0.1.0"}]}.\n');
    await prepareDevelopmentBundle(app, architecture);
    // These are explicit compiler-purpose assertions, not remote/native Intel
    // producer evidence. The fixture executes actual cross-CPU compiled code.
    const execution = { architecture, native: true, macOS: run('/usr/bin/sw_vers', ['-productVersion']), osBuild: run('/usr/bin/sw_vers', ['-buildVersion']),
      xcode: run('/usr/bin/xcodebuild', ['-version']), sdkVersion: run('/usr/bin/xcrun', ['--show-sdk-version']), sdkBuild: run('/usr/bin/xcrun', ['--show-sdk-build-version']),
      swift: run('/usr/bin/swift', ['--version']).split('\n')[0] + `\nTarget: ${architecture}-apple-macosx27.0.0`, elixir: run('mise', ['exec', '--', 'elixir', '--version']), zig: '0.16.0' };
    const record = { schemaVersion: 1, kind: 'macos-native-build-candidate', product: source.product, publicationAuthority: 'none', tag, version: source.version, sourceCommit: commit,
      sourceInputsSha256: hash(encode(source)), architecture, execution, material, bundle: await auditMacBundle(app, architecture) };
    renameSync(app, join(candidate, 'Frameshift.app'));
    const bytes = encode(record); writeFileSync(join(candidate, 'candidate.json'), bytes, { mode: 0o600 }); candidates.push({ candidate, record, bytes, sha256: hash(bytes) });
  }
  return { repository, git, tag, commit, sourcePath, source, armCandidate: candidates[0].candidate, armSha256: candidates[0].sha256, intelCandidate: candidates[1].candidate, intelSha256: candidates[1].sha256, candidates, output: join(repository, 'var/cohort') };
}
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
