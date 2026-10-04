defmodule FrameshiftPlatform.Assets.Types do
  @moduledoc """
  Declares the public Ash projections used by generated frontend contracts.

  phoenix-assets derives `ProfileRevision` and `SourceDocument` types directly
  from their resources with `only: :public`. The resources remain the attribute
  owner; the browser consumes generated types rather than maintaining a second
  handwritten schema.

  ## Data boundary

  These projections omit nonpublic canonical payloads, source bindings and actor
  attribution. They describe public catalog metadata, not write authorization or
  physical qualification. Run the existing generated-contract checks when resource
  attributes change so server projections and Svelte types remain aligned.
  """

  use PhoenixAssets.Types.Schema
  type("ProfileRevision", resource: FrameshiftPlatform.Catalog.ProfileRevision, only: :public)
  type("SourceDocument", resource: FrameshiftPlatform.Catalog.SourceDocument, only: :public)
end
