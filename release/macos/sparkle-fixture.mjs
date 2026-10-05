import assert from 'node:assert/strict';
import { spawnSync } from 'node:child_process';
import { createHash, generateKeyPairSync, sign } from 'node:crypto';
import { mkdtempSync, readFileSync, rmSync, writeFileSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { readReleaseInput } from '../files.mjs';
import { verifySparkleArchive } from './channels.mjs';

// Explicit isolated qualification of a separately pinned upstream tool.
// Private ephemeral keys enter a 0600 file; the user's Keychain is never used.
const [tool, expectedHash] = process.argv.slice(2);
let root;
try {
  if (process.argv.length !== 4 || !/^[0-9a-f]{64}$/.test(expectedHash || '')) throw new Error();
  const binary = await readReleaseInput(tool, { maximum: 16 * 1024 * 1024, protectedTrust: true });
  assert.equal(createHash('sha256').update(binary).digest('hex'), expectedHash);
  root = mkdtempSync(join(tmpdir(), 'frameshift-sparkle-interop-'));
  const pair = generateKeyPairSync('ed25519');
  const seed = pair.privateKey.export({ format: 'der', type: 'pkcs8' }).subarray(-32);
  const publicKey = pair.publicKey.export({ format: 'der', type: 'spki' }).subarray(-32);
  const secret = join(root, 'ephemeral-key'), archive = join(root, 'archive.dmg');
  const bytes = Buffer.from('Sparkle archive signature interoperability fixture\n');
  // Sparkle 2.10's current file format is the 32-byte seed, not seed+public.
  writeFileSync(secret, seed.toString('base64') + '\n', { mode: 0o600 });
  writeFileSync(archive, bytes, { mode: 0o600 });
  const run = args => {
    const result = spawnSync(tool, ['--ed-key-file', secret, ...args],
      { encoding: 'utf8', timeout: 10_000, maxBuffer: 4096 });
    if (result.error || result.status !== 0) throw new Error();
    return result.stdout.trim();
  };
  const upstream = Buffer.from(run(['-p', archive]), 'base64');
  const node = sign(null, bytes, pair.privateKey);
  assert.deepEqual(upstream, node); verifySparkleArchive(bytes, upstream, publicKey);
  run(['--verify', archive, node.toString('base64')]);
  assert.deepEqual(readFileSync(archive), bytes);
  const final = await readReleaseInput(tool, { maximum: 16 * 1024 * 1024, protectedTrust: true });
  assert.deepEqual(final, binary);
  process.stdout.write('Pinned Sparkle signature interoperability passed: upstream signing, Node verification, Node signing and upstream verification; isolated ephemeral keys\n');
} catch {
  process.stderr.write('Pinned Sparkle signature interoperability refused\n'); process.exitCode = 1;
} finally {
  if (root) rmSync(root, { recursive: true, force: true });
}
