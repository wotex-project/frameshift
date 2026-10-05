import { resolve } from 'node:path';
import { stageMacMaterial } from './material-handoff.mjs';

const repository = resolve(new URL('../..', import.meta.url).pathname);
const [tag, commit, sourcePath, architecture, candidate, candidateSha256, archivePath, archiveSha256, coreSha256, gleamSha256, joinSha256, output, ...extra] = process.argv.slice(2);
if (!tag || !commit || !sourcePath || !architecture || !candidate || !candidateSha256 || !archivePath || !archiveSha256 || !coreSha256 || !gleamSha256 || !joinSha256 || !output || extra.length) {
  process.stderr.write('usage: stage-macos-material TAG COMMIT SOURCE_RECORD arm64|x86_64 CANDIDATE CANDIDATE_SHA256 ARCHIVE ARCHIVE_SHA256 CORE_SHA256 GLEAM_SHA256 JOIN_SHA256 OUTPUT\n');
  process.exitCode = 64;
} else {
  try { process.stdout.write(JSON.stringify(await stageMacMaterial({ repository, tag, commit, sourcePath, architecture, candidate, candidateSha256, archivePath, archiveSha256, coreSha256, gleamSha256, joinSha256, output })) + '\n'); }
  catch { process.stderr.write('Mac dependency input archive handoff refused; existing output retained\n'); process.exitCode = 1; }
}
