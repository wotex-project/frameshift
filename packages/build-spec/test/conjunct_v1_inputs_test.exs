defmodule FrameshiftBuild.ConjunctV1InputsTest do
  @moduledoc false

  use ExUnit.Case, async: true

  alias FrameshiftBuild.ConjunctAdapter

  @hands __DIR__
         |> Path.join("fixtures/conjunct-v1-inputs.expected.json")
         |> File.read!()
         |> JSON.decode!()

  test "all five original identity domains and every authored refusal survive import" do
    assert length(@hands["cases"]) == 32

    for hand <- @hands["cases"] do
      actual =
        case apply(ConjunctAdapter, :v1_inputs, expand(hand["args"])) do
          {:ok, value} -> %{"ok" => true, "value" => value}
          {:error, error} -> %{"ok" => false, "error" => error}
        end

      assert actual == hand["expected"], hand["id"]
    end
  end

  defp expand(values) when is_list(values), do: Enum.map(values, &expand/1)
  defp expand(%{"$source" => name}), do: Map.fetch!(@hands["sources"], name)

  defp expand(%{"$repeat" => %{"value" => value, "count" => count}}),
    do: String.duplicate(expand(value), count)

  defp expand(%{"$copies" => %{"value" => value, "count" => count}}),
    do: List.duplicate(expand(value), count)

  defp expand(value), do: value
end
