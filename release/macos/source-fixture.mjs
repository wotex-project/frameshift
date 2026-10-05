import { createHash } from 'node:crypto';
import { execFileSync } from 'node:child_process';
import { copyFileSync, mkdirSync, readFileSync, renameSync, writeFileSync } from 'node:fs';
import { dirname, join, resolve } from 'node:path';
import { recordInputs, verifyInputs } from '../inputs.mjs';
import { macMaterial } from './candidate.mjs';
import { auditMacBundle } from './closure.mjs';
import { fixture as nativeFixture, run, temporary } from './fixture.mjs';
import { prepareDevelopmentBundle } from './prepare.mjs';

const owner = resolve(new URL('../..', import.meta.url).pathname);
const encode = value => Buffer.from(JSON.stringify(value) + '\n');
const hash = value => createHash('sha256').update(value).digest('hex');
function put(root, path, bytes) { const full = join(root, path); mkdirSync(dirname(full), { recursive: true }); writeFileSync(full, bytes); }
export async function sourceFixture(t, { sourceFiles = {}, materialFiles = {} } = {}) {
  const repository = temporary(t), git = args => execFileSync('git', args, { cwd: repository, encoding: 'utf8', stdio: 'pipe' }).trim();
  for (const path of ['.mise.toml', 'release/read-version.exs', 'release/linux/verify-version.exs']) { mkdirSync(dirname(join(repository, path)), { recursive: true }); copyFileSync(join(owner, path), join(repository, path)); }
  put(repository, '.gitignore', 'var/\n_build/\ndeps/\nbuild/\n'); put(repository, 'README.md', 'exact source\n');
  put(repository, 'apps/core/mix.exs', 'defmodule Fixture do\n  @moduledoc false\n\n  use Mix.Project\n  def project, do: [app: :frameshift_core, version: "0.1.0"]\nend\n');
  for (const [path, bytes] of Object.entries(sourceFiles)) put(repository, path, bytes);
  git(['init', '-b', 'main']); git(['add', '.']); git(['-c', 'user.name=Fixture', '-c', 'user.email=fixture@example.invalid', 'commit', '-m', 'test(mac): define source-bound compiler fixture']);
  const commit = git(['rev-parse', 'HEAD']), tag = 'v0.1.0'; git(['tag', tag]); mkdirSync(join(repository, 'var'), { mode: 0o700 });
  await recordInputs(repository, tag, commit, join(repository, 'var/inputs'));
  const sourcePath = join(repository, 'var/inputs/source-inputs.json'), source = await verifyInputs(repository, tag, commit, sourcePath);
  put(repository, 'apps/core/deps/example/source.c', 'dependency source\n'); put(repository, 'packages/decision-kernel/build/packages/example/source.gleam', 'Gleam source\n');
  for (const [path, bytes] of Object.entries(materialFiles)) put(repository, path, bytes);
  const material = await macMaterial(repository), candidates = [];
  for (const architecture of ['arm64', 'x86_64']) {
    const f = nativeFixture(t, architecture), candidate = join(repository, 'var', architecture); mkdirSync(candidate, { mode: 0o700 });
    const app = f.root;
    const plist = join(app, 'Contents/Info.plist'); writeFileSync(plist, readFileSync(plist, 'utf8').replace('io.frameshift.closure-fixture', 'io.frameshift.app'));
    const core = join(app, 'Contents/Resources/core'); renameSync(join(core, 'erts-fixture'), join(core, 'erts-17.1'));
    put(core, 'releases/start_erl.data', '17.1 0.1.0');
    put(core, 'releases/0.1.0/frameshift_core.rel', '{release,{"frameshift_core","0.1.0"},{erts,"17.1"},[{frameshift_core,"0.1.0",permanent}]}.\n');
    put(core, 'lib/frameshift_core-0.1.0/ebin/frameshift_core.app', '{application,frameshift_core,[{vsn,"0.1.0"}]}.\n');
    await prepareDevelopmentBundle(app, architecture);
    // These are explicit compiler-purpose assertions, not remote/native Intel
    // producer evidence. The fixture executes actual cross-CPU compiled code.
    const execution = { architecture, native: true, macOS: run('/usr/bin/sw_vers', ['-productVersion']), osBuild: run('/usr/bin/sw_vers', ['-buildVersion']),
      xcode: run('/usr/bin/xcodebuild', ['-version']), sdkVersion: run('/usr/bin/xcrun', ['--show-sdk-version']), sdkBuild: run('/usr/bin/xcrun', ['--show-sdk-build-version']),
      swift: run('/usr/bin/swift', ['--version']).split('\n')[0] + `\nTarget: ${architecture}-apple-macosx27.0.0`, elixir: run('mise', ['exec', '--', 'elixir', '--version']), zig: '0.16.0' };
    const record = { schemaVersion: 1, kind: 'macos-native-build-candidate', product: source.product, publicationAuthority: 'none', tag, version: source.version, sourceCommit: commit,
      sourceInputsSha256: hash(encode(source)), architecture, execution, material, bundle: await auditMacBundle(app, architecture) };
    renameSync(app, join(candidate, 'Frameshift.app'));
    const bytes = encode(record); writeFileSync(join(candidate, 'candidate.json'), bytes, { mode: 0o600 }); candidates.push({ candidate, record, bytes, sha256: hash(bytes) });
  }
  return { repository, git, tag, commit, sourcePath, source, armCandidate: candidates[0].candidate, armSha256: candidates[0].sha256, intelCandidate: candidates[1].candidate, intelSha256: candidates[1].sha256, candidates, output: join(repository, 'var/cohort') };
}
