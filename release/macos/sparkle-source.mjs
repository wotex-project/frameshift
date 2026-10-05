import { spawnSync } from 'node:child_process';
import { createHash } from 'node:crypto';
import { constants, closeSync, fstatSync, fsyncSync, lstatSync, mkdirSync, openSync, readdirSync, realpathSync, unlinkSync, writeFileSync } from 'node:fs';
import { basename, dirname, join, posix, resolve, sep } from 'node:path';
import { isDeepStrictEqual as same } from 'node:util';
import { readReleaseInput } from '../files.mjs';
import { verifyInputs } from '../inputs.mjs';
import { materialPath, readMaterialReceipt, validateCapturedFacts } from '../material-receipts.mjs';
import { sparkleArchive, sparkleLinks, sparkleRoles, sparkleRoot } from '../macos-framework.mjs';
import { releaseGit } from '../source.mjs';
import { verifySparkleFramework } from './sparkle-material.mjs';

const owner = resolve(new URL('../..', import.meta.url).pathname);
const encode = value => Buffer.from(JSON.stringify(value) + '\n'), hash = bytes => createHash('sha256').update(bytes).digest('hex');
const fail = () => { throw new Error('updater source inputs or receipt unavailable, unsafe or changed'); };
const identity = stat => ['dev', 'ino', 'mode', 'uid', 'gid', 'nlink', 'size', 'mtimeNs', 'ctimeNs'].map(key => String(stat[key]));
const stableDirectory = stat => ['dev', 'ino', 'mode', 'uid', 'gid'].map(key => String(stat[key]));
const keys = (value, names) => value && typeof value === 'object' && !Array.isArray(value) && same(Object.keys(value).sort(), names.split(' ').sort());
const digest = value => typeof value === 'string' && /^[0-9a-f]{64}$/.test(value);
const relative = path => path.slice(sparkleRoot.length + 1);
function directory(path, privateMode = false) {
  const stat = lstatSync(path, { bigint: true });
  if (!stat.isDirectory() || stat.uid !== BigInt(process.getuid()) || (stat.mode & 0o7022n) || (privateMode && (stat.mode & 0o7777n) !== 0o700n)) fail();
  return stat;
}
function synchronize(path, isDirectory = false) {
  const fd = openSync(path, constants.O_RDONLY | constants.O_NOFOLLOW | constants.O_NONBLOCK | (isDirectory ? constants.O_DIRECTORY : 0));
  try {
    const opened = fstatSync(fd), named = lstatSync(path);
    if (!(isDirectory ? opened.isDirectory() && named.isDirectory() : opened.isFile() && named.isFile()) || opened.dev !== named.dev || opened.ino !== named.ino) fail();
    fsyncSync(fd);
  } finally { closeSync(fd); }
}
export function readSwiftManifest(packageRoot, timeout = 60_000) {
  const result = spawnSync('/usr/bin/swift', ['package', '--package-path', packageRoot, 'dump-package'], { encoding: 'utf8', timeout, maxBuffer: 512 * 1024, stdio: ['ignore', 'pipe', 'pipe'] });
  if (result.error || result.status !== 0) fail();
  try { return JSON.parse(result.stdout); } catch { fail(); }
}
function binaryIdentity(manifest) {
  if (!Array.isArray(manifest.targets)) fail();
  const targets = manifest.targets.filter(target => target.type === 'binary');
  if (targets.length !== 1 || targets[0].name !== 'Sparkle' || targets[0].url !== sparkleArchive.url || targets[0].checksum !== sparkleArchive.sha256) fail();
  return { name: 'Sparkle', url: targets[0].url, checksum: targets[0].checksum };
}
function frameworkCustody(root, content) {
  return [...content.files, ...content.directories, ...content.links].map(item => ({ path: item.path, identity: identity(lstatSync(join(root, item.path), { bigint: true })) }));
}

export async function checkSparkleSource({ repository, tag, commit, sourcePath, archive, framework, output }, { manifest = readSwiftManifest } = {}) {
  repository = realpathSync(repository); archive = resolve(archive); framework = resolve(framework); output = resolve(output);
  const deadline = performance.now() + 360_000, budget = () => { if (performance.now() >= deadline) fail(); };
  const source = await verifyInputs(repository, tag, commit, sourcePath); budget();
  const packageRoot = join(repository, 'apps/macos'), packagePath = join(packageRoot, 'Package.swift');
  const packageBytes = await readReleaseInput(packagePath, { maximum: 64 * 1024, protectedTrust: true });
  const parserPaths = ['release/macos/sparkle-source.mjs', 'release/macos/sparkle-material.mjs', 'release/macos-framework.mjs'];
  const parserBytes = await Promise.all(parserPaths.map(path => readReleaseInput(join(owner, path), { maximum: 64 * 1024, protectedTrust: true })));
  const inspect = async () => {
    const binary = binaryIdentity(manifest(packageRoot, Math.max(1, Math.min(60_000, Math.floor(deadline - performance.now()))))); budget();
    const input = await verifySparkleFramework(archive, framework); budget();
    return { binary, packageSha256: hash(await readReleaseInput(packagePath, { maximum: 64 * 1024, protectedTrust: true })),
      archive: input.archive, framework: input.framework, native: input.native };
  };
  const observation = await inspect(), archiveCustody = identity(lstatSync(archive, { bigint: true })), cachedCustody = frameworkCustody(framework, observation.framework);
  if (observation.packageSha256 !== hash(packageBytes)) fail();
  const bytes = encode({ schemaVersion: 1, kind: 'pinned-sparkle-source-material', product: source.product, tag, version: source.version, sourceCommit: commit,
    sourceInputsSha256: hash(encode(source)), parserSourceSha256: hash(Buffer.concat(parserBytes)), publicationAuthority: 'none', ...observation });
  if (bytes.length > 64 * 1024) fail();
  const parent = dirname(output), parentStat = directory(parent), physical = join(realpathSync(parent), basename(output));
  if ([repository, dirname(archive), framework].some(root => physical === root || root.startsWith(physical + sep) ||
      (root !== repository && physical.startsWith(root + sep))) ||
      (physical.startsWith(repository + sep) && !releaseGit(repository, ['check-ignore', '--no-index', physical]).length)) fail();
  let exists = false; try { lstatSync(output); exists = true; } catch (error) { if (error.code !== 'ENOENT') throw error; }
  const receipt = join(output, 'sparkle-material.json'), pending = join(output, 'check.pending'), marker = Buffer.from('incomplete updater source check\n');
  let created;
  if (exists) {
    created = directory(output, true);
    if (!same(readdirSync(output).sort(), ['sparkle-material.json']) || lstatSync(receipt).nlink !== 1 || !(await readReleaseInput(receipt, { maximum: 64 * 1024, privateKey: true })).equals(bytes)) fail();
  } else {
    mkdirSync(output, { mode: 0o700 }); created = directory(output, true);
    writeFileSync(pending, marker, { flag: 'wx', mode: 0o600 }); synchronize(pending); synchronize(output, true);
  }
  await verifyInputs(repository, tag, commit, sourcePath); budget();
  if (!same(observation, await inspect())) fail();
  await verifyInputs(repository, tag, commit, sourcePath); budget();
  for (let index = 0; index < parserPaths.length; index++) if (!(await readReleaseInput(join(owner, parserPaths[index]), { maximum: 64 * 1024, protectedTrust: true })).equals(parserBytes[index])) fail();
  if (!same(archiveCustody, identity(lstatSync(archive, { bigint: true }))) || !same(cachedCustody, frameworkCustody(framework, observation.framework)) ||
      !same(stableDirectory(parentStat), stableDirectory(directory(parent))) || !same(stableDirectory(created), stableDirectory(directory(output, true))) ||
      !same(readdirSync(output).sort(), exists ? ['sparkle-material.json'] : ['check.pending'])) fail();
  if (exists) {
    if (lstatSync(receipt).nlink !== 1 || !(await readReleaseInput(receipt, { maximum: 64 * 1024, privateKey: true })).equals(bytes)) fail();
  } else {
    if (lstatSync(pending).nlink !== 1 || !(await readReleaseInput(pending, { maximum: 1024, privateKey: true })).equals(marker)) fail();
    writeFileSync(receipt, bytes, { flag: 'wx', mode: 0o600 }); synchronize(receipt);
    if (!same(stableDirectory(created), stableDirectory(directory(output, true))) || !same(readdirSync(output).sort(), ['check.pending', 'sparkle-material.json']) ||
        lstatSync(receipt).nlink !== 1 || !(await readReleaseInput(receipt, { maximum: 64 * 1024, privateKey: true })).equals(bytes) ||
        !(await readReleaseInput(pending, { maximum: 1024, privateKey: true })).equals(marker)) fail();
    unlinkSync(pending); synchronize(output, true); synchronize(parent, true);
  }
  return { publicationAuthority: 'none', files: observation.framework.files.length, links: observation.framework.links.length,
    receiptSha256: hash(bytes), disposition: exists ? 'retained-bytes-verified' : 'source-bytes-recorded' };
}

export async function readSparkleSourceReceipt(path, expectedDigest, source) {
  const bytes = await readReleaseInput(path, { maximum: 64 * 1024, privateKey: true });
  const record = await readMaterialReceipt(path, expectedDigest, source, 'pinned-sparkle-source-material');
  if (!bytes.equals(encode(record)) || !keys(record, 'schemaVersion kind product tag version sourceCommit sourceInputsSha256 parserSourceSha256 publicationAuthority binary packageSha256 archive framework native') ||
      !same(record.archive, sparkleArchive) || !same(record.binary, { name: 'Sparkle', url: sparkleArchive.url, checksum: sparkleArchive.sha256 }) ||
      !digest(record.packageSha256) || record.packageSha256 !== source.files.find(file => file.path === 'apps/macos/Package.swift')?.sha256 ||
      !keys(record.framework, 'files directories links') || !Array.isArray(record.framework.files) || record.framework.files.length !== 85 ||
      !Array.isArray(record.framework.directories) || record.framework.directories.length !== 57 || !Array.isArray(record.framework.links) || record.framework.links.length !== 9 ||
      !Array.isArray(record.native) || record.native.length !== 5) fail();
  validateCapturedFacts(record.framework.files);
  if (record.framework.files.some(file => file.bytes > 16 * 1024 * 1024 || (file.mode & 0o022)) ||
      record.framework.files.reduce((sum, file) => sum + file.bytes, 0) > 64 * 1024 * 1024 ||
      record.native.some(file => !keys(file, 'path slices') || !materialPath(file.path))) fail();
  const directories = new Set();
  for (const entry of record.framework.directories) {
    if (!keys(entry, 'path mode') || (entry.path !== '' && !materialPath(entry.path)) || directories.has(entry.path) ||
        !Number.isInteger(entry.mode) || entry.mode < 0 || entry.mode > 0o777 || (entry.mode & 0o022)) fail();
    directories.add(entry.path);
  }
  if (!directories.has('') || !same(record.framework.links, [...sparkleLinks].map(([path, target]) => ({ path: relative(path), target })).sort((a, b) => a.path.localeCompare(b.path)))) fail();
  const members = new Set([...directories, ...record.framework.files.map(file => file.path)]);
  const files = new Set(record.framework.files.map(file => file.path));
  for (const entry of record.framework.directories) {
    let parent = dirname(entry.path); while (parent !== '.') { if (!directories.has(parent)) fail(); parent = dirname(parent); }
  }
  for (const file of record.framework.files) {
    if (directories.has(file.path)) fail();
    let parent = dirname(file.path); while (parent !== '.') { if (!directories.has(parent)) fail(); parent = dirname(parent); }
  }
  for (const link of record.framework.links) if (members.has(link.path) || !members.has(link.path === 'Versions/Current' ? 'Versions/B' : `Versions/B/${basename(link.path)}`)) fail();
  const native = new Map(record.native.map(file => [file.path, file.slices]));
  if (native.size !== 5) fail();
  for (const [path, type] of sparkleRoles) {
    const slices = native.get(relative(path));
    if (!files.has(relative(path)) || !Array.isArray(slices) || slices.length !== 2 || !same(slices.map(slice => slice.arch), ['arm64', 'x86_64']) ||
        slices.some(slice => !keys(slice, 'arch filetype minimum dependencies rpaths') || slice.filetype !== type || slice.minimum !== '12.0.0' ||
          !Array.isArray(slice.rpaths) || slice.rpaths.length || !Array.isArray(slice.dependencies) || slice.dependencies.length > 64 ||
          slice.dependencies.some(path => typeof path !== 'string' || Buffer.byteLength(path) > 512 || posix.normalize(path) !== path || !['/usr/lib/', '/System/Library/'].some(root => path.startsWith(root)) || /[\u0000-\u001f\u007f]/.test(path)))) fail();
  }
  return record;
}

if (process.argv[1] === new URL(import.meta.url).pathname) {
  const args = process.argv.slice(2);
  if (args.length !== 6) { console.error('usage: check-sparkle-source TAG COMMIT SOURCE_RECORD ARCHIVE FRAMEWORK OUTPUT'); process.exitCode = 64; }
  else {
    const [tag, commit, sourcePath, archive, framework, output] = args;
    try { console.log(JSON.stringify(await checkSparkleSource({ repository: owner, tag, commit, sourcePath, archive, framework, output }))); }
    catch { console.error('updater source inputs or receipt unavailable, unsafe or changed'); process.exitCode = 1; }
  }
}
