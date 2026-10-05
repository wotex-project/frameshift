defmodule FrameshiftPlatform.Access do
  @moduledoc """
  Owns private platform accounts, authentication tokens and actor policies.

  The Ash domain registers `FrameshiftPlatform.Access.AuditEvent`, which records
  source/profile attribution inside the transaction that creates the catalog
  record. Use catalog actions rather than inserting audit rows independently.

  `FrameshiftPlatform.Access.User` and `FrameshiftPlatform.Access.Token` use Ash
  Authentication's password/token lifecycle. They share this domain and database
  while remaining excluded from public catalog projections. Only authenticated
  server boundaries may turn an account into a current permission context;
  issuance or possession of a token does not grant a catalog/operator role.

  `FrameshiftPlatform.Access.Membership` retains attributed catalog grants and
  one-way revocation. `FrameshiftPlatform.Access.Memberships` owns trusted local
  provisioning, verified-session role lookup and exact current-reference checks.
  Membership IDs and roles are excluded from public browser projections.

  ## Actor boundary

  `FrameshiftPlatform.Access.Actor` carries a trusted UUID and role from the
  invoking boundary. Role checks authorize catalog writers and operator reads;
  constructing an actor struct does not authenticate an HTTP caller. Audit data
  and actor identities are separate from anonymous catalog projections.
  """

  use Ash.Domain

  resources do
    resource FrameshiftPlatform.Access.AuditEvent
    resource FrameshiftPlatform.Access.User
    resource FrameshiftPlatform.Access.Token
    resource FrameshiftPlatform.Access.Membership
    resource FrameshiftPlatformWeb.SessionView
  end
end
