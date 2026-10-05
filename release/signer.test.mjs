import assert from 'node:assert/strict';
import { execFileSync } from 'node:child_process';
import { createHash, generateKeyPairSync } from 'node:crypto';
import { chmod, lstat, mkdir, mkdtemp, readFile, rm, symlink, writeFile } from 'node:fs/promises';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import test from 'node:test';
import { verifyRelease } from './manifest.mjs';
import { parsePlan, signRelease } from './signer.mjs';

const digest = bytes => createHash('sha256').update(bytes).digest('hex');

function planFor() {
  return {
    schemaVersion: 1, product: 'io.frameshift.app', version: '1.2.3',
    artifacts: [{ platform: 'macos', architecture: 'universal', format: 'dmg',
      file: 'Frameshift-1.2.3.dmg',
      url: 'https://example.com/releases/v1.2.3/Frameshift-1.2.3.dmg' }],
  };
}

async function fixture(t) {
  const root = await mkdtemp(join(tmpdir(), 'frameshift-signer-'));
  t.after(() => rm(root, { recursive: true, force: true }));
  const artifactDirectory = join(root, 'artifacts');
  await mkdir(artifactDirectory);
  const planPath = join(root, 'plan.json');
  const privateKeyPath = join(root, 'owner.pem');
  const artifactPath = join(artifactDirectory, 'Frameshift-1.2.3.dmg');
  const { publicKey, privateKey } = generateKeyPairSync('ed25519');
  const trustedKeyDigest = digest(publicKey.export({ type: 'spki', format: 'der' }));
  await writeFile(planPath, JSON.stringify(planFor()) + '\n');
  await writeFile(artifactPath, Buffer.from('fixture DMG bytes'));
  await writeFile(privateKeyPath, privateKey.export({ type: 'pkcs8', format: 'pem' }),
    { mode: 0o600 });
  return { root, artifactDirectory, planPath, privateKeyPath,
    artifactPath, trustedKeyDigest };
}

test('signer derives exact bytes, self-verifies, and reproduces detached output', async t => {
  const options = await fixture(t);
  const first = join(options.root, 'signed-one');
  const second = join(options.root, 'signed-two');
  assert.deepEqual(await signRelease({ ...options, outputDirectory: first }),
    { version: '1.2.3', artifactCount: 1 });
  await signRelease({ ...options, outputDirectory: second });
  for (const file of ['manifest.json', 'manifest.sig', 'release.pub.pem']) {
    assert.deepEqual(await readFile(join(first, file)), await readFile(join(second, file)));
    assert.equal((await lstat(join(first, file))).mode & 0o777, 0o600);
  }
  assert.equal((await lstat(first)).mode & 0o777, 0o700);
  const verified = await verifyRelease({ manifestPath: join(first, 'manifest.json'),
    signaturePath: join(first, 'manifest.sig'), publicKeyPath: join(first, 'release.pub.pem'),
    trustedKeyDigest: options.trustedKeyDigest, artifactDirectory: options.artifactDirectory });
  assert.equal(verified.artifacts[0].sha256, digest('fixture DMG bytes'));
  await assert.rejects(signRelease({ ...options, outputDirectory: first }), /EEXIST/);
});

test('signer refuses unpinned keys, weak key permissions, unsafe parents, and links', async t => {
  const options = await fixture(t);
  const outputDirectory = join(options.root, 'signed');
  await assert.rejects(signRelease({ ...options, trustedKeyDigest: digest('wrong'),
    outputDirectory }), /owner-pinned/);
  await chmod(options.privateKeyPath, 0o644);
  await assert.rejects(signRelease({ ...options, outputDirectory }), /unsafe release private key/);
  await chmod(options.privateKeyPath, 0o600);
  await chmod(options.root, 0o777);
  await assert.rejects(signRelease({ ...options, outputDirectory }), /unsafe release output parent/);
  await chmod(options.root, 0o700);
  await rm(options.artifactPath);
  await symlink(options.planPath, options.artifactPath);
  await assert.rejects(signRelease({ ...options, outputDirectory }));
  await assert.rejects(lstat(outputDirectory), /ENOENT/);
});

test('signer bounds the plan file before reading it', async t => {
  const options = await fixture(t);
  await writeFile(options.planPath, Buffer.alloc(64 * 1024 + 1));
  await assert.rejects(signRelease({ ...options, outputDirectory: join(options.root, 'signed') }),
    /invalid release input size/);
  assert.throws(() => parsePlan(Buffer.alloc(64 * 1024 + 1)), /invalid release plan size/);
});

test('signing CLI accepts the pinned trust file and emits verifiable artifacts', async t => {
  const options = await fixture(t);
  const trustPath = join(options.root, 'trusted.sha256');
  const outputDirectory = join(options.root, 'signed-cli');
  await writeFile(trustPath, options.trustedKeyDigest + '\n');
  const output = execFileSync(process.execPath, [join(import.meta.dirname, 'sign.mjs'),
    options.planPath, options.artifactDirectory, options.privateKeyPath,
    trustPath, outputDirectory], { encoding: 'utf8' });
  assert.match(output, /^signed 1\.2\.3: 1 exact artifacts\n$/);
  const verified = await verifyRelease({ manifestPath: join(outputDirectory, 'manifest.json'),
    signaturePath: join(outputDirectory, 'manifest.sig'),
    publicKeyPath: join(outputDirectory, 'release.pub.pem'),
    trustedKeyDigest: options.trustedKeyDigest, artifactDirectory: options.artifactDirectory });
  assert.equal(verified.version, '1.2.3');
});

test('plan parser refuses duplicate members and incomplete artifact identity', () => {
  const plan = planFor();
  assert.deepEqual(parsePlan(Buffer.from(JSON.stringify(plan) + '\n')), plan);
  const duplicate = JSON.stringify(plan).replace('"version":"1.2.3",',
    '"version":"1.2.3","version":"1.2.3",') + '\n';
  assert.throws(() => parsePlan(Buffer.from(duplicate)), /encoding/);
  assert.throws(() => parsePlan(Buffer.from(JSON.stringify({ ...plan, artifacts: [{
    ...plan.artifacts[0], bytes: 1,
  }] }) + '\n')), /fields/);
});
