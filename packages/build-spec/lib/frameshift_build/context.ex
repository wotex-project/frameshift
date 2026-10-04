defmodule FrameshiftBuild.Context do
  @moduledoc """
  Resolves exact v1 assembly, profiles, signal mappings and artifact layouts.

  `resolve/4` admits each document list, enforces the combined byte budget and
  checks canonical identities with standard cryptography before the shared Gleam
  resolver binds references. It returns assembly identity, verified context,
  canonical combined bytes and a domain-separated compilation identity.

  ## Failure and ownership

  Malformed documents, count/budget excess, missing pins or incompatible references
  return stable binary refusal codes rather than a partial trusted context.
  Original bytes remain the identity input; the adapter does not normalize an
  unaccepted document into a different hash.

  Use `FrameshiftBuild.resolve_context/4` for the public package boundary.
  Resolution proves exact structural custody under the retained v1 contract, not
  manufacturer evidence, hardware fit or successor Conjunct conformance.
  """

  alias FrameshiftBuild.Documents

  @spec resolve(binary(), [binary()], [binary()]) :: {:ok, map()} | {:error, binary()}
  @spec resolve(binary(), [binary()], [binary()], [binary()]) :: {:ok, map()} | {:error, binary()}
  def resolve(bytes, profiles, mappings, layouts \\ [])

  def resolve(bytes, profiles, mappings, layouts) when is_binary(bytes) do
    with :ok <- Documents.input_types(profiles),
         :ok <- Documents.input_types(mappings),
         :ok <- Documents.input_types(layouts),
         {:ok, nil} <-
           Documents.normalize(
             :frameshift_build@resolution.complete_budget(bytes, profiles, mappings, layouts)
           ),
         {:ok, assembly} <- FrameshiftBuild.build_identity(bytes),
         {:ok, profiles} <- Documents.hash(profiles, &FrameshiftBuild.profile_identity/1),
         {:ok, mappings} <- Documents.hash(mappings, &FrameshiftBuild.mapping_identity/1),
         {:ok, layouts} <- Documents.hash(layouts, &FrameshiftBuild.layout_identity/1),
         {:ok, context} <-
           Documents.normalize(
             :frameshift_build@context.resolve_all(bytes, profiles, mappings, layouts)
           ),
         {:ok, canonical} <-
           Documents.normalize(:frameshift_build@context.canonical(assembly, context)) do
      identity =
        "sha256:" <>
          Base.encode16(:crypto.hash(:sha256, "frameshift.compilation.v1\n" <> canonical),
            case: :lower
          )

      {:ok,
       %{identity: identity, assembly_identity: assembly, canonical: canonical, context: context}}
    end
  end

  def resolve(_, _, _, _), do: {:error, "invalid_document"}
end
