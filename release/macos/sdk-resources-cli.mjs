import { checkSDKResources } from './sdk-resources.mjs';
const [root, ...extra] = process.argv.slice(2);
if (!root || extra.length) { process.stderr.write('usage: check-sdk-resources RESOURCE_ROOT\n'); process.exitCode = 64; }
else {
  try { process.stdout.write(JSON.stringify(await checkSDKResources(root)) + '\n'); }
  catch { process.stderr.write('generation SDK resources: unavailable, unsafe or changed custody\n'); process.exitCode = 1; }
}
