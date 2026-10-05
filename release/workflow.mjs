import { createHash } from 'node:crypto';
import { verifyInputs } from './inputs.mjs';
import { remoteSourceIdentity } from './remote.mjs';

export async function workflowInputs({ githubRepository, repository, tag, commit, recordPath, expectedDigest }, request) {
  if (expectedDigest !== undefined && (typeof expectedDigest !== 'string' || expectedDigest.length !== 64 || !/^[0-9a-f]{64}$/.test(expectedDigest))) throw new Error('invalid expected source digest');
  const remote = remoteSourceIdentity(githubRepository, tag, commit, request);
  const record = await verifyInputs(repository, tag, commit, recordPath);
  const sourceInputsSha256 = createHash('sha256').update(JSON.stringify(record) + '\n').digest('hex');
  if (expectedDigest !== undefined && expectedDigest !== sourceInputsSha256) throw new Error('source record handoff mismatch');
  const after = remoteSourceIdentity(githubRepository, tag, commit, request);
  if (JSON.stringify(after) !== JSON.stringify(remote)) throw new Error('remote source changed');
  return { ...remote, sourceInputsSha256 };
}
