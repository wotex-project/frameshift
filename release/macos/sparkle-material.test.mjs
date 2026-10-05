import assert from 'node:assert/strict';
import { spawnSync } from 'node:child_process';
import { chmodSync, copyFileSync, linkSync, lstatSync, mkdirSync, mkdtempSync, readFileSync, rmSync, symlinkSync, unlinkSync, writeFileSync } from 'node:fs';
import { join } from 'node:path';
import test from 'node:test';
import { sparkleArchive, sparkleRoot } from '../macos-framework.mjs';
import { inspectMachO } from './closure.mjs';
import { stageSparkleFramework, verifySparkleFramework } from './sparkle-material.mjs';

const archive = process.env.FRAMESHIFT_SPARKLE_ARCHIVE;
const live = process.platform === 'darwin' && archive;
const skip = !live && 'Exact pinned FRAMESHIFT_SPARKLE_ARCHIVE on macOS required';
const owner = new URL('../..', import.meta.url).pathname;
const custody = path => ['dev', 'ino', 'mode', 'size', 'mtimeNs', 'ctimeNs'].map(key => String(lstatSync(path, { bigint: true })[key]));
function work(t) {
  const parent = mkdtempSync('/tmp/.package.'); chmodSync(parent, 0o700);
  t.after(() => rmSync(parent, { recursive: true, force: true }));
  const app = join(parent, 'Frameshift.app'); mkdirSync(join(app, 'Contents'), { recursive: true, mode: 0o755 });
  return { parent, app };
}
function run(command, args) {
  const result = spawnSync(command, args, { timeout: 30_000, maxBuffer: 64 * 1024 });
  assert.equal(result.status, 0); return result;
}
function source(t) {
  const f = work(t), zip = join(f.parent, 'sdk.zip'); copyFileSync(archive, zip); chmodSync(zip, 0o600);
  run('/usr/bin/unzip', ['-q', zip, 'Sparkle.xcframework/macos-arm64_x86_64/Sparkle.framework/*', '-d', f.parent]);
  return { ...f, zip, framework: join(f.parent, 'Sparkle.xcframework/macos-arm64_x86_64/Sparkle.framework') };
}

test('archive type, aliases, size, permission and digest refuse before output creation', { skip: process.platform !== 'darwin' }, async t => {
  const f = work(t), zip = join(f.parent, 'sdk.zip');
  writeFileSync(zip, Buffer.alloc(sparkleArchive.bytes), { mode: 0o600 });
  const check = () => stageSparkleFramework(zip, f.app, 'arm64');
  await assert.rejects(check); assert.throws(() => lstatSync(join(f.app, 'Contents/Frameworks')), { code: 'ENOENT' });
  chmodSync(zip, 0o666); await assert.rejects(check); chmodSync(zip, 0o600);
  linkSync(zip, join(f.parent, 'alias')); await assert.rejects(check); unlinkSync(join(f.parent, 'alias'));
  unlinkSync(zip); symlinkSync('unknown', zip); await assert.rejects(check); unlinkSync(zip); mkdirSync(zip); await assert.rejects(check);
  assert.throws(() => lstatSync(join(f.app, 'Contents/Frameworks')), { code: 'ENOENT' });
});

test('fixed CLI usage and refusal never disclose the supplied private path', () => {
  const cli = join(owner, 'release/macos/sparkle-material.mjs');
  const run = args => spawnSync(process.execPath, [cli, ...args], { encoding: 'utf8', timeout: 5000 });
  assert.equal(run([]).status, 64);
  const result = run(['verify', 'private-updater-archive', 'private-framework']);
  assert.equal(result.status, 1); assert.equal(result.stdout, '');
  assert.equal(result.stderr, 'pinned updater material unavailable, unsafe or changed\n');
});

test('actual archive joins every compilation input and repeated CLI admission leaves custody unchanged', { skip }, async t => {
  const f = source(t), before = custody(f.zip), core = join(f.framework, 'Versions/B/Sparkle'), cache = custody(core);
  const result = await verifySparkleFramework(f.zip, f.framework);
  assert.equal(result.publicationAuthority, 'none'); assert.deepEqual(result.archive, sparkleArchive);
  assert.equal(result.framework.links.length, 9); assert.equal(result.native.length, 5);
  assert.ok(result.framework.files.length > 50);
  const cli = run(process.execPath, [join(owner, 'release/macos/sparkle-material.mjs'), 'verify', f.zip, f.framework]);
  assert.deepEqual(JSON.parse(cli.stdout), result);
  assert.deepEqual(custody(f.zip), before); assert.deepEqual(custody(core), cache);
  assert.equal(JSON.stringify(result).includes(f.parent), false);
});

test('same-size archive and cache changes, extra/missing files, aliases and unsafe members refuse without repair', { skip }, async t => {
  const f = source(t), core = join(f.framework, 'Versions/B/Sparkle'), original = readFileSync(core), zipBytes = readFileSync(f.zip);
  const check = () => verifySparkleFramework(f.zip, f.framework);
  const changed = Buffer.from(zipBytes); changed[changed.length - 1] ^= 1; writeFileSync(f.zip, changed); await assert.rejects(check); assert.deepEqual(readFileSync(f.zip), changed); writeFileSync(f.zip, zipBytes);
  const altered = Buffer.from(original); altered[altered.length - 1] ^= 1; writeFileSync(core, altered); await assert.rejects(check); assert.deepEqual(readFileSync(core), altered); writeFileSync(core, original);
  chmodSync(core, 0o777); await assert.rejects(check); chmodSync(core, 0o755);
  writeFileSync(join(f.framework, 'extra'), 'retained'); await assert.rejects(check); unlinkSync(join(f.framework, 'extra'));
  const alias = join(f.framework, 'Versions/Current'); unlinkSync(alias); symlinkSync('../outside', alias); await assert.rejects(check); unlinkSync(alias); symlinkSync('B', alias);
  linkSync(core, join(f.parent, 'core-alias')); await assert.rejects(check); unlinkSync(join(f.parent, 'core-alias'));
  unlinkSync(core); await assert.rejects(check);
});

test('both CPU derivations use real lipo slices and preserve every common file and alias', { skip }, async t => {
  const before = custody(archive);
  for (const architecture of ['arm64', 'x86_64']) {
    const f = work(t), result = await stageSparkleFramework(archive, f.app, architecture);
    assert.equal(result.architecture, architecture); assert.equal(result.derived.links.length, 9);
    const native = new Set(result.native.map(file => file.path));
    assert.deepEqual(result.derived.files.filter(file => !native.has(file.path)), result.source.files.filter(file => !native.has(file.path)));
    for (const file of result.native) {
      const target = join(f.app, sparkleRoot, file.path);
      assert.deepEqual(await inspectMachO(target), file.slices); assert.deepEqual(file.slices.map(slice => slice.arch), [architecture]);
      run('/usr/bin/codesign', ['--verify', '--strict', target]);
    }
    const retained = readFileSync(join(f.app, sparkleRoot, 'Versions/B/Sparkle'));
    await assert.rejects(() => stageSparkleFramework(archive, f.app, architecture));
    assert.deepEqual(readFileSync(join(f.app, sparkleRoot, 'Versions/B/Sparkle')), retained);
  }
  assert.deepEqual(custody(archive), before);
});

test('nonprivate or aliased stage and unsupported CPU refuse before framework creation', { skip: process.platform !== 'darwin' }, async t => {
  const f = work(t), missing = join(f.parent, 'absent');
  await assert.rejects(() => stageSparkleFramework(missing, f.app, 'universal'));
  chmodSync(f.parent, 0o755); await assert.rejects(() => stageSparkleFramework(missing, f.app, 'arm64')); chmodSync(f.parent, 0o700);
  const alias = join(f.parent, 'alias'); symlinkSync(f.app, alias); await assert.rejects(() => stageSparkleFramework(missing, alias, 'arm64'));
  assert.throws(() => lstatSync(join(f.app, 'Contents/Frameworks')), { code: 'ENOENT' });
});
