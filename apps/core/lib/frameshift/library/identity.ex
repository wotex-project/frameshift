defmodule Frameshift.Library.Identity do
  @moduledoc """
  Validates master lineage and computes canonical recipe identities.

  `validate_master/3` checks required attributes and permitted import/generation
  relationships. `validate_recipe_input/3` admits generation or composition
  parameters and correctly spelled source digests before persistence lookup.
  These checks are pure and do not confirm that referenced masters exist.

  ## Recipe bytes

  `recipe_identity/3` canonicalizes parameters with RFC 8785 and hashes the recipe
  kind, canonical bytes and ordered source digests with explicit separators.
  Changing parameters, kind or source order changes the identity. It returns the
  persistable canonical representation or a canonicalization error.

  `Frameshift.Library` resolves source existence and commits records/files under
  its single writer. Structural admission and deterministic identity are not
  source-authenticity, generation-quality or frame-compatibility assessments.
  """

  alias Frameshift.Digest

  @required_master_fields ~w(title source_kind width height media_type provenance)a

  @doc "Validates a master's attributes and its import or generation relationship."
  @spec validate_master(map(), String.t() | nil, String.t() | nil) :: :ok | {:error, term()}
  def validate_master(attributes, parent_digest, recipe_hash) when is_map(attributes) do
    with :ok <- validate_master_attributes(attributes) do
      validate_master_relationship(attributes, parent_digest, recipe_hash)
    end
  end

  def validate_master(_, _, _), do: {:error, :invalid_attributes}

  @doc "Validates recipe input before looking up source masters."
  @spec validate_recipe_input(term(), term(), term()) :: :ok | {:error, atom()}
  def validate_recipe_input(kind, parameters, source_digests)
      when kind in [:generation, :composition] and is_map(parameters) and is_list(source_digests) do
    if Enum.all?(source_digests, &Digest.valid_sha256?/1),
      do: :ok,
      else: {:error, :invalid_source_digest}
  end

  def validate_recipe_input(_, _, _), do: {:error, :invalid_recipe}

  @doc "Returns the canonical digest and persisted representation of a validated recipe."
  @spec recipe_identity(:generation | :composition, map(), [String.t()]) ::
          {:ok, String.t(), String.t(), String.t()} | {:error, {:canonicalization, term()}}
  def recipe_identity(kind, parameters, source_digests) do
    case RFC8785.encode(parameters) do
      {:ok, canonical_json} ->
        kind_string = Atom.to_string(kind)

        hash =
          Digest.sha256([
            kind_string,
            <<0>>,
            canonical_json,
            <<0>>,
            Enum.join(source_digests, <<0>>)
          ])

        {:ok, hash, kind_string, canonical_json}

      {:error, reason} ->
        {:error, {:canonicalization, reason}}
    end
  end

  defp validate_master_attributes(attributes) do
    missing = Enum.reject(@required_master_fields, &Map.has_key?(attributes, &1))

    if missing == [],
      do: validate_master_values(attributes),
      else: {:error, {:missing_fields, missing}}
  end

  defp validate_master_relationship(%{source_kind: :import}, nil, nil), do: :ok

  defp validate_master_relationship(%{source_kind: :generated}, _, recipe_hash)
       when is_binary(recipe_hash),
       do: :ok

  defp validate_master_relationship(_, _, _),
    do: {:error, :invalid_master_relationship}

  defp validate_master_values(attributes) do
    validations = [
      {attributes.source_kind in [:import, :generated], :invalid_source_kind},
      {is_integer(attributes.width) and attributes.width > 0, :invalid_width},
      {is_integer(attributes.height) and attributes.height > 0, :invalid_height},
      {is_binary(attributes.title) and String.trim(attributes.title) != "", :invalid_title},
      {is_binary(attributes.media_type), :invalid_media_type}
    ]

    case Enum.find(validations, fn {valid?, _} -> not valid? end) do
      nil -> :ok
      {_, error} -> {:error, error}
    end
  end
end
