import { spawnSync } from 'node:child_process';
import { constants, closeSync, cpSync, fstatSync, fsyncSync, lstatSync, mkdirSync, mkdtempSync, openSync, readFileSync, readdirSync, realpathSync, rmSync, unlinkSync, writeFileSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { basename, dirname, join, resolve, sep } from 'node:path';
import { verifyInputs } from '../inputs.mjs';
import { releaseGit } from '../source.mjs';
import { contextNames, gleamHashes, inventory, sha256 } from './material.mjs';

const equal = (a, b) => JSON.stringify(a) === JSON.stringify(b);
const encode = record => JSON.stringify(record) + '\n';
function directory(path, privateMode = false) {
  const stat = lstatSync(path);
  if (!stat.isDirectory() || stat.uid !== process.getuid() ||
      (privateMode ? (stat.mode & 0o7777) !== 0o700 : (stat.mode & 0o022) !== 0)) throw new Error('unsafe candidate directory');
}
function syncDirectory(path) {
  const fd = openSync(path, constants.O_RDONLY | constants.O_DIRECTORY | constants.O_NOFOLLOW);
  try { fsyncSync(fd); } finally { closeSync(fd); }
}
function readCandidate(path) {
  if (!lstatSync(path).isFile()) throw new Error('unsafe candidate record');
  const fd = openSync(path, constants.O_RDONLY | constants.O_NOFOLLOW | constants.O_NONBLOCK);
  try {
    const before = fstatSync(fd, { bigint: true });
    if (!before.isFile() || before.uid !== BigInt(process.getuid()) || (before.mode & 0o7777n) !== 0o600n || before.size > 16n * 1024n * 1024n) {
      throw new Error('unsafe candidate record');
    }
    const bytes = readFileSync(fd, 'utf8');
    const after = fstatSync(fd, { bigint: true });
    const named = lstatSync(path, { bigint: true });
    if (['dev', 'ino', 'size', 'mode', 'mtimeNs', 'ctimeNs'].some(key => before[key] !== after[key] || after[key] !== named[key])) {
      throw new Error('candidate record changed');
    }
    const record = JSON.parse(bytes);
    if (encode(record) !== bytes) throw new Error('noncanonical candidate record');
    return record;
  } finally { closeSync(fd); }
}
function run(command, args, capture = false) {
  const environment = { ...process.env };
  for (const name of Object.keys(environment)) if (name.startsWith('GIT_')) delete environment[name];
  const result = spawnSync(command, args, { stdio: capture ? ['ignore', 'pipe', 'pipe'] : ['ignore', 'inherit', 'inherit'],
    env: environment, encoding: 'utf8', timeout: 30 * 60_000, maxBuffer: 64 * 1024 });
  if (result.error || result.status !== 0) throw new Error('target build unavailable');
  return capture ? result.stdout.trim() : '';
}
function subject(source, architecture) {
  return { schemaVersion: 1, kind: 'ubuntu-release-candidate', product: source.product,
    publicationAuthority: 'none', tag: source.tag, version: source.version, sourceCommit: source.commit,
    sourceInputsSha256: sha256(encode(source)), ubuntu: '24.04', architecture };
}
function retainedFiles(output, synchronize = false) {
  return inventory(output, ['package', 'runtime'], synchronize);
}
function artifact(source, architecture, files) {
  const path = `package/frameshift_${source.version}_${architecture}.deb`;
  const archive = files.find(file => file.path === path);
  if (!archive || archive.bytes === 0 || files.filter(file => file.path.endsWith('.deb')).length !== 1) throw new Error('candidate archive missing or ambiguous');
  return { platform: 'ubuntu', architecture, format: 'deb', path, bytes: archive.bytes, sha256: archive.sha256 };
}

export async function buildCandidate({ repository, tag, commit, sourcePath, architecture, output }, execute = run) {
  if (!['amd64', 'arm64'].includes(architecture)) throw new Error('unsupported candidate architecture');
  repository = realpathSync(repository);
  sourcePath = resolve(sourcePath);
  output = resolve(output);
  const source = await verifyInputs(repository, tag, commit, sourcePath);
  const expected = subject(source, architecture);
  directory(dirname(output));
  const physical = join(realpathSync(dirname(output)), basename(output));
  if ((physical === repository || physical.startsWith(repository + sep)) &&
      releaseGit(repository, ['check-ignore', '--no-index', physical]).length === 0) throw new Error('candidate output must be outside tracked source');
  let exists = false;
  try { lstatSync(output); exists = true; } catch (error) { if (error.code !== 'ENOENT') throw error; }
  if (exists) {
    directory(output, true);
    if (!equal(readdirSync(output).sort(), ['candidate.json', 'package', 'runtime'])) throw new Error('incomplete or conflicting candidate output');
    const record = readCandidate(join(output, 'candidate.json'));
    const keys = [...Object.keys(expected), 'buildExecution', 'artifacts', 'files'].sort();
    const execution = record.buildExecution;
    const native = architecture === 'arm64' ? ['aarch64', 'arm64'] : ['x86_64', 'amd64'];
    if (!equal(Object.keys(record).sort(), keys) || !equal(Object.keys(execution).sort(), ['buildErlFlags', 'daemonArchitecture', 'emulated']) ||
        !['aarch64', 'arm64', 'x86_64', 'amd64'].includes(execution.daemonArchitecture) ||
        execution.emulated !== !native.includes(execution.daemonArchitecture) || execution.buildErlFlags !== (execution.emulated ? '+JMsingle true' : '') ||
        !equal(record.artifacts, [artifact(source, architecture, record.files)]) ||
        !equal(Object.fromEntries(Object.keys(expected).map(key => [key, record[key]])), expected) ||
        !equal(inventory(output).filter(file => file.path !== 'candidate.json'), record.files)) {
      throw new Error('conflicting candidate output');
    }
    await verifyInputs(repository, tag, commit, sourcePath);
    return record;
  }
  mkdirSync(output, { mode: 0o700 });
  writeFileSync(join(output, 'build.pending'), 'incomplete ubuntu candidate\n', { flag: 'wx', mode: 0o600 });
  syncDirectory(output);
  const context = mkdtempSync(join(tmpdir(), 'frameshift-tagged-ubuntu-'));
  try {
    execute(join(repository, 'release/linux/prepare-context'), [repository, context, architecture]);
    execute(process.execPath, [join(repository, 'release/linux/record-inputs.mjs'), repository, context, architecture, gleamHashes[architecture], sourcePath, tag, commit]);
    const material = inventory(context, contextNames);
    const daemon = execute('docker', ['info', '--format', '{{.Architecture}}'], true);
    if (!['aarch64', 'arm64', 'x86_64', 'amd64'].includes(daemon)) throw new Error('unsupported build daemon architecture');
    const emulated = architecture === 'arm64' ? !['aarch64', 'arm64'].includes(daemon) : !['x86_64', 'amd64'].includes(daemon);
    const jit = emulated ? '+JMsingle true' : '';
    const runtime = join(output, 'runtime');
    execute('docker', ['build', '--platform', `linux/${architecture}`, '--file', join(context, 'linux/build.Dockerfile'),
      '--build-arg', `FIXTURE_ERL_FLAGS=${jit}`, '--build-arg', `EXPECTED_VERSION=${source.version}`, '--target', 'artifact',
      '--output', `type=local,dest=${runtime}`, context]);
    if (!equal(material, inventory(context, contextNames))) throw new Error('build material changed');
    await verifyInputs(repository, tag, commit, sourcePath);
    const runtimeFiles = inventory(runtime, ['root']);
    const packaging = join(context, 'packaging');
    mkdirSync(packaging, { mode: 0o700 });
    cpSync(join(runtime, 'root'), join(packaging, 'root'), { recursive: true });
    cpSync(join(context, 'linux'), join(packaging, 'linux'), { recursive: true });
    if (!equal(runtimeFiles, inventory(packaging, ['root']))) throw new Error('runtime handoff changed');
    execute(process.execPath, [join(repository, 'release/linux/record-package.mjs'), repository, packaging, architecture, 'candidate', sourcePath, tag, commit]);
    const packageMaterial = inventory(packaging);
    execute('docker', ['build', '--platform', `linux/${architecture}`, '--file', join(packaging, 'linux/deb.Dockerfile'),
      '--build-arg', 'PACKAGE_MODE=--candidate', '--build-arg', `PACKAGE_VERSION=${source.version}`,
      '--build-arg', `FIXTURE_ERL_FLAGS=${jit}`, '--target', 'artifact',
      '--output', `type=local,dest=${join(output, 'package')}`, packaging]);
    if (!equal(packageMaterial, inventory(packaging)) || !equal(runtimeFiles, inventory(runtime, ['root'])) ||
        !equal(material, inventory(context, contextNames))) throw new Error('target material changed');
    await verifyInputs(repository, tag, commit, sourcePath);
    const files = retainedFiles(output, true);
    await verifyInputs(repository, tag, commit, sourcePath);
    const record = { ...expected, buildExecution: { daemonArchitecture: daemon, emulated, buildErlFlags: jit },
      artifacts: [artifact(source, architecture, files)], files };
    const bytes = encode(record);
    if (Buffer.byteLength(bytes) > 16 * 1024 * 1024) throw new Error('candidate record too large');
    const fd = openSync(join(output, 'candidate.json'), constants.O_WRONLY | constants.O_CREAT | constants.O_EXCL | constants.O_NOFOLLOW, 0o600);
    try { writeFileSync(fd, bytes); fsyncSync(fd); } finally { closeSync(fd); }
    syncDirectory(output);
    unlinkSync(join(output, 'build.pending'));
    syncDirectory(output);
    syncDirectory(dirname(output));
    return record;
  } finally { rmSync(context, { recursive: true, force: true }); }
}
