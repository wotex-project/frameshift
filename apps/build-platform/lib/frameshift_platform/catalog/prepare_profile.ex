defmodule FrameshiftPlatform.Catalog.PrepareProfile do
  @moduledoc """
  Derives candidate profile metadata from validated canonical bytes.

  The Ash create change calls `FrameshiftBuild.inspect_profile/1` and copies only
  its derived identity, key, revision, kind and classes. It resets source bindings
  and places the exact citations in action context for
  `FrameshiftPlatform.Catalog.BindProfileSources` to resolve before insertion.

  ## Input ownership

  Callers supply the canonical document and label, not derived identifiers.
  A codec refusal becomes a `:canonical` field error and prevents creation.
  Valid encoding establishes structural and content identity only; it does not
  promote candidate evidence to a physically qualified configuration.
  """

  use Ash.Resource.Change

  @derived [:identity, :profile_key, :profile_revision, :kind, :classes]

  @impl true
  def change(changeset, _, _) do
    case FrameshiftBuild.inspect_profile(Ash.Changeset.get_attribute(changeset, :canonical)) do
      {:ok, profile} ->
        changeset
        |> Ash.Changeset.force_change_attributes(Map.take(profile, @derived))
        |> Ash.Changeset.force_change_attribute(:source_bindings, [])
        |> Ash.Changeset.set_context(%{profile_citations: profile.citations})

      {:error, code} ->
        Ash.Changeset.add_error(changeset, field: :canonical, message: code)
    end
  end
end
