defmodule Frameshift.Pairing.Endpoint do
  @moduledoc """
  Returns the pairing response and next physical-window state together.

  `handle/4` accepts an existing `Frameshift.Pairing.Window`, verified peer DER,
  bounded request body and explicit current time. Parsing and authorization check
  the physical device/secret/request ID against the TLS-authenticated peer, then
  produce a finite success/problem response and corresponding next state.

  ## Commit before acknowledgement

  The caller must persist successful authorization before releasing the response.
  This module performs no socket or disk I/O and cannot make that transition
  durable by returning it. Failed attempts may also change window state and must
  be retained according to the owner contract.

  Certificate identity comes exclusively from TLS, never JSON. The endpoint cannot
  open pair mode or accept ordinary frame control; physical adapters and later
  paired interactions retain their separate authority.
  """

  alias Frameshift.Pairing.{Request, Window}

  @type response :: %{status: pos_integer(), content_type: String.t(), body: binary()}

  @doc "Builds one pairing response and next state from an authenticated TLS peer."
  @spec handle(Window.t(), binary(), binary(), non_neg_integer()) :: {response(), Window.t()}
  def handle(%Window{} = state, peer_certificate, body, now_ms) do
    with {:ok, request} <- Request.parse(body),
         {:ok, next} <- Request.authorize(state, request, peer_certificate, now_ms) do
      status = if state.host_certificate_fingerprint == nil, do: 201, else: 200

      response =
        success(status, %{
          "version" => 1,
          "requestId" => request.request_id,
          "deviceId" => next.device_id,
          "hostCertificateFingerprint" => next.host_certificate_fingerprint
        })

      {response, next}
    else
      {:error, reason, next} -> {problem(reason), next}
      {:error, reason} -> {problem(reason), state}
    end
  end

  defp success(status, document) do
    %{
      status: status,
      content_type: "application/json",
      body: RFC8785.encode!(document)
    }
  end

  defp problem(reason) do
    {status, code, title} = problem_details(reason)

    %{
      status: status,
      content_type: "application/problem+json",
      body:
        RFC8785.encode!(%{
          "type" => "urn:frameshift:problem:#{code}",
          "title" => title,
          "status" => status
        })
    }
  end

  defp problem_details(:pair_mode_required),
    do: {403, "pair-mode-required", "Physical pair mode is required"}

  defp problem_details(:pairing_locked), do: {429, "pairing-locked", "Pairing window is closed"}
  defp problem_details(:already_paired), do: {409, "already-paired", "Frame is already paired"}
  defp problem_details(:pairing_rejected), do: {403, "pairing-rejected", "Pairing was rejected"}
  defp problem_details(_), do: {400, "invalid-pairing-request", "Invalid pairing request"}
end
