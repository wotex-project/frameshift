import assert from 'node:assert/strict';
import { mkdirSync, mkdtempSync } from 'node:fs';
import { join, resolve } from 'node:path';
import { fileURLToPath } from 'node:url';
import { Attempt, consumerSources } from './attempt.mjs';
import { verifyAttempt } from './readback.mjs';

const repository = resolve(fileURLToPath(new URL('../..', import.meta.url)));
const parent = join(repository, 'var/conjunct/attempts');
mkdirSync(parent, { recursive: true });
const attempt = new Attempt({ root: repository, directory: join(mkdtempSync(join(parent, 'joint-')), 'record'),
  scope: 'joint', sourcePaths: consumerSources(repository), required: ['stage', 'check', 'completed'] });

function child(id, args) {
  const actual = attempt.command({ id, program: process.execPath, args, cwd: repository, env: process.env });
  process.stderr.write(actual.stderr ?? Buffer.alloc(0));
  if (actual.error) throw actual.error;
  assert.equal(actual.status, 0, actual.stdout?.toString());
  return JSON.parse(actual.stdout.toString('utf8').trim());
}

try {
  const stage = child('stage', [fileURLToPath(new URL('./stage.mjs', import.meta.url))]);
  attempt.write('stage-readback-original', { directory: stage.attempt });
  attempt.write('stage-readback-actual', verifyAttempt(stage.attempt));
  const check = child('check', [fileURLToPath(new URL('./check.mjs', import.meta.url)), stage.bundle, stage.manifest_digest]);
  assert.equal(check.manifest_digest, stage.manifest_digest);
  attempt.write('check-readback-original', { directory: check.attempt });
  attempt.write('check-readback-actual', verifyAttempt(check.attempt));
  attempt.completion({ stage, check });
  assert.equal(attempt.finish().state, 'passed');
  verifyAttempt(attempt.directory);
  console.log(`Staged Elixir/Node/browser consumers pass: ${check.output}; custody ${attempt.directory}`);
} catch (error) {
  attempt.failure(error);
  throw error;
}
