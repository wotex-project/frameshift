defmodule Frameshift.Renderer.Indexed4Test do
  @moduledoc false

  use ExUnit.Case, async: false

  alias Frameshift.Renderer
  alias Frameshift.Renderer.Protocol

  @directory Path.expand("../../../../../renderer", __DIR__)
  @worker Path.join(@directory, "zig-out/bin/frameshift-raster")
  @palette [{0, 0, 0}, {255, 255, 255}, {255, 255, 0}, {255, 0, 0}, {0, 0, 255}, {0, 255, 0}]

  setup_all do
    {output, status} =
      System.cmd("zig", ["build", "-Doptimize=ReleaseSafe"],
        cd: @directory,
        stderr_to_stdout: true
      )

    assert status == 0, output
    :ok
  end

  setup do
    renderer = start_supervised!({Renderer, path: @worker, name: nil})
    %{renderer: renderer}
  end

  test "actual worker returns exact pigment codes and retains old indexed8 bytes", c do
    job = job()

    assert {:ok, %{format: :indexed4_msb, width: 6, height: 1, bytes: <<0x01, 0x23, 0x56>>}} =
             Renderer.render(c.renderer, job)

    assert {:ok, %{format: :indexed8, bytes: <<0, 1, 2, 3, 4, 5>>}} =
             Renderer.render(c.renderer, %{job | output_format: :indexed8})

    assert {:ok, %{bytes: <<0x01, 0x23, 0x56>>}} =
             Renderer.render(c.renderer, %{
               job
               | palette: Enum.reverse(job.palette),
                 wire_codes: Enum.reverse(job.wire_codes)
             })
  end

  test "request 0.2 retains the 52-byte header and four-byte RGB/code entries" do
    job = job()
    assert {:ok, [<<size::32>>, body]} = Protocol.encode_request(job)
    assert size == 52 + 6 * 4 + 6 * 4
    assert <<"FSR1", 0, 2, 1, 3, 2, 0, 0::16, _::binary>> = body

    assert binary_part(body, 52, 24) ==
             <<0, 0, 0, 0, 255, 255, 255, 1, 255, 255, 0, 2, 255, 0, 0, 3, 0, 0, 255, 5, 0, 255,
               0, 6>>
  end

  test "host refuses malformed codes and odd rows before dispatch", c do
    original = job()

    invalid = [
      Map.delete(original, :wire_codes),
      %{original | wire_codes: [0, 1, 2, 3, 5, 5]},
      %{original | wire_codes: [0, 1, 2, 3, 5, 16]},
      %{original | wire_codes: [0, 1, 2, 3, 5, -1]},
      %{original | wire_codes: [0, 1, 2, 3, 5, "6"]},
      %{original | wire_codes: [0, 1]},
      %{original | palette: [{0, 0, 0}], wire_codes: [0]},
      %{original | target_width: 5}
    ]

    for job <- invalid, do: assert({:error, :invalid_profile} = Renderer.render(c.renderer, job))

    assert {:error, :invalid_color} =
             Protocol.encode_request(%{original | palette: [{0, 0, 256} | tl(original.palette)]})

    assert {:ok, _} = Renderer.render(c.renderer, original)
  end

  test "response decoding admits only the exact version, row geometry and byte count" do
    response = <<"FSO1", 0, 2, 0, 3, 6::32, 1::32, 3::32, 1, 35, 86>>

    assert {:ok, {:ok, %{format: :indexed4_msb, bytes: <<1, 35, 86>>}}} =
             Protocol.decode_response(response)

    assert {:ok, _, <<>>} = Protocol.take_response(<<byte_size(response)::32, response::binary>>)

    assert {:error, :invalid_output_format} =
             Protocol.decode_response(<<"FSO1", 0, 1, 0, 3, 6::32, 1::32, 3::32, 1, 35, 86>>)

    assert {:error, :invalid_output_format} =
             Protocol.decode_response(<<"FSO1", 0, 2, 0, 2, 6::32, 1::32, 3::32, 1, 35, 86>>)

    assert {:error, :invalid_response_length} =
             Protocol.decode_response(<<"FSO1", 0, 2, 0, 3, 5::32, 1::32, 3::32, 1, 35, 86>>)

    assert {:error, :invalid_response_length} =
             Protocol.decode_response(<<"FSO1", 0, 2, 0, 3, 6::32, 1::32, 2::32, 1, 35>>)

    assert {:error, :invalid_response_length} =
             Protocol.decode_response(<<"FSO1", 0, 2, 0, 3, 6::32, 1::32, 3::32, 1, 35>>)

    assert {:ok, {:worker_error, :invalid_profile}} =
             Protocol.decode_response(<<"FSO1", 0, 2, 5, 0, 0::32, 0::32, 0::32>>)
  end

  defp job do
    %{
      source_width: 6,
      source_height: 1,
      crop_x: 0,
      crop_y: 0,
      crop_width: 6,
      crop_height: 1,
      target_width: 6,
      target_height: 1,
      background: {255, 255, 255},
      output_format: :indexed4_msb,
      resize_filter: :bilinear,
      dither_mode: :none,
      palette: @palette,
      wire_codes: [0, 1, 2, 3, 5, 6],
      rgba: for({r, g, b} <- @palette, into: <<>>, do: <<r, g, b, 255>>)
    }
  end
end
