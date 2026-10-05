#!/usr/bin/env node
import { readPinnedFingerprint } from './files.mjs';
import { verifyPublishedArtifacts, verifyRelease } from './manifest.mjs';

const [manifestPath, signaturePath, publicKeyPath, artifactDirectory, trustFile, publicOption] =
  process.argv.slice(2);
if (!manifestPath || !signaturePath || !publicKeyPath || !artifactDirectory || !trustFile ||
    (process.argv.length !== 7 && process.argv.length !== 8) ||
    (publicOption && publicOption !== '--public')) {
  process.stderr.write('usage: node release/verify.mjs MANIFEST SIGNATURE PUBLIC_KEY ARTIFACT_DIR PINNED_KEY_SHA256_FILE [--public]\n');
  process.exit(64);
}

try {
  const trustedKeyDigest = await readPinnedFingerprint(trustFile);
  const manifest = await verifyRelease({ manifestPath, signaturePath, publicKeyPath,
    trustedKeyDigest, artifactDirectory });
  if (publicOption) await verifyPublishedArtifacts(manifest);
  process.stdout.write(`verified ${manifest.version}: ${manifest.artifacts.length} exact artifacts${publicOption ? ' and public URLs' : ''}\n`);
} catch {
  process.stderr.write('release verification refused: invalid input, trust or custody\n');
  process.exitCode = 1;
}
