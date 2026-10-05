import { createHash } from 'node:crypto';
import { execFileSync } from 'node:child_process';
import { constants, closeSync, fstatSync, fsyncSync, lstatSync, mkdirSync, openSync, readFileSync, readdirSync, realpathSync, writeFileSync } from 'node:fs';
import { lstat, open } from 'node:fs/promises';
import { basename, dirname, join, resolve, sep } from 'node:path';
import { releaseGit, releaseSourceIdentity } from './source.mjs';

const git = releaseGit;

function entries(repository) {
  const tree = git(repository, ['ls-tree', '-r', '-z', '--full-tree', 'HEAD']).split('\0').filter(Boolean);
  const index = git(repository, ['ls-files', '--stage', '-z']).split('\0').filter(Boolean);
  const entries = tree.map(entry => {
    const match = /^(100644|100755) blob ([0-9a-f]{40})\t(.+)$/.exec(entry);
    if (!match) throw new Error('unsupported tracked source entry');
    const [, mode, blob, path] = match;
    if (path.startsWith('/') || path.split('/').some(part => !part || part === '.' || part === '..') || /[\u0000-\u001f\u007f]/.test(path)) {
      throw new Error('unsafe tracked source path');
    }
    return { path, mode, blob };
  });
  if (index.length !== entries.length || index.some((entry, i) => entry !== `${entries[i].mode} ${entries[i].blob} 0\t${entries[i].path}`)) {
    throw new Error('source index differs from the committed tree');
  }
  return entries;
}

async function fileFacts(repository, entry) {
  const path = join(repository, entry.path);
  if (!(await lstat(path)).isFile()) throw new Error('source input must be a regular file');
  const handle = await open(path, constants.O_RDONLY | constants.O_NOFOLLOW | constants.O_NONBLOCK);
  try {
    const before = await handle.stat({ bigint: true });
    const mode = entry.mode === '100755' ? 0o755n : 0o644n;
    if (!before.isFile() || (before.mode & 0o7777n) !== mode) throw new Error('source mode/type differs from Git');
    const sha = createHash('sha256');
    const blob = createHash('sha1').update(`blob ${before.size}\0`);
    let count = 0n;
    for await (const chunk of handle.createReadStream({ autoClose: false, highWaterMark: 64 * 1024 })) {
      count += BigInt(chunk.length);
      if (count > before.size) throw new Error('source grew while reading');
      sha.update(chunk); blob.update(chunk);
    }
    const after = await handle.stat({ bigint: true });
    const named = await lstat(path, { bigint: true });
    if (count !== before.size || before.size > BigInt(Number.MAX_SAFE_INTEGER) || !named.isFile() ||
        ['dev', 'ino', 'size', 'mode', 'mtimeNs', 'ctimeNs'].some(key => before[key] !== after[key] || after[key] !== named[key]) ||
        blob.digest('hex') !== entry.blob) throw new Error('source bytes changed or differ from Git');
    return { ...entry, bytes: Number(before.size), sha256: sha.digest('hex') };
  } finally {
    await handle.close();
  }
}

function applicationVersion(repository) {
  const output = execFileSync('mise', ['exec', '--', 'elixir', join(repository, 'release/read-version.exs'), join(repository, 'apps/core')],
    { cwd: repository, timeout: 60_000, maxBuffer: 64 * 1024, encoding: 'utf8', stdio: ['ignore', 'pipe', 'pipe'] });
  const matches = [...output.matchAll(/^frameshift-release-version:([^\r\n]+)$/gm)];
  if (matches.length !== 1) throw new Error('application version unavailable');
  return matches[0][1];
}

export async function captureInputs(repository, tag, commit) {
  repository = realpathSync(repository);
  const identity = releaseSourceIdentity(repository, tag, commit);
  const tracked = entries(repository);
  const files = [];
  for (const entry of tracked) files.push(await fileFacts(repository, entry));
  for (const path of ['.mise.toml', 'apps/core/mix.exs', 'release/read-version.exs']) {
    if (!files.some(file => file.path === path)) throw new Error('required source input missing');
  }
  if (applicationVersion(repository) !== identity.version) throw new Error('application version differs from release tag');
  const record = { schemaVersion: 1, kind: 'release-source-inputs', product: 'io.frameshift.app',
    tag, version: identity.version, commit, tree: git(repository, ['rev-parse', 'HEAD^{tree}']).trim(),
    publicationAuthority: 'none', toolchainInput: '.mise.toml',
    dependencyLocks: files.map(file => file.path).filter(path => /(?:^|\/)(?:mix\.lock|Cargo\.lock|Package\.resolved|package-lock\.json|manifest\.toml)$/.test(path)),
    files };
  if (JSON.stringify(entries(repository)) !== JSON.stringify(tracked) ||
      JSON.stringify(releaseSourceIdentity(repository, tag, commit)) !== JSON.stringify(identity) ||
      applicationVersion(repository) !== identity.version) throw new Error('source identity changed during capture');
  return record;
}

const encoded = record => {
  const bytes = JSON.stringify(record) + '\n';
  if (Buffer.byteLength(bytes) > 8 * 1024 * 1024) throw new Error('source input record too large');
  return bytes;
};
function sameCapture(before, after) {
  if (encoded(before) !== encoded(after)) throw new Error('source inputs changed during work');
}

function ownedDirectory(path, privateMode = false) {
  const stat = lstatSync(path);
  if (!stat.isDirectory() || stat.uid !== process.getuid() ||
      (privateMode ? (stat.mode & 0o7777) !== 0o700 : (stat.mode & 0o022) !== 0)) throw new Error('unsafe source record directory');
}

function readRecord(path) {
  if (!lstatSync(path).isFile()) throw new Error('unsafe source input record');
  const fd = openSync(path, constants.O_RDONLY | constants.O_NOFOLLOW | constants.O_NONBLOCK);
  try {
    const stat = fstatSync(fd, { bigint: true });
    if (!stat.isFile() || stat.uid !== BigInt(process.getuid()) || (stat.mode & 0o7777n) !== 0o600n || stat.size > 8n * 1024n * 1024n) {
      throw new Error('unsafe source input record');
    }
    const bytes = readFileSync(fd, 'utf8');
    const after = fstatSync(fd, { bigint: true });
    const named = lstatSync(path, { bigint: true });
    if (['dev', 'ino', 'size', 'mode', 'mtimeNs', 'ctimeNs'].some(key => stat[key] !== after[key] || after[key] !== named[key])) {
      throw new Error('source input record changed while reading');
    }
    return bytes;
  } finally { closeSync(fd); }
}

function syncDirectory(path) {
  const fd = openSync(path, constants.O_RDONLY | constants.O_DIRECTORY | constants.O_NOFOLLOW);
  try { fsyncSync(fd); } finally { closeSync(fd); }
}

export async function recordInputs(repository, tag, commit, output) {
  repository = realpathSync(repository);
  output = resolve(output);
  const parent = dirname(output);
  ownedDirectory(parent);
  const physical = join(realpathSync(parent), basename(output));
  if ((physical === repository || physical.startsWith(repository + sep)) &&
      git(repository, ['check-ignore', '--no-index', physical]).length === 0) {
    throw new Error('source record must be outside tracked source');
  }
  const record = await captureInputs(repository, tag, commit);
  sameCapture(record, await captureInputs(repository, tag, commit));
  const path = join(output, 'source-inputs.json');
  try {
    lstatSync(output);
    ownedDirectory(output, true);
    if (readdirSync(output).join('\0') !== 'source-inputs.json' || readRecord(path) !== encoded(record)) {
      throw new Error('conflicting source input output');
    }
    const fd = openSync(path, constants.O_RDONLY | constants.O_NOFOLLOW);
    try { fsyncSync(fd); } finally { closeSync(fd); }
  } catch (error) {
    if (error.code !== 'ENOENT') throw error;
    // An existing incomplete directory is retained: exclusive mkdir refuses it.
    mkdirSync(output, { mode: 0o700 });
    const fd = openSync(path, constants.O_WRONLY | constants.O_CREAT | constants.O_EXCL | constants.O_NOFOLLOW, 0o600);
    try { writeFileSync(fd, encoded(record)); fsyncSync(fd); } finally { closeSync(fd); }
  }
  syncDirectory(output);
  syncDirectory(parent);
  return record;
}

export async function verifyInputs(repository, tag, commit, path) {
  ownedDirectory(dirname(resolve(path)), true);
  const previous = readRecord(path);
  const current = await captureInputs(repository, tag, commit);
  sameCapture(current, await captureInputs(repository, tag, commit));
  if (previous !== encoded(current)) throw new Error('source differs from frozen input record');
  return current;
}
