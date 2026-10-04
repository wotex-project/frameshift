defmodule Frameshift.RenderPipelineTest do
  @moduledoc false

  use ExUnit.Case, async: false

  alias Frameshift.Digest
  alias Frameshift.DirectDelivery
  alias Frameshift.Library
  alias Frameshift.LocalAPI
  alias Frameshift.MasterPackage
  alias Frameshift.Qualification.Profile
  alias Frameshift.Renderer
  alias Frameshift.RenderPipeline
  alias Frameshift.Simulator
  alias Frameshift.Transport.CredentialResolver
  alias Frameshift.Transport.KeychainBroker

  @frame_id "sim-pipeline-0001"
  @profile_id "urn:frameshift:test:rgb24-v1"
  @original <<137, "PNG\r\n", 26, 10, 1, 2, 3>>
  @rgba <<1, 2, 3, 255, 4, 5, 6, 255>>
  @rgb <<1, 2, 3, 4, 5, 6>>
  @renderer_dir Path.expand("../../../../renderer", __DIR__)
  @renderer_path Path.join(@renderer_dir, "zig-out/bin/frameshift-raster")
  @thing_fixture Path.expand(
                   "../../../../protocol/fixtures/valid/thing-description.json",
                   __DIR__
                 )

  defmodule StaticCredentialResolver do
    @moduledoc false

    @behaviour CredentialResolver

    @impl CredentialResolver
    def resolve(reference, %{owner: owner}) do
      send(owner, {:credential_reference, reference})
      {:ok, %{certificate: <<1, 2, 3>>, private_key: {:rsa, <<4, 5, 6>>}}}
    end
  end

  defmodule ConfirmedSynchronizer do
    @moduledoc false

    @spec sync(term(), term(), term(), term(), term()) :: {:ok, map()}
    def sync(td, artifact, credential, _, context) do
      send(self(), {:direct_delivery, td, artifact, credential, context})
      {:ok, %{outcome: :displayed}}
    end
  end

  defmodule TimedOutSynchronizer do
    @moduledoc false

    @spec sync(term(), term(), term(), term(), term()) :: {:error, {:transport, :timeout}}
    def sync(_, _, _, _, _),
      do: {:error, {:transport, :timeout}}
  end

  setup_all do
    {output, status} =
      System.cmd("zig", ["build", "-Doptimize=ReleaseSafe"],
        cd: @renderer_dir,
        stderr_to_stdout: true
      )

    assert status == 0, output
    :ok
  end

  setup do
    root =
      Path.join(
        System.tmp_dir!(),
        "frameshift-pipeline-test-#{System.unique_integer([:positive, :monotonic])}"
      )

    on_exit(fn -> File.rm_rf!(root) end)
    {:ok, library} = Library.start_link(data_dir: Path.join(root, "library"), name: nil)
    {:ok, renderer} = Renderer.start_link(path: @renderer_path, name: nil)

    {:ok, simulator} =
      Simulator.start_link(
        data_dir: Path.join(root, "simulator"),
        capabilities: capabilities(),
        name: nil
      )

    on_exit(fn ->
      Enum.each([library, renderer, simulator], &stop_if_alive/1)
    end)

    %{
      library: library,
      library_dir: Path.join(root, "library"),
      renderer: renderer,
      simulator: simulator
    }
  end

  test "a queued core command renders, caches, and converges through a universal target",
       context do
    {:ok, package} = MasterPackage.encode(@original, @rgba, 2, 1)
    {:ok, master} = Library.import_master(context.library, package, master_attributes())

    assert {:ok, _} =
             Library.register_paired_frame(
               context.library,
               thing_description(),
               "keychain:pipeline-frame",
               "sha256:" <> String.duplicate("d", 64)
             )

    command = %{
      "kind" => "queue",
      "targetID" => @frame_id,
      "itemID" => master["digest"]
    }

    assert {:ok, queued} =
             LocalAPI.execute_with_renderer(context.library, context.renderer, command)

    assert [%{"queuedTargetID" => @frame_id}] = queued["items"]

    assert {:ok, manifest} = Library.outbox_manifest(context.library, @frame_id)
    assert manifest["desiredAsset"] == Digest.sha256(@rgb)
    assert manifest["artifactProfile"] == @profile_id

    assert {:ok, %{"bytes" => @rgb}} =
             Library.read_object(context.library, manifest["desiredAsset"])

    GenServer.stop(context.renderer)

    assert {:ok, _} =
             LocalAPI.execute_with_renderer(context.library, context.renderer, command)

    assert {:ok, repeated_manifest} = Library.outbox_manifest(context.library, @frame_id)
    assert repeated_manifest["desiredAsset"] == manifest["desiredAsset"]
    assert repeated_manifest["revision"] == manifest["revision"] + 1

    assert {:ok, acknowledgement} =
             Simulator.pull_outbox(context.simulator, repeated_manifest, @rgb)

    assert acknowledgement["refresh"] == "displayed"
    assert acknowledgement["currentAsset"] == manifest["desiredAsset"]
    assert :ok = Library.acknowledge_outbox(context.library, @frame_id, acknowledgement)
  end

  test "an explicit pinned-loop command renders a still and queues a durable playlist", context do
    {:ok, package} = MasterPackage.encode(@original, @rgba, 2, 1)
    {:ok, master} = Library.import_master(context.library, package, master_attributes())
    :ok = Library.pin(context.library, master["digest"])
    other_rgba = <<10, 20, 30, 255, 40, 50, 60, 255>>
    {:ok, other_package} = MasterPackage.encode(@original <> "-other", other_rgba, 2, 1)

    {:ok, other} =
      Library.import_master(context.library, other_package, %{
        master_attributes()
        | title: "Second canonical fixture"
      })

    :ok = Library.pin(context.library, other["digest"])

    assert {:ok, _} =
             Library.register_paired_frame(
               context.library,
               thing_description(),
               "keychain:pipeline-frame",
               "sha256:" <> String.duplicate("d", 64)
             )

    command = %{
      "id" => "pinned-loop-test",
      "kind" => "loopPinned",
      "targetID" => @frame_id,
      "dwellMs" => 1_000
    }

    assert {:ok, snapshot} =
             LocalAPI.execute_with_renderer(context.library, context.renderer, command)

    assert [%{"playlist" => %{"status" => "pending", "entryCount" => 2}}] = snapshot["targets"]
    assert Enum.all?(snapshot["items"], &(&1["loopStatus"] == "pending"))
    assert {:ok, manifest} = Library.outbox_manifest(context.library, @frame_id)
    assert is_binary(manifest["playlistRevision"])

    assert {:ok, body} =
             Library.outbox_playlist(context.library, @frame_id, manifest["playlistRevision"])

    {:ok, document} = RFC8785.decode(body)

    assert MapSet.new(document["entries"]) ==
             MapSet.new([
               %{"assetDigest" => Digest.sha256(@rgb), "dwellMs" => 1_000},
               %{"assetDigest" => Digest.sha256(<<10, 20, 30, 40, 50, 60>>), "dwellMs" => 1_000}
             ])
  end

  test "a missing interval fails before pinned artwork is rendered", context do
    {:ok, package} = MasterPackage.encode(@original, @rgba, 2, 1)
    {:ok, master} = Library.import_master(context.library, package, master_attributes())
    :ok = Library.pin(context.library, master["digest"])

    assert {:ok, _} =
             Library.register_paired_frame(
               context.library,
               thing_description(),
               "keychain:pipeline-frame",
               "sha256:" <> String.duplicate("d", 64)
             )

    GenServer.stop(context.renderer)

    assert {:error, :interval_required} =
             LocalAPI.execute_with_renderer(context.library, context.renderer, %{
               "kind" => "loopPinned",
               "targetID" => @frame_id
             })

    assert :empty = Library.outbox_manifest(context.library, @frame_id)
  end

  test "ordered artwork resumes its exact saved body after pin changes and host restart",
       context do
    {:ok, package} = MasterPackage.encode(@original, @rgba, 2, 1)
    {:ok, first} = Library.import_master(context.library, package, master_attributes())

    {:ok, other_package} =
      MasterPackage.encode(@original <> "-other", <<10, 20, 30, 255, 40, 50, 60, 255>>, 2, 1)

    {:ok, second} =
      Library.import_master(context.library, other_package, %{
        master_attributes()
        | title: "Second fixture"
      })

    {:ok, _} =
      Library.register_paired_frame(
        context.library,
        thing_description(),
        "keychain:ordered-loop",
        "sha256:" <> String.duplicate("d", 64)
      )

    ids = [second["digest"], first["digest"]]

    command = %{
      "id" => "ordered-set",
      "kind" => "loopArtwork",
      "targetID" => @frame_id,
      "itemIDs" => ids,
      "dwellMs" => 1_501
    }

    assert {:ok, snapshot} =
             LocalAPI.execute_with_renderer(context.library, context.renderer, command)

    [target] = snapshot["targets"]
    assert Enum.map(target["playlist"]["items"], & &1["id"]) == ids
    assert target["loopInterval"]["requestedDwellMs"] == 1_501
    assert target["loopInterval"]["appliedDwellMs"] == 1_501
    assert target["loopInterval"]["requiresReview"] == false
    {:ok, initial} = Library.outbox_manifest(context.library, @frame_id)
    revision = initial["playlistRevision"]
    {:ok, body} = Library.outbox_playlist(context.library, @frame_id, revision)
    playlist = Jason.decode!(body)

    assert Enum.map(playlist["entries"], & &1["assetDigest"]) == [
             Digest.sha256(<<10, 20, 30, 40, 50, 60>>),
             Digest.sha256(@rgb)
           ]

    assert :ok = Library.acknowledge_outbox(context.library, @frame_id, displayed_ack(initial))

    assert {:ok, _} =
             LocalAPI.execute_with_renderer(context.library, context.renderer, %{
               "kind" => "queue",
               "targetID" => @frame_id,
               "itemID" => first["digest"]
             })

    {:ok, single} = Library.outbox_manifest(context.library, @frame_id)
    assert :ok = Library.acknowledge_outbox(context.library, @frame_id, displayed_ack(single))
    :ok = Library.pin(context.library, first["digest"])
    :ok = Library.remove_master(context.library, second["digest"])
    GenServer.stop(context.library)
    GenServer.stop(context.renderer)
    {:ok, restarted} = Library.start_link(data_dir: context.library_dir, name: nil)
    on_exit(fn -> stop_if_alive(restarted) end)

    assert {:ok, resumed} =
             LocalAPI.execute(restarted, %{
               "id" => "resume-saved-set",
               "kind" => "resumePlaylist",
               "targetID" => @frame_id,
               "playlistRevision" => revision
             })

    assert hd(resumed["targets"])["playlist"]["status"] == "pending"
    assert {:ok, manifest} = Library.outbox_manifest(restarted, @frame_id)
    assert manifest["revision"] > single["revision"]
    assert manifest["playlistRevision"] == revision
    assert {:ok, ^body} = Library.outbox_playlist(restarted, @frame_id, revision)
    assert Enum.map(hd(resumed["targets"])["playlist"]["items"], & &1["id"]) == ids
    assert {:ok, []} = Library.collect_removed(restarted)
  end

  test "invalid or removed ordered masters fail before rendering and preserve pending intent",
       context do
    {:ok, package} = MasterPackage.encode(@original, @rgba, 2, 1)
    {:ok, master} = Library.import_master(context.library, package, master_attributes())

    {:ok, _} =
      Library.register_paired_frame(
        context.library,
        thing_description(),
        "keychain:ordered-loop",
        "sha256:" <> String.duplicate("d", 64)
      )

    command = %{
      "kind" => "loopArtwork",
      "targetID" => @frame_id,
      "itemIDs" => [master["digest"]],
      "dwellMs" => 1
    }

    assert {:ok, _} = LocalAPI.execute_with_renderer(context.library, context.renderer, command)
    {:ok, manifest} = Library.outbox_manifest(context.library, @frame_id)

    assert %{"requestedDwellMs" => 1, "appliedDwellMs" => 1_000} =
             Library.frame_playlist_interval(context.library, @frame_id)

    GenServer.stop(context.renderer)

    for ids <- [
          [],
          [master["digest"], master["digest"]],
          ["bad"],
          List.duplicate(master["digest"], 65)
        ] do
      assert {:error, :invalid_command} =
               LocalAPI.execute_with_renderer(
                 context.library,
                 context.renderer,
                 Map.put(command, "itemIDs", ids)
               )
    end

    assert {:error, :invalid_interval} =
             LocalAPI.execute_with_renderer(
               context.library,
               context.renderer,
               Map.put(command, "dwellMs", 31_536_000_001)
             )

    :ok = Library.remove_master(context.library, master["digest"])

    assert {:error, :item_not_found} =
             LocalAPI.execute_with_renderer(context.library, context.renderer, command)

    assert {:ok, ^manifest} = Library.outbox_manifest(context.library, @frame_id)
  end

  defp displayed_ack(manifest) do
    %{
      "manifestRevision" => manifest["revision"],
      "storage" => "verified",
      "refresh" => "displayed",
      "currentAsset" => manifest["desiredAsset"],
      "lastError" => nil
    }
  end

  test "metadata that disagrees with the durable canonical representation is rejected", context do
    {:ok, package} = MasterPackage.encode(@original, @rgba, 2, 1)
    {:ok, master} = Library.import_master(context.library, package, master_attributes())
    mismatched = %{render_job() | source_width: 1}

    assert {:error, :source_dimensions_mismatch} =
             RenderPipeline.render_stored_master(
               context.library,
               context.renderer,
               master["digest"],
               Map.delete(mismatched, :rgba),
               artifact_attributes()
             )
  end

  test "qualified render pins active binding, exact build and result across cache replay",
       context do
    {:ok, package} = MasterPackage.encode(@original, @rgba, 2, 1)
    {:ok, master} = Library.import_master(context.library, package, master_attributes())

    {:ok, frame} =
      Library.register_paired_frame(
        context.library,
        thing_description(),
        "keychain:qualified-pipeline-frame",
        "sha256:" <> String.duplicate("d", 64)
      )

    binding = qualification_manifest(frame, Renderer.build_digest(context.renderer))
    {:ok, binding_digest} = Library.register_qualification(context.library, binding)

    :ok =
      Library.admit_qualification(context.library, binding_digest, %{
        "schemaVersion" => 1,
        "scope" => "software_reference",
        "outcome" => "passed",
        "suiteDigest" => Digest.sha256("pipeline qualification fixture")
      })

    :ok = Library.activate_qualification(context.library, @frame_id, binding_digest)
    job = Map.delete(render_job(), :rgba)

    assert {:ok, first} =
             RenderPipeline.render_qualified_stored_master(
               context.library,
               context.renderer,
               @frame_id,
               "pull",
               master["digest"],
               job,
               artifact_attributes()
             )

    assert first["digest"] == Digest.sha256(@rgb)
    assert first.cache == :miss
    assert first.qualification_digest == binding_digest

    assert {:ok, %{"digest" => work_digest}} =
             Library.get_qualified_work(context.library, first.work_digest)

    assert work_digest == first.work_digest

    assert {:ok, %{"artifact_digest" => artifact_digest}} =
             Library.qualified_result(context.library, first.work_digest)

    assert artifact_digest == first["digest"]

    assert {:ok, _} =
             LocalAPI.execute_with_renderer(context.library, context.renderer, %{
               "id" => "qualified-pull-1",
               "kind" => "queue",
               "targetID" => @frame_id,
               "itemID" => master["digest"]
             })

    assert %{
             "queued" => [
               %{
                 "artifact_digest" => ^artifact_digest,
                 "qualification_digest" => ^binding_digest,
                 "status" => "qualified",
                 "work_digest" => queued_work_digest
               }
             ]
           } = Library.delivery_custody(context.library, @frame_id)

    assert queued_work_digest != work_digest

    assert {:ok, %{"artifact_digest" => ^artifact_digest}} =
             Library.qualified_result(context.library, queued_work_digest)

    assert {:ok, second} =
             RenderPipeline.render_qualified_stored_master(
               context.library,
               context.renderer,
               @frame_id,
               "pull",
               master["digest"],
               job,
               artifact_attributes()
             )

    assert second.cache == :hit
    assert second.work_digest == first.work_digest
    assert second.result_digest == first.result_digest

    wrong_build = qualification_manifest(frame, Digest.sha256("wrong renderer"))
    {:ok, wrong_digest} = Library.register_qualification(context.library, wrong_build)

    :ok =
      Library.admit_qualification(context.library, wrong_digest, %{
        "schemaVersion" => 1,
        "scope" => "software_reference",
        "outcome" => "passed",
        "suiteDigest" => Digest.sha256("wrong build fixture")
      })

    :ok = Library.activate_qualification(context.library, @frame_id, wrong_digest)

    assert {:error, :qualification_runtime_mismatch} =
             RenderPipeline.render_qualified_stored_master(
               context.library,
               context.renderer,
               @frame_id,
               "pull",
               master["digest"],
               job,
               artifact_attributes()
             )
  end

  test "queue uses the active qualification profile instead of the default profile", context do
    {:ok, package} = MasterPackage.encode(@original, @rgba, 2, 1)
    {:ok, master} = Library.import_master(context.library, package, master_attributes())
    alternate_id = "urn:frameshift:test:z-rgb24-v1"

    td = Jason.decode!(thing_description())
    [default_profile] = td["frameshift:capabilities"]["storage"]["artifactProfiles"]

    td =
      put_in(
        td,
        ["frameshift:capabilities", "storage", "artifactProfiles"],
        [default_profile, %{default_profile | "id" => alternate_id}]
      )

    {:ok, frame} =
      Library.register_paired_frame(
        context.library,
        Jason.encode!(td),
        "keychain:qualified-alternate-frame",
        "sha256:" <> String.duplicate("d", 64)
      )

    {:ok, profile_digest} = Profile.digest(frame["capabilities"], alternate_id)

    manifest =
      qualification_manifest(frame, Renderer.build_digest(context.renderer))
      |> Map.put("profileId", alternate_id)
      |> Map.put("profileDigest", profile_digest)

    {:ok, binding_digest} = Library.register_qualification(context.library, manifest)

    :ok =
      Library.admit_qualification(context.library, binding_digest, %{
        "schemaVersion" => 1,
        "scope" => "software_reference",
        "outcome" => "passed",
        "suiteDigest" => Digest.sha256("alternate profile fixture")
      })

    :ok = Library.activate_qualification(context.library, @frame_id, binding_digest)

    assert {:ok, _} =
             LocalAPI.execute_with_renderer(context.library, context.renderer, %{
               "id" => "alternate-profile-queue",
               "kind" => "queue",
               "targetID" => @frame_id,
               "itemID" => master["digest"]
             })

    assert {:ok, %{"artifactProfile" => ^alternate_id}} =
             Library.outbox_manifest(context.library, @frame_id)

    assert %{"queued" => [%{"qualification_digest" => ^binding_digest}]} =
             Library.delivery_custody(context.library, @frame_id)
  end

  test "queue uses the admitted push binding when a frame also offers pull", context do
    {:ok, package} = MasterPackage.encode(@original, @rgba, 2, 1)
    {:ok, master} = Library.import_master(context.library, package, master_attributes())

    td =
      thing_description()
      |> Jason.decode!()
      |> put_in(["frameshift:capabilities", "transferModes"], ["pull", "push"])
      |> Jason.encode!()

    {:ok, frame} =
      Library.register_paired_frame(
        context.library,
        td,
        "keychain:qualified-dual-mode-frame",
        "sha256:" <> String.duplicate("d", 64)
      )

    manifest = qualification_manifest(frame, Renderer.build_digest(context.renderer), "push")
    {:ok, binding_digest} = Library.register_qualification(context.library, manifest)

    :ok =
      Library.admit_qualification(context.library, binding_digest, %{
        "schemaVersion" => 1,
        "scope" => "software_reference",
        "outcome" => "passed",
        "suiteDigest" => Digest.sha256("dual mode fixture")
      })

    :ok = Library.activate_qualification(context.library, @frame_id, binding_digest)

    assert {:ok, %{"statusMessage" => "Displayed on Pipeline Frame"}} =
             LocalAPI.execute_with_delivery(
               context.library,
               context.renderer,
               %{
                 "id" => "qualified-dual-mode-push",
                 "kind" => "queue",
                 "targetID" => @frame_id,
                 "itemID" => master["digest"]
               },
               credential_resolver: {StaticCredentialResolver, %{owner: self()}},
               synchronizer: ConfirmedSynchronizer
             )

    assert_receive {:direct_delivery, _, _, _, _}
    assert :empty = Library.outbox_manifest(context.library, @frame_id)

    assert %{
             "current" => [
               %{
                 "qualification_digest" => ^binding_digest,
                 "status" => "qualified",
                 "work_digest" => work_digest
               }
             ]
           } = Library.delivery_custody(context.library, @frame_id)

    expected_digest = Digest.sha256(@rgb)

    assert {:ok, %{"artifact_digest" => ^expected_digest}} =
             Library.qualified_result(context.library, work_digest)
  end

  test "a push-only queue command renders and records confirmed direct delivery", context do
    {:ok, package} = MasterPackage.encode(@original, @rgba, 2, 1)
    {:ok, master} = Library.import_master(context.library, package, master_attributes())

    push_td =
      thing_description()
      |> Jason.decode!()
      |> put_in(["frameshift:capabilities", "transferModes"], ["push"])
      |> Jason.encode!()

    assert {:ok, _} =
             Library.register_paired_frame(
               context.library,
               push_td,
               "keychain:pipeline-direct-frame",
               "sha256:" <> String.duplicate("d", 64)
             )

    owner = self()

    broker_transport = fn _, request ->
      send(owner, {:keychain_broker_request, request})

      case request["operation"] do
        "resolve" ->
          {:ok,
           %{
             "ok" => true,
             "certificate" => Base.encode64(<<1, 2, 3>>),
             "algorithm" => "ecdsa"
           }}

        "sign" ->
          {:ok, %{"ok" => true, "signature" => Base.encode64(<<4, 5, 6>>)}}
      end
    end

    assert {:ok, snapshot} =
             LocalAPI.execute_with_delivery(
               context.library,
               context.renderer,
               %{
                 "id" => "direct-command-1",
                 "kind" => "queue",
                 "targetID" => @frame_id,
                 "itemID" => master["digest"]
               },
               credential_resolver:
                 {KeychainBroker,
                  %{
                    socket_path: "/unused/credential.sock",
                    token: String.duplicate("a", 64),
                    transport: broker_transport
                  }},
               synchronizer: ConfirmedSynchronizer
             )

    assert snapshot["statusMessage"] == "Displayed on Pipeline Frame"

    assert_receive {:keychain_broker_request,
                    %{
                      "operation" => "resolve",
                      "reference" => "keychain:pipeline-direct-frame"
                    }}

    assert_receive {:direct_delivery, _td, artifact, credential, sync_context}
    assert artifact.bytes == @rgb
    assert artifact.digest == Digest.sha256(@rgb)

    assert credential.server_spki_sha256 ==
             Base.decode16!(String.duplicate("d", 64), case: :lower)

    assert :public_key.sign("tls-proof", :sha256, credential.client_private_key) == <<4, 5, 6>>

    assert_receive {:keychain_broker_request,
                    %{
                      "operation" => "sign",
                      "scheme" => "ecdsa-sha256",
                      "digest" => encoded_digest
                    }}

    assert Base.decode64!(encoded_digest) == :crypto.hash(:sha256, "tls-proof")

    assert sync_context.request_id == "direct-command-1"
    assert :empty = Library.outbox_manifest(context.library, @frame_id)

    assert {:ok, %{"status" => "displayed", "desired_digest" => digest}} =
             Library.direct_delivery(context.library, @frame_id)

    assert digest == artifact.digest
  end

  test "a qualified push timeout retains exact custody through repeated uncertain transfer",
       context do
    {:ok, package} = MasterPackage.encode(@original, @rgba, 2, 1)
    {:ok, master} = Library.import_master(context.library, package, master_attributes())

    push_td =
      thing_description()
      |> Jason.decode!()
      |> put_in(["frameshift:capabilities", "transferModes"], ["push"])
      |> Jason.encode!()

    assert {:ok, frame} =
             Library.register_paired_frame(
               context.library,
               push_td,
               "keychain:pipeline-timeout-frame",
               "sha256:" <> String.duplicate("d", 64)
             )

    manifest = qualification_manifest(frame, Renderer.build_digest(context.renderer), "push")
    {:ok, binding_digest} = Library.register_qualification(context.library, manifest)

    :ok =
      Library.admit_qualification(context.library, binding_digest, %{
        "schemaVersion" => 1,
        "scope" => "software_reference",
        "outcome" => "passed",
        "suiteDigest" => Digest.sha256("qualified timeout fixture")
      })

    :ok = Library.activate_qualification(context.library, @frame_id, binding_digest)

    assert {:error, :delivery_outcome_unknown} =
             LocalAPI.execute_with_delivery(
               context.library,
               context.renderer,
               %{
                 "id" => "direct-timeout-1",
                 "kind" => "queue",
                 "targetID" => @frame_id,
                 "itemID" => master["digest"]
               },
               credential_resolver: {StaticCredentialResolver, %{owner: self()}},
               synchronizer: TimedOutSynchronizer
             )

    assert {:ok, %{"revision" => 1, "status" => "pending", "desired_digest" => digest}} =
             Library.direct_delivery(context.library, @frame_id)

    assert digest == Digest.sha256(@rgb)
    assert :empty = Library.outbox_manifest(context.library, @frame_id)

    assert %{
             "desired" => [
               %{
                 "work_digest" => work_digest,
                 "qualification_digest" => ^binding_digest,
                 "status" => "qualified"
               }
             ]
           } = Library.delivery_custody(context.library, @frame_id)

    [profile | _] = frame["capabilities"]["storage"]["artifactProfiles"]

    assert {:error, {:transport, :timeout}} =
             DirectDelivery.push(
               context.library,
               frame,
               %{"digest" => digest, work_digest: work_digest},
               profile,
               "direct-timeout-1",
               credential_resolver: {StaticCredentialResolver, %{owner: self()}},
               synchronizer: TimedOutSynchronizer
             )

    assert {:ok, %{"revision" => 1, "status" => "pending"}} =
             Library.direct_delivery(context.library, @frame_id)

    assert %{
             "desired" => [
               %{"work_digest" => ^work_digest, "qualification_digest" => ^binding_digest}
             ]
           } = Library.delivery_custody(context.library, @frame_id)

    assert %{"entries" => audit} = Library.audit_page(context.library)
    assert Enum.count(audit, &(&1["operation"] == "direct.desired")) == 1

    outcomes =
      audit
      |> Enum.filter(&(&1["operation"] == "direct.attempt.completed"))
      |> Enum.map(& &1["detail"]["outcome"])

    assert outcomes == ["unknown", "unknown"]
  end

  defp render_job do
    %{
      source_width: 2,
      source_height: 1,
      crop_x: 0,
      crop_y: 0,
      crop_width: 2,
      crop_height: 1,
      target_width: 2,
      target_height: 1,
      background: {0, 0, 0},
      output_format: :rgb24,
      resize_filter: :nearest,
      dither_mode: :none,
      palette: [],
      rgba: @rgba
    }
  end

  defp stop_if_alive(process) do
    if Process.alive?(process), do: GenServer.stop(process)
  catch
    :exit, _ -> :ok
  end

  defp master_attributes do
    %{
      title: "Canonical RGBA Fixture",
      source_kind: :import,
      width: 2,
      height: 1,
      media_type: MasterPackage.media_type(),
      provenance: %{"kind" => "test-fixture"}
    }
  end

  defp artifact_attributes do
    %{
      profile_id: @profile_id,
      renderer_revision: "frameshift-raster-v0.1",
      media_type: "application/vnd.frameshift.rgb24"
    }
  end

  defp qualification_manifest(frame, renderer_digest, mode \\ "pull") do
    connector = if mode == "push", do: "wotex-http-v0.1", else: "frameshift-outbox-v0.1"
    {:ok, profile_digest} = Profile.digest(frame["capabilities"], @profile_id)
    {:ok, binding_digest} = Profile.binding_digest(frame["td_json"], mode, connector)

    %{
      "schemaVersion" => 1,
      "frameId" => @frame_id,
      "thingDescriptionDigest" => Digest.sha256(frame["td_json"]),
      "profileId" => @profile_id,
      "profileDigest" => profile_digest,
      "rendererBuildDigest" => renderer_digest,
      "rendererProtocolRevision" => "fsr1",
      "rendererAlgorithmRevision" => "frameshift-raster-v0.1",
      "bindingDigest" => binding_digest,
      "connectorRevision" => connector,
      "effectClass" => "physical_display",
      "transferMode" => mode
    }
  end

  defp thing_description do
    @thing_fixture
    |> File.read!()
    |> Jason.decode!()
    |> Map.put("id", "urn:frameshift:device:#{@frame_id}")
    |> Map.put("title", "Pipeline Frame")
    |> Map.put("frameshift:capabilities", capabilities())
    |> put_in(
      ["actions", "installAsset", "input", "contentMediaType"],
      artifact_attributes().media_type
    )
    |> put_in(
      ["actions", "installAsset", "forms", Access.at(0), "contentType"],
      artifact_attributes().media_type
    )
    |> put_in(
      ["actions", "installAsset", "forms", Access.at(0), "frameshift:artifactProfile"],
      @profile_id
    )
    |> Jason.encode!()
  end

  defp capabilities do
    %{
      "protocolMajor" => 0,
      "protocolMinor" => 1,
      "deviceId" => @frame_id,
      "hardwareRevision" => "simulator-pipeline-v1",
      "firmwareVersion" => "simulator-0.1.0",
      "stillOnly" => true,
      "transferModes" => ["pull"],
      "displayClass" => "continuous-color-raster",
      "geometry" => %{
        "width" => 2,
        "height" => 1,
        "orientation" => "identity",
        "safeInset" => %{"top" => 0, "right" => 0, "bottom" => 0, "left" => 0},
        "pixelAspectRatio" => %{"horizontal" => 1, "vertical" => 1}
      },
      "color" => %{
        "kind" => "continuous",
        "colorSpaces" => ["srgb"],
        "transferFunction" => "srgb",
        "channelOrder" => "rgb",
        "bitDepth" => 8,
        "alphaHandling" => "none",
        "profileRevision" => "sim-srgb-v1"
      },
      "refresh" => %{
        "kind" => "sample-and-hold",
        "typicalRefreshMs" => 1,
        "maximumRefreshMs" => 100,
        "minimumDwellMs" => 1_000,
        "flashDuringRefresh" => false
      },
      "power" => %{
        "class" => "continuous-emissive",
        "source" => "external",
        "remoteWake" => true
      },
      "storage" => %{
        "maximumAssetBytes" => 6,
        "totalBytes" => 12,
        "availableBytes" => 12,
        "maximumAssetCount" => 2,
        "digestAlgorithms" => ["sha-256"],
        "artifactProfiles" => [
          %{
            "id" => @profile_id,
            "mediaType" => "application/vnd.frameshift.rgb24",
            "width" => 2,
            "height" => 1,
            "maximumAssetBytes" => 6,
            "rowAlignment" => 1,
            "byteOrder" => "not-applicable",
            "channelOrder" => "rgb",
            "bitDepth" => 8,
            "compression" => "none",
            "colorProfileRevision" => "sim-srgb-v1"
          }
        ],
        "maximumPlaylistLength" => 2
      }
    }
  end
end
