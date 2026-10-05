defmodule Frameshift.NativeCodec.Protocol do
  @moduledoc """
  Validates the isolated original-byte codec's finite binary boundary.

  `encode_request/1` bounds the exact original before adding its unsigned
  big-endian length. The owner closes stdin after those bytes; paths, credentials,
  caller-declared dimensions and provider context never enter this protocol.
  `decode_header/1` accepts exactly the 64-byte FSN1 v1 header and checks geometry,
  reserved fields, source media, interpretation and payload length before the
  owner reads or allocates canonical pixels.

  ## Representation and failure

  Success describes top-left straight-alpha RGBA8 sRGB with orientation 1. The
  result separately retains original orientation and the source-color
  interpretation/digest used by the pinned codec. `decode_response/2` revalidates
  the original header, exact pixel count and canonical zero-alpha RGB; neither a media
  signature nor a well-formed header proves that a trusted decoder produced it.
  The worker owner must bind execution to the staged executable digest and retain
  that identity in immutable master provenance.

  Producer failures have zero geometry, metadata and payload. They map to finite
  atoms without exposing source metadata or upstream diagnostics. Unknown codes,
  versions, metadata, lengths or trailing bytes refuse. This module performs no
  process, file, library or network I/O; worker deadlines, back-pressure,
  cancellation and actual exit belong to `Frameshift.NativeCodec`.
  """

  @header_bytes 64
  @maximum_source_bytes 128 * 1024 * 1024
  @maximum_pixels Frameshift.Renderer.Protocol.maximum_source_pixels()
  @maximum_dimension 32_768
  @errors %{
    1 => :codec_malformed,
    2 => :codec_unsupported,
    3 => :codec_bounds,
    4 => :codec_color,
    5 => :codec_metadata,
    6 => :codec_allocation,
    7 => :codec_internal
  }
  @interpretations %{
    1 => "assumed-srgb",
    2 => "png-srgb",
    3 => "cicp-srgb",
    4 => "cicp-display-p3",
    5 => "matrix-icc",
    6 => "gamma-srgb-primaries"
  }

  @type header :: %{
          width: pos_integer(),
          height: pos_integer(),
          rgba_bytes: pos_integer(),
          original_orientation: 1..8,
          original_media_type: String.t(),
          color_interpretation: String.t(),
          source_color_digest: String.t() | nil
        }
  @type normalized :: %{
          width: pos_integer(),
          height: pos_integer(),
          rgba: binary(),
          original_orientation: 1..8,
          original_media_type: String.t(),
          color_interpretation: String.t(),
          source_color_digest: String.t() | nil
        }

  @doc "Returns the fixed response header size, before any pixel allocation."
  @spec header_bytes() :: pos_integer()
  def header_bytes, do: @header_bytes

  @doc "Returns the maximum complete canonical response, including its header."
  @spec maximum_response_bytes() :: pos_integer()
  def maximum_response_bytes, do: @header_bytes + @maximum_pixels * 4

  @doc "Bounds an original and returns its exact length-prefixed request as iodata."
  @spec encode_request(binary()) :: {:ok, iodata()} | {:error, atom()}
  def encode_request(bytes)
      when is_binary(bytes) and byte_size(bytes) in 1..@maximum_source_bytes,
      do: {:ok, [<<byte_size(bytes)::unsigned-big-32>>, bytes]}

  def encode_request(_), do: {:error, :invalid_codec_source}

  @doc "Admits one exact FSN1 header and its bounded canonical pixel count."
  @spec decode_header(binary()) :: {:ok, header()} | {:worker_error, atom()} | {:error, atom()}
  def decode_header(
        <<"FSN1", 1::unsigned-big-16, 0, interpretation, width::unsigned-big-32,
          height::unsigned-big-32, orientation, 1, 0::48, length::unsigned-big-64,
          digest::binary-size(32)>>
      ) do
    with true <- width in 1..@maximum_dimension and height in 1..@maximum_dimension,
         true <- width * height <= @maximum_pixels and length == width * height * 4,
         true <- orientation in 1..8,
         {:ok, color} <- Map.fetch(@interpretations, interpretation),
         :ok <- validate_digest(interpretation, digest) do
      {:ok,
       %{
         width: width,
         height: height,
         rgba_bytes: length,
         original_orientation: orientation,
         original_media_type: "image/png",
         color_interpretation: color,
         source_color_digest:
           if(interpretation in [1, 2],
             do: nil,
             else: "sha256:" <> Base.encode16(digest, case: :lower)
           )
       }}
    else
      _ -> {:error, :invalid_codec_header}
    end
  end

  def decode_header(<<"FSN1", 1::unsigned-big-16, status, 0::456>>) do
    case Map.fetch(@errors, status) do
      {:ok, error} -> {:worker_error, error}
      :error -> {:error, :invalid_codec_header}
    end
  end

  def decode_header(_), do: {:error, :invalid_codec_header}

  @doc "Revalidates the original FSN1 header, exact pixels and canonical transparent RGB."
  @spec decode_response(binary(), binary()) :: {:ok, normalized()} | {:error, atom()}
  def decode_response(bytes, rgba) when is_binary(rgba) do
    with {:ok, header} <- decode_header(bytes),
         true <- byte_size(rgba) == header.rgba_bytes and canonical_alpha?(rgba) do
      {:ok, header |> Map.delete(:rgba_bytes) |> Map.put(:rgba, rgba)}
    else
      _ -> {:error, :invalid_codec_pixels}
    end
  end

  def decode_response(_, _), do: {:error, :invalid_codec_pixels}

  defp validate_digest(interpretation, <<0::256>>) when interpretation in [1, 2], do: :ok

  defp validate_digest(interpretation, digest)
       when interpretation in 3..6 and digest != <<0::256>>, do: :ok

  defp validate_digest(_, _), do: {:error, :invalid_codec_header}

  defp canonical_alpha?(<<>>), do: true
  defp canonical_alpha?(<<0, 0, 0, 0, rest::binary>>), do: canonical_alpha?(rest)

  defp canonical_alpha?(<<_, _, _, alpha, rest::binary>>) when alpha != 0,
    do: canonical_alpha?(rest)

  defp canonical_alpha?(_), do: false
end
