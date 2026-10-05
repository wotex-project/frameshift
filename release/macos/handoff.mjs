import { createHash } from 'node:crypto';
import { constants, closeSync, fstatSync, fsyncSync, lstatSync, mkdirSync, openSync, readdirSync, realpathSync, unlinkSync, writeFileSync } from 'node:fs';
import { basename, dirname, join, resolve, sep } from 'node:path';
import { isDeepStrictEqual } from 'node:util';
import { readReleaseInput } from '../files.mjs';
import { verifyInputs } from '../inputs.mjs';
import { releaseGit } from '../source.mjs';
import { availableSpace, extractArchive, openArchive, verifyArchive, verifyExtractedArchive } from '../ustar.mjs';
import { inspectMacCandidate } from './cohort.mjs';
import { macImageTool } from './dmg.mjs';

const encode = value => Buffer.from(JSON.stringify(value) + '\n');
const hash = value => createHash('sha256').update(value).digest('hex');
const fail = message => { throw new Error(message); };
function directory(path) {
  const stat = lstatSync(path);
  if (!stat.isDirectory() || stat.uid !== process.getuid() || (stat.mode & 0o7777) !== 0o700) fail('unsafe Mac handoff directory');
  return stat;
}
function synchronize(path, isDirectory = false) {
  const fd = openSync(path, constants.O_RDONLY | constants.O_NOFOLLOW | constants.O_NONBLOCK | (isDirectory ? constants.O_DIRECTORY : 0));
  try {
    const opened = fstatSync(fd), named = lstatSync(path);
    if (!(isDirectory ? opened.isDirectory() && named.isDirectory() : opened.isFile() && named.isFile()) || opened.dev !== named.dev || opened.ino !== named.ino) fail('Mac handoff sync custody changed');
    fsyncSync(fd);
  } finally { closeSync(fd); }
}

export async function stageMacCandidate({ repository, tag, commit, sourcePath, architecture, archivePath, archiveSha256, output }, { tool = macImageTool } = {}) {
  if (!['arm64', 'x86_64'].includes(architecture)) fail('unsupported Mac handoff CPU');
  repository = realpathSync(repository);
  const source = await verifyInputs(repository, tag, commit, sourcePath), archive = openArchive(archivePath, archiveSha256, 'macos-candidate');
  try {
    const destination = join(realpathSync(dirname(resolve(output))), basename(output));
    if (destination === repository || (destination.startsWith(repository + sep) && !releaseGit(repository, ['check-ignore', '--no-index', destination]).length)) fail('Mac handoff output overlaps source');
    const candidate = join(destination, 'macos-candidate'), recordPath = join(destination, 'handoff.json');
    const admit = async () => {
      verifyExtractedArchive(archive, destination);
      // The independently pinned archive binds these candidate bytes; the
      // resulting digest is retained for subsequent source-cohort admission.
      const bytes = await readReleaseInput(join(candidate, 'candidate.json'), { maximum: 16 * 1024 * 1024, privateKey: true });
      const result = await inspectMacCandidate({ repository, source, candidate, expectedDigest: hash(bytes), architecture }, tool);
      verifyExtractedArchive(archive, destination); verifyArchive(archive);
      await verifyInputs(repository, tag, commit, sourcePath);
      return { schemaVersion: 1, kind: 'macos-candidate-handoff', product: source.product, publicationAuthority: 'none', tag, version: source.version, sourceCommit: commit,
        architecture, sourceInputsSha256: hash(encode(source)), archiveSha256, candidateRecordSha256: result.recordSha256 };
    };
    const recheck = async expected => {
      if (!isDeepStrictEqual(expected, await admit())) fail('Mac handoff candidate changed');
    };
    let exists = false;
    try { lstatSync(destination); exists = true; } catch (error) { if (error.code !== 'ENOENT') throw error; }
    if (exists) {
      const before = directory(destination);
      if (!isDeepStrictEqual(readdirSync(destination).sort(), ['handoff.json', 'macos-candidate'])) fail('incomplete or unknown Mac handoff');
      const bytes = await readReleaseInput(recordPath, { maximum: 4096, privateKey: true }), record = await admit();
      if (!bytes.equals(encode(record))) fail('Mac handoff retained record differs');
      await recheck(record);
      const final = directory(destination);
      if (before.dev !== final.dev || before.ino !== final.ino || !isDeepStrictEqual(readdirSync(destination).sort(), ['handoff.json', 'macos-candidate']) || !(await readReleaseInput(recordPath, { maximum: 4096, privateKey: true })).equals(bytes)) fail('Mac handoff replay custody changed');
      return { ...record, recordSha256: hash(bytes), disposition: 'retained-bytes-verified' };
    }
    availableSpace(dirname(destination), archive.payloadBytes); mkdirSync(destination, { mode: 0o700 }); const created = directory(destination);
    writeFileSync(join(destination, 'handoff.pending'), 'incomplete Mac candidate handoff\n', { flag: 'wx', mode: 0o600 }); synchronize(join(destination, 'handoff.pending')); synchronize(destination, true);
    extractArchive(archive, destination);
    const record = await admit(); await recheck(record); const bytes = encode(record);
    if (bytes.length > 4096) fail('Mac handoff record limit');
    writeFileSync(recordPath, bytes, { flag: 'wx', mode: 0o600 }); synchronize(recordPath);
    await recheck(record);
    const final = directory(destination);
    if (created.dev !== final.dev || created.ino !== final.ino || !isDeepStrictEqual(readdirSync(destination).sort(), ['handoff.json', 'handoff.pending', 'macos-candidate']) || !(await readReleaseInput(recordPath, { maximum: 4096, privateKey: true })).equals(bytes)) fail('Mac handoff final custody changed');
    synchronize(destination, true); unlinkSync(join(destination, 'handoff.pending')); synchronize(destination, true); synchronize(dirname(destination), true);
    return { ...record, recordSha256: hash(bytes), disposition: 'candidate-archive-staged' };
  } finally { closeSync(archive.fd); }
}
