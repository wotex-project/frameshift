import assert from 'node:assert/strict';
import { execFileSync } from 'node:child_process';
import { mkdirSync, mkdtempSync, readFileSync, rmSync, symlinkSync, writeFileSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import test from 'node:test';
import { checkDocumentationIndex, checkLinks, documentationPolicy, headersForPath, inventory, labelHeadingAnchors, releaseSourceIdentity, resolveRoute, sharedVersionMenu, siteHeaders, sourceIdentity, validateDevelopmentOutput, validateReleaseDocumentationOutput } from './site.mjs';

function fixture(t) {
  const root = mkdtempSync(join(tmpdir(), 'frameshift-site-test-'));
  t.after(() => rmSync(root, { recursive: true, force: true }));
  return root;
}

test('clean main source is eligible; dirty, alternate and detached sources refuse', t => {
  const root = fixture(t);
  const git = args => execFileSync('git', args, { cwd: root, stdio: 'pipe' });
  git(['init', '-b', 'main']);
  writeFileSync(join(root, 'README.md'), 'fixture');
  git(['add', 'README.md']);
  git(['-c', 'user.name=Fixture', '-c', 'user.email=fixture@example.invalid', 'commit', '-m', 'docs: fixture']);
  const clean = sourceIdentity(root);
  assert.equal(clean.publishableDevelopment, true);
  writeFileSync(join(root, 'README.md'), 'changed');
  assert.throws(() => sourceIdentity(root), /requires clean main/);
  assert.deepEqual(sourceIdentity(root, true), { ...clean, dirty: true, publishableDevelopment: false });
  git(['restore', 'README.md']);
  git(['checkout', '-b', 'fixture']);
  assert.throws(() => sourceIdentity(root), /requires clean main/);
  git(['checkout', '--detach', clean.commit]);
  assert.throws(() => sourceIdentity(root), /requires clean main/);
});

test('nested paths, escaped attributes and fragments resolve; missing targets refuse', t => {
  const root = fixture(t);
  mkdirSync(join(root, 'docs'));
  writeFileSync(join(root, 'index.html'), '<a href="/docs/">Docs</a>');
  writeFileSync(join(root, 'docs/index.html'), '<h2 id="unicode-å">Title</h2><a href="/?q=a&amp;b=c">Home</a><a href="#unicode-%C3%A5">Section</a>');
  assert.deepEqual(checkLinks(root), { pages: 2, links: 3 });
  writeFileSync(join(root, 'docs/index.html'), '<a href="#missing">Broken</a>');
  assert.throws(() => checkLinks(root), /missing anchor/);
  writeFileSync(join(root, 'docs/index.html'), '<img src="missing.png">');
  assert.throws(() => checkLinks(root), /missing missing.png/);
});

test('asset inventory rejects symlinks; route resolution refuses traversal and reserved assets', t => {
  const root = fixture(t);
  writeFileSync(join(root, 'index.html'), '<h1>Fixture</h1>');
  writeFileSync(join(root, '_headers'), 'fixture');
  assert.equal(resolveRoute(root, '/'), join(root, 'index.html'));
  assert.equal(resolveRoute(root, '/%2e%2e/private'), null);
  assert.equal(resolveRoute(root, '/_headers'), null);
  assert.equal(resolveRoute(root, '/missing'), null);
  symlinkSync(join(root, 'index.html'), join(root, 'alias.html'));
  assert.throws(() => inventory(root), /Non-regular static asset/);
});

test('CSP hashes exact inline scripts and guide/docs policies never overlap', t => {
  const root = fixture(t);
  writeFileSync(join(root, 'index.html'), '<script>window.fixture=1;</script><script src="external.js"></script>');
  const policy = documentationPolicy(root);
  assert.match(policy, /script-src 'self' 'sha256-/);
  assert.ok(!policy.includes("script-src 'unsafe-inline'"));
  assert.ok(policy.includes("connect-src 'self'"));
  assert.ok(policy.includes("form-action 'self'"));
  const headers = siteHeaders("/*\n  Content-Security-Policy: default-src 'none'; script-src 'self'\n  X-Frame-Options: DENY\n", policy);
  assert.equal(headersForPath(headers, '/docs/dev/index.html')['content-security-policy'], policy);
  assert.equal(headersForPath(headers, '/docs/dev/index.html')['x-frame-options'], 'DENY');
  assert.equal(headersForPath(headers, '/')['content-security-policy'], "default-src 'none'; script-src 'self'");
  assert.equal(headersForPath(headers, '/docs/')['cache-control'], 'no-cache');
  const changed = documentationPolicy(root);
  writeFileSync(join(root, 'index.html'), '<script>window.fixture=2;</script>');
  assert.notEqual(documentationPolicy(root), changed);
});

test('generated heading link names survive without JavaScript and preserve upstream names', () => {
  const unnamed = '<a href="#section" class="hover-link"><i aria-hidden="true"></i></a>';
  assert.match(labelHeadingAnchors(unnamed), /aria-label="Link to this section"/);
  const named = '<a href="#section" class="hover-link" aria-label="Upstream name">';
  assert.equal(labelHeadingAnchors(named), named);
});

test('a maintained document missing from the owner index refuses the build', t => {
  const root = fixture(t);
  mkdirSync(join(root, 'docs/dev'), { recursive: true });
  const pages = [{ source: 'docs/README.md', id: 'docs--readme' }, { source: 'docs/host/macos.md', id: 'docs--host--macos' }];
  writeFileSync(join(root, 'docs/dev/docs--readme.html'), '<h1>Index</h1>');
  assert.throws(() => checkDocumentationIndex(root, pages), /omits: docs\/host\/macos.md/);
  writeFileSync(join(root, 'docs/dev/docs--readme.html'), '<a href="/docs/dev/docs--host--macos.html#startup">Mac</a>');
  assert.doesNotThrow(() => checkDocumentationIndex(root, pages));
});

test('changed or unowned output and retained release docs refuse replacement with bytes preserved', t => {
  const root = fixture(t);
  writeFileSync(join(root, 'index.html'), 'keep prior development site');
  assert.throws(() => validateDevelopmentOutput(root));
  writeFileSync(join(root, 'site-manifest.json'), JSON.stringify({ schemaVersion: 1,
    channel: 'development', release: null, files: inventory(root) }));
  assert.doesNotThrow(() => validateDevelopmentOutput(root));
  writeFileSync(join(root, 'index.html'), 'external edit');
  assert.throws(() => validateDevelopmentOutput(root), /unowned or changed/);
  mkdirSync(join(root, 'docs/v1.2.3'), { recursive: true });
  writeFileSync(join(root, 'docs/v1.2.3/index.html'), 'keep released bytes');
  assert.throws(() => validateDevelopmentOutput(root), /Retained release docs/);
  assert.equal(readFileSync(join(root, 'docs/v1.2.3/index.html'), 'utf8'), 'keep released bytes');
});

test('release docs require the clean exact stable tag; dirty, missing, moved and mismatched source refuses', t => {
  const root = fixture(t);
  const git = args => execFileSync('git', args, { cwd: root, encoding: 'utf8', stdio: 'pipe' }).trim();
  git(['init', '-b', 'main']);
  writeFileSync(join(root, 'README.md'), 'first exact source');
  git(['add', 'README.md']);
  git(['-c', 'user.name=Fixture', '-c', 'user.email=fixture@example.invalid', 'commit', '-m', 'docs: fixture']);
  const commit = git(['rev-parse', 'HEAD']);
  git(['-c', 'user.name=Fixture', '-c', 'user.email=fixture@example.invalid', 'tag', '-a', 'v1.2.3', '-m', 'fixture']);
  const expected = { commit, tag: 'v1.2.3', version: '1.2.3', dirty: false, publishableDevelopment: false };
  assert.deepEqual(releaseSourceIdentity(root, 'v1.2.3', commit), expected);
  git(['checkout', '--detach', commit]);
  assert.deepEqual(releaseSourceIdentity(root, 'v1.2.3', commit), expected);
  for (const tag of ['v1.2.3-rc.1', 'v01.2.3', '1.2.3', '--help', 'v1.2.4']) {
    assert.throws(() => releaseSourceIdentity(root, tag, commit));
  }
  assert.throws(() => releaseSourceIdentity(root, 'v1.2.3', 'a'.repeat(40)), /clean exact/);
  assert.throws(() => releaseSourceIdentity(root, 'v1.2.3', 'HEAD'), /exact source commit/);
  writeFileSync(join(root, 'README.md'), 'changed source');
  assert.throws(() => releaseSourceIdentity(root, 'v1.2.3', commit), /clean exact/);
  git(['add', 'README.md']);
  git(['-c', 'user.name=Fixture', '-c', 'user.email=fixture@example.invalid', 'commit', '-m', 'docs: successor']);
  git(['tag', '-f', 'v1.2.3']);
  assert.throws(() => releaseSourceIdentity(root, 'v1.2.3', commit), /clean exact/);
});

test('version menu stays outside immutable docs; per-version policies and cache rules stay separate', t => {
  const root = fixture(t);
  const html = '<script defer src="docs_config.js"></script><script src="dist/search.js"></script>';
  assert.equal(sharedVersionMenu(html), '<script defer src="/docs/docs_config.js"></script><script src="dist/search.js"></script>');
  const headers = siteHeaders("/*\n  Content-Security-Policy: default-src 'none'; script-src 'self'\n", 'development-policy',
    [{ version: '1.2.3', policy: 'release-policy' }]);
  assert.deepEqual(headersForPath(headers, '/docs/v1.2.3/Frameshift.Library.html'), {
    'content-security-policy': 'release-policy', 'cache-control': 'public, max-age=31536000, immutable' });
  assert.equal(headersForPath(headers, '/docs/dev/Frameshift.Library.html')['cache-control'], 'no-cache');
  assert.deepEqual(headersForPath(headers, '/docs/docs_config.js'), { 'cache-control': 'no-cache' });
  mkdirSync(join(root, 'docs/v1.2.3'), { recursive: true });
  writeFileSync(join(root, 'docs/v1.2.3/docs--readme.html'), '<a href="/docs/v1.2.3/docs--owner.html">Owner</a>');
  assert.doesNotThrow(() => checkDocumentationIndex(root,
    [{ source: 'docs/owner.md', id: 'docs--owner' }], '/docs/v1.2.3/'));
  assert.throws(() => checkDocumentationIndex(root,
    [{ source: 'docs/missing.md', id: 'docs--missing' }], '/docs/v1.2.3/'), /omits/);
});

test('retained candidate identity and complete inventory refuse unowned or changed bytes without replacement', t => {
  const root = fixture(t);
  const identity = { tag: 'v1.2.3', version: '1.2.3', commit: 'a'.repeat(40) };
  writeFileSync(join(root, 'index.html'), 'immutable candidate');
  const manifest = { schemaVersion: 1, channel: 'release-documentation', publishable: false, release: null,
    commit: identity.commit, documentation: { tag: identity.tag, version: identity.version }, files: inventory(root) };
  const record = join(root, 'site-manifest.json');
  writeFileSync(record, JSON.stringify(manifest));
  assert.deepEqual(validateReleaseDocumentationOutput(root, identity), manifest);
  assert.throws(() => validateReleaseDocumentationOutput(root, { ...identity, commit: 'b'.repeat(40) }), /conflicting/);
  writeFileSync(join(root, 'index.html'), 'external retained change');
  assert.throws(() => validateReleaseDocumentationOutput(root, identity), /changed/);
  assert.equal(readFileSync(join(root, 'index.html'), 'utf8'), 'external retained change');
  writeFileSync(record, JSON.stringify({ ...manifest, publishable: true, files: inventory(root).filter(file => file.path !== 'site-manifest.json') }));
  assert.throws(() => validateReleaseDocumentationOutput(root, identity), /unowned/);
});
