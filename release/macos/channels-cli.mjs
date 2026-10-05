import { deriveMacChannels } from './channels.mjs';

const args = process.argv.slice(2);
if (args.length !== 9) {
  process.stderr.write('usage: scripts/derive-macos-channels MANIFEST SIGNATURE PUBLIC_KEY ARTIFACT_DIR RELEASE_TRUST MINIMUM_OS SPARKLE_SIGNATURE SPARKLE_TRUST OUTPUT\n');
  process.exitCode = 64;
} else {
  const [manifestPath, signaturePath, publicKeyPath, artifactDirectory, releaseTrustPath, minimumOS,
    sparkleSignaturePath, sparkleTrustPath, outputDirectory] = args;
  try {
    const result = await deriveMacChannels({ manifestPath, signaturePath, publicKeyPath, artifactDirectory,
      releaseTrustPath, minimumOS, sparkleSignaturePath, sparkleTrustPath, outputDirectory });
    process.stdout.write(`Mac channel material: ${result.version}; ${result.disposition}; publication authority none\n`);
  } catch {
    process.stderr.write('Mac channel material refused\n');
    process.exitCode = 1;
  }
}
