import { copyFileSync, mkdirSync, writeFileSync } from 'node:fs';
import { dirname, join } from 'node:path';
import { sparkleArchive, sparkleInputArchive, sparkleInputFramework } from '../macos-framework.mjs';
import { materialFixture } from './material-fixture.mjs';
import { run } from './fixture.mjs';
import { checkSparkleSource, readSparkleSourceReceipt } from './sparkle-source.mjs';
import { stageSparkleFramework } from './sparkle-material.mjs';

export async function sparkleJoinFixture(t, archive) {
  let sdk;
  const f = await materialFixture(t, {
    sourceFiles: {
      '.gitignore': 'var/\n_build/\ndeps/\nbuild/\n.build/\n',
      'apps/macos/Package.swift': `// swift-tools-version: 6.0\nimport PackageDescription\nlet package = Package(name: "UpdaterJoinFixture", platforms: [.macOS(.v14)], targets: [.binaryTarget(name: "Sparkle", url: "${sparkleArchive.url}", checksum: "${sparkleArchive.sha256}")])\n`,
    },
    prepareMaterial: async source => {
      const zip = join(source.repository, sparkleInputArchive), framework = join(source.repository, sparkleInputFramework);
      mkdirSync(dirname(zip), { recursive: true, mode: 0o700 }); copyFileSync(archive, zip);
      run('/bin/chmod', ['600', zip]);
      const artifact = join(source.repository, 'apps/macos/.build/artifacts/macos/Sparkle'); mkdirSync(artifact, { recursive: true });
      run('/usr/bin/unzip', ['-q', zip, 'Sparkle.xcframework/macos-arm64_x86_64/Sparkle.framework/*', '-d', artifact]);
      const output = join(source.repository, 'var/sdk-proof'), result = await checkSparkleSource({ ...source, archive: zip, framework, output });
      const sparklePath = join(output, 'sparkle-material.json'), receipt = await readSparkleSourceReceipt(sparklePath, result.receiptSha256, source.source);
      sdk = { sparklePath, sparkleSha256: result.receiptSha256, archive: zip, framework };
      return [...receipt.framework.files.map(file => ({ ...file, path: sparkleInputFramework + file.path })),
        { path: sparkleInputArchive, mode: 0o600, bytes: sparkleArchive.bytes, sha256: sparkleArchive.sha256 }];
    },
    prepareApp: async (native, architecture) => {
      await stageSparkleFramework(sdk.archive, native.root, architecture);
      const source = join(native.parent, 'controller.m');
      writeFileSync(source, '#import <Foundation/Foundation.h>\n#import <Sparkle/Sparkle.h>\nint main(void) { @autoreleasepool { SPUStandardUpdaterController *c = [[SPUStandardUpdaterController alloc] initWithStartingUpdater:NO updaterDelegate:nil userDriverDelegate:nil]; return c.updater == nil; } }\n');
      run('/usr/bin/xcrun', ['clang', '-arch', architecture, '-mmacosx-version-min=14.0', '-F', join(native.root, 'Contents/Frameworks'),
        '-framework', 'Sparkle', '-framework', 'Foundation', '-Wl,-rpath,@loader_path/../Frameworks', source, '-o', join(native.root, 'Contents/MacOS/Frameshift')]);
    },
  });
  return { ...f, ...sdk };
}
