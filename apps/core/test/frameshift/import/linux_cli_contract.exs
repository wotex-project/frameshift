Code.prepend_paths(
  Path.wildcard("/src/_build/test/lib/*/ebin")
  |> Enum.reject(&(Path.basename(Path.dirname(&1)) in ["exile", "exqlite"]))
)

ExUnit.start()

defmodule Frameshift.Import.LinuxCLIContract do
  @moduledoc false

  use ExUnit.Case, async: false

  alias Frameshift.CLI
  alias Frameshift.Digest

  @token String.duplicate("a", 64)
  @result %{
    "status" => "succeeded",
    "errorCode" => nil,
    "importedItemID" => Digest.sha256("wire-result")
  }

  setup do
    directory = Path.join(System.tmp_dir!(), "cli-wire-#{System.unique_integer([:positive])}")
    File.mkdir!(directory)
    File.chmod!(directory, 0o710)
    file = Path.join(directory, "source.png")
    socket = Path.join(directory, "c.sock")
    System.put_env("FRAMESHIFT_SERVICE_UID", "65534")
    System.put_env("FRAMESHIFT_CONTROL_GID", "50")
    System.put_env("FRAMESHIFT_SOCKET_PATH", socket)
    on_exit(fn -> File.rm_rf!(directory) end)
    %{socket: socket, source_path: file}
  end

  test "explicit begin resumes at an acknowledged offset and streams bounded exact remaining bytes",
       %{socket: socket, source_path: file} do
    bytes = :binary.copy("x", 6_144) <> "remaining"
    File.write!(file, bytes)

    server =
      server(socket, [
        {"importBegin",
         fn request ->
           assert request["intent"]["sourceDigest"] == Digest.sha256(bytes)
           refute Map.has_key?(request["intent"], "path")
           upload(6_144)
         end},
        {"importChunk",
         fn request ->
           assert request["offset"] == 6_144
           assert request["bytes"] == Base.encode64("remaining")
           upload(byte_size(bytes))
         end},
        {"importFinish", fn _ -> @result end}
      ])

    assert {0, output, ""} = CLI.run(["import", file, "--id", "resumed"])
    refute output =~ @token
    refute output =~ file
    assert Task.await(server) == ["importBegin", "importChunk", "importFinish"]
  end

  test "a closed chunk acknowledgement stops with 69 and no retry or finish", %{
    socket: socket,
    source_path: file
  } do
    File.write!(file, "V")

    server =
      server(socket, [{"importBegin", fn _ -> upload(0) end}, {"importChunk", fn _ -> :close end}])

    assert {69, "", error} = CLI.run(["import", file, "--id", "chunk-loss"])
    refute error =~ file
    refute error =~ @token
    assert Task.await(server) == ["importBegin", "importChunk"]
  end

  test "a closed finish reply preserves uncertainty with 75 and never resubmits", %{
    socket: socket,
    source_path: file
  } do
    File.write!(file, "V")

    server =
      server(socket, [
        {"importBegin", fn _ -> upload(0) end},
        {"importChunk", fn _ -> upload(1) end},
        {"importFinish", fn _ -> :close end}
      ])

    assert {75, "", error} = CLI.run(["import", file, "--id", "finish-loss"])
    assert error =~ "same command ID"
    refute error =~ file
    refute error =~ @token
    assert Task.await(server) == ["importBegin", "importChunk", "importFinish"]
  end

  test "forged acknowledgement offsets cannot cause a duplicate chunk or premature finish", %{
    socket: socket,
    source_path: file
  } do
    File.write!(file, "V")

    server =
      server(socket, [
        {"importBegin", fn _ -> upload(0) end},
        {"importChunk", fn _ -> upload(0) end}
      ])

    assert {69, "", _} = CLI.run(["import", file, "--id", "bad-offset"])
    assert Task.await(server) == ["importBegin", "importChunk"]
  end

  test "source changes after byte acknowledgement refuse before finish", %{
    socket: socket,
    source_path: file
  } do
    File.write!(file, "V")

    server =
      server(socket, [
        {"importBegin", fn _ -> upload(0) end},
        {"importChunk",
         fn _ ->
           File.write!(file, "F")
           upload(1)
         end}
      ])

    assert {69, "", _} = CLI.run(["import", file, "--id", "changed-source"])
    assert Task.await(server) == ["importBegin", "importChunk"]
  end

  test "invalid or over-disclosing finish results remain unknown", %{
    socket: socket,
    source_path: file
  } do
    File.write!(file, "V")

    for result <- [
          %{@result | "importedItemID" => "invalid"},
          Map.put(@result, "path", "/private/fixture")
        ] do
      server =
        server(socket, [
          {"importBegin", fn _ -> upload(0) end},
          {"importChunk", fn _ -> upload(1) end},
          {"importFinish", fn _ -> result end}
        ])

      assert {75, "", error} = CLI.run(["import", file, "--id", "invalid-result"])
      refute error =~ "private"
      assert Task.await(server) == ["importBegin", "importChunk", "importFinish"]
      File.rm!(socket)
    end
  end

  test "status distinguishes pending and failed history without opening an original", %{
    socket: socket
  } do
    for {receipt, expected} <- [
          {%{"status" => "pending", "errorCode" => nil, "importedItemID" => nil}, 75},
          {%{
             "status" => "failed",
             "errorCode" => "library_storage_full",
             "importedItemID" => nil
           }, 2},
          {@result, 0}
        ] do
      server =
        server(socket, [
          {"importStatus",
           fn request ->
             assert request["commandId"] == "retained"
             receipt
           end}
        ])

      assert {^expected, output, _} = CLI.run(["import-status", "retained"])
      {:ok, %{"import" => ^receipt}} = Wotex.JSON.decode(output)
      assert Task.await(server) == ["importStatus"]
      File.rm!(socket)
    end
  end

  defp upload(offset), do: %{"status" => "uploading", "uploadToken" => @token, "offset" => offset}

  defp server(path, steps) do
    {:ok, listener} =
      :gen_tcp.listen(0, [:binary, packet: 4, active: false, ifaddr: {:local, path}])

    File.chmod!(path, 0o660)

    Task.async(fn ->
      operations = Enum.map(steps, &serve_step(listener, &1))

      assert {:error, :timeout} = :gen_tcp.accept(listener, 250)
      :gen_tcp.close(listener)
      operations
    end)
  end

  defp serve_step(listener, {operation, response}) do
    {:ok, socket} = :gen_tcp.accept(listener, 5_000)
    {:ok, bytes} = :gen_tcp.recv(socket, 0, 5_000)
    {:ok, request} = Wotex.JSON.decode(bytes)
    assert request["operation"] == operation
    assert request["auth"] == "peer"

    case response.(request) do
      :close ->
        :ok

      payload ->
        :ok =
          :gen_tcp.send(
            socket,
            RFC8785.encode!(%{
              "version" => 1,
              "requestId" => request["requestId"],
              "ok" => true,
              "import" => payload
            })
          )
    end

    :gen_tcp.close(socket)
    operation
  end
end
