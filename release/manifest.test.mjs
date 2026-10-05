import assert from 'node:assert/strict';
import { createHash, generateKeyPairSync, sign } from 'node:crypto';
import { mkdtemp, rm, symlink, writeFile } from 'node:fs/promises';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import test from 'node:test';
import { parseManifest, verifyPublishedArtifacts, verifyPublishedFile, verifyRelease } from './manifest.mjs';

const digest = (bytes) => createHash('sha256').update(bytes).digest('hex');

function manifestFor(bytes) {
  return {
    schemaVersion: 1,
    product: 'io.frameshift.app',
    version: '1.2.3',
    artifacts: [{
      platform: 'macos',
      architecture: 'universal',
      format: 'dmg',
      file: 'Frameshift-1.2.3.dmg',
      url: 'https://example.com/releases/v1.2.3/Frameshift-1.2.3.dmg',
      bytes: bytes.length,
      sha256: digest(bytes),
    }],
  };
}

test('signature, pinned key, and exact artifact bytes are all required', async (t) => {
  const directory = await mkdtemp(join(tmpdir(), 'frameshift-release-'));
  t.after(() => rm(directory, { recursive: true, force: true }));
  const artifactBytes = Buffer.from('fixture DMG bytes');
  const manifest = manifestFor(artifactBytes);
  const manifestBytes = Buffer.from(JSON.stringify(manifest) + '\n');
  const { publicKey, privateKey } = generateKeyPairSync('ed25519');
  const trustedKeyDigest = digest(publicKey.export({ type: 'spki', format: 'der' }));
  const manifestPath = join(directory, 'manifest.json');
  const signaturePath = join(directory, 'manifest.sig');
  const publicKeyPath = join(directory, 'release.pub.pem');
  const artifactPath = join(directory, manifest.artifacts[0].file);
  await Promise.all([
    writeFile(manifestPath, manifestBytes),
    writeFile(signaturePath, sign(null, manifestBytes, privateKey)),
    writeFile(publicKeyPath, publicKey.export({ type: 'spki', format: 'pem' })),
    writeFile(artifactPath, artifactBytes),
  ]);
  const options = { manifestPath, signaturePath, publicKeyPath, trustedKeyDigest,
    artifactDirectory: directory };
  assert.deepEqual(await verifyRelease(options), manifest);
  await assert.rejects(verifyRelease({ ...options, trustedKeyDigest: digest('wrong key') }),
    /trusted key mismatch/);

  await writeFile(artifactPath, Buffer.from('fixture DMG byte!'));
  await assert.rejects(verifyRelease(options), /digest mismatch/);
  await writeFile(artifactPath, artifactBytes);

  await writeFile(manifestPath, Buffer.from(JSON.stringify({ ...manifest, artifacts: [{
    ...manifest.artifacts[0], sha256: digest('forged artifact'),
  }] }) + '\n'));
  await assert.rejects(verifyRelease(options), /signature or trusted key mismatch/);
  await writeFile(manifestPath, manifestBytes);

  await rm(artifactPath);
  await symlink(manifestPath, artifactPath);
  await assert.rejects(verifyRelease(options));
});

test('schema rejects duplicate JSON, mutable URLs, duplicate targets, and traversal', () => {
  const manifest = manifestFor(Buffer.from('fixture'));
  const encoded = (value) => Buffer.from(JSON.stringify(value) + '\n');
  assert.deepEqual(parseManifest(encoded(manifest)), manifest);
  const duplicate = JSON.stringify(manifest).replace('"version":"1.2.3",',
    '"version":"1.2.3","version":"1.2.3",') + '\n';
  assert.throws(() => parseManifest(Buffer.from(duplicate)), /compact JSON/);
  assert.throws(() => parseManifest(encoded({ ...manifest, artifacts: [
    manifest.artifacts[0], manifest.artifacts[0],
  ] })), /duplicate release artifact/);
  assert.throws(() => parseManifest(encoded({ ...manifest, artifacts: [{
    ...manifest.artifacts[0], file: '../Frameshift-1.2.3.dmg',
  }] })), /invalid release filename/);
  assert.throws(() => parseManifest(encoded({ ...manifest, artifacts: [{
    ...manifest.artifacts[0], url: 'http://example.com/latest/Frameshift-1.2.3.dmg',
  }] })), /invalid release URL/);
  assert.throws(() => parseManifest(encoded({ ...manifest, artifacts: [{
    ...manifest.artifacts[0], url: 'https://example.com/latest/v1.2.3/Frameshift-1.2.3.dmg',
  }] })), /invalid release URL/);
  assert.throws(() => parseManifest(encoded({ ...manifest, artifacts: [{
    ...manifest.artifacts[0], platform: 'windows',
  }] })), /unsupported release target/);
});

test('publication fetch follows bounded HTTPS redirects and hashes the served bytes', async () => {
  const bytes = Buffer.from('public artifact bytes');
  const manifest = manifestFor(bytes);
  const calls = [];
  const fetcher = async (url, options) => {
    calls.push({ url, options });
    if (calls.length === 1) {
      return new Response(null, { status: 302,
        headers: { location: 'https://assets.example.com/signed-artifact' } });
    }
    return new Response(bytes, { status: 200,
      headers: { 'content-length': String(bytes.length) } });
  };
  await verifyPublishedArtifacts(manifest, fetcher);
  assert.equal(calls.length, 2);
  assert.equal(calls[0].options.redirect, 'manual');
  assert.equal(calls[0].options.headers['accept-encoding'], 'identity');
  assert.equal(calls[0].options.credentials, 'omit');
  assert.equal(calls[1].url, 'https://assets.example.com/signed-artifact');

  await assert.rejects(verifyPublishedArtifacts(manifest,
    async () => new Response(Buffer.from('public artifact byte!'))), /digest mismatch/);
  await assert.rejects(verifyPublishedArtifacts(manifest,
    async () => new Response(bytes, { status: 206 })), /response refused/);
  await assert.rejects(verifyPublishedArtifacts(manifest,
    async () => new Response(bytes, { headers: { 'content-encoding': 'gzip' } })),
  /response refused/);
  await assert.rejects(verifyPublishedArtifacts(manifest,
    async () => new Response(null, { status: 302,
      headers: { location: 'http://internal.invalid/artifact' } })), /left HTTPS/);
  await assert.rejects(verifyPublishedArtifacts(manifest,
    async () => new Response(null, { status: 302,
      headers: { location: 'https://assets.example.com/loop' } })), /redirect limit/);
});

test('public metadata shares bounded readback and releases refused/redirected response bodies', async () => {
  const bytes = Buffer.from('public detached metadata');
  const file = { file: 'manifest.json', url: 'https://example.invalid/releases/v1.2.3/manifest.json', bytes: bytes.length, sha256: digest(bytes) };
  let cancelled = 0;
  let count = 0;
  await verifyPublishedFile(file, async () => {
    if (++count === 1) return new Response(new ReadableStream({ cancel() { cancelled++; } }), {
      status: 302, headers: { location: 'https://assets.example.invalid/metadata' }
    });
    return new Response(bytes);
  });
  assert.equal(cancelled, 1);
  await assert.rejects(() => verifyPublishedFile(file, async () => new Response(new ReadableStream({ cancel() { cancelled++; } }), {
    status: 206
  })), /refused/);
  assert.equal(cancelled, 2);
  for (const invalid of [{ ...file, bytes: 0 }, { ...file, sha256: file.sha256 + '\n' },
    { ...file, file: '../manifest.json' }, { ...file, url: 'http://example.invalid/manifest.json' }]) {
    await assert.rejects(() => verifyPublishedFile(invalid, () => assert.fail('invalid metadata cannot fetch')));
  }
});
