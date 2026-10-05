defmodule FrameshiftPlatform.Access.Memberships do
  @moduledoc """
  Provisions private catalog grants and derives current session permission actors.

  `grant/4` takes a stable grant UUID, account UUID, server-selected catalog role
  and trusted local administrator actor. `revoke/3` takes the grant UUID, expected
  version 1 and administrator. Transactions serialize each account's grants and
  each grant's revocation; exact retry returns retained state without replacing
  attribution or timestamps. Conflicting identity, input or revision refuses.

  ## Authentication and current permission

  `actor_for/2` verifies the opaque session through
  `FrameshiftPlatform.Access.Authentication.authenticate/1`, derives its account
  UUID and loads one active membership for the server-selected role. Its
  `FrameshiftPlatform.Access.Actor` carries the grant UUID and version 1.
  `current?/1` rechecks that reference for each Ash role policy. It never caches
  grants or falls back to a trusted local actor on failed account lookup.

  ## Results and authority limits

  Results are records/actors or finite `:invalid_input`, `:unauthorized`,
  `:conflict`, `:unavailable` and `:outcome_unknown` refusals. An exceptional
  provisioning operation is uncertain; callers must inspect/replay the same
  stable input rather than assume no effect. Read/storage failures grant nothing.
  Private records and IDs must not enter browser schemas, logs or public views.

  These functions have no HTTP route. The supported operator role reads only the
  existing catalog audit; it admits no Refpath operator/project or composition.
  Reference checking is not an atomic command lease. Browser writes still need
  their command, revision, transaction and private-resource qualification.
  """

  alias FrameshiftPlatform.Access.{Actor, Authentication, Membership}
  alias FrameshiftPlatform.Repo
  require Ash.Query

  @roles [:catalog_editor, :research_worker, :operator]
  @type failure :: :invalid_input | :unauthorized | :conflict | :unavailable | :outcome_unknown

  @doc "Creates or inspects one stable attributed grant under trusted administration."
  @spec grant(String.t(), String.t(), atom(), Actor.t()) ::
          {:ok, Membership.t()} | {:error, failure()}
  def grant(id, user_id, role, admin) do
    with :ok <- administrator(admin),
         true <- uuid?(id) and uuid?(user_id) and role in @roles do
      transaction(fn -> grant_for_account(id, user_id, role, admin) end)
    else
      false -> {:error, :invalid_input}
      error -> error
    end
  end

  @doc "Revokes once at version 1 and preserves exact repeated revocation."
  @spec revoke(String.t(), integer(), Actor.t()) :: {:ok, Membership.t()} | {:error, failure()}
  def revoke(id, expected, admin) do
    with :ok <- administrator(admin), true <- uuid?(id) and expected == 1 do
      transaction(fn -> revoke_existing(id, admin) end)
    else
      false -> {:error, :invalid_input}
      error -> error
    end
  end

  @doc "Resolves one server-selected catalog role from a verified current session."
  @spec actor_for(binary(), atom()) :: {:ok, Actor.t()} | {:error, failure()}
  def actor_for(token, role) when role in @roles do
    with {:ok, user} <- Authentication.authenticate(token),
         {:ok, [grant]} <-
           Membership
           |> Ash.Query.filter(user_id == ^user.id and role == ^role and is_nil(revoked_at))
           |> Ash.Query.limit(2)
           |> Ash.read(authorize?: false) do
      {:ok,
       %Actor{id: user.id, role: role, membership_id: grant.id, membership_version: grant.version}}
    else
      {:error, :unavailable} -> {:error, :unavailable}
      {:error, error} when is_struct(error) -> {:error, :unavailable}
      _ -> {:error, :unauthorized}
    end
  rescue
    _ -> {:error, :unavailable}
  end

  def actor_for(_, _), do: {:error, :invalid_input}

  @doc "Rechecks an account grant, or accepts the existing explicitly trusted local path."
  @spec current?(term()) :: boolean()
  def current?(%Actor{membership_id: nil, membership_version: nil} = actor),
    do: Actor.allowed?(actor, [:catalog_editor, :research_worker, :operator, :access_admin])

  def current?(%Actor{id: user_id, role: role, membership_id: id, membership_version: 1})
      when role in @roles do
    if uuid?(id) and uuid?(user_id) do
      case Repo.query(
             "SELECT 1 FROM platform_memberships m JOIN platform_users u ON u.id = m.user_id WHERE m.id = $1 AND m.user_id = $2 AND m.role = $3 AND m.version = 1 AND m.revoked_at IS NULL",
             [Ecto.UUID.dump!(id), Ecto.UUID.dump!(user_id), Atom.to_string(role)],
             mode: :savepoint
           ) do
        {:ok, %{rows: [[1]]}} -> true
        _ -> false
      end
    else
      false
    end
  rescue
    _ -> false
  end

  def current?(_), do: false

  defp grant_for_account(id, user_id, role, admin) do
    case Repo.query!("SELECT id FROM platform_users WHERE id = $1 FOR UPDATE", [
           Ecto.UUID.dump!(user_id)
         ]).rows do
      [[_]] -> grant_locked(id, user_id, role, admin)
      _ -> {:error, :conflict}
    end
  end

  defp revoke_existing(id, admin) do
    case Repo.query!("SELECT id FROM platform_memberships WHERE id = $1 FOR UPDATE", [
           Ecto.UUID.dump!(id)
         ]).rows do
      [[_]] -> revoke_locked(id, admin)
      _ -> {:error, :conflict}
    end
  end

  defp grant_locked(id, user_id, role, admin) do
    case Ash.get(Membership, id, actor: admin, not_found_error?: false) do
      {:ok, nil} ->
        finite(
          Ash.create(Membership, %{id: id, user_id: user_id, role: role},
            action: :grant,
            actor: admin
          )
        )

      {:ok, %{user_id: ^user_id, role: ^role, granted_by: administrator} = grant}
      when administrator == admin.id ->
        {:ok, grant}

      {:error, _} ->
        {:error, :unavailable}

      _ ->
        {:error, :conflict}
    end
  end

  defp revoke_locked(id, admin) do
    case Ash.get(Membership, id, actor: admin) do
      {:ok, %{version: 1} = grant} ->
        finite(Ash.update(grant, %{}, action: :revoke, actor: admin))

      {:ok, %{version: 2, revoked_by: administrator} = grant} when administrator == admin.id ->
        {:ok, grant}

      {:error, _} ->
        {:error, :unavailable}

      _ ->
        {:error, :conflict}
    end
  end

  defp finite({:ok, grant}), do: {:ok, grant}

  defp finite({:error, error}) do
    case Ash.Error.to_error_class(error) do
      %Ash.Error.Invalid{} -> {:error, :conflict}
      _ -> {:error, :outcome_unknown}
    end
  end

  defp finite(_), do: {:error, :outcome_unknown}

  defp transaction(fun) do
    case Repo.transaction(fn -> settle(fun.()) end) do
      {:ok, value} ->
        {:ok, value}

      {:error, reason} when reason in [:conflict, :unavailable, :outcome_unknown] ->
        {:error, reason}

      {:error, error} ->
        finite({:error, error})
    end
  rescue
    _ -> {:error, :outcome_unknown}
  end

  defp settle({:ok, value}), do: value
  defp settle({:error, reason}), do: Repo.rollback(reason)

  defp administrator(%Actor{membership_id: nil, membership_version: nil} = actor) do
    if Actor.allowed?(actor, [:access_admin]) and uuid?(actor.id),
      do: :ok,
      else: {:error, :unauthorized}
  end

  defp administrator(_), do: {:error, :unauthorized}

  defp uuid?(value) when is_binary(value) do
    case Ecto.UUID.cast(value) do
      {:ok, ^value} -> true
      _ -> false
    end
  end

  defp uuid?(_), do: false
end
