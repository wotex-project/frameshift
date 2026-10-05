defmodule Frameshift.NativeCodec.ProtocolTest do
  @moduledoc false

  use ExUnit.Case, async: true

  alias Frameshift.NativeCodec.Protocol

  test "requests retain exact bytes with a finite unsigned length" do
    assert {:ok, request} = Protocol.encode_request(<<0, 255, 1>>)
    assert IO.iodata_to_binary(request) == <<3::32, 0, 255, 1>>
    assert {:error, :invalid_codec_source} = Protocol.encode_request(<<>>)
    assert {:error, :invalid_codec_source} = Protocol.encode_request(:source)
    assert Protocol.maximum_response_bytes() == 67_108_108
  end

  test "geometry and exact payload limits are checked before reading pixels" do
    assert {:ok, %{width: 32_768, height: 1, rgba_bytes: 131_072}} =
             Protocol.decode_header(header(width: 32_768, length: 131_072))

    for invalid <- [
          header(width: 0),
          header(height: 0),
          header(width: 32_769, length: 131_076),
          header(width: 4_096, height: 4_096, length: 67_108_864),
          header(length: 0),
          header(length: 5),
          header(length: 18_446_744_073_709_551_615)
        ] do
      assert {:error, :invalid_codec_header} = Protocol.decode_header(invalid)
    end
  end

  test "every orientation and source color interpretation has distinct bounded metadata" do
    for orientation <- 1..8, interpretation <- 1..6 do
      digest = if interpretation <= 2, do: <<0::256>>, else: <<1::256>>

      assert {:ok, result} =
               Protocol.decode_header(
                 header(orientation: orientation, interpretation: interpretation, digest: digest)
               )

      assert result.original_orientation == orientation
      assert result.original_media_type == "image/png"
      assert is_binary(result.color_interpretation)

      assert result.source_color_digest ==
               if(interpretation <= 2,
                 do: nil,
                 else: "sha256:" <> Base.encode16(digest, case: :lower)
               )
    end

    for invalid <- [
          header(orientation: 0),
          header(orientation: 9),
          header(interpretation: 0),
          header(interpretation: 7),
          header(interpretation: 1, digest: <<1::256>>),
          header(interpretation: 2, digest: <<1::256>>),
          header(interpretation: 3),
          header(interpretation: 6),
          header(media: 2),
          header(reserved: 1),
          header(version: 2),
          header() <> <<0>>,
          binary_part(header(), 0, 63)
        ] do
      assert {:error, :invalid_codec_header} = Protocol.decode_header(invalid)
    end
  end

  test "only exact finite worker failures with no metadata are admitted" do
    for {code, reason} <-
          Enum.with_index(
            [
              :codec_malformed,
              :codec_unsupported,
              :codec_bounds,
              :codec_color,
              :codec_metadata,
              :codec_allocation,
              :codec_internal
            ],
            1
          )
          |> Enum.map(fn {reason, code} -> {code, reason} end) do
      assert {:worker_error, ^reason} = Protocol.decode_header(<<"FSN1", 1::16, code, 0::456>>)

      assert {:error, :invalid_codec_header} =
               Protocol.decode_header(<<"FSN1", 1::16, code, 0::448, 1>>)
    end

    assert {:error, :invalid_codec_header} = Protocol.decode_header(<<"FSN1", 1::16, 8, 0::456>>)
    assert {:error, :invalid_codec_header} = Protocol.decode_header("bad")
  end

  test "pixels revalidate the wire header and canonical alpha without accepting forged maps" do
    assert {:ok, %{rgba: <<12, 34, 56, 255>>}} =
             Protocol.decode_response(header(), <<12, 34, 56, 255>>)

    assert {:ok, %{rgba: <<0, 0, 0, 0>>}} = Protocol.decode_response(header(), <<0, 0, 0, 0>>)
    assert {:ok, _} = Protocol.decode_response(header(), <<12, 34, 56, 1>>)

    for {metadata, pixels} <- [
          {header(), <<1, 0, 0, 0>>},
          {header(), <<0, 0, 0>>},
          {header(), <<0, 0, 0, 255, 0>>},
          {header(width: 0), <<0, 0, 0, 255>>},
          {%{rgba_bytes: 0}, <<>>},
          {header(), :pixels}
        ] do
      assert {:error, :invalid_codec_pixels} = Protocol.decode_response(metadata, pixels)
    end
  end

  defp header(options \\ []) do
    <<"FSN1", Keyword.get(options, :version, 1)::16, 0, Keyword.get(options, :interpretation, 1),
      Keyword.get(options, :width, 1)::32, Keyword.get(options, :height, 1)::32,
      Keyword.get(options, :orientation, 1), Keyword.get(options, :media, 1),
      Keyword.get(options, :reserved, 0)::48, Keyword.get(options, :length, 4)::64,
      Keyword.get(options, :digest, <<0::256>>)::binary>>
  end
end
