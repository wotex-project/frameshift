defmodule Frameshift.Renderer.Protocol do
  @moduledoc """
  Encodes and validates the bounded binary raster-worker protocol.

  `encode_request/1` checks source/target geometry, crop, output format, palette,
  RGBA length and declared limits before building the length-prefixed request.
  `maximum_frame_bytes/0` and `maximum_source_pixels/0` expose the current software
  ceilings so upstream package/import code can use the same bounds.

  ## Incremental responses

  `take_response/1` consumes a complete frame from fragmented port bytes or
  returns a request for more data. Declared lengths are bounded before response
  allocation. `decode_response/1` checks the versioned worker body and returns
  pixels/metadata or a typed error instead of interpreting malformed bytes.

  ## Packed palette output

  `:indexed4_msb` jobs use FSR1 0.2 and require 2–16 ordered RGB entries with
  matching unique `:wire_codes` in 0–15 and an even target width. The worker
  quantizes to palette positions, maps hardware codes and packs adjacent pixels
  high nibble first. RGB24/indexed8 retain FSR1 0.1. Version/format substitutions,
  malformed codes, odd rows and incorrect packed response lengths refuse.

  This module performs no port, filesystem or library I/O.
  `Frameshift.Renderer` owns deadlines, single-flight state and replacement after
  protocol loss; renderer wire limits do not establish physical frame capacity.
  """

  @maximum_frame_bytes 64 * 1024 * 1024
  @maximum_dimension 32_768
  @maximum_target_pixels 16_777_216
  @request_header_bytes 52
  @maximum_palette_bytes 256 * 3
  @maximum_source_pixels div(
                           @maximum_frame_bytes - @request_header_bytes -
                             @maximum_palette_bytes,
                           4
                         )

  @output_formats %{rgb24: 1, indexed8: 2, indexed4_msb: 3}
  @resize_filters %{nearest: 1, bilinear: 2}
  @dither_modes %{none: 0, ordered_2x2: 1, floyd_steinberg: 2}
  @worker_errors %{
    1 => :malformed,
    2 => :unsupported_version,
    3 => :bounds_exceeded,
    4 => :invalid_crop,
    5 => :invalid_profile,
    6 => :allocation_failed
  }

  @required_job_fields ~w(
    source_width
    source_height
    crop_x
    crop_y
    crop_width
    crop_height
    target_width
    target_height
    background
    output_format
    resize_filter
    dither_mode
    palette
    rgba
  )a

  @doc "Returns the maximum accepted worker frame size."
  @spec maximum_frame_bytes() :: pos_integer()
  def maximum_frame_bytes, do: @maximum_frame_bytes

  @doc "Returns the source pixel ceiling after protocol header and palette overhead."
  @spec maximum_source_pixels() :: pos_integer()
  def maximum_source_pixels, do: @maximum_source_pixels

  @doc "Validates a raster job and builds its length prefixed Zig worker request."
  @spec encode_request(map()) :: {:ok, iodata()} | {:error, term()}
  def encode_request(job) when is_map(job) do
    with :ok <- required_fields(job),
         :ok <- validate_dimensions(job),
         :ok <- validate_crop(job),
         :ok <- validate_source(job),
         {:ok, output} <- fetch_code(@output_formats, job.output_format),
         {:ok, resize} <- fetch_code(@resize_filters, job.resize_filter),
         {:ok, dither} <- fetch_code(@dither_modes, job.dither_mode),
         {:ok, background} <- encode_color(job.background),
         :ok <- validate_profile(job),
         {:ok, palette} <- encode_job_palette(job) do
      body =
        <<
          "FSR1",
          0,
          protocol_minor(job.output_format),
          1,
          output,
          resize,
          dither,
          0::unsigned-big-16,
          job.source_width::unsigned-big-32,
          job.source_height::unsigned-big-32,
          job.crop_x::unsigned-big-32,
          job.crop_y::unsigned-big-32,
          job.crop_width::unsigned-big-32,
          job.crop_height::unsigned-big-32,
          job.target_width::unsigned-big-32,
          job.target_height::unsigned-big-32,
          background::binary,
          0,
          length(job.palette)::unsigned-big-16,
          0::unsigned-big-16,
          palette::binary,
          job.rgba::binary
        >>

      if byte_size(body) <= @maximum_frame_bytes,
        do: {:ok, [<<byte_size(body)::unsigned-big-32>>, body]},
        else: {:error, :request_too_large}
    end
  end

  def encode_request(_), do: {:error, :invalid_job}

  @doc "Consumes one complete response from a possibly fragmented port buffer."
  @spec take_response(binary()) ::
          {:more, binary()}
          | {:ok, {:ok, map()} | {:worker_error, atom()}, binary()}
          | {:error, term()}
  def take_response(buffer) when byte_size(buffer) < 4, do: {:more, buffer}

  def take_response(<<length::unsigned-big-32, rest::binary>> = buffer) do
    cond do
      length > @maximum_frame_bytes ->
        {:error, :response_too_large}

      byte_size(rest) < length ->
        {:more, buffer}

      true ->
        <<body::binary-size(^length), remainder::binary>> = rest

        case decode_response(body) do
          {:ok, result} -> {:ok, result, remainder}
          {:error, reason} -> {:error, reason}
        end
    end
  end

  @doc "Decodes a bounded worker response body into pixels or a typed worker error."
  @spec decode_response(binary()) ::
          {:ok, {:ok, map()} | {:worker_error, atom()}} | {:error, term()}
  def decode_response(<<
        "FSO1",
        0,
        minor,
        status,
        output,
        width::unsigned-big-32,
        height::unsigned-big-32,
        payload_length::unsigned-big-32,
        payload::binary
      >>)
      when minor in [1, 2] do
    with true <- byte_size(payload) == payload_length,
         {:ok, result} <- decode_status(status, output, width, height, payload, minor) do
      {:ok, result}
    else
      false -> {:error, :invalid_response_length}
      {:error, reason} -> {:error, reason}
    end
  end

  def decode_response(_), do: {:error, :invalid_response}

  defp decode_status(0, output, width, height, payload, minor) do
    with {:ok, format, divisor, multiplier} <- decode_output(output, minor),
         :ok <- validate_response_dimensions(width, height),
         true <- rem(width, divisor) == 0,
         true <- byte_size(payload) == div(width * height * multiplier, divisor) do
      {:ok, {:ok, %{format: format, width: width, height: height, bytes: payload}}}
    else
      false -> {:error, :invalid_response_length}
      {:error, reason} -> {:error, reason}
    end
  end

  defp decode_status(status, 0, 0, 0, <<>>, _) do
    case Map.fetch(@worker_errors, status) do
      {:ok, reason} -> {:ok, {:worker_error, reason}}
      :error -> {:error, :unknown_worker_status}
    end
  end

  defp decode_status(_, _, _, _, _, _),
    do: {:error, :invalid_error_response}

  defp decode_output(1, 1), do: {:ok, :rgb24, 1, 3}
  defp decode_output(2, 1), do: {:ok, :indexed8, 1, 1}
  defp decode_output(3, 2), do: {:ok, :indexed4_msb, 2, 1}
  defp decode_output(_, _), do: {:error, :invalid_output_format}

  defp protocol_minor(:indexed4_msb), do: 2
  defp protocol_minor(_), do: 1

  defp required_fields(job) do
    case Enum.reject(@required_job_fields, &Map.has_key?(job, &1)) do
      [] -> :ok
      missing -> {:error, {:missing_fields, missing}}
    end
  end

  defp validate_dimensions(job) do
    dimensions = [
      job.source_width,
      job.source_height,
      job.crop_width,
      job.crop_height,
      job.target_width,
      job.target_height
    ]

    cond do
      not Enum.all?(dimensions, &(is_integer(&1) and &1 > 0 and &1 <= @maximum_dimension)) ->
        {:error, :invalid_dimensions}

      job.source_width * job.source_height > @maximum_source_pixels ->
        {:error, :source_too_large}

      job.target_width * job.target_height > @maximum_target_pixels ->
        {:error, :target_too_large}

      true ->
        :ok
    end
  end

  defp validate_crop(job) do
    valid_origin =
      is_integer(job.crop_x) and job.crop_x >= 0 and
        is_integer(job.crop_y) and job.crop_y >= 0

    if valid_origin and
         job.crop_x + job.crop_width <= job.source_width and
         job.crop_y + job.crop_height <= job.source_height,
       do: :ok,
       else: {:error, :invalid_crop}
  end

  defp validate_source(job) do
    if is_binary(job.rgba) and
         byte_size(job.rgba) == job.source_width * job.source_height * 4,
       do: :ok,
       else: {:error, :invalid_source_length}
  end

  defp validate_profile(%{output_format: :rgb24, palette: [], dither_mode: :none}), do: :ok

  defp validate_profile(%{output_format: :indexed8, palette: palette})
       when is_list(palette) and length(palette) in 1..256,
       do: :ok

  defp validate_profile(%{
         output_format: :indexed4_msb,
         palette: palette,
         wire_codes: codes,
         target_width: width
       })
       when is_list(palette) and is_list(codes) and length(palette) in 2..16 do
    if rem(width, 2) == 0 and length(codes) == length(palette) and
         Enum.all?(codes, &(is_integer(&1) and &1 in 0..15)) and
         length(Enum.uniq(codes)) == length(codes),
       do: :ok,
       else: {:error, :invalid_profile}
  end

  defp validate_profile(_), do: {:error, :invalid_profile}

  defp encode_job_palette(%{output_format: :indexed4_msb} = job) do
    Enum.zip(job.palette, job.wire_codes)
    |> Enum.reduce_while({:ok, <<>>}, fn {color, code}, {:ok, encoded} ->
      case encode_color(color) do
        {:ok, bytes} -> {:cont, {:ok, <<encoded::binary, bytes::binary, code>>}}
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
  end

  defp encode_job_palette(job), do: encode_palette(job.palette)

  defp fetch_code(codes, value) do
    case Map.fetch(codes, value) do
      {:ok, code} -> {:ok, code}
      :error -> {:error, :invalid_profile}
    end
  end

  defp encode_palette(palette) when is_list(palette) and length(palette) <= 256 do
    Enum.reduce_while(palette, {:ok, <<>>}, fn color, {:ok, encoded} ->
      case encode_color(color) do
        {:ok, bytes} -> {:cont, {:ok, <<encoded::binary, bytes::binary>>}}
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
  end

  defp encode_palette(_), do: {:error, :invalid_palette}

  defp encode_color({red, green, blue}) do
    if Enum.all?([red, green, blue], &(is_integer(&1) and &1 in 0..255)),
      do: {:ok, <<red, green, blue>>},
      else: {:error, :invalid_color}
  end

  defp encode_color(_), do: {:error, :invalid_color}

  defp validate_response_dimensions(width, height) do
    if width > 0 and height > 0 and
         width <= @maximum_dimension and height <= @maximum_dimension and
         width * height <= @maximum_target_pixels,
       do: :ok,
       else: {:error, :invalid_response_dimensions}
  end
end
