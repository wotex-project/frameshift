defmodule FrameshiftPlatform.DependencyBoundaryTest do
  @moduledoc false

  use ExUnit.Case, async: true

  alias FrameshiftPlatform.AtomFilterFixture, as: AtomFilter
  require Ash.Query

  test "locked Ash filters unsafe atom attributes without interning caller strings" do
    record =
      AtomFilter |> Ash.Changeset.for_create(:create, %{value: :fixture_value}) |> Ash.create!()

    assert [%{id: id}] = AtomFilter |> Ash.Query.filter(value == "fixture_value") |> Ash.read!()
    assert id == record.id

    for _ <- 1..100 do
      input = "frameshift_uninterned_filter_#{System.unique_integer([:positive])}"
      assert [] = AtomFilter |> Ash.Query.filter(value == ^input) |> Ash.read!()
      assert_raise ArgumentError, fn -> String.to_existing_atom(input) end
    end
  end

  test "locked Gun refuses CRLF before dispatching a request" do
    for header <- ["x-test", "cookie"], value <- ["a\rb", "a\nb", "a\r\nx: injected"] do
      assert_raise ErlangError, fn -> :gun.get(self(), "/", [{header, value}]) end
    end

    refute_receive {:"$gen_cast", _}
    assert :ignore == :cow_cookie.parse_set_cookie("a=b\r\nx: injected")
  end

  test "BAML native parser loads with the runtime's Rustler build dependency" do
    types = BamlElixir.Native.parse_baml(Application.app_dir(:beamlens, "priv/baml_src"))
    assert Map.has_key?(types, :functions)
    assert Map.has_key?(types, :classes)
  end
end
