defmodule Frameshift.Generation.NormalizedResult do
  @moduledoc """
  Admits canonical still results from the selected trusted platform adapter.

  `package/2` checks original bytes, dimensions, exact decoder identity and the
  sRGB/top-left/straight-alpha RGBA8 declaration before constructing the same
  `Frameshift.MasterPackage` consumed by deterministic rendering. The adapter
  must actually decode its provider output; a declared MIME type or dimension is
  not a codec. This module verifies the bounded adapter contract, not the model
  or platform codec's independent conformance.

  ## Source and cache custody

  `read_master/2` verifies registered object bytes and the full canonical package,
  including metadata dimensions. It refuses removed, missing, corrupt and legacy
  raw-image masters. `source_request/2` derives edit input through that path and
  attaches transient source bytes to the provider request. Caller source fields
  are rejected by the coordinator and these bytes never enter recipe identity,
  audit or credentials. Cache refusal never invokes another provider or rewrites
  an immutable object.

  Source-byte and pixel bounds follow the master container and Zig request
  envelope. Media/pixel declarations and decoder/model revisions remain separate
  provenance from the SHA-256 identity of the complete immutable master package.
  """

  alias Frameshift.Library
  alias Frameshift.MasterPackage

  @representation "rgba8-srgb-straight-alpha-top-left"
  @source_types ~w(image/png image/jpeg image/heic image/avif)

  @doc "Checks a normalized adapter result and returns its immutable master package."
  @spec package(term(), map()) :: {:ok, map()} | {:error, atom()}
  def package(result, request) when is_map(result) and is_map(request) do
    with :ok <- validate_description(result, request),
         {:ok, package} <-
           MasterPackage.encode(
             result[:bytes],
             result[:canonical_rgba],
             result[:width],
             result[:height]
           ) do
      {:ok, Map.put(result, :master_package, IO.iodata_to_binary(package))}
    end
  end

  def package(_, _), do: {:error, :invalid_provider_result}

  @doc "Verifies an active canonical master before cache reuse or derived edit input."
  @spec read_master(GenServer.server(), String.t()) :: {:ok, map()} | {:error, atom()}
  def read_master(library, digest) do
    with {:ok, %{"removed_at_ms" => nil, "media_type" => media_type} = master} <-
           Library.get_master(library, digest),
         true <- media_type == MasterPackage.media_type(),
         {:ok, object} <-
           Library.read_object(library, digest, MasterPackage.maximum_package_bytes()),
         {:ok, decoded} <- MasterPackage.decode(object["bytes"]),
         true <- decoded.width == master["width"] and decoded.height == master["height"] do
      {:ok, decoded}
    else
      _ -> {:error, :generation_master_unavailable}
    end
  end

  @doc "Adds only Library-derived canonical parent bytes to an edit provider request."
  @spec source_request(GenServer.server(), map()) :: {:ok, map()} | {:error, atom()}
  def source_request(library, %{mode: "edit", parent_digest: digest} = request) do
    with {:ok, source} <- read_master(library, digest) do
      {:ok, Map.put(request, :source_image, Map.put(source, :digest, digest))}
    end
  end

  def source_request(_, request), do: {:ok, request}

  defp validate_description(result, request) do
    cond do
      result[:media_type] not in @source_types ->
        {:error, :invalid_result_media_type}

      not decoder_matches?(result, request) ->
        {:error, :decoder_mismatch}

      result[:canonical_representation] != @representation ->
        {:error, :invalid_canonical_representation}

      not is_binary(result[:bytes]) or not is_binary(result[:canonical_rgba]) ->
        {:error, :invalid_result_bytes}

      MasterPackage.source_media_type(result[:bytes]) != result[:media_type] ->
        {:error, :invalid_result_media_type}

      not valid_result_id?(result[:result_id]) ->
        {:error, :invalid_result_id}

      true ->
        :ok
    end
  end

  defp decoder_matches?(result, request) do
    valid_decoder_value?(request[:decoder_id]) and
      valid_decoder_value?(request[:decoder_revision]) and
      result[:decoder_id] == request[:decoder_id] and
      result[:decoder_revision] == request[:decoder_revision]
  end

  defp valid_decoder_value?(value),
    do: is_binary(value) and byte_size(value) in 1..128 and String.valid?(value)

  defp valid_result_id?(value),
    do: is_binary(value) and byte_size(value) in 1..512 and String.valid?(value)
end
