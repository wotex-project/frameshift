defmodule FrameshiftBuild.ConjunctInputs do
  @moduledoc """
  Retains a complete, verified v1 closure for an explicit successor migration.

  `import/5` validates original assembly, profile, mapping and layout bytes
  through the existing v1 public codecs. It refuses missing pinned profiles
  and reconstructs the supplied compilation context before retaining all five
  identity domains. It returns immutable original bytes and verified identities;
  it neither emits a Conjunct artifact nor interprets a physical result.

  ## Limits and ownership

  Each document is at most 262144 bytes and the complete supplied closure,
  including context, is at most 4194304 bytes. Each document list has at most
  64 entries. These checks precede hashing and decoding; the existing codecs
  retain their other v1 limits and exact refusal vocabulary.

  Use `FrameshiftBuild.ConjunctAdapter.v1_inputs/5` as the public adapter entry.
  The caller supplies every byte. There is no source lookup, catalog mutation,
  worker startup or implicit successor selection. Missing/conflicting facts and
  citations remain in their exact original bytes for the subsequent mapper.
  """

  alias FrameshiftBuild.Documents

  @doc "Verifies complete original inputs and returns all five retained identity domains."
  @spec import(term(), term(), term(), term(), term()) :: {:ok, map()} | {:error, binary()}
  def import(assembly, profiles, mappings, layouts, context) do
    with :ok <- inputs(assembly, profiles, mappings, layouts, context),
         {:ok, resolution} <- FrameshiftBuild.resolve_build(assembly, profiles),
         :ok <- complete(resolution),
         {:ok, resolved} <- FrameshiftBuild.resolve_context(assembly, profiles, mappings, layouts),
         :ok <- same_context(resolved.canonical, context),
         {:ok, profile_docs} <-
           records("component-profile", profiles, &FrameshiftBuild.profile_identity/1),
         {:ok, mapping_docs} <-
           records("signal-mapping", mappings, &FrameshiftBuild.mapping_identity/1),
         {:ok, layout_docs} <-
           records("artifact-layout", layouts, &FrameshiftBuild.layout_identity/1) do
      documents =
        [
          record("assembly", resolved.assembly_identity, assembly),
          record("compilation-context", resolved.identity, context)
          | profile_docs ++ mapping_docs ++ layout_docs
        ]
        |> Enum.sort_by(&{&1["kind"], &1["identity"]})

      {:ok,
       %{
         "format" => "frameshift.conjunct.v1-inputs/1",
         "assembly_identity" => resolved.assembly_identity,
         "context_identity" => resolved.identity,
         "documents" => documents
       }}
    end
  end

  defp inputs(assembly, profiles, mappings, layouts, context)
       when is_binary(assembly) and is_binary(context) do
    with :ok <- Documents.input_types(profiles),
         :ok <- Documents.input_types(mappings),
         :ok <- Documents.input_types(layouts) do
      bytes = [assembly, context | profiles ++ mappings ++ layouts]

      if Enum.all?(bytes, &(byte_size(&1) <= 262_144)) and
           Enum.sum(Enum.map(bytes, &byte_size/1)) <= 4_194_304,
         do: :ok,
         else: {:error, "too_large"}
    end
  end

  defp inputs(_, _, _, _, _), do: {:error, "invalid_document"}

  defp complete(%{resolution: {:resolution, _, _, []}}), do: :ok
  defp complete(_), do: {:error, "missing_profile"}
  defp same_context(bytes, bytes), do: :ok
  defp same_context(_, _), do: {:error, "context_mismatch"}

  defp records(kind, bytes, identity) do
    with {:ok, pairs} <- Documents.hash(bytes, identity) do
      {:ok, Enum.map(pairs, fn {id, original} -> record(kind, id, original) end)}
    end
  end

  defp record(kind, identity, bytes),
    do: %{"kind" => kind, "identity" => identity, "bytes" => bytes}
end
