defmodule FrameshiftPlatform.MembershipConcurrencyTest do
  @moduledoc false

  use ExUnit.Case, async: false
  alias Ecto.Adapters.SQL.Sandbox
  alias FrameshiftPlatform.Access.{Actor, Authentication, Memberships}
  alias FrameshiftPlatform.Repo

  setup do
    user =
      unboxed(fn ->
        password = "private concurrent membership fixture"

        {:ok, user} =
          Authentication.register(%{
            email: "#{Ecto.UUID.generate()}@example.com",
            password: password,
            password_confirmation: password
          })

        user
      end)

    on_exit(fn ->
      unboxed(fn ->
        Repo.transaction(fn ->
          Repo.query!("DELETE FROM platform_memberships WHERE user_id = $1", [
            Ecto.UUID.dump!(user.id)
          ])

          Repo.query!("DELETE FROM platform_tokens WHERE subject = $1", [
            AshAuthentication.user_to_subject(user)
          ])

          Repo.query!("DELETE FROM platform_users WHERE id = $1", [Ecto.UUID.dump!(user.id)])
        end)
      end)
    end)

    %{user: user, admin: %Actor{id: Ecto.UUID.generate(), role: :access_admin}}
  end

  test "independent connections wait on the account lock and cannot grant duplicate active roles",
       %{user: user, admin: admin} do
    parent = self()
    first_id = Ecto.UUID.generate()

    first =
      Task.async(fn ->
        unboxed(fn ->
          Repo.transaction(fn ->
            Repo.query!("SELECT id FROM platform_users WHERE id = $1 FOR UPDATE", [
              Ecto.UUID.dump!(user.id)
            ])

            send(parent, :account_locked)

            receive do
              :release -> :ok
            after
              5000 -> raise "fixture release deadline"
            end

            {:ok, grant} = Memberships.grant(first_id, user.id, :catalog_editor, admin)
            grant
          end)
        end)
      end)

    assert_receive :account_locked

    second =
      Task.async(fn ->
        unboxed(fn ->
          %{rows: [[pid]]} = Repo.query!("SELECT pg_backend_pid()", [])
          send(parent, {:candidate_connection, pid})
          Memberships.grant(Ecto.UUID.generate(), user.id, :catalog_editor, admin)
        end)
      end)

    assert_receive {:candidate_connection, pid}
    await_database_lock(pid, System.monotonic_time(:millisecond) + 5000)
    send(first.pid, :release)
    assert {:ok, grant} = Task.await(first, 5000)
    assert grant.id == first_id
    assert {:error, :conflict} = Task.await(second, 5000)

    assert %{rows: [[1]]} =
             unboxed(fn ->
               Repo.query!("SELECT count(*) FROM platform_memberships WHERE user_id = $1", [
                 Ecto.UUID.dump!(user.id)
               ])
             end)
  end

  test "concurrent exact grant and revoke retries retain one attributed transition", %{
    user: user,
    admin: admin
  } do
    id = Ecto.UUID.generate()
    results = tasks(fn -> Memberships.grant(id, user.id, :research_worker, admin) end)
    assert [{:ok, first}, {:ok, second}] = results
    assert persisted(first) == persisted(second)

    assert [{:ok, revoked}, {:ok, same}] = tasks(fn -> Memberships.revoke(id, 1, admin) end)
    assert revoked.version == 2 and revoked.revoked_by == admin.id
    assert persisted(revoked) == persisted(same)

    assert %{rows: [[1]]} =
             unboxed(fn ->
               Repo.query!("SELECT count(*) FROM platform_memberships WHERE user_id = $1", [
                 Ecto.UUID.dump!(user.id)
               ])
             end)
  end

  defp tasks(fun),
    do:
      1..2
      |> Enum.map(fn _ -> Task.async(fn -> unboxed(fun) end) end)
      |> Enum.map(&Task.await(&1, 5000))

  defp unboxed(fun), do: Sandbox.unboxed_run(Repo, fun)

  defp persisted(grant),
    do:
      Map.take(grant, [
        :id,
        :user_id,
        :role,
        :version,
        :granted_by,
        :granted_at,
        :revoked_by,
        :revoked_at
      ])

  defp await_database_lock(pid, deadline) do
    %{rows: [[waiting]]} =
      unboxed(fn ->
        Repo.query!("SELECT wait_event_type = 'Lock' FROM pg_stat_activity WHERE pid = $1", [pid])
      end)

    if waiting != true do
      assert System.monotonic_time(:millisecond) < deadline,
             "independent connection did not wait on database lock"

      Process.sleep(20)
      await_database_lock(pid, deadline)
    end
  end
end
