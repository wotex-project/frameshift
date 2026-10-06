defmodule FrameshiftRelease.MixProject do
  @moduledoc """
  Builds the independent portable release policy tool.

  ## Boundaries

  This Mix project uses pinned Elixir/OTP and no host application dependencies.
  `FrameshiftRelease.Input` delegates descriptor custody to the separately built
  Zig worker under `worker/`. Release schemas and trust remain Elixir concerns;
  no worker, NIF or tool dependency is shipped in the application.
  """

  use Mix.Project

  def project do
    [
      app: :frameshift_release,
      version: "0.1.0",
      elixir: "~> 1.20",
      deps: [],
      escript: [main_module: FrameshiftRelease.CLI, name: "frameshift-release"]
    ]
  end

  def application, do: [extra_applications: [:crypto, :public_key]]
end
