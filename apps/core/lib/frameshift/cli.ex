defmodule Frameshift.CLI do
  @moduledoc """
  Runs finite Linux command and observer queries through authenticated local IPC.

  The release's `bin/frameshiftctl` invokes `main/1` in a clean bundled OTP VM.
  This module does not start the host application or access SQLite. `parse/1`
  maps explicit product arguments to the existing wire contract; each mutation
  requires a caller-retained `--id`. No retry or replacement ID hides an unknown
  outcome. Pairing reads bounded physical bootstrap JSON from stdin with a finite
  deadline; only discovery/origin/reference and retained ID appear in argv.
  `discover` takes a bounded Avahi introduction snapshot without starting the
  host or reading credentials. Import awaits its streamed custody boundary.
  Physical recovery never reposts a secret.

  Catalog edits carry the observed metadata/storage revision. Metadata requires
  an explicit complete user-label set or clear flag, preserving machine labels
  unless named dismissals match the current revision. Ordered/pinned loops select
  an explicit millisecond interval or the source-backed profile recommendation;
  the core still owns target admission, clamping, rendering and display truth.

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

  alias Frameshift.{CLIInput, Digest}
  alias Frameshift.Discovery.Avahi
  alias Frameshift.LocalIPC.Client
  alias Frameshift.Pairing.Bootstrap

  @usage """
  usage: frameshiftctl diagnostics health|metrics|audit [--limit 1..100] [--cursor ID]
         frameshiftctl state|storage
         frameshiftctl metadata ID | recovery [--after ID]
         frameshiftctl instruction TEXT | select TARGET | send ITEM TARGET
         frameshiftctl reconcile TARGET | pin ID | unpin ID | remove ID | restore ID
         frameshiftctl resume TARGET REVISION
         frameshiftctl storage-set REVISION BYTES
         frameshiftctl metadata-edit ITEM REVISION TITLE --label LABEL... | --clear-user-labels
           [--dismiss filename|metadata|vision LABEL]...
         frameshiftctl loop TARGET MILLISECONDS|profile ITEM... | loop-pinned TARGET MILLISECONDS|profile
         frameshiftctl pair|recover-pair DISCOVERED_ID ORIGIN CREDENTIAL_REF
         frameshiftctl discover
  Every mutation requires --id COMMAND_ID. Configure service UID, endpoint GID and socket path.
  Pair/recover-pair reads one bounded physical bootstrap JSON from closed stdin.
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
  @spec run([String.t()], IO.device()) :: {non_neg_integer(), String.t(), String.t()}
  def run(args, input \\ :stdio)
  def run(["--help"], _), do: {0, @usage, ""}

  def run(["--version"], _) do
    Application.load(:frameshift_core)
    {0, "frameshiftctl #{Application.spec(:frameshift_core, :vsn)}\n", ""}
  end

  def run(["discover"], _) do
    case Avahi.browse() do
      {:ok, snapshot} -> {0, RFC8785.encode!(snapshot) <> "\n", ""}
      _ -> {69, "", "frameshiftctl: discovery unavailable\n"}
    end
  end

  def run(args, input) do
    with {:ok, {role, body}} <- parse(args),
         {:ok, path, policy} <- endpoint(role),
         {:ok, body} <- bootstrap_input(body, input) do
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
  @spec parse([String.t()]) ::
          {:ok, {:command | :diagnostics | :discovery, map()}} | {:error, :usage}
  def parse(args) when is_list(args) do
    if length(args) <= 270 and Enum.all?(args, &valid_argument?/1) and
         Enum.reduce(args, 0, &(byte_size(&1) + &2)) <= 64 * 1024,
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
  defp parse_args(["discover"]), do: {:ok, {:discovery, %{}}}
  defp parse_args(["storage"]), do: read("libraryStorage")
  defp parse_args(["metadata", id]), do: identified_read("libraryMetadata", "itemID", id)
  defp parse_args(["recovery"]), do: read("libraryRecovery")

  defp parse_args(["recovery", "--after", id]),
    do: identified_read("libraryRecovery", "afterID", id)

  defp parse_args([verb, discovered, origin, "linux-pem-v1:" <> hex = reference, "--id", id])
       when verb in ["pair", "recover-pair"] and byte_size(discovered) in 16..128 and
              byte_size(origin) in 1..1_024 and byte_size(id) in 1..64 and byte_size(hex) == 64 do
    with true <- Regex.match?(~r/\A[A-Za-z0-9._~-]+\z/, discovered),
         true <- Regex.match?(~r/\A[A-Za-z0-9._~-]+\z/, id),
         true <- Digest.valid_sha256?("sha256:" <> hex),
         :ok <- pairing_origin(origin) do
      operation = if verb == "pair", do: "pair", else: "recoverPair"

      {:ok,
       {:command,
        %{
          "auth" => "peer",
          "operation" => operation,
          "commandId" => id,
          "discoveredId" => discovered,
          "origin" => origin,
          "credentialRef" => reference
        }}}
    else
      _ -> {:error, :usage}
    end
  end

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

  defp pairing_origin(origin) do
    with {:ok, uri} <- URI.new(origin),
         true <- uri.scheme == "https" and is_binary(uri.host) and uri.host != "",
         true <- is_nil(uri.userinfo) and is_nil(uri.query) and is_nil(uri.fragment),
         true <- uri.path in [nil, "", "/"] and uri.port in 1..65_535 do
      :ok
    else
      _ -> {:error, :usage}
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

  defp action(["storage-set", revision, value]) do
    with true <- Digest.valid_sha256?(revision),
         {:ok, limit} <- decimal(value, 1_048_576, 1_099_511_627_776) do
      {:ok,
       %{"kind" => "updateStorage", "storageRevision" => revision, "objectByteLimit" => limit}}
    else
      _ -> {:error, :usage}
    end
  end

  defp action(["metadata-edit", item, revision, title | options]) do
    with true <- Digest.valid_sha256?(item) and Digest.valid_sha256?(revision),
         {:ok, title} <- metadata_text(title, 256),
         {:ok, edit} <- metadata_options(options, %{labels: [], dismissed: [], clear: false}),
         true <- edit.clear or edit.labels != [] do
      {:ok,
       %{
         "kind" => "updateMetadata",
         "itemID" => item,
         "metadataRevision" => revision,
         "title" => title,
         "userLabels" => Enum.reverse(edit.labels),
         "dismissedLabels" => Enum.reverse(edit.dismissed)
       }}
    else
      _ -> {:error, :usage}
    end
  end

  defp action([verb, target, interval | items])
       when verb in ["loop", "loop-pinned"] and byte_size(target) in 1..128 do
    with {:ok, dwell} <- interval(interval),
         :ok <- loop_items(verb, items) do
      command = %{
        "kind" => if(verb == "loop", do: "loopArtwork", else: "loopPinned"),
        "targetID" => target
      }

      command = if verb == "loop", do: Map.put(command, "itemIDs", items), else: command
      {:ok, if(dwell, do: Map.put(command, "dwellMs", dwell), else: command)}
    else
      _ -> {:error, :usage}
    end
  end

  defp action(_), do: {:error, :usage}

  defp decimal(value, minimum, maximum) when byte_size(value) in 1..13 do
    case Integer.parse(value) do
      {number, ""} when number >= minimum and number <= maximum ->
        if value == Integer.to_string(number), do: {:ok, number}, else: {:error, :usage}

      _ ->
        {:error, :usage}
    end
  end

  defp decimal(_, _, _), do: {:error, :usage}
  defp interval("profile"), do: {:ok, nil}
  defp interval(value), do: decimal(value, 1, 31_536_000_000)

  defp loop_items("loop-pinned", []), do: :ok

  defp loop_items("loop", items) when length(items) in 1..64 do
    if length(Enum.uniq(items)) == length(items) and Enum.all?(items, &Digest.valid_sha256?/1),
      do: :ok,
      else: {:error, :usage}
  end

  defp loop_items(_, _), do: {:error, :usage}

  defp metadata_text(text, maximum) do
    value = text |> String.normalize(:nfc) |> String.trim()

    if byte_size(value) in 1..maximum and not String.match?(value, ~r/\p{Cc}/u),
      do: {:ok, value},
      else: {:error, :usage}
  end

  defp metadata_options([], edit), do: {:ok, edit}

  defp metadata_options(["--clear-user-labels" | rest], %{clear: false, labels: []} = edit),
    do: metadata_options(rest, %{edit | clear: true})

  defp metadata_options(["--label", label | rest], %{clear: false, labels: labels} = edit)
       when length(labels) < 32 do
    with {:ok, label} <- metadata_text(label, 128) do
      metadata_options(rest, %{edit | labels: [label | labels]})
    end
  end

  defp metadata_options(["--dismiss", source, label | rest], %{dismissed: dismissed} = edit)
       when source in ~w(filename metadata vision) and length(dismissed) < 64 do
    with {:ok, label} <- metadata_text(label, 128) do
      metadata_options(rest, %{
        edit
        | dismissed: [%{"provenance" => source, "label" => label} | dismissed]
      })
    end
  end

  defp metadata_options(_, _), do: {:error, :usage}

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

  defp bootstrap_input(%{"operation" => operation} = body, input)
       when operation in ["pair", "recoverPair"] do
    with {:ok, bytes} <- CLIInput.read(input, 2_048),
         {:ok, %{device_id: id}} <- Bootstrap.parse(bytes),
         true <- id == body["discoveredId"] do
      {:ok, Map.put(body, "bootstrap", bytes)}
    else
      _ ->
        {:error, :usage}
    end
  end

  defp bootstrap_input(body, _), do: {:ok, body}

  defp response_result({:ok, %{"ok" => false, "error" => %{"code" => code}} = response})
       when code in ["command_outcome_unknown", "pairing_outcome_unknown", "pairing_incomplete"],
       do:
         {75, RFC8785.encode!(response) <> "\n",
          "frameshiftctl: uncertain outcome; retain the command ID and use explicit recovery\n"}

  defp response_result({:ok, %{"ok" => ok} = response}),
    do: {if(ok, do: 0, else: 2), RFC8785.encode!(response) <> "\n", ""}

  defp response_result({:error, :command_outcome_unknown}),
    do: {75, "", "frameshiftctl: command_outcome_unknown; reconcile using the same command ID\n"}

  defp response_result({:error, _}),
    do: {69, "", "frameshiftctl: unavailable or invalid response\n"}
end
