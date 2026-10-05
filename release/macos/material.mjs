import { createHash } from 'node:crypto';
import { constants, closeSync, fstatSync, fsyncSync, lstatSync, mkdirSync, openSync, readdirSync, realpathSync, unlinkSync, writeFileSync } from 'node:fs';
import { basename, dirname, join, resolve, sep } from 'node:path';
import { isDeepStrictEqual as same } from 'node:util';
import { joinDependencyInputs, readMaterialReceipt } from '../material-receipts.mjs';
import { readReleaseInput } from '../files.mjs';
import { verifyInputs } from '../inputs.mjs';
import { releaseGit } from '../source.mjs';
import { inspectMacCandidate } from './cohort.mjs';
import { auditMacBundle } from './closure.mjs';
import { macImageTool } from './dmg.mjs';
import { readSparkleSourceReceipt } from './sparkle-source.mjs';
import { joinSparkleInputs } from './sparkle-inputs.mjs';

const encode = value => Buffer.from(JSON.stringify(value) + '\n');
const hash = value => createHash('sha256').update(value).digest('hex');
const fail = message => { throw new Error(message); };
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
export async function macMaterialJoin({ repository, tag, commit, sourcePath, architecture, candidate, candidateSha256, corePath, coreSha256, gleamPath, gleamSha256, sparklePath, sparkleSha256, output }, { tool = macImageTool } = {}) {
  if (Boolean(sparklePath) !== Boolean(sparkleSha256)) fail('both updater receipt custody inputs required');
  repository = realpathSync(repository); output = resolve(output);
  const deadline = performance.now() + 180_000, budget = () => { if (performance.now() > deadline) fail('Mac material join processing deadline'); };
  const source = await verifyInputs(repository, tag, commit, sourcePath); budget();
  const inputDirectories = [candidate, dirname(resolve(corePath)), dirname(resolve(gleamPath)), ...(sparklePath ? [dirname(resolve(sparklePath))] : [])].map(path => resolve(path));
  const custody = () => inputDirectories.map(path => ({ identity: identity(directory(path)), names: readdirSync(path).sort() }));
  const initialCustody = custody();
  const inspect = async () => {
    const core = await readMaterialReceipt(corePath, coreSha256, source, 'locked-core-source-material'), gleam = await readMaterialReceipt(gleamPath, gleamSha256, source, 'locked-gleam-source-material');
    const retained = await inspectMacCandidate({ repository, source, candidate, expectedDigest: candidateSha256, architecture }, tool); budget();
    const sparkle = sparklePath ? await readSparkleSourceReceipt(sparklePath, sparkleSha256, source) : undefined;
    const inputs = joinSparkleInputs(retained.material, sparkle);
    const joined = await joinDependencyInputs(repository, core, gleam, inputs.material); budget();
    return { ...joined, ...(sparkle ? { sparkleReceiptSha256: sparkleSha256, updaterInputs: inputs.updaterInputs } : {}) };
  };
  const joined = await inspect(), parent = dirname(output), parentStat = lstatSync(parent, { bigint: true });
  if (!parentStat.isDirectory() || parentStat.uid !== BigInt(process.getuid()) || (parentStat.mode & 0o022n) !== 0n) fail('unsafe Mac material output parent');
  const physical = join(realpathSync(parent), basename(output)), inputs = inputDirectories.map(path => realpathSync(path));
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
  await readMaterialReceipt(corePath, coreSha256, source, 'locked-core-source-material');
  await readMaterialReceipt(gleamPath, gleamSha256, source, 'locked-gleam-source-material');
  if (sparklePath) await readSparkleSourceReceipt(sparklePath, sparkleSha256, source);
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
