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
  """

  @enforce_keys [:id, :role]
  defstruct [:id, :role]
  @type t :: %__MODULE__{id: String.t(), role: atom()}

  @spec allowed?(term(), [atom()]) :: boolean()
  def allowed?(%__MODULE__{id: id, role: role}, roles) when is_binary(id) do
    match?({:ok, _}, Ecto.UUID.cast(id)) and role in roles
  end

  def allowed?(_, _), do: false
end
