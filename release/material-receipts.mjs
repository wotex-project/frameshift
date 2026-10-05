import { createHash } from 'node:crypto';
import { lstatSync, opendirSync } from 'node:fs';
import { dirname, join, resolve } from 'node:path';
import { isDeepStrictEqual as same } from 'node:util';
import { coreMaterialParse, generatedCoreSourceInput } from './core-material.mjs';
import { gleamSourceManifest } from './gleam-material.mjs';
import { readReleaseInput } from './files.mjs';

const encode = value => Buffer.from(JSON.stringify(value) + '\n');
const hash = value => createHash('sha256').update(value).digest('hex');
const fail = message => { throw new Error(message); };
const digest = value => typeof value === 'string' && /^[0-9a-f]{64}$/.test(value);
const keys = (value, names) => value && typeof value === 'object' && !Array.isArray(value) && same(Object.keys(value).sort(), names.split(' ').sort());
export const materialPath = path => typeof path === 'string' && Buffer.byteLength(path) <= 512 && path.split('/').length <= 32 && !/[\u0000-\u001f\u007f\\]/.test(path) && path.split('/').every(part => part && part !== '.' && part !== '..');
const safePath = materialPath;
const identity = stat => ['dev', 'ino', 'mode', 'uid', 'gid'].map(key => String(stat[key]));
export function materialDirectoryNames(path) {
  const handle = opendirSync(path), names = [];
  try {
    let entry; while ((entry = handle.readSync()) !== null) {
      if (names.length === 8192) fail('material directory namespace limit');
      names.push(entry.name);
    }
  } finally { handle.closeSync(); }
  return names.sort();
}
function directory(path) {
  const stat = lstatSync(path, { bigint: true });
  if (!stat.isDirectory() || stat.uid !== BigInt(process.getuid()) || (stat.mode & 0o7777n) !== 0o700n) fail('unsafe material custody directory');
  return stat;
}
export function validateCapturedFacts(files) {
  if (!Array.isArray(files) || !files.length || files.length > 8192) fail('invalid captured material inventory');
  const seen = new Set(); let bytes = 0;
  for (const file of files) {
    if (!keys(file, 'path mode bytes sha256') || !safePath(file.path) || seen.has(file.path) || !Number.isInteger(file.mode) || file.mode < 0 || file.mode > 0o777 || (file.mode & 0o002) !== 0 || (file.mode & 0o400) === 0 || !Number.isSafeInteger(file.bytes) || file.bytes < 0 || file.bytes > 128 * 1024 * 1024 || !digest(file.sha256) || (bytes += file.bytes) > 512 * 1024 * 1024) fail('invalid captured material file');
    seen.add(file.path);
  }
  for (const path of seen) { let parent = dirname(path); while (parent !== '.') { if (seen.has(parent)) fail('captured material file/directory conflict'); parent = dirname(parent); } }
}
function retainedGitPath(path, locks) {
  const match = /^apps\/core\/deps\/([^/]+)\/\.git\/(.+)$/.exec(path);
  if (!match || !locks.some(lock => lock.type === 'git' && lock.key === match[1])) return false;
  const name = match[2];
  if (['HEAD', 'FETCH_HEAD', 'config', 'description', 'index', 'info/exclude', 'info/sparse-checkout', 'objects/info/commit-graphs/commit-graph-chain'].includes(name)) return true;
  if (/^objects\/pack\/pack-[0-9a-f]{40}\.(?:pack|idx|rev)$/.test(name) || /^objects\/info\/commit-graphs\/graph-[0-9a-f]{40}\.graph$/.test(name)) return true;
  const reference = /^(?:refs\/heads\/|refs\/remotes\/origin\/)(.+)$/.exec(name);
  return Boolean(reference && reference[1].split('/').every(part => /^[A-Za-z0-9][A-Za-z0-9._-]{0,127}$/.test(part)));
}
export async function readMaterialReceipt(path, expectedDigest, source, kind) {
  if (!digest(expectedDigest)) fail('invalid material receipt digest');
  const parent = directory(dirname(resolve(path))), names = materialDirectoryNames(dirname(resolve(path)));
  if (lstatSync(path).nlink !== 1) fail('material receipt alias');
  const bytes = await readReleaseInput(path, { maximum: 16 * 1024 * 1024, privateKey: true });
  let value; try { value = JSON.parse(new TextDecoder('utf-8', { fatal: true }).decode(bytes)); } catch { fail('invalid material receipt'); }
  if (!bytes.equals(encode(value)) || hash(bytes) !== expectedDigest || value.schemaVersion !== 1 || value.kind !== kind || value.product !== source.product || value.tag !== source.tag || value.version !== source.version || value.sourceCommit !== source.commit || value.sourceInputsSha256 !== hash(encode(source)) || value.publicationAuthority !== 'none' || !digest(value.parserSourceSha256)) fail('material receipt identity differs');
  if (lstatSync(path).nlink !== 1 || !same(identity(parent), identity(directory(dirname(resolve(path))))) || !same(names, materialDirectoryNames(dirname(resolve(path))))) fail('material receipt namespace changed');
  return value;
}
function parserFacts(parser) {
  if (!keys(parser, 'hex modules') || parser.hex !== '2.5.1' || !Array.isArray(parser.modules) || parser.modules.length !== 3) fail('unsupported material parser observation');
  const names = ['Elixir.Hex.SCM', 'mix_hex_tarball', 'mix_hex_erl_tar'];
  if (parser.modules.some((entry, i) => !keys(entry, 'name sha256') || entry.name !== names[i] || !digest(entry.sha256))) fail('invalid material parser modules');
  return parser;
}
function sourceFacts(prefix, item, proved, limits) {
  if (!Array.isArray(item.files) || !item.files.length || !Array.isArray(item.directories) || !item.directories.length || item.files.length + item.directories.length > 8192) fail('invalid material receipt source inventory');
  const directories = new Set();
  for (const entry of item.directories) {
    if (!keys(entry, 'path mode') || (entry.path !== '' && !safePath(entry.path)) || directories.has(entry.path) || !Number.isInteger(entry.mode) || entry.mode < 0 || entry.mode > 0o777 || (entry.mode & 0o022) !== 0 || ++limits.entries > 8192) fail('invalid material receipt directory');
    directories.add(entry.path);
  }
  if (!directories.has('')) fail('material receipt root directory missing');
  for (const file of item.files) {
    if (!keys(file, 'path mode bytes sha256') || !safePath(file.path) || !Number.isInteger(file.mode) || file.mode < 0 || file.mode > 0o777 || (file.mode & 0o002) !== 0 || (file.mode & 0o400) === 0 || !Number.isSafeInteger(file.bytes) || file.bytes < 0 || file.bytes > 128 * 1024 * 1024 || !digest(file.sha256)) fail('invalid material receipt source file');
    let parent = dirname(file.path); while (parent !== '.') { if (!directories.has(parent)) fail('material receipt source parent missing'); parent = dirname(parent); }
    const path = prefix + file.path;
    if (proved.has(path) || ++limits.entries > 8192 || (limits.bytes += file.bytes) > 512 * 1024 * 1024) fail('duplicate or excessive material receipt source');
    proved.set(path, { ...file, path });
  }
}
export async function joinDependencyInputs(repository, core, gleam, material, { gitMetadata = false } = {}) {
  if (!keys(core, 'schemaVersion kind product tag version sourceCommit sourceInputsSha256 parserSourceSha256 publicationAuthority lockSha256 packages') || !keys(gleam, 'schemaVersion kind product tag version sourceCommit sourceInputsSha256 parserSourceSha256 publicationAuthority manifestSha256 fetchedMetadataSha256 fetchedMetadataMode requirements packages') || core.parserSourceSha256 !== gleam.parserSourceSha256 || !Array.isArray(core.packages) || !Array.isArray(gleam.packages)) fail('unsupported material receipt schema');
  const lockBytes = await readReleaseInput(join(repository, 'apps/core/mix.lock'), { maximum: 64 * 1024 }), locks = coreMaterialParse('lock', lockBytes);
  const manifestBytes = await readReleaseInput(join(repository, 'packages/decision-kernel/manifest.toml'), { maximum: 64 * 1024 }), manifest = gleamSourceManifest(manifestBytes);
  if (core.lockSha256 !== hash(lockBytes) || gleam.manifestSha256 !== hash(manifestBytes) || !same(core.packages.map(item => item.lock), locks) || !same(gleam.packages.map(item => item.lock), manifest.packages) || !same(gleam.requirements, manifest.requirements)) fail('material receipt differs from frozen dependency identities');
  const proved = new Map(), limits = { bytes: 0, entries: 0 }; let parser;
  const admitParser = value => { const next = parserFacts(value); if (parser && !same(parser, next)) fail('source receipt parser cohorts differ'); parser = next; };
  for (const item of core.packages) {
    if (!keys(item, item.lock.type === 'hex' ? 'lock parser files directories' : 'lock files directories')) fail('invalid core receipt package');
    if (item.lock.type === 'hex') {
      admitParser(item.parser);
      if (!item.files.some(file => file.path === '.hex') || !item.files.some(file => file.path === 'hex_metadata.config')) fail('core Hex metadata facts missing');
    } else {
      if (item.files.some(file => file.path.split('/').includes('.git'))) fail('Git receipt private metadata is not source');
      if (item.lock.sparse && item.files.some(file => !file.path.startsWith(item.lock.sparse + '/'))) fail('Git receipt source outside sparse subtree');
    }
    sourceFacts(`apps/core/deps/${item.lock.key}/`, item, proved, limits);
  }
  for (const item of gleam.packages) {
    if (!keys(item, 'lock innerChecksum parser files directories') || !digest(item.innerChecksum)) fail('invalid Gleam receipt package');
    admitParser(item.parser); sourceFacts(`packages/decision-kernel/build/packages/${item.lock.name}/`, item, proved, limits);
  }
  if (!digest(gleam.fetchedMetadataSha256) || !Number.isInteger(gleam.fetchedMetadataMode) || gleam.fetchedMetadataMode < 0 || gleam.fetchedMetadataMode > 0o777 || (gleam.fetchedMetadataMode & 0o002) !== 0 || (gleam.fetchedMetadataMode & 0o400) === 0) fail('invalid Gleam fetched metadata facts');
  validateCapturedFacts(material);
  const metadataPath = 'packages/decision-kernel/build/packages/packages.toml', captured = new Map(material.map(file => [file.path, file]));
  const metadata = captured.get(metadataPath);
  if (!metadata || metadata.sha256 !== gleam.fetchedMetadataSha256 || metadata.mode !== gleam.fetchedMetadataMode || metadata.bytes < 1 || metadata.bytes > 64 * 1024) fail('captured Gleam metadata differs from receipt');
  for (const [path, file] of proved) if (!same(file, captured.get(path))) fail('captured source differs from admitted receipt');
  proved.set(metadataPath, metadata);
  const generated = [], retainedGitMetadata = [];
  for (const file of material) {
    if (proved.has(file.path)) continue;
    const local = file.path.replace(/^apps\/core\/deps\//, ''), input = generatedCoreSourceInput(local), key = local.split('/')[0];
    let reason;
    if (input && proved.has(`apps/core/deps/${key}/${input}`)) reason = 'generated-lexer-parser';
    else if (file.path === 'apps/core/deps/file_system/priv/mac_listener' && proved.has('apps/core/deps/file_system/c_src/mac/main.c')) reason = 'generated-native-helper';
    else if (file.path === 'packages/decision-kernel/build/packages/gleam.lock' && file.bytes === 0 && file.sha256 === hash(Buffer.alloc(0))) reason = 'compiler-lock-metadata';
    else if (gitMetadata && retainedGitPath(file.path, locks)) {
      retainedGitMetadata.push({ ...file, reason: 'retained-git-build-metadata' }); continue;
    } else fail('unexplained captured dependency input');
    generated.push({ ...file, reason });
  }
  return { provedSourceFiles: proved.size, generatedInputs: generated, ...(gitMetadata ? { retainedGitMetadata } : {}) };
}
