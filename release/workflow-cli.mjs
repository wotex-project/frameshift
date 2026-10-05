import { remoteSourceIdentity } from './remote.mjs';
import { workflowInputs } from './workflow.mjs';

const [operation, githubRepository, tag, commit, repository, recordPath, expectedDigest, ...extra] = process.argv.slice(2);
const count = process.argv.length - 2;
if (extra.length || !((operation === 'remote' && count === 4) || (operation === 'record' && count === 6) || (operation === 'verify' && count === 7))) {
  process.stderr.write('usage: workflow-cli remote GITHUB_REPO TAG COMMIT | record GITHUB_REPO TAG COMMIT REPO RECORD | verify GITHUB_REPO TAG COMMIT REPO RECORD SHA256\n');
  process.exitCode = 64;
} else {
  try {
    const result = operation === 'remote' ? remoteSourceIdentity(githubRepository, tag, commit) :
      await workflowInputs({ githubRepository, repository, tag, commit, recordPath, expectedDigest });
    process.stdout.write(`tag=${result.tag}\ncommit=${result.commit}\nversion=${result.version}\n`);
    if (result.sourceInputsSha256) process.stdout.write(`source_inputs_sha256=${result.sourceInputsSha256}\n`);
  } catch {
    process.stderr.write('release workflow source: remote tag, local source or input handoff unavailable/conflicting\n');
    process.exitCode = 1;
  }
}
