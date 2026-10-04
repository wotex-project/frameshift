defmodule Frameshift.Qualification.Identity do
  @moduledoc """
  Builds canonical identities for bindings, accepted work and rendered results.

  `binding/1` validates closed, bounded fields tying one frame/profile to the
  renderer build and transfer contract. `work/3` adds immutable master/recipe
  references to that binding. `result/4` records the rendered artifact, byte count
  and media type against frozen work; the output artifact is not a work input.

  ## Canonical custody

  Artifacts use exact schema versions, validated SHA-256 references and RFC 8785
  canonical bytes. Unknown fields, unsupported values and malformed references
  refuse rather than being dropped before hashing. `software_evidence/1` validates
  a bounded suite/scope/outcome record before local admission.

  These functions establish deterministic identity and structural evidence shape.
  They neither activate a binding nor execute a render/transfer. Persistence and
  current selection belong to `Frameshift.Qualification.Store`; accepted-work
  immutability belongs to `Frameshift.Qualification.WorkStore` under the library.
  """

  alias Frameshift.Digest

  @binding_keys ~w(
    bindingDigest connectorRevision effectClass frameId profileDigest profileId
    rendererAlgorithmRevision rendererBuildDigest rendererProtocolRevision
    schemaVersion thingDescriptionDigest transferMode
  )
  @work_keys ~w(bindingDigest masterDigest recipeDigest schemaVersion)
  @result_keys ~w(artifactDigest byteCount mediaType schemaVersion workDigest)
  @evidence_keys ~w(outcome schemaVersion scope suiteDigest)

  @type identity :: %{digest: String.t(), canonical_json: String.t(), document: map()}

  @doc "Builds the canonical digest of an exact reusable render/transfer binding."
  @spec binding(map()) :: {:ok, identity()} | {:error, atom()}
  def binding(document) when is_map(document) do
    with :ok <- exact_keys(document, @binding_keys),
         :ok <- version(document),
         :ok <- bounded(document["frameId"], 128),
         :ok <- bounded(document["profileId"], 256),
         :ok <-
           digest_fields(
             document,
             ~w(thingDescriptionDigest profileDigest rendererBuildDigest bindingDigest)
           ),
         :ok <-
           bounded_fields(
             document,
             ~w(connectorRevision rendererAlgorithmRevision rendererProtocolRevision),
             128
           ),
         :ok <- transfer_mode(document["transferMode"]),
         :ok <- effect_class(document["effectClass"]) do
      canonical_identity(document)
    end
  end

  def binding(_), do: {:error, :invalid_qualification}

  @doc "Binds an admitted qualification to one master and composition recipe."
  @spec work(String.t(), String.t(), String.t()) :: {:ok, identity()} | {:error, atom()}
  def work(binding_digest, master_digest, recipe_digest) do
    document = %{
      "schemaVersion" => 1,
      "bindingDigest" => binding_digest,
      "masterDigest" => master_digest,
      "recipeDigest" => recipe_digest
    }

    with :ok <- exact_keys(document, @work_keys),
         :ok <- digest_fields(document, ~w(bindingDigest masterDigest recipeDigest)) do
      canonical_identity(document)
    end
  end

  @doc "Records exact rendered bytes against one frozen work identity."
  @spec result(String.t(), String.t(), non_neg_integer(), String.t()) ::
          {:ok, identity()} | {:error, atom()}
  def result(work_digest, artifact_digest, byte_count, media_type) do
    document = %{
      "schemaVersion" => 1,
      "workDigest" => work_digest,
      "artifactDigest" => artifact_digest,
      "byteCount" => byte_count,
      "mediaType" => media_type
    }

    with :ok <- exact_keys(document, @result_keys),
         :ok <- digest_fields(document, ~w(workDigest artifactDigest)),
         true <- is_integer(byte_count) and byte_count >= 0,
         :ok <- bounded(media_type, 128) do
      canonical_identity(document)
    else
      false -> {:error, :invalid_qualification}
      error -> error
    end
  end

  @doc "Validates a bounded software conformance record before local admission."
  @spec software_evidence(map()) :: {:ok, String.t()} | {:error, atom()}
  def software_evidence(document) when is_map(document) do
    with :ok <- exact_keys(document, @evidence_keys),
         :ok <- version(document),
         true <- document["scope"] == "software_reference",
         true <- document["outcome"] == "passed",
         true <- Digest.valid_sha256?(document["suiteDigest"]),
         {:ok, canonical} <- RFC8785.encode(document) do
      {:ok, canonical}
    else
      _ -> {:error, :invalid_qualification_evidence}
    end
  end

  def software_evidence(_), do: {:error, :invalid_qualification_evidence}

  defp exact_keys(document, keys) do
    if Enum.sort(Map.keys(document)) == keys,
      do: :ok,
      else: {:error, :invalid_qualification}
  end

  defp version(%{"schemaVersion" => 1}), do: :ok
  defp version(_), do: {:error, :unsupported_qualification_version}

  defp bounded(value, maximum)
       when is_binary(value) and byte_size(value) > 0 and byte_size(value) <= maximum do
    if String.valid?(value), do: :ok, else: {:error, :invalid_qualification}
  end

  defp bounded(_, _), do: {:error, :invalid_qualification}

  defp bounded_fields(document, keys, maximum) do
    Enum.reduce_while(keys, :ok, fn key, :ok ->
      case bounded(document[key], maximum) do
        :ok -> {:cont, :ok}
        error -> {:halt, error}
      end
    end)
  end

  defp digest_fields(document, keys) do
    if Enum.all?(keys, &Digest.valid_sha256?(document[&1])),
      do: :ok,
      else: {:error, :invalid_qualification}
  end

  defp transfer_mode(mode) when mode in ["push", "pull"], do: :ok
  defp transfer_mode(_), do: {:error, :invalid_qualification}

  defp effect_class("physical_display"), do: :ok
  defp effect_class(_), do: {:error, :invalid_qualification}

  defp canonical_identity(document) do
    case RFC8785.encode(document) do
      {:ok, canonical_json} ->
        {:ok,
         %{
           digest: Digest.sha256(canonical_json),
           canonical_json: canonical_json,
           document: document
         }}

      {:error, _} ->
        {:error, :invalid_qualification}
    end
  end
end
