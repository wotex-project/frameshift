import { createHash } from 'node:crypto';
import { execFileSync } from 'node:child_process';
import { mkdirSync, mkdtempSync, readFileSync, readdirSync, rmSync, writeFileSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { dirname, join, resolve } from 'node:path';
import { checkCoreMaterial } from './core-material.mjs';
import { checkGleamMaterial } from './gleam-material.mjs';
import { recordInputs } from './inputs.mjs';

const owner = resolve(new URL('..', import.meta.url).pathname);
export const encode = value => Buffer.from(JSON.stringify(value) + '\n');
export const hash = value => createHash('sha256').update(value).digest('hex');
function put(root, path, bytes, mode = 0o644) { mkdirSync(dirname(join(root, path)), { recursive: true }); writeFileSync(join(root, path), bytes, { mode }); }
export async function noticeFixture(t, { noticeCount = 1, noticeBytes = 3 } = {}) {
  const repository = mkdtempSync(join(tmpdir(), 'frameshift-notice-source-')); t.after(() => rmSync(repository, { recursive: true, force: true }));
  const run = (command, args, cwd = repository) => execFileSync(command, args, { cwd, encoding: 'utf8', stdio: 'pipe', timeout: 60_000, maxBuffer: 64 * 1024 }).trim(), git = args => run('git', args);
  for (const name of readdirSync(join(owner, 'release'))) if ((name.endsWith('.mjs') && !name.endsWith('.test.mjs')) || name.endsWith('.exs')) put(repository, 'release/' + name, readFileSync(join(owner, 'release', name)));
  put(repository, '.mise.toml', readFileSync(join(owner, '.mise.toml'))); put(repository, '.gitignore', 'var/\ndeps/\nbuild/\n');
  put(repository, 'apps/core/mix.exs', 'defmodule NoticeFixture do\n  @moduledoc false\n\n  use Mix.Project\n  def project, do: [app: :frameshift_core, version: "1.2.3"]\nend\n');
  put(repository, 'packages/decision-kernel/gleam.toml', 'name = "frameshift_decisions"\nversion = "0.1.0"\n');
  mkdirSync(join(repository, 'var'), { mode: 0o700 });
  const coreCache = join(repository, 'var/core-cache'), gleamCache = join(repository, 'var/gleam-cache'); for (const path of [coreCache, gleamCache]) mkdirSync(path, { mode: 0o700 });
  const script = `Application.load(:hex)
root = hd(System.argv())
put = fn path, bytes -> File.mkdir_p!(Path.dirname(path)); File.write!(path, bytes) end
hex = fn bytes -> Base.encode16(bytes, case: :lower) end
core = for name <- ["covered", "missing"] do
  notices = if name == "covered", do: Enum.map(0..(${noticeCount} - 1), fn i -> {String.to_charlist("licenses/notice-" <> Integer.to_string(i) <> ".txt"), :binary.copy(<<128, 0, 10>>, div(${noticeBytes}, 3)) <> :binary.copy(<<128>>, rem(${noticeBytes}, 3))} end), else: []
  files = [{~c"README.md", "fixture package\\n"}] ++ notices
  {:ok, p} = :mix_hex_tarball.create(%{"name" => name, "version" => "1.0.0", "build_tools" => ["mix"], "files" => Enum.map(files, fn {path, _} -> List.to_string(path) end)}, files)
  {:ok, outer} = :mix_hex_erl_tar.extract({:binary, p.tarball}, [:memory]); {_, metadata} = Enum.find(outer, fn {n, _} -> n == ~c"metadata.config" end)
  dep = Path.join(root, "apps/core/deps/" <> name)
  Enum.each(files, fn {path, bytes} -> put.(Path.join(dep, List.to_string(path)), bytes) end)
  put.(Path.join(dep, "hex_metadata.config"), metadata)
  put.(Path.join(dep, ".hex"), :erlang.term_to_binary({{:hex, 2, 0}, %{name: name, version: "1.0.0", inner_checksum: hex.(p.inner_checksum), outer_checksum: hex.(p.outer_checksum), repo: "hexpm", managers: [:mix]}}))
  put.(Path.join(root, "var/core-cache/" <> name <> "-1.0.0.tar"), p.tarball)
  %{name: name, inner: hex.(p.inner_checksum), outer: hex.(p.outer_checksum)}
end
files = [{~c"LICENCE", "test-purpose notice\\n"}, {~c"src/example.gleam", "pub fn example() { 1 }\\n"}]
{:ok, p} = :mix_hex_tarball.create(%{"name" => "notice_gleam", "version" => "1.0.0", "build_tools" => ["gleam"]}, files)
Enum.each(files, fn {path, bytes} -> put.(Path.join(root, "packages/decision-kernel/build/packages/notice_gleam/" <> List.to_string(path)), bytes) end)
put.(Path.join(root, "var/gleam-cache/" <> Base.encode16(p.outer_checksum) <> ".tar"), p.tarball)
IO.binwrite(:json.encode(%{core: core, gleam: Base.encode16(p.outer_checksum)}))`;
  const produced = JSON.parse(run('mise', ['exec', '--', 'mix', 'run', '--no-mix-exs', '--no-start', '--no-compile', '--no-deps-check', '-e', script, '--', repository], owner));
  const gitRoot = join(repository, 'apps/core/deps/git_notice'), depGit = args => run('git', args, gitRoot);
  put(gitRoot, 'packages/demo/COPYING.fixture', 'test-purpose sparse notice\n'); put(gitRoot, 'packages/demo/src.txt', 'source\n');
  depGit(['init', '-b', 'main']); depGit(['add', '.']); depGit(['-c', 'user.name=Fixture', '-c', 'user.email=fixture@example.invalid', 'commit', '-m', 'test(host): define sparse notice fixture']);
  const depCommit = depGit(['rev-parse', 'HEAD']);
  put(repository, 'apps/core/mix.lock', `%{${produced.core.map(p => `${p.name}: {:hex, :${p.name}, "1.0.0", "${p.inner}", [:mix], [], "hexpm", "${p.outer}"}`).join(', ')}, git_notice: {:git, "https://example.invalid/notice.git", "${depCommit}", [ref: "${depCommit}", sparse: "packages/demo"]}}\n`);
  put(repository, 'packages/decision-kernel/manifest.toml', `packages = [\n  { name = "notice_gleam", version = "1.0.0", build_tools = ["gleam"], requirements = [], source = "hex", outer_checksum = "${produced.gleam}" },\n]\n\n[requirements]\nnotice_gleam = { version = "~> 1.0" }\n`);
  put(repository, 'packages/decision-kernel/build/packages/packages.toml', '[packages]\nnotice_gleam = "1.0.0"\n\n[git]\n'); put(repository, 'packages/decision-kernel/build/packages/gleam.lock', '');
  git(['init', '-b', 'main']); git(['add', '.']); git(['-c', 'user.name=Fixture', '-c', 'user.email=fixture@example.invalid', 'commit', '-m', 'test(host): freeze actual notice source cohort']);
  const tag = 'v1.2.3', commit = git(['rev-parse', 'HEAD']); git(['tag', tag]); await recordInputs(repository, tag, commit, join(repository, 'var/inputs'));
  const sourcePath = join(repository, 'var/inputs/source-inputs.json'), coreDir = join(repository, 'var/core-material'), gleamDir = join(repository, 'var/gleam-material');
  const core = await checkCoreMaterial({ repository, tag, commit, sourcePath, cache: coreCache, output: coreDir }), gleam = await checkGleamMaterial({ repository, tag, commit, sourcePath, cache: gleamCache, output: gleamDir });
  return { repository, tag, commit, sourcePath, coreCache, corePath: join(coreDir, 'core-material.json'), coreSha256: core.receiptSha256, gleamCache, gleamPath: join(gleamDir, 'gleam-material.json'), gleamSha256: gleam.receiptSha256, output: join(repository, 'var/notices') };
}
