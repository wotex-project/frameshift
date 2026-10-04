defmodule FrameshiftPlatform.CompositionTest do
  @moduledoc false

  use ExUnit.Case, async: true
  import Phoenix.ConnTest
  @endpoint FrameshiftPlatformWeb.Endpoint

  test "every frame class retains the complete obligation set and refuses admission" do
    stages =
      ~w(graph completeness geometry viewing power_interfaces power_loads power_contracts thermal mounting signals signal_routes operation artifacts)

    for class <- ~w(paper photo pixel) do
      assert {:ok, state} = FrameshiftPlatform.Composition.availability(class)
      assert state.mandatory_obligations == stages
      assert state.status == :unavailable
      assert state.admission == false
      assert "power_loads" in state.producer_gaps
      assert "signal_routes" in state.producer_gaps
    end
  end

  test "public readiness cannot be promoted by caller flags" do
    conn =
      get(
        build_conn(),
        "/api/composition/paper?status=compatible&admission=true&producer_gaps[]="
      )

    assert %{
             "status" => "unavailable",
             "admission" => false,
             "reason" => "producer_profile_incomplete"
           } = json_response(conn, 200)

    assert Plug.Conn.get_resp_header(conn, "cache-control") == ["no-store"]

    assert build_conn()
           |> post("/api/composition/paper", %{status: "compatible"})
           |> response(404)
  end

  test "unknown class inputs refuse without reflecting caller data" do
    for class <- ["unknown", "Paper", nil, %{"paper" => true}, ["paper"]] do
      assert {:error, :unsupported_class} = FrameshiftPlatform.Composition.availability(class)
    end

    assert %{"error" => "unsupported_class"} =
             build_conn() |> get("/api/composition/private-input") |> json_response(400)
  end
end
