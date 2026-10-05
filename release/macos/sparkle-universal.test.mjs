import assert from 'node:assert/strict';
import { copyFileSync, existsSync, readFileSync, writeFileSync } from 'node:fs';
import { join } from 'node:path';
import test from 'node:test';
import { sparkleContainers, sparkleLinks, sparkleResourceSeals, sparkleRoot } from '../macos-framework.mjs';
import { auditMacBundle } from './closure.mjs';
import { fixture, run } from './fixture.mjs';
import { macImageTool, verifyDevelopmentSignatures } from './dmg.mjs';
import { prepareDevelopmentBundle } from './prepare.mjs';
import { stageSparkleFramework } from './sparkle-material.mjs';
import { universalDevelopmentBundle } from './universal.mjs';

const archive = process.env.FRAMESHIFT_SPARKLE_ARCHIVE;
const mac = { skip: !(process.platform === 'darwin' && archive) && 'Exact pinned FRAMESHIFT_SPARKLE_ARCHIVE on macOS required' };
async function inputs(t) {
  const values = [];
  for (const architecture of ['arm64', 'x86_64']) {
    const f = fixture(t, architecture);
    await stageSparkleFramework(archive, f.root, architecture);
    const source = join(f.parent, 'controller.m');
    writeFileSync(source, '#import <Foundation/Foundation.h>\n#import <Sparkle/Sparkle.h>\nint main(void) { @autoreleasepool { SPUStandardUpdaterController *c = [[SPUStandardUpdaterController alloc] initWithStartingUpdater:NO updaterDelegate:nil userDriverDelegate:nil]; return c.updater == nil; } }\n');
    run('/usr/bin/xcrun', ['clang', '-arch', architecture, '-mmacosx-version-min=14.0', '-F', join(f.root, 'Contents/Frameworks'),
      '-framework', 'Sparkle', '-framework', 'Foundation', '-Wl,-rpath,@loader_path/../Frameworks', source, '-o', join(f.root, 'Contents/MacOS/Frameshift')]);
    const observation = await prepareDevelopmentBundle(f.root, architecture);
    assert.ok(observation.natives.every(file => file.slices.length === 1 && file.slices[0].arch === architecture));
    verifyDevelopmentSignatures(f.root, observation);
    values.push({ ...f, observation });
  }
  return { arm: values[0], intel: values[1], output: join(values[0].parent, 'universal') };
}

test('actual thin SDK inputs merge all native roles, preserve aliases, verify every seal and retain no-effect replay', mac, async t => {
  const f = await inputs(t), before = [f.arm.observation, f.intel.observation];
  assert.ok(sparkleResourceSeals.some(path => before[0].files.find(file => file.path === path).sha256 !== before[1].files.find(file => file.path === path).sha256));
  const result = await universalDevelopmentBundle(f.arm.root, f.intel.root, f.output);
  assert.equal(result.nativeFiles, 12); assert.equal(result.publicationAuthority, 'none');
  const app = join(f.output, 'Frameshift.app'), admitted = await auditMacBundle(app, 'universal');
  assert.deepEqual(new Map(admitted.links.map(link => [link.path, link.target])), sparkleLinks);
  assert.ok(admitted.natives.every(file => file.slices.length === 2)); verifyDevelopmentSignatures(app, admitted);
  for (const path of sparkleContainers) run('/usr/bin/codesign', ['--verify', '--strict', join(app, path)]);
  if (process.arch === 'arm64') run('/usr/bin/arch', ['-arm64', join(app, 'Contents/MacOS/Frameshift')]);
  const record = readFileSync(join(f.output, 'universal.json')); let effects = 0;
  const readOnly = (command, args, timeout) => { if (command === '/usr/bin/lipo' || (command === '/usr/bin/codesign' && args.includes('--force'))) effects++; return macImageTool(command, args, timeout); };
  const replay = await universalDevelopmentBundle(f.arm.root, f.intel.root, f.output, { tool: readOnly });
  assert.equal(replay.recordSha256, result.recordSha256); assert.equal(effects, 0); assert.deepEqual(readFileSync(join(f.output, 'universal.json')), record);
  assert.deepEqual([await auditMacBundle(f.arm.root, 'arm64'), await auditMacBundle(f.intel.root, 'x86_64')], before);
});

test('SDK headers and unknown signature paths remain common-byte conflicts before output creation', mac, async t => {
  const f = await inputs(t), header = join(f.intel.root, sparkleRoot, 'Versions/B/Headers/SPUUpdater.h');
  writeFileSync(header, Buffer.concat([readFileSync(header), Buffer.from('\nfixture changed header\n')]));
  await prepareDevelopmentBundle(f.intel.root, 'x86_64');
  await assert.rejects(() => universalDevelopmentBundle(f.arm.root, f.intel.root, f.output), /common bytes/);
  assert.equal(existsSync(f.output), false);
  copyFileSync(join(f.arm.root, sparkleRoot, 'Versions/B/Headers/SPUUpdater.h'), header);
  writeFileSync(join(f.intel.root, sparkleRoot, 'Versions/B/Headers/CodeResources'), 'unknown signature bytes');
  await prepareDevelopmentBundle(f.intel.root, 'x86_64');
  await assert.rejects(() => universalDevelopmentBundle(f.arm.root, f.intel.root, f.output), /file sets/);
  assert.equal(existsSync(f.output), false);
});

test('an altered SDK resource with only the outer app resealed fails nested admission', mac, async t => {
  const f = await inputs(t), header = join(f.intel.root, sparkleRoot, 'Versions/B/Headers/SPUUpdater.h');
  writeFileSync(header, Buffer.concat([readFileSync(header), Buffer.from('\nretained corrupt nested bytes\n')]));
  run('/usr/bin/codesign', ['--force', '--sign', '-', '--timestamp=none', f.intel.root]);
  await assert.rejects(() => universalDevelopmentBundle(f.arm.root, f.intel.root, f.output));
  assert.equal(existsSync(f.output), false); assert.match(readFileSync(header, 'utf8'), /retained corrupt nested bytes/);
});
