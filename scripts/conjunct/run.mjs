import assert from 'node:assert/strict';
import { spawnSync } from 'node:child_process';
import { fileURLToPath } from 'node:url';

const stage = spawnSync(process.execPath, [fileURLToPath(new URL('./stage.mjs', import.meta.url))],
  { encoding: 'utf8', stdio: ['ignore', 'pipe', 'inherit'], maxBuffer: 32 * 1024 * 1024 });
if (stage.error) throw stage.error;
assert.equal(stage.status, 0, stage.stdout);
const result = JSON.parse(stage.stdout.trim());
console.log(`Verified bundle: ${result.bundle} (${result.manifest_digest})`);
const check = spawnSync(process.execPath, [fileURLToPath(new URL('./check.mjs', import.meta.url)), result.bundle, result.manifest_digest],
  { stdio: 'inherit' });
if (check.error) throw check.error;
assert.equal(check.status, 0);
