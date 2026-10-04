defmodule FrameshiftPlatform.Catalog.SeedImport do
  @moduledoc """
  Imports reviewed local source and profile candidates with explicit attribution.

  `run/2` reads a schema-1 `manifest.json`, records source revisions first and
  then validates each profile file against its pinned metadata. The supplied
  `FrameshiftPlatform.Access.Actor` must have an admitted catalog-writing role.
  Success returns source/profile counts; unauthorized input or any conflicting
  revision stops the import with an error.

  ## Retry and file bounds

  Identical existing sources/profiles are reused, making a partial import
  retryable. The whole manifest is not one transaction: earlier successful
  records remain if a later item fails. Each create retains its own atomic audit.
  Files must be regular and at most 256 KiB; profile paths must match the exact
  ID/revision naming convention. No remote source is fetched and candidates are
  not promoted to physical qualification.

  The administrative `Mix.Tasks.Frameshift.SeedCatalog` task supplies the actor
  and directory explicitly; application startup never imports seeds implicitly.
  """

  alias FrameshiftPlatform.Access.Actor
  alias FrameshiftPlatform.Catalog

  @spec run(String.t(), Actor.t()) :: {:ok, map()} | {:error, term()}
  def run(directory, %Actor{} = actor) when is_binary(directory) do
    with true <- Actor.allowed?(actor, [:catalog_editor, :research_worker]),
         {:ok, manifest} <- manifest(directory),
         :ok <- record_sources(manifest["sources"], actor),
         :ok <- record_profiles(manifest["profiles"], directory, actor) do
      {:ok, %{sources: length(manifest["sources"]), profiles: length(manifest["profiles"])}}
    else
      false -> {:error, :unauthorized}
      {:error, error} -> {:error, error}
    end
  end

  def run(_, _), do: {:error, :unauthorized}

  defp manifest(directory) do
    with {:ok, bytes} <- bounded_read(Path.join(directory, "manifest.json")),
         {:ok, %{"schema" => 1, "sources" => sources, "profiles" => profiles} = manifest} <-
           Jason.decode(bytes),
         true <- is_list(sources) and length(sources) in 1..1_024,
         true <- is_list(profiles) and length(profiles) in 1..256 do
      {:ok, manifest}
    else
      _ -> {:error, :invalid_seed_manifest}
    end
  end

  defp record_sources(sources, actor) do
    Enum.reduce_while(sources, :ok, fn source, :ok -> continue(record_source(source, actor)) end)
  end

  defp record_source(%{"retrieved_at" => time} = source, actor) when is_binary(time) do
    with {:ok, observed_at, 0} <- DateTime.from_iso8601(time),
         {:ok, %{results: existing}} <-
           Catalog.list_sources(
             query: [filter: [uri: source["url"], revision: source["revision"]]],
             page: [limit: 1]
           ) do
      persist_source(existing, source, observed_at, actor)
    else
      _ -> {:error, :invalid_source_observation}
    end
  end

  defp record_source(_, _), do: {:error, :invalid_source_observation}

  defp persist_source([existing], source, _, _) do
    if existing.content_sha256 == source["digest"] and existing.kind == :manufacturer,
      do: :ok,
      else: {:error, :source_revision_conflict}
  end

  defp persist_source([], source, observed_at, actor) do
    Catalog.record_source(
      %{
        title: source["title"],
        uri: source["url"],
        revision: source["revision"],
        content_sha256: source["digest"],
        kind: :manufacturer,
        observed_at: observed_at
      },
      actor: actor
    )
    |> normalize()
  end

  defp record_profiles(profiles, directory, actor) do
    Enum.reduce_while(profiles, :ok, fn profile, :ok ->
      continue(record_profile(profile, directory, actor))
    end)
  end

  defp record_profile(profile, directory, actor) do
    with true <- valid_path?(profile),
         {:ok, canonical} <- bounded_read(Path.join(directory, profile["file"])),
         {:ok, metadata} <- FrameshiftBuild.inspect_profile(canonical),
         true <- matches_entry?(metadata, profile),
         {:ok, existing} <- Catalog.get_profile(metadata.identity, not_found_error?: false) do
      persist_profile(existing, profile, canonical, actor)
    else
      _ -> {:error, :invalid_seed_profile}
    end
  end

  defp valid_path?(%{"id" => id, "revision" => revision, "file" => file})
       when is_binary(id) and is_binary(revision) do
    token = ~r/\A[A-Za-z0-9][A-Za-z0-9._+-]{0,95}\z/

    Regex.match?(token, id) and Regex.match?(token, revision) and
      file == "profiles/#{id}.#{revision}.json"
  end

  defp valid_path?(_), do: false

  defp matches_entry?(metadata, profile) do
    metadata.identity == profile["identity"] and metadata.profile_key == profile["id"] and
      metadata.profile_revision == profile["revision"] and
      profile["evidence_state"] == "candidate"
  end

  defp persist_profile(nil, entry, canonical, actor),
    do:
      Catalog.record_profile(%{label: entry["label"], canonical: canonical}, actor: actor)
      |> normalize()

  defp persist_profile(existing, _, canonical, _) do
    if existing.canonical == canonical, do: :ok, else: {:error, :profile_revision_conflict}
  end

  defp bounded_read(path) do
    with {:ok, %{type: :regular}} <- File.lstat(path),
         {:ok, bytes} when is_binary(bytes) <-
           File.open(path, [:read, :binary], &IO.binread(&1, 262_145)),
         true <- byte_size(bytes) <= 262_144 do
      {:ok, bytes}
    else
      _ -> {:error, :invalid_seed_file}
    end
  end

  defp normalize({:ok, _}), do: :ok
  defp normalize({:error, error}), do: {:error, error}
  defp continue(:ok), do: {:cont, :ok}
  defp continue({:error, error}), do: {:halt, {:error, error}}
end
