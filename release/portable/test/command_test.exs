defmodule FrameshiftRelease.CommandTest do
  @moduledoc false

  use ExUnit.Case, async: false
  alias FrameshiftRelease.Command

  setup do
    root =
      Path.join(System.tmp_dir!(), "frameshift-command-#{System.unique_integer([:positive])}")

    File.mkdir!(root)
    File.chmod!(root, 0o700)
    on_exit(fn -> File.rm_rf!(root) end)
    %{root: root}
  end

  test "actual argv cwd environment closed stdin and separate stderr", %{root: root} do
    script =
      "printf '%s\\n' \"$PWD\" \"$1\" \"$2\" \"$3\" \"${FS_VALUE}\" \"${FS_REMOVED-unset}\"; printf private >&2; if read ignored; then exit 7; fi"

    assert {:ok, bytes} =
             run(["-c", script, "fixture", "$(touch must-not-exist)", "", "🖼"], root,
               env: [{"FS_VALUE", "exact Ω"}, {"FS_REMOVED", nil}]
             )

    [actual_cwd, rest] = String.split(bytes, "\n", parts: 2)
    assert File.stat!(actual_cwd).inode == File.stat!(root).inode
    assert rest == "$(touch must-not-exist)\n\n🖼\nexact Ω\nunset\n"
    refute File.exists?(Path.join(root, "must-not-exist"))
  end

  test "fair draining accepts simultaneous pressure on both pipes", %{root: root} do
    script =
      "dd if=/dev/zero bs=8192 count=40 2>/dev/null & { dd if=/dev/zero bs=8192 count=40 2>/dev/null; } >&2 & wait"

    assert {:ok, bytes} =
             run(["-c", script], root, stdout_maximum: 400_000, stderr_maximum: 400_000)

    assert bytes == :binary.copy(<<0>>, 327_680)
  end

  test "independent stdout and stderr overflow refuses complete output", %{root: root} do
    for redirect <- ["", " >&2"] do
      assert {:error, :child_output_limit} =
               run(["-c", "{ dd if=/dev/zero bs=65537 count=1 2>/dev/null; }#{redirect}"], root)
    end
  end

  test "invalid arguments launch failures nonzero and signalled exit refuse", %{root: root} do
    for options <- [
          [budget_ms: 0],
          [stdout_maximum: 16 * 1024 * 1024 + 1],
          [stderr_maximum: 0],
          [budget_ms: 1, budget_ms: 2],
          [unknown: true],
          [env: [{"KEY", "a"}, {"KEY", "b"}]],
          [env: [{"BAD=KEY", "value"}]]
        ] do
      assert {:error, :invalid_command} = run([], root, options)
    end

    for args <- [[<<0>>], [<<255>>], [String.duplicate("x", 8193)], List.duplicate("x", 257)] do
      assert {:error, :invalid_command} = run(args, root)
    end

    assert {:error, :invalid_command} = Command.run("sh", [], root)
    assert {:error, :child_launch_refused} = run([], root, worker: Path.join(root, "absent"))

    assert {:error, :child_failed} =
             Command.run(Path.join(root, "absent"), [], root, worker: worker())

    assert {:error, :child_failed} = run(["-c", "printf private; exit 7"], root)
    assert {:error, :child_failed} = run(["-c", "kill -TERM $$"], root)
    assert {:error, :child_failed} = run([], Path.join(root, "absent"))
  end

  test "known-start deadline retains TERM-ignoring child until its later actual exit", %{
    root: root
  } do
    pid_file = Path.join(root, "pid")
    parent = self()

    spawn(fn ->
      result =
        run(
          ["-c", "trap '' TERM; echo $$ > \"$1\"; sleep 1.5; printf late", "fixture", pid_file],
          root,
          budget_ms: 500
        )

      send(parent, {:result, result})
    end)

    pid = await_pid(pid_file)
    {port, worker_pid, owner} = worker_port()
    assert alive?(pid)
    Process.sleep(600)
    assert alive?(pid)
    assert Process.alive?(owner)
    assert Port.info(port)
    refute_received {:result, _}
    assert_receive {:result, {:error, :child_deadline}}, 5000
    refute alive?(pid)
    refute alive?(worker_pid)
    assert Port.info(port) == nil
  end

  test "caller death retains actual child and requests TERM only once", %{root: root} do
    pid_file = Path.join(root, "pid")
    term_file = Path.join(root, "term")

    caller =
      spawn(fn ->
        run(
          [
            "-c",
            "trap 'printf t >> \"$2\"' TERM; echo $$ > \"$1\"; sleep 1.5; printf late",
            "fixture",
            pid_file,
            term_file
          ],
          root
        )
      end)

    pid = await_pid(pid_file)
    {port, worker_pid, owner} = worker_port()
    monitor = Process.monitor(owner)
    Process.exit(caller, :kill)
    assert_receive {:DOWN, ^monitor, :process, ^owner, :normal}, 5000
    assert File.read!(term_file) == "t"
    refute alive?(pid)
    refute alive?(worker_pid)
    assert Port.info(port) == nil
  end

  test "direct exit without pipe EOF refuses without descendant-exit claims", %{root: root} do
    assert {:error, :child_output_incomplete} = run(["-c", "sleep 0.8 & exit 0"], root)
  end

  test "bounded response parser refuses extra truncated oversized and false exit frames", %{
    root: root
  } do
    success = <<12::32, 1, 0, 1, 0, 0::64>>

    for {name, bytes, status} <- [
          {"oversized", <<65549::32>>, 0},
          {"truncated", <<12::32, 1, 0>>, 0},
          {"wrong-size", <<13::32, 1, 0, 1, 0, 0::64, 1>>, 0},
          {"extra", success <> success, 0},
          {"tail", success <> <<0>>, 0},
          {"false-exit", success, 65}
        ] do
      tool = Path.join(root, name)

      octal =
        for <<byte <- bytes>>,
          into: "",
          do: "\\" <> String.pad_leading(Integer.to_string(byte, 8), 3, "0")

      File.write!(tool, "#!/bin/sh\nprintf '#{octal}'\nexit #{status}\n")
      File.chmod!(tool, 0o700)
      assert {:error, _} = run([], root, worker: tool)
    end
  end

  test "actual worker refuses malformed launch records before child execution", %{root: root} do
    executable = "/bin/echo"

    body =
      <<1, 0, 0::16, 1000::32, 1::32, 1::32, byte_size(executable)::16, byte_size(root)::16,
        executable::binary, root::binary>>

    for {offset, replacement} <- [{0, 2}, {1, 1}, {2, 2}, {16, 255}, {20, 0}] do
      <<before::binary-size(^offset), _, after_bytes::binary>> = body
      changed = before <> <<replacement>> <> after_bytes
      assert_worker_refusal(changed)
    end

    assert_worker_refusal(body <> <<0>>)
    assert_worker_refusal(binary_part(body, 0, byte_size(body) - 1))
  end

  defp assert_worker_refusal(body) do
    port = Port.open({:spawn_executable, String.to_charlist(worker())}, [:binary, :exit_status])
    Port.command(port, <<byte_size(body)::32, body::binary>>)
    assert {<<4::32, 1, 1, 1, 0>>, 65} = worker_exit(port, <<>>)
  end

  defp worker_exit(port, bytes) do
    receive do
      {^port, {:data, chunk}} -> worker_exit(port, bytes <> chunk)
      {^port, {:exit_status, status}} -> {bytes, status}
    after
      5000 -> flunk("Worker did not retain a known refusal through actual exit")
    end
  end

  defp run(arguments, root, options \\ []),
    do: Command.run("/bin/sh", arguments, root, Keyword.put_new(options, :worker, worker()))

  defp worker,
    do:
      System.get_env("FRAMESHIFT_RELEASE_COMMAND_WORKER") ||
        Path.expand("../worker/zig-out/bin/frameshift-release-command", __DIR__)

  defp await_pid(path, attempts \\ 500) do
    case File.read(path) do
      {:ok, bytes} when bytes != "" ->
        String.trim(bytes) |> String.to_integer()

      _ when attempts > 0 ->
        Process.sleep(10)
        await_pid(path, attempts - 1)

      _ ->
        flunk("Command did not reach known-start fixture")
    end
  end

  defp worker_port do
    Enum.find_value(Port.list(), fn port ->
      case Port.info(port) do
        nil ->
          nil

        info ->
          if String.ends_with?(List.to_string(info[:name]), "frameshift-release-command"),
            do: {port, info[:os_pid], info[:connected]}
      end
    end) || flunk("Missing owned command worker")
  end

  defp alive?(pid) do
    {_, status} = System.cmd("kill", ["-0", Integer.to_string(pid)], stderr_to_stdout: true)
    status == 0
  end
end
