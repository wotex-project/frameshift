import assert from 'node:assert/strict';
import { spawn, spawnSync } from 'node:child_process';
import { randomBytes } from 'node:crypto';
import { chmod, lstat, mkdir, mkdtemp, open, rm, writeFile } from 'node:fs/promises';
import { join, resolve } from 'node:path';
import { readReleaseInput } from '../files.mjs';
import { auditMacBundle } from './closure.mjs';
import { verifyDevelopmentSignatures } from './dmg.mjs';
import { prepareDevelopmentBundle } from './prepare.mjs';

// Exercise the production coordinator in an owned AppKit diagnostic clone.
// No UI input, installed updater, Keychain identity or release authority follows.
let work, child, log;
const run = (command, args) => {
  const result = spawnSync(command, args, { timeout: 30_000, maxBuffer: 64 * 1024, stdio: ['ignore', 'pipe', 'pipe'] });
  if (result.error || result.status !== 0) throw new Error('quit fixture tool refused');
};
try {
  if (process.platform !== 'darwin' || !['arm64', 'x64'].includes(process.arch) || process.argv.length !== 4) throw new Error('fixture profile');
  const [source, probe] = process.argv.slice(2).map(path => resolve(path));
  const architecture = process.arch === 'x64' ? 'x86_64' : 'arm64';
  const before = await auditMacBundle(source, architecture);
  await verifyDevelopmentSignatures(source, before);
  const probeBytes = await readReleaseInput(probe, { maximum: 128 * 1024 * 1024, protectedTrust: true });
  work = await mkdtemp('/tmp/frameshift-quit.'); await chmod(work, 0o700);
  const stage = join(work, '.package.quit'); await mkdir(stage, { mode: 0o700 });
  const app = join(stage, 'Frameshift.app'); run('/usr/bin/ditto', [source, app]);
  const executable = join(app, 'Contents/MacOS/Frameshift');
  await writeFile(executable, probeBytes, { mode: 0o755 }); await chmod(executable, 0o755);
  run('/usr/bin/plutil', ['-replace', 'CFBundleIdentifier', '-string', 'io.frameshift.quit-probe', join(app, 'Contents/Info.plist')]);
  const admitted = await prepareDevelopmentBundle(app, architecture);
  await verifyDevelopmentSignatures(app, admitted);
  const data = join(work, 'data'); await mkdir(data, { mode: 0o700 });
  const result = join(work, 'result'); log = await open(join(work, 'probe.log'), 'wx', 0o600);
  child = spawn(executable, ['--owned-quit-probe', result], {
    stdio: ['ignore', log.fd, log.fd],
    env: { ...process.env, FRAMESHIFT_DATA_DIR: data, FRAMESHIFT_SOCKET_PATH: join(data, 'core.sock'),
      FRAMESHIFT_IPC_TOKEN: randomBytes(32).toString('hex'), ERL_FLAGS: '+S 4:4 +SDcpu 2 +SDio 2',
      ERL_CRASH_DUMP: join(work, 'crash.dump'), ERL_CRASH_DUMP_SECONDS: '0' },
  });
  const completion = new Promise((resolve, reject) => {
    child.once('error', reject);
    child.once('exit', (code, signal) => { if (code === 0 && signal === null) resolve(); else reject(new Error('quit probe exit')); });
  });
  let timer;
  try {
    await Promise.race([completion, new Promise((_, reject) => { timer = setTimeout(() => reject(new Error('quit probe deadline')), 30_000); })]);
  } finally { clearTimeout(timer); }
  const record = (await readReleaseInput(result, { maximum: 256, protectedTrust: true })).toString('utf8');
  const match = /^core:([1-9][0-9]*)\nready\ndeferred\nconfirmed\n$/.exec(record);
  assert.ok(match);
  const pid = Number(match[1]); assert.ok(Number.isSafeInteger(pid) && pid > 1 && pid <= 0x7fffffff);
  assert.throws(() => process.kill(pid, 0), error => error.code === 'ESRCH');
  await assert.rejects(lstat(join(data, 'core.pid')), error => error.code === 'ENOENT');
  assert.deepEqual(await auditMacBundle(source, architecture), before);
  await verifyDevelopmentSignatures(source, before);
  assert.deepEqual(await readReleaseInput(probe, { maximum: 128 * 1024 * 1024, protectedTrust: true }), probeBytes);
  process.stdout.write('Owned core quit fixture passed: real AppKit deferred reply, observed packaged launcher exit and OTP PID removal; interactive UI and installed update remain separate\n');
  await log.close(); log = undefined;
  await rm(work, { recursive: true }); work = undefined;
} catch {
  // Only this fixture's child is signalled. Failed private evidence is retained.
  if (child?.exitCode === null && child.signalCode === null) child.kill('SIGTERM');
  process.stderr.write('Owned core quit fixture refused; private evidence retained\n'); process.exitCode = 1;
} finally { if (log) await log.close(); }
