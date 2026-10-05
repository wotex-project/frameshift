import { createHash, createPublicKey, verify } from 'node:crypto';
import { constants, closeSync, fsyncSync, lstatSync, mkdirSync, openSync, readdirSync, realpathSync, unlinkSync, writeFileSync } from 'node:fs';
import { basename, dirname, join, resolve } from 'node:path';
import { hashReleaseArchive, readPinnedFingerprint, readReleaseInput, withReleaseInput } from '../files.mjs';
import { verifyManifestSignature } from '../manifest.mjs';
import { versionNumber } from './closure.mjs';

const maximum = 1024 * 1024 * 1024;
const digest = bytes => createHash('sha256').update(bytes).digest('hex');
const encode = value => Buffer.from(JSON.stringify(value) + '\n');
const refuse = () => { throw new Error('Mac channel material refused'); };
const spkiPrefix = Buffer.from('302a300506032b6570032100', 'hex');

function base64(bytes, length) {
  const text = new TextDecoder('utf-8', { fatal: true }).decode(bytes);
  const value = text.endsWith('\n') ? text.slice(0, -1) : text;
  const decoded = Buffer.from(value, 'base64');
  if (decoded.length !== length || decoded.toString('base64') !== value) refuse();
  return decoded;
}

// Sparkle 2.10.0 signs ordinary Ed25519 over the full archive, not its SHA-256.
// The key is independently configured raw public bytes, never a manifest field.
export function verifySparkleArchive(bytes, signature, publicKey) {
  if (!Buffer.isBuffer(bytes) || bytes.length < 1 || bytes.length > maximum ||
      !Buffer.isBuffer(signature) || signature.length !== 64 ||
      !Buffer.isBuffer(publicKey) || publicKey.length !== 32) refuse();
  const key = createPublicKey({ key: Buffer.concat([spkiPrefix, publicKey]), format: 'der', type: 'spki' });
  if (!verify(null, bytes, key, signature)) refuse();
}

const ruby = text => "'" + text.replaceAll('\\', '\\\\').replaceAll("'", "\\'") + "'";
const xml = text => text.replaceAll('&', '&amp;').replaceAll('"', '&quot;')
  .replaceAll('<', '&lt;').replaceAll('>', '&gt;').replaceAll("'", '&apos;');

async function inputs(options) {
  if (typeof options.minimumOS !== 'string' || !/^(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)$/.test(options.minimumOS) ||
      versionNumber(options.minimumOS) < versionNumber('14.0.0')) refuse();
  const trustedKeyDigest = await readPinnedFingerprint(options.releaseTrustPath);
  const manifest = await verifyManifestSignature({ ...options, trustedKeyDigest });
  const artifact = manifest.artifacts.find(entry => entry.platform === 'macos');
  if (!artifact || artifact.architecture !== 'universal' || artifact.format !== 'dmg' || artifact.bytes > maximum ||
      Buffer.byteLength(artifact.url) > 2048) refuse();
  const publicKey = base64(await readReleaseInput(options.sparkleTrustPath,
    { minimum: 44, maximum: 45, protectedTrust: true }), 32);
  const signature = base64(await readReleaseInput(options.sparkleSignaturePath,
    { minimum: 88, maximum: 89 }), 64);
  const archivePath = join(options.artifactDirectory, artifact.file);
  await withReleaseInput(archivePath, { maximum, budgetMs: 120_000 }, async (handle, size, budget) => {
    if (size !== artifact.bytes) refuse();
    const bytes = Buffer.alloc(size);
    for (let offset = 0; offset < size;) {
      budget();
      const { bytesRead } = await handle.read(bytes, offset, Math.min(64 * 1024, size - offset), offset);
      if (!bytesRead) refuse();
      offset += bytesRead;
    }
    if ((await handle.read(Buffer.alloc(1), 0, 1, size)).bytesRead || digest(bytes) !== artifact.sha256) refuse();
    verifySparkleArchive(bytes, signature, publicKey);
    budget();
  });
  const cask = `cask "frameshift" do\n  version ${ruby(manifest.version)}\n  sha256 ${ruby(artifact.sha256)}\n\n  url ${ruby(artifact.url)}\n  name "Frameshift"\n  desc "Still artwork for digital art displays"\n  homepage "https://frameshift.wotex.io/"\n\n  auto_updates true\n  depends_on macos: ${ruby('>= ' + options.minimumOS)}\n\n  app "Frameshift.app"\nend\n`;
  const appcast = `<?xml version="1.0" encoding="UTF-8"?>\n<rss version="2.0" xmlns:sparkle="http://www.andymatuschak.org/xml-namespaces/sparkle">\n  <channel>\n    <title>Frameshift updates</title>\n    <link>https://frameshift.wotex.io/</link>\n    <description>Frameshift releases</description>\n    <item>\n      <title>Frameshift ${xml(manifest.version)}</title>\n      <link>https://frameshift.wotex.io/download/</link>\n      <sparkle:version>${xml(manifest.version)}</sparkle:version>\n      <sparkle:shortVersionString>${xml(manifest.version)}</sparkle:shortVersionString>\n      <sparkle:minimumSystemVersion>${options.minimumOS}</sparkle:minimumSystemVersion>\n      <enclosure url="${xml(artifact.url)}" length="${artifact.bytes}" type="application/octet-stream" sparkle:edSignature="${signature.toString('base64')}" />\n    </item>\n  </channel>\n</rss>\n`;
  const files = { 'frameshift.rb': Buffer.from(cask), 'appcast.xml': Buffer.from(appcast) };
  const record = { schemaVersion: 1, kind: 'macos-channel-material', product: manifest.product,
    publicationAuthority: 'none', version: manifest.version, declaredMinimumOS: options.minimumOS,
    qualificationRequired: ['final-app-and-updater', 'minimum-os', 'developer-id-and-notarization', 'installed-update', 'public-archive', 'publisher-rights'],
    releaseKeySha256: trustedKeyDigest, sparkleKeySha256: digest(publicKey),
    manifestSha256: digest(await readReleaseInput(options.manifestPath, { maximum: 64 * 1024 })),
    artifact, files: Object.entries(files).map(([path, bytes]) => ({ path, bytes: bytes.length, sha256: digest(bytes) })) };
  if (Object.values(files).concat(encode(record)).some(bytes => bytes.length > 16 * 1024)) refuse();
  return { archivePath, artifact, files: { ...files, 'channels.json': encode(record) }, record };
}

function directory(path, privateMode) {
  const stat = lstatSync(path);
  if (!stat.isDirectory() || stat.uid !== process.getuid() ||
      (stat.mode & (privateMode ? 0o7777 : 0o7022)) !== (privateMode ? 0o700 : 0)) refuse();
  return stat;
}
function sync(path) {
  const fd = openSync(path, constants.O_RDONLY | constants.O_NOFOLLOW | constants.O_NONBLOCK);
  try { fsyncSync(fd); } finally { closeSync(fd); }
}
async function retained(output, files, pending = false) {
  const before = directory(output, true);
  const names = Object.keys(files).concat(pending ? ['build.pending'] : []).sort();
  if (JSON.stringify(readdirSync(output).sort()) !== JSON.stringify(names)) refuse();
  for (const [name, bytes] of Object.entries(files)) {
    if (!(await readReleaseInput(join(output, name), { maximum: 16 * 1024, privateKey: true })).equals(bytes)) refuse();
  }
  if (pending && !(await readReleaseInput(join(output, 'build.pending'), { maximum: 128, privateKey: true }))
    .equals(Buffer.from('incomplete Mac channel material\n'))) refuse();
  const after = directory(output, true);
  if (before.dev !== after.dev || before.ino !== after.ino ||
      JSON.stringify(readdirSync(output).sort()) !== JSON.stringify(names)) refuse();
}

export async function deriveMacChannels(options) {
  const material = await inputs(options);
  const requested = resolve(options.outputDirectory);
  const parent = dirname(requested), before = directory(parent, false);
  const output = join(realpathSync(parent), basename(requested));
  if (/[\u0000-\u001f\u007f]/.test(output)) refuse();
  let exists = false;
  try { lstatSync(output); exists = true; } catch (error) { if (error.code !== 'ENOENT') throw error; }
  if (!exists) mkdirSync(output, { mode: 0o700 });
  const original = directory(output, true);
  if (exists) await retained(output, material.files);
  else {
    writeFileSync(join(output, 'build.pending'), 'incomplete Mac channel material\n', { flag: 'wx', mode: 0o600 });
    sync(join(output, 'build.pending')); sync(output); sync(parent);
    for (const [name, bytes] of Object.entries(material.files)) {
      writeFileSync(join(output, name), bytes, { flag: 'wx', mode: 0o600 }); sync(join(output, name));
    }
    await retained(output, material.files, true);
  }
  const final = await inputs(options), after = directory(parent, false);
  if (!encode(final.record).equals(encode(material.record)) || before.dev !== after.dev || before.ino !== after.ino ||
      JSON.stringify(await hashReleaseArchive(material.archivePath)) !== JSON.stringify({ bytes: material.artifact.bytes, sha256: material.artifact.sha256 })) refuse();
  await retained(output, material.files, !exists);
  const current = directory(output, true);
  if (original.dev !== current.dev || original.ino !== current.ino) refuse();
  if (!exists) { sync(output); unlinkSync(join(output, 'build.pending')); sync(output); sync(parent); }
  return { version: material.record.version, publicationAuthority: 'none',
    disposition: exists ? 'retained-bytes-verified' : 'local-material-created' };
}
