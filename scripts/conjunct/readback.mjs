import assert from 'node:assert/strict';
import { readdirSync, readFileSync } from 'node:fs';
import { join } from 'node:path';
import { isDeepStrictEqual } from 'node:util';
import { gunzipSync } from 'node:zlib';

const bytes = value => Array.isArray(value) && value.every(byte => Number.isInteger(byte) && byte >= 0 && byte <= 255);
const read = path => JSON.parse(gunzipSync(readFileSync(path)).toString('utf8'));

/** Reopen complete records without importing the candidate's state calculation. */
export function reopenAttempt(directory) {
  const records = Object.fromEntries(readdirSync(directory).sort().filter(name => name.endsWith('.json.gz'))
    .map(name => [name.slice(0, -8), read(join(directory, name))]));
  const request = records['request-original'];
  assert.equal(request.version, 'frameshift.conjunct-attempt.v1');
  assert.deepEqual(records['initial-state'], { state: 'incomplete' });
  assert(Array.isArray(request.sourcePaths) && Array.isArray(request.required));
  const before = records['source-original'];
  const after = records['source-actual'];
  const sourceValid = source => source && isDeepStrictEqual(Object.keys(source).sort(), [...request.sourcePaths].sort()) &&
    Object.values(source).every(value => bytes(value.bytes) && Number.isInteger(value.mode) && value.mode >= 0 && value.mode <= 0o7777);
  const sourceUnchanged = Boolean(sourceValid(before) && sourceValid(after) && isDeepStrictEqual(before, after));
  const commands = [];
  const originals = Object.entries(records).filter(([name]) => name.endsWith('-original') &&
    !['request-original', 'source-original'].includes(name));
  const children = originals.filter(([, row]) => row.id !== undefined).sort((a, b) => a[1].index - b[1].index);
  let complete = new Set(children.map(([, row]) => row.id)).size === children.length;
  let observationError = false;
  for (const [name, row] of originals.filter(([, row]) => row.id === undefined)) {
    const actual = records[name.replace(/-original$/, '-actual')];
    if (actual === undefined) complete = false;
    else observationError ||= actual.error != null;
  }
  for (const [index, [name, original]] of children.entries()) {
    const actual = records[name.replace(/-original$/, '-actual')];
    const originalValid = original.index === index && name === `${original.id}-original` &&
      (original.id === 'completed' || (typeof original.program === 'string' && Array.isArray(original.args) &&
        original.args.every(arg => typeof arg === 'string') && typeof original.cwd === 'string' &&
        original.env && typeof original.env === 'object' && Number.isSafeInteger(original.maxBuffer) && original.maxBuffer > 0));
    const actualValid = actual && actual.id === original.id && (actual.status === null || Number.isInteger(actual.status)) &&
      (actual.signal === null || typeof actual.signal === 'string') && (actual.error === null ||
        (typeof actual.error === 'object' && typeof actual.error.name === 'string' && typeof actual.error.message === 'string')) &&
      bytes(actual.stdout) && bytes(actual.stderr) &&
      (original.id !== 'completed' || (actual.status === 0 && isDeepStrictEqual(original.value, actual.value)));
    if (!originalValid || !actualValid) { complete = false; continue; }
    commands.push({ id: original.id, status: actual.status, signal: actual.signal,
      error: actual.error?.code ?? (actual.error ? actual.error.name : null), stdout: actual.stdout, stderr: actual.stderr });
  }
  for (const name of Object.keys(records).filter(name => name.endsWith('-actual') &&
    !['source-actual', 'result-actual', 'exception-actual'].includes(name))) {
    if (records[name.replace(/-actual$/, '-original')] === undefined) complete = false;
  }
  const required = request.required.every(id => commands.some(command => command.id === id));
  const nonzero = commands.some(command => command.status !== null && command.status !== 0);
  const missing = !complete || !sourceUnchanged || (!required && !nonzero) || observationError ||
    commands.some(command => command.error !== null || command.status === null || command.signal !== null) ||
    (records['exception-actual'] !== undefined && commands.every(command => command.status === 0));
  const summary = { state: missing ? 'incomplete' : nonzero ? 'failed' : 'passed', recording_complete: complete,
    source_unchanged: sourceUnchanged, required_complete: required, commands };
  return { request, records, summary, recorded_summary: records['result-actual'],
    valid: isDeepStrictEqual(summary, records['result-actual']) };
}

export function verifyAttempt(directory) {
  const reopened = reopenAttempt(directory);
  assert(reopened.valid, 'retained attempt summary differs from independent readback');
  assert.equal(reopened.summary.state, 'passed', 'retained attempt is not passed');
  return reopened;
}
