defmodule FrameshiftPlatform.Catalog do
  @moduledoc """
  Exposes immutable source documents and candidate component profiles.

  The Ash domain provides source/profile list and record interfaces plus lookup
  by exact profile identity. Reads expose catalog evidence without an account;
  record actions require a trusted catalog-editor or research-worker actor.

  ## Recording evidence

  Record `FrameshiftPlatform.Catalog.SourceDocument` revisions before profiles
  that cite them. Profile creation validates canonical bytes, derives identity
  and metadata, resolves exact citations and records attribution atomically.
  Neither a stored source nor a structurally valid profile proves physical fit;
  `FrameshiftPlatform.Catalog.ProfileRevision` currently retains candidate status.
  """

  use Ash.Domain

  resources do
    resource FrameshiftPlatform.Catalog.ProfileRevision do
      define :list_profiles, action: :read
      define :record_profile, action: :record
      define :get_profile, action: :by_identity, args: [:identity]
    end

    resource FrameshiftPlatform.Catalog.SourceDocument do
      define :list_sources, action: :read
      define :record_source, action: :record
    end
  end
end
