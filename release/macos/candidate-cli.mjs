import { dirname, resolve } from 'node:path';
import { fileURLToPath } from 'node:url';
import { macBuildCandidate } from './candidate.mjs';
const args = process.argv.slice(2);
if (args.length !== 5 || !['arm64', 'x86_64'].includes(args[3])) {
  console.error('usage: scripts/package-macos-candidate TAG COMMIT SOURCE_RECORD arm64|x86_64 OUTPUT'); process.exitCode = 64;
} else {
  try { console.log(JSON.stringify(await macBuildCandidate({ repository: resolve(dirname(fileURLToPath(import.meta.url)), '../..'), tag: args[0], commit: args[1], sourcePath: args[2], architecture: args[3], output: args[4] }))); }
  catch { console.error('tagged Mac build candidate refused; existing output retained'); process.exitCode = 1; }
}
