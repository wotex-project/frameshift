defmodule Frameshift.Qualification.StoreTest do
  @moduledoc false

  use ExUnit.Case, async: true

  alias Frameshift.Digest
  alias Frameshift.Library
  alias Frameshift.Qualification.Profile

  @fixture Path.expand("../../../../../protocol/fixtures/valid/thing-description.json", __DIR__)
  @fingerprint "sha256:" <> String.duplicate("b", 64)
  @profile_id "urn:frameshift:profile:sim-rgb24-v1"

  setup do
    data_dir =
      Path.join(
        System.tmp_dir!(),
        "frameshift-qualification-test-#{System.unique_integer([:positive, :monotonic])}"
      )

    on_exit(fn -> File.rm_rf!(data_dir) end)
    {:ok, library} = Library.start_link(data_dir: data_dir, name: nil)

    {:ok, frame} =
      Library.register_paired_frame(
        library,
        File.read!(@fixture),
        "keychain:fixture",
        @fingerprint
      )

    %{library: library, data_dir: data_dir, frame: frame}
  end

  test "candidate cannot activate and admission is exact and durable", context do
    %{library: library, frame: frame, data_dir: data_dir} = context
    manifest = manifest(frame)
    evidence = evidence()

    assert {:ok, digest} = Library.register_qualification(library, manifest)
    assert {:ok, ^digest} = Library.register_qualification(library, manifest)
    assert :not_found = Library.active_qualification(library, frame["frame_id"])

    assert {:error, :qualification_not_admitted} =
             Library.activate_qualification(library, frame["frame_id"], digest)

    assert {:error, :invalid_qualification_evidence} =
             Library.admit_qualification(library, digest, %{evidence | "outcome" => "failed"})

    assert :ok = Library.admit_qualification(library, digest, evidence)
    assert :ok = Library.admit_qualification(library, digest, evidence)

    assert {:error, :qualification_evidence_conflict} =
             Library.admit_qualification(library, digest, %{
               evidence
               | "suiteDigest" => Digest.sha256("different suite")
             })

    assert :ok = Library.activate_qualification(library, frame["frame_id"], digest)
    assert :ok = Library.activate_qualification(library, frame["frame_id"], digest)

    assert {:ok, %{"digest" => ^digest, "status" => "admitted"}} =
             Library.active_qualification(library, frame["frame_id"])

    assert %{"entries" => audit} = Library.audit_page(library)
    assert Enum.count(audit, &(&1["operation"] == "qualification.candidate")) == 1
    assert Enum.count(audit, &(&1["operation"] == "qualification.admitted")) == 1
    assert Enum.count(audit, &(&1["operation"] == "qualification.activated")) == 1

    GenServer.stop(library)
    {:ok, restarted} = Library.start_link(data_dir: data_dir, name: nil)

    assert {:ok, %{"digest" => ^digest, "manifest" => ^manifest}} =
             Library.active_qualification(restarted, frame["frame_id"])

    GenServer.stop(restarted)
  end

  test "switch and rollback select only future work and retain candidate history", context do
    %{library: library, frame: frame} = context
    first = manifest(frame)
    second = %{first | "rendererBuildDigest" => Digest.sha256("renderer-v2")}

    {:ok, first_digest} = Library.register_qualification(library, first)
    {:ok, second_digest} = Library.register_qualification(library, second)
    assert first_digest != second_digest

    assert :ok = Library.admit_qualification(library, first_digest, evidence())
    assert :ok = Library.admit_qualification(library, second_digest, evidence())
    assert :ok = Library.activate_qualification(library, frame["frame_id"], first_digest)
    assert :ok = Library.activate_qualification(library, frame["frame_id"], second_digest)

    assert {:ok, %{"digest" => ^second_digest}} =
             Library.active_qualification(library, frame["frame_id"])

    assert :ok = Library.activate_qualification(library, frame["frame_id"], first_digest)

    assert {:ok, %{"digest" => ^first_digest}} =
             Library.active_qualification(library, frame["frame_id"])

    assert {:error, :qualification_frame_mismatch} =
             Library.register_qualification(library, %{
               first
               | "profileDigest" => Digest.sha256("mismatched profile")
             })

    assert {:error, :unsupported_qualification_contract} =
             Library.register_qualification(library, %{
               first
               | "connectorRevision" => "unimplemented-connector"
             })

    assert {:error, :qualification_not_admitted} =
             Library.activate_qualification(library, "another-frame", first_digest)

    GenServer.stop(library)
  end

  test "cohort promotion is all or nothing and survives restart", context do
    %{library: library, frame: first, data_dir: data_dir} = context

    second_td =
      @fixture
      |> File.read!()
      |> String.replace("sim-photo-00000001", "sim-photo-00000002")

    {:ok, second} =
      Library.register_paired_frame(
        library,
        second_td,
        "keychain:second",
        "sha256:" <> String.duplicate("c", 64)
      )

    first_id = first["frame_id"]
    second_id = second["frame_id"]
    {:ok, first_old} = Library.register_qualification(library, manifest(first))
    {:ok, second_old} = Library.register_qualification(library, manifest(second))
    :ok = Library.admit_qualification(library, first_old, evidence())
    :ok = Library.admit_qualification(library, second_old, evidence())
    :ok = Library.activate_qualification(library, first_id, first_old)
    :ok = Library.activate_qualification(library, second_id, second_old)

    {:ok, master} = Library.import_master(library, "cohort source", master_attributes())

    {:ok, recipe_digest} =
      Library.register_recipe(library, :composition, composition(manifest(first)), [
        master["digest"]
      ])

    {:ok, accepted_work} =
      Library.accept_qualified_work(
        library,
        first_id,
        first_old,
        master["digest"],
        recipe_digest
      )

    upgraded = fn frame ->
      %{manifest(frame) | "rendererBuildDigest" => Digest.sha256("renderer-v2")}
    end

    {:ok, first_new} = Library.register_qualification(library, upgraded.(first))
    {:ok, second_new} = Library.register_qualification(library, upgraded.(second))
    :ok = Library.admit_qualification(library, first_new, evidence())
    selections = [{first_id, first_new}, {second_id, second_new}]

    assert %{"entries" => before_failed_promotion} = Library.audit_page(library)

    assert {:error, :qualification_not_admitted} =
             Library.activate_qualification_cohort(library, selections)

    assert {:ok, %{"digest" => ^first_old}} = Library.active_qualification(library, first_id)
    assert {:ok, %{"digest" => ^second_old}} = Library.active_qualification(library, second_id)
    assert %{"entries" => ^before_failed_promotion} = Library.audit_page(library)

    assert {:error, :duplicate_qualification_frame} =
             Library.activate_qualification_cohort(library, [
               {first_id, first_new},
               {first_id, first_old}
             ])

    assert {:error, :qualification_frame_mismatch} =
             Library.activate_qualification_cohort(library, [{second_id, first_new}])

    assert {:error, :invalid_qualification_cohort} =
             Library.activate_qualification_cohort(library, [])

    :ok = Library.admit_qualification(library, second_new, evidence())
    assert :ok = Library.activate_qualification_cohort(library, selections)
    assert :ok = Library.activate_qualification_cohort(library, selections)
    assert {:ok, %{"digest" => ^first_new}} = Library.active_qualification(library, first_id)
    assert {:ok, %{"digest" => ^second_new}} = Library.active_qualification(library, second_id)

    assert {:ok, %{"binding_digest" => ^first_old}} =
             Library.get_qualified_work(library, accepted_work)

    assert %{"entries" => audit} = Library.audit_page(library)
    assert Enum.count(audit, &(&1["operation"] == "qualification.activated")) == 4

    {:ok, injector} =
      Exqlite.start_link(database: Path.join(data_dir, "metadata.sqlite"), foreign_keys: :on)

    Exqlite.query!(
      injector,
      """
      CREATE TRIGGER fail_second_cohort_activation BEFORE UPDATE ON active_qualifications
      WHEN NEW.frame_id = 'sim-photo-00000002'
      BEGIN SELECT RAISE(ABORT, 'injected cohort failure'); END
      """
    )

    assert {:error, {:database, "injected cohort failure"}} =
             Library.activate_qualification_cohort(library, [
               {first_id, first_old},
               {second_id, second_old}
             ])

    assert Process.alive?(library)
    assert {:ok, %{"digest" => ^first_new}} = Library.active_qualification(library, first_id)
    assert {:ok, %{"digest" => ^second_new}} = Library.active_qualification(library, second_id)
    assert %{"entries" => ^audit} = Library.audit_page(library)

    Exqlite.query!(injector, "DROP TRIGGER fail_second_cohort_activation")
    GenServer.stop(injector)

    assert :ok =
             Library.activate_qualification_cohort(library, [
               {first_id, first_old},
               {second_id, second_old}
             ])

    assert :ok = Library.activate_qualification_cohort(library, selections)

    GenServer.stop(library)
    {:ok, restarted} = Library.start_link(data_dir: data_dir, name: nil)
    assert {:ok, %{"digest" => ^first_new}} = Library.active_qualification(restarted, first_id)
    assert {:ok, %{"digest" => ^second_new}} = Library.active_qualification(restarted, second_id)

    assert {:ok, %{"binding_digest" => ^first_old}} =
             Library.get_qualified_work(restarted, accepted_work)

    GenServer.stop(restarted)
  end

  test "qualification decisions emit bounded success and refusal telemetry", context do
    %{library: library, frame: frame} = context
    handler_id = "qualification-test-#{System.unique_integer([:positive])}"

    :ok =
      :telemetry.attach(
        handler_id,
        [:frameshift, :qualification, :decision],
        &__MODULE__.capture_qualification_event/4,
        {library, self()}
      )

    on_exit(fn -> :telemetry.detach(handler_id) end)

    assert {:error, :invalid_qualification_cohort} =
             Library.activate_qualification_cohort(library, [])

    assert_receive {%{count: 1}, %{stage: :cohort, outcome: :refused}}

    assert {:ok, digest} = Library.register_qualification(library, manifest(frame))
    assert_receive {%{count: 1}, %{stage: :candidate, outcome: :succeeded}}

    assert {:error, :qualification_not_admitted} =
             Library.activate_qualification(library, frame["frame_id"], digest)

    assert_receive {%{count: 1}, %{stage: :activation, outcome: :refused}}
    GenServer.stop(library)
  end

  test "forgetting frame clears active selection and blocks stale reactivation", context do
    %{library: library, frame: frame} = context
    {:ok, digest} = Library.register_qualification(library, manifest(frame))
    :ok = Library.admit_qualification(library, digest, evidence())
    :ok = Library.activate_qualification(library, frame["frame_id"], digest)

    assert :ok = Library.forget_paired_frame(library, frame["frame_id"])
    assert :not_found = Library.active_qualification(library, frame["frame_id"])

    assert {:error, :frame_not_paired} =
             Library.activate_qualification(library, frame["frame_id"], digest)

    GenServer.stop(library)
  end

  test "accepted work and result survive a binding switch and restart", context do
    %{library: library, frame: frame, data_dir: data_dir} = context
    first = manifest(frame)
    {:ok, first_digest} = Library.register_qualification(library, first)
    :ok = Library.admit_qualification(library, first_digest, evidence())
    :ok = Library.activate_qualification(library, frame["frame_id"], first_digest)

    {:ok, master} = Library.import_master(library, "source", master_attributes())
    recipe = composition(first)

    {:ok, recipe_digest} =
      Library.register_recipe(library, :composition, recipe, [master["digest"]])

    {:ok, injector} =
      Exqlite.start_link(database: Path.join(data_dir, "metadata.sqlite"), foreign_keys: :on)

    Exqlite.query!(
      injector,
      """
      CREATE TRIGGER fail_qualified_work BEFORE INSERT ON qualified_work
      BEGIN SELECT RAISE(ABORT, 'injected work failure'); END
      """
    )

    assert {:error, {:database, "injected work failure"}} =
             Library.accept_qualified_work(
               library,
               frame["frame_id"],
               first_digest,
               master["digest"],
               recipe_digest
             )

    assert Process.alive?(library)
    Exqlite.query!(injector, "DROP TRIGGER fail_qualified_work")
    GenServer.stop(injector)

    assert {:ok, work_digest} =
             Library.accept_qualified_work(
               library,
               frame["frame_id"],
               first_digest,
               master["digest"],
               recipe_digest
             )

    assert {:ok, ^work_digest} =
             Library.accept_qualified_work(
               library,
               frame["frame_id"],
               first_digest,
               master["digest"],
               recipe_digest
             )

    second = %{first | "rendererBuildDigest" => Digest.sha256("renderer-v2")}
    {:ok, second_digest} = Library.register_qualification(library, second)
    :ok = Library.admit_qualification(library, second_digest, evidence())
    :ok = Library.activate_qualification(library, frame["frame_id"], second_digest)

    assert {:error, :qualification_changed} =
             Library.accept_qualified_work(
               library,
               frame["frame_id"],
               first_digest,
               master["digest"],
               recipe_digest
             )

    assert {:ok, artifact} =
             Library.register_artifact(library, "wire bytes", %{
               master_digest: master["digest"],
               recipe_hash: recipe_digest,
               profile_id: @profile_id,
               renderer_revision: first["rendererAlgorithmRevision"],
               media_type: "application/vnd.frameshift.rgb24"
             })

    assert {:ok, result_digest} =
             Library.record_qualified_result(library, work_digest, artifact["digest"])

    assert {:ok, ^result_digest} =
             Library.record_qualified_result(library, work_digest, artifact["digest"])

    assert {:ok, %{"binding_digest" => ^first_digest}} =
             Library.get_qualified_work(library, work_digest)

    assert {:ok, %{"artifact_digest" => artifact_digest}} =
             Library.qualified_result(library, work_digest)

    assert artifact_digest == artifact["digest"]
    GenServer.stop(library)

    {:ok, restarted} = Library.start_link(data_dir: data_dir, name: nil)

    assert {:ok, %{"digest" => ^second_digest}} =
             Library.active_qualification(restarted, frame["frame_id"])

    assert {:ok, %{"binding_digest" => ^first_digest}} =
             Library.get_qualified_work(restarted, work_digest)

    assert {:ok, %{"digest" => ^result_digest}} =
             Library.qualified_result(restarted, work_digest)

    GenServer.stop(restarted)
  end

  test "work refuses mismatched recipe inputs and unknown results", context do
    %{library: library, frame: frame} = context
    binding = manifest(frame)
    {:ok, binding_digest} = Library.register_qualification(library, binding)
    :ok = Library.admit_qualification(library, binding_digest, evidence())
    :ok = Library.activate_qualification(library, frame["frame_id"], binding_digest)
    {:ok, master} = Library.import_master(library, "source", master_attributes())

    mismatched = %{composition(binding) | "rendererBuildDigest" => Digest.sha256("other")}

    {:ok, recipe_digest} =
      Library.register_recipe(library, :composition, mismatched, [master["digest"]])

    assert {:error, :qualification_recipe_mismatch} =
             Library.accept_qualified_work(
               library,
               frame["frame_id"],
               binding_digest,
               master["digest"],
               recipe_digest
             )

    assert {:error, :qualified_work_missing} =
             Library.record_qualified_result(
               library,
               Digest.sha256("missing work"),
               Digest.sha256("a")
             )

    GenServer.stop(library)
  end

  test "pull intent and last-good reference retain their accepted work across restart", context do
    %{library: library, frame: frame, data_dir: data_dir} = context

    %{binding_digest: binding, work_digest: work, artifact_digest: artifact} =
      qualified_artifact(library, frame, "pull")

    assert {:error, :qualification_intent_mismatch} =
             Library.queue_outbox(
               library,
               frame["frame_id"],
               artifact,
               @profile_id,
               nil,
               nil,
               Digest.sha256("other work")
             )

    assert {:ok, manifest} =
             Library.queue_outbox(
               library,
               frame["frame_id"],
               artifact,
               @profile_id,
               nil,
               nil,
               work
             )

    assert %{"queued" => [%{"work_digest" => ^work, "qualification_digest" => ^binding}]} =
             Library.delivery_custody(library, frame["frame_id"])

    GenServer.stop(library)
    {:ok, restarted} = Library.start_link(data_dir: data_dir, name: nil)

    assert %{"queued" => [%{"work_digest" => ^work}]} =
             Library.delivery_custody(restarted, frame["frame_id"])

    assert :ok =
             Library.acknowledge_outbox(restarted, frame["frame_id"], %{
               "manifestRevision" => manifest["revision"],
               "storage" => "verified",
               "refresh" => "displayed",
               "currentAsset" => artifact,
               "lastError" => nil
             })

    assert %{"current" => [%{"work_digest" => ^work, "qualification_digest" => ^binding}]} =
             Library.delivery_custody(restarted, frame["frame_id"])

    assert {:error, :qualification_required} =
             Library.queue_outbox(restarted, frame["frame_id"], artifact, @profile_id)

    assert :empty = Library.outbox_manifest(restarted, frame["frame_id"])

    assert %{"current" => [%{"work_digest" => ^work}]} =
             Library.delivery_custody(restarted, frame["frame_id"])

    GenServer.stop(restarted)
  end

  test "legacy queued work can finish after qualification activates", context do
    %{library: library, frame: frame, data_dir: data_dir} = context
    binding = manifest(frame, "pull")
    artifact = legacy_artifact(library, binding)

    assert {:ok, queued} =
             Library.queue_outbox(library, frame["frame_id"], artifact, @profile_id)

    assert %{"queued" => [%{"status" => "legacy_unqualified"}]} =
             Library.delivery_custody(library, frame["frame_id"])

    {:ok, binding_digest} = Library.register_qualification(library, binding)
    :ok = Library.admit_qualification(library, binding_digest, evidence())
    :ok = Library.activate_qualification(library, frame["frame_id"], binding_digest)

    assert {:error, :qualification_required} =
             Library.queue_outbox(library, frame["frame_id"], artifact, @profile_id)

    GenServer.stop(library)
    {:ok, restarted} = Library.start_link(data_dir: data_dir, name: nil)
    assert {:ok, ^queued} = Library.outbox_manifest(restarted, frame["frame_id"])

    assert :ok =
             Library.acknowledge_outbox(restarted, frame["frame_id"], %{
               "manifestRevision" => queued["revision"],
               "storage" => "verified",
               "refresh" => "displayed",
               "currentAsset" => artifact,
               "lastError" => nil
             })

    assert %{"current" => [%{"status" => "legacy_unqualified"}]} =
             Library.delivery_custody(restarted, frame["frame_id"])

    GenServer.stop(restarted)
  end

  test "legacy pending push can be replayed and confirmed after qualification activates",
       context do
    %{library: library, frame: frame, data_dir: data_dir} = context
    binding = manifest(frame)
    artifact = legacy_artifact(library, binding)
    frame_id = frame["frame_id"]

    assert {:ok, intent} =
             Library.begin_direct_delivery(
               library,
               frame_id,
               artifact,
               @profile_id,
               "legacy-push"
             )

    {:ok, binding_digest} = Library.register_qualification(library, binding)
    :ok = Library.admit_qualification(library, binding_digest, evidence())
    :ok = Library.activate_qualification(library, frame_id, binding_digest)

    assert {:ok, ^intent} =
             Library.begin_direct_delivery(
               library,
               frame_id,
               artifact,
               @profile_id,
               "legacy-push"
             )

    assert {:error, :qualification_required} =
             Library.begin_direct_delivery(library, frame_id, artifact, @profile_id, "new-push")

    GenServer.stop(library)
    {:ok, restarted} = Library.start_link(data_dir: data_dir, name: nil)

    assert {:ok, ^intent} =
             Library.begin_direct_delivery(
               restarted,
               frame_id,
               artifact,
               @profile_id,
               "legacy-push"
             )

    assert :ok =
             Library.finish_direct_delivery(
               restarted,
               frame_id,
               intent["revision"],
               "legacy-push",
               artifact,
               :displayed
             )

    assert %{"current" => [%{"status" => "legacy_unqualified"}]} =
             Library.delivery_custody(restarted, frame_id)

    GenServer.stop(restarted)
  end

  test "restart retains pending legacy outbox custody", context do
    %{library: library, frame: frame, data_dir: data_dir} = context
    artifact = legacy_artifact(library, manifest(frame, "pull"))
    frame_id = frame["frame_id"]
    {:ok, queued} = Library.queue_outbox(library, frame_id, artifact, @profile_id)
    GenServer.stop(library)

    {:ok, restarted} = Library.start_link(data_dir: data_dir, name: nil)
    assert {:ok, ^queued} = Library.outbox_manifest(restarted, frame_id)

    assert %{"queued" => [%{"status" => "legacy_unqualified"}]} =
             Library.delivery_custody(restarted, frame_id)

    assert :ok =
             Library.acknowledge_outbox(restarted, frame_id, %{
               "manifestRevision" => queued["revision"],
               "storage" => "verified",
               "refresh" => "displayed",
               "currentAsset" => artifact,
               "lastError" => nil
             })

    assert %{"current" => [%{"status" => "legacy_unqualified"}]} =
             Library.delivery_custody(restarted, frame_id)

    GenServer.stop(restarted)
  end

  test "push pending and confirmation retain exact work after active switch", context do
    %{library: library, frame: frame} = context

    %{binding_digest: binding, work_digest: work, artifact_digest: artifact} =
      qualified_artifact(library, frame, "push")

    assert {:ok, intent} =
             Library.begin_direct_delivery(
               library,
               frame["frame_id"],
               artifact,
               @profile_id,
               "push-1",
               work
             )

    assert intent["work_digest"] == work
    assert intent["qualification_digest"] == binding

    assert {:error, :qualification_required} =
             Library.begin_direct_delivery(
               library,
               frame["frame_id"],
               artifact,
               @profile_id,
               "push-1"
             )

    assert {:error, :unsupported_profile} =
             Library.begin_direct_delivery(
               library,
               frame["frame_id"],
               artifact,
               "wrong-profile",
               "push-2",
               work
             )

    first = manifest(frame)
    second = %{first | "rendererBuildDigest" => Digest.sha256("new renderer")}
    {:ok, second_digest} = Library.register_qualification(library, second)
    :ok = Library.admit_qualification(library, second_digest, evidence())
    :ok = Library.activate_qualification(library, frame["frame_id"], second_digest)

    assert :ok =
             Library.finish_direct_delivery(
               library,
               frame["frame_id"],
               intent["revision"],
               "push-1",
               artifact,
               :displayed
             )

    assert %{"current" => [%{"work_digest" => ^work, "qualification_digest" => ^binding}]} =
             Library.delivery_custody(library, frame["frame_id"])

    GenServer.stop(library)
  end

  defp manifest(frame, mode \\ "push") do
    {:ok, profile_digest} = Profile.digest(frame["capabilities"], @profile_id)
    connector = if mode == "push", do: "wotex-http-v0.1", else: "frameshift-outbox-v0.1"
    {:ok, binding_digest} = Profile.binding_digest(frame["td_json"], mode, connector)

    %{
      "schemaVersion" => 1,
      "frameId" => frame["frame_id"],
      "thingDescriptionDigest" => Digest.sha256(frame["td_json"]),
      "profileId" => @profile_id,
      "profileDigest" => profile_digest,
      "rendererBuildDigest" => Digest.sha256("renderer-v1"),
      "rendererProtocolRevision" => "fsr1",
      "rendererAlgorithmRevision" => "frameshift-raster-v0.1",
      "bindingDigest" => binding_digest,
      "connectorRevision" => connector,
      "effectClass" => "physical_display",
      "transferMode" => mode
    }
  end

  defp evidence do
    %{
      "schemaVersion" => 1,
      "scope" => "software_reference",
      "outcome" => "passed",
      "suiteDigest" => Digest.sha256("fixture suite")
    }
  end

  defp composition(binding) do
    %{
      "profileId" => binding["profileId"],
      "rendererRevision" => binding["rendererAlgorithmRevision"],
      "rendererBuildDigest" => binding["rendererBuildDigest"],
      "targetWidth" => 1920,
      "targetHeight" => 1080
    }
  end

  defp master_attributes do
    %{
      title: "Qualification source",
      source_kind: :import,
      width: 1920,
      height: 1080,
      media_type: "image/png",
      provenance: %{"kind" => "test"}
    }
  end

  defp qualified_artifact(library, frame, mode) do
    binding = manifest(frame, mode)
    {:ok, binding_digest} = Library.register_qualification(library, binding)
    :ok = Library.admit_qualification(library, binding_digest, evidence())
    :ok = Library.activate_qualification(library, frame["frame_id"], binding_digest)

    {:ok, master} = Library.import_master(library, "qualified source", master_attributes())

    {:ok, recipe_digest} =
      Library.register_recipe(library, :composition, composition(binding), [master["digest"]])

    {:ok, work_digest} =
      Library.accept_qualified_work(
        library,
        frame["frame_id"],
        binding_digest,
        master["digest"],
        recipe_digest
      )

    {:ok, artifact} =
      Library.register_artifact(library, "qualified wire", %{
        master_digest: master["digest"],
        recipe_hash: recipe_digest,
        profile_id: @profile_id,
        renderer_revision: binding["rendererAlgorithmRevision"],
        media_type: "application/vnd.frameshift.rgb24"
      })

    {:ok, _} = Library.record_qualified_result(library, work_digest, artifact["digest"])

    %{
      binding_digest: binding_digest,
      work_digest: work_digest,
      artifact_digest: artifact["digest"]
    }
  end

  defp legacy_artifact(library, binding) do
    {:ok, master} = Library.import_master(library, "legacy source", master_attributes())

    {:ok, recipe_digest} =
      Library.register_recipe(library, :composition, composition(binding), [master["digest"]])

    {:ok, artifact} =
      Library.register_artifact(library, "legacy wire", %{
        master_digest: master["digest"],
        recipe_hash: recipe_digest,
        profile_id: @profile_id,
        renderer_revision: binding["rendererAlgorithmRevision"],
        media_type: "application/vnd.frameshift.rgb24"
      })

    artifact["digest"]
  end

  @doc false
  @spec capture_qualification_event(term(), map(), map(), {pid(), pid()}) :: :ok
  def capture_qualification_event(_, measurements, metadata, {emitter, observer}) do
    if self() == emitter, do: send(observer, {measurements, metadata})
    :ok
  end
end
