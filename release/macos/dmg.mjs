import { spawnSync } from 'node:child_process';
import { constants, chmodSync, closeSync, fstatSync, fsyncSync, lstatSync, mkdirSync, mkdtempSync, openSync, readdirSync, readlinkSync, realpathSync, rmSync, statfsSync, symlinkSync, unlinkSync, writeFileSync } from 'node:fs';
import { basename, dirname, join, resolve } from 'node:path';
import { createHash } from 'node:crypto';
import { readReleaseInput, withReleaseInput } from '../files.mjs';
import { auditMacBundle } from './closure.mjs';

const sha256 = bytes => createHash('sha256').update(bytes).digest('hex');
const fail = message => { throw new Error(message); };
const reading = Buffer.from('Frameshift development build\n\nThis local disk image is an unpublished development candidate. It carries no production installation or update qualification. Do not distribute it as a release.\n');
const metadataLimit = 1024 * 1024, imageLimit = 1024 * 1024 * 1024;

export function macImageTool(command, args, timeout = 30_000) {
  const result = spawnSync(command, args, { encoding: 'utf8', timeout, killSignal: 'SIGKILL', maxBuffer: 256 * 1024 });
  if (result.error || result.status !== 0) fail('Mac disk-image tool refused');
  return { stdout: result.stdout, stderr: result.stderr };
}

function synchronize(path, directory = false) {
  const fd = openSync(path, constants.O_RDONLY | constants.O_NOFOLLOW | constants.O_NONBLOCK | (directory ? constants.O_DIRECTORY : 0));
  try {
    const opened = fstatSync(fd), named = lstatSync(path);
    if (!(directory ? opened.isDirectory() && named.isDirectory() : opened.isFile() && named.isFile()) || opened.dev !== named.dev || opened.ino !== named.ino) fail('disk-image sync custody changed');
    fsyncSync(fd);
  } finally { closeSync(fd); }
}
function privateOutput(path) {
  const stat = lstatSync(path);
  if (!stat.isDirectory() || stat.uid !== process.getuid() || (stat.mode & 0o7777) !== 0o700) fail('unsafe disk-image output');
}
function save(path, bytes) {
  if (bytes.length > metadataLimit) fail('disk-image metadata limit');
  writeFileSync(path, bytes, { flag: 'wx', mode: 0o600 }); synchronize(path);
}
async function metadata(path) {
  return readReleaseInput(path, { maximum: metadataLimit, privateKey: true });
}
async function imageFacts(path) {
  return withReleaseInput(path, { maximum: imageLimit, privateKey: true, budgetMs: 120_000 }, async (handle, size, budget) => {
    const block = Buffer.alloc(64 * 1024), hash = createHash('sha256');
    for (let offset = 0; offset < size;) {
      budget();
      const { bytesRead } = await handle.read(block, 0, Math.min(block.length, size - offset), offset);
      if (!bytesRead) fail('disk image changed');
      hash.update(block.subarray(0, bytesRead)); offset += bytesRead;
    }
    if ((await handle.read(block, 0, 1, size)).bytesRead) fail('disk image grew');
    return { bytes: size, sha256: hash.digest('hex') };
  });
}
function signatures(root, observation, tool) {
  for (const native of observation.natives) tool('/usr/bin/codesign', ['--verify', '--strict', join(root, native.path)]);
  tool('/usr/bin/codesign', ['--verify', '--deep', '--strict', root]);
  const signature = tool('/usr/bin/codesign', ['--display', '--verbose=2', root]);
  if (!/^Signature=adhoc$/m.test(signature.stderr)) fail('ad-hoc development app required');
}

async function mountedReadback(image, work, expectedBytes, architecture, tool) {
  const mount = join(work, 'mount'); mkdirSync(mount, { mode: 0o700 });
  const original = lstatSync(mount);
  let attachAttempted = false, detached = false;
  try {
    tool('/usr/bin/hdiutil', ['verify', '-nocache', image], 120_000);
    attachAttempted = true;
    tool('/usr/bin/hdiutil', ['attach', image, '-readonly', '-nobrowse', '-noautoopen', '-noautofsck', '-mountpoint', mount, '-plist']);
    const names = readdirSync(mount).sort();
    const known = new Set(['Frameshift.app', 'Applications', 'Read Me.txt', '.fseventsd', '.Trashes', '.Spotlight-V100']);
    if (names.some(name => !known.has(name)) || !['Frameshift.app', 'Applications', 'Read Me.txt'].every(name => names.includes(name))) fail('unexpected mounted image member');
    const applications = join(mount, 'Applications');
    if (!lstatSync(applications).isSymbolicLink() || readlinkSync(applications) !== '/Applications') fail('invalid Applications link');
    if (!(await readReleaseInput(join(mount, 'Read Me.txt'), { maximum: 4096 })).equals(reading)) fail('invalid development reading text');
    const mounted = join(mount, 'Frameshift.app'), observation = await auditMacBundle(mounted, architecture);
    if (!Buffer.from(JSON.stringify(observation)).equals(expectedBytes)) fail('mounted app differs from admitted source');
    signatures(mounted, observation, tool);
    tool('/usr/bin/hdiutil', ['detach', mount]); detached = true;
  } finally {
    if (attachAttempted && !detached) {
      // Even a timed-out attach can leave a live OS mount. Its exact private
      // mountpoint must detach before any recursive cleanup is permitted.
      try { tool('/usr/bin/hdiutil', ['detach', mount]); detached = true; }
      catch { fail('disk-image mount retained after refused detach'); }
    }
    if (!attachAttempted || detached) {
      const current = lstatSync(mount);
      if (!current.isDirectory() || current.dev !== original.dev || current.ino !== original.ino) fail('original mountpoint custody not restored');
      rmSync(mount, { recursive: true });
    }
  }
}

export async function developmentDiskImage(input, architecture, destination, { tool = macImageTool } = {}) {
  const initial = await auditMacBundle(input, architecture);
  signatures(resolve(input), initial, tool);
  const source = realpathSync(input), output = join(realpathSync(dirname(resolve(destination))), basename(destination));
  if (output === source || output.startsWith(`${source}/`) || source.startsWith(`${output}/`) || /[\u0000-\u001f\u007f]/.test(output)) fail('overlapping or unsafe disk-image paths');
  const observationBytes = Buffer.from(JSON.stringify(initial)), name = `Frameshift-development-${architecture}.dmg`;
  const image = join(output, name), expected = { schemaVersion: 1, publicationAuthority: 'none', architecture, minimumOS: initial.declaredMinimum, bundleSha256: sha256(observationBytes), archive: name };
  if (observationBytes.length > metadataLimit) fail('disk-image metadata limit');
  if (lstatSync(dirname(output)).isDirectory() === false) fail('disk-image parent required');
  let exists = false;
  try { lstatSync(output); exists = true; } catch (error) { if (error.code !== 'ENOENT') throw error; }
  if (exists) {
    privateOutput(output);
    const retained = lstatSync(output);
    if (JSON.stringify(readdirSync(output).sort()) !== JSON.stringify([name, 'bundle.json', 'dmg.json'].sort())) fail('incomplete or unknown disk-image output');
    const bundleBytes = await metadata(join(output, 'bundle.json'));
    if (!bundleBytes.equals(observationBytes)) fail('source bundle changed');
    const recordBytes = await metadata(join(output, 'dmg.json'));
    let record; try { record = JSON.parse(recordBytes); } catch { fail('invalid disk-image record'); }
    const facts = await imageFacts(image), candidate = { ...expected, ...facts };
    if (!Buffer.from(JSON.stringify(candidate)).equals(recordBytes)) fail('disk-image record or bytes changed');
    // Readback workspace lives beside, rather than inside, completed immutable
    // output. A failed unmount remains visible and is never recursively erased.
    const work = mkdtempSync(join(dirname(output), '.dmg-readback.'));
    await mountedReadback(image, work, bundleBytes, architecture, tool);
    rmSync(work, { recursive: true });
    privateOutput(output);
    const current = lstatSync(output);
    if (retained.dev !== current.dev || retained.ino !== current.ino || JSON.stringify(readdirSync(output).sort()) !== JSON.stringify([name, 'bundle.json', 'dmg.json'].sort()) || JSON.stringify(await imageFacts(image)) !== JSON.stringify(facts) || !Buffer.from(JSON.stringify(await auditMacBundle(source, architecture))).equals(bundleBytes) || !(await metadata(join(output, 'dmg.json'))).equals(recordBytes) || !(await metadata(join(output, 'bundle.json'))).equals(bundleBytes)) fail('disk-image replay custody changed');
    return { ...candidate, disposition: 'retained-bytes-verified' };
  }
  const free = statfsSync(dirname(output), { bigint: true });
  const needed = BigInt(initial.files.reduce((sum, file) => sum + file.bytes, 0)) * 2n + 256n * 1024n * 1024n;
  if (free.bavail * free.bsize < needed) fail('insufficient disk-image staging space');
  mkdirSync(output, { mode: 0o700 }); privateOutput(output);
  const created = lstatSync(output);
  save(join(output, 'build.pending'), Buffer.from('incomplete development disk image\n'));
  const work = join(output, '.work'), payload = join(work, 'payload');
  mkdirSync(payload, { recursive: true, mode: 0o700 });
  const copied = join(payload, 'Frameshift.app');
  tool('/usr/bin/ditto', [source, copied], 120_000);
  if (!Buffer.from(JSON.stringify(await auditMacBundle(copied, architecture))).equals(observationBytes)) fail('copied app differs from admitted source');
  signatures(copied, initial, tool);
  symlinkSync('/Applications', join(payload, 'Applications'));
  writeFileSync(join(payload, 'Read Me.txt'), reading, { flag: 'wx', mode: 0o644 });
  tool('/usr/bin/hdiutil', ['create', '-srcfolder', payload, '-fs', 'HFS+', '-format', 'UDZO', '-volname', 'Frameshift Development', '-nospotlight', '-noskipunreadable', image], 120_000);
  chmodSync(image, 0o600);
  const facts = await imageFacts(image);
  await mountedReadback(image, work, observationBytes, architecture, tool);
  if (JSON.stringify(await imageFacts(image)) !== JSON.stringify(facts) || !Buffer.from(JSON.stringify(await auditMacBundle(source, architecture))).equals(observationBytes)) fail('disk-image build custody changed');
  rmSync(work, { recursive: true });
  synchronize(image); save(join(output, 'bundle.json'), observationBytes); save(join(output, 'dmg.json'), Buffer.from(JSON.stringify({ ...expected, ...facts })));
  privateOutput(output);
  const final = lstatSync(output);
  if (created.dev !== final.dev || created.ino !== final.ino || JSON.stringify(readdirSync(output).sort()) !== JSON.stringify([name, 'bundle.json', 'dmg.json', 'build.pending'].sort()) || JSON.stringify(await imageFacts(image)) !== JSON.stringify(facts) || !(await metadata(join(output, 'bundle.json'))).equals(observationBytes) || !(await metadata(join(output, 'dmg.json'))).equals(Buffer.from(JSON.stringify({ ...expected, ...facts })))) fail('disk-image output custody changed');
  synchronize(output, true); unlinkSync(join(output, 'build.pending')); synchronize(output, true);
  return { ...expected, ...facts, disposition: 'development-candidate' };
}
