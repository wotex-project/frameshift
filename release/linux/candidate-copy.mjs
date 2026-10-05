import { copyFileSync, lstatSync } from 'node:fs';
import { basename, dirname, join, resolve } from 'node:path';
import { fileURLToPath } from 'node:url';
import { buildCandidate } from './candidate.mjs';
import { inventory } from './material.mjs';

const [tag, commit, sourcePath, architecture, output, destination, ...extra] = process.argv.slice(2);
try {
  if (!destination || extra.length || !lstatSync(join(output, 'candidate.json')).isFile()) throw new Error('candidate required');
  const record = await buildCandidate({ repository: resolve(dirname(fileURLToPath(import.meta.url)), '../..'),
    tag, commit, sourcePath, architecture, output }, () => { throw new Error('check cannot rebuild'); });
  const archive = record.artifacts[0];
  copyFileSync(join(output, archive.path), join(destination, basename(archive.path)));
  const [copy, ...others] = inventory(destination);
  if (!copy || others.length || copy.bytes !== archive.bytes || copy.sha256 !== archive.sha256) throw new Error('archive handoff changed');
  process.stdout.write('Ubuntu candidate archive handoff: exact bytes verified\n');
} catch {
  process.stderr.write('Ubuntu candidate archive handoff: source, custody or copied bytes refused\n');
  process.exitCode = 1;
}
