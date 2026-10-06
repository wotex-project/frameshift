defmodule FrameshiftCore.MixProject do
  @moduledoc """
  Configures the native core's dependencies, release application and quality tools.

  The Mix project pins the supported Elixir/Wotex contract and declares the shared
  decision package plus storage, schema and transport dependencies. Application
  startup delegates to `Frameshift.Application`; loading project configuration
  does not start the library, renderer or IPC listeners.

  ## Development and documentation

  Aliases and preferred environments select the existing formatter, compiler,
  Credo, audit, Doctor, ExDoc, coverage and Dialyzer checks. Documentation includes
  owned architecture/research guides alongside the core API. Exact dependency
  constraints and operated-release qualification remain distinct from generated
  reference documentation; project metadata is build configuration, not a runtime API.
  """

  use Mix.Project

  @source_url "https://github.com/wotex-project/frameshift"
  @wotex_ref "c8c727a7c8c18fec82d80cc5ba88d246af3c67fc"

  def project do
    [
      app: :frameshift_core,
      version: "0.1.0-dev",
      elixir: "~> 1.20 and >= 1.20.2",
      start_permanent: Mix.env() == :prod,
      deps: deps(),
      aliases: aliases(),
      description: description(),
      docs: docs(),
      elixirc_options: [warnings_as_errors: true],
      name: "Frameshift Core",
      source_url: @source_url,
      homepage_url: @source_url,
      test_coverage: [tool: ExCoveralls],
      test_ignore_filters: [
        "test/frameshift/local_ipc/linux_peer_identity_contract.exs",
        "test/frameshift/local_ipc/linux_diagnostics_service.exs",
        "test/frameshift/local_ipc/linux_command_service.exs",
        "test/frameshift/local_ipc/linux_client_service.exs",
        "test/frameshift/local_ipc/linux_credential_service.exs",
        "test/frameshift/discovery/linux_avahi_join.exs",
        "test/frameshift/native_codec/linux_owner_join.exs",
        "test/frameshift/import/linux_receipt_join.exs",
        "test/frameshift/import/linux_upload_client.exs",
        "test/frameshift/import/linux_upload_contract.exs",
        "test/frameshift/import/linux_upload_service.exs",
        "test/frameshift/import/linux_cli_contract.exs",
        "test/frameshift/import/linux_full_disk.exs"
      ],
      dialyzer: dialyzer()
    ]
  end

  def application do
    [
      extra_applications: [:crypto, :logger, :ssl],
      mod: {Frameshift.Application, []}
    ]
  end

  def cli do
    [
      preferred_envs: [
        check: :test,
        coveralls: :test,
        "coveralls.detail": :test,
        "coveralls.html": :test,
        "coveralls.lcov": :test,
        doctor: :test,
        dialyzer: :test
      ]
    ]
  end

  defp deps do
    [
      {:frameshift_decisions, path: "../../packages/decision-kernel"},
      {:exqlite, "~> 0.42.0"},
      {:exile, "0.15.0"},
      {:telemetry, "~> 1.4"},
      {:telemetry_metrics, "~> 1.1"},
      {:jsv, "~> 0.25.0"},
      {:rfc8785, "~> 1.0.0"},
      {:mint, "~> 1.11.0"},
      {:wotex,
       git: "https://github.com/wotex-project/wotex.git",
       ref: @wotex_ref,
       sparse: "packages/wotex",
       override: true},
      {:wotex_binding_http,
       git: "https://github.com/wotex-project/wotex.git",
       ref: @wotex_ref,
       sparse: "packages/wotex-binding-http"},
      {:wotex_runtime,
       git: "https://github.com/wotex-project/wotex.git",
       ref: @wotex_ref,
       sparse: "packages/wotex-runtime",
       override: true},
      {:benchee, "~> 1.5", only: :dev, runtime: false},
      {:benchee_markdown, "~> 0.3.4", only: :dev, runtime: false},
      {:credo, "~> 1.7.19", only: [:dev, :test], runtime: false},
      {:dialyxir, "~> 1.4.8", only: [:dev, :test], runtime: false},
      {:doctor, "~> 0.22", only: [:dev, :test], runtime: false},
      {:ex_check, "~> 0.17", only: [:dev, :test], runtime: false},
      {:ex_doc, "~> 0.38", only: [:dev, :test, :docs], runtime: false},
      {:excoveralls, "~> 0.18", only: :test},
      {:mix_audit, "~> 2.1", only: [:dev, :test], runtime: false},
      {:stream_data, "~> 1.3", only: :test}
    ]
  end

  defp aliases do
    [
      bench: ["run --no-start bench/protocol_bench.exs"],
      lint: [
        "format --check-formatted",
        "compile --warnings-as-errors",
        "credo --strict",
        "dialyzer"
      ]
    ]
  end

  defp description do
    "Durable, vendor-neutral host runtime for universal Frameshift devices"
  end

  defp docs do
    [
      main: "readme",
      extras:
        [
          {"README.md", title: "Core overview"},
          {"../../docs/product-definition.md", title: "Product definition"},
          {"../../docs/architecture/system.md", title: "System architecture"},
          {"../../docs/architecture/build-platform.md", title: "Composition workbench"},
          {"../../docs/architecture/conjunct-integration.md", title: "Conjunct integration"},
          {"../../docs/architecture/producer-contracts.md", title: "Required library contracts"},
          {"../../docs/architecture/physical-build-contract.md",
           title: "Physical build contract"},
          {"../../docs/architecture/build-artifacts.md", title: "Build artifact layouts"},
          {"../../docs/architecture/build-orchestration.md", title: "Build orchestration"},
          {"../../docs/architecture/build-commerce.md", title: "Optional service integration"},
          {"../../docs/architecture/implementation-plan.md", title: "Implementation plan"},
          {"../../docs/hardware/bom.md", title: "Component bill of materials"},
          {"../../data/physical/README.md",
           title: "Sourced physical candidates", filename: "physical-candidates"},
          {"../../docs/research/build-platform-decisions.md", title: "Build platform decisions"},
          {"../../docs/research/conjunct-adoption.md", title: "Conjunct adoption"},
          {"../../docs/research/thin-composition-evidence.md",
           title: "Thin composition evidence"},
          {"../../docs/architecture/host-core.md", title: "Portable host core"},
          {"../../docs/architecture/library-backup.md", title: "Library backup and restore"},
          {"../../docs/architecture/container-frame-simulator.md",
           title: "Networked frame simulator"},
          {"../../docs/hardware/validation-plan.md", title: "Hardware validation plan"},
          {"../../docs/architecture/domain-map.md", title: "Host domain map"},
          {"../../docs/architecture/install-and-guide.md", title: "Installation and guide"},
          {"../../docs/architecture/guide-simulation.md", title: "Guide simulation"},
          {"../../docs/architecture/shared-decision-kernel.md", title: "Shared decision kernel"},
          {"../../docs/architecture/release-manifest.md", title: "Release artifact manifest"},
          {"../../docs/architecture/qualified-generations.md", title: "Qualified generations"},
          {"../../docs/architecture/diagnostics.md", title: "Host diagnostics"},
          {"../../docs/architecture/frame-protocol.md", title: "Frame protocol"},
          {"../../docs/architecture/display-timing.md", title: "Display timing"},
          {"../../docs/architecture/verification.md", title: "Verification map"},
          {"../../docs/research/software-stack.md", title: "Software stack research"},
          {"../../docs/research/embedded-persistence.md", title: "Embedded persistence"},
          {"../../docs/research/hardware-platforms.md", title: "Hardware platform research"},
          {"../../docs/host/linux.md", title: "Linux host"},
          {"../../docs/host/macos.md", title: "macOS host"},
          {"../../docs/host/guide-handoff.md", title: "Guide handoff"},
          {"../../docs/research/protocol-foundations.md", title: "Protocol foundations"}
        ] ++ Path.wildcard("bench/output/*.md"),
      groups_for_extras: [
        Architecture: ~r/docs\/architecture/,
        Benchmarks: ~r/bench\/output/
      ],
      source_url: @source_url,
      formatters: ["html"]
    ]
  end

  defp dialyzer do
    [
      plt_add_apps: [:mix, :ex_unit],
      plt_file: {:no_warn, "priv/plts/frameshift_core.plt"},
      flags: [:error_handling, :missing_return]
    ]
  end
end
