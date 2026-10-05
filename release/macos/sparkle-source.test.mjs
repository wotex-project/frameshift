import assert from 'node:assert/strict';
import { execFileSync, spawnSync } from 'node:child_process';
import { createHash } from 'node:crypto';
import { chmodSync, copyFileSync, existsSync, linkSync, lstatSync, mkdirSync, mkdtempSync, readFileSync, rmSync, symlinkSync, unlinkSync, writeFileSync } from 'node:fs';
import { dirname, join } from 'node:path';
import test from 'node:test';
import { recordInputs, verifyInputs } from '../inputs.mjs';
import { sparkleArchive } from '../macos-framework.mjs';
import { checkSparkleSource, readSparkleSourceReceipt, readSwiftManifest } from './sparkle-source.mjs';

const owner = new URL('../..', import.meta.url).pathname, archive = process.env.FRAMESHIFT_SPARKLE_ARCHIVE;
const mac = { skip: !(process.platform === 'darwin' && archive) && 'Exact pinned FRAMESHIFT_SPARKLE_ARCHIVE on macOS required' };
const encode = value => Buffer.from(JSON.stringify(value) + '\n'), hash = bytes => createHash('sha256').update(bytes).digest('hex');
const custody = path => ['dev', 'ino', 'mode', 'size', 'mtimeNs', 'ctimeNs'].map(key => String(lstatSync(path, { bigint: true })[key]));
async function fixture(t, { checksum = sparkleArchive.sha256 } = {}) {
  const root = mkdtempSync('/tmp/frameshift-updater-source-test.'); chmodSync(root, 0o700); t.after(() => rmSync(root, { recursive: true, force: true }));
  const repository = join(root, 'source'); mkdirSync(repository, { mode: 0o700 });
  const git = args => execFileSync('git', args, { cwd: repository, encoding: 'utf8', stdio: 'pipe' }).trim();
  function put(path, bytes) { const full = join(repository, path); mkdirSync(dirname(full), { recursive: true }); writeFileSync(full, bytes); }
  for (const path of ['.mise.toml', 'release/read-version.exs']) { mkdirSync(dirname(join(repository, path)), { recursive: true }); copyFileSync(join(owner, path), join(repository, path)); }
  put('.gitignore', 'var/\n.build/\n');
  put('apps/core/mix.exs', 'defmodule SourceFixture do\n  @moduledoc false\n\n  use Mix.Project\n  def project, do: [app: :frameshift_core, version: "0.1.0"]\nend\n');
  put('apps/macos/Package.swift', `// swift-tools-version: 6.0\nimport PackageDescription\nlet package = Package(name: "SDKInputFixture", platforms: [.macOS(.v14)], targets: [.binaryTarget(name: "Sparkle", url: "${sparkleArchive.url}", checksum: "${checksum}")])\n`);
  git(['init', '-b', 'main']); git(['add', '.']); git(['-c', 'user.name=Fixture', '-c', 'user.email=fixture@example.invalid', 'commit', '-m', 'test(mac): define frozen updater input fixture']);
  const tag = 'v0.1.0', commit = git(['rev-parse', 'HEAD']); git(['tag', tag]); mkdirSync(join(repository, 'var'), { mode: 0o700 });
  await recordInputs(repository, tag, commit, join(repository, 'var/inputs'));
  const sourcePath = join(repository, 'var/inputs/source-inputs.json'), source = await verifyInputs(repository, tag, commit, sourcePath);
  const zip = join(root, 'sdk.zip'); copyFileSync(archive, zip); chmodSync(zip, 0o600);
  execFileSync('/usr/bin/unzip', ['-q', zip, 'Sparkle.xcframework/macos-arm64_x86_64/Sparkle.framework/*', '-d', root], { timeout: 30_000, stdio: 'pipe' });
  return { root, repository, git, tag, commit, sourcePath, source, archive: zip,
    framework: join(root, 'Sparkle.xcframework/macos-arm64_x86_64/Sparkle.framework'), output: join(repository, 'var/sdk-material') };
}

test('actual frozen Git/Mix/SwiftPM and SDK bytes produce an independently pinned unchanged input receipt', mac, async t => {
  const f = await fixture(t), before = custody(f.archive), first = await checkSparkleSource(f), path = join(f.output, 'sparkle-material.json');
  const record = await readSparkleSourceReceipt(path, first.receiptSha256, f.source);
  assert.equal(record.framework.files.length, 85); assert.equal(record.native.length, 5); assert.equal(record.publicationAuthority, 'none');
  assert.equal(record.packageSha256, f.source.files.find(file => file.path === 'apps/macos/Package.swift').sha256);
  assert.equal(JSON.stringify(record).includes(f.root), false);
  const retained = custody(path), replay = await checkSparkleSource(f);
  assert.equal(replay.disposition, 'retained-bytes-verified'); assert.equal(replay.receiptSha256, first.receiptSha256);
  assert.deepEqual(custody(path), retained); assert.deepEqual(custody(f.archive), before);
  await assert.rejects(() => readSparkleSourceReceipt(path, '0'.repeat(64), f.source));
  await assert.rejects(() => readSparkleSourceReceipt(path, first.receiptSha256, { ...f.source, commit: '0'.repeat(40) }));
});

test('SwiftPM parses a wrong frozen binary pin and refuses before any receipt output', mac, async t => {
  const f = await fixture(t, { checksum: '0'.repeat(64) });
  await assert.rejects(() => checkSparkleSource(f)); assert.equal(existsSync(f.output), false);
  writeFileSync(join(f.repository, 'apps/macos/Package.swift'), 'changed uncommitted manifest');
  await assert.rejects(() => checkSparkleSource(f)); assert.equal(existsSync(f.output), false);
});

test('same-byte cache mutation during the second manifest child retains incomplete custody and refuses replay', mac, async t => {
  const f = await fixture(t), header = join(f.framework, 'Versions/B/Headers/SPUUpdater.h'); let calls = 0;
  const manifest = (...args) => { const result = readSwiftManifest(...args); if (++calls === 2) writeFileSync(header, readFileSync(header)); return result; };
  await assert.rejects(() => checkSparkleSource(f, { manifest }));
  assert.ok(existsSync(join(f.output, 'check.pending'))); assert.equal(existsSync(join(f.output, 'sparkle-material.json')), false);
  await assert.rejects(() => checkSparkleSource(f)); assert.ok(existsSync(join(f.output, 'check.pending')));
});

test('independent consumer rejects authentic-digest wrong schemas/profiles, aliases and changed/partial output without repair', mac, async t => {
  const f = await fixture(t), first = await checkSparkleSource(f), path = join(f.output, 'sparkle-material.json'), original = readFileSync(path), record = JSON.parse(original);
  for (const mutate of [r => { r.archive.version = '2.9.3'; }, r => { r.packageSha256 = '0'.repeat(64); },
    r => { r.framework.links[0].target = '/outside'; }, r => { r.native[0].slices[0].filetype = 8; },
    r => { r.framework.files[0].mode = 0o666; }, r => { r.extra = 'unsupported'; }]) {
    const changed = structuredClone(record); mutate(changed); const bytes = encode(changed); writeFileSync(path, bytes);
    await assert.rejects(() => readSparkleSourceReceipt(path, hash(bytes), f.source)); assert.deepEqual(readFileSync(path), bytes);
  }
  writeFileSync(path, original);
  linkSync(path, join(f.root, 'receipt-alias')); await assert.rejects(() => readSparkleSourceReceipt(path, first.receiptSha256, f.source)); unlinkSync(join(f.root, 'receipt-alias'));
  writeFileSync(join(f.output, 'unknown'), 'retained unknown'); await assert.rejects(() => checkSparkleSource(f)); assert.equal(readFileSync(join(f.output, 'unknown'), 'utf8'), 'retained unknown'); unlinkSync(join(f.output, 'unknown'));
  unlinkSync(path); symlinkSync(f.archive, path); await assert.rejects(() => checkSparkleSource(f)); unlinkSync(path);
  writeFileSync(join(f.output, 'check.pending'), 'retained pending', { mode: 0o600 }); await assert.rejects(() => checkSparkleSource(f)); assert.equal(readFileSync(join(f.output, 'check.pending'), 'utf8'), 'retained pending');
});

test('source CLI usage and refusal are finite and exclude supplied private inputs', () => {
  const cli = join(owner, 'release/macos/sparkle-source.mjs');
  const run = args => spawnSync(process.execPath, [cli, ...args], { encoding: 'utf8', timeout: 10_000 });
  assert.equal(run([]).status, 64);
  const result = run(['v0.1.0', '0'.repeat(40), 'private-source', 'private-archive', 'private-cache', 'private-output']);
  assert.equal(result.status, 1); assert.equal(result.stdout, ''); assert.equal(result.stderr, 'updater source inputs or receipt unavailable, unsafe or changed\n');
});
