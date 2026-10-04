defmodule FrameshiftBuild.MixProject do
  @moduledoc """
  Configures the retained physical-planning package and its shared-code build.

  The project compiles Gleam before Elixir and the application artifact so Elixir
  adapters call the same codecs and checks as the browser path. It depends on the
  shared decision package and uses standard OTP cryptography for exact identities.
  This project configuration does not start a compiler service or product host.

  ## Build ownership

  `Mix.Tasks.Compile.GleamBuildSpec` copies admitted generated BEAM modules from
  the package sources plus its JSON runtime. Test modules remain outside the
  installed application. The package retains v1 replay/migration behavior;
  qualified Conjunct integration is a separate consumer delivery gate.
  """

  use Mix.Project

  def project do
    [
      app: :frameshift_build,
      version: "0.1.0",
      elixir: "~> 1.20",
      compilers: [:gleam_build_spec, :elixir, :app],
      elixirc_options: [warnings_as_errors: true],
      deps: [
        {:frameshift_decisions, path: "../decision-kernel"},
        {:credo, "1.7.19", only: [:dev, :test], runtime: false}
      ]
    ]
  end

  def application, do: [extra_applications: [:crypto]]
end

defmodule Mix.Tasks.Compile.GleamBuildSpec do
  @moduledoc """
  Builds and installs the retained BuildSpec Gleam modules for Mix consumers.

  The compiler requires the selected `gleam` executable and runs an Erlang-target
  build with warnings treated as errors. Nonzero exit status raises a Mix error
  with the compiler output rather than publishing partially generated modules.

  ## Installed modules

  The task removes previously generated non-Elixir BEAM files, copies modules
  corresponding to current package sources and includes the required Gleam JSON
  runtime. It preserves the Elixir adapter modules in the compile directory.
  Source-path naming determines generated module names; test-only modules are not
  copied into the product artifact. This is build-time tooling, not runtime I/O.
  """

  use Mix.Task

  @root __DIR__
  @generated Path.join(@root, "build/dev/erlang")

  def run(_) do
    executable = System.find_executable("gleam") || Mix.raise("Gleam is required")

    {output, status} =
      System.cmd(executable, ["build", "--target", "erlang", "--warnings-as-errors"],
        cd: @root,
        stderr_to_stdout: true
      )

    if status != 0, do: Mix.raise("BuildSpec Gleam build failed:\n#{output}")
    File.mkdir_p!(Mix.Project.compile_path())
    remove_generated_modules()
    Enum.each(Path.wildcard(Path.join(@root, "src/**/*.gleam")), &copy_source/1)
    Enum.each(Path.wildcard(Path.join(@generated, "gleam_json/ebin/*.beam")), &copy_beam/1)
    {:ok, []}
  end

  defp remove_generated_modules do
    Mix.Project.compile_path()
    |> Path.join("*.beam")
    |> Path.wildcard()
    |> Enum.reject(&String.starts_with?(Path.basename(&1), "Elixir."))
    |> Enum.each(&File.rm!/1)
  end

  defp copy_source(source) do
    beam =
      source
      |> Path.relative_to(Path.join(@root, "src"))
      |> Path.rootname()
      |> String.replace("/", "@")
      |> Kernel.<>(".beam")

    copy_beam(Path.join([@generated, "frameshift_build", "ebin", beam]))
  end

  defp copy_beam(source) do
    File.cp!(source, Path.join(Mix.Project.compile_path(), Path.basename(source)))
  end
end
