import { createHash } from 'node:crypto';
import { constants, closeSync, fstatSync, fsyncSync, lstatSync, mkdirSync, openSync, readdirSync, realpathSync, unlinkSync, writeFileSync } from 'node:fs';
import { basename, dirname, join, resolve, sep } from 'node:path';
import { isDeepStrictEqual as same } from 'node:util';
import { coreMaterialParse, generatedCoreSourceInput } from '../core-material.mjs';
import { gleamSourceManifest } from '../gleam-material.mjs';
import { readReleaseInput } from '../files.mjs';
import { verifyInputs } from '../inputs.mjs';
import { releaseGit } from '../source.mjs';
import { inspectMacCandidate } from './cohort.mjs';
import { auditMacBundle } from './closure.mjs';
import { macImageTool } from './dmg.mjs';

const encode = value => Buffer.from(JSON.stringify(value) + '\n');
const hash = value => createHash('sha256').update(value).digest('hex');
const fail = message => { throw new Error(message); };
const digest = value => typeof value === 'string' && /^[0-9a-f]{64}$/.test(value);
const keys = (value, names) => value && typeof value === 'object' && !Array.isArray(value) && same(Object.keys(value).sort(), names.split(' ').sort());
const safePath = path => typeof path === 'string' && Buffer.byteLength(path) <= 512 && path.split('/').length <= 32 && !/[\u0000-\u001f\u007f\\]/.test(path) && path.split('/').every(part => part && part !== '.' && part !== '..');
const identity = stat => ['dev', 'ino', 'mode', 'uid', 'gid'].map(key => String(stat[key]));
function directory(path) {
  const stat = lstatSync(path, { bigint: true });
  if (!stat.isDirectory() || stat.uid !== BigInt(process.getuid()) || (stat.mode & 0o7777n) !== 0o700n) fail('unsafe Mac material custody directory');
  return stat;
}
function synchronize(path, isDirectory = false) {
  const fd = openSync(path, constants.O_RDONLY | constants.O_NOFOLLOW | constants.O_NONBLOCK | (isDirectory ? constants.O_DIRECTORY : 0));
  try {
    const stat = fstatSync(fd), named = lstatSync(path);
    if (!(isDirectory ? stat.isDirectory() && named.isDirectory() : stat.isFile() && named.isFile()) || stat.dev !== named.dev || stat.ino !== named.ino) fail('Mac material sync custody changed');
    fsyncSync(fd);
  } finally { closeSync(fd); }
}
async function receipt(path, expectedDigest, source, kind) {
  if (!digest(expectedDigest)) fail('invalid Mac material receipt digest');
  const parent = directory(dirname(resolve(path))), names = readdirSync(dirname(resolve(path))).sort();
  if (lstatSync(path).nlink !== 1) fail('Mac material receipt alias');
  const bytes = await readReleaseInput(path, { maximum: 16 * 1024 * 1024, privateKey: true });
  let value; try { value = JSON.parse(new TextDecoder('utf-8', { fatal: true }).decode(bytes)); } catch { fail('invalid Mac material receipt'); }
  if (!bytes.equals(encode(value)) || hash(bytes) !== expectedDigest || value.schemaVersion !== 1 || value.kind !== kind || value.product !== source.product || value.tag !== source.tag || value.version !== source.version || value.sourceCommit !== source.commit || value.sourceInputsSha256 !== hash(encode(source)) || value.publicationAuthority !== 'none' || !digest(value.parserSourceSha256)) fail('Mac material receipt identity differs');
  if (lstatSync(path).nlink !== 1 || !same(identity(parent), identity(directory(dirname(resolve(path))))) || !same(names, readdirSync(dirname(resolve(path))).sort())) fail('Mac material receipt namespace changed');
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
async function joinInputs(repository, source, core, gleam, candidate) {
  if (!keys(core, 'schemaVersion kind product tag version sourceCommit sourceInputsSha256 parserSourceSha256 publicationAuthority lockSha256 packages') || !keys(gleam, 'schemaVersion kind product tag version sourceCommit sourceInputsSha256 parserSourceSha256 publicationAuthority manifestSha256 fetchedMetadataSha256 fetchedMetadataMode requirements packages') || core.parserSourceSha256 !== gleam.parserSourceSha256 || !Array.isArray(core.packages) || !Array.isArray(gleam.packages)) fail('unsupported Mac material receipt schema');
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
    } else if (item.lock.sparse && item.files.some(file => !file.path.startsWith(item.lock.sparse + '/'))) fail('Git receipt source outside sparse subtree');
    sourceFacts(`apps/core/deps/${item.lock.key}/`, item, proved, limits);
  }
  for (const item of gleam.packages) {
    if (!keys(item, 'lock innerChecksum parser files directories') || !digest(item.innerChecksum)) fail('invalid Gleam receipt package');
    admitParser(item.parser); sourceFacts(`packages/decision-kernel/build/packages/${item.lock.name}/`, item, proved, limits);
  }
  if (!digest(gleam.fetchedMetadataSha256) || !Number.isInteger(gleam.fetchedMetadataMode) || gleam.fetchedMetadataMode < 0 || gleam.fetchedMetadataMode > 0o777 || (gleam.fetchedMetadataMode & 0o002) !== 0 || (gleam.fetchedMetadataMode & 0o400) === 0) fail('invalid Gleam fetched metadata facts');
  const metadataPath = 'packages/decision-kernel/build/packages/packages.toml', captured = new Map(candidate.material.map(file => [file.path, file]));
  const metadata = captured.get(metadataPath);
  if (!metadata || metadata.sha256 !== gleam.fetchedMetadataSha256 || metadata.mode !== gleam.fetchedMetadataMode || metadata.bytes < 1 || metadata.bytes > 64 * 1024) fail('captured Gleam metadata differs from receipt');
  for (const [path, file] of proved) if (!same(file, captured.get(path))) fail('captured source differs from admitted receipt');
  proved.set(metadataPath, metadata);
  const generated = [];
  for (const file of candidate.material) {
    if (proved.has(file.path)) continue;
    const local = file.path.replace(/^apps\/core\/deps\//, ''), input = generatedCoreSourceInput(local), key = local.split('/')[0];
    let reason;
    if (input && proved.has(`apps/core/deps/${key}/${input}`)) reason = 'generated-lexer-parser';
    else if (file.path === 'apps/core/deps/file_system/priv/mac_listener' && proved.has('apps/core/deps/file_system/c_src/mac/main.c')) reason = 'generated-native-helper';
    else if (file.path === 'packages/decision-kernel/build/packages/gleam.lock' && file.bytes === 0 && file.sha256 === hash(Buffer.alloc(0))) reason = 'compiler-lock-metadata';
    else fail('unexplained captured dependency input');
    generated.push({ ...file, reason });
  }
  return { provedSourceFiles: proved.size, generatedInputs: generated };
}

export async function macMaterialJoin({ repository, tag, commit, sourcePath, architecture, candidate, candidateSha256, corePath, coreSha256, gleamPath, gleamSha256, output }, { tool = macImageTool } = {}) {
  repository = realpathSync(repository); output = resolve(output);
  const deadline = performance.now() + 180_000, budget = () => { if (performance.now() > deadline) fail('Mac material join processing deadline'); };
  const source = await verifyInputs(repository, tag, commit, sourcePath); budget();
  const inputDirectories = [candidate, dirname(resolve(corePath)), dirname(resolve(gleamPath))].map(path => resolve(path));
  const custody = () => inputDirectories.map(path => ({ identity: identity(directory(path)), names: readdirSync(path).sort() }));
  const initialCustody = custody();
  const inspect = async () => {
    const core = await receipt(corePath, coreSha256, source, 'locked-core-source-material'), gleam = await receipt(gleamPath, gleamSha256, source, 'locked-gleam-source-material');
    const retained = await inspectMacCandidate({ repository, source, candidate, expectedDigest: candidateSha256, architecture }, tool); budget();
    const joined = await joinInputs(repository, source, core, gleam, retained); budget(); return joined;
  };
  const joined = await inspect(), parent = dirname(output), parentStat = lstatSync(parent, { bigint: true });
  if (!parentStat.isDirectory() || parentStat.uid !== BigInt(process.getuid()) || (parentStat.mode & 0o022n) !== 0n) fail('unsafe Mac material output parent');
  const physical = join(realpathSync(parent), basename(output)), inputs = [candidate, dirname(corePath), dirname(gleamPath)].map(path => realpathSync(path));
  if (physical === repository || inputs.some(path => physical === path || physical.startsWith(path + sep) || path.startsWith(physical + sep)) || (physical.startsWith(repository + sep) && !releaseGit(repository, ['check-ignore', '--no-index', physical]).length)) fail('Mac material output overlaps inputs');
  const bytes = encode({ schemaVersion: 1, kind: 'macos-dependency-input-join', product: source.product, tag, version: source.version, sourceCommit: commit,
    sourceInputsSha256: hash(encode(source)), architecture, candidateRecordSha256: candidateSha256, coreReceiptSha256: coreSha256, gleamReceiptSha256: gleamSha256, publicationAuthority: 'none', ...joined });
  if (bytes.length > 64 * 1024) fail('Mac material joined record limit');
  const path = join(output, 'dependency-inputs.json'), pending = join(output, 'check.pending'), marker = Buffer.from('incomplete Mac dependency input join\n');
  let exists = false; try { lstatSync(output); exists = true; } catch (error) { if (error.code !== 'ENOENT') throw error; }
  let created;
  if (exists) {
    created = directory(output);
    if (!same(readdirSync(output).sort(), ['dependency-inputs.json']) || lstatSync(path).nlink !== 1 || !(await readReleaseInput(path, { maximum: 64 * 1024, privateKey: true })).equals(bytes)) fail('incomplete or conflicting Mac material output');
  } else {
    mkdirSync(output, { mode: 0o700 }); created = directory(output);
    writeFileSync(pending, marker, { flag: 'wx', mode: 0o600 }); synchronize(pending); synchronize(output, true);
  }
  await verifyInputs(repository, tag, commit, sourcePath); budget();
  if (!same(joined, await inspect())) fail('Mac material inputs changed');
  await verifyInputs(repository, tag, commit, sourcePath); budget();
  // Finish with descriptor/byte checks after every version/parser child. This
  // catches a child-time change to another input already read in that pass.
  await receipt(corePath, coreSha256, source, 'locked-core-source-material');
  await receipt(gleamPath, gleamSha256, source, 'locked-gleam-source-material');
  const candidatePath = join(candidate, 'candidate.json');
  const candidateBytes = await readReleaseInput(candidatePath, { maximum: 16 * 1024 * 1024, privateKey: true });
  if (lstatSync(candidatePath).nlink !== 1 || hash(candidateBytes) !== candidateSha256 || !same(JSON.parse(candidateBytes).bundle, await auditMacBundle(join(candidate, 'Frameshift.app'), architecture))) fail('Mac material final candidate custody changed');
  budget();
  if (!same(initialCustody, custody()) || !same(identity(parentStat), identity(lstatSync(parent, { bigint: true })))) fail('Mac material input/parent namespace changed');
  if (!same(identity(created), identity(directory(output))) || !same(readdirSync(output).sort(), exists ? ['dependency-inputs.json'] : ['check.pending'])) fail('Mac material output custody changed');
  if (exists) {
    if (lstatSync(path).nlink !== 1 || !(await readReleaseInput(path, { maximum: 64 * 1024, privateKey: true })).equals(bytes)) fail('Mac material replay changed');
  } else {
    if (lstatSync(pending).nlink !== 1 || !(await readReleaseInput(pending, { maximum: 1024, privateKey: true })).equals(marker)) fail('Mac material pending custody changed');
    writeFileSync(path, bytes, { flag: 'wx', mode: 0o600 }); synchronize(path);
    if (!same(identity(created), identity(directory(output))) || !same(readdirSync(output).sort(), ['check.pending', 'dependency-inputs.json']) || lstatSync(path).nlink !== 1 || !(await readReleaseInput(path, { maximum: 64 * 1024, privateKey: true })).equals(bytes) || !(await readReleaseInput(pending, { maximum: 1024, privateKey: true })).equals(marker)) fail('Mac material completion custody changed');
    unlinkSync(pending); synchronize(output, true); synchronize(parent, true);
  }
  return { publicationAuthority: 'none', architecture, ...joined, recordSha256: hash(bytes), disposition: exists ? 'retained-bytes-verified' : 'dependency-inputs-joined' };
}
