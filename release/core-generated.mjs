import { spawnSync } from 'node:child_process';
import { createHash } from 'node:crypto';
import { constants, closeSync, fstatSync, fsyncSync, lstatSync, mkdirSync, openSync, realpathSync, unlinkSync, writeFileSync } from 'node:fs';
import { basename, dirname, join, resolve, sep } from 'node:path';
import { isDeepStrictEqual as same } from 'node:util';
import { checkCoreMaterial, generatedCoreSourceInput, lockedSourceFacts } from './core-material.mjs';
import { readReleaseInput } from './files.mjs';
import { verifyInputs } from './inputs.mjs';
import { materialDirectoryNames, readMaterialReceipt, validateCapturedFacts } from './material-receipts.mjs';
import { releaseGit } from './source.mjs';

const owner = resolve(new URL('..', import.meta.url).pathname), helper = join(owner, 'release/core-generated.exs');
const encode = value => Buffer.from(JSON.stringify(value) + '\n');
const hash = value => createHash('sha256').update(value).digest('hex');
const fail = message => { throw new Error(message); };
const digest = value => typeof value === 'string' && /^[0-9a-f]{64}$/.test(value);
const keys = (value, names) => value && typeof value === 'object' && !Array.isArray(value) && same(Object.keys(value).sort(), names.split(' ').sort());
const identity = stat => ['dev', 'ino', 'mode', 'uid', 'gid'].map(key => String(stat[key]));
const fileIdentity = stat => ['dev', 'ino', 'mode', 'uid', 'gid', 'size', 'nlink', 'mtimeNs', 'ctimeNs'].map(key => String(stat[key]));
function directory(path, privateMode = false) {
  const stat = lstatSync(path, { bigint: true });
  if (!stat.isDirectory() || stat.uid !== BigInt(process.getuid()) || (privateMode ? (stat.mode & 0o7777n) !== 0o700n : (stat.mode & 0o7022n) !== 0n)) fail('unsafe generated core directory');
  return stat;
}
function synchronize(path, isDirectory = false) {
  const fd = openSync(path, constants.O_RDONLY | constants.O_NOFOLLOW | constants.O_NONBLOCK | (isDirectory ? constants.O_DIRECTORY : 0));
  try { const opened = fstatSync(fd), named = lstatSync(path); if (!(isDirectory ? opened.isDirectory() && named.isDirectory() : opened.isFile() && named.isFile()) || opened.dev !== named.dev || opened.ino !== named.ino) fail('generated core sync custody changed'); fsyncSync(fd); }
  finally { closeSync(fd); }
}
export function generatedSyntaxTool(operation, root, selections) {
  const env = { ...process.env };
  for (const name of Object.keys(env)) if (name.startsWith('GIT_') || ['ERL_COMPILER_OPTIONS', 'ERL_FLAGS', 'ERL_AFLAGS', 'ERL_ZFLAGS', 'ELIXIR_ERL_OPTIONS', 'ERL_LIBS'].includes(name)) delete env[name];
  env.ERL_CRASH_DUMP = '/dev/null';
  const result = spawnSync('/bin/sh', ['-c', 'ulimit -f 4096 || exit 1; exec "$@"', 'generated-core-child', 'mise', 'exec', '--', 'elixir', helper, operation, root],
    { cwd: owner, env, input: encode(selections), timeout: 30_000, killSignal: 'SIGKILL', maxBuffer: 64 * 1024 });
  if (result.error || result.status !== 0) fail('generated core syntax child unavailable or refused');
  try { return JSON.parse(new TextDecoder('utf-8', { fatal: true }).decode(result.stdout)); } catch { fail('generated core syntax child output refused'); }
}
async function observations(value, expectedFiles) {
  if (!keys(value, 'otp erts parsetools modules templates generated') || value.otp !== '29' || value.erts !== '17.1' || value.parsetools !== '2.8' || !Array.isArray(value.modules) || !Array.isArray(value.templates) || !Array.isArray(value.generated)) fail('unsupported generated core tool cohort');
  const modules = ['leex', 'yecc', 'yeccparser', 'yeccscan'], templates = ['leexinc.hrl', 'yeccpre.hrl'];
  const admit = async (files, names) => {
    if (files.length !== names.length) fail('generated core tool inventory differs');
    const result = [];
    for (const [i, file] of files.entries()) {
      if (!keys(file, 'name path bytes sha256') || file.name !== names[i] || typeof file.path !== 'string' || !file.path.startsWith('/') || !Number.isSafeInteger(file.bytes) || file.bytes < 1 || file.bytes > 8 * 1024 * 1024 || !digest(file.sha256)) fail('invalid generated core tool observation');
      const bytes = await readReleaseInput(file.path, { maximum: 8 * 1024 * 1024, protectedTrust: true });
      if (bytes.length !== file.bytes || hash(bytes) !== file.sha256) fail('generated core tool bytes changed');
      result.push({ name: file.name, bytes: file.bytes, sha256: file.sha256 });
    }
    return result;
  };
  if (!same(value.generated, expectedFiles)) fail('generated core bytes differ from captured inputs');
  return { otp: value.otp, erts: value.erts, parsetools: value.parsetools, modules: await admit(value.modules, modules), templates: await admit(value.templates, templates) };
}
async function joinedReceipt(path, expectedHash, source, coreSha256) {
  directory(dirname(resolve(path)), true);
  if (!digest(expectedHash) || lstatSync(path).nlink !== 1) fail('invalid generated core join custody/digest');
  const bytes = await readReleaseInput(path, { maximum: 64 * 1024, privateKey: true }); let value;
  try { value = JSON.parse(new TextDecoder('utf-8', { fatal: true }).decode(bytes)); } catch { fail('invalid generated core joined record'); }
  const linux = value.kind === 'ubuntu-dependency-input-join';
  if (!bytes.equals(encode(value)) || hash(bytes) !== expectedHash || !keys(value, 'schemaVersion kind product tag version sourceCommit sourceInputsSha256 architecture candidateRecordSha256 coreReceiptSha256 gleamReceiptSha256 publicationAuthority provedSourceFiles generatedInputs' + (linux ? ' retainedGitMetadata buildInputsSha256' : '')) || value.schemaVersion !== 1 || !['macos-dependency-input-join', 'ubuntu-dependency-input-join'].includes(value.kind) || value.product !== source.product || value.tag !== source.tag || value.version !== source.version || value.sourceCommit !== source.commit || value.sourceInputsSha256 !== hash(encode(source)) || value.coreReceiptSha256 !== coreSha256 || !digest(value.candidateRecordSha256) || !digest(value.gleamReceiptSha256) || value.publicationAuthority !== 'none' || !(linux ? ['arm64', 'amd64'] : ['arm64', 'x86_64']).includes(value.architecture) || !Number.isInteger(value.provedSourceFiles) || value.provedSourceFiles < 1 || value.provedSourceFiles > 8192 || !Array.isArray(value.generatedInputs) || value.generatedInputs.length > 7 || (linux && (!digest(value.buildInputsSha256) || !Array.isArray(value.retainedGitMetadata) || value.retainedGitMetadata.length > 8192))) fail('generated core join identity/schema differs');
  for (const file of value.generatedInputs) {
    if (!keys(file, 'path mode bytes sha256 reason') || !['generated-lexer-parser', 'generated-native-helper', 'compiler-lock-metadata'].includes(file.reason)) fail('invalid generated core input reason');
    if (file.reason === 'generated-lexer-parser' && (!generatedCoreSourceInput(file.path.replace(/^apps\/core\/deps\//, '')) || !file.path.startsWith('apps/core/deps/') || file.mode !== 0o644 || file.bytes > 2 * 1024 * 1024 || file.bytes < 1)) fail('unsupported captured generated syntax');
    if (file.reason === 'generated-native-helper' && file.path !== 'apps/core/deps/file_system/priv/mac_listener') fail('unsupported remaining generated native input');
    if (file.reason === 'compiler-lock-metadata' && (file.path !== 'packages/decision-kernel/build/packages/gleam.lock' || file.bytes !== 0 || file.sha256 !== hash(Buffer.alloc(0)))) fail('unsupported remaining compiler lock input');
  }
  if (value.generatedInputs.length) validateCapturedFacts(value.generatedInputs.map(({ reason, ...file }) => file));
  if (linux && value.retainedGitMetadata.length) {
    for (const file of value.retainedGitMetadata) if (!keys(file, 'path mode bytes sha256 reason') || file.reason !== 'retained-git-build-metadata' || !/^apps\/core\/deps\/[^/]+\/\.git\//.test(file.path)) fail('invalid retained Git metadata assertion');
    validateCapturedFacts(value.retainedGitMetadata.map(({ reason, ...file }) => file));
  }
  return value;
}
async function inspectProof(root, pairs, generated = true, synchronizeFiles = false) {
  directory(root, true);
  const files = new Map();
  for (const pair of pairs) { files.set(pair.grammarRelative, pair.source); if (generated) files.set(pair.generatedRelative, pair.captured); }
  const parents = new Set(); for (const path of files.keys()) { let parent = dirname(path); while (parent !== '.') { parents.add(parent); parent = dirname(parent); } }
  const seen = new Set(), directories = [], custody = [{ path: '', stat: fileIdentity(lstatSync(root, { bigint: true })), names: materialDirectoryNames(root) }];
  async function visit(path) {
    const full = join(root, path);
    if (lstatSync(full).isDirectory()) {
      if (!parents.has(path)) fail('unknown generated core proof directory'); directory(full, true); directories.push(path);
      custody.push({ path, stat: fileIdentity(lstatSync(full, { bigint: true })), names: materialDirectoryNames(full) });
      for (const name of materialDirectoryNames(full)) await visit(path + '/' + name);
    } else {
      const expected = files.get(path);
      if (!expected || lstatSync(full).nlink !== 1 || (lstatSync(full).mode & 0o7777) !== 0o600) fail('unknown or aliased generated core proof file');
      custody.push({ path, stat: fileIdentity(lstatSync(full, { bigint: true })) });
      const bytes = await readReleaseInput(full, { maximum: path.endsWith('.erl') ? 2 * 1024 * 1024 : 64 * 1024, privateKey: true });
      if (bytes.length !== expected.bytes || hash(bytes) !== expected.sha256) fail('generated core proof bytes differ');
      seen.add(path); if (synchronizeFiles) synchronize(full);
    }
  }
  for (const name of materialDirectoryNames(root)) await visit(name);
  if (seen.size !== files.size) fail('generated core proof incomplete');
  if (synchronizeFiles) { for (const path of directories.reverse()) synchronize(join(root, path), true); synchronize(root, true); }
  for (const entry of custody) if (!same(entry.stat, fileIdentity(lstatSync(join(root, entry.path), { bigint: true }))) || (entry.names && !same(entry.names, materialDirectoryNames(join(root, entry.path))))) fail('generated core proof custody changed');
  return custody;
}

export async function checkCoreGenerated({ repository, tag, commit, sourcePath, cache, corePath, coreSha256, joinPath, joinSha256, output }, { tool = generatedSyntaxTool } = {}) {
  repository = realpathSync(repository); output = resolve(output);
  const deadline = performance.now() + 180_000, budget = () => { if (performance.now() > deadline) fail('generated core processing deadline'); };
  const source = await verifyInputs(repository, tag, commit, sourcePath); budget();
  const core = await readMaterialReceipt(corePath, coreSha256, source, 'locked-core-source-material'), joined = await joinedReceipt(joinPath, joinSha256, source, coreSha256);
  const inputs = [dirname(resolve(corePath)), dirname(resolve(joinPath)), dirname(resolve(sourcePath))];
  const custody = () => inputs.map(path => ({ identity: identity(directory(path, true)), names: materialDirectoryNames(path) }));
  const initialCustody = custody(), helperBytes = await readReleaseInput(helper, { maximum: 64 * 1024, protectedTrust: true });
  const replayCore = async () => { const result = await checkCoreMaterial({ repository, tag, commit, sourcePath, cache, output: dirname(resolve(corePath)) }, { budgetMs: Math.max(1, deadline - performance.now()) }); if (result.receiptSha256 !== coreSha256 || result.disposition !== 'retained-bytes-verified') fail('generated core source replay differs'); budget(); };
  await replayCore();
  const selected = joined.generatedInputs.filter(file => file.reason === 'generated-lexer-parser').sort((a, b) => a.path < b.path ? -1 : 1), pairs = [];
  for (const captured of selected) {
    const local = captured.path.slice('apps/core/deps/'.length), key = local.split('/')[0], grammar = generatedCoreSourceInput(local), item = core.packages.find(item => item.lock.key === key), file = item?.files.find(file => file.path === grammar);
    if (!file || file.bytes < 1 || file.bytes > 64 * 1024) fail('admitted generated syntax grammar missing or excessive');
    const sourceFile = { ...file, path: 'apps/core/deps/' + key + '/' + grammar };
    await lockedSourceFacts(join(repository, sourceFile.path), sourceFile, budget);
    pairs.push({ source: sourceFile, captured, grammarRelative: key + '/' + grammar, generatedRelative: local });
  }
  const parent = dirname(output), parentStat = directory(parent), physical = join(realpathSync(parent), basename(output));
  const exclusion = [...inputs.map(path => realpathSync(path)), realpathSync(cache), realpathSync(join(repository, 'apps/core/deps'))];
  if (physical === repository || exclusion.some(path => physical === path || physical.startsWith(path + sep) || path.startsWith(physical + sep)) || (physical.startsWith(repository + sep) && !releaseGit(repository, ['check-ignore', '--no-index', physical]).length)) fail('generated core output overlaps inputs');
  const proof = join(output, 'proof'), recordPath = join(output, 'generated-core.json'), pending = join(output, 'check.pending'), marker = Buffer.from('incomplete generated core syntax proof\n');
  let exists = false; try { lstatSync(output); exists = true; } catch (error) { if (error.code !== 'ENOENT') throw error; }
  let created;
  if (exists) { created = directory(output, true); if (!same(materialDirectoryNames(output), ['generated-core.json', 'proof'])) fail('incomplete or conflicting generated core output'); await inspectProof(proof, pairs); }
  else {
    mkdirSync(output, { mode: 0o700 }); created = directory(output, true); writeFileSync(pending, marker, { flag: 'wx', mode: 0o600 }); synchronize(pending); mkdirSync(proof, { mode: 0o700 }); synchronize(output, true);
    for (const pair of pairs) { const packageRoot = join(proof, pair.grammarRelative.split('/')[0]); if (!materialDirectoryNames(proof).includes(basename(packageRoot))) { mkdirSync(packageRoot, { mode: 0o700 }); mkdirSync(join(packageRoot, 'src'), { mode: 0o700 }); } const bytes = await readReleaseInput(join(repository, pair.source.path), { maximum: 64 * 1024 }); if (bytes.length !== pair.source.bytes || hash(bytes) !== pair.source.sha256) fail('generated core grammar changed before copy'); writeFileSync(join(proof, pair.grammarRelative), bytes, { mode: 0o600, flag: 'wx' }); }
    await inspectProof(proof, pairs, false, true);
  }
  const sourceCloneCustody = pairs.map(pair => fileIdentity(lstatSync(join(proof, pair.grammarRelative), { bigint: true })));
  const expectedFiles = exists ? [] : pairs.map(pair => ({ path: pair.generatedRelative, bytes: pair.captured.bytes, sha256: pair.captured.sha256 }));
  const observed = await tool(exists ? 'observe' : 'generate', proof, pairs.map(pair => pair.grammarRelative)); budget();
  const generator = await observations(observed, expectedFiles);
  if (!same(sourceCloneCustody, pairs.map(pair => fileIdentity(lstatSync(join(proof, pair.grammarRelative), { bigint: true }))))) fail('generated core private grammar changed');
  const proofCustody = await inspectProof(proof, pairs, true, !exists);
  const bytes = encode({ schemaVersion: 1, kind: 'generated-core-syntax-material', product: source.product, tag, version: source.version, sourceCommit: commit, sourceInputsSha256: hash(encode(source)), candidateRecordSha256: joined.candidateRecordSha256, dependencyInputsSha256: joinSha256, coreReceiptSha256: coreSha256, helperSourceSha256: hash(helperBytes), generator, files: pairs.map(pair => ({ source: pair.source, generated: pair.captured })), remainingGeneratedInputs: joined.generatedInputs.length - pairs.length, publicationAuthority: 'none' });
  if (bytes.length > 64 * 1024) fail('generated core record limit');
  if (exists && (lstatSync(recordPath).nlink !== 1 || !(await readReleaseInput(recordPath, { maximum: 64 * 1024, privateKey: true })).equals(bytes))) fail('conflicting generated core retained record');
  await replayCore(); await verifyInputs(repository, tag, commit, sourcePath); budget();
  const finalObservation = await tool('observe', proof, pairs.map(pair => pair.grammarRelative)); budget();
  if (!same(generator, await observations(finalObservation, []))) fail('generated core tool observations changed');
  await verifyInputs(repository, tag, commit, sourcePath); budget();
  if (!same(generator, await observations(finalObservation, []))) fail('generated core final tool bytes changed');
  // Finish frozen source bytes without another parser/Mix/version child.
  for (const file of source.files) await lockedSourceFacts(join(repository, file.path), { ...file, mode: file.mode === '100755' ? 0o755 : 0o644 }, budget);
  await readMaterialReceipt(corePath, coreSha256, source, 'locked-core-source-material'); await joinedReceipt(joinPath, joinSha256, source, coreSha256);
  if (!(await readReleaseInput(helper, { maximum: 64 * 1024, protectedTrust: true })).equals(helperBytes)) fail('generated core helper changed');
  for (const pair of pairs) await lockedSourceFacts(join(repository, pair.source.path), pair.source, budget);
  if (!same(proofCustody, await inspectProof(proof, pairs))) fail('generated core final proof custody changed');
  if (!same(initialCustody, custody()) || !same(identity(parentStat), identity(directory(parent))) || !same(identity(created), identity(directory(output, true))) || !same(materialDirectoryNames(output), exists ? ['generated-core.json', 'proof'] : ['check.pending', 'proof'])) fail('generated core input/output namespace changed');
  if (exists) { if (lstatSync(recordPath).nlink !== 1 || !(await readReleaseInput(recordPath, { maximum: 64 * 1024, privateKey: true })).equals(bytes)) fail('generated core replay changed'); }
  else {
    if (lstatSync(pending).nlink !== 1 || !(await readReleaseInput(pending, { maximum: 1024, privateKey: true })).equals(marker)) fail('generated core pending custody changed');
    writeFileSync(recordPath, bytes, { flag: 'wx', mode: 0o600 }); synchronize(recordPath);
    if (!same(identity(created), identity(directory(output, true))) || !same(materialDirectoryNames(output), ['check.pending', 'generated-core.json', 'proof']) || !(await readReleaseInput(recordPath, { maximum: 64 * 1024, privateKey: true })).equals(bytes) || !(await readReleaseInput(pending, { maximum: 1024, privateKey: true })).equals(marker)) fail('generated core completion custody changed');
    unlinkSync(pending); synchronize(output, true); synchronize(parent, true);
  }
  return { publicationAuthority: 'none', qualifiedGeneratedFiles: pairs.length, remainingGeneratedInputs: joined.generatedInputs.length - pairs.length, recordSha256: hash(bytes), disposition: exists ? 'retained-bytes-verified' : 'generated-source-derived' };
}
