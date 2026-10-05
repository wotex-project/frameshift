import { resolve } from 'node:path';
import { linuxMaterialJoin } from './source-material.mjs';

const repository = resolve(new URL('../..', import.meta.url).pathname);
const [tag, commit, sourcePath, architecture, candidate, candidateSha256, corePath, coreSha256, gleamPath, gleamSha256, output, ...extra] = process.argv.slice(2);
if (!tag || !commit || !sourcePath || !architecture || !candidate || !candidateSha256 || !corePath || !coreSha256 || !gleamPath || !gleamSha256 || !output || extra.length) {
  process.stderr.write('usage: check-linux-material TAG COMMIT SOURCE_RECORD arm64|amd64 CANDIDATE CANDIDATE_SHA256 CORE_RECEIPT CORE_SHA256 GLEAM_RECEIPT GLEAM_SHA256 OUTPUT\n');
  process.exitCode = 64;
} else {
  try { process.stdout.write(JSON.stringify(await linuxMaterialJoin({ repository, tag, commit, sourcePath, architecture, candidate, candidateSha256, corePath, coreSha256, gleamPath, gleamSha256, output })) + '\n'); }
  catch { process.stderr.write('Ubuntu dependency inputs: unavailable, unsafe or conflicting source/receipt/candidate/output\n'); process.exitCode = 1; }
}
