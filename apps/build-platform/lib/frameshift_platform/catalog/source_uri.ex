defmodule FrameshiftPlatform.Catalog.SourceURI do
  @moduledoc """
  Validates source locator syntax for catalog creation.

  The Ash validation accepts a parsed HTTPS URI with a nonempty host and without
  userinfo or a fragment. Invalid values return a field-specific `:uri` error.
  The source resource separately bounds the locator's stored length.

  ## Validation scope

  This check performs no DNS resolution, network request, provenance verification
  or private-address admission. A syntactically accepted locator is not a
  validated acquisition destination or proof that source content is public.
  Network acquisition requires its own permissions and destination limits.
  """

  use Ash.Resource.Validation

  @impl true
  def validate(changeset, _, _) do
    case Ash.Changeset.get_attribute(changeset, :uri) do
      value when is_binary(value) -> validate_uri(URI.new(value))
      _ -> {:error, field: :uri, message: "requires a public HTTPS source"}
    end
  end

  defp validate_uri({:ok, %URI{scheme: "https", host: host, userinfo: nil, fragment: nil}})
       when is_binary(host) and byte_size(host) > 0, do: :ok

  defp validate_uri(_),
    do: {:error, field: :uri, message: "requires HTTPS without credentials or fragments"}
end
