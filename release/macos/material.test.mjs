import assert from 'node:assert/strict';
import { createHash } from 'node:crypto';
import { execFileSync, spawnSync } from 'node:child_process';
import { chmodSync, linkSync, lstatSync, mkdirSync, readFileSync, readdirSync, rmSync, truncateSync, writeFileSync } from 'node:fs';
import { dirname, join, resolve } from 'node:path';
import test from 'node:test';
import { coreMaterialParse } from '../core-material.mjs';
import { gleamSourceManifest } from '../gleam-material.mjs';
import { macImageTool } from './dmg.mjs';
import { macMaterialJoin } from './material.mjs';
import { sourceFixture } from './source-fixture.mjs';

const owner = resolve(new URL('../..', import.meta.url).pathname);
const encode = value => Buffer.from(JSON.stringify(value) + '\n');
const hash = value => createHash('sha256').update(value).digest('hex');
async function fixture(t) {
  const commit = '1'.repeat(40), outer = '2'.repeat(64), keys = ['earmark_parser', 'example', 'file_system'];
  const mixLock = `%{${keys.map(key => `${key}: {:git, "https://example.invalid/source.git", "${commit}", [ref: "${commit}"]}`).join(', ')}}\n`;
  const manifestText = `packages = [\n  { name = "example", version = "1.0.0", build_tools = ["gleam"], requirements = [], otp_app = "example", source = "hex", outer_checksum = "${outer}" },\n]\n\n[requirements]\nexample = { version = "~> 1.0" }\n`;
  const metadata = '[packages]\nexample = "1.0.0"\n\n[git]\n';
  const sourceFiles = { 'apps/core/mix.lock': mixLock, 'packages/decision-kernel/manifest.toml': manifestText };
  for (const folder of ['release', 'release/macos']) for (const name of readdirSync(join(owner, folder))) {
    if (name.endsWith('.mjs') && !name.endsWith('.test.mjs')) sourceFiles[`${folder}/${name}`] = readFileSync(join(owner, folder, name));
  }
  sourceFiles['release/core-material.exs'] = readFileSync(join(owner, 'release/core-material.exs'));
  const f = await sourceFixture(t, { sourceFiles,
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
function changedReceipt(f, name, change) {
  const record = JSON.parse(readFileSync(f[name + 'Path'])); change(record);
  const bytes = encode(record); writeFileSync(f[name + 'Path'], bytes); return { ...f, [name + 'Sha256']: hash(bytes) };
}

test('retained source assertions bind real source/CPU candidates with explicit generated scope and no-effect replay', async t => {
  const f = await fixture(t), joined = await macMaterialJoin(f);
  assert.equal(joined.provedSourceFiles, 5); assert.equal(joined.publicationAuthority, 'none');
  assert.deepEqual(joined.generatedInputs.map(file => file.reason), ['generated-lexer-parser', 'generated-native-helper', 'compiler-lock-metadata']);
  const path = join(f.output, 'dependency-inputs.json'), before = lstatSync(path);
  assert.equal(before.mode & 0o7777, 0o600); assert.equal(lstatSync(f.output).mode & 0o7777, 0o700);
  const replay = await macMaterialJoin(f); assert.equal(replay.recordSha256, joined.recordSha256); assert.equal(replay.disposition, 'retained-bytes-verified');
  assert.equal(lstatSync(path).ino, before.ino); assert.equal(lstatSync(path).mtimeMs, before.mtimeMs);
  const cli = JSON.parse(execFileSync('mise', ['exec', '--', 'node', join(f.repository, 'release/macos/material-cli.mjs'), f.tag, f.commit, f.sourcePath, f.architecture, f.candidate, f.candidateSha256, f.corePath, f.coreSha256, f.gleamPath, f.gleamSha256, f.output], { cwd: f.repository, encoding: 'utf8', timeout: 60_000, maxBuffer: 64 * 1024 }));
  assert.equal(cli.recordSha256, joined.recordSha256); assert.equal(cli.disposition, 'retained-bytes-verified');
  const intel = await macMaterialJoin({ ...f, architecture: 'x86_64', candidate: f.intelCandidate, candidateSha256: f.intelSha256, output: join(f.repository, 'var/intel-join') });
  assert.equal(intel.provedSourceFiles, joined.provedSourceFiles);
});

test('independent digests, frozen identities, source facts and parser schema conflicts refuse before output', async t => {
  const f = await fixture(t);
  for (const key of ['coreSha256', 'gleamSha256', 'candidateSha256']) await assert.rejects(() => macMaterialJoin({ ...f, [key]: 'f'.repeat(64) }), /digest|identity/);
  const original = readFileSync(f.corePath), mutations = [record => { record.sourceInputsSha256 = 'f'.repeat(64); }, record => { record.lockSha256 = 'f'.repeat(64); }, record => { record.packages[0].files[0].sha256 = 'f'.repeat(64); }, record => { record.packages[0].files.push(record.packages[0].files[0]); }, record => { record.packages[0].files[0].path = '../escape'; }, record => { record.publisherAuthenticated = true; }];
  for (const mutation of mutations) { await assert.rejects(() => macMaterialJoin(changedReceipt(f, 'core', mutation))); writeFileSync(f.corePath, original); }
  const bad = changedReceipt(f, 'gleam', record => { record.packages[0].parser.hex = 'other'; }); await assert.rejects(() => macMaterialJoin(bad), /parser/);
  assert.equal(readdirSync(join(f.repository, 'var')).includes('material-join'), false);
});

test('missing proof for a generated source prerequisite and unexplained captured material refuse', async t => {
  const f = await fixture(t);
  const bad = changedReceipt(f, 'core', record => { record.packages[0].files = [{ ...record.packages[0].files[0], path: 'src/other.xrl' }]; });
  await assert.rejects(() => macMaterialJoin(bad), /source differs/);
  writeFileSync(f.corePath, encode(f.core));
  const path = join(f.candidate, 'candidate.json'), record = JSON.parse(readFileSync(path)); record.material.push({ path: 'apps/core/deps/example/unexplained.ex', mode: 0o644, bytes: 1, sha256: 'a'.repeat(64) });
  const bytes = encode(record); writeFileSync(path, bytes); await assert.rejects(() => macMaterialJoin({ ...f, candidateSha256: hash(bytes) }), /unexplained/);
});

test('receipt alias/permissions/size and retained partial or changed output refuse while preserving bytes', async t => {
  const f = await fixture(t), alias = join(f.repository, 'var/alias'); linkSync(f.corePath, alias); await assert.rejects(() => macMaterialJoin(f), /alias/); rmSync(alias);
  chmodSync(f.corePath, 0o644); await assert.rejects(() => macMaterialJoin(f), /unsafe/); chmodSync(f.corePath, 0o600);
  truncateSync(f.corePath, 16 * 1024 * 1024 + 1); await assert.rejects(() => macMaterialJoin(f), /size/); writeFileSync(f.corePath, encode(f.core));
  mkdirSync(f.output, { mode: 0o700 }); writeFileSync(join(f.output, 'check.pending'), 'retained', { mode: 0o600 }); await assert.rejects(() => macMaterialJoin(f), /incomplete/); assert.deepEqual(readdirSync(f.output), ['check.pending']);
  const complete = { ...f, output: join(f.repository, 'var/complete') }; await macMaterialJoin(complete);
  const path = join(complete.output, 'dependency-inputs.json'), bytes = readFileSync(path); writeFileSync(path, Buffer.from(bytes).fill(32, 0, 1)); await assert.rejects(() => macMaterialJoin(complete), /conflicting/);
});

test('in-flight receipt/source/namespace mutation refuses and keeps incomplete custody', async t => {
  const f = await fixture(t); let versions = 0;
  await assert.rejects(() => macMaterialJoin(f, { tool: (command, args, timeout) => {
    const result = macImageTool(command, args, timeout);
    if (args.includes(join(f.repository, 'release/linux/verify-version.exs')) && ++versions === 2) {
      const record = JSON.parse(readFileSync(f.corePath)); record.lockSha256 = 'f'.repeat(64); writeFileSync(f.corePath, encode(record));
    }
    return result;
  } }), /identity/);
  assert.deepEqual(readdirSync(f.output), ['check.pending']);
});

test('CLI fixed usage and refusal do not disclose supplied receipt paths', () => {
  const run = args => spawnSync('mise', ['exec', '--', 'node', join(owner, 'release/macos/material-cli.mjs'), ...args], { cwd: owner, encoding: 'utf8', timeout: 60_000 });
  assert.equal(run([]).status, 64);
  const result = run(['v1.2.3', 'f'.repeat(40), 'private-path', 'arm64', 'private-path', 'a'.repeat(64), 'private-path', 'b'.repeat(64), 'private-path', 'c'.repeat(64), 'private-path']);
  assert.equal(result.status, 1); assert.equal(result.stdout, ''); assert.equal(result.stderr, 'Mac dependency inputs: unavailable, unsafe or conflicting source/receipt/candidate/output\n');
});
