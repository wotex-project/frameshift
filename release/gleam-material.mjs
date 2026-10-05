import { createHash } from 'node:crypto';
import { constants, closeSync, fstatSync, fsyncSync, lstatSync, mkdirSync, openSync, readdirSync, realpathSync, unlinkSync, writeFileSync } from 'node:fs';
import { basename, dirname, join, resolve, sep } from 'node:path';
import { isDeepStrictEqual as same } from 'node:util';
import { coreMaterialParse, lockedSourceFacts } from './core-material.mjs';
import { readReleaseInput } from './files.mjs';
import { verifyInputs } from './inputs.mjs';
import { releaseGit } from './source.mjs';

const owner = resolve(new URL('..', import.meta.url).pathname);
const encode = value => Buffer.from(JSON.stringify(value) + '\n');
const hash = value => createHash('sha256').update(value).digest('hex');
const maximumRecord = 16 * 1024 * 1024;
const fail = message => { throw new Error(message); };
const identity = stat => ['dev', 'ino', 'mode', 'uid', 'gid'].map(key => String(stat[key]));
const namePattern = '[a-z][a-z0-9_]{0,127}';
const versionPattern = '[0-9][A-Za-z0-9.+-]{0,127}';
const byName = (a, b) => a.name < b.name ? -1 : a.name > b.name ? 1 : 0;
const packageLine = new RegExp(`^\\{ name = "(${namePattern})", version = "(${versionPattern})", build_tools = \\["gleam"\\], requirements = (\\[(?:"${namePattern}"(?:, "${namePattern}")*)?\\])(?:, otp_app = "(${namePattern})")?, source = "hex", outer_checksum = "([0-9A-F]{64})" \\},$`);
function literal(bytes) {
  const text = new TextDecoder('utf-8', { fatal: true }).decode(bytes);
  if (bytes.length > 64 * 1024 || /[^\x20-\x7e\n\r]/.test(text) || text.includes('\r') || text.includes('\\')) fail('unsupported Gleam literal input');
  return text.split('\n').filter(line => !line.startsWith('#')).join('\n').trim();
}

export function gleamSourceManifest(bytes) {
  const text = literal(bytes), match = /^packages = \[\n([\s\S]+?)\n\]\n\n\[requirements\]\n([\s\S]+)$/.exec(text);
  if (!match) fail('unsupported Gleam manifest form');
  const packages = match[1].split('\n').map(line => {
    const parsed = packageLine.exec(line.trim());
    if (!parsed) fail('unsupported Gleam package entry');
    const [, name, version, requirements, otpApp, outer] = parsed, required = JSON.parse(requirements);
    if ((otpApp && otpApp !== name) || required.length > 128 || new Set(required).size !== required.length) fail('ambiguous Gleam package identity');
    return { name, version, buildTools: ['gleam'], requirements: required, ...(otpApp ? { otpApp } : {}), outer };
  }).sort(byName);
  if (!packages.length || packages.length > 128 || new Set(packages.map(p => p.name)).size !== packages.length) fail('Gleam manifest package limit or duplicate');
  const names = new Set(packages.map(p => p.name)), requirements = [];
  for (const line of match[2].split('\n')) {
    const parsed = new RegExp(`^(${namePattern}) = \\{ version = "([A-Za-z0-9 .+<>=~*-]{1,256})" \\}$`).exec(line);
    if (!parsed || !names.has(parsed[1]) || requirements.some(item => item.name === parsed[1])) fail('unsupported Gleam requirement entry');
    requirements.push({ name: parsed[1], version: parsed[2] });
  }
  if (packages.some(p => p.requirements.some(name => !names.has(name)))) fail('missing Gleam transitive requirement');
  return { packages, requirements: requirements.sort(byName) };
}
export function gleamFetchedPackages(bytes) {
  const match = /^\[packages\]\n([\s\S]+?)\n\n\[git\]$/.exec(literal(bytes));
  if (!match) fail('unsupported Gleam fetched metadata');
  const pairs = match[1].split('\n').map(line => {
    const parsed = new RegExp(`^(${namePattern}) = "(${versionPattern})"$`).exec(line);
    if (!parsed) fail('unsupported Gleam fetched package');
    return { name: parsed[1], version: parsed[2] };
  }).sort(byName);
  if (pairs.length > 128 || new Set(pairs.map(p => p.name)).size !== pairs.length) fail('duplicate Gleam fetched package');
  return pairs;
}
function directory(path, privateMode = false) {
  const stat = lstatSync(path, { bigint: true });
  if (!stat.isDirectory() || stat.uid !== BigInt(process.getuid()) || (privateMode ? (stat.mode & 0o7777n) !== 0o700n : (stat.mode & 0o022n) !== 0n)) fail('unsafe Gleam material directory');
  return stat;
}
function sync(path, isDirectory = false) {
  const fd = openSync(path, constants.O_RDONLY | constants.O_NOFOLLOW | constants.O_NONBLOCK | (isDirectory ? constants.O_DIRECTORY : 0));
  try {
    const stat = fstatSync(fd), named = lstatSync(path);
    if (!(isDirectory ? stat.isDirectory() && named.isDirectory() : stat.isFile() && named.isFile()) || stat.dev !== named.dev || stat.ino !== named.ino) fail('Gleam material sync custody changed');
    fsyncSync(fd);
  } finally { closeSync(fd); }
}
async function inspect(repository, cache, parse, budget) {
  const component = join(repository, 'packages/decision-kernel'), root = join(component, 'build/packages');
  const manifestBytes = await readReleaseInput(join(component, 'manifest.toml'), { maximum: 64 * 1024 }), manifest = gleamSourceManifest(manifestBytes);
  const metadataPath = join(root, 'packages.toml'), metadataBytes = await readReleaseInput(metadataPath, { maximum: 64 * 1024 });
  if (!same(gleamFetchedPackages(metadataBytes), manifest.packages.map(({ name, version }) => ({ name, version })))) fail('Gleam fetched metadata differs from manifest');
  const rootStat = directory(root), cacheStat = directory(cache), names = readdirSync(root).sort(), cacheNames = readdirSync(cache).sort();
  if (!same(names, [...manifest.packages.map(p => p.name), 'packages.toml', 'gleam.lock'].sort())) fail('Gleam package namespace differs from manifest');
  const lockPath = join(root, 'gleam.lock');
  if (lstatSync(metadataPath).nlink !== 1 || lstatSync(lockPath).nlink !== 1 || (await readReleaseInput(lockPath, { minimum: 0, maximum: 0 })).length !== 0) fail('unsafe Gleam fetched metadata/lock');
  const metadataMode = lstatSync(metadataPath).mode & 0o7777, lockMode = lstatSync(lockPath).mode & 0o7777;
  await lockedSourceFacts(metadataPath, { path: 'packages.toml', mode: metadataMode, bytes: metadataBytes.length, sha256: hash(metadataBytes) }, budget);
  await lockedSourceFacts(lockPath, { path: 'gleam.lock', mode: lockMode, bytes: 0, sha256: hash(Buffer.alloc(0)) }, budget);
  const packages = []; let count = 0, total = 0;
  for (const lock of manifest.packages) {
    budget();
    const archivePath = join(cache, `${lock.outer}.tar`);
    if (lstatSync(archivePath).nlink !== 1) fail('Gleam archive alias');
    const bytes = await readReleaseInput(archivePath, { maximum: 64 * 1024 * 1024 });
    if (lstatSync(archivePath).nlink !== 1 || hash(bytes) !== lock.outer.toLowerCase()) fail('Gleam archive differs from locked checksum');
    const parsed = parse('package', bytes);
    if (parsed.name !== lock.name || parsed.version !== lock.version || parsed.outer !== lock.outer.toLowerCase()) fail('Gleam archive identity differs from manifest');
    const expected = new Map(parsed.files.map(file => [file.path, file])), parents = new Set(['']), files = [], directories = [], seen = new Set();
    for (const path of [...expected.keys(), ...parsed.directories.map(path => path + '/placeholder')]) {
      let parent = dirname(path); while (parent !== '.') { parents.add(parent); parent = dirname(parent); }
    }
    const packageRoot = join(root, lock.name);
    async function visit(relative, depth) {
      budget();
      if (++count > 8192 || depth > 32 || Buffer.byteLength(relative) > 512 || /[\u0000-\u001f\u007f\\]/.test(relative) || relative.split('/').some(part => part === '.' || part === '..')) fail('Gleam source entry limit or unsafe path');
      const path = join(packageRoot, relative), stat = lstatSync(path, { bigint: true });
      if (stat.isDirectory()) {
        if (!parents.has(relative)) fail('additional Gleam source directory');
        directory(path); const before = readdirSync(path).sort(); directories.push({ path: relative, mode: Number(stat.mode & 0o7777n) });
        for (const name of before) await visit(relative ? `${relative}/${name}` : name, depth + 1);
        if (!same(before, readdirSync(path).sort()) || !same(identity(stat), identity(directory(path)))) fail('Gleam source namespace changed');
      } else {
        const entry = expected.get(relative); if (!entry) fail('additional Gleam source file');
        const file = await lockedSourceFacts(path, entry, budget); total += file.bytes;
        if (total > 512 * 1024 * 1024) fail('Gleam source byte limit');
        files.push(file); seen.add(relative);
      }
    }
    await visit('', 0); if (seen.size !== expected.size) fail('missing Gleam source file');
    packages.push({ lock, innerChecksum: parsed.inner, parser: parsed.parser, files, directories });
  }
  if (!same(names, readdirSync(root).sort()) || !same(cacheNames, readdirSync(cache).sort()) || !same(identity(rootStat), identity(directory(root))) || !same(identity(cacheStat), identity(directory(cache))) || !(await readReleaseInput(metadataPath, { maximum: 64 * 1024 })).equals(metadataBytes) || lstatSync(metadataPath).nlink !== 1 || lstatSync(lockPath).nlink !== 1 || (await readReleaseInput(lockPath, { minimum: 0, maximum: 0 })).length !== 0) fail('Gleam source/cache/metadata namespace changed');
  if ((lstatSync(metadataPath).mode & 0o7777) !== metadataMode || (lstatSync(lockPath).mode & 0o7777) !== lockMode) fail('Gleam fetched metadata modes changed');
  return { material: { manifestSha256: hash(manifestBytes), fetchedMetadataSha256: hash(metadataBytes), fetchedMetadataMode: metadataMode, requirements: manifest.requirements, packages }, namespace: { names, cacheNames, root: identity(rootStat), cache: identity(cacheStat), lockMode } };
}

export async function checkGleamMaterial({ repository, tag, commit, sourcePath, cache, output }, { parse = coreMaterialParse, budgetMs = 180_000 } = {}) {
  repository = realpathSync(repository); directory(cache); cache = realpathSync(cache); output = resolve(output);
  const deadline = performance.now() + budgetMs, budget = () => { if (performance.now() >= deadline) fail('Gleam material processing deadline'); };
  const parser = (operation, bytes) => { budget(); const value = parse(operation, bytes, Math.max(1, Math.min(60_000, Math.floor(deadline - performance.now())))); budget(); return value; };
  const source = await verifyInputs(repository, tag, commit, sourcePath); budget();
  const helper = join(owner, 'release/core-material.exs'), helperBytes = await readReleaseInput(helper, { maximum: 64 * 1024 });
  const observation = await inspect(repository, cache, parser, budget);
  const bytes = encode({ schemaVersion: 1, kind: 'locked-gleam-source-material', product: source.product, tag, version: source.version, sourceCommit: commit,
    sourceInputsSha256: hash(encode(source)), parserSourceSha256: hash(helperBytes), publicationAuthority: 'none', ...observation.material });
  if (bytes.length > maximumRecord) fail('Gleam material receipt limit');
  const parent = dirname(output); directory(parent); const physical = join(realpathSync(parent), basename(output)), sourceRoot = join(repository, 'packages/decision-kernel/build/packages');
  if (physical === repository || physical === cache || physical.startsWith(cache + sep) || cache.startsWith(physical + sep) || physical === sourceRoot || physical.startsWith(sourceRoot + sep) || (physical.startsWith(repository + sep) && !releaseGit(repository, ['check-ignore', '--no-index', physical]).length)) fail('Gleam material output overlaps inputs');
  let exists = false; try { lstatSync(output); exists = true; } catch (error) { if (error.code !== 'ENOENT') throw error; }
  const receipt = join(output, 'gleam-material.json'), pending = join(output, 'check.pending'), marker = Buffer.from('incomplete Gleam dependency source check\n');
  let created;
  if (exists) {
    created = directory(output, true);
    if (!same(readdirSync(output).sort(), ['gleam-material.json']) || lstatSync(receipt).nlink !== 1 || !(await readReleaseInput(receipt, { maximum: maximumRecord, privateKey: true })).equals(bytes)) fail('incomplete or conflicting Gleam material output');
  } else {
    mkdirSync(output, { mode: 0o700 }); created = directory(output, true);
    writeFileSync(pending, marker, { flag: 'wx', mode: 0o600 }); sync(pending); sync(output, true);
  }
  await verifyInputs(repository, tag, commit, sourcePath); budget();
  if (!same(observation, await inspect(repository, cache, parser, budget)) || !(await readReleaseInput(helper, { maximum: 64 * 1024 })).equals(helperBytes)) fail('Gleam material changed during check');
  await verifyInputs(repository, tag, commit, sourcePath); budget();
  if (!same(identity(created), identity(directory(output, true))) || !same(readdirSync(output).sort(), exists ? ['gleam-material.json'] : ['check.pending'])) fail('Gleam receipt output custody changed');
  if (exists) {
    if (lstatSync(receipt).nlink !== 1 || !(await readReleaseInput(receipt, { maximum: maximumRecord, privateKey: true })).equals(bytes)) fail('Gleam receipt changed during replay');
  } else {
    if (lstatSync(pending).nlink !== 1 || !(await readReleaseInput(pending, { maximum: 1024, privateKey: true })).equals(marker)) fail('Gleam pending custody changed');
    writeFileSync(receipt, bytes, { flag: 'wx', mode: 0o600 }); sync(receipt);
    if (!same(identity(created), identity(directory(output, true))) || !same(readdirSync(output).sort(), ['check.pending', 'gleam-material.json']) || lstatSync(receipt).nlink !== 1 || !(await readReleaseInput(receipt, { maximum: maximumRecord, privateKey: true })).equals(bytes) || !(await readReleaseInput(pending, { maximum: 1024, privateKey: true })).equals(marker)) fail('Gleam receipt output changed');
    unlinkSync(pending); sync(output, true); sync(parent, true);
  }
  return { publicationAuthority: 'none', packages: observation.material.packages.length, files: observation.material.packages.reduce((sum, p) => sum + p.files.length, 0), receiptSha256: hash(bytes), disposition: exists ? 'retained-bytes-verified' : 'source-bytes-recorded' };
}
