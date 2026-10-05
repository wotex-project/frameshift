import { createHash } from 'node:crypto';
import { execFileSync } from 'node:child_process';
import { lstatSync, readdirSync, readFileSync, writeFileSync } from 'node:fs';
import { join, relative } from 'node:path';

const [repository, context, architecture, gleamHash] = process.argv.slice(2);
if (!repository || !context || !['amd64', 'arm64'].includes(architecture) || !/^[a-f0-9]{64}$/.test(gleamHash)) {
  throw new Error('invalid development build inputs');
}
const entries = [];
function collect(path) {
  const stat = lstatSync(path);
  if (stat.isDirectory()) {
    for (const name of readdirSync(path).sort()) collect(join(path, name));
  } else if (stat.isFile()) {
    const bytes = readFileSync(path);
    entries.push({ path: relative(context, path), bytes: bytes.length, sha256: createHash('sha256').update(bytes).digest('hex') });
  } else {
    throw new Error('build input must be a regular file or directory');
  }
}
for (const name of ['apps', 'packages', 'protocol', 'codec', 'linux', 'mix-archives', 'gleam', 'frameshift-raster']) collect(join(context, name));
entries.sort((a, b) => a.path.localeCompare(b.path, 'en'));
const record = {
  schemaVersion: 1,
  kind: 'development-closure',
  product: 'io.frameshift.app',
  version: '0.1.0-dev',
  ubuntu: '24.04',
  architecture,
  sourceCommit: execFileSync('git', ['-C', repository, 'rev-parse', 'HEAD'], { encoding: 'utf8' }).trim(),
  workingTreeChanged: execFileSync('git', ['-C', repository, 'status', '--porcelain'], { encoding: 'utf8' }).length > 0,
  toolchains: { otp: '29.1', elixir: '1.20.4', gleam: '1.18.1', gleamArchiveSha256: gleamHash, zig: '0.16.0', rust: '1.97.1', hex: '2.5.1' },
  images: { build: 'sha256:5b77ba2dec41d6d1716b354bbca92cd9359ed02b273f92eeabd0c92f9c9bdeee', rust: 'sha256:b1b3c9c0d921d7fa0a6d1f9ec7e4eab87f8c8ec97644c3d791450f131dec813f', runtime: 'sha256:534baea6a22c03a63003dbc8dbe78fe34bc0d7e595d9a9dc9834884ff530eb55' },
  inputs: entries,
};
writeFileSync(join(context, 'inputs.json'), `${JSON.stringify(record)}\n`, { flag: 'wx' });
