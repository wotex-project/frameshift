defmodule Frameshift.CLIInputTest do
  @moduledoc false

  use ExUnit.Case, async: true

  alias Frameshift.CLIInput

  test "closed input is byte bounded independently of bootstrap or PEM grammar" do
    for {bytes, maximum, expected} <- [
          {"a", 1, {:ok, "a"}},
          {<<0, 255>>, 2, {:ok, <<0, 255>>}},
          {"", 2, {:error, :invalid_input}},
          {"abc", 2, {:error, :invalid_input}},
          {String.duplicate("a", 131_072), 131_072, {:ok, String.duplicate("a", 131_072)}},
          {String.duplicate("a", 131_073), 131_072, {:error, :invalid_input}}
        ] do
      {:ok, device} = StringIO.open(bytes)
      assert CLIInput.read(device, maximum) == expected
      StringIO.close(device)
    end

    for maximum <- [0, -1, 131_073, nil] do
      assert {:error, :invalid_input} = CLIInput.read(:unavailable, maximum)
    end
  end
end
