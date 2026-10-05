import assert from 'node:assert/strict';
import { execFileSync, spawnSync } from 'node:child_process';
import { chmodSync, copyFileSync, linkSync, lstatSync, mkdirSync, mkdtempSync, readFileSync, readdirSync, rmSync, symlinkSync, truncateSync, writeFileSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { dirname, join, resolve } from 'node:path';
import test from 'node:test';
import { coreMaterialParse } from './core-material.mjs';
import { checkGleamMaterial, gleamFetchedPackages, gleamSourceManifest } from './gleam-material.mjs';
import { recordInputs } from './inputs.mjs';

const owner = resolve(new URL('..', import.meta.url).pathname);
function put(root, path, bytes) { const full = join(root, path); mkdirSync(dirname(full), { recursive: true }); writeFileSync(full, bytes); return full; }
const run = (command, args, cwd = owner) => execFileSync(command, args, { cwd, encoding: 'utf8', timeout: 60_000, maxBuffer: 64 * 1024, stdio: ['ignore', 'pipe', 'pipe'] }).trim();
async function fixture(t) {
  const repository = mkdtempSync(join(tmpdir(), 'frameshift-gleam-material-')); t.after(() => rmSync(repository, { recursive: true, force: true }));
  const git = args => run('git', args, repository);
  for (const path of ['.mise.toml', 'release/read-version.exs', 'release/core-material.mjs', 'release/core-material.exs', 'release/gleam-material.mjs', 'release/gleam-material-cli.mjs', 'release/files.mjs', 'release/inputs.mjs', 'release/source.mjs']) { mkdirSync(dirname(join(repository, path)), { recursive: true }); copyFileSync(join(owner, path), join(repository, path)); }
  put(repository, '.gitignore', 'var/\nbuild/\n');
  put(repository, 'apps/core/mix.exs', 'defmodule Fixture do\n  @moduledoc false\n\n  use Mix.Project\n  def project, do: [app: :frameshift_core, version: "1.2.3"]\nend\n');
  put(repository, 'packages/decision-kernel/gleam.toml', 'name = "frameshift_decisions"\nversion = "0.1.0"\n');
  mkdirSync(join(repository, 'var'), { mode: 0o700 }); const cache = join(repository, 'var/cache'); mkdirSync(cache, { mode: 0o700 });
  const script = `Application.load(:hex); root = hd(System.argv());
packages = for name <- ["example", "helper"] do
  files = [{~c"LICENCE", "fixture license text\\n"}, {~c"src/native.erl", "-module(native).\\n"}, {~c"src/example.gleam", "pub fn example() { 1 }\\n"}];
  {:ok, p} = :mix_hex_tarball.create(%{"name" => name, "version" => "1.0.0", "build_tools" => ["gleam"]}, files);
  outer = Base.encode16(p.outer_checksum); File.write!(Path.join([root, "var/cache", outer <> ".tar"]), p.tarball);
  Enum.each(files, fn {path, bytes} -> file = Path.join([root, "packages/decision-kernel/build/packages", name, List.to_string(path)]); File.mkdir_p!(Path.dirname(file)); File.write!(file, bytes) end);
  %{name: name, outer: outer}
end; IO.binwrite(:json.encode(packages))`;
  const packages = JSON.parse(run('mise', ['exec', '--', 'mix', 'run', '--no-mix-exs', '--no-start', '--no-compile', '--no-deps-check', '-e', script, '--', repository]));
  const rows = packages.map(({ name, outer }) => `  { name = "${name}", version = "1.0.0", build_tools = ["gleam"], requirements = ${name === 'helper' ? '["example"]' : '[]'}, otp_app = "${name}", source = "hex", outer_checksum = "${outer}" },`).join('\n');
  const manifest = `# generated literal profile\npackages = [\n${rows}\n]\n\n[requirements]\nexample = { version = ">= 1.0.0 and < 2.0.0" }\nhelper = { version = "~> 1.0" }\n`;
  put(repository, 'packages/decision-kernel/manifest.toml', manifest);
  const root = join(repository, 'packages/decision-kernel/build/packages');
  const metadata = '[packages]\nhelper = "1.0.0"\nexample = "1.0.0"\n\n[git]\n'; put(root, 'packages.toml', metadata); put(root, 'gleam.lock', '');
  git(['init', '-b', 'main']); git(['add', '.']); git(['-c', 'user.name=Fixture', '-c', 'user.email=fixture@example.invalid', 'commit', '-m', 'test(release): define Gleam source fixture']);
  const commit = git(['rev-parse', 'HEAD']), tag = 'v1.2.3'; git(['tag', tag]); await recordInputs(repository, tag, commit, join(repository, 'var/inputs'));
  return { repository, git, tag, commit, sourcePath: join(repository, 'var/inputs/source-inputs.json'), cache, output: join(repository, 'var/material'), root, packages, manifest, metadata, archive: join(cache, packages[0].outer + '.tar') };
}

test('actual Hex/Gleam source and fetched metadata join frozen source with private unchanged replay', async t => {
  const f = await fixture(t), result = await checkGleamMaterial(f);
  assert.equal(result.packages, 2); assert.equal(result.files, 6); assert.equal(result.publicationAuthority, 'none');
  const receipt = join(f.output, 'gleam-material.json'), before = lstatSync(receipt), record = JSON.parse(readFileSync(receipt));
  assert.equal(record.packages[0].parser.hex, '2.5.1'); assert.equal(record.packages[0].innerChecksum.length, 64);
  assert.equal(record.packages[0].files.some(file => file.path === 'src/native.erl'), true);
  assert.equal(lstatSync(f.output).mode & 0o7777, 0o700); assert.equal(before.mode & 0o7777, 0o600);
  const replay = await checkGleamMaterial(f); assert.equal(replay.receiptSha256, result.receiptSha256); assert.equal(replay.disposition, 'retained-bytes-verified');
  assert.equal(lstatSync(receipt).ino, before.ino); assert.equal(lstatSync(receipt).mtimeMs, before.mtimeMs);
  const cli = JSON.parse(run('mise', ['exec', '--', 'node', join(f.repository, 'release/gleam-material-cli.mjs'), f.tag, f.commit, f.sourcePath, f.cache, f.output]));
  assert.equal(cli.receiptSha256, result.receiptSha256); assert.equal(cli.disposition, 'retained-bytes-verified');
});

test('unsupported literal forms, ambiguous identities, duplicate metadata and bounds refuse', async t => {
  const f = await fixture(t);
  for (const text of [f.manifest.replace('source = "hex"', 'source = "local"'), f.manifest.replace('build_tools = ["gleam"]', 'build_tools = ["rebar3"]'), f.manifest.replace('otp_app = "example"', 'otp_app = "other"'), f.manifest.replace('requirements = []', 'requirements = ["missing"]'), f.manifest + '\n[unexpected]\na = 1', f.manifest.replace('name = "helper"', 'name = "example"'), f.manifest.replace('1.0.0"', '1.0.0\\t"')]) {
    assert.throws(() => gleamSourceManifest(Buffer.from(text)));
  }
  for (const text of [f.metadata.replace('helper = "1.0.0"', 'example = "1.0.0"'), f.metadata + '\nother = "git"', '[packages]\n\n[git]']) assert.throws(() => gleamFetchedPackages(Buffer.from(text)));
  assert.throws(() => gleamSourceManifest(Buffer.alloc(64 * 1024 + 1))); await assert.rejects(() => checkGleamMaterial(f, { budgetMs: 1 }), /deadline/);
  const bounded = count => Buffer.from('packages = [\n' + Array.from({ length: count }, (_, i) => `  { name = "package_${i}", version = "1.0.0", build_tools = ["gleam"], requirements = [], source = "hex", outer_checksum = "${'A'.repeat(64)}" },`).join('\n') + '\n]\n\n[requirements]\npackage_0 = { version = "~> 1.0" }\n');
  assert.equal(gleamSourceManifest(bounded(128)).packages.length, 128); assert.throws(() => gleamSourceManifest(bounded(129)), /limit/);
});

test('checksum-before-parser, fetched versions, delivered Erlang bytes and hidden frozen manifest changes refuse', async t => {
  const f = await fixture(t), bytes = readFileSync(f.archive); writeFileSync(f.archive, Buffer.from(bytes).fill(0, 0, 1));
  let calls = 0; await assert.rejects(() => checkGleamMaterial(f, { parse: (...args) => { calls++; return coreMaterialParse(...args); } }), /checksum/); assert.equal(calls, 0); writeFileSync(f.archive, bytes);
  put(f.root, 'packages.toml', f.metadata.replace('1.0.0', '2.0.0')); await assert.rejects(() => checkGleamMaterial(f), /metadata differs/); put(f.root, 'packages.toml', f.metadata);
  const source = join(f.root, 'example/src/native.erl'), previous = readFileSync(source); writeFileSync(source, Buffer.from(previous).fill(66, 0, 1));
  await assert.rejects(() => checkGleamMaterial(f), /source differs/); writeFileSync(source, previous);
  f.git(['update-index', '--assume-unchanged', 'packages/decision-kernel/manifest.toml']); put(f.repository, 'packages/decision-kernel/manifest.toml', f.manifest.replace('1.0.0', '2.0.0'));
  assert.equal(f.git(['status', '--porcelain']), ''); await assert.rejects(() => checkGleamMaterial(f), /bytes changed or differ/);
});

test('extra/missing/generated/aliased/special sources and unsafe fetched metadata cannot enter admission', async t => {
  const f = await fixture(t);
  const extra = put(f.root, 'example/src/extra.beam', 'generated'); await assert.rejects(() => checkGleamMaterial(f), /additional/); rmSync(extra);
  mkdirSync(join(f.root, 'empty-extra')); await assert.rejects(() => checkGleamMaterial(f), /namespace/); rmSync(join(f.root, 'empty-extra'), { recursive: true });
  const source = join(f.root, 'example/LICENCE'), bytes = readFileSync(source); rmSync(source); await assert.rejects(() => checkGleamMaterial(f), /missing/);
  symlinkSync('src/example.gleam', source); await assert.rejects(() => checkGleamMaterial(f), /alias/); rmSync(source); writeFileSync(source, bytes);
  const alias = join(f.repository, 'var/alias'); linkSync(source, alias); await assert.rejects(() => checkGleamMaterial(f), /alias/); rmSync(alias);
  rmSync(source); run('mkfifo', [source]); await assert.rejects(() => checkGleamMaterial(f), /alias/); rmSync(source); writeFileSync(source, bytes);
  chmodSync(join(f.root, 'packages.toml'), 0o666); await assert.rejects(() => checkGleamMaterial(f), /unsafe/); chmodSync(join(f.root, 'packages.toml'), 0o644);
  truncateSync(f.archive, 64 * 1024 * 1024 + 1); await assert.rejects(() => checkGleamMaterial(f), /size/);
});

test('source/cache/receipt mutation across repeated inspection retains incomplete or complete custody', async t => {
  const f = await fixture(t); let calls = 0;
  await assert.rejects(() => checkGleamMaterial(f, { parse: (...args) => {
    if (++calls === 3) put(f.root, 'helper/src/late.gleam', 'late'); return coreMaterialParse(...args);
  } }), /additional/);
  assert.deepEqual(readdirSync(f.output), ['check.pending']); rmSync(join(f.root, 'helper/src/late.gleam')); await assert.rejects(() => checkGleamMaterial(f), /incomplete/);
  const complete = { ...f, output: join(f.repository, 'var/complete') }; await checkGleamMaterial(complete);
  calls = 0; await assert.rejects(() => checkGleamMaterial(complete, { parse: (...args) => {
    if (++calls === 3) put(f.cache, 'late.tar', 'late'); return coreMaterialParse(...args);
  } }), /changed/);
  assert.deepEqual(readdirSync(complete.output), ['gleam-material.json']);
  const receipt = join(complete.output, 'gleam-material.json'); chmodSync(receipt, 0o644); await assert.rejects(() => checkGleamMaterial(complete), /unsafe/);
});

test('CLI usage and refusals emit fixed text without exposing caller inputs', () => {
  const run = args => spawnSync('mise', ['exec', '--', 'node', join(owner, 'release/gleam-material-cli.mjs'), ...args], { cwd: owner, encoding: 'utf8', timeout: 60_000 });
  assert.equal(run([]).status, 64);
  const secret = 'private-fixture-path', result = run(['v1.2.3', 'f'.repeat(40), secret, secret, secret]);
  assert.equal(result.status, 1); assert.equal(result.stdout, ''); assert.equal(result.stderr, 'Gleam dependency source: unavailable, unsafe or conflicting input/output\n');
});
