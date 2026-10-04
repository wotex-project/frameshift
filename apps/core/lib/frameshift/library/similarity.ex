defmodule Frameshift.Library.Similarity do
  @moduledoc """
  Reads bounded native feature-print candidates under the serialized Library owner.

  `page/2` accepts an active source master, exact saved feature digest/cohort,
  optional exclusive digest cursor and source/pin/frame facets. Each page checks
  the source again, excludes it and removed masters, and returns at most sixteen
  verified archives in digest order. Frame membership follows retained master or
  artifact-recipe references, never physically displayed artwork.

  ## Native comparison and read custody

  Swift owns secure archive decoding, ranking, scan deadlines and the result
  ceiling. This module creates no receipts, render jobs, labels, audit writes or
  frame intent. Corrupt candidate bytes refuse the page; invalid facets/cursors,
  unknown paired frames and changed source identity return finite errors.

  Only `Frameshift.Library` supplies its SQLite connection. Cursors are ordering
  boundaries, not snapshots or authorization tokens; concurrent candidate changes
  can affect later pages. `Frameshift.Library.Metadata` owns the archive bounds
  and byte verification. Similarity never grants profile or physical authority.
  """

  alias Frameshift.Digest
  alias Frameshift.Library.Metadata

  @doc "Projects sixteen verified candidates after an exclusive digest cursor."
  @spec page(pid(), map()) :: {:ok, map()} | {:error, atom()}
  def page(connection, request) do
    with :ok <- validate_source(request),
         :ok <- validate_filters(request["filters"]),
         :ok <- paired_filter(connection, request["filters"]["frameID"]),
         {:ok, source} <- Metadata.analysis(connection, request["itemID"]),
         true <-
           source["cohort"] == request["cohort"] and
             source["featurePrint"]["digest"] == request["featureDigest"],
         rows = candidates(connection, request),
         {:ok, items} <- project(connection, Enum.take(rows, 16)) do
      {:ok,
       %{
         "itemID" => request["itemID"],
         "cohort" => source["cohort"],
         "featureDigest" => source["featurePrint"]["digest"],
         "items" => items,
         "nextCursor" => if(length(rows) > 16, do: List.last(items)["item"]["id"])
       }}
    else
      false -> {:error, :analysis_changed}
      error -> error
    end
  rescue
    _ in Exqlite.Error -> {:error, :analysis_unavailable}
  end

  defp validate_source(request) do
    if Digest.valid_sha256?(request["itemID"]) and Digest.valid_sha256?(request["featureDigest"]) and
         Metadata.vision_cohort?(request["cohort"]) and
         (request["afterID"] == nil or Digest.valid_sha256?(request["afterID"])),
       do: :ok,
       else: {:error, :invalid_request}
  end

  defp validate_filters(filters) when is_map(filters) do
    if Enum.all?(Map.keys(filters), &(&1 in ~w(pinnedOnly sourceKind frameID))) and
         is_boolean(Map.get(filters, "pinnedOnly", false)) and
         filters["sourceKind"] in [nil, "import", "generated"] and
         valid_frame?(filters["frameID"]), do: :ok, else: {:error, :invalid_request}
  end

  defp validate_filters(_), do: {:error, :invalid_request}
  defp valid_frame?(nil), do: true
  defp valid_frame?(frame) when is_binary(frame), do: byte_size(frame) in 1..128
  defp valid_frame?(_), do: false
  defp paired_filter(_, nil), do: :ok

  defp paired_filter(connection, frame) do
    case Exqlite.query!(connection, "SELECT frame_id FROM paired_frames WHERE frame_id = ?", [
           frame
         ]).rows do
      [[^frame]] -> :ok
      _ -> {:error, :invalid_request}
    end
  end

  defp candidates(connection, request) do
    filters = request["filters"]

    Exqlite.query!(
      connection,
      """
      SELECT m.digest, m.title, (p.object_digest IS NOT NULL) FROM masters m
      JOIN master_analysis a ON a.master_digest = m.digest
      LEFT JOIN pins p ON p.object_digest = m.digest
      WHERE m.removed_at_ms IS NULL AND m.digest != ? AND a.cohort = ?
        AND (? IS NULL OR m.digest > ?)
        AND (? = 0 OR p.object_digest IS NOT NULL)
        AND (? IS NULL OR m.source_kind = ?)
        AND (? IS NULL OR EXISTS (
          SELECT 1 FROM frame_asset_refs refs WHERE refs.frame_id = ? AND (
            refs.object_digest = m.digest OR EXISTS (
              SELECT 1 FROM artifact_recipe_links links
              WHERE links.master_digest = m.digest AND links.artifact_digest = refs.object_digest
            )
          )
        ))
      ORDER BY m.digest LIMIT 17
      """,
      [
        request["itemID"],
        request["cohort"],
        request["afterID"],
        request["afterID"],
        if(Map.get(filters, "pinnedOnly", false), do: 1, else: 0),
        filters["sourceKind"],
        filters["sourceKind"],
        filters["frameID"],
        filters["frameID"]
      ]
    ).rows
  end

  defp project(connection, rows) do
    Enum.reduce_while(rows, {:ok, []}, fn [digest, title, pinned], {:ok, items} ->
      case Metadata.analysis(connection, digest) do
        {:ok, analysis} ->
          item = %{
            "item" => %{
              "id" => digest,
              "digest" => digest,
              "title" => title,
              "isPinned" => pinned == 1
            },
            "featurePrint" => analysis["featurePrint"]
          }

          {:cont, {:ok, [item | items]}}

        error ->
          {:halt, error}
      end
    end)
    |> case do
      {:ok, items} -> {:ok, Enum.reverse(items)}
      error -> error
    end
  end
end
