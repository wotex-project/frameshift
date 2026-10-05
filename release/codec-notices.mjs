import { createHash } from 'node:crypto';
import { constants, closeSync, fstatSync, fsyncSync, lstatSync, mkdirSync, openSync, realpathSync, unlinkSync, writeFileSync } from 'node:fs';
import { basename, dirname, join, resolve, sep } from 'node:path';
import { isDeepStrictEqual as same } from 'node:util';
import { cargoArchiveParse, checkCargoMaterial } from './cargo-material.mjs';
import { lockedSourceFacts } from './core-material.mjs';
import { readReleaseInput } from './files.mjs';
import { verifyInputs } from './inputs.mjs';
import { materialDirectoryNames, materialPath, readMaterialReceipt } from './material-receipts.mjs';
import { conventionalNoticePath } from './notices.mjs';
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
function parentsOf(paths) {
  const parents = new Set();
  for (const path of paths) { let parent = dirname(path); while (parent !== '.') { parents.add(parent); parent = dirname(parent); } }
  return [...parents].sort();
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

function selection(receipt, source) {
  const packages = [], files = []; let total = 0;
  function select(scope, lock, available, prefix) {
    const notices = [], selected = [];
    for (const file of available) {
      const notice = conventionalNoticePath(file.path), metadata = ['Cargo.toml', 'Cargo.toml.orig'].includes(file.path);
      if (!notice && !metadata) continue;
      const retainedPath = scope + '/' + lock.name + '/' + lock.version + '/' + file.path;
      if (!materialPath(retainedPath) || file.bytes > 1024 * 1024 || (total += file.bytes) > 16 * 1024 * 1024 || files.length === 512) fail('codec notice selection bounds');
      files.push({ scope, package: lock.name, version: lock.version, role: notice ? 'conventional-notice-file' : 'package-metadata', source: { ...file, path: prefix + file.path }, retainedPath });
      selected.push(retainedPath); if (notice) notices.push(retainedPath);
    }
    packages.push({ scope, lock, conventionalNoticeFiles: notices, selectedFiles: selected });
  }
  for (const item of receipt.packages) select('registry', item.lock, item.files, item.lock.name + '-' + item.lock.version + '/');
  for (const item of receipt.localPackages) {
    const prefix = item.lock.name === 'frameshift-codec' ? 'codec/' : 'codec/vendor/jpeg-decoder/';
    const available = source.files.filter(file => file.path.startsWith(prefix) && !(item.lock.name === 'frameshift-codec' && file.path.startsWith('codec/vendor/'))).map(file => ({ ...file, path: file.path.slice(prefix.length), mode: file.mode === '100755' ? 0o755 : 0o644, gitMode: file.mode }));
    select('frozen-project', item.lock, available, prefix);
  }
  return { packages, files };
}
function sourceCustody(repository, sources, files) {
  const roots = file => file.scope === 'registry' ? sources : repository, directories = new Set();
  const identities = files.map(file => {
    const path = join(roots(file), file.source.path); let parent = dirname(path), stop = roots(file);
    for (;;) { directories.add(parent); if (parent === stop) break; parent = dirname(parent); }
    return fileIdentity(lstatSync(path, { bigint: true }));
  });
  return { files: identities, directories: [...directories].sort().map(path => ({ identity: fileIdentity(directory(path)), names: materialDirectoryNames(path) })) };
}
export async function collectCodecNotices({ repository, tag, commit, sourcePath, cache, sources, cargoPath, cargoSha256, output }, { parse = cargoArchiveParse, budgetMs = 360_000 } = {}) {
  repository = realpathSync(repository); cache = resolve(cache); sources = resolve(sources); output = resolve(output);
  const deadline = performance.now() + budgetMs, budget = () => { if (performance.now() >= deadline) fail('codec notice deadline'); };
  const source = await verifyInputs(repository, tag, commit, sourcePath); budget();
  const readReceipt = () => readMaterialReceipt(cargoPath, cargoSha256, source, 'locked-codec-cargo-source-material');
  const receipt = await readReceipt();
  const replay = async () => {
    const result = await checkCargoMaterial({ repository, tag, commit, sourcePath, cache, sources, output: dirname(resolve(cargoPath)) }, { parse, budgetMs: Math.max(1, Math.min(180_000, deadline - performance.now())) });
    if (result.receiptSha256 !== cargoSha256 || result.disposition !== 'retained-bytes-verified') fail('codec source replay differs'); budget();
  };
  const inputs = [...new Set([dirname(resolve(sourcePath)), dirname(resolve(cargoPath)), cache, sources])];
  const inputCustody = () => inputs.map(path => ({ identity: identity(directory(path, path !== cache && path !== sources)), names: materialDirectoryNames(path) }));
  const before = inputCustody(); await replay();
  const selected = selection(receipt, source), custody = sourceCustody(repository, sources, selected.files);
  const sourceFile = file => join(file.scope === 'registry' ? sources : repository, file.source.path);
  for (const file of selected.files) await lockedSourceFacts(sourceFile(file), file.source, budget);
  const bytes = encode({ schemaVersion: 1, kind: 'locked-codec-notice-material', product: source.product, tag, version: source.version, sourceCommit: commit, sourceInputsSha256: hash(encode(source)), cargoReceiptSha256: cargoSha256, collectionScope: 'codec-conventional-notice-files-and-manifest-metadata', rightsReview: 'required', publicationAuthority: 'none', ...selected });
  if (bytes.length > 1024 * 1024) fail('codec notice inventory limit');
  const parent = dirname(output), parentStat = directory(parent), physical = join(realpathSync(parent), basename(output));
  if (physical === repository || [...inputs, join(repository, 'codec')].map(path => realpathSync(path)).some(path => physical === path || physical.startsWith(path + sep) || path.startsWith(physical + sep)) || (physical.startsWith(repository + sep) && !releaseGit(repository, ['check-ignore', '--no-index', physical]).length)) fail('codec notice output overlaps inputs');
  let exists = false; try { lstatSync(output); exists = true; } catch (error) { if (error.code !== 'ENOENT') throw error; }
  const record = join(output, 'notices.json'), root = join(output, 'files'), pending = join(output, 'collect.pending'), marker = Buffer.from('incomplete codec notice collection\n'); let created;
  if (exists) {
    created = directory(output, true);
    if (!same(materialDirectoryNames(output), ['files', 'notices.json']) || lstatSync(record).nlink !== 1 || !(await readReleaseInput(record, { maximum: 1024 * 1024, privateKey: true })).equals(bytes)) fail('incomplete or conflicting codec notice output');
  } else {
    mkdirSync(output, { mode: 0o700 }); created = directory(output, true); writeFileSync(pending, marker, { flag: 'wx', mode: 0o600 }); synchronize(pending); mkdirSync(root, { mode: 0o700 }); synchronize(output, true);
    for (const path of parentsOf(selected.files.map(file => file.retainedPath))) mkdirSync(join(root, path), { mode: 0o700 });
    for (const file of selected.files) { const raw = await readReleaseInput(sourceFile(file), { maximum: 1024 * 1024 }); if (raw.length !== file.source.bytes || hash(raw) !== file.source.sha256) fail('codec notice source changed before copying'); writeFileSync(join(root, file.retainedPath), raw, { flag: 'wx', mode: 0o600 }); }
  }
  const copied = await copiedCustody(root, selected.files, !exists);
  await replay(); await verifyInputs(repository, tag, commit, sourcePath); budget();
  // All source/version/parser children finish before the final static checks.
  for (const file of source.files) await lockedSourceFacts(join(repository, file.path), { ...file, mode: file.mode === '100755' ? 0o755 : 0o644 }, budget);
  await readReceipt();
  for (const file of selected.files) await lockedSourceFacts(sourceFile(file), file.source, budget);
  if (!same(custody, sourceCustody(repository, sources, selected.files)) || !same(copied, await copiedCustody(root, selected.files)) || !same(before, inputCustody()) || !same(identity(parentStat), identity(directory(parent))) || !same(identity(created), identity(directory(output, true))) || !same(materialDirectoryNames(output), exists ? ['files', 'notices.json'] : ['collect.pending', 'files'])) fail('codec notice custody/namespace changed');
  if (exists) { if (lstatSync(record).nlink !== 1 || !(await readReleaseInput(record, { maximum: 1024 * 1024, privateKey: true })).equals(bytes)) fail('retained codec notice inventory changed'); }
  else {
    if (lstatSync(pending).nlink !== 1 || !(await readReleaseInput(pending, { maximum: 1024, privateKey: true })).equals(marker)) fail('codec notice pending custody changed');
    writeFileSync(record, bytes, { flag: 'wx', mode: 0o600 }); synchronize(record);
    if (!same(identity(created), identity(directory(output, true))) || !same(materialDirectoryNames(output), ['collect.pending', 'files', 'notices.json']) || lstatSync(record).nlink !== 1 || lstatSync(pending).nlink !== 1 || !(await readReleaseInput(record, { maximum: 1024 * 1024, privateKey: true })).equals(bytes) || !(await readReleaseInput(pending, { maximum: 1024, privateKey: true })).equals(marker)) fail('codec notice completion custody changed');
    unlinkSync(pending); synchronize(output, true); synchronize(parent, true);
  }
  return { publicationAuthority: 'none', rightsReview: 'required', packages: selected.packages.length, files: selected.files.length, packagesWithoutConventionalNoticeFile: selected.packages.filter(item => !item.conventionalNoticeFiles.length).length, recordSha256: hash(bytes), disposition: exists ? 'retained-bytes-verified' : 'notice-bytes-collected' };
}
