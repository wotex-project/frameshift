import { auditMacBundle } from './closure.mjs';

const args = process.argv.slice(2);
if (args.length !== 2 || !['arm64', 'x86_64', 'universal'].includes(args[1])) {
  console.error('usage: scripts/check-macos-closure APP arm64|x86_64|universal');
  process.exitCode = 64;
} else {
  try { console.log(JSON.stringify(await auditMacBundle(...args))); }
  catch { console.error('Mac bundle closure refused'); process.exitCode = 1; }
}
