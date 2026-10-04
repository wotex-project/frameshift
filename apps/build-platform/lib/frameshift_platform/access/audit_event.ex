defmodule FrameshiftPlatform.Access.AuditEvent do
  @moduledoc """
  Stores append-only attribution for catalog source and profile creation.

  The `:record` action accepts an event and subject UUID, while
  `FrameshiftPlatform.Access.StampActor` derives the actor UUID from action
  context. Allowed events are `:source_recorded` and `:profile_recorded`.
  There are no update or destroy actions.

  ## Access and transaction ownership

  Catalog editors and research workers may record facts; operators may read
  them. `FrameshiftPlatform.Catalog.RecordEvent` creates the event inside the
  originating catalog transaction, so an audit failure also refuses that create.
  The ledger is durable attribution, distinct from process-local telemetry counts
  and the public source/profile projections.
  """

  use Ash.Resource,
    domain: FrameshiftPlatform.Access,
    data_layer: AshPostgres.DataLayer,
    authorizers: [Ash.Policy.Authorizer]

  postgres do
    table "platform_audit_events"
    repo FrameshiftPlatform.Repo
  end

  actions do
    defaults [:read]

    create :record do
      accept [:event, :subject_id]
      change FrameshiftPlatform.Access.StampActor
    end
  end

  policies do
    policy action_type(:read) do
      authorize_if {FrameshiftPlatform.Access.RoleCheck, roles: [:operator]}
    end

    policy action(:record) do
      authorize_if {FrameshiftPlatform.Access.RoleCheck,
                    roles: [:catalog_editor, :research_worker]}
    end
  end

  attributes do
    uuid_primary_key :id
    attribute :actor_id, :uuid, allow_nil?: false, writable?: false, sensitive?: true
    attribute :subject_id, :uuid, allow_nil?: false

    attribute :event, :atom,
      allow_nil?: false,
      constraints: [one_of: [:source_recorded, :profile_recorded]]

    create_timestamp :recorded_at
  end
end
