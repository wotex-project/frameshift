import assert from 'node:assert/strict';
import { spawnSync } from 'node:child_process';
import { copyFileSync, existsSync, mkdirSync, readFileSync, readdirSync, rmSync, symlinkSync, writeFileSync } from 'node:fs';
import { join } from 'node:path';
import test from 'node:test';
import { universalDevelopmentBundle } from './universal.mjs';
import { prepareDevelopmentBundle } from './prepare.mjs';
import { developmentDiskImage, macImageTool } from './dmg.mjs';
import { fixture, roles, run, temporary } from './fixture.mjs';

const mac = { skip: process.platform !== 'darwin' };
async function sources(t) {
  const arm = fixture(t, 'arm64'), intel = fixture(t, 'x86_64');
  for (const [value, architecture] of [[arm, 'arm64'], [intel, 'x86_64']]) {
    writeFileSync(join(value.root, 'Contents/Resources/common.fixture'), 'same common bytes');
    await prepareDevelopmentBundle(value.root, architecture);
  }
  return { arm, intel, output: join(arm.parent, 'candidate') };
}

test('separate native bundles join every executable and dylib, retain replay bytes and feed mounted DMG readback', mac, async t => {
  const { arm, intel, output } = await sources(t);
  const first = await universalDevelopmentBundle(arm.root, intel.root, output);
  assert.equal(first.publicationAuthority, 'none'); assert.equal(first.architecture, 'universal'); assert.equal(first.nativeFiles, 7);
  const app = join(output, 'Frameshift.app'), record = readFileSync(join(output, 'universal.json'));
  const extra = join(app, 'Contents/Resources/extra-empty-directory'); mkdirSync(extra);
  await assert.rejects(universalDevelopmentBundle(arm.root, intel.root, output), /retained bytes changed/); rmSync(extra, { recursive: true });
  for (const [relative] of roles) assert.deepEqual(run('/usr/bin/lipo', ['-archs', join(app, relative)]).split(' ').sort(), ['arm64', 'x86_64']);
  if (process.arch === 'arm64') run('/usr/bin/arch', ['-arm64', join(app, roles[0][0])]);
  const replay = await universalDevelopmentBundle(arm.root, intel.root, output);
  assert.equal(replay.disposition, 'retained-bytes-verified'); assert.equal(replay.recordSha256, first.recordSha256);
  assert.ok(readFileSync(join(output, 'universal.json')).equals(record));
  const image = await developmentDiskImage(app, 'universal', join(arm.parent, 'image'));
  assert.equal(image.publicationAuthority, 'none'); assert.equal(image.disposition, 'development-candidate');
});

test('common bytes, semantic plist identities, CPU and file sets refuse before output creation', mac, async t => {
  const { arm, intel, output } = await sources(t), common = join(intel.root, 'Contents/Resources/common.fixture');
  const empty = join(intel.root, 'Contents/Resources/extra-empty-directory'); mkdirSync(empty);
  await assert.rejects(universalDevelopmentBundle(arm.root, intel.root, output), /directories differ/); assert.equal(existsSync(output), false); rmSync(empty, { recursive: true });
  writeFileSync(common, 'different common bytes'); await prepareDevelopmentBundle(intel.root, 'x86_64');
  await assert.rejects(universalDevelopmentBundle(arm.root, intel.root, output), /common bytes/); assert.equal(existsSync(output), false);
  writeFileSync(common, 'same common bytes');
  const plist = join(intel.root, 'Contents/Info.plist'), original = readFileSync(plist);
  writeFileSync(plist, original.toString().replace('io.frameshift.closure-fixture', 'io.frameshift.other-fixture'));
  await prepareDevelopmentBundle(intel.root, 'x86_64');
  await assert.rejects(universalDevelopmentBundle(arm.root, intel.root, output), /plists differ/); assert.equal(existsSync(output), false);
  writeFileSync(plist, original); writeFileSync(join(intel.root, 'Contents/Resources/unknown'), 'different set');
  await prepareDevelopmentBundle(intel.root, 'x86_64');
  await assert.rejects(universalDevelopmentBundle(arm.root, intel.root, output), /file sets/); assert.equal(existsSync(output), false);
  const fat = fixture(t, 'universal'); await prepareDevelopmentBundle(fat.root, 'universal');
  await assert.rejects(universalDevelopmentBundle(fat.root, fat.root, output), /exact single CPU/);
  await assert.rejects(universalDevelopmentBundle(intel.root, arm.root, output), /CPU/);
});

test('same path with a differing optional native type refuses without selecting one input', mac, async t => {
  const { arm, intel, output } = await sources(t);
  copyFileSync(join(arm.root, roles[0][0]), join(arm.root, 'Contents/Resources/extra-native'));
  copyFileSync(join(intel.root, roles[4][0]), join(intel.root, 'Contents/Resources/extra-native'));
  await prepareDevelopmentBundle(arm.root, 'arm64'); await prepareDevelopmentBundle(intel.root, 'x86_64');
  await assert.rejects(universalDevelopmentBundle(arm.root, intel.root, output), /native types/); assert.equal(existsSync(output), false);
});

test('merge failure and changed input retain incomplete stages and refuse a rerun', mac, async t => {
  const { arm, intel, output } = await sources(t); let merges = 0;
  const failed = (command, args, timeout) => {
    if (command === '/usr/bin/lipo') { merges++; throw new Error('fixture merge refused'); }
    return macImageTool(command, args, timeout);
  };
  await assert.rejects(universalDevelopmentBundle(arm.root, intel.root, output, { tool: failed }), /merge refused/);
  assert.ok(existsSync(join(output, 'build.pending'))); assert.equal(existsSync(join(output, 'universal.json')), false);
  assert.ok(readdirSync(output).some(name => name.startsWith('.package.')));
  await assert.rejects(universalDevelopmentBundle(arm.root, intel.root, output, { tool: failed }), /incomplete/); assert.equal(merges, 1);
  const changedOutput = join(arm.parent, 'changed-input'); let changed = false;
  const changedSource = (command, args, timeout) => {
    const result = macImageTool(command, args, timeout);
    if (command === '/usr/bin/lipo' && !changed) { changed = true; writeFileSync(join(intel.root, 'Contents/Resources/changed-during-merge'), 'retain changed input'); }
    return result;
  };
  await assert.rejects(universalDevelopmentBundle(arm.root, intel.root, changedOutput, { tool: changedSource }), /source changed during merge/);
  assert.ok(existsSync(join(changedOutput, 'build.pending'))); assert.equal(existsSync(join(changedOutput, 'universal.json')), false);
});

test('retained record aliases, changed outputs and namespace mutation refuse without a merge or replacement', mac, async t => {
  const { arm, intel, output } = await sources(t);
  await universalDevelopmentBundle(arm.root, intel.root, output);
  const record = join(output, 'universal.json'), original = readFileSync(record), app = join(output, 'Frameshift.app');
  rmSync(record); symlinkSync(join(app, 'Contents/Info.plist'), record);
  await assert.rejects(universalDevelopmentBundle(arm.root, intel.root, output), /regular/); assert.ok(existsSync(record));
  rmSync(record); writeFileSync(record, original, { mode: 0o600 });
  let merges = 0;
  const tool = (command, args, timeout) => {
    if (command === '/usr/bin/lipo') merges++;
    const result = macImageTool(command, args, timeout);
    if (command === '/usr/bin/codesign' && args.includes('--deep') && args.at(-1) === app) writeFileSync(join(output, 'unknown'), 'preserve unknown');
    return result;
  };
  await assert.rejects(universalDevelopmentBundle(arm.root, intel.root, output, { tool }), /output custody/); assert.equal(merges, 0);
  assert.equal(readFileSync(join(output, 'unknown'), 'utf8'), 'preserve unknown'); assert.ok(readFileSync(record).equals(original));
  rmSync(join(output, 'unknown'));
  const changedDuringReadback = (command, args, timeout) => {
    const result = macImageTool(command, args, timeout);
    if (command === '/usr/bin/codesign' && args.includes('--deep') && args.at(-1) === app) writeFileSync(join(app, 'Contents/Resources/changed-output'), 'changed output');
    return result;
  };
  await assert.rejects(universalDevelopmentBundle(arm.root, intel.root, output, { tool: changedDuringReadback }), /replay custody/);
  await assert.rejects(universalDevelopmentBundle(arm.root, intel.root, output)); assert.ok(existsSync(join(app, 'Contents/Resources/changed-output')));
});

test('universal CLI has fixed usage and refusal without exposing private source paths', t => {
  const cli = new URL('./universal-cli.mjs', import.meta.url).pathname;
  assert.equal(spawnSync(process.execPath, [cli], { encoding: 'utf8', timeout: 2000 }).status, 64);
  const bad = spawnSync(process.execPath, [cli, join(temporary(t), 'secret-source'), 'missing-intel', 'unused-output'], { encoding: 'utf8', timeout: 2000 });
  assert.equal(bad.status, 1); assert.equal(bad.stdout, ''); assert.equal(bad.stderr, 'universal development bundle refused; existing output retained\n');
});
