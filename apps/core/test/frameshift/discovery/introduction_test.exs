defmodule Frameshift.Discovery.IntroductionTest do
  @moduledoc false

  use ExUnit.Case, async: true

  alias Frameshift.Discovery.Introduction

  @entries ["v=0", "id=paper-frame-00001", "td=/.well-known/wot", "scheme=https"]

  test "original wire entries and OS-decoded entries admit only the reference introduction" do
    for entries <- [@entries, @entries ++ ["pair=0"], @entries ++ ["pair=1"]] do
      assert {:ok, result} = Introduction.parse_entries(entries)
      assert Introduction.parse_txt(wire(entries)) == {:ok, result}
      assert result["deviceId"] == "paper-frame-00001"
      assert result["thingPath"] == "/.well-known/wot"
      assert result["pairMode"] == "pair=1" in entries
      assert map_size(result) == 3
    end
  end

  test "duplicates, private fields, unknown versions and routes, and malformed framing refuse" do
    for entries <- [
          @entries ++ ["id=another-frame-0001"],
          @entries ++ ["owner=private"],
          @entries ++ ["pair=true"],
          @entries ++ ["pair=\0"],
          List.replace_at(@entries, 0, "v=1"),
          List.replace_at(@entries, 1, "id=short"),
          List.replace_at(@entries, 1, "id=bad/id-and-untrusted-host"),
          List.replace_at(@entries, 1, "id=" <> <<255, 254>>),
          List.replace_at(@entries, 1, "id=" <> String.duplicate("a", 129)),
          List.replace_at(@entries, 2, "td=https://other.example/.well-known/wot"),
          List.replace_at(@entries, 3, "scheme=http"),
          tl(@entries),
          ["v=0", "id=paper-frame-00001", "td=/.well-known/wot", "scheme"],
          ["v=0", "id=paper-frame-00001", "td=/.well-known/wot", nil]
        ] do
      assert {:error, :invalid_introduction} = Introduction.parse_entries(entries)
    end

    for bytes <- ["", <<0>>, <<30, "v=0">>, wire(@entries) <> <<0>>, String.duplicate("x", 513)] do
      assert {:error, :invalid_introduction} = Introduction.parse_txt(bytes)
    end
  end

  defp wire(entries), do: Enum.map_join(entries, &(<<byte_size(&1)>> <> &1))
end
