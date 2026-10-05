import { createHash } from 'node:crypto';
import { execFileSync } from 'node:child_process';
import { copyFileSync, mkdirSync, mkdtempSync, readFileSync, readdirSync, rmSync, writeFileSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { dirname, join, resolve } from 'node:path';
import { coreMaterialParse } from '../core-material.mjs';
import { gleamSourceManifest } from '../gleam-material.mjs';
import { recordInputs, verifyInputs } from '../inputs.mjs';
import { gleamHashes, images, inventory } from './material.mjs';

const owner = resolve(new URL('../..', import.meta.url).pathname);
export const encode = value => Buffer.from(JSON.stringify(value) + '\n');
export const hash = value => createHash('sha256').update(value).digest('hex');
const fact = (path, bytes, mode = 0o644) => ({ path, mode, bytes: Buffer.byteLength(bytes), sha256: hash(Buffer.from(bytes)) });
function put(root, path, bytes, mode = 0o644) { mkdirSync(dirname(join(root, path)), { recursive: true }); writeFileSync(join(root, path), bytes, { mode }); }
export async function linuxMaterialFixture(t) {
  const repository = mkdtempSync(join(tmpdir(), 'frameshift-linux-material-')); t.after(() => rmSync(repository, { recursive: true, force: true }));
  const git = args => execFileSync('git', args, { cwd: repository, encoding: 'utf8', stdio: 'pipe' }).trim();
  const commitRef = '1'.repeat(40), mixLock = `%{example: {:git, "https://example.invalid/source.git", "${commitRef}", [ref: "${commitRef}"]}}\n`;
  const manifestText = `packages = [\n  { name = "example", version = "1.0.0", build_tools = ["gleam"], requirements = [], otp_app = "example", source = "hex", outer_checksum = "${'2'.repeat(64)}" },\n]\n\n[requirements]\nexample = { version = "~> 1.0" }\n`;
  for (const folder of ['release', 'release/linux']) for (const name of readdirSync(join(owner, folder))) if (name.endsWith('.mjs') && !name.endsWith('.test.mjs')) put(repository, `${folder}/${name}`, readFileSync(join(owner, folder, name)));
  for (const path of ['.mise.toml', 'release/read-version.exs', 'release/core-material.exs', 'release/linux/verify-version.exs']) { mkdirSync(dirname(join(repository, path)), { recursive: true }); copyFileSync(join(owner, path), join(repository, path)); }
  put(repository, '.gitignore', 'var/\n');
  put(repository, 'apps/core/mix.exs', 'defmodule Fixture do\n  @moduledoc false\n\n  use Mix.Project\n  def project, do: [app: :frameshift_core, version: "0.1.0"]\nend\n');
  put(repository, 'apps/core/mix.lock', mixLock); put(repository, 'packages/decision-kernel/manifest.toml', manifestText);
  git(['init', '-b', 'main']); git(['add', '.']); git(['-c', 'user.name=Fixture', '-c', 'user.email=fixture@example.invalid', 'commit', '-m', 'test(protocol): define retained Ubuntu source assertions']);
  const commit = git(['rev-parse', 'HEAD']), tag = 'v0.1.0'; git(['tag', tag]); mkdirSync(join(repository, 'var'), { mode: 0o700 });
  await recordInputs(repository, tag, commit, join(repository, 'var/inputs'));
  const sourcePath = join(repository, 'var/inputs/source-inputs.json'), source = await verifyInputs(repository, tag, commit, sourcePath);
  const metadata = '[packages]\nexample = "1.0.0"\n\n[git]\n', sourceBytes = 'locked source\n', gleamBytes = 'Gleam source\n';
  const material = [fact('apps/core/deps/example/source.ex', sourceBytes), fact('apps/core/deps/example/.git/HEAD', 'ref: refs/heads/main\n'), fact('packages/decision-kernel/build/packages/example/source.gleam', gleamBytes), fact('packages/decision-kernel/build/packages/gleam.lock', ''), fact('packages/decision-kernel/build/packages/packages.toml', metadata)];
  const base = { schemaVersion: 1, product: source.product, tag, version: source.version, sourceCommit: commit, sourceInputsSha256: hash(encode(source)), parserSourceSha256: hash(readFileSync(join(repository, 'release/core-material.exs'))), publicationAuthority: 'none' };
  const parser = { hex: '2.5.1', modules: ['Elixir.Hex.SCM', 'mix_hex_tarball', 'mix_hex_erl_tar'].map(name => ({ name, sha256: '3'.repeat(64) })) };
  // Independently pinned retained assertions for refusal fixtures. Actual
  // archive/Git receipts are exercised separately against full target builds.
  const core = { ...base, kind: 'locked-core-source-material', lockSha256: hash(Buffer.from(mixLock)), packages: [{ lock: coreMaterialParse('lock', Buffer.from(mixLock))[0], files: [fact('source.ex', sourceBytes)], directories: [{ path: '', mode: 0o755 }] }] };
  const manifest = gleamSourceManifest(Buffer.from(manifestText));
  const gleam = { ...base, kind: 'locked-gleam-source-material', manifestSha256: hash(Buffer.from(manifestText)), fetchedMetadataSha256: hash(Buffer.from(metadata)), fetchedMetadataMode: 0o644, requirements: manifest.requirements,
    packages: [{ lock: manifest.packages[0], innerChecksum: '4'.repeat(64), parser, files: [fact('source.gleam', gleamBytes)], directories: [{ path: '', mode: 0o755 }] }] };
  const coreDir = join(repository, 'var/core-proof'), gleamDir = join(repository, 'var/gleam-proof'); mkdirSync(coreDir, { mode: 0o700 }); mkdirSync(gleamDir, { mode: 0o700 });
  const corePath = join(coreDir, 'core-material.json'), gleamPath = join(gleamDir, 'gleam-material.json'); writeFileSync(corePath, encode(core), { mode: 0o600 }); writeFileSync(gleamPath, encode(gleam), { mode: 0o600 });
  const selected = [];
  for (const file of source.files) {
    let path = file.path;
    if (/^release\/linux\//.test(path)) path = path.replace(/^release\//, '');
    else if (!/^apps\/core\/(?:lib\/|config\/|rel\/|mix\.(?:exs|lock)$)/.test(path) && !/^packages\/decision-kernel\/(?!build\/)/.test(path) && !/^(?:protocol\/|codec\/(?!target\/))/.test(path)) continue;
    selected.push({ path, mode: file.mode === '100755' ? 0o755 : 0o644, bytes: file.bytes, sha256: file.sha256 });
  }
  const candidates = [];
  for (const architecture of ['arm64', 'amd64']) {
    const candidate = join(repository, 'var', architecture); mkdirSync(candidate, { mode: 0o700 });
    const inputRecord = { schemaVersion: 1, kind: 'tagged-closure-candidate', product: source.product, version: source.version, ubuntu: '24.04', architecture, sourceCommit: commit, workingTreeChanged: false,
      publicationAuthority: 'none', tag, sourceInputsSha256: hash(encode(source)), resolvedMaterialAssertion: 'captured-only', toolchains: { otp: '29.1', elixir: '1.20.4', gleam: '1.18.1', gleamArchiveSha256: gleamHashes[architecture], zig: '0.16.0', rust: '1.97.1', hex: '2.5.1' }, images, inputs: [...selected, ...material] };
    put(candidate, 'runtime/root/usr/share/doc/frameshift/build-inputs.json', encode(inputRecord)); put(candidate, 'runtime/root/usr/share/doc/frameshift/source-inputs.json', encode(source));
    const coreRoot = 'runtime/root/usr/lib/frameshift/core';
    put(candidate, `${coreRoot}/releases/start_erl.data`, '17.1 0.1.0\n');
    put(candidate, `${coreRoot}/releases/0.1.0/frameshift_core.rel`, '{release,{"frameshift_core","0.1.0"},{erts,"17.1"},[{frameshift_core,"0.1.0",permanent}]}.\n');
    put(candidate, `${coreRoot}/lib/frameshift_core-0.1.0/ebin/frameshift_core.app`, '{application,frameshift_core,[{vsn,"0.1.0"}]}.\n');
    put(candidate, `package/frameshift_0.1.0_${architecture}.deb`, 'retained fixture bytes; no actual DEB/ELF or installed claim\n');
    const record = { schemaVersion: 1, kind: 'ubuntu-release-candidate', product: source.product, publicationAuthority: 'none', tag, version: source.version, sourceCommit: commit, sourceInputsSha256: hash(encode(source)), ubuntu: '24.04', architecture,
      buildExecution: { daemonArchitecture: 'aarch64', emulated: architecture === 'amd64', buildErlFlags: architecture === 'amd64' ? '+JMsingle true' : '' }, artifacts: [], files: [] };
    const f = { repository, tag, commit, sourcePath, source, architecture, candidate, corePath, coreSha256: hash(encode(core)), gleamPath, gleamSha256: hash(encode(gleam)), core, gleam, record, inputRecord, output: join(repository, 'var/join-' + architecture) };
    updateCandidate(f); candidates.push(f);
  }
  return { ...candidates[0], candidates };
}
export function updateCandidate(f, change = () => {}) {
  change(f.record); f.record.files = inventory(f.candidate, ['package', 'runtime']);
  const path = `package/frameshift_0.1.0_${f.architecture}.deb`, archive = f.record.files.find(file => file.path === path);
  f.record.artifacts = [{ platform: 'ubuntu', architecture: f.architecture, format: 'deb', path, bytes: archive.bytes, sha256: archive.sha256 }];
  const bytes = encode(f.record); writeFileSync(join(f.candidate, 'candidate.json'), bytes, { mode: 0o600 }); f.candidateSha256 = hash(bytes); return f;
}
export function changeInputs(f, change) {
  change(f.inputRecord); writeFileSync(join(f.candidate, 'runtime/root/usr/share/doc/frameshift/build-inputs.json'), encode(f.inputRecord)); return updateCandidate(f);
}
