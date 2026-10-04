defmodule FrameshiftPlatform.Access.StampActor do
  @moduledoc """
  Derives persisted actor attribution from trusted Ash action context.

  The change force-sets `:actor_id` from a
  `FrameshiftPlatform.Access.Actor` supplied to the action. Resource attributes
  mark that field non-writable so accepted input cannot override attribution.
  A missing typed actor adds an action error instead of recording a guessed ID.

  ## Policy relationship

  This change writes attribution; it does not authenticate or authorize the
  actor. Resource policies using `FrameshiftPlatform.Access.RoleCheck` establish
  role eligibility. Apply both boundaries to catalog and audit creates so the
  stored actor and the policy actor refer to the same invocation.
  """

  use Ash.Resource.Change
  alias FrameshiftPlatform.Access.Actor

  @impl true
  def change(changeset, _, %{actor: %Actor{id: id}}) do
    Ash.Changeset.force_change_attribute(changeset, :actor_id, id)
  end

  def change(changeset, _, _) do
    Ash.Changeset.add_error(changeset, "authenticated actor required")
  end
end
