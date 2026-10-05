import { signMacChannels } from './channels.mjs';

const args = process.argv.slice(2);
if (args.length !== 9) {
  process.stderr.write('usage: scripts/sign-macos-channels MANIFEST SIGNATURE PUBLIC_KEY ARTIFACT_DIR RELEASE_TRUST MINIMUM_OS SPARKLE_SEED SPARKLE_TRUST OUTPUT\n');
  process.exitCode = 64;
} else {
  const [manifestPath, signaturePath, publicKeyPath, artifactDirectory, releaseTrustPath, minimumOS,
    sparkleSeedPath, sparkleTrustPath, outputDirectory] = args;
  try {
    const result = await signMacChannels({ manifestPath, signaturePath, publicKeyPath, artifactDirectory,
      releaseTrustPath, minimumOS, sparkleSeedPath, sparkleTrustPath, outputDirectory });
    process.stdout.write(`Signed Mac channel material: ${result.version}; ${result.disposition}; publication authority none\n`);
  } catch {
    process.stderr.write('Mac channel signing refused\n'); process.exitCode = 1;
  }
}
