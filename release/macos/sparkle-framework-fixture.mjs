import assert from 'node:assert/strict';
import { createHash } from 'node:crypto';
import { execFileSync } from 'node:child_process';
import { chmodSync, closeSync, mkdirSync, mkdtempSync, readFileSync, rmSync, writeFileSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { readReleaseInput } from '../files.mjs';
import { extractArchive, openArchive, verifyExtractedArchive } from '../ustar.mjs';
import { auditMacBundle } from './closure.mjs';
import { fixture, run } from './fixture.mjs';
import { prepareDevelopmentBundle } from './prepare.mjs';
import { sparkleContainers, sparkleRoot } from '../macos-framework.mjs';

// Explicit local qualification, using independently pinned upstream bytes.
// The controller never starts, performs no check, and uses no signing keys.
const expected = '17e28312b8e18ab7cdbbe09a6fb28cc55a5479ec6c371dbc07cdecd2a14fd959';
const roots = [];
try {
  if (process.platform !== 'darwin' || process.arch !== 'arm64' || process.argv.length !== 3) throw new Error('fixture profile');
  const archive = await readReleaseInput(process.argv[2], { maximum: 16 * 1024 * 1024, protectedTrust: true });
  assert.equal(createHash('sha256').update(archive).digest('hex'), expected);
  const work = mkdtempSync(join(tmpdir(), 'frameshift-sparkle-sdk-fixture.')); roots.push(work);
  const retained = join(work, 'sdk.zip'); writeFileSync(retained, archive, { mode: 0o600 });
  run('/usr/bin/unzip', ['-q', retained, 'Sparkle.xcframework/macos-arm64_x86_64/Sparkle.framework/*', '-d', work]);
  assert.deepEqual(readFileSync(retained), archive);
  const f = fixture({ after: callback => roots.push(callback) });
  mkdirSync(join(f.root, 'Contents/Frameworks'));
  run('/usr/bin/ditto', [join(work, 'Sparkle.xcframework/macos-arm64_x86_64/Sparkle.framework'), join(f.root, sparkleRoot)]);
  const source = join(f.parent, 'sparkle-controller.m');
  writeFileSync(source, '#import <Foundation/Foundation.h>\n#import <Sparkle/Sparkle.h>\nint main(void) { @autoreleasepool { SPUStandardUpdaterController *controller = [[SPUStandardUpdaterController alloc] initWithStartingUpdater:NO updaterDelegate:nil userDriverDelegate:nil]; return controller.updater == nil; } }\n');
  run('/usr/bin/xcrun', ['clang', '-arch', 'arm64', '-mmacosx-version-min=14.0', '-F', join(f.root, 'Contents/Frameworks'),
    '-framework', 'Sparkle', '-framework', 'Foundation', '-Wl,-rpath,@loader_path/../Frameworks', source, '-o', join(f.root, 'Contents/MacOS/Frameshift')]);
  const before = await auditMacBundle(f.root, 'arm64');
  assert.equal(before.links.length, 9); assert.equal(before.natives.length, 12);
  for (const file of before.natives.filter(file => file.path.startsWith(sparkleRoot + '/'))) {
    assert.deepEqual(file.slices.map(slice => slice.arch), ['arm64', 'x86_64']);
    assert.ok(file.slices.every(slice => slice.minimum === '12.0.0'));
  }
  const after = await prepareDevelopmentBundle(f.root, 'arm64'); assert.deepEqual(after.links, before.links);
  for (const path of sparkleContainers) run('/usr/bin/codesign', ['--verify', '--strict', join(f.root, path)]);
  run('/usr/bin/codesign', ['--verify', '--deep', '--strict', f.root]);
  run(join(f.root, 'Contents/MacOS/Frameshift'), []);
  const transport = join(work, 'transport'), candidate = join(transport, 'macos-candidate');
  mkdirSync(candidate, { recursive: true, mode: 0o700 });
  run('/usr/bin/ditto', [f.root, join(candidate, 'Frameshift.app')]);
  const tar = join(work, 'candidate.tar');
  execFileSync('/usr/bin/tar', ['--format=ustar', '-cf', tar, '-C', transport, 'macos-candidate'],
    { env: { ...process.env, COPYFILE_DISABLE: '1' }, timeout: 30_000, maxBuffer: 64 * 1024, stdio: ['ignore', 'pipe', 'pipe'] });
  chmodSync(tar, 0o600);
  const admitted = openArchive(tar, createHash('sha256').update(readFileSync(tar)).digest('hex'), 'macos-candidate');
  try {
    const received = join(work, 'received'); mkdirSync(received, { mode: 0o700 });
    extractArchive(admitted, received); verifyExtractedArchive(admitted, received);
    const app = join(received, 'macos-candidate/Frameshift.app');
    assert.deepEqual(await auditMacBundle(app, 'arm64'), after);
    for (const path of sparkleContainers) run('/usr/bin/codesign', ['--verify', '--strict', join(app, path)]);
    run('/usr/bin/codesign', ['--verify', '--deep', '--strict', app]);
    verifyExtractedArchive(admitted, received);
  } finally { closeSync(admitted.fd); }
  assert.deepEqual(await readReleaseInput(process.argv[2], { maximum: 16 * 1024 * 1024, protectedTrust: true }), archive);
  process.stdout.write('Pinned Sparkle framework fixture passed: exact aliases and native slices, nested ad-hoc seals, arm64 loader/controller initialization and USTAR link/seal readback; updater not started\n');
} catch {
  process.stderr.write('Pinned Sparkle framework fixture refused\n'); process.exitCode = 1;
} finally {
  for (const root of roots.reverse()) { if (typeof root === 'function') root(); else rmSync(root, { recursive: true, force: true }); }
}
