defmodule FrameshiftPlatform.Assets.Types do
  @moduledoc """
  Declares the public Ash projections used by generated frontend contracts.

  phoenix-assets derives `ProfileRevision`, `SourceDocument` and `SessionView` types directly
  from their resources with `only: :public`. The resources remain the attribute
  owner; the browser consumes generated types rather than maintaining a second
  handwritten schema.

  ## Data boundary

  The ephemeral `FrameshiftPlatformWeb.SessionView` owns only authenticated
  status and a transient CSRF value, with no account/token or authorization fields.
  Catalog projections omit nonpublic canonical payloads, source bindings and actor
  attribution. The session projection reports account resolution without granting
  domain permission. None of these types establishes write authorization or
  physical qualification. Run the existing generated-contract checks when resource
  attributes change so server projections and Svelte types remain aligned.
  """

  use PhoenixAssets.Types.Schema
  type("ProfileRevision", resource: FrameshiftPlatform.Catalog.ProfileRevision, only: :public)
  type("SourceDocument", resource: FrameshiftPlatform.Catalog.SourceDocument, only: :public)
  type("SessionView", resource: FrameshiftPlatformWeb.SessionView, only: :public)
end
