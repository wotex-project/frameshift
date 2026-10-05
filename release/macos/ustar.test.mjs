import assert from 'node:assert/strict';
import { execFileSync } from 'node:child_process';
import { createHash } from 'node:crypto';
import { chmodSync, closeSync, lstatSync, mkdirSync, readFileSync, readlinkSync, rmSync, symlinkSync, writeFileSync } from 'node:fs';
import { dirname, join } from 'node:path';
import test from 'node:test';
import { extractArchive, openArchive, verifyExtractedArchive } from '../ustar.mjs';
import { temporary } from './fixture.mjs';
import { sparkleLinks, sparkleRoot } from '../macos-framework.mjs';

const hash = value => createHash('sha256').update(value).digest('hex');
function fixture(t) {
  const root = temporary(t), candidate = join(root, 'macos-candidate'), app = join(candidate, 'Frameshift.app');
  mkdirSync(candidate, { mode: 0o700 });
  for (const name of ['Headers', 'Modules', 'PrivateHeaders', 'Resources', 'Updater.app', 'XPCServices']) mkdirSync(join(app, sparkleRoot, 'Versions/B', name), { recursive: true });
  for (const name of ['Sparkle', 'Autoupdate']) writeFileSync(join(app, sparkleRoot, 'Versions/B', name), `Parser fixture ${name}`, { mode: 0o644 });
  for (const [path, target] of sparkleLinks) symlinkSync(target, join(app, path));
  const path = join(root, 'macos.tar');
  execFileSync('tar', ['--format=ustar', '-cf', path, '-C', root, 'macos-candidate'], { env: { ...process.env, COPYFILE_DISABLE: '1' }, timeout: 5000 });
  chmodSync(path, 0o600); const bytes = readFileSync(path), archive = openArchive(path, hash(bytes), 'macos-candidate');
  const entries = archive.entries; closeSync(archive.fd);
  return { root, path, bytes, entries };
}
function field(header, offset, length, value) { header.fill(0, offset, offset + length); header.write(value, offset, length, 'utf8'); }
function checksum(header) {
  header.fill(32, 148, 156);
  header.write(header.reduce((sum, byte) => sum + byte, 0).toString(8).padStart(6, '0') + '\0 ', 148, 8, 'ascii');
}
function refusal(f, bytes, pattern) {
  writeFileSync(f.path, bytes); assert.throws(() => openArchive(f.path, hash(bytes), 'macos-candidate'), pattern);
}

test('actual USTAR preserves only the complete framework aliases and public replay leaves their inodes unchanged', t => {
  const f = fixture(t), archive = openArchive(f.path, hash(f.bytes), 'macos-candidate');
  try {
    const output = join(f.root, 'received'); mkdirSync(output, { mode: 0o700 });
    extractArchive(archive, output); verifyExtractedArchive(archive, output);
    const links = archive.entries.filter(entry => entry.link !== undefined); assert.equal(links.length, 9);
    const identities = links.map(entry => lstatSync(join(output, entry.path), { bigint: true }).ino);
    for (const entry of links) { assert.equal(readlinkSync(join(output, entry.path)), entry.link); assert.equal(lstatSync(join(output, entry.path)).isSymbolicLink(), true); }
    verifyExtractedArchive(archive, output);
    assert.deepEqual(links.map(entry => lstatSync(join(output, entry.path), { bigint: true }).ino), identities);
    const path = join(output, links[0].path); rmSync(path); symlinkSync('/tmp', path);
    assert.throws(() => verifyExtractedArchive(archive, output), /link custody changed/);
    assert.equal(readlinkSync(path), '/tmp');
  } finally { closeSync(archive.fd); }
});

test('retargeted, absolute, cyclic, extra, special-mode and nonzero-payload links refuse before extraction', t => {
  const f = fixture(t), link = f.entries.find(entry => entry.link !== undefined);
  const mutations = [
    ...['/tmp', '..', 'Versions/Current/other', 'Resources', 'Versions/B/Resources'].map(target => header => field(header, 157, 100, target)),
    header => field(header, 0, 100, 'macos-candidate/Frameshift.app/Contents/Resources/alias'),
    header => field(header, 100, 8, '0001777'), header => field(header, 124, 12, '1'),
    header => { header[156] = 49; },
  ];
  for (const change of mutations) {
    const bytes = Buffer.from(f.bytes), header = bytes.subarray(link.offset - 512, link.offset); change(header); checksum(header);
    refusal(f, bytes);
  }
});

test('partial or dangling link sets and any archive member under an alias refuse during preflight', t => {
  const f = fixture(t), link = f.entries.find(entry => entry.link !== undefined);
  refusal(f, Buffer.concat([f.bytes.subarray(0, link.offset - 512), f.bytes.subarray(link.offset)]), /incomplete framework/);
  const terminal = f.entries.find(entry => entry.path.endsWith('/Versions/B/Headers'));
  refusal(f, Buffer.concat([f.bytes.subarray(0, terminal.offset - 512), f.bytes.subarray(terminal.offset)]), /dangling framework/);
  const header = Buffer.from(f.bytes.subarray(link.offset - 512, link.offset));
  field(header, 0, 100, 'macos-candidate/Frameshift.app/Contents/Frameworks/Sparkle.framework/Resources/child');
  field(header, 157, 100, ''); field(header, 100, 8, '0000644'); header[156] = 48; checksum(header);
  refusal(f, Buffer.concat([f.bytes.subarray(0, 512), header, f.bytes.subarray(512)]), /parent directory/);
});

test('Ubuntu and material profiles refuse symbolic aliases even with otherwise valid paths and transport digests', t => {
  const f = fixture(t), rootHeader = Buffer.from(f.bytes.subarray(0, 512));
  const source = f.entries.find(entry => entry.link !== undefined);
  for (const root of ['ubuntu-candidate', 'ubuntu-material', 'macos-material']) {
    const linkHeader = Buffer.from(f.bytes.subarray(source.offset - 512, source.offset));
    field(rootHeader, 0, 100, root + '/'); checksum(rootHeader);
    field(linkHeader, 0, 100, root + '/alias'); checksum(linkHeader);
    const bytes = Buffer.concat([rootHeader, linkHeader, Buffer.alloc(1024)]); writeFileSync(f.path, bytes);
    assert.throws(() => openArchive(f.path, hash(bytes), root), /regular files and directories/);
  }
});
