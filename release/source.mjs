import { execFileSync } from 'node:child_process';

export function releaseGit(repository, args) {
  const sourceEnvironment = { ...process.env };
  for (const name of Object.keys(sourceEnvironment)) {
    if (name.startsWith('GIT_')) delete sourceEnvironment[name];
  }
  return execFileSync('git', ['--no-replace-objects', `--work-tree=${repository}`, ...args], {
    cwd: repository, env: sourceEnvironment, encoding: 'utf8', timeout: 15_000,
    maxBuffer: 8 * 1024 * 1024, stdio: ['ignore', 'pipe', 'pipe'],
  });
}

export function releaseCoordinates(tag, expectedCommit) {
  if (typeof tag !== 'string' || tag.length > 33 || tag.trim() !== tag ||
      !/^v(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)$/.test(tag) ||
      typeof expectedCommit !== 'string' || expectedCommit.length !== 40 || !/^[0-9a-f]{40}$/.test(expectedCommit)) {
    throw new Error('Release requires a stable tag and exact source commit');
  }
  return { tag, commit: expectedCommit, version: tag.slice(1) };
}

export function releaseSourceIdentity(repository, tag, expectedCommit) {
  releaseCoordinates(tag, expectedCommit);
  const git = args => releaseGit(repository, args).trim();
  const commit = git(['rev-parse', 'HEAD']);
  const tagged = git(['rev-parse', '--verify', `refs/tags/${tag}^{commit}`]);
  if (commit !== expectedCommit || tagged !== expectedCommit || git(['status', '--porcelain', '--untracked-files=all'])) {
    throw new Error('Release requires clean exact tag/commit source');
  }
  return { commit, tag, version: tag.slice(1), dirty: false, publishableDevelopment: false };
}
