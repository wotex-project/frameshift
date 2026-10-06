defmodule FrameshiftRelease.InputTest do
  @moduledoc false

  use ExUnit.Case, async: false

  alias FrameshiftRelease.Input

  setup do
    root =
      Path.join(System.tmp_dir!(), "frameshift-portable-#{System.unique_integer([:positive])}")

    File.mkdir!(root)
    File.chmod!(root, 0o700)
    path = Path.join(root, "input")
    File.write!(path, "exact bytes\0\n")
    on_exit(fn -> File.rm_rf!(root) end)
    %{root: root, path: path}
  end

  test "actual byte and streamed digest parity retain the file unchanged", %{path: path} do
    bytes = :binary.copy(<<0, 1, 255, 10>>, 200_000)
    File.write!(path, bytes)
    before = File.stat!(path, time: :posix)
    assert {:ok, ^bytes} = read(path, maximum: byte_size(bytes))
    assert {:ok, %{bytes: count, sha256: hash}} = hash(path)
    assert count == byte_size(bytes)
    assert hash == Base.encode16(:crypto.hash(:sha256, bytes), case: :lower)
    after_read = File.stat!(path, time: :posix)

    assert Map.drop(Map.from_struct(before), [:atime]) ==
             Map.drop(Map.from_struct(after_read), [:atime])

    assert File.read!(path) == bytes

    assert {:ok, :consumed} =
             with_input(path, [maximum: byte_size(bytes)], fn ^bytes -> :consumed end)
  end

  test "empty exact bounds and malformed requests refuse without a worker", %{path: path} do
    for options <- [
          [maximum: 1],
          [maximum: -1],
          [maximum: 17 * 1024 * 1024],
          [maximum: 64, minimum: 65],
          [maximum: 64, budget_ms: 0],
          [maximum: 64, private_key: :yes],
          [maximum: 64, maximum: 64],
          [maximum: 64, unexpected: 1]
        ] do
      assert {:error, _} = read(path, options)
    end

    for name <- ["", <<255>>, "a\0b", String.duplicate("a", 4097)] do
      assert {:error, :invalid_bounds} = read(name, maximum: 64)
    end

    File.write!(path, "")
    assert {:error, :invalid_bounds} = read(path, maximum: 0)
    assert {:ok, ""} = read(path, minimum: 0, maximum: 0)
    assert {:ok, %{bytes: 0}} = hash(path, minimum: 0, maximum: 0)
  end

  test "symlink FIFO directory and device refuse promptly without a writer", %{
    path: path,
    root: root
  } do
    alias_path = Path.join(root, "alias")
    File.ln_s!(path, alias_path)
    fifo = Path.join(root, "fifo")
    assert {_, 0} = System.cmd("mkfifo", [fifo])
    start = System.monotonic_time(:millisecond)

    for input <- [alias_path, fifo, root, "/dev/null"] do
      assert {:error, :input_refused} = read(input, maximum: 64)
    end

    assert System.monotonic_time(:millisecond) - start < 5000
    assert File.read!(path) == "exact bytes\0\n"
  end

  test "private and protected trust predicates are independent and exact", %{path: path} do
    for mode <- [0o644, 0o500, 0o700, 0o4600, 0o666] do
      File.chmod!(path, mode)
      assert {:error, :input_refused} = read(path, maximum: 64, private_key: true)
    end

    for mode <- [0o400, 0o600] do
      File.chmod!(path, mode)
      assert {:ok, _} = read(path, maximum: 64, private_key: true, protected_trust: true)
    end

    File.chmod!(path, 0o644)
    assert {:ok, _} = read(path, maximum: 64, protected_trust: true)
    File.chmod!(path, 0o664)
    assert {:error, :input_refused} = read(path, maximum: 64, protected_trust: true)
  end

  test "exact 16 MiB read ceiling streams across pipes and the next byte refuses", %{path: path} do
    bytes = :binary.copy(<<37>>, 16 * 1024 * 1024)
    File.write!(path, bytes)
    assert {:ok, ^bytes} = read(path, maximum: byte_size(bytes))
    File.write!(path, <<38>>, [:append])
    assert {:error, :input_refused} = read(path, maximum: byte_size(bytes))
    assert {:error, :input_refused} = hash(path, maximum: byte_size(bytes))
  end

  test "replacement same-byte rewrite growth truncation mode and link count refuse during consumption",
       %{path: path} do
    for mutation <- [:replace, :same_bytes, :grow, :truncate, :mode, :link] do
      File.chmod!(path, 0o600)
      File.write!(path, "unchanged")

      assert {:error, :input_refused} =
               with_input(path, [maximum: 64], fn bytes ->
                 assert bytes == "unchanged"

                 case mutation do
                   :replace ->
                     File.rename!(path, path <> ".old")
                     File.write!(path, bytes)

                   :same_bytes ->
                     File.write!(path, bytes)

                   :grow ->
                     File.write!(path, bytes <> "more")

                   :truncate ->
                     File.write!(path, "")

                   :mode ->
                     File.chmod!(path, 0o400)

                   :link ->
                     File.ln!(path, path <> ".link")
                 end

                 :must_not_accept
               end)
    end
  end

  test "consumer exception aborts and is reraised after actual worker exit", %{path: path} do
    parent = self()

    assert_raise RuntimeError, "consumer fixture", fn ->
      with_input(path, [maximum: 64], fn _ ->
        send(parent, {:worker, worker_port()})
        raise "consumer fixture"
      end)
    end

    assert_receive {:worker, {port, pid, _owner}}
    assert Port.info(port) == nil
    assert {_, code} = System.cmd("kill", ["-0", Integer.to_string(pid)], stderr_to_stdout: true)
    assert code != 0
  end

  test "deadline cannot promote bytes when the consumer completes late", %{path: path} do
    parent = self()

    assert {:error, error} =
             with_input(path, [maximum: 64, budget_ms: 1000], fn _ ->
               send(parent, :consumption_started)
               Process.sleep(1100)
               :late_result
             end)

    assert_receive :consumption_started
    assert error in [:deadline, :input_refused]
    assert {:ok, _} = read(path, maximum: 64)
  end

  test "stopped caller leaves monitored owner until the actual worker exits", %{path: path} do
    parent = self()

    caller =
      spawn(fn ->
        with_input(path, [maximum: 64], fn _ ->
          send(parent, {:live, worker_port()})

          receive do
            :never -> :never
          end
        end)
      end)

    assert_receive {:live, {port, pid, owner}}, 5000
    monitor = Process.monitor(owner)
    Process.exit(caller, :kill)
    assert_receive {:DOWN, ^monitor, :process, ^owner, :normal}, 5000
    assert Port.info(port) == nil
    assert {_, code} = System.cmd("kill", ["-0", Integer.to_string(pid)], stderr_to_stdout: true)
    assert code != 0
  end

  test "unavailable and malformed tool output refuses without accepted bytes", %{
    path: path,
    root: root
  } do
    assert {:error, :worker_unavailable} =
             read(path, maximum: 64, worker: Path.join(root, "absent"))

    for {label, output} <- [
          {"size", "\\377\\377\\377\\377"},
          {"short", "\\000\\000\\000\\004\\001"},
          {"order", "\\000\\000\\000\\004\\001\\000\\003\\000"}
        ] do
      worker = Path.join(root, label)
      File.write!(worker, "#!/bin/sh\nprintf '#{output}'\n")
      File.chmod!(worker, 0o700)
      assert {:error, _} = read(path, maximum: 64, worker: worker)
    end
  end

  test "actual worker rejects malformed request and queued duplicate finish", %{path: path} do
    for request <- [<<0xFFFFFFFF::32>>, <<27::32, 0::216>>] do
      port = Port.open({:spawn_executable, String.to_charlist(worker())}, [:binary, :exit_status])
      Port.command(port, request)
      assert {_, 65} = collect_exit(port)
    end

    port = open_request(path, 1000)
    assert {<<1, 0, 1, 0, 13::64, "exact bytes\0\n">>, <<>>} = provisional(port)
    assert Port.info(port) != nil
    Port.command(port, <<1::32, 1, 1::32, 1>>)
    assert {_, 65} = collect_exit(port)
    assert Port.info(port) == nil
  end

  test "successful tool frames followed by truncated extra output cannot be accepted", %{
    path: path,
    root: root
  } do
    worker = Path.join(root, "trailing-worker")
    initial = <<25::32, 1, 0, 1, 0, 13::64, "exact bytes\0\n">>
    terminal = <<4::32, 1, 0, 3, 0, 7>>

    octal = fn bytes ->
      for <<byte <- bytes>>,
        into: "",
        do: "\\" <> String.pad_leading(Integer.to_string(byte, 8), 3, "0")
    end

    script =
      "#!/bin/sh\ndd bs=1 count=#{30 + byte_size(path)} >/dev/null 2>/dev/null\nprintf '#{octal.(initial)}'\ndd bs=1 count=5 >/dev/null 2>/dev/null\nprintf '#{octal.(terminal)}'\n"

    File.write!(worker, script)
    File.chmod!(worker, 0o700)
    assert {:error, :input_refused} = read(path, maximum: 64, worker: worker)
  end

  test "actual worker bounds truncated finish and explicit abort without accepting", %{path: path} do
    for finish <- [<<1::32>>, <<1::32, 0>>] do
      port = open_request(path, 200)
      provisional(port)
      Port.command(port, finish)
      assert {_, 65} = collect_exit(port)
      assert Port.info(port) == nil
    end

    assert File.read!(path) == "exact bytes\0\n"
  end

  defp open_request(path, milliseconds) do
    port = Port.open({:spawn_executable, String.to_charlist(worker())}, [:binary, :exit_status])
    body = <<1, 1, 0, 0, 1::64, 64::64, milliseconds::32, byte_size(path)::16, path::binary>>
    Port.command(port, <<byte_size(body)::32, body::binary>>)
    port
  end

  defp provisional(port, bytes \\ <<>>) do
    case bytes do
      <<length::32, body::binary-size(length), rest::binary>> ->
        {body, rest}

      _ ->
        receive do
          {^port, {:data, chunk}} -> provisional(port, bytes <> chunk)
        after
          5000 -> flunk("No provisional worker response")
        end
    end
  end

  defp collect_exit(port, bytes \\ <<>>) do
    assert byte_size(bytes) <= 1024

    receive do
      {^port, {:data, chunk}} -> collect_exit(port, bytes <> chunk)
      {^port, {:exit_status, code}} -> {bytes, code}
    after
      5000 -> flunk("Actual worker exit not observed")
    end
  end

  defp worker,
    do:
      System.get_env("FRAMESHIFT_RELEASE_INPUT_WORKER") ||
        Path.expand("../worker/zig-out/bin/frameshift-release-input", __DIR__)

  defp read(path, options), do: Input.read(path, Keyword.put_new(options, :worker, worker()))

  defp hash(path, options \\ []),
    do: Input.hash(path, Keyword.put_new(options, :worker, worker()))

  defp with_input(path, options, consumer),
    do: Input.with_input(path, Keyword.put_new(options, :worker, worker()), consumer)

  defp worker_port do
    Enum.find_value(Port.list(), fn port ->
      case Port.info(port) do
        nil ->
          nil

        info ->
          if info[:connected] != self() and
               String.ends_with?(List.to_string(info[:name]), "frameshift-release-input") do
            {port, info[:os_pid], info[:connected]}
          end
      end
    end)
  end
end
