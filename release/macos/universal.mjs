import { createHash } from 'node:crypto';
import { constants, chmodSync, closeSync, fsyncSync, lstatSync, mkdirSync, mkdtempSync, openSync, readdirSync, realpathSync, renameSync, rmSync, statfsSync, unlinkSync, writeFileSync } from 'node:fs';
import { basename, dirname, join, resolve } from 'node:path';
import { isDeepStrictEqual } from 'node:util';
import { readReleaseInput } from '../files.mjs';
import { auditMacBundle } from './closure.mjs';
import { prepareDevelopmentBundle } from './prepare.mjs';
import { macImageTool, verifyDevelopmentSignatures } from './dmg.mjs';

const maximum = 1024 * 1024, encode = value => Buffer.from(JSON.stringify(value));
const hash = bytes => createHash('sha256').update(bytes).digest('hex');
const fail = message => { throw new Error(message); };
const ignored = new Set(['Contents/Info.plist', 'Contents/_CodeSignature/CodeResources']);
const privateDirectory = path => {
  const stat = lstatSync(path);
  if (!stat.isDirectory() || stat.uid !== process.getuid() || (stat.mode & 0o7777) !== 0o700) fail('unsafe universal output');
  return stat;
};
function sync(path) {
  const fd = openSync(path, constants.O_RDONLY | constants.O_NOFOLLOW | constants.O_NONBLOCK);
  try { fsyncSync(fd); } finally { closeSync(fd); }
}
function syncTree(root, observation) {
  for (const file of observation.files) sync(join(root, file.path));
  function directories(path) {
    for (const name of readdirSync(path)) if (lstatSync(join(path, name)).isDirectory()) directories(join(path, name));
    const fd = openSync(path, constants.O_RDONLY | constants.O_NOFOLLOW | constants.O_DIRECTORY);
    try { fsyncSync(fd); } finally { closeSync(fd); }
  }
  directories(root);
}
async function comparablePlist(root, tool) {
  await readReleaseInput(join(root, 'Contents/Info.plist'), { maximum: 64 * 1024 });
  const { stdout } = tool('/usr/bin/plutil', ['-convert', 'json', '-o', '-', join(root, 'Contents/Info.plist')]);
  let value; try { value = JSON.parse(stdout); } catch { fail('invalid universal source plist'); }
  for (const key of ['CFBundleIdentifier', 'CFBundleShortVersionString', 'CFBundleVersion']) if (typeof value[key] !== 'string' || !value[key] || Buffer.byteLength(value[key]) > 256 || /[\u0000-\u001f\u007f]/.test(value[key])) fail('missing universal product identity');
  delete value.LSMinimumSystemVersion;
  return value;
}
function pair(arm, intel) {
  for (const [observation, architecture] of [[arm, 'arm64'], [intel, 'x86_64']]) {
    if (observation.natives.some(file => file.slices.length !== 1 || file.slices[0].arch !== architecture)) fail('universal inputs require exact single CPU');
  }
  if (!isDeepStrictEqual(arm.files.map(file => file.path), intel.files.map(file => file.path))) fail('universal source file sets differ');
  if (!isDeepStrictEqual(arm.directories, intel.directories)) fail('universal source directories differ');
  const aNative = new Map(arm.natives.map(file => [file.path, file])), iNative = new Map(intel.natives.map(file => [file.path, file]));
  if (!isDeepStrictEqual([...aNative.keys()], [...iNative.keys()])) fail('universal native roles differ');
  let estimate = 0;
  for (let index = 0; index < arm.files.length; index++) {
    const a = arm.files[index], i = intel.files[index];
    if (a.mode !== i.mode) fail('universal source modes differ');
    if (aNative.has(a.path)) {
      if (aNative.get(a.path).slices[0].filetype !== iNative.get(a.path).slices[0].filetype) fail('universal native types differ');
      const bytes = a.bytes + i.bytes + 1024 * 1024;
      if (bytes > 128 * 1024 * 1024) fail('universal native byte estimate exceeds closure limit');
      estimate += bytes;
    } else {
      if (!ignored.has(a.path) && !isDeepStrictEqual(a, i)) fail('universal common bytes differ');
      estimate += Math.max(a.bytes, i.bytes);
    }
  }
  if (estimate > 512 * 1024 * 1024) fail('universal byte estimate exceeds closure limit');
  return estimate;
}

export async function universalDevelopmentBundle(armInput, intelInput, destination, { tool = macImageTool } = {}) {
  const arm = await auditMacBundle(armInput, 'arm64'), intel = await auditMacBundle(intelInput, 'x86_64');
  verifyDevelopmentSignatures(resolve(armInput), arm, tool); verifyDevelopmentSignatures(resolve(intelInput), intel, tool);
  const estimate = pair(arm, intel), armRoot = realpathSync(armInput), intelRoot = realpathSync(intelInput);
  if (!isDeepStrictEqual(await comparablePlist(armRoot, tool), await comparablePlist(intelRoot, tool))) fail('universal product plists differ');
  const output = join(realpathSync(dirname(resolve(destination))), basename(destination));
  if (/[\u0000-\u001f\u007f]/.test(output) || [armRoot, intelRoot].some(source => source === output || source.startsWith(`${output}/`) || output.startsWith(`${source}/`))) fail('overlapping universal paths');
  const identity = { schemaVersion: 1, publicationAuthority: 'none', architecture: 'universal', inputs: [arm, intel] };
  if (encode(identity).length > maximum) fail('universal record limit');
  const app = join(output, 'Frameshift.app'), recordPath = join(output, 'universal.json');
  let exists = false;
  try { lstatSync(output); exists = true; } catch (error) { if (error.code !== 'ENOENT') throw error; }
  const summary = (bundle, record, disposition) => ({ schemaVersion: 1, publicationAuthority: 'none', architecture: 'universal', minimumOS: bundle.declaredMinimum, nativeFiles: bundle.natives.length, recordSha256: hash(record), disposition });
  if (exists) {
    const before = privateDirectory(output);
    if (!isDeepStrictEqual(readdirSync(output).sort(), ['Frameshift.app', 'universal.json'])) fail('incomplete or unknown universal output');
    const record = await readReleaseInput(recordPath, { maximum, privateKey: true });
    const bundle = await auditMacBundle(app, 'universal'); verifyDevelopmentSignatures(app, bundle, tool);
    if (!record.equals(encode({ ...identity, bundle }))) fail('universal inputs or retained bytes changed');
    if (!encode(await auditMacBundle(armRoot, 'arm64')).equals(encode(arm)) || !encode(await auditMacBundle(intelRoot, 'x86_64')).equals(encode(intel)) || !encode(await auditMacBundle(app, 'universal')).equals(encode(bundle)) || !(await readReleaseInput(recordPath, { maximum, privateKey: true })).equals(record)) fail('universal replay custody changed');
    const final = privateDirectory(output);
    if (before.dev !== final.dev || before.ino !== final.ino || !isDeepStrictEqual(readdirSync(output).sort(), ['Frameshift.app', 'universal.json'])) fail('universal output custody changed');
    return summary(bundle, record, 'retained-bytes-verified');
  }
  const free = statfsSync(dirname(output), { bigint: true });
  if (free.bavail * free.bsize < BigInt(estimate) * 2n + 256n * 1024n * 1024n) fail('insufficient universal staging space');
  mkdirSync(output, { mode: 0o700 }); const created = privateDirectory(output);
  writeFileSync(join(output, 'build.pending'), 'incomplete universal development bundle\n', { flag: 'wx', mode: 0o600 }); sync(join(output, 'build.pending'));
  const stageRoot = mkdtempSync(join(output, '.package.')), stage = join(stageRoot, 'Frameshift.app');
  tool('/usr/bin/ditto', [armRoot, stage], 120_000);
  if (!encode(await auditMacBundle(stage, 'arm64')).equals(encode(arm))) fail('universal copied source changed');
  for (const file of arm.natives) {
    const merged = join(stageRoot, 'merged');
    tool('/usr/bin/lipo', ['-create', join(armRoot, file.path), join(intelRoot, file.path), '-output', merged], 120_000);
    chmodSync(merged, file.mode); renameSync(merged, join(stage, file.path));
  }
  await prepareDevelopmentBundle(stage, 'universal');
  const bundle = await auditMacBundle(stage, 'universal'); verifyDevelopmentSignatures(stage, bundle, tool);
  const record = encode({ ...identity, bundle });
  if (record.length > maximum) fail('universal record limit');
  if (!encode(await auditMacBundle(armRoot, 'arm64')).equals(encode(arm)) || !encode(await auditMacBundle(intelRoot, 'x86_64')).equals(encode(intel))) fail('universal source changed during merge');
  syncTree(stage, bundle); renameSync(stage, app); rmSync(stageRoot, { recursive: true });
  writeFileSync(recordPath, record, { flag: 'wx', mode: 0o600 }); sync(recordPath);
  const final = privateDirectory(output);
  if (created.dev !== final.dev || created.ino !== final.ino || !isDeepStrictEqual(readdirSync(output).sort(), ['Frameshift.app', 'build.pending', 'universal.json']) || !encode(await auditMacBundle(app, 'universal')).equals(encode(bundle)) || !(await readReleaseInput(recordPath, { maximum, privateKey: true })).equals(record)) fail('universal final custody changed');
  syncTree(output, { files: [] }); unlinkSync(join(output, 'build.pending')); syncTree(output, { files: [] });
  return summary(bundle, record, 'development-candidate');
}
