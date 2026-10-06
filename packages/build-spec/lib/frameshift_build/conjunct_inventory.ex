defmodule FrameshiftBuild.ConjunctInventory do
  @moduledoc """
  Independently inventories every JSON node in a complete retained v1 closure.

  `import/5` first verifies original inputs through
  `FrameshiftBuild.ConjunctInputs.import/5`. It then enumerates each document's
  root, members and array elements, retaining exact scalar values and container
  structure. The source inventory binds the verified compilation context and
  identifies its limited JSON-node coverage scope for later mapping validation.

  ## Ownership and failures

  This is source syntax custody, not a physical converter or an admitting
  consumer. It emits no Conjunct successor, chooses no source interpretation
  and starts no worker or I/O. Original citations and missing/conflicting facts
  remain in the full retained input and in their exact node descriptors.

  Earlier v1 refusals pass through unchanged. More than 10000 nodes returns
  `too_many_concepts` without a partial inventory. The caller preserves the
  refused original and supplies a complete corrected closure to recover.
  Use `FrameshiftBuild.ConjunctAdapter.v1_inventory/5` as the public entry.
  """

  alias FrameshiftBuild.ConjunctInputs

  @doc "Verifies original inputs and returns the complete bounded JSON-node inventory."
  @spec import(term(), term(), term(), term(), term()) :: {:ok, map()} | {:error, binary()}
  def import(assembly, profiles, mappings, layouts, context) do
    with {:ok, inputs} <- ConjunctInputs.import(assembly, profiles, mappings, layouts, context),
         {:ok, nodes} <- nodes(inputs["documents"]) do
      inventory = %{
        "artifact" => %{
          "reference" => inputs["context_identity"],
          "format" => "frameshift.compilation",
          "version" => "1"
        },
        "coverage_scope" => "frameshift/v1-closure-json-nodes/1",
        "complete" => true,
        "concepts" => Enum.map(nodes, &concept/1)
      }

      {:ok,
       %{
         "format" => "frameshift.conjunct.v1-inventory/1",
         "inputs" => inputs,
         "inventory" => inventory,
         "nodes" => nodes
       }}
    end
  end

  defp nodes(documents) do
    documents
    |> Enum.reduce_while({:ok, {[], 0}}, fn document, {:ok, state} ->
      case walk(JSON.decode!(document["bytes"]), "", document, state) do
        {:ok, next} -> {:cont, {:ok, next}}
        refusal -> {:halt, refusal}
      end
    end)
    |> case do
      {:ok, {nodes, _}} -> {:ok, Enum.sort_by(nodes, & &1["id"])}
      refusal -> refusal
    end
  end

  defp walk(_, _, _, {_, 10_000}), do: {:error, "too_many_concepts"}

  defp walk(value, pointer, document, {nodes, count}) do
    {descriptor, children} = describe(value)
    id = document["kind"] <> "@" <> document["identity"] <> "#" <> pointer

    node = %{
      "id" => id,
      "document_kind" => document["kind"],
      "document_identity" => document["identity"],
      "pointer" => pointer,
      "value" => descriptor
    }

    Enum.reduce_while(children, {:ok, {[node | nodes], count + 1}}, fn {key, child},
                                                                       {:ok, state} ->
      case walk(child, pointer <> "/" <> token(key), document, state) do
        {:ok, next} -> {:cont, {:ok, next}}
        refusal -> {:halt, refusal}
      end
    end)
  end

  defp describe(value) when is_map(value) do
    keys = value |> Map.keys() |> Enum.sort()
    {%{"type" => "object", "keys" => keys}, Enum.map(keys, &{&1, Map.fetch!(value, &1)})}
  end

  defp describe(value) when is_list(value),
    do: {%{"type" => "array", "length" => length(value)}, Enum.with_index(value, &{&2, &1})}

  defp describe(nil), do: {%{"type" => "null"}, []}
  defp describe(value) when is_binary(value), do: {%{"type" => "string", "value" => value}, []}
  defp describe(value) when is_integer(value), do: {%{"type" => "integer", "value" => value}, []}
  defp describe(value) when is_boolean(value), do: {%{"type" => "boolean", "value" => value}, []}

  defp token(key),
    do: key |> to_string() |> String.replace("~", "~0") |> String.replace("/", "~1")

  defp concept(node),
    do: %{"id" => node["id"], "locator" => node["id"], "requirements" => ["CJ1-07", "CJ3-11"]}
end
