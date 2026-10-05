import { universalDevelopmentBundle } from './universal.mjs';
const args = process.argv.slice(2);
if (args.length !== 3) { console.error('usage: scripts/package-macos-universal ARM_APP INTEL_APP OUTPUT'); process.exitCode = 64; }
else {
  try { console.log(JSON.stringify(await universalDevelopmentBundle(...args))); }
  catch { console.error('universal development bundle refused; existing output retained'); process.exitCode = 1; }
}
