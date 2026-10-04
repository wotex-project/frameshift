defmodule FrameshiftPlatform.Access do
  @moduledoc """
  Owns the platform's actor policies and append-only audit resource.

  The Ash domain registers `FrameshiftPlatform.Access.AuditEvent`, which records
  source/profile attribution inside the transaction that creates the catalog
  record. Use catalog actions rather than inserting audit rows independently.

  ## Actor boundary

  `FrameshiftPlatform.Access.Actor` carries a trusted UUID and role from the
  invoking boundary. Role checks authorize catalog writers and operator reads;
  constructing an actor struct does not authenticate an HTTP caller. Audit data
  and actor identities are separate from anonymous catalog projections.
  """

  use Ash.Domain

  resources do
    resource FrameshiftPlatform.Access.AuditEvent
  end
end
