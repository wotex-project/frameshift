defmodule FrameshiftPlatform.MixProject do
  @moduledoc """
  Configures the independent Phoenix/Ash companion application's build.

  The project selects product/shared-package paths, the exact Refpath and
  AshPostgres source pins and their compatible numerical/native dependencies.
  Application startup delegates to `FrameshiftPlatform.Application`; the platform
  owns its PostgreSQL database separately from native artwork SQLite custody.

  ## Quality and environments

  Test compilation includes support modules and the test alias creates/migrates
  its isolated database before ExUnit. The check alias runs format, warning-free
  compilation, tests and strict Credo. Narrow dependency-advisory exceptions retain
  their explicit reachability record; they do not suppress unrelated findings.
  Frontend contract/build checks remain in the repository's platform lane.
  """

  use Mix.Project

  def project do
    [
      app: :frameshift_platform,
      version: "0.1.0-dev",
      elixir: "~> 1.20",
      elixirc_paths: elixirc_paths(Mix.env()),
      start_permanent: Mix.env() == :prod,
      elixirc_options: [warnings_as_errors: true],
      # Current paths use Bandit/Req and guarded Gun headers, never cowlib encoders.
      # See the scoped reachability record and DependencyBoundaryTest.
      hex: [
        ignore_advisories: [
          "EEF-CVE-2026-43966",
          "EEF-CVE-2026-43969",
          "GHSA-w4f7-4cxr-rv3c"
        ]
      ],
      aliases: aliases(),
      deps: deps()
    ]
  end

  def application do
    [mod: {FrameshiftPlatform.Application, []}, extra_applications: [:logger, :crypto]]
  end

  def cli, do: [preferred_envs: [check: :test]]

  defp elixirc_paths(:test), do: ["lib", "test/support"]
  defp elixirc_paths(_), do: ["lib"]

  defp deps do
    [
      {:frameshift_decisions, path: "../../packages/decision-kernel"},
      {:frameshift_build, path: "../../packages/build-spec"},
      {:refpath,
       git: "https://github.com/refpath/refpath.git",
       ref: "ee60f58cb885f8fe6875ce9468b0c6ffdb5496c0"},
      # Match the researched runtime's numerical ABI; newer Axon requires Nx 1.
      {:axon, "0.8.1"},
      {:scholar, "0.4.1"},
      {:nx, "0.12.1"},
      # BAML uses its precompiled NIF; Refpath builds native code with Rustler 0.38.
      {:rustler, "0.38.0", runtime: false, override: true},
      {:phoenix, "~> 1.8.15"},
      {:phoenix_assets, "~> 1.1.1"},
      {:ash, "~> 3.34.4"},
      {:ash_authentication, "4.15.0"},
      {:argon2_elixir, "4.1.3"},
      {:ash_postgres,
       git: "https://github.com/futhr/ash_postgres.git",
       ref: "528177429ab9bd72ab6ee7bfdf278f94c9fd8252",
       override: true},
      {:simple_sat, "~> 0.1"},
      {:postgrex, "~> 0.22"},
      {:bandit, "~> 1.12"},
      {:jason, "~> 1.4"},
      {:beamlens, "~> 0.3.1"},
      {:req, "~> 0.6"},
      {:telemetry_metrics, "~> 1.1"},
      {:prometheus, "~> 6.1.3"},
      {:telemetry_poller, "~> 1.3"},
      {:credo, "~> 1.7.19", only: [:dev, :test], runtime: false},
      {:stream_data, "~> 1.3"}
    ]
  end

  defp aliases do
    [
      "ecto.setup": ["ecto.create", "ecto.migrate"],
      test: ["ecto.create --quiet", "ecto.migrate --quiet", "test"],
      check: [
        "format --check-formatted",
        "compile --warnings-as-errors",
        "test",
        "credo --strict"
      ]
    ]
  end
end
