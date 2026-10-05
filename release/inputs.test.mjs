import assert from 'node:assert/strict';
import { execFileSync } from 'node:child_process';
import { chmodSync, copyFileSync, lstatSync, mkdirSync, mkdtempSync, readFileSync, readdirSync, rmSync, symlinkSync, writeFileSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { dirname, join, resolve } from 'node:path';
import test from 'node:test';
import { fileURLToPath } from 'node:url';
import { captureInputs, recordInputs, verifyInputs } from './inputs.mjs';
import { releaseSourceIdentity } from './source.mjs';

const repository = resolve(dirname(fileURLToPath(import.meta.url)), '..');
function fixture(t, version = '1.2.3', mutation = '') {
  const root = mkdtempSync(join(tmpdir(), 'frameshift-release-inputs-'));
  t.after(() => rmSync(root, { recursive: true, force: true }));
  const git = args => execFileSync('git', args, { cwd: root, encoding: 'utf8', stdio: 'pipe' }).trim();
  git(['init', '-b', 'main']);
  mkdirSync(join(root, 'apps/core'), { recursive: true });
  mkdirSync(join(root, 'release'));
  mkdirSync(join(root, 'var'), { mode: 0o700 });
  copyFileSync(join(repository, '.mise.toml'), join(root, '.mise.toml'));
  copyFileSync(join(repository, 'release/read-version.exs'), join(root, 'release/read-version.exs'));
  writeFileSync(join(root, '.gitignore'), '_build/\nvar/\n');
  writeFileSync(join(root, 'README.md'), 'exact source\n');
  writeFileSync(join(root, 'apps/core/mix.lock'), '{}\n');
  writeFileSync(join(root, 'apps/core/mix.exs'), `defmodule FixtureProject do\n  @moduledoc false\n\n  use Mix.Project\n  def project do\n    ${mutation}\n    [app: :frameshift_core, version: "${version}"]\n  end\nend\n`);
  const commit = () => {
    git(['add', '.']);
    git(['-c', 'user.name=Fixture', '-c', 'user.email=fixture@example.invalid', 'commit', '-m', 'test(host): define source fixture']);
    git(['tag', '-f', 'v1.2.3']);
    return git(['rev-parse', 'HEAD']);
  };
  const sha = commit();
  return { root, git, sha, commit, output: join(root, 'var/inputs') };
}

test('actual Git/Mix source binds deterministic private output and identical rerun without rewriting', async t => {
  const { root, sha, output } = fixture(t);
  const record = await recordInputs(root, 'v1.2.3', sha, output);
  assert.equal(record.version, '1.2.3');
  assert.equal(record.publicationAuthority, 'none');
  assert.deepEqual(record.dependencyLocks, ['apps/core/mix.lock']);
  assert.equal(record.files.find(file => file.path === 'README.md').bytes, 13);
  assert.equal(lstatSync(output).mode & 0o7777, 0o700);
  const path = join(output, 'source-inputs.json');
  assert.equal(lstatSync(path).mode & 0o7777, 0o600);
  const before = lstatSync(path);
  assert.deepEqual(await recordInputs(root, 'v1.2.3', sha, output), record);
  assert.equal(lstatSync(path).ino, before.ino);
  assert.equal(lstatSync(path).mtimeMs, before.mtimeMs);
  await verifyInputs(root, 'v1.2.3', sha, path);
});

test('development/version mismatch and malformed/missing/moved tag or commit refuse', async t => {
  const dev = fixture(t, '1.2.3-dev');
  await assert.rejects(() => recordInputs(dev.root, 'v1.2.3', dev.sha, dev.output), /version differs/);
  assert.equal(readdirSync(join(dev.root, 'var')).length, 0);
  const { root, git, sha } = fixture(t);
  for (const tag of ['v1.2.3-dev', 'v01.2.3', '--help', 'v1.2.4']) {
    assert.throws(() => releaseSourceIdentity(root, tag, sha));
  }
  assert.throws(() => releaseSourceIdentity(root, 'v1.2.3', 'f'.repeat(40)));
  writeFileSync(join(root, 'README.md'), 'different source');
  git(['add', '.']);
  git(['-c', 'user.name=Fixture', '-c', 'user.email=fixture@example.invalid', 'commit', '-m', 'test(host): change fixture source']);
  const moved = git(['rev-parse', 'HEAD']);
  assert.throws(() => releaseSourceIdentity(root, 'v1.2.3', moved));
  git(['tag', '-f', 'v1.2.3']);
  assert.throws(() => releaseSourceIdentity(root, 'v1.2.3', sha));
});

test('hidden content and executable-mode changes refuse despite clean Git status', async t => {
  const { root, git, sha } = fixture(t);
  git(['update-index', '--assume-unchanged', 'README.md']);
  writeFileSync(join(root, 'README.md'), 'hidden bytes\n');
  assert.equal(git(['status', '--porcelain']), '');
  await assert.rejects(() => captureInputs(root, 'v1.2.3', sha), /bytes changed or differ/);
  writeFileSync(join(root, 'README.md'), 'exact source\n');
  git(['config', 'core.fileMode', 'false']);
  chmodSync(join(root, 'README.md'), 0o755);
  assert.equal(git(['status', '--porcelain']), '');
  await assert.rejects(() => captureInputs(root, 'v1.2.3', sha), /mode\/type/);
});

test('dirty/untracked source, committed symlink and replaced final inode refuse', async t => {
  const { root, git, sha, commit } = fixture(t);
  writeFileSync(join(root, 'untracked'), 'untracked');
  await assert.rejects(() => captureInputs(root, 'v1.2.3', sha), /clean exact/);
  rmSync(join(root, 'untracked'));
  git(['update-index', '--assume-unchanged', 'README.md']);
  rmSync(join(root, 'README.md'));
  symlinkSync('.mise.toml', join(root, 'README.md'));
  await assert.rejects(() => captureInputs(root, 'v1.2.3', sha));
  git(['update-index', '--no-assume-unchanged', 'README.md']);
  const next = commit();
  await assert.rejects(() => captureInputs(root, 'v1.2.3', next), /unsupported tracked/);
});

test('unsafe/conflicting/incomplete output refuses and preserves every existing byte', async t => {
  const { root, sha, output } = fixture(t);
  await recordInputs(root, 'v1.2.3', sha, output);
  const path = join(output, 'source-inputs.json');
  const before = readFileSync(path);
  writeFileSync(join(output, 'unrelated'), 'retain');
  await assert.rejects(() => recordInputs(root, 'v1.2.3', sha, output), /conflicting/);
  assert.deepEqual(readFileSync(path), before);
  rmSync(join(output, 'unrelated'));
  chmodSync(path, 0o644);
  await assert.rejects(() => recordInputs(root, 'v1.2.3', sha, output), /unsafe/);
  assert.deepEqual(readFileSync(path), before);
  const empty = join(root, 'var/empty');
  mkdirSync(empty, { mode: 0o700 });
  await assert.rejects(() => recordInputs(root, 'v1.2.3', sha, empty));
  assert.deepEqual(readdirSync(empty), []);
  const alias = join(root, 'var/alias');
  symlinkSync(output, alias);
  await assert.rejects(() => recordInputs(root, 'v1.2.3', sha, alias), /unsafe/);
});

test('post-build verification detects hidden changes while preserving the frozen record', async t => {
  const { root, git, sha, output } = fixture(t);
  await recordInputs(root, 'v1.2.3', sha, output);
  const path = join(output, 'source-inputs.json');
  const before = readFileSync(path);
  git(['update-index', '--assume-unchanged', 'README.md']);
  writeFileSync(join(root, 'README.md'), 'hidden build mutation');
  await assert.rejects(() => verifyInputs(root, 'v1.2.3', sha, path));
  assert.deepEqual(readFileSync(path), before);
});

test('a version query changing hidden source cannot publish a partial input record', async t => {
  const { root, git, sha, output } = fixture(t, '1.2.3', 'File.write!("../../README.md", "query mutated source")');
  git(['update-index', '--assume-unchanged', 'README.md']);
  await assert.rejects(() => recordInputs(root, 'v1.2.3', sha, output));
  assert.deepEqual(readdirSync(join(root, 'var')), []);
});

test('replacement objects and caller Git-directory/index overrides cannot substitute tagged source', async t => {
  const { root, git, sha } = fixture(t);
  writeFileSync(join(root, 'README.md'), 'replacement object bytes');
  git(['add', '.']);
  git(['-c', 'user.name=Fixture', '-c', 'user.email=fixture@example.invalid', 'commit', '-m', 'test(host): define replacement source']);
  const replacement = git(['rev-parse', 'HEAD']);
  git(['replace', sha, replacement]);
  git(['checkout', '--detach', sha]);
  assert.equal(git(['status', '--porcelain']), '');
  await assert.rejects(() => captureInputs(root, 'v1.2.3', sha));
  git(['replace', '-d', sha]);
  git(['reset', '--hard', sha]);
  const previous = { GIT_DIR: process.env.GIT_DIR, GIT_WORK_TREE: process.env.GIT_WORK_TREE, GIT_INDEX_FILE: process.env.GIT_INDEX_FILE };
  try {
    process.env.GIT_DIR = '/unavailable-caller-git-directory';
    process.env.GIT_WORK_TREE = '/unavailable-caller-tree';
    process.env.GIT_INDEX_FILE = '/unavailable-caller-index';
    assert.equal((await captureInputs(root, 'v1.2.3', sha)).commit, sha);
  } finally {
    for (const [name, value] of Object.entries(previous)) {
      if (value === undefined) delete process.env[name]; else process.env[name] = value;
    }
  }
});

test('a hidden FIFO refuses before opening a reader or creating an output', async t => {
  const { root, git, sha, output } = fixture(t);
  git(['update-index', '--assume-unchanged', 'README.md']);
  rmSync(join(root, 'README.md'));
  execFileSync('mkfifo', [join(root, 'README.md')]);
  assert.equal(git(['status', '--porcelain']), '');
  await assert.rejects(() => recordInputs(root, 'v1.2.3', sha, output), /regular file/);
  assert.deepEqual(readdirSync(join(root, 'var')), []);
});
