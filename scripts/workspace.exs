defmodule FrameshiftWorkspace do
  @moduledoc """
  Checks declared component ownership and statically visible workspace imports.

  `check/1` reads `workspace.json` and the Git-index/untracked file inventory,
  then validates component names, roots, dependency edges and owned source files.
  `inspect_files/3` accepts an explicit inventory for fixtures and returns
  human-readable violations; an empty list means the inspected boundaries pass.

  ## What is inspected

  Elixir syntax, frontend ESM/alias imports and pure Gleam imports are parsed
  without evaluating project files. Unknown dependencies, cycles, escaped/unowned
  roots and disallowed static cross-component imports are errors. Unsupported
  opaque/glob import forms refuse instead of guessing an allowed target.

  This is an architecture-policy check, not a sandbox for dynamic code,
  cross-process messages, operating-system I/O or credential use. Runtime and
  installed-release boundaries require their own checks; passing this inventory
  cannot establish those behaviors.
  """

  @spec check(String.t()) :: [String.t()]
  def check(root) do
    components =
      root
      |> Path.join("workspace.json")
      |> File.read!()
      |> :json.decode()
      |> Map.fetch!("components")

    {files, 0} =
      System.cmd("git", ["ls-files", "--cached", "--others", "--exclude-standard", "-z"],
        cd: root
      )

    inspect_files(root, components, String.split(files, <<0>>, trim: true))
  end

  @spec inspect_files(String.t(), [map()], [String.t()]) :: [String.t()]
  def inspect_files(root, components, files) do
    configuration_errors(root, components) ++
      Enum.flat_map(files, &file_errors(root, components, &1))
  end

  defp configuration_errors(root, components) do
    names = Enum.map(components, & &1["name"])
    roots = Enum.map(components, & &1["root"])
    duplicates = duplicate_errors(names, "component") ++ duplicate_errors(roots, "root")
    duplicates ++ Enum.flat_map(components, &component_errors(root, components, names, &1))
  end

  defp duplicate_errors(values, kind) do
    values
    |> Enum.frequencies()
    |> Enum.filter(fn {_, count} -> count > 1 end)
    |> Enum.map(fn {value, _} -> "duplicate #{kind}: #{value}" end)
  end

  defp component_errors(root, components, names, component) do
    unknown = component["depends_on"] -- names
    errors = Enum.map(unknown, &"#{component["name"]}: unknown dependency #{&1}")
    errors = errors ++ cycle_errors(component["name"], component["name"], components, [])
    location = component["root"]

    cond do
      Path.type(location) != :relative or Path.expand(location, root) == root or
          not String.starts_with?(Path.expand(location, root), root <> "/") ->
        ["#{component["name"]}: root must stay inside workspace" | errors]

      component["planned"] != true and not File.dir?(Path.join(root, location)) ->
        ["#{component["name"]}: missing root #{location}" | errors]

      true ->
        errors
    end
  end

  defp cycle_errors(start, current, components, seen) do
    cond do
      current in seen ->
        ["dependency cycle from #{start}: #{Enum.join(Enum.reverse([current | seen]), " -> ")}"]

      component = Enum.find(components, &(&1["name"] == current)) ->
        Enum.flat_map(
          component["depends_on"],
          &cycle_errors(start, &1, components, [current | seen])
        )

      true ->
        []
    end
  end

  defp file_errors(root, components, file) do
    owner = owner_for_path(components, file)

    cond do
      Path.basename(file) == "mix.exs" and is_nil(owner) ->
        ["#{file}: unowned Mix project"]

      is_nil(owner) ->
        []

      Path.extname(file) in [".ex", ".exs"] ->
        inspect_elixir(root, components, owner, file)

      Path.extname(file) == ".gleam" ->
        inspect_gleam(root, owner, file)

      Path.extname(file) in [".js", ".mjs", ".ts", ".svelte"] ->
        inspect_frontend(root, components, owner, file)

      true ->
        []
    end
  end

  defp inspect_frontend(root, components, owner, file) do
    source = File.read!(Path.join(root, file))

    scripts =
      if Path.extname(file) == ".svelte" do
        Regex.scan(~r/<script\b[^>]*>(.*?)<\/script>/s, source, capture: :all_but_first)
        |> List.flatten()
      else
        [source]
      end

    scripts
    |> Enum.flat_map(&frontend_imports/1)
    |> Enum.flat_map(fn
      {:opaque, kind} -> ["#{file}: #{kind} requires a literal import path"]
      {:glob, _} -> ["#{file}: import.meta.glob bypasses workspace dependency checks"]
      {_, specifier} -> frontend_import_errors(root, components, owner, file, specifier)
    end)
    |> Enum.uniq()
  end

  defp frontend_imports(source) do
    tokens =
      Regex.scan(
        ~r/\/\/[^\n]*|\/\*[\s\S]*?\*\/|"(?:\\.|[^"\\])*"|'(?:\\.|[^'\\])*'|`(?:\\.|[^`\\])*`|[A-Za-z_$][A-Za-z0-9_$]*|[^\s]/,
        source
      )
      |> List.flatten()
      |> Enum.reject(&(String.starts_with?(&1, "//") or String.starts_with?(&1, "/*")))
      |> Enum.map(fn token ->
        if String.starts_with?(token, ["\"", "'", "`"]),
          do: {:quoted, token},
          else: token
      end)

    embedded =
      Enum.flat_map(tokens, fn
        {:quoted, "`" <> _ = template} ->
          if String.contains?(template, "${") and
               Regex.match?(~r/\bimport\s*(?:\(|\.)/, template),
             do: [{:opaque, "template import"}],
             else: []

        _ ->
          []
      end)

    embedded ++ collect_frontend_imports(tokens, [])
  end

  defp collect_frontend_imports([], found), do: Enum.reverse(found)

  defp collect_frontend_imports(["import", ".", "meta", ".", glob | rest], found)
       when glob in ["glob", "globEager"] do
    collect_frontend_imports(rest, [{:glob, nil} | found])
  end

  defp collect_frontend_imports(["import", "(" | rest], found) do
    case rest do
      [{:quoted, literal}, ")" | tail] ->
        collect_frontend_imports(tail, [{:dynamic, literal} | found])

      _ ->
        collect_frontend_imports(rest, [{:opaque, "dynamic import"} | found])
    end
  end

  defp collect_frontend_imports(["import", {:quoted, literal} | rest], found),
    do: collect_frontend_imports(rest, [{:static, literal} | found])

  defp collect_frontend_imports(["import" | rest], found) do
    case import_from(rest) do
      nil -> collect_frontend_imports(rest, found)
      literal -> collect_frontend_imports(rest, [{:static, literal} | found])
    end
  end

  defp collect_frontend_imports(["export", kind | rest], found) when kind in ["{", "*"] do
    case import_from(rest) do
      nil -> collect_frontend_imports(rest, found)
      literal -> collect_frontend_imports(rest, [{:static, literal} | found])
    end
  end

  defp collect_frontend_imports([_ | rest], found), do: collect_frontend_imports(rest, found)

  defp import_from(tokens) do
    tokens
    |> Enum.take_while(&(&1 not in [";", "import", "export"]))
    |> Enum.chunk_every(2, 1, :discard)
    |> Enum.find_value(fn
      ["from", {:quoted, literal}] -> literal
      _ -> nil
    end)
  end

  defp frontend_import_errors(root, components, owner, file, literal) do
    specifier = binary_part(literal, 1, byte_size(literal) - 2)

    cond do
      String.starts_with?(literal, "`") or String.contains?(specifier, "\\") ->
        ["#{file}: import path must be an unescaped string literal"]

      String.starts_with?(specifier, ["./", "../"]) ->
        frontend_path_errors(root, components, owner, file, specifier, Path.dirname(file))

      String.starts_with?(specifier, "$") ->
        frontend_alias_errors(root, components, owner, file, specifier)

      String.starts_with?(specifier, ["/", "@frameshift/", "#"]) ->
        ["#{file}: unregistered frontend import #{specifier}"]

      true ->
        []
    end
  end

  defp frontend_alias_errors(root, components, owner, file, specifier) do
    [alias_name | remainder] = String.split(specifier, "/", parts: 2)
    aliases = Map.get(owner, "frontend_aliases", %{})

    cond do
      alias_name in Map.get(owner, "frontend_virtual_imports", []) ->
        []

      target = aliases[alias_name] ->
        relative = Path.join([target | remainder])
        frontend_path_errors(root, components, owner, file, specifier, relative, true)

      true ->
        ["#{file}: unknown frontend alias #{alias_name}"]
    end
  end

  defp frontend_path_errors(root, components, owner, file, specifier, base, resolved? \\ false) do
    target =
      if resolved?,
        do: Path.expand(base, root),
        else: Path.expand(specifier, Path.join(root, base))

    if target == root or not String.starts_with?(target, root <> "/") do
      ["#{file}: import #{specifier} escapes the workspace"]
    else
      target_owner = owner_for_path(components, Path.relative_to(target, root))
      dependency_error(owner, target_owner, "#{file}: import #{specifier}")
    end
  end

  defp inspect_gleam(root, owner, file) do
    if is_list(owner["pure_imports"]) and String.starts_with?(file, owner["root"] <> "/src/") do
      pure_gleam_errors(root, owner, file, File.read!(Path.join(root, file)))
    else
      []
    end
  end

  defp pure_gleam_errors(root, owner, file, source) do
    # Gleam strings and line comments cannot introduce imports or externals.
    source = Regex.replace(~r/"(?:\\.|[^"\\])*"|\/\/[^\n]*/s, source, " ")

    external =
      if Regex.match?(~r/@external\s*\(/, source),
        do: ["#{file}: native externals are prohibited in pure source"],
        else: []

    imports =
      Regex.scan(
        ~r/\bimport\s+([a-z][a-z0-9_\/]*)(?:\.\{([^}]*)\})?(?:\s+as\s+([a-z][a-z0-9_]*))?/s,
        source,
        capture: :all_but_first
      )

    external ++
      Enum.flat_map(imports, fn [name | rest] ->
        pure_import_errors(root, owner, file, name) ++
          nondeterministic_call_errors(file, source, name, rest)
      end)
  end

  defp nondeterministic_call_errors(file, source, name, rest) do
    selected = Enum.at(rest, 0, "")
    alias_name = Enum.at(rest, 1, "")
    qualifier = if alias_name == "", do: Path.basename(name), else: alias_name

    forbidden =
      case name do
        "gleam/list" -> ["shuffle", "sample"]
        "gleam/int" -> ["random"]
        _ -> []
      end

    Enum.flat_map(forbidden, fn function ->
      qualified = Regex.compile!("\\b" <> qualifier <> "\\s*\\.\\s*" <> function <> "\\b")
      imported = Regex.compile!("(?:^|,)\\s*" <> function <> "\\b")

      if Regex.match?(qualified, source) or Regex.match?(imported, selected),
        do: ["#{file}: nondeterministic #{name}.#{function} is prohibited in pure source"],
        else: []
    end)
  end

  defp pure_import_errors(root, owner, file, name) do
    local = Path.join([root, owner["root"], "src", name <> ".gleam"])

    if name in owner["pure_imports"] or File.regular?(local) do
      []
    else
      ["#{file}: #{name} is not an admitted pure import"]
    end
  end

  defp inspect_elixir(root, components, owner, file) do
    case Code.string_to_quoted(File.read!(Path.join(root, file)), columns: true) do
      {:ok, ast} ->
        {_, errors} = Macro.prewalk(ast, [], &inspect_node(&1, &2, components, owner, file, root))
        Enum.uniq(Enum.reverse(errors))

      {:error, _} ->
        ["#{file}: cannot inspect invalid Elixir syntax"]
    end
  end

  defp inspect_node({:__aliases__, meta, names} = node, errors, components, owner, file, _) do
    name =
      names
      |> Enum.take_while(&is_atom/1)
      |> Enum.map_join(".", &Atom.to_string/1)
      |> String.trim_leading("Elixir.")

    {node, reference_errors(components, owner, name, "#{file}:#{meta[:line]}") ++ errors}
  end

  defp inspect_node({:path, path} = node, errors, components, owner, file, root)
       when is_binary(path) do
    target = path |> Path.expand(Path.dirname(Path.join(root, file))) |> Path.relative_to(root)
    target_owner = owner_for_path(components, target)
    error = dependency_error(owner, target_owner, "#{file}: path #{path}")
    {node, error ++ errors}
  end

  defp inspect_node(node, errors, components, owner, file, _) when is_atom(node) do
    name = Atom.to_string(node)

    if String.starts_with?(name, "Elixir.") or name == String.downcase(name) do
      {node,
       reference_errors(components, owner, String.trim_leading(name, "Elixir."), file) ++ errors}
    else
      {node, errors}
    end
  end

  defp inspect_node(node, errors, _, _, _, _), do: {node, errors}

  defp reference_errors(components, owner, name, location) do
    target =
      Enum.find(components, fn component ->
        Enum.any?(component["modules"], &module_matches?(name, &1))
      end)

    dependency_error(owner, target, "#{location}: #{name}")
  end

  defp module_matches?(name, prefix),
    do: name == prefix or String.starts_with?(name, [prefix <> ".", prefix <> "@"])

  defp dependency_error(_, nil, _), do: []

  defp dependency_error(owner, target, location) do
    if target["name"] == owner["name"] or target["name"] in owner["depends_on"] do
      []
    else
      ["#{location}: #{owner["name"]} cannot depend on #{target["name"]}"]
    end
  end

  defp owner_for_path(components, file) do
    Enum.find(components, &(file == &1["root"] or String.starts_with?(file, &1["root"] <> "/")))
  end
end
