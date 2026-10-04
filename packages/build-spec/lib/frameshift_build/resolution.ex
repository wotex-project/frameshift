defmodule FrameshiftBuild.Resolution do
  @moduledoc """
  Resolves the exact profiles pinned by a retained v1 assembly.

  `resolve/2` accepts assembly bytes and a bounded list of canonical profile
  bytes. It applies shared count/byte limits, verifies assembly/profile identities
  with standard SHA-256 and invokes the shared Gleam reference resolver. Success
  returns the assembly identity and verified resolution; failures keep stable
  binary refusal codes.

  ## Scope

  No catalog lookup, network fetch or mutable source fallback occurs here.
  Callers supply the exact pinned bytes; missing, malformed or conflicting inputs
  cannot be replaced by another revision with a similar label.
  `FrameshiftBuild.Context` extends resolution with mappings/layouts and their
  combined identity. Neither path grants physical qualification or build admission.
  """

  alias FrameshiftBuild.Documents

  @spec resolve(binary(), [binary()]) :: {:ok, map()} | {:error, binary()}
  def resolve(bytes, profiles) when is_binary(bytes) and is_list(profiles) do
    with :ok <- Documents.input_types(profiles),
         {:ok, nil} <- Documents.normalize(:frameshift_build@resolution.budget(bytes, profiles)),
         {:ok, identity} <- FrameshiftBuild.build_identity(bytes),
         {:ok, pairs} <- Documents.hash(profiles, &FrameshiftBuild.profile_identity/1),
         {:ok, resolution} <-
           Documents.normalize(:frameshift_build@resolution.resolve(bytes, pairs)) do
      {:ok, %{identity: identity, resolution: resolution}}
    end
  end

  def resolve(_, _), do: {:error, "invalid_document"}
end
