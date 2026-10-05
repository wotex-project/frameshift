import { dirname, resolve } from 'node:path';
import { fileURLToPath } from 'node:url';
import { buildCandidate } from './candidate.mjs';

const [tag, commit, sourcePath, architecture, output, ...extra] = process.argv.slice(2);
if (!tag || !commit || !sourcePath || !architecture || !output || extra.length) {
  process.stderr.write('usage: package-linux-candidate TAG COMMIT SOURCE_RECORD arm64|amd64 OUTPUT\n');
  process.exitCode = 64;
} else {
  try {
    await buildCandidate({ repository: resolve(dirname(fileURLToPath(import.meta.url)), '../..'), tag, commit, sourcePath, architecture, output });
    process.stdout.write('Ubuntu build candidate: recorded, publication authority none\n');
  } catch {
    process.stderr.write('Ubuntu build candidate: source, material, target or output unavailable/conflicting; retain interrupted output for inspection\n');
    process.exitCode = 1;
  }
}
