defmodule FrameshiftPlatform.Access.Actor do
  @moduledoc """
  Carries trusted actor identity and role into platform actions.

  The struct requires `:id` and `:role`. `allowed?/2` accepts only this struct,
  a UUID-castable binary ID and membership in the caller's explicit role list;
  other inputs return `false`. It performs no database lookup or authentication.

  ## Supplying an actor

  Authenticated boundaries derive the identity and role before invoking Ash.
  Request JSON must not choose them. `FrameshiftPlatform.Access.RoleCheck`
  uses this value for policies, and `FrameshiftPlatform.Access.StampActor`
  writes the same identity into immutable attribution fields.

  `FrameshiftPlatform.Access.Memberships.actor_for/2` supplies an exact private
  `:membership_id` and `:membership_version` after current session verification.
  Policies recheck that reference, so a held actor cannot survive revocation or
  replacement. Both fields are nil for the existing explicitly trusted local
  administrator/worker path; failed authentication cannot select that path.
  Inspection omits identity, role and grant fields so policy diagnostics cannot
  disclose private account/permission references.
  """

  @enforce_keys [:id, :role]
  @derive {Inspect, only: []}
  defstruct [:id, :role, :membership_id, :membership_version]

  @type t :: %__MODULE__{
          id: String.t(),
          role: atom(),
          membership_id: String.t() | nil,
          membership_version: pos_integer() | nil
        }

  @spec allowed?(term(), [atom()]) :: boolean()
  def allowed?(%__MODULE__{id: id, role: role}, roles) when is_binary(id) do
    match?({:ok, _}, Ecto.UUID.cast(id)) and role in roles
  end

  def allowed?(_, _), do: false
end
