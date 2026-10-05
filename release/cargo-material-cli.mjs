import { resolve } from 'node:path';
import { checkCargoMaterial } from './cargo-material.mjs';

const repository = resolve(new URL('..', import.meta.url).pathname), [tag, commit, sourcePath, cache, sources, output, ...extra] = process.argv.slice(2);
if (!tag || !commit || !sourcePath || !cache || !sources || !output || extra.length) {
  process.stderr.write('usage: check-cargo-material TAG COMMIT SOURCE_RECORD CRATE_CACHE REGISTRY_SOURCES OUTPUT\n'); process.exitCode = 64;
} else {
  try { process.stdout.write(JSON.stringify(await checkCargoMaterial({ repository, tag, commit, sourcePath, cache, sources, output })) + '\n'); }
  catch { process.stderr.write('codec Cargo source: unavailable, unsafe or conflicting input/output\n'); process.exitCode = 1; }
}
