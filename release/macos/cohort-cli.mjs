import { dirname, resolve } from 'node:path';
import { fileURLToPath } from 'node:url';
import { macSourceCohort } from './cohort.mjs';
const args = process.argv.slice(2);
if (args.length !== 8) {
  console.error('usage: scripts/package-macos-cohort TAG COMMIT SOURCE_RECORD ARM_CANDIDATE ARM_SHA256 INTEL_CANDIDATE INTEL_SHA256 OUTPUT'); process.exitCode = 64;
} else {
  try {
    const result = await macSourceCohort({ repository: resolve(dirname(fileURLToPath(import.meta.url)), '../..'), tag: args[0], commit: args[1], sourcePath: args[2], armCandidate: args[3], armSha256: args[4], intelCandidate: args[5], intelSha256: args[6], output: args[7] });
    console.log(JSON.stringify(result));
  } catch { console.error('source-bound Mac cohort refused; existing output retained'); process.exitCode = 1; }
}
