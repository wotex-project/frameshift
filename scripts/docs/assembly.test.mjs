import assert from 'node:assert/strict';
import { generateKeyPairSync, sign } from 'node:crypto';
import { execFileSync, spawnSync } from 'node:child_process';
import { chmodSync, cpSync, existsSync, lstatSync, mkdirSync, mkdtempSync, readFileSync, rmSync, symlinkSync, writeFileSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { fileURLToPath } from 'node:url';
import test from 'node:test';
import { assembleSite, compareVersions, recoverSite, validateAssembly } from './assembly.mjs';
import { checkLinks, digest, documentationPolicy, inventory, pathExists, siteHeaders } from './site.mjs';

function fixture(t) {
  const root = mkdtempSync(join(tmpdir(), 'frameshift-assembly-test-'));
  t.after(() => rmSync(root, { recursive: true, force: true }));
  const keys = generateKeyPairSync('ed25519');
  const trustFile = join(root, 'trust.sha256');
  writeFileSync(trustFile, digest(keys.publicKey.export({ type: 'spki', format: 'der' })) + '\n');
  return { root, keys, trustFile };
}

function recordDocs(root, route, commit, version) {
  const directory = join(root, route.slice(1));
  mkdirSync(directory, { recursive: true, mode: 0o700 });
  writeFileSync(join(directory, 'index.html'), `<h1>${version || 'Unreleased development'}</h1><p>${commit}</p><a href="/">Guide</a><script src="/docs/docs_config.js"></script>`);
  writeFileSync(join(directory, 'build.json'), JSON.stringify({ schemaVersion: 1, route, commit, dirty: false, preview: false,
    channel: version ? 'release-documentation' : 'development', version, tag: version ? `v${version}` : null,
    publishableDevelopment: !version, files: inventory(directory).filter(file => file.path !== 'build.json') }) + '\n');
}

function recordSite(root, commit, version) {
  const manifest = { schemaVersion: 1, channel: version ? 'release-documentation' : 'development', commit, dirty: false, release: null,
    ...(version ? { publishable: false, documentation: { version, tag: `v${version}` } } : {}),
    links: checkLinks(root), files: inventory(root).filter(file => file.path !== 'site-manifest.json') };
  writeFileSync(join(root, 'site-manifest.json'), JSON.stringify(manifest) + '\n');
}

function development(f, name = 'dev', commit = 'a'.repeat(40)) {
  const root = join(f.root, name);
  mkdirSync(root, { mode: 0o700 });
  mkdirSync(join(root, 'docs'), { mode: 0o700 });
  mkdirSync(join(root, 'download'), { mode: 0o700 });
  writeFileSync(join(root, 'index.html'), '<h1>Guide</h1><!-- RELEASE_DOWNLOADS_START -->No release<!-- RELEASE_DOWNLOADS_END -->');
  writeFileSync(join(root, 'site.css'), 'body{font:1rem sans-serif}');
  writeFileSync(join(root, '404.html'), '<h1>Not found</h1>');
  writeFileSync(join(root, 'download/index.html'), '<h1>No qualified release</h1>');
  writeFileSync(join(root, 'docs/index.html'), '<h1>No release</h1><a href="/docs/dev/">Development</a>');
  writeFileSync(join(root, 'docs/docs_config.js'), 'var versionNodes = [];\n');
  recordDocs(root, '/docs/dev/', commit);
  writeFileSync(join(root, '_headers'), siteHeaders("/*\n  Content-Security-Policy: default-src 'none'; script-src 'self'\n  X-Frame-Options: DENY\n", documentationPolicy(join(root, 'docs/dev'))));
  recordSite(root, commit);
  return root;
}

function release(f, dev, version = '1.2.3', sourceCommit = 'b'.repeat(40), bytes = Buffer.from('fixture archive')) {
  const directory = mkdtempSync(join(f.root, 'release-'));
  const candidate = join(directory, 'candidate');
  cpSync(dev, candidate, { recursive: true });
  recordDocs(candidate, `/docs/v${version}/`, sourceCommit, version);
  recordSite(candidate, sourceCommit, version);
  const name = `frameshift-${version}-amd64.deb`;
  const manifest = { schemaVersion: 1, product: 'io.frameshift.app', version,
    artifacts: [{ platform: 'ubuntu', architecture: 'amd64', format: 'deb', file: name,
      url: `https://example.invalid/releases/v${version}/${name}`, bytes: bytes.length, sha256: digest(bytes) }] };
  const encoded = Buffer.from(JSON.stringify(manifest) + '\n');
  const manifestPath = join(directory, 'manifest.json');
  const signaturePath = join(directory, 'manifest.sig');
  const publicKeyPath = join(directory, 'public.pem');
  writeFileSync(manifestPath, encoded);
  writeFileSync(signaturePath, sign(null, encoded, f.keys.privateKey));
  writeFileSync(publicKeyPath, f.keys.publicKey.export({ type: 'spki', format: 'pem' }));
  writeFileSync(join(directory, name), bytes);
  return { candidate, sourceCommit, manifestPath, signaturePath, publicKeyPath, artifactDirectory: directory };
}

const publicBytes = async () => new Response('fixture archive', { headers: { 'content-length': '15' } });
const retainedFiles = site => inventory(site).filter(file => file.path.startsWith('docs/v') || file.path.startsWith('release-records/'));

test('assembly CLI refuses FIFO and oversized signed metadata before replacing the previous site', async t => {
  const f = fixture(t);
  const dev = development(f);
  const output = join(f.root, 'site');
  await assembleSite({ development: dev, output });
  const before = inventory(output);
  const r = release(f, dev);
  const saved = readFileSync(r.manifestPath);
  for (const kind of ['fifo', 'oversized']) {
    rmSync(r.manifestPath);
    if (kind === 'fifo') execFileSync('mkfifo', [r.manifestPath]);
    else writeFileSync(r.manifestPath, Buffer.alloc(64 * 1024 + 1));
    const result = spawnSync(process.execPath, [fileURLToPath(new URL('./assemble.mjs', import.meta.url)),
      'release', dev, r.candidate, output, r.manifestPath, r.signaturePath, r.publicKeyPath, r.artifactDirectory, f.trustFile, r.sourceCommit],
      { encoding: 'utf8', timeout: 2000, killSignal: 'SIGKILL' });
    assert.equal(result.error, undefined, `${kind} must refuse before the child deadline`);
    assert.equal(result.status, 1);
    assert.deepEqual(inventory(output), before);
    assert.equal(existsSync(output + '.lock'), false);
    assert.equal(existsSync(output + '.previous'), false);
    rmSync(r.manifestPath);
    writeFileSync(r.manifestPath, saved);
  }
});

test('no-release assembly refuses previews and preserves custody on a foreign lock or dangling output', async t => {
  const f = fixture(t);
  const dev = development(f);
  const output = join(f.root, 'site');
  const result = await assembleSite({ development: dev, output });
  assert.equal(result.latest, null);
  assert.match(readFileSync(join(output, 'download/index.html'), 'utf8'), /No qualified release/);
  const before = inventory(output);
  const build = join(dev, 'docs/dev/build.json');
  const bad = JSON.parse(readFileSync(build));
  bad.preview = true;
  bad.publishableDevelopment = false;
  writeFileSync(build, JSON.stringify(bad));
  recordSite(dev, 'a'.repeat(40));
  await assert.rejects(assembleSite({ development: dev, output }), /eligible clean-main/);
  assert.deepEqual(inventory(output), before);
  mkdirSync(output + '.lock', { mode: 0o700 });
  writeFileSync(join(output + '.lock', 'other-writer'), 'preserve');
  await assert.rejects(assembleSite({ development: dev, output }), /EEXIST/);
  assert.equal(readFileSync(join(output + '.lock', 'other-writer'), 'utf8'), 'preserve');
  rmSync(output + '.lock', { recursive: true });
  const alias = join(f.root, 'dangling');
  symlinkSync(join(f.root, 'missing'), alias);
  await assert.rejects(assembleSite({ development: dev, output: alias }), /custody/);
  assert.ok(lstatSync(alias).isSymbolicLink());
  assert.ok(pathExists(alias));
});

test('signed/public release promotion retains versions across development and older releases', async t => {
  const f = fixture(t);
  const dev = development(f);
  const output = join(f.root, 'site');
  const accepted = release(f, dev);
  const initial = await assembleSite({ development: dev, output, release: accepted, trustFile: f.trustFile }, { fetcher: publicBytes });
  assert.equal(initial.latest, '1.2.3');
  assert.match(readFileSync(join(output, 'download/index.html'), 'utf8'), /https:\/\/example.invalid\/releases\/v1.2.3/);
  const retained = retainedFiles(output);
  const globals = ['index.html', 'docs/index.html', 'download/index.html'].map(path => readFileSync(join(output, path), 'utf8'));
  const successor = development(f, 'successor', 'c'.repeat(40));
  await assert.rejects(assembleSite({ development: successor, output }), /trust file/);
  await assembleSite({ development: successor, output, trustFile: f.trustFile });
  assert.deepEqual(retainedFiles(output), retained);
  assert.deepEqual(['index.html', 'docs/index.html', 'download/index.html'].map(path => readFileSync(join(output, path), 'utf8')), globals);
  const older = release(f, dev, '1.0.0', 'd'.repeat(40));
  const result = await assembleSite({ development: successor, output, release: older, trustFile: f.trustFile }, { fetcher: publicBytes });
  assert.equal(result.latest, '1.2.3');
  assert.deepEqual(result.releases.map(entry => entry.version), ['1.2.3', '1.0.0']);
  assert.deepEqual(['index.html', 'download/index.html'].map(path => readFileSync(join(output, path), 'utf8')), [globals[0], globals[2]]);
  assert.deepEqual(retainedFiles(output).filter(file => file.path.includes('v1.2.3/')), retained);
  assert.equal((await validateAssembly(output, f.trustFile)).latest, '1.2.3');
  await assembleSite({ development: successor, output, release: accepted, trustFile: f.trustFile }, { fetcher: publicBytes });
  assert.deepEqual(retainedFiles(output).filter(file => file.path.includes('v1.2.3/')), retained);
});

test('changed source, signed artifacts, trust, public bytes and in-flight input refuse before replacing output', async t => {
  const f = fixture(t);
  const dev = development(f);
  const output = join(f.root, 'site');
  const accepted = release(f, dev);
  await assembleSite({ development: dev, output, release: accepted, trustFile: f.trustFile }, { fetcher: publicBytes });
  const before = inventory(output);
  const changedSource = release(f, dev, '1.2.3', 'e'.repeat(40));
  const changedBytes = release(f, dev, '1.2.3', accepted.sourceCommit, Buffer.from('changed archive'));
  await assert.rejects(assembleSite({ development: dev, output, release: changedSource, trustFile: f.trustFile }, { fetcher: publicBytes }), /Conflicting source/);
  await assert.rejects(assembleSite({ development: dev, output, release: changedBytes, trustFile: f.trustFile }, {
    fetcher: async () => new Response('changed archive', { headers: { 'content-length': '15' } }),
  }), /Conflicting source/);
  await assert.rejects(assembleSite({ development: dev, output, release: accepted, trustFile: f.trustFile }, {
    fetcher: async () => new Response('wrong public!!!', { headers: { 'content-length': '15' } }),
  }), /public release digest mismatch/);
  const wrong = join(f.root, 'wrong.sha256');
  writeFileSync(wrong, 'f'.repeat(64));
  await assert.rejects(assembleSite({ development: dev, output, release: accepted, trustFile: wrong }), /trusted key mismatch/);
  chmodSync(f.trustFile, 0o666);
  await assert.rejects(assembleSite({ development: dev, output, trustFile: f.trustFile }), /trust file custody/);
  chmodSync(f.trustFile, 0o600);
  const fresh = release(f, dev, '1.3.0');
  await assert.rejects(assembleSite({ development: dev, output, release: fresh, trustFile: f.trustFile }, {
    fetcher: async () => {
      recordDocs(dev, '/docs/dev/', 'f'.repeat(40));
      recordSite(dev, 'f'.repeat(40));
      return publicBytes();
    },
  }), /inputs changed/);
  assert.deepEqual(inventory(output), before);
  assert.equal(existsSync(output + '.lock'), false);
});

test('actual killed writers restore or complete exact local assemblies without replaying release effects', async t => {
  const f = fixture(t);
  const dev = development(f);
  for (const step of ['previous', 'current']) {
    const output = join(f.root, `site-${step}`);
    await assembleSite({ development: dev, output, trustFile: f.trustFile, release: release(f, dev) }, { fetcher: publicBytes });
    const retained = retainedFiles(output);
    const successor = development(f, `dev-${step}`, 'c'.repeat(40));
    const code = `import { assembleSite } from ${JSON.stringify(new URL('./assembly.mjs', import.meta.url).href)};
      await assembleSite(${JSON.stringify({ development: successor, output, trustFile: f.trustFile })}, { afterSwap: step => { if (step === ${JSON.stringify(step)}) process.kill(process.pid, 'SIGKILL'); } });`;
    const killed = spawnSync(process.execPath, ['--input-type=module', '-e', code], { encoding: 'utf8', timeout: 30_000 });
    assert.equal(killed.signal, 'SIGKILL', killed.stderr);
    assert.ok(existsSync(output + '.lock'));
    assert.ok(existsSync(output + '.previous'));
    const recovery = spawnSync(process.execPath, [fileURLToPath(new URL('./assemble.mjs', import.meta.url)),
      'recover', output, f.trustFile], { encoding: 'utf8', timeout: 30_000 });
    assert.equal(recovery.status, 0, recovery.stderr);
    assert.equal(recovery.stdout, `Local site ${step === 'previous' ? 'restored' : 'completed'}\n`);
    const recovered = await validateAssembly(output, f.trustFile);
    assert.equal(recovered.development.commit, (step === 'previous' ? 'a' : 'c').repeat(40));
    assert.equal(existsSync(output + '.lock'), false);
    assert.equal(existsSync(output + '.previous'), false);
    assert.deepEqual(retainedFiles(output), retained);
    assert.equal(await recoverSite(output, f.trustFile), 'verified');
  }
});

test('exact numeric version ordering survives components beyond JavaScript safe integers', () => {
  assert.equal(compareVersions('1.10.0', '1.9.100'), 1);
  assert.equal(compareVersions('9007199254740993.0.0', '9007199254740992.100.0'), 1);
  assert.equal(compareVersions('1.2.3', '1.2.3'), 0);
  assert.throws(() => compareVersions('01.2.3', '1.2.3'), /Invalid stable/);
});

test('changed recovery custody refuses with current, prior and journal bytes preserved', async t => {
  const f = fixture(t);
  const dev = development(f);
  const output = join(f.root, 'site');
  await assembleSite({ development: dev, output });
  const successor = development(f, 'successor', 'c'.repeat(40));
  await assert.rejects(assembleSite({ development: successor, output }, {
    afterSwap: step => { if (step === 'current') throw new Error('injected post-swap fault'); },
  }), /outcome uncertain/);
  writeFileSync(join(output, 'index.html'), 'unknown changed current bytes');
  const prior = inventory(output + '.previous');
  const journal = readFileSync(join(output + '.lock', 'journal.json'));
  await assert.rejects(recoverSite(output), /changed site assembly/);
  assert.equal(readFileSync(join(output, 'index.html'), 'utf8'), 'unknown changed current bytes');
  assert.deepEqual(inventory(output + '.previous'), prior);
  assert.deepEqual(readFileSync(join(output + '.lock', 'journal.json')), journal);
});

test('a changed ready stage cannot authorize deleting candidate or restoring over unknown custody', async t => {
  const f = fixture(t);
  const dev = development(f);
  const output = join(f.root, 'site');
  await assembleSite({ development: dev, output });
  const successor = development(f, 'successor', 'c'.repeat(40));
  await assert.rejects(assembleSite({ development: successor, output }, {
    afterSwap: step => { if (step === 'previous') throw new Error('injected before-new-name fault'); },
  }), /outcome uncertain/);
  const journal = JSON.parse(readFileSync(join(output + '.lock', 'journal.json')));
  const stage = join(f.root, journal.stage);
  writeFileSync(join(stage, 'index.html'), 'unknown staged bytes');
  const prior = inventory(output + '.previous');
  await assert.rejects(recoverSite(output), /changed site assembly/);
  assert.deepEqual(inventory(output + '.previous'), prior);
  assert.equal(existsSync(output), false);
  assert.equal(readFileSync(join(stage, 'index.html'), 'utf8'), 'unknown staged bytes');
  assert.ok(existsSync(output + '.lock'));
});
