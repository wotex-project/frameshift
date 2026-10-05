import { createHash } from 'node:crypto';
import { constants, closeSync, fchmodSync, fstatSync, fsyncSync, lstatSync, openSync, readdirSync, realpathSync, renameSync, unlinkSync, writeFileSync } from 'node:fs';
import { join, resolve } from 'node:path';
import { isDeepStrictEqual as same } from 'node:util';
import { readReleaseInput } from './files.mjs';
import { gleamFetchedPackages, gleamSourceManifest } from './gleam-material.mjs';
import { verifyInputs } from './inputs.mjs';
import { releaseGit } from './source.mjs';

const hash = bytes => createHash('sha256').update(bytes).digest('hex');
const encode = value => Buffer.from(JSON.stringify(value) + '\n');
const fail = message => { throw new Error(message); };
const identity = stat => ['dev', 'ino', 'mode', 'uid', 'gid'].map(key => String(stat[key]));
const fileIdentity = stat => [...identity(stat), ...['size', 'nlink', 'mtimeNs', 'ctimeNs'].map(key => String(stat[key]))];
const renamedIdentity = stat => [...identity(stat), ...['size', 'nlink', 'mtimeNs'].map(key => String(stat[key]))];
function regular(path) {
  const stat = lstatSync(path, { bigint: true });
  if (!stat.isFile() || stat.uid !== BigInt(process.getuid()) || stat.nlink !== 1n || (stat.mode & 0o7022n) !== 0n || (stat.mode & 0o400n) === 0n) fail('unsafe Gleam preparation file');
  return stat;
}
function directories(repository) {
  return ['', 'packages', 'packages/decision-kernel', 'packages/decision-kernel/build', 'packages/decision-kernel/build/packages'].map(relative => {
    const stat = lstatSync(join(repository, relative), { bigint: true });
    if (!stat.isDirectory() || stat.uid !== BigInt(process.getuid()) || (stat.mode & 0o7022n) !== 0n || (stat.mode & 0o700n) !== 0o700n) fail('unsafe Gleam preparation directory');
    return identity(stat);
  });
}
function synchronize(path, directory = false) {
  const fd = openSync(path, constants.O_RDONLY | constants.O_NOFOLLOW | constants.O_NONBLOCK | (directory ? constants.O_DIRECTORY : 0));
  try {
    const opened = fstatSync(fd), named = lstatSync(path);
    if (!(directory ? opened.isDirectory() && named.isDirectory() : opened.isFile() && named.isFile()) || opened.dev !== named.dev || opened.ino !== named.ino) fail('Gleam preparation sync custody changed');
    fsyncSync(fd);
  } finally { closeSync(fd); }
}

export async function inspectGleamMetadata(repository) {
  repository = realpathSync(repository);
  const custody = directories(repository), root = join(repository, 'packages/decision-kernel/build/packages');
  const manifestPath = join(repository, 'packages/decision-kernel/manifest.toml'), path = join(root, 'packages.toml'), lockPath = join(root, 'gleam.lock');
  const manifestStat = regular(manifestPath), before = regular(path), lockStat = regular(lockPath);
  const manifestBytes = await readReleaseInput(manifestPath, { maximum: 64 * 1024 }), bytes = await readReleaseInput(path, { maximum: 64 * 1024 });
  const manifest = gleamSourceManifest(manifestBytes), packages = manifest.packages.map(({ name, version }) => ({ name, version }));
  if (!same(gleamFetchedPackages(bytes), packages) || (await readReleaseInput(lockPath, { minimum: 0, maximum: 0 })).length !== 0) fail('Gleam preparation metadata differs from frozen manifest');
  const names = [...packages.map(item => item.name), 'gleam.lock', 'packages.toml'].sort();
  if (!same(names, readdirSync(root).sort()) || !same(custody, directories(repository)) || !same(fileIdentity(before), fileIdentity(regular(path))) || !same(fileIdentity(manifestStat), fileIdentity(regular(manifestPath))) || !same(fileIdentity(lockStat), fileIdentity(regular(lockPath)))) fail('Gleam preparation input custody changed');
  const packageCustody = packages.map(item => {
    const stat = lstatSync(join(root, item.name), { bigint: true });
    if (!stat.isDirectory() || stat.uid !== BigInt(process.getuid()) || (stat.mode & 0o7022n) !== 0n) fail('unsafe Gleam preparation package namespace');
    return { name: item.name, identity: identity(stat) };
  });
  const canonical = Buffer.from('[packages]\n' + packages.map(({ name, version }) => `${name} = "${version}"\n`).join('') + '\n[git]\n');
  return { repository, root, path, manifestPath, lockPath, custody, packageCustody, manifestStat, before, lockStat, manifestBytes, bytes, canonical, names };
}

export async function prepareGleamMetadata({ repository, tag, commit, sourcePath }, { verify = verifyInputs } = {}) {
  repository = realpathSync(resolve(repository));
  const deadline = performance.now() + 60_000, budget = () => { if (performance.now() > deadline) fail('Gleam metadata preparation processing deadline'); };
  const source = await verify(repository, tag, commit, sourcePath); budget();
  const input = await inspectGleamMetadata(repository); budget();
  if (!releaseGit(repository, ['check-ignore', '--no-index', input.path]).length) fail('Gleam preparation metadata is not ignored');
  const pending = join(input.root, '.prepare-metadata.pending'), prepared = join(input.root, '.packages.toml.prepared');
  const unchanged = input.bytes.equals(input.canonical);
  const marker = encode({ kind: 'incomplete-gleam-metadata-preparation', sourceInputsSha256: hash(encode(source)), manifestSha256: hash(input.manifestBytes), inputSha256: hash(input.bytes), canonicalSha256: hash(input.canonical) });
  const inputCustody = async (extra = []) => {
    budget();
    if (!same(input.custody, directories(repository)) || !same(readdirSync(input.root).sort(), [...input.names, ...extra].sort()) || input.packageCustody.some(item => !same(item.identity, identity(lstatSync(join(input.root, item.name), { bigint: true })))) || !same(fileIdentity(input.before), fileIdentity(regular(input.path))) || !same(fileIdentity(input.manifestStat), fileIdentity(regular(input.manifestPath))) || !same(fileIdentity(input.lockStat), fileIdentity(regular(input.lockPath)))) fail('Gleam metadata preparation changed custody');
    if (!(await readReleaseInput(input.path, { maximum: 64 * 1024 })).equals(input.bytes) || !(await readReleaseInput(input.manifestPath, { maximum: 64 * 1024 })).equals(input.manifestBytes) || (await readReleaseInput(input.lockPath, { minimum: 0, maximum: 0 })).length !== 0) fail('Gleam metadata preparation changed bytes');
  };
  if (unchanged) {
    await verify(repository, tag, commit, sourcePath); await inputCustody();
  } else {
    writeFileSync(pending, marker, { flag: 'wx', mode: 0o600 }); synchronize(pending); synchronize(input.root, true);
    const fd = openSync(prepared, constants.O_WRONLY | constants.O_CREAT | constants.O_EXCL | constants.O_NOFOLLOW, 0o600);
    try { writeFileSync(fd, input.canonical); fchmodSync(fd, Number(input.before.mode & 0o7777n)); fsyncSync(fd); } finally { closeSync(fd); }
    const preparedStat = regular(prepared), pendingStat = regular(pending);
    await verify(repository, tag, commit, sourcePath); await inputCustody(['.prepare-metadata.pending', '.packages.toml.prepared']);
    if (!same(fileIdentity(preparedStat), fileIdentity(regular(prepared))) || !same(fileIdentity(pendingStat), fileIdentity(regular(pending))) || !(await readReleaseInput(prepared, { maximum: 64 * 1024 })).equals(input.canonical) || !(await readReleaseInput(pending, { maximum: 1024, privateKey: true })).equals(marker)) fail('Gleam preparation pending custody changed');
    budget(); renameSync(prepared, input.path); synchronize(input.root, true);
    if (!same(input.custody, directories(repository)) || !same(readdirSync(input.root).sort(), [...input.names, '.prepare-metadata.pending'].sort()) || !same(renamedIdentity(preparedStat), renamedIdentity(regular(input.path))) || !same(fileIdentity(pendingStat), fileIdentity(regular(pending))) || !(await readReleaseInput(input.path, { maximum: 64 * 1024 })).equals(input.canonical) || !(await readReleaseInput(pending, { maximum: 1024, privateKey: true })).equals(marker)) fail('Gleam preparation final custody changed');
    budget(); unlinkSync(pending); synchronize(input.root, true);
  }
  return { publicationAuthority: 'none', metadataSha256: hash(input.canonical), mode: Number(input.before.mode & 0o7777n), disposition: unchanged ? 'canonical-bytes-verified' : 'generated-metadata-prepared' };
}
