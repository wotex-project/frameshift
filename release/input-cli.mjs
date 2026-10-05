import { dirname, resolve } from 'node:path';
import { fileURLToPath } from 'node:url';
import { recordInputs, verifyInputs } from './inputs.mjs';

const repository = resolve(dirname(fileURLToPath(import.meta.url)), '..');
const [operation, tag, commit, path, ...extra] = process.argv.slice(2);
if (!['record', 'verify'].includes(operation) || !tag || !commit || !path || extra.length) {
  process.stderr.write('usage: record-release-inputs TAG COMMIT OUTPUT | verify-release-inputs TAG COMMIT RECORD\n');
  process.exitCode = 64;
} else {
  try {
    if (operation === 'record') await recordInputs(repository, tag, commit, path);
    else await verifyInputs(repository, tag, commit, path);
    process.stdout.write(`release source inputs: ${operation} ok\n`);
  } catch {
    process.stderr.write('release source inputs: unavailable, unsafe or conflicting source/record\n');
    process.exitCode = 1;
  }
}
