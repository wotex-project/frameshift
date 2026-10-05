import { spawnSync } from 'node:child_process';
import { createHash } from 'node:crypto';
import { chmod, lstat, mkdir, mkdtemp, readdir, readlink, rename, rm, writeFile } from 'node:fs/promises';
import { basename, dirname, join, resolve } from 'node:path';
import { isDeepStrictEqual as same } from 'node:util';
import { readReleaseInput } from '../files.mjs';
import { sparkleArchive, sparkleLinks, sparkleRoles, sparkleRoot } from '../macos-framework.mjs';
import { inspectMachO } from './closure.mjs';

const archiveBounds = { minimum: sparkleArchive.bytes, maximum: sparkleArchive.bytes, protectedTrust: true };
const hash = bytes => createHash('sha256').update(bytes).digest('hex');
const identity = stat => ['dev', 'ino', 'mode', 'uid', 'gid', 'nlink', 'size', 'mtimeNs', 'ctimeNs'].map(key => String(stat[key]));
const fail = () => { throw new Error('pinned updater material unavailable, unsafe or changed'); };
const relative = path => path.slice(sparkleRoot.length + 1);
const aliases = new Map([...sparkleLinks].map(([path, target]) => [relative(path), target]));
const roles = new Map([...sparkleRoles].map(([path, type]) => [relative(path), type]));
const run = (command, args) => {
  const result = spawnSync(command, args, { timeout: 30_000, maxBuffer: 64 * 1024, stdio: ['ignore', 'pipe', 'pipe'] });
  if (result.error || result.status !== 0) fail();
};

async function snapshot(root, budget) {
  const files = [], directories = [], links = [], custody = [];
  let entries = 0, total = 0;
  async function visit(path, depth) {
    budget();
    if (++entries > 512 || depth > 24 || Buffer.byteLength(path) > 512 || /[\u0000-\u001f\u007f]/.test(path)) fail();
    const named = path ? join(root, path) : root, before = await lstat(named, { bigint: true });
    if (![0n, BigInt(process.getuid())].includes(before.uid)) fail();
    if (before.isSymbolicLink()) {
      const target = await readlink(named);
      if (before.nlink !== 1n || aliases.get(path) !== target || !same(identity(before), identity(await lstat(named, { bigint: true }))) || await readlink(named) !== target) fail();
      links.push({ path, target });
    } else {
      const mode = Number(before.mode & 0o7777n);
      if ((mode & 0o7022) || !(mode & 0o400)) fail();
      if (before.isDirectory()) {
        const names = (await readdir(named)).sort();
        for (const name of names) await visit(path ? `${path}/${name}` : name, depth + 1);
        if (!same(names, (await readdir(named)).sort())) fail();
        directories.push({ path, mode });
      } else if (before.isFile()) {
        if (before.nlink !== 1n || before.size > 16n * 1024n * 1024n || (total += Number(before.size)) > 64 * 1024 * 1024) fail();
        const bytes = await readReleaseInput(named, { minimum: 0, maximum: 16 * 1024 * 1024, protectedTrust: true });
        files.push({ path, mode, bytes: bytes.length, sha256: hash(bytes) });
      } else fail();
      if (!same(identity(before), identity(await lstat(named, { bigint: true })))) fail();
    }
    custody.push({ path, identity: identity(before) });
  }
  await visit('', 0);
  const ordered = items => items.sort((a, b) => a.path.localeCompare(b.path));
  return { content: { files: ordered(files), directories: ordered(directories), links: ordered(links) }, custody: ordered(custody) };
}

async function withArchive(path, consume) {
  if (process.platform !== 'darwin') fail();
  const deadline = performance.now() + 120_000, budget = () => { if (performance.now() > deadline) fail(); };
  const named = await lstat(path, { bigint: true });
  if (!named.isFile() || named.nlink !== 1n) fail();
  const before = identity(named);
  const bytes = await readReleaseInput(path, archiveBounds);
  if (hash(bytes) !== sparkleArchive.sha256) fail();
  const work = await mkdtemp('/tmp/frameshift-updater-material.'); await chmod(work, 0o700);
  try {
    const retained = join(work, 'sdk.zip'); await writeFile(retained, bytes, { flag: 'wx', mode: 0o600 });
    run('/usr/bin/unzip', ['-q', retained, 'Sparkle.xcframework/macos-arm64_x86_64/Sparkle.framework/*', '-d', work]); budget();
    const framework = join(work, 'Sparkle.xcframework/macos-arm64_x86_64/Sparkle.framework');
    const expected = await snapshot(framework, budget);
    if (!same(new Map(expected.content.links.map(link => [link.path, link.target])), aliases)) fail();
    const native = [];
    for (const [path, filetype] of roles) {
      const slices = await inspectMachO(join(framework, path), budget);
      if (!same(slices.map(slice => slice.arch), ['arm64', 'x86_64']) || slices.some(slice => slice.filetype !== filetype)) fail();
      native.push({ path, slices });
    }
    const result = await consume(framework, expected.content, native, budget);
    if (!same(await snapshot(framework, budget), expected) ||
        !(await readReleaseInput(path, archiveBounds)).equals(bytes) ||
        !same(identity(await lstat(path, { bigint: true })), before) ||
        !(await readReleaseInput(retained, { ...archiveBounds, privateKey: true })).equals(bytes)) fail();
    budget();
    return result;
  } finally { await rm(work, { recursive: true, force: true }); }
}

/** Compare actual cached compilation bytes with the separately pinned ZIP. */
export async function verifySparkleFramework(archive, input) {
  return withArchive(archive, async (_, expected, native, budget) => {
    const before = await snapshot(resolve(input), budget);
    if (!same(before.content, expected) || !same(await snapshot(resolve(input), budget), before)) fail();
    return { schemaVersion: 1, publicationAuthority: 'none', archive: sparkleArchive, framework: expected, native };
  });
}

/** Derive one CPU only in an unpublished package stage, never the SDK cache. */
export async function stageSparkleFramework(archive, input, architecture) {
  if (!['arm64', 'x86_64'].includes(architecture)) fail();
  const app = resolve(input), parent = dirname(app), stat = await lstat(parent);
  if (basename(app) !== 'Frameshift.app' || !/^\.package\.[a-zA-Z0-9]+$/.test(basename(parent)) ||
      !stat.isDirectory() || stat.uid !== process.getuid() || (stat.mode & 0o7777) !== 0o700) fail();
  for (const directory of [app, join(app, 'Contents')]) {
    const stat = await lstat(directory);
    if (!stat.isDirectory() || stat.uid !== process.getuid() || (stat.mode & 0o7022)) fail();
  }
  const frameworks = join(app, 'Contents/Frameworks');
  try { await lstat(frameworks); fail(); } catch (error) { if (error.code !== 'ENOENT') throw error; }
  return withArchive(archive, async (source, expected, native, budget) => {
    await mkdir(frameworks, { mode: 0o755 });
    const target = join(app, sparkleRoot); run('/usr/bin/ditto', [source, target]); budget();
    if (!same((await snapshot(target, budget)).content, expected)) fail();
    for (const file of native) {
      const output = join(parent, 'sparkle-thin');
      run('/usr/bin/lipo', ['-thin', architecture, join(source, file.path), '-output', output]);
      const original = expected.files.find(item => item.path === file.path); await chmod(output, original.mode);
      if (!same(await inspectMachO(output, budget), file.slices.filter(slice => slice.arch === architecture))) fail();
      await rename(output, join(target, file.path));
    }
    const derived = await snapshot(target, budget), nativePaths = new Set(native.map(file => file.path));
    if (!same(derived.content.links, expected.links) || !same(derived.content.directories, expected.directories) ||
        !same(derived.content.files.filter(file => !nativePaths.has(file.path)), expected.files.filter(file => !nativePaths.has(file.path)))) fail();
    return { schemaVersion: 1, publicationAuthority: 'none', archive: sparkleArchive, architecture,
      source: expected, derived: derived.content, native: native.map(file => ({ path: file.path, slices: file.slices.filter(slice => slice.arch === architecture) })) };
  });
}

if (process.argv[1] === new URL(import.meta.url).pathname) {
  const [operation, ...args] = process.argv.slice(2);
  if (!((operation === 'verify' && args.length === 2) || (operation === 'stage' && args.length === 3))) {
    console.error('usage: sparkle-material.mjs verify ARCHIVE FRAMEWORK | stage ARCHIVE PRIVATE_APP CPU'); process.exitCode = 64;
  } else {
    try { console.log(JSON.stringify(await (operation === 'verify' ? verifySparkleFramework(...args) : stageSparkleFramework(...args)))); }
    catch { console.error('pinned updater material unavailable, unsafe or changed'); process.exitCode = 1; }
  }
}
