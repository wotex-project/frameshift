import assert from 'node:assert/strict';
import { execFileSync, spawnSync } from 'node:child_process';
import { chmodSync, existsSync, linkSync, lstatSync, mkdirSync, readFileSync, readdirSync, rmSync, writeFileSync } from 'node:fs';
import { join, resolve } from 'node:path';
import test from 'node:test';
import { gzipSync, gunzipSync } from 'node:zlib';
import { cargoArchiveParse, cargoSourceLock, checkCargoMaterial } from './cargo-material.mjs';
import { cargoFixture as fixture, hash } from './cargo-material-fixture.mjs';

const owner = resolve(new URL('..', import.meta.url).pathname);
function checksum(header) { header.fill(32, 148, 156); const value = header.reduce((n, byte) => n + byte, 0).toString(8).padStart(6, '0'); header.write(value + '\0 ', 148, 'ascii'); }
function changed(raw, change) { const tar = gunzipSync(raw); change(tar); checksum(tar.subarray(0, 512)); return gzipSync(tar); }
const parseBytes = (f, raw) => cargoArchiveParse({ ...f.package, checksum: hash(raw) }, raw);
test('actual Cargo package joins frozen lock and exact fetched sources with private unchanged CLI replay', async t => {
  const f = await fixture(t), result = await checkCargoMaterial(f), path = join(f.output, 'cargo-material.json'), before = lstatSync(path), value = JSON.parse(readFileSync(path));
  assert.equal(result.packages, 1); assert.equal(result.generatedCacheMarkers, 1); assert.equal(result.publicationAuthority, 'none'); assert.equal(value.packages[0].files.some(file => file.path === 'LICENSE'), true); assert.equal(value.localPackages.length, 2); assert.equal(value.runtime.node, 'v26.9.0');
  assert.equal(before.mode & 0o7777, 0o600); assert.equal(lstatSync(f.output).mode & 0o7777, 0o700);
  const replay = await checkCargoMaterial(f); assert.equal(replay.receiptSha256, result.receiptSha256); assert.equal(replay.disposition, 'retained-bytes-verified'); assert.equal(lstatSync(path).ino, before.ino); assert.equal(lstatSync(path).mtimeMs, before.mtimeMs);
  const cli = JSON.parse(execFileSync('mise', ['exec', '--', 'node', join(f.repository, 'release/cargo-material-cli.mjs'), f.tag, f.commit, f.sourcePath, f.cache, f.sources, f.output], { cwd: f.repository, encoding: 'utf8', timeout: 90_000, maxBuffer: 64 * 1024 })); assert.equal(cli.receiptSha256, result.receiptSha256);
});

test('literal lock scope refuses unknown/ambiguous references, duplicate identities, alternate sources and unconsumed syntax', async t => {
  const f = await fixture(t); assert.equal(cargoSourceLock(Buffer.from(f.lock)).length, 3);
  for (const text of [f.lock.replace('version = 4', 'version = 3'), f.lock.replace('"test_crate",', '"missing",'), f.lock + '\n[metadata]\nextra = true\n', f.lock.replace('registry+https://github.com/rust-lang/crates.io-index', 'registry+https://example.invalid/index'), f.lock + '\n[[package]]\nname = "jpeg-decoder"\nversion = "0.3.2-fs.1"\n', f.lock.replace('name = "jpeg-decoder"', 'name = "other-local"')]) assert.throws(() => cargoSourceLock(Buffer.from(text)));
  assert.throws(() => cargoSourceLock(Buffer.alloc(64 * 1024 + 1))); await assert.rejects(() => checkCargoMaterial(f, { budgetMs: 1 }), /deadline/);
});

test('bounded actual parser accepts POSIX headers and clears preloads, while malformed types/paths/fields/identity/padding refuse', async t => {
  const f = await fixture(t), tar = gunzipSync(f.raw);
  const posix = Buffer.from(tar); for (let at = 0; at + 512 <= posix.length && posix[at] !== 0;) { const h = posix.subarray(at, at + 512), bytes = parseInt(h.subarray(124, 136).toString().replace(/\0/g, ''), 8); h.write('ustar\0' + '00', 257, 'ascii'); checksum(h); at += 512 + Math.ceil(bytes / 512) * 512; }
  assert.deepEqual(parseBytes(f, gzipSync(posix)).files, parseBytes(f, f.raw).files);
  const prior = process.env.NODE_OPTIONS; try { process.env.NODE_OPTIONS = '--require /private-unsupported-preload'; assert.ok(parseBytes(f, f.raw).files.length); } finally { if (prior === undefined) delete process.env.NODE_OPTIONS; else process.env.NODE_OPTIONS = prior; }
  for (const mutation of [h => { h[156] = 50; }, h => { h[156] = 76; }, h => { h[156] = 120; }, h => { h.fill(0, 0, 100); h.write('../outside', 0); }, h => { h[100] = 128; }, h => { h[345] = 1; }, h => { h[500] = 1; }, h => { h.fill(0, 157, 257); h.write('link', 157); }]) assert.throws(() => parseBytes(f, changed(f.raw, mutation)), /refused/);
  assert.throws(() => cargoArchiveParse({ ...f.package, checksum: 'f'.repeat(64) }, f.raw));
  const trailing = Buffer.concat([tar, Buffer.from('outside')]); assert.throws(() => parseBytes(f, gzipSync(trailing)));
  const wrong = Buffer.from(tar); let manifestStart;
  for (let at = 0; at + 512 <= wrong.length && wrong[at] !== 0;) { const h = wrong.subarray(at, at + 512), bytes = parseInt(h.subarray(124, 136).toString().replace(/\0/g, ''), 8); if (h.subarray(0, 100).toString().split('\0')[0] === 'test_crate-1.0.0/Cargo.toml') manifestStart = at + 512; at += 512 + Math.ceil(bytes / 512) * 512; }
  assert.ok(manifestStart); const name = wrong.indexOf(Buffer.from('name = "test_crate"'), manifestStart); assert.ok(name >= manifestStart); wrong[name + 8] = 88; assert.throws(() => parseBytes(f, gzipSync(wrong)));
  assert.throws(() => parseBytes(f, gzipSync(Buffer.alloc(128 * 1024 * 1024 + 512))), /refused/);
});

test('checksum precedes parsing and missing/extra/aliased/unsafe source or generated marker cannot pass cache admission', async t => {
  const f = await fixture(t); writeFileSync(f.archive, 'changed'); let calls = 0; await assert.rejects(() => checkCargoMaterial(f, { parse: () => { calls++; throw Error('not reached'); } }), /checksum/); assert.equal(calls, 0); writeFileSync(f.archive, f.raw);
  const source = join(f.root, 'LICENSE'), original = readFileSync(source), alias = join(f.repository, 'var/alias');
  linkSync(source, alias); await assert.rejects(() => checkCargoMaterial(f), /alias/); rmSync(alias);
  chmodSync(source, 0o666); await assert.rejects(() => checkCargoMaterial(f), /unsafe|source differs/); chmodSync(source, 0o644);
  writeFileSync(source, 'changed'); await assert.rejects(() => checkCargoMaterial(f), /source differs/); writeFileSync(source, original);
  rmSync(source); await assert.rejects(() => checkCargoMaterial(f), /incomplete/); writeFileSync(source, original);
  writeFileSync(join(f.root, 'extra'), 'unknown'); await assert.rejects(() => checkCargoMaterial(f), /additional/); rmSync(join(f.root, 'extra'));
  mkdirSync(join(f.root, 'extra'), { mode: 0o700 }); await assert.rejects(() => checkCargoMaterial(f), /additional/); rmSync(join(f.root, 'extra'), { recursive: true });
  const marker = join(f.root, '.cargo-ok'); writeFileSync(marker, '{"v":2}'); await assert.rejects(() => checkCargoMaterial(f), /source differs/); assert.equal(existsSync(f.output), false);
});

test('partial or conflicting output and late source/cache/frozen namespace changes preserve custody', async t => {
  for (const mutation of ['source', 'cache', 'frozen', 'output']) {
    const f = await fixture(t); let calls = 0;
    await assert.rejects(() => checkCargoMaterial(f, { parse: (...args) => {
      const result = cargoArchiveParse(...args);
      if (++calls === 2) {
        if (mutation === 'source') { const p = join(f.root, 'LICENSE'); writeFileSync(p, readFileSync(p)); }
        if (mutation === 'cache') writeFileSync(join(f.cache, 'unknown'), 'retained');
        if (mutation === 'frozen') { f.git(['update-index', '--assume-unchanged', 'codec/Cargo.lock']); writeFileSync(join(f.repository, 'codec/Cargo.lock'), f.lock + '\n'); }
        if (mutation === 'output') writeFileSync(join(f.output, 'unknown'), 'retained');
      }
      return result;
    } })); assert.equal(existsSync(join(f.output, 'check.pending')), true); assert.equal(existsSync(join(f.output, 'cargo-material.json')), false); await assert.rejects(() => checkCargoMaterial(f));
  }
});

test('CLI usage/refusal has no supplied private path or parser details', () => {
  const run = args => spawnSync('mise', ['exec', '--', 'node', join(owner, 'release/cargo-material-cli.mjs'), ...args], { cwd: owner, encoding: 'utf8', timeout: 60_000 }); assert.equal(run([]).status, 64);
  const result = run(['v1.2.3', 'f'.repeat(40), 'private-source', 'private-cache', 'private-sources', 'private-output']); assert.equal(result.status, 1); assert.equal(result.stdout, ''); assert.equal(result.stderr, 'codec Cargo source: unavailable, unsafe or conflicting input/output\n');
});

test('completed evidence refuses changed bytes, aliases, unsafe modes and unknown namespace without replacing the receipt', async t => {
  const f = await fixture(t); await checkCargoMaterial(f);
  const path = join(f.output, 'cargo-material.json'), original = readFileSync(path), before = lstatSync(path), alias = join(f.repository, 'var/receipt-alias');
  writeFileSync(path, Buffer.from(original.toString().replace('locked-codec-cargo-source-material', 'forged-codec-cargo-source-material')));
  const changed = readFileSync(path); await assert.rejects(() => checkCargoMaterial(f), /conflicting/); assert.deepEqual(readFileSync(path), changed); assert.equal(lstatSync(path).ino, before.ino);
  writeFileSync(path, original); linkSync(path, alias); await assert.rejects(() => checkCargoMaterial(f), /conflicting/); assert.equal(lstatSync(path).nlink, 2); rmSync(alias);
  chmodSync(path, 0o644); await assert.rejects(() => checkCargoMaterial(f), /unsafe/); assert.equal(lstatSync(path).mode & 0o7777, 0o644); chmodSync(path, 0o600);
  writeFileSync(join(f.output, 'unknown'), 'retained'); await assert.rejects(() => checkCargoMaterial(f), /conflicting/); assert.equal(readFileSync(join(f.output, 'unknown'), 'utf8'), 'retained'); rmSync(join(f.output, 'unknown'));
  chmodSync(f.output, 0o755); await assert.rejects(() => checkCargoMaterial(f), /unsafe/); chmodSync(f.output, 0o700);
  assert.deepEqual(readFileSync(path), original); assert.equal(lstatSync(path).ino, before.ino); assert.equal(existsSync(join(f.output, 'check.pending')), false);
});
