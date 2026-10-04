defmodule FrameshiftPlatform.Catalog.BindProfileSources do
  @moduledoc """
  Binds canonical profile citations to exact stored source revisions.

  This Ash change installs a before-action hook after
  `FrameshiftPlatform.Catalog.PrepareProfile` has supplied validated citations.
  It resolves each digest/revision pair in bounded batches and checks that the
  stored evidence kind matches the citation. Repeated citations reuse the same
  resolved source record.

  ## Refusal and custody

  Missing revisions, kind mismatches or failed lookups add
  `unresolved_source_revision` on `:canonical` and prevent insertion. Successful
  bindings include the stored source UUID; caller input cannot choose that field.
  Resolution uses immutable catalog metadata and performs no network fetch or
  source-authenticity assessment.
  """

  use Ash.Resource.Change
  alias FrameshiftPlatform.Catalog

  @impl true
  def change(changeset, _, _) do
    Ash.Changeset.before_action(changeset, &bind/1)
  end

  defp bind(changeset) do
    citations = Map.get(changeset.context, :profile_citations, [])

    with {:ok, sources} <- resolve(citations),
         true <- Enum.all?(citations, &matching_source?(&1, sources)) do
      bindings =
        Enum.map(citations, &Map.put(&1, "source_document_id", sources[source_key(&1)].id))

      Ash.Changeset.force_change_attribute(changeset, :source_bindings, bindings)
    else
      _ ->
        Ash.Changeset.add_error(changeset,
          field: :canonical,
          message: "unresolved_source_revision"
        )
    end
  end

  defp resolve(citations) do
    citations
    |> Enum.map(&source_key/1)
    |> Enum.uniq()
    |> Enum.chunk_every(100)
    |> Enum.reduce_while({:ok, %{}}, &resolve_batch/2)
  end

  defp resolve_batch(keys, {:ok, sources}) do
    filter =
      Enum.map(keys, fn {digest, revision} -> %{content_sha256: digest, revision: revision} end)

    case Catalog.list_sources(query: [filter: [or: filter]], page: [limit: 100]) do
      {:ok, page} ->
        resolved = Map.new(page.results, &{{&1.content_sha256, &1.revision}, &1})
        {:cont, {:ok, Map.merge(sources, resolved)}}

      {:error, error} ->
        {:halt, {:error, error}}
    end
  end

  defp matching_source?(citation, sources) do
    case Map.get(sources, source_key(citation)) do
      nil -> false
      source -> Atom.to_string(source.kind) == citation["evidence"]
    end
  end

  defp source_key(citation), do: {citation["digest"], citation["revision"]}
end
