import assert from 'node:assert/strict';
import { chmodSync, mkdirSync, mkdtempSync, readFileSync, rmSync, symlinkSync, writeFileSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { test } from 'node:test';
import { cohort, digest, inventory, verifyArchive, verifyBundle, verifyDiscovery } from './artifacts.mjs';

function discovery(transport) {
  return { protocol: cohort.protocol, transports: [transport],
    implementation: { source_revision: cohort.revision }, limits: cohort.limits,
    contracts: [{ contract: cohort.contract, profiles: cohort.profiles, operations: cohort.operations,
      readable_schemas: cohort.readable_schemas, writable_schemas: cohort.readable_schemas.slice(0, 1) }] };
}

function fixture(run) {
  const root = mkdtempSync(join(tmpdir(), 'frameshift-artifact-test-'));
  try {
    mkdirSync(join(root, 'discovery'));
    for (const [name, transport] of [['port', 'cj/port/1'], ['wasm', 'cj/wasm-abi/1']]) {
      writeFileSync(join(root, 'discovery', `${name}.json`), JSON.stringify(discovery(transport)));
    }
    writeFileSync(join(root, 'executable'), 'test bytes');
    chmodSync(join(root, 'executable'), 0o755);
    const manifest = { version: 'frameshift.conjunct-bundle.v1', cohort, publishable: false, files: inventory(root) };
    const bytes = JSON.stringify(manifest);
    writeFileSync(join(root, 'manifest.json'), bytes);
    run(root, digest(bytes));
  } finally { rmSync(root, { recursive: true, force: true }); }
}

test('exact inventory accepts only the selected manifest and cohort', () => fixture((root, hash) => {
  verifyBundle(root, hash);
  assert.throws(() => verifyBundle(root, 'sha256:' + '0'.repeat(64)), /manifest digest/);
}));

for (const [name, mutate] of [
  ['changed bytes', root => writeFileSync(join(root, 'executable'), 'altered bytes')],
  ['extra file', root => writeFileSync(join(root, 'undeclared'), 'unexpected')],
  ['lost executable permission', root => chmodSync(join(root, 'executable'), 0o644)],
  ['symlink', root => { rmSync(join(root, 'executable')); symlinkSync('/etc/hosts', join(root, 'executable')); }],
  ['rewritten manifest', root => {
    const manifest = JSON.parse(readFileSync(join(root, 'manifest.json'), 'utf8'));
    manifest.cohort.revision = '0'.repeat(40);
    writeFileSync(join(root, 'manifest.json'), JSON.stringify(manifest));
  }],
]) {
  test(`bundle refuses ${name}`, () => fixture((root, hash) => {
    mutate(root);
    assert.throws(() => verifyBundle(root, hash));
  }));
}

test('discovery refuses changed contracts, absent profiles and wrong transports', () => {
  for (const mutate of [value => { value.contracts[0].contract.digest = 'sha256:' + '0'.repeat(64); },
    value => { value.contracts[0].profiles.pop(); }, value => { value.transports = ['cj/c-abi/1']; },
    value => { value.limits.document_bytes = 1; }]) {
    const value = structuredClone(discovery('cj/port/1'));
    mutate(value);
    assert.throws(() => verifyDiscovery(value, 'cj/port/1'));
  }
});

test('archive traversal, absolute names, duplicate names, links and devices refuse before extraction', () => {
  verifyArchive('root/\nroot/file\n', 'drwx root\n-rw root/file\n');
  for (const path of ['/absolute', 'root/../outside', 'root\\outside']) {
    assert.throws(() => verifyArchive(path + '\n', '-rw file\n'));
  }
  assert.throws(() => verifyArchive('root/file\nroot/file\n', '-rw file\n-rw file\n'));
  for (const type of ['l', 'h', 'c', 'b', 'p']) assert.throws(() => verifyArchive('root/file\n', type + 'rw file\n'));
});
