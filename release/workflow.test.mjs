import assert from 'node:assert/strict';
import { execFileSync } from 'node:child_process';
import { copyFileSync, mkdirSync, mkdtempSync, readFileSync, rmSync, writeFileSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { dirname, join, resolve } from 'node:path';
import test from 'node:test';
import { fileURLToPath } from 'node:url';
import { recordInputs } from './inputs.mjs';
import { remoteSourceIdentity } from './remote.mjs';
import { workflowInputs } from './workflow.mjs';

const root = resolve(dirname(fileURLToPath(import.meta.url)), '..');
const sha = 'a'.repeat(40);
const repo = 'wotex-project/frameshift';
const tag = 'v1.2.3';
const reference = commit => ({ ref: `refs/tags/${tag}`, object: { type: 'commit', sha: commit } });

test('remote lightweight and annotated tags resolve only through computed repository endpoints', () => {
  assert.deepEqual(remoteSourceIdentity(repo, tag, sha, () => reference(sha)), { repository: repo, tag, commit: sha, version: '1.2.3' });
  const object = 'b'.repeat(40);
  const requests = [];
  const result = remoteSourceIdentity(repo, tag, sha, (path, timeout) => {
    requests.push(path);
    assert.ok(timeout > 0 && timeout <= 15_000);
    if (requests.length === 1) return { ref: `refs/tags/${tag}`, object: { type: 'tag', sha: object, url: 'https://untrusted.example/key' } };
    return { sha: object, object: { type: 'commit', sha } };
  });
  assert.equal(result.commit, sha);
  assert.deepEqual(requests, [`repos/${repo}/git/ref/tags/${tag}`, `repos/${repo}/git/tags/${object}`]);
});

test('malformed coordinates and repository paths refuse before an API query', () => {
  let queries = 0;
  const request = () => { queries++; throw new Error('invalid input reached API'); };
  for (const repository of ['https://github.com/a/b', 'a/../b', 'a/b\n', '--help', 'a/b/c']) {
    assert.throws(() => remoteSourceIdentity(repository, tag, sha, request));
  }
  for (const malformed of ['v1.2.3-dev', 'v01.2.3', '--help', 'v1.2.3\n']) {
    assert.throws(() => remoteSourceIdentity(repo, malformed, sha, request));
  }
  assert.throws(() => remoteSourceIdentity(repo, tag, 'main', request));
  assert.throws(() => remoteSourceIdentity(repo, tag, sha + '\n', request));
  assert.equal(queries, 0);
});

test('missing, moved, wildcard, malformed and unsupported remote objects refuse', () => {
  const object = 'b'.repeat(40);
  for (const response of [reference(object), [reference(sha)], { ...reference(sha), ref: 'refs/heads/main' },
    { ref: `refs/tags/${tag}`, object: { type: 'tree', sha } }, { ref: `refs/tags/${tag}`, object: { type: 'commit', sha: 'malformed' } }]) {
    assert.throws(() => remoteSourceIdentity(repo, tag, sha, () => response));
  }
  assert.throws(() => remoteSourceIdentity(repo, tag, sha, () => { throw new Error('404 or API unavailable'); }));
  let count = 0;
  assert.throws(() => remoteSourceIdentity(repo, tag, sha, () => ++count === 1 ?
    { ref: `refs/tags/${tag}`, object: { type: 'tag', sha: object } } : { sha: 'c'.repeat(40), object: { type: 'commit', sha } }));
});

test('annotation loops and excessive depth stop after bounded requests', () => {
  const object = 'b'.repeat(40);
  let count = 0;
  assert.throws(() => remoteSourceIdentity(repo, tag, sha, () => ++count === 1 ?
    { ref: `refs/tags/${tag}`, object: { type: 'tag', sha: object } } : { sha: object, object: { type: 'tag', sha: object } }));
  assert.equal(count, 2);
  count = 0;
  assert.throws(() => remoteSourceIdentity(repo, tag, sha, () => {
    const current = (++count).toString(16).padStart(40, '0');
    return count === 1 ? { ref: `refs/tags/${tag}`, object: { type: 'tag', sha: current } } :
      { sha: (count - 1).toString(16).padStart(40, '0'), object: { type: 'tag', sha: current } };
  }));
  assert.equal(count, 9);
});

async function fixture(t) {
  const repository = mkdtempSync(join(tmpdir(), 'frameshift-workflow-source-'));
  t.after(() => rmSync(repository, { recursive: true, force: true }));
  const git = args => execFileSync('git', args, { cwd: repository, encoding: 'utf8', stdio: 'pipe' }).trim();
  git(['init', '-b', 'main']);
  mkdirSync(join(repository, 'apps/core'), { recursive: true });
  mkdirSync(join(repository, 'release'));
  mkdirSync(join(repository, 'var'), { mode: 0o700 });
  copyFileSync(join(root, '.mise.toml'), join(repository, '.mise.toml'));
  copyFileSync(join(root, 'release/read-version.exs'), join(repository, 'release/read-version.exs'));
  writeFileSync(join(repository, '.gitignore'), '_build/\nvar/\n');
  writeFileSync(join(repository, 'README.md'), 'frozen source\n');
  writeFileSync(join(repository, 'apps/core/mix.exs'), 'defmodule WorkflowFixture do\n  @moduledoc false\n\n  use Mix.Project\n  def project, do: [app: :frameshift_core, version: "1.2.3"]\nend\n');
  git(['add', '.']);
  git(['-c', 'user.name=Fixture', '-c', 'user.email=fixture@example.invalid', 'commit', '-m', 'test(host): define workflow source fixture']);
  const commit = git(['rev-parse', 'HEAD']);
  git(['tag', tag]);
  const output = join(repository, 'var/source');
  await recordInputs(repository, tag, commit, output);
  return { githubRepository: repo, repository, tag, commit, recordPath: join(output, 'source-inputs.json'), git };
}

test('source jobs and target jobs must agree on the exact deterministic Git/Mix record', async t => {
  const f = await fixture(t);
  const request = () => reference(f.commit);
  const identity = await workflowInputs(f, request);
  assert.match(identity.sourceInputsSha256, /^[0-9a-f]{64}$/);
  assert.deepEqual(await workflowInputs({ ...f, expectedDigest: identity.sourceInputsSha256 }, request), identity);
  await assert.rejects(() => workflowInputs({ ...f, expectedDigest: 'f'.repeat(64) }, request), /handoff mismatch/);
  let queries = 0;
  for (const digest of ['malformed', 'f'.repeat(64) + '\n']) {
    await assert.rejects(() => workflowInputs({ ...f, expectedDigest: digest }, () => { queries++; return reference(f.commit); }));
  }
  assert.equal(queries, 0);
});

test('a remote move during source verification refuses while retaining the frozen record', async t => {
  const f = await fixture(t);
  const before = readFileSync(f.recordPath);
  let queries = 0;
  await assert.rejects(() => workflowInputs(f, () => reference(++queries === 1 ? f.commit : sha)), /remote tag commit mismatch/);
  assert.equal(queries, 2);
  assert.deepEqual(readFileSync(f.recordPath), before);
});

test('hidden local source mutation cannot be handed to a target job', async t => {
  const f = await fixture(t);
  const before = readFileSync(f.recordPath);
  f.git(['update-index', '--assume-unchanged', 'README.md']);
  writeFileSync(join(f.repository, 'README.md'), 'hidden source mutation');
  assert.equal(f.git(['status', '--porcelain']), '');
  await assert.rejects(() => workflowInputs(f, () => reference(f.commit)));
  assert.deepEqual(readFileSync(f.recordPath), before);
});

test('the candidate workflow exposes only explicit manual staging and pinned actions with read-only credentials', () => {
  const workflow = readFileSync(join(root, '.github/workflows/ubuntu-candidate.yml'), 'utf8');
  assert.doesNotMatch(workflow, /\b(?:pull_request|pull_request_target|workflow_run|push|secrets)\s*[:.]/);
  assert.doesNotMatch(workflow, /\b(?:contents|actions|id-token)\s*:\s*write/);
  assert.doesNotMatch(workflow, /persist(?:-credentials|_github_token):\s*true/);
  const uses = [...workflow.matchAll(/uses: ([^\s]+)\s/g)].map(match => match[1]);
  assert.ok(uses.length > 0);
  assert.ok(uses.every(action => /@[0-9a-f]{40}$/.test(action)));
  assert.match(workflow, /needs: source/);
  assert.match(workflow, /source_inputs_sha256/);
  assert.match(workflow, /check-linux-candidate/);
  assert.match(workflow, /tar --format=ustar --hard-dereference/);
  assert.match(workflow, /stage-linux-candidate/);
  assert.match(workflow, /archive_sha256=%s/);
  assert.match(workflow, /steps\.archive\.outputs\.archive_sha256/);
  assert.match(workflow, /steps\.retain\.outputs\.artifact-id/);
  assert.match(workflow, /GITHUB_STEP_SUMMARY/);
  assert.match(workflow, /archive: false/);
  assert.match(workflow, /overwrite: false/);
  assert.match(workflow, /github\.run_attempt/);
});

test('Mac workflow stages explicit native candidates with pinned read-only authority and exact transport identities', () => {
  const workflow = readFileSync(join(root, '.github/workflows/macos-candidate.yml'), 'utf8');
  assert.match(workflow, /workflow_dispatch:/);
  assert.doesNotMatch(workflow, /\b(?:pull_request|pull_request_target|workflow_run|push|secrets)\s*[:.]/);
  assert.doesNotMatch(workflow, /\b(?:contents|actions|id-token)\s*:\s*write/);
  assert.doesNotMatch(workflow, /persist(?:-credentials|_github_token):\s*true/);
  assert.doesNotMatch(workflow, /\bgh\s+(?:release|workflow)\b|\b(?:notarytool|stapler|wrangler)\b/);
  const uses = [...workflow.matchAll(/uses: ([^\s]+)\s/g)].map(match => match[1]);
  assert.ok(uses.length > 0); assert.ok(uses.every(action => /@[0-9a-f]{40}$/.test(action)));
  assert.match(workflow, /needs: source/); assert.match(workflow, /source_inputs_sha256/);
  assert.match(workflow, /architecture: arm64\s+runner: macos-26\s/);
  assert.match(workflow, /architecture: x86_64\s+runner: macos-26-intel\s/);
  assert.doesNotMatch(workflow, /macos-latest/);
  assert.match(workflow, /sysctl -n hw\.optional\.arm64/);
  assert.match(workflow, /DEVELOPER_DIR: \/Applications\/Xcode_26\.6\.app\/Contents\/Developer/);
  assert.match(workflow, /Build version 17F113/); assert.match(workflow, /--show-sdk-version\)" = 26\.5/);
  assert.match(workflow, /mix deps\.get --check-locked/); assert.match(workflow, /gleam deps download/);
  assert.match(workflow, /package-macos-candidate/); assert.match(workflow, /check-packaged-app/);
  assert.match(workflow, /COPYFILE_DISABLE=1 \/usr\/bin\/tar --format ustar/);
  assert.match(workflow, /stage-macos-candidate/);
  assert.match(workflow, /steps\.archive\.outputs\.archive_sha256/); assert.match(workflow, /steps\.archive\.outputs\.candidate_record_sha256/);
  assert.match(workflow, /steps\.retain\.outputs\.artifact-id/); assert.match(workflow, /GITHUB_STEP_SUMMARY/);
  assert.match(workflow, /archive: false/); assert.match(workflow, /overwrite: false/); assert.match(workflow, /github\.run_attempt/);
  const build = workflow.slice(workflow.indexOf('- name: Build the frozen native candidate'), workflow.indexOf('- name: Recheck remote identity'));
  assert.doesNotMatch(build, /GH_TOKEN|secrets/);
});
