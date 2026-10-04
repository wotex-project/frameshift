defmodule Frameshift.IdentityCLITest do
  @moduledoc false

  use ExUnit.Case, async: false

  alias Frameshift.IdentityCLI

  setup do
    names = ~w(FRAMESHIFT_SERVICE_UID FRAMESHIFT_CREDENTIAL_DIRECTORY)
    previous = Map.new(names, &{&1, System.get_env(&1)})
    Enum.each(names, &System.delete_env/1)

    on_exit(fn ->
      Enum.each(previous, fn
        {name, nil} -> System.delete_env(name)
        {name, value} -> System.put_env(name, value)
      end)
    end)

    :ok
  end

  test "help/version need no input or custody; exact command and canonical service policy refuse before input" do
    assert {0, help, ""} = IdentityCLI.run(["--help"], :unavailable)
    assert help =~ "Existing identity files are never replaced"

    assert {0, "frameshift-identity 0.1.0-dev\n", ""} =
             IdentityCLI.run(["--version"], :unavailable)

    for args <- [
          [],
          ["import", "/private/key.pem"],
          ["import", "--force"],
          ["export"],
          ["rotate"],
          nil
        ] do
      assert {64, "", _} = IdentityCLI.run(args, :unavailable)
    end

    for value <- ["", "0", "01", "+1", "1.0", "4294967295"] do
      System.put_env("FRAMESHIFT_SERVICE_UID", value)
      assert {64, "", _} = IdentityCLI.run(["import"], :unavailable)
    end

    System.put_env("FRAMESHIFT_SERVICE_UID", "1")
    System.put_env("FRAMESHIFT_CREDENTIAL_DIRECTORY", "/missing/private/directory")

    assert {69, "", "frameshift-identity: credential custody unavailable\n"} =
             IdentityCLI.run(["import"], :unavailable)
  end
end
