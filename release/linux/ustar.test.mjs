import assert from 'node:assert/strict';
import { execFileSync } from 'node:child_process';
import { chmodSync, closeSync, constants, ftruncateSync, lstatSync, mkdirSync, mkdtempSync, openSync, readFileSync, rmSync, statfsSync, symlinkSync, writeFileSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import test from 'node:test';
import { sha256 } from './material.mjs';
import { availableSpace, extractArchive, openArchive, verifyArchive, verifyExtractedArchive } from './ustar.mjs';

function fixture(t) {
  const root = mkdtempSync(join(tmpdir(), 'frameshift-ustar-'));
  t.after(() => rmSync(root, { recursive: true, force: true }));
  const candidate = join(root, 'ubuntu-candidate');
  mkdirSync(candidate, { mode: 0o700 });
  mkdirSync(join(candidate, 'nested'), { mode: 0o750 });
  writeFileSync(join(candidate, 'nested/still'), 'retained still bytes', { mode: 0o640 });
  const path = join(root, 'candidate.tar');
  execFileSync('tar', ['--format=ustar', '-cf', path, '-C', root, 'ubuntu-candidate']);
  chmodSync(path, 0o600);
  const bytes = readFileSync(path);
  const archive = openArchive(path, sha256(bytes));
  const file = archive.entries.find(entry => !entry.directory);
  const rootHeader = Buffer.from(bytes.subarray(0, 512));
  const fileHeader = Buffer.from(bytes.subarray(file.offset - 512, file.offset));
  closeSync(archive.fd);
  return { root, path, bytes, file, rootHeader, fileHeader };
}
function field(header, offset, length, value) {
  header.fill(0, offset, offset + length);
  header.write(value, offset, length, 'utf8');
}
function checksum(header) {
  header.fill(32, 148, 156);
  const sum = header.reduce((total, byte) => total + byte, 0);
  header.write(sum.toString(8).padStart(6, '0') + '\0 ', 148, 8, 'ascii');
}
function refusal(f, bytes, label) {
  writeFileSync(f.path, bytes);
  assert.throws(() => openArchive(f.path, sha256(bytes)), undefined, label);
}

test('actual USTAR producer preserves bounded regular bytes and modes, and changed descriptor custody refuses', t => {
  const f = fixture(t);
  const archive = openArchive(f.path, sha256(f.bytes));
  try {
    assert.equal(archive.entries.length, 3);
    assert.equal(archive.payloadBytes, 20);
    const output = join(f.root, 'received');
    mkdirSync(output, { mode: 0o700 });
    extractArchive(archive, output);
    verifyExtractedArchive(archive, output);
    assert.equal(readFileSync(join(output, 'ubuntu-candidate/nested/still'), 'utf8'), 'retained still bytes');
    assert.equal(lstatSync(join(output, 'ubuntu-candidate/nested')).mode & 0o7777, 0o750);
    assert.equal(lstatSync(join(output, 'ubuntu-candidate/nested/still')).mode & 0o7777, 0o640);
    writeFileSync(f.path, f.bytes);
    assert.throws(() => verifyArchive(archive), /custody/);
  } finally { closeSync(archive.fd); }
});

test('untrusted names, header types, numbers, checksum and modes refuse despite a matching transport digest', t => {
  const f = fixture(t);
  const cases = [
    ['checksum', header => header[0] ^= 1, false],
    ['absolute', header => field(header, 0, 100, '/ubuntu-candidate/nested/still')],
    ['traversal', header => field(header, 0, 100, 'ubuntu-candidate/../still')],
    ['dot', header => field(header, 0, 100, 'ubuntu-candidate/./still')],
    ['empty component', header => field(header, 0, 100, 'ubuntu-candidate//still')],
    ['backslash', header => field(header, 0, 100, 'ubuntu-candidate/\\still')],
    ['outside root', header => field(header, 0, 100, 'other/still')],
    ['control', header => field(header, 0, 100, 'ubuntu-candidate/secret\n')],
    ['bad UTF8', header => { field(header, 0, 100, 'ubuntu-candidate/'); header[17] = 0xff; }],
    ['prefix traversal', header => field(header, 345, 155, '../ubuntu-candidate')],
    ['string padding', header => header[99] = 65],
    ...['1', '2', '3', '4', '6', '7', 'x', 'g', 'L', 'K'].map(type => [`type ${type}`, header => header[156] = type.charCodeAt(0)]),
    ['link target', header => field(header, 157, 100, 'private-source')],
    ['magic', header => field(header, 257, 6, 'ustar ')],
    ['high-bit magic', header => header[257] |= 0x80],
    ['version', header => field(header, 263, 2, '01')],
    ['high-bit version', header => header[263] |= 0x80],
    ['reserved', header => header[511] = 1],
    ['binary number', header => header[124] = 0x80],
    ['non-octal number', header => field(header, 108, 8, '0000008')],
    ['oversized member', header => field(header, 124, 12, (512 * 1024 * 1024 + 1).toString(8))],
    ['mode overflow', header => field(header, 100, 8, '1777777')],
    ['setuid', header => field(header, 100, 8, '0004600')],
    ['group write', header => field(header, 100, 8, '0000660')],
    ['no owner read', header => field(header, 100, 8, '0000240')]
  ];
  for (const [label, mutate, repair = true] of cases) {
    const bytes = Buffer.from(f.bytes);
    const header = bytes.subarray(f.file.offset - 512, f.file.offset);
    mutate(header);
    if (repair) checksum(header);
    refusal(f, bytes, label);
  }
});

test('duplicates, file parents, nonzero padding/trailing bytes and missing terminators refuse', t => {
  const f = fixture(t);
  refusal(f, Buffer.concat([f.rootHeader, f.rootHeader, f.bytes.subarray(512)]), 'duplicate root');
  const parent = Buffer.from(f.fileHeader);
  field(parent, 0, 100, 'ubuntu-candidate/parent');
  field(parent, 124, 12, '0');
  checksum(parent);
  const child = Buffer.from(parent);
  field(child, 0, 100, 'ubuntu-candidate/parent/child');
  checksum(child);
  refusal(f, Buffer.concat([f.rootHeader, parent, child, Buffer.alloc(1024)]), 'file as directory');
  const padding = Buffer.from(f.bytes);
  padding[f.file.offset + f.file.bytes] = 1;
  refusal(f, padding, 'payload padding');
  refusal(f, Buffer.concat([f.bytes, Buffer.alloc(512, 1)]), 'trailing material');
  refusal(f, Buffer.concat([f.rootHeader, f.fileHeader, f.bytes.subarray(f.file.offset, f.file.offset + 512), Buffer.alloc(512)]), 'single terminator');
  const nonprivate = Buffer.from(f.bytes);
  field(nonprivate, 100, 8, '0000755');
  checksum(nonprivate.subarray(0, 512));
  refusal(f, nonprivate, 'root must be private');
  const directoryPayload = Buffer.from(f.bytes);
  field(directoryPayload, 124, 12, '1');
  checksum(directoryPayload.subarray(0, 512));
  refusal(f, directoryPayload, 'directory payload');
});

test('archive custody, digest grammar, sparse size ceiling and free-space reserve refuse without unbounded reads', t => {
  const f = fixture(t);
  for (const hash of ['0'.repeat(64), 'a'.repeat(64) + '\n', 'A'.repeat(64), '0'.repeat(63)]) {
    assert.throws(() => openArchive(f.path, hash));
  }
  chmodSync(f.path, 0o666);
  assert.throws(() => openArchive(f.path, sha256(f.bytes)), /custody/);
  chmodSync(f.path, 0o600);
  const alias = join(f.root, 'alias');
  symlinkSync(f.path, alias);
  assert.throws(() => openArchive(alias, sha256(f.bytes)), /regular/);
  const fifo = join(f.root, 'fifo');
  execFileSync('mkfifo', [fifo]);
  assert.throws(() => openArchive(fifo, sha256(f.bytes)), /regular/);
  const fd = openSync(f.path, constants.O_WRONLY);
  try { ftruncateSync(fd, 1024 * 1024 * 1024 + 512); } finally { closeSync(fd); }
  assert.throws(() => openArchive(f.path, sha256(f.bytes)), /custody/);
  const { bavail, bsize } = statfsSync(f.root, { bigint: true });
  assert.throws(() => availableSpace(f.root, bavail * bsize), /insufficient/);
  assert.doesNotThrow(() => availableSpace(f.root, 20));
});

test('the actual 65536-entry limit admits its boundary and refuses the next entry', t => {
  const f = fixture(t);
  const bytes = Buffer.alloc((65_537 + 2) * 512);
  f.rootHeader.copy(bytes);
  for (let index = 1; index < 65_537; index++) {
    const header = bytes.subarray(index * 512, (index + 1) * 512);
    f.fileHeader.copy(header);
    field(header, 0, 100, `ubuntu-candidate/f${index}`);
    field(header, 124, 12, '0');
    checksum(header);
  }
  const admitted = Buffer.concat([bytes.subarray(0, 65_536 * 512), Buffer.alloc(1024)]);
  writeFileSync(f.path, admitted);
  const archive = openArchive(f.path, sha256(admitted));
  try { assert.equal(archive.entries.length, 65_536); } finally { closeSync(archive.fd); }
  refusal(f, bytes, '65537 entries');
});
