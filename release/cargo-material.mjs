import { spawnSync } from 'node:child_process';
import { createHash } from 'node:crypto';
import { constants, closeSync, fstatSync, fsyncSync, lstatSync, mkdirSync, openSync, realpathSync, unlinkSync, writeFileSync } from 'node:fs';
import { basename, dirname, join, resolve, sep } from 'node:path';
import { isDeepStrictEqual as same } from 'node:util';
import { lockedSourceFacts } from './core-material.mjs';
import { readReleaseInput } from './files.mjs';
import { verifyInputs } from './inputs.mjs';
import { materialDirectoryNames, materialPath, validateCapturedFacts } from './material-receipts.mjs';
import { releaseGit } from './source.mjs';

const owner = resolve(new URL('..', import.meta.url).pathname), helper = join(owner, 'release/cargo-material-child.mjs');
const encode = value => Buffer.from(JSON.stringify(value) + '\n');
const hash = value => createHash('sha256').update(value).digest('hex');
const fail = message => { throw new Error(message); };
const identity = stat => ['dev', 'ino', 'mode', 'uid', 'gid'].map(key => String(stat[key]));
const fileIdentity = stat => ['dev', 'ino', 'mode', 'uid', 'gid', 'size', 'nlink', 'mtimeNs', 'ctimeNs'].map(key => String(stat[key]));
const keys = (value, names) => value && typeof value === 'object' && !Array.isArray(value) && same(Object.keys(value).sort(), names.split(' ').sort());
const namePattern = '[A-Za-z][A-Za-z0-9_-]{0,127}', versionPattern = '[0-9]+\\.[0-9]+\\.[0-9]+(?:[-+][A-Za-z0-9.+-]+)?';
const registry = 'registry+https://github.com/rust-lang/crates.io-index';
export function cargoSourceLock(bytes) {
  const text = new TextDecoder('utf-8', { fatal: true }).decode(bytes);
  if (bytes.length > 64 * 1024 || /[^\x20-\x7e\n]/.test(text) || text.includes('\\')) fail('unsupported Cargo lock literal');
  const input = text.split('\n').filter(line => !line.startsWith('#')).join('\n').trim(), chunks = input.split('\n[[package]]\n');
  if (chunks.shift().trim() !== 'version = 4' || !chunks.length || chunks.length > 128) fail('Cargo lock version/bounds');
  const seen = new Set(), packages = chunks.map(chunk => {
    const match = new RegExp(`^name = "(${namePattern})"\\nversion = "(${versionPattern})"(?:\\nsource = "([^"\\n]+)"\\nchecksum = "([0-9a-f]{64})")?(?:\\ndependencies = \\[\\n((?: "${namePattern}(?: ${versionPattern})?",\\n)*)\\])?$`).exec(chunk.trim());
    if (!match || match[2].length > 128 || (match[3] && match[3] !== registry)) fail('unsupported Cargo package entry');
    const [, name, version, source, checksum, dependencies] = match, key = name + ' ' + version;
    if (seen.has(key)) fail('duplicate Cargo package identity'); seen.add(key);
    const required = dependencies ? dependencies.split('\n').filter(Boolean).map(line => JSON.parse(line.trim().slice(0, -1))) : [];
    if (new Set(required).size !== required.length || (!source && !['frameshift-codec', 'jpeg-decoder'].includes(name))) fail('unsupported Cargo dependency/local identity');
    return { name, version, ...(source ? { source, checksum } : {}), dependencies: required };
  });
  for (const item of packages) for (const required of item.dependencies) { const [name, version] = required.split(' '); if (packages.filter(p => p.name === name && (!version || p.version === version)).length !== 1) fail('missing or ambiguous Cargo dependency'); }
  if (['frameshift-codec', 'jpeg-decoder'].some(name => packages.filter(p => !p.source && p.name === name).length !== 1) || !packages.some(p => p.source)) fail('Cargo local/registry profile missing');
  return packages.sort((a, b) => a.name === b.name ? (a.version < b.version ? -1 : a.version > b.version ? 1 : 0) : a.name < b.name ? -1 : 1);
}
function directory(path, privateMode = false) { const stat = lstatSync(path, { bigint: true }); if (!stat.isDirectory() || stat.uid !== BigInt(process.getuid()) || (privateMode ? (stat.mode & 0o7777n) !== 0o700n : (stat.mode & 0o7022n) !== 0n)) fail('unsafe Cargo material directory'); return stat; }
function synchronize(path, isDirectory = false) { const fd = openSync(path, constants.O_RDONLY | constants.O_NOFOLLOW | constants.O_NONBLOCK | (isDirectory ? constants.O_DIRECTORY : 0)); try { const a = fstatSync(fd), b = lstatSync(path); if (!(isDirectory ? a.isDirectory() && b.isDirectory() : a.isFile() && b.isFile()) || a.dev !== b.dev || a.ino !== b.ino) fail('Cargo sync custody changed'); fsyncSync(fd); } finally { closeSync(fd); } }
export function cargoArchiveParse(lock, bytes, timeoutMs = 30_000) {
  const env = { ...process.env }; for (const key of Object.keys(env)) if (key.startsWith('GIT_') || ['NODE_OPTIONS', 'NODE_PATH', 'NODE_V8_COVERAGE'].includes(key)) delete env[key];
  const result = spawnSync(process.execPath, ['--max-old-space-size=256', helper, lock.name, lock.version, lock.checksum], { cwd: owner, env, input: bytes, timeout: Math.max(1, Math.min(30_000, timeoutMs)), killSignal: 'SIGKILL', maxBuffer: 16 * 1024 * 1024 });
  if (result.error || result.status !== 0) fail('Cargo archive child unavailable/refused');
  try { return JSON.parse(new TextDecoder('utf-8', { fatal: true }).decode(result.stdout)); } catch { fail('Cargo archive child output refused'); }
}
async function inspect(repository, source, cache, sources, parse, budget) {
  const lockBytes = await readReleaseInput(join(repository, 'codec/Cargo.lock'), { maximum: 64 * 1024 }), locks = cargoSourceLock(lockBytes), packages = [], localPackages = []; let entries = 0, totalBytes = 0, runtime;
  const custody = [{ path: cache, identity: fileIdentity(directory(cache)), names: materialDirectoryNames(cache) }, { path: sources, identity: fileIdentity(directory(sources)), names: materialDirectoryNames(sources) }];
  for (const lock of locks) {
    budget();
    if (!lock.source) {
      const path = lock.name === 'frameshift-codec' ? 'codec/Cargo.toml' : 'codec/vendor/jpeg-decoder/Cargo.toml', fact = source.files.find(file => file.path === path);
      if (!fact) fail('Cargo local manifest not frozen');
      const bytes = await readReleaseInput(join(repository, path), { maximum: 64 * 1024 }), text = new TextDecoder('utf-8', { fatal: true }).decode(bytes), header = /^\[package\]\nname = "([^"\n]+)"\nversion = "([^"\n]+)"\n/.exec(text);
      if (!header || header[1] !== lock.name || header[2] !== lock.version || hash(bytes) !== fact.sha256) fail('Cargo local manifest identity differs');
      localPackages.push({ lock, scope: 'frozen-tracked-project-reference', manifest: fact }); continue;
    }
    const stem = lock.name + '-' + lock.version, archivePath = join(cache, stem + '.crate');
    if (lstatSync(archivePath).nlink !== 1) fail('Cargo archive alias');
    const raw = await readReleaseInput(archivePath, { maximum: 64 * 1024 * 1024, protectedTrust: true });
    if (hash(raw) !== lock.checksum) fail('Cargo archive checksum differs');
    custody.push({ path: archivePath, identity: fileIdentity(lstatSync(archivePath, { bigint: true })) });
    const parsed = await parse(lock, raw); budget();
    if (!keys(parsed, 'runtime files directories') || !keys(parsed.runtime, 'node zlib') || parsed.runtime.node !== 'v26.9.0' || typeof parsed.runtime.zlib !== 'string' || !/^[0-9A-Za-z.+-]{1,64}$/.test(parsed.runtime.zlib) || (runtime && !same(runtime, parsed.runtime)) || !Array.isArray(parsed.directories) || parsed.directories.length > 8192) fail('Cargo archive schema/runtime differs');
    runtime = parsed.runtime; validateCapturedFacts(parsed.files);
    const expectedDirs = new Map([['', undefined]]), expectedFiles = new Map(parsed.files.map(file => [file.path, file]));
    for (const entry of parsed.directories) { if (!keys(entry, 'path mode') || (entry.path !== '' && !materialPath(entry.path)) || !Number.isInteger(entry.mode) || entry.mode > 0o777 || (entry.mode & 0o022) || (entry.mode & 0o500) !== 0o500 || expectedDirs.get(entry.path) !== undefined || expectedFiles.has(entry.path)) fail('invalid Cargo archive directory'); expectedDirs.set(entry.path, entry.mode); }
    for (const file of parsed.files) { if ((file.mode & 0o022) || file.path.split('/').includes('.cargo-ok')) fail('unsafe/reserved Cargo source'); let parent = dirname(file.path); while (parent !== '.') { if (!expectedDirs.has(parent)) expectedDirs.set(parent, undefined); parent = dirname(parent); } }
    const root = join(sources, stem), directories = [], files = []; let marker;
    async function visit(path) {
      const full = join(root, path), stat = lstatSync(full, { bigint: true });
      if (stat.isDirectory()) {
        if (!expectedDirs.has(path)) fail('additional Cargo source directory'); directory(full);
        const mode = Number(stat.mode & 0o7777n); if (expectedDirs.get(path) !== undefined && mode !== expectedDirs.get(path)) fail('Cargo source directory mode differs');
        const names = materialDirectoryNames(full); custody.push({ path: full, identity: fileIdentity(stat), names }); directories.push({ path, mode });
        for (const name of names) await visit(path ? path + '/' + name : name);
      } else {
        const file = path === '.cargo-ok' ? { path, mode: 0o644, bytes: 7, sha256: hash(Buffer.from('{"v":1}')) } : expectedFiles.get(path);
        if (!file) fail('additional Cargo source file');
        await lockedSourceFacts(full, file, budget); custody.push({ path: full, identity: fileIdentity(lstatSync(full, { bigint: true })) });
        if (path === '.cargo-ok') marker = { ...file, reason: 'generated-cargo-unpack-marker' }; else files.push(file);
      }
      if (++entries > 8192) fail('Cargo material entry ceiling');
    }
    await visit('');
    if (!marker || files.length !== parsed.files.length || directories.length !== expectedDirs.size || (totalBytes += files.reduce((n, f) => n + f.bytes, 0)) > 512 * 1024 * 1024) fail('Cargo source incomplete/excessive');
    packages.push({ lock, archive: { bytes: raw.length, sha256: lock.checksum }, files, directories, cacheMarker: marker });
  }
  for (const item of custody) if (!same(item.identity, fileIdentity(lstatSync(item.path, { bigint: true }))) || (item.names && !same(item.names, materialDirectoryNames(item.path)))) fail('Cargo material custody changed');
  return { material: { lockSha256: hash(lockBytes), runtime, packages, localPackages }, custody };
}

export async function checkCargoMaterial({ repository, tag, commit, sourcePath, cache, sources, output }, { parse = cargoArchiveParse, budgetMs = 180_000 } = {}) {
  repository = realpathSync(repository); cache = resolve(cache); sources = resolve(sources); output = resolve(output);
  const deadline = performance.now() + budgetMs, budget = () => { if (performance.now() >= deadline) fail('Cargo material deadline'); };
  const parser = (lock, bytes) => { budget(); return parse(lock, bytes, Math.max(1, deadline - performance.now())); };
  const source = await verifyInputs(repository, tag, commit, sourcePath); budget();
  const sourceParent = dirname(resolve(sourcePath)), sourceCustody = { identity: identity(directory(sourceParent, true)), names: materialDirectoryNames(sourceParent) };
  const helperBytes = await readReleaseInput(helper, { maximum: 64 * 1024, protectedTrust: true }), observation = await inspect(repository, source, cache, sources, parser, budget);
  const bytes = encode({ schemaVersion: 1, kind: 'locked-codec-cargo-source-material', product: source.product, tag, version: source.version, sourceCommit: commit, sourceInputsSha256: hash(encode(source)), parserSourceSha256: hash(helperBytes), publicationAuthority: 'none', ...observation.material });
  if (bytes.length > 16 * 1024 * 1024) fail('Cargo receipt ceiling');
  const parent = dirname(output), parentStat = directory(parent), physical = join(realpathSync(parent), basename(output));
  if (physical === repository || [cache, sources, sourceParent, join(repository, 'codec')].map(path => realpathSync(path)).some(path => physical === path || physical.startsWith(path + sep) || path.startsWith(physical + sep)) || (physical.startsWith(repository + sep) && !releaseGit(repository, ['check-ignore', '--no-index', physical]).length)) fail('Cargo output overlaps inputs');
  let exists = false; try { lstatSync(output); exists = true; } catch (error) { if (error.code !== 'ENOENT') throw error; }
  const record = join(output, 'cargo-material.json'), pending = join(output, 'check.pending'), marker = Buffer.from('incomplete codec Cargo source check\n'); let created;
  if (exists) { created = directory(output, true); if (!same(materialDirectoryNames(output), ['cargo-material.json']) || lstatSync(record).nlink !== 1 || !(await readReleaseInput(record, { maximum: 16 * 1024 * 1024, privateKey: true })).equals(bytes)) fail('incomplete or conflicting Cargo material output'); }
  else { mkdirSync(output, { mode: 0o700 }); created = directory(output, true); writeFileSync(pending, marker, { mode: 0o600, flag: 'wx' }); synchronize(pending); synchronize(output, true); }
  await verifyInputs(repository, tag, commit, sourcePath); budget();
  if (!same(observation, await inspect(repository, source, cache, sources, parser, budget))) fail('Cargo material changed during check');
  await verifyInputs(repository, tag, commit, sourcePath); budget();
  // No child follows these final static input checks.
  for (const file of source.files) await lockedSourceFacts(join(repository, file.path), { ...file, mode: file.mode === '100755' ? 0o755 : 0o644 }, budget);
  if (!(await readReleaseInput(helper, { maximum: 64 * 1024, protectedTrust: true })).equals(helperBytes)) fail('Cargo helper changed');
  for (const item of observation.material.packages) {
    const path = join(cache, item.lock.name + '-' + item.lock.version + '.crate'); if (lstatSync(path).nlink !== 1 || hash(await readReleaseInput(path, { maximum: 64 * 1024 * 1024, protectedTrust: true })) !== item.lock.checksum) fail('Cargo final archive changed');
    const root = join(sources, item.lock.name + '-' + item.lock.version); for (const file of [...item.files, item.cacheMarker]) await lockedSourceFacts(join(root, file.path), file, budget);
  }
  for (const item of observation.custody) if (!same(item.identity, fileIdentity(lstatSync(item.path, { bigint: true }))) || (item.names && !same(item.names, materialDirectoryNames(item.path)))) fail('Cargo final material custody changed');
  if (!same(sourceCustody, { identity: identity(directory(sourceParent, true)), names: materialDirectoryNames(sourceParent) }) || !same(identity(parentStat), identity(directory(parent))) || !same(identity(created), identity(directory(output, true))) || !same(materialDirectoryNames(output), exists ? ['cargo-material.json'] : ['check.pending'])) fail('Cargo input/output namespace changed');
  if (exists) { if (lstatSync(record).nlink !== 1 || !(await readReleaseInput(record, { maximum: 16 * 1024 * 1024, privateKey: true })).equals(bytes)) fail('Cargo retained record changed'); }
  else {
    if (lstatSync(pending).nlink !== 1 || !(await readReleaseInput(pending, { maximum: 1024, privateKey: true })).equals(marker)) fail('Cargo pending custody changed');
    writeFileSync(record, bytes, { mode: 0o600, flag: 'wx' }); synchronize(record);
    if (!same(identity(created), identity(directory(output, true))) || !same(materialDirectoryNames(output), ['cargo-material.json', 'check.pending']) || lstatSync(record).nlink !== 1 || lstatSync(pending).nlink !== 1 || !(await readReleaseInput(record, { maximum: 16 * 1024 * 1024, privateKey: true })).equals(bytes) || !(await readReleaseInput(pending, { maximum: 1024, privateKey: true })).equals(marker)) fail('Cargo completion custody changed');
    unlinkSync(pending); synchronize(output, true); synchronize(parent, true);
  }
  return { publicationAuthority: 'none', packages: observation.material.packages.length, sourceFiles: observation.material.packages.reduce((n, p) => n + p.files.length, 0), generatedCacheMarkers: observation.material.packages.length, receiptSha256: hash(bytes), disposition: exists ? 'retained-bytes-verified' : 'source-bytes-recorded' };
}
