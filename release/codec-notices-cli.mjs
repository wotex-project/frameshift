import { resolve } from 'node:path';
import { collectCodecNotices } from './codec-notices.mjs';

const repository = resolve(new URL('..', import.meta.url).pathname), [tag, commit, sourcePath, cache, sources, cargoPath, cargoSha256, output, ...extra] = process.argv.slice(2);
if (!tag || !commit || !sourcePath || !cache || !sources || !cargoPath || !cargoSha256 || !output || extra.length) {
  process.stderr.write('usage: collect-codec-notices TAG COMMIT SOURCE_RECORD CRATE_CACHE REGISTRY_SOURCES CARGO_RECEIPT CARGO_SHA256 OUTPUT\n'); process.exitCode = 64;
} else {
  try { process.stdout.write(JSON.stringify(await collectCodecNotices({ repository, tag, commit, sourcePath, cache, sources, cargoPath, cargoSha256, output })) + '\n'); }
  catch { process.stderr.write('codec notices: unavailable, unsafe or conflicting input/output\n'); process.exitCode = 1; }
}
