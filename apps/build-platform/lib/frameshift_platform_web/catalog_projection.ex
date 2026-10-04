defmodule FrameshiftPlatformWeb.CatalogProjection do
  @moduledoc """
  Projects public resource attributes and validates catalog page offsets.

  `public_record/2` derives allowed fields from Ash resource metadata and removes
  sensitive attributes even if marked public. It returns a plain map, excluding
  private canonical bytes, bindings and actor attribution from list responses.

  ## Pagination

  `offset/1` accepts an exact decimal binary of at most five bytes in the inclusive
  range 0–10,000. Trailing input, negative values and oversized offsets return
  `{:error, :offset}`. Both catalog controllers use this helper so anonymous
  pagination has one input contract rather than endpoint-specific coercions.
  """

  @spec public_record(module(), struct()) :: map()
  def public_record(resource, record) do
    fields =
      resource
      |> Ash.Resource.Info.public_attributes()
      |> Enum.reject(& &1.sensitive?)
      |> Enum.map(& &1.name)

    Map.take(record, fields)
  end

  @spec offset(term()) :: {:ok, non_neg_integer()} | {:error, :offset}
  def offset(raw) when is_binary(raw) and byte_size(raw) <= 5 do
    case Integer.parse(raw) do
      {value, ""} when value >= 0 and value <= 10_000 -> {:ok, value}
      _ -> {:error, :offset}
    end
  end

  def offset(_), do: {:error, :offset}
end
