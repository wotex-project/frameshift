[input_path, output_path, module_name, directory] = System.argv()
module = Module.concat([module_name])
{:module, ^module} = Code.ensure_loaded(module)
beam = module |> :code.which() |> to_string() |> File.read!()

File.write!(Path.join(directory, "beam-actual.etf"), :erlang.term_to_binary({module, beam}), [
  :exclusive
])

original = input_path |> File.read!() |> JSON.decode!()

invoke = fn hand ->
  case apply(module, :import, hand["args"]) do
    {:ok, value} -> %{"ok" => true, "value" => value}
    {:error, error} -> %{"ok" => false, "error" => error}
  end
end

observe = fn hands -> Enum.map(hands, &%{"id" => &1["id"], "actual" => invoke.(&1)}) end
hands = observe.(original["cases"])
properties = observe.(original["properties"])
preflight = observe.(original["smoke"])

samples =
  for repeat <- 1..5, hand <- original["smoke"] do
    before = System.monotonic_time(:nanosecond)
    actual = invoke.(hand)
    elapsed = System.monotonic_time(:nanosecond) - before
    %{"id" => hand["id"], "repeat" => repeat, "elapsed_ns" => elapsed, "actual" => actual}
  end

File.write!(
  output_path,
  JSON.encode!(%{hands: hands, properties: properties, preflight: preflight, samples: samples}) <>
    "\n",
  [:exclusive]
)
