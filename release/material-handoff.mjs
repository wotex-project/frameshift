import { createHash } from 'node:crypto';
import { constants, closeSync, fstatSync, fsyncSync, lstatSync, mkdirSync, openSync, realpathSync, unlinkSync, writeFileSync } from 'node:fs';
import { basename, dirname, join, resolve, sep } from 'node:path';
import { isDeepStrictEqual } from 'node:util';
import { readReleaseInput } from './files.mjs';
import { verifyInputs } from './inputs.mjs';
import { releaseGit } from './source.mjs';
import { availableSpace, extractArchive, openArchive, verifyArchive, verifyExtractedArchive } from './ustar.mjs';
import { materialDirectoryNames } from './material-receipts.mjs';

const encode = value => Buffer.from(JSON.stringify(value) + '\n');
const hash = value => createHash('sha256').update(value).digest('hex');
const same = isDeepStrictEqual;
const fail = message => { throw new Error(message); };
const identity = stat => ({ dev: stat.dev, ino: stat.ino, mode: stat.mode, uid: stat.uid, gid: stat.gid });
function directory(path) {
  const stat = lstatSync(path, { bigint: true });
  if (!stat.isDirectory() || stat.uid !== BigInt(process.getuid()) || (stat.mode & 0o7777n) !== 0o700n) fail('unsafe material handoff directory');
  return identity(stat);
}
function synchronize(path, isDirectory = false) {
  const fd = openSync(path, constants.O_RDONLY | constants.O_NOFOLLOW | constants.O_NONBLOCK | (isDirectory ? constants.O_DIRECTORY : 0));
  try {
    const opened = fstatSync(fd), named = lstatSync(path);
    if (!(isDirectory ? opened.isDirectory() && named.isDirectory() : opened.isFile() && named.isFile()) || opened.dev !== named.dev || opened.ino !== named.ino) fail('material handoff sync custody changed');
    fsyncSync(fd);
  } finally { closeSync(fd); }
}
async function privateBytes(path, maximum, expectedHash) {
  if (lstatSync(path).nlink !== 1) fail('material handoff file alias');
  const bytes = await readReleaseInput(path, { maximum, privateKey: true });
  if (expectedHash && hash(bytes) !== expectedHash) fail('material handoff independent digest mismatch');
  return bytes;
}

export async function stageDependencyMaterial({ repository, tag, commit, sourcePath, architecture, candidate, candidateSha256, archivePath, archiveSha256, coreSha256, gleamSha256, joinSha256, sparkleSha256, output }, { platform, tool } = {}) {
  if (!['macos', 'ubuntu'].includes(platform)) fail('unsupported dependency input archive profile');
  if (sparkleSha256 !== undefined && (platform !== 'macos' || typeof sparkleSha256 !== 'string' || !/^[0-9a-f]{64}$/.test(sparkleSha256))) fail('unsupported updater receipt custody input');
  const root = platform + '-material', architectures = platform === 'macos' ? ['arm64', 'x86_64'] : ['arm64', 'amd64'];
  const adapter = platform === 'macos' ? await import('./macos/material.mjs') : await import('./linux/source-material.mjs');
  const joinMaterial = platform === 'macos' ? adapter.macMaterialJoin : adapter.linuxMaterialJoin;
  if (!architectures.includes(architecture) || [candidateSha256, coreSha256, gleamSha256, joinSha256].some(value => typeof value !== 'string' || !/^[0-9a-f]{64}$/.test(value))) fail('invalid material handoff identity');
  repository = realpathSync(repository); candidate = resolve(candidate); output = resolve(output);
  const source = await verifyInputs(repository, tag, commit, sourcePath), archive = openArchive(archivePath, archiveSha256, root);
  try {
    const expected = new Map([[root, 0], [root + '/core-material.json', 16 * 1024 * 1024], [root + '/gleam-material.json', 16 * 1024 * 1024], [root + '/dependency-inputs.json', 64 * 1024]]);
    if (sparkleSha256) expected.set(root + '/sparkle-material.json', 64 * 1024);
    if (archive.entries.length !== expected.size || archive.entries.some(entry => !expected.has(entry.path) || entry.directory !== (entry.path === root) || entry.mode !== (entry.directory ? 0o700 : 0o600) || (!entry.directory && (entry.bytes < 1 || entry.bytes > expected.get(entry.path))))) fail('unsupported material handoff members');
    const parent = dirname(output), parentStat = lstatSync(parent, { bigint: true });
    if (!parentStat.isDirectory() || parentStat.uid !== BigInt(process.getuid()) || (parentStat.mode & 0o022n) !== 0n) fail('unsafe material handoff parent');
    const destination = join(realpathSync(parent), basename(output)), input = realpathSync(candidate), archiveInput = realpathSync(archivePath);
    if (destination === repository || destination === input || destination.startsWith(input + sep) || input.startsWith(destination + sep) || archiveInput === destination || archiveInput.startsWith(destination + sep) || (destination.startsWith(repository + sep) && !releaseGit(repository, ['check-ignore', '--no-index', destination]).length)) fail('material handoff output overlaps inputs');
    const candidateCustody = { identity: directory(candidate), names: materialDirectoryNames(candidate) };
    const sourceParent = dirname(resolve(sourcePath)), sourceCustody = { identity: directory(sourceParent), names: materialDirectoryNames(sourceParent) };
    const sourceInput = realpathSync(sourceParent);
    if (destination === sourceInput || destination.startsWith(sourceInput + sep) || sourceInput.startsWith(destination + sep)) fail('material handoff output overlaps source custody');
    const material = join(destination, root), verification = join(destination, 'verification'), path = join(destination, 'handoff.json'), pending = join(destination, 'handoff.pending');
    const marker = Buffer.from(`incomplete ${platform === 'macos' ? 'Mac' : 'Ubuntu'} dependency input handoff\n`);
    const joinedPath = join(material, 'dependency-inputs.json'), verifiedPath = join(verification, 'dependency-inputs.json');
    const verifyReceived = async () => {
      verifyExtractedArchive(archive, destination); verifyArchive(archive);
      await privateBytes(join(material, 'core-material.json'), 16 * 1024 * 1024, coreSha256);
      await privateBytes(join(material, 'gleam-material.json'), 16 * 1024 * 1024, gleamSha256);
      if (sparkleSha256) await privateBytes(join(material, 'sparkle-material.json'), 64 * 1024, sparkleSha256);
      const received = await privateBytes(joinedPath, 64 * 1024, joinSha256);
      const result = await joinMaterial({ repository, tag, commit, sourcePath, architecture, candidate, candidateSha256,
        corePath: join(material, 'core-material.json'), coreSha256, gleamPath: join(material, 'gleam-material.json'), gleamSha256,
        ...(sparkleSha256 ? { sparklePath: join(material, 'sparkle-material.json'), sparkleSha256 } : {}), output: verification }, { tool });
      if (result.recordSha256 !== joinSha256 || !(await privateBytes(verifiedPath, 64 * 1024, joinSha256)).equals(received)) fail('received dependency join differs from local verification');
      return result;
    };
    const finalInputs = async () => {
      // No child runs after these checks. The join already performed all
      // version/seal consumers; repeat bytes after the final source child.
      verifyExtractedArchive(archive, destination); verifyArchive(archive);
      if (!(await privateBytes(verifiedPath, 64 * 1024, joinSha256)).equals(await privateBytes(joinedPath, 64 * 1024, joinSha256))) fail('material verification custody changed');
      const bytes = await privateBytes(join(candidate, 'candidate.json'), 16 * 1024 * 1024, candidateSha256);
      if (platform === 'macos') {
        const { auditMacBundle } = await import('./macos/closure.mjs');
        if (!same(JSON.parse(bytes).bundle, await auditMacBundle(join(candidate, 'Frameshift.app'), architecture))) fail('material handoff final Mac bytes changed');
      } else await adapter.inspectLinuxMaterialBytes({ repository, source, candidate, candidateSha256, architecture });
      if (!same(candidateCustody, { identity: directory(candidate), names: materialDirectoryNames(candidate) }) || !same(identity(parentStat), identity(lstatSync(parent, { bigint: true })))) fail('material handoff final inputs changed');
      if (!same(materialDirectoryNames(verification), ['dependency-inputs.json'])) fail('material verification namespace changed');
      directory(verification);
      if (!same(sourceCustody, { identity: directory(sourceParent), names: materialDirectoryNames(sourceParent) })) fail('material handoff source namespace changed');
    };
    let exists = false;
    try { lstatSync(destination); exists = true; } catch (error) { if (error.code !== 'ENOENT') throw error; }
    let created;
    if (exists) {
      created = directory(destination);
      if (!same(materialDirectoryNames(destination), ['handoff.json', root, 'verification'].sort())) fail('incomplete or unknown material handoff');
    } else {
      availableSpace(parent, archive.payloadBytes); mkdirSync(destination, { mode: 0o700 }); created = directory(destination);
      writeFileSync(pending, marker, { flag: 'wx', mode: 0o600 }); synchronize(pending); synchronize(destination, true);
      extractArchive(archive, destination);
    }
    const joined = await verifyReceived();
    const bytes = encode({ schemaVersion: 1, kind: platform + '-dependency-input-handoff', product: source.product, tag, version: source.version, sourceCommit: commit,
      sourceInputsSha256: hash(encode(source)), architecture, candidateRecordSha256: candidateSha256, archiveSha256, coreReceiptSha256: coreSha256, gleamReceiptSha256: gleamSha256,
      ...(sparkleSha256 ? { sparkleReceiptSha256: sparkleSha256, updaterInputs: joined.updaterInputs } : {}),
      dependencyInputsSha256: joinSha256, provedSourceFiles: joined.provedSourceFiles, generatedInputs: joined.generatedInputs.length, ...(platform === 'ubuntu' ? { retainedGitMetadata: joined.retainedGitMetadata.length } : {}), publicationAuthority: 'none' });
    if (bytes.length > 4096) fail('material handoff record limit');
    if (exists && !(await privateBytes(path, 4096)).equals(bytes)) fail('material retained handoff differs');
    await verifyReceived(); await verifyInputs(repository, tag, commit, sourcePath); await finalInputs();
    if (!same(created, directory(destination)) || !same(materialDirectoryNames(destination), exists ? ['handoff.json', root, 'verification'].sort() : ['handoff.pending', root, 'verification'].sort())) fail('material handoff output custody changed');
    if (exists) {
      if (!(await privateBytes(path, 4096)).equals(bytes)) fail('material handoff replay changed');
    } else {
      if (!(await privateBytes(pending, 1024)).equals(marker)) fail('material handoff pending custody changed');
      writeFileSync(path, bytes, { flag: 'wx', mode: 0o600 }); synchronize(path);
      await verifyInputs(repository, tag, commit, sourcePath); await finalInputs();
      if (!same(created, directory(destination)) || !same(materialDirectoryNames(destination), ['handoff.json', 'handoff.pending', root, 'verification'].sort()) || !(await privateBytes(path, 4096)).equals(bytes) || !(await privateBytes(pending, 1024)).equals(marker)) fail('material handoff completion custody changed');
      unlinkSync(pending); synchronize(destination, true); synchronize(parent, true);
    }
    return { publicationAuthority: 'none', architecture, provedSourceFiles: joined.provedSourceFiles, generatedInputs: joined.generatedInputs.length, ...(sparkleSha256 ? { updaterInputs: joined.updaterInputs } : {}), ...(platform === 'ubuntu' ? { retainedGitMetadata: joined.retainedGitMetadata.length } : {}), recordSha256: hash(bytes), disposition: exists ? 'retained-bytes-verified' : 'dependency-input-archive-staged' };
  } finally { closeSync(archive.fd); }
}
