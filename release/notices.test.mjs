import assert from 'node:assert/strict';
import { execFileSync, spawnSync } from 'node:child_process';
import { chmodSync, existsSync, linkSync, lstatSync, mkdirSync, readFileSync, readdirSync, rmSync, writeFileSync } from 'node:fs';
import { join, resolve } from 'node:path';
import test from 'node:test';
import { coreMaterialParse } from './core-material.mjs';
import { collectDependencyNotices, conventionalNoticePath } from './notices.mjs';
import { hash, noticeFixture as fixture } from './notices-fixture.mjs';

const owner = resolve(new URL('..', import.meta.url).pathname);
test('actual Hex, sparse Git and Gleam notices preserve raw bytes, separate metadata and report missing names through CLI replay', async t => {
  const f = await fixture(t), result = await collectDependencyNotices(f), record = join(f.output, 'notices.json'), before = lstatSync(record);
  assert.equal(result.packages, 4); assert.equal(result.files, 5); assert.equal(result.packagesWithoutConventionalNoticeFile, 1); assert.equal(result.rightsReview, 'required'); assert.equal(result.publicationAuthority, 'none');
  const value = JSON.parse(readFileSync(record)); assert.deepEqual(value.packages.find(p => p.name === 'missing').conventionalNoticeFiles, []); assert.equal(value.packages.find(p => p.name === 'missing').selectedFiles.length, 1);
  const raw = join(f.output, 'files/core/covered/licenses/notice-0.txt'), source = join(f.repository, 'apps/core/deps/covered/licenses/notice-0.txt'), beforeRaw = lstatSync(raw);
  assert.deepEqual(readFileSync(raw), Buffer.from([128, 0, 10])); assert.deepEqual(readFileSync(raw), readFileSync(source)); assert.equal(beforeRaw.mode & 0o7777, 0o600); assert.equal(lstatSync(f.output).mode & 0o7777, 0o700);
  const replay = await collectDependencyNotices(f); assert.equal(replay.recordSha256, result.recordSha256); assert.equal(replay.disposition, 'retained-bytes-verified'); assert.equal(lstatSync(record).ino, before.ino); assert.equal(lstatSync(record).mtimeMs, before.mtimeMs); assert.equal(lstatSync(raw).ino, beforeRaw.ino); assert.equal(lstatSync(raw).mtimeMs, beforeRaw.mtimeMs);
  const cli = JSON.parse(execFileSync('mise', ['exec', '--', 'node', join(f.repository, 'release/notices-cli.mjs'), f.tag, f.commit, f.sourcePath, f.coreCache, f.corePath, f.coreSha256, f.gleamCache, f.gleamPath, f.gleamSha256, f.output], { cwd: f.repository, encoding: 'utf8', timeout: 90_000, maxBuffer: 64 * 1024 })); assert.equal(cli.recordSha256, result.recordSha256);
});

test('selection follows the declared filename profile, including suffix candidates, and refuses unsafe or unmatched names', () => {
  for (const path of ['LICENSE', 'LICENCE.md', 'vendor/COPYING.fixture', 'copyright.txt', 'NOTICE-extra', 'AUTHORS', 'licenses/custom.txt', 'a/LICENCES/BSD-3-Clause.txt', 'src/license_parser.ex']) assert.equal(conventionalNoticePath(path), true);
  for (const path of ['README.md', 'src/parser_license.ex', 'some-license.txt', '../LICENSE', 'licenses/../secret', 'LICENSE\u0000.txt']) assert.equal(conventionalNoticePath(path), false);
});

test('independent receipt digests, forged inventories and changed source refuse without replacing source evidence', async t => {
  const f = await fixture(t);
  for (const key of ['coreSha256', 'gleamSha256']) await assert.rejects(() => collectDependencyNotices({ ...f, [key]: 'f'.repeat(64) }));
  const original = readFileSync(f.corePath), forged = JSON.parse(original); forged.extra = true; writeFileSync(f.corePath, JSON.stringify(forged) + '\n');
  await assert.rejects(() => collectDependencyNotices({ ...f, coreSha256: hash(readFileSync(f.corePath)) }), /conflicting/); assert.deepEqual(readFileSync(f.corePath), Buffer.from(JSON.stringify(forged) + '\n')); writeFileSync(f.corePath, original);
  writeFileSync(join(f.repository, 'apps/core/deps/covered/licenses/notice-0.txt'), 'changed'); await assert.rejects(() => collectDependencyNotices(f), /source differs/); assert.equal(existsSync(f.output), false);
});

test('actual source-admitted file, aggregate and entry ceilings refuse before collection', async t => {
  for (const options of [{ noticeBytes: 1024 * 1024 + 1 }, { noticeCount: 17, noticeBytes: 1024 * 1024 }, { noticeCount: 513 }]) {
    const f = await fixture(t, options); await assert.rejects(() => collectDependencyNotices(f), /bounds/); assert.equal(existsSync(f.output), false);
  }
});

test('partial, aliased, changed, unsafe and extra copied custody is retained and refused', async t => {
  const f = await fixture(t); mkdirSync(f.output, { mode: 0o700 }); writeFileSync(join(f.output, 'collect.pending'), 'retained', { mode: 0o600 }); await assert.rejects(() => collectDependencyNotices(f), /incomplete/); assert.deepEqual(readdirSync(f.output), ['collect.pending']);
  const complete = { ...f, output: f.output + '-complete' }; await collectDependencyNotices(complete); const path = join(complete.output, 'files/core/covered/licenses/notice-0.txt'), original = readFileSync(path), alias = join(f.repository, 'var/alias');
  linkSync(path, alias); await assert.rejects(() => collectDependencyNotices(complete), /aliased/); rmSync(alias);
  chmodSync(path, 0o644); await assert.rejects(() => collectDependencyNotices(complete), /unsafe/); chmodSync(path, 0o600);
  writeFileSync(path, 'changed'); await assert.rejects(() => collectDependencyNotices(complete), /bytes differ/); writeFileSync(path, original);
  mkdirSync(join(complete.output, 'files/unknown'), { mode: 0o700 }); await assert.rejects(() => collectDependencyNotices(complete), /unknown/); assert.equal(existsSync(join(complete.output, 'files/unknown')), true);
});

test('changes during final source parsers are caught by static selected-file, source and copy checks', async t => {
  for (const mutation of ['original', 'copy', 'namespace', 'frozen']) {
    const f = await fixture(t); let finalPackages = 0;
    await assert.rejects(() => collectDependencyNotices(f, { parse: (...args) => {
      const result = coreMaterialParse(...args);
      if (existsSync(join(f.output, 'collect.pending')) && args[0] === 'package' && result.name === 'notice_gleam' && ++finalPackages === 2) {
        if (mutation === 'original') { const path = join(f.repository, 'apps/core/deps/covered/licenses/notice-0.txt'); writeFileSync(path, readFileSync(path)); }
        if (mutation === 'copy') { const path = join(f.output, 'files/core/covered/licenses/notice-0.txt'); writeFileSync(path, readFileSync(path)); }
        if (mutation === 'namespace') writeFileSync(join(f.output, 'files/unknown'), 'preserved');
        if (mutation === 'frozen') { execFileSync('git', ['update-index', '--assume-unchanged', 'apps/core/mix.exs'], { cwd: f.repository }); const path = join(f.repository, 'apps/core/mix.exs'); writeFileSync(path, readFileSync(path, 'utf8') + '\n'); }
      }
      return result;
    } })); assert.equal(existsSync(join(f.output, 'collect.pending')), true); assert.equal(existsSync(join(f.output, 'notices.json')), false);
  }
});

test('CLI fixes usage/refusal and does not expose supplied private paths', () => {
  const run = args => spawnSync('mise', ['exec', '--', 'node', join(owner, 'release/notices-cli.mjs'), ...args], { cwd: owner, encoding: 'utf8', timeout: 60_000 }); assert.equal(run([]).status, 64);
  const result = run(['v1.2.3', 'f'.repeat(40), 'private-source', 'private-core-cache', 'private-core', 'a'.repeat(64), 'private-gleam-cache', 'private-gleam', 'b'.repeat(64), 'private-output']); assert.equal(result.status, 1); assert.equal(result.stdout, ''); assert.equal(result.stderr, 'dependency notices: unavailable, unsafe or conflicting input/output\n');
});
