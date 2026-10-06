import assert from 'node:assert/strict';
import { createHash } from 'node:crypto';
import { execFileSync } from 'node:child_process';
import { chmodSync, copyFileSync, existsSync, lstatSync, mkdirSync, readFileSync, rmSync, unlinkSync, writeFileSync } from 'node:fs';
import { join } from 'node:path';
import test from 'node:test';
import { isSparkleInput } from '../macos-framework.mjs';
import { stageDependencyMaterial } from '../material-handoff.mjs';
import { inspectMacCandidate } from './cohort.mjs';
import { candidateCommand, macBuildCandidate } from './candidate.mjs';
import { macImageTool } from './dmg.mjs';
import { temporary } from './fixture.mjs';
import { stageMacMaterial } from './material-handoff.mjs';
import { macMaterialJoin } from './material.mjs';
import { sparkleJoinFixture } from './sparkle-join-fixture.mjs';

const zip = process.env.FRAMESHIFT_SPARKLE_ARCHIVE;
const mac = { skip: !(process.platform === 'darwin' && zip) && 'Exact pinned FRAMESHIFT_SPARKLE_ARCHIVE on macOS required' };
const encode = value => Buffer.from(JSON.stringify(value) + '\n'), hash = value => createHash('sha256').update(value).digest('hex');
const custody = path => ['ino', 'size', 'mode', 'mtimeNs', 'ctimeNs'].map(key => String(lstatSync(path, { bigint: true })[key]));
function archive(t, f, joinedPath, change = () => {}) {
  const root = temporary(t), material = join(root, 'macos-material'); mkdirSync(material, { mode: 0o700 });
  for (const [path, name] of [[f.corePath, 'core-material.json'], [f.gleamPath, 'gleam-material.json'], [f.sparklePath, 'sparkle-material.json'], [joinedPath, 'dependency-inputs.json']]) copyFileSync(path, join(material, name));
  change(material);
  const archivePath = join(root, 'material.tar');
  execFileSync('/usr/bin/tar', ['--format', 'ustar', '-cf', archivePath, '-C', root, 'macos-material'], { env: { ...process.env, COPYFILE_DISABLE: '1' }, timeout: 30_000 }); chmodSync(archivePath, 0o600);
  return { archivePath, archiveSha256: hash(readFileSync(archivePath)) };
}

test('actual SDK source receipt joins both CPU candidates and fourth-receipt USTAR with immutable CLI replay', mac, async t => {
  const f = await sparkleJoinFixture(t, zip), original = custody(f.sparklePath);
  for (const [architecture, candidate, candidateSha256] of [['arm64', f.armCandidate, f.armSha256], ['x86_64', f.intelCandidate, f.intelSha256]]) {
    const request = { ...f, architecture, candidate, candidateSha256, output: f.output + '-' + architecture };
    const joined = await macMaterialJoin(request); assert.equal(joined.updaterInputs, 86); assert.equal(joined.provedSourceFiles, 5); assert.equal(joined.generatedInputs.length, 3);
    const joinedPath = join(request.output, 'dependency-inputs.json'), before = custody(joinedPath);
    assert.equal((await macMaterialJoin(request)).recordSha256, joined.recordSha256); assert.deepEqual(custody(joinedPath), before);
    const handoff = { ...request, ...archive(t, f, joinedPath), joinSha256: joined.recordSha256, output: request.output + '-received' };
    const received = await stageMacMaterial(handoff); assert.equal(received.updaterInputs, 86); assert.equal(received.publicationAuthority, 'none');
    const retained = join(handoff.output, 'macos-material/sparkle-material.json'), retainedBefore = custody(retained), recordBefore = custody(join(handoff.output, 'handoff.json'));
    assert.deepEqual(readFileSync(retained), readFileSync(f.sparklePath));
    const args = [f.tag, f.commit, f.sourcePath, architecture, candidate, candidateSha256];
    const cliJoin = JSON.parse(execFileSync(process.execPath, [join(f.repository, 'release/macos/material-cli.mjs'), ...args, f.corePath, f.coreSha256, f.gleamPath, f.gleamSha256, request.output, f.sparklePath, f.sparkleSha256], { cwd: f.repository, encoding: 'utf8', timeout: 90_000 }));
    assert.equal(cliJoin.recordSha256, joined.recordSha256);
    const cli = JSON.parse(execFileSync(process.execPath, [join(f.repository, 'release/macos/material-handoff-cli.mjs'), ...args, handoff.archivePath, handoff.archiveSha256, f.coreSha256, f.gleamSha256, handoff.joinSha256, handoff.output, f.sparkleSha256], { cwd: f.repository, encoding: 'utf8', timeout: 90_000 }));
    assert.equal(cli.recordSha256, received.recordSha256); assert.equal(cli.disposition, 'retained-bytes-verified');
    assert.deepEqual(custody(retained), retainedBefore); assert.deepEqual(custody(join(handoff.output, 'handoff.json')), recordBefore);
  }
  assert.deepEqual(custody(f.sparklePath), original);
});

test('SDK receipt, captured scope and embedded framework must agree before joined output creation', mac, async t => {
  const f = await sparkleJoinFixture(t, zip);
  for (const request of [{ ...f, sparklePath: undefined, sparkleSha256: undefined }, { ...f, sparkleSha256: '0'.repeat(64) }, { ...f, sparklePath: undefined }]) {
    await assert.rejects(() => macMaterialJoin(request)); assert.equal(existsSync(f.output), false);
  }
  const path = join(f.candidate, 'candidate.json'), original = readFileSync(path), record = JSON.parse(original);
  for (const change of [r => { r.material = r.material.filter(file => !isSparkleInput(file.path)); },
    r => { r.material.find(file => isSparkleInput(file.path)).sha256 = '0'.repeat(64); },
    r => { r.material.splice(r.material.findIndex(file => isSparkleInput(file.path)), 1); },
    r => { r.material.find(file => isSparkleInput(file.path)).path += '-unknown'; }]) {
    const changed = structuredClone(record); change(changed); const bytes = encode(changed); writeFileSync(path, bytes);
    await assert.rejects(() => macMaterialJoin({ ...f, candidateSha256: hash(bytes) })); assert.equal(existsSync(f.output), false); assert.deepEqual(readFileSync(path), bytes);
  }
  writeFileSync(path, original);
  const receipt = readFileSync(f.sparklePath), wrong = JSON.parse(receipt); wrong.packageSha256 = '0'.repeat(64); const bytes = encode(wrong); writeFileSync(f.sparklePath, bytes);
  await assert.rejects(() => macMaterialJoin({ ...f, sparkleSha256: hash(bytes) })); assert.equal(existsSync(f.output), false); writeFileSync(f.sparklePath, receipt);
  assert.equal((await inspectMacCandidate({ ...f, expectedDigest: f.candidateSha256 })).material.filter(file => isSparkleInput(file.path)).length, 86);
});

test('SDK archive member/digest conflicts and child-time replacement preserve refused custody', mac, async t => {
  const f = await sparkleJoinFixture(t, zip), joined = await macMaterialJoin(f), joinedPath = join(f.output, 'dependency-inputs.json');
  const request = { ...f, ...archive(t, f, joinedPath), joinSha256: joined.recordSha256, output: f.output + '-received' };
  await assert.rejects(() => stageMacMaterial({ ...request, sparkleSha256: undefined })); assert.equal(existsSync(request.output), false);
  await assert.rejects(() => stageDependencyMaterial(request, { platform: 'ubuntu' }), /updater/);
  for (const change of [root => unlinkSync(join(root, 'sparkle-material.json')), root => chmodSync(join(root, 'sparkle-material.json'), 0o644), root => writeFileSync(join(root, 'unknown'), 'retained')]) {
    await assert.rejects(() => stageMacMaterial({ ...request, ...archive(t, f, joinedPath, change) })); assert.equal(existsSync(request.output), false);
  }
  const wrong = { ...request, sparkleSha256: '0'.repeat(64), output: request.output + '-wrong' };
  await assert.rejects(() => stageMacMaterial(wrong)); assert.ok(existsSync(join(wrong.output, 'handoff.pending'))); await assert.rejects(() => stageMacMaterial(wrong), /incomplete/);
  let versions = 0;
  await assert.rejects(() => stageMacMaterial(request, { tool: (command, args, timeout) => {
    const result = macImageTool(command, args, timeout);
    if (args.includes(join(f.repository, 'release/linux/verify-version.exs')) && ++versions === 4) {
      const path = join(request.output, 'macos-material/sparkle-material.json'), bytes = readFileSync(path); writeFileSync(path, Buffer.from(bytes).fill(32, 0, 1));
    }
    return result;
  } }));
  assert.ok(existsSync(join(request.output, 'handoff.pending'))); assert.equal(existsSync(join(request.output, 'handoff.json')), false);
  await assert.rejects(() => stageMacMaterial(request), /incomplete/);
});

test('native producer captures the real SwiftPM artifact before and after the build boundary and refuses changed inputs', mac, async t => {
  const f = await sparkleJoinFixture(t, zip), built = join(f.repository, 'apps/macos/.build/artifacts/Frameshift.app');
  const execute = (command, args, options) => {
    if (command.endsWith('/scripts/package-macos')) { return candidateCommand('/usr/bin/ditto', [join(f.candidate, 'Frameshift.app'), built], { cwd: f.repository, timeout: 120_000 }); }
    return candidateCommand(command, args, options);
  };
  const request = { ...f, output: f.output + '-produced' }, first = await macBuildCandidate(request, execute);
  assert.equal(first.disposition, 'native-build-candidate');
  const record = JSON.parse(readFileSync(join(request.output, 'candidate.json')));
  assert.equal(record.material.filter(file => isSparkleInput(file.path)).length, 86);
  const joined = await macMaterialJoin({ ...f, candidate: request.output, candidateSha256: first.recordSha256, output: f.output + '-producer-joined' });
  assert.equal(joined.updaterInputs, 86);
  const replay = await macBuildCandidate(request, (command, args, options) => { assert.equal(command.endsWith('/scripts/package-macos'), false); return candidateCommand(command, args, options); });
  assert.equal(replay.recordSha256, first.recordSha256);
  const unused = { ...f, output: f.output + '-unused' };
  await assert.rejects(() => macBuildCandidate(unused, (command, args, options) => {
    const result = execute(command, args, options);
    if (command.endsWith('/scripts/package-macos')) {
      rmSync(join(built, 'Contents/Frameworks'), { recursive: true });
      copyFileSync(join(built, 'Contents/MacOS/frameshiftctl'), join(built, 'Contents/MacOS/Frameshift'));
      candidateCommand('/usr/bin/codesign', ['--force', '--sign', '-', '--timestamp=none', built], { cwd: f.repository });
    }
    return result;
  }), /updater inputs and bundle differ/);
  assert.ok(existsSync(join(unused.output, 'build.pending')));
  const changed = { ...f, output: f.output + '-changed' };
  await assert.rejects(() => macBuildCandidate(changed, (command, args, options) => {
    const result = execute(command, args, options);
    if (command.endsWith('/scripts/package-macos')) {
      const header = join(f.framework, 'Versions/B/Headers/SPUUpdater.h'), bytes = readFileSync(header); writeFileSync(header, Buffer.from(bytes).fill(32, 0, 1));
    }
    return result;
  }));
  assert.ok(existsSync(join(changed.output, 'build.pending'))); assert.equal(existsSync(join(changed.output, 'candidate.json')), false);
});
