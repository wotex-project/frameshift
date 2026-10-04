defmodule FrameshiftPlatform.Catalog.SourceDocument do
  @moduledoc """
  Stores immutable public source locators and revision metadata.

  The `:record` action accepts title, HTTPS URI, revision, content digest, evidence
  kind and observation time. The digest is 64 lowercase hexadecimal characters;
  source URI/revision and content-digest/revision pairs are unique. Trusted action
  context supplies private actor attribution and a transactional audit event.

  ## Reading and recording

  Anonymous reads use required offset pagination with a default of 50 and maximum
  of 100 records. Only catalog editors and research workers may record revisions.
  There are no update or destroy actions; changed source content needs a distinct
  revision instead of overwriting the old observation.

  The resource stores metadata, not downloaded document bytes or permission to
  redistribute them. `FrameshiftPlatform.Catalog.SourceURI` validates locator
  syntax without fetching, resolving or authenticating the source.
  """

  use Ash.Resource,
    domain: FrameshiftPlatform.Catalog,
    data_layer: AshPostgres.DataLayer,
    authorizers: [Ash.Policy.Authorizer]

  postgres do
    table "catalog_source_documents"
    repo FrameshiftPlatform.Repo
  end

  actions do
    read :read do
      primary? true
      pagination offset?: true, default_limit: 50, max_page_size: 100, required?: true
    end

    create :record do
      accept [:title, :uri, :revision, :content_sha256, :kind, :observed_at]
      change FrameshiftPlatform.Access.StampActor
      validate FrameshiftPlatform.Catalog.SourceURI
      change {FrameshiftPlatform.Catalog.RecordEvent, kind: :source}
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

    attribute :title, :string,
      allow_nil?: false,
      public?: true,
      constraints: [min_length: 1, max_length: 200]

    attribute :uri, :string, allow_nil?: false, public?: true, constraints: [max_length: 2_048]

    attribute :revision, :string,
      allow_nil?: false,
      public?: true,
      constraints: [min_length: 1, max_length: 128]

    attribute :content_sha256, :string,
      allow_nil?: false,
      public?: true,
      constraints: [match: ~r/\A[0-9a-f]{64}\z/]

    attribute :kind, :atom,
      allow_nil?: false,
      public?: true,
      constraints: [one_of: [:manufacturer, :standard, :supplier, :measurement, :custom]]

    attribute :observed_at, :utc_datetime_usec, allow_nil?: false, public?: true
    attribute :actor_id, :uuid, allow_nil?: false, writable?: false, sensitive?: true
    create_timestamp :recorded_at, public?: true
  end

  identities do
    identity :source_revision, [:uri, :revision]
    identity :source_content_revision, [:content_sha256, :revision]
  end
end
