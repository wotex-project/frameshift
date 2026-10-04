defmodule FrameshiftPlatform.OrchestrationTest do
  @moduledoc false

  use FrameshiftPlatform.DataCase, async: false
  alias FrameshiftPlatform.Orchestration
  alias FrameshiftPlatform.Repo
  alias Refpath.BootConfig
  alias Refpath.BootConfig.Contract

  test "the host contract has one owner and no public runtime or implicit diagnostics" do
    contract = Orchestration.contract()
    assert {:ok, ^contract} = Contract.validate(contract)
    assert {:ok, manifest} = Contract.conformance_manifest(contract)
    assert manifest.repo_mode == :durable
    boot_config = Contract.to_boot_config(contract)
    assert boot_config.settings.deployment_mode == :embedded
    assert boot_config.settings.hosting_mode == :self_hosted
    assert Enum.all?(manifest.features, fn {_, enabled} -> enabled == false end)
    assert contract.settings.beamlens_enabled == false
    assert contract.settings.skip_pubsub == true
    assert contract.repo == Repo

    lock = File.read!("mix.lock")
    assert lock =~ Orchestration.revision()
  end

  test "embedded runtime uses host pool, runtime schema and no duplicate services" do
    host_repo = Process.whereis(Repo)
    host_pubsub = Process.whereis(FrameshiftPlatform.PubSub)
    on_exit(fn -> BootConfig.erase() end)
    runtime = start_supervised!(Contract.child_spec(Orchestration.contract()))
    assert runtime == Process.whereis(Refpath.Supervisor)
    assert Process.whereis(Repo) == host_repo
    assert Process.whereis(FrameshiftPlatform.PubSub) == host_pubsub
    assert Process.whereis(Refpath.Repo) == nil
    assert Process.whereis(Beamlens.Supervisor) == nil
    assert Refpath.Repo.get_dynamic_repo() == Repo
    assert {:ok, %{status: :ready}} = Orchestration.readiness()

    assert {:ok, []} =
             Refpath.Trace.Analytics.QueryAdapter.query("SELECT * FROM skill_events", [])

    first = upsert_fixture("First revision")
    updated = upsert_fixture("Second revision")
    assert first.id == updated.id
    assert updated.body == "Second revision"

    assert %{rows: [["public"]]} =
             Ecto.Adapters.SQL.query!(
               Repo,
               "SELECT table_schema FROM information_schema.tables WHERE table_name = 'catalog_source_documents'"
             )

    assert {:ok, %{results: []}} = FrameshiftPlatform.Catalog.list_sources()

    assert {:error, {:already_started, ^runtime}} =
             Refpath.Supervisor.start_link(Contract.to_boot_config(Orchestration.contract()))
  end

  test "runtime readiness refuses an absent supervisor" do
    assert {:ok, %{status: :not_ready, subsystems: systems}} = Orchestration.readiness()
    assert Enum.any?(systems, &(&1.reason == :supervisor_not_running))
  end

  defp upsert_fixture(body) do
    Refpath.Definitions.Instruction
    |> Ash.Changeset.for_create(:upsert, %{
      category: :context,
      name: "frameshift-host-pool-test",
      body: body
    })
    |> Ash.create!(authorize?: false)
  end
end
