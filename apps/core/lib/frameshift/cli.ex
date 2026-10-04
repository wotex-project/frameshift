defmodule Frameshift.CLI do
  @moduledoc """
  Runs finite Linux command and observer queries through authenticated local IPC.

  The release's `bin/frameshiftctl` invokes `main/1` in a clean bundled OTP VM.
  This module does not start the host application or access SQLite. `parse/1`
  maps explicit product arguments to the existing wire contract; each mutation
  requires a caller-retained `--id`. No retry or replacement ID hides an unknown
  outcome. Import and pairing await their platform-specific custody boundaries.

  ## Policy and output

  `run/1` reads the configured service UID, selected endpoint GID and socket path.
  The service must be nonroot and IDs canonical bounded decimals. The IPC client
  verifies final inode custody and actual kernel server identity before sending.
  Environment policy is installed/operator input, never server-supplied identity.

  Validated envelopes are canonical JSON on stdout. Finite stderr messages omit
  raw exceptions, credentials and paths. Status 2 denotes a domain refusal, 64
  usage/policy errors, 69 unavailable reads or pre-send admission, and 75 an
  unknown mutation outcome. Help/version need no service or credential access.
  """

  alias Frameshift.Digest
  alias Frameshift.LocalIPC.Client

  @usage """
  usage: frameshiftctl diagnostics health|metrics|audit [--limit 1..100] [--cursor ID]
         frameshiftctl state|storage
         frameshiftctl metadata ID | recovery [--after ID]
         frameshiftctl instruction TEXT | select TARGET | send ITEM TARGET
         frameshiftctl reconcile TARGET | pin ID | unpin ID | remove ID | restore ID
         frameshiftctl resume TARGET REVISION
  Every mutation requires --id COMMAND_ID. Configure service UID, endpoint GID and socket path.
  """

  @doc "Prints a finite CLI result and exits with its status without starting the application."
  @spec main([String.t()]) :: no_return()
  def main(args) do
    {status, output, error} = run(args)
    IO.write(output)
    IO.write(:stderr, error)
    System.halt(status)
  end

  @doc "Runs one command, returning status, stdout and stderr for launchers and joined fixtures."
  @spec run([String.t()]) :: {non_neg_integer(), String.t(), String.t()}
  def run(["--help"]), do: {0, @usage, ""}

  def run(["--version"]) do
    Application.load(:frameshift_core)
    {0, "frameshiftctl #{Application.spec(:frameshift_core, :vsn)}\n", ""}
  end

  def run(args) do
    with {:ok, {role, body}} <- parse(args),
         {:ok, path, policy} <- endpoint(role) do
      request =
        Map.merge(body, %{
          "version" => 1,
          "requestId" => Base.encode16(:crypto.strong_rand_bytes(16), case: :lower)
        })

      response_result(Client.exchange(path, request, role, policy))
    else
      _ -> {64, "", @usage}
    end
  rescue
    _ -> {69, "", "frameshiftctl: unavailable or invalid response\n"}
  catch
    _, _ -> {69, "", "frameshiftctl: unavailable or invalid response\n"}
  end

  @doc "Admits exact CLI arguments without opening a socket or allocating a command identity."
  @spec parse([String.t()]) :: {:ok, {:command | :diagnostics, map()}} | {:error, :usage}
  def parse(args) when is_list(args) do
    if length(args) <= 16 and Enum.all?(args, &valid_argument?/1),
      do: parse_args(args),
      else: {:error, :usage}
  end

  def parse(_), do: {:error, :usage}

  defp valid_argument?(value) when is_binary(value) and byte_size(value) <= 8_192,
    do: String.valid?(value) and not String.contains?(value, <<0>>)

  defp valid_argument?(_), do: false

  defp parse_args(["diagnostics", operation | rest]) when operation in ~w(health metrics audit) do
    with {:ok, paging} <- paging(rest, %{}),
         true <- operation != "health" or paging == %{} do
      {:ok, {:diagnostics, Map.put(paging, "operation", operation)}}
    else
      _ -> {:error, :usage}
    end
  end

  defp parse_args(["state"]), do: read("snapshot")
  defp parse_args(["storage"]), do: read("libraryStorage")
  defp parse_args(["metadata", id]), do: identified_read("libraryMetadata", "itemID", id)
  defp parse_args(["recovery"]), do: read("libraryRecovery")

  defp parse_args(["recovery", "--after", id]),
    do: identified_read("libraryRecovery", "afterID", id)

  defp parse_args(args) do
    case Enum.split(args, -2) do
      {action, ["--id", id]} when is_binary(id) and byte_size(id) in 1..64 ->
        with true <- String.valid?(id) and not String.contains?(id, <<0>>),
             {:ok, command} <- action(action) do
          {:ok,
           {:command,
            %{"operation" => "command", "auth" => "peer", "command" => Map.put(command, "id", id)}}}
        else
          _ -> {:error, :usage}
        end

      _ ->
        {:error, :usage}
    end
  end

  defp action(["instruction", text]) when byte_size(text) <= 4_096,
    do: {:ok, %{"kind" => "updateInstruction", "instruction" => text}}

  defp action([verb, id]) when verb in ~w(pin unpin remove restore) do
    with true <- Digest.valid_sha256?(id) do
      command =
        if verb in ~w(pin unpin),
          do: %{"kind" => "setPinned", "itemID" => id, "isPinned" => verb == "pin"},
          else: %{"kind" => verb, "itemID" => id}

      {:ok, command}
    else
      _ -> {:error, :usage}
    end
  end

  defp action([verb, target]) when verb in ~w(select reconcile) and byte_size(target) in 1..128 do
    kind = if verb == "select", do: "selectTarget", else: "reconcileDelivery"
    {:ok, %{"kind" => kind, "targetID" => target}}
  end

  defp action(["send", item, target]) when byte_size(target) in 1..128 do
    if Digest.valid_sha256?(item),
      do: {:ok, %{"kind" => "queue", "itemID" => item, "targetID" => target}},
      else: {:error, :usage}
  end

  defp action(["resume", target, revision]) when byte_size(target) in 1..128 do
    if Digest.valid_sha256?(revision),
      do:
        {:ok, %{"kind" => "resumePlaylist", "targetID" => target, "playlistRevision" => revision}},
      else: {:error, :usage}
  end

  defp action(_), do: {:error, :usage}

  defp read(operation), do: {:ok, {:command, %{"operation" => operation, "auth" => "peer"}}}

  defp identified_read(operation, key, id) do
    if Digest.valid_sha256?(id) do
      {:ok, {role, body}} = read(operation)
      {:ok, {role, Map.put(body, key, id)}}
    else
      {:error, :usage}
    end
  end

  defp paging([], options), do: {:ok, options}

  defp paging([flag, value | rest], options)
       when flag in ["--limit", "--cursor"] and byte_size(value) in 1..16 do
    key = if flag == "--limit", do: "limit", else: "cursor"

    with false <- Map.has_key?(options, key),
         {number, ""} <- Integer.parse(value),
         true <- number >= 0 and value == Integer.to_string(number),
         true <- key == "cursor" or number in 1..100,
         true <- number <= 9_007_199_254_740_991 do
      paging(rest, Map.put(options, key, number))
    else
      _ -> {:error, :usage}
    end
  end

  defp paging(_, _), do: {:error, :usage}

  defp endpoint(role) do
    {group_name, path_name, default_path} =
      if role == :diagnostics,
        do:
          {"FRAMESHIFT_DIAGNOSTICS_GID", "FRAMESHIFT_DIAGNOSTICS_SOCKET_PATH",
           "/run/frameshift/observer/d.sock"},
        else:
          {"FRAMESHIFT_CONTROL_GID", "FRAMESHIFT_SOCKET_PATH", "/run/frameshift/control/c.sock"}

    with {:ok, uid} <- configured_id("FRAMESHIFT_SERVICE_UID"),
         {:ok, gid} <- configured_id(group_name) do
      {:ok, System.get_env(path_name) || default_path, [uid: uid, gid: gid]}
    end
  end

  defp configured_id(name) do
    with value when is_binary(value) and byte_size(value) in 1..10 <- System.get_env(name),
         {id, ""} <- Integer.parse(value),
         true <- id in 1..4_294_967_294 and value == Integer.to_string(id) do
      {:ok, id}
    else
      _ -> {:error, :usage}
    end
  end

  defp response_result({:ok, %{"ok" => ok} = response}),
    do: {if(ok, do: 0, else: 2), RFC8785.encode!(response) <> "\n", ""}

  defp response_result({:error, :command_outcome_unknown}),
    do: {75, "", "frameshiftctl: command_outcome_unknown; reconcile using the same command ID\n"}

  defp response_result({:error, _}),
    do: {69, "", "frameshiftctl: unavailable or invalid response\n"}
end
