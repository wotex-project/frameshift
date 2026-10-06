defmodule FrameshiftRelease.RecordJSON do
  @moduledoc """
  Preserves the exact compact JSON representation of portable release records.

  `decode/2` returns objects as `{:object, ordered_pairs}` and leaves arrays as
  lists. It refuses duplicate keys, floating numeric spellings, invalid UTF-8,
  whitespace/escape rewrites and any encoding other than the complete compact
  object plus one trailing LF. The caller supplies a finite maximum up to 16 MiB.
  `encode/1` emits ordered objects without sorting or converting them to maps.

  ## Ownership and authentication

  `FrameshiftRelease.Manifest` and `FrameshiftRelease.SourceRecord` own their
  distinct field ordering, schemas, identities and semantic bounds. This helper
  performs no file I/O or authentication and is not a general JSON schema engine.
  Signatures and hashes always cover the original admitted bytes. Encoders must
  supply their owner's bounded ordered structure; parser errors return a fixed
  atom and never expose input or exception terms.
  """

  @doc "Decodes ordered objects only when their compact representation matches exactly."
  @spec decode(binary(), pos_integer()) :: {:ok, term()} | {:error, :invalid_record}
  def decode(bytes, maximum)
      when is_binary(bytes) and is_integer(maximum) and maximum in 1..16_777_216 and
             byte_size(bytes) >= 2 and byte_size(bytes) <= maximum do
    callbacks = %{
      object_start: fn _ -> {MapSet.new(), []} end,
      object_push: fn key, value, {seen, pairs} ->
        if MapSet.member?(seen, key), do: throw(:invalid_record)
        {MapSet.put(seen, key), [{key, value} | pairs]}
      end,
      object_finish: fn {_, pairs}, outer -> {{:object, Enum.reverse(pairs)}, outer} end,
      float: fn _ -> throw(:invalid_record) end
    }

    {ordered, _, _} = :json.decode(bytes, :ok, callbacks)
    if encode(ordered) == bytes, do: {:ok, ordered}, else: {:error, :invalid_record}
  rescue
    _ -> {:error, :invalid_record}
  catch
    _ -> {:error, :invalid_record}
  end

  def decode(_, _), do: {:error, :invalid_record}

  @doc "Emits the owner's ordered structure as compact JSON with exactly one LF."
  @spec encode(term()) :: binary()
  def encode(value) do
    encoder = fn
      {:object, pairs}, recurse -> :json.encode_key_value_list(pairs, recurse)
      other, recurse -> :json.encode_value(other, recurse)
    end

    IO.iodata_to_binary(:json.encode(value, encoder)) <> "\n"
  end
end
