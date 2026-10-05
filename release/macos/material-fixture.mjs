import { createHash } from 'node:crypto';
import { mkdirSync, readFileSync, readdirSync, writeFileSync } from 'node:fs';
import { dirname, join, resolve } from 'node:path';
import { coreMaterialParse } from '../core-material.mjs';
import { gleamSourceManifest } from '../gleam-material.mjs';
import { sourceFixture } from './source-fixture.mjs';

const owner = resolve(new URL('../..', import.meta.url).pathname);
const encode = value => Buffer.from(JSON.stringify(value) + '\n');
const hash = value => createHash('sha256').update(value).digest('hex');
export async function materialFixture(t, { sourceFiles: extraSources = {}, prepareMaterial, prepareApp } = {}) {
  const commit = '1'.repeat(40), outer = '2'.repeat(64), keys = ['earmark_parser', 'example', 'file_system'];
  const mixLock = `%{${keys.map(key => `${key}: {:git, "https://example.invalid/source.git", "${commit}", [ref: "${commit}"]}`).join(', ')}}\n`;
  const manifestText = `packages = [\n  { name = "example", version = "1.0.0", build_tools = ["gleam"], requirements = [], otp_app = "example", source = "hex", outer_checksum = "${outer}" },\n]\n\n[requirements]\nexample = { version = "~> 1.0" }\n`;
  const metadata = '[packages]\nexample = "1.0.0"\n\n[git]\n';
  const sourceFiles = { 'apps/core/mix.lock': mixLock, 'packages/decision-kernel/manifest.toml': manifestText };
  for (const folder of ['release', 'release/macos']) for (const name of readdirSync(join(owner, folder))) {
    if (name.endsWith('.mjs') && !name.endsWith('.test.mjs')) sourceFiles[`${folder}/${name}`] = readFileSync(join(owner, folder, name));
  }
  sourceFiles['release/core-material.exs'] = readFileSync(join(owner, 'release/core-material.exs'));
  Object.assign(sourceFiles, extraSources);
  const f = await sourceFixture(t, { sourceFiles,
    prepareMaterial, prepareApp,
    materialFiles: { 'apps/core/deps/earmark_parser/src/earmark_parser_link_text_lexer.xrl': 'grammar source\n',
      'apps/core/deps/earmark_parser/src/earmark_parser_link_text_lexer.erl': 'generated lexer\n', 'apps/core/deps/file_system/c_src/mac/main.c': 'native helper source\n',
      'apps/core/deps/file_system/priv/mac_listener': 'generated helper\n', 'packages/decision-kernel/build/packages/packages.toml': metadata, 'packages/decision-kernel/build/packages/gleam.lock': '' } });
  const base = { schemaVersion: 1, product: f.source.product, tag: f.tag, version: f.source.version, sourceCommit: f.commit,
    sourceInputsSha256: hash(encode(f.source)), parserSourceSha256: hash(readFileSync(join(owner, 'release/core-material.exs'))), publicationAuthority: 'none' };
  const material = f.candidates[0].record.material;
  const sourceItem = (prefix, exclude = []) => {
    const files = material.filter(file => file.path.startsWith(prefix) && !exclude.includes(file.path)).map(file => ({ ...file, path: file.path.slice(prefix.length) }));
    const directories = new Set(['']); for (const file of files) { let path = dirname(file.path); while (path !== '.') { directories.add(path); path = dirname(path); } }
    return { files, directories: [...directories].sort().map(path => ({ path, mode: 0o755 })) };
  };
  // Receipts here are independently pinned retained-purpose assertions; the
  // full isolated host join separately uses actual archive/Git verifier output.
  // Real Git/Mix identity, version consumers, CPU binaries and seals are used.
  const core = { ...base, kind: 'locked-core-source-material', lockSha256: hash(Buffer.from(mixLock)),
    packages: coreMaterialParse('lock', Buffer.from(mixLock)).map(lock => ({ lock, ...sourceItem(`apps/core/deps/${lock.key}/`, ['apps/core/deps/earmark_parser/src/earmark_parser_link_text_lexer.erl', 'apps/core/deps/file_system/priv/mac_listener']) })) };
  const manifest = gleamSourceManifest(Buffer.from(manifestText));
  const gleam = { ...base, kind: 'locked-gleam-source-material', manifestSha256: hash(Buffer.from(manifestText)), fetchedMetadataSha256: hash(Buffer.from(metadata)), fetchedMetadataMode: 0o644,
    requirements: manifest.requirements, packages: manifest.packages.map(lock => ({ lock, innerChecksum: '4'.repeat(64),
      parser: { hex: '2.5.1', modules: ['Elixir.Hex.SCM', 'mix_hex_tarball', 'mix_hex_erl_tar'].map(name => ({ name, sha256: '3'.repeat(64) })) }, ...sourceItem(`packages/decision-kernel/build/packages/${lock.name}/`) })) };
  const coreDir = join(f.repository, 'var/core-proof'), gleamDir = join(f.repository, 'var/gleam-proof'); mkdirSync(coreDir, { mode: 0o700 }); mkdirSync(gleamDir, { mode: 0o700 });
  const corePath = join(coreDir, 'core-material.json'), gleamPath = join(gleamDir, 'gleam-material.json');
  writeFileSync(corePath, encode(core), { mode: 0o600 }); writeFileSync(gleamPath, encode(gleam), { mode: 0o600 });
  return { ...f, architecture: 'arm64', candidate: f.armCandidate, candidateSha256: f.armSha256, corePath, coreSha256: hash(encode(core)), gleamPath, gleamSha256: hash(encode(gleam)), core, gleam, output: join(f.repository, 'var/material-join') };
}
