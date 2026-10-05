Code.prepend_paths(
  Path.wildcard("/src/_build/test/lib/*/ebin")
  |> Enum.reject(&(Path.basename(Path.dirname(&1)) in ["exile", "exqlite"]))
)

Code.prepend_paths(["/opt/exile/ebin", "/opt/exqlite/ebin"])
ExUnit.start()

defmodule Frameshift.Import.LinuxUploadContract do
  @moduledoc false

  use ExUnit.Case, async: false

  test "existing nonroot owner corpus retains private temporary custody" do
    directory = "/tmp/codec-service"
    File.mkdir!(directory)
    File.chown!(directory, 65_534)
    File.chmod!(directory, 0o700)

    assert {output, 0} =
             System.cmd(
               "runuser",
               [
                 "-u",
                 "nobody",
                 "--",
                 "elixir",
                 "/src/test/frameshift/native_codec/linux_owner_join.exs"
               ],
               env: [{"TMPDIR", directory}],
               stderr_to_stdout: true
             )

    assert output =~ "10 passed"
  end

  test "fresh Linux SQLite and Exile join different kernel actors to real import registration" do
    root = "/tmp/import-service"
    control = "/tmp/import-control"
    File.mkdir!(root)
    File.chown!(root, 65_534)
    File.chmod!(root, 0o700)
    File.mkdir!(control)
    File.chmod!(control, 0o777)

    service =
      Task.async(fn ->
        System.cmd(
          "runuser",
          [
            "-u",
            "nobody",
            "-g",
            "staff",
            "--",
            "elixir",
            "/src/test/frameshift/import/linux_upload_service.exs"
          ],
          env: [{"TMPDIR", root}],
          stderr_to_stdout: true
        )
      end)

    assert eventually(fn -> File.exists?(Path.join(control, "ready")) end)

    assert {output, 0} =
             System.cmd(
               "runuser",
               [
                 "-u",
                 "daemon",
                 "-g",
                 "staff",
                 "--",
                 "elixir",
                 "/src/test/frameshift/import/linux_upload_client.exs"
               ],
               stderr_to_stdout: true
             )

    assert output =~ "authenticated-import-passed"

    assert {output, 0} =
             System.cmd(
               "runuser",
               [
                 "-u",
                 "nobody",
                 "-g",
                 "staff",
                 "--",
                 "elixir",
                 "/src/test/frameshift/import/linux_upload_client.exs",
                 "other-actor"
               ],
               stderr_to_stdout: true
             )

    assert output =~ "actor-conflict-passed"
    File.write!(Path.join(control, "stop"), "stop")
    assert {output, 0} = Task.await(service, 30_000)
    assert output =~ "fresh-sqlite-import-passed"
    refute File.exists?(Path.join(root, "frameshift-import-custody"))
    refute File.exists?(Path.join(root, "frameshift-codec-custody"))
  end

  test "fresh nonroot SQLite receipts preserve rollback, backup, restart and exact replay" do
    directory = "/tmp/receipt-service"
    File.mkdir!(directory)
    File.chown!(directory, 65_534)
    File.chmod!(directory, 0o700)

    assert {output, 0} =
             System.cmd(
               "runuser",
               [
                 "-u",
                 "nobody",
                 "--",
                 "elixir",
                 "/src/test/frameshift/import/linux_receipt_join.exs"
               ],
               env: [{"TMPDIR", directory}],
               stderr_to_stdout: true
             )

    assert output =~ "14 passed"
  end

  defp eventually(function, attempts \\ 1_000)
  defp eventually(_, 0), do: false

  defp eventually(function, attempts),
    do:
      if(function.(),
        do: true,
        else:
          (
            Process.sleep(10)
            eventually(function, attempts - 1)
          )
      )
end
