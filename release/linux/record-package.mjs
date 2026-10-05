import { createHash } from 'node:crypto';
import { execFileSync } from 'node:child_process';
import { lstatSync, readdirSync, readFileSync, writeFileSync } from 'node:fs';
import { join, relative } from 'node:path';

const [repository, context, architecture, revision] = process.argv.slice(2);
if (!repository || !context || !['amd64', 'arm64'].includes(architecture) || !/^[1-9][0-9]{0,3}$/.test(revision)) {
  throw new Error('invalid development package inputs');
}
const runtimePath = join(context, 'root/usr/share/doc/frameshift/build-inputs.json');
const runtimeBytes = readFileSync(runtimePath);
const runtime = JSON.parse(runtimeBytes);
if (runtime.schemaVersion !== 1 || runtime.kind !== 'development-closure' || runtime.product !== 'io.frameshift.app' ||
    runtime.version !== '0.1.0-dev' || runtime.ubuntu !== '24.04' || runtime.architecture !== architecture) {
  throw new Error('runtime closure identity mismatch');
}
const sha256 = bytes => createHash('sha256').update(bytes).digest('hex');
const inputs = [];
function collect(path) {
  const stat = lstatSync(path);
  if (stat.isDirectory()) {
    for (const name of readdirSync(path).sort()) collect(join(path, name));
  } else if (stat.isFile()) {
    const bytes = readFileSync(path);
    inputs.push({ path: relative(context, path), mode: stat.mode & 0o7777, bytes: bytes.length, sha256: sha256(bytes) });
  } else {
    throw new Error('package input must be a regular file or directory');
  }
}
collect(join(context, 'root'));
collect(join(context, 'linux'));
const record = {
  schemaVersion: 1,
  kind: 'development-deb',
  product: runtime.product,
  version: runtime.version,
  packageVersion: `0.1.0~dev+fixture${revision}`,
  ubuntu: runtime.ubuntu,
  architecture,
  sourceCommit: execFileSync('git', ['-C', repository, 'rev-parse', 'HEAD'], { encoding: 'utf8' }).trim(),
  workingTreeChanged: execFileSync('git', ['-C', repository, 'status', '--porcelain'], { encoding: 'utf8' }).length > 0,
  runtimeInputsSha256: sha256(runtimeBytes),
  image: 'sha256:534baea6a22c03a63003dbc8dbe78fe34bc0d7e595d9a9dc9834884ff530eb55',
  inputs,
};
writeFileSync(join(context, 'packaging-inputs.json'), `${JSON.stringify(record)}\n`, { flag: 'wx' });
