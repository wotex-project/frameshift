import { createHash, createPublicKey, verify } from 'node:crypto';
import { lstat } from 'node:fs/promises';
import { join } from 'node:path';
import { hashReleaseArchive, readReleaseInput } from './files.mjs';

const manifestKeys = ['schemaVersion', 'product', 'version', 'artifacts'];
const artifactKeys = ['platform', 'architecture', 'format', 'file', 'url', 'bytes', 'sha256'];
const tuples = new Set([
  'macos/universal/dmg',
  'ubuntu/amd64/deb',
  'ubuntu/arm64/deb',
  'nerves-rpi5/arm64/fw',
]);
const decoder = new TextDecoder('utf-8', { fatal: true });

function requireKeys(value, keys) {
  if (value === null || typeof value !== 'object' || Array.isArray(value) ||
      Object.keys(value).length !== keys.length ||
      !keys.every((key) => Object.hasOwn(value, key))) {
    throw new Error('invalid release manifest fields');
  }
}

function validArtifact(artifact, version) {
  requireKeys(artifact, artifactKeys);
  const tuple = `${artifact.platform}/${artifact.architecture}/${artifact.format}`;
  if (!tuples.has(tuple)) throw new Error('unsupported release target');
  if (typeof artifact.file !== 'string' ||
      !/^[A-Za-z0-9][A-Za-z0-9._-]{0,127}$/.test(artifact.file) ||
      artifact.file.includes('..') || !artifact.file.includes(version) ||
      !artifact.file.endsWith(`.${artifact.format}`)) {
    throw new Error('invalid release filename');
  }
  if (!Number.isSafeInteger(artifact.bytes) || artifact.bytes < 1 ||
      artifact.bytes > 8 * 1024 * 1024 * 1024) {
    throw new Error('invalid release byte count');
  }
  if (typeof artifact.sha256 !== 'string' || artifact.sha256.length !== 64 || !/^[0-9a-f]{64}$/.test(artifact.sha256)) {
    throw new Error('invalid release digest');
  }
  if (typeof artifact.url !== 'string') throw new Error('invalid release URL');
  let url;
  try { url = new URL(artifact.url); } catch { throw new Error('invalid release URL'); }
  if (url.protocol !== 'https:' || url.username || url.password || url.search || url.hash ||
      url.port || url.pathname.includes('%') ||
      /(^|\/)latest(\/|$)/i.test(url.pathname) ||
      !url.pathname.endsWith(`/v${version}/${artifact.file}`) ||
      artifact.url !== url.href) {
    throw new Error('invalid release URL');
  }
  return tuple;
}

export function parseManifest(bytes) {
  if (!Buffer.isBuffer(bytes) || bytes.length < 2 || bytes.length > 64 * 1024) {
    throw new Error('invalid release manifest size');
  }
  let text;
  let manifest;
  try {
    text = decoder.decode(bytes);
    manifest = JSON.parse(text);
  } catch {
    throw new Error('invalid release manifest JSON');
  }
  if (JSON.stringify(manifest) + '\n' !== text) {
    throw new Error('release manifest must use exact compact JSON encoding');
  }
  requireKeys(manifest, manifestKeys);
  if (manifest.schemaVersion !== 1 || manifest.product !== 'io.frameshift.app' ||
      typeof manifest.version !== 'string' ||
      manifest.version.length > 32 ||
      !/^(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)$/.test(manifest.version) ||
      !Array.isArray(manifest.artifacts) || manifest.artifacts.length < 1 ||
      manifest.artifacts.length > 16) {
    throw new Error('invalid release manifest identity');
  }
  const names = new Set();
  const targets = new Set();
  for (const artifact of manifest.artifacts) {
    const target = validArtifact(artifact, manifest.version);
    if (names.has(artifact.file) || targets.has(target)) {
      throw new Error('duplicate release artifact');
    }
    names.add(artifact.file);
    targets.add(target);
  }
  return manifest;
}

export async function artifactFacts(directory, file) {
  if (typeof file !== 'string' || file.length > 128 || !/^[A-Za-z0-9]/.test(file) || /[^A-Za-z0-9._-]/.test(file) || file.includes('..')) {
    throw new Error('invalid release archive name');
  }
  const directoryStat = await lstat(directory, { bigint: true });
  if (!directoryStat.isDirectory()) throw new Error('invalid release artifact directory');
  const facts = await hashReleaseArchive(join(directory, file));
  const final = await lstat(directory, { bigint: true });
  if (!final.isDirectory() || ['dev', 'ino', 'mode', 'uid', 'gid'].some(key => directoryStat[key] !== final[key])) {
    throw new Error('release artifact directory changed');
  }
  return facts;
}

async function verifyArtifact(directory, artifact) {
  const facts = await artifactFacts(directory, artifact.file);
  if (facts.bytes !== artifact.bytes) {
    throw new Error(`release artifact size mismatch: ${artifact.file}`);
  }
  if (facts.sha256 !== artifact.sha256) {
    throw new Error(`release artifact digest mismatch: ${artifact.file}`);
  }
}

// Retained site evidence uses this signature-only boundary; it does not assert
// that local archives or public bytes were checked during this invocation.
export async function verifyManifestSignature({ manifestPath, signaturePath, publicKeyPath,
                                                trustedKeyDigest }) {
  if (typeof trustedKeyDigest !== 'string' || trustedKeyDigest.length !== 64 || !/^[0-9a-f]{64}$/.test(trustedKeyDigest)) {
    throw new Error('missing pinned release key fingerprint');
  }
  const [bytes, signature, pem] = await Promise.all([
    readReleaseInput(manifestPath, { minimum: 2, maximum: 64 * 1024 }),
    readReleaseInput(signaturePath, { minimum: 64, maximum: 64 }),
    readReleaseInput(publicKeyPath, { maximum: 16 * 1024 }),
  ]);
  const manifest = parseManifest(bytes);
  let key;
  try { key = createPublicKey(pem); } catch { throw new Error('invalid release public key'); }
  const keyDigest = createHash('sha256').update(key.export({ type: 'spki', format: 'der' })).digest('hex');
  if (key.asymmetricKeyType !== 'ed25519' || keyDigest !== trustedKeyDigest ||
      signature.length !== 64 || !verify(null, bytes, key, signature)) {
    throw new Error('release signature or trusted key mismatch');
  }
  return manifest;
}

export async function verifyRelease(options) {
  const manifest = await verifyManifestSignature(options);
  for (const artifact of manifest.artifacts) await verifyArtifact(options.artifactDirectory, artifact);
  return manifest;
}

async function downloadDigest(artifact, fetcher) {
  let url = artifact.url;
  const signal = AbortSignal.timeout(15 * 60 * 1000);
  for (let redirects = 0; redirects <= 5; redirects += 1) {
    const response = await fetcher(url, {
      redirect: 'manual', credentials: 'omit', signal, headers: { 'accept-encoding': 'identity' },
    });
    if ([301, 302, 303, 307, 308].includes(response.status)) {
      await response.body?.cancel().catch(() => {});
      const location = response.headers.get('location');
      if (!location || redirects === 5) throw new Error('release redirect limit exceeded');
      const next = new URL(location, url);
      if (next.protocol !== 'https:' || next.username || next.password) {
        throw new Error('release redirect left HTTPS');
      }
      url = next.href;
      continue;
    }
    if (response.status !== 200 || !response.body ||
        (response.headers.get('content-encoding') &&
         response.headers.get('content-encoding') !== 'identity')) {
      await response.body?.cancel().catch(() => {});
      throw new Error(`public release response refused: ${artifact.file}`);
    }
    const length = response.headers.get('content-length');
    if (length !== null && (!/^[0-9]+$/.test(length) || Number(length) !== artifact.bytes)) {
      await response.body.cancel().catch(() => {});
      throw new Error(`public release length mismatch: ${artifact.file}`);
    }
    const hash = createHash('sha256');
    let count = 0;
    for await (const chunk of response.body) {
      count += chunk.byteLength;
      if (count > artifact.bytes) {
        await response.body.cancel().catch(() => {});
        throw new Error(`public release exceeds declared size: ${artifact.file}`);
      }
      hash.update(chunk);
    }
    if (count !== artifact.bytes || hash.digest('hex') !== artifact.sha256) {
      throw new Error(`public release digest mismatch: ${artifact.file}`);
    }
    return;
  }
}

// Archives are admitted by parseManifest; the channel observer also uses this
// bounded byte check for the three detached public metadata files.
export async function verifyPublishedFile(file, fetcher = fetch) {
  if (!file || typeof file.file !== 'string' || file.file.length > 128 || !/^[A-Za-z0-9]/.test(file.file) ||
      /[^A-Za-z0-9._-]/.test(file.file) || file.file.includes('..') ||
      !Number.isSafeInteger(file.bytes) || file.bytes < 1 || file.bytes > 8 * 1024 * 1024 * 1024 ||
      typeof file.sha256 !== 'string' || file.sha256.length !== 64 || !/^[0-9a-f]{64}$/.test(file.sha256)) throw new Error('invalid public release file');
  const url = new URL(file.url);
  if (url.protocol !== 'https:' || url.username || url.password || url.port || url.search || url.hash ||
      url.pathname.includes('%') || /(^|\/)latest(\/|$)/i.test(url.pathname) || !url.pathname.endsWith('/' + file.file) ||
      url.href !== file.url) throw new Error('invalid public release file URL');
  await downloadDigest(file, fetcher);
}

export async function verifyPublishedArtifacts(manifest, fetcher = fetch) {
  const admitted = parseManifest(Buffer.from(JSON.stringify(manifest) + '\n'));
  for (const artifact of admitted.artifacts) await downloadDigest(artifact, fetcher);
}
