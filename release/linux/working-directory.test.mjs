import assert from 'node:assert/strict';
import { spawnSync } from 'node:child_process';
import { chmodSync, mkdirSync, mkdtempSync, readFileSync, realpathSync, rmSync, writeFileSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join, resolve } from 'node:path';
import test from 'node:test';
const policy = resolve(new URL('./policy.sh', import.meta.url).pathname);
function fixture(t) { const root = mkdtempSync(join(tmpdir(), 'frameshift-cli-cwd-')); t.after(() => { chmodSync(root, 0o700); rmSync(root, { recursive: true, force: true }); }); return root; }
function run(cwd, paths = [], unreadable = false) { return spawnSync('/bin/sh', ['-eu', '-c', '. "$1"; shift; if [ "$1" = unreadable ]; then chmod 000 .; fi; shift; frameshift_working_directory "$@"; pwd -P', 'fixture', policy, unreadable ? 'unreadable' : 'usable', ...paths], { cwd, encoding: 'utf8', timeout: 5000 }); }
test('usable caller cwd preserves relative file meaning and literal argument bytes', t => {
  const root = fixture(t), file = 'input $() `literal`'; writeFileSync(join(root, file), 'owned'); const result = run(root, [file]); assert.equal(result.status, 0); assert.equal(result.stdout.trim(), realpathSync(root)); assert.equal(readFileSync(join(root, file), 'utf8'), 'owned');
});
test('unreadable cwd permits path-free/absolute commands and refuses relative file paths before moving', t => {
  const root = fixture(t); for (const paths of [[], ['/absolute input $() `literal`']]) { chmodSync(root, 0o700); const result = run(root, paths, true); assert.equal(result.status, 0); assert.equal(result.stdout, '/\n'); }
  chmodSync(root, 0o700); const result = run(root, ['relative input'], true); assert.equal(result.status, 69); assert.equal(result.stdout, ''); assert.equal(result.stderr, 'frameshift: installed service policy or directory custody unavailable\n');
});
test('unlinked cwd uses explicit fallback without reinterpreting a relative import/restore path', t => {
  const root = fixture(t); function removed(paths) { const path = join(root, 'removed-' + paths.length + '-' + Math.random().toString(16).slice(2)); mkdirSync(path); return spawnSync('/bin/sh', ['-eu', '-c', 'cd "$1"; rmdir "$1"; . "$2"; shift 2; frameshift_working_directory "$@"; pwd -P', 'fixture', path, policy, ...paths], { cwd: root, encoding: 'utf8', timeout: 5000 }); }
  for (const paths of [[], ['/absolute']]) { const result = removed(paths); assert.equal(result.status, 0); assert.equal(result.stdout, '/\n'); }
  const result = removed(['/absolute', 'relative']); assert.equal(result.status, 69); assert.equal(result.stdout, ''); assert.equal(result.stderr.includes('relative'), false);
});
