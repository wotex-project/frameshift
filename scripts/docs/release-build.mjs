import assert from 'node:assert/strict';
import { generateKeyPairSync, sign } from 'node:crypto';
import { execFileSync, spawnSync } from 'node:child_process';
import { cpSync, lstatSync, mkdirSync, mkdtempSync, readFileSync, rmSync, writeFileSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { dirname, join, resolve } from 'node:path';
import { fileURLToPath } from 'node:url';
import { checkLinks, digest, headersForPath, inventory, validateReleaseDocumentationOutput } from './site.mjs';
import { assembleSite, validateAssembly } from './assembly.mjs';

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
const build = (revision, tag = 'v0.1.0') => spawnSync(join(root, 'scripts/build-site'), ['--release-docs', tag, revision], {
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

  // Join actual clean/rendered bundles to the release verifier and assembler.
  // Ephemeral signatures and synthetic public responses prove software wiring,
  // never production trust, an installed DEB or real public archive availability.
  writeFileSync(api, html);
  manifest.files = inventory(output).filter(file => file.path !== 'site-manifest.json');
  writeFileSync(join(output, 'site-manifest.json'), JSON.stringify(manifest, null, 2) + '\n');
  execFileSync(join(root, 'scripts/build-site'), [], { cwd: root, env: process.env, stdio: 'pipe', timeout: 120_000 });
  const development = join(root, 'var/site');
  const assembled = join(root, 'var/site-assembled');
  execFileSync(join(root, 'scripts/assemble-site'), ['development', development, assembled], { cwd: root, env: process.env, stdio: 'pipe', timeout: 30_000 });
  const keys = generateKeyPairSync('ed25519');
  const trustFile = join(root, 'var/fixture-trust.sha256');
  writeFileSync(trustFile, digest(keys.publicKey.export({ type: 'spki', format: 'der' })) + '\n');
  const bytes = Buffer.from('fixture archive');
  const signedInput = (candidate, version, sourceCommit) => {
    const directory = mkdtempSync(join(root, 'var/fixture-signature-'));
    const file = `frameshift-${version}-amd64.deb`;
    const manifest = Buffer.from(JSON.stringify({ schemaVersion: 1, product: 'io.frameshift.app', version,
      artifacts: [{ platform: 'ubuntu', architecture: 'amd64', format: 'deb', file,
        url: `https://example.invalid/releases/v${version}/${file}`, bytes: bytes.length, sha256: digest(bytes) }] }) + '\n');
    const manifestPath = join(directory, 'manifest.json');
    const signaturePath = join(directory, 'manifest.sig');
    const publicKeyPath = join(directory, 'public.pem');
    writeFileSync(manifestPath, manifest);
    writeFileSync(signaturePath, sign(null, manifest, keys.privateKey));
    writeFileSync(publicKeyPath, keys.publicKey.export({ type: 'spki', format: 'pem' }));
    writeFileSync(join(directory, file), bytes);
    return { candidate, sourceCommit, manifestPath, signaturePath, publicKeyPath, artifactDirectory: directory };
  };
  const fetcher = async () => new Response(bytes, { headers: { 'content-length': String(bytes.length) } });
  await assembleSite({ development, output: assembled, trustFile, release: signedInput(output, '0.1.0', revision) }, { fetcher });
  const retainedVersion = inventory(join(assembled, 'docs/v0.1.0'));
  const globalGuide = readFileSync(join(assembled, 'index.html'));
  execFileSync(join(root, 'scripts/assemble-site'), ['development', development, assembled, trustFile], { cwd: root, env: process.env, stdio: 'pipe', timeout: 30_000 });
  assert.deepEqual(inventory(join(assembled, 'docs/v0.1.0')), retainedVersion);
  assert.deepEqual(readFileSync(join(assembled, 'index.html')), globalGuide);

  writeFileSync(mix, original.replace(/version: "[^"]+"/, 'version: "0.0.1"'));
  const olderCommit = commit();
  git(['tag', 'v0.0.1']);
  succeeded(build(olderCommit, 'v0.0.1'));
  await assembleSite({ development, output: assembled, trustFile,
    release: signedInput(join(root, 'var/site-v0.0.1'), '0.0.1', olderCommit) }, { fetcher });
  const accepted = await validateAssembly(assembled, trustFile);
  assert.equal(accepted.latest, '0.1.0');
  assert.deepEqual(accepted.releases.map(entry => entry.version), ['0.1.0', '0.0.1']);
  assert.deepEqual(inventory(join(assembled, 'docs/v0.1.0')), retainedVersion);
  assert.deepEqual(readFileSync(join(assembled, 'index.html')), globalGuide);
  if (browser) execFileSync('mise', ['exec', '--', 'node', join(root, 'scripts/docs/browser.mjs')], {
    cwd: root, env: { ...process.env, FRAMESHIFT_DOCS_SITE: assembled }, stdio: 'inherit', timeout: 90_000,
  });
  console.log(`Release docs fixture passed: ${manifest.links.pages} HTML pages, ${manifest.links.links} links; exact source/version refusal, immutable rerun/conflict${browser ? ', Chrome version/search/CSP/no-JS' : ''}.`);
  console.log(`Assembled fixture passed: ${accepted.links.pages} HTML pages, ${accepted.links.links} links; two retained versions, signed/synthetic-public join, clean development CLI update and older-version refusal to rewind.`);
} finally {
  rmSync(root, { recursive: true, force: true });
}
