import assert from 'node:assert/strict';
import { spawnSync } from 'node:child_process';
import { randomUUID } from 'node:crypto';
import { chmodSync, copyFileSync, readFileSync } from 'node:fs';
import { dirname, join, resolve } from 'node:path';
import { fileURLToPath } from 'node:url';
import { readReleaseInput } from '../files.mjs';
import { fixture } from './fixture.mjs';

// A disposable sealed app exercises the actual stopped SDK and isolated defaults.
// Failure retains private work; no running updater, live feed or install follows.
let completed = false;
const cleanup = [];
const call = (command, args, timeout = 30_000) => {
  const result = spawnSync(command, args, { encoding: 'utf8', timeout, maxBuffer: 16 * 1024 * 1024 });
  assert.equal(result.error, undefined);
  assert.equal(result.status, 0, result.stderr);
  return result.stdout;
};
try {
  assert.equal(process.platform, 'darwin');
  assert.equal(process.argv.length, 5);
  const [archive, cache, probe] = process.argv.slice(2).map(path => resolve(path));
  const root = resolve(dirname(fileURLToPath(import.meta.url)), '../..');
  const tool = join(root, 'release/macos/.build/release/frameshift-mac-release');
  const cpu = process.arch === 'arm64' ? 'arm64' : 'x86_64';
  const binary = await readReleaseInput(probe, { maximum: 128 * 1024 * 1024, protectedTrust: true });
  const original = call(tool, ['verify-sparkle-framework', archive, cache], 180_000);
  const { parent, root: app } = fixture({ after: action => cleanup.push(action) }, cpu);
  // The helper's temporary directory is physical and exclusive to this fixture.
  chmodSync(parent, 0o700);
  copyFileSync(probe, join(app, 'Contents/MacOS/Frameshift'));
  chmodSync(join(app, 'Contents/MacOS/Frameshift'), 0o755);
  const info = join(app, 'Contents/Info.plist');
  copyFileSync(join(root, 'apps/macos/App/Info.plist'), info);
  const identifier = `io.frameshift.fixture.updater.${randomUUID()}`;
  call('/usr/bin/plutil', ['-replace', 'CFBundleIdentifier', '-string', identifier, info]);
  call('/usr/bin/plutil', ['-insert', 'SUFeedURL', '-string', 'https://updates.example.invalid/appcast.xml', info]);
  call('/usr/bin/plutil', ['-insert', 'SUPublicEDKey', '-string', Buffer.alloc(32, 0x7a).toString('base64'), info]);
  call(tool, ['stage-sparkle-framework', archive, app, cpu], 180_000);
  assert.match(call(tool, ['prepare-swiftbuild-updater-bundle', app, cpu], 360_000), /^development bundle: (arm64|x86_64), minimum macOS \d+\.\d+\.\d+\n$/);
  const before = call(tool, ['verify-development-bundle', app, cpu], 180_000);
  assert.equal(call(join(app, 'Contents/MacOS/Frameshift'), ['--stopped-preferences']), 'stopped updater preserves stored choices\n');
  assert.equal(call(tool, ['verify-development-bundle', app, cpu], 180_000), before);
  assert.equal(call(tool, ['verify-sparkle-framework', archive, cache], 180_000), original);
  assert.deepEqual(await readReleaseInput(probe, { maximum: 128 * 1024 * 1024, protectedTrust: true }), binary);
  assert.equal(readFileSync(info).includes(Buffer.from(identifier)), true);
  completed = true;
  process.stdout.write('Native updater fixture passed: actual stopped controller preserves isolated stored choices; strict CPU/nested seals and original inputs remain unchanged\n');
} catch {
  process.stderr.write('Native updater fixture refused; private evidence retained\n');
  process.exitCode = 1;
} finally {
  if (completed) for (const action of cleanup) action();
}
