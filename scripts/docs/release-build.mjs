import assert from 'node:assert/strict';
import { execFileSync, spawnSync } from 'node:child_process';
import { cpSync, lstatSync, mkdirSync, mkdtempSync, readFileSync, rmSync, writeFileSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { dirname, join, resolve } from 'node:path';
import { fileURLToPath } from 'node:url';
import { checkLinks, headersForPath, inventory, validateReleaseDocumentationOutput } from './site.mjs';

const repository = resolve(dirname(fileURLToPath(import.meta.url)), '../..');
const browser = process.argv.length === 3 && process.argv[2] === '--browser';
if (process.argv.length !== 2 && !browser) throw new Error('usage: node scripts/docs/release-build.mjs [--browser]');
const root = mkdtempSync(join(tmpdir(), 'frameshift-release-docs-'));
const git = args => execFileSync('git', args, { cwd: root, encoding: 'utf8', stdio: 'pipe' }).trim();
const commit = () => {
  git(['add', '.']);
  git(['-c', 'user.name=Fixture', '-c', 'user.email=fixture@example.invalid', 'commit', '-m', 'docs: qualify fixture source']);
  return git(['rev-parse', 'HEAD']);
};
const build = revision => spawnSync(join(root, 'scripts/build-site'), ['--release-docs', 'v0.1.0', revision], {
  cwd: root, env: process.env, encoding: 'utf8', timeout: 120_000, maxBuffer: 4 * 1024 * 1024,
});
const succeeded = result => assert.equal(result.status, 0, result.stderr + result.stdout);

try {
  // A clean, test-only source repository and stable tag; never tag the worktree
  // or claim that these development dependencies/artifacts are released.
  const sources = execFileSync('git', ['ls-files', '--cached', '--others', '--exclude-standard', '-z'], {
    cwd: repository, encoding: 'utf8',
  }).split('\0').filter(Boolean);
  for (const source of sources) {
    assert.ok(lstatSync(join(repository, source)).isFile(), source);
    mkdirSync(dirname(join(root, source)), { recursive: true });
    cpSync(join(repository, source), join(root, source));
  }
  for (const cache of ['apps/core/deps', 'apps/core/_build/dev', 'packages/decision-kernel/build']) {
    mkdirSync(dirname(join(root, cache)), { recursive: true });
    cpSync(join(repository, cache), join(root, cache), { recursive: true });
  }
  const mix = join(root, 'apps/core/mix.exs');
  const original = readFileSync(mix, 'utf8');
  assert.match(original, /version: "[^"]+"/);
  writeFileSync(mix, original.replace(/version: "[^"]+"/, 'version: "0.0.0-dev"'));
  git(['init', '-b', 'main']);
  let revision = commit();
  git(['tag', 'v0.1.0']);
  const output = join(root, 'var/site-v0.1.0');
  const wrongVersion = build(revision);
  assert.notEqual(wrongVersion.status, 0);
  assert.match(wrongVersion.stderr, /version differs from the application/);
  assert.throws(() => lstatSync(output), /ENOENT/);

  writeFileSync(mix, original.replace(/version: "[^"]+"/, 'version: "0.1.0"'));
  revision = commit();
  git(['tag', '-f', 'v0.1.0']);
  succeeded(build(revision));
  const identity = { tag: 'v0.1.0', version: '0.1.0', commit: revision };
  const manifest = validateReleaseDocumentationOutput(output, identity);
  assert.equal(manifest.publishable, false);
  assert.equal(manifest.release, null);
  const docs = join(output, 'docs/v0.1.0');
  const record = JSON.parse(readFileSync(join(docs, 'build.json'), 'utf8'));
  assert.equal(record.commit, revision);
  assert.equal(record.tag, 'v0.1.0');
  assert.equal(record.version, '0.1.0');
  assert.equal(record.publishableDevelopment, false);
  assert.deepEqual(record.files, inventory(docs).filter(file => file.path !== 'build.json'));
  const api = join(docs, 'Frameshift.Library.html');
  const html = readFileSync(api, 'utf8');
  assert.ok(html.includes('Versioned documentation 0.1.0'));
  assert.ok(html.includes(revision));
  assert.ok(html.includes('src="/docs/docs_config.js"'));
  assert.ok(html.includes('id="restore_master/3"'));
  assert.ok(readFileSync(join(output, 'download/index.html'), 'utf8').includes('No qualified release or installer'));
  assert.deepEqual(checkLinks(output), manifest.links);
  const headers = readFileSync(join(output, '_headers'), 'utf8');
  assert.match(headersForPath(headers, '/docs/v0.1.0/Frameshift.Library.html')['cache-control'], /immutable/);
  assert.equal(headersForPath(headers, '/docs/docs_config.js')['cache-control'], 'no-cache');
  const retained = lstatSync(api, { bigint: true });
  const rerun = build(revision);
  succeeded(rerun);
  assert.match(rerun.stdout, /Identical release documentation verified/);
  const replayed = lstatSync(api, { bigint: true });
  for (const key of ['dev', 'ino', 'mode', 'uid', 'gid', 'nlink', 'size', 'mtimeNs', 'ctimeNs']) {
    assert.equal(replayed[key], retained[key], key);
  }

  if (browser) execFileSync('mise', ['exec', '--', 'node', join(root, 'scripts/docs/browser.mjs')], {
    cwd: root, env: { ...process.env, FRAMESHIFT_DOCS_SITE: output }, stdio: 'inherit', timeout: 90_000,
  });

  // Even an internally recorded inventory cannot authorize different content
  // for this version. Preserve the existing bytes when its new build conflicts.
  writeFileSync(api, html + '\n<!-- conflicting retained content -->\n');
  manifest.files = inventory(output).filter(file => file.path !== 'site-manifest.json');
  writeFileSync(join(output, 'site-manifest.json'), JSON.stringify(manifest, null, 2) + '\n');
  const conflict = build(revision);
  assert.notEqual(conflict.status, 0);
  assert.match(conflict.stderr, /Conflicting content for an existing documentation version/);
  assert.ok(readFileSync(api, 'utf8').includes('conflicting retained content'));
  assert.deepEqual(inventory(output).filter(file => file.path !== 'site-manifest.json'), manifest.files);
  console.log(`Release docs fixture passed: ${manifest.links.pages} HTML pages, ${manifest.links.links} links; exact source/version refusal, immutable rerun/conflict${browser ? ', Chrome version/search/CSP/no-JS' : ''}.`);
} finally {
  rmSync(root, { recursive: true, force: true });
}
