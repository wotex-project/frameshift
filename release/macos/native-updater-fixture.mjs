import assert from 'node:assert/strict';
import { spawn, spawnSync } from 'node:child_process';
import { generateKeyPairSync, randomUUID } from 'node:crypto';
import { chmodSync, copyFileSync, readFileSync, writeFileSync } from 'node:fs';
import { createServer } from 'node:http';
import { dirname, join, resolve } from 'node:path';
import { fileURLToPath } from 'node:url';
import { readReleaseInput } from '../files.mjs';
import { fixture } from './fixture.mjs';
import { signSparkleFeed } from './channels.mjs';

// Disposable sealed apps exercise isolated defaults and probing-only local feeds.
// Failure retains private work. No production eligibility or install follows.
let completed = false;
const cleanup = [];
let server;
const call = (command, args, timeout = 30_000) => {
  const result = spawnSync(command, args, { encoding: 'utf8', timeout, maxBuffer: 16 * 1024 * 1024 });
  assert.equal(result.error, undefined);
  assert.equal(result.status, 0, result.stderr);
  return result.stdout;
};
const launch = (binary, args, parent) => new Promise((resolve, reject) => {
  const child = spawn(binary, args, { stdio: ['ignore', 'pipe', 'pipe'] });
  const output = [[], []];
  let bytes = 0, failure;
  const stop = reason => {
    failure ??= reason;
    child.kill('SIGTERM');
    killTimer ??= setTimeout(() => child.kill('SIGKILL'), 2000);
  };
  let killTimer;
  const timer = setTimeout(() => stop(new Error('probe deadline')), 30_000);
  [child.stdout, child.stderr].forEach((pipe, index) => pipe.on('data', chunk => {
    bytes += chunk.length;
    if (bytes > 512 * 1024) stop(new Error('probe output bound'));
    else output[index].push(chunk);
  }));
  child.once('error', error => { failure ??= error; });
  child.once('close', (code, signal) => {
    clearTimeout(timer); clearTimeout(killTimer);
    const [stdout, stderr] = output.map(chunks => Buffer.concat(chunks).toString('utf8'));
    writeFileSync(join(parent, 'probe.stdout'), stdout, { mode: 0o600 });
    writeFileSync(join(parent, 'probe.stderr'), stderr, { mode: 0o600 });
    if (failure || code !== 0 || signal) reject(failure ?? new Error(`probe exit ${code}`));
    else resolve(stdout);
  });
});
try {
  assert.equal(process.platform, 'darwin');
  assert.equal(process.argv.length, 5);
  const [archive, cache, probe] = process.argv.slice(2).map(path => resolve(path));
  const root = resolve(dirname(fileURLToPath(import.meta.url)), '../..');
  const tool = join(root, 'release/macos/.build/release/frameshift-mac-release');
  const cpu = process.arch === 'arm64' ? 'arm64' : 'x86_64';
  const binary = await readReleaseInput(probe, { maximum: 128 * 1024 * 1024, protectedTrust: true });
  const original = call(tool, ['verify-sparkle-framework', archive, cache], 180_000);
  const keys = generateKeyPairSync('ed25519');
  const publicBytes = keys.publicKey.export({ format: 'der', type: 'spki' }).subarray(-32);
  const publicKey = publicBytes.toString('base64');
  const body = Buffer.from(`<?xml version="1.0" encoding="UTF-8"?>
<rss version="2.0" xmlns:sparkle="http://www.andymatuschak.org/xml-namespaces/sparkle">
<channel><title>Fixture updates</title><item><title>Fixture 2.0.0</title>
<sparkle:version>2.0.0</sparkle:version><sparkle:shortVersionString>2.0.0</sparkle:shortVersionString>
<sparkle:minimumSystemVersion>14.0</sparkle:minimumSystemVersion>
<enclosure url="https://archive.example.invalid/never-downloaded.zip" length="1" type="application/octet-stream" sparkle:edSignature="${Buffer.alloc(64, 0x7a).toString('base64')}" />
</item></channel></rss>\n`);
  const signed = signSparkleFeed(body, keys.privateKey, publicBytes);
  const tampered = Buffer.from(signed);
  tampered[body.indexOf('Fixture updates')] ^= 1;
  const responses = [signed, tampered, body, signed];
  let requests = 0, unexpected = false;
  server = createServer((request, response) => {
    if (request.method !== 'GET' || request.url !== '/appcast.xml' || requests >= 4) {
      unexpected = true; response.writeHead(404); response.end(); return;
    }
    const content = responses[requests++];
    response.writeHead(200, { 'Content-Type': 'application/rss+xml', 'Content-Length': content.length, 'Cache-Control': 'no-store' });
    response.end(content);
  });
  await new Promise((resolve, reject) => { server.once('error', reject); server.listen(0, '127.0.0.1', resolve); });
  const feed = `http://127.0.0.1:${server.address().port}/appcast.xml`;
  for (const mode of ['--stopped-preferences', '--running-preferences', '--signed-feed']) {
    const { parent, root: app } = fixture({ after: action => cleanup.push(action) }, cpu);
    // Each child owns a different physical app and defaults domain.
    chmodSync(parent, 0o700);
    copyFileSync(probe, join(app, 'Contents/MacOS/Frameshift'));
    chmodSync(join(app, 'Contents/MacOS/Frameshift'), 0o755);
    const info = join(app, 'Contents/Info.plist');
    copyFileSync(join(root, 'apps/macos/App/Info.plist'), info);
    const identifier = `io.frameshift.fixture.updater.${randomUUID()}`;
    call('/usr/bin/plutil', ['-replace', 'CFBundleIdentifier', '-string', identifier, info]);
    call('/usr/bin/plutil', ['-insert', 'SUFeedURL', '-string', 'https://updates.example.invalid/appcast.xml', info]);
    call('/usr/bin/plutil', ['-insert', 'SUPublicEDKey', '-string', publicKey, info]);
    if (mode === '--signed-feed') {
      call('/usr/bin/plutil', ['-insert', 'NSAppTransportSecurity', '-json', '{"NSAllowsLocalNetworking":true}', info]);
    }
    call(tool, ['stage-sparkle-framework', archive, app, cpu], 180_000);
    assert.match(call(tool, ['prepare-swiftbuild-updater-bundle', app, cpu], 360_000), /^development bundle: (arm64|x86_64), minimum macOS \d+\.\d+\.\d+\n$/);
    const before = call(tool, ['verify-development-bundle', app, cpu], 180_000);
    const args = mode === '--stopped-preferences' ? [mode] : mode === '--running-preferences' ? [mode, 'https://updates.example.invalid/appcast.xml', publicKey] : [mode, feed, publicKey];
    const stdout = await launch(join(app, 'Contents/MacOS/Frameshift'), args, parent);
    if (mode === '--stopped-preferences') assert.equal(stdout, 'stopped updater preserves stored choices\n');
    else if (mode === '--running-preferences') assert.equal(stdout, 'running updater preserves choices and denies paused checks\n');
    else assert.match(stdout, /^(signed feed refused: [^\n]+\n){2}signed feed accepts valid, refuses tampered\/unsigned, recovers valid\n$/);
    assert.equal(call(tool, ['verify-development-bundle', app, cpu], 180_000), before);
    assert.equal(readFileSync(info).includes(Buffer.from(identifier)), true);
    if (mode !== '--signed-feed') assert.equal(requests, 0);
  }
  assert.equal(requests, 4);
  assert.equal(unexpected, false);
  assert.equal(call(tool, ['verify-sparkle-framework', archive, cache], 180_000), original);
  assert.deepEqual(await readReleaseInput(probe, { maximum: 128 * 1024 * 1024, protectedTrust: true }), binary);
  completed = true;
  process.stdout.write('Native updater fixture passed: stopped/running choices, paused KVO refusal and actual signed/tampered/unsigned/recovered SDK probes; strict CPU/nested seals and original inputs unchanged\n');
} catch {
  process.stderr.write('Native updater fixture refused; private evidence retained\n');
  process.exitCode = 1;
} finally {
  if (server) await new Promise(resolve => server.close(resolve));
  if (completed) for (const action of cleanup) action();
}
