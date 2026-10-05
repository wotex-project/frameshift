import { createHash } from 'node:crypto';
import { constants, closeSync, fchmodSync, fstatSync, fsyncSync, lstatSync, mkdirSync, opendirSync, openSync, readSync, statfsSync, writeSync } from 'node:fs';
import { dirname, join } from 'node:path';

const archiveProfiles = {
  'ubuntu-candidate': { archive: 1024 * 1024 * 1024, file: 512 * 1024 * 1024, entries: 65_536 },
  'macos-candidate': { archive: 1024 * 1024 * 1024, file: 512 * 1024 * 1024, entries: 65_536 },
  'macos-material': { archive: 33 * 1024 * 1024, file: 16 * 1024 * 1024, entries: 4 }
};
const reserve = 128n * 1024n * 1024n;
const decoder = new TextDecoder('utf-8', { fatal: true });
const zero = bytes => bytes.every(byte => byte === 0);
const sameStat = (a, b) => ['dev', 'ino', 'size', 'mode', 'uid', 'gid', 'nlink', 'mtimeNs', 'ctimeNs'].every(key => a[key] === b[key]);

function read(fd, position, length) {
  const bytes = Buffer.alloc(length);
  let offset = 0;
  while (offset < length) {
    const count = readSync(fd, bytes, offset, length - offset, position + offset);
    if (count === 0) throw new Error('truncated USTAR');
    offset += count;
  }
  return bytes;
}

function text(bytes) {
  const end = bytes.indexOf(0);
  if (end !== -1 && !zero(bytes.subarray(end))) throw new Error('invalid USTAR string padding');
  return decoder.decode(end === -1 ? bytes : bytes.subarray(0, end));
}

function octal(bytes) {
  const value = bytes.toString('ascii').replace(/^[ ]+|[\0 ]+$/g, '');
  if (!/^[0-7]{1,12}$/.test(value) || bytes.some(byte => byte > 127)) throw new Error('invalid USTAR number');
  return Number.parseInt(value, 8);
}

function members(fd, size, deadline, root, profile) {
  const entries = [];
  const names = new Set();
  const directories = new Set();
  let position = 0;
  let payloadBytes = 0;
  while (position + 512 <= size) {
    if (performance.now() > deadline) throw new Error('USTAR processing deadline');
    const header = read(fd, position, 512);
    if (zero(header)) {
      if (size - position < 1024 || !zero(read(fd, position + 512, 512))) throw new Error('missing USTAR terminator');
      for (let offset = position + 1024; offset < size; offset += 64 * 1024) {
        if (performance.now() > deadline) throw new Error('USTAR processing deadline');
        if (!zero(read(fd, offset, Math.min(64 * 1024, size - offset)))) throw new Error('trailing USTAR material');
      }
      if (!names.has(root)) throw new Error('missing candidate root');
      for (const entry of entries) {
        if (entry.path !== root && !directories.has(dirname(entry.path))) {
          throw new Error('missing USTAR parent directory');
        }
      }
      return { entries, payloadBytes };
    }
    const checksum = header.reduce((sum, byte, offset) => sum + (offset >= 148 && offset < 156 ? 32 : byte), 0);
    if (octal(header.subarray(148, 156)) !== checksum || !header.subarray(257, 263).equals(Buffer.from('ustar\0', 'ascii')) ||
        !header.subarray(263, 265).equals(Buffer.from('00', 'ascii')) || !zero(header.subarray(500)) || text(header.subarray(157, 257)) !== '') {
      throw new Error('unsupported or corrupt USTAR header');
    }
    const type = header[156];
    if (![0, 48, 53].includes(type)) throw new Error('USTAR accepts only regular files and directories');
    const prefix = text(header.subarray(345, 500));
    const name = text(header.subarray(0, 100));
    let path = prefix ? `${prefix}/${name}` : name;
    const directory = type === 53;
    if (directory && path.endsWith('/')) path = path.slice(0, -1);
    if (/[\u0000-\u001f\u007f\\]/.test(path) || path.split('/').some(part => !part || part === '.' || part === '..') ||
        !(path === root || path.startsWith(root + '/')) || names.has(path)) throw new Error('unsafe or duplicate USTAR path');
    const mode = octal(header.subarray(100, 108));
    const bytes = octal(header.subarray(124, 136));
    for (const [start, end] of [[108, 116], [116, 124], [136, 148]]) octal(header.subarray(start, end));
    for (const start of [329, 337]) if (!zero(header.subarray(start, start + 8))) octal(header.subarray(start, start + 8));
    if (mode > 0o777 || (mode & 0o022) !== 0 || (mode & 0o400) === 0 ||
        (directory && ((mode & 0o500) !== 0o500 || bytes !== 0)) || (!directory && bytes > profile.file) ||
        (path === root && (!directory || mode !== 0o700))) throw new Error('unsafe USTAR mode or size');
    names.add(path);
    if (directory) directories.add(path);
    entries.push({ path, directory, mode, bytes, offset: position + 512 });
    if (entries.length > profile.entries) throw new Error('too many USTAR entries');
    payloadBytes += bytes;
    const padded = Math.ceil(bytes / 512) * 512;
    if (payloadBytes > profile.archive || position + 512 + padded > size ||
        !zero(read(fd, position + 512 + bytes, padded - bytes))) throw new Error('invalid USTAR payload or padding');
    position += 512 + padded;
  }
  throw new Error('missing USTAR terminator');
}

export function openArchive(path, expectedHash, root = 'ubuntu-candidate') {
  if (!Object.hasOwn(archiveProfiles, root)) throw new Error('unsupported release archive profile');
  const profile = archiveProfiles[root];
  if (typeof expectedHash !== 'string' || expectedHash.length !== 64 || !/^[0-9a-f]{64}$/.test(expectedHash)) throw new Error('invalid expected archive digest');
  const named = lstatSync(path, { bigint: true });
  if (!named.isFile()) throw new Error('archive must be a regular file');
  const fd = openSync(path, constants.O_RDONLY | constants.O_NOFOLLOW | constants.O_NONBLOCK);
  try {
    const before = fstatSync(fd, { bigint: true });
    if (!before.isFile() || before.uid !== BigInt(process.getuid()) || (before.mode & 0o022n) !== 0n ||
        before.size < 1024n || before.size > BigInt(profile.archive) || before.size % 512n !== 0n || !sameStat(before, named)) throw new Error('unsafe archive custody');
    const archive = { fd, path, before, expectedHash, deadline: performance.now() + 120_000 };
    verifyArchive(archive);
    return { ...archive, root, ...members(fd, Number(before.size), archive.deadline, root, profile) };
  } catch (error) { closeSync(fd); throw error; }
}

export function verifyArchive({ fd, path, before, expectedHash, deadline }) {
  const hash = createHash('sha256');
  const block = Buffer.alloc(64 * 1024);
  for (let position = 0; position < Number(before.size);) {
    if (performance.now() > deadline) throw new Error('archive processing deadline');
    const count = readSync(fd, block, 0, Math.min(block.length, Number(before.size) - position), position);
    if (count === 0) throw new Error('archive changed');
    hash.update(block.subarray(0, count));
    position += count;
  }
  if (hash.digest('hex') !== expectedHash || !sameStat(before, fstatSync(fd, { bigint: true })) ||
      !sameStat(before, lstatSync(path, { bigint: true }))) throw new Error('archive digest or custody changed');
}

export function availableSpace(parent, payloadBytes) {
  const { bavail, bsize } = statfsSync(parent, { bigint: true });
  if (bavail * bsize < BigInt(payloadBytes) + reserve) throw new Error('insufficient handoff space');
}

export function verifyExtractedArchive(archive, output) {
  const expected = new Map(archive.entries.map(entry => [entry.path, entry]));
  let observed = 0;
  for (const entry of archive.entries) {
    if (performance.now() > archive.deadline) throw new Error('archive processing deadline');
    const path = join(output, entry.path);
    const before = lstatSync(path, { bigint: true });
    if (before.uid !== BigInt(process.getuid()) || Number(before.mode & 0o7777n) !== entry.mode ||
        (entry.directory ? !before.isDirectory() : !before.isFile() || before.size !== BigInt(entry.bytes))) {
      throw new Error('extracted archive custody changed');
    }
    if (!entry.directory) {
      if (before.nlink !== 1n) throw new Error('extracted archive alias');
      const fd = openSync(path, constants.O_RDONLY | constants.O_NOFOLLOW | constants.O_NONBLOCK);
      try {
        if (!sameStat(before, fstatSync(fd, { bigint: true }))) throw new Error('extracted archive file changed');
        const block = Buffer.alloc(64 * 1024);
        for (let position = 0; position < entry.bytes;) {
          if (performance.now() > archive.deadline) throw new Error('archive processing deadline');
          const count = readSync(fd, block, 0, Math.min(block.length, entry.bytes - position), position);
          if (!count || !block.subarray(0, count).equals(read(archive.fd, entry.offset + position, count))) throw new Error('extracted archive bytes differ');
          position += count;
        }
        if (readSync(fd, block, 0, 1, entry.bytes) !== 0 || !sameStat(before, fstatSync(fd, { bigint: true })) || !sameStat(before, lstatSync(path, { bigint: true }))) throw new Error('extracted archive file custody changed');
      } finally { closeSync(fd); }
      continue;
    }
    const directory = opendirSync(path);
    try {
      let child;
      while ((child = directory.readSync()) !== null) {
        if (++observed > archive.entries.length || !expected.has(`${entry.path}/${child.name}`)) throw new Error('extracted archive names changed');
      }
    } finally { directory.closeSync(); }
    if (!sameStat(before, lstatSync(path, { bigint: true }))) throw new Error('extracted archive directory changed');
  }
  if (observed !== archive.entries.length - 1) throw new Error('extracted archive names changed');
}

export function extractArchive(archive, output) {
  const directories = archive.entries.filter(entry => entry.directory).sort((a, b) => a.path.split('/').length - b.path.split('/').length);
  for (const entry of directories) {
    if (performance.now() > archive.deadline) throw new Error('archive processing deadline');
    mkdirSync(join(output, entry.path), { mode: 0o700 });
  }
  for (const entry of archive.entries.filter(entry => !entry.directory)) {
    if (performance.now() > archive.deadline) throw new Error('archive processing deadline');
    const fd = openSync(join(output, entry.path), constants.O_WRONLY | constants.O_CREAT | constants.O_EXCL | constants.O_NOFOLLOW, 0o600);
    try {
      for (let position = 0; position < entry.bytes;) {
        if (performance.now() > archive.deadline) throw new Error('archive processing deadline');
        const block = read(archive.fd, entry.offset + position, Math.min(64 * 1024, entry.bytes - position));
        for (let offset = 0; offset < block.length;) {
          const count = writeSync(fd, block, offset, block.length - offset);
          if (count === 0) throw new Error('archive write stopped');
          offset += count;
        }
        position += block.length;
      }
      fchmodSync(fd, entry.mode);
      fsyncSync(fd);
    } finally { closeSync(fd); }
  }
  for (const entry of directories.reverse()) {
    if (performance.now() > archive.deadline) throw new Error('archive processing deadline');
    const fd = openSync(join(output, entry.path), constants.O_RDONLY | constants.O_DIRECTORY | constants.O_NOFOLLOW);
    try { fchmodSync(fd, entry.mode); fsyncSync(fd); } finally { closeSync(fd); }
  }
  verifyArchive(archive);
}
