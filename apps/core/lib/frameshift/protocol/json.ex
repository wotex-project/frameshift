defmodule Frameshift.Protocol.JSON do
  @moduledoc """
  Decodes bounded Frame Protocol JSON before schema admission.

  `decode_control/2` applies a 64 KiB byte ceiling; `decode_thing_description/1`
  permits the separate 256 KiB TD ceiling. Both enforce nesting depth 32 before
  materializing the document. RFC 8785 decoding refuses duplicate keys, unsafe
  numeric forms and malformed UTF-8 rather than accepting ambiguous input.

  ## Schema and result boundary

  After parser admission, `Frameshift.Protocol.Schema` validates the named
  embedded schema. Results retain distinct parser/limit/schema errors so callers
  can refuse malformed wire input without dispatching it. TD/TM semantic admission
  still belongs to `Frameshift.Protocol.Thing` through Wotex.

  `encode/1` returns deterministic RFC 8785 JSON for a value; encoding alone does
  not validate a protocol schema, authenticate a peer or authorize a mutation.
  No decode path fetches external schemas or interprets document strings as code.
  """

  alias Frameshift.Protocol.Schema

  @control_limit 64 * 1024
  @thing_description_limit 256 * 1024
  @nesting_limit 32

  @type reason ::
          :body_too_large
          | :nesting_too_deep
          | :invalid_json
          | :unknown_schema
          | {:schema, term()}

  @doc "Decodes a control document within byte and nesting limits, then validates its schema."
  @spec decode_control(binary(), Schema.schema_name()) :: {:ok, term()} | {:error, reason()}
  def decode_control(json, schema_name) when is_binary(json) do
    decode(json, schema_name, @control_limit)
  end

  @doc "Decodes a larger bounded Thing Description without fetching remote schemas."
  @spec decode_thing_description(binary()) :: {:ok, term()} | {:error, reason()}
  def decode_thing_description(json) when is_binary(json) do
    decode(json, "thing-description", @thing_description_limit)
  end

  @doc "Encodes a JSON value using deterministic RFC 8785 key and number spelling."
  @spec encode(term()) :: {:ok, binary()} | {:error, term()}
  def encode(document), do: RFC8785.encode(document)

  defp decode(json, schema_name, byte_limit) do
    with :ok <- check_size(json, byte_limit),
         :ok <- check_depth(json),
         {:ok, document} <- decode_strict(json),
         :ok <- validate_schema(schema_name, document) do
      {:ok, document}
    end
  end

  defp check_size(json, limit) when byte_size(json) <= limit, do: :ok
  defp check_size(_, _), do: {:error, :body_too_large}

  defp check_depth(json) do
    case scan_depth(json, 0, false, false) do
      {:ok, _, _, _} -> :ok
      {:error, :nesting_too_deep} = error -> error
    end
  end

  defp scan_depth(<<>>, depth, in_string, escaped),
    do: {:ok, depth, in_string, escaped}

  defp scan_depth(<<_, rest::binary>>, depth, true, true),
    do: scan_depth(rest, depth, true, false)

  defp scan_depth(<<?\\, rest::binary>>, depth, true, false),
    do: scan_depth(rest, depth, true, true)

  defp scan_depth(<<?", rest::binary>>, depth, true, false),
    do: scan_depth(rest, depth, false, false)

  defp scan_depth(<<_, rest::binary>>, depth, true, false),
    do: scan_depth(rest, depth, true, false)

  defp scan_depth(<<?", rest::binary>>, depth, false, false),
    do: scan_depth(rest, depth, true, false)

  defp scan_depth(<<byte, rest::binary>>, depth, false, false) when byte in [?{, ?[] do
    next_depth = depth + 1

    if next_depth > @nesting_limit,
      do: {:error, :nesting_too_deep},
      else: scan_depth(rest, next_depth, false, false)
  end

  defp scan_depth(<<byte, rest::binary>>, depth, false, false) when byte in [?}, ?]] do
    scan_depth(rest, max(depth - 1, 0), false, false)
  end

  defp scan_depth(<<_, rest::binary>>, depth, false, false),
    do: scan_depth(rest, depth, false, false)

  defp decode_strict(json) do
    case RFC8785.decode(json) do
      {:ok, document} -> {:ok, document}
      {:error, _} -> {:error, :invalid_json}
    end
  end

  defp validate_schema(schema_name, document) do
    case Schema.validate(schema_name, document) do
      :ok -> :ok
      {:error, :unknown_schema} -> {:error, :unknown_schema}
      {:error, reason} -> {:error, {:schema, reason}}
    end
  end
end
