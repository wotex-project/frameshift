defmodule FrameshiftPlatform.Catalog.ProfileRevision do
  @moduledoc """
  Stores immutable canonical component profiles and their source bindings.

  The `:record` action accepts only a label and canonical document. Shared v1
  codec validation derives identity, key, revision, kind and classes; exact source
  citations resolve to stored source documents. Actor attribution and the audit
  event are written through the same action transaction.

  ## Reads and identity

  Anonymous reads use required offset pagination, defaulting to 50 records with
  a maximum page size of 100. `:by_identity` retrieves an exact `sha256:` identity.
  Both key/revision and content identity are unique; no update or destroy action
  can silently replace existing bytes. Canonical content and private attribution
  are separate from the public metadata projection.

  ## Evidence scope

  Every row currently has the non-writable `:candidate` evidence state. Recording
  valid bytes and resolved citations does not establish manufacturer authenticity,
  physical compatibility or actual-build admission. Use
  `FrameshiftPlatform.Catalog` interfaces so all changes and policies run.
  """

  use Ash.Resource,
    domain: FrameshiftPlatform.Catalog,
    data_layer: AshPostgres.DataLayer,
    authorizers: [Ash.Policy.Authorizer]

  postgres do
    table "catalog_profile_revisions"
    repo FrameshiftPlatform.Repo
  end

  actions do
    read :read do
      primary? true
      pagination offset?: true, default_limit: 50, max_page_size: 100, required?: true
    end

    read :by_identity do
      get? true
      argument :identity, :string, allow_nil?: false
      filter expr(identity == ^arg(:identity))
    end

    create :record do
      accept [:label, :canonical]
      change FrameshiftPlatform.Access.StampActor
      change FrameshiftPlatform.Catalog.PrepareProfile
      change FrameshiftPlatform.Catalog.BindProfileSources
      change {FrameshiftPlatform.Catalog.RecordEvent, kind: :profile}
    end
  end

  policies do
    policy action_type(:read) do
      authorize_if always()
    end

    policy action(:record) do
      authorize_if {FrameshiftPlatform.Access.RoleCheck,
                    roles: [:catalog_editor, :research_worker]}
    end
  end

  attributes do
    uuid_primary_key :id, public?: true

    attribute :label, :string,
      allow_nil?: false,
      public?: true,
      constraints: [min_length: 1, max_length: 160]

    attribute :canonical, :string,
      allow_nil?: false,
      constraints: [trim?: false, min_length: 1, max_length: 262_144]

    attribute :identity, :string,
      allow_nil?: false,
      public?: true,
      writable?: false,
      constraints: [match: ~r/\Asha256:[0-9a-f]{64}\z/]

    attribute :profile_key, :string,
      allow_nil?: false,
      public?: true,
      writable?: false,
      constraints: [min_length: 1, max_length: 96]

    attribute :profile_revision, :string,
      allow_nil?: false,
      public?: true,
      writable?: false,
      constraints: [min_length: 1, max_length: 96]

    attribute :kind, :string, allow_nil?: false, public?: true, writable?: false

    attribute :classes, {:array, :string},
      allow_nil?: false,
      public?: true,
      writable?: false,
      constraints: [min_length: 1, max_length: 3]

    attribute :evidence_state, :atom,
      allow_nil?: false,
      public?: true,
      writable?: false,
      default: :candidate,
      constraints: [one_of: [:candidate]]

    attribute :source_bindings, {:array, :map}, allow_nil?: false, writable?: false
    attribute :actor_id, :uuid, allow_nil?: false, writable?: false, sensitive?: true
    create_timestamp :recorded_at, public?: true
  end

  identities do
    identity :profile_revision, [:profile_key, :profile_revision]
    identity :profile_content, [:identity]
  end
end
