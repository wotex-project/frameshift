defmodule FrameshiftBuild.ConjunctAdapterTest do
  @moduledoc false

  use ExUnit.Case, async: true

  alias FrameshiftBuild.ConjunctAdapter

  @hands __DIR__
         |> Path.join("fixtures/conjunct-adapter-v1.expected.json")
         |> File.read!()
         |> JSON.decode!()

  test "complete authored conversion hands match without changing source inputs" do
    assert length(@hands["cases"]) == 44

    for hand <- @hands["cases"] do
      actual = invoke(hand["operation"], hand["args"])
      assert actual == hand["expected"], hand["id"]
    end
  end

  defp invoke(operation, arguments) do
    name = %{"quantity" => :quantity, "transform" => :transform, "local_id" => :local_id}

    case apply(ConjunctAdapter, Map.fetch!(name, operation), arguments) do
      {:ok, value} -> %{"ok" => true, "value" => value}
      {:error, error} -> %{"ok" => false, "error" => error}
    end
  end

  test "integers beyond the v1 ceiling refuse before exact conversion" do
    assert {:error, "invalid_range"} =
             ConjunctAdapter.quantity("component", "mass", "g", 0, 9_007_199_254_740_992)

    assert {:error, "invalid_range"} =
             ConjunctAdapter.transform(0, [9_007_199_254_740_992, 0, 0], nil, nil)
  end
end
