import { resolve } from 'node:path';
import { macMaterialJoin } from './material.mjs';

const repository = resolve(new URL('../..', import.meta.url).pathname);
const [tag, commit, sourcePath, architecture, candidate, candidateSha256, corePath, coreSha256, gleamPath, gleamSha256, output, sparklePath, sparkleSha256, ...extra] = process.argv.slice(2);
if (!tag || !commit || !sourcePath || !architecture || !candidate || !candidateSha256 || !corePath || !coreSha256 || !gleamPath || !gleamSha256 || !output || Boolean(sparklePath) !== Boolean(sparkleSha256) || extra.length) {
  process.stderr.write('usage: check-macos-material TAG COMMIT SOURCE_RECORD arm64|x86_64 CANDIDATE CANDIDATE_SHA256 CORE_RECEIPT CORE_SHA256 GLEAM_RECEIPT GLEAM_SHA256 OUTPUT [SPARKLE_RECEIPT SPARKLE_SHA256]\n');
  process.exitCode = 64;
} else {
  try { process.stdout.write(JSON.stringify(await macMaterialJoin({ repository, tag, commit, sourcePath, architecture, candidate, candidateSha256, corePath, coreSha256, gleamPath, gleamSha256, sparklePath, sparkleSha256, output })) + '\n'); }
  catch { process.stderr.write('Mac dependency inputs: unavailable, unsafe or conflicting source/receipt/candidate/output\n'); process.exitCode = 1; }
}
