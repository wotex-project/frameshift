import { execFileSync } from 'node:child_process';
import { releaseCoordinates } from './source.mjs';

function ghJSON(path, timeout) {
  return JSON.parse(execFileSync('gh', ['api', '--hostname', 'github.com', '-H', 'Accept: application/vnd.github+json',
    '-H', 'X-GitHub-Api-Version: 2026-03-10', path],
  { encoding: 'utf8', stdio: ['ignore', 'pipe', 'pipe'], timeout, maxBuffer: 64 * 1024 }));
}

export function remoteSourceIdentity(repository, tag, commit, request = ghJSON) {
  const identity = releaseCoordinates(tag, commit);
  if (typeof repository !== 'string' || repository.length > 200 || repository.trim() !== repository ||
      !/^[A-Za-z0-9][A-Za-z0-9_.-]*\/[A-Za-z0-9][A-Za-z0-9_.-]*$/.test(repository)) throw new Error('unsupported GitHub repository');
  const deadline = Date.now() + 60_000;
  const read = path => {
    const remaining = deadline - Date.now();
    if (remaining <= 0) throw new Error('remote source deadline');
    return request(path, Math.min(15_000, remaining));
  };
  const ref = read(`repos/${repository}/git/ref/tags/${tag}`);
  if (ref?.ref !== `refs/tags/${tag}`) throw new Error('remote tag reference mismatch');
  let object = ref.object;
  const seen = new Set();
  for (let depth = 0; depth <= 8; depth++) {
    if (!object || typeof object.sha !== 'string' || object.sha.length !== 40 || !/^[0-9a-f]{40}$/.test(object.sha) || seen.has(object.sha)) throw new Error('invalid or repeated remote object');
    if (object.type === 'commit') {
      if (object.sha !== commit) throw new Error('remote tag commit mismatch');
      return { repository, ...identity };
    }
    if (object.type !== 'tag' || depth === 8) throw new Error('unsupported remote tag object or depth');
    seen.add(object.sha);
    const annotated = read(`repos/${repository}/git/tags/${object.sha}`);
    if (annotated?.sha !== object.sha) throw new Error('annotated remote tag identity mismatch');
    object = annotated.object;
  }
  throw new Error('remote source unavailable');
}
