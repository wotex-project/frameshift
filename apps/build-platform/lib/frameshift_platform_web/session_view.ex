defmodule FrameshiftPlatformWeb.SessionView do
  @moduledoc """
  Declares the public, ephemeral browser-session response schema.

  `project/2` constructs only the authenticated boolean and the CSRF token emitted
  by `FrameshiftPlatformWeb.SessionController`. phoenix-assets derives the
  browser's `SessionView` type from these public Ash attributes, keeping one
  schema owner for the actual HTTP projection and Svelte consumer.

  ## Custody and limits

  This resource has no persistence, primary identity or Ash actions. It stores no
  account, role, scope, password or authentication token and grants no command
  permission. A true boolean means the host resolved its current account; domain
  authorization still requires current server membership. The CSRF token is a
  transient request-protection value, independently of the encrypted HttpOnly
  authentication cookie. Consumers must use the current response without placing
  either value in browser storage or inferring logout from a failed lookup.
  """

  use Ash.Resource, domain: FrameshiftPlatform.Access, data_layer: Ash.DataLayer.Simple

  resource do
    require_primary_key? false
  end

  attributes do
    attribute :authenticated, :boolean, allow_nil?: false, public?: true
    attribute :csrf_token, :string, allow_nil?: false, public?: true
  end

  @doc "Projects the host's current session result through the public schema."
  @spec project(boolean(), String.t()) :: map()
  def project(authenticated, csrf) when is_boolean(authenticated) and is_binary(csrf) do
    fields = Ash.Resource.Info.public_attributes(__MODULE__) |> Enum.map(& &1.name)
    Map.take(struct!(__MODULE__, authenticated: authenticated, csrf_token: csrf), fields)
  end
end
