import assert from 'node:assert/strict';
import { spawnSync } from 'node:child_process';
import { chmodSync, copyFileSync, mkdirSync, mkdtempSync, realpathSync, rmSync, writeFileSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { dirname, join } from 'node:path';

export const run = (command, args) => {
  const result = spawnSync(command, args, { encoding: 'utf8', timeout: 30_000, maxBuffer: 64 * 1024 });
  assert.equal(result.status, 0, `${command}: ${result.stderr}`);
  return result.stdout.trim();
};
export const temporary = t => {
  const path = mkdtempSync(join(realpathSync(tmpdir()), '.package.'));
  t.after(() => rmSync(path, { recursive: true, force: true }));
  return path;
};
export const roles = [
  ['Contents/MacOS/Frameshift', 'exe'], ['Contents/MacOS/frameshiftctl', 'exe'],
  ['Contents/Resources/bin/frameshift-raster', 'exe'], ['Contents/Resources/core/erts-fixture/bin/beam.smp', 'exe'],
  ['Contents/Resources/core/lib/exile-fixture/priv/exile.so', 'lib'], ['Contents/Resources/core/lib/exile-fixture/priv/spawner', 'exe'],
  ['Contents/Resources/core/lib/exqlite-fixture/priv/sqlite3_nif.so', 'lib'],
];
export function fixture(t, architecture = 'arm64', rpath) {
  const parent = temporary(t), root = join(parent, 'Frameshift.app');
  mkdirSync(root);
  const source = join(parent, 'fixture.c'); writeFileSync(source, 'int fixture(void) { return 7; }\nint main(void) { return 0; }\n');
  const archs = architecture === 'universal' ? ['arm64', 'x86_64'] : [architecture];
  const outputs = {};
  for (const kind of ['exe', 'lib']) {
    const slices = archs.map(arch => {
      const output = join(parent, `${kind}-${arch}`);
      run('/usr/bin/xcrun', ['clang', '-arch', arch, '-mmacosx-version-min=14.0', ...(kind === 'lib' ? ['-dynamiclib', '-install_name', '@loader_path/fixture.dylib'] : []), ...(rpath ? ['-Wl,-rpath,' + rpath] : []), source, '-o', output]);
      return output;
    });
    outputs[kind] = join(parent, kind);
    if (slices.length === 2) run('/usr/bin/lipo', ['-create', ...slices, '-output', outputs[kind]]);
    else copyFileSync(slices[0], outputs[kind]);
  }
  for (const [relative, kind] of roles) { const path = join(root, relative); mkdirSync(dirname(path), { recursive: true }); copyFileSync(outputs[kind], path); chmodSync(path, 0o755); }
  writeFileSync(join(root, 'Contents/Info.plist'), '<plist version="1.0"><dict><key>CFBundleExecutable</key><string>Frameshift</string><key>CFBundleIdentifier</key><string>io.frameshift.closure-fixture</string><key>CFBundlePackageType</key><string>APPL</string><key>CFBundleVersion</key><string>1</string><key>LSMinimumSystemVersion</key><string>14.0</string></dict></plist>');
  return { root, parent };
}
