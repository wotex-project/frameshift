import { createHash } from 'node:crypto';
import { constants, closeSync, fstatSync, fsyncSync, lstatSync, mkdirSync, openSync, readdirSync, realpathSync, unlinkSync, writeFileSync } from 'node:fs';
import { basename, dirname, join, resolve, sep } from 'node:path';
import { isDeepStrictEqual } from 'node:util';
import { readReleaseInput } from '../files.mjs';
import { verifyInputs } from '../inputs.mjs';
import { releaseGit } from '../source.mjs';
import { auditMacBundle } from './closure.mjs';
import { macImageTool, verifyDevelopmentSignatures } from './dmg.mjs';
import { universalDevelopmentBundle } from './universal.mjs';
import { isSparkleInput, sparkleArchive, sparkleInputArchive, sparkleInputFramework } from '../macos-framework.mjs';

const encode = value => Buffer.from(JSON.stringify(value) + '\n');
const hash = value => createHash('sha256').update(value).digest('hex');
const fail = message => { throw new Error(message); };
const digest = value => typeof value === 'string' && value.length === 64 && /^[0-9a-f]{64}$/.test(value);
const keys = (value, expected) => value && typeof value === 'object' && !Array.isArray(value) && isDeepStrictEqual(Object.keys(value).sort(), expected.split(' ').sort());
function directory(path) {
  const stat = lstatSync(path);
  if (!stat.isDirectory() || stat.uid !== process.getuid() || (stat.mode & 0o7777) !== 0o700) fail('unsafe Mac cohort directory');
  return stat;
}
function synchronize(path, isDirectory = false) {
  const fd = openSync(path, constants.O_RDONLY | constants.O_NOFOLLOW | constants.O_NONBLOCK | (isDirectory ? constants.O_DIRECTORY : 0));
  try {
    const opened = fstatSync(fd), named = lstatSync(path);
    if (!(isDirectory ? opened.isDirectory() && named.isDirectory() : opened.isFile() && named.isFile()) || opened.dev !== named.dev || opened.ino !== named.ino) fail('Mac cohort sync custody changed');
    fsyncSync(fd);
  } finally { closeSync(fd); }
}
async function readRecord(path, maximum) {
  if (lstatSync(path).nlink !== 1) fail('Mac cohort record alias');
  const bytes = await readReleaseInput(path, { maximum, privateKey: true });
  if (lstatSync(path).nlink !== 1) fail('Mac cohort record alias');
  let record;
  try { record = JSON.parse(new TextDecoder('utf-8', { fatal: true }).decode(bytes)); } catch { fail('invalid Mac cohort record'); }
  if (!bytes.equals(encode(record))) fail('noncanonical Mac cohort record');
  return { record, bytes };
}
function compilerCohort(execution, architecture) {
  if (!keys(execution, 'architecture native macOS osBuild xcode sdkVersion sdkBuild swift elixir zig') || execution.architecture !== architecture || execution.native !== true || execution.zig !== '0.16.0') fail('invalid Mac producer execution');
  for (const name of ['macOS', 'osBuild', 'xcode', 'sdkVersion', 'sdkBuild', 'swift', 'elixir', 'zig']) {
    const value = execution[name];
    if (typeof value !== 'string' || !value || Buffer.byteLength(value) > 4096 || value.includes('\0')) fail('invalid Mac producer tool observation');
  }
  const swift = execution.swift.split('\n')[0];
  const otp = execution.elixir.match(/^Erlang\/OTP (\d+) \[erts-([^\]]+)\]/m);
  const elixir = execution.elixir.match(/^Elixir ([^\s]+) \(compiled with Erlang\/OTP (\d+)\)$/m);
  if (!/^Apple Swift version [0-9]/.test(swift) || !otp || !elixir || otp[1] !== elixir[2]) fail('invalid Mac compiler identity');
  return { xcode: execution.xcode, sdkVersion: execution.sdkVersion, sdkBuild: execution.sdkBuild, swift, otp: otp[1], erts: otp[2], elixir: elixir[1], zig: execution.zig };
}
function materialFacts(files) {
  if (!Array.isArray(files) || !files.length || files.length > 8192) fail('invalid Mac candidate material');
  const paths = new Set(); let bytes = 0;
  for (const file of files) {
    if (!keys(file, 'path mode bytes sha256') || typeof file.path !== 'string' || Buffer.byteLength(file.path) > 512 || /[\u0000-\u001f\u007f\\]/.test(file.path) || file.path.split('/').some(part => !part || part === '.' || part === '..') ||
        (!['apps/core/deps/', 'packages/decision-kernel/build/packages/', sparkleInputFramework].some(root => file.path.startsWith(root)) && file.path !== sparkleInputArchive) || paths.has(file.path) ||
        !Number.isInteger(file.mode) || file.mode < 0 || file.mode > 0o7777 || !Number.isSafeInteger(file.bytes) || file.bytes < 0 || file.bytes > 128 * 1024 * 1024 || !digest(file.sha256)) fail('invalid Mac candidate material entry');
    paths.add(file.path); bytes += file.bytes;
    if (isSparkleInput(file.path) && ((file.mode & 0o7022) || !(file.mode & 0o400) || file.bytes > 16 * 1024 * 1024 ||
        (file.path === sparkleInputArchive && (file.mode !== 0o600 || file.bytes !== sparkleArchive.bytes || file.sha256 !== sparkleArchive.sha256)))) fail('invalid pinned updater material');
  }
  if (bytes > 512 * 1024 * 1024) fail('Mac candidate material byte limit');
  return files;
}

// Receiver admission checks retained assertions against independently supplied
// digests and real app bytes. It does not recreate remote execution evidence.
export async function inspectMacCandidate({ repository, source, candidate, expectedDigest, architecture }, tool = macImageTool) {
  if (!digest(expectedDigest) || !['arm64', 'x86_64'].includes(architecture)) fail('invalid Mac candidate custody identity');
  candidate = resolve(candidate);
  const before = directory(candidate), names = ['Frameshift.app', 'candidate.json'];
  if (!isDeepStrictEqual(readdirSync(candidate).sort(), names)) fail('incomplete or unknown Mac candidate');
  const path = join(candidate, 'candidate.json'), { record, bytes } = await readRecord(path, 16 * 1024 * 1024);
  if (hash(bytes) !== expectedDigest || !keys(record, 'schemaVersion kind product publicationAuthority tag version sourceCommit sourceInputsSha256 architecture execution material bundle') ||
      record.schemaVersion !== 1 || record.kind !== 'macos-native-build-candidate' || record.product !== source.product || record.publicationAuthority !== 'none' || record.tag !== source.tag || record.version !== source.version || record.sourceCommit !== source.commit || record.sourceInputsSha256 !== hash(encode(source)) || record.architecture !== architecture) fail('Mac candidate source or record digest differs');
  const compiler = compilerCohort(record.execution, architecture), material = materialFacts(record.material);
  const app = join(candidate, 'Frameshift.app'), bundle = await auditMacBundle(app, architecture);
  const updater = material.filter(file => isSparkleInput(file.path));
  if (Boolean(bundle.links?.length) !== Boolean(updater.length) || (updater.length && (updater.length !== 86 || !updater.some(file => file.path === sparkleInputArchive)))) fail('Mac updater bundle and captured material differ');
  if (bundle.natives.some(file => file.slices.length !== 1 || file.slices[0].arch !== architecture) || !isDeepStrictEqual(bundle, record.bundle)) fail('Mac candidate bundle differs');
  verifyDevelopmentSignatures(app, bundle, tool);
  for (const [name, expected] of [['CFBundleIdentifier', source.product], ['CFBundleShortVersionString', source.version], ['CFBundleVersion', source.version]]) {
    if (tool('/usr/bin/plutil', ['-extract', name, 'raw', join(app, 'Contents/Info.plist')]).stdout.trim() !== expected) fail('Mac candidate product version differs');
  }
  if (tool('mise', ['exec', '--', 'elixir', join(repository, 'release/linux/verify-version.exs'), join(app, 'Contents/Resources/core'), source.version], 60_000).stdout.trim() !== 'runtime version: verified') fail('Mac candidate core version differs');
  const final = directory(candidate);
  if (before.dev !== final.dev || before.ino !== final.ino || !isDeepStrictEqual(readdirSync(candidate).sort(), names) || !isDeepStrictEqual(bundle, await auditMacBundle(app, architecture)) || !(await readRecord(path, 16 * 1024 * 1024)).bytes.equals(bytes)) fail('Mac candidate receiver custody changed');
  return { architecture, recordSha256: expectedDigest, compiler, material, bundle };
}

export async function macSourceCohort({ repository, tag, commit, sourcePath, armCandidate, armSha256, intelCandidate, intelSha256, output }, { tool = macImageTool } = {}) {
  repository = realpathSync(repository);
  const source = await verifyInputs(repository, tag, commit, sourcePath);
  const inputs = async () => {
    const arm = await inspectMacCandidate({ repository, source, candidate: armCandidate, expectedDigest: armSha256, architecture: 'arm64' }, tool);
    const intel = await inspectMacCandidate({ repository, source, candidate: intelCandidate, expectedDigest: intelSha256, architecture: 'x86_64' }, tool);
    if (!isDeepStrictEqual(arm.compiler, intel.compiler) || !isDeepStrictEqual(arm.material, intel.material)) fail('Mac candidate compiler or material cohorts differ');
    return [arm, intel];
  };
  const admitted = await inputs();
  const destination = join(realpathSync(dirname(resolve(output))), basename(output));
  const roots = [realpathSync(armCandidate), realpathSync(intelCandidate)];
  if (roots.some(root => root === destination || root.startsWith(destination + sep) || destination.startsWith(root + sep)) ||
      (destination === repository || (destination.startsWith(repository + sep) && !releaseGit(repository, ['check-ignore', '--no-index', destination]).length))) fail('Mac cohort output overlaps input or source');
  const subject = { schemaVersion: 1, kind: 'macos-source-cohort', product: source.product, publicationAuthority: 'none', tag, version: source.version, sourceCommit: commit, sourceInputsSha256: hash(encode(source)),
    candidateRecords: admitted.map(input => ({ architecture: input.architecture, sha256: input.recordSha256 })), compiler: admitted[0].compiler };
  const child = join(destination, 'universal-candidate'), recordPath = join(destination, 'cohort.json');
  const recheck = async () => {
    await verifyInputs(repository, tag, commit, sourcePath);
    if (!isDeepStrictEqual(admitted, await inputs())) fail('Mac cohort inputs changed');
    await verifyInputs(repository, tag, commit, sourcePath);
  };
  const assemble = () => universalDevelopmentBundle(join(armCandidate, 'Frameshift.app'), join(intelCandidate, 'Frameshift.app'), child, { tool });
  const completed = result => ({ ...subject, universalRecordSha256: result.recordSha256, minimumOS: result.minimumOS, nativeFiles: result.nativeFiles });
  const retainedUniversal = async result => {
    const before = directory(child);
    if (!isDeepStrictEqual(readdirSync(child).sort(), ['Frameshift.app', 'universal.json'])) fail('Mac cohort universal namespace changed');
    const bytes = await readReleaseInput(join(child, 'universal.json'), { maximum: 1024 * 1024, privateKey: true });
    if (hash(bytes) !== result.recordSha256) fail('Mac cohort universal record changed');
    const record = JSON.parse(new TextDecoder('utf-8', { fatal: true }).decode(bytes));
    if (!isDeepStrictEqual(record.inputs, admitted.map(input => input.bundle)) || !isDeepStrictEqual(record.bundle, await auditMacBundle(join(child, 'Frameshift.app'), 'universal'))) fail('Mac cohort universal bytes changed');
    const final = directory(child);
    if (before.dev !== final.dev || before.ino !== final.ino || !isDeepStrictEqual(readdirSync(child).sort(), ['Frameshift.app', 'universal.json']) || !(await readReleaseInput(join(child, 'universal.json'), { maximum: 1024 * 1024, privateKey: true })).equals(bytes)) fail('Mac cohort universal custody changed');
  };
  let exists = false;
  try { lstatSync(destination); exists = true; } catch (error) { if (error.code !== 'ENOENT') throw error; }
  if (exists) {
    const before = directory(destination);
    if (!isDeepStrictEqual(readdirSync(destination).sort(), ['cohort.json', 'universal-candidate'])) fail('incomplete or unknown Mac cohort output');
    const { record, bytes } = await readRecord(recordPath, 64 * 1024), result = await assemble();
    if (!bytes.equals(encode(completed(result)))) fail('Mac cohort retained record differs');
    await recheck(); await retainedUniversal(result);
    const final = directory(destination);
    if (before.dev !== final.dev || before.ino !== final.ino || !isDeepStrictEqual(readdirSync(destination).sort(), ['cohort.json', 'universal-candidate']) || !(await readRecord(recordPath, 64 * 1024)).bytes.equals(bytes)) fail('Mac cohort replay custody changed');
    return { ...record, recordSha256: hash(bytes), disposition: 'retained-bytes-verified' };
  }
  mkdirSync(destination, { mode: 0o700 }); const created = directory(destination);
  writeFileSync(join(destination, 'build.pending'), 'incomplete source-bound Mac cohort\n', { flag: 'wx', mode: 0o600 }); synchronize(join(destination, 'build.pending')); synchronize(destination, true);
  const result = await assemble(); await recheck();
  const record = completed(result), bytes = encode(record);
  if (bytes.length > 64 * 1024) fail('Mac cohort record limit');
  writeFileSync(recordPath, bytes, { flag: 'wx', mode: 0o600 }); synchronize(recordPath);
  await recheck();
  await retainedUniversal(result);
  const final = directory(destination);
  if (created.dev !== final.dev || created.ino !== final.ino || !isDeepStrictEqual(readdirSync(destination).sort(), ['build.pending', 'cohort.json', 'universal-candidate']) || !(await readRecord(recordPath, 64 * 1024)).bytes.equals(bytes)) fail('Mac cohort final custody changed');
  synchronize(destination, true); unlinkSync(join(destination, 'build.pending')); synchronize(destination, true); synchronize(dirname(destination), true);
  return { ...record, recordSha256: hash(bytes), disposition: 'source-bound-universal-candidate' };
}
