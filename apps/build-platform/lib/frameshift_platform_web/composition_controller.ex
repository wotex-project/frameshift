defmodule FrameshiftPlatformWeb.CompositionController do
  @moduledoc """
  Exposes the public frame-composition qualification state.

  `show/2` accepts one exact `paper`, `photo` or `pixel` class and returns the
  deterministic projection from `FrameshiftPlatform.Composition`. It names all
  mandatory obligations and the currently missing producer boundaries without
  exposing private catalog, artwork, actor or operational records.

  ## Response contract

  An unavailable profile is a successful read with `status: unavailable` and
  `admission: false`; it is not a transport outage or physical incompatibility.
  Unknown or structured class parameters return `400 unsupported_class`.
  Responses are not cached so a later qualified deployment cannot inherit an
  earlier availability projection. This read grants no composition execution
  or mutation authority, regardless of extra caller parameters.
  """

  use Phoenix.Controller, formats: [:json]
  alias FrameshiftPlatform.Composition

  @spec show(Plug.Conn.t(), map()) :: Plug.Conn.t()
  def show(conn, parameters) do
    conn = Plug.Conn.put_resp_header(conn, "cache-control", "no-store")

    case Composition.availability(Map.get(parameters, "class")) do
      {:ok, state} ->
        json(conn, state)

      {:error, :unsupported_class} ->
        conn |> put_status(:bad_request) |> json(%{error: "unsupported_class"})
    end
  end
end
