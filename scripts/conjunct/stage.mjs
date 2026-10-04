import assert from 'node:assert/strict';
import { spawnSync } from 'node:child_process';
import { chmodSync, cpSync, existsSync, mkdirSync, mkdtempSync, readFileSync, rmSync, writeFileSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join, resolve } from 'node:path';
import { fileURLToPath } from 'node:url';
import { cohort, digest, inventory, verifyArchive, verifyBundle, verifyDiscovery } from './artifacts.mjs';

const repository = resolve(fileURLToPath(new URL('../..', import.meta.url)));
const work = mkdtempSync(join(tmpdir(), 'frameshift-conjunct-build-'));
const cache = join(repository, 'var/conjunct/cache');
const bundles = join(repository, 'var/conjunct/bundles');
mkdirSync(cache, { recursive: true });
mkdirSync(bundles, { recursive: true });
const bundle = mkdtempSync(join(bundles, `${cohort.revision.slice(0, 12)}-`));
const env = { ...process.env, CONJUNCT_SOURCE_REVISION: cohort.revision,
  CARGO_BUILD_JOBS: process.env.CARGO_BUILD_JOBS || '2', ERL_FLAGS: process.env.ERL_FLAGS || '+S 2:2' };

function run(command, args, cwd = repository, options = {}) {
  const result = spawnSync(command, args, { cwd, env, encoding: 'utf8', maxBuffer: 32 * 1024 * 1024,
    stdio: options.capture ? 'pipe' : 'inherit', ...options });
  if (result.error) throw result.error;
  assert.equal(result.status, 0, `${command} ${args.join(' ')} failed: ${result.stderr || ''}`);
  return result.stdout?.trimEnd();
}

function extract(archive, destination, strip = false) {
  verifyArchive(run('tar', ['-tf', archive], repository, { capture: true }),
    run('tar', ['-tvf', archive], repository, { capture: true }));
  mkdirSync(destination, { recursive: true });
  run('tar', ['-xf', archive, '-C', destination, ...(strip ? ['--strip-components=1'] : [])]);
}

function copy(source, destination) {
  mkdirSync(resolve(destination, '..'), { recursive: true });
  cpSync(source, destination, { recursive: true });
}

try {
  const archive = join(cache, `${cohort.revision}.tar.gz`);
  if (!existsSync(archive)) {
    const result = spawnSync('gh', ['api', `repos/${cohort.repository}/tarball/${cohort.revision}`],
      { cwd: repository, maxBuffer: 64 * 1024 * 1024 });
    assert.equal(result.status, 0, result.stderr?.toString());
    writeFileSync(archive, result.stdout);
  }
  assert.equal(digest(readFileSync(archive)), cohort.source_archive_digest, 'producer source archive changed');
  const source = join(work, 'source');
  extract(archive, source, true);
  for (const record of Object.values(cohort.algorithm_sources)) {
    assert.equal(digest(readFileSync(join(source, record.path))), record.digest);
  }
  const rust = run('rustc', ['-vV'], repository, { capture: true });
  assert(rust.startsWith('rustc 1.97.1 '), 'select the Frameshift pinned Rust compiler');
  const target = rust.match(/^host: (.+)$/m)[1];
  const tsc = join(repository, 'apps/build-platform/assets/node_modules/typescript/bin/tsc');
  const typescript = run(process.execPath, [tsc, '--version'], repository, { capture: true });
  assert.equal(typescript, 'Version 6.0.3');
  assert.equal(process.versions.node, '26.9.0');
  const beam = run('elixir', ['-e', 'IO.puts(System.version()); IO.puts(File.read!(Path.join([:code.root_dir(), "releases", :erlang.system_info(:otp_release), "OTP_VERSION"])))'], repository, { capture: true });
  assert.equal(beam, '1.20.4\n29.1', 'select the Frameshift pinned BEAM runtime');
  env.CARGO_TARGET_DIR = join(cache, 'cargo');
  run('cargo', ['build', '--locked', '--release', '--manifest-path', join(source, 'Cargo.toml'), '-p', 'conjunct-port']);
  run('cargo', ['build', '--locked', '--release', '--manifest-path', join(source, 'Cargo.toml'), '-p', 'conjunct-abi', '--target', 'wasm32-unknown-unknown']);
  run('cargo', ['build', '--locked', '--release', '--manifest-path', join(source, 'Cargo.toml'), '-p', 'conjunct-distribution', '--example', 'discovery']);
  copy(join(env.CARGO_TARGET_DIR, 'release/conjunct-port'), join(bundle, 'native', target, 'conjunct-port'));
  chmodSync(join(bundle, 'native', target, 'conjunct-port'), 0o755);
  copy(join(env.CARGO_TARGET_DIR, 'wasm32-unknown-unknown/release/conjunct_abi.wasm'), join(bundle, 'wasm/conjunct_abi.wasm'));
  mkdirSync(join(bundle, 'discovery'));
  const discovery = run(join(env.CARGO_TARGET_DIR, 'release/examples/discovery'), ['port'], repository, { capture: true });
  verifyDiscovery(JSON.parse(discovery), 'cj/port/1');
  writeFileSync(join(bundle, 'discovery/port.json'), discovery);

  for (const [name, directory] of [['kernel', 'bindings/typescript/conjunct-kernel'],
    ['data', 'bindings/typescript/conjunct-data'], ['guide', 'frontend/guide']]) {
    const input = join(source, directory);
    run(process.execPath, [tsc, '-p', join(input, 'tsconfig.json')]);
    const output = join(bundle, 'js', name);
    for (const file of ['dist', 'package.json', 'README.md']) copy(join(input, file), join(output, file));
    copy(join(source, 'LICENSE'), join(output, 'LICENSE'));
    if (name === 'data') {
      for (const file of ['src/generated', 'generation-manifest.json', 'generation-config.json']) {
        copy(join(input, file), join(output, file));
      }
    }
  }
  const { RawKernel } = await import(`file://${join(bundle, 'js/kernel/dist/index.js')}`);
  const kernel = await RawKernel.instantiate(readFileSync(join(bundle, 'wasm/conjunct_abi.wasm')));
  const wasmDiscovery = kernel.describe();
  verifyDiscovery(JSON.parse(new TextDecoder().decode(wasmDiscovery)), 'cj/wasm-abi/1');
  writeFileSync(join(bundle, 'discovery/wasm.json'), wasmDiscovery);

  for (const name of ['wire', 'data', 'kernel']) {
    const input = join(source, `bindings/elixir/conjunct_${name}`);
    const output = join(bundle, `elixir/conjunct_${name}`);
    for (const file of ['lib', 'mix.exs', 'README.md', 'LICENSE']) copy(join(input, file), join(output, file));
    if (name === 'data') {
      for (const file of ['generation-manifest.json', 'generation-config.json']) copy(join(input, file), join(output, file));
    }
  }
  const telemetryArchive = join(cache, `telemetry-${cohort.telemetry.version}.tar`);
  if (!existsSync(telemetryArchive)) {
    const response = await fetch(`https://repo.hex.pm/tarballs/telemetry-${cohort.telemetry.version}.tar`,
      { signal: AbortSignal.timeout(30_000) });
    assert(response.ok, `telemetry download failed: ${response.status}`);
    writeFileSync(telemetryArchive, new Uint8Array(await response.arrayBuffer()));
  }
  assert.equal(digest(readFileSync(telemetryArchive)), cohort.telemetry.archive_digest);
  const hex = join(work, 'telemetry');
  extract(telemetryArchive, hex);
  extract(join(hex, 'contents.tar.gz'), join(bundle, 'elixir/telemetry'));
  copy(join(source, 'LICENSE'), join(bundle, 'licenses/conjunct-MIT.txt'));
  copy(join(source, 'Cargo.lock'), join(bundle, 'provenance/Cargo.lock'));
  copy(join(source, 'bindings/elixir/conjunct_kernel/mix.lock'), join(bundle, 'provenance/kernel.mix.lock'));
  const cargo = JSON.parse(run('cargo', ['metadata', '--locked', '--manifest-path', join(source, 'Cargo.toml'),
    '--format-version=1'], repository, { capture: true }));
  const abi = cargo.packages.find(package_ => package_.name === 'conjunct-abi');
  const port = cargo.packages.find(package_ => package_.name === 'conjunct-port');
  const selected = new Set();
  function dependency(id) {
    if (selected.has(id)) return;
    selected.add(id);
    const node = cargo.resolve.nodes.find(node_ => node_.id === id);
    for (const edge of node.deps.filter(edge_ => edge_.dep_kinds.some(kind => kind.kind !== 'dev'))) dependency(edge.pkg);
  }
  dependency(abi.id);
  dependency(port.id);
  const dependencies = cargo.packages.filter(package_ => selected.has(package_.id)).map(package_ => ({
    name: package_.name, version: package_.version, license: package_.license, source: package_.source,
  })).sort((a, b) => a.name.localeCompare(b.name));
  assert(dependencies.every(dependency_ => dependency_.license), 'undeclared dependency license');
  const manifest = { version: 'frameshift.conjunct-bundle.v1', cohort, target,
    toolchains: { rust, node: process.versions.node, typescript, beam,
      elixir: run('elixir', ['--version'], repository, { capture: true }) },
    publishable: false, blockers: ['unsigned consumer experiment; no physical or operated qualification'],
    dependencies: [...dependencies, { name: 'telemetry', version: cohort.telemetry.version, license: 'Apache-2.0' }],
    files: inventory(bundle) };
  const bytes = JSON.stringify(manifest, null, 2) + '\n';
  writeFileSync(join(bundle, 'manifest.json'), bytes);
  verifyBundle(bundle, digest(bytes));
  console.log(JSON.stringify({ bundle, manifest_digest: digest(bytes) }));
} catch (error) {
  rmSync(bundle, { recursive: true, force: true });
  throw error;
} finally {
  rmSync(work, { recursive: true, force: true });
}
