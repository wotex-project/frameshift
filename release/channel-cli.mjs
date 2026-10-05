import { readPinnedFingerprint } from './files.mjs';
import { inspectReleaseChannel } from './channel.mjs';

const [repository, manifestPath, signaturePath, publicKeyPath, artifactDirectory, trustFile, ...extra] = process.argv.slice(2);
if (!trustFile || extra.length) {
  process.stderr.write('usage: inspect-release-channel OWNER/REPO MANIFEST SIGNATURE PUBLIC_KEY ARTIFACT_DIR TRUST_FILE\n');
  process.exitCode = 64;
} else {
  try {
    const trustedKeyDigest = await readPinnedFingerprint(trustFile);
    const observation = await inspectReleaseChannel({ repository, manifestPath, signaturePath, publicKeyPath, artifactDirectory, trustedKeyDigest });
    process.stdout.write(JSON.stringify(observation) + '\n');
    if (observation.state !== 'public-bytes-verified') process.exitCode = 2;
  } catch {
    process.stderr.write('release channel inspection refused: local trust, channel, public bytes or custody\n');
    process.exitCode = 1;
  }
}
