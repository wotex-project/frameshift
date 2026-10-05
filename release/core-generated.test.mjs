import assert from 'node:assert/strict';
import { execFileSync, spawnSync } from 'node:child_process';
import { chmodSync, linkSync, lstatSync, mkdirSync, mkdtempSync, readFileSync, readdirSync, rmSync, writeFileSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join, resolve } from 'node:path';
import test from 'node:test';
import { checkCoreGenerated, generatedSyntaxTool } from './core-generated.mjs';
import { changeJoin, encode, generatedFixture as fixture } from './core-generated-fixture.mjs';

const owner = resolve(new URL('..', import.meta.url).pathname);
test('generator clears inherited compiler options and refuses unsupported input/private roots', t => {
  const root = mkdtempSync(join(tmpdir(), 'frameshift-generator-env-')); t.after(() => rmSync(root, { recursive: true, force: true }));
  const prior = process.env.ERL_COMPILER_OPTIONS;
  try { process.env.ERL_COMPILER_OPTIONS = 'this is not an Erlang term'; const observed = generatedSyntaxTool('observe', root, []); assert.equal(observed.parsetools, '2.8'); assert.deepEqual(observed.generated, []); }
  finally { if (prior === undefined) delete process.env.ERL_COMPILER_OPTIONS; else process.env.ERL_COMPILER_OPTIONS = prior; }
  assert.throws(() => generatedSyntaxTool('generate', root, ['unknown/src/parser.yrl']), /refused/);
  chmodSync(root, 0o755); assert.throws(() => generatedSyntaxTool('observe', root, []), /refused/);
});

test('actual archived grammars and generators derive five captured inputs, preserve proof custody and replay without generation', async t => {
  const f = await fixture(t), result = await checkCoreGenerated(f); assert.equal(result.qualifiedGeneratedFiles, 5); assert.equal(result.remainingGeneratedInputs, 0); assert.equal(result.publicationAuthority, 'none');
  const path = join(f.output, 'generated-core.json'), before = lstatSync(path), source = join(f.output, 'proof/erlex/src/erlex_parser.yrl'), beforeSource = lstatSync(source);
  const replay = await checkCoreGenerated(f, { tool: (operation, ...args) => { assert.equal(operation, 'observe'); return generatedSyntaxTool(operation, ...args); } });
  assert.equal(replay.recordSha256, result.recordSha256); assert.equal(replay.disposition, 'retained-bytes-verified'); assert.equal(lstatSync(path).ino, before.ino); assert.equal(lstatSync(path).mtimeMs, before.mtimeMs); assert.equal(lstatSync(source).ino, beforeSource.ino); assert.equal(lstatSync(source).mtimeMs, beforeSource.mtimeMs);
  const cli = JSON.parse(execFileSync('mise', ['exec', '--', 'node', join(f.repository, 'release/core-generated-cli.mjs'), f.tag, f.commit, f.sourcePath, f.cache, f.corePath, f.coreSha256, f.joinPath, f.joinSha256, f.output], { cwd: f.repository, timeout: 90_000, maxBuffer: 64 * 1024, encoding: 'utf8' })); assert.equal(cli.recordSha256, result.recordSha256);
  const bytes = readFileSync(path, 'utf8'); assert.equal(bytes.includes('/Users/'), false); assert.equal(bytes.includes('/var/folders/'), false); assert.equal(JSON.parse(bytes).generator.modules.length, 4); assert.equal(JSON.parse(bytes).generator.templates.length, 2);
});

test('empty captured grammar subset records zero derivations without qualifying other generated scopes', async t => {
  const f = changeJoin(await fixture(t), r => { r.generatedInputs = []; }); const result = await checkCoreGenerated(f); assert.equal(result.qualifiedGeneratedFiles, 0); assert.deepEqual(readdirSync(join(f.output, 'proof')), []);
});

test('independent identities, unsupported schemas/roles and changed captured outputs refuse', async t => {
  const f = await fixture(t);
  for (const key of ['coreSha256', 'joinSha256']) await assert.rejects(() => checkCoreGenerated({ ...f, [key]: 'f'.repeat(64) }));
  for (const mutation of [r => { r.coreReceiptSha256 = 'f'.repeat(64); }, r => { r.candidateRecordSha256 = 'invalid'; }, r => { r.extra = true; }, r => { r.generatedInputs[0].reason = 'other'; }, r => { r.generatedInputs[0].path = 'apps/core/deps/earmark_parser/src/unknown.erl'; }, r => { r.generatedInputs.push(r.generatedInputs[0]); }, r => { r.generatedInputs[0].mode = 0o755; }, r => { r.generatedInputs[0].bytes = 2 * 1024 * 1024 + 1; }]) await assert.rejects(() => checkCoreGenerated(changeJoin(f, mutation)));
  const bad = changeJoin(f, r => { r.generatedInputs[0].sha256 = 'f'.repeat(64); }); await assert.rejects(() => checkCoreGenerated(bad), /captured/); assert.deepEqual(readdirSync(bad.output).sort(), ['check.pending', 'proof']);
});

test('partial output and aliased, changed or unsafe retained proof refuse without regeneration', async t => {
  const f = await fixture(t); mkdirSync(f.output, { mode: 0o700 }); writeFileSync(join(f.output, 'check.pending'), 'retained', { mode: 0o600 }); await assert.rejects(() => checkCoreGenerated(f), /incomplete/); assert.deepEqual(readdirSync(f.output), ['check.pending']);
  const complete = { ...f, output: f.output + '-complete' }; await checkCoreGenerated(complete); const path = join(complete.output, 'proof/erlex/src/erlex_parser.erl'), original = readFileSync(path), alias = join(f.repository, 'var/alias');
  linkSync(path, alias); await assert.rejects(() => checkCoreGenerated(complete), /aliased/); rmSync(alias);
  chmodSync(path, 0o644); await assert.rejects(() => checkCoreGenerated(complete), /aliased/); chmodSync(path, 0o600);
  writeFileSync(path, 'changed'); await assert.rejects(() => checkCoreGenerated(complete), /bytes/); writeFileSync(path, original);
  writeFileSync(join(complete.output, 'proof/unknown'), 'preserved'); await assert.rejects(() => checkCoreGenerated(complete), /unknown/); assert.equal(readFileSync(join(complete.output, 'proof/unknown'), 'utf8'), 'preserved');
});

test('tool/module/template and private or original source changes during children retain incomplete custody', async t => {
  for (const mutation of ['module', 'template', 'private', 'source', 'namespace']) {
    const f = await fixture(t); let calls = 0;
    await assert.rejects(() => checkCoreGenerated(f, { tool: (operation, ...args) => {
      const result = generatedSyntaxTool(operation, ...args);
      if (++calls === 1) {
        if (mutation === 'module') result.modules[0].sha256 = 'f'.repeat(64);
        if (mutation === 'template') result.templates[0].sha256 = 'f'.repeat(64);
        if (mutation === 'private') writeFileSync(join(f.output, 'proof/erlex/src/erlex_parser.yrl'), readFileSync(join(f.output, 'proof/erlex/src/erlex_parser.yrl')));
      }
      if (calls === 2 && mutation === 'source') { const file = join(f.repository, 'apps/core/mix.exs'); f.repository && execFileSync('git', ['update-index', '--assume-unchanged', 'apps/core/mix.exs'], { cwd: f.repository }); writeFileSync(file, readFileSync(file, 'utf8') + '\n'); }
      if (calls === 2 && mutation === 'namespace') writeFileSync(join(f.output, 'proof/unknown'), 'retain');
      return result;
    } })); assert.equal(readdirSync(f.output).includes('check.pending'), true); assert.equal(readdirSync(f.output).includes('generated-core.json'), false);
  }
});

test('CLI has fixed usage/refusal without disclosing supplied paths', () => {
  const run = args => spawnSync('mise', ['exec', '--', 'node', join(owner, 'release/core-generated-cli.mjs'), ...args], { cwd: owner, encoding: 'utf8', timeout: 60_000 }); assert.equal(run([]).status, 64);
  const result = run(['v0.1.0', 'f'.repeat(40), 'private-source', 'private-cache', 'private-core', 'a'.repeat(64), 'private-join', 'b'.repeat(64), 'private-output']); assert.equal(result.status, 1); assert.equal(result.stdout, ''); assert.equal(result.stderr, 'generated core source: unavailable, unsafe or conflicting input/output\n');
});
