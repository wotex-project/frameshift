import assert from 'node:assert/strict';
import { spawnSync } from 'node:child_process';
import { createHash, generateKeyPairSync, sign } from 'node:crypto';
import { chmodSync, lstatSync, mkdirSync, mkdtempSync, readFileSync, readdirSync, rmSync, symlinkSync, writeFileSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import test from 'node:test';
import { deriveMacChannels, signMacChannels, signSparkleFeed, verifyMacChannels, verifySparkleArchive, verifySparkleFeed } from './channels.mjs';

const hash = bytes => createHash('sha256').update(bytes).digest('hex');
function fixture(t, url = 'https://example.test/releases/v1.2.3/Frameshift-1.2.3.dmg') {
  const root = mkdtempSync(join(tmpdir(), 'frameshift-mac-channels-'));
  t.after(() => rmSync(root, { recursive: true, force: true }));
  const release = generateKeyPairSync('ed25519'), sparkle = generateKeyPairSync('ed25519');
  const archive = Buffer.from('opaque archive fixture; not an installed DMG\n');
  const artifactDirectory = join(root, 'archives'); mkdirSync(artifactDirectory, { mode: 0o700 });
  const artifact = { platform: 'macos', architecture: 'universal', format: 'dmg',
    file: 'Frameshift-1.2.3.dmg', url, bytes: archive.length, sha256: hash(archive) };
  const manifest = { schemaVersion: 1, product: 'io.frameshift.app', version: '1.2.3', artifacts: [artifact] };
  const paths = { manifestPath: join(root, 'manifest.json'), signaturePath: join(root, 'manifest.sig'),
    publicKeyPath: join(root, 'release.pub.pem'), releaseTrustPath: join(root, 'release-trust'),
    sparkleSignaturePath: join(root, 'sparkle.sig'), sparkleTrustPath: join(root, 'sparkle-trust'),
    outputDirectory: join(root, 'output'), artifactDirectory, minimumOS: '15.0.0' };
  const save = (path, bytes) => writeFileSync(path, bytes, { mode: 0o600 });
  const publicKey = sparkle.publicKey.export({ type: 'spki', format: 'der' }).subarray(-32);
  const refresh = () => {
    const bytes = Buffer.from(JSON.stringify(manifest) + '\n');
    save(paths.manifestPath, bytes); save(paths.signaturePath, sign(null, bytes, release.privateKey));
  };
  refresh(); save(paths.publicKeyPath, release.publicKey.export({ type: 'spki', format: 'pem' }));
  save(paths.releaseTrustPath, hash(release.publicKey.export({ type: 'spki', format: 'der' })) + '\n');
  save(paths.sparkleTrustPath, publicKey.toString('base64') + '\n');
  save(paths.sparkleSignaturePath, sign(null, archive, sparkle.privateKey).toString('base64') + '\n');
  const archivePath = join(artifactDirectory, artifact.file); save(archivePath, archive);
  return { root, options: paths, release, sparkle, archive, archivePath, artifact, manifest, publicKey, refresh };
}

test('separate signed archive and manifest derive the same exact Mac channel identities', async t => {
  const f = fixture(t);
  const result = await deriveMacChannels(f.options);
  assert.deepEqual(result, { version: '1.2.3', publicationAuthority: 'none', disposition: 'local-material-created' });
  const record = JSON.parse(readFileSync(join(f.options.outputDirectory, 'channels.json')));
  assert.deepEqual(record.artifact, f.artifact);
  assert.equal(record.declaredMinimumOS, '15.0.0'); assert.equal(record.publicationAuthority, 'none');
  assert.ok(record.qualificationRequired.includes('final-app-and-updater'));
  const cask = readFileSync(join(f.options.outputDirectory, 'frameshift.rb'), 'utf8');
  const feed = readFileSync(join(f.options.outputDirectory, 'appcast.xml'), 'utf8');
  assert.ok(cask.includes(`sha256 '${f.artifact.sha256}'`)); assert.ok(cask.includes(`url '${f.artifact.url}'`));
  assert.ok(cask.includes("depends_on macos: '>= 15.0.0'")); assert.ok(cask.includes('auto_updates true'));
  assert.ok(!/zap|uninstall|system_command/.test(cask));
  assert.ok(feed.includes(`<sparkle:version>1.2.3</sparkle:version>`));
  assert.ok(feed.includes(`<sparkle:minimumSystemVersion>15.0.0</sparkle:minimumSystemVersion>`));
  assert.ok(feed.includes(`length="${f.artifact.bytes}"`)); assert.ok(!/pubDate|releaseNotesLink|delta/.test(feed));
  assert.deepEqual(readdirSync(f.options.outputDirectory).sort(), ['appcast.xml', 'channels.json', 'frameshift.rb', 'sparkle.sig']);
  for (const entry of record.files) {
    const bytes = readFileSync(join(f.options.outputDirectory, entry.path));
    assert.equal(entry.bytes, bytes.length); assert.equal(entry.sha256, hash(bytes));
  }
  assert.equal(lstatSync(f.options.outputDirectory).mode & 0o7777, 0o700);
  for (const name of readdirSync(f.options.outputDirectory)) assert.equal(lstatSync(join(f.options.outputDirectory, name)).mode & 0o7777, 0o600);
});

function signingOptions(f) {
  const sparkleSeedPath = join(f.root, 'ephemeral-sparkle-seed');
  const seed = f.sparkle.privateKey.export({ format: 'der', type: 'pkcs8' }).subarray(-32);
  writeFileSync(sparkleSeedPath, seed.toString('base64') + '\n', { mode: 0o600 });
  return { ...f.options, sparkleSeedPath };
}

test('protected signing produces a canonical feed and verifies publicly after the seed is absent', async t => {
  const f = fixture(t), options = signingOptions(f);
  await signMacChannels(options);
  const output = options.outputDirectory, feed = readFileSync(join(output, 'appcast.xml'));
  const body = verifySparkleFeed(feed, f.publicKey);
  assert.ok(body.toString().includes('<sparkle:version>1.2.3</sparkle:version>'));
  assert.equal(JSON.parse(readFileSync(join(output, 'channels.json'))).feedSignatureVerified, true);
  const before = lstatSync(join(output, 'appcast.xml'), { bigint: true });
  assert.equal((await signMacChannels(options)).disposition, 'retained-bytes-verified');
  assert.equal(lstatSync(join(output, 'appcast.xml'), { bigint: true }).mtimeNs, before.mtimeNs);
  const signedOutput = join(f.root, 'cli-signed');
  const signingArgs = [options.manifestPath, options.signaturePath, options.publicKeyPath, options.artifactDirectory,
    options.releaseTrustPath, options.minimumOS, options.sparkleSeedPath, options.sparkleTrustPath, signedOutput];
  const signed = spawnSync(process.execPath, [join(import.meta.dirname, 'channels-sign-cli.mjs'), ...signingArgs],
    { encoding: 'utf8', timeout: 5000, maxBuffer: 1024 });
  assert.equal(signed.status, 0, signed.stderr); assert.equal(signed.stderr, '');
  assert.equal(signed.stdout, 'Signed Mac channel material: 1.2.3; local-material-created; publication authority none\n');
  assert.deepEqual(readFileSync(join(signedOutput, 'appcast.xml')), feed);
  rmSync(options.sparkleSeedPath);
  assert.equal((await verifyMacChannels(options)).disposition, 'signed-local-bytes-verified');
  const args = [options.manifestPath, options.signaturePath, options.publicKeyPath, options.artifactDirectory,
    options.releaseTrustPath, options.minimumOS, options.sparkleTrustPath, output];
  const verified = spawnSync(process.execPath, [join(import.meta.dirname, 'channels-verify-cli.mjs'), ...args],
    { encoding: 'utf8', timeout: 5000, maxBuffer: 1024 });
  assert.equal(verified.status, 0); assert.equal(verified.stderr, '');
  assert.equal(verified.stdout, 'Signed Mac channel material: 1.2.3; public-key-only bytes verified; publication authority none\n');
  assert.deepEqual(readFileSync(join(output, 'appcast.xml')), feed);
  assert.equal(lstatSync(join(output, 'appcast.xml'), { bigint: true }).ino, before.ino);
});

test('wrong seed, weak private modes and unsigned-to-signed replacement refuse without laundering material', async t => {
  const f = fixture(t), options = signingOptions(f);
  const correct = readFileSync(options.sparkleSeedPath);
  writeFileSync(options.sparkleSeedPath, Buffer.alloc(32, 42).toString('base64'));
  await assert.rejects(signMacChannels(options)); assert.equal(readdirSync(f.root).includes('output'), false);
  writeFileSync(options.sparkleSeedPath, correct); chmodSync(options.sparkleSeedPath, 0o644);
  await assert.rejects(signMacChannels(options)); assert.equal(readdirSync(f.root).includes('output'), false);
  chmodSync(options.sparkleSeedPath, 0o600);
  await deriveMacChannels(options);
  const unsigned = readFileSync(join(options.outputDirectory, 'appcast.xml'));
  await assert.rejects(signMacChannels(options)); await assert.rejects(verifyMacChannels(options));
  assert.deepEqual(readFileSync(join(options.outputDirectory, 'appcast.xml')), unsigned);
  const args = [options.manifestPath, options.signaturePath, options.publicKeyPath, options.artifactDirectory,
    options.releaseTrustPath, options.minimumOS, options.sparkleSeedPath, options.sparkleTrustPath, join(f.root, 'new-signed')];
  chmodSync(options.sparkleSeedPath, 0o644);
  const denied = spawnSync(process.execPath, [join(import.meta.dirname, 'channels-sign-cli.mjs'), ...args],
    { encoding: 'utf8', timeout: 5000, maxBuffer: 1024 });
  assert.equal(denied.status, 1); assert.equal(denied.stdout, ''); assert.equal(denied.stderr, 'Mac channel signing refused\n');
  assert.ok(!denied.stderr.includes(f.root));
});

test('signed body, footer length, namespace and record changes refuse even when a changed feed is authentically resigned', async t => {
  const f = fixture(t), options = signingOptions(f); await signMacChannels(options);
  const path = join(options.outputDirectory, 'appcast.xml'), original = readFileSync(path), body = verifySparkleFeed(original, f.publicKey);
  const changed = Buffer.from(body.toString().replace('15.0.0', '16.0.0'));
  for (const bytes of [Buffer.from(original.toString().replace('15.0.0', '16.0.0')),
    Buffer.from(original.toString().replace(`length: ${body.length}\n`, `length: ${body.length + 1}\n`)),
    Buffer.concat([original, Buffer.from('\n')]), body]) assert.throws(() => verifySparkleFeed(bytes, f.publicKey));
  const resigned = signSparkleFeed(changed, f.sparkle.privateKey, f.publicKey);
  assert.deepEqual(verifySparkleFeed(resigned, f.publicKey), changed);
  writeFileSync(path, resigned); await assert.rejects(verifyMacChannels(options));
  assert.deepEqual(readFileSync(path), resigned); writeFileSync(path, original);
  await assert.rejects(verifyMacChannels({ ...options, minimumOS: '16.0.0' }));
  const recordPath = join(options.outputDirectory, 'channels.json'), record = JSON.parse(readFileSync(recordPath));
  record.declaredMinimumOS = '16.0.0'; writeFileSync(recordPath, JSON.stringify(record) + '\n');
  await assert.rejects(verifyMacChannels(options)); assert.equal(JSON.parse(readFileSync(recordPath)).declaredMinimumOS, '16.0.0');
});

test('real Ruby and XML parsers preserve quoted URL semantics', { skip: process.platform !== 'darwin' }, async t => {
  const f = fixture(t, "https://example.test/releases/a'b&c/v1.2.3/Frameshift-1.2.3.dmg");
  await deriveMacChannels(f.options);
  const cask = join(f.options.outputDirectory, 'frameshift.rb'), feed = join(f.options.outputDirectory, 'appcast.xml');
  const syntax = spawnSync('/usr/bin/ruby', ['-c', cask], { encoding: 'utf8', timeout: 5000 });
  assert.equal(syntax.status, 0, syntax.stderr);
  const ruby = spawnSync('/usr/bin/ruby', ['-e', 'def cask(_); yield; end; def url(value); puts value; end; def method_missing(*); end; load ARGV[0]', cask],
    { encoding: 'utf8', timeout: 5000 });
  assert.equal(ruby.status, 0, ruby.stderr); assert.equal(ruby.stdout, f.artifact.url + '\n');
  const parsed = spawnSync('/usr/bin/xmllint', ['--nonet', '--xpath', 'string(//*[local-name()="enclosure"]/@url)', feed],
    { encoding: 'utf8', timeout: 5000 });
  assert.equal(parsed.status, 0, parsed.stderr); assert.equal(parsed.stdout.trim(), f.artifact.url);
  const signedOptions = { ...signingOptions(f), outputDirectory: join(f.root, 'signed-output') };
  await signMacChannels(signedOptions);
  const signedXML = spawnSync('/usr/bin/xmllint', ['--nonet', '--noout', join(signedOptions.outputDirectory, 'appcast.xml')],
    { encoding: 'utf8', timeout: 5000 });
  assert.equal(signedXML.status, 0, signedXML.stderr);
});

test('signature checks bind full archive bytes to the independent Sparkle trust root', async t => {
  const f = fixture(t);
  writeFileSync(f.options.sparkleSignaturePath, sign(null, f.archive, f.release.privateKey).toString('base64'));
  await assert.rejects(deriveMacChannels(f.options)); assert.equal(readdirSync(f.root).includes('output'), false);
  assert.throws(() => verifySparkleArchive(f.archive, sign(null, Buffer.from(hash(f.archive)), f.sparkle.privateKey), f.publicKey));
  writeFileSync(f.options.sparkleSignaturePath, sign(null, f.archive, f.sparkle.privateKey).toString('base64'));
  writeFileSync(f.archivePath, Buffer.alloc(f.archive.length, 42));
  await assert.rejects(deriveMacChannels(f.options)); assert.equal(readdirSync(f.root).includes('output'), false);
  writeFileSync(f.archivePath, f.archive);
  writeFileSync(f.options.releaseTrustPath, hash('untrusted'));
  await assert.rejects(deriveMacChannels(f.options));
});

test('canonical base64, public-key custody and regular input admission refuse before output', async t => {
  const f = fixture(t), signature = readFileSync(f.options.sparkleSignaturePath), trust = readFileSync(f.options.sparkleTrustPath);
  for (const value of ['!', signature.toString().trim() + '\r\n', signature.toString().trim().slice(0, -1), 'x'.repeat(90)]) {
    writeFileSync(f.options.sparkleSignaturePath, value); await assert.rejects(deriveMacChannels(f.options));
  }
  writeFileSync(f.options.sparkleSignaturePath, signature);
  chmodSync(f.options.sparkleTrustPath, 0o666); await assert.rejects(deriveMacChannels(f.options)); chmodSync(f.options.sparkleTrustPath, 0o600);
  rmSync(f.options.sparkleTrustPath); symlinkSync(f.options.publicKeyPath, f.options.sparkleTrustPath);
  await assert.rejects(deriveMacChannels(f.options)); rmSync(f.options.sparkleTrustPath); writeFileSync(f.options.sparkleTrustPath, trust, { mode: 0o600 });
  rmSync(f.archivePath); mkdirSync(f.archivePath); await assert.rejects(deriveMacChannels(f.options));
  assert.equal(readdirSync(f.root).includes('output'), false);
});

test('minimum declaration, missing target and archive/URL bounds refuse without claims', async t => {
  const f = fixture(t);
  for (const minimumOS of ['14.0', '13.9.0', '014.0.0', '14.256.0', '65536.0.0', '14.0.0\n']) {
    await assert.rejects(deriveMacChannels({ ...f.options, minimumOS }));
  }
  f.artifact.bytes = 1024 * 1024 * 1024 + 1; f.refresh(); await assert.rejects(deriveMacChannels(f.options));
  f.artifact.bytes = f.archive.length;
  f.artifact.url = 'https://example.test/' + 'a'.repeat(2048) + '/v1.2.3/' + f.artifact.file;
  f.refresh(); await assert.rejects(deriveMacChannels(f.options));
  f.manifest.artifacts = [{ ...f.artifact, platform: 'ubuntu', architecture: 'arm64', format: 'deb',
    file: 'Frameshift-1.2.3.deb', url: 'https://example.test/v1.2.3/Frameshift-1.2.3.deb' }];
  f.refresh(); await assert.rejects(deriveMacChannels(f.options));
  assert.equal(readdirSync(f.root).includes('output'), false);
});

test('complete replay preserves files and conflicting declarations retain accepted bytes', async t => {
  const f = fixture(t); await deriveMacChannels(f.options);
  const before = readdirSync(f.options.outputDirectory).map(name => ({ name,
    stat: lstatSync(join(f.options.outputDirectory, name), { bigint: true }), bytes: readFileSync(join(f.options.outputDirectory, name)) }));
  assert.equal((await deriveMacChannels(f.options)).disposition, 'retained-bytes-verified');
  await assert.rejects(deriveMacChannels({ ...f.options, minimumOS: '16.0.0' }));
  for (const entry of before) {
    const path = join(f.options.outputDirectory, entry.name), after = lstatSync(path, { bigint: true });
    assert.equal(after.ino, entry.stat.ino); assert.equal(after.mtimeNs, entry.stat.mtimeNs); assert.deepEqual(readFileSync(path), entry.bytes);
  }
  writeFileSync(join(f.options.outputDirectory, 'appcast.xml'), 'changed');
  await assert.rejects(deriveMacChannels(f.options)); assert.equal(readFileSync(join(f.options.outputDirectory, 'appcast.xml'), 'utf8'), 'changed');
});

test('partial, unknown and unsafe output custody is preserved', async t => {
  const f = fixture(t); mkdirSync(f.options.outputDirectory, { mode: 0o700 });
  writeFileSync(join(f.options.outputDirectory, 'build.pending'), 'interrupted', { mode: 0o600 });
  await assert.rejects(deriveMacChannels(f.options));
  assert.equal(readFileSync(join(f.options.outputDirectory, 'build.pending'), 'utf8'), 'interrupted');
  rmSync(f.options.outputDirectory, { recursive: true });
  const retained = join(f.root, 'retained'); mkdirSync(retained, { mode: 0o700 }); writeFileSync(join(retained, 'sentinel'), 'preserved');
  symlinkSync(retained, f.options.outputDirectory); await assert.rejects(deriveMacChannels(f.options));
  assert.equal(readFileSync(join(retained, 'sentinel'), 'utf8'), 'preserved'); rmSync(f.options.outputDirectory);
  chmodSync(f.root, 0o777); await assert.rejects(deriveMacChannels(f.options)); chmodSync(f.root, 0o700);
  assert.equal(readdirSync(f.root).includes('output'), false);
});

test('CLI refuses a FIFO and sanitizes paths and crypto errors within a bounded process', t => {
  const f = fixture(t), fifo = join(f.root, 'private-sentinel-fifo');
  assert.equal(spawnSync('mkfifo', [fifo], { timeout: 5000 }).status, 0);
  const args = [f.options.manifestPath, f.options.signaturePath, f.options.publicKeyPath, f.options.artifactDirectory,
    f.options.releaseTrustPath, f.options.minimumOS, fifo, f.options.sparkleTrustPath, f.options.outputDirectory];
  const run = spawnSync(process.execPath, [join(import.meta.dirname, 'channels-cli.mjs'), ...args],
    { encoding: 'utf8', timeout: 5000, maxBuffer: 1024 });
  assert.equal(run.status, 1); assert.equal(run.stdout, ''); assert.equal(run.stderr, 'Mac channel material refused\n');
  assert.ok(!run.stderr.includes(f.root)); assert.equal(readdirSync(f.root).includes('output'), false);
});
