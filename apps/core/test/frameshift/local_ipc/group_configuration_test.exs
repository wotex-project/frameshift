defmodule Frameshift.LocalIPC.GroupConfigurationTest do
  @moduledoc false

  use ExUnit.Case, async: false

  alias Frameshift.LocalIPC.SocketDirectory

  setup do
    for key <- [:start_local_ipc, :start_library, :start_renderer] do
      previous = Application.fetch_env(:frameshift_core, key)
      Application.put_env(:frameshift_core, key, key == :start_local_ipc)

      on_exit(fn ->
        case previous do
          {:ok, value} -> Application.put_env(:frameshift_core, key, value)
          :error -> Application.delete_env(:frameshift_core, key)
        end
      end)
    end

    for key <-
          ~w(FRAMESHIFT_CONTROL_GID FRAMESHIFT_CREDENTIAL_SOCKET FRAMESHIFT_DIAGNOSTICS_GID FRAMESHIFT_DIAGNOSTICS_SOCKET_PATH FRAMESHIFT_SOCKET_PATH FRAMESHIFT_IPC_TOKEN_FILE) do
      previous = System.get_env(key)

      on_exit(fn ->
        if previous, do: System.put_env(key, previous), else: System.delete_env(key)
      end)

      System.delete_env(key)
    end

    :ok
  end

  test "control access cannot silently use a missing observer policy or private bootstrap token" do
    token_path = "/tmp/fs-control-config-#{System.unique_integer([:positive])}"
    File.write!(token_path, "unchanged control bootstrap")
    on_exit(fn -> File.rm(token_path) end)
    System.put_env("FRAMESHIFT_IPC_TOKEN_FILE", token_path)
    System.delete_env("FRAMESHIFT_DIAGNOSTICS_GID")

    for gid <- ["50", "", "0", "050", "-1", "4294967295"] do
      System.put_env("FRAMESHIFT_CONTROL_GID", gid)

      assert_raise RuntimeError,
                   "Linux control group requires distinct observer access and no token broker",
                   fn -> Frameshift.Application.start(:normal, []) end

      assert File.read!(token_path) == "unchanged control bootstrap"
    end
  end

  test "invalid or unsupported group configuration refuses before consuming bootstrap credentials" do
    token_path = "/tmp/fs-group-config-#{System.unique_integer([:positive])}"
    File.write!(token_path, "unchanged bootstrap input")
    on_exit(fn -> File.rm(token_path) end)
    System.put_env("FRAMESHIFT_IPC_TOKEN_FILE", token_path)
    System.put_env("FRAMESHIFT_SOCKET_PATH", token_path <> "/command/c.sock")
    System.put_env("FRAMESHIFT_DIAGNOSTICS_SOCKET_PATH", token_path <> "/observer/d.sock")

    for gid <- ["", "0", "-1", "+50", "050", "50junk", "4294967295"] do
      System.put_env("FRAMESHIFT_DIAGNOSTICS_GID", gid)

      assert_raise RuntimeError,
                   "Linux diagnostics group requires a valid GID and separate socket directory",
                   fn -> Frameshift.Application.start(:normal, []) end

      assert File.read!(token_path) == "unchanged bootstrap input"
    end

    System.put_env("FRAMESHIFT_DIAGNOSTICS_GID", "50")
    System.put_env("FRAMESHIFT_DIAGNOSTICS_SOCKET_PATH", token_path <> "/command/d.sock")

    assert_raise RuntimeError,
                 "Linux diagnostics group requires a valid GID and separate socket directory",
                 fn -> Frameshift.Application.start(:normal, []) end

    assert File.read!(token_path) == "unchanged bootstrap input"
  end

  test "group policy does not admit a non-Linux socket or an invalid Linux GID" do
    path = "/tmp/fs-no-group-#{System.unique_integer([:positive])}/d.sock"

    if :os.type() == {:unix, :linux} do
      assert {:error, :invalid_socket_group} = SocketDirectory.prepare_group(path, 0)
    else
      assert {:error, :unsupported_group_socket} = SocketDirectory.prepare_group(path, 50)
    end

    assert {:error, :enoent} = File.lstat(Path.dirname(path))
  end
end
