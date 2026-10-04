Code.require_file("workspace.exs", __DIR__)
ExUnit.start()

defmodule FrameshiftWorkspaceTest do
  @moduledoc false

  use ExUnit.Case, async: true

  setup do
    root =
      Path.join(System.tmp_dir!(), "frameshift-workspace-#{System.unique_integer([:positive])}")

    File.mkdir_p!(root)
    on_exit(fn -> File.rm_rf!(root) end)

    components = [
      %{
        "name" => "core",
        "root" => "apps/core",
        "modules" => ["Frameshift"],
        "depends_on" => ["decisions"],
        "planned" => true
      },
      %{
        "name" => "platform",
        "root" => "apps/platform",
        "modules" => ["FrameshiftPlatform"],
        "depends_on" => ["decisions"],
        "frontend_aliases" => %{
          "$phoenix" => "apps/platform/assets/src/lib/generated",
          "$lib" => "apps/platform/assets/src/lib"
        },
        "frontend_virtual_imports" => ["$app"],
        "planned" => true
      },
      %{
        "name" => "decisions",
        "root" => "packages/decisions",
        "modules" => ["frameshift_decisions"],
        "depends_on" => [],
        "pure_imports" => ["gleam/int", "gleam/list"],
        "planned" => true
      }
    ]

    %{root: root, components: components}
  end

  test "allows shared decisions without coupling the applications", context do
    assert inspect_source(
             context,
             "apps/core/lib/sample.ex",
             "defmodule Frameshift.Sample do\n def run, do: :frameshift_decisions.run()\nend"
           ) == []

    assert inspect_source(
             context,
             "apps/platform/lib/sample.ex",
             "defmodule FrameshiftPlatform.Sample do\n def run, do: :frameshift_decisions.run()\nend"
           ) == []
  end

  test "rejects cross-application aliases and fully qualified calls", context do
    for source <- [
          "alias Frameshift.Library, as: Library",
          "Frameshift.Library.list()",
          ":\"Elixir.Frameshift.Library\".list()"
        ] do
      assert [error] = inspect_source(context, "apps/platform/lib/sample.ex", source)
      assert error =~ "platform cannot depend on core"
    end
  end

  test "ignores module-like names in strings and comments", context do
    assert inspect_source(
             context,
             "apps/platform/lib/sample.ex",
             "# Frameshift.Library\n\"Frameshift.Library\""
           ) == []
  end

  test "rejects shared package imports of an application", context do
    assert [error] =
             inspect_source(
               context,
               "packages/decisions/lib/sample.ex",
               "alias FrameshiftPlatform.Repo"
             )

    assert error =~ "decisions cannot depend on platform"
  end

  test "rejects cross-application path dependencies", context do
    assert [error] =
             inspect_source(
               context,
               "apps/platform/mix.exs",
               "[{:frameshift_core, path: \"../core\"}]"
             )

    assert error =~ "platform cannot depend on core"
  end

  test "rejects an unregistered application", context do
    assert inspect_source(context, "apps/hidden/mix.exs", "[]") == [
             "apps/hidden/mix.exs: unowned Mix project"
           ]
  end

  test "rejects invalid syntax instead of skipping inspection", context do
    assert inspect_source(context, "apps/core/lib/broken.ex", "defmodule Broken do") == [
             "apps/core/lib/broken.ex: cannot inspect invalid Elixir syntax"
           ]
  end

  test "rejects cyclic and unknown dependencies", context do
    components =
      Enum.map(context.components, fn component ->
        if component["name"] == "decisions",
          do: %{component | "depends_on" => ["core", "missing"]},
          else: component
      end)

    errors = FrameshiftWorkspace.inspect_files(context.root, components, [])
    assert Enum.any?(errors, &String.contains?(&1, "dependency cycle"))
    assert Enum.any?(errors, &String.contains?(&1, "unknown dependency missing"))
  end

  test "pure production source rejects I/O and native escape hatches", context do
    file = "packages/decisions/src/geometry.gleam"
    assert [error] = inspect_source(context, file, "import gleam/io\n")
    assert error =~ "gleam/io is not an admitted pure import"

    source = "@external(erlang, \"os\", \"cmd\")\npub fn run(command: String) -> String"
    assert [error] = inspect_source(context, file, source)
    assert error =~ "native externals are prohibited"

    assert [error] = inspect_source(context, file, "import another_package/clock\n")
    assert error =~ "not an admitted pure import"
  end

  test "pure library imports and inspected production modules are allowed", context do
    assert inspect_source(context, "packages/decisions/src/units.gleam", "import gleam/int\n") ==
             []

    assert inspect_source(
             context,
             "packages/decisions/src/geometry.gleam",
             "import units\nimport gleam/list.{type List}\n// @external(erlang, \"os\", \"cmd\")"
           ) == []
  end

  test "test runner I/O is allowed but tests cannot be imported into production", context do
    assert inspect_source(context, "packages/decisions/test/fixture.gleam", "import gleam/io\n") ==
             []

    assert [error] =
             inspect_source(context, "packages/decisions/src/geometry.gleam", "import fixture\n")

    assert error =~ "fixture is not an admitted pure import"
  end

  test "rejects random operations inside otherwise admitted library modules", context do
    for source <- [
          "import gleam/list\npub fn run() { list.shuffle([1]) }",
          "import gleam/list as items\npub fn run() { items.sample([1], 1) }",
          "import gleam/list.{\n shuffle as choose,\n map,\n}\npub fn run() { choose([1]) }",
          "import gleam/int.{random}\npub fn run() { random(5) }",
          "import gleam/int as number\npub fn run() { number.random }"
        ] do
      assert [error] = inspect_source(context, "packages/decisions/src/randomness.gleam", source)
      assert error =~ "nondeterministic"
    end
  end

  test "inspects inline declarations and ignores strings and comments", context do
    file = "packages/decisions/src/example.gleam"
    assert [error] = inspect_source(context, file, "import gleam/list import gleam/io")
    assert error =~ "gleam/io"

    source = "pub const example = \"import gleam/io\"\n// import gleam/io\nimport gleam/list"
    assert inspect_source(context, file, source) == []

    assert [error] =
             inspect_source(context, file, "pub const x = 1 @external(erlang, \"os\", \"cmd\")")

    assert error =~ "native externals"
  end

  test "recognizes nested generated Gleam module ownership", context do
    source = ":frameshift_decisions@private.run()"
    components = Enum.map(context.components, &Map.put(&1, "depends_on", []))

    assert [error] =
             inspect_source(
               %{context | components: components},
               "apps/platform/lib/run.ex",
               source
             )

    assert error =~ "platform cannot depend on decisions"
  end

  test "frontend static imports and reexports obey the component graph", context do
    file = "apps/platform/assets/src/routes/+page.ts"

    assert inspect_source(
             context,
             file,
             ~s(import type { Profile } from "$phoenix/types"; export * from "$lib/view"; import "../app.css")
           ) == []

    for source <- [
          ~s(import "../../../../core/lib/private.js"),
          ~s(export * from "../../../../core/lib/private.js")
        ] do
      assert [error] = inspect_source(context, file, source)
      assert error =~ "platform cannot depend on core"
    end
  end

  test "frontend aliases resolve before dependency checks", context do
    file = "apps/platform/assets/src/routes/+page.svelte"

    assert inspect_source(
             context,
             file,
             ~s(<script lang="ts">import type { Profile } from "$phoenix/types"; import { page } from "$app/stores"</script>)
           ) == []

    assert [error] =
             inspect_source(
               context,
               file,
               ~s(<script>import "$phoenix/../../../../../core/lib/private.js"</script>)
             )

    assert error =~ "platform cannot depend on core"
    assert [error] = inspect_source(context, file, ~s(<script>import "$secret/data"</script>))
    assert error =~ "unknown frontend alias $secret"
  end

  test "frontend dynamic imports require literal paths and reject glob escape hatches", context do
    file = "apps/platform/assets/src/routes/+page.ts"
    assert inspect_source(context, file, ~s|const page = import("$lib/view")|) == []

    assert [error] = inspect_source(context, file, "import(path)")
    assert error =~ "requires a literal import path"

    assert [error] = inspect_source(context, file, ~s|import.meta.glob("../../core/**/*.ts")|)
    assert error =~ "import.meta.glob"

    assert [error] = inspect_source(context, file, ~s|const lazy = `${import(path)}`|)
    assert error =~ "template import"
  end

  test "frontend strings and comments cannot invent an import", context do
    file = "apps/platform/assets/src/routes/+page.ts"

    assert inspect_source(
             context,
             file,
             ~s|// import "../../../../../core/private.js"\nconst note = 'import(path)'; /* require(path) */|
           ) == []
  end

  test "frontend imports cannot escape the workspace or disguise a path", context do
    file = "apps/platform/assets/src/routes/+page.ts"

    for source <- [
          ~s(import "../../../../../../outside.js"),
          ~s(import "@frameshift/unregistered"),
          ~s(import `../${name}.js`),
          ~s(import "..\\/../../core/private.js")
        ] do
      assert [_] = inspect_source(context, file, source)
    end
  end

  defp inspect_source(context, file, source) do
    path = Path.join(context.root, file)
    File.mkdir_p!(Path.dirname(path))
    File.write!(path, source)
    FrameshiftWorkspace.inspect_files(context.root, context.components, [file])
  end
end
