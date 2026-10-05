import assert from 'node:assert/strict';
import { execFileSync, spawnSync } from 'node:child_process';
import { chmodSync, copyFileSync, linkSync, lstatSync, mkdirSync, mkdtempSync, readFileSync, readdirSync, rmSync, symlinkSync, truncateSync, writeFileSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { dirname, join, resolve } from 'node:path';
import test from 'node:test';
import { inspectGleamMetadata, prepareGleamMetadata } from './gleam-metadata.mjs';
import { recordInputs, verifyInputs } from './inputs.mjs';

const owner = resolve(new URL('..', import.meta.url).pathname);
const canonical = '[packages]\nexample = "1.0.0"\nhelper = "2.0.0"\n\n[git]\n';
const reordered = '[packages]\nhelper = "2.0.0"\nexample = "1.0.0"\n\n[git]\n';
function put(root, path, bytes) { const file = join(root, path); mkdirSync(dirname(file), { recursive: true }); writeFileSync(file, bytes); return file; }
async function fixture(t) {
  const repository = mkdtempSync(join(tmpdir(), 'frameshift-gleam-metadata-')); t.after(() => rmSync(repository, { recursive: true, force: true }));
  const git = args => execFileSync('git', args, { cwd: repository, encoding: 'utf8', stdio: 'pipe', timeout: 30_000 }).trim();
  for (const name of readdirSync(join(owner, 'release'))) if ((name.endsWith('.mjs') && !name.endsWith('.test.mjs')) || name.endsWith('.exs')) put(repository, 'release/' + name, readFileSync(join(owner, 'release', name)));
  copyFileSync(join(owner, '.mise.toml'), join(repository, '.mise.toml')); put(repository, '.gitignore', 'var/\nbuild/\n');
  put(repository, 'apps/core/mix.exs', 'defmodule Fixture do\n  @moduledoc false\n\n  use Mix.Project\n  def project, do: [app: :frameshift_core, version: "1.2.3"]\nend\n');
  put(repository, 'packages/decision-kernel/gleam.toml', 'name = "frameshift_decisions"\nversion = "0.1.0"\n\n[dependencies]\nexample = "~> 1.0"\nhelper = "~> 2.0"\n');
  put(repository, 'packages/decision-kernel/manifest.toml', 'packages = [\n  { name = "example", version = "1.0.0", build_tools = ["gleam"], requirements = [], source = "hex", outer_checksum = "' + 'A'.repeat(64) + '" },\n  { name = "helper", version = "2.0.0", build_tools = ["gleam"], requirements = [], source = "hex", outer_checksum = "' + 'B'.repeat(64) + '" },\n]\n\n[requirements]\nexample = { version = "~> 1.0" }\nhelper = { version = "~> 2.0" }\n');
  git(['init', '-b', 'main']); git(['add', '.']); git(['-c', 'user.name=Fixture', '-c', 'user.email=fixture@example.invalid', 'commit', '-m', 'test(release): define fetched metadata source']);
  const commit = git(['rev-parse', 'HEAD']), tag = 'v1.2.3'; git(['tag', tag]); mkdirSync(join(repository, 'var'), { mode: 0o700 }); await recordInputs(repository, tag, commit, join(repository, 'var/inputs'));
  const root = join(repository, 'packages/decision-kernel/build/packages'), path = put(root, 'packages.toml', reordered); chmodSync(path, 0o600);
  put(root, 'gleam.lock', ''); for (const name of ['example', 'helper']) mkdirSync(join(root, name));
  return { repository, git, tag, commit, sourcePath: join(repository, 'var/inputs/source-inputs.json'), root, path };
}

test('tagged generated metadata prepares exact ordered bytes/mode and unchanged private CLI replay', async t => {
  const f = await fixture(t), before = lstatSync(f.path), result = await prepareGleamMetadata(f);
  assert.equal(result.publicationAuthority, 'none'); assert.equal(result.disposition, 'generated-metadata-prepared');
  assert.equal(readFileSync(f.path, 'utf8'), canonical); assert.equal(lstatSync(f.path).mode & 0o7777, 0o600); assert.notEqual(lstatSync(f.path).ino, before.ino);
  const stat = lstatSync(f.path), replay = await prepareGleamMetadata(f); assert.equal(replay.metadataSha256, result.metadataSha256); assert.equal(replay.disposition, 'canonical-bytes-verified');
  assert.equal(lstatSync(f.path).ino, stat.ino); assert.equal(lstatSync(f.path).mtimeMs, stat.mtimeMs); assert.deepEqual(readdirSync(f.root).sort(), ['example', 'gleam.lock', 'helper', 'packages.toml']);
  const cli = JSON.parse(execFileSync('mise', ['exec', '--', 'node', join(f.repository, 'release/gleam-metadata-cli.mjs'), f.tag, f.commit, f.sourcePath], { cwd: f.repository, encoding: 'utf8', timeout: 60_000, maxBuffer: 64 * 1024 }));
  assert.equal(cli.disposition, 'canonical-bytes-verified'); assert.equal(cli.metadataSha256, result.metadataSha256); assert.equal(lstatSync(f.path).ino, stat.ino);
});

test('unsupported metadata/version/Git state, unsafe files/paths and size refuse without replacement', async t => {
  const f = await fixture(t);
  for (const bytes of [reordered.replace('1.0.0', '1.0.1'), reordered + 'example = "git"\n', reordered.replace('helper = "2.0.0"', 'example = "2.0.0"'), '[packages]\n\n[git]\n', reordered.replace('helper', '../helper')]) {
    writeFileSync(f.path, bytes); await assert.rejects(prepareGleamMetadata(f)); assert.equal(readFileSync(f.path, 'utf8'), bytes);
  }
  writeFileSync(f.path, reordered); const alias = join(f.repository, 'var/alias'); linkSync(f.path, alias); await assert.rejects(prepareGleamMetadata(f), /unsafe/); rmSync(alias);
  chmodSync(f.path, 0o666); await assert.rejects(prepareGleamMetadata(f), /unsafe/); chmodSync(f.path, 0o600);
  truncateSync(f.path, 64 * 1024 + 1); await assert.rejects(prepareGleamMetadata(f), /size/); writeFileSync(f.path, reordered);
  rmSync(f.path); symlinkSync('gleam.lock', f.path); await assert.rejects(prepareGleamMetadata(f), /unsafe/); rmSync(f.path);
  execFileSync('mkfifo', [f.path]); await assert.rejects(prepareGleamMetadata(f), /unsafe/); rmSync(f.path); writeFileSync(f.path, reordered, { mode: 0o600 });
  chmodSync(f.root, 0o777); await assert.rejects(prepareGleamMetadata(f), /directory/); chmodSync(f.root, 0o755);
  writeFileSync(join(f.root, 'gleam.lock'), 'busy'); await assert.rejects(prepareGleamMetadata(f)); assert.equal(readFileSync(f.path, 'utf8'), reordered);
});

test('hidden frozen source, missing package and retained partial preparation refuse without resuming', async t => {
  const f = await fixture(t); writeFileSync(join(f.root, '.prepare-metadata.pending'), 'retain'); await assert.rejects(prepareGleamMetadata(f), /custody/); assert.equal(readFileSync(join(f.root, '.prepare-metadata.pending'), 'utf8'), 'retain'); rmSync(join(f.root, '.prepare-metadata.pending'));
  writeFileSync(join(f.root, '.packages.toml.prepared'), 'retain'); await assert.rejects(prepareGleamMetadata(f), /custody/); assert.equal(readFileSync(join(f.root, '.packages.toml.prepared'), 'utf8'), 'retain'); rmSync(join(f.root, '.packages.toml.prepared'));
  rmSync(join(f.root, 'helper'), { recursive: true }); await assert.rejects(prepareGleamMetadata(f), /custody/); mkdirSync(join(f.root, 'helper'));
  const path = 'packages/decision-kernel/manifest.toml'; f.git(['update-index', '--assume-unchanged', path]); writeFileSync(join(f.repository, path), readFileSync(join(f.repository, path), 'utf8').replace('1.0.0', '1.0.1'));
  assert.equal(f.git(['status', '--porcelain']), ''); await assert.rejects(prepareGleamMetadata(f)); assert.equal(readFileSync(f.path, 'utf8'), reordered);
});

test('mutation after the final source child refuses prepared or unchanged custody', async t => {
  for (const mutation of ['metadata', 'pending', 'prepared', 'package', 'source', 'canonical']) {
    const f = await fixture(t); let calls = 0; if (mutation === 'canonical') writeFileSync(f.path, canonical);
    const verify = async (...args) => {
      const result = await verifyInputs(...args);
      if (++calls === 2) {
        if (mutation === 'metadata' || mutation === 'canonical') writeFileSync(f.path, reordered.replace('2.0.0', '2.0.1'));
        if (mutation === 'pending') writeFileSync(join(f.root, '.prepare-metadata.pending'), 'changed');
        if (mutation === 'prepared') writeFileSync(join(f.root, '.packages.toml.prepared'), 'changed');
        if (mutation === 'package') { rmSync(join(f.root, 'helper'), { recursive: true }); symlinkSync('example', join(f.root, 'helper')); }
        if (mutation === 'source') writeFileSync(join(f.repository, 'packages/decision-kernel/manifest.toml'), 'changed');
      }
      return result;
    };
    await assert.rejects(prepareGleamMetadata(f, { verify }));
    if (mutation !== 'canonical') assert.equal(lstatSync(join(f.root, '.prepare-metadata.pending')).mode & 0o7777, 0o600);
    assert.equal(readFileSync(f.path, 'utf8'), mutation === 'metadata' || mutation === 'canonical' ? reordered.replace('2.0.0', '2.0.1') : reordered);
  }
});

test('five pinned Gleam dependency processes converge to identical prepared metadata', async t => {
  const f = await fixture(t), hashes = [], gleam = execFileSync('mise', ['which', 'gleam'], { cwd: owner, encoding: 'utf8' }).trim();
  assert.equal(execFileSync(gleam, ['--version'], { encoding: 'utf8' }).trim(), 'gleam 1.18.1');
  for (let attempt = 0; attempt < 5; attempt++) {
    execFileSync(gleam, ['deps', 'download'], { cwd: join(f.repository, 'packages/decision-kernel'), timeout: 30_000, stdio: 'pipe' });
    hashes.push((await prepareGleamMetadata(f)).metadataSha256); assert.equal((await inspectGleamMetadata(f.repository)).bytes.toString(), canonical);
  }
  assert.equal(new Set(hashes).size, 1);
});

test('metadata preparation CLI has fixed private usage/refusal', () => {
  const cli = new URL('./gleam-metadata-cli.mjs', import.meta.url).pathname;
  assert.equal(spawnSync(process.execPath, [cli], { encoding: 'utf8', timeout: 2000 }).status, 64);
  const result = spawnSync(process.execPath, [cli, 'v1.2.3', 'f'.repeat(40), 'private-source-record'], { encoding: 'utf8', timeout: 2000 });
  assert.equal(result.status, 1); assert.equal(result.stdout, ''); assert.equal(result.stderr, 'Gleam generated metadata preparation refused; retained input and incomplete custody preserved\n');
});
