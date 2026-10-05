import assert from 'node:assert/strict';
import { chmodSync, copyFileSync, mkdirSync, readFileSync, rmSync, symlinkSync, writeFileSync } from 'node:fs';
import { dirname, join } from 'node:path';
import test from 'node:test';
import { auditMacBundle } from './closure.mjs';
import { fixture, run } from './fixture.mjs';
import { prepareDevelopmentBundle } from './prepare.mjs';
import { sparkleContainers, sparkleLinks, sparkleRoles, sparkleRoot } from '../macos-framework.mjs';

const mac = { skip: process.platform !== 'darwin' };
function frameworkFixture(t) {
  const f = fixture(t), framework = join(f.root, sparkleRoot);
  mkdirSync(join(framework, 'Versions/B/Resources'), { recursive: true });
  for (const name of ['Headers', 'Modules', 'PrivateHeaders']) mkdirSync(join(framework, 'Versions/B', name));
  for (const [path, type] of sparkleRoles) {
    mkdirSync(dirname(join(f.root, path)), { recursive: true });
    copyFileSync(join(f.parent, type === 6 ? 'lib' : 'exe'), join(f.root, path)); chmodSync(join(f.root, path), 0o755);
  }
  for (const [path, target] of sparkleLinks) symlinkSync(target, join(f.root, path));
  const plist = (executable, identifier, type) => `<plist version="1.0"><dict><key>CFBundleExecutable</key><string>${executable}</string><key>CFBundleIdentifier</key><string>${identifier}</string><key>CFBundlePackageType</key><string>${type}</string><key>CFBundleShortVersionString</key><string>2.10.0</string><key>CFBundleVersion</key><string>1</string></dict></plist>`;
  writeFileSync(join(framework, 'Versions/B/Resources/Info.plist'), plist('Sparkle', 'org.sparkle-project.Sparkle', 'FMWK'));
  for (const path of sparkleContainers.slice(0, -1)) {
    const name = path.includes('Downloader') ? 'Downloader' : path.includes('Installer') ? 'Installer' : 'Updater';
    writeFileSync(join(f.root, path, 'Contents/Info.plist'), plist(name, `io.frameshift.fixture.${name}`, 'APPL'));
  }
  run('/usr/bin/install_name_tool', ['-id', '@rpath/Sparkle.framework/Versions/B/Sparkle', join(framework, 'Versions/B/Sparkle')]);
  run('/usr/bin/xcrun', ['clang', '-arch', 'arm64', '-mmacosx-version-min=14.0', '-F', join(f.root, 'Contents/Frameworks'),
    '-framework', 'Sparkle', '-Wl,-rpath,@loader_path/../Frameworks', join(f.parent, 'fixture.c'), '-o', join(f.root, 'Contents/MacOS/Frameshift')]);
  return { ...f, framework };
}

test('compiled shell joins the complete fixed framework and private preparation seals all nested code', mac, async t => {
  const f = frameworkFixture(t), report = await auditMacBundle(f.root, 'arm64');
  assert.equal(report.natives.length, 12); assert.deepEqual(new Map(report.links.map(link => [link.path, link.target])), sparkleLinks);
  const signed = await prepareDevelopmentBundle(f.root, 'arm64');
  assert.deepEqual(signed.links, report.links);
  for (const path of sparkleContainers) run('/usr/bin/codesign', ['--verify', '--strict', join(f.root, path)]);
  run('/usr/bin/codesign', ['--verify', '--deep', '--strict', f.root]);
});

test('missing, retargeted, dangling and unrelated aliases retain bytes and refuse', mac, async t => {
  const f = frameworkFixture(t), path = join(f.framework, 'Resources');
  rmSync(path); await assert.rejects(auditMacBundle(f.root, 'arm64'), /missing framework link/);
  for (const target of ['/tmp', 'Versions/B/Resources', 'Resources', 'Versions/Current/missing', '../../..']) {
    symlinkSync(target, path); await assert.rejects(auditMacBundle(f.root, 'arm64'), /framework link/); rmSync(path);
  }
  symlinkSync('Versions/Current/Resources', path);
  rmSync(join(f.framework, 'Versions/B/Headers'), { recursive: true });
  await assert.rejects(auditMacBundle(f.root, 'arm64'), /dangling framework link/);
  mkdirSync(join(f.framework, 'Versions/B/Headers'));
  const extra = join(f.root, 'Contents/Resources/unrelated'); symlinkSync('../Frameworks/Sparkle.framework', extra);
  await assert.rejects(auditMacBundle(f.root, 'arm64'), /links/);
});

test('framework identity, role type and additional native code refuse despite a valid shell import', mac, async t => {
  const f = frameworkFixture(t), plist = join(f.framework, 'Versions/B/Resources/Info.plist'), original = readFileSync(plist);
  for (const replacement of [['2.10.0', '2.9.3'], ['org.sparkle-project.Sparkle', 'io.other.Sparkle']]) {
    writeFileSync(plist, original.toString().replace(...replacement)); await assert.rejects(auditMacBundle(f.root, 'arm64'), /framework identity/);
  }
  writeFileSync(plist, original);
  const autoupdate = join(f.framework, 'Versions/B/Autoupdate'), bytes = readFileSync(autoupdate);
  copyFileSync(join(f.parent, 'lib'), autoupdate); await assert.rejects(auditMacBundle(f.root, 'arm64'), /framework native role/);
  writeFileSync(autoupdate, bytes);
  copyFileSync(join(f.parent, 'exe'), join(f.framework, 'Versions/B/extra'));
  await assert.rejects(auditMacBundle(f.root, 'arm64'), /framework native role/);
});

test('only the main shell single explicit run path resolves Sparkle; arbitrary and inherited imports refuse', mac, async t => {
  const f = frameworkFixture(t), shell = join(f.root, 'Contents/MacOS/Frameshift');
  run('/usr/bin/install_name_tool', ['-add_rpath', '@loader_path', shell]);
  await assert.rejects(auditMacBundle(f.root, 'arm64'), /unsupported or outside/);
  run('/usr/bin/install_name_tool', ['-delete_rpath', '@loader_path', shell]);
  run('/usr/bin/install_name_tool', ['-delete_rpath', '@loader_path/../Frameworks', shell]);
  await assert.rejects(auditMacBundle(f.root, 'arm64'), /unsupported or outside/);
  run('/usr/bin/install_name_tool', ['-add_rpath', '@executable_path/../Frameworks', shell]);
  await auditMacBundle(f.root, 'arm64');
  const cli = join(f.root, 'Contents/MacOS/frameshiftctl');
  run('/usr/bin/install_name_tool', ['-change', '/usr/lib/libSystem.B.dylib', '@rpath/Sparkle.framework/Versions/B/Sparkle', cli]);
  await assert.rejects(auditMacBundle(f.root, 'arm64'), /unsupported or outside/);
  run('/usr/bin/install_name_tool', ['-change', '@rpath/Sparkle.framework/Versions/B/Sparkle', '/usr/lib/libSystem.B.dylib', cli]);
  run('/usr/bin/install_name_tool', ['-change', '@rpath/Sparkle.framework/Versions/B/Sparkle', '@rpath/Other.framework/Other', shell]);
  await assert.rejects(auditMacBundle(f.root, 'arm64'), /missing shell framework import/);
});
