import { createHash } from 'node:crypto';
import { lstatSync } from 'node:fs';
import { join, resolve } from 'node:path';
import { isDeepStrictEqual as same } from 'node:util';
import { readReleaseInput } from '../files.mjs';
import { materialDirectoryNames } from '../material-receipts.mjs';

const identity = stat => ['dev', 'ino', 'mode', 'uid', 'gid', 'size', 'nlink', 'mtimeNs', 'ctimeNs'].map(key => String(stat[key]));
const fail = () => { throw new Error('unsafe, changed or unsupported SDK resource custody'); };
const facts = [
  { path: 'configs.json', bytes: 47709, sha256: '37180f6a7b21bf718e30e1f72efcc1241691daa5d3dc4ef32fc5d9fe7ec50f86' },
  { path: 'models.json', bytes: 125897, sha256: 'b50e05acf0410422bb1513b61dc81542e94bea5e5d7c3ed9a94ca47ca89c0134' }
];
export async function checkSDKResources(root, { read = readReleaseInput } = {}) {
  if (process.version !== 'v26.9.0' || process.getuid() === 0) fail();
  root = resolve(root); const before = lstatSync(root, { bigint: true }), files = [];
  if (!before.isDirectory() || before.uid !== BigInt(process.getuid()) || (before.mode & 0o7777n) !== 0o700n || !same(materialDirectoryNames(root), facts.map(f => f.path))) fail();
  for (const fact of facts) {
    const path = join(root, fact.path), stat = lstatSync(path, { bigint: true });
    if (!stat.isFile() || stat.uid !== BigInt(process.getuid()) || stat.nlink !== 1n || (stat.mode & 0o7777n) !== 0o600n) fail();
    const bytes = await read(path, { maximum: 256 * 1024, privateKey: true });
    if (bytes.length !== fact.bytes || createHash('sha256').update(bytes).digest('hex') !== fact.sha256 || !same(identity(stat), identity(lstatSync(path, { bigint: true })))) fail();
    files.push({ path, identity: identity(stat) });
  }
  for (const file of files) if (!same(file.identity, identity(lstatSync(file.path, { bigint: true })))) fail();
  if (!same(identity(before), identity(lstatSync(root, { bigint: true }))) || !same(materialDirectoryNames(root), facts.map(f => f.path))) fail();
  return { schemaVersion: 1, kind: 'pinned-generation-sdk-resource-custody', wrapperRevision: '8868a9685d9c299816f43ef53efd455ffca437f0', implementationRevision: 'd473a2f148b3e7dc9b90d0b7cfccc5cda999eb66', publicationAuthority: 'none', resources: facts.map(f => ({ ...f })) };
}
