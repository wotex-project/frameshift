import assert from 'node:assert/strict';
import { createHash, generateKeyPairSync, sign } from 'node:crypto';
import { execFileSync, spawnSync } from 'node:child_process';
import { mkdtempSync, readFileSync, rmSync, symlinkSync, writeFileSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join, resolve } from 'node:path';

const root = resolve(import.meta.dirname, '../../..');
const directory = mkdtempSync(join(tmpdir(), 'frameshift-guide-release-'));
const names = [
  'FRAMESHIFT_RELEASE_MANIFEST', 'FRAMESHIFT_RELEASE_SIGNATURE',
  'FRAMESHIFT_RELEASE_PUBLIC_KEY', 'FRAMESHIFT_RELEASE_ARTIFACT_DIR',
  'FRAMESHIFT_RELEASE_TRUST_FILE',
];
const cleanEnv = { ...process.env };
for (const name of names) delete cleanEnv[name];
const digest = (bytes) => createHash('sha256').update(bytes).digest('hex');
const build = (env) => execFileSync(process.execPath, ['apps/guide/build.mjs'], {
  cwd: root, env, stdio: 'pipe',
});

try {
  const bytes = Buffer.from('synthetic release fixture');
  const file = 'Frameshift-1.2.3.dmg';
  writeFileSync(join(directory, file), bytes);
  const manifest = {
    schemaVersion: 1, product: 'io.frameshift.app', version: '1.2.3',
    artifacts: [{ platform: 'macos', architecture: 'universal', format: 'dmg',
      file, url: `https://example.com/releases/v1.2.3/${file}`,
      bytes: bytes.length, sha256: digest(bytes) }],
  };
  const encoded = Buffer.from(JSON.stringify(manifest) + '\n');
  const { publicKey, privateKey } = generateKeyPairSync('ed25519');
  writeFileSync(join(directory, 'manifest.json'), encoded);
  writeFileSync(join(directory, 'manifest.sig'), sign(null, encoded, privateKey));
  writeFileSync(join(directory, 'public.pem'), publicKey.export({ type: 'spki', format: 'pem' }));
  writeFileSync(join(directory, 'trusted.sha256'),
    digest(publicKey.export({ type: 'spki', format: 'der' })) + '\n');
  const env = {
    ...cleanEnv,
    FRAMESHIFT_RELEASE_MANIFEST: join(directory, 'manifest.json'),
    FRAMESHIFT_RELEASE_SIGNATURE: join(directory, 'manifest.sig'),
    FRAMESHIFT_RELEASE_PUBLIC_KEY: join(directory, 'public.pem'),
    FRAMESHIFT_RELEASE_ARTIFACT_DIR: directory,
    FRAMESHIFT_RELEASE_TRUST_FILE: join(directory, 'trusted.sha256'),
  };
  build(env);
  const htmlPath = join(root, 'apps/guide/dist/index.html');
  const html = readFileSync(htmlPath, 'utf8');
  assert.match(html, /Verified host release 1\.2\.3/);
  assert.match(html, /macOS universal installer/);
  assert.doesNotMatch(html, /Installation artifacts are not yet available/);
  const refused = spawnSync(process.execPath, ['apps/guide/build.mjs'], {
    cwd: root, env: { ...env, FRAMESHIFT_RELEASE_SIGNATURE: '' }, encoding: 'utf8',
  });
  assert.notEqual(refused.status, 0);
  assert.match(refused.stderr, /Incomplete signed release inputs/);
  assert.match(readFileSync(htmlPath, 'utf8'), /Verified host release 1\.2\.3/);
  for (const kind of ['alias', 'fifo', 'oversized']) {
    const path = join(directory, `invalid-trust-${kind}`);
    if (kind === 'alias') symlinkSync(join(directory, 'trusted.sha256'), path);
    else if (kind === 'fifo') execFileSync('mkfifo', [path]);
    else writeFileSync(path, Buffer.alloc(66));
    const invalid = spawnSync(process.execPath, ['apps/guide/build.mjs'], {
      cwd: root, env: { ...env, FRAMESHIFT_RELEASE_TRUST_FILE: path }, encoding: 'utf8', timeout: 2000, killSignal: 'SIGKILL'
    });
    assert.equal(invalid.error, undefined, `${kind} must refuse without a stalled reader`);
    assert.notEqual(invalid.status, 0);
    assert.equal(readFileSync(htmlPath, 'utf8'), html);
  }
  process.stdout.write('Signed fixture guide build, partial input and bounded trust refusal preserve previous output\n');
} finally {
  build(cleanEnv);
  rmSync(directory, { recursive: true, force: true });
}
