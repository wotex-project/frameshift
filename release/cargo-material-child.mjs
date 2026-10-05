import { createHash } from 'node:crypto';
import { readSync } from 'node:fs';
import { dirname } from 'node:path';
import { gunzipSync } from 'node:zlib';

const hash = value => createHash('sha256').update(value).digest('hex');
const fail = () => { throw new Error('unsupported crate archive'); };
const zero = bytes => bytes.every(byte => byte === 0);
const safe = path => typeof path === 'string' && Buffer.byteLength(path) <= 512 && path.split('/').length <= 32 && !/[\u0000-\u001f\u007f\\]/.test(path) && path.split('/').every(part => part && part !== '.' && part !== '..');
const decode = bytes => new TextDecoder('utf-8', { fatal: true }).decode(bytes);
function text(bytes) { const end = bytes.indexOf(0); if (end !== -1 && !zero(bytes.subarray(end))) fail(); return decode(end === -1 ? bytes : bytes.subarray(0, end)); }
function octal(bytes) { const value = bytes.toString('ascii').replace(/^[ ]+|[\0 ]+$/g, ''); if (!/^[0-7]{1,12}$/.test(value) || bytes.some(byte => byte > 127)) fail(); return Number.parseInt(value, 8); }
function readInput() {
  const chunks = [], block = Buffer.alloc(64 * 1024); let size = 0;
  for (;;) { const n = readSync(0, block, 0, block.length, null); if (!n) break; size += n; if (size > 64 * 1024 * 1024) fail(); chunks.push(Buffer.from(block.subarray(0, n))); }
  if (!size) fail(); return Buffer.concat(chunks, size);
}
function inspect(raw, name, version, expected) {
  if (process.version !== 'v26.9.0' || !/^[A-Za-z][A-Za-z0-9_-]{0,127}$/.test(name) || !/^[0-9]+\.[0-9]+\.[0-9]+(?:[-+][A-Za-z0-9.+-]+)?$/.test(version) || version.length > 128 || !/^[0-9a-f]{64}$/.test(expected) || hash(raw) !== expected) fail();
  const tar = gunzipSync(raw, { maxOutputLength: 128 * 1024 * 1024 }), root = name + '-' + version, files = [], directories = [], names = new Set(), kinds = new Map(); let position = 0, finished = false, manifest;
  if (tar.length < 1024 || tar.length % 512) fail();
  while (position + 512 <= tar.length) {
    const h = tar.subarray(position, position + 512);
    if (zero(h)) { if (tar.length - position < 1024 || !zero(tar.subarray(position + 512))) fail(); finished = true; break; }
    const checksum = h.reduce((n, byte, i) => n + (i >= 148 && i < 156 ? 32 : byte), 0), magic = h.subarray(257, 265);
    const posix = magic.equals(Buffer.from('ustar\0' + '00', 'ascii')), gnu = magic.equals(Buffer.from('ustar  \0', 'ascii'));
    if (octal(h.subarray(148, 156)) !== checksum || (!posix && !gnu) || text(h.subarray(157, 257)) !== '' || !zero(h.subarray(500)) || (gnu && !zero(h.subarray(345)))) fail();
    const type = h[156]; if (![0, 48, 53].includes(type)) fail(); const directory = type === 53;
    const prefix = posix ? text(h.subarray(345, 500)) : '', base = text(h.subarray(0, 100)); let path = prefix ? prefix + '/' + base : base;
    if (directory && path.endsWith('/')) path = path.slice(0, -1);
    if (!safe(path) || !(path === root || path.startsWith(root + '/')) || names.has(path) || path.split('/').includes('.cargo-ok') || (path === root && !directory)) fail();
    const mode = octal(h.subarray(100, 108)), bytes = octal(h.subarray(124, 136));
    for (const [a, b] of [[108, 116], [116, 124]]) if (!zero(h.subarray(a, b))) octal(h.subarray(a, b));
    octal(h.subarray(136, 148));
    for (const at of [329, 337]) if (!zero(h.subarray(at, at + 8))) octal(h.subarray(at, at + 8));
    if (mode > 0o777 || (mode & 0o022) || !(mode & 0o400) || (directory && (!(mode & 0o100) || bytes)) || bytes > 128 * 1024 * 1024) fail();
    const padded = Math.ceil(bytes / 512) * 512;
    if (position + 512 + padded > tar.length || !zero(tar.subarray(position + 512 + bytes, position + 512 + padded))) fail();
    names.add(path); kinds.set(path, directory); if (names.size > 8192) fail();
    const relative = path === root ? '' : path.slice(root.length + 1);
    if (directory) directories.push({ path: relative, mode });
    else {
      const data = tar.subarray(position + 512, position + 512 + bytes); files.push({ path: relative, mode, bytes, sha256: hash(data) });
      if (relative === 'Cargo.toml') { if (bytes > 64 * 1024) fail(); manifest = data; }
    }
    position += 512 + padded;
  }
  if (!finished || !files.length || !manifest) fail();
  for (const path of names) { let parent = dirname(path); while (parent !== '.') { if (kinds.get(parent) === false) fail(); parent = dirname(parent); } }
  const content = decode(manifest), start = content.indexOf('[package]\n');
  if (start < 0 || content.slice(0, start).split('\n').some(line => line.trim() && !line.trim().startsWith('#')) || content.split('\n').filter(line => line === '[package]').length !== 1) fail();
  const identity = /^\[package\]\n(?:edition = "[0-9]+"\n)?(?:rust-version = "[0-9]+\.[0-9]+(?:\.[0-9]+)?"\n)?name = "([A-Za-z][A-Za-z0-9_-]{0,127})"\nversion = "([^"\n\\]{1,128})"\n/.exec(content.slice(start));
  if (!identity || identity[1] !== name || identity[2] !== version) fail();
  const byPath = (a, b) => a.path < b.path ? -1 : a.path > b.path ? 1 : 0;
  return { runtime: { node: process.version, zlib: process.versions.zlib }, files: files.sort(byPath), directories: directories.sort(byPath) };
}
const [name, version, expected, ...extra] = process.argv.slice(2);
if (extra.length) fail();
process.stdout.write(JSON.stringify(inspect(readInput(), name, version, expected)) + '\n');
