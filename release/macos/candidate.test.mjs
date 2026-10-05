import assert from 'node:assert/strict';
import { execFileSync, spawnSync } from 'node:child_process';
import { copyFileSync, cpSync, existsSync, lstatSync, mkdirSync, readFileSync, readdirSync, renameSync, rmSync, symlinkSync, writeFileSync } from 'node:fs';
import { dirname, join, resolve } from 'node:path';
import test from 'node:test';
import { recordInputs } from '../inputs.mjs';
import { candidateCommand, macBuildCandidate, macMaterial } from './candidate.mjs';
import { prepareDevelopmentBundle } from './prepare.mjs';
import { fixture as nativeFixture, temporary } from './fixture.mjs';

const owner = resolve(new URL('../..', import.meta.url).pathname), mac = { skip: process.platform !== 'darwin' || process.arch !== 'arm64' };
function put(root, relative, bytes) { const path = join(root, relative); mkdirSync(dirname(path), { recursive: true }); writeFileSync(path, bytes); }
async function fixture(t, buildVersion = '0.1.0') {
  const repository = temporary(t), prototype = nativeFixture(t), git = args => execFileSync('git', args, { cwd: repository, encoding: 'utf8', stdio: 'pipe' }).trim();
  for (const path of ['.mise.toml', 'release/read-version.exs', 'release/linux/verify-version.exs']) {
    mkdirSync(dirname(join(repository, path)), { recursive: true }); copyFileSync(join(owner, path), join(repository, path));
  }
  put(repository, '.gitignore', 'var/\n_build/\n.build/\ndeps/\nbuild/\n');
  put(repository, 'README.md', 'exact source\n'); put(repository, 'apps/core/mix.lock', '{}\n');
  put(repository, 'apps/core/mix.exs', 'defmodule Fixture do\n  @moduledoc false\n\n  use Mix.Project\n  def project, do: [app: :frameshift_core, version: "0.1.0"]\nend\n');
  const plist = join(prototype.root, 'Contents/Info.plist');
  writeFileSync(plist, readFileSync(plist, 'utf8').replace('io.frameshift.closure-fixture', 'io.frameshift.app'));
  if (buildVersion !== '0.1.0') execFileSync('/usr/bin/plutil', ['-replace', 'CFBundleVersion', '-string', buildVersion, plist]);
  mkdirSync(join(repository, 'apps/macos/App'), { recursive: true }); copyFileSync(plist, join(repository, 'apps/macos/App/Info.plist'));
  put(repository, 'scripts/package-macos', '#!/bin/sh\nexit 0\n');
  put(repository, 'packages/decision-kernel/manifest.toml', 'packages = [\n  { name = "example", version = "1.0.0", build_tools = ["gleam"], requirements = [], source = "hex", outer_checksum = "' + 'A'.repeat(64) + '" },\n  { name = "helper", version = "2.0.0", build_tools = ["gleam"], requirements = [], source = "hex", outer_checksum = "' + 'B'.repeat(64) + '" },\n]\n\n[requirements]\nexample = { version = "~> 1.0" }\nhelper = { version = "~> 2.0" }\n');
  git(['init', '-b', 'main']); git(['add', '.']);
  git(['-c', 'user.name=Fixture', '-c', 'user.email=fixture@example.invalid', 'commit', '-m', 'test(mac): define exact tagged compiler fixture']);
  const commit = git(['rev-parse', 'HEAD']); git(['tag', 'v0.1.0']);
  put(repository, 'apps/core/deps/example/source.c', 'exact dependency material\n');
  put(repository, 'packages/decision-kernel/build/packages/example/source.gleam', 'exact Gleam material\n');
  put(repository, 'packages/decision-kernel/build/packages/helper/source.gleam', 'exact helper material\n');
  put(repository, 'packages/decision-kernel/build/packages/packages.toml', '[packages]\nexample = "1.0.0"\nhelper = "2.0.0"\n\n[git]\n');
  put(repository, 'packages/decision-kernel/build/packages/gleam.lock', '');
  mkdirSync(join(repository, 'var'), { mode: 0o700 });
  await recordInputs(repository, 'v0.1.0', commit, join(repository, 'var/inputs'));
  const core = join(prototype.root, 'Contents/Resources/core');
  renameSync(join(core, 'erts-fixture'), join(core, 'erts-17.1'));
  put(core, 'releases/start_erl.data', '17.1 0.1.0');
  put(core, 'releases/0.1.0/frameshift_core.rel', '{release,{"frameshift_core","0.1.0"},{erts,"17.1"},[{frameshift_core,"0.1.0",permanent}]}.\n');
  put(core, 'lib/frameshift_core-0.1.0/ebin/frameshift_core.app', '{application,frameshift_core,[{vsn,"0.1.0"}]}.\n');
  await prepareDevelopmentBundle(prototype.root, 'arm64');
  return { repository, git, prototype: prototype.root, tag: 'v0.1.0', commit, sourcePath: join(repository, 'var/inputs/source-inputs.json'), architecture: 'arm64', output: join(repository, 'var/candidate') };
}
function executor(f, mutation = '') {
  let built = false;
  return (command, args, options) => {
    if (command.endsWith('/scripts/package-macos')) {
      assert.equal(options.timeout, 30 * 60_000); built = true;
      const app = join(f.repository, 'apps/macos/.build/artifacts/Frameshift.app'); mkdirSync(dirname(app), { recursive: true }); cpSync(f.prototype, app, { recursive: true });
      if (mutation === 'source') { f.git(['update-index', '--assume-unchanged', 'README.md']); put(f.repository, 'README.md', 'hidden source mutation'); }
      if (mutation === 'material') put(f.repository, 'apps/core/deps/example/source.c', 'changed dependency');
      if (mutation === 'version') put(app, 'Contents/Resources/core/releases/start_erl.data', '17.1 0.2.0');
      if (mutation === 'bundle-version') execFileSync('/usr/bin/plutil', ['-replace', 'CFBundleVersion', '-string', '1', join(app, 'Contents/Info.plist')]);
      if (mutation === 'metadata-order') put(f.repository, 'packages/decision-kernel/build/packages/packages.toml', '[packages]\nhelper = "2.0.0"\nexample = "1.0.0"\n\n[git]\n');
      if (mutation === 'metadata-version') put(f.repository, 'packages/decision-kernel/build/packages/packages.toml', '[packages]\nexample = "1.0.1"\nhelper = "2.0.0"\n\n[git]\n');
      return '';
    }
    if (built && mutation === 'tool' && command === '/usr/bin/xcrun' && args[0] === '--show-sdk-version') return '999.0';
    const result = candidateCommand(command, args, options);
    if (mutation === 'copy' && command === '/usr/bin/ditto') put(args[1], 'Contents/Resources/substituted', 'changed copy');
    return result;
  };
}

test('exact Git/Mix source and native compiler roles join retained descriptors, inputs and no-build replay', mac, async t => {
  const f = await fixture(t), record = await macBuildCandidate(f, executor(f));
  assert.equal(record.publicationAuthority, 'none'); assert.equal(record.tag, 'v0.1.0'); assert.equal(record.disposition, 'native-build-candidate');
  const path = join(f.output, 'candidate.json'), bytes = readFileSync(path), before = lstatSync(path);
  const replay = await macBuildCandidate(f, (command, args, options) => {
    assert.equal(command.endsWith('/scripts/package-macos'), false); return candidateCommand(command, args, options);
  });
  assert.equal(replay.disposition, 'retained-bytes-verified'); assert.equal(replay.recordSha256, record.recordSha256);
  assert.ok(readFileSync(path).equals(bytes)); assert.equal(lstatSync(path).mtimeMs, before.mtimeMs); assert.equal(before.mode & 0o7777, 0o600);
  assert.equal(JSON.parse(bytes).bundle.natives.length, 7); assert.equal(JSON.parse(bytes).material.length, 5);
});

test('wrong source, physical CPU and mutable artifact overlap refuse before building or creating output', mac, async t => {
  const f = await fixture(t); let builds = 0;
  const execute = (command, args, options) => { if (command.endsWith('/scripts/package-macos')) builds++; return candidateCommand(command, args, options); };
  await assert.rejects(macBuildCandidate({ ...f, commit: 'f'.repeat(40) }, execute));
  await assert.rejects(macBuildCandidate({ ...f, architecture: 'x86_64' }, execute), /physical Mac CPU/);
  mkdirSync(join(f.repository, 'apps/macos/.build/artifacts'), { recursive: true });
  await assert.rejects(macBuildCandidate({ ...f, output: join(f.repository, 'apps/macos/.build/artifacts/candidate') }, execute), /overlaps/);
  assert.equal(builds, 0); assert.equal(existsSync(f.output), false);
});

test('a clean stable source with a fixed bundle build counter refuses before packaging', mac, async t => {
  const f = await fixture(t, '1'); let builds = 0;
  await assert.rejects(macBuildCandidate(f, (command, args, options) => {
    if (command.endsWith('/scripts/package-macos')) builds++;
    return candidateCommand(command, args, options);
  }), /bundle version differs/);
  assert.equal(builds, 0); assert.equal(existsSync(f.output), false);
});

test('source, material, tool, version and copied bytes changing during work retain incomplete output', mac, async t => {
  for (const mutation of ['source', 'material', 'tool', 'version', 'bundle-version', 'copy', 'metadata-version']) {
    const f = await fixture(t);
    await assert.rejects(macBuildCandidate(f, executor(f, mutation)));
    assert.ok(existsSync(join(f.output, 'build.pending'))); assert.equal(existsSync(join(f.output, 'candidate.json')), false);
    if (mutation === 'copy') assert.ok(existsSync(join(f.output, 'Frameshift.app/Contents/Resources/substituted')));
  }
});

test('new producer normalizes only equivalent generated metadata and retained replay performs no preparation', mac, async t => {
  const f = await fixture(t), before = await macMaterial(f.repository), result = await macBuildCandidate(f, executor(f, 'metadata-order'));
  assert.equal(result.disposition, 'native-build-candidate'); assert.deepEqual(await macMaterial(f.repository), before);
  const path = join(f.repository, 'packages/decision-kernel/build/packages/packages.toml');
  writeFileSync(path, '[packages]\nhelper = "2.0.0"\nexample = "1.0.0"\n\n[git]\n'); const changed = readFileSync(path), stat = lstatSync(path);
  await assert.rejects(macBuildCandidate(f, executor(f)), /inputs or bytes changed/);
  assert.ok(readFileSync(path).equals(changed)); assert.equal(lstatSync(path).ino, stat.ino); assert.equal(lstatSync(path).mtimeMs, stat.mtimeMs);
  const fresh = { ...f, output: join(f.repository, 'var/noncanonical') }; let builds = 0;
  await assert.rejects(macBuildCandidate(fresh, (command, args, options) => { if (command.endsWith('/scripts/package-macos')) builds++; return candidateCommand(command, args, options); }), /preparation required/);
  assert.equal(builds, 0); assert.equal(existsSync(fresh.output), false);
});

test('candidate aliases, unknown members and changed app custody refuse without replacing retained bytes', mac, async t => {
  const f = await fixture(t); await macBuildCandidate(f, executor(f));
  const path = join(f.output, 'candidate.json'), bytes = readFileSync(path);
  put(f.output, 'unknown', 'retain'); await assert.rejects(macBuildCandidate(f, executor(f)), /incomplete/); assert.equal(readFileSync(join(f.output, 'unknown'), 'utf8'), 'retain');
  rmSync(join(f.output, 'unknown')); rmSync(path); symlinkSync(join(f.output, 'Frameshift.app/Contents/Info.plist'), path);
  await assert.rejects(macBuildCandidate(f, executor(f)), /regular/); rmSync(path); writeFileSync(path, bytes, { mode: 0o600 });
  put(f.output, 'Frameshift.app/Contents/Resources/changed', 'retain changed app');
  await assert.rejects(macBuildCandidate(f, executor(f))); assert.ok(readFileSync(path).equals(bytes));
});

test('material inventory excludes private Git/generated code and refuses regular-file aliases', async t => {
  const root = temporary(t);
  put(root, 'apps/core/deps/example/source', 'source'); put(root, 'packages/decision-kernel/build/packages/example/source', 'Gleam source');
  put(root, 'apps/core/deps/exile/priv/spawner', 'generated'); put(root, 'apps/core/deps/example/.git/config', 'private fixture configuration');
  assert.equal((await macMaterial(root)).length, 2);
  symlinkSync('source', join(root, 'apps/core/deps/example/alias'));
  await assert.rejects(macMaterial(root), /links and special/);
});

test('candidate command deadline and fixed CLI usage/refusal do not disclose supplied paths', t => {
  assert.throws(() => candidateCommand(process.execPath, ['-e', 'setTimeout(()=>{},10000)'], { timeout: 50 }), /tool unavailable/);
  const cli = new URL('./candidate-cli.mjs', import.meta.url).pathname;
  assert.equal(spawnSync(process.execPath, [cli], { encoding: 'utf8', timeout: 2000 }).status, 64);
  const bad = spawnSync(process.execPath, [cli, 'v0.1.0', 'f'.repeat(40), join(temporary(t), 'secret-source'), 'arm64', 'unused-output'], { encoding: 'utf8', timeout: 2000 });
  assert.equal(bad.status, 1); assert.equal(bad.stdout, ''); assert.equal(bad.stderr, 'tagged Mac build candidate refused; existing output retained\n');
});
