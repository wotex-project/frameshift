defmodule FrameshiftPlatformWeb.ErrorJSON do
  @moduledoc """
  Renders public HTTP failures as status-derived JSON messages.

  `render/2` asks Phoenix for the standard status message associated with the
  error template and returns it under `errors.detail`. Exception messages,
  request parameters and assigns do not enter that public response.

  ## Error boundary

  This module formats generic endpoint errors. Catalog controllers separately
  return their finite domain error codes for invalid input and unavailable reads.
  Detailed diagnostics belong to the host's authorized operational path, not
  anonymous JSON responses.
  """

  @spec render(String.t(), map()) :: map()
  def render(template, _) do
    %{errors: %{detail: Phoenix.Controller.status_message_from_template(template)}}
  end
end
