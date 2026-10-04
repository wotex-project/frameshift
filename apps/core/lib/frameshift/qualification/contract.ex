defmodule Frameshift.Qualification.Contract do
  @moduledoc """
  Checks render/transfer qualification against software implemented by this host.

  `validate/1` requires the declared renderer protocol and algorithm revisions
  to match the local executable contract and selects the connector revision by
  exact push/pull mode. Unknown modes, malformed inputs and unsupported revisions
  return `:unsupported_qualification_contract`.

  ## Qualification scope

  This check is one input to `Frameshift.Qualification.Store`, alongside exact
  frame/profile identity and software evidence. Matching revision labels does not
  prove a candidate has passed a suite or establish physical hardware safety.
  A new algorithm, protocol or connector must be implemented and independently
  qualified before this allowlist changes; data cannot advertise new host code.
  """

  @renderer_protocol "fsr1"
  @renderer_algorithm "frameshift-raster-v0.1"
  @connectors %{
    "push" => "wotex-http-v0.1",
    "pull" => "frameshift-outbox-v0.1"
  }

  @doc "Checks a candidate against executable local software revisions."
  @spec validate(map()) :: :ok | {:error, :unsupported_qualification_contract}
  def validate(document) when is_map(document) do
    if document["rendererProtocolRevision"] == @renderer_protocol and
         document["rendererAlgorithmRevision"] == @renderer_algorithm and
         document["connectorRevision"] == @connectors[document["transferMode"]],
       do: :ok,
       else: {:error, :unsupported_qualification_contract}
  end

  def validate(_), do: {:error, :unsupported_qualification_contract}
end
