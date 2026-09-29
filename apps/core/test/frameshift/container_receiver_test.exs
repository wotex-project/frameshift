defmodule Frameshift.ContainerReceiverTest do
  @moduledoc false

  use ExUnit.Case, async: false

  alias Frameshift.Digest
  alias Frameshift.Library
  alias Frameshift.Outbox.TLSServer
  alias Frameshift.Playlist.Plan
  alias Frameshift.Transport.SPKIPin

  @moduletag :container
  @image "frameshift-frame-receiver:local"
  @fixture Path.expand("../../../../protocol/fixtures/valid/thing-description.json", __DIR__)
  @container_context Path.expand("../../../../simulator/container", __DIR__)
  @fixture_root Path.expand("../../../../.build/container-fixtures", __DIR__)

  @classes %{
    "paper" => %{
      width: 1600,
      height: 1200,
      display: "restricted-palette-reflective",
      power: "bistable-sleeping",
      refresh: "global-bistable",
      refresh_ms: 19_000,
      minimum_dwell_ms: 180_000,
      recommended_dwell_ms: 21_600_000,
      model: "Waveshare 13.3-inch e-Paper HAT+ (E)"
    },
    "photo" => %{
      width: 2560,
      height: 1440,
      display: "continuous-color-raster",
      power: "continuous-emissive",
      refresh: "sample-and-hold",
      refresh_ms: 17,
      minimum_dwell_ms: 1_000,
      model: "BOE MV270QHM-N40 Rev.P1"
    },
    "pixel" => %{
      width: 192,
      height: 128,
      display: "low-resolution-emissive-matrix",
      power: "continuous-high-current",
      refresh: "scanned-emissive",
      refresh_ms: 17,
      minimum_dwell_ms: 1_000,
      model: "Waveshare RGB-Matrix-P3-64x64 3x2"
    }
  }

  setup_all do
    {output, 0} =
      System.cmd("docker", ["build", "--pull=false", "--tag", @image, @container_context],
        stderr_to_stdout: true
      )

    assert output =~ "Successfully tagged" or output =~ "naming to"
    :ok
  end

  for class <- ["paper", "photo", "pixel"] do
    test "#{class} candidate pulls exact artwork and survives receiver restart" do
      context = start_fixture!(unquote(class))
      on_exit(fn -> stop_fixture(context) end)

      digest = queue_artifact!(context, 7)

      assert %{"outcome" => "displayed", "scenarioRefreshMs" => refresh_ms, "model" => model} =
               run_receiver!(context)

      assert refresh_ms == context.profile.refresh_ms
      assert model == context.profile.model
      inspected = run_inspector!(context, "on")
      timing = inspected["timingProfile"]
      assert timing["minimumDwellMs"] == context.profile.minimum_dwell_ms

      if context.class == "paper" do
        assert timing["recommendedDwellMs"] == context.profile.recommended_dwell_ms
        assert timing["recommendationBasis"] == "provisional-profile"
        assert timing["recommendationRevision"] == "frameshift-paper-e6-v1"
      else
        refute Map.has_key?(timing, "recommendedDwellMs")
      end

      assert :empty == Library.outbox_manifest(context.library, context.frame_id)
      assert %{"outcome" => "empty"} = run_receiver!(context)

      assert :crypto.hash(:sha256, File.read!(asset_path(context, digest))) ==
               Base.decode16!(String.replace_prefix(digest, "sha256:", ""), case: :lower)

      assert %{"currentAsset" => ^digest} = stored_state(context)

      expected_without_power = if context.class == "paper", do: digest, else: nil

      assert %{"outcome" => "inspected", "visibleAsset" => ^expected_without_power} =
               run_inspector!(context, "off")

      assert %{"outcome" => "inspected", "visibleAsset" => ^digest} =
               run_inspector!(context, "on")
    end
  end

  test "paper keeps the old still through a failed first loop tick and retries at its floor" do
    context = start_fixture!("paper")
    on_exit(fn -> stop_fixture(context) end)
    first = queue_artifact!(context, 31)
    assert %{"outcome" => "displayed"} = run_receiver!(context)
    second = queue_artifact!(context, 32)
    assert %{"outcome" => "displayed"} = run_receiver!(context)
    document = playlist([first, second], context.profile.minimum_dwell_ms)
    payload = %{"FS_PLAYLIST_JSON" => RFC8785.encode!(document)}

    assert %{"outcome" => "playlist_installed"} =
             run_action!(context, "install_playlist", payload)

    assert %{"outcome" => "playlist_failed", "state" => %{"currentAsset" => ^second}} =
             run_action!(context, "tick", %{"FS_NOW_MS" => "100"}, "display_failure")

    assert %{"outcome" => "waiting"} =
             run_action!(context, "tick", %{"FS_NOW_MS" => "180099"})

    assert %{"outcome" => "playlist_displayed", "state" => %{"currentAsset" => ^first}} =
             run_action!(context, "tick", %{"FS_NOW_MS" => "180100"})

    assert %{"outcome" => "playlist_existing", "state" => %{"playlistIndex" => 0}} =
             run_action!(context, "install_playlist", payload)

    altered = Map.put(document, "revision", Digest.sha256("invalid"))

    assert {:error, output} =
             run_receiver(
               context,
               "none",
               nil,
               25,
               "install_playlist",
               "on",
               %{"FS_PLAYLIST_JSON" => RFC8785.encode!(altered)}
             )

    assert output =~ "playlist revision mismatch"
    assert stored_state(context)["playlist"] == document
  end

  for class <- ["paper", "photo", "pixel"] do
    test "#{class} installs an authenticated outbox playlist and then cycles offline" do
      context = start_fixture!(unquote(class))
      on_exit(fn -> stop_fixture(context) end)
      first = queue_artifact!(context, 41)
      assert %{"outcome" => "displayed"} = run_receiver!(context)
      second = queue_artifact!(context, 42)
      {:ok, frame} = Library.get_paired_frame(context.library, context.frame_id)
      dwell = context.profile.minimum_dwell_ms
      assert {:ok, plan} = Plan.build(frame["capabilities"], [first, second], dwell)

      entries = [
        %{"masterDigest" => Digest.sha256("master-41"), "artifactDigest" => first},
        %{"masterDigest" => Digest.sha256("master-42"), "artifactDigest" => second}
      ]

      assert {:ok, manifest} =
               Library.queue_playlist(
                 context.library,
                 context.frame_id,
                 context.profile_id,
                 plan.playlist,
                 entries,
                 "container-playlist"
               )

      assert manifest["playlistRevision"] == plan.playlist["revision"]

      assert %{"outcome" => "playlist_displayed", "state" => %{"currentAsset" => ^first}} =
               run_receiver!(context)

      assert :empty == Library.outbox_manifest(context.library, context.frame_id)
      assert File.regular?(asset_path(context, second))
      assert stored_state(context)["playlist"] == plan.playlist

      assert %{"outcome" => "playlist_displayed", "state" => %{"currentAsset" => ^second}} =
               run_action!(context, "tick", %{"FS_NOW_MS" => Integer.to_string(dwell)})
    end
  end

  for class <- ["paper", "photo", "pixel"] do
    test "#{class} receiver cycles cached stills on its own clock" do
      context = start_fixture!(unquote(class))
      on_exit(fn -> stop_fixture(context) end)
      first = queue_artifact!(context, 21)
      assert %{"outcome" => "displayed"} = run_receiver!(context)
      second = queue_artifact!(context, 22)
      assert %{"outcome" => "displayed"} = run_receiver!(context)

      dwell = context.profile.minimum_dwell_ms
      document = playlist([first, second], dwell)

      assert %{"outcome" => "playlist_installed"} =
               run_action!(context, "install_playlist", %{
                 "FS_PLAYLIST_JSON" => RFC8785.encode!(document)
               })

      assert %{"outcome" => "playlist_displayed", "state" => %{"currentAsset" => ^first}} =
               run_action!(context, "tick", %{"FS_NOW_MS" => "100"})

      assert %{"outcome" => "waiting"} =
               run_action!(context, "tick", %{"FS_NOW_MS" => Integer.to_string(99 + dwell)})

      assert %{"outcome" => "playlist_displayed", "state" => %{"currentAsset" => ^second}} =
               run_action!(context, "tick", %{"FS_NOW_MS" => Integer.to_string(100 + dwell)})

      assert %{"outcome" => "playlist_displayed", "state" => %{"currentAsset" => ^first}} =
               run_action!(context, "tick", %{"FS_NOW_MS" => "100000000"})

      expected_without_power = if context.class == "paper", do: first, else: nil

      assert %{"visibleAsset" => ^expected_without_power} = run_inspector!(context, "off")

      too_fast = playlist([first, second], dwell - 1)

      assert {:error, output} =
               run_receiver(
                 context,
                 "none",
                 nil,
                 25,
                 "install_playlist",
                 "on",
                 %{"FS_PLAYLIST_JSON" => RFC8785.encode!(too_fast)}
               )

      assert output =~ "invalid playlist entry"
      assert stored_state(context)["playlist"] == document
    end
  end

  defp playlist(digests, dwell_ms) do
    entries = Enum.map(digests, &%{"assetDigest" => &1, "dwellMs" => dwell_ms})
    payload = %{"mode" => "cycle", "entries" => entries}
    Map.put(payload, "revision", Digest.sha256(RFC8785.encode!(payload)))
  end

  defp run_action!(context, action, extras, fault \\ "none") do
    {:ok, output} = run_receiver(context, fault, nil, 25, action, "on", extras)
    {:ok, document} = RFC8785.decode(output)
    document
  end

  test "faulted pull preserves host custody and previous visible reference" do
    context = start_fixture!("paper")
    on_exit(fn -> stop_fixture(context) end)
    first = queue_artifact!(context, 3)

    assert %{"outcome" => "missed_contact"} = run_receiver!(context, "missed_contact")

    assert {:ok, %{"desiredAsset" => ^first}} =
             Library.outbox_manifest(context.library, context.frame_id)

    assert {:error, _} = run_receiver(context, "corrupt_transfer")

    assert {:ok, %{"desiredAsset" => ^first}} =
             Library.outbox_manifest(context.library, context.frame_id)

    assert %{"outcome" => "storage-full"} = run_receiver!(context, "storage_full")

    assert {:ok, %{"desiredAsset" => ^first}} =
             Library.outbox_manifest(context.library, context.frame_id)

    assert %{"outcome" => "display-failed"} = run_receiver!(context, "display_failure")
    assert %{"currentAsset" => nil} = stored_state(context)

    assert {:ok, %{"desiredAsset" => ^first}} =
             Library.outbox_manifest(context.library, context.frame_id)

    assert %{"outcome" => "temperature-out-of-range"} =
             run_receiver!(context, "none", 41)

    assert %{"currentAsset" => nil} = stored_state(context)

    assert %{"outcome" => "displayed"} = run_receiver!(context)
    assert %{"currentAsset" => ^first} = stored_state(context)

    second = queue_artifact!(context, 9)

    assert {:error, _} = run_receiver(context, "power_loss_after_download")

    assert %{"currentAsset" => ^first, "desiredAsset" => ^second} = stored_state(context)

    assert {:ok, %{"desiredAsset" => ^second}} =
             Library.outbox_manifest(context.library, context.frame_id)

    assert %{"outcome" => "ack_conflict"} = run_receiver!(context, "stale_ack")

    assert {:ok, %{"desiredAsset" => ^second}} =
             Library.outbox_manifest(context.library, context.frame_id)

    assert %{"outcome" => "displayed"} = run_receiver!(context)
    assert :empty == Library.outbox_manifest(context.library, context.frame_id)
    assert %{"currentAsset" => ^second} = stored_state(context)
  end

  test "wrong host pin sends no request and leaves the manifest pending" do
    context = start_fixture!("pixel")
    on_exit(fn -> stop_fixture(context) end)
    digest = queue_artifact!(context, 11)

    assert {:error, _} =
             run_receiver(context, "none", String.duplicate("0", 64) |> then(&("sha256:" <> &1)))

    assert {:ok, %{"desiredAsset" => ^digest}} =
             Library.outbox_manifest(context.library, context.frame_id)

    assert %{"currentAsset" => nil} = stored_state(context)
  end

  test "rejects an artifact whose byte count does not match the candidate geometry" do
    context = start_fixture!("pixel")
    on_exit(fn -> stop_fixture(context) end)
    expected_bytes = context.profile.width * context.profile.height * 3
    digest = queue_artifact!(context, 13, expected_bytes - 1)

    assert {:error, output} = run_receiver(context, "none")
    assert output =~ "asset digest mismatch"

    assert {:ok, %{"desiredAsset" => ^digest}} =
             Library.outbox_manifest(context.library, context.frame_id)

    assert %{"currentAsset" => nil} = stored_state(context)
    refute File.exists?(asset_path(context, digest))
  end

  test "rejects a receiver profile that differs from the queued manifest" do
    context = start_fixture!("photo")
    on_exit(fn -> stop_fixture(context) end)
    digest = queue_artifact!(context, 15)
    wrong_profile = %{context | profile_id: "urn:frameshift:sim:other-rgb24-proxy-v1"}

    assert {:error, output} = run_receiver(wrong_profile, "none")
    assert output =~ "unexpected manifest profile or revision"

    assert {:ok, %{"desiredAsset" => ^digest}} =
             Library.outbox_manifest(context.library, context.frame_id)

    assert %{"currentAsset" => nil} = stored_state(context)
  end

  defp start_fixture!(class) do
    profile = Map.fetch!(@classes, class)

    root = Path.join(@fixture_root, "#{class}-#{System.unique_integer([:positive])}")

    File.mkdir_p!(Path.join(root, "data"))
    File.mkdir_p!(Path.join(root, "certs"))
    File.chmod!(root, 0o700)
    File.chmod!(Path.join(root, "data"), 0o700)
    File.chmod!(Path.join(root, "certs"), 0o700)
    frame_id = "sim-container-#{class}-0001"
    profile_id = "urn:frameshift:sim:#{class}-rgb24-proxy-v1"

    certificates =
      :public_key.pkix_test_data(%{
        server_chain: %{
          root: [key: {:rsa, 2048, 65_537}],
          intermediates: [],
          peer: [key: {:rsa, 2048, 65_537}]
        },
        client_chain: %{
          root: [key: {:rsa, 2048, 65_537}],
          intermediates: [],
          peer: [key: {:rsa, 2048, 65_537}]
        }
      })

    server = certificates.server_config
    frame = certificates.client_config

    {:ok, server_pin} =
      SPKIPin.fingerprint(:public_key.pkix_decode_cert(Keyword.fetch!(server, :cert), :otp))

    {:ok, frame_pin} = SPKIPin.fingerprint_der(Keyword.fetch!(frame, :cert))
    write_pem!(Path.join(root, "certs/frame.pem"), :Certificate, Keyword.fetch!(frame, :cert))
    {key_type, key_der} = Keyword.fetch!(frame, :key)
    write_pem!(Path.join(root, "certs/frame-key.pem"), key_type, key_der)

    {:ok, library} = Library.start_link(data_dir: Path.join(root, "library"), name: nil)
    thing = thing_description!(class, frame_id, profile_id, profile)

    {:ok, _} =
      Library.register_paired_frame(library, thing, "keychain:container-frame", frame_pin)

    {:ok, workers} = Task.Supervisor.start_link(max_children: 17)

    {:ok, listener} =
      TLSServer.start_link(
        name: nil,
        library: library,
        task_supervisor: workers,
        bind_address: {0, 0, 0, 0},
        port: 0,
        certificate: Keyword.fetch!(server, :cert),
        private_key: Keyword.fetch!(server, :key)
      )

    {:ok, port} = TLSServer.port(listener)

    %{
      root: root,
      class: class,
      profile: profile,
      frame_id: frame_id,
      profile_id: profile_id,
      server_pin: "sha256:" <> Base.encode16(server_pin, case: :lower),
      port: port,
      library: library,
      workers: workers,
      listener: listener
    }
  end

  defp thing_description!(class, frame_id, profile_id, profile) do
    {:ok, thing} = @fixture |> File.read!() |> RFC8785.decode()
    capabilities = thing["frameshift:capabilities"]
    bytes = profile.width * profile.height * 3

    geometry =
      Map.merge(capabilities["geometry"], %{"width" => profile.width, "height" => profile.height})

    artifact = capabilities["storage"]["artifactProfiles"] |> hd()

    artifact =
      Map.merge(artifact, %{
        "id" => profile_id,
        "width" => profile.width,
        "height" => profile.height,
        "maximumAssetBytes" => bytes
      })

    storage =
      Map.merge(capabilities["storage"], %{
        "maximumAssetBytes" => bytes,
        "totalBytes" => bytes * 2,
        "availableBytes" => bytes * 2,
        "artifactProfiles" => [artifact]
      })

    refresh =
      Map.merge(capabilities["refresh"], %{
        "kind" => profile.refresh,
        "typicalRefreshMs" => profile.refresh_ms,
        "maximumRefreshMs" => max(profile.refresh_ms * 2, 100),
        "minimumDwellMs" => profile.minimum_dwell_ms,
        "flashDuringRefresh" => class == "paper"
      })

    refresh =
      if class == "paper" do
        Map.merge(refresh, %{
          "recommendedDwellMs" => profile.recommended_dwell_ms,
          "recommendationBasis" => "provisional-profile",
          "recommendationRevision" => "frameshift-paper-e6-v1"
        })
      else
        refresh
      end

    power =
      Map.merge(capabilities["power"], %{
        "class" => profile.power,
        "source" => if(class == "paper", do: "battery", else: "external"),
        "remoteWake" => class != "paper"
      })

    capabilities =
      Map.merge(capabilities, %{
        "deviceId" => frame_id,
        "hardwareRevision" => profile.model,
        "transferModes" => ["pull"],
        "displayClass" => profile.display,
        "geometry" => geometry,
        "refresh" => refresh,
        "power" => power,
        "storage" => storage
      })

    forms = get_in(thing, ["actions", "installAsset", "forms"])
    forms = Enum.map(forms, &Map.put(&1, "frameshift:artifactProfile", profile_id))

    thing =
      thing
      |> Map.put("id", "urn:frameshift:device:#{frame_id}")
      |> Map.put("title", profile.model)
      |> Map.put("frameshift:capabilities", capabilities)
      |> put_in(["actions", "installAsset", "forms"], forms)

    RFC8785.encode!(thing)
  end

  defp queue_artifact!(context, byte, byte_count \\ nil) do
    count = byte_count || context.profile.width * context.profile.height * 3
    bytes = :binary.copy(<<byte>>, count)

    {:ok, master} =
      Library.import_master(context.library, "master-#{byte}", %{
        title: "Container fixture",
        source_kind: :import,
        width: 1,
        height: 1,
        media_type: "image/png",
        provenance: %{"kind" => "test-fixture"}
      })

    {:ok, recipe} =
      Library.register_recipe(
        context.library,
        :composition,
        %{"width" => context.profile.width, "height" => context.profile.height},
        [master["digest"]]
      )

    {:ok, artifact} =
      Library.register_artifact(context.library, bytes, %{
        master_digest: master["digest"],
        recipe_hash: recipe,
        profile_id: context.profile_id,
        renderer_revision: "container-proxy-v1",
        media_type: "application/vnd.frameshift.rgb24"
      })

    {:ok, _} =
      Library.queue_outbox(
        context.library,
        context.frame_id,
        artifact["digest"],
        context.profile_id
      )

    artifact["digest"]
  end

  defp run_receiver!(context, fault \\ "none", temperature_c \\ 25) do
    {:ok, output} = run_receiver(context, fault, nil, temperature_c)
    {:ok, document} = RFC8785.decode(output)
    document
  end

  defp run_inspector!(context, power_state) do
    {:ok, output} = run_receiver(context, "none", nil, 25, "inspect", power_state)
    {:ok, document} = RFC8785.decode(output)
    document
  end

  defp run_receiver(
         context,
         fault,
         pin \\ nil,
         temperature_c \\ 25,
         action \\ "contact",
         power_state \\ "on",
         extra_env \\ %{}
       ) do
    name = "frameshift-receiver-#{System.unique_integer([:positive])}"
    %{uid: uid, gid: gid} = File.stat!(context.root)

    args = [
      "run",
      "--rm",
      "--name",
      name,
      "--user",
      "#{uid}:#{gid}",
      "--init",
      "--read-only",
      "--cap-drop",
      "ALL",
      "--security-opt",
      "no-new-privileges",
      "--add-host",
      "host.docker.internal:host-gateway",
      "--mount",
      "type=bind,source=#{Path.join(context.root, "data")},target=/data",
      "--mount",
      "type=bind,source=#{Path.join(context.root, "certs")},target=/certs,readonly",
      "--env",
      "FS_FRAME_CLASS=#{context.class}",
      "--env",
      "FS_FAULT=#{fault}",
      "--env",
      "FS_ACTION=#{action}",
      "--env",
      "FS_POWER_STATE=#{power_state}",
      "--env",
      "FS_DATA_DIR=/data",
      "--env",
      "FS_HOST=host.docker.internal",
      "--env",
      "FS_PORT=#{context.port}",
      "--env",
      "FS_HOST_SPKI=#{pin || context.server_pin}",
      "--env",
      "FS_CERTFILE=/certs/frame.pem",
      "--env",
      "FS_KEYFILE=/certs/frame-key.pem",
      "--env",
      "FS_PROFILE_ID=#{context.profile_id}",
      "--env",
      "FS_TEMPERATURE_C=#{temperature_c}"
    ]

    extra_args = Enum.flat_map(extra_env, fn {key, value} -> ["--env", "#{key}=#{value}"] end)
    args = args ++ extra_args ++ [@image]

    task = Task.async(fn -> System.cmd("docker", args, stderr_to_stdout: true) end)

    case Task.yield(task, 45_000) do
      {:ok, {output, 0}} ->
        {:ok, String.trim(output)}

      {:ok, {output, _}} ->
        {:error, output}

      nil ->
        System.cmd("docker", ["kill", name], stderr_to_stdout: true)
        Task.shutdown(task, :brutal_kill)
        {:error, :container_timeout}
    end
  end

  defp stored_state(context) do
    path = Path.join(context.root, "data/state.json")

    case File.read(path) do
      {:ok, bytes} ->
        {:ok, document} = RFC8785.decode(bytes)
        document

      {:error, :enoent} ->
        %{"currentAsset" => nil}
    end
  end

  defp asset_path(context, digest), do: Path.join(context.root, "data/#{digest}.bin")

  defp write_pem!(path, type, der) do
    File.write!(path, :public_key.pem_encode([{type, der, :not_encrypted}]))
    File.chmod!(path, 0o600)
  end

  defp stop_fixture(context) do
    for process <- [context.listener, context.workers, context.library] do
      try do
        if Process.alive?(process), do: GenServer.stop(process)
      catch
        :exit, _ -> :ok
      end
    end

    File.rm_rf!(context.root)
  end
end
