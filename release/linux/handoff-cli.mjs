import { dirname, resolve } from 'node:path';
import { fileURLToPath } from 'node:url';
import { stageCandidate } from './handoff.mjs';

const [tag, commit, sourcePath, architecture, archivePath, archiveSha256, output, ...extra] = process.argv.slice(2);
if (!output || extra.length) {
  process.stderr.write('usage: stage-linux-candidate TAG COMMIT SOURCE_RECORD arm64|amd64 ARCHIVE SHA256 OUTPUT\n');
  process.exitCode = 64;
} else {
  try {
    await stageCandidate({ repository: resolve(dirname(fileURLToPath(import.meta.url)), '../..'),
      tag, commit, sourcePath, architecture, archivePath, archiveSha256, output });
    process.stdout.write('Ubuntu candidate handoff: exact source and retained bytes verified; publication authority none\n');
  } catch {
    process.stderr.write('Ubuntu candidate handoff: archive, source, capacity or retained custody refused\n');
    process.exitCode = 1;
  }
}
