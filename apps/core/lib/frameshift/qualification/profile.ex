defmodule Frameshift.Qualification.Profile do
  @moduledoc """
  Identifies the exact byte-affecting frame profile and transfer binding.

  `digest/2` selects an artifact profile by ID and canonically hashes that profile
  with its color and geometry contract. Storage availability and health are
  excluded because they can change without changing accepted artifact bytes.
  Missing or unsupported profile structure returns `:unsupported_profile`.

  ## Transfer identity

  `binding_digest/3` joins the exact admitted TD with push/pull mode and connector
  revision. Changed Forms or connector semantics therefore cannot borrow an older
  qualification merely because the profile ID matches. Hashing performs no live
  TD fetch or network interaction.

  The caller supplies already admitted capabilities and TD bytes; structural
  identity alone is not a passing conformance report or authorization to activate.
  `Frameshift.Qualification.Store` checks those references against paired custody.
  """

  alias Frameshift.Digest

  @doc "Returns the canonical digest of one selected artifact profile and its color/geometry contract."
  @spec digest(map(), String.t()) :: {:ok, String.t()} | {:error, :unsupported_profile}
  def digest(capabilities, profile_id)
      when is_map(capabilities) and is_binary(profile_id) do
    with %{
           "storage" => %{"artifactProfiles" => profiles},
           "color" => color,
           "geometry" => geometry
         } <-
           capabilities,
         true <- is_list(profiles) and is_map(color) and is_map(geometry),
         %{} = profile <- Enum.find(profiles, &(&1["id"] == profile_id)),
         {:ok, canonical} <-
           RFC8785.encode(%{
             "artifactProfile" => profile,
             "color" => color,
             "geometry" => geometry
           }) do
      {:ok, Digest.sha256(canonical)}
    else
      _ -> {:error, :unsupported_profile}
    end
  end

  def digest(_, _), do: {:error, :unsupported_profile}

  @doc "Identifies the exact admitted TD and connector revision used for one transfer mode."
  @spec binding_digest(String.t(), String.t(), String.t()) ::
          {:ok, String.t()} | {:error, :invalid_binding}
  def binding_digest(td_json, mode, connector_revision)
      when is_binary(td_json) and mode in ["push", "pull"] and
             is_binary(connector_revision) and byte_size(connector_revision) in 1..128 do
    if String.valid?(connector_revision),
      do: encode_binding(td_json, mode, connector_revision),
      else: {:error, :invalid_binding}
  end

  def binding_digest(_, _, _), do: {:error, :invalid_binding}

  defp encode_binding(td_json, mode, connector_revision) do
    case RFC8785.encode(%{
           "thingDescriptionDigest" => Digest.sha256(td_json),
           "transferMode" => mode,
           "connectorRevision" => connector_revision
         }) do
      {:ok, canonical} -> {:ok, Digest.sha256(canonical)}
      {:error, _} -> {:error, :invalid_binding}
    end
  end
end
