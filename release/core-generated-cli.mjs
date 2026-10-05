import { resolve } from 'node:path';
import { checkCoreGenerated } from './core-generated.mjs';

const repository = resolve(new URL('..', import.meta.url).pathname);
const [tag, commit, sourcePath, cache, corePath, coreSha256, joinPath, joinSha256, output, ...extra] = process.argv.slice(2);
if (!tag || !commit || !sourcePath || !cache || !corePath || !coreSha256 || !joinPath || !joinSha256 || !output || extra.length) {
  process.stderr.write('usage: check-core-generated TAG COMMIT SOURCE_RECORD HEX_CACHE CORE_RECEIPT CORE_SHA256 DEPENDENCY_JOIN JOIN_SHA256 OUTPUT\n'); process.exitCode = 64;
} else {
  try { process.stdout.write(JSON.stringify(await checkCoreGenerated({ repository, tag, commit, sourcePath, cache, corePath, coreSha256, joinPath, joinSha256, output })) + '\n'); }
  catch { process.stderr.write('generated core source: unavailable, unsafe or conflicting input/output\n'); process.exitCode = 1; }
}
