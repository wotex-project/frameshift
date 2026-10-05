import { createHash, createPrivateKey, createPublicKey, sign } from 'node:crypto';
import { lstat, mkdir, rm, writeFile } from 'node:fs/promises';
import { dirname, join } from 'node:path';
import { artifactFacts, parseManifest, verifyRelease } from './manifest.mjs';
import { readReleaseInput } from './files.mjs';

const decoder = new TextDecoder('utf-8', { fatal: true });
const planKeys = ['schemaVersion', 'product', 'version', 'artifacts'];
const artifactKeys = ['platform', 'architecture', 'format', 'file', 'url'];

function exactKeys(value, keys) {
  return value !== null && typeof value === 'object' && !Array.isArray(value) &&
    Object.keys(value).length === keys.length &&
    keys.every(key => Object.hasOwn(value, key));
}

export function parsePlan(bytes) {
  if (!Buffer.isBuffer(bytes) || bytes.length < 2 || bytes.length > 64 * 1024) {
    throw new Error('invalid release plan size');
  }
  let text;
  let plan;
  try {
    text = decoder.decode(bytes);
    plan = JSON.parse(text);
  } catch {
    throw new Error('invalid release plan JSON');
  }
  if (JSON.stringify(plan) + '\n' !== text || !exactKeys(plan, planKeys) ||
      !Array.isArray(plan.artifacts) ||
      !plan.artifacts.every(artifact => exactKeys(artifact, artifactKeys))) {
    throw new Error('invalid release plan fields or encoding');
  }
  const placeholder = {
    schemaVersion: plan.schemaVersion, product: plan.product, version: plan.version,
    artifacts: plan.artifacts.map(artifact => ({
      platform: artifact.platform, architecture: artifact.architecture,
      format: artifact.format, file: artifact.file, url: artifact.url,
      bytes: 1, sha256: '0'.repeat(64),
    })),
  };
  parseManifest(Buffer.from(JSON.stringify(placeholder) + '\n'));
  return plan;
}

async function readPlan(path) {
  return parsePlan(await readReleaseInput(path, { minimum: 2, maximum: 64 * 1024 }));
}

async function readSigningKey(path) {
  const bytes = await readReleaseInput(path, { maximum: 16 * 1024, privateKey: true });
  try { return createPrivateKey(bytes); } catch { throw new Error('invalid release private key'); }
}

function signingIdentity(key, trustedKeyDigest) {
  if (key.asymmetricKeyType !== 'ed25519' ||
      typeof trustedKeyDigest !== 'string' || trustedKeyDigest.length !== 64 || !/^[0-9a-f]{64}$/.test(trustedKeyDigest)) {
    throw new Error('invalid release signing identity');
  }
  const publicKey = createPublicKey(key);
  const digest = createHash('sha256')
    .update(publicKey.export({ type: 'spki', format: 'der' })).digest('hex');
  if (digest !== trustedKeyDigest) throw new Error('release signing key is not owner-pinned');
  return publicKey.export({ type: 'spki', format: 'pem' });
}

async function admitOutputParent(outputDirectory) {
  const parent = await lstat(dirname(outputDirectory));
  if (!parent.isDirectory() || parent.uid !== process.getuid() ||
      (parent.mode & 0o022) !== 0) {
    throw new Error('unsafe release output parent');
  }
}

export async function signRelease({ planPath, artifactDirectory, privateKeyPath,
                                    trustedKeyDigest, outputDirectory }) {
  await admitOutputParent(outputDirectory);
  const plan = await readPlan(planPath);
  const key = await readSigningKey(privateKeyPath);
  const publicKeyPem = signingIdentity(key, trustedKeyDigest);
  const artifacts = [];
  for (const artifact of plan.artifacts) {
    const facts = await artifactFacts(artifactDirectory, artifact.file);
    artifacts.push({
      platform: artifact.platform, architecture: artifact.architecture,
      format: artifact.format, file: artifact.file, url: artifact.url,
      bytes: facts.bytes, sha256: facts.sha256,
    });
  }
  const manifestBytes = Buffer.from(JSON.stringify({
    schemaVersion: plan.schemaVersion, product: plan.product,
    version: plan.version, artifacts,
  }) + '\n');
  parseManifest(manifestBytes);
  const signature = sign(null, manifestBytes, key);
  if (signature.length !== 64) throw new Error('invalid release signature size');

  await mkdir(outputDirectory, { mode: 0o700 });
  try {
    const manifestPath = join(outputDirectory, 'manifest.json');
    const signaturePath = join(outputDirectory, 'manifest.sig');
    const publicKeyPath = join(outputDirectory, 'release.pub.pem');
    await writeFile(manifestPath, manifestBytes, { flag: 'wx', mode: 0o600 });
    await writeFile(signaturePath, signature, { flag: 'wx', mode: 0o600 });
    await writeFile(publicKeyPath, publicKeyPem, { flag: 'wx', mode: 0o600 });
    await verifyRelease({ manifestPath, signaturePath, publicKeyPath,
      trustedKeyDigest, artifactDirectory });
    return { version: plan.version, artifactCount: artifacts.length };
  } catch (error) {
    await rm(outputDirectory, { recursive: true, force: true });
    throw error;
  }
}
