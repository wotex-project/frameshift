defmodule Frameshift.CLITest do
  @moduledoc false

  use ExUnit.Case, async: true

  alias Frameshift.CLI
  alias Frameshift.Digest

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
          ["import", "/private/file.png", "--id", "id"],
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
end
