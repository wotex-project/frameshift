import assert from 'node:assert/strict';
import { createHash } from 'node:crypto';
import { chmodSync, copyFileSync, existsSync, mkdirSync, readFileSync, renameSync, symlinkSync, unlinkSync, writeFileSync } from 'node:fs';
import { dirname, join } from 'node:path';
import test from 'node:test';
import { sparkleArchive, sparkleInputArchive, sparkleInputFramework } from '../macos-framework.mjs';
import { run, temporary } from './fixture.mjs';
import { captureSparkleInputs } from './sparkle-capture.mjs';
import { macMaterial } from './candidate.mjs';
import { readSwiftManifest } from './sparkle-source.mjs';

const archive = process.env.FRAMESHIFT_SPARKLE_ARCHIVE;
const mac = { skip: !(process.platform === 'darwin' && archive) && 'Exact pinned FRAMESHIFT_SPARKLE_ARCHIVE on macOS required' };
const packageText = checksum => `// swift-tools-version: 6.0\nimport PackageDescription\nlet package = Package(name: "CaptureFixture", platforms: [.macOS(.v14)], targets: [.binaryTarget(name: "Sparkle", url: "${sparkleArchive.url}", checksum: "${checksum}")])\n`;
function packageFixture(t) {
  const repository = temporary(t), packageRoot = join(repository, 'apps/macos'); mkdirSync(packageRoot, { recursive: true });
  const packagePath = join(packageRoot, 'Package.swift'); writeFileSync(packagePath, packageText(sparkleArchive.sha256));
  return { repository, packageRoot, packagePath };
}
function resolvedFixture(t) {
  const f = packageFixture(t), zip = join(f.repository, sparkleInputArchive); mkdirSync(dirname(zip), { recursive: true, mode: 0o700 });
  copyFileSync(archive, zip); chmodSync(zip, 0o600);
  // Actual SwiftPM resolves the fixed remote checksum into the compiler cache.
  // The capture gate itself never resolves or downloads an artifact.
  run('/usr/bin/swift', ['package', '--package-path', f.packageRoot, 'resolve']);
  return { ...f, zip, framework: join(f.repository, sparkleInputFramework), statePath: join(f.packageRoot, '.build/workspace-state.json') };
}

test('actual SwiftPM root artifact supplies all original SDK facts without rewriting cache or state', mac, async t => {
  const f = resolvedFixture(t), state = readFileSync(f.statePath), before = readFileSync(join(f.framework, 'Versions/B/Sparkle'));
  const inputs = await captureSparkleInputs(f.repository);
  assert.equal(inputs.length, 86); assert.ok(inputs.some(file => file.path === sparkleInputArchive && file.sha256 === sparkleArchive.sha256));
  assert.equal(inputs.find(file => file.path === sparkleInputFramework + 'Versions/B/Sparkle').sha256, createHash('sha256').update(before).digest('hex'));
  assert.deepEqual(await captureSparkleInputs(f.repository), inputs); assert.deepEqual(readFileSync(f.statePath), state); assert.deepEqual(readFileSync(join(f.framework, 'Versions/B/Sparkle')), before);
});

test('unknown/redirected workspace identity and unsafe or changed cached bytes refuse without repair', mac, async t => {
  const f = resolvedFixture(t), original = readFileSync(f.statePath), state = JSON.parse(original);
  for (const change of [s => { s.version = 5; }, s => { s.object.artifacts[0].path = '/outside/Sparkle.xcframework'; },
    s => { s.object.artifacts[0].packageRef.kind = 'fileSystem'; }, s => { s.object.artifacts[0].source.checksum = '0'.repeat(64); },
    s => { s.object.artifacts[0].kind = { unknown: {} }; }, s => { s.object.dependencies.push({ unknown: true }); },
    s => { s.object.artifacts.push(s.object.artifacts[0]); }, s => { s.object.prebuilts.push({ unknown: true }); }]) {
    const changed = structuredClone(state); change(changed); const bytes = Buffer.from(JSON.stringify(changed)); writeFileSync(f.statePath, bytes);
    await assert.rejects(() => captureSparkleInputs(f.repository)); assert.deepEqual(readFileSync(f.statePath), bytes);
  }
  writeFileSync(f.statePath, original);
  const six = structuredClone(state); six.version = 6; delete six.object.prebuilts; six.object.artifacts[0].kind = 'xcframework'; writeFileSync(f.statePath, JSON.stringify(six));
  assert.equal((await captureSparkleInputs(f.repository)).length, 86); writeFileSync(f.statePath, original);
  const header = join(f.framework, 'Versions/B/Headers/SPUUpdater.h'), bytes = readFileSync(header); writeFileSync(header, Buffer.from(bytes).fill(32, 0, 1));
  await assert.rejects(() => captureSparkleInputs(f.repository)); writeFileSync(header, bytes);
  chmodSync(f.zip, 0o644); await assert.rejects(() => captureSparkleInputs(f.repository)); chmodSync(f.zip, 0o600);
  const artifacts = join(f.packageRoot, '.build/artifacts'), retained = artifacts + '-retained'; renameSync(artifacts, retained); symlinkSync(retained, artifacts);
  await assert.rejects(() => captureSparkleInputs(f.repository)); unlinkSync(artifacts); renameSync(retained, artifacts);
  assert.ok(existsSync(f.framework)); assert.deepEqual(readFileSync(header), bytes);
});

test('absent updater preserves the inventory and wrong pins or manifest-child mutation refuse', { skip: process.platform !== 'darwin' }, async t => {
  const f = packageFixture(t);
  writeFileSync(f.packagePath, '// swift-tools-version: 6.0\nimport PackageDescription\nlet package = Package(name: "Empty", targets: [])\n');
  assert.deepEqual(await captureSparkleInputs(f.repository), []); assert.equal(existsSync(join(f.packageRoot, '.build/sparkle')), false);
  writeFileSync(f.packagePath, packageText('0'.repeat(64))); await assert.rejects(() => captureSparkleInputs(f.repository));
  writeFileSync(f.packagePath, '// swift-tools-version: 6.0\nimport PackageDescription\nlet package = Package(name: "Empty", targets: [])\n');
  await assert.rejects(() => captureSparkleInputs(f.repository, { manifest: (...args) => { const result = readSwiftManifest(...args); writeFileSync(f.packagePath, readFileSync(f.packagePath)); return result; } }));
});

test('the complete SDK shares the native producer aggregate member ceiling with core and Gleam inputs', mac, async t => {
  const f = resolvedFixture(t), core = join(f.repository, 'apps/core/deps'), gleam = join(f.repository, 'packages/decision-kernel/build/packages');
  mkdirSync(core, { recursive: true }); mkdirSync(gleam, { recursive: true }); writeFileSync(join(gleam, 'source.gleam'), '');
  // 8,040 core/Gleam members plus the actual 152-member SDK/archive profile.
  for (let index = 0; index < 8037; index++) writeFileSync(join(core, `source-${index}`), '');
  assert.equal((await macMaterial(f.repository)).length, 8124);
  writeFileSync(join(core, 'one-more'), '');
  await assert.rejects(() => macMaterial(f.repository), /aggregate inventory limit/);
  assert.ok(existsSync(join(core, 'one-more')));
});
