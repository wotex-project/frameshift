import assert from 'node:assert/strict';
import { spawnSync } from 'node:child_process';
import { lstatSync, mkdirSync, readdirSync, readFileSync, writeFileSync } from 'node:fs';
import { isDeepStrictEqual } from 'node:util';
import { isAbsolute, join, relative, resolve, sep } from 'node:path';
import { gunzipSync, gzipSync } from 'node:zlib';

const namePattern = /^[a-z][a-z0-9.-]*$/;
const errorValue = error => error ? { name: error.name, code: error.code ?? null,
  message: error.message, syscall: error.syscall ?? null, path: error.path ?? null } : null;
export const readRecord = (directory, name) => JSON.parse(gunzipSync(readFileSync(join(directory, `${name}.json.gz`))).toString('utf8'));

export function sourceSnapshot(root, paths) {
  return Object.fromEntries(paths.map(path => {
    assert(typeof path === 'string' && path !== '' && !isAbsolute(path) &&
      !path.split(/[\\/]/).includes('..'), 'source path must be relative and confined');
    try {
      const file = join(root, path);
      const stat = lstatSync(file);
      assert(stat.isFile() && !stat.isSymbolicLink(), 'source must be an ordinary file');
      return [path, { mode: stat.mode & 0o7777, bytes: [...readFileSync(file)] }];
    } catch (error) { return [path, { error: errorValue(error) }]; }
  }));
}

export function consumerSources(root) {
  const walk = path => readdirSync(join(root, path)).sort().flatMap(name => {
    const item = join(path, name);
    return lstatSync(join(root, item)).isDirectory() ? walk(item) : [item];
  });
  return [...walk('scripts/conjunct'), 'docs/architecture/conjunct-integration.md'].sort();
}

/** Explicit, call-owned observations for one source-built consumer attempt. */
export class Attempt {
  constructor({ root, directory, scope, sourcePaths, required }) {
    this.root = resolve(root);
    this.directory = resolve(directory);
    assert(relative(join(this.root, 'var/conjunct/attempts'), this.directory) !== '' &&
      this.directory.startsWith(join(this.root, 'var/conjunct/attempts') + sep), 'attempt must have its own ignored directory');
    assert(namePattern.test(scope) && required.length > 0 && required.every(name => namePattern.test(name)) &&
      new Set(required).size === required.length, 'invalid attempt scope/requirements');
    mkdirSync(resolve(this.directory, '..'), { recursive: true });
    mkdirSync(this.directory);
    this.sourcePaths = [...sourcePaths];
    this.commands = [];
    this.closed = false;
    this.write('request-original', { version: 'frameshift.conjunct-attempt.v1', root: this.root,
      directory: this.directory, scope, sourcePaths: this.sourcePaths, required: [...required] });
    this.write('initial-state', { state: 'incomplete' });
    this.write('source-original', sourceSnapshot(this.root, this.sourcePaths));
  }

  write(name, value) {
    assert(namePattern.test(name), 'invalid record name');
    writeFileSync(join(this.directory, `${name}.json.gz`), gzipSync(JSON.stringify(value)), { flag: 'wx' });
  }

  retainBytes(name, path) {
    this.write(`${name}-original`, { path: resolve(path) });
    let bytes;
    try {
      bytes = readFileSync(path);
    } catch (error) {
      this.write(`${name}-actual`, { bytes: null, error: errorValue(error) });
      throw error;
    }
    this.write(`${name}-actual`, { bytes: [...bytes], error: null });
    return bytes;
  }

  command({ id, program, args, cwd, env, maxBuffer = 32 * 1024 * 1024 }) {
    assert(!this.closed && namePattern.test(id) && !this.commands.includes(id), 'duplicate/closed command');
    assert(typeof program === 'string' && args.every(arg => typeof arg === 'string') &&
      typeof cwd === 'string' && env && Number.isSafeInteger(maxBuffer) && maxBuffer > 0, 'invalid command');
    this.commands.push(id);
    this.write(`${id}-original`, { index: this.commands.length - 1, id, program, args, cwd, env, maxBuffer });
    const actual = spawnSync(program, args, { cwd, env, maxBuffer, encoding: null, stdio: ['ignore', 'pipe', 'pipe'] });
    this.write(`${id}-actual`, { id, status: actual.status, signal: actual.signal,
      error: errorValue(actual.error), stdout: [...(actual.stdout ?? [])], stderr: [...(actual.stderr ?? [])] });
    return actual;
  }

  completion(value) {
    assert(!this.closed && !this.commands.includes('completed'), 'duplicate/closed completion');
    this.commands.push('completed');
    this.write('completed-original', { index: this.commands.length - 1, id: 'completed', value });
    this.write('completed-actual', { id: 'completed', status: 0, signal: null, error: null, stdout: [], stderr: [], value });
  }

  beginChild({ id, program, args, cwd, env, maxBuffer = 32 * 1024 * 1024 }) {
    assert(!this.closed && namePattern.test(id) && !this.commands.includes(id), 'duplicate/closed child');
    this.commands.push(id);
    this.write(`${id}-original`, { index: this.commands.length - 1, id, program, args, cwd, env, maxBuffer });
  }

  endChild(id, { status, signal, error, stdout, stderr }) {
    assert(!this.closed && this.commands.includes(id), 'unknown/closed child');
    this.write(`${id}-actual`, { id, status, signal, error: errorValue(error), stdout: [...stdout], stderr: [...stderr] });
  }

  finish() {
    assert(!this.closed, 'attempt already closed');
    this.closed = true;
    this.write('source-actual', sourceSnapshot(this.root, this.sourcePaths));
    const summary = summarize(this.directory);
    this.write('result-actual', summary);
    return summary;
  }

  failure(error) {
    this.write('exception-actual', errorValue(error));
    if (!this.closed) return this.finish();
    return readRecord(this.directory, 'result-actual');
  }
}

export function summarize(directory) {
  const input = readRecord(directory, 'request-original');
  const before = readRecord(directory, 'source-original');
  const after = readRecord(directory, 'source-actual');
  const names = readdirSync(directory).filter(name => name.endsWith('-original.json.gz') &&
    !['request-original.json.gz', 'source-original.json.gz'].includes(name));
  const allOriginals = names.map(name => ({ name: name.slice(0, -8), value: readRecord(directory, name.slice(0, -8)) }));
  const originals = allOriginals.map(row => row.value).filter(row => row.id);
  originals.sort((a, b) => a.index - b.index);
  const commands = [];
  let recordingComplete = true;
  let observationError = false;
  for (const row of allOriginals.filter(row => !row.value.id)) {
    try {
      const actual = readRecord(directory, row.name.replace(/-original$/, '-actual'));
      observationError ||= actual.error != null;
    }
    catch { recordingComplete = false; }
  }
  for (const row of originals) {
    try {
      const actual = readRecord(directory, `${row.id}-actual`);
      assert(actual.id === row.id);
      commands.push({ id: row.id, status: actual.status, signal: actual.signal,
        error: actual.error?.code ?? (actual.error ? actual.error.name : null), stdout: actual.stdout, stderr: actual.stderr });
    } catch { recordingComplete = false; }
  }
  const sourceUnchanged = isDeepStrictEqual(before, after) &&
    Object.values(before).every(value => !value.error) && Object.values(after).every(value => !value.error);
  const requiredComplete = input.required.every(id => commands.some(command => command.id === id));
  const failed = commands.some(command => command.status !== null && command.status !== 0);
  const incomplete = !recordingComplete || !sourceUnchanged || (!requiredComplete && !failed) || observationError ||
    commands.some(command => command.error !== null || command.status === null || command.signal !== null) ||
    (readdirSync(directory).includes('exception-actual.json.gz') && commands.every(command => command.status === 0));
  return { state: incomplete ? 'incomplete' : failed ? 'failed' : 'passed',
    recording_complete: recordingComplete, source_unchanged: sourceUnchanged,
    required_complete: requiredComplete, commands };
}
