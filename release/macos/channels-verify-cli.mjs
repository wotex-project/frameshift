import { verifyMacChannels } from './channels.mjs';

const args = process.argv.slice(2);
if (args.length !== 8) {
  process.stderr.write('usage: scripts/verify-macos-channels MANIFEST SIGNATURE PUBLIC_KEY ARTIFACT_DIR RELEASE_TRUST MINIMUM_OS SPARKLE_TRUST OUTPUT\n');
  process.exitCode = 64;
} else {
  const [manifestPath, signaturePath, publicKeyPath, artifactDirectory, releaseTrustPath, minimumOS,
    sparkleTrustPath, outputDirectory] = args;
  try {
    const result = await verifyMacChannels({ manifestPath, signaturePath, publicKeyPath, artifactDirectory,
      releaseTrustPath, minimumOS, sparkleTrustPath, outputDirectory });
    process.stdout.write(`Signed Mac channel material: ${result.version}; public-key-only bytes verified; publication authority none\n`);
  } catch {
    process.stderr.write('Mac channel verification refused\n'); process.exitCode = 1;
  }
}
