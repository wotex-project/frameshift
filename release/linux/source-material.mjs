import { spawnSync } from 'node:child_process';
import { createHash } from 'node:crypto';
import { constants, closeSync, fstatSync, fsyncSync, lstatSync, mkdirSync, openSync, realpathSync, unlinkSync, writeFileSync } from 'node:fs';
import { basename, dirname, join, resolve, sep } from 'node:path';
import { isDeepStrictEqual as same } from 'node:util';
import { readReleaseInput, withReleaseInput } from '../files.mjs';
import { verifyInputs } from '../inputs.mjs';
import { joinDependencyInputs, materialDirectoryNames, materialPath, readMaterialReceipt, validateCapturedFacts } from '../material-receipts.mjs';
import { releaseGit } from '../source.mjs';
import { assertSourceMaterial, gleamHashes, images } from './material.mjs';

const encode = value => Buffer.from(JSON.stringify(value) + '\n');
const hash = value => createHash('sha256').update(value).digest('hex');
const fail = message => { throw new Error(message); };
const digest = value => typeof value === 'string' && /^[0-9a-f]{64}$/.test(value);
const keys = (value, names) => value && typeof value === 'object' && !Array.isArray(value) && same(Object.keys(value).sort(), names.split(' ').sort());
const identity = stat => ['dev', 'ino', 'mode', 'uid', 'gid'].map(key => String(stat[key]));
function directory(path, privateMode = false) {
  const stat = lstatSync(path, { bigint: true });
  if (!stat.isDirectory() || stat.uid !== BigInt(process.getuid()) || (privateMode ? (stat.mode & 0o7777n) !== 0o700n : (stat.mode & 0o7022n) !== 0n)) fail('unsafe Ubuntu material custody directory');
  return stat;
}
function synchronize(path, isDirectory = false) {
  const fd = openSync(path, constants.O_RDONLY | constants.O_NOFOLLOW | constants.O_NONBLOCK | (isDirectory ? constants.O_DIRECTORY : 0));
  try {
    const stat = fstatSync(fd), named = lstatSync(path);
    if (!(isDirectory ? stat.isDirectory() && named.isDirectory() : stat.isFile() && named.isFile()) || stat.dev !== named.dev || stat.ino !== named.ino) fail('Ubuntu material sync custody changed');
    fsyncSync(fd);
  } finally { closeSync(fd); }
}
async function json(path, maximum, privateKey = false) {
  if (lstatSync(path).nlink !== 1) fail('Ubuntu material record alias');
  const bytes = await readReleaseInput(path, { maximum, privateKey });
  let value; try { value = JSON.parse(new TextDecoder('utf-8', { fatal: true }).decode(bytes)); } catch { fail('invalid Ubuntu material record'); }
  if (!bytes.equals(encode(value)) || lstatSync(path).nlink !== 1) fail('noncanonical Ubuntu material record');
  return { bytes, value };
}
async function candidateFiles(root, expected, budget) {
  validateCapturedFacts(expected);
  if (expected.some(file => !/^(?:package|runtime)\//.test(file.path))) fail('unknown Ubuntu candidate file namespace');
  const parents = new Set();
  for (const file of expected) { let parent = dirname(file.path); while (parent !== '.') { parents.add(parent); parent = dirname(parent); } }
  const files = [], directories = []; let entries = 0, total = 0;
  async function visit(path) {
    budget();
    if (!materialPath(path) || ++entries > 8192) fail('Ubuntu candidate path/entry limit');
    const full = join(root, path), stat = lstatSync(full, { bigint: true });
    if (stat.isDirectory()) {
      const before = directory(full), names = materialDirectoryNames(full);
      if (!parents.has(path) || !names.length || names.length + entries > 8192) fail('unknown or excessive Ubuntu candidate directory');
      directories.push({ path, identity: identity(before), names });
      for (const name of names) await visit(path + '/' + name);
      if (!same(identity(before), identity(directory(full))) || !same(names, materialDirectoryNames(full))) fail('Ubuntu candidate namespace changed');
    } else {
      if (!stat.isFile() || stat.uid !== BigInt(process.getuid()) || stat.nlink !== 1n || (stat.mode & 0o7022n) !== 0n || (stat.mode & 0o400n) === 0n || stat.size > 128n * 1024n * 1024n || (total += Number(stat.size)) > 512 * 1024 * 1024) fail('unsafe or excessive Ubuntu candidate file');
      const facts = await withReleaseInput(full, { minimum: 0, maximum: 128 * 1024 * 1024 }, async (handle, size, fileBudget) => {
        const sha = createHash('sha256'), block = Buffer.alloc(64 * 1024); let offset = 0;
        while (offset < size) {
          budget(); fileBudget();
          const { bytesRead } = await handle.read(block, 0, Math.min(block.length, size - offset), offset);
          if (!bytesRead) fail('Ubuntu candidate file shortened');
          offset += bytesRead; sha.update(block.subarray(0, bytesRead));
        }
        if ((await handle.read(block, 0, 1, offset)).bytesRead) fail('Ubuntu candidate file grew');
        return { path, mode: Number(stat.mode & 0o7777n), bytes: size, sha256: sha.digest('hex') };
      });
      if (!same(identity(stat), identity(lstatSync(full, { bigint: true }))) || lstatSync(full).nlink !== 1) fail('Ubuntu candidate file custody changed');
      files.push(facts);
    }
  }
  for (const path of ['package', 'runtime']) await visit(path);
  if (!same(files, expected)) fail('Ubuntu candidate bytes differ from record');
  for (const entry of directories) if (!same(entry.identity, identity(directory(join(root, entry.path)))) || !same(entry.names, materialDirectoryNames(join(root, entry.path)))) fail('Ubuntu candidate final namespace changed');
  return directories;
}
function versionTool(repository, core, version) {
  const environment = { ...process.env };
  for (const name of Object.keys(environment)) if (name.startsWith('GIT_')) delete environment[name];
  const result = spawnSync('mise', ['exec', '--', 'elixir', join(repository, 'release/linux/verify-version.exs'), core, version],
    { cwd: repository, env: environment, encoding: 'utf8', timeout: 60_000, maxBuffer: 64 * 1024, stdio: ['ignore', 'pipe', 'pipe'] });
  if (result.error || result.status !== 0 || result.stdout.trim() !== 'runtime version: verified') fail('Ubuntu material runtime version refused');
}
async function inspectCandidate(repository, source, candidate, expectedDigest, architecture, budget, tool, runVersion = true) {
  if (!digest(expectedDigest) || !['arm64', 'amd64'].includes(architecture)) fail('invalid Ubuntu candidate digest/architecture');
  const initial = identity(directory(candidate, true)), names = materialDirectoryNames(candidate);
  if (!same(names, ['candidate.json', 'package', 'runtime'])) fail('incomplete Ubuntu candidate namespace');
  const { bytes, value: record } = await json(join(candidate, 'candidate.json'), 16 * 1024 * 1024, true);
  if (hash(bytes) !== expectedDigest || !keys(record, 'schemaVersion kind product publicationAuthority tag version sourceCommit sourceInputsSha256 ubuntu architecture buildExecution artifacts files') || record.schemaVersion !== 1 || record.kind !== 'ubuntu-release-candidate' || record.product !== source.product || record.tag !== source.tag || record.version !== source.version || record.sourceCommit !== source.commit || record.sourceInputsSha256 !== hash(encode(source)) || record.ubuntu !== '24.04' || record.architecture !== architecture || record.publicationAuthority !== 'none') fail('Ubuntu candidate identity differs');
  const execution = record.buildExecution;
  if (!keys(execution, 'daemonArchitecture emulated buildErlFlags') || !['aarch64', 'arm64', 'x86_64', 'amd64'].includes(execution.daemonArchitecture)) fail('invalid Ubuntu candidate execution assertion');
  const emulated = architecture === 'arm64' ? !['aarch64', 'arm64'].includes(execution.daemonArchitecture) : !['x86_64', 'amd64'].includes(execution.daemonArchitecture);
  if (execution.emulated !== emulated || execution.buildErlFlags !== (emulated ? '+JMsingle true' : '')) fail('Ubuntu candidate execution policy differs');
  const directories = await candidateFiles(candidate, record.files, budget);
  const archivePath = `package/frameshift_${source.version}_${architecture}.deb`, archive = record.files.find(file => file.path === archivePath);
  if (!archive || !archive.bytes || record.files.filter(file => file.path.endsWith('.deb')).length !== 1 || !same(record.artifacts, [{ platform: 'ubuntu', architecture, format: 'deb', path: archivePath, bytes: archive.bytes, sha256: archive.sha256 }])) fail('Ubuntu candidate archive assertion differs');
  const doc = join(candidate, 'runtime/root/usr/share/doc/frameshift');
  const embedded = await readReleaseInput(join(doc, 'source-inputs.json'), { maximum: 8 * 1024 * 1024 });
  if (!embedded.equals(encode(source))) fail('Ubuntu embedded source differs');
  const { bytes: inputBytes, value: inputs } = await json(join(doc, 'build-inputs.json'), 16 * 1024 * 1024);
  if (!keys(inputs, 'schemaVersion kind product version ubuntu architecture sourceCommit workingTreeChanged publicationAuthority tag sourceInputsSha256 resolvedMaterialAssertion toolchains images inputs') || inputs.schemaVersion !== 1 || inputs.kind !== 'tagged-closure-candidate' || inputs.product !== source.product || inputs.version !== source.version || inputs.ubuntu !== '24.04' || inputs.architecture !== architecture || inputs.sourceCommit !== source.commit || inputs.workingTreeChanged !== false || inputs.publicationAuthority !== 'none' || inputs.tag !== source.tag || inputs.sourceInputsSha256 !== hash(encode(source)) || inputs.resolvedMaterialAssertion !== 'captured-only' || !same(inputs.images, images) || !same(inputs.toolchains, { otp: '29.1', elixir: '1.20.4', gleam: '1.18.1', gleamArchiveSha256: gleamHashes[architecture], zig: '0.16.0', rust: '1.97.1', hex: '2.5.1' })) fail('Ubuntu build input identity differs');
  validateCapturedFacts(inputs.inputs); assertSourceMaterial(source, inputs.inputs);
  const material = inputs.inputs.filter(file => /^(?:apps\/core\/deps\/|packages\/decision-kernel\/build\/packages\/)/.test(file.path));
  const core = join(candidate, 'runtime/root/usr/lib/frameshift/core'), start = await readReleaseInput(join(core, 'releases/start_erl.data'), { maximum: 64 * 1024 });
  const startText = new TextDecoder('utf-8', { fatal: true }).decode(start);
  if (!/^\d+\.\d+(?:\.\d+)?\s+\d+\.\d+\.\d+\s*$/.test(startText) || startText.trim().split(/\s+/)[1] !== source.version) fail('Ubuntu runtime start version differs');
  for (const path of [`releases/${source.version}/frameshift_core.rel`, `lib/frameshift_core-${source.version}/ebin/frameshift_core.app`]) await readReleaseInput(join(core, path), { maximum: 64 * 1024 });
  if (runVersion) { await tool(repository, core, source.version); budget(); }
  if (!same(initial, identity(directory(candidate, true))) || !same(names, materialDirectoryNames(candidate))) fail('Ubuntu candidate custody changed');
  return { material, buildInputsSha256: hash(inputBytes), directories };
}

// Receipt transport needs the same bounded complete candidate check after its
// last source child, without rerunning any parser or runtime/version child.
export async function inspectLinuxMaterialBytes({ repository, source, candidate, candidateSha256, architecture }) {
  const deadline = performance.now() + 180_000;
  const budget = () => { if (performance.now() > deadline) fail('Ubuntu material static inspection deadline'); };
  return inspectCandidate(repository, source, candidate, candidateSha256, architecture, budget, undefined, false);
}

export async function linuxMaterialJoin({ repository, tag, commit, sourcePath, architecture, candidate, candidateSha256, corePath, coreSha256, gleamPath, gleamSha256, output }, { tool = versionTool } = {}) {
  repository = realpathSync(repository); candidate = resolve(candidate); output = resolve(output);
  const deadline = performance.now() + 180_000, budget = () => { if (performance.now() > deadline) fail('Ubuntu material join processing deadline'); };
  const source = await verifyInputs(repository, tag, commit, sourcePath); budget();
  const inputDirectories = [candidate, dirname(resolve(sourcePath)), dirname(resolve(corePath)), dirname(resolve(gleamPath))];
  const custody = () => inputDirectories.map(path => ({ identity: identity(directory(path, true)), names: materialDirectoryNames(path) }));
  const initialCustody = custody();
  const inspect = async (runVersion = true) => {
    const core = await readMaterialReceipt(corePath, coreSha256, source, 'locked-core-source-material'), gleam = await readMaterialReceipt(gleamPath, gleamSha256, source, 'locked-gleam-source-material');
    const retained = await inspectCandidate(repository, source, candidate, candidateSha256, architecture, budget, tool, runVersion);
    const joined = await joinDependencyInputs(repository, core, gleam, retained.material, { gitMetadata: true }); budget();
    return { ...joined, buildInputsSha256: retained.buildInputsSha256, directories: retained.directories };
  };
  const joined = await inspect(), parent = dirname(output), parentStat = directory(parent);
  const physical = join(realpathSync(parent), basename(output)), inputs = inputDirectories.map(path => realpathSync(path));
  if (physical === repository || inputs.some(path => physical === path || physical.startsWith(path + sep) || path.startsWith(physical + sep)) || (physical.startsWith(repository + sep) && !releaseGit(repository, ['check-ignore', '--no-index', physical]).length)) fail('Ubuntu material output overlaps inputs');
  const { directories, ...facts } = joined;
  const bytes = encode({ schemaVersion: 1, kind: 'ubuntu-dependency-input-join', product: source.product, tag, version: source.version, sourceCommit: commit,
    sourceInputsSha256: hash(encode(source)), architecture, candidateRecordSha256: candidateSha256, coreReceiptSha256: coreSha256, gleamReceiptSha256: gleamSha256, publicationAuthority: 'none', ...facts });
  if (bytes.length > 64 * 1024) fail('Ubuntu material joined record limit');
  const path = join(output, 'dependency-inputs.json'), pending = join(output, 'check.pending'), marker = Buffer.from('incomplete Ubuntu dependency input join\n');
  let exists = false; try { lstatSync(output); exists = true; } catch (error) { if (error.code !== 'ENOENT') throw error; }
  let created;
  if (exists) {
    created = directory(output, true);
    if (!same(materialDirectoryNames(output), ['dependency-inputs.json']) || lstatSync(path).nlink !== 1 || !(await readReleaseInput(path, { maximum: 64 * 1024, privateKey: true })).equals(bytes)) fail('incomplete or conflicting Ubuntu material output');
  } else {
    mkdirSync(output, { mode: 0o700 }); created = directory(output, true);
    writeFileSync(pending, marker, { flag: 'wx', mode: 0o600 }); synchronize(pending); synchronize(output, true);
  }
  await verifyInputs(repository, tag, commit, sourcePath); budget();
  if (!same(joined, await inspect())) fail('Ubuntu material inputs changed');
  await verifyInputs(repository, tag, commit, sourcePath); budget();
  // No parser or runtime version child may follow the final static candidate
  // pass. Recheck source receipts again after its dependency parser children.
  if (!same(joined, await inspect(false))) fail('Ubuntu material final candidate custody changed');
  await verifyInputs(repository, tag, commit, sourcePath); budget();
  await readMaterialReceipt(corePath, coreSha256, source, 'locked-core-source-material');
  await readMaterialReceipt(gleamPath, gleamSha256, source, 'locked-gleam-source-material');
  const finalCandidate = await inspectCandidate(repository, source, candidate, candidateSha256, architecture, budget, tool, false);
  if (!same(directories, finalCandidate.directories) || finalCandidate.buildInputsSha256 !== facts.buildInputsSha256) fail('Ubuntu material final static inputs changed');
  budget();
  if (!same(initialCustody, custody()) || !same(identity(parentStat), identity(directory(parent)))) fail('Ubuntu material input/parent namespace changed');
  if (!same(identity(created), identity(directory(output, true))) || !same(materialDirectoryNames(output), exists ? ['dependency-inputs.json'] : ['check.pending'])) fail('Ubuntu material output custody changed');
  if (exists) {
    if (lstatSync(path).nlink !== 1 || !(await readReleaseInput(path, { maximum: 64 * 1024, privateKey: true })).equals(bytes)) fail('Ubuntu material replay changed');
  } else {
    if (lstatSync(pending).nlink !== 1 || !(await readReleaseInput(pending, { maximum: 1024, privateKey: true })).equals(marker)) fail('Ubuntu material pending custody changed');
    writeFileSync(path, bytes, { flag: 'wx', mode: 0o600 }); synchronize(path);
    if (!same(identity(created), identity(directory(output, true))) || !same(materialDirectoryNames(output), ['check.pending', 'dependency-inputs.json']) || lstatSync(path).nlink !== 1 || !(await readReleaseInput(path, { maximum: 64 * 1024, privateKey: true })).equals(bytes) || !(await readReleaseInput(pending, { maximum: 1024, privateKey: true })).equals(marker)) fail('Ubuntu material completion custody changed');
    unlinkSync(pending); synchronize(output, true); synchronize(parent, true);
  }
  return { publicationAuthority: 'none', architecture, ...facts, recordSha256: hash(bytes), disposition: exists ? 'retained-bytes-verified' : 'dependency-inputs-joined' };
}
