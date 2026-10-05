import { resolve } from 'node:path';
import { collectDependencyNotices } from './notices.mjs';

const repository = resolve(new URL('..', import.meta.url).pathname);
const [tag, commit, sourcePath, coreCache, corePath, coreSha256, gleamCache, gleamPath, gleamSha256, output, ...extra] = process.argv.slice(2);
if (!tag || !commit || !sourcePath || !coreCache || !corePath || !coreSha256 || !gleamCache || !gleamPath || !gleamSha256 || !output || extra.length) {
  process.stderr.write('usage: collect-dependency-notices TAG COMMIT SOURCE_RECORD CORE_CACHE CORE_RECEIPT CORE_SHA256 GLEAM_CACHE GLEAM_RECEIPT GLEAM_SHA256 OUTPUT\n'); process.exitCode = 64;
} else {
  try { process.stdout.write(JSON.stringify(await collectDependencyNotices({ repository, tag, commit, sourcePath, coreCache, corePath, coreSha256, gleamCache, gleamPath, gleamSha256, output })) + '\n'); }
  catch { process.stderr.write('dependency notices: unavailable, unsafe or conflicting input/output\n'); process.exitCode = 1; }
}
