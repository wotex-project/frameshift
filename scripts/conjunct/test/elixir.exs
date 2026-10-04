ExUnit.start()

defmodule Frameshift.ConjunctConsumerTest do
  @moduledoc false

  use ExUnit.Case, async: false

  setup_all do
    [bundle, target, report] = System.argv()

    {:ok, manifest} =
      bundle |> Path.join("manifest.json") |> File.read!() |> Conjunct.Wire.decode()

    cohort = manifest["cohort"]
    executable = Path.join([bundle, "native", target, "conjunct-port"])
    file = Enum.find(manifest["files"], &(&1["path"] == "native/#{target}/conjunct-port"))

    {:ok,
     bundle: bundle,
     cohort: cohort,
     executable: executable,
     digest: file["digest"],
     report: report}
  end

  test "passive packages, exact data and port results", context do
    ports = Port.list()

    for app <- [:conjunct_kernel, :conjunct_wire, :conjunct_data] do
      assert Application.spec(app, :mod) == []
      assert {:ok, _} = Application.ensure_all_started(app)
    end

    assert Port.list() == ports
    server = start_supervised!({Conjunct.Kernel.Port, options(context)})
    assert {:ok, bytes} = Conjunct.Kernel.describe(server)
    {:ok, discovery} = Conjunct.Wire.decode(bytes)
    assert discovery["protocol"] == context.cohort["protocol"]
    assert discovery["implementation"]["source_revision"] == context.cohort["revision"]

    assert [
             %{
               "contract" => contract,
               "profiles" => profiles,
               "operations" => operations,
               "readable_schemas" => schemas
             }
           ] = discovery["contracts"]

    assert contract == context.cohort["contract"]
    assert profiles == context.cohort["profiles"]
    assert operations == context.cohort["operations"]
    assert schemas == context.cohort["readable_schemas"]

    schema = "urn:conjunct:schema:domain:0.1"
    scope = fixture("scope.json")
    unsupported = fixture("unsupported.json")
    duplicate = fixture("duplicate.json")
    assert {:ok, value} = Conjunct.Data.decode_bytes(scope, schema)
    assert {:ok, canonical} = Conjunct.Data.encode_canonical(value, schema)
    assert {:ok, id} = Conjunct.Data.artifact_id(value, schema)

    assert {:error, %{errors: [%{code: :unsupported_profile}]}} =
             Conjunct.Data.decode_bytes(unsupported, schema)

    assert {:error, %{errors: [%{code: :duplicate_key}]}} =
             Conjunct.Data.decode_bytes(duplicate, schema)

    assert {:error, %{errors: [%{code: :arithmetic_overflow}]}} =
             Conjunct.Data.read_rational(%{"n" => "9223372036854775808", "d" => "1"})

    configuration = File.read!("configuration.json")

    assert {:ok, %{context: kernel, response: created}} =
             Conjunct.Kernel.create(server, configuration)

    refute is_nil(kernel)
    assert decode(created)["result"]["limits"] == context.cohort["limits"]
    assert {:ok, loaded} = Conjunct.Kernel.load(kernel, scope)
    assert decode(loaded)["outcome"] == "completed"
    assert {:ok, refused} = Conjunct.Kernel.load(kernel, unsupported)
    assert "unsupported_profile" in codes(refused)
    assert {:ok, malformed} = Conjunct.Kernel.load(kernel, duplicate)
    assert "duplicate_key" in codes(malformed)

    assert {:ok, oversized} =
             Conjunct.Kernel.load(
               kernel,
               :binary.copy(<<0>>, context.cohort["limits"]["document_bytes"] + 1)
             )

    assert decode(oversized)["outcome"] == "incomplete"
    assert "limit_exceeded" in codes(oversized)

    assert {:ok, %{context: nil, response: wrong_contract}} =
             Conjunct.Kernel.create(server, File.read!("wrong-contract.json"))

    assert "unsupported_contract" in codes(wrong_contract)
    assert {:ok, source} = Conjunct.Kernel.load(kernel, fixture("profile-probe-source.json"))
    assert decode(source)["outcome"] == "completed"
    assert {:ok, control} = Conjunct.Kernel.load(kernel, fixture("present-rule.json"))
    assert decode(control)["outcome"] == "completed"

    assert {:ok, unsupported_flow} =
             Conjunct.Kernel.load(kernel, fixture("directed-flow-rule.json"))

    assert decode(unsupported_flow)["outcome"] == "refused"

    assert Enum.any?(
             decode(unsupported_flow)["diagnostics"],
             &(&1["code"] == "schema_violation" and &1["path"] == "/body/rules/0")
           )

    assert :ok = Conjunct.Kernel.destroy(kernel)

    report = %{
      "artifact_id" => id,
      "canonical" => canonical,
      "frame_profile_available" => false,
      "responses" => [
        created,
        loaded,
        refused,
        malformed,
        oversized,
        wrong_contract,
        source,
        control,
        unsupported_flow
      ]
    }

    {:ok, bytes} = Conjunct.Wire.encode_canonical(report)
    File.write!(context.report, bytes)
  end

  test "altered executable is refused before spawning", context do
    Process.flag(:trap_exit, true)
    ports = Port.list()

    assert {:error, _} =
             Conjunct.Kernel.Port.start_link(
               Keyword.put(
                 options(context),
                 :executable_digest,
                 "sha256:" <> String.duplicate("0", 64)
               )
             )

    assert Port.list() == ports
  end

  test "replacement invalidates contexts and requires explicit recreation", context do
    server = start_supervised!({Conjunct.Kernel.Port, options(context)})

    assert {:ok, %{context: old}} =
             Conjunct.Kernel.create(server, File.read!("configuration.json"))

    assert {:ok, _} = Conjunct.Kernel.load(old, fixture("scope.json"))
    :ok = stop_supervised(Conjunct.Kernel.Port)
    assert {:error, :stale_context} = Conjunct.Kernel.load(old, fixture("scope.json"))
    replacement = start_supervised!({Conjunct.Kernel.Port, options(context)})

    assert {:ok, %{context: fresh}} =
             Conjunct.Kernel.create(replacement, File.read!("configuration.json"))

    assert fresh.generation != old.generation
    assert {:ok, loaded} = Conjunct.Kernel.load(fresh, fixture("scope.json"))
    assert decode(loaded)["outcome"] == "completed"
  end

  defp options(context) do
    [
      executable: context.executable,
      executable_digest: context.digest,
      request_timeout: context.cohort["binding"]["timeout_ms"],
      max_queue: context.cohort["binding"]["max_queue"]
    ]
  end

  defp fixture(name), do: File.read!(Path.join("fixtures", name))

  defp decode(bytes) do
    {:ok, value} = Conjunct.Wire.decode(bytes)
    value
  end

  defp codes(bytes), do: Enum.map(decode(bytes)["diagnostics"], & &1["code"])
end
