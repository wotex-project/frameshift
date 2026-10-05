import { spawnSync } from 'node:child_process';
import { lstat } from 'node:fs/promises';
import { basename, dirname, join, posix, resolve } from 'node:path';
import { auditMacBundle } from './closure.mjs';
import { sparkleContainers } from './sparkle-framework.mjs';

const run = (command, args) => {
  const result = spawnSync(command, args, { encoding: 'utf8', timeout: 15_000, maxBuffer: 64 * 1024 });
  if (result.error || result.status !== 0) throw new Error(`development bundle ${basename(command)} refused`);
  return result.stdout.trim();
};

// Only the unpublished, private package-macos stage is mutable. This operation
// never patches minimum-OS load commands or rewrites imported library names.
export async function prepareDevelopmentBundle(input, architecture) {
  const root = resolve(input), parent = dirname(root), stat = await lstat(parent);
  if (basename(root) !== 'Frameshift.app' || !/^\.package\.[a-zA-Z0-9]+$/.test(basename(parent)) || !stat.isDirectory() || stat.uid !== process.getuid() || (stat.mode & 0o7777) !== 0o700) throw new Error('private development stage required');
  const before = await auditMacBundle(root, architecture, { enforceMinimum: false, enforcePaths: false });
  const compiler = run('/usr/bin/xcrun', ['--find', 'swift']);
  if (!compiler.startsWith('/') || !compiler.endsWith('/usr/bin/swift')) throw new Error('unknown Swift toolchain');
  const toolchain = resolve(dirname(compiler), '..');
  for (const file of before.natives) {
    const removable = [...new Set(file.slices.flatMap(slice => slice.rpaths).filter(path => path.startsWith(`${toolchain}/lib/`) && posix.normalize(path) === path))];
    if (!removable.length) continue;
    if (file.slices.some(slice => slice.dependencies.some(path => path.startsWith('@rpath/')))) throw new Error('toolchain run-path dependency unavailable');
    const path = join(root, file.path);
    run('/usr/bin/codesign', ['--remove-signature', path]);
    for (const rpath of removable) run('/usr/bin/install_name_tool', ['-delete_rpath', rpath, path]);
  }
  run('/usr/bin/plutil', ['-replace', 'LSMinimumSystemVersion', '-string', before.nativeMinimum, join(root, 'Contents/Info.plist')]);
  const admitted = await auditMacBundle(root, architecture);
  // codesign recognizes the main executable as its enclosing app. Sign every
  // other leaf first; the final app operation signs its main executable too.
  for (const file of admitted.natives.filter(file => file.path !== 'Contents/MacOS/Frameshift')) run('/usr/bin/codesign', ['--force', '--sign', '-', '--timestamp=none', join(root, file.path)]);
  if (admitted.links) for (const path of sparkleContainers) run('/usr/bin/codesign', ['--force', '--sign', '-', '--timestamp=none', join(root, path)]);
  run('/usr/bin/codesign', ['--force', '--sign', '-', '--timestamp=none', root]);
  run('/usr/bin/codesign', ['--verify', '--deep', '--strict', root]);
  return auditMacBundle(root, architecture);
}

if (process.argv[1] === new URL(import.meta.url).pathname) {
  const args = process.argv.slice(2);
  if (args.length !== 2) { console.error('usage: prepare.mjs PRIVATE_STAGE ARCHITECTURE'); process.exitCode = 64; }
  else {
    try { const result = await prepareDevelopmentBundle(...args); console.log(`development bundle: ${result.architecture}, minimum macOS ${result.declaredMinimum}`); }
    catch { console.error('development bundle preparation refused'); process.exitCode = 1; }
  }
}
