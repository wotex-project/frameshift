import { createHash } from 'node:crypto';
import { execFileSync } from 'node:child_process';
import { mkdirSync, mkdtempSync, readFileSync, readdirSync, rmSync, writeFileSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { dirname, join, resolve } from 'node:path';
import { recordInputs } from './inputs.mjs';

const owner = resolve(new URL('..', import.meta.url).pathname);
export const hash = value => createHash('sha256').update(value).digest('hex');
function put(root, path, bytes, mode = 0o644) { mkdirSync(dirname(join(root, path)), { recursive: true }); writeFileSync(join(root, path), bytes, { mode }); }
export async function cargoFixture(t) {
  const repository = mkdtempSync(join(tmpdir(), 'frameshift-cargo-source-')); t.after(() => rmSync(repository, { recursive: true, force: true }));
  const run = (cmd, args, cwd = repository) => execFileSync(cmd, args, { cwd, encoding: 'utf8', stdio: 'pipe', timeout: 60_000, maxBuffer: 64 * 1024 }).trim(), git = args => run('git', args);
  for (const name of readdirSync(join(owner, 'release'))) if ((name.endsWith('.mjs') && !name.endsWith('.test.mjs')) || name.endsWith('.exs')) put(repository, 'release/' + name, readFileSync(join(owner, 'release', name)));
  put(repository, '.mise.toml', readFileSync(join(owner, '.mise.toml'))); put(repository, '.gitignore', 'var/\n');
  put(repository, 'apps/core/mix.exs', 'defmodule CargoFixture do\n  @moduledoc false\n\n  use Mix.Project\n  def project, do: [app: :frameshift_core, version: "1.2.3"]\nend\n');
  put(repository, 'codec/Cargo.toml', '[package]\nname = "frameshift-codec"\nversion = "0.1.0"\n');
  put(repository, 'codec/vendor/jpeg-decoder/Cargo.toml', '[package]\nname = "jpeg-decoder"\nversion = "0.3.2-fs.1"\n');
  mkdirSync(join(repository, 'var'), { mode: 0o700 }); const producer = join(repository, 'var/producer');
  put(producer, 'Cargo.toml', '[package]\nname = "test_crate"\nversion = "1.0.0"\nedition = "2024"\nlicense-file = "LICENSE"\ndescription = "Source admission fixture"\n'); put(producer, 'src/lib.rs', 'pub fn fixture() -> u8 { 1 }\n'); put(producer, 'LICENSE', Buffer.from([128, 0, 10]));
  // Actual upstream archive producer; no verification build or online fetch.
  run('mise', ['exec', '--', 'cargo', 'package', '--offline', '--no-verify', '--allow-dirty', '--manifest-path', join(producer, 'Cargo.toml')], owner);
  const cache = join(repository, 'var/cache'), sources = join(repository, 'var/sources'); mkdirSync(cache, { mode: 0o700 }); mkdirSync(sources, { mode: 0o700 });
  const archive = join(cache, 'test_crate-1.0.0.crate'), raw = readFileSync(join(producer, 'target/package/test_crate-1.0.0.crate')); writeFileSync(archive, raw, { mode: 0o600 });
  run('tar', ['-xzf', archive, '-C', sources]); const root = join(sources, 'test_crate-1.0.0'); writeFileSync(join(root, '.cargo-ok'), '{"v":1}', { mode: 0o644 });
  const lock = 'version = 4\n\n[[package]]\nname = "frameshift-codec"\nversion = "0.1.0"\ndependencies = [\n "jpeg-decoder",\n "test_crate",\n]\n\n[[package]]\nname = "jpeg-decoder"\nversion = "0.3.2-fs.1"\n\n[[package]]\nname = "test_crate"\nversion = "1.0.0"\nsource = "registry+https://github.com/rust-lang/crates.io-index"\nchecksum = "' + hash(raw) + '"\n'; put(repository, 'codec/Cargo.lock', lock);
  git(['init', '-b', 'main']); git(['add', '.']); git(['-c', 'user.name=Fixture', '-c', 'user.email=fixture@example.invalid', 'commit', '-m', 'test(host): freeze actual Cargo archive fixture']);
  const tag = 'v1.2.3', commit = git(['rev-parse', 'HEAD']); git(['tag', tag]); await recordInputs(repository, tag, commit, join(repository, 'var/inputs'));
  return { repository, git, tag, commit, sourcePath: join(repository, 'var/inputs/source-inputs.json'), cache, sources, archive, raw, root, lock, package: { name: 'test_crate', version: '1.0.0', checksum: hash(raw) }, output: join(repository, 'var/material') };
}
