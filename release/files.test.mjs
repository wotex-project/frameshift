import assert from 'node:assert/strict';
import { execFileSync, spawnSync } from 'node:child_process';
import { createHash, generateKeyPairSync, sign } from 'node:crypto';
import { appendFile, chmod, mkdir, mkdtemp, readFile, rename, rm, symlink, writeFile } from 'node:fs/promises';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import test from 'node:test';
import { artifactFacts, parseManifest, verifyManifestSignature } from './manifest.mjs';
import { signRelease } from './signer.mjs';
import { readReleaseInput, withReleaseInput } from './files.mjs';

const digest = bytes => createHash('sha256').update(bytes).digest('hex');
async function fixture(t) {
  const root = await mkdtemp(join(tmpdir(), 'frameshift-release-custody-'));
  t.after(() => rm(root, { recursive: true, force: true }));
  const artifactDirectory = join(root, 'artifacts');
  await mkdir(artifactDirectory, { mode: 0o700 });
  const file = 'Frameshift-1.2.3.dmg';
  const bytes = Buffer.from('private synthetic release bytes');
  const artifact = { platform: 'macos', architecture: 'universal', format: 'dmg', file,
    url: `https://example.invalid/releases/v1.2.3/${file}`, bytes: bytes.length, sha256: digest(bytes) };
  const manifest = { schemaVersion: 1, product: 'io.frameshift.app', version: '1.2.3', artifacts: [artifact] };
  const { privateKey, publicKey } = generateKeyPairSync('ed25519');
  const manifestBytes = Buffer.from(JSON.stringify(manifest) + '\n');
  const options = { root, artifactDirectory, artifactPath: join(artifactDirectory, file), manifest,
    manifestPath: join(root, 'manifest.json'), signaturePath: join(root, 'manifest.sig'),
    publicKeyPath: join(root, 'release.pub.pem'), planPath: join(root, 'plan.json'),
    privateKeyPath: join(root, 'owner.pem'), trustPath: join(root, 'trust.sha256'),
    trustedKeyDigest: digest(publicKey.export({ type: 'spki', format: 'der' })), outputDirectory: join(root, 'signed') };
  const { bytes: _, sha256: __, ...planned } = artifact;
  await Promise.all([
    writeFile(options.artifactPath, bytes), writeFile(options.manifestPath, manifestBytes),
    writeFile(options.signaturePath, sign(null, manifestBytes, privateKey)),
    writeFile(options.publicKeyPath, publicKey.export({ type: 'spki', format: 'pem' })),
    writeFile(options.privateKeyPath, privateKey.export({ type: 'pkcs8', format: 'pem' }), { mode: 0o600 }),
    writeFile(options.trustPath, options.trustedKeyDigest + '\n'),
    writeFile(options.planPath, JSON.stringify({ ...manifest, artifacts: [planned] }) + '\n')
  ]);
  return options;
}

test('all signed metadata and signing inputs refuse symlink names rather than accepting target bytes', async t => {
  const f = await fixture(t);
  assert.deepEqual(await verifyManifestSignature(f), f.manifest);
  for (const key of ['manifestPath', 'signaturePath', 'publicKeyPath', 'planPath', 'privateKeyPath']) {
    const alias = join(f.root, `alias-${key}`);
    await symlink(f[key], alias);
    if (['planPath', 'privateKeyPath'].includes(key)) await assert.rejects(() => signRelease({ ...f, [key]: alias }));
    else await assert.rejects(() => verifyManifestSignature({ ...f, [key]: alias }));
  }
});

test('metadata bounds refuse before parsing and owner-private signing modes are exact', async t => {
  const f = await fixture(t);
  for (const [key, size, operation] of [
    ['manifestPath', 64 * 1024 + 1, verifyManifestSignature],
    ['signaturePath', 65, verifyManifestSignature],
    ['publicKeyPath', 16 * 1024 + 1, verifyManifestSignature],
    ['planPath', 64 * 1024 + 1, signRelease],
    ['privateKeyPath', 16 * 1024 + 1, signRelease]
  ]) {
    const before = await readFile(f[key]);
    const bytes = Buffer.alloc(size, 32); before.copy(bytes);
    await writeFile(f[key], bytes);
    await assert.rejects(() => operation(f), /release input/);
    await writeFile(f[key], before);
  }
  for (const mode of [0o000, 0o500, 0o700, 0o1600, 0o644]) {
    await chmod(f.privateKeyPath, mode);
    await assert.rejects(() => signRelease(f), mode === 0 ? /EACCES|private key/ : /private key/);
  }
  await chmod(f.privateKeyPath, 0o400);
  await signRelease(f);
  assert.deepEqual(await verifyManifestSignature({ ...f, manifestPath: join(f.outputDirectory, 'manifest.json'),
    signaturePath: join(f.outputDirectory, 'manifest.sig'), publicKeyPath: join(f.outputDirectory, 'release.pub.pem') }), f.manifest);
});

test('public verification admits only one canonical public Ed25519 SPKI block', async t => {
  const f = await fixture(t);
  const publicPEM = await readFile(f.publicKeyPath);
  const privatePEM = await readFile(f.privateKeyPath);
  const encoded = publicPEM.toString().split('\n')[1];
  const der = Buffer.from(encoded, 'base64');
  const alphabet = 'ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/';
  const index = alphabet.indexOf(encoded.at(-2));
  const noncanonical = encoded.slice(0, -2) + alphabet[index + 1] + '=';
  assert.deepEqual(Buffer.from(noncanonical, 'base64'), der);
  const pem = body => Buffer.from(`-----BEGIN PUBLIC KEY-----\n${body}\n-----END PUBLIC KEY-----\n`);
  const nullParameters = Buffer.concat([Buffer.from('302c300706032b65700500032100', 'hex'), der.subarray(12)]);
  assert.deepEqual(await verifyManifestSignature(f), f.manifest);
  for (const bytes of [privatePEM, Buffer.concat([publicPEM, publicPEM]),
    Buffer.concat([Buffer.from('extra content\n'), publicPEM]),
    Buffer.from(publicPEM.toString().replace('PUBLIC KEY', 'CERTIFICATE')),
    pem(noncanonical), pem(nullParameters.toString('base64')),
    pem(Buffer.concat([der, Buffer.from([0])]).toString('base64'))]) {
    await writeFile(f.publicKeyPath, bytes, { mode: 0o600 });
    await assert.rejects(() => verifyManifestSignature(f), /invalid release public key/);
  }
  await writeFile(f.publicKeyPath, publicPEM.toString().replaceAll('\n', '\r\n'));
  assert.deepEqual(await verifyManifestSignature(f), f.manifest);
});

function cli(f, signing) {
  const path = join(import.meta.dirname, signing ? 'sign.mjs' : 'verify.mjs');
  const args = signing ? [f.planPath, f.artifactDirectory, f.privateKeyPath, f.trustPath, f.outputDirectory] :
    [f.manifestPath, f.signaturePath, f.publicKeyPath, f.artifactDirectory, f.trustPath];
  return spawnSync(process.execPath, [path, ...args], { encoding: 'utf8', timeout: 2000, killSignal: 'SIGKILL' });
}
function refused(result, signing) {
  assert.equal(result.error, undefined, 'a nonregular input must not stall until the child deadline');
  assert.equal(result.status, 1);
  assert.equal(result.stdout, '');
  assert.equal(result.stderr, signing ? 'release signing refused: invalid input, trust or custody\n' :
    'release verification refused: invalid input, trust or custody\n');
}

test('every CLI input FIFO refuses promptly without a writer and sanitized diagnostics contain no private path', async t => {
  const f = await fixture(t);
  for (const key of ['manifestPath', 'signaturePath', 'publicKeyPath', 'trustPath', 'artifactPath', 'planPath', 'privateKeyPath']) {
    const before = await readFile(f[key]);
    await rm(f[key]);
    execFileSync('mkfifo', [f[key]]);
    refused(cli(f, ['planPath', 'privateKeyPath'].includes(key)), ['planPath', 'privateKeyPath'].includes(key));
    await rm(f[key]);
    await writeFile(f[key], before, { mode: key === 'privateKeyPath' ? 0o600 : 0o644 });
  }
});

test('fingerprint files accept only the exact independently pinned grammar and reject aliases', async t => {
  const f = await fixture(t);
  for (const value of [' ' + f.trustedKeyDigest, f.trustedKeyDigest + '\n\n', f.trustedKeyDigest.toUpperCase(), f.trustedKeyDigest + '\r\n']) {
    await writeFile(f.trustPath, value);
    refused(cli(f, false), false);
  }
  await writeFile(f.trustPath, f.trustedKeyDigest);
  assert.equal(cli(f, false).status, 0);
  await chmod(f.trustPath, 0o666);
  refused(cli(f, false), false);
  await chmod(f.trustPath, 0o644);
  const alias = join(f.root, 'trust-link');
  await symlink(f.trustPath, alias);
  refused(cli({ ...f, trustPath: alias }, false), false);
});

test('real opened descriptors refuse replaced names, growth, same-size mutation and changed modes', async t => {
  const f = await fixture(t);
  const bytes = await readFile(f.artifactPath);
  for (const mutation of ['replace', 'grow', 'overwrite', 'mode']) {
    await writeFile(f.artifactPath, bytes, { mode: 0o644 });
    await chmod(f.artifactPath, 0o644);
    await assert.rejects(() => withReleaseInput(f.artifactPath, { maximum: 1024 }, async (handle, size) => {
      const actual = Buffer.alloc(size);
      assert.equal((await handle.read(actual, 0, size, 0)).bytesRead, size);
      assert.deepEqual(actual, bytes);
      if (mutation === 'replace') {
        const replacement = join(f.artifactDirectory, 'replacement');
        await writeFile(replacement, bytes);
        await rename(replacement, f.artifactPath);
      } else if (mutation === 'grow') await appendFile(f.artifactPath, 'changed');
      else if (mutation === 'overwrite') await writeFile(f.artifactPath, Buffer.alloc(bytes.length, 65));
      else await chmod(f.artifactPath, 0o600);
      return actual;
    }), /changed while reading/);
  }
  for (const path of [f.artifactDirectory, '/dev/null']) {
    await assert.rejects(() => readReleaseInput(path, { maximum: 1024 }), /regular/);
  }
});

test('local archive input refuses special files, non-flat names and noncanonical digest strings', async t => {
  const f = await fixture(t);
  await assert.rejects(() => artifactFacts(f.artifactDirectory, '../manifest.json'));
  await assert.rejects(() => artifactFacts(f.artifactDirectory, '/dev/null'));
  await assert.rejects(() => artifactFacts(f.artifactDirectory, '.'));
  await assert.rejects(() => artifactFacts(f.artifactDirectory, 'Frameshift-1.2.3.dmg\n'));
  const alias = join(f.artifactDirectory, 'device');
  await symlink('/dev/null', alias);
  await assert.rejects(() => artifactFacts(f.artifactDirectory, 'device'));
  const malformed = { ...f.manifest, artifacts: [{ ...f.manifest.artifacts[0], sha256: f.manifest.artifacts[0].sha256 + '\n' }] };
  assert.throws(() => parseManifest(Buffer.from(JSON.stringify(malformed) + '\n')), /digest/);
});
