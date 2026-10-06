[input_path, output_path, module_name, directory] = System.argv()
module = Module.concat([module_name])
{:module, ^module} = Code.ensure_loaded(module)
beam = module |> :code.which() |> to_string() |> File.read!()

File.write!(
  Path.join(directory, "elixir-beam-actual.etf"),
  :erlang.term_to_binary({module, beam}),
  [:exclusive]
)

{:module, :frameshift_build@compiler@properties} =
  Code.ensure_loaded(:frameshift_build@compiler@properties)

registry_beam =
  :frameshift_build@compiler@properties |> :code.which() |> to_string() |> File.read!()

File.write!(
  Path.join(directory, "registry-beam-actual.etf"),
  :erlang.term_to_binary({:frameshift_build@compiler@properties, registry_beam}),
  [:exclusive]
)

original = input_path |> File.read!() |> JSON.decode!()
operations = %{"quantity" => :quantity, "transform" => :transform, "local_id" => :local_id}

invoke = fn hand ->
  result = apply(module, Map.fetch!(operations, hand["operation"]), hand["args"])

  case result do
    {:ok, value} -> %{"ok" => true, "value" => value}
    {:error, error} -> %{"ok" => false, "error" => error}
  end
end

hands = Enum.map(original["cases"], &%{"id" => &1["id"], "actual" => invoke.(&1)})

properties =
  Enum.map(original["properties"], fn property ->
    %{"id" => property["id"], "actual" => invoke.(property)}
  end)

preflight = Enum.map(original["smoke"], &%{"id" => &1["id"], "actual" => invoke.(&1)})

samples =
  for repeat <- 1..2, hand <- original["smoke"] do
    before = System.monotonic_time(:nanosecond)
    actual = invoke.(hand)
    elapsed = System.monotonic_time(:nanosecond) - before
    %{"id" => hand["id"], "repeat" => repeat, "elapsed_ns" => elapsed, "actual" => actual}
  end

runtime = %{
  elixir: System.version(),
  otp: :erlang.system_info(:otp_release) |> to_string(),
  architecture: :erlang.system_info(:system_architecture) |> to_string()
}

File.write!(
  output_path,
  JSON.encode!(%{
    runtime: runtime,
    hands: hands,
    properties: properties,
    preflight: preflight,
    samples: samples
  }),
  [
    :exclusive
  ]
)

IO.puts("Complete Elixir adapter observations retained before comparison")
