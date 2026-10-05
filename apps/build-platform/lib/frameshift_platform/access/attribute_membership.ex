defmodule FrameshiftPlatform.Access.AttributeMembership do
  @moduledoc """
  Derives membership grant/revocation attribution from trusted action context.

  Configure the change with `event: :grant` or `event: :revoke` on
  `FrameshiftPlatform.Access.Membership`. It stamps the invoking administrator's
  UUID and the current UTC time into non-writable attributes. Missing or
  unauthorized actors add an action error; request attributes cannot choose
  attribution or the timestamp.

  ## Lifecycle owner

  This change stamps attribution only. The membership's Ash policy, version
  validation, optimistic lock and PostgreSQL constraints own authorization and
  the one-way transition. `FrameshiftPlatform.Access.Memberships` serializes
  provisioning/revocation and handles exact retry without changing retained
  timestamps. There is no public provisioning route or automatic retry.
  """

  use Ash.Resource.Change
  alias FrameshiftPlatform.Access.Actor

  @impl true
  def change(changeset, opts, %{actor: %Actor{id: id} = actor}) do
    if Actor.allowed?(actor, [:access_admin]) do
      event = Keyword.fetch!(opts, :event)

      {identity, time} =
        if event == :grant, do: {:granted_by, :granted_at}, else: {:revoked_by, :revoked_at}

      changeset
      |> Ash.Changeset.force_change_attribute(identity, id)
      |> Ash.Changeset.force_change_attribute(time, DateTime.utc_now())
    else
      Ash.Changeset.add_error(changeset, "trusted membership administrator required")
    end
  end

  def change(changeset, _, _),
    do: Ash.Changeset.add_error(changeset, "trusted membership administrator required")
end
