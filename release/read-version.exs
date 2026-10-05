Mix.start()
Mix.env(:prod)
[project_root] = System.argv()

version =
  Mix.Project.in_project(:frameshift_core, project_root, fn _ ->
    if Mix.Project.config()[:app] != :frameshift_core do
      raise "application identity unavailable"
    end

    Mix.Project.config()[:version]
  end)

if is_binary(version) do
  IO.puts("frameshift-release-version:" <> version)
else
  raise "application version unavailable"
end
