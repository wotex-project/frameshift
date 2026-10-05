import assert from 'node:assert/strict';
import { spawnSync } from 'node:child_process';
import { chmodSync, copyFileSync, linkSync, mkdirSync, readFileSync, renameSync, rmSync, symlinkSync, truncateSync, writeFileSync } from 'node:fs';
import { dirname, join } from 'node:path';
import test from 'node:test';
import { auditMacBundle, inspectMachO, versionNumber } from './closure.mjs';
import { prepareDevelopmentBundle } from './prepare.mjs';
import { fixture, roles, run, temporary } from './fixture.mjs';

function thin({ type = 0x0100000c, subtype = 0, platform = 1, minimum = 0x000e0000, filetype = 2 } = {}) {
  const bytes = Buffer.alloc(56);
  bytes.writeUInt32LE(0xfeedfacf, 0); bytes.writeUInt32LE(type, 4); bytes.writeUInt32LE(subtype, 8);
  bytes.writeUInt32LE(filetype, 12); bytes.writeUInt32LE(1, 16); bytes.writeUInt32LE(24, 20);
  bytes.writeUInt32LE(0x32, 32); bytes.writeUInt32LE(24, 36); bytes.writeUInt32LE(platform, 40); bytes.writeUInt32LE(minimum, 44);
  return bytes;
}

test('native metadata bounds refuse malformed command regions, platforms and CPU subtypes', async t => {
  const path = join(temporary(t), 'native');
  writeFileSync(path, thin());
  assert.equal((await inspectMachO(path))[0].minimum, '14.0.0');
  const malformed = [
    thin({ platform: 2 }), thin({ subtype: 2 }), thin({ type: 12 }), thin({ filetype: 1 }), thin({ minimum: 0 }),
    ...[[16, 4097], [20, 1024 * 1024 + 8], [20, 64], [36, 7], [36, 16], [52, 33], [32, 0x27]].map(([offset, value]) => { const bytes = thin(); bytes.writeUInt32LE(value, offset); return bytes; }),
    thin().subarray(0, 48), Buffer.from([0xcf, 0xfa]),
  ];
  for (const bytes of malformed) { writeFileSync(path, bytes); await assert.rejects(inspectMachO(path)); }
  truncateSync(path, 128 * 1024 * 1024 + 1);
  await assert.rejects(inspectMachO(path), /size/);
  rmSync(path); symlinkSync('missing', path);
  await assert.rejects(inspectMachO(path), /regular/);
});

test('fat metadata requires distinct aligned contained matching slices before allocation', async t => {
  const path = join(temporary(t), 'fat'), bytes = Buffer.alloc(184);
  bytes.writeUInt32BE(0xcafebabe, 0); bytes.writeUInt32BE(2, 4);
  for (const [start, type, subtype, offset] of [[8, 0x0100000c, 0, 64], [28, 0x01000007, 3, 128]]) {
    bytes.writeUInt32BE(type, start); bytes.writeUInt32BE(subtype, start + 4); bytes.writeUInt32BE(offset, start + 8);
    bytes.writeUInt32BE(56, start + 12); bytes.writeUInt32BE(3, start + 16);
    thin({ type, subtype }).copy(bytes, offset);
  }
  writeFileSync(path, bytes);
  assert.deepEqual((await inspectMachO(path)).map(slice => slice.arch), ['arm64', 'x86_64']);
  for (const [offset, value] of [[4, 3], [16, 32], [36, 64], [40, 4096], [44, 31], [32, 0], [136, 8]]) {
    const bad = Buffer.from(bytes); bad.writeUInt32BE(value, offset); writeFileSync(path, bad); await assert.rejects(inspectMachO(path));
  }
  const wide = Buffer.alloc(40); wide.writeUInt32BE(0xcafebabf); wide.writeUInt32BE(1, 4); wide.writeUInt32BE(0x0100000c, 8);
  wide.writeBigUInt64BE(2n ** 63n, 16); wide.writeBigUInt64BE(56n, 24); writeFileSync(path, wide);
  await assert.rejects(inspectMachO(path), /fat region/);
});

test('minimum OS parsing preserves numeric order and refuses ambiguous or overflowing versions', () => {
  assert.ok(versionNumber('15.0') > versionNumber('14.10.255'));
  for (const value of ['14', '014.0', '14.00', '14.256', '65536.0', '9.0', '14.0\n', null]) assert.throws(() => versionNumber(value));
});

test('native reader refuses actual inode replacement and permission mutation during descriptor inspection', async t => {
  const parent = temporary(t), path = join(parent, 'native');
  for (const change of [() => { renameSync(path, join(parent, 'retained')); writeFileSync(path, thin()); }, () => chmodSync(path, 0o600)]) {
    writeFileSync(path, thin()); chmodSync(path, 0o644);
    let changed = false;
    await assert.rejects(inspectMachO(path, () => { if (!changed) { changed = true; change(); } }), /changed while reading/);
  }
});

const mac = { skip: process.platform !== 'darwin' };

test('actual arm64, Intel and universal binaries satisfy only their static CPU and OS profile', mac, async t => {
  for (const architecture of ['arm64', 'x86_64', 'universal']) {
    const { root } = fixture(t, architecture), report = await auditMacBundle(root, architecture);
    assert.equal(report.natives.length, 7); assert.equal(report.nativeMinimum, '14.0.0'); assert.equal(report.publicationAuthority, 'none');
    assert.ok(report.files.every(file => /^[0-9a-f]{64}$/.test(file.sha256)));
    if (architecture !== 'universal') {
      await assert.rejects(auditMacBundle(root, 'universal'), /CPU/);
      await assert.rejects(auditMacBundle(root, architecture === 'arm64' ? 'x86_64' : 'arm64'), /CPU/);
    }
  }
});

test('actual bundle refuses false declarations, missing roles, aliases, unsafe modes and sparse sizes', mac, async t => {
  const { root } = fixture(t), plist = join(root, 'Contents/Info.plist'), original = readFileSync(plist);
  writeFileSync(plist, original.toString().replace('14.0', '13.0'));
  await assert.rejects(auditMacBundle(root, 'arm64'), /understates/);
  writeFileSync(plist, '<plist><dict>broken'); await assert.rejects(auditMacBundle(root, 'arm64'), /plist/); writeFileSync(plist, original);
  const source = join(root, roles[0][0]), bytes = readFileSync(source);
  chmodSync(source, 0o664); await assert.rejects(auditMacBundle(root, 'arm64'), /mode/); chmodSync(source, 0o644);
  await assert.rejects(auditMacBundle(root, 'arm64'), /executable mode/); chmodSync(source, 0o755);
  rmSync(source); await assert.rejects(auditMacBundle(root, 'arm64'), /required native/);
  symlinkSync(join(root, roles[1][0]), source); await assert.rejects(auditMacBundle(root, 'arm64'), /links/); rmSync(source); writeFileSync(source, bytes, { mode: 0o755 });
  const extra = join(root, 'extra'); writeFileSync(extra, ''); truncateSync(extra, 128 * 1024 * 1024 + 1);
  await assert.rejects(auditMacBundle(root, 'arm64'), /byte limit/); rmSync(extra);
  let deep = root; for (let index = 0; index < 33; index++) { deep = join(deep, 'd'); mkdirSync(deep); }
  await assert.rejects(auditMacBundle(root, 'arm64'), /inventory limit/);
});

test('actual loader references refuse external search paths, missing local libraries and inherited run-path context', mac, async t => {
  const { root } = fixture(t), executable = join(root, roles[0][0]);
  run('/usr/bin/install_name_tool', ['-add_rpath', '/opt/homebrew/lib', executable]);
  await assert.rejects(auditMacBundle(root, 'arm64'), /outside loader/);
  run('/usr/bin/install_name_tool', ['-delete_rpath', '/opt/homebrew/lib', executable]);
  run('/usr/bin/install_name_tool', ['-change', '/usr/lib/libSystem.B.dylib', '@loader_path/missing.dylib', executable]);
  await assert.rejects(auditMacBundle(root, 'arm64'), /missing bundled/);
  const library = join(root, 'Contents/MacOS/missing.dylib'); copyFileSync(join(root, roles[4][0]), library);
  assert.equal((await auditMacBundle(root, 'arm64')).natives.length, 8);
  run('/usr/bin/install_name_tool', ['-change', '@loader_path/missing.dylib', '@rpath/missing.dylib', executable]);
  await assert.rejects(auditMacBundle(root, 'arm64'), /unsupported or outside/);
});

test('bundle member and native limits refuse real inventories and hard links', mac, async t => {
  const { root } = fixture(t), source = join(root, roles[0][0]), extra = join(root, 'extra');
  linkSync(source, extra); await assert.rejects(auditMacBundle(root, 'arm64'), /hard links/); rmSync(extra);
  const natives = join(root, 'natives'); mkdirSync(natives);
  for (let index = 0; index < 129; index++) copyFileSync(source, join(natives, `${index}`));
  await assert.rejects(auditMacBundle(root, 'arm64'), /native inventory/); rmSync(natives, { recursive: true });
  const entries = join(root, 'entries'); mkdirSync(entries);
  for (let index = 0; index < 8192; index++) writeFileSync(join(entries, `${index}`), '');
  await assert.rejects(auditMacBundle(root, 'arm64'), /inventory limit/);
});

test('private development preparation removes only an unused selected-toolchain path and signs inside out', mac, async t => {
  const swift = run('/usr/bin/xcrun', ['--find', 'swift']), path = join(dirname(dirname(swift)), 'lib/swift-fixture/macosx');
  const { root } = fixture(t, 'arm64', path);
  await assert.rejects(auditMacBundle(root, 'arm64'), /outside loader/);
  const report = await prepareDevelopmentBundle(root, 'arm64');
  assert.equal(report.declaredMinimum, '14.0.0');
  assert.ok(report.natives.every(file => file.slices.every(slice => !slice.rpaths.includes(path))));
  run('/usr/bin/codesign', ['--verify', '--deep', '--strict', root]);
  run('/usr/bin/codesign', ['--verify', '--strict', join(root, roles[4][0])]);
  const { root: refused } = fixture(t, 'arm64', path), executable = join(refused, roles[0][0]);
  run('/usr/bin/install_name_tool', ['-change', '/usr/lib/libSystem.B.dylib', '@rpath/native.dylib', executable]);
  await assert.rejects(prepareDevelopmentBundle(refused, 'arm64'), /run-path dependency/);
  await assert.rejects(prepareDevelopmentBundle(join(dirname(refused), 'existing.app'), 'arm64'), /private development/);
});

test('closure CLI uses fixed usage and failure output without disclosing input paths', t => {
  const cli = new URL('./closure-cli.mjs', import.meta.url).pathname;
  const usage = spawnSync(process.execPath, [cli], { encoding: 'utf8', timeout: 2000 });
  assert.equal(usage.status, 64);
  const bad = spawnSync(process.execPath, [cli, join(temporary(t), 'private-missing-path'), 'arm64'], { encoding: 'utf8', timeout: 2000 });
  assert.equal(bad.status, 1); assert.equal(bad.stderr, 'Mac bundle closure refused\n'); assert.equal(bad.stdout, '');
});
