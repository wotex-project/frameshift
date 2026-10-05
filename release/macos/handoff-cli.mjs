import { dirname, resolve } from 'node:path';
import { fileURLToPath } from 'node:url';
import { stageMacCandidate } from './handoff.mjs';
const args = process.argv.slice(2);
if (args.length !== 7 || !['arm64', 'x86_64'].includes(args[3])) {
  console.error('usage: scripts/stage-macos-candidate TAG COMMIT SOURCE_RECORD arm64|x86_64 ARCHIVE ARCHIVE_SHA256 OUTPUT'); process.exitCode = 64;
} else {
  try { console.log(JSON.stringify(await stageMacCandidate({ repository: resolve(dirname(fileURLToPath(import.meta.url)), '../..'), tag: args[0], commit: args[1], sourcePath: args[2], architecture: args[3], archivePath: args[4], archiveSha256: args[5], output: args[6] }))); }
  catch { console.error('Mac candidate archive handoff refused; existing output retained'); process.exitCode = 1; }
}
