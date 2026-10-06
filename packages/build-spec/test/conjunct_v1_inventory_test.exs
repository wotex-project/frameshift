defmodule FrameshiftBuild.ConjunctInventoryTest do
  @moduledoc false

  use ExUnit.Case, async: true

  test "all authored complete source inventories and bounded refusals" do
    fixture =
      "test/fixtures/conjunct-v1-inventory.expected.json" |> File.read!() |> JSON.decode!()

    for hand <- fixture["cases"] do
      args = expand(hand["args"], fixture["sources"])

      actual =
        case apply(FrameshiftBuild.ConjunctAdapter, :v1_inventory, args) do
          {:ok, value} -> %{"ok" => true, "value" => value}
          {:error, code} -> %{"ok" => false, "error" => code}
        end

      assert actual == hand["expected"], hand["id"]
    end
  end

  defp expand(%{"$source" => key}, sources), do: Map.fetch!(sources, key)

  defp expand(%{"$repeat" => %{"value" => value, "count" => count}}, sources),
    do: String.duplicate(expand(value, sources), count)

  defp expand(%{"$copies" => %{"value" => value, "count" => count}}, sources),
    do: List.duplicate(expand(value, sources), count)

  defp expand(values, sources) when is_list(values), do: Enum.map(values, &expand(&1, sources))
  defp expand(value, _), do: value
end
