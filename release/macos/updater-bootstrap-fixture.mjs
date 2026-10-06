import assert from 'node:assert/strict';
import { spawnSync } from 'node:child_process';
import { chmodSync, copyFileSync, existsSync, mkdirSync, mkdtempSync, readFileSync, readdirSync, realpathSync, rmSync, writeFileSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { dirname, join, resolve } from 'node:path';
import { fileURLToPath } from 'node:url';

// The actual setup script uses an isolated GH transport stand-in. The native
// archive/manifest reader remains real; no remote write or update client runs.
const repository = resolve(dirname(fileURLToPath(import.meta.url)), '../..');
let work, complete = false;
try {
  assert.equal(process.platform, 'darwin');
  assert.equal(process.argv.length, 3);
  const archive = resolve(process.argv[2]);
  work = mkdtempSync(join(realpathSync(tmpdir()), 'frameshift-updater-bootstrap-'));
  chmodSync(work, 0o700);
  for (const scenario of ['existing', 'partial', 'competing', 'state']) {
    const root = join(work, scenario), scripts = join(root, 'scripts'), packageRoot = join(root, 'apps/macos');
    const toolRoot = join(root, 'release/macos/.build/release'), bin = join(root, 'bin');
    for (const path of [scripts, packageRoot, toolRoot, bin]) mkdirSync(path, { recursive: true, mode: 0o700 });
    copyFileSync(join(repository, 'scripts/prepare-macos-sdk'), join(scripts, 'prepare-macos-sdk'));
    copyFileSync(join(repository, 'apps/macos/Package.swift'), join(packageRoot, 'Package.swift'));
    copyFileSync(join(repository, 'release/macos/.build/release/frameshift-mac-release'), join(toolRoot, 'frameshift-mac-release'));
    chmodSync(join(toolRoot, 'frameshift-mac-release'), 0o755);
    const original = join(packageRoot, '.build/sparkle/Sparkle-for-Swift-Package-Manager.zip');
    const marker = join(root, 'gh-called');
    writeFileSync(join(bin, 'gh'), `#!/bin/sh
set -eu
download=''
while [ "$#" -gt 0 ]; do
  if [ "$1" = '--dir' ]; then shift; download=$1; fi
  shift
done
/bin/cp "$FRAMESHIFT_BOOTSTRAP_FIXTURE_ARCHIVE" "$download/Sparkle-for-Swift-Package-Manager.zip"
printf 'competing input' > "$FRAMESHIFT_BOOTSTRAP_FIXTURE_ORIGINAL"
printf 'called' > "$FRAMESHIFT_BOOTSTRAP_FIXTURE_MARKER"
`, { mode: 0o755 });
    if (scenario !== 'competing') mkdirSync(dirname(original), { recursive: true, mode: 0o700 });
    else mkdirSync(join(packageRoot, '.build'), { mode: 0o700 });
    if (scenario === 'existing') writeFileSync(original, 'retained input', { mode: 0o600 });
    if (scenario === 'state') {
      copyFileSync(archive, original); chmodSync(original, 0o600);
      writeFileSync(join(packageRoot, '.build/workspace-state.json'), '{"retained":"invalid"}\n', { mode: 0o600 });
    }
    const before = existsSync(original) ? readFileSync(original) : undefined;
    const result = spawnSync('/bin/sh', [join(scripts, 'prepare-macos-sdk')], {
      encoding: 'utf8', timeout: 180_000, maxBuffer: 64 * 1024,
      env: { ...process.env, PATH: `${bin}:/usr/bin:/bin:/usr/sbin:/sbin`,
        FRAMESHIFT_BOOTSTRAP_FIXTURE_ARCHIVE: archive,
        FRAMESHIFT_BOOTSTRAP_FIXTURE_ORIGINAL: original,
        FRAMESHIFT_BOOTSTRAP_FIXTURE_MARKER: marker },
    });
    assert.equal(result.error, undefined);
    assert.notEqual(result.status, 0);
    if (before) assert.deepEqual(readFileSync(original), before);
    assert.equal(existsSync(marker), scenario === 'competing');
    if (scenario === 'competing') {
      assert.equal(readFileSync(original, 'utf8'), 'competing input');
      const retained = readdirSync(join(packageRoot, '.build')).filter(name => name.startsWith('.sparkle.'));
      assert.equal(retained.length, 1);
      assert.deepEqual(readFileSync(join(packageRoot, '.build', retained[0], 'Sparkle-for-Swift-Package-Manager.zip')), readFileSync(archive));
    }
    if (scenario === 'state') assert.equal(readFileSync(join(packageRoot, '.build/workspace-state.json'), 'utf8'), '{"retained":"invalid"}\n');
  }
  complete = true;
  process.stdout.write('Updater bootstrap fixture passed: existing/partial inputs refuse without fetch; competing original and invalid retained state survive unchanged\n');
} catch {
  process.stderr.write('Updater bootstrap fixture refused; private evidence retained\n');
  process.exitCode = 1;
} finally {
  if (complete) rmSync(work, { recursive: true });
}
