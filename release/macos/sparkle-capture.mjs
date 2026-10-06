import { lstatSync, realpathSync } from 'node:fs';
import { dirname, join, relative } from 'node:path';
import { isDeepStrictEqual as same } from 'node:util';
import { readReleaseInput } from '../files.mjs';
import { sparkleArchive, sparkleInputArchive, sparkleInputFramework } from '../macos-framework.mjs';
import { readSwiftManifest } from './sparkle-source.mjs';
import { verifySparkleFramework } from './sparkle-material.mjs';

const fail = () => { throw new Error('recorded updater compiler inputs unavailable, unsafe or changed'); };
const identity = stat => ['dev', 'ino', 'mode', 'uid', 'gid', 'nlink', 'size', 'mtimeNs', 'ctimeNs'].map(key => String(stat[key]));
const keys = (value, names) => value && typeof value === 'object' && !Array.isArray(value) && same(Object.keys(value).sort(), names.split(' ').sort());
function parents(repository, path) {
  const names = relative(repository, dirname(path)).split('/'), custody = []; let directory = repository;
  if (names.some(name => !name || name === '.' || name === '..')) fail();
  for (const name of names) {
    directory = join(directory, name); const stat = lstatSync(directory, { bigint: true });
    if (!stat.isDirectory() || stat.uid !== BigInt(process.getuid()) || (stat.mode & 0o7022n)) fail();
    custody.push(['dev', 'ino', 'mode', 'uid', 'gid'].map(key => String(stat[key])));
  }
  return custody;
}
function workspace(bytes, packageRoot) {
  let state; try { state = JSON.parse(new TextDecoder('utf-8', { fatal: true }).decode(bytes)); } catch { fail(); }
  if (!keys(state, 'version object') || ![6, 7].includes(state.version) ||
      !keys(state.object, state.version === 7 ? 'artifacts dependencies prebuilts' : 'artifacts dependencies') ||
      !same(state.object.dependencies, []) || (state.version === 7 && !same(state.object.prebuilts, [])) ||
      !Array.isArray(state.object.artifacts) || state.object.artifacts.length !== 1) fail();
  const artifact = state.object.artifacts[0];
  if (!keys(artifact, 'kind packageRef path source targetName') || artifact.targetName !== 'Sparkle' ||
      !same(artifact.kind, state.version === 7 ? { xcframework: {} } : 'xcframework') ||
      !same(artifact.packageRef, { identity: 'macos', kind: 'root', location: packageRoot, name: 'macos' }) ||
      !same(artifact.source, { checksum: sparkleArchive.sha256, type: 'remote', url: sparkleArchive.url }) ||
      artifact.path !== join(packageRoot, '.build/artifacts/macos/Sparkle/Sparkle.xcframework')) fail();
}

/** Admit the actual root-package compiler artifact without fetching or repair. */
export async function captureSparkleInputs(repository, { manifest = readSwiftManifest } = {}) {
  repository = realpathSync(repository);
  const packageRoot = join(repository, 'apps/macos'), packagePath = join(packageRoot, 'Package.swift');
  try { lstatSync(packagePath); } catch (error) { if (error.code === 'ENOENT') return []; throw error; }
  const deadline = performance.now() + 180_000, budget = () => { if (performance.now() >= deadline) fail(); };
  parents(repository, packagePath);
  const packageBytes = await readReleaseInput(packagePath, { maximum: 64 * 1024, protectedTrust: true }), packageStat = identity(lstatSync(packagePath, { bigint: true }));
  if (lstatSync(packagePath).nlink !== 1) fail();
  const parsed = manifest(packageRoot, 60_000); budget();
  if (!Array.isArray(parsed.targets)) fail();
  const binary = parsed.targets.filter(target => target.type === 'binary');
  if (binary.length === 0) {
    if (!(await readReleaseInput(packagePath, { maximum: 64 * 1024, protectedTrust: true })).equals(packageBytes) || !same(packageStat, identity(lstatSync(packagePath, { bigint: true })))) fail();
    return [];
  }
  if (binary.length !== 1 || binary[0].name !== 'Sparkle' || binary[0].url !== sparkleArchive.url || binary[0].checksum !== sparkleArchive.sha256) fail();
  const archive = join(repository, sparkleInputArchive), framework = join(repository, sparkleInputFramework), statePath = join(packageRoot, '.build/workspace-state.json');
  const inputPaths = [packagePath, archive, framework, statePath], inputParents = inputPaths.map(path => parents(repository, path));
  const stateBytes = await readReleaseInput(statePath, { maximum: 128 * 1024, protectedTrust: true }), stateStat = identity(lstatSync(statePath, { bigint: true }));
  if (lstatSync(statePath).nlink !== 1 || (lstatSync(archive).mode & 0o7777) !== 0o600) fail();
  workspace(stateBytes, packageRoot);
  const input = await verifySparkleFramework(archive, framework); budget();
  if (!(await readReleaseInput(packagePath, { maximum: 64 * 1024, protectedTrust: true })).equals(packageBytes) ||
      !(await readReleaseInput(statePath, { maximum: 128 * 1024, protectedTrust: true })).equals(stateBytes) ||
      !same(packageStat, identity(lstatSync(packagePath, { bigint: true }))) || !same(stateStat, identity(lstatSync(statePath, { bigint: true })))) fail();
  if (!same(inputParents, inputPaths.map(path => parents(repository, path)))) fail();
  return [...input.framework.files.map(file => ({ ...file, path: sparkleInputFramework + file.path })),
    { path: sparkleInputArchive, mode: 0o600, bytes: sparkleArchive.bytes, sha256: sparkleArchive.sha256 }];
}
