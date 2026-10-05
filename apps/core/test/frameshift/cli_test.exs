defmodule Frameshift.CLITest do
  @moduledoc false

  use ExUnit.Case, async: true

  alias Frameshift.CLI
  alias Frameshift.Digest
  alias Frameshift.Playlist.Plan

  @photo Path.expand("../../../../protocol/fixtures/valid/capabilities-photo.json", __DIR__)

  test "import keeps paths local, requires a retained ID and exposes file-free status recovery" do
    assert {:ok,
            {:import,
             %{"file" => "/caller/private/source.png", "id" => "original-1", "title" => nil}}} =
             CLI.parse(["import", "/caller/private/source.png", "--id", "original-1"])

    assert {:ok, {:import, %{"title" => "Été"}}} =
             CLI.parse(["import", "source.png", "--title", "Été", "--id", "id"])

    assert {:ok,
            {:command,
             %{"operation" => "importStatus", "commandId" => "original-1", "auth" => "peer"}}} =
             CLI.parse(["import-status", "original-1"])

    for args <- [
          ["import", "file"],
          ["import", "", "--id", "id"],
          ["import", "file", "--id", ""],
          ["import", "file", "--title", "e\u0301", "--id", "id"],
          ["import", "file", "--title", "x\n", "--id", "id"],
          ["import", "file", "--id", "id", "--title", "Title"],
          ["import-status", ""],
          ["import-status", "id", "file"],
          ["import-status", "id", "--id", "id"]
        ] do
      assert {:error, :usage} = CLI.parse(args)
    end

    assert {0, help, ""} = CLI.run(["--help"])
    assert help =~ "import FILE"
    assert help =~ "import-status COMMAND_ID"
  end

  test "physical CLI arguments keep commissioning IDs and require the protected namespace" do
    reference = "linux-pem-v1:" <> Digest.hex!(Digest.sha256("certificate"))

    for {verb, operation} <- [{"pair", "pair"}, {"recover-pair", "recoverPair"}] do
      assert {:ok,
              {:command,
               %{
                 "operation" => ^operation,
                 "commandId" => "retained",
                 "credentialRef" => ^reference
               } = body}} =
               CLI.parse([
                 verb,
                 "sim-photo-00000001",
                 "https://frame.local",
                 reference,
                 "--id",
                 "retained"
               ])

      refute Map.has_key?(body, "bootstrap")

      for {origin, ref, id} <- [
            {"http://frame.local", reference, "id"},
            {"https://frame.local/path", reference, "id"},
            {"https://user:pass@frame.local", reference, "id"},
            {"https://frame.local", "keychain:wrong-policy", "id"},
            {"https://frame.local", reference, "id/secret"},
            {"https://frame.local", reference, String.duplicate("x", 65)}
          ] do
        assert {:error, :usage} = CLI.parse([verb, "sim-photo-00000001", origin, ref, "--id", id])
      end
    end
  end

  test "loop arguments preserve order and milliseconds through the playlist decision" do
    items = Enum.map(1..64, &Digest.sha256("ordered-#{&1}"))

    assert {:ok, {:command, %{"command" => command}}} =
             CLI.parse(["loop", "frame", "1501"] ++ items ++ ["--id", "loop-id"])

    assert command["itemIDs"] == items
    assert command["dwellMs"] == 1_501
    capabilities = @photo |> File.read!() |> JSON.decode!()
    assert {:error, :playlist_too_long} = Plan.build(capabilities, items, command["dwellMs"])

    assert {:ok, %{dwell_ms: 1_501}} =
             Plan.build(capabilities, Enum.take(items, 2), command["dwellMs"])

    assert {:ok, {:command, %{"command" => profile}}} =
             CLI.parse(["loop", "frame", "profile", hd(items), "--id", "profile-id"])

    refute Map.has_key?(profile, "dwellMs")
    assert {:error, :interval_required} = Plan.build(capabilities, profile["itemIDs"])

    assert {:ok, {:command, %{"command" => pinned}}} =
             CLI.parse(["loop-pinned", "frame", "1", "--id", "pinned-id"])

    assert pinned["kind"] == "loopPinned"
    refute Map.has_key?(pinned, "itemIDs")
    assert {:ok, %{dwell_ms: 1_000}} = Plan.build(capabilities, [hd(items)], pinned["dwellMs"])

    for action <- [
          ["loop", "frame", "1"],
          ["loop", "frame", "1", hd(items), hd(items)],
          ["loop", "frame", "1"] ++ items ++ [Digest.sha256("overflow")],
          ["loop-pinned", "frame", "profile", hd(items)],
          ["loop", "frame", "1", "bad"]
        ] do
      assert {:error, :usage} = CLI.parse(action ++ ["--id", "id"])
    end
  end

  test "catalog options require explicit label intent and bounded canonical numbers" do
    digest = Digest.sha256("fixture")
    prefix = ["metadata-edit", digest, digest, "  Cafe\u0301  "]
    labels = Enum.flat_map(1..32, &["--label", "label-#{&1}"])
    dismissals = Enum.flat_map(1..64, &["--dismiss", "vision", "machine-#{&1}"])

    assert {:ok, {:command, %{"command" => edit}}} =
             CLI.parse(prefix ++ labels ++ dismissals ++ ["--id", "edit-id"])

    assert edit["title"] == "Café"
    assert edit["userLabels"] == Enum.map(1..32, &"label-#{&1}")
    assert length(edit["dismissedLabels"]) == 64

    for options <- [
          [],
          ["--dismiss", "vision", "machine"],
          ["--clear-user-labels", "--label", "label"],
          ["--label", "label", "--clear-user-labels"],
          ["--clear-user-labels", "--clear-user-labels"],
          ["--label", "x\ny"],
          ["--label", String.duplicate("é", 65)],
          ["--clear-user-labels", "--dismiss", "user", "label"],
          labels ++ ["--label", "overflow"],
          labels ++ dismissals ++ ["--dismiss", "metadata", "overflow"]
        ] do
      assert {:error, :usage} = CLI.parse(prefix ++ options ++ ["--id", "id"])
    end

    for value <- ["0", "-1", "01", "+1", "1.0", "1ms", "31536000001"] do
      assert {:error, :usage} =
               CLI.parse(["loop-pinned", "frame", value, "--id", "id"])
    end

    for value <- ["1048575", "1099511627777", "01048576", "1048576bytes"] do
      assert {:error, :usage} = CLI.parse(["storage-set", digest, value, "--id", "id"])
    end

    for value <- [1_048_576, 1_099_511_627_776] do
      assert {:ok, {:command, %{"command" => %{"objectByteLimit" => ^value}}}} =
               CLI.parse(["storage-set", digest, Integer.to_string(value), "--id", "id"])
    end
  end

  test "commands retain caller identities and map still-artwork actions to the owned contract" do
    item = Digest.sha256("item")
    revision = Digest.sha256("revision")

    assert {:ok, {:command, %{"operation" => "snapshot", "auth" => "peer"}}} =
             CLI.parse(["state"])

    assert {:ok, {:command, %{"operation" => "libraryMetadata", "itemID" => ^item}}} =
             CLI.parse(["metadata", item])

    assert {:ok, {:command, %{"operation" => "libraryRecovery", "afterID" => ^item}}} =
             CLI.parse(["recovery", "--after", item])

    assert {:ok, {:command, %{"operation" => "libraryStorage"}}} = CLI.parse(["storage"])

    actions = [
      ["instruction", "line one\nline two"],
      ["select", "target"],
      ["send", item, "target"],
      ["reconcile", "target"],
      ["pin", item],
      ["unpin", item],
      ["remove", item],
      ["restore", item],
      ["resume", "target", revision]
    ]

    for action <- actions do
      assert {:ok,
              {:command, %{"operation" => "command", "auth" => "peer", "command" => command}}} =
               CLI.parse(action ++ ["--id", "retained-id"])

      assert command["id"] == "retained-id"
      refute Map.has_key?(command, "actor_uid")
      assert {:error, :usage} = CLI.parse(action)
    end
  end

  test "hostile, ambiguous and unavailable arguments refuse before socket effects" do
    for args <- [
          nil,
          [1],
          [<<255>>],
          ["instruction", <<0>>, "--id", "id"],
          ["pin", "not-digest", "--id", "id"],
          ["send", Digest.sha256("x"), "", "--id", "id"],
          ["instruction", "text", "--id", ""],
          ["instruction", "text", "--id", String.duplicate("x", 65)],
          ["instruction", String.duplicate("x", 4_097), "--id", "id"],
          ["import", "/private/file.png", "--uid", "0", "--id", "id"],
          ["pair", "secret", "--id", "id"],
          ["state", "--uid", "0"],
          ["metadata", "x"],
          ["diagnostics", "health", "--limit", "1"],
          ["diagnostics", "audit", "--limit", "101"],
          ["diagnostics", "audit", "--limit", "1", "--limit", "2"],
          ["diagnostics", "audit", "--cursor", "-1"],
          ["diagnostics", "audit", "--cursor", "01"],
          ["diagnostics", "audit", "--cursor", "9007199254740992"],
          ["diagnostics", "audit", "--cursor", String.duplicate("9", 1_000)]
        ] do
      assert {:error, :usage} = CLI.parse(args)
    end

    assert {:ok, {:diagnostics, %{"operation" => "audit", "limit" => 100, "cursor" => 0}}} =
             CLI.parse(["diagnostics", "audit", "--limit", "100", "--cursor", "0"])
  end

  test "help and release version need no socket or service state" do
    assert {0, help, ""} = CLI.run(["--help"])
    assert help =~ "--id COMMAND_ID"
    assert {0, version, ""} = CLI.run(["--version"])
    assert version == "frameshiftctl 0.1.0-dev\n"
    assert {64, "", _} = CLI.run(["send"])
  end

  test "discovery is an exact standalone read without a service command identity" do
    assert {:ok, {:discovery, %{}}} = CLI.parse(["discover"])

    for args <- [["discover", "--id", "id"], ["discover", "--all"], ["discover", "/tmp/helper"]] do
      assert {:error, :usage} = CLI.parse(args)
      assert {64, "", _} = CLI.run(args)
    end

    unless :os.type() == {:unix, :linux} do
      assert {69, "", "frameshiftctl: discovery unavailable\n"} = CLI.run(["discover"])
    end
  end
end
