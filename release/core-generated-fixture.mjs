import { createHash } from 'node:crypto';
import { execFileSync } from 'node:child_process';
import { chmodSync, copyFileSync, mkdirSync, mkdtempSync, readFileSync, readdirSync, rmSync, writeFileSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { dirname, join, resolve } from 'node:path';
import { checkCoreMaterial } from './core-material.mjs';
import { generatedSyntaxTool } from './core-generated.mjs';
import { recordInputs, verifyInputs } from './inputs.mjs';

const owner = resolve(new URL('..', import.meta.url).pathname);
export const encode = value => Buffer.from(JSON.stringify(value) + '\n');
export const hash = value => createHash('sha256').update(value).digest('hex');
const names = ['earmark_parser/src/earmark_parser_link_text_lexer.xrl', 'earmark_parser/src/earmark_parser_link_text_parser.yrl', 'earmark_parser/src/earmark_parser_string_lexer.xrl', 'erlex/src/erlex_lexer.xrl', 'erlex/src/erlex_parser.yrl'];
function put(root, path, bytes, mode = 0o644) { mkdirSync(dirname(join(root, path)), { recursive: true }); writeFileSync(join(root, path), bytes, { mode }); }
export async function generatedFixture(t) {
  const repository = mkdtempSync(join(tmpdir(), 'frameshift-core-generated-')); t.after(() => rmSync(repository, { recursive: true, force: true }));
  const run = (command, args, cwd = repository) => execFileSync(command, args, { cwd, encoding: 'utf8', stdio: 'pipe', timeout: 60_000, maxBuffer: 64 * 1024 }).trim(), git = args => run('git', args);
  for (const name of readdirSync(join(owner, 'release'))) if ((name.endsWith('.mjs') && !name.endsWith('.test.mjs')) || name.endsWith('.exs')) put(repository, 'release/' + name, readFileSync(join(owner, 'release', name)));
  copyFileSync(join(owner, '.mise.toml'), join(repository, '.mise.toml')); put(repository, '.gitignore', 'var/\ndeps/\n');
  put(repository, 'apps/core/mix.exs', 'defmodule GeneratedFixture do\n  @moduledoc false\n\n  use Mix.Project\n  def project, do: [app: :frameshift_core, version: "0.1.0"]\nend\n');
  mkdirSync(join(repository, 'var'), { mode: 0o700 }); const cache = join(repository, 'var/cache'); mkdirSync(cache, { mode: 0o700 });
  const lexer = 'Definitions.\nD = [0-9]\nRules.\n{D}+ : {token, {integer, TokenLine, list_to_integer(TokenChars)}}.\nErlang code.\n';
  const parser = "Nonterminals expr.\nTerminals number.\nRootsymbol expr.\nexpr -> number : '$1'.\nErlang code.\n";
  for (const path of names) put(repository, 'apps/core/deps/' + path, path.endsWith('.xrl') ? lexer : parser);
  const create = `Application.load(:hex)
root = hd(System.argv())
result = for {name, version} <- [{"earmark_parser", "1.4.46"}, {"erlex", "0.2.9"}] do
  dep = Path.join(root, "apps/core/deps/" <> name)
  files = Path.wildcard(Path.join(dep, "src/*")) |> Enum.map(fn path -> {String.to_charlist(Path.relative_to(path, dep)), File.read!(path)} end)
  {:ok, p} = :mix_hex_tarball.create(%{"name" => name, "version" => version, "build_tools" => ["mix"], "files" => Enum.map(files, fn {p, _} -> List.to_string(p) end)}, files)
  hex = fn bytes -> Base.encode16(bytes, case: :lower) end
  {:ok, outer} = :mix_hex_erl_tar.extract({:binary, p.tarball}, [:memory])
  {_, metadata} = Enum.find(outer, fn {name, _} -> name == ~c"metadata.config" end)
  File.write!(Path.join(dep, "hex_metadata.config"), metadata)
  File.write!(Path.join(dep, ".hex"), :erlang.term_to_binary({{:hex, 2, 0}, %{name: name, version: version, inner_checksum: hex.(p.inner_checksum), outer_checksum: hex.(p.outer_checksum), repo: "hexpm", managers: [:mix]}}))
  File.write!(Path.join(root, "var/cache/" <> name <> "-" <> version <> ".tar"), p.tarball)
  %{name: name, version: version, inner: hex.(p.inner_checksum), outer: hex.(p.outer_checksum)}
end
IO.binwrite(:json.encode(result))`;
  const packages = JSON.parse(run('mise', ['exec', '--', 'mix', 'run', '--no-mix-exs', '--no-start', '--no-compile', '--no-deps-check', '-e', create, '--', repository], owner));
  put(repository, 'apps/core/mix.lock', `%{${packages.map(p => `${p.name}: {:hex, :${p.name}, "${p.version}", "${p.inner}", [:mix], [], "hexpm", "${p.outer}"}`).join(', ')}}\n`);
  git(['init', '-b', 'main']); git(['add', '.']); git(['-c', 'user.name=Fixture', '-c', 'user.email=fixture@example.invalid', 'commit', '-m', 'test(host): define real parser-generator source fixture']);
  const tag = 'v0.1.0', commit = git(['rev-parse', 'HEAD']); git(['tag', tag]); await recordInputs(repository, tag, commit, join(repository, 'var/inputs'));
  const sourcePath = join(repository, 'var/inputs/source-inputs.json'), source = await verifyInputs(repository, tag, commit, sourcePath), coreDir = join(repository, 'var/core-proof');
  const coreResult = await checkCoreMaterial({ repository, tag, commit, sourcePath, cache, output: coreDir }), corePath = join(coreDir, 'core-material.json');
  const scratch = join(repository, 'var/captured-generation'); mkdirSync(scratch, { mode: 0o700 });
  for (const path of names) { const pkg = path.split('/')[0]; if (!readdirSync(scratch).includes(pkg)) { mkdirSync(join(scratch, pkg), { mode: 0o700 }); mkdirSync(join(scratch, pkg, 'src'), { mode: 0o700 }); } copyFileSync(join(repository, 'apps/core/deps', path), join(scratch, path)); }
  for (const path of names) chmodSync(join(scratch, path), 0o600);
  const generated = generatedSyntaxTool('generate', scratch, names).generated;
  for (const file of generated) put(repository, 'apps/core/deps/' + file.path, readFileSync(join(scratch, file.path)));
  // Actual archive/source and generator consumers; the candidate/join fields
  // are independently pinned retained-purpose assertions, not an app build.
  const joined = { schemaVersion: 1, kind: 'macos-dependency-input-join', product: source.product, tag, version: source.version, sourceCommit: commit, sourceInputsSha256: hash(encode(source)), architecture: 'arm64', candidateRecordSha256: '3'.repeat(64), coreReceiptSha256: coreResult.receiptSha256, gleamReceiptSha256: '4'.repeat(64), publicationAuthority: 'none', provedSourceFiles: coreResult.files, generatedInputs: generated.map(file => ({ ...file, path: 'apps/core/deps/' + file.path, mode: 0o644, reason: 'generated-lexer-parser' })) };
  const joinDir = join(repository, 'var/dependency-join'); mkdirSync(joinDir, { mode: 0o700 }); const joinPath = join(joinDir, 'dependency-inputs.json'); writeFileSync(joinPath, encode(joined), { mode: 0o600 });
  return { repository, tag, commit, sourcePath, cache, corePath, coreSha256: coreResult.receiptSha256, joinPath, joinSha256: hash(encode(joined)), joined, output: join(repository, 'var/generated-proof') };
}
export function changeJoin(f, change) { const value = structuredClone(f.joined); change(value); writeFileSync(f.joinPath, encode(value)); return { ...f, joined: value, joinSha256: hash(encode(value)) }; }
