import { createHash } from 'node:crypto';
import { constants, closeSync, fstatSync, fsyncSync, lstatSync, mkdirSync, openSync, realpathSync, unlinkSync, writeFileSync } from 'node:fs';
import { basename, dirname, join, resolve, sep } from 'node:path';
import { isDeepStrictEqual as same } from 'node:util';
import { checkCoreMaterial, coreMaterialParse, lockedSourceFacts } from './core-material.mjs';
import { readReleaseInput } from './files.mjs';
import { checkGleamMaterial } from './gleam-material.mjs';
import { verifyInputs } from './inputs.mjs';
import { materialDirectoryNames, materialPath, readMaterialReceipt } from './material-receipts.mjs';
import { releaseGit } from './source.mjs';

const encode = value => Buffer.from(JSON.stringify(value) + '\n');
const hash = value => createHash('sha256').update(value).digest('hex');
const fail = message => { throw new Error(message); };
const identity = stat => ['dev', 'ino', 'mode', 'uid', 'gid'].map(key => String(stat[key]));
const fileIdentity = stat => ['dev', 'ino', 'mode', 'uid', 'gid', 'size', 'nlink', 'mtimeNs', 'ctimeNs'].map(key => String(stat[key]));
function directory(path, privateMode = false) {
  const stat = lstatSync(path, { bigint: true });
  if (!stat.isDirectory() || stat.uid !== BigInt(process.getuid()) || (privateMode ? (stat.mode & 0o7777n) !== 0o700n : (stat.mode & 0o7022n) !== 0n)) fail('unsafe notice directory');
  return stat;
}
function synchronize(path, isDirectory = false) {
  const fd = openSync(path, constants.O_RDONLY | constants.O_NOFOLLOW | constants.O_NONBLOCK | (isDirectory ? constants.O_DIRECTORY : 0));
  try { const opened = fstatSync(fd), named = lstatSync(path); if (!(isDirectory ? opened.isDirectory() && named.isDirectory() : opened.isFile() && named.isFile()) || opened.dev !== named.dev || opened.ino !== named.ino) fail('notice sync custody changed'); fsyncSync(fd); }
  finally { closeSync(fd); }
}
export function conventionalNoticePath(path) {
  return materialPath(path) && (/^(?:licen[cs]es?|copying|copyright|notices?|authors)(?:[._-].*)?$/i.test(basename(path)) || path.split('/').slice(0, -1).some(part => /^licen[cs]es$/i.test(part)));
}
function selections(core, gleam) {
  const packages = [], files = []; let total = 0;
  for (const [component, receipt, prefix] of [['core', core, 'apps/core/deps/'], ['decision-kernel', gleam, 'packages/decision-kernel/build/packages/']]) {
    if (!Array.isArray(receipt.packages) || !receipt.packages.length || receipt.packages.length > 128) fail('notice package bounds');
    for (const item of receipt.packages) {
      const name = component === 'core' ? item.lock.key : item.lock.name, selected = [], notices = [];
      for (const file of item.files) {
        const notice = conventionalNoticePath(file.path), metadata = component === 'core' && item.lock.type === 'hex' && file.path === 'hex_metadata.config';
        if (!notice && !metadata) continue;
        const retainedPath = component + '/' + name + '/' + file.path;
        if (!materialPath(retainedPath) || file.bytes > 1024 * 1024 || (total += file.bytes) > 16 * 1024 * 1024 || files.length === 512) fail('notice selection bounds');
        files.push({ component, package: name, role: notice ? 'conventional-notice-file' : 'package-metadata', source: { ...file, path: prefix + name + '/' + file.path }, retainedPath });
        selected.push(retainedPath); if (notice) notices.push(retainedPath);
      }
      packages.push({ component, name, lock: item.lock, conventionalNoticeFiles: notices, selectedFiles: selected });
    }
  }
  return { packages, files };
}
function parentsOf(paths) {
  const parents = new Set();
  for (const path of paths) { let parent = dirname(path); while (parent !== '.') { parents.add(parent); parent = dirname(parent); } }
  return [...parents].sort();
}
function sourceDirectoryCustody(repository, files) {
  const paths = new Set();
  for (const file of files) {
    const root = file.component === 'core' ? 'apps/core/deps' : 'packages/decision-kernel/build/packages';
    let parent = dirname(file.source.path);
    while (parent === root || parent.startsWith(root + '/')) { paths.add(parent); if (parent === root) break; parent = dirname(parent); }
  }
  return [...paths].sort().map(path => ({ path, identity: fileIdentity(directory(join(repository, path))), names: materialDirectoryNames(join(repository, path)) }));
}
async function copiedCustody(root, files, syncFiles = false) {
  directory(root, true); const expected = new Map(files.map(file => [file.retainedPath, file.source])), parents = new Set(parentsOf(expected.keys())), seen = new Set(), custody = [];
  async function visit(path) {
    const full = join(root, path), stat = lstatSync(full, { bigint: true });
    if (stat.isDirectory()) {
      if (path && !parents.has(path)) fail('unknown notice directory'); directory(full, true);
      const names = materialDirectoryNames(full); custody.push({ path, identity: fileIdentity(stat), names });
      for (const name of names) await visit(path ? path + '/' + name : name);
      if (syncFiles) synchronize(full, true);
    } else {
      const file = expected.get(path);
      if (!file || stat.nlink !== 1n || (stat.mode & 0o7777n) !== 0o600n) fail('unknown, aliased or unsafe notice file');
      const bytes = await readReleaseInput(full, { maximum: 1024 * 1024, privateKey: true });
      if (bytes.length !== file.bytes || hash(bytes) !== file.sha256) fail('copied notice bytes differ');
      custody.push({ path, identity: fileIdentity(stat) }); seen.add(path); if (syncFiles) synchronize(full);
    }
  }
  await visit('');
  if (seen.size !== expected.size) fail('notice collection incomplete');
  for (const item of custody) if (!same(item.identity, fileIdentity(lstatSync(join(root, item.path), { bigint: true }))) || (item.names && !same(item.names, materialDirectoryNames(join(root, item.path))))) fail('notice collection custody changed');
  return custody;
}

export async function collectDependencyNotices({ repository, tag, commit, sourcePath, coreCache, corePath, coreSha256, gleamCache, gleamPath, gleamSha256, output }, { parse = coreMaterialParse } = {}) {
  repository = realpathSync(repository); output = resolve(output);
  const deadline = performance.now() + 360_000, budget = () => { if (performance.now() > deadline) fail('notice processing deadline'); };
  const source = await verifyInputs(repository, tag, commit, sourcePath); budget();
  const readReceipts = async () => ({ core: await readMaterialReceipt(corePath, coreSha256, source, 'locked-core-source-material'), gleam: await readMaterialReceipt(gleamPath, gleamSha256, source, 'locked-gleam-source-material') });
  const { core, gleam } = await readReceipts();
  const replaySources = async () => {
    for (const [check, cache, path, expected] of [[checkCoreMaterial, coreCache, corePath, coreSha256], [checkGleamMaterial, gleamCache, gleamPath, gleamSha256]]) {
      const result = await check({ repository, tag, commit, sourcePath, cache, output: dirname(resolve(path)) }, { parse, budgetMs: Math.max(1, Math.min(180_000, deadline - performance.now())) });
      if (result.receiptSha256 !== expected || result.disposition !== 'retained-bytes-verified') fail('notice source receipt replay differs'); budget();
    }
  };
  const inputDirectories = [...new Set([dirname(resolve(sourcePath)), dirname(resolve(corePath)), dirname(resolve(gleamPath)), resolve(coreCache), resolve(gleamCache)])];
  const inputCustody = () => inputDirectories.map(path => ({ identity: identity(directory(path, path !== resolve(coreCache) && path !== resolve(gleamCache))), names: materialDirectoryNames(path) }));
  const inputs = inputCustody(); await replaySources();
  const selected = selections(core, gleam), sourceDirs = sourceDirectoryCustody(repository, selected.files);
  const sourceFiles = selected.files.map(file => fileIdentity(lstatSync(join(repository, file.source.path), { bigint: true })));
  for (const file of selected.files) await lockedSourceFacts(join(repository, file.source.path), file.source, budget);
  const bytes = encode({ schemaVersion: 1, kind: 'locked-dependency-notice-material', product: source.product, tag, version: source.version, sourceCommit: commit, sourceInputsSha256: hash(encode(source)), coreReceiptSha256: coreSha256, gleamReceiptSha256: gleamSha256, collectionScope: 'conventional-notice-files-and-core-hex-metadata', rightsReview: 'required', publicationAuthority: 'none', ...selected });
  if (bytes.length > 1024 * 1024) fail('notice inventory limit');
  const parent = dirname(output), parentStat = directory(parent), physical = join(realpathSync(parent), basename(output));
  const excluded = [...inputDirectories, join(repository, 'apps/core/deps'), join(repository, 'packages/decision-kernel/build/packages')].map(path => realpathSync(path));
  if (physical === repository || excluded.some(path => physical === path || physical.startsWith(path + sep) || path.startsWith(physical + sep)) || (physical.startsWith(repository + sep) && !releaseGit(repository, ['check-ignore', '--no-index', physical]).length)) fail('notice output overlaps inputs');
  let exists = false; try { lstatSync(output); exists = true; } catch (error) { if (error.code !== 'ENOENT') throw error; }
  const record = join(output, 'notices.json'), root = join(output, 'files'), pending = join(output, 'collect.pending'), marker = Buffer.from('incomplete dependency notice collection\n'); let created;
  if (exists) {
    created = directory(output, true);
    if (!same(materialDirectoryNames(output), ['files', 'notices.json']) || lstatSync(record).nlink !== 1 || !(await readReleaseInput(record, { maximum: 1024 * 1024, privateKey: true })).equals(bytes)) fail('incomplete or conflicting notice output');
  } else {
    mkdirSync(output, { mode: 0o700 }); created = directory(output, true); writeFileSync(pending, marker, { flag: 'wx', mode: 0o600 }); synchronize(pending); mkdirSync(root, { mode: 0o700 }); synchronize(output, true);
    for (const path of parentsOf(selected.files.map(file => file.retainedPath))) mkdirSync(join(root, path), { mode: 0o700 });
    for (const file of selected.files) { const raw = await readReleaseInput(join(repository, file.source.path), { maximum: 1024 * 1024 }); if (raw.length !== file.source.bytes || hash(raw) !== file.source.sha256) fail('notice source changed before copying'); writeFileSync(join(root, file.retainedPath), raw, { flag: 'wx', mode: 0o600 }); }
  }
  const copied = await copiedCustody(root, selected.files, !exists);
  await replaySources(); await verifyInputs(repository, tag, commit, sourcePath); budget();
  // Static checks follow every archive parser and version child.
  for (const file of source.files) await lockedSourceFacts(join(repository, file.path), { ...file, mode: file.mode === '100755' ? 0o755 : 0o644 }, budget);
  await readReceipts();
  for (const file of selected.files) await lockedSourceFacts(join(repository, file.source.path), file.source, budget);
  if (!same(sourceFiles, selected.files.map(file => fileIdentity(lstatSync(join(repository, file.source.path), { bigint: true })))) || !same(sourceDirs, sourceDirectoryCustody(repository, selected.files)) || !same(copied, await copiedCustody(root, selected.files))) fail('notice source/proof custody changed');
  if (!same(inputs, inputCustody()) || !same(identity(parentStat), identity(directory(parent))) || !same(identity(created), identity(directory(output, true))) || !same(materialDirectoryNames(output), exists ? ['files', 'notices.json'] : ['collect.pending', 'files'])) fail('notice input/output namespace changed');
  if (exists) { if (lstatSync(record).nlink !== 1 || !(await readReleaseInput(record, { maximum: 1024 * 1024, privateKey: true })).equals(bytes)) fail('retained notice inventory changed'); }
  else {
    if (lstatSync(pending).nlink !== 1 || !(await readReleaseInput(pending, { maximum: 1024, privateKey: true })).equals(marker)) fail('notice pending custody changed');
    writeFileSync(record, bytes, { flag: 'wx', mode: 0o600 }); synchronize(record);
    if (!same(identity(created), identity(directory(output, true))) || !same(materialDirectoryNames(output), ['collect.pending', 'files', 'notices.json']) || lstatSync(record).nlink !== 1 || lstatSync(pending).nlink !== 1 || !(await readReleaseInput(record, { maximum: 1024 * 1024, privateKey: true })).equals(bytes) || !(await readReleaseInput(pending, { maximum: 1024, privateKey: true })).equals(marker)) fail('notice completion custody changed');
    unlinkSync(pending); synchronize(output, true); synchronize(parent, true);
  }
  return { publicationAuthority: 'none', rightsReview: 'required', packages: selected.packages.length, files: selected.files.length, packagesWithoutConventionalNoticeFile: selected.packages.filter(item => !item.conventionalNoticeFiles.length).length, recordSha256: hash(bytes), disposition: exists ? 'retained-bytes-verified' : 'notice-bytes-collected' };
}
