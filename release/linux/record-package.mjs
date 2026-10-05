import { readFileSync, writeFileSync } from 'node:fs';
import { join } from 'node:path';
import { verifyInputs } from '../inputs.mjs';
import { releaseGit } from '../source.mjs';
import { images, inventory, sha256 } from './material.mjs';

const [repository, context, architecture, revision, sourcePath, tag, commit, ...extra] = process.argv.slice(2);
if (!repository || !context || !['amd64', 'arm64'].includes(architecture) || extra.length ||
    (sourcePath ? !tag || !commit || revision !== 'candidate' : !/^[1-9][0-9]{0,3}$/.test(revision) || tag || commit)) {
  throw new Error('invalid package inputs');
}
// Admit regular input custody before reading its metadata.
const inputs = inventory(context, ['root', 'linux']);
const source = sourcePath ? await verifyInputs(repository, tag, commit, sourcePath) : null;
const runtimePath = join(context, 'root/usr/share/doc/frameshift/build-inputs.json');
const runtimeBytes = readFileSync(runtimePath);
const runtime = JSON.parse(runtimeBytes);
if (runtime.schemaVersion !== 1 || runtime.kind !== (source ? 'tagged-closure-candidate' : 'development-closure') || runtime.product !== 'io.frameshift.app' ||
    runtime.version !== (source?.version ?? '0.1.0-dev') || runtime.ubuntu !== '24.04' || runtime.architecture !== architecture ||
    (source && (runtime.sourceCommit !== commit || runtime.tag !== tag || runtime.sourceInputsSha256 !== sha256(JSON.stringify(source) + '\n') ||
      readFileSync(join(context, 'root/usr/share/doc/frameshift/source-inputs.json'), 'utf8') !== JSON.stringify(source) + '\n'))) {
  throw new Error('runtime closure identity mismatch');
}
const record = {
  schemaVersion: 1,
  kind: source ? 'tagged-deb-candidate' : 'development-deb',
  product: runtime.product,
  version: runtime.version,
  packageVersion: source?.version ?? `0.1.0~dev+fixture${revision}`,
  ubuntu: runtime.ubuntu,
  architecture,
  sourceCommit: releaseGit(repository, ['rev-parse', 'HEAD']).trim(),
  workingTreeChanged: releaseGit(repository, ['status', '--porcelain']).length > 0,
  publicationAuthority: 'none',
  ...(source ? { tag, sourceInputsSha256: runtime.sourceInputsSha256 } : {}),
  runtimeInputsSha256: sha256(runtimeBytes),
  image: images.runtime,
  inputs,
};
writeFileSync(join(context, 'packaging-inputs.json'), `${JSON.stringify(record)}\n`, { flag: 'wx' });
