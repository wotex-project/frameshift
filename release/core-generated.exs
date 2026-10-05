defmodule Frameshift.Release.GeneratedSyntax do
  @moduledoc """
  Generates or observes the fixed OTP parser-tools cohort for release evidence.

  ## Ownership and supported inputs

  This private release helper supports only the five lexer/parser grammars
  already identified by the core dependency source contract. The Node caller
  first admits archive/Git source receipts and captured input identities, then
  copies bounded grammars into a private `package/src` tree. This helper never
  compiles or loads the generated Erlang actions and never changes dependency
  caches, a retained candidate, its receipts or the application Library.

  ## Operations and observations

  `run/1` accepts `generate ROOT` or `observe ROOT`. Generation reads one bounded
  JSON selection from stdin, requires absent generated names and invokes the
  inspected `:leex.file/2` or `:yecc.file/2`
  exports using relative source names. Inherited compiler options are removed;
  errors/warnings are returned rather than printed. Generated proof files use
  private modes. `observe ROOT` reports the same generator module/template
  identities without generating or writing any file.

  The observation names OTP, ERTS, parsetools, four generator modules and the
  two default templates. Tool paths appear only in the private child result so
  the caller can recheck their descriptor bytes; persisted records retain
  names, sizes and hashes. Installation paths affect generated `-file` metadata:
  raw output must match the captured hash, without source normalization.

  ## Refusal, recovery and evidence limits

  The caller owns source/output descriptor and namespace custody, independent
  expected hashes, child deadlines/file limits, private persistence and final
  checks after every child. Agreement establishes derivation of selected source
  inputs by the observed cohort; it does not authenticate the publisher/toolchain
  or qualify target BEAM/native execution, license rights or release authority.
  """

  @grammars %{
    "earmark_parser/src/earmark_parser_link_text_lexer.xrl" => :leex,
    "earmark_parser/src/earmark_parser_link_text_parser.yrl" => :yecc,
    "earmark_parser/src/earmark_parser_string_lexer.xrl" => :leex,
    "erlex/src/erlex_lexer.xrl" => :leex,
    "erlex/src/erlex_parser.yrl" => :yecc
  }

  def run([operation, root]) when operation in ["generate", "observe"] do
    System.delete_env("ERL_COMPILER_OPTIONS")
    "29" = System.otp_release()
    ~c"17.1" = :erlang.system_info(:version)
    :ok = Application.load(:parsetools)
    ~c"2.8" = Application.spec(:parsetools, :vsn)
    input = IO.binread(:stdio, 4097)
    true = is_binary(input) and byte_size(input) in 1..4096
    selections = :json.decode(input)
    true = is_list(selections) and length(selections) <= 5
    true = length(Enum.uniq(selections)) == length(selections)
    true = Enum.all?(selections, &Map.has_key?(@grammars, &1))
    directory!(root)

    generated =
      if operation == "generate" do
        Enum.map(selections, fn selection ->
          [package, "src", name] = Path.split(selection)
          package_root = Path.join(root, package)
          directory!(package_root)
          directory!(Path.join(package_root, "src"))
          grammar = Path.join([package_root, "src", name])
          %{type: :regular, mode: mode, links: 1, size: size} = File.lstat!(grammar)
          0o600 = Bitwise.band(mode, 0o7777)
          true = size in 1..(64 * 1024)
          output = Path.rootname(grammar) <> ".erl"
          {:error, :enoent} = File.lstat(output)

          File.cd!(package_root, fn ->
            relative = String.to_charlist(Path.join("src", name))

            case apply(Map.fetch!(@grammars, selection), :file, [
                   relative,
                   [
                     report_errors: false,
                     report_warnings: false,
                     return_errors: true,
                     return_warnings: true
                   ]
                 ]) do
              {:ok, _file, []} -> :ok
              {:ok, _file} -> :ok
              _ -> raise "generated syntax refused"
            end
          end)

          :ok = File.chmod(output, 0o600)
          file = facts!(output)
          true = file.bytes in 1..(2 * 1024 * 1024)
          %{path: Path.rootname(selection) <> ".erl", bytes: file.bytes, sha256: file.sha256}
        end)
      else
        []
      end

    modules =
      Enum.map([:leex, :yecc, :yeccparser, :yeccscan], fn module ->
        {:module, ^module} = Code.ensure_loaded(module)

        module
        |> :code.which()
        |> List.to_string()
        |> facts!()
        |> Map.put(:name, Atom.to_string(module))
      end)

    include = :parsetools |> :code.lib_dir(:include) |> List.to_string()

    templates =
      Enum.map(
        ["leexinc.hrl", "yeccpre.hrl"],
        &Map.put(facts!(Path.join(include, &1)), :name, &1)
      )

    IO.binwrite(:stdio, [
      :json.encode(%{
        otp: "29",
        erts: "17.1",
        parsetools: "2.8",
        modules: modules,
        templates: templates,
        generated: generated
      }),
      "\n"
    ])
  end

  defp directory!(path) do
    %{type: :directory, mode: mode} = File.lstat!(path)
    0o700 = Bitwise.band(mode, 0o7777)
  end

  defp facts!(path) do
    %{type: :regular, size: size} = File.lstat!(path)
    true = size in 1..(8 * 1024 * 1024)
    bytes = File.open!(path, [:read, :binary], &IO.binread(&1, size + 1))
    true = byte_size(bytes) == size
    %{path: path, bytes: size, sha256: Base.encode16(:crypto.hash(:sha256, bytes), case: :lower)}
  end
end

Frameshift.Release.GeneratedSyntax.run(System.argv())
