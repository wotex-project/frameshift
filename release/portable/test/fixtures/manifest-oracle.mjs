// Temporary test-only comparison owner; no production portable caller imports Node.
import { createHash, createPublicKey, generateKeyPairSync, sign, verify } from 'node:crypto';
import { readFileSync } from 'node:fs';
import { parseManifest } from '../../../manifest.mjs';

if (process.versions.node !== '26.9.0') throw new Error('fixture needs pinned Node');
if (process.argv[2] === 'verify') {
  const item = JSON.parse(readFileSync(process.argv[3], 'utf8'));
  const key = createPublicKey(item.pem);
  if (!verify(null, Buffer.from(item.message, 'base64'), key, Buffer.from(item.signature, 'base64'))) process.exit(1);
  process.stdout.write('verified\n');
} else {
  const archive = Buffer.from('exact local fixture installer');
  const base = { schemaVersion: 1, product: 'io.frameshift.app', version: '1.2.3', artifacts: [{
    platform: 'macos', architecture: 'universal', format: 'dmg', file: 'Frameshift-1.2.3.dmg',
    url: 'https://example.invalid/v1.2.3/Frameshift-1.2.3.dmg', bytes: archive.length,
    sha256: createHash('sha256').update(archive).digest('hex') }] };
  const cases = [];
  const add = (label, value) => {
    const bytes = Buffer.isBuffer(value) ? value : Buffer.from(JSON.stringify(value) + '\n');
    let accepted = false;
    try { parseManifest(bytes); accepted = true; } catch {}
    cases.push({ label, message: bytes.toString('base64'), accepted });
  };
  const url = (label, value) => add(label, { ...base, artifacts: [{ ...base.artifacts[0], url: value }] });
  add('base', base);
  add('reordered', { artifacts: [Object.fromEntries(Object.entries(base.artifacts[0]).reverse())], version: '1.2.3', product: base.product, schemaVersion: 1 });
  for (const host of ['.', '..', 'xn--', 'xn--abc', 'xn--foo-', 'foo..bar', '_example.com', '-x.com',
    'a,b.com', 'a"b.com', '123.abc', 'a.1', 'foo.0x', 'foo.0xff', 'foo.0xg', '127.0.0.1',
    '127.0.0.1.', '127.1', '0177.0.0.1', '256.0.0.1', '0x7f000001', '123...',
    '[::]', '[::1]', '[0:0:0:0:0:0:0:1]', '[::ffff:192.0.2.1]', '[::ffff:c000:201]',
    '[1:0:0:2:0:0:3:4]', '[1::2:0:0:3:4]', '[2001:db8:1:2:3:4:5:6]', '[2001:DB8::1]',
    'EXAMPLE.com', 'example.com:443', 'example.com:444', 'user@example.com', 'münchen.de',
    'xn-' + 'a'.repeat(16382), 'a'.repeat(20000)]) {
    url(`host:${host.slice(0, 50)}`, `https://${host}/v1.2.3/Frameshift-1.2.3.dmg`);
  }
  for (let code = 0; code <= 127; code++) {
    const char = String.fromCharCode(code);
    url(`host-byte:${code}`, `https://a${char}b.invalid/v1.2.3/Frameshift-1.2.3.dmg`);
    url(`path-byte:${code}`, `https://example.invalid/a${char}b/v1.2.3/Frameshift-1.2.3.dmg`);
  }
  for (const suffix of ['?', '#', '?#', '#?', '?x', '#x', '?x#', '##']) url(`delimiter:${suffix}`, base.artifacts[0].url + suffix);
  for (const prefix of ['/latest', '/LATEST', '/a/../', '/a/./', '/a//', '/%61', '/a{b}', '/a^b'])
    url(`prefix:${prefix}`, 'https://example.invalid' + prefix + '/v1.2.3/Frameshift-1.2.3.dmg');
  for (const change of [{ schemaVersion: true }, { schemaVersion: 1.0, product: 'wrong' }, { version: '01.2.3' },
    { version: '1.2.3-beta' }, { artifacts: [] }, { artifacts: [base.artifacts[0], base.artifacts[0]] }, { extra: null }]) add('schema', { ...base, ...change });
  for (const change of [{ bytes: true }, { bytes: 0 }, { bytes: 8589934593 }, { bytes: 1.5 }, { sha256: 'A'.repeat(64) },
    { file: '../Frameshift-1.2.3.dmg' }, { architecture: 'arm64' }, { format: 'zip' }]) add('artifact', { ...base, artifacts: [{ ...base.artifacts[0], ...change }] });
  const body = JSON.stringify(base);
  for (const text of [body, body + '\n\n', ' ' + body + '\n', body.replace('"schemaVersion":1', '"schemaVersion":1,"schemaVersion":1') + '\n',
    body.replace('"schemaVersion":1', '"schemaVersion":1.0') + '\n', body.replace('io.frameshift', '\\u0069o.frameshift') + '\n']) add('encoding', Buffer.from(text));
  add('utf8', Buffer.from([0xff, 10]));
  const { publicKey, privateKey } = generateKeyPairSync('ed25519');
  const message = Buffer.from(body + '\n');
  process.stdout.write(JSON.stringify({ cases, base, archive: archive.toString('base64'), message: message.toString('base64'),
    signature: sign(null, message, privateKey).toString('base64'), pem: publicKey.export({ type: 'spki', format: 'pem' }),
    fingerprint: createHash('sha256').update(publicKey.export({ type: 'spki', format: 'der' })).digest('hex') }) + '\n');
}
