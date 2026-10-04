defmodule FrameshiftContainerReceiver do
  @moduledoc false

  require Record

  Record.defrecordp(
    :otp_certificate,
    Record.extract(:OTPCertificate, from_lib: "public_key/include/public_key.hrl")
  )

  Record.defrecordp(
    :otp_tbs_certificate,
    Record.extract(:OTPTBSCertificate, from_lib: "public_key/include/public_key.hrl")
  )

  @maximum_control_bytes 65_536
  @maximum_asset_bytes 32 * 1024 * 1024
  @maximum_header_bytes 65_536

  @profiles %{
    "paper" => %{
      model: "Waveshare 13.3-inch e-Paper HAT+ (E)",
      width: 1600,
      height: 1200,
      refresh_ms: 19_000,
      minimum_dwell_ms: 180_000,
      recommended_dwell_ms: 21_600_000,
      recommendation_basis: "provisional-profile",
      recommendation_revision: "frameshift-paper-e6-v1"
    },
    "photo" => %{
      model: "BOE MV270QHM-N40 Rev.P1",
      width: 2560,
      height: 1440,
      refresh_ms: 17,
      minimum_dwell_ms: 1_000
    },
    "pixel" => %{
      model: "Waveshare RGB-Matrix-P3-64x64 3x2",
      width: 192,
      height: 128,
      refresh_ms: 17,
      minimum_dwell_ms: 1_000
    }
  }

  def main do
    config = configuration!()
    File.mkdir_p!(config.data_dir)
    state = load_state!(config)

    result =
      case {config.action, config.power_state, config.fault} do
        {"inspect", _, _} -> %{outcome: "inspected", state: state}
        {"install_playlist", "on", _} -> install_playlist!(config, state)
        {"tick", "on", _} -> tick_playlist!(config, state)
        {"contact", "off", _} -> %{outcome: "powered_off", state: state}
        {"tick", "off", _} -> %{outcome: "powered_off", state: state}
        {"contact", _, "missed_contact"} -> %{outcome: "missed_contact", state: state}
        _ -> contact!(config, state)
      end

    result =
      result
      |> Map.put(:visibleAsset, visible_asset(config, result.state))
      |> Map.put(:timingProfile, config.timing_profile)

    IO.puts(encode_json(result))
  rescue
    exception ->
      IO.puts(:stderr, Exception.message(exception))
      System.halt(1)
  end

  defp configuration! do
    class = System.fetch_env!("FS_FRAME_CLASS")
    profile = Map.fetch!(@profiles, class)
    fault = System.get_env("FS_FAULT", "none")
    action = System.get_env("FS_ACTION", "contact")
    power_state = System.get_env("FS_POWER_STATE", "on")

    unless fault in ~w(none missed_contact corrupt_transfer storage_full display_failure power_loss_after_download stale_ack) do
      raise "invalid fault"
    end

    unless action in ~w(contact inspect install_playlist tick) and power_state in ~w(on off),
      do: raise("invalid action or power state")

    %{
      class: class,
      action: action,
      power_state: power_state,
      model: profile.model,
      artifact_bytes: profile.width * profile.height * 3,
      scenario_refresh_ms: profile.refresh_ms,
      timing_profile: timing_profile(profile),
      playlist_json: System.get_env("FS_PLAYLIST_JSON"),
      now_ms: System.get_env("FS_NOW_MS", "0") |> String.to_integer(),
      fault: fault,
      data_dir: System.fetch_env!("FS_DATA_DIR"),
      host: System.fetch_env!("FS_HOST"),
      port: System.fetch_env!("FS_PORT") |> String.to_integer(),
      host_pin: System.fetch_env!("FS_HOST_SPKI"),
      certfile: System.fetch_env!("FS_CERTFILE"),
      keyfile: System.fetch_env!("FS_KEYFILE"),
      profile_id: System.fetch_env!("FS_PROFILE_ID"),
      refresh_delay_ms: System.get_env("FS_REFRESH_DELAY_MS", "0") |> String.to_integer(),
      temperature_c: System.get_env("FS_TEMPERATURE_C", "25") |> String.to_integer()
    }
  end

  defp timing_profile(profile) do
    base = %{minimumDwellMs: profile.minimum_dwell_ms}

    case Map.fetch(profile, :recommended_dwell_ms) do
      {:ok, dwell} ->
        Map.merge(base, %{
          recommendedDwellMs: dwell,
          recommendationBasis: profile.recommendation_basis,
          recommendationRevision: profile.recommendation_revision
        })

      :error ->
        base
    end
  end

  defp load_state!(config) do
    path = Path.join(config.data_dir, "state.json")

    state =
      case File.read(path) do
        {:ok, bytes} when byte_size(bytes) <= @maximum_control_bytes ->
          decode_json(bytes)

        {:error, :enoent} ->
          %{"class" => config.class, "currentAsset" => nil, "desiredAsset" => nil}

        _ ->
          raise "invalid persisted state"
      end

    if state["class"] != config.class, do: raise("frame class changed across restart")
    verify_current!(state, config.data_dir, config.artifact_bytes)
    state
  end

  defp verify_current!(%{"currentAsset" => nil}, _, _), do: :ok

  defp verify_current!(%{"currentAsset" => digest}, data_dir, expected_bytes) do
    path = asset_path!(data_dir, digest)
    bytes = File.read!(path)

    if byte_size(bytes) != expected_bytes or digest_bytes(bytes) != digest,
      do: raise("persisted current asset corrupt")
  end

  defp visible_asset(%{class: "paper"}, state), do: state["currentAsset"]
  defp visible_asset(%{power_state: "on"}, state), do: state["currentAsset"]
  defp visible_asset(_, _), do: nil

  defp install_playlist!(%{playlist_json: json} = config, state)
       when is_binary(json) and byte_size(json) <= @maximum_control_bytes do
    playlist = decode_json(json)
    validate_playlist!(config, playlist)

    if state["playlist"] == playlist do
      %{outcome: "playlist_existing", state: state}
    else
      persist_playlist!(config, state, playlist)
    end
  end

  defp install_playlist!(_, _), do: raise("playlist document required")

  defp persist_playlist!(config, state, playlist) do
    installed =
      Map.merge(state, %{
        "playlist" => playlist,
        "playlistIndex" => nil,
        "playlistDueMs" => nil,
        "playlistClockMs" => nil,
        "playlistRetryAtMs" => nil,
        "playlistSuspended" => false
      })

    durable_state!(config.data_dir, installed)
    %{outcome: "playlist_installed", state: installed}
  end

  defp validate_playlist!(config, playlist) when is_map(playlist) do
    validate_playlist_structure!(config, playlist)

    Enum.each(playlist["entries"], fn entry ->
      unless verified_asset?(config.data_dir, entry["assetDigest"], config.artifact_bytes),
        do: raise("invalid playlist entry or uncached asset")
    end)
  end

  defp validate_playlist!(_, _), do: raise("invalid playlist document")

  defp validate_playlist_structure!(config, playlist) when is_map(playlist) do
    entries = Map.get(playlist, "entries")

    unless Map.keys(playlist) |> Enum.sort() == ["entries", "mode", "revision"] and
             valid_digest?(playlist["revision"]) and playlist["mode"] in ~w(hold cycle) and
             is_list(entries) and length(entries) in 1..2 do
      raise "invalid playlist document"
    end

    Enum.each(entries, &validate_playlist_entry_shape!(config, &1))

    if playlist["revision"] != canonical_playlist_revision(playlist),
      do: raise("playlist revision mismatch")
  end

  defp validate_playlist_structure!(_, _), do: raise("invalid playlist document")

  defp validate_playlist_entry_shape!(config, entry) when is_map(entry) do
    digest = entry["assetDigest"]
    dwell = entry["dwellMs"]

    unless Map.keys(entry) |> Enum.sort() == ["assetDigest", "dwellMs"] and
             valid_digest?(digest) and is_integer(dwell) and
             dwell >= config.timing_profile.minimumDwellMs and dwell <= 31_536_000_000 do
      raise "invalid playlist entry"
    end
  end

  defp validate_playlist_entry_shape!(_, _), do: raise("invalid playlist entry")

  defp canonical_playlist_revision(playlist) do
    entries =
      Enum.map_join(playlist["entries"], ",", fn entry ->
        ~s({"assetDigest":"#{entry["assetDigest"]}","dwellMs":#{entry["dwellMs"]}})
      end)

    digest_bytes(~s({"entries":[#{entries}],"mode":"#{playlist["mode"]}"}))
  end

  defp tick_playlist!(config, %{"playlist" => playlist} = state) do
    now_ms = config.now_ms
    clock_ms = state["playlistClockMs"]
    if now_ms < 0 or (is_integer(clock_ms) and now_ms < clock_ms), do: raise("clock regressed")

    cond do
      state["playlistSuspended"] -> %{outcome: "playlist_suspended", state: state}
      waiting_for_dwell?(state, playlist, now_ms) -> %{outcome: "waiting", state: state}
      true -> display_playlist_entry!(config, state, playlist, now_ms)
    end
  end

  defp tick_playlist!(_, _), do: raise("no playlist installed")

  defp waiting_for_dwell?(%{"playlistRetryAtMs" => retry_at}, _, now_ms)
       when is_integer(retry_at) and now_ms < retry_at,
       do: true

  defp waiting_for_dwell?(%{"playlistIndex" => nil}, _, _), do: false
  defp waiting_for_dwell?(_, %{"mode" => "hold"}, _), do: true

  defp waiting_for_dwell?(state, _, now_ms) do
    retry_at = state["playlistRetryAtMs"]
    due = state["playlistDueMs"]
    (is_integer(retry_at) and now_ms < retry_at) or (is_integer(due) and now_ms < due)
  end

  defp display_playlist_entry!(config, state, playlist, now_ms) do
    index = next_playlist_index(state, playlist)
    entry = Enum.at(playlist["entries"], index)
    digest = entry["assetDigest"]

    unless verified_asset?(config.data_dir, digest, config.artifact_bytes),
      do: raise("playlist asset corrupt")

    desired = Map.put(state, "desiredAsset", digest)
    durable_state!(config.data_dir, desired)

    cond do
      config.fault == "power_loss_after_download" ->
        System.halt(23)

      config.fault == "display_failure" ->
        fail_playlist_display!(config, desired, now_ms)

      config.class == "paper" and (config.temperature_c < 0 or config.temperature_c > 40) ->
        fail_playlist_display!(config, desired, now_ms)

      true ->
        complete_playlist_display!(config, desired, playlist, index, now_ms)
    end
  end

  defp next_playlist_index(%{"playlistIndex" => nil}, _), do: 0

  defp next_playlist_index(state, playlist),
    do: rem(state["playlistIndex"] + 1, length(playlist["entries"]))

  defp fail_playlist_display!(config, state, now_ms) do
    failed = Map.put(state, "playlistRetryAtMs", now_ms + config.timing_profile.minimumDwellMs)
    durable_state!(config.data_dir, failed)
    %{outcome: "playlist_failed", state: failed}
  end

  defp complete_playlist_display!(config, state, playlist, index, now_ms) do
    if state["currentAsset"] != state["desiredAsset"], do: Process.sleep(config.refresh_delay_ms)
    completion_ms = now_ms + config.refresh_delay_ms
    entry = Enum.at(playlist["entries"], index)
    due = if playlist["mode"] == "cycle", do: completion_ms + entry["dwellMs"], else: nil

    completed =
      Map.merge(state, %{
        "currentAsset" => entry["assetDigest"],
        "playlistIndex" => index,
        "playlistClockMs" => completion_ms,
        "playlistDueMs" => due,
        "playlistRetryAtMs" => nil
      })

    durable_state!(config.data_dir, completed)
    %{outcome: "playlist_displayed", state: completed}
  end

  defp contact!(config, state) do
    case exchange!(config, "GET", "/v0/outbox/manifest", nil) do
      %{status: 204} -> %{outcome: "empty", state: state}
      %{status: 200, body: body} -> process_manifest!(config, state, body)
      _ -> raise "manifest request failed"
    end
  end

  defp process_manifest!(config, state, body) do
    if byte_size(body) > @maximum_control_bytes, do: raise("manifest too large")
    manifest = decode_json(body)
    digest = Map.fetch!(manifest, "desiredAsset")
    revision = Map.fetch!(manifest, "revision")
    profile_id = Map.fetch!(manifest, "artifactProfile")

    unless is_integer(revision) and revision > 0 and profile_id == config.profile_id do
      raise "unexpected manifest profile or revision"
    end

    cond do
      is_nil(digest) ->
        %{outcome: "no_work", state: state}

      not valid_digest?(digest) ->
        raise "invalid manifest digest"

      is_binary(manifest["playlistRevision"]) ->
        apply_playlist_manifest!(config, state, manifest)

      true ->
        apply_manifest!(config, state, digest, revision)
    end
  end

  defp apply_playlist_manifest!(config, state, manifest) do
    revision = manifest["playlistRevision"]
    unless valid_digest?(revision), do: raise("invalid playlist revision")

    response =
      exchange!(
        config,
        "GET",
        "/v0/outbox/playlists/sha256/#{String.slice(revision, 7, 64)}",
        nil
      )

    if response.status != 200, do: raise("playlist request failed")
    verify_playlist_response!(response)
    playlist = decode_json(response.body)
    validate_playlist_structure!(config, playlist)

    unless playlist["revision"] == revision and
             hd(playlist["entries"])["assetDigest"] == manifest["desiredAsset"] do
      raise "playlist manifest mismatch"
    end

    if config.fault == "storage_full" and missing_playlist_asset?(config, playlist) do
      acknowledge_failure!(
        config,
        state,
        manifest["revision"],
        "failed",
        "not-requested",
        "storage-full"
      )
    else
      install_pulled_playlist!(config, state, manifest, playlist)
    end
  end

  defp verify_playlist_response!(response) do
    expected = "sha-256=:#{Base.encode64(:crypto.hash(:sha256, response.body))}:"

    unless byte_size(response.body) <= @maximum_control_bytes and
             response.headers["content-type"] == "application/json" and
             response.headers["content-digest"] == expected do
      raise "playlist digest mismatch"
    end
  end

  defp missing_playlist_asset?(config, playlist) do
    Enum.any?(playlist["entries"], fn entry ->
      not verified_asset?(config.data_dir, entry["assetDigest"], config.artifact_bytes)
    end)
  end

  defp install_pulled_playlist!(config, state, manifest, playlist) do
    Enum.each(playlist["entries"], &fetch_playlist_asset!(config, &1["assetDigest"]))
    validate_playlist!(config, playlist)

    cond do
      config.fault == "power_loss_after_download" ->
        System.halt(23)

      config.fault == "display_failure" ->
        acknowledge_failure!(
          config,
          state,
          manifest["revision"],
          "verified",
          "failed",
          "display-failed"
        )

      config.class == "paper" and (config.temperature_c < 0 or config.temperature_c > 40) ->
        acknowledge_failure!(
          config,
          state,
          manifest["revision"],
          "verified",
          "failed",
          "temperature-out-of-range"
        )

      true ->
        complete_pulled_playlist!(config, state, manifest, playlist)
    end
  end

  defp fetch_playlist_asset!(config, digest) do
    unless verified_asset?(config.data_dir, digest, config.artifact_bytes) do
      response =
        exchange!(config, "GET", "/v0/outbox/assets/sha256/#{String.slice(digest, 7, 64)}", nil)

      if response.status != 200, do: raise("playlist asset request failed")
      verify_asset_response!(response, digest, config.fault, config.artifact_bytes)
      durable_write!(asset_path!(config.data_dir, digest), response.body)
    end
  end

  defp complete_pulled_playlist!(config, state, manifest, playlist) do
    first = hd(playlist["entries"])
    digest = first["assetDigest"]
    if state["currentAsset"] != digest, do: Process.sleep(config.refresh_delay_ms)
    completion_ms = config.now_ms + config.refresh_delay_ms
    due = if playlist["mode"] == "cycle", do: completion_ms + first["dwellMs"], else: nil

    installed =
      Map.merge(state, %{
        "currentAsset" => digest,
        "desiredAsset" => digest,
        "playlist" => playlist,
        "playlistIndex" => 0,
        "playlistClockMs" => completion_ms,
        "playlistDueMs" => due,
        "playlistRetryAtMs" => nil,
        "playlistSuspended" => false
      })

    durable_state!(config.data_dir, installed)
    ack = acknowledgement(manifest["revision"], "verified", "displayed", digest, nil)
    response = exchange!(config, "POST", "/v0/outbox/ack", encode_json(ack))

    case response.status do
      200 -> %{outcome: "playlist_displayed", state: installed}
      409 -> %{outcome: "ack_conflict", state: installed}
      _ -> raise "playlist acknowledgement failed"
    end
  end

  defp apply_manifest!(config, state, digest, revision) do
    existing = verified_asset?(config.data_dir, digest, config.artifact_bytes)

    cond do
      config.fault == "storage_full" and not existing ->
        acknowledge_failure!(config, state, revision, "failed", "not-requested", "storage-full")

      true ->
        store_and_display!(config, state, digest, revision, existing)
    end
  end

  defp store_and_display!(config, state, digest, revision, existing) do
    unless existing do
      hex = String.replace_prefix(digest, "sha256:", "")
      response = exchange!(config, "GET", "/v0/outbox/assets/sha256/#{hex}", nil)
      if response.status != 200, do: raise("asset request failed")
      verify_asset_response!(response, digest, config.fault, config.artifact_bytes)
      durable_write!(asset_path!(config.data_dir, digest), response.body)
    end

    desired =
      state
      |> Map.put("desiredAsset", digest)
      |> Map.put("playlistSuspended", Map.has_key?(state, "playlist"))

    durable_state!(config.data_dir, desired)

    case config.fault do
      "power_loss_after_download" ->
        System.halt(23)

      "display_failure" ->
        acknowledge_failure!(
          config,
          desired,
          revision,
          storage(existing),
          "failed",
          "display-failed"
        )

      _ ->
        maybe_display!(config, desired, digest, revision, existing)
    end
  end

  defp maybe_display!(
         %{class: "paper", temperature_c: temperature} = config,
         state,
         _digest,
         revision,
         existing
       )
       when temperature < 0 or temperature > 40 do
    acknowledge_failure!(
      config,
      state,
      revision,
      storage(existing),
      "failed",
      "temperature-out-of-range"
    )
  end

  defp maybe_display!(config, state, digest, revision, existing),
    do: display_and_ack!(config, state, digest, revision, existing)

  defp display_and_ack!(config, state, digest, revision, existing) do
    Process.sleep(config.refresh_delay_ms)
    displayed = Map.put(state, "currentAsset", digest)
    durable_state!(config.data_dir, displayed)
    ack_revision = if config.fault == "stale_ack", do: revision + 1, else: revision
    ack = acknowledgement(ack_revision, storage(existing), "displayed", digest, nil)
    response = exchange!(config, "POST", "/v0/outbox/ack", encode_json(ack))

    case response.status do
      200 ->
        %{
          outcome: "displayed",
          state: displayed,
          model: config.model,
          scenarioRefreshMs: config.scenario_refresh_ms
        }

      409 ->
        %{outcome: "ack_conflict", state: displayed}

      _ ->
        raise "acknowledgement failed: #{response.status} #{response.body}"
    end
  end

  defp acknowledge_failure!(config, state, revision, storage, refresh, code) do
    error = %{"type" => "urn:frameshift:problem:#{code}", "title" => code}
    ack = acknowledgement(revision, storage, refresh, state["currentAsset"], error)
    response = exchange!(config, "POST", "/v0/outbox/ack", encode_json(ack))

    if response.status != 200,
      do: raise("failure acknowledgement rejected: #{response.status} #{response.body}")

    %{outcome: code, state: state}
  end

  defp acknowledgement(revision, storage, refresh, current, error) do
    %{
      "manifestRevision" => revision,
      "storage" => storage,
      "refresh" => refresh,
      "currentAsset" => current,
      "lastError" => error
    }
  end

  defp storage(true), do: "unchanged"
  defp storage(false), do: "verified"

  defp verify_asset_response!(response, digest, fault, expected_bytes) do
    bytes = if fault == "corrupt_transfer", do: response.body <> <<0>>, else: response.body
    expected_header = "sha-256=:#{Base.encode64(:crypto.hash(:sha256, response.body))}:"

    unless byte_size(bytes) == expected_bytes and byte_size(bytes) <= @maximum_asset_bytes and
             response.headers["content-type"] == "application/vnd.frameshift.rgb24" and
             digest_bytes(bytes) == digest and
             response.headers["content-digest"] == expected_header do
      raise "asset digest mismatch"
    end
  end

  defp verified_asset?(data_dir, digest, expected_bytes) do
    case File.read(asset_path!(data_dir, digest)) do
      {:ok, bytes} -> byte_size(bytes) == expected_bytes and digest_bytes(bytes) == digest
      _ -> false
    end
  end

  defp asset_path!(data_dir, digest) do
    unless valid_digest?(digest), do: raise("invalid digest path")
    Path.join(data_dir, digest <> ".bin")
  end

  defp valid_digest?("sha256:" <> hex) when byte_size(hex) == 64 do
    String.match?(hex, ~r/\A[0-9a-f]{64}\z/)
  end

  defp valid_digest?(_), do: false

  defp digest_bytes(bytes),
    do: "sha256:" <> Base.encode16(:crypto.hash(:sha256, bytes), case: :lower)

  defp durable_state!(data_dir, state) do
    durable_write!(Path.join(data_dir, "state.json"), encode_json(state))
  end

  defp durable_write!(path, contents) do
    temporary = path <> ".tmp"
    {:ok, file} = File.open(temporary, [:write, :binary, :exclusive])

    try do
      :ok = IO.binwrite(file, contents)
      :ok = :file.sync(file)
    after
      File.close(file)
    end

    File.rename!(temporary, path)
  end

  defp exchange!(config, method, path, body) do
    :ok = :ssl.start()

    options = [
      active: false,
      mode: :binary,
      certfile: String.to_charlist(config.certfile),
      keyfile: String.to_charlist(config.keyfile),
      verify: :verify_peer,
      cacerts: [],
      verify_fun: {&verify_server/3, %{expected: config.host_pin}},
      versions: [:"tlsv1.3"],
      server_name_indication: :disable,
      alpn_advertised_protocols: ["http/1.1"]
    ]

    {:ok, socket} = :ssl.connect(String.to_charlist(config.host), config.port, options, 5_000)

    try do
      verify_peer_pin!(socket, config.host_pin)
      request = request(method, path, body)
      :ok = :ssl.send(socket, request)

      read_response!(
        socket,
        if(path =~ "/assets/", do: @maximum_asset_bytes, else: @maximum_control_bytes)
      )
    after
      :ssl.close(socket)
    end
  end

  defp request(method, path, nil), do: "#{method} #{path} HTTP/1.1\r\nHost: frame-host\r\n\r\n"

  defp request(method, path, body) do
    bytes = IO.iodata_to_binary(body)

    "#{method} #{path} HTTP/1.1\r\nHost: frame-host\r\nContent-Type: application/json\r\n" <>
      "Content-Length: #{byte_size(bytes)}\r\n\r\n" <> bytes
  end

  defp read_response!(socket, body_limit) do
    wire = receive_to_close!(socket, [], 0, body_limit + @maximum_header_bytes)

    case :binary.split(wire, "\r\n\r\n") do
      [head, body]
      when byte_size(head) <= @maximum_header_bytes and byte_size(body) <= body_limit ->
        parse_response!(head, body)

      _ ->
        raise "invalid response framing"
    end
  end

  defp receive_to_close!(socket, chunks, size, limit) do
    case :ssl.recv(socket, 0, 5_000) do
      {:ok, bytes} when size + byte_size(bytes) <= limit ->
        receive_to_close!(socket, [bytes | chunks], size + byte_size(bytes), limit)

      {:error, :closed} ->
        chunks |> Enum.reverse() |> IO.iodata_to_binary()

      _ ->
        raise "response exceeded limit or timed out"
    end
  end

  defp parse_response!(head, body) do
    [status_line | header_lines] = String.split(head, "\r\n")
    ["HTTP/1.1", status, _reason] = String.split(status_line, " ", parts: 3)

    headers =
      Enum.reduce(header_lines, %{}, fn line, result ->
        [name, value] = String.split(line, ":", parts: 2)
        key = String.downcase(name)
        if Map.has_key?(result, key), do: raise("duplicate response header")
        Map.put(result, key, String.trim(value))
      end)

    if headers["content-length"] != Integer.to_string(byte_size(body)) do
      raise "response length mismatch"
    end

    %{status: String.to_integer(status), headers: headers, body: body}
  end

  defp verify_server(_, {:bad_cert, reason}, state)
       when reason in [:unknown_ca, :selfsigned_peer],
       do: {:valid, state}

  defp verify_server(_, {:bad_cert, reason}, _), do: {:fail, reason}
  defp verify_server(_, {:extension, _}, state), do: {:unknown, state}
  defp verify_server(_, :valid, state), do: {:valid, state}

  defp verify_server(certificate, :valid_peer, %{expected: expected} = state) do
    public_key_info =
      certificate
      |> otp_certificate(:tbsCertificate)
      |> otp_tbs_certificate(:subjectPublicKeyInfo)

    encoded = :public_key.pkix_encode(:OTPSubjectPublicKeyInfo, public_key_info, :otp)
    pin = "sha256:" <> Base.encode16(:crypto.hash(:sha256, encoded), case: :lower)
    if pin == expected, do: {:valid, state}, else: {:fail, :host_spki_mismatch}
  end

  defp verify_server(_, _, state), do: {:unknown, state}

  defp verify_peer_pin!(socket, expected) do
    {:ok, der} = :ssl.peercert(socket)
    certificate = :public_key.pkix_decode_cert(der, :otp)

    public_key_info =
      certificate
      |> otp_certificate(:tbsCertificate)
      |> otp_tbs_certificate(:subjectPublicKeyInfo)

    encoded = :public_key.pkix_encode(:OTPSubjectPublicKeyInfo, public_key_info, :otp)
    pin = "sha256:" <> Base.encode16(:crypto.hash(:sha256, encoded), case: :lower)
    if pin != expected, do: raise("host SPKI mismatch")
  end

  defp encode_json(value), do: value |> json_nulls() |> :json.encode() |> IO.iodata_to_binary()
  defp decode_json(bytes), do: bytes |> :json.decode() |> elixir_nulls()

  defp json_nulls(nil), do: :null

  defp json_nulls(map) when is_map(map),
    do: Map.new(map, fn {key, value} -> {key, json_nulls(value)} end)

  defp json_nulls(list) when is_list(list), do: Enum.map(list, &json_nulls/1)
  defp json_nulls(value), do: value

  defp elixir_nulls(:null), do: nil

  defp elixir_nulls(map) when is_map(map),
    do: Map.new(map, fn {key, value} -> {key, elixir_nulls(value)} end)

  defp elixir_nulls(list) when is_list(list), do: Enum.map(list, &elixir_nulls/1)
  defp elixir_nulls(value), do: value
end

FrameshiftContainerReceiver.main()
