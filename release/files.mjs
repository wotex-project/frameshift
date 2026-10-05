import { createHash } from 'node:crypto';
import { constants } from 'node:fs';
import { lstat, open } from 'node:fs/promises';

const sameStat = (a, b) => ['dev', 'ino', 'size', 'mode', 'uid', 'gid', 'nlink', 'mtimeNs', 'ctimeNs'].every(key => a[key] === b[key]);

// Shared only by local release metadata/archive readers. The consumer receives
// an admitted descriptor; the final named file must still be that same object.
export async function withReleaseInput(path, { minimum = 1, maximum, privateKey = false, protectedTrust = false, budgetMs = 60_000 }, consume) {
  const deadline = performance.now() + budgetMs;
  const budget = () => { if (performance.now() > deadline) throw new Error('release input processing deadline'); };
  const named = await lstat(path, { bigint: true });
  if (!named.isFile()) throw new Error('release input must be regular');
  const custody = stat => {
    if (privateKey && (stat.uid !== BigInt(process.getuid()) || ![0o400n, 0o600n].includes(stat.mode & 0o7777n))) {
      throw new Error('unsafe release private key file');
    }
    if (protectedTrust && (![0n, BigInt(process.getuid())].includes(stat.uid) || (stat.mode & 0o022n) !== 0n)) {
      throw new Error('unsafe release trust file');
    }
  };
  custody(named);
  budget();
  const handle = await open(path, constants.O_RDONLY | constants.O_NOFOLLOW | constants.O_NONBLOCK);
  try {
    const before = await handle.stat({ bigint: true });
    if (!before.isFile() || before.size < BigInt(minimum) || before.size > BigInt(maximum) || !sameStat(before, named)) {
      throw new Error('invalid release input size or custody');
    }
    custody(before);
    budget();
    const result = await consume(handle, Number(before.size), budget);
    budget();
    const after = await handle.stat({ bigint: true });
    const final = await lstat(path, { bigint: true });
    if (!final.isFile() || !sameStat(before, after) || !sameStat(after, final)) throw new Error('release input changed while reading');
    budget();
    return result;
  } finally { await handle.close(); }
}

export async function readReleaseInput(path, bounds) {
  return withReleaseInput(path, bounds, async (handle, size, budget) => {
    const bytes = Buffer.alloc(size);
    let offset = 0;
    while (offset < bytes.length) {
      budget();
      const { bytesRead } = await handle.read(bytes, offset, Math.min(64 * 1024, bytes.length - offset), offset);
      if (bytesRead === 0) throw new Error('release input changed while reading');
      offset += bytesRead;
    }
    budget();
    if ((await handle.read(Buffer.alloc(1), 0, 1, offset)).bytesRead !== 0) throw new Error('release input grew while reading');
    return bytes;
  });
}

export async function hashReleaseArchive(path) {
  return withReleaseInput(path, { maximum: 8 * 1024 * 1024 * 1024, budgetMs: 15 * 60_000 }, async (handle, size, budget) => {
    const hash = createHash('sha256');
    const block = Buffer.alloc(64 * 1024);
    let count = 0;
    while (count < size) {
      budget();
      const { bytesRead } = await handle.read(block, 0, Math.min(block.length, size - count), count);
      if (bytesRead === 0) throw new Error('release input changed while reading');
      count += bytesRead;
      hash.update(block.subarray(0, bytesRead));
    }
    budget();
    if ((await handle.read(block, 0, 1, count)).bytesRead !== 0) throw new Error('release input grew while reading');
    return { bytes: count, sha256: hash.digest('hex') };
  });
}

export async function readPinnedFingerprint(path) {
  const bytes = await readReleaseInput(path, { minimum: 64, maximum: 65, protectedTrust: true });
  const value = new TextDecoder('utf-8', { fatal: true }).decode(bytes);
  const digest = value.slice(0, 64);
  if (!/^[0-9a-f]{64}$/.test(digest) || (value !== digest && value !== digest + '\n')) throw new Error('invalid release trust fingerprint');
  return digest;
}
