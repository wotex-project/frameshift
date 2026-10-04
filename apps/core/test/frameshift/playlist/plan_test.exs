defmodule Frameshift.Playlist.PlanTest do
  @moduledoc false

  use ExUnit.Case, async: true

  alias Frameshift.Digest
  alias Frameshift.Playlist.Plan
  alias Frameshift.Protocol.Schema

  @fixture Path.expand("../../../../../protocol/fixtures/valid/capabilities-photo.json", __DIR__)
  @first Digest.sha256("first")
  @second Digest.sha256("second")

  test "a source-qualified profile suggestion becomes the new loop dwell" do
    capabilities =
      photo_capabilities()
      |> put_in(["refresh", "minimumDwellMs"], 180_000)
      |> put_in(["refresh", "recommendedDwellMs"], 21_600_000)
      |> put_in(["refresh", "recommendationBasis"], "provisional-profile")
      |> put_in(["refresh", "recommendationRevision"], "frameshift-paper-e6-v1")

    assert :ok = Schema.validate("capabilities", capabilities)
    assert {:ok, plan} = Plan.build(capabilities, [@first, @second])
    assert plan.dwell_ms == 21_600_000
    assert plan.source == :profile
    assert plan.recommendation_revision == "frameshift-paper-e6-v1"
    assert Enum.map(plan.playlist["entries"], & &1["assetDigest"]) == [@first, @second]
    assert Enum.all?(plan.playlist["entries"], &(&1["dwellMs"] == 21_600_000))
    assert :ok = Schema.validate("playlist", plan.playlist)
  end

  test "continuous displays require a chosen interval and enforce their floor" do
    capabilities = photo_capabilities()
    assert {:error, :interval_required} = Plan.build(capabilities, [@first])
    assert {:ok, plan} = Plan.build(capabilities, [@first], 1)
    assert plan.dwell_ms == 1_000
    assert plan.source == :override
  end

  test "empty, duplicate, malformed, and over-capacity plans fail before transfer" do
    capabilities = photo_capabilities()
    assert {:error, :empty_playlist} = Plan.build(capabilities, [], 1_000)
    assert {:error, :duplicate_artifact} = Plan.build(capabilities, [@first, @first], 1_000)
    assert {:error, :invalid_artifact} = Plan.build(capabilities, ["bad"], 1_000)

    limited = put_in(capabilities, ["storage", "maximumPlaylistLength"], 1)
    assert {:error, :playlist_too_long} = Plan.build(limited, [@first, @second], 1_000)
  end

  test "operator intervals retain millisecond precision within the one-year bound" do
    capabilities = photo_capabilities()
    assert {:ok, %{dwell_ms: 1_501}} = Plan.build(capabilities, [@first], 1_501)
    assert {:ok, %{dwell_ms: 31_536_000_000}} = Plan.build(capabilities, [@first], 31_536_000_000)

    for invalid <- [0, -1, 1.5, "1500", 31_536_000_001] do
      assert {:error, :invalid_interval} = Plan.build(capabilities, [@first], invalid)
    end
  end

  defp photo_capabilities, do: @fixture |> File.read!() |> JSON.decode!()
end
