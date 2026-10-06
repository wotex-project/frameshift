import { createHash } from 'node:crypto';
import { constants, closeSync, fstatSync, fsyncSync, lstatSync, openSync, readSync, readdirSync } from 'node:fs';
import { join } from 'node:path';

export const sha256 = bytes => createHash('sha256').update(bytes).digest('hex');
export const gleamHashes = {
  arm64: 'ea08a64846677f36da7f2e9163c4393dd9a9dee814d13a8fb28fbe7dcbf32f6d',
  amd64: '4955a38c2e8c99457458e2471472ccd5ee3c45bd7637a315ce33bccf0dd75d9e',
};
export const images = {
  build: 'sha256:52ec0f335b9084bcfc0ce3a29b4c0288dc2fc2a07658ff809dc7d07589212cde',
  rust: 'sha256:b1b3c9c0d921d7fa0a6d1f9ec7e4eab87f8c8ec97644c3d791450f131dec813f',
  runtime: 'sha256:534baea6a22c03a63003dbc8dbe78fe34bc0d7e595d9a9dc9834884ff530eb55',
};

export function inventory(root, names = readdirSync(root).sort(), synchronize = false) {
  const files = [];
  const block = Buffer.alloc(64 * 1024);
  function visit(path) {
    if (/[\u0000-\u001f\u007f]/.test(path) || path.split('/').some(part => !part || part === '.' || part === '..')) {
      throw new Error('unsafe material path');
    }
    const full = join(root, path);
    const named = lstatSync(full, { bigint: true });
    if (named.isDirectory()) {
      for (const name of readdirSync(full).sort()) visit(`${path}/${name}`);
      if (synchronize) {
        const fd = openSync(full, constants.O_RDONLY | constants.O_DIRECTORY | constants.O_NOFOLLOW);
        try { fsyncSync(fd); } finally { closeSync(fd); }
      }
    } else if (named.isFile()) {
      const fd = openSync(full, constants.O_RDONLY | constants.O_NOFOLLOW | constants.O_NONBLOCK);
      try {
        const before = fstatSync(fd, { bigint: true });
        if (!before.isFile() || before.size > 512n * 1024n * 1024n || before.dev !== named.dev || before.ino !== named.ino) {
          throw new Error('unsafe material file');
        }
        const hash = createHash('sha256');
        let bytes = 0;
        let count;
        while ((count = readSync(fd, block)) !== 0) {
          bytes += count;
          if (BigInt(bytes) > before.size) throw new Error('material grew while reading');
          hash.update(block.subarray(0, count));
        }
        const after = fstatSync(fd, { bigint: true });
        const final = lstatSync(full, { bigint: true });
        if (BigInt(bytes) !== before.size || !final.isFile() ||
            ['dev', 'ino', 'size', 'mode', 'mtimeNs', 'ctimeNs'].some(key => before[key] !== after[key] || after[key] !== final[key])) {
          throw new Error('material changed while reading');
        }
        files.push({ path, mode: Number(before.mode & 0o7777n), bytes, sha256: hash.digest('hex') });
        if (files.length > 65_536) throw new Error('material inventory too large');
        if (synchronize) fsyncSync(fd);
      } finally { closeSync(fd); }
    } else {
      throw new Error('material must be regular files/directories');
    }
  }
  for (const name of names) visit(name);
  return files;
}

export const contextNames = ['apps', 'packages', 'protocol', 'codec', 'linux', 'mix-archives', 'gleam', 'frameshift-raster'];

export function assertSourceMaterial(source, material) {
  const selected = new Map();
  for (const file of source.files) {
    let path = file.path;
    if (/^release\/linux\//.test(path)) path = path.replace(/^release\//, '');
    else if (!/^apps\/core\/(?:lib\/|config\/|rel\/|mix\.(?:exs|lock)$)/.test(path) &&
             !/^packages\/decision-kernel\/(?!build\/)/.test(path) &&
             !/^(?:protocol\/|codec\/(?!target\/))/.test(path)) continue;
    selected.set(path, file);
  }
  const seen = new Set();
  for (const file of material) {
    if (/^(?:apps\/core\/deps\/|packages\/decision-kernel\/build\/packages\/|mix-archives\/)/.test(file.path) ||
        ['gleam', 'frameshift-raster'].includes(file.path)) continue;
    const expected = selected.get(file.path);
    if (!expected || expected.sha256 !== file.sha256 || expected.bytes !== file.bytes ||
        file.mode !== (expected.mode === '100755' ? 0o755 : 0o644)) throw new Error('prepared project material differs from source');
    seen.add(file.path);
  }
  if (seen.size !== selected.size) throw new Error('prepared project material is incomplete');
}
