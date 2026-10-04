defmodule Frameshift.Discovery.Introduction do
  @moduledoc """
  Admits the privacy-limited reference HTTPS DNS-SD introduction.

  `parse_txt/1` accepts the original length-prefixed TXT bytes; `parse_entries/1`
  accepts decoded entries from an OS discovery adapter. Both preserve duplicate
  keys until refusal and enforce the same 512-byte wire ceiling. Exactly `v`,
  `id`, `td` and `scheme` are required, with optional `pair`. Extra metadata,
  unknown versions/routes, non-ASCII device identities and malformed framing
  refuse rather than becoming a more permissive frame profile.

  ## Candidate authority

  A result contains only `deviceId`, `thingPath` and the boolean `pairMode` hint.
  It establishes neither device custody nor compatibility. Pairing separately
  matches the physical bootstrap, pins TLS and admits an authenticated TD.
  No owner, artwork, network credential or private TD belongs in these fields.
  """

  @type result :: {:ok, map()} | {:error, :invalid_introduction}

  @doc "Parses one bounded TXT wire record, preserving every entry until validation."
  @spec parse_txt(binary()) :: result()
  def parse_txt(bytes) when is_binary(bytes) and byte_size(bytes) in 1..512 do
    with {:ok, entries} <- entries(bytes, []), do: parse_entries(entries)
  end

  def parse_txt(_), do: {:error, :invalid_introduction}

  @doc "Admits decoded TXT entries with exact reference keys and original wire-size accounting."
  @spec parse_entries([binary()]) :: result()
  def parse_entries(entries) when is_list(entries) and length(entries) in 4..5 do
    with true <- Enum.all?(entries, &(is_binary(&1) and byte_size(&1) in 1..255)),
         true <- Enum.reduce(entries, 0, &(1 + byte_size(&1) + &2)) <= 512,
         {:ok, fields} <- fields(entries, %{}),
         %{"v" => "0", "id" => id, "td" => "/.well-known/wot", "scheme" => "https"} <- fields,
         true <- byte_size(id) in 16..128 and Regex.match?(~r/\A[A-Za-z0-9._~-]+\z/, id),
         true <- Map.get(fields, "pair") in [nil, "0", "1"] do
      {:ok,
       %{"deviceId" => id, "thingPath" => "/.well-known/wot", "pairMode" => fields["pair"] == "1"}}
    else
      _ -> {:error, :invalid_introduction}
    end
  end

  def parse_entries(_), do: {:error, :invalid_introduction}

  defp entries(<<>>, result), do: {:ok, Enum.reverse(result)}

  defp entries(<<length, rest::binary>>, result) when length > 0 and byte_size(rest) >= length do
    <<entry::binary-size(^length), tail::binary>> = rest
    entries(tail, [entry | result])
  end

  defp entries(_, _), do: {:error, :invalid_introduction}

  defp fields([], result), do: {:ok, result}

  defp fields([entry | rest], result) do
    case :binary.split(entry, "=") do
      [key, value] when key in ~w(v id td scheme pair) ->
        if Map.has_key?(result, key),
          do: {:error, :invalid_introduction},
          else: fields(rest, Map.put(result, key, value))

      _ ->
        {:error, :invalid_introduction}
    end
  end
end
