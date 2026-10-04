import assert from 'node:assert/strict';
import { createHash } from 'node:crypto';
import { lstatSync, readdirSync, readFileSync } from 'node:fs';
import { join, posix } from 'node:path';

export const cohort = JSON.parse(readFileSync(new URL('./cohort.json', import.meta.url), 'utf8'));
export const digest = bytes => `sha256:${createHash('sha256').update(bytes).digest('hex')}`;

// Inventory only ordinary files. Symlinks and special files must never enter a
// runtime bundle, including when their target would happen to be inside it.
export function inventory(root, relative = '') {
  return readdirSync(join(root, relative)).sort().flatMap(name => {
    const path = posix.join(relative, name);
    const absolute = join(root, path);
    const stat = lstatSync(absolute);
    assert(!stat.isSymbolicLink(), `symlink in artifact bundle: ${path}`);
    if (stat.isDirectory()) return inventory(root, path);
    assert(stat.isFile(), `special file in artifact bundle: ${path}`);
    return [{ path, bytes: stat.size, digest: digest(readFileSync(absolute)), executable: (stat.mode & 0o111) !== 0 }];
  });
}

export function verifyBundle(root, expectedDigest) {
  const bytes = readFileSync(join(root, 'manifest.json'));
  assert.equal(digest(bytes), expectedDigest, 'bundle manifest digest changed');
  const manifest = JSON.parse(bytes.toString('utf8'));
  assert.equal(manifest.version, 'frameshift.conjunct-bundle.v1');
  assert.deepEqual(manifest.cohort, cohort, 'bundle selects a different producer cohort');
  assert.equal(manifest.publishable, false, 'this consumer bundle is unsigned');
  assert.deepEqual(inventory(root).filter(file => file.path !== 'manifest.json'), manifest.files,
    'artifact inventory, digest, size or executable permission changed');
  for (const transport of ['port', 'wasm']) {
    verifyDiscovery(JSON.parse(readFileSync(join(root, `discovery/${transport}.json`), 'utf8')), `cj/${transport === 'port' ? 'port/1' : 'wasm-abi/1'}`);
  }
  return manifest;
}

export function verifyDiscovery(discovery, transport) {
  assert.equal(discovery.protocol, cohort.protocol);
  assert.deepEqual(discovery.transports, [transport]);
  assert.equal(discovery.implementation.source_revision, cohort.revision);
  assert.equal(discovery.contracts.length, 1);
  const selected = discovery.contracts[0];
  assert.deepEqual(selected.contract, cohort.contract);
  assert.deepEqual(selected.profiles, cohort.profiles);
  assert.deepEqual(selected.operations, cohort.operations);
  assert.deepEqual(selected.readable_schemas, cohort.readable_schemas);
  assert.deepEqual(selected.writable_schemas, cohort.readable_schemas.slice(0, 1));
  for (const [name, maximum] of Object.entries(cohort.limits)) {
    assert(Number.isSafeInteger(discovery.limits[name]) && discovery.limits[name] >= maximum,
      `producer cannot satisfy consumer limit: ${name}`);
  }
  return selected;
}

// The tar reader is the operating system tool, but paths and member types are
// checked before extraction. The source archive is also pinned by raw digest.
export function verifyArchive(entries, types) {
  const paths = entries.trimEnd().split('\n');
  assert(paths.length > 0 && !paths.includes(''));
  assert.equal(new Set(paths).size, paths.length, 'duplicate archive path');
  for (const path of paths) {
    assert(!path.startsWith('/') && !path.includes('\\') &&
      !path.split('/').includes('..'), `unsafe archive path: ${path}`);
  }
  const members = types.trimEnd().split('\n');
  assert.equal(members.length, paths.length);
  assert(members.every(line => line.startsWith('-') || line.startsWith('d')),
    'archive contains a link or special file');
}
