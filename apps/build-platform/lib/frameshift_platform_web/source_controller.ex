defmodule FrameshiftPlatformWeb.SourceController do
  @moduledoc """
  Lists public source-revision metadata with bounded anonymous pagination.

  `index/2` reads 50 records per page, ordered by descending recording time and
  ascending UUID, and returns data, offset and continuation status. Records use
  `FrameshiftPlatformWeb.CatalogProjection.public_record/2` so private actor
  attribution cannot leak through generic struct serialization.

  ## Refusal and evidence scope

  Offsets must satisfy the shared 0–10,000 bound. Invalid offsets return 400;
  failed catalog reads return a finite 503 availability code. The endpoint does
  not fetch source URLs or serve document payloads. A listed digest and locator
  are recorded evidence metadata, not an authenticated manufacturer claim.
  """

  use Phoenix.Controller, formats: [:json]
  alias FrameshiftPlatform.Catalog
  alias FrameshiftPlatform.Catalog.SourceDocument
  alias FrameshiftPlatformWeb.CatalogProjection

  @spec index(Plug.Conn.t(), map()) :: Plug.Conn.t()
  def index(conn, params) do
    with {:ok, offset} <- CatalogProjection.offset(Map.get(params, "offset", "0")),
         {:ok, page} <-
           Catalog.list_sources(
             page: [limit: 50, offset: offset],
             query: [sort: [recorded_at: :desc, id: :asc]]
           ) do
      json(conn, %{
        data: Enum.map(page.results, &CatalogProjection.public_record(SourceDocument, &1)),
        more: page.more?,
        offset: offset
      })
    else
      {:error, :offset} -> conn |> put_status(400) |> json(%{error: "invalid_offset"})
      {:error, _} -> conn |> put_status(503) |> json(%{error: "catalog_unavailable"})
    end
  end
end
