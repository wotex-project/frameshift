Code.prepend_paths(
  Path.wildcard("/src/_build/test/lib/*/ebin")
  |> Enum.reject(&(Path.basename(Path.dirname(&1)) in ["exile", "exqlite"]))
)

Code.prepend_paths(["/opt/exile/ebin", "/opt/exqlite/ebin"])
{:ok, _} = Application.ensure_all_started(:exqlite)
ExUnit.start()
Code.require_file(Path.expand("../library/import_command_test.exs", __DIR__))
