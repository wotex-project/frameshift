import { developmentDiskImage } from './dmg.mjs';
const args = process.argv.slice(2);
if (args.length !== 3 || !['arm64', 'x86_64', 'universal'].includes(args[1])) {
  console.error('usage: scripts/package-macos-dmg APP arm64|x86_64|universal OUTPUT'); process.exitCode = 64;
} else {
  try { console.log(JSON.stringify(await developmentDiskImage(...args))); }
  catch { console.error('development disk-image candidate refused; existing output retained'); process.exitCode = 1; }
}
