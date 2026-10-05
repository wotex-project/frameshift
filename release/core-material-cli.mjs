import { resolve } from 'node:path';
import { checkCoreMaterial } from './core-material.mjs';

const repository = resolve(new URL('..', import.meta.url).pathname);
const [tag, commit, sourcePath, cache, output, ...extra] = process.argv.slice(2);
if (!tag || !commit || !sourcePath || !cache || !output || extra.length) {
  process.stderr.write('usage: check-core-material TAG COMMIT SOURCE_RECORD HEX_CACHE OUTPUT\n');
  process.exitCode = 64;
} else {
  try { process.stdout.write(JSON.stringify(await checkCoreMaterial({ repository, tag, commit, sourcePath, cache, output })) + '\n'); }
  catch { process.stderr.write('core dependency source: unavailable, unsafe or conflicting input/output\n'); process.exitCode = 1; }
}
