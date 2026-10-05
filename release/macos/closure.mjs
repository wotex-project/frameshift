import { createHash } from 'node:crypto';
import { spawnSync } from 'node:child_process';
import { lstat, readdir } from 'node:fs/promises';
import { join, posix, resolve } from 'node:path';
import { readReleaseInput, withReleaseInput } from '../files.mjs';

const limits = { entries: 8192, file: 128 * 1024 * 1024, total: 512 * 1024 * 1024, native: 128, commands: 1024 * 1024 };
const fail = message => { throw new Error(message); };
const identity = stat => ['dev', 'ino', 'size', 'mode', 'uid', 'gid', 'nlink', 'mtimeNs', 'ctimeNs'].map(key => String(stat[key]));
const version = value => `${value >>> 16}.${(value >>> 8) & 255}.${value & 255}`;
export const versionNumber = value => {
  if (typeof value !== 'string' || !/^(0|[1-9][0-9]{0,4})\.(0|[1-9][0-9]{0,2})(?:\.(0|[1-9][0-9]{0,2}))?$/.test(value)) fail('invalid macOS version');
  const [major, minor, patch = 0] = value.split('.').map(Number);
  if (major < 10 || major > 65535 || minor > 255 || patch > 255) fail('invalid macOS version');
  return major * 65536 + minor * 256 + patch;
};
const magic = bytes => bytes.length < 4 ? 0 : bytes.readUInt32BE(0);
const nativeMagic = new Set([0xcffaedfe, 0xfeedfacf, 0xcefaedfe, 0xfeedface, 0xcafebabe, 0xcafebabf, 0xbebafeca, 0xbfbafeca]);
const safeMode = stat => { if ((stat.mode & 0o7022n) !== 0n) fail('unsafe bundle mode'); };

async function inventory(root, budget) {
  const files = [], directories = [];
  let entries = 0, total = 0;
  async function visit(relative, depth) {
    budget();
    if (++entries > limits.entries || depth > 32 || Buffer.byteLength(relative) > 512 || /[\u0000-\u001f\u007f]/.test(relative)) fail('bundle inventory limit');
    const path = relative ? join(root, relative) : root;
    const before = await lstat(path, { bigint: true });
    safeMode(before);
    if (before.isDirectory()) {
      const names = (await readdir(path)).sort();
      for (const name of names) await visit(relative ? `${relative}/${name}` : name, depth + 1);
      const after = await lstat(path, { bigint: true });
      if (!after.isDirectory() || JSON.stringify(identity(before)) !== JSON.stringify(identity(after))) fail('bundle directory changed');
      directories.push({ path: relative, identity: identity(after) });
    } else if (before.isFile()) {
      if (before.nlink !== 1n) fail('bundle hard links unavailable');
      if (before.size > BigInt(limits.file) || (total += Number(before.size)) > limits.total) fail('bundle byte limit');
      const result = await withReleaseInput(path, { minimum: 0, maximum: limits.file }, async (handle, size) => {
        const block = Buffer.alloc(64 * 1024), hash = createHash('sha256');
        let offset = 0, prefix = Buffer.alloc(0);
        while (offset < size) {
          budget();
          const { bytesRead } = await handle.read(block, 0, Math.min(block.length, size - offset), offset);
          if (!bytesRead) fail('bundle file changed');
          if (offset === 0) prefix = Buffer.from(block.subarray(0, Math.min(8, bytesRead)));
          hash.update(block.subarray(0, bytesRead)); offset += bytesRead;
        }
        if ((await handle.read(block, 0, 1, size)).bytesRead) fail('bundle file grew');
        return { bytes: size, sha256: hash.digest('hex'), native: nativeMagic.has(magic(prefix)) };
      });
      const after = await lstat(path, { bigint: true });
      if (JSON.stringify(identity(before)) !== JSON.stringify(identity(after))) fail('bundle file changed');
      files.push({ path: relative, mode: Number(after.mode & 0o7777n), ...result, identity: identity(after) });
    } else fail('bundle links and special files unavailable');
  }
  await visit('', 0);
  return { files, directories };
}

const cpu = (type, subtype) => {
  if (type === 0x0100000c && subtype === 0) return 'arm64';
  if (type === 0x01000007 && (subtype === 3 || subtype === 0x80000003)) return 'x86_64';
  return fail('unsupported native CPU subtype');
};
const imports = new Set([0xc, 0x80000018, 0x8000001f, 0x20, 0x80000023]);
const unavailableLoads = new Set([0x6, 0x7, 0xf, 0x25, 0x27, 0x2f, 0x30, 0x80000035]);

// Parse the loader metadata, not instructions, symbols, signatures or dyld's
// runtime run-path stack. Limits apply before allocating a command region.
export async function inspectMachO(path, budget = () => {}) {
  return withReleaseInput(path, { maximum: limits.file }, async (handle, size) => {
    const read = async (offset, count) => {
      budget();
      if (!Number.isSafeInteger(offset) || count < 0 || count > limits.commands || offset < 0 || offset + count > size) fail('invalid native region');
      const bytes = Buffer.alloc(count);
      for (let position = 0; position < count;) {
        budget();
        const { bytesRead } = await handle.read(bytes, position, Math.min(64 * 1024, count - position), offset + position);
        if (!bytesRead) fail('truncated native region');
        position += bytesRead;
      }
      return bytes;
    };
    const first = await read(0, 8), marker = magic(first);
    let regions = [{ offset: 0, size }];
    if ([0xcafebabe, 0xcafebabf].includes(marker)) {
      const count = first.readUInt32BE(4), width = marker === 0xcafebabe ? 20 : 32;
      if (count < 1 || count > 2) fail('unsupported fat CPU count');
      const table = await read(8, count * width);
      regions = Array.from({ length: count }, (_, index) => {
        const start = index * width, type = table.readUInt32BE(start), subtype = table.readUInt32BE(start + 4);
        const offset = width === 20 ? table.readUInt32BE(start + 8) : Number(table.readBigUInt64BE(start + 8));
        const length = width === 20 ? table.readUInt32BE(start + 12) : Number(table.readBigUInt64BE(start + 16));
        const alignment = table.readUInt32BE(start + (width === 20 ? 16 : 24));
        if (!Number.isSafeInteger(offset) || !Number.isSafeInteger(length) || offset < 8 + count * width || length < 32 || offset + length > size || alignment > 30 || offset % (2 ** alignment) || (width === 32 && table.readUInt32BE(start + 28))) fail('invalid fat region');
        return { offset, size: length, type, subtype, arch: cpu(type, subtype) };
      });
      const ordered = regions.toSorted((a, b) => a.offset - b.offset);
      if (new Set(regions.map(item => item.arch)).size !== count || ordered.some((item, index) => index && ordered[index - 1].offset + ordered[index - 1].size > item.offset)) fail('overlapping or duplicate fat CPU');
    } else if (marker !== 0xcffaedfe) fail('unsupported native header');
    const slices = [];
    for (const region of regions) {
      const header = await read(region.offset, 32);
      if (magic(header) !== 0xcffaedfe) fail('unsupported native header');
      const type = header.readUInt32LE(4), subtype = header.readUInt32LE(8), arch = cpu(type, subtype), filetype = header.readUInt32LE(12);
      const count = header.readUInt32LE(16), length = header.readUInt32LE(20);
      if (![2, 6, 8].includes(filetype) || count < 1 || count > 4096 || length > limits.commands || length < count * 8 || length + 32 > region.size || (region.arch && (region.type !== type || region.subtype !== subtype))) fail('invalid native header');
      const commands = await read(region.offset + 32, length);
      const dependencies = [], rpaths = [];
      let minimum, offset = 0;
      for (let index = 0; index < count; index++) {
        if (offset + 8 > commands.length) fail('invalid load command');
        const command = commands.readUInt32LE(offset), size = commands.readUInt32LE(offset + 4);
        if (size < 8 || size % 8 || offset + size > commands.length) fail('invalid load command');
        const body = commands.subarray(offset, offset + size);
        const string = base => {
          if (size < base) fail('invalid loader string');
          const start = body.readUInt32LE(8), end = body.indexOf(0, start);
          if (start < base || start >= size || end < start) fail('invalid loader string');
          const value = new TextDecoder('utf-8', { fatal: true }).decode(body.subarray(start, end));
          if (!value || Buffer.byteLength(value) > 512 || /[\u0000-\u001f\u007f]/.test(value)) fail('invalid loader string');
          return value;
        };
        if (imports.has(command)) dependencies.push(string(24));
        else if (command === 0x8000001c) rpaths.push(string(12));
        else if (command === 0xe && string(12) !== '/usr/lib/dyld') fail('outside dynamic linker');
        else if (unavailableLoads.has(command)) fail('unsupported native loader command');
        else if (command === 0x32 || command === 0x24) {
          if (minimum !== undefined || (command === 0x24 && size !== 16) || (command === 0x32 && (size < 24 || body.readUInt32LE(8) !== 1 || body.readUInt32LE(20) > 32 || size !== 24 + body.readUInt32LE(20) * 8))) fail('unsupported native deployment command');
          minimum = body.readUInt32LE(command === 0x32 ? 12 : 8);
          versionNumber(version(minimum));
        }
        offset += size;
      }
      if (offset !== length || minimum === undefined) fail('missing or conflicting native deployment');
      slices.push({ arch, filetype, minimum: version(minimum), dependencies, rpaths });
    }
    return slices.toSorted((a, b) => a.arch.localeCompare(b.arch));
  });
}

const applePath = value => ['/usr/lib/', '/System/Library/'].some(prefix => value.startsWith(prefix)) && posix.normalize(value) === value;
const localPath = (source, slice, value) => {
  let suffix;
  if (value === '@loader_path') suffix = '';
  else if (value.startsWith('@loader_path/')) suffix = value.slice(13);
  else if (value === '@executable_path' && slice.filetype === 2) suffix = '';
  else if (value.startsWith('@executable_path/') && slice.filetype === 2) suffix = value.slice(17);
  else fail('unsupported or outside loader path');
  const target = posix.normalize(posix.join(posix.dirname(source), suffix));
  if (target === '..' || target.startsWith('../') || target.startsWith('/')) fail('outside loader path');
  return target;
};

export async function auditMacBundle(input, architecture, { enforceMinimum = true, enforcePaths = true } = {}) {
  if (!['arm64', 'x86_64', 'universal'].includes(architecture)) fail('unsupported bundle architecture');
  const root = resolve(input), deadline = performance.now() + 120_000;
  const budget = () => { if (performance.now() > deadline) fail('bundle processing deadline'); };
  const before = await inventory(root, budget), natives = [];
  for (const file of before.files.filter(file => file.native)) {
    if (natives.length >= limits.native) fail('native inventory limit');
    const slices = await inspectMachO(join(root, file.path), budget);
    const expected = architecture === 'universal' ? ['arm64', 'x86_64'] : [architecture];
    if (expected.some(arch => !slices.some(slice => slice.arch === arch))) fail('missing bundle CPU');
    if (slices.some(slice => slice.filetype === 2) && !(file.mode & 0o111)) fail('native executable mode missing');
    natives.push({ path: file.path, sha256: file.sha256, mode: file.mode, slices });
  }
  const roles = [
    [/^Contents\/MacOS\/Frameshift$/, 2], [/^Contents\/MacOS\/frameshiftctl$/, 2],
    [/^Contents\/Resources\/bin\/frameshift-raster$/, 2], [/^Contents\/Resources\/core\/erts-[^/]+\/bin\/beam\.smp$/, 2],
    [/^Contents\/Resources\/core\/lib\/exqlite-[^/]+\/priv\/sqlite3_nif\.so$/, 6],
    [/^Contents\/Resources\/core\/lib\/exile-[^/]+\/priv\/exile\.so$/, 6],
    [/^Contents\/Resources\/core\/lib\/exile-[^/]+\/priv\/spawner$/, 2],
  ];
  for (const [pattern, type] of roles) {
    const found = natives.filter(file => pattern.test(file.path));
    if (found.length !== 1 || found[0].slices.some(slice => slice.filetype !== type)) fail('missing or ambiguous required native role');
  }
  if (enforcePaths) {
    const byPath = new Map(natives.map(file => [file.path, file]));
    const directories = new Set(before.directories.map(directory => directory.path));
    for (const file of natives) for (const slice of file.slices) {
      for (const path of slice.rpaths) if (!applePath(path) && !directories.has(localPath(file.path, slice, path))) fail('missing loader directory');
      for (const path of slice.dependencies) {
        if (applePath(path)) continue;
        const target = byPath.get(localPath(file.path, slice, path));
        if (!target?.slices.some(candidate => candidate.arch === slice.arch && candidate.filetype === 6)) fail('missing bundled dylib');
      }
    }
  }
  const plist = join(root, 'Contents/Info.plist');
  const bytes = await readReleaseInput(plist, { maximum: 64 * 1024 });
  const parsed = spawnSync('/usr/bin/plutil', ['-convert', 'json', '-o', '-', '--', '-'], { input: bytes, encoding: 'utf8', timeout: 15_000, maxBuffer: 256 * 1024 });
  budget();
  if (parsed.error || parsed.status !== 0) fail('invalid bundle plist');
  let info;
  try { info = JSON.parse(parsed.stdout); } catch { fail('invalid bundle plist'); }
  if (info.CFBundleExecutable !== 'Frameshift' || typeof info.LSMinimumSystemVersion !== 'string') fail('unsupported bundle declaration');
  const declared = info.LSMinimumSystemVersion, minimum = Math.max(...natives.flatMap(file => file.slices.map(slice => versionNumber(slice.minimum))));
  if (enforceMinimum && versionNumber(declared) < minimum) fail('bundle understates minimum macOS');
  versionNumber(declared);
  const after = await inventory(root, budget);
  if (JSON.stringify(before) !== JSON.stringify(after)) fail('bundle changed during inspection');
  return { schemaVersion: 1, publicationAuthority: 'none', architecture, declaredMinimum: declared, nativeMinimum: version(minimum), files: before.files.map(({ identity, native, ...file }) => file), natives };
}
