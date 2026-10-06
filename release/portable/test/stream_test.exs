defmodule FrameshiftRelease.StreamTest do
  @moduledoc false

  use ExUnit.Case, async: false
  alias FrameshiftRelease.Input

  setup do
    root = Path.join(System.tmp_dir!(), "frameshift-stream-#{System.unique_integer([:positive])}")
    File.mkdir!(root)
    File.chmod!(root, 0o700)
    path = Path.join(root, "input")
    File.write!(path, :binary.copy("exact bytes\0\n", 10_000))
    on_exit(fn -> File.rm_rf!(root) end)
    %{root: root, path: path}
  end

  test "actual streaming exceeds metadata read bounds and matches Git blob and SHA256", %{
    path: path
  } do
    bytes = :binary.copy(<<0, 255, 1, 10>>, div(17 * 1024 * 1024, 4))
    File.write!(path, bytes)
    before = File.stat!(path)

    assert {:ok, {sha256, blob, chunks}} =
             stream(path, [maximum: byte_size(bytes)], fn %{bytes: size, chunks: chunks} ->
               assert size == byte_size(bytes)
               initial = {:crypto.hash_init(:sha256), :crypto.hash_init(:sha), 0}

               {sha256, blob, count} =
                 Enum.reduce(
                   chunks,
                   put_elem(initial, 1, :crypto.hash_update(elem(initial, 1), "blob #{size}\0")),
                   fn chunk, {sha256, blob, count} ->
                     assert byte_size(chunk) in 1..65536

                     {:crypto.hash_update(sha256, chunk), :crypto.hash_update(blob, chunk),
                      count + 1}
                   end
                 )

               {:crypto.hash_final(sha256), :crypto.hash_final(blob), count}
             end)

    assert sha256 == :crypto.hash(:sha256, bytes)
    assert chunks == 272

    git_blob =
      System.get_env("FRAMESHIFT_GIT_BLOB_ORACLE") ||
        case System.cmd("git", ["--no-replace-objects", "hash-object", "--no-filters", "--", path]) do
          {value, 0} -> value
        end

    assert Regex.match?(~r/\A[0-9a-f]{40}\z/, String.trim(git_blob))
    assert String.trim(git_blob) == Base.encode16(blob, case: :lower)

    assert Map.drop(Map.from_struct(before), [:atime]) ==
             Map.drop(Map.from_struct(File.stat!(path)), [:atime])
  end

  test "empty explicit bounds and unsafe leaves retain stream refusal", %{path: path, root: root} do
    assert {:error, :invalid_bounds} = stream(path, [], & &1)
    assert {:error, :invalid_bounds} = stream(path, [maximum: 8 * 1024 * 1024 * 1024 + 1], & &1)
    assert {:error, :input_refused} = stream(path, [maximum: 1], & &1)
    File.write!(path, "")
    assert {:ok, []} = stream(path, [minimum: 0, maximum: 0], &Enum.to_list(&1.chunks))
    File.ln_s!(path, Path.join(root, "alias"))
    assert {_, 0} = System.cmd("mkfifo", [Path.join(root, "fifo")])

    for name <- [Path.join(root, "alias"), Path.join(root, "fifo"), root, "/dev/null"] do
      assert {:error, :input_refused} = stream(name, [minimum: 0, maximum: 1], & &1)
    end
  end

  test "ignored partial escaped and other-process streams cannot accept", %{path: path} do
    for consumer <- [
          fn _ -> :ignored end,
          &Enum.take(&1.chunks, 1),
          & &1.chunks,
          fn %{chunks: chunks} ->
            task =
              Task.async(fn ->
                try do
                  Enum.to_list(chunks)
                catch
                  :stream_process_refused -> :refused
                end
              end)

            assert :refused = Task.await(task)
          end
        ] do
      assert {:error, :consumer_refused} = stream(path, [maximum: 200_000], consumer)
    end
  end

  test "same-byte mutation during streaming or after complete consumption refuses", %{path: path} do
    bytes = File.read!(path)

    for moment <- [:during, :after] do
      File.write!(path, bytes)

      assert {:error, :input_refused} =
               stream(path, [maximum: 200_000], fn %{chunks: chunks} ->
                 Enum.reduce(chunks, 0, fn chunk, index ->
                   if moment == :during and index == 0, do: File.write!(path, bytes)
                   index + byte_size(chunk)
                 end)

                 if moment == :after, do: File.write!(path, bytes)
                 :must_not_accept
               end)
    end
  end

  test "reducer failure and stopped caller retain the owner until actual worker exit", %{
    path: path
  } do
    parent = self()

    assert_raise RuntimeError, "stream reducer fixture", fn ->
      stream(path, [maximum: 200_000], fn %{chunks: chunks} ->
        Enum.each(chunks, fn _ ->
          send(parent, {:worker, worker_port()})
          raise "stream reducer fixture"
        end)
      end)
    end

    assert_receive {:worker, {port, pid, _}}
    assert_exited(port, pid)

    caller =
      spawn(fn ->
        stream(path, [maximum: 200_000], fn %{chunks: chunks} ->
          Enum.each(chunks, fn _ ->
            send(parent, {:live, worker_port()})
            receive do: (:never -> :never)
          end)
        end)
      end)

    assert_receive {:live, {port, pid, owner}}, 5000
    monitor = Process.monitor(owner)
    Process.exit(caller, :kill)
    assert_receive {:DOWN, ^monitor, :process, ^owner, :normal}, 5000
    assert_exited(port, pid)
  end

  test "absolute deadline refuses a later next chunk and callback completion", %{path: path} do
    parent = self()

    assert {:error, reason} =
             stream(path, [maximum: 200_000, budget_ms: 1000], fn %{chunks: chunks} ->
               Enum.each(chunks, fn _ ->
                 send(parent, {:started, worker_port()})
                 Process.sleep(1100)
               end)

               :late
             end)

    assert_receive {:started, {port, pid, _}}
    assert reason in [:deadline, :input_refused]
    assert_exited(port, pid)
  end

  test "oversized out-of-order truncated and forged terminal stream responses refuse", %{
    path: path,
    root: root
  } do
    octal = fn bytes ->
      for <<byte <- bytes>>,
        into: "",
        do: "\\" <> String.pad_leading(Integer.to_string(byte, 8), 3, "0")
    end

    for {name, reply} <- [
          {"oversized", <<65549::32>>},
          {"offset", <<13::32, 1, 0, 4, 0, 1::64, 0>>},
          {"truncated", <<65548::32, 1, 0, 4, 0, 0::64, 0>>},
          {"terminal", <<4::32, 1, 0, 3, 0>>}
        ] do
      tool = Path.join(root, name)
      first = <<12::32, 1, 0, 4, 0, 130_000::64>>

      File.write!(
        tool,
        "#!/bin/sh\ndd bs=1 count=#{30 + byte_size(path)} >/dev/null 2>/dev/null\n" <>
          "printf '#{octal.(first)}'\ndd bs=1 count=17 >/dev/null 2>/dev/null\n" <>
          "printf '#{octal.(reply)}'\n"
      )

      File.chmod!(tool, 0o700)

      assert {:error, _} =
               Input.with_stream(path, [maximum: 200_000, worker: tool], &Enum.to_list(&1.chunks))
    end
  end

  test "actual worker refuses skipped overlapping oversized and duplicate pull requests", %{
    path: path
  } do
    for request <- [
          <<2, 1::64, 65536::32>>,
          <<2, 0::64, 65537::32>>,
          <<2, 0::64, 0::32>>,
          <<2, 0::64, 65536::32, 0>>,
          <<1>>
        ] do
      port = open_stream(path)
      assert {<<1, 0, 4, 0, 130_000::64>>, <<>>} = frame(port)
      Port.command(port, <<byte_size(request)::32, request::binary>>)
      assert {_, 65} = exit_status(port)
    end

    port = open_stream(path)
    frame(port)
    pull = <<13::32, 2, 0::64, 65536::32>>
    Port.command(port, pull <> pull)
    assert {<<1, 0, 4, 0, 0::64, chunk::binary>>, rest} = frame(port)
    assert byte_size(chunk) == 65536
    assert {_, 65} = exit_status(port, rest)
  end

  defp stream(path, options, consumer),
    do: Input.with_stream(path, Keyword.put(options, :worker, worker()), consumer)

  defp worker,
    do:
      System.get_env("FRAMESHIFT_RELEASE_INPUT_WORKER") ||
        Path.expand("../worker/zig-out/bin/frameshift-release-input", __DIR__)

  defp worker_port do
    Enum.find_value(Port.list(), fn port ->
      case Port.info(port) do
        nil ->
          nil

        info ->
          if info[:connected] != self() and
               String.ends_with?(List.to_string(info[:name]), "frameshift-release-input"),
             do: {port, info[:os_pid], info[:connected]}
      end
    end)
  end

  defp assert_exited(port, pid) do
    assert Port.info(port) == nil
    assert {_, code} = System.cmd("kill", ["-0", Integer.to_string(pid)], stderr_to_stdout: true)
    assert code != 0
  end

  defp open_stream(path) do
    port = Port.open({:spawn_executable, String.to_charlist(worker())}, [:binary, :exit_status])
    body = <<1, 3, 0, 0, 1::64, 200_000::64, 1000::32, byte_size(path)::16, path::binary>>
    Port.command(port, <<byte_size(body)::32, body::binary>>)
    port
  end

  defp frame(port, bytes \\ <<>>) do
    case bytes do
      <<length::32, body::binary-size(length), rest::binary>> ->
        {body, rest}

      _ ->
        receive do
          {^port, {:data, chunk}} -> frame(port, bytes <> chunk)
        after
          5000 -> flunk("No stream frame")
        end
    end
  end

  defp exit_status(port, bytes \\ <<>>) do
    assert byte_size(bytes) <= 65560

    receive do
      {^port, {:data, chunk}} -> exit_status(port, bytes <> chunk)
      {^port, {:exit_status, code}} -> {bytes, code}
    after
      5000 -> flunk("No actual stream worker exit")
    end
  end
end
