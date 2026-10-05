import assert from 'node:assert/strict';
import { execFileSync, spawnSync } from 'node:child_process';
import { chmodSync, existsSync, linkSync, lstatSync, mkdirSync, readFileSync, rmSync, writeFileSync } from 'node:fs';
import { join, resolve } from 'node:path';
import test from 'node:test';
import { cargoArchiveParse, checkCargoMaterial } from './cargo-material.mjs';
import { cargoFixture, hash } from './cargo-material-fixture.mjs';
import { collectCodecNotices } from './codec-notices.mjs';
import { recordInputs } from './inputs.mjs';

const owner = resolve(new URL('..', import.meta.url).pathname);
async function fixture(t, { local = true, excess } = {}) {
  const f = await cargoFixture(t);
  if (local) { writeFileSync(join(f.repository, 'codec/vendor/jpeg-decoder/LICENSE-MIT'), Buffer.from([255, 0, 10])); writeFileSync(join(f.repository, 'codec/COPYING'), 'fixture\n'); }
  if (excess) {
    for (let n = 0; n < excess.count; n++) writeFileSync(join(f.repository, 'codec', 'NOTICE-' + n), Buffer.alloc(excess.bytes, 88));
  }
  f.git(['add', 'codec']); f.git(['-c', 'user.name=Fixture', '-c', 'user.email=fixture@example.invalid', 'commit', '--allow-empty', '-m', 'test(host): freeze local notice sources']);
  f.commit = f.git(['rev-parse', 'HEAD']); f.git(['tag', '-f', f.tag]); await recordInputs(f.repository, f.tag, f.commit, join(f.repository, 'var/notice-inputs')); f.sourcePath = join(f.repository, 'var/notice-inputs/source-inputs.json');
  const result = await checkCargoMaterial(f); f.cargoPath = join(f.output, 'cargo-material.json'); f.cargoSha256 = result.receiptSha256; f.output = join(f.repository, 'var/notices'); return f;
}
test('actual Cargo and frozen local binary notices retain metadata roles and unchanged private CLI replay', async t => {
  const f = await fixture(t), result = await collectCodecNotices(f), path = join(f.output, 'notices.json'), before = lstatSync(path), value = JSON.parse(readFileSync(path));
  assert.equal(result.packages, 3); assert.equal(result.packagesWithoutConventionalNoticeFile, 0); assert.equal(result.rightsReview, 'required'); assert.equal(result.publicationAuthority, 'none'); assert.equal(value.collectionScope, 'codec-conventional-notice-files-and-manifest-metadata');
  const local = value.files.find(file => file.scope === 'frozen-project' && file.package === 'jpeg-decoder' && file.role === 'conventional-notice-file'); assert.equal(local.source.gitMode, '100644'); assert.deepEqual(readFileSync(join(f.output, 'files', local.retainedPath)), Buffer.from([255, 0, 10]));
  assert.equal(value.files.filter(file => file.role === 'package-metadata').length, 4); assert.equal(before.mode & 0o7777, 0o600); assert.equal(lstatSync(f.output).mode & 0o7777, 0o700);
  const replay = await collectCodecNotices(f); assert.equal(replay.recordSha256, result.recordSha256); assert.equal(lstatSync(path).ino, before.ino); assert.equal(lstatSync(path).mtimeMs, before.mtimeMs);
  const cli = JSON.parse(execFileSync('mise', ['exec', '--', 'node', join(f.repository, 'release/codec-notices-cli.mjs'), f.tag, f.commit, f.sourcePath, f.cache, f.sources, f.cargoPath, f.cargoSha256, f.output], { cwd: f.repository, encoding: 'utf8', timeout: 120_000 })); assert.equal(cli.disposition, 'retained-bytes-verified'); assert.equal(cli.recordSha256, result.recordSha256);
});
test('missing local notice names remain explicit and metadata never fills their notice list', async t => {
  const f = await fixture(t, { local: false }); const result = await collectCodecNotices(f), value = JSON.parse(readFileSync(join(f.output, 'notices.json')));
  assert.equal(result.packagesWithoutConventionalNoticeFile, 2); for (const item of value.packages.filter(p => p.scope === 'frozen-project')) { assert.deepEqual(item.conventionalNoticeFiles, []); assert.equal(item.selectedFiles.length, 1); }
});
test('independently wrong, forged, missing or changed Cargo receipts refuse without creating collection or repairing evidence', async t => {
  const f = await fixture(t); let calls = 0; await assert.rejects(() => collectCodecNotices({ ...f, cargoSha256: 'f'.repeat(64) }, { parse: () => { calls++; throw Error('never'); } }), /identity/); assert.equal(calls, 0);
  const original = readFileSync(f.cargoPath), forged = Buffer.from(original.toString().replace('"name":"test_crate"', '"name":"forged_crate"')); writeFileSync(f.cargoPath, forged); await assert.rejects(() => collectCodecNotices({ ...f, cargoSha256: hash(forged) }), /conflicting|differs/); assert.deepEqual(readFileSync(f.cargoPath), forged); writeFileSync(f.cargoPath, original);
  rmSync(f.cargoPath); await assert.rejects(() => collectCodecNotices(f)); assert.equal(existsSync(f.cargoPath), false); assert.equal(existsSync(f.output), false);
});
test('source-admitted notice file, aggregate and selected-entry ceilings refuse before collection', async t => {
  for (const excess of [{ count: 1, bytes: 1024 * 1024 + 1 }, { count: 17, bytes: 1024 * 1024 }, { count: 513, bytes: 1 }]) { const f = await fixture(t, { excess }); await assert.rejects(() => collectCodecNotices(f), /selection bounds/); assert.equal(existsSync(f.output), false); }
  const f = await fixture(t); await assert.rejects(() => collectCodecNotices(f, { budgetMs: 1 }), /deadline/);
});
test('retained copies and inventory refuse aliases, modes, bytes and additional or partial namespace without replacement', async t => {
  const f = await fixture(t); await collectCodecNotices(f); const path = join(f.output, 'notices.json'), original = readFileSync(path), value = JSON.parse(original), copied = join(f.output, 'files', value.files.find(file => file.role === 'conventional-notice-file').retainedPath), raw = readFileSync(copied), alias = join(f.repository, 'var/alias');
  linkSync(copied, alias); await assert.rejects(() => collectCodecNotices(f), /aliased/); rmSync(alias); chmodSync(copied, 0o644); await assert.rejects(() => collectCodecNotices(f), /unsafe/); chmodSync(copied, 0o600);
  writeFileSync(copied, 'changed'); await assert.rejects(() => collectCodecNotices(f), /bytes differ/); assert.equal(readFileSync(copied, 'utf8'), 'changed'); writeFileSync(copied, raw);
  mkdirSync(join(f.output, 'files/unknown'), { mode: 0o700 }); await assert.rejects(() => collectCodecNotices(f), /unknown/); rmSync(join(f.output, 'files/unknown'), { recursive: true });
  linkSync(path, alias); await assert.rejects(() => collectCodecNotices(f), /conflicting/); rmSync(alias); writeFileSync(path, 'changed'); await assert.rejects(() => collectCodecNotices(f), /conflicting/); assert.equal(readFileSync(path, 'utf8'), 'changed'); writeFileSync(path, original);
  writeFileSync(join(f.output, 'collect.pending'), 'retained'); await assert.rejects(() => collectCodecNotices(f), /conflicting/); assert.equal(readFileSync(join(f.output, 'collect.pending'), 'utf8'), 'retained'); assert.deepEqual(readFileSync(path), original);
});
test('late archive parser mutation of selected source, copied bytes, pinned receipt or frozen source preserves incomplete custody', async t => {
  for (const mutation of ['source', 'copy', 'receipt', 'frozen', 'output']) {
    const f = await fixture(t); let calls = 0;
    await assert.rejects(() => collectCodecNotices(f, { parse: (...args) => {
      const result = cargoArchiveParse(...args); if (++calls === 4) {
        if (mutation === 'source') { const p = join(f.root, 'LICENSE'); writeFileSync(p, readFileSync(p)); }
        if (mutation === 'copy') { const p = join(f.output, 'files/registry/test_crate/1.0.0/LICENSE'); writeFileSync(p, readFileSync(p)); }
        if (mutation === 'receipt') writeFileSync(f.cargoPath, Buffer.from('changed'));
        if (mutation === 'frozen') { f.git(['update-index', '--assume-unchanged', 'codec/COPYING']); writeFileSync(join(f.repository, 'codec/COPYING'), 'changed'); }
        if (mutation === 'output') writeFileSync(join(f.output, 'unknown'), 'retained');
      } return result;
    } })); assert.equal(existsSync(join(f.output, 'collect.pending')), true); assert.equal(existsSync(join(f.output, 'notices.json')), false);
  }
});
test('fixed CLI errors exclude supplied private paths', () => {
  const run = args => spawnSync('mise', ['exec', '--', 'node', join(owner, 'release/codec-notices-cli.mjs'), ...args], { cwd: owner, encoding: 'utf8', timeout: 60_000 }); assert.equal(run([]).status, 64);
  const result = run(['v1.2.3', 'f'.repeat(40), 'private-source', 'private-cache', 'private-sources', 'private-cargo', 'f'.repeat(64), 'private-output']); assert.equal(result.status, 1); assert.equal(result.stdout, ''); assert.equal(result.stderr, 'codec notices: unavailable, unsafe or conflicting input/output\n');
});
