defmodule FrameshiftDecisions.MixProject do
  @moduledoc """
  Configures the shared pure decision package for Mix consumers.

  The project invokes the Gleam compiler before creating the OTP application
  artifact and declares no additional runtime applications. Its source package
  also builds for JavaScript so native host and browser guide decisions can share
  the same defined rules and parity fixtures.

  ## Boundary

  `Mix.Tasks.Compile.Gleam` installs generated Erlang modules and the required
  Gleam standard library. Project loading starts no process and performs no
  product decision. Native/guide rules and retained v1 replay keep their existing
  owner; generic successor composition belongs to Conjunct, not a second engine.
  """

  use Mix.Project

  def project do
    [
      app: :frameshift_decisions,
      version: "0.1.0",
      compilers: [:gleam, :app],
      deps: []
    ]
  end

  def application, do: [extra_applications: []]
end

defmodule Mix.Tasks.Compile.Gleam do
  @moduledoc """
  Installs the shared decision kernel's Erlang build into the Mix artifact.

  The task locates the selected Gleam executable, builds the package with
  warnings as errors and raises a Mix error if the build fails. It creates the
  compile destination and replaces stale generated BEAMs before copying current
  source modules and the selected Gleam standard-library runtime.

  ## Build scope

  Generated module names derive from package-relative source paths. The compiler
  operates at build time; it does not start a host, interpreter service or decision
  process. JavaScript output and cross-target parity are checked by their separate
  repository lane rather than inferred from this Erlang-target build succeeding.
  """

  use Mix.Task

  @root __DIR__
  @ebin Path.join(@root, "build/dev/erlang/frameshift_decisions/ebin")
  @stdlib Path.join(@root, "build/dev/erlang/gleam_stdlib/ebin")

  def run(_) do
    executable = System.find_executable("gleam") || Mix.raise("Gleam is required")

    {output, status} =
      System.cmd(executable, ["build", "--target", "erlang", "--warnings-as-errors"],
        cd: @root,
        stderr_to_stdout: true
      )

    if status != 0, do: Mix.raise("Gleam build failed:\n#{output}")

    File.mkdir_p!(Mix.Project.compile_path())

    Mix.Project.compile_path()
    |> Path.join("*.beam")
    |> Path.wildcard()
    |> Enum.each(&File.rm!/1)

    @root
    |> Path.join("src/**/*.gleam")
    |> Path.wildcard()
    |> Enum.each(&copy_module/1)

    @stdlib
    |> Path.join("*.beam")
    |> Path.wildcard()
    |> Enum.each(&File.cp!(&1, Path.join(Mix.Project.compile_path(), Path.basename(&1))))

    {:ok, []}
  end

  defp copy_module(source) do
    beam =
      source
      |> Path.relative_to(Path.join(@root, "src"))
      |> Path.rootname()
      |> String.replace("/", "@")
      |> Kernel.<>(".beam")

    File.cp!(Path.join(@ebin, beam), Path.join(Mix.Project.compile_path(), beam))
  end
end
