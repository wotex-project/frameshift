import assert from 'node:assert/strict';
import { spawnSync } from 'node:child_process';
import { appendFileSync, chmodSync, existsSync, lstatSync, readFileSync, readdirSync, rmSync, symlinkSync, writeFileSync } from 'node:fs';
import { join } from 'node:path';
import test from 'node:test';
import { developmentDiskImage, macImageTool } from './dmg.mjs';
import { prepareDevelopmentBundle } from './prepare.mjs';
import { fixture, temporary } from './fixture.mjs';

const mac = { skip: process.platform !== 'darwin' };
async function source(t, architecture = 'arm64') {
  const files = fixture(t, architecture);
  await prepareDevelopmentBundle(files.root, architecture);
  return files;
}
const bytes = output => readdirSync(output).sort().map(name => [name, readFileSync(join(output, name))]);

test('actual universal development image mounts exact app bytes and replay preserves the retained archive', mac, async t => {
  const { root, parent } = await source(t, 'universal'), output = join(parent, 'candidate');
  const first = await developmentDiskImage(root, 'universal', output);
  assert.equal(first.publicationAuthority, 'none'); assert.equal(first.minimumOS, '14.0.0'); assert.equal(first.disposition, 'development-candidate');
  assert.ok(first.bytes > 0); assert.match(first.sha256, /^[0-9a-f]{64}$/);
  const retained = bytes(output), stat = lstatSync(join(output, first.archive));
  const replay = await developmentDiskImage(root, 'universal', output);
  assert.equal(replay.disposition, 'retained-bytes-verified'); assert.equal(replay.sha256, first.sha256); assert.deepEqual(bytes(output), retained);
  assert.equal(lstatSync(join(output, first.archive)).mtimeMs, stat.mtimeMs);
  assert.equal(lstatSync(output).mode & 0o7777, 0o700);
  for (const name of readdirSync(output)) assert.equal(lstatSync(join(output, name)).mode & 0o7777, 0o600);
});

test('archive, metadata alias, permission and re-signed source changes refuse without replacing retained bytes', mac, async t => {
  const { root, parent } = await source(t), output = join(parent, 'candidate');
  const first = await developmentDiskImage(root, 'arm64', output), image = join(output, first.archive), bundle = join(output, 'bundle.json');
  const originalImage = readFileSync(image), originalBundle = readFileSync(bundle), record = readFileSync(join(output, 'dmg.json'));
  let mounts = 0;
  const tool = (command, args, timeout) => { if (args[0] === 'attach') mounts++; return macImageTool(command, args, timeout); };
  appendFileSync(image, 'tamper');
  await assert.rejects(developmentDiskImage(root, 'arm64', output, { tool }), /record or bytes/); assert.equal(mounts, 0);
  assert.ok(readFileSync(image).equals(Buffer.concat([originalImage, Buffer.from('tamper')])));
  writeFileSync(image, originalImage);
  rmSync(bundle); symlinkSync(join(output, 'dmg.json'), bundle);
  await assert.rejects(developmentDiskImage(root, 'arm64', output), /regular/); assert.ok(lstatSync(bundle).isSymbolicLink());
  rmSync(bundle); writeFileSync(bundle, originalBundle, { mode: 0o600 }); chmodSync(bundle, 0o644);
  await assert.rejects(developmentDiskImage(root, 'arm64', output), /unsafe release private/); chmodSync(bundle, 0o600);
  writeFileSync(join(root, 'Contents/Resources/source-changed.txt'), 'changed source');
  await prepareDevelopmentBundle(root, 'arm64');
  await assert.rejects(developmentDiskImage(root, 'arm64', output), /source bundle changed/);
  assert.ok(readFileSync(image).equals(originalImage)); assert.ok(readFileSync(join(output, 'dmg.json')).equals(record));
});

test('failed creation and incomplete rerun retain private output without another build', mac, async t => {
  const { root, parent } = await source(t), output = join(parent, 'candidate'); let creates = 0;
  const tool = (command, args, timeout) => {
    if (args[0] === 'create') { creates++; throw new Error('fixture creator refused'); }
    return macImageTool(command, args, timeout);
  };
  await assert.rejects(developmentDiskImage(root, 'arm64', output, { tool }), /creator refused/);
  assert.ok(existsSync(join(output, 'build.pending'))); assert.ok(existsSync(join(output, '.work/payload/Frameshift.app')));
  assert.equal(existsSync(join(output, 'dmg.json')), false);
  await assert.rejects(developmentDiskImage(root, 'arm64', output, { tool }), /incomplete/); assert.equal(creates, 1);
  await assert.rejects(developmentDiskImage(root, 'arm64', join(root, 'inside')), /overlapping/); assert.equal(existsSync(join(root, 'inside')), false);
});

test('lost attach response detaches its actual private mount and refuses completion', mac, async t => {
  const { root, parent } = await source(t), output = join(parent, 'candidate'); let detaches = 0;
  const tool = (command, args, timeout) => {
    const result = macImageTool(command, args, timeout);
    if (args[0] === 'detach') detaches++;
    if (args[0] === 'attach') throw new Error('fixture attach response lost');
    return result;
  };
  await assert.rejects(developmentDiskImage(root, 'arm64', output, { tool }), /attach response lost/);
  assert.equal(detaches, 1); assert.equal(existsSync(join(output, '.work/mount')), false);
  assert.ok(existsSync(join(output, 'build.pending'))); assert.equal(existsSync(join(output, 'dmg.json')), false);
});

test('refused detach preserves the actual read-only mount instead of recursively deleting it', mac, async t => {
  const { root, parent } = await source(t), output = join(parent, 'candidate'), mount = join(output, '.work/mount'); let detaches = 0;
  const tool = (command, args, timeout) => {
    if (args[0] === 'detach') { detaches++; throw new Error('fixture detach refused'); }
    return macImageTool(command, args, timeout);
  };
  try {
    await assert.rejects(developmentDiskImage(root, 'arm64', output, { tool }), /mount retained/);
    assert.equal(detaches, 2); assert.ok(existsSync(join(mount, 'Frameshift.app/Contents/Info.plist')));
    assert.throws(() => writeFileSync(join(mount, 'should-refuse.txt'), 'read-only'), /read-only|EROFS/);
    assert.ok(existsSync(join(output, 'build.pending'))); assert.equal(existsSync(join(output, 'dmg.json')), false);
  } finally {
    // This fixture owns the mount and explicitly detaches it before its outer
    // temporary-directory cleanup. Product refusal deliberately retains it.
    macImageTool('/usr/bin/hdiutil', ['detach', mount]);
  }
});

test('image tool bounds actual child output and lifetime', () => {
  const start = performance.now();
  assert.throws(() => macImageTool(process.execPath, ['-e', 'setTimeout(()=>{},10000)'], 50), /tool refused/);
  assert.ok(performance.now() - start < 2000);
  assert.throws(() => macImageTool(process.execPath, ['-e', 'process.stdout.write("x".repeat(300000))']), /tool refused/);
});

test('completed replay detects a namespace change during mounted readback and preserves the added file', mac, async t => {
  const { root, parent } = await source(t), output = join(parent, 'candidate');
  const first = await developmentDiskImage(root, 'arm64', output), retained = readFileSync(join(output, first.archive));
  const tool = (command, args, timeout) => {
    const result = macImageTool(command, args, timeout);
    if (args[0] === 'detach') writeFileSync(join(output, 'unknown'), 'retain this');
    return result;
  };
  await assert.rejects(developmentDiskImage(root, 'arm64', output, { tool }), /replay custody/);
  assert.equal(readFileSync(join(output, 'unknown'), 'utf8'), 'retain this');
  assert.ok(readFileSync(join(output, first.archive)).equals(retained));
});

test('disk-image CLI has fixed usage and refusal without exposing supplied private paths', t => {
  const cli = new URL('./dmg-cli.mjs', import.meta.url).pathname;
  const usage = spawnSync(process.execPath, [cli], { encoding: 'utf8', timeout: 2000 }); assert.equal(usage.status, 64);
  const bad = spawnSync(process.execPath, [cli, join(temporary(t), 'secret-path'), 'arm64', 'unknown-output'], { encoding: 'utf8', timeout: 2000 });
  assert.equal(bad.status, 1); assert.equal(bad.stdout, ''); assert.equal(bad.stderr, 'development disk-image candidate refused; existing output retained\n');
});
