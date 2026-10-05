import { createHash } from 'node:crypto';
import { spawnSync } from 'node:child_process';
import { constants, closeSync, fstatSync, fsyncSync, lstatSync, mkdirSync, openSync, readdirSync, realpathSync, statfsSync, unlinkSync, writeFileSync } from 'node:fs';
import { basename, dirname, join, resolve, sep } from 'node:path';
import { verifyInputs } from '../inputs.mjs';
import { releaseGit } from '../source.mjs';
import { readReleaseInput, withReleaseInput } from '../files.mjs';
import { auditMacBundle } from './closure.mjs';
import { verifyDevelopmentSignatures } from './dmg.mjs';

const encode = value => Buffer.from(JSON.stringify(value) + '\n');
const hash = value => createHash('sha256').update(value).digest('hex');
const same = (a, b) => encode(a).equals(encode(b));
const fail = message => { throw new Error(message); };
const maximumRecord = 16 * 1024 * 1024;

export function candidateCommand(command, args, { cwd, timeout = 30_000, build = false } = {}) {
  const env = { ...process.env };
  for (const name of Object.keys(env)) if (name.startsWith('GIT_')) delete env[name];
  const result = spawnSync(command, args, { cwd, env, timeout, killSignal: 'SIGKILL', encoding: 'utf8', maxBuffer: 64 * 1024,
    stdio: build ? ['ignore', 'inherit', 'inherit'] : ['ignore', 'pipe', 'pipe'] });
  if (result.error || result.status !== 0) fail('Mac candidate tool unavailable');
  return build ? '' : result.stdout.trim();
}
function outputDirectory(path) {
  const stat = lstatSync(path);
  if (!stat.isDirectory() || stat.uid !== process.getuid() || (stat.mode & 0o7777) !== 0o700) fail('unsafe Mac candidate output');
  return stat;
}
function synchronize(path, directory = false) {
  const fd = openSync(path, constants.O_RDONLY | constants.O_NOFOLLOW | constants.O_NONBLOCK | (directory ? constants.O_DIRECTORY : 0));
  try {
    const stat = fstatSync(fd), named = lstatSync(path);
    if (!(directory ? stat.isDirectory() && named.isDirectory() : stat.isFile() && named.isFile()) || stat.dev !== named.dev || stat.ino !== named.ino) fail('Mac candidate sync custody changed');
    fsyncSync(fd);
  } finally { closeSync(fd); }
}
function syncApp(root, observation) {
  for (const file of observation.files) synchronize(join(root, file.path));
  for (const directory of observation.directories) synchronize(join(root, directory.path), true);
}

// Captured dependency bytes are local build inputs, not a claim that the cache
// was authenticated against upstream archives. Generated native outputs are
// checked in the final app closure rather than frozen as compiler input.
export async function macMaterial(repository) {
  const files = [], deadline = performance.now() + 120_000;
  let total = 0, entries = 0;
  const budget = () => { if (performance.now() > deadline) fail('Mac material inventory deadline'); };
  const generated = new Set(['apps/core/deps/exile/priv/exile.so', 'apps/core/deps/exile/priv/spawner', 'apps/core/deps/exqlite/priv/sqlite3_nif.so', 'apps/core/deps/exqlite/priv/sqlite3_nif.a']);
  async function visit(relative, depth) {
    budget();
    if (++entries > 8192 || depth > 32 || Buffer.byteLength(relative) > 512 || /[\u0000-\u001f\u007f]/.test(relative)) fail('Mac material inventory limit');
    const path = join(repository, relative), stat = lstatSync(path, { bigint: true });
    if (stat.isDirectory()) {
      const before = readdirSync(path).sort();
      for (const name of before) if (!['.git', '_build', '.elixir_ls', '.DS_Store'].includes(name)) await visit(`${relative}/${name}`, depth + 1);
      if (!same(before, readdirSync(path).sort())) fail('Mac material namespace changed');
    } else if (stat.isFile()) {
      if (generated.has(relative) || /\.(?:o|beam|d)$/.test(relative)) return;
      if (stat.size > 128n * 1024n * 1024n || (total += Number(stat.size)) > 512 * 1024 * 1024) fail('Mac material byte limit');
      const facts = await withReleaseInput(path, { minimum: 0, maximum: 128 * 1024 * 1024 }, async (handle, size) => {
        const block = Buffer.alloc(64 * 1024), digest = createHash('sha256');
        for (let offset = 0; offset < size;) {
          budget();
          const { bytesRead } = await handle.read(block, 0, Math.min(block.length, size - offset), offset);
          if (!bytesRead) fail('Mac material changed');
          digest.update(block.subarray(0, bytesRead)); offset += bytesRead;
        }
        if ((await handle.read(block, 0, 1, size)).bytesRead) fail('Mac material grew');
        return { bytes: size, sha256: digest.digest('hex') };
      });
      const final = lstatSync(path, { bigint: true });
      if (['dev', 'ino', 'size', 'mode', 'uid', 'gid', 'nlink', 'mtimeNs', 'ctimeNs'].some(key => stat[key] !== final[key])) fail('Mac material changed during admission');
      files.push({ path: relative, mode: Number(stat.mode & 0o7777n), ...facts });
    } else fail('Mac material links and special files unavailable');
  }
  for (const path of ['apps/core/deps', 'packages/decision-kernel/build/packages']) await visit(path, 0);
  if (!files.length) fail('Mac dependency material missing');
  return files;
}

function tools(repository, architecture, execute) {
  const run = (command, args) => execute(command, args, { cwd: repository });
  const machine = run('/usr/bin/uname', ['-m']), armHardware = run('/usr/sbin/sysctl', ['-n', 'hw.optional.arm64']);
  if (machine !== architecture || armHardware !== (architecture === 'arm64' ? '1' : '0')) fail('native physical Mac CPU required');
  const fields = {
    architecture, native: true, macOS: run('/usr/bin/sw_vers', ['-productVersion']), osBuild: run('/usr/bin/sw_vers', ['-buildVersion']),
    xcode: run('/usr/bin/xcodebuild', ['-version']), sdkVersion: run('/usr/bin/xcrun', ['--show-sdk-version']), sdkBuild: run('/usr/bin/xcrun', ['--show-sdk-build-version']),
    swift: run('/usr/bin/swift', ['--version']), elixir: run('mise', ['exec', '--', 'elixir', '--version']), zig: run('mise', ['exec', '--', 'zig', 'version']),
  };
  if (Object.values(fields).some(value => typeof value === 'string' && (!value || Buffer.byteLength(value) > 4096 || value.includes('\0'))) || fields.zig !== '0.16.0') fail('Mac toolchain observation unavailable');
  return fields;
}
function declaredVersion(repository, expected, execute, plist = join(repository, 'apps/macos/App/Info.plist')) {
  const version = execute('/usr/bin/plutil', ['-extract', 'CFBundleShortVersionString', 'raw', plist], { cwd: repository });
  const identifier = execute('/usr/bin/plutil', ['-extract', 'CFBundleIdentifier', 'raw', plist], { cwd: repository });
  if (version !== expected || identifier !== 'io.frameshift.app') fail('Mac bundle version differs from source');
}
function nativeSignatures(root, observation, repository, execute) {
  verifyDevelopmentSignatures(root, observation, (command, args, timeout) => {
    if (args.includes('--display')) {
      // codesign writes display data to stderr; capture only this fixed public
      // ad-hoc signature selector without dumping diagnostics or paths.
      const result = spawnSync(command, args, { cwd: repository, timeout: 30_000, killSignal: 'SIGKILL', maxBuffer: 64 * 1024, encoding: 'utf8' });
      if (result.error || result.status !== 0) fail('Mac candidate signature unavailable');
      return { stdout: result.stdout, stderr: result.stderr };
    }
    return { stdout: execute(command, args, { cwd: repository, timeout }), stderr: '' };
  });
}

export async function macBuildCandidate({ repository, tag, commit, sourcePath, architecture, output }, execute = candidateCommand) {
  if (!['arm64', 'x86_64'].includes(architecture)) fail('unsupported Mac candidate CPU');
  repository = realpathSync(repository); output = resolve(output);
  const source = await verifyInputs(repository, tag, commit, sourcePath);
  const execution = tools(repository, architecture, execute); declaredVersion(repository, source.version, execute);
  const material = await macMaterial(repository);
  const physical = join(realpathSync(dirname(output)), basename(output));
  const artifactRoot = join(repository, 'apps/macos/.build/artifacts');
  if (physical === repository || physical === artifactRoot || physical.startsWith(artifactRoot + sep) || artifactRoot.startsWith(physical + sep) || (physical.startsWith(repository + sep) && !releaseGit(repository, ['check-ignore', '--no-index', physical]).length)) fail('Mac candidate output overlaps source or mutable artifacts');
  const subject = { schemaVersion: 1, kind: 'macos-native-build-candidate', product: source.product, publicationAuthority: 'none', tag, version: source.version,
    sourceCommit: commit, sourceInputsSha256: hash(encode(source)), architecture, execution, material };
  if (encode(subject).length > maximumRecord) fail('Mac candidate record limit');
  const app = join(output, 'Frameshift.app'), recordPath = join(output, 'candidate.json');
  const versions = root => {
    declaredVersion(repository, source.version, execute, join(root, 'Contents/Info.plist'));
    if (execute('mise', ['exec', '--', 'elixir', join(repository, 'release/linux/verify-version.exs'), join(root, 'Contents/Resources/core'), source.version], { cwd: repository, timeout: 60_000 }) !== 'runtime version: verified') fail('Mac runtime version unavailable');
  };
  const recheck = async () => {
    await verifyInputs(repository, tag, commit, sourcePath);
    if (!same(material, await macMaterial(repository)) || !same(execution, tools(repository, architecture, execute))) fail('Mac build inputs changed');
  };
  let exists = false;
  try { lstatSync(output); exists = true; } catch (error) { if (error.code !== 'ENOENT') throw error; }
  const summary = (bundle, bytes, disposition) => ({ schemaVersion: 1, publicationAuthority: 'none', tag, sourceCommit: commit, sourceInputsSha256: subject.sourceInputsSha256,
    architecture, minimumOS: bundle.declaredMinimum, recordSha256: hash(bytes), disposition });
  if (exists) {
    const before = outputDirectory(output);
    if (!same(readdirSync(output).sort(), ['Frameshift.app', 'candidate.json'])) fail('incomplete or unknown Mac candidate output');
    const bytes = await readReleaseInput(recordPath, { maximum: maximumRecord, privateKey: true });
    const bundle = await auditMacBundle(app, architecture); versions(app); nativeSignatures(app, bundle, repository, execute);
    if (!bytes.equals(encode({ ...subject, bundle }))) fail('Mac candidate inputs or bytes changed');
    await recheck();
    const final = outputDirectory(output);
    if (before.dev !== final.dev || before.ino !== final.ino || !same(readdirSync(output).sort(), ['Frameshift.app', 'candidate.json']) || !same(bundle, await auditMacBundle(app, architecture)) || !(await readReleaseInput(recordPath, { maximum: maximumRecord, privateKey: true })).equals(bytes)) fail('Mac candidate replay custody changed');
    return summary(bundle, bytes, 'retained-bytes-verified');
  }
  const free = statfsSync(dirname(output), { bigint: true }), needed = 1024n * 1024n * 1024n + BigInt(material.reduce((sum, file) => sum + file.bytes, 0)) * 2n;
  if (free.bavail * free.bsize < needed) fail('insufficient Mac candidate build space');
  mkdirSync(output, { mode: 0o700 }); const created = outputDirectory(output);
  writeFileSync(join(output, 'build.pending'), 'incomplete tagged Mac candidate\n', { flag: 'wx', mode: 0o600 }); synchronize(join(output, 'build.pending')); synchronize(output, true);
  execute(join(repository, 'scripts/package-macos'), [], { cwd: repository, build: true, timeout: 30 * 60_000 });
  await recheck();
  const built = join(repository, 'apps/macos/.build/artifacts/Frameshift.app'), bundle = await auditMacBundle(built, architecture);
  versions(built); nativeSignatures(built, bundle, repository, execute);
  execute('/usr/bin/ditto', [built, app], { cwd: repository, timeout: 120_000 });
  if (!same(bundle, await auditMacBundle(app, architecture))) fail('Mac candidate copy differs');
  versions(app); nativeSignatures(app, bundle, repository, execute); await recheck();
  const bytes = encode({ ...subject, bundle });
  if (bytes.length > maximumRecord) fail('Mac candidate record limit');
  syncApp(app, bundle); writeFileSync(recordPath, bytes, { flag: 'wx', mode: 0o600 }); synchronize(recordPath);
  await recheck();
  const final = outputDirectory(output);
  if (created.dev !== final.dev || created.ino !== final.ino || !same(readdirSync(output).sort(), ['Frameshift.app', 'build.pending', 'candidate.json']) || !same(bundle, await auditMacBundle(app, architecture)) || !(await readReleaseInput(recordPath, { maximum: maximumRecord, privateKey: true })).equals(bytes)) fail('Mac candidate final custody changed');
  synchronize(output, true); unlinkSync(join(output, 'build.pending')); synchronize(output, true); synchronize(dirname(output), true);
  return summary(bundle, bytes, 'native-build-candidate');
}
