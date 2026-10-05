[root, expected] = System.argv()

unless String.match?(expected, ~r/\A[0-9A-Za-z.+-]{1,32}\z/) do
  raise "runtime version refused"
end

[erts, ^expected] = root |> Path.join("releases/start_erl.data") |> File.read!() |> String.split()
release = Path.join([root, "releases", expected, "frameshift_core.rel"])
application = Path.join([root, "lib", "frameshift_core-" <> expected, "ebin/frameshift_core.app"])

{:ok, [{:release, {~c"frameshift_core", version}, {:erts, erts_version}, applications}]} =
  :file.consult(String.to_charlist(release))

^expected = List.to_string(version)
^erts = List.to_string(erts_version)
{_, ^version, _} = List.keyfind(applications, :frameshift_core, 0)

{:ok, [{:application, :frameshift_core, properties}]} =
  :file.consult(String.to_charlist(application))

^version = Keyword.fetch!(properties, :vsn)
IO.puts("runtime version: verified")
