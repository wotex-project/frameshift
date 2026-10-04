Code.prepend_paths(Path.wildcard("/src/_build/test/lib/*/ebin"))

ExUnit.start()
Code.require_file(Path.join(__DIR__, "group_configuration_test.exs"))
Code.require_file(Path.join(__DIR__, "peer_identity_test.exs"))

defmodule Frameshift.LocalIPC.LinuxCredentialContract do
  @moduledoc false

  use ExUnit.Case, async: false

  test "a nonroot resolver admits private inode custody and uses the loaded identity in pinned TLS" do
    root = "/tmp/fs-key-wrong-#{System.unique_integer([:positive])}"
    File.mkdir_p!(root)
    File.chmod!(root, 0o700)
    File.chown!(root, 65_534)
    path = Path.join(root, String.duplicate("f", 64) <> ".pem")
    File.write!(path, "root-owned fixture must not be read")
    File.chmod!(path, 0o600)
    on_exit(fn -> File.rm_rf!(root) end)

    assert {output, 0} =
             System.cmd(
               "runuser",
               [
                 "-u",
                 "nobody",
                 "--",
                 "elixir",
                 "/src/test/frameshift/local_ipc/linux_credential_service.exs",
                 root
               ],
               stderr_to_stdout: true
             )

    assert output =~ "protected-file-pinned-tls-passed"
    assert output =~ "pairing-directory-sync-passed"
    assert File.read!(path) == "root-owned fixture must not be read"
    assert {:ok, %File.Stat{uid: 0, mode: mode}} = File.lstat(path)
    assert Bitwise.band(mode, 0o7777) == 0o600
  end
end

defmodule Frameshift.LocalIPC.LinuxPeerIdentityContract do
  @moduledoc false

  use ExUnit.Case, async: false

  alias Frameshift.LocalIPC.PeerIdentity

  test "reads the Linux kernel UID of the connected owner and another local user" do
    assert :os.type() == {:unix, :linux}
    path = "/tmp/frameshift-peer-#{System.unique_integer([:positive])}.sock"
    {:ok, listener} = :socket.open(:local, :stream, :default)

    on_exit(fn ->
      :socket.close(listener)
      File.rm(path)
    end)

    :ok = :socket.bind(listener, %{family: :local, path: path})
    :ok = :socket.listen(listener)
    :ok = File.chmod(path, 0o777)

    {:ok, local} = :socket.open(:local, :stream, :default)
    :ok = :socket.connect(local, %{family: :local, path: path})
    {:ok, accepted_local} = :socket.accept(listener, 10_000)
    assert {:ok, 0} = PeerIdentity.uid(accepted_local)

    assert {:ok, %{pid: local_pid, uid: 0, gid: 0}} =
             PeerIdentity.credentials(accepted_local)

    assert local_pid > 0
    :socket.close(accepted_local)
    :socket.close(local)

    client =
      Task.async(fn ->
        System.cmd("runuser", ["-u", "nobody", "--", "elixir", "-e", client_code(path)],
          stderr_to_stdout: true
        )
      end)

    {:ok, accepted_other} = :socket.accept(listener, 10_000)
    assert {:ok, 65_534} = PeerIdentity.uid(accepted_other)

    assert {:ok, %{pid: other_pid, uid: 65_534, gid: 65_534}} =
             PeerIdentity.credentials(accepted_other)

    assert other_pid != local_pid
    :socket.close(accepted_other)
    assert {_, 0} = Task.await(client, 10_000)
  end

  defp client_code(path) do
    "{:ok, socket} = :socket.open(:local, :stream, :default); " <>
      ":ok = :socket.connect(socket, %{family: :local, path: #{inspect(path)}}); " <>
      ":socket.close(socket)"
  end
end

defmodule Frameshift.LocalIPC.LinuxDiagnosticsContract do
  @moduledoc false

  use ExUnit.Case, async: false

  setup_all do
    Code.prepend_paths(Path.wildcard("/src/_build/test/lib/*/ebin"))
    assert Code.ensure_loaded?(Frameshift.LocalIPC.DiagnosticsServer)
    :ok
  end

  test "supplementary observers read the real dispatcher while denied users and changed custody refuse" do
    root = "/tmp/fg-control-#{System.unique_integer([:positive])}"
    service_root = root <> "-service"
    path = Path.join(service_root, "d.sock")
    File.mkdir_p!(root)
    File.chmod!(root, 0o777)
    wrong = Path.join(root, "wrong")
    target = Path.join(root, "target")
    File.mkdir_p!(wrong)
    File.mkdir_p!(target)
    File.chmod!(wrong, 0o755)
    File.chmod!(target, 0o755)
    File.write!(Path.join(target, "target"), "untouched")

    on_exit(fn ->
      File.rm_rf(root)
      File.rm_rf(service_root)
    end)

    assert {:error, :unprivileged_service_required} =
             Frameshift.LocalIPC.SocketDirectory.prepare_group(path, 50)

    assert {:error, :enoent} = File.lstat(service_root)

    service =
      Task.async(fn ->
        System.cmd(
          "runuser",
          [
            "-u",
            "nobody",
            "-g",
            "nogroup",
            "-G",
            "staff",
            "--",
            "elixir",
            "/src/test/frameshift/local_ipc/linux_diagnostics_service.exs",
            path,
            root,
            Path.join(wrong, "d.sock"),
            target
          ],
          stderr_to_stdout: true
        )
      end)

    await_file(root, "ready", service)

    assert {:ok, %File.Stat{uid: 65_534, gid: 50, mode: directory_mode}} =
             File.lstat(service_root)

    assert Bitwise.band(directory_mode, 0o7777) == 0o710
    assert {:ok, %File.Stat{uid: 65_534, gid: 50, mode: socket_mode}} = File.lstat(path)
    assert Bitwise.band(socket_mode, 0o7777) == 0o660

    # daemon's primary group is 1, but supplementary staff (50) grants connect.
    assert {output, 0} = client(path, true, "health")
    assert output =~ "observer-primary-gid=1"
    assert output =~ ~s("fixture":true)
    assert output =~ ~s("ok":true)
    assert {denied, 0} = client(path, false, "health")
    assert denied =~ "eacces"
    refute denied =~ ~s("fixture":true)
    assert {mutation, 0} = client(path, true, "command")
    assert mutation =~ ~s("code":"invalid_request")
    assert {forged, 0} = client(path, true, "health", %{"uid" => 0, "gid" => 50})
    assert forged =~ ~s("code":"invalid_request")

    File.write!(Path.join(root, "loosen"), "go")
    await_file(root, "loosened", service)
    assert {changed, 0} = client(path, true, "health")
    assert changed =~ ~s("code":"authentication_required")
    refute changed =~ ~s("fixture":true)
    File.write!(Path.join(root, "restore"), "go")
    await_file(root, "restored", service)
    assert {restored, 0} = client(path, true, "health")
    assert restored =~ ~s("queryCount":2)
    File.write!(Path.join(root, "stop"), "go")
    assert {_, 0} = Task.await(service, 10_000)
    assert {:error, :enoent} = File.lstat(path)
  end

  defp client(path, observer, operation, extra \\ %{}) do
    request =
      Map.merge(%{"version" => 1, "requestId" => "observer", "operation" => operation}, extra)

    payload = RFC8785.encode!(request)

    code = """
    status = File.read!("/proc/self/status")
    row = status |> String.split("\n") |> Enum.find(&String.starts_with?(&1, "Gid:"))
    ["Gid:", primary_gid, _, _, _] = String.split(row)
    IO.puts("observer-primary-gid=" <> primary_gid)
    {:ok, socket} = :socket.open(:local, :stream, :default)
    case :socket.connect(socket, %{family: :local, path: #{inspect(path)}}, 2_000) do
      :ok ->
        bytes = #{inspect(payload)}
        :ok = :socket.send(socket, <<byte_size(bytes)::unsigned-big-32, bytes::binary>>)
        {:ok, <<size::unsigned-big-32>>} = :socket.recv(socket, 4, 5_000)
        {:ok, response} = :socket.recv(socket, size, 5_000)
        IO.puts(response)
      {:error, reason} -> IO.puts(Atom.to_string(reason))
    end
    :socket.close(socket)
    """

    groups = if observer, do: ["-G", "staff"], else: []

    System.cmd(
      "runuser",
      ["-u", "daemon", "-g", "daemon"] ++ groups ++ ["--", "elixir", "-e", code],
      stderr_to_stdout: true
    )
  end

  defp await_file(root, name, service, attempts \\ 1_000)
  defp await_file(_, _, service, 0), do: flunk("service timeout: #{inspect(Task.yield(service))}")

  defp await_file(root, name, service, attempts) do
    cond do
      File.exists?(Path.join(root, name)) ->
        :ok

      result = Task.yield(service) ->
        flunk("service stopped: #{inspect(result)}")

      true ->
        Process.sleep(10)
        await_file(root, name, service, attempts - 1)
    end
  end
end

defmodule Frameshift.LocalIPC.LinuxCommandContract do
  @moduledoc false

  use ExUnit.Case, async: false

  test "distinct Linux application groups hand the connected UID to command claims and completions" do
    root = "/tmp/fg-cmd-#{System.unique_integer([:positive])}"
    path = root <> "-service/c.sock"
    File.mkdir_p!(root)
    File.chmod!(root, 0o777)

    on_exit(fn ->
      for directory <- [
            root,
            Path.dirname(path),
            Path.dirname(path) <> "-observer",
            Path.dirname(path) <> "-data"
          ] do
        File.rm_rf(directory)
      end
    end)

    service =
      Task.async(fn ->
        System.cmd(
          "runuser",
          [
            "-u",
            "nobody",
            "-g",
            "nogroup",
            "-G",
            "staff",
            "--",
            "elixir",
            "/src/test/frameshift/local_ipc/linux_command_service.exs",
            path,
            root
          ],
          stderr_to_stdout: true
        )
      end)

    await_file(root, "ready", service)
    assert :ok = Frameshift.LocalIPC.SocketDirectory.validate_group_socket(path, 50, 65_534)
    observer_path = Path.join(Path.dirname(path) <> "-observer", "d.sock")

    assert :ok =
             Frameshift.LocalIPC.SocketDirectory.validate_group_socket(
               observer_path,
               65_534,
               65_534
             )

    command = %{
      "id" => "actor-command",
      "kind" => "updateInstruction",
      "instruction" => "Linux local setting"
    }

    request = %{
      "version" => 1,
      "requestId" => "linux-command",
      "operation" => "command",
      "auth" => "peer",
      "command" => command
    }

    assert {denied, 0} = client(path, request, false)
    assert denied =~ "eacces"
    assert {accepted, 0} = client(path, request)
    assert accepted =~ ~s("ok":true)
    assert accepted =~ ~s("instruction":"Linux local setting")

    cli_code = """
    Code.prepend_paths(Path.wildcard("/src/_build/test/lib/*/ebin"))
    System.put_env("FRAMESHIFT_SERVICE_UID", "65534")
    System.put_env("FRAMESHIFT_CONTROL_GID", "50")
    System.put_env("FRAMESHIFT_SOCKET_PATH", #{inspect(path)})
    {0, response, ""} = Frameshift.CLI.run(["instruction", "CLI still artwork", "--id", "cli-command"])
    IO.write(response)
    {0, state, ""} = Frameshift.CLI.run(["state"])
    IO.write(state)
    """

    assert {cli, 0} =
             System.cmd(
               "runuser",
               ["-u", "daemon", "-g", "daemon", "-G", "staff", "--", "elixir", "-e", cli_code],
               stderr_to_stdout: true
             )

    assert cli =~ ~s("instruction":"CLI still artwork")

    assert {token, 0} = client(path, %{request | "auth" => String.duplicate("a", 64)})
    assert token =~ ~s("code":"authentication_required")
    assert {forged, 0} = client(path, Map.put(request, "actor_uid", 0))
    assert forged =~ ~s("code":"invalid_request")

    for kind <- ["importFile", "recordVision"] do
      assert {unavailable, 0} =
               client(path, %{
                 request
                 | "command" => %{
                     "id" => kind,
                     "kind" => kind,
                     "importPath" => "/home/caller/private.png"
                   }
               })

      assert unavailable =~ ~s("code":"operation_unavailable")
    end

    pairing = %{
      "version" => 1,
      "requestId" => "no-pair",
      "operation" => "pair",
      "auth" => "peer",
      "bootstrap" => "invalid",
      "discoveredId" => "sim-photo-00000001",
      "origin" => "https://frame.invalid",
      "credentialRef" => "unavailable"
    }

    assert {unavailable_pair, 0} = client(path, pairing)
    assert unavailable_pair =~ ~s("code":"operation_unavailable")

    bootstrap =
      RFC8785.encode!(%{
        "version" => 1,
        "deviceId" => "sim-photo-00000001",
        "serverSpki" => "sha256:" <> String.duplicate("b", 64),
        "secret" => Base.url_encode64(:binary.copy(<<17>>, 16), padding: false)
      })

    source = Path.join(root, "bootstrap.json")
    File.write!(source, bootstrap)
    File.chmod!(source, 0o600)

    code =
      "Code.prepend_paths(Path.wildcard(\"/src/_build/test/lib/*/ebin\")); Frameshift.CLI.main(System.argv())"

    arguments = [
      "pair",
      "sim-photo-00000001",
      "https://frame.invalid",
      "linux-pem-v1:" <> String.duplicate("c", 64),
      "--id",
      "pair-command"
    ]

    assert {refused, 2} =
             System.cmd(
               "/bin/sh",
               [
                 "-c",
                 "exec runuser -u daemon -g daemon -G staff -- elixir \"$@\" < \"$FRAMESHIFT_BOOTSTRAP_FIXTURE\"",
                 "--",
                 "-e",
                 code,
                 "--" | arguments
               ],
               env: [
                 {"FRAMESHIFT_BOOTSTRAP_FIXTURE", source},
                 {"FRAMESHIFT_SERVICE_UID", "65534"},
                 {"FRAMESHIFT_CONTROL_GID", "50"},
                 {"FRAMESHIFT_SOCKET_PATH", path}
               ],
               stderr_to_stdout: true
             )

    assert refused =~ ~s("code":"pairing_preflight_failed")
    refute refused =~ Base.url_encode64(:binary.copy(<<17>>, 16), padding: false)
    # Control membership alone cannot read the distinct observer endpoint.
    assert {observer_denied, 0} =
             client(observer_path, %{
               "version" => 1,
               "requestId" => "observer-denied",
               "operation" => "health"
             })

    assert observer_denied =~ "eacces"

    File.write!(Path.join(root, "loosen"), "go")
    await_file(root, "loosened", service)
    assert {changed, 0} = client(path, request)
    assert changed =~ ~s("code":"authentication_required")
    File.write!(Path.join(root, "restore"), "go")
    await_file(root, "restored", service)
    File.write!(Path.join(root, "stop"), "go")
    assert {_, 0} = Task.await(service, 10_000)
    assert {:error, :enoent} = File.lstat(path)
  end

  test "public inet raw credentials report the actual connected UID and primary GID" do
    path = "/tmp/fg-inet-#{System.unique_integer([:positive])}.sock"
    {:ok, listener} = :gen_tcp.listen(0, [:binary, active: false, ifaddr: {:local, path}])
    File.chmod!(path, 0o777)

    on_exit(fn ->
      :gen_tcp.close(listener)
      File.rm(path)
    end)

    client =
      Task.async(fn ->
        code =
          "{:ok, socket} = :gen_tcp.connect({:local, #{inspect(path)}}, 0, [:binary, active: false]); Process.sleep(250); :gen_tcp.close(socket)"

        System.cmd(
          "runuser",
          ["-u", "daemon", "-g", "daemon", "-G", "staff", "--", "elixir", "-e", code],
          stderr_to_stdout: true
        )
      end)

    {:ok, socket} = :gen_tcp.accept(listener, 10_000)

    assert {:ok, %{pid: pid, uid: 1, gid: 1}} =
             Frameshift.LocalIPC.PeerIdentity.inet_credentials(socket)

    assert pid > 0
    :gen_tcp.close(socket)
    assert {:error, _} = Frameshift.LocalIPC.PeerIdentity.inet_credentials(socket)
    assert {_, 0} = Task.await(client, 10_000)
  end

  defp client(path, request, observer \\ true) do
    payload = RFC8785.encode!(request)

    code = """
    case :gen_tcp.connect({:local, #{inspect(path)}}, 0, [:binary, packet: 4, active: false], 2_000) do
      {:ok, socket} ->
        :ok = :gen_tcp.send(socket, #{inspect(payload)})
        {:ok, response} = :gen_tcp.recv(socket, 0, 5_000)
        IO.puts(response)
        :gen_tcp.close(socket)
      {:error, reason} -> IO.puts(Atom.to_string(reason))
    end
    """

    groups = if observer, do: ["-G", "staff"], else: []

    System.cmd(
      "runuser",
      ["-u", "daemon", "-g", "daemon"] ++ groups ++ ["--", "elixir", "-e", code],
      stderr_to_stdout: true
    )
  end

  defp await_file(root, name, service, attempts \\ 1_000)
  defp await_file(_, _, service, 0), do: flunk("service timeout: #{inspect(Task.yield(service))}")

  defp await_file(root, name, service, attempts) do
    cond do
      File.exists?(Path.join(root, name)) ->
        :ok

      result = Task.yield(service) ->
        flunk("service stopped: #{inspect(result)}")

      true ->
        Process.sleep(10)
        await_file(root, name, service, attempts - 1)
    end
  end
end

defmodule Frameshift.LocalIPC.LinuxClientContract do
  @moduledoc false

  use ExUnit.Case, async: false

  alias Frameshift.LocalIPC.Client

  test "client checks kernel server UID before sending even when filesystem custody matches" do
    root = "/tmp/fg-client-peer-#{System.unique_integer([:positive])}"
    path = Path.join(root, "c.sock")
    File.mkdir_p!(root)
    File.chown!(root, 65_534)
    File.chgrp!(root, 50)
    File.chmod!(root, 0o710)

    {:ok, listener} =
      :gen_tcp.listen(0, [:binary, packet: 4, active: false, ifaddr: {:local, path}])

    File.chown!(path, 65_534)
    File.chgrp!(path, 50)
    File.chmod!(path, 0o660)

    on_exit(fn ->
      :gen_tcp.close(listener)
      File.rm_rf!(root)
    end)

    caller =
      Task.async(fn -> Client.exchange(path, request(), :command, uid: 65_534, gid: 50) end)

    {:ok, connected} = :gen_tcp.accept(listener, 5_000)
    assert {:error, :unavailable} = Task.await(caller)
    assert {:error, :closed} = :gen_tcp.recv(connected, 0, 1_000)
    :gen_tcp.close(connected)
  end

  test "one sent mutation gets unknown outcome for invalid frames, with no retry and finite partial-read deadline" do
    control = "/tmp/fg-client-frame-#{System.unique_integer([:positive])}"
    path = control <> "-service/c.sock"
    File.mkdir_p!(control)
    File.chmod!(control, 0o777)

    on_exit(fn ->
      File.rm_rf!(control)
      File.rm_rf!(Path.dirname(path))
    end)

    service =
      Task.async(fn ->
        System.cmd(
          "runuser",
          [
            "-u",
            "nobody",
            "-g",
            "nogroup",
            "-G",
            "staff",
            "--",
            "elixir",
            "/src/test/frameshift/local_ipc/linux_client_service.exs",
            path,
            Path.join(control, "ready")
          ],
          stderr_to_stdout: true
        )
      end)

    wait = fn wait, attempts ->
      cond do
        File.exists?(Path.join(control, "ready")) ->
          :ok

        result = Task.yield(service) ->
          flunk("fixture exited: #{inspect(result)}")

        attempts == 0 ->
          flunk("fixture timeout")

        true ->
          Process.sleep(10)
          wait.(wait, attempts - 1)
      end
    end

    wait.(wait, 1_000)
    policy = [uid: 65_534, gid: 50]

    previous =
      for name <- ~w(FRAMESHIFT_SERVICE_UID FRAMESHIFT_CONTROL_GID FRAMESHIFT_SOCKET_PATH),
          into: %{},
          do: {name, System.get_env(name)}

    on_exit(fn ->
      Enum.each(previous, fn {name, value} ->
        if value, do: System.put_env(name, value), else: System.delete_env(name)
      end)
    end)

    System.put_env("FRAMESHIFT_SERVICE_UID", "65534")
    System.put_env("FRAMESHIFT_CONTROL_GID", "50")
    System.put_env("FRAMESHIFT_SOCKET_PATH", path)
    assert {2, refusal, ""} = Frameshift.CLI.run(["instruction", "refused", "--id", "retained"])
    assert refusal =~ ~s("code":"command_id_conflict")
    assert {75, "", error} = Frameshift.CLI.run(["instruction", "unknown", "--id", "retained"])
    assert error =~ "command_outcome_unknown"
    refute error =~ path

    for _ <- [:duplicate, :oversized, :truncated] do
      assert {:error, :command_outcome_unknown} =
               Client.exchange(path, request(), :command, policy)
    end

    started = System.monotonic_time(:millisecond)

    assert {:error, :command_outcome_unknown} =
             Client.exchange(path, request(), :command, policy, 50)

    assert System.monotonic_time(:millisecond) - started < 1_000
    assert {:error, :command_outcome_unknown} = Client.exchange(path, request(), :command, policy)

    args = [
      "pair",
      "sim-photo-00000001",
      "https://frame.invalid",
      "linux-pem-v1:" <> String.duplicate("c", 64),
      "--id",
      "physical-retained"
    ]

    secret = Base.url_encode64(:binary.copy(<<17>>, 16), padding: false)

    bootstrap =
      RFC8785.encode!(%{
        "version" => 1,
        "deviceId" => "sim-photo-00000001",
        "serverSpki" => "sha256:" <> String.duplicate("b", 64),
        "secret" => secret
      })

    for bytes <- [
          "",
          "partial",
          String.duplicate("x", 2_049),
          String.replace(bootstrap, "sim-photo-00000001", "other-photo-00001")
        ] do
      {:ok, input} = StringIO.open(bytes)
      assert {64, "", usage} = Frameshift.CLI.run(args, input)
      refute usage =~ secret
      StringIO.close(input)
    end

    owner = self()

    input =
      spawn(fn ->
        receive do
          {:io_request, reader, _, _} ->
            send(owner, {:held_reader, reader})

            receive do
              :stop -> :ok
            end
        end
      end)

    started = System.monotonic_time(:millisecond)
    assert {64, "", _} = Frameshift.CLI.run(args, input)
    assert (System.monotonic_time(:millisecond) - started) in 4_500..6_500
    assert_receive {:held_reader, reader}
    refute Process.alive?(reader)
    send(input, :stop)

    source = Path.join(control, "physical.json")
    File.write!(source, bootstrap)
    File.chmod!(source, 0o600)

    code =
      "Code.prepend_paths(Path.wildcard(\"/src/_build/test/lib/*/ebin\")); Frameshift.CLI.main(System.argv())"

    invoke = fn arguments ->
      System.cmd(
        "/bin/sh",
        [
          "-c",
          "exec elixir \"$@\" < \"$FRAMESHIFT_BOOTSTRAP_FIXTURE\"",
          "--",
          "-e",
          code,
          "--" | arguments
        ],
        env: [{"FRAMESHIFT_BOOTSTRAP_FIXTURE", source}],
        stderr_to_stdout: true
      )
    end

    assert {success, 0} = invoke.(args)
    assert success =~ ~s("frameId":"sim-photo-00000001")
    assert {recovery, 0} = invoke.(["recover-pair" | tl(args)])
    assert recovery =~ ~s("frameId":"sim-photo-00000001")
    assert {mismatch, 75} = invoke.(args)
    assert mismatch =~ "command_outcome_unknown"
    assert {incomplete, 75} = invoke.(args)
    assert incomplete =~ ~s("code":"pairing_incomplete")
    assert {closed, 75} = invoke.(args)
    assert closed =~ "command_outcome_unknown"

    for output <- [success, recovery, mismatch, incomplete, closed] do
      refute output =~ secret
      refute output =~ source
    end

    assert {_, 0} = Task.await(service, 10_000)
  end

  defp request,
    do: %{
      "version" => 1,
      "requestId" => "bounded-client",
      "operation" => "command",
      "auth" => "peer",
      "command" => %{
        "kind" => "updateInstruction",
        "id" => "retained",
        "instruction" => "bounded"
      }
    }
end

defmodule Frameshift.Discovery.LinuxProcessContract do
  @moduledoc false

  use ExUnit.Case, async: false

  alias Frameshift.Discovery.Avahi

  @row ~s(=;eth0;IPv4;opaque-node;_frameshift._tcp;local;frame.local;192.168.1.2;8443;"v=0" "id=paper-frame-00001" "td=/.well-known/wot" "scheme=https"\n)

  setup do
    root = "/tmp/fg-discovery-#{System.unique_integer([:positive])}"
    File.mkdir!(root)
    File.chmod!(root, 0o755)
    on_exit(fn -> File.rm_rf!(root) end)
    %{root: root}
  end

  test "protected helper executes exact arguments, resolves a bounded snapshot and discards failed/oversized output",
       %{root: root} do
    output = Path.join(root, "output")
    File.write!(output, @row)

    script =
      "#!/bin/sh\nset -eu\n[ \"$*\" = '--parsable --resolve --terminate --no-db-lookup --domain=local _frameshift._tcp' ]\ncat \"#{output}\"\n"

    browser = helper(root, script)

    assert {:ok, %{"frames" => [_], "authority" => "introduction"}} =
             Avahi.browse(browser: browser)

    code =
      "Code.prepend_paths(Path.wildcard(\"/src/_build/test/lib/*/ebin\")); IO.inspect(Frameshift.Discovery.Avahi.browse(browser: System.argv() |> hd()))"

    assert {result, 0} =
             System.cmd("runuser", ["-u", "nobody", "--", "elixir", "-e", code, "--", browser],
               stderr_to_stdout: true
             )

    assert result =~ ~s("authority" => "introduction")

    File.write!(browser, script <> "printf '%s' 'secret-path-and-raw-exception'\nexit 1\n")
    assert {:error, :discovery_unavailable} = Avahi.browse(browser: browser)
    File.write!(output, String.duplicate("x", 65_537))
    File.write!(browser, script)
    assert {:error, :discovery_unavailable} = Avahi.browse(browser: browser)

    File.chmod!(browser, 0o777)
    assert {:error, :discovery_unavailable} = Avahi.browse(browser: browser)
    File.chmod!(browser, 0o755)
    File.chown!(browser, 65_534)
    assert {:error, :discovery_unavailable} = Avahi.browse(browser: browser)
    File.chown!(browser, 0)
    link = Path.join(root, "link")
    File.ln_s!(browser, link)
    assert {:error, :discovery_unavailable} = Avahi.browse(browser: link)
    assert File.read!(browser) == script
    assert {:error, :discovery_unavailable} = Avahi.browse(browser: "/missing/browser")
    assert {:error, :discovery_unavailable} = Avahi.browse(browser: browser, deadline_ms: 5_001)
    assert {:error, :discovery_unavailable} = Avahi.browse(browser: browser, unknown: true)
  end

  test "the OS deadline kills an uncooperative helper and the collector returns no partial introduction",
       %{root: root} do
    pid_path = Path.join(root, "pid")
    output = Path.join(root, "output")
    File.write!(output, @row)

    browser =
      helper(
        root,
        "#!/bin/sh\ntrap '' TERM HUP\nprintf '%s' \"$$\" > \"#{pid_path}\"\ncat \"#{output}\"\nwhile :; do :; done\n"
      )

    started = System.monotonic_time(:millisecond)
    assert {:error, :discovery_unavailable} = Avahi.browse(browser: browser, deadline_ms: 300)
    assert System.monotonic_time(:millisecond) - started < 1_500
    pid = File.read!(pid_path)

    # PID 1 may retain a zombie in this container; it has exited and cannot run.
    status = File.read("/proc/#{pid}/status")

    assert status == {:error, :enoent} or
             (elem(status, 0) == :ok and elem(status, 1) =~ "State:\tZ")

    assert {:error, :discovery_unavailable} =
             Avahi.browse(browser: browser, timeout: "/missing/timeout")

    assert {69, "", "frameshiftctl: discovery unavailable\n"} = Frameshift.CLI.run(["discover"])
  end

  defp helper(root, bytes) do
    path = Path.join(root, "browser")
    File.write!(path, bytes)
    File.chmod!(path, 0o755)
    path
  end
end
