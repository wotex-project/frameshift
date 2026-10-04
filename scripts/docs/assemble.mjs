import { assembleSite, recoverSite } from './assembly.mjs';

const args = process.argv.slice(2);
const usage = 'usage: scripts/assemble-site development DEV_SITE OUTPUT [TRUST_FILE]\n' +
  '       scripts/assemble-site release DEV_SITE RELEASE_DOCS OUTPUT MANIFEST SIGNATURE PUBLIC_KEY ARTIFACT_DIR TRUST_FILE SOURCE_COMMIT\n' +
  '       scripts/assemble-site recover OUTPUT [TRUST_FILE]\n';
try {
  let result;
  if (args[0] === 'development' && [3, 4].includes(args.length)) {
    result = await assembleSite({ development: args[1], output: args[2], trustFile: args[3] });
  } else if (args[0] === 'release' && args.length === 10) {
    const [, development, candidate, output, manifestPath, signaturePath, publicKeyPath, artifactDirectory, trustFile, sourceCommit] = args;
    result = await assembleSite({ development, output, trustFile,
      release: { candidate, sourceCommit, manifestPath, signaturePath, publicKeyPath, artifactDirectory } });
  } else if (args[0] === 'recover' && [2, 3].includes(args.length)) {
    result = await recoverSite(args[1], args[2]);
  } else {
    process.stderr.write(usage);
    process.exitCode = 64;
  }
  if (result) process.stdout.write(typeof result === 'string' ? `Local site ${result}\n` :
    `Local site assembled: ${result.releases.length} retained releases; latest ${result.latest || 'unavailable'}; development ${result.development.commit}\n`);
} catch (error) {
  process.stderr.write(`Site assembly refused: ${error.message}\n`);
  process.exitCode = error.message.includes('outcome uncertain') ? 75 : 1;
}
