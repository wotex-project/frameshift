// Temporary producer comparison for SourceRecordTest; no portable production import.
import { execFileSync } from 'node:child_process';
import { copyFileSync, mkdirSync, mkdtempSync, readFileSync, rmSync, writeFileSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join, resolve } from 'node:path';
import { createHash } from 'node:crypto';
import { recordInputs } from '../../../inputs.mjs';

if (process.versions.node !== '26.9.0') throw new Error('fixture needs pinned Node');
const repository = resolve(import.meta.dirname, '../../../..');
const root = mkdtempSync(join(tmpdir(), 'frameshift-source-oracle-'));
try {
  const environment = { ...process.env };
  for (const key of Object.keys(environment)) if (key.startsWith('GIT_')) delete environment[key];
  const git = args => execFileSync('git', ['--no-replace-objects', '-c', 'commit.gpgsign=false',
    '-c', 'tag.gpgSign=false', '-c', 'core.hooksPath=/dev/null', ...args],
    { cwd: root, env: environment, encoding: 'utf8', stdio: 'pipe' }).trim();
  git(['init', '--object-format=sha1', '-b', 'main']);
  mkdirSync(join(root, 'apps/core'), { recursive: true });
  mkdirSync(join(root, 'release'));
  mkdirSync(join(root, 'Ω'));
  mkdirSync(join(root, 'var'), { mode: 0o700 });
  copyFileSync(join(repository, '.mise.toml'), join(root, '.mise.toml'));
  copyFileSync(join(repository, 'release/read-version.exs'), join(root, 'release/read-version.exs'));
  writeFileSync(join(root, '.gitignore'), '_build/\nvar/\n');
  writeFileSync(join(root, 'apps/core/mix.exs'), 'defmodule FixtureProject do\n  @moduledoc false\n\n  use Mix.Project\n  def project, do: [app: :frameshift_core, version: "1.2.3"]\nend\n');
  writeFileSync(join(root, 'apps/core/mix.lock'), '{}\n');
  writeFileSync(join(root, 'Ω/draw🖼.md'), 'unchanged UTF-8 source\n');
  writeFileSync(join(root, 'executable'), '#!/bin/sh\nexit 0\n', { mode: 0o755 });
  git(['add', '.']);
  git(['-c', 'user.name=Fixture', '-c', 'user.email=fixture@example.invalid', 'commit', '-m', 'test(release): define source comparison fixture']);
  git(['tag', 'v1.2.3']);
  const commit = git(['rev-parse', 'HEAD']);
  const record = await recordInputs(root, 'v1.2.3', commit, join(root, 'var/source'));
  const message = readFileSync(join(root, 'var/source/source-inputs.json'));
  process.stdout.write(JSON.stringify({ message: message.toString('base64'), record, tag: 'v1.2.3', commit,
    digest: createHash('sha256').update(message).digest('hex') }) + '\n');
} finally { rmSync(root, { recursive: true, force: true }); }
