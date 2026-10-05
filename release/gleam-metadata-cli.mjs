import { resolve } from 'node:path';
import { prepareGleamMetadata } from './gleam-metadata.mjs';

const repository = resolve(new URL('..', import.meta.url).pathname);
const [tag, commit, sourcePath, ...extra] = process.argv.slice(2);
if (!tag || !commit || !sourcePath || extra.length) {
  process.stderr.write('usage: prepare-gleam-metadata TAG COMMIT SOURCE_RECORD\n'); process.exitCode = 64;
} else {
  try { process.stdout.write(JSON.stringify(await prepareGleamMetadata({ repository, tag, commit, sourcePath })) + '\n'); }
  catch { process.stderr.write('Gleam generated metadata preparation refused; retained input and incomplete custody preserved\n'); process.exitCode = 1; }
}
