defmodule Frameshift.Protocol.SchemaResolver do
  @moduledoc """
  Resolves JSON Schema references from the installed protocol schema map.

  The `JSV.Resolver` callback looks up an exact `$id` among the supplied embedded
  schemas and returns the matching document. An unknown URI returns an
  `unknown_schema` error rather than fetching remote content or applying a
  different version with a similar name.

  ## Trust boundary

  `Frameshift.Protocol.Schema` supplies the compile-time schema set. Untrusted
  control documents and Thing Descriptions cannot redefine it or trigger network
  I/O through a reference. This resolver does not canonicalize documents or
  perform protocol-semantic admission; those are separate parser/consumer steps.
  """

  @behaviour JSV.Resolver

  @impl true
  def resolve(uri, schemas) when is_binary(uri) and is_map(schemas) do
    case Enum.find(Map.values(schemas), &(&1["$id"] == uri)) do
      nil -> {:error, {:unknown_schema, uri}}
      schema -> {:normal, schema}
    end
  end
end
