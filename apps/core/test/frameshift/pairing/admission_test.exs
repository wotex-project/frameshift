defmodule Frameshift.Pairing.AdmissionTest do
  @moduledoc false

  use ExUnit.Case, async: true

  alias Frameshift.Digest
  alias Frameshift.Library
  alias Frameshift.Pairing.Admission

  @thing_source File.read!(
                  Path.expand(
                    "../../../../../protocol/fixtures/valid/thing-description.json",
                    __DIR__
                  )
                )
                |> String.replace("https://frame.invalid/", "https://frame.local/")
  @device_id "sim-photo-00000001"
  @pin "sha256:" <> String.duplicate("a", 64)
  @secret :binary.copy(<<17, 29, 43, 61>>, 4)
  @encoded_secret Base.url_encode64(@secret, padding: false)

  defmodule Resolver do
    @moduledoc false

    @spec resolve(term(), map()) :: {:ok, map()}
    def resolve(_, %{owner: owner}) do
      send(owner, :resolved_identity)
      {:ok, %{certificate: <<1, 2, 3>>, private_key: {:rsa, :test_key}}}
    end
  end

  setup do
    root =
      Path.join(
        System.tmp_dir!(),
        "frameshift-pair-admission-#{System.unique_integer([:positive, :monotonic])}"
      )

    {:ok, library} = Library.start_link(data_dir: root, name: nil)
    on_exit(fn -> File.rm_rf!(root) end)
    %{library: library, root: root}
  end

  test "Linux successful receipts preserve actor/payload custody across restart without another pair",
       c do
    request = physical_request("pair-success")
    options = physical_options(c)
    assert {:ok, %{"frameId" => @device_id}} = Admission.execute_as(request, 7, options)
    assert_receive :resolved_identity
    assert_receive {:physical_pair, "pair-success"}
    assert_receive :physical_td
    replay = Map.put(request, "requestId", "different-connection")
    assert {:ok, %{"frameId" => @device_id}} = Admission.execute_as(replay, 7, options)
    assert {:error, :command_id_conflict} = Admission.execute_as(request, 8, options)

    assert {:error, :command_id_conflict} =
             Admission.execute_as(Map.put(request, "origin", "https://other.local"), 7, options)

    refute_receive :resolved_identity
    refute_receive {:physical_pair, _}
    refute_receive :physical_td
    GenServer.stop(c.library)
    {:ok, restarted} = Library.start_link(data_dir: c.root, name: nil)

    try do
      options = Keyword.put(options, :library, restarted)
      assert {:ok, %{"frameId" => @device_id}} = Admission.execute_as(request, 7, options)
      :ok = Library.forget_paired_frame(restarted, @device_id)
      assert {:error, :pairing_receipt_unavailable} = Admission.execute_as(request, 7, options)
    after
      GenServer.stop(restarted)
    end

    for path <- Path.wildcard(Path.join(c.root, "**/*")), File.regular?(path) do
      assert :binary.match(File.read!(path), @encoded_secret) == :nomatch
      assert :binary.match(File.read!(path), @secret) == :nomatch
    end
  end

  test "Linux pending/unknown receipts never post again; explicit recovery only reads the TD",
       c do
    pending = physical_request("pending-pair")
    hash = physical_hash(pending)
    assert {:ok, :execute} = Library.claim_command_as(c.library, "pending-pair", hash, 7)

    assert {:error, :command_outcome_unknown} =
             Admission.execute_as(pending, 7, physical_options(c))

    refute_receive :resolved_identity

    owner = self()

    options =
      Keyword.put(physical_options(c), :pairer, fn _, _, id ->
        send(owner, {:unknown_pair, id})
        {:error, :pairing_transport_failure}
      end)

    request = physical_request("unknown-pair")
    assert {:error, :pairing_outcome_unknown} = Admission.execute_as(request, 7, options)
    assert_receive :resolved_identity
    assert_receive {:unknown_pair, "unknown-pair"}
    assert {:error, :pairing_outcome_unknown} = Admission.execute_as(request, 7, options)
    refute_receive :resolved_identity
    refute_receive :physical_td
    recover = Map.put(request, "operation", "recoverPair")
    assert {:error, :command_id_conflict} = Admission.execute_as(recover, 7, options)
    recover = Map.put(recover, "commandId", "explicit-recovery")
    assert {:ok, %{"frameId" => @device_id}} = Admission.execute_as(recover, 7, options)
    assert_receive :resolved_identity
    assert_receive :physical_td
    refute_receive {:unknown_pair, _}
    assert {:ok, %{"frameId" => @device_id}} = Admission.execute_as(recover, 7, options)
    refute_receive :physical_td
  end

  test "Linux malformed physical commands refuse before receipts or key resolution", c do
    original = physical_request("admitted-id")
    audit = Library.audit_page(c.library)

    for {request, actor} <- [
          {original, nil},
          {original, -1},
          {original, 4_294_967_295},
          {Map.put(original, "commandId", "id/secret"), 7},
          {Map.put(original, "commandId", String.duplicate("x", 65)), 7},
          {Map.put(original, "bootstrap", "invalid"), 7},
          {Map.put(original, "discoveredId", "other-device-00001"), 7},
          {Map.put(original, "credentialRef", "keychain:wrong-policy"), 7},
          {Map.put(original, "origin", "https://user:pass@frame.local"), 7},
          {Map.put(original, "origin", "https://frame.local/private"), 7},
          {Map.put(original, "operation", "arbitrary"), 7}
        ] do
      assert {:error, :invalid_pairing_request} =
               Admission.execute_as(request, actor, physical_options(c))
    end

    assert Library.audit_page(c.library) == audit
    refute_receive :resolved_identity
    refute_receive {:physical_pair, _}
    refute_receive :physical_td
  end

  test "Linux completion failure keeps an admitted physical result pending without reposting",
       c do
    connection = :sys.get_state(c.library).connection

    Exqlite.query!(
      connection,
      "CREATE TRIGGER refuse_pair_completion BEFORE INSERT ON audit_entries WHEN NEW.operation = 'command.completed' BEGIN SELECT RAISE(ABORT, 'fixture'); END"
    )

    request = physical_request("completion-lost")

    assert {:error, :command_outcome_unknown} =
             Admission.execute_as(request, 7, physical_options(c))

    assert_receive :resolved_identity
    assert_receive {:physical_pair, "completion-lost"}
    assert_receive :physical_td
    assert {:ok, _} = Library.get_paired_frame(c.library, @device_id)
    Exqlite.query!(connection, "DROP TRIGGER refuse_pair_completion")

    assert {:error, :command_outcome_unknown} =
             Admission.execute_as(request, 7, physical_options(c))

    refute_receive :resolved_identity
    refute_receive {:physical_pair, _}
  end

  test "admits only the authenticated TD and never stores the bootstrap secret", context do
    owner = self()

    pairer = fn bootstrap, credential, request_id ->
      send(owner, {:paired, bootstrap.device_id, credential.server_spki_sha256, request_id})
      {:ok, %{device_id: bootstrap.device_id}}
    end

    assert {:ok, %{"frameId" => @device_id}} =
             Admission.pair(
               bootstrap(),
               @device_id,
               "https://frame.local",
               "keychain:admission-test",
               "pair-request-1",
               options(context, pairer, fn _, _ -> {:ok, @thing_source} end)
             )

    assert_receive :resolved_identity
    assert_receive {:paired, @device_id, _pin, "pair-request-1"}
    assert {:ok, frame} = Library.get_paired_frame(context.library, @device_id)
    assert frame["credential_ref"] == "keychain:admission-test"

    assert {:error, :pairing_preflight_failed} =
             Admission.pair(
               bootstrap(),
               @device_id,
               "https://frame.local",
               "keychain:admission-test",
               "pair-request-repeat",
               options(context, fn _, _, _ -> flunk("re-paired a registered frame") end, fn _,
                                                                                            _ ->
                 flunk("re-fetched TD")
               end)
             )

    refute_receive :resolved_identity

    for path <- Path.wildcard(Path.join(context.root, "**/*")), File.regular?(path) do
      assert :binary.match(File.read!(path), @encoded_secret) == :nomatch
    end
  end

  test "rejects a discovery mismatch before resolving an identity", context do
    assert {:error, :pairing_preflight_failed} =
             Admission.pair(
               bootstrap(),
               "other-frame-00001",
               "https://frame.local",
               "keychain:admission-test",
               "pair-request-2",
               options(context, fn _, _, _ -> flunk("pair sent") end, fn _, _ ->
                 flunk("TD fetched")
               end)
             )

    refute_receive :resolved_identity
    assert Library.list_paired_frames(context.library) == []
  end

  test "an uncertain pair exchange and a mismatched TD leave no paired frame", context do
    uncertain = fn _, _, _ -> {:error, :pairing_transport_failure} end
    fetcher = fn _, _ -> flunk("TD fetched after uncertain pair") end

    assert {:error, :pairing_outcome_unknown} =
             Admission.pair(
               bootstrap(),
               @device_id,
               "https://frame.local",
               "keychain:admission-test",
               "pair-request-3",
               options(context, uncertain, fetcher)
             )

    mismatched_td = String.replace(@thing_source, @device_id, "other-frame-00001")

    assert {:error, :pairing_incomplete} =
             Admission.pair(
               bootstrap(),
               @device_id,
               "https://frame.local",
               "keychain:admission-test",
               "pair-request-4",
               options(
                 context,
                 fn bootstrap, _, _ -> {:ok, %{device_id: bootstrap.device_id}} end,
                 fn _, _ ->
                   {:ok, mismatched_td}
                 end
               )
             )

    other_origin = String.replace(@thing_source, "https://frame.local/", "https://other.local/")

    assert {:error, :pairing_incomplete} =
             Admission.pair(
               bootstrap(),
               @device_id,
               "https://frame.local",
               "keychain:admission-test",
               "pair-request-5",
               options(
                 context,
                 fn bootstrap, _, _ -> {:ok, %{device_id: bootstrap.device_id}} end,
                 fn _, _ ->
                   {:ok, other_origin}
                 end
               )
             )

    assert Library.list_paired_frames(context.library) == []
  end

  test "recovery fetches only the pinned authenticated TD and refuses a mismatched QR", context do
    owner = self()

    fetcher = fn credential, path ->
      send(owner, {:read_only_recovery, credential.server_spki_sha256, path})
      {:ok, @thing_source}
    end

    assert {:error, :pairing_preflight_failed} =
             Admission.recover(
               bootstrap(),
               "other-frame-00001",
               "https://frame.local",
               "keychain:admission-test",
               options(context, fn _, _, _ -> flunk("pair POST replayed") end, fetcher)
             )

    refute_receive :resolved_identity

    assert {:ok, %{"frameId" => @device_id}} =
             Admission.recover(
               bootstrap(),
               @device_id,
               "https://frame.local",
               "keychain:admission-test",
               options(context, fn _, _, _ -> flunk("pair POST replayed") end, fetcher)
             )

    assert_receive :resolved_identity
    assert_receive {:read_only_recovery, pin, "/.well-known/wot"}
    assert "sha256:" <> Base.encode16(pin, case: :lower) == @pin
    assert {:ok, _} = Library.get_paired_frame(context.library, @device_id)
  end

  defp bootstrap do
    Jason.encode!(%{
      "version" => 1,
      "deviceId" => @device_id,
      "serverSpki" => @pin,
      "secret" => @encoded_secret
    })
  end

  defp physical_request(id),
    do: %{
      "operation" => "pair",
      "commandId" => id,
      "bootstrap" => bootstrap(),
      "discoveredId" => @device_id,
      "origin" => "https://frame.local",
      "credentialRef" => "linux-pem-v1:" <> String.duplicate("c", 64)
    }

  defp physical_hash(request),
    do:
      Digest.sha256(
        RFC8785.encode!(%{
          "domain" => "frameshift-linux-pairing-v1",
          "request" =>
            Map.take(request, ~w(operation bootstrap discoveredId origin credentialRef))
        })
      )

  defp physical_options(c) do
    owner = self()

    options(
      c,
      fn bootstrap, _, id ->
        send(owner, {:physical_pair, id})
        {:ok, %{device_id: bootstrap.device_id}}
      end,
      fn _, "/.well-known/wot" ->
        send(owner, :physical_td)
        {:ok, @thing_source}
      end
    )
  end

  defp options(context, pairer, fetcher) do
    [
      library: context.library,
      resolver: {Resolver, %{owner: self()}},
      pairer: pairer,
      fetcher: fetcher
    ]
  end
end
