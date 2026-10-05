import assert from 'node:assert/strict';
import { execFileSync } from 'node:child_process';
import { chmodSync, copyFileSync, cpSync, existsSync, lstatSync, mkdirSync, mkdtempSync, readFileSync, rmSync, symlinkSync, writeFileSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { dirname, join, resolve } from 'node:path';
import test from 'node:test';
import { fileURLToPath } from 'node:url';
import { recordInputs } from '../inputs.mjs';
import { buildCandidate } from './candidate.mjs';
import { inventory } from './material.mjs';

const owner = resolve(dirname(fileURLToPath(import.meta.url)), '../..');
const silent = { encoding: 'utf8', stdio: 'pipe' };
function put(root, path, bytes, mode = 0o644) {
  mkdirSync(dirname(join(root, path)), { recursive: true });
  writeFileSync(join(root, path), bytes, { mode });
}
function runtime(root, version = '1.2.3', appVersion = version) {
  put(root, 'releases/start_erl.data', `17.1 ${version}\n`);
  put(root, `releases/${version}/frameshift_core.rel`, `{release,{"frameshift_core","${version}"},{erts,"17.1"},[{frameshift_core,"${version}",permanent}]}.\n`);
  put(root, `lib/frameshift_core-${version}/ebin/frameshift_core.app`, `{application,frameshift_core,[{vsn,"${appVersion}"}]}.\n`);
}
async function fixture(t, version = '1.2.3') {
  const repository = mkdtempSync(join(tmpdir(), 'frameshift-ubuntu-candidate-'));
  t.after(() => rmSync(repository, { recursive: true, force: true }));
  const git = args => execFileSync('git', args, { ...silent, cwd: repository }).trim();
  git(['init', '-b', 'main']);
  mkdirSync(join(repository, 'var'), { mode: 0o700 });
  for (const path of ['.mise.toml', 'release/read-version.exs', 'release/source.mjs', 'release/inputs.mjs']) {
    mkdirSync(dirname(join(repository, path)), { recursive: true });
    copyFileSync(join(owner, path), join(repository, path));
  }
  cpSync(join(owner, 'release/linux'), join(repository, 'release/linux'), { recursive: true });
  put(repository, '.gitignore', '_build/\nvar/\n');
  put(repository, 'README.md', 'source untouched\n');
  put(repository, 'apps/core/mix.exs', `defmodule Fixture do\n  @moduledoc false\n\n  use Mix.Project\n  def project, do: [app: :frameshift_core, version: "${version}"]\nend\n`);
  put(repository, 'apps/core/mix.lock', '{}\n');
  put(repository, 'apps/core/lib/source.ex', 'source fixture\n');
  put(repository, 'packages/decision-kernel/gleam.toml', 'name="fixture"\n');
  put(repository, 'protocol/source.json', '{}\n');
  put(repository, 'codec/source.txt', 'scalar codec fixture\n');
  git(['add', '.']);
  git(['-c', 'user.name=Fixture', '-c', 'user.email=fixture@example.invalid', 'commit', '-m', 'test(host): define tagged source fixture']);
  const commit = git(['rev-parse', 'HEAD']);
  git(['tag', 'v1.2.3']);
  const inputs = join(repository, 'var/inputs');
  if (version === '1.2.3') await recordInputs(repository, 'v1.2.3', commit, inputs);
  return { repository, tag: 'v1.2.3', commit, git, sourcePath: join(inputs, 'source-inputs.json'), architecture: 'arm64', output: join(repository, 'var/candidate') };
}
function executor(f, mutation = '') {
  return (command, args, capture) => {
    if (command.endsWith('/prepare-context')) {
      const context = args[1];
      for (const path of ['apps/core/lib', 'apps/core/mix.exs', 'apps/core/mix.lock', 'packages', 'protocol', 'codec']) {
        mkdirSync(dirname(join(context, path)), { recursive: true });
        cpSync(join(f.repository, path), join(context, path), { recursive: true });
      }
      cpSync(join(f.repository, 'release/linux'), join(context, 'linux'), { recursive: true });
      put(context, 'mix-archives/hex/archive', 'fixture archive');
      put(context, 'gleam', 'fixture compiler', 0o755);
      put(context, 'frameshift-raster', 'fixture raster', 0o755);
      if (mutation === 'prepared') put(context, 'apps/core/lib/source.ex', 'substituted source');
    } else if (command === 'docker' && args[0] === 'info') return 'aarch64';
    else if (command === 'docker') {
      const context = args.at(-1);
      const destination = args[args.indexOf('--output') + 1].slice('type=local,dest='.length);
      if (args.includes('EXPECTED_VERSION=1.2.3')) {
        const root = join(destination, 'root');
        runtime(join(root, 'usr/lib/frameshift/core'), '1.2.3', mutation === 'app-version' ? '1.2.4' : '1.2.3');
        execFileSync('mise', ['exec', '--', 'elixir', join(context, 'linux/verify-version.exs'), join(root, 'usr/lib/frameshift/core'), '1.2.3'], silent);
        for (const [source, target] of [['inputs.json', 'build-inputs.json'], ['source-inputs.json', 'source-inputs.json']]) {
          put(root, `usr/share/doc/frameshift/${target}`, readFileSync(join(context, source)));
        }
        if (mutation === 'context') put(context, 'codec/source.txt', 'changed during build');
        if (mutation === 'source') {
          f.git(['update-index', '--assume-unchanged', 'README.md']);
          put(f.repository, 'README.md', 'hidden build mutation');
        }
        if (mutation === 'architecture') {
          const path = join(root, 'usr/share/doc/frameshift/build-inputs.json');
          const record = JSON.parse(readFileSync(path)); record.architecture = 'amd64'; writeFileSync(path, JSON.stringify(record));
        }
      } else {
        put(destination, 'frameshift_1.2.3_arm64.deb', 'synthetic archive: no installed claim');
        cpSync(join(context, 'packaging-inputs.json'), join(destination, 'packaging-inputs.json'));
        if (mutation === 'handoff') put(context, 'root/usr/lib/frameshift/core/releases/start_erl.data', 'changed packaging input');
      }
    } else {
      assert.equal(command, process.execPath);
      return execFileSync(command, args, silent).trim();
    }
    return capture ? '' : undefined;
  };
}

test('tagged source joins version descriptors, private candidate records and identical no-build replay', async t => {
  const f = await fixture(t);
  const record = await buildCandidate(f, executor(f));
  assert.equal(record.publicationAuthority, 'none');
  assert.equal(record.version, '1.2.3');
  assert.equal(record.buildExecution.emulated, false);
  assert.equal(record.artifacts[0].bytes, 37);
  assert.equal(lstatSync(f.output).mode & 0o7777, 0o700);
  const path = join(f.output, 'candidate.json');
  const before = lstatSync(path);
  assert.equal(before.mode & 0o7777, 0o600);
  assert.deepEqual(await buildCandidate(f, () => assert.fail('rerun must not rebuild')), record);
  assert.equal(lstatSync(path).ino, before.ino);
  assert.equal(lstatSync(path).mtimeMs, before.mtimeMs);
  const packaging = JSON.parse(readFileSync(join(f.output, 'package/packaging-inputs.json')));
  assert.equal(packaging.kind, 'tagged-deb-candidate');
  assert.equal(packaging.packageVersion, '1.2.3');
  assert.equal(packaging.sourceInputsSha256, record.sourceInputsSha256);
});

test('prepared/source/context/version/architecture/handoff changes retain incomplete output without a final record', async t => {
  for (const mutation of ['prepared', 'source', 'context', 'app-version', 'architecture', 'handoff']) {
    const f = await fixture(t);
    await assert.rejects(() => buildCandidate(f, executor(f, mutation)));
    assert.equal(existsSync(join(f.output, 'candidate.json')), false, mutation);
    assert.equal(readFileSync(join(f.output, 'build.pending'), 'utf8'), 'incomplete ubuntu candidate\n');
    await assert.rejects(() => buildCandidate(f, () => assert.fail('incomplete output must not rebuild')));
  }
});

test('changed retained archive or output custody refuses without changing the previous record', async t => {
  const f = await fixture(t);
  await buildCandidate(f, executor(f));
  const path = join(f.output, 'candidate.json');
  const prior = readFileSync(path);
  const altered = JSON.parse(prior); altered.artifacts[0].architecture = 'amd64';
  writeFileSync(path, JSON.stringify(altered) + '\n');
  await assert.rejects(() => buildCandidate(f), /conflicting/);
  writeFileSync(path, prior);
  put(f.output, 'package/frameshift_1.2.3_arm64.deb', 'different final archive');
  await assert.rejects(() => buildCandidate(f), /conflicting/);
  assert.deepEqual(readFileSync(path), prior);
  chmodSync(f.output, 0o755);
  await assert.rejects(() => buildCandidate(f), /unsafe/);
  assert.deepEqual(readFileSync(path), prior);
});

test('development source refuses before any build or output creation', async t => {
  const f = await fixture(t, '1.2.3-dev');
  await assert.rejects(() => buildCandidate(f, () => assert.fail('development cannot start a build')));
  assert.equal(existsSync(f.output), false);
});

test('material symlinks and FIFO refuse before reading target bytes', t => {
  const root = mkdtempSync(join(tmpdir(), 'frameshift-material-'));
  t.after(() => rmSync(root, { recursive: true, force: true }));
  put(root, 'original', 'retain');
  symlinkSync('original', join(root, 'alias'));
  assert.throws(() => inventory(root), /regular files/);
  rmSync(join(root, 'alias'));
  execFileSync('mkfifo', [join(root, 'fifo')]);
  assert.throws(() => inventory(root), /regular files/);
  assert.equal(readFileSync(join(root, 'original'), 'utf8'), 'retain');
});
