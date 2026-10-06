import { writeFileSync } from 'node:fs';
import { join } from 'node:path';
import { verifyInputs } from '../inputs.mjs';
import { releaseGit } from '../source.mjs';
import { assertSourceMaterial, contextNames, images, inventory, sha256 } from './material.mjs';

const [repository, context, architecture, gleamHash, sourcePath, tag, commit, ...extra] = process.argv.slice(2);
if (!repository || !context || !['amd64', 'arm64'].includes(architecture) || !/^[a-f0-9]{64}$/.test(gleamHash)) {
  throw new Error('invalid build inputs');
}
if (extra.length || (sourcePath ? !tag || !commit : tag || commit)) throw new Error('invalid source binding');
const source = sourcePath ? await verifyInputs(repository, tag, commit, sourcePath) : null;
const entries = inventory(context, contextNames);
if (source) assertSourceMaterial(source, entries);
const sourceBytes = source && JSON.stringify(source) + '\n';
const record = {
  schemaVersion: 1,
  kind: source ? 'tagged-closure-candidate' : 'development-closure',
  product: 'io.frameshift.app',
  version: source?.version ?? '0.1.0-dev',
  ubuntu: '24.04',
  architecture,
  sourceCommit: releaseGit(repository, ['rev-parse', 'HEAD']).trim(),
  workingTreeChanged: releaseGit(repository, ['status', '--porcelain']).length > 0,
  publicationAuthority: 'none',
  ...(source ? { tag, sourceInputsSha256: sha256(sourceBytes), resolvedMaterialAssertion: 'captured-only' } : {}),
  toolchains: { otp: '29.1.1', elixir: '1.20.4', gleam: '1.18.1', gleamArchiveSha256: gleamHash, zig: '0.16.0', rust: '1.97.1', hex: '2.5.1' },
  images,
  inputs: entries,
};
writeFileSync(join(context, source ? 'source-inputs.json' : 'source-inputs.none'), sourceBytes ?? '', { flag: 'wx', mode: 0o600 });
writeFileSync(join(context, 'inputs.json'), `${JSON.stringify(record)}\n`, { flag: 'wx' });
