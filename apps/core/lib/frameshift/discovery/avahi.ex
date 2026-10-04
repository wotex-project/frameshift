defmodule Frameshift.Discovery.Avahi do
  @moduledoc """
  Takes one bounded Linux DNS-SD snapshot through the installed Avahi client.

  `browse/1` launches root-owned regular Avahi/coreutils executables with fixed
  arguments and no shell or PATH lookup. Avahi resolves only `_frameshift._tcp`
  in `local`; GNU timeout kills its process group after five seconds. The owner
  collects at most 64 KiB until a successful exit, with a six-second absolute
  deadline. Failure or overflow exposes no successful partial snapshot and no
  raw helper output. Fixture options may shorten the deadline or select equally
  protected executables; the CLI accepts none of these options from users.

  ## Introduction and lifecycle

  `parse_snapshot/1` decodes Avahi's machine format, including separate DNS label
  and quoted TXT escape rules. Duplicate/private TXT fields refuse through
  `Frameshift.Discovery.Introduction`. Added/unresolved or removed services are
  absent from results. At most 512 events and 64 active service identities are
  admitted. Invalid introductions/routes count as omitted; broken framing or
  structural/resource limits refuse the whole snapshot.

  Equivalent dual-family/interface results coalesce, preferring IPv4. Conflicting
  instance, host, port or introduction for one device ID omit that ID. Origins
  use resolved private/link-local IPv4 or ULA IPv6 literals; scoped IPv6,
  loopback, public and mapped addresses refuse. Service labels/interfaces/host
  names never enter the public result. Every returned frame is an unauthenticated
  candidate: physical bootstrap, pin and authenticated TD still own admission.

  ## Installation evidence

  This adapter requires the system Avahi/D-Bus service and packaged runtime
  dependencies. It neither starts daemons nor retries discovery. Process and
  parser fixtures do not establish supported Ubuntu installation, measured RSS,
  scoped link-local transport or independent physical-frame interoperability.
  """

  alias Frameshift.Discovery.Introduction

  @maximum_bytes 65_536
  @arguments ~w(--parsable --resolve --terminate --no-db-lookup --domain=local _frameshift._tcp)
  @type result :: {:ok, map()} | {:error, atom()}

  @doc "Runs a finite snapshot with fixed OS defaults; protected fixture options may shorten it."
  @spec browse(keyword()) :: result()
  def browse(options \\ []) do
    browser = Keyword.get(options, :browser, "/usr/bin/avahi-browse")
    timeout = Keyword.get(options, :timeout, "/usr/bin/timeout")
    deadline = Keyword.get(options, :deadline_ms, 5_000)

    with {:unix, :linux} <- :os.type(),
         true <- Keyword.keys(options) -- [:browser, :timeout, :deadline_ms] == [],
         true <- is_integer(deadline) and deadline in 1..5_000,
         :ok <- executable(browser),
         :ok <- executable(timeout),
         {:ok, bytes} <- execute(timeout, browser, deadline) do
      parse_snapshot(bytes)
    else
      _ -> {:error, :discovery_unavailable}
    end
  rescue
    _ -> {:error, :discovery_unavailable}
  catch
    _, _ -> {:error, :discovery_unavailable}
  end

  @doc "Parses one complete bounded Avahi dump without authenticating or contacting a frame."
  @spec parse_snapshot(binary()) :: result()
  def parse_snapshot(bytes) when is_binary(bytes) and byte_size(bytes) <= @maximum_bytes do
    with true <- String.valid?(bytes),
         true <- bytes == "" or String.ends_with?(bytes, "\n"),
         lines = lines(bytes),
         true <- length(lines) <= 512,
         {:ok, state} <- events(lines, %{services: %{}, omitted: 0}) do
      snapshot(state)
    else
      _ -> {:error, :invalid_discovery_snapshot}
    end
  end

  def parse_snapshot(_), do: {:error, :invalid_discovery_snapshot}

  defp lines(""), do: []
  defp lines(bytes), do: bytes |> binary_part(0, byte_size(bytes) - 1) |> String.split("\n")

  defp executable(path) when is_binary(path) and byte_size(path) in 1..4_096 do
    with true <- Path.type(path) == :absolute and not String.contains?(path, <<0>>),
         {:ok, %{type: :regular, uid: 0, mode: mode}} <- File.lstat(path),
         true <- Bitwise.band(mode, 0o022) == 0 and Bitwise.band(mode, 0o100) != 0 do
      :ok
    else
      _ -> {:error, :discovery_unavailable}
    end
  end

  defp executable(_), do: {:error, :discovery_unavailable}

  defp execute(timeout, browser, milliseconds) do
    duration =
      "#{div(milliseconds, 1_000)}.#{String.pad_leading(to_string(rem(milliseconds, 1_000)), 3, "0")}s"

    port =
      Port.open({:spawn_executable, timeout}, [
        :binary,
        :exit_status,
        :use_stdio,
        :stderr_to_stdout,
        args: ["--signal=KILL", duration, browser | @arguments],
        env: [{~c"LC_ALL", ~c"C"}, {~c"DBUS_SYSTEM_BUS_ADDRESS", false}]
      ])

    Process.unlink(port)
    monitor = :erlang.monitor(:port, port)

    try do
      collect(port, monitor, System.monotonic_time(:millisecond) + milliseconds + 1_000, [], 0)
    after
      if Port.info(port), do: Port.close(port)
      Process.demonitor(monitor, [:flush])
    end
  end

  defp collect(port, monitor, deadline, chunks, size) do
    remaining = max(0, deadline - System.monotonic_time(:millisecond))

    if remaining == 0,
      do: {:error, :discovery_unavailable},
      else: receive_output(port, monitor, deadline, chunks, size, remaining)
  end

  defp receive_output(port, monitor, deadline, chunks, size, remaining) do
    receive do
      {^port, {:data, bytes}} ->
        total = size + byte_size(bytes)
        retained = if total <= @maximum_bytes, do: [bytes | chunks], else: []
        collect(port, monitor, deadline, retained, min(total, @maximum_bytes + 1))

      {^port, {:exit_status, 0}} when size <= @maximum_bytes ->
        {:ok, chunks |> Enum.reverse() |> IO.iodata_to_binary()}

      {^port, {:exit_status, _}} ->
        {:error, :discovery_unavailable}

      {:DOWN, ^monitor, :port, ^port, _} ->
        {:error, :discovery_unavailable}
    after
      remaining -> {:error, :discovery_unavailable}
    end
  end

  defp events([], state), do: {:ok, state}

  defp events([line | rest], state) when byte_size(line) <= 4_096 do
    with {:ok, event, base, route} <- line(line),
         {:ok, state} <- event(state, event, base, route),
         true <- map_size(state.services) <= 64 do
      events(rest, state)
    else
      _ -> {:error, :invalid_discovery_snapshot}
    end
  end

  defp events(_, _), do: {:error, :invalid_discovery_snapshot}

  defp line(line) do
    case String.split(line, ";", parts: 10) do
      [event, interface, family, name, type, domain] when event in ["+", "-"] ->
        {:ok, event, [interface, family, name, type, domain], nil}

      ["=", interface, family, name, type, domain, host, address, port, txt] ->
        {:ok, "=", [interface, family, name, type, domain], [host, address, port, txt]}

      _ ->
        {:error, :invalid_discovery_snapshot}
    end
  end

  defp event(state, event, base, route) do
    case base(base) do
      {:ok, key} -> update(state, event, key, route)
      _ -> {:ok, %{state | omitted: state.omitted + 1}}
    end
  end

  defp base([interface, family, escaped, "_frameshift._tcp", "local"])
       when byte_size(interface) in 1..15 and family in ["IPv4", "IPv6"] and
              byte_size(escaped) in 1..252 do
    with true <- Regex.match?(~r/\A[A-Za-z0-9_.:-]+\z/, interface),
         {:ok, name} <- label(escaped, <<>>),
         true <- byte_size(name) in 1..63 and Regex.match?(~r/\A[A-Za-z0-9._~-]+\z/, name) do
      {:ok, {interface, family, name}}
    else
      _ -> {:error, :invalid_service}
    end
  end

  defp base(_), do: {:error, :invalid_service}

  defp label(<<>>, result), do: {:ok, result}

  defp label(<<"\\", byte, rest::binary>>, result) when byte in [?., ?\\],
    do: label(rest, result <> <<byte>>)

  defp label(<<"\\", a, b, c, rest::binary>>, result)
       when a in ?0..?2 and b in ?0..?9 and c in ?0..?9 do
    byte = (a - ?0) * 100 + (b - ?0) * 10 + c - ?0
    if byte <= 255, do: label(rest, result <> <<byte>>), else: {:error, :invalid_service}
  end

  defp label(<<byte, rest::binary>>, result) when byte != ?\\,
    do: label(rest, result <> <<byte>>)

  defp label(_, _), do: {:error, :invalid_service}

  defp update(state, "-", key, _),
    do: {:ok, %{state | services: Map.delete(state.services, key)}}

  defp update(state, "+", key, _),
    do: {:ok, %{state | services: Map.put(state.services, key, nil)}}

  defp update(state, "=", key, route) do
    case candidate(key, route) do
      {:ok, candidate} ->
        {:ok, %{state | services: Map.put(state.services, key, candidate)}}

      _ ->
        {:ok, %{state | services: Map.put(state.services, key, nil), omitted: state.omitted + 1}}
    end
  end

  defp candidate({_, family, name}, [host, address, port, txt]) do
    with {:ok, host} <- hostname(host),
         {number, ""} when number in 1..65_535 <- Integer.parse(port),
         true <- Integer.to_string(number) == port,
         {:ok, ip} <- :inet.parse_address(String.to_charlist(address)),
         true <- usable_address?(family, ip),
         {:ok, entries} <- txt(txt, []),
         {:ok, introduction} <- Introduction.parse_entries(entries) do
      literal = ip |> :inet.ntoa() |> List.to_string()
      origin = URI.to_string(%URI{scheme: "https", host: literal, port: number})
      identity = {name, host, number, introduction}
      {:ok, %{identity: identity, family: family, frame: Map.put(introduction, "origin", origin)}}
    else
      _ -> {:error, :invalid_candidate}
    end
  end

  defp hostname(host) when byte_size(host) in 1..253 do
    normalized = String.downcase(host)

    normalized =
      if String.ends_with?(normalized, "."),
        do: String.slice(normalized, 0..-2//1),
        else: normalized

    labels = String.split(normalized, ".")

    if length(labels) >= 2 and List.last(labels) == "local" and
         Enum.all?(Enum.drop(labels, -1), fn label ->
           byte_size(label) in 1..63 and
             Regex.match?(~r/\A[a-z0-9](?:[a-z0-9-]*[a-z0-9])?\z/, label)
         end),
       do: {:ok, normalized},
       else: {:error, :invalid_candidate}
  end

  defp hostname(_), do: {:error, :invalid_candidate}

  defp usable_address?("IPv4", {10, _, _, _}), do: true
  defp usable_address?("IPv4", {172, second, _, _}) when second in 16..31, do: true
  defp usable_address?("IPv4", {192, 168, _, _}), do: true
  defp usable_address?("IPv4", {169, 254, _, _}), do: true

  defp usable_address?("IPv6", {first, _, _, _, _, _, _, _})
       when Bitwise.band(first, 0xFE00) == 0xFC00,
       do: true

  defp usable_address?(_, _), do: false

  defp txt(<<>>, result), do: {:ok, Enum.reverse(result)}

  defp txt(<<"\"", rest::binary>>, result) when length(result) < 5 do
    with {:ok, entry, tail} <- quoted(rest, <<>>) do
      case tail do
        <<>> ->
          txt(<<>>, [entry | result])

        <<" ", "\"", _::binary>> ->
          txt(binary_part(tail, 1, byte_size(tail) - 1), [entry | result])

        _ ->
          {:error, :invalid_txt}
      end
    end
  end

  defp txt(_, _), do: {:error, :invalid_txt}

  defp quoted(<<"\"", rest::binary>>, entry), do: {:ok, entry, rest}

  defp quoted(<<"\\", byte, rest::binary>>, entry) when byte in [?\", ?\\],
    do: quoted(rest, entry <> <<byte>>)

  defp quoted(<<"\\", a, b, c, rest::binary>>, entry)
       when a in ?0..?2 and b in ?0..?9 and c in ?0..?9 do
    byte = (a - ?0) * 100 + (b - ?0) * 10 + c - ?0
    if byte <= 255, do: quoted(rest, entry <> <<byte>>), else: {:error, :invalid_txt}
  end

  defp quoted(<<byte, rest::binary>>, entry) when byte in 32..126 and byte != ?\\,
    do: quoted(rest, entry <> <<byte>>)

  defp quoted(_, _), do: {:error, :invalid_txt}

  defp snapshot(state) do
    grouped =
      state.services
      |> Map.values()
      |> Enum.reject(&is_nil/1)
      |> Enum.group_by(& &1.frame["deviceId"])

    {frames, ambiguous} =
      Enum.reduce(grouped, {[], 0}, fn {_, candidates}, {frames, omitted} ->
        if candidates |> Enum.map(& &1.identity) |> Enum.uniq() |> length() == 1 do
          selected = Enum.min_by(candidates, &{&1.family, &1.frame["origin"]})
          {[selected.frame | frames], omitted}
        else
          {frames, omitted + length(candidates)}
        end
      end)

    {:ok,
     %{
       "version" => 1,
       "authority" => "introduction",
       "frames" => Enum.sort_by(frames, & &1["deviceId"]),
       "omittedCount" => state.omitted + ambiguous
     }}
  end
end
