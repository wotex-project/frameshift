import assert from 'node:assert/strict';
import { execFileSync, spawnSync } from 'node:child_process';
import { chmodSync, copyFileSync, linkSync, lstatSync, mkdirSync, mkdtempSync, readFileSync, readdirSync, rmSync, symlinkSync, truncateSync, writeFileSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { dirname, join, resolve } from 'node:path';
import test from 'node:test';
import { gzipSync } from 'node:zlib';
import { checkCoreMaterial, coreMaterialParse } from './core-material.mjs';
import { recordInputs } from './inputs.mjs';

const owner = resolve(new URL('..', import.meta.url).pathname);
const run = (command, args, cwd = owner) => execFileSync(command, args, { cwd, encoding: 'utf8', timeout: 60_000, maxBuffer: 64 * 1024, stdio: ['ignore', 'pipe', 'pipe'] }).trim();
function put(root, path, bytes, mode = 0o644) { const full = join(root, path); mkdirSync(dirname(full), { recursive: true }); writeFileSync(full, bytes, { mode }); return full; }
async function fixture(t) {
  const repository = mkdtempSync(join(tmpdir(), 'frameshift-core-material-'));
  t.after(() => rmSync(repository, { recursive: true, force: true }));
  const git = args => run('git', args, repository);
  put(repository, '.gitignore', 'var/\ndeps/\n');
  for (const path of ['.mise.toml', 'release/read-version.exs']) { mkdirSync(dirname(join(repository, path)), { recursive: true }); copyFileSync(join(owner, path), join(repository, path)); }
  put(repository, 'apps/core/mix.exs', 'defmodule Fixture do\n  @moduledoc false\n\n  use Mix.Project\n  def project, do: [app: :frameshift_core, version: "1.2.3"]\nend\n');
  mkdirSync(join(repository, 'var'), { mode: 0o700 });
  const cache = join(repository, 'var/cache'); mkdirSync(cache, { mode: 0o700 });
  const hexRoot = join(repository, 'apps/core/deps/example'); mkdirSync(hexRoot, { recursive: true });
  // Actual pinned upstream producer: valid checksums, metadata, file modes and
  // a current binary SCM manifest. No parser or checksum is stubbed here.
  const create = `Application.load(:hex)
root = hd(System.argv())
files = [{~c"lib/example.ex", "defmodule Example do\\n  @moduledoc false\\n\\nend\\n"}, {~c"LICENSE", "fixture rights text\\n"}]
metadata = %{"name" => "example", "version" => "1.0.0", "build_tools" => ["mix"], "files" => Enum.map(files, fn {p, _} -> List.to_string(p) end)}
{:ok, p} = :mix_hex_tarball.create(metadata, files)
hex = fn b -> Base.encode16(b, case: :lower) end
File.write!(Path.join(root, "var/cache/example-1.0.0.tar"), p.tarball)
{:ok, outer} = :mix_hex_erl_tar.extract({:binary, p.tarball}, [:memory])
{_, raw_metadata} = Enum.find(outer, fn {name, _} -> name == ~c"metadata.config" end)
dep = Path.join(root, "apps/core/deps/example")
Enum.each(files, fn {path, bytes} -> path = Path.join(dep, List.to_string(path)); File.mkdir_p!(Path.dirname(path)); File.write!(path, bytes) end)
File.write!(Path.join(dep, "hex_metadata.config"), raw_metadata)
manifest = %{name: "example", version: "1.0.0", inner_checksum: hex.(p.inner_checksum), outer_checksum: hex.(p.outer_checksum), repo: "hexpm", managers: [:mix]}
File.write!(Path.join(dep, ".hex"), :erlang.term_to_binary({{:hex, 2, 0}, manifest}))
IO.binwrite(:json.encode(%{inner: manifest.inner_checksum, outer: manifest.outer_checksum}))`;
  const hex = JSON.parse(run('mise', ['exec', '--', 'mix', 'run', '--no-mix-exs', '--no-start', '--no-compile', '--no-deps-check', '-e', create, '--', repository]));
  const gitRoot = join(repository, 'apps/core/deps/git_source'), depGit = args => run('git', args, gitRoot);
  put(gitRoot, 'packages/demo/lib/example.ex', 'defmodule GitExample do\n  @moduledoc false\n\nend\n');
  put(gitRoot, 'packages/demo/run.sh', '#!/bin/sh\nexit 0\n', 0o755);
  depGit(['init', '-b', 'main']); depGit(['add', '.']); depGit(['-c', 'user.name=Fixture', '-c', 'user.email=fixture@example.invalid', 'commit', '-m', 'test(host): define locked sparse dependency']);
  const depCommit = depGit(['rev-parse', 'HEAD']);
  put(repository, 'apps/core/mix.lock', `%{example: {:hex, :example, "1.0.0", "${hex.inner}", [:mix], [], "hexpm", "${hex.outer}"}, git_source: {:git, "https://example.invalid/source.git", "${depCommit}", [ref: "${depCommit}", sparse: "packages/demo"]}}\n`);
  git(['init', '-b', 'main']); git(['add', '.']); git(['-c', 'user.name=Fixture', '-c', 'user.email=fixture@example.invalid', 'commit', '-m', 'test(host): define material source']);
  const commit = git(['rev-parse', 'HEAD']), tag = 'v1.2.3'; git(['tag', tag]);
  await recordInputs(repository, tag, commit, join(repository, 'var/inputs'));
  return { repository, git, cache, hexRoot, gitRoot, depGit, depCommit, archive: join(cache, 'example-1.0.0.tar'), tag, commit, sourcePath: join(repository, 'var/inputs/source-inputs.json'), output: join(repository, 'var/material') };
}

test('actual Hex archives and literal sparse Git blobs bind private receipt and unchanged replay', async t => {
  const f = await fixture(t);
  const result = await checkCoreMaterial(f);
  assert.equal(result.publicationAuthority, 'none'); assert.equal(result.packages, 2); assert.equal(result.files, 6);
  const receipt = join(f.output, 'core-material.json'), record = JSON.parse(readFileSync(receipt));
  assert.equal(record.packages[0].parser.hex, '2.5.1'); assert.equal(record.packages[1].lock.commit, f.depCommit);
  assert.equal(record.packages[1].files.find(file => file.path.endsWith('run.sh')).mode, 0o755);
  assert.equal(lstatSync(f.output).mode & 0o7777, 0o700); assert.equal(lstatSync(receipt).mode & 0o7777, 0o600);
  const before = lstatSync(receipt);
  const replay = await checkCoreMaterial(f);
  assert.equal(replay.receiptSha256, result.receiptSha256); assert.equal(replay.disposition, 'retained-bytes-verified');
  assert.equal(lstatSync(receipt).ino, before.ino); assert.equal(lstatSync(receipt).mtimeMs, before.mtimeMs);
  assert.deepEqual(readdirSync(f.output), ['core-material.json']);
});

test('archive checksum precedes parsing; changed source, SCM identity and generated metadata refuse', async t => {
  const f = await fixture(t), original = readFileSync(f.archive);
  writeFileSync(f.archive, Buffer.from(original).fill(0, 0, 1));
  let packageCalls = 0;
  await assert.rejects(() => checkCoreMaterial(f, { parse: (...args) => { if (args[0] === 'package') packageCalls++; return coreMaterialParse(...args); } }), /archive differs/);
  assert.equal(packageCalls, 0); writeFileSync(f.archive, original);
  const path = join(f.hexRoot, 'lib/example.ex'), source = readFileSync(path);
  writeFileSync(path, Buffer.from(source).fill(65, 0, 1)); await assert.rejects(() => checkCoreMaterial(f), /source differs/); writeFileSync(path, source);
  const metadata = join(f.hexRoot, 'hex_metadata.config'), previous = readFileSync(metadata);
  writeFileSync(metadata, Buffer.from(previous).fill(65, 0, 1)); await assert.rejects(() => checkCoreMaterial(f), /source differs/); writeFileSync(metadata, previous);
  const manifest = join(f.hexRoot, '.hex'), bytes = readFileSync(manifest);
  writeFileSync(manifest, 'example,1.0.0,legacy,hexpm\n'); await assert.rejects(() => checkCoreMaterial(f), /parser/); writeFileSync(manifest, bytes);
  assert.equal(readdirSync(join(f.repository, 'var')).includes('material'), false);
});

test('Git bytes, executable mode and literal locked commit refuse regardless of index or caller Git overrides', async t => {
  const f = await fixture(t), path = join(f.gitRoot, 'packages/demo/lib/example.ex'), previous = readFileSync(path);
  f.depGit(['update-index', '--assume-unchanged', 'packages/demo/lib/example.ex']);
  writeFileSync(path, Buffer.from(previous).fill(66, 0, 1)); assert.equal(f.depGit(['status', '--porcelain']), '');
  await assert.rejects(() => checkCoreMaterial(f), /Git blob/); writeFileSync(path, previous);
  const script = join(f.gitRoot, 'packages/demo/run.sh'); chmodSync(script, 0o644);
  await assert.rejects(() => checkCoreMaterial(f), /Git blob/); chmodSync(script, 0o755);
  put(f.gitRoot, 'packages/demo/new.ex', 'new source'); f.depGit(['add', '.']);
  f.depGit(['-c', 'user.name=Fixture', '-c', 'user.email=fixture@example.invalid', 'commit', '-m', 'test(host): move dependency fixture']);
  await assert.rejects(() => checkCoreMaterial(f), /checkout differs/);
  f.depGit(['reset', '--hard', f.depCommit]);
  const old = process.env.GIT_DIR; process.env.GIT_DIR = '/unavailable/override';
  try { assert.equal((await checkCoreMaterial(f)).packages, 2); } finally { if (old === undefined) delete process.env.GIT_DIR; else process.env.GIT_DIR = old; }
});

test('source namespace, missing members, aliases, special files and bounded sparse inputs refuse', async t => {
  const f = await fixture(t);
  const additional = put(f.repository, 'apps/core/deps/extra/source.ex', 'extra');
  await assert.rejects(() => checkCoreMaterial(f), /namespace/); rmSync(dirname(additional), { recursive: true });
  const extra = put(f.hexRoot, 'unexpected.ex', 'extra'); await assert.rejects(() => checkCoreMaterial(f), /additional/); rmSync(extra);
  mkdirSync(join(f.hexRoot, 'empty-extra')); await assert.rejects(() => checkCoreMaterial(f), /additional/); rmSync(join(f.hexRoot, 'empty-extra'), { recursive: true });
  const source = join(f.hexRoot, 'LICENSE'), bytes = readFileSync(source); rmSync(source);
  await assert.rejects(() => checkCoreMaterial(f), /missing/);
  symlinkSync('lib/example.ex', source); await assert.rejects(() => checkCoreMaterial(f), /alias/); rmSync(source); writeFileSync(source, bytes);
  const hardlink = join(f.repository, 'var/license-alias'); linkSync(source, hardlink);
  await assert.rejects(() => checkCoreMaterial(f), /alias/); rmSync(hardlink);
  rmSync(source); run('mkfifo', [source]); await assert.rejects(() => checkCoreMaterial(f), /alias/); rmSync(source); writeFileSync(source, bytes);
  const archive = readFileSync(f.archive); truncateSync(f.archive, 64 * 1024 * 1024 + 1);
  await assert.rejects(() => checkCoreMaterial(f), /size/); writeFileSync(f.archive, archive);
  truncateSync(source, 128 * 1024 * 1024 + 1); await assert.rejects(() => checkCoreMaterial(f), /size/); writeFileSync(source, bytes);
  await assert.rejects(() => checkCoreMaterial(f, { budgetMs: 1 }), /deadline/);
});

test('hidden lock mutation and changes during the repeated source/cache inspection preserve incomplete custody', async t => {
  const f = await fixture(t), lock = join(f.repository, 'apps/core/mix.lock'), previous = readFileSync(lock);
  f.git(['update-index', '--assume-unchanged', 'apps/core/mix.lock']); writeFileSync(lock, Buffer.from(previous).fill(65, 0, 1));
  await assert.rejects(() => checkCoreMaterial(f), /bytes changed or differ/); writeFileSync(lock, previous);
  let locks = 0;
  await assert.rejects(() => checkCoreMaterial(f, { parse: (...args) => {
    if (args[0] === 'lock' && ++locks === 2) put(f.hexRoot, 'late.ex', 'late');
    return coreMaterialParse(...args);
  } }), /additional/);
  assert.deepEqual(readdirSync(f.output), ['check.pending']); rmSync(join(f.hexRoot, 'late.ex'));
  await assert.rejects(() => checkCoreMaterial(f), /incomplete/);
  assert.deepEqual(readdirSync(f.output), ['check.pending']);
});

test('literal-only locks, archive duplicate/unsafe/special member inventories and decompression limits refuse', () => {
  for (const bytes of ['File.write!("should-not-exist", "executed")', '%{same: 1, same: 2}', '%{}', '%{unsupported: {:path, "example"}}']) {
    assert.throws(() => coreMaterialParse('lock', Buffer.from(bytes)), /parser/);
  }
  // Use the real Hex archive writer; each malicious inner member is otherwise
  // checksum-valid. Duplicates cannot be hidden by the parser's map projection.
  const script = `Application.load(:hex); root = hd(System.argv());
for {name, files} <- [{"duplicate", [{~c"lib/x.ex", "a"}, {~c"lib/x.ex", "b"}]}, {"unsafe", [{~c"../x.ex", "a"}]}] do
  case :mix_hex_tarball.create(%{"name" => "example", "version" => "1.0.0"}, files) do
    {:ok, p} -> File.write!(Path.join(root, name <> ".tar"), p.tarball)
    _ -> :ok
  end
end`;
  const root = mkdtempSync(join(tmpdir(), 'frameshift-core-archive-refusal-'));
  try {
    run('mise', ['exec', '--', 'mix', 'run', '--no-mix-exs', '--no-start', '--no-compile', '--no-deps-check', '-e', script, '--', root]);
    for (const name of readdirSync(root)) assert.throws(() => coreMaterialParse('package', readFileSync(join(root, name))), /parser/);
    assert.ok(readdirSync(root).includes('duplicate.tar'));
    const members = join(root, 'members'); mkdirSync(members);
    symlinkSync('missing', join(members, 'link')); run('mkfifo', [join(members, 'fifo')]);
    for (const name of ['link', 'fifo']) {
      const tar = join(root, `${name}-inner.tar`);
      run('tar', ['--format', 'ustar', '-cf', tar, '-C', members, name]);
      writeFileSync(join(root, `${name}.gz`), gzipSync(readFileSync(tar)));
    }
    writeFileSync(join(root, 'expanded.gz'), gzipSync(Buffer.alloc(128 * 1024 * 1024 + 1)));
    const outerScript = `Application.load(:hex); root = hd(System.argv());
{:ok, p} = :mix_hex_tarball.create(%{"name" => "example", "version" => "1.0.0"}, [{~c"x.ex", "x"}]);
{:ok, outer} = :mix_hex_erl_tar.extract({:binary, p.tarball}, [:memory]);
{_, metadata} = Enum.find(outer, fn {name, _} -> name == ~c"metadata.config" end);
for name <- ["link", "fifo", "expanded"] do
  compressed = File.read!(Path.join(root, name <> ".gz"));
  checksum = Base.encode16(:crypto.hash(:sha256, ["3", metadata, compressed]));
  :ok = :mix_hex_erl_tar.create(Path.join(root, name <> "-outer.tar"), [{~c"VERSION", "3"}, {~c"CHECKSUM", checksum}, {~c"metadata.config", metadata}, {~c"contents.tar.gz", compressed}], [])
end`;
    run('mise', ['exec', '--', 'mix', 'run', '--no-mix-exs', '--no-start', '--no-compile', '--no-deps-check', '-e', outerScript, '--', root]);
    for (const name of ['link', 'fifo', 'expanded']) assert.throws(() => coreMaterialParse('package', readFileSync(join(root, `${name}-outer.tar`))), /parser/);
    assert.throws(() => coreMaterialParse('lock', Buffer.alloc(64 * 1024 + 1, 32)), /parser/);
    assert.throws(() => coreMaterialParse('lock', Buffer.from('%{a: 1}'), 1), /parser/);
  } finally { rmSync(root, { recursive: true, force: true }); }
});

test('cache namespace or completed output mutation during checking refuses while retaining custody', async t => {
  const f = await fixture(t); let packages = 0;
  await assert.rejects(() => checkCoreMaterial(f, { parse: (...args) => {
    if (args[0] === 'package' && ++packages === 2) put(f.cache, 'late.tar', 'extra');
    return coreMaterialParse(...args);
  } }), /namespace|changed/);
  assert.deepEqual(readdirSync(f.output), ['check.pending']);
  const good = { ...f, output: join(f.repository, 'var/complete') }; await checkCoreMaterial(good);
  let locks = 0;
  await assert.rejects(() => checkCoreMaterial(good, { parse: (...args) => {
    if (args[0] === 'lock' && ++locks === 2) mkdirSync(join(good.output, 'late-directory'));
    return coreMaterialParse(...args);
  } }), /custody/);
  assert.ok(readdirSync(good.output).includes('core-material.json'));
});

test('changed or aliased private receipt and fixed CLI errors refuse without rebuilding or disclosing inputs', async t => {
  const f = await fixture(t); await checkCoreMaterial(f);
  const receipt = join(f.output, 'core-material.json'), original = readFileSync(receipt);
  writeFileSync(receipt, Buffer.from(original).fill(32, 0, 1)); await assert.rejects(() => checkCoreMaterial(f), /conflicting/); writeFileSync(receipt, original);
  chmodSync(receipt, 0o644); await assert.rejects(() => checkCoreMaterial(f), /unsafe/); chmodSync(receipt, 0o600);
  linkSync(receipt, join(f.repository, 'var/receipt-alias')); await assert.rejects(() => checkCoreMaterial(f), /conflicting/);
  const secret = 'private-fixture-input';
  const result = spawnSync('mise', ['exec', '--', 'node', join(owner, 'release/core-material-cli.mjs'), f.tag, f.commit, secret, secret, secret], { cwd: owner, encoding: 'utf8', timeout: 60_000 });
  assert.equal(result.status, 1); assert.equal(result.stdout, ''); assert.equal(result.stderr, 'core dependency source: unavailable, unsafe or conflicting input/output\n');
  assert.deepEqual(readFileSync(receipt), original);
});
