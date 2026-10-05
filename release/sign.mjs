#!/usr/bin/env node
import { readPinnedFingerprint } from './files.mjs';
import { signRelease } from './signer.mjs';

const [planPath, artifactDirectory, privateKeyPath, trustFile, outputDirectory] =
  process.argv.slice(2);
if (process.argv.length !== 7) {
  process.stderr.write('usage: node release/sign.mjs PLAN.json ARTIFACT_DIR PRIVATE_KEY.pem PINNED_KEY_SHA256_FILE NEW_OUTPUT_DIR\n');
  process.exit(64);
}

try {
  const trustedKeyDigest = await readPinnedFingerprint(trustFile);
  const result = await signRelease({ planPath, artifactDirectory, privateKeyPath,
    trustedKeyDigest, outputDirectory });
  process.stdout.write(`signed ${result.version}: ${result.artifactCount} exact artifacts\n`);
} catch {
  process.stderr.write('release signing refused: invalid input, trust or custody\n');
  process.exitCode = 1;
}
