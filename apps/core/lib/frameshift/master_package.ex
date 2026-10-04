defmodule Frameshift.MasterPackage do
  @moduledoc """
  Packages exact source bytes with their canonical RGBA8 master representation.

  `encode/4` validates original bytes, dimensions and tightly packed RGBA length,
  then returns the versioned FSM1 container as iodata. `decode/1` verifies magic,
  version, reserved fields, lengths and complete body before returning dimensions,
  original bytes and canonical pixels. Both paths reject malformed/oversized data.

  ## Representation and limits

  The 32-byte header uses unsigned big-endian fields. Canonical pixels are sRGB,
  top-left row order, straight alpha and orientation 1; the Apple decoding boundary
  must normalize them before packaging. Dimension, source-byte and pixel ceilings
  are enforced by this module and `Frameshift.Renderer.Protocol`.

  `media_type/0` identifies this internal durable format. It is a master container,
  not a frame artifact or a network control document. `Frameshift.RenderPipeline`
  uses its verified pixels to render exact target bytes while retaining the
  unchanged original for future recipes and derivatives.
  """

  @magic "FSM1"
  @version 1
  @header_bytes 32
  @maximum_dimension 32_768
  @maximum_pixels Frameshift.Renderer.Protocol.maximum_source_pixels()
  @maximum_source_bytes 128 * 1024 * 1024
  @maximum_rgba_bytes @maximum_pixels * 4
  @maximum_package_bytes @header_bytes + @maximum_rgba_bytes + @maximum_source_bytes

  @type decoded :: %{
          width: pos_integer(),
          height: pos_integer(),
          rgba: binary(),
          original: binary()
        }

  @doc "Returns the versioned media type for immutable master packages."
  @spec media_type() :: String.t()
  def media_type, do: "application/vnd.frameshift.master-v1"

  @doc "Returns the admitted maximum package size in bytes."
  @spec maximum_package_bytes() :: pos_integer()
  def maximum_package_bytes, do: @maximum_package_bytes

  @doc "Packages exact source bytes with canonical RGBA pixels and checked dimensions."
  @spec encode(binary(), binary(), pos_integer(), pos_integer()) ::
          {:ok, iodata()} | {:error, atom()}
  def encode(original, rgba, width, height)
      when is_binary(original) and is_binary(rgba) and is_integer(width) and is_integer(height) do
    with :ok <- validate_dimensions(width, height),
         :ok <- validate_original(original),
         :ok <- validate_rgba(rgba, width, height) do
      header =
        <<@magic, @version::unsigned-big-16, 0::unsigned-big-16, width::unsigned-big-32,
          height::unsigned-big-32, byte_size(rgba)::unsigned-big-64,
          byte_size(original)::unsigned-big-64>>

      {:ok, [header, rgba, original]}
    end
  end

  def encode(_, _, _, _), do: {:error, :invalid_master_package}

  @doc "Verifies and unpacks a bounded versioned master package."
  @spec decode(binary()) :: {:ok, decoded()} | {:error, atom()}
  def decode(package) when is_binary(package) and byte_size(package) <= @maximum_package_bytes do
    with {:ok, width, height, rgba_bytes, original_bytes, body} <- parse_header(package),
         :ok <- validate_dimensions(width, height),
         true <- rgba_bytes == width * height * 4,
         true <- rgba_bytes <= @maximum_rgba_bytes,
         true <- original_bytes in 1..@maximum_source_bytes,
         true <- byte_size(body) == rgba_bytes + original_bytes do
      <<rgba::binary-size(^rgba_bytes), original::binary-size(^original_bytes)>> = body
      {:ok, %{width: width, height: height, rgba: rgba, original: original}}
    else
      false -> {:error, :invalid_master_package}
      {:error, reason} -> {:error, reason}
    end
  end

  def decode(_), do: {:error, :invalid_master_package}

  defp parse_header(
         <<@magic, @version::unsigned-big-16, 0::unsigned-big-16, width::unsigned-big-32,
           height::unsigned-big-32, rgba_bytes::unsigned-big-64, original_bytes::unsigned-big-64,
           body::binary>>
       ),
       do: {:ok, width, height, rgba_bytes, original_bytes, body}

  defp parse_header(_), do: {:error, :invalid_master_package}

  defp validate_dimensions(width, height)
       when width in 1..@maximum_dimension and height in 1..@maximum_dimension and
              width * height <= @maximum_pixels,
       do: :ok

  defp validate_dimensions(_, _), do: {:error, :invalid_dimensions}

  defp validate_original(original) when byte_size(original) in 1..@maximum_source_bytes, do: :ok
  defp validate_original(_), do: {:error, :invalid_original}

  defp validate_rgba(rgba, width, height) do
    if byte_size(rgba) == width * height * 4,
      do: :ok,
      else: {:error, :invalid_rgba}
  end
end
