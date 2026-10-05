defmodule FrameshiftPlatform.MembershipsTest do
  @moduledoc false

  use FrameshiftPlatform.DataCase, async: false
  alias FrameshiftPlatform.Access.{Actor, AuditEvent, Authentication, Membership, Memberships}
  alias FrameshiftPlatform.{Catalog, Repo}

  test "verified login alone has no catalog membership or bootstrap authority" do
    user = account()
    token = user.__metadata__.token

    for role <- [:catalog_editor, :research_worker, :operator],
        do: assert({:error, :unauthorized} = Memberships.actor_for(token, role))

    assert {:error, :invalid_input} = Memberships.actor_for(token, :access_admin)
    assert {:error, :unauthorized} = Memberships.actor_for("forged", :catalog_editor)

    assert {:error, :unauthorized} =
             Memberships.grant(Ecto.UUID.generate(), user.id, :catalog_editor, user)

    assert {:error, _} = Ash.read(Membership, actor: user)
  end

  test "stable grant preserves identity, attribution and timestamps on replay" do
    user = account()
    admin = admin()
    id = Ecto.UUID.generate()
    assert {:ok, grant} = Memberships.grant(id, user.id, :catalog_editor, admin)
    assert grant.id == id and grant.user_id == user.id and grant.version == 1
    assert grant.granted_by == admin.id and grant.revoked_at == nil
    assert {:ok, same} = Memberships.grant(id, user.id, :catalog_editor, admin)
    assert persisted(same) == persisted(grant)
    assert {:error, :conflict} = Memberships.grant(id, user.id, :research_worker, admin)
    assert {:error, :conflict} = Memberships.grant(id, user.id, :catalog_editor, admin())

    assert {:error, :conflict} =
             Memberships.grant(Ecto.UUID.generate(), user.id, :catalog_editor, admin)

    assert %{rows: [[1]]} = Repo.query!("SELECT count(*) FROM platform_memberships", [])
  end

  test "catalog policies recheck exact membership and refuse a held revoked actor" do
    user = account()
    admin = admin()
    assert {:ok, grant} = Memberships.grant(Ecto.UUID.generate(), user.id, :catalog_editor, admin)
    assert {:ok, actor} = Memberships.actor_for(user.__metadata__.token, :catalog_editor)

    assert actor.id == user.id and actor.membership_id == grant.id and
             actor.membership_version == 1

    refute inspect(actor) =~ actor.id
    refute inspect(actor) =~ actor.membership_id
    refute inspect(actor) =~ "catalog_editor"

    assert {:ok, source} = Catalog.record_source(source(), actor: actor)
    assert source.actor_id == user.id
    assert {:ok, revoked} = Memberships.revoke(grant.id, 1, admin)
    assert revoked.version == 2 and revoked.revoked_by == admin.id
    assert {:error, _} = Ash.update(grant, %{}, action: :revoke, actor: admin)
    assert {:ok, same} = Memberships.revoke(grant.id, 1, admin)
    assert persisted(same) == persisted(revoked)
    assert {:ok, same} = Memberships.grant(grant.id, user.id, :catalog_editor, admin)
    assert persisted(same) == persisted(revoked)
    refute Memberships.current?(actor)
    assert {:error, _} = Catalog.record_source(source(), actor: actor)

    assert {:error, :unauthorized} =
             Memberships.actor_for(user.__metadata__.token, :catalog_editor)

    assert {:error, :conflict} = Memberships.revoke(grant.id, 1, admin())
    assert {:error, :invalid_input} = Memberships.revoke(grant.id, 2, admin)
    assert {:ok, %{results: [_]}} = Catalog.list_sources()
  end

  test "regrant uses a new reference and old actor cannot inherit replacement authority" do
    user = account()
    admin = admin()
    {:ok, first} = Memberships.grant(Ecto.UUID.generate(), user.id, :research_worker, admin)
    {:ok, actor} = Memberships.actor_for(user.__metadata__.token, :research_worker)
    {:ok, _} = Memberships.revoke(first.id, 1, admin)
    {:ok, second} = Memberships.grant(Ecto.UUID.generate(), user.id, :research_worker, admin)
    {:ok, current} = Memberships.actor_for(user.__metadata__.token, :research_worker)
    refute Memberships.current?(actor)
    assert current.membership_id == second.id and current.membership_id != first.id
    assert {:ok, _} = Catalog.record_source(source(), actor: current)
  end

  test "mismatched account, role, version and malformed references never qualify" do
    user = account()
    {:ok, _} = Memberships.grant(Ecto.UUID.generate(), user.id, :catalog_editor, admin())
    {:ok, actor} = Memberships.actor_for(user.__metadata__.token, :catalog_editor)

    for forged <- [
          %{actor | id: Ecto.UUID.generate()},
          %{actor | role: :operator},
          %{actor | membership_id: Ecto.UUID.generate()},
          %{actor | membership_id: "bad"},
          %{actor | membership_version: 2},
          %{actor | membership_version: nil},
          Map.from_struct(actor)
        ] do
      refute Memberships.current?(forged)
      assert {:error, _} = Catalog.record_source(source(), actor: forged)
    end
  end

  test "audit-reader grants give no catalog writes or generic operator authority" do
    user = account()
    {:ok, _} = Memberships.grant(Ecto.UUID.generate(), user.id, :operator, admin())
    {:ok, actor} = Memberships.actor_for(user.__metadata__.token, :operator)
    assert {:ok, []} = Ash.read(AuditEvent, actor: actor)
    assert {:error, _} = Catalog.record_source(source(), actor: actor)
    assert {:error, _} = Ash.read(Membership, actor: actor)

    assert {:error, :unauthorized} =
             Memberships.grant(Ecto.UUID.generate(), user.id, :catalog_editor, actor)
  end

  test "removed session token cannot resolve an otherwise active membership" do
    user = account()
    {:ok, _} = Memberships.grant(Ecto.UUID.generate(), user.id, :catalog_editor, admin())
    assert :ok = Authentication.revoke(user.__metadata__.token)

    assert {:error, :unauthorized} =
             Memberships.actor_for(user.__metadata__.token, :catalog_editor)
  end

  test "invalid provisioning and ordinary resource writes refuse without grants" do
    user = account()
    admin = admin()

    for {id, account_id, role} <- [
          {"bad", user.id, :catalog_editor},
          {Ecto.UUID.generate(), "bad", :catalog_editor},
          {Ecto.UUID.generate(), user.id, "catalog_editor"},
          {Ecto.UUID.generate(), user.id, :access_admin},
          {Ecto.UUID.generate(), user.id, :customer}
        ],
        do: assert({:error, :invalid_input} = Memberships.grant(id, account_id, role, admin))

    for actor <- [nil, %Actor{id: user.id, role: :catalog_editor}, Map.from_struct(admin), user] do
      assert {:error, _} =
               Ash.create(
                 Membership,
                 %{id: Ecto.UUID.generate(), user_id: user.id, role: :catalog_editor},
                 action: :grant,
                 actor: actor
               )
    end

    assert {:error, :conflict} =
             Memberships.grant(Ecto.UUID.generate(), Ecto.UUID.generate(), :catalog_editor, admin)

    assert Ash.Resource.Info.public_attributes(Membership) == []
    assert %{rows: [[0]]} = Repo.query!("SELECT count(*) FROM platform_memberships", [])
  end

  test "database constraints retain grant shape and account custody" do
    user = account()
    {:ok, grant} = Memberships.grant(Ecto.UUID.generate(), user.id, :catalog_editor, admin())

    for sql <- [
          "UPDATE platform_memberships SET version = 3 WHERE id = $1",
          "UPDATE platform_memberships SET role = 'access_admin' WHERE id = $1",
          "UPDATE platform_memberships SET version = 2 WHERE id = $1"
        ] do
      assert {:error, %Postgrex.Error{}} =
               Repo.query(sql, [Ecto.UUID.dump!(grant.id)], mode: :savepoint)
    end

    assert {:error, %Postgrex.Error{}} =
             Repo.query("DELETE FROM platform_users WHERE id = $1", [Ecto.UUID.dump!(user.id)],
               mode: :savepoint
             )
  end

  test "membership storage loss refuses lookup and every held-reference policy" do
    user = account()
    {:ok, _} = Memberships.grant(Ecto.UUID.generate(), user.id, :catalog_editor, admin())
    {:ok, actor} = Memberships.actor_for(user.__metadata__.token, :catalog_editor)
    Repo.query!("ALTER TABLE platform_memberships RENAME TO unavailable_memberships", [])

    assert {:error, :unavailable} =
             Memberships.actor_for(user.__metadata__.token, :catalog_editor)

    refute Memberships.current?(actor)
    assert {:error, _} = Catalog.record_source(source(), actor: actor)
    Repo.query!("ALTER TABLE unavailable_memberships RENAME TO platform_memberships", [])
    assert Memberships.current?(actor)
  end

  defp admin, do: %Actor{id: Ecto.UUID.generate(), role: :access_admin}

  defp persisted(grant),
    do: Map.take(grant, Enum.map(Ash.Resource.Info.attributes(Membership), & &1.name))

  defp account do
    password = "private membership fixture password"

    {:ok, user} =
      Authentication.register(%{
        email: "#{Ecto.UUID.generate()}@example.com",
        password: password,
        password_confirmation: password
      })

    user
  end

  defp source do
    %{
      title: "Membership fixture",
      uri: "https://example.com/#{Ecto.UUID.generate()}",
      revision: "fixture-1",
      content_sha256: String.duplicate("a", 64),
      kind: :custom,
      observed_at: DateTime.utc_now()
    }
  end
end
