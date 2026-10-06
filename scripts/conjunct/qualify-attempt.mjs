import assert from 'node:assert/strict';
import { spawnSync } from 'node:child_process';
import { chmodSync, existsSync, lstatSync, mkdirSync, mkdtempSync, readFileSync, readdirSync, unlinkSync, writeFileSync } from 'node:fs';
import { join, resolve } from 'node:path';
import { fileURLToPath, pathToFileURL } from 'node:url';
import { isDeepStrictEqual } from 'node:util';
import { gzipSync } from 'node:zlib';
import { reopenAttempt } from './readback.mjs';

const repository = resolve(fileURLToPath(new URL('../..', import.meta.url)));
const parent = join(repository, 'var/conjunct/attempts');
mkdirSync(parent, { recursive: true });
const owner = mkdtempSync(join(parent, 'qualification-'));
const write = (name, value) => writeFileSync(join(owner, `${name}.json.gz`), gzipSync(JSON.stringify(value)), { flag: 'wx' });
write('initial-state', { state: 'incomplete' });
const walk = path => readdirSync(join(repository, path)).sort().flatMap(name => {
  const item = join(path, name);
  return lstatSync(join(repository, item)).isDirectory() ? walk(item) : [item];
});
const paths = [...walk('scripts/conjunct'), 'docs/architecture/conjunct-integration.md'].sort();
const sourceSnapshot = (root, selected) => Object.fromEntries(selected.map(path => {
  const stat = lstatSync(join(root, path));
  assert(stat.isFile() && !stat.isSymbolicLink());
  return [path, { mode: stat.mode & 0o7777, bytes: [...readFileSync(join(root, path))] }];
}));
const originalSource = sourceSnapshot(repository, paths);
write('source-original', originalSource);
try {
const observeGit = (id, args, expected) => {
  const maxBuffer = 8 * 1024 * 1024;
  write(`${id}-original`, { program: 'git', args, expected, cwd: repository, env: { ...process.env }, maxBuffer });
  const actual = spawnSync('git', args, { cwd: repository, env: process.env, maxBuffer, encoding: null });
  write(`${id}-actual`, { status: actual.status, signal: actual.signal,
    error: actual.error ? { name: actual.error.name, code: actual.error.code ?? null, message: actual.error.message } : null,
    stdout: [...(actual.stdout ?? [])], stderr: [...(actual.stderr ?? [])] });
  if (actual.error) throw actual.error;
  assert.equal(actual.status, 0);
  return actual.stdout;
};
const fixturePath = 'scripts/conjunct/test/fixtures/retained-attempt.expected.json';
const fixtureBytes = readFileSync(join(repository, fixturePath));
const norm = observeGit('norm', ['show', `dc2a5b6d8c4da45ec27a8de134f0b1b962a728bb:${fixturePath}`], { revision: 'dc2a5b6d8c4da45ec27a8de134f0b1b962a728bb', path: fixturePath, bytes: [...fixtureBytes] });
assert.deepEqual(norm, fixtureBytes, 'authored hands differ from their prior committed Norm');
const fixture = JSON.parse(fixtureBytes);
assert.equal(fixture.cases.length, 7);
for (const [path, expected] of Object.entries(fixture.original_sources)) {
  const id = `predecessor-${path.split('/').at(-1).replace('.', '-')}`;
  const actual = observeGit(id, ['show', `${fixture.predecessor}:${path}`], expected);
  assert.equal(actual.toString('utf8'), expected);
}
const candidatePath = join(repository, 'scripts/conjunct/attempt.mjs');
const candidateSource = readFileSync(candidatePath, 'utf8');
write('candidate-original', { path: candidatePath, source: candidateSource, node: process.version });
const beforeImport = readdirSync(parent).sort();
const candidate = await import(pathToFileURL(candidatePath));
write('candidate-import-actual', { exports: Object.keys(candidate).sort(), before: beforeImport, after: readdirSync(parent).sort(),
  loaded: { command: candidate.Attempt.prototype.command.toString(), summarize: candidate.summarize.toString() } });
assert.deepEqual(readdirSync(parent).sort(), beforeImport, 'import created an attempt');

const source = { 'source.txt': { mode: 0o644, bytes: [...Buffer.from('original\n')] } };
const command = (id, stdout = [], stderr = [], status = 0) => ({ id, status, signal: null, error: null, stdout, stderr });
function expectedSummary(schedule) {
  const commands = schedule.commands.filter(row => row.id !== schedule.remove_actual);
  const complete = schedule.remove_actual === undefined;
  const unchanged = isDeepStrictEqual(schedule.source_before, schedule.source_after);
  const required = schedule.required.every(id => commands.some(row => row.id === id));
  const nonzero = commands.some(row => row.status !== null && row.status !== 0);
  const unavailable = commands.some(row => row.status === null || row.signal !== null || row.error !== null);
  return { state: !complete || !unchanged || (!required && !nonzero) || unavailable ? 'incomplete' : nonzero ? 'failed' : 'passed',
    recording_complete: complete, source_unchanged: unchanged, required_complete: required, commands };
}

let next = 0;
function execute(schedule, loaded = candidate, label = 'case', compare = true) {
  const id = `${label}-${next++}`;
  const root = join(owner, id);
  mkdirSync(root);
  for (const [path, value] of Object.entries(schedule.source_before)) {
    writeFileSync(join(root, path), Buffer.from(value.bytes));
    chmodSync(join(root, path), value.mode);
  }
  const directory = join(root, 'var/conjunct/attempts/record');
  const commands = schedule.commands.map(row => ({ id: row.id,
    program: row.error === 'ENOENT' ? join(root, 'absent-tool') : process.execPath,
    args: row.error === 'ENOENT' ? [] : ['-e', `process.stdout.write(Buffer.from(${JSON.stringify(row.stdout)}));process.stderr.write(Buffer.from(${JSON.stringify(row.stderr)}));process.exitCode=${row.status};`],
    cwd: root, env: { ...process.env }, maxBuffer: 32 * 1024 * 1024 }));
  const original = { schedule, request: { version: 'frameshift.conjunct-attempt.v1', root, directory, scope: 'hand',
    sourcePaths: Object.keys(schedule.source_before), required: schedule.required }, commands, expected: schedule.expected };
  write(`${id}-original`, original);
  const attempt = new loaded.Attempt({ root, directory, scope: 'hand', sourcePaths: original.request.sourcePaths, required: schedule.required });
  for (const request of commands) attempt.command(request);
  for (const [path, value] of Object.entries(schedule.source_after)) {
    writeFileSync(join(root, path), Buffer.from(value.bytes));
    chmodSync(join(root, path), value.mode);
  }
  if (schedule.remove_actual) {
    const path = join(directory, `${schedule.remove_actual}-actual.json.gz`);
    write(`${id}-removed-original`, { path, bytes: [...readFileSync(path)] });
    unlinkSync(path);
  }
  const summary = attempt.finish();
  const reopened = reopenAttempt(directory);
  write(`${id}-actual`, { summary, reopened });
  assert.deepEqual(reopened.request, original.request);
  assert.deepEqual(reopened.records['source-original'], schedule.source_before);
  assert.deepEqual(reopened.records['source-actual'], schedule.source_after);
  commands.forEach((request, index) => assert.deepEqual(reopened.records[`${request.id}-original`], { index, ...request }));
  if (compare) {
    assert.deepEqual(summary, schedule.expected, `${id}: candidate summary`);
    assert.deepEqual(reopened.summary, schedule.expected, `${id}: independent readback`);
    assert(reopened.valid, `${id}: stored summary disagrees with full records`);
  }
  return { id, root, directory, summary, reopened };
}

const hands = fixture.cases.map(hand => execute(hand, candidate, 'hand'));
write('hands-actual', { count: hands.length, directories: hands.map(hand => hand.directory), states: hands.map(hand => hand.summary.state) });
assert.notEqual(hands[0].directory, hands[1].directory);
const independentFirst = reopenAttempt(hands[0].directory);
assert.deepEqual(independentFirst.summary, fixture.cases[0].expected, 'second instance changed the first');

const campaigns = [];
for (const seed of fixture.seeds) {
  let state = seed >>> 0;
  const random = ceiling => { state = (Math.imul(state, 1664525) + 1013904223) >>> 0; return state % ceiling; };
  const schedule = Array.from({ length: fixture.successful_cases_per_seed }, (_, index) => {
    const count = random(5);
    const failure = random(count + 1) - 1;
    const rows = Array.from({ length: count }, (_, position) => command(`probe-${position}`,
      Array.from({ length: random(25) }, () => random(256)), Array.from({ length: random(12) }, () => random(256)),
      position === failure ? 1 + random(20) : 0));
    const item = { id: `seed-${seed}-${index}`, required: count === 0 ? ['absent'] : rows.map(row => row.id),
      source_before: source, source_after: source, commands: rows };
    return { ...item, expected: expectedSummary(item) };
  });
  write(`seed-${seed}-original`, { seed, schedules: schedule, expected_successful_cases: fixture.successful_cases_per_seed });
  const actual = schedule.map(item => execute(item, candidate, `seed-${seed}`));
  write(`seed-${seed}-actual`, { successful_cases: actual.length, directories: actual.map(item => item.directory) });
  campaigns.push(actual.length);
}

const faultInputs = {
  'omit-child-actual': { required: ['probe-0', 'probe-1', 'probe-2'], source_before: source, source_after: source,
    commands: [0, 1, 2].map(index => command(`probe-${index}`, [0, 1, 2, 3, 4], [10, 0])) },
  'promote-empty-prefix': { required: ['probe-0', 'probe-1', 'probe-2'], source_before: source, source_after: source, commands: [] },
};
const replacements = {
  'omit-child-actual': ['this.write(`${id}-actual`, { id, status: actual.status, signal: actual.signal,',
    'if (false) this.write(`${id}-actual`, { id, status: actual.status, signal: actual.signal,'],
  'promote-empty-prefix': ['const requiredComplete = input.required.every(id => commands.some(command => command.id === id));',
    'const requiredComplete = true;'],
};
const faults = [];
for (const id of fixture.faults) {
  const [anchor, replacement] = replacements[id];
  assert.equal(candidateSource.split(anchor).length, 2, `ambiguous fault anchor: ${id}`);
  const mutated = candidateSource.replace(anchor, replacement);
  const path = join(owner, `${id}.mjs`);
  write(`fault-${id}-source-original`, { path, original: candidateSource, mutated, anchor, replacement });
  writeFileSync(path, mutated, { flag: 'wx' });
  const loaded = await import(pathToFileURL(path));
  const loadedMethod = id === 'omit-child-actual' ? loaded.Attempt.prototype.command.toString() : loaded.summarize.toString();
  write(`fault-${id}-load-actual`, { source: readFileSync(path, 'utf8'), loadedMethod });
  assert(loadedMethod.includes(replacement), 'fault was not loaded');
  const full = faultInputs[id];
  const minimalSource = { 'source.txt': { mode: 0o644, bytes: [] } };
  const reduced = { required: ['probe-0'], source_before: minimalSource, source_after: minimalSource,
    commands: id === 'omit-child-actual' ? [command('probe-0')] : [] };
  const sizes = [full, reduced].map(value => Buffer.byteLength(JSON.stringify(value)));
  write(`fault-${id}-reduction-original`, { full, reduced, sizes, expected: 'strictly smaller actual rerun with the same wrong state' });
  assert(sizes[1] < sizes[0]);
  const actual = [full, reduced].map((input, index) => {
    const item = { ...input, expected: expectedSummary(input) };
    execute(item, candidate, `fault-${id}-baseline-${index}`);
    const result = execute(item, loaded, `fault-${id}-mutant-${index}`, false);
    assert.notDeepEqual(result.summary, item.expected, 'actual fault survived');
    assert.equal(result.summary.state, id === 'omit-child-actual' ? 'incomplete' : 'passed');
    return { directory: result.directory, expected: item.expected, observed: result.summary, independent: result.reopened.summary };
  });
  write(`fault-${id}-reduction-actual`, { actual, sizes, strictly_smaller: true, infrastructure_failure: false, killed: true });
  faults.push(id);
}

write('smoke-original', fixture.smoke);
const smoke = [];
for (let index = 0; index < fixture.smoke.calls; index++) {
  const root = join(owner, `smoke-${index}`);
  mkdirSync(root);
  writeFileSync(join(root, 'source.txt'), Buffer.from([0, 255]));
  chmodSync(join(root, 'source.txt'), 0o644);
  const directory = join(root, 'var/conjunct/attempts/record');
  const expected = { state: 'passed', recording_complete: true, source_unchanged: true, required_complete: true,
    commands: [command('completed')] };
  write(`smoke-${index}-original`, { root, directory, required: ['completed'], source: { 'source.txt': { mode: 0o644, bytes: [0, 255] } }, expected });
  const started = process.hrtime.bigint();
  const attempt = new candidate.Attempt({ root, directory, scope: 'smoke', sourcePaths: ['source.txt'], required: ['completed'] });
  attempt.completion({ index });
  const summary = attempt.finish();
  const reopened = reopenAttempt(directory);
  const actual = { elapsed_ns: Number(process.hrtime.bigint() - started), summary, reopened };
  write(`smoke-${index}-actual`, actual);
  assert.deepEqual(summary, expected);
  assert.deepEqual(reopened.summary, expected);
  assert(reopened.valid);
  smoke.push(actual.elapsed_ns);
}
const after = sourceSnapshot(repository, paths);
write('source-actual', after);
assert.deepEqual(after, originalSource, 'consumer source changed during qualification');
const report = { state: 'passed', norm: 'dc2a5b6d8c4da45ec27a8de134f0b1b962a728bb', hands: hands.length, seeds: fixture.seeds, successful_cases: campaigns,
  faults, reduced_actual_reruns: faults.length, smoke_calls: smoke.length, smoke_elapsed_ns: smoke, timing_budget: null,
  controlled_performance_qualified: false, package_archives_qualified: false, node: process.version };
write('result-actual', report);
console.log(`Retained attempt qualification passed: ${owner}; 7 hands, 300 schedules, 2 loaded/reduced faults, 10 smokes`);
} catch (error) {
  write('exception-actual', { name: error.name, message: error.message, code: error.code ?? null, stack: error.stack });
  if (!existsSync(join(owner, 'source-actual.json.gz'))) write('source-actual', sourceSnapshot(repository, paths));
  throw error;
}
