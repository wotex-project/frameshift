defmodule FrameshiftPlatform.Access.RoleCheck do
  @moduledoc """
  Checks an Ash action's actor against an explicitly configured role list.

  Configure the policy with a `:roles` option, such as `[:catalog_editor]`.
  The check delegates to `FrameshiftPlatform.Access.Actor.allowed?/2`, requiring
  a typed actor, UUID-castable identity and an admitted role. Untyped or malformed
  actors fail the check rather than acquiring anonymous write privileges.

  ## Integration

  Use this check in resource policies, not as a session authenticator. The
  invoking boundary must establish the actor first; action parameters cannot
  replace that context. `describe/1` supplies the policy's human-readable role
  requirement for Ash diagnostics.

  Account-derived actors carry a private grant/version reference. The check calls
  `FrameshiftPlatform.Access.Memberships.current?/1` against current PostgreSQL
  state; revoked, replaced, mismatched references and unavailable storage refuse.
  The existing explicit local actor path remains separate. This policy check
  provides no command identity, transaction lease or browser authentication.
  """

  use Ash.Policy.SimpleCheck
  alias FrameshiftPlatform.Access.Actor

  @impl true
  def describe(opts), do: "actor has one of #{inspect(opts[:roles])}"

  @impl true
  def match?(actor, _, opts) do
    Actor.allowed?(actor, Keyword.fetch!(opts, :roles)) and
      FrameshiftPlatform.Access.Memberships.current?(actor)
  end
end
