import { constants, closeSync, fstatSync, fsyncSync, lstatSync, mkdirSync, openSync, readSync, readdirSync, realpathSync, unlinkSync, writeFileSync } from 'node:fs';
import { basename, dirname, join, resolve, sep } from 'node:path';
import { verifyInputs } from '../inputs.mjs';
import { releaseGit } from '../source.mjs';
import { buildCandidate } from './candidate.mjs';
import { inventory, sha256 } from './material.mjs';
import { availableSpace, extractArchive, openArchive, verifyArchive, verifyExtractedArchive } from '../ustar.mjs';

const encode = record => JSON.stringify(record) + '\n';
const same = (a, b) => JSON.stringify(a) === JSON.stringify(b);
function directory(path, privateMode = false) {
  const stat = lstatSync(path);
  if (!stat.isDirectory() || stat.uid !== process.getuid() ||
      (privateMode ? (stat.mode & 0o7777) !== 0o700 : (stat.mode & 0o022) !== 0)) throw new Error('unsafe handoff directory');
}
function synchronize(path) {
  const fd = openSync(path, constants.O_RDONLY | constants.O_DIRECTORY | constants.O_NOFOLLOW);
  try { fsyncSync(fd); } finally { closeSync(fd); }
}
function readRecord(path) {
  const named = lstatSync(path, { bigint: true });
  if (!named.isFile()) throw new Error('handoff record must be regular');
  const fd = openSync(path, constants.O_RDONLY | constants.O_NOFOLLOW | constants.O_NONBLOCK);
  try {
    const before = fstatSync(fd, { bigint: true });
    if (!before.isFile() || before.uid !== BigInt(process.getuid()) || (before.mode & 0o7777n) !== 0o600n || before.size > 4096n ||
        before.dev !== named.dev || before.ino !== named.ino) throw new Error('unsafe handoff record');
    const buffer = Buffer.alloc(Number(before.size));
    let offset = 0;
    while (offset < buffer.length) {
      const count = readSync(fd, buffer, offset, buffer.length - offset, offset);
      if (count === 0) throw new Error('handoff record changed');
      offset += count;
    }
    const bytes = new TextDecoder('utf-8', { fatal: true }).decode(buffer);
    const after = fstatSync(fd, { bigint: true });
    const final = lstatSync(path, { bigint: true });
    if (['dev', 'ino', 'size', 'mode', 'mtimeNs', 'ctimeNs'].some(key => before[key] !== after[key] || after[key] !== final[key])) throw new Error('handoff record changed');
    const record = JSON.parse(bytes);
    if (encode(record) !== bytes) throw new Error('noncanonical handoff record');
    return record;
  } finally { closeSync(fd); }
}

export async function stageCandidate({ repository, tag, commit, sourcePath, architecture, archivePath, archiveSha256, output }) {
  if (!['amd64', 'arm64'].includes(architecture)) throw new Error('unsupported handoff architecture');
  const archive = openArchive(archivePath, archiveSha256);
  try {
    repository = realpathSync(repository);
    output = resolve(output);
    directory(dirname(output));
    const physical = join(realpathSync(dirname(output)), basename(output));
    if ((physical === repository || physical.startsWith(repository + sep)) &&
        releaseGit(repository, ['check-ignore', '--no-index', physical]).length === 0) throw new Error('handoff output must be outside tracked source');
    const source = await verifyInputs(repository, tag, commit, sourcePath);
    const candidatePath = join(output, 'ubuntu-candidate');
    const recordPath = join(output, 'handoff.json');
    const candidate = () => buildCandidate({ repository, tag, commit, sourcePath, architecture, output: candidatePath },
      () => { throw new Error('handoff cannot rebuild'); });
    const subject = candidateRecord => ({ schemaVersion: 1, kind: 'ubuntu-candidate-handoff', product: source.product,
      publicationAuthority: 'none', tag: source.tag, version: source.version, sourceCommit: source.commit, architecture,
      sourceInputsSha256: sha256(encode(source)), archiveSha256, candidateSha256: sha256(encode(candidateRecord)) });
    let exists = false;
    try { lstatSync(output); exists = true; } catch (error) { if (error.code !== 'ENOENT') throw error; }
    if (exists) {
      directory(output, true);
      if (!same(readdirSync(output).sort(), ['handoff.json', 'ubuntu-candidate'])) throw new Error('incomplete or conflicting handoff');
      const recorded = readRecord(recordPath);
      verifyExtractedArchive(archive, output);
      if (!same(recorded, subject(await candidate()))) throw new Error('conflicting handoff record');
      verifyArchive(archive);
      await verifyInputs(repository, tag, commit, sourcePath);
      return recorded;
    }
    availableSpace(dirname(output), archive.payloadBytes);
    mkdirSync(output, { mode: 0o700 });
    writeFileSync(join(output, 'handoff.pending'), 'incomplete candidate handoff\n', { flag: 'wx', mode: 0o600 });
    synchronize(output);
    extractArchive(archive, output);
    verifyExtractedArchive(archive, output);
    const candidateRecord = await candidate();
    inventory(candidatePath, undefined, true);
    verifyExtractedArchive(archive, output);
    if (!same(candidateRecord, await candidate())) throw new Error('candidate changed before handoff');
    const record = subject(candidateRecord);
    verifyArchive(archive);
    await verifyInputs(repository, tag, commit, sourcePath);
    const fd = openSync(recordPath, constants.O_WRONLY | constants.O_CREAT | constants.O_EXCL | constants.O_NOFOLLOW, 0o600);
    try { writeFileSync(fd, encode(record)); fsyncSync(fd); } finally { closeSync(fd); }
    synchronize(output);
    unlinkSync(join(output, 'handoff.pending'));
    synchronize(output);
    synchronize(dirname(output));
    return record;
  } finally { closeSync(archive.fd); }
}
