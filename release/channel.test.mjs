import assert from 'node:assert/strict';
import { spawnSync } from 'node:child_process';
import { createHash, generateKeyPairSync, sign } from 'node:crypto';
import { lstatSync, mkdirSync, mkdtempSync, readFileSync, rmSync, writeFileSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import test from 'node:test';
import { channelGhRead, inspectReleaseChannel } from './channel.mjs';
import { signRelease } from './signer.mjs';

const hash = bytes => createHash('sha256').update(bytes).digest('hex');
const clone = value => structuredClone(value);
async function fixture(t) {
  const root = mkdtempSync(join(tmpdir(), 'frameshift-channel-'));
  t.after(() => rmSync(root, { recursive: true, force: true }));
  const repository = 'owner/frameshift-binaries';
  const artifactDirectory = join(root, 'artifacts');
  mkdirSync(artifactDirectory, { mode: 0o700 });
  const file = 'frameshift_1.2.3_arm64.deb';
  const archive = Buffer.from('synthetic archive, no installed claim');
  writeFileSync(join(artifactDirectory, file), archive);
  const keys = generateKeyPairSync('ed25519');
  const trustedKeyDigest = hash(keys.publicKey.export({ type: 'spki', format: 'der' }));
  const planPath = join(root, 'plan.json');
  const privateKeyPath = join(root, 'owner.pem');
  writeFileSync(privateKeyPath, keys.privateKey.export({ type: 'pkcs8', format: 'pem' }), { mode: 0o600 });
  const prefix = `https://github.com/${repository}/releases/download/v1.2.3/`;
  writeFileSync(planPath, JSON.stringify({ schemaVersion: 1, product: 'io.frameshift.app', version: '1.2.3',
    artifacts: [{ platform: 'ubuntu', architecture: 'arm64', format: 'deb', file, url: prefix + file }] }) + '\n');
  const outputDirectory = join(root, 'signed');
  await signRelease({ planPath, privateKeyPath, artifactDirectory, trustedKeyDigest, outputDirectory });
  const options = { repository, artifactDirectory, trustedKeyDigest,
    manifestPath: join(outputDirectory, 'manifest.json'), signaturePath: join(outputDirectory, 'manifest.sig'),
    publicKeyPath: join(outputDirectory, 'release.pub.pem') };
  const bytes = new Map([[file, archive], ['manifest.json', readFileSync(options.manifestPath)],
    ['manifest.sig', readFileSync(options.signaturePath)], ['release.pub.pem', readFileSync(options.publicKeyPath)]]);
  const repo = { id: 100, full_name: repository, private: false, visibility: 'public' };
  const release = { id: 101, tag_name: 'v1.2.3', draft: false, prerelease: false, published_at: '2026-10-05T00:00:00Z',
    html_url: `https://github.com/${repository}/releases/tag/v1.2.3`, target_commitish: 'channel-default-branch',
    assets_url: 'https://untrusted.invalid/do-not-follow' };
  const assets = [...bytes].map(([name, value], index) => ({ id: 200 + index, name, state: 'uploaded', size: value.length,
    digest: 'sha256:' + hash(value), browser_download_url: prefix + name }));
  return { root, options, keys, bytes, repo, release, assets };
}
function transport(f, mutate = () => {}) {
  const paths = [];
  const downloads = [];
  let round = 0;
  return {
    paths, downloads,
    request(path, timeout) {
      assert.ok(timeout > 0 && timeout <= 15_000);
      paths.push(path);
      if (path === `repos/${f.options.repository}`) { mutate(++round); return { status: 200, data: clone(f.repo) }; }
      if (path === `repos/${f.options.repository}/releases/tags/v1.2.3`) return { status: f.release ? 200 : 404, data: clone(f.release) };
      assert.equal(path, `repos/${f.options.repository}/releases/101/assets?per_page=100&page=1`);
      return { status: 200, data: clone(f.assets) };
    },
    async fetcher(url, options) {
      downloads.push(url);
      assert.equal(options.credentials, 'omit');
      assert.equal(options.redirect, 'manual');
      assert.deepEqual(options.headers, { 'accept-encoding': 'identity' });
      const bytes = f.bytes.get(new URL(url).pathname.split('/').at(-1));
      assert.ok(bytes);
      return new Response(bytes, { headers: { 'content-length': String(bytes.length) } });
    }
  };
}

test('real signed local files join exact API inventory and anonymous archive/metadata readback without rewriting', async t => {
  const f = await fixture(t);
  const wire = transport(f);
  const before = lstatSync(f.options.manifestPath);
  const observation = await inspectReleaseChannel(f.options, wire.request, wire.fetcher);
  assert.equal(observation.state, 'public-bytes-verified');
  assert.equal(observation.publicationAuthority, 'none');
  assert.equal(observation.repositoryId, 100);
  assert.equal(observation.releaseId, 101);
  assert.equal(wire.paths.length, 6);
  assert.equal(wire.downloads.length, 4);
  assert.deepEqual(await inspectReleaseChannel(f.options, wire.request, wire.fetcher), observation);
  assert.equal(lstatSync(f.options.manifestPath).ino, before.ino);
  assert.equal(lstatSync(f.options.manifestPath).mtimeMs, before.mtimeMs);
  for (const asset of f.assets) asset.digest = null;
  assert.equal((await inspectReleaseChannel(f.options, wire.request, wire.fetcher)).state, 'public-bytes-verified');
});

test('malformed coordinates, wrong channels, hosting size, trust and local archive tamper refuse with zero API requests', async t => {
  const f = await fixture(t);
  const request = () => assert.fail('invalid local input cannot issue an API request');
  for (const repository of ['owner/frameshift-binaries\n', '../owner/repo', 'owner/repo?latest', 'https://github.com/owner/repo']) {
    await assert.rejects(() => inspectReleaseChannel({ ...f.options, repository }, request));
  }
  await assert.rejects(() => inspectReleaseChannel({ ...f.options, repository: 'another/channel' }, request), /URL/);
  await assert.rejects(() => inspectReleaseChannel({ ...f.options, trustedKeyDigest: '0'.repeat(64) }, request), /trusted key/);
  const original = readFileSync(f.options.manifestPath);
  const manifest = JSON.parse(original);
  manifest.artifacts[0].bytes = 2 * 1024 * 1024 * 1024;
  const huge = Buffer.from(JSON.stringify(manifest) + '\n');
  writeFileSync(f.options.manifestPath, huge);
  writeFileSync(f.options.signaturePath, sign(null, huge, f.keys.privateKey));
  await assert.rejects(() => inspectReleaseChannel(f.options, request), /size/);
  writeFileSync(f.options.manifestPath, original);
  writeFileSync(f.options.signaturePath, sign(null, original, f.keys.privateKey));
  writeFileSync(join(f.options.artifactDirectory, manifest.artifacts[0].file), 'substituted private archive');
  await assert.rejects(() => inspectReleaseChannel(f.options, request), /size mismatch|digest mismatch/);
});

test('missing published release, visible draft, missing assets and starter uploads remain non-promoting observations', async t => {
  const f = await fixture(t);
  const wire = transport(f);
  const initial = clone(f.release);
  f.release = null;
  const absent = await inspectReleaseChannel(f.options, wire.request, wire.fetcher);
  assert.equal(absent.state, 'not-published');
  assert.equal(absent.releaseId, null);
  f.release = { ...initial, draft: true, published_at: null };
  assert.equal((await inspectReleaseChannel(f.options, wire.request, wire.fetcher)).state, 'not-published');
  f.release = initial;
  const missing = f.assets.pop();
  const incomplete = await inspectReleaseChannel(f.options, wire.request, wire.fetcher);
  assert.equal(incomplete.state, 'incomplete');
  assert.deepEqual(incomplete.missing, [missing.name]);
  f.assets.push({ ...missing, state: 'starter', size: 0, digest: null });
  const interrupted = await inspectReleaseChannel(f.options, wire.request, wire.fetcher);
  assert.equal(interrupted.state, 'incomplete');
  assert.deepEqual(interrupted.interrupted, [missing.name]);
  assert.equal(wire.downloads.length, 0);
});

test('private/malformed releases and conflicting/ambiguous asset inventories refuse before public download', async t => {
  const f = await fixture(t);
  const wire = transport(f);
  const prior = { repo: clone(f.repo), release: clone(f.release), assets: clone(f.assets) };
  const mutations = [
    () => f.repo.private = true, () => f.repo.visibility = 'private', () => f.repo.id = 0,
    () => f.release.tag_name = 'v1.2.4', () => f.release.id = -1, () => f.release.prerelease = true,
    () => f.release.published_at = null, () => f.release.html_url = 'https://untrusted.invalid',
    () => f.assets[0].size++, () => f.assets[0].digest = 'sha256:' + '0'.repeat(64),
    () => f.assets[0].browser_download_url = 'https://untrusted.invalid', () => f.assets[0].state = 'unknown',
    () => f.assets[1].name = f.assets[0].name, () => f.assets[1].id = f.assets[0].id,
    () => f.assets.push({ ...f.assets[0], id: 999, name: 'unrecognized' })
  ];
  for (const mutation of mutations) {
    Object.assign(f, clone(prior));
    mutation();
    await assert.rejects(() => inspectReleaseChannel(f.options, wire.request, wire.fetcher));
  }
  assert.equal(wire.downloads.length, 0);
});

test('API metadata cannot substitute for actual public bytes and in-flight local/remote changes refuse', async t => {
  const f = await fixture(t);
  let wire = transport(f);
  await assert.rejects(() => inspectReleaseChannel(f.options, wire.request, async () => new Response('wrong served bytes')), /length|digest/);
  for (const mutation of [
    () => f.repo.id++, () => f.release.id++, () => f.assets[0].id++, () => f.assets.pop(), () => f.release = null
  ]) {
    const prior = { repo: clone(f.repo), release: clone(f.release), assets: clone(f.assets) };
    wire = transport(f, round => { if (round === 2) mutation(); });
    await assert.rejects(() => inspectReleaseChannel(f.options, wire.request, wire.fetcher));
    Object.assign(f, prior);
  }
  wire = transport(f);
  let downloaded = false;
  await assert.rejects(() => inspectReleaseChannel(f.options, wire.request, async (url, opts) => {
    if (!downloaded) { downloaded = true; writeFileSync(f.options.publicKeyPath, Buffer.concat([readFileSync(f.options.publicKeyPath), Buffer.from('\n')])); }
    return wire.fetcher(url, opts);
  }), /changed during/);
});

test('the actual gh adapter uses bounded explicit GETs and distinguishes HTTP 404 from credential/service failure', t => {
  const root = mkdtempSync(join(tmpdir(), 'frameshift-gh-channel-'));
  t.after(() => rmSync(root, { recursive: true, force: true }));
  const bin = join(root, 'bin'); mkdirSync(bin);
  const record = join(root, 'args.json');
  const fixture = join(bin, 'gh');
  const script = `#!${process.execPath}\nimport { writeFileSync } from 'node:fs';\nwriteFileSync(process.env.FRAMESHIFT_GH_TEST_ARGS, JSON.stringify(process.argv.slice(2)));\nconst status = process.env.FRAMESHIFT_GH_TEST_STATUS;\nprocess.stdout.write('HTTP/2.0 ' + status + ' Status\\nContent-Type: application/json; charset=utf-8\\r\\n\\r\\n' + JSON.stringify({ status }));\nprocess.exitCode = status === '200' ? 0 : 1;\n`;
  writeFileSync(fixture, script, { mode: 0o755 });
  const previous = { PATH: process.env.PATH, status: process.env.FRAMESHIFT_GH_TEST_STATUS, args: process.env.FRAMESHIFT_GH_TEST_ARGS };
  try {
    process.env.PATH = bin + ':' + previous.PATH;
    process.env.FRAMESHIFT_GH_TEST_ARGS = record;
    for (const status of ['200', '404', '401', '403', '500']) {
      process.env.FRAMESHIFT_GH_TEST_STATUS = status;
      if (['200', '404'].includes(status)) assert.equal(channelGhRead('repos/owner/repo').status, Number(status));
      else assert.throws(() => channelGhRead('repos/owner/repo'), /unavailable/);
      const args = JSON.parse(readFileSync(record));
      assert.deepEqual(args.slice(0, 7), ['api', '--hostname', 'github.com', '--method', 'GET', '--include', '-H']);
      assert.ok(args.includes('X-GitHub-Api-Version: 2026-03-10'));
      assert.equal(args.at(-1), 'repos/owner/repo');
    }
    writeFileSync(fixture, `#!${process.execPath}\nprocess.stdout.write('HTTP/2.0 200 OK\\nContent-Type: application/json\\n\\n' + 'x'.repeat(300000));\n`, { mode: 0o755 });
    assert.throws(() => channelGhRead('repos/owner/repo'), /unavailable|invalid/);
    const cli = spawnSync(process.execPath, [join(import.meta.dirname, 'channel-cli.mjs')], { encoding: 'utf8' });
    assert.equal(cli.status, 64);
    assert.equal(cli.stdout, '');
  } finally {
    process.env.PATH = previous.PATH;
    for (const [key, value] of [['FRAMESHIFT_GH_TEST_STATUS', previous.status], ['FRAMESHIFT_GH_TEST_ARGS', previous.args]]) {
      if (value === undefined) delete process.env[key]; else process.env[key] = value;
    }
  }
});

test('the channel CLI returns explicit incomplete status and fixed refusal without invoking gh for invalid trust', async t => {
  const f = await fixture(t);
  const bin = join(f.root, 'bin'); mkdirSync(bin);
  const called = join(f.root, 'called');
  const script = `#!${process.execPath}\nimport { writeFileSync } from 'node:fs';\nwriteFileSync(${JSON.stringify(called)}, 'GET observed');\nconst repo = ${JSON.stringify(f.repo)};\nconst path = process.argv.at(-1);\nconst status = path === 'repos/' + repo.full_name ? 200 : 404;\nprocess.stdout.write('HTTP/2.0 ' + status + ' Status\\nContent-Type: application/json\\n\\n' + JSON.stringify(status === 200 ? repo : { message: 'Not Found' }));\nprocess.exitCode = status === 200 ? 0 : 1;\n`;
  writeFileSync(join(bin, 'gh'), script, { mode: 0o755 });
  const trustFile = join(f.root, 'trust.sha256');
  writeFileSync(trustFile, f.options.trustedKeyDigest + '\n', { mode: 0o600 });
  const args = [join(import.meta.dirname, 'channel-cli.mjs'), f.options.repository, f.options.manifestPath,
    f.options.signaturePath, f.options.publicKeyPath, f.options.artifactDirectory, trustFile];
  const run = () => spawnSync(process.execPath, args, { encoding: 'utf8', timeout: 5000,
    env: { ...process.env, PATH: bin + ':' + process.env.PATH } });
  const partial = run();
  assert.equal(partial.error, undefined);
  assert.equal(partial.status, 2);
  assert.equal(partial.stderr, '');
  const observation = JSON.parse(partial.stdout);
  assert.equal(observation.state, 'not-published');
  assert.equal(observation.publicationAuthority, 'none');
  assert.equal(observation.missing.length, 4);
  rmSync(called);
  writeFileSync(trustFile, 'malformed private fixture\n');
  const refused = run();
  assert.equal(refused.status, 1);
  assert.equal(refused.stdout, '');
  assert.equal(refused.stderr, 'release channel inspection refused: local trust, channel, public bytes or custody\n');
  assert.throws(() => lstatSync(called), /ENOENT/);
});
