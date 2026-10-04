defmodule Frameshift.Qualification.WorkStore do
  @moduledoc """
  Freezes accepted artwork work and its exact result under the library writer.

  `accept/5` checks the frame's active admitted binding in the same transaction
  that records master/recipe work identity. `record_result/3` binds that immutable
  work to the exact registered artifact; repeated incompatible results cannot
  rewrite previously accepted bytes.

  ## Delivery custody

  `delivery_binding/6` checks work, result, frame, artifact, profile and transfer
  mode before a delivery intent uses qualified output. Reads through `get/2` and
  `result/2` expose the retained records while connection ownership remains with
  `Frameshift.Library`.

  A later activation or cohort rollback changes admission for new work, not the
  identity/result of old work. Accepted work is not proof of a completed network
  mutation or displayed artwork; delivery confirmation remains a separate
  revision-bound transition with its own durable intent and recovery.
  """

  alias Frameshift.Diagnostics.Store, as: DiagnosticsStore
  alias Frameshift.Digest
  alias Frameshift.Library.Writer
  alias Frameshift.Qualification.Identity
  alias Frameshift.Qualification.Store, as: BindingStore

  @doc "Accepts one master and composition recipe under the still-active binding."
  @spec accept(pid(), String.t(), String.t(), String.t(), String.t()) ::
          {:ok, String.t()} | {:error, term()}
  def accept(connection, frame_id, binding_digest, master_digest, recipe_digest) do
    with true <- valid_frame?(frame_id),
         true <-
           Enum.all?([binding_digest, master_digest, recipe_digest], &Digest.valid_sha256?/1) do
      transact(connection, fn owner ->
        accept_in_transaction(owner, frame_id, binding_digest, master_digest, recipe_digest)
      end)
    else
      _ -> {:error, :invalid_qualified_work}
    end
  end

  @doc "Records the exact persisted artifact for one accepted work identity."
  @spec record_result(pid(), String.t(), String.t()) :: {:ok, String.t()} | {:error, term()}
  def record_result(connection, work_digest, artifact_digest) do
    with true <- Digest.valid_sha256?(work_digest) and Digest.valid_sha256?(artifact_digest) do
      transact(connection, &record_result_in_transaction(&1, work_digest, artifact_digest))
    else
      _ -> {:error, :invalid_qualified_result}
    end
  end

  @doc "Reads an accepted immutable work record."
  @spec get(pid(), String.t()) :: {:ok, map()} | :not_found
  def get(connection, digest) when is_binary(digest) do
    case Exqlite.query!(
           connection,
           """
           SELECT digest, binding_digest, frame_id, master_digest, recipe_digest,
                  manifest_json, accepted_at_ms
           FROM qualified_work WHERE digest = ?
           """,
           [digest]
         ).rows do
      [[digest, binding, frame, master, recipe, manifest_json, accepted_at]] ->
        {:ok,
         %{
           "digest" => digest,
           "binding_digest" => binding,
           "frame_id" => frame,
           "master_digest" => master,
           "recipe_digest" => recipe,
           "manifest" => Jason.decode!(manifest_json),
           "accepted_at_ms" => accepted_at
         }}

      [] ->
        :not_found
    end
  end

  def get(_, _), do: :not_found

  @doc "Reads the single immutable result for an accepted work identity."
  @spec result(pid(), String.t()) :: {:ok, map()} | :not_found
  def result(connection, work_digest) when is_binary(work_digest) do
    case Exqlite.query!(
           connection,
           """
           SELECT digest, artifact_digest, manifest_json, created_at_ms
           FROM qualified_results WHERE work_digest = ?
           """,
           [work_digest]
         ).rows do
      [[digest, artifact_digest, manifest_json, created_at]] ->
        {:ok,
         %{
           "digest" => digest,
           "work_digest" => work_digest,
           "artifact_digest" => artifact_digest,
           "manifest" => Jason.decode!(manifest_json),
           "created_at_ms" => created_at
         }}

      [] ->
        :not_found
    end
  end

  def result(_, _), do: :not_found

  @doc "Validates exact work/result custody for one frame delivery intent."
  @spec delivery_binding(pid(), String.t() | nil, String.t(), String.t(), String.t(), String.t()) ::
          {:ok, String.t() | nil} | {:error, term()}
  def delivery_binding(connection, nil, frame_id, _, _, _) do
    case BindingStore.active(connection, frame_id) do
      :not_found -> {:ok, nil}
      {:ok, _} -> {:error, :qualification_required}
    end
  end

  def delivery_binding(connection, work_digest, frame_id, artifact_digest, profile_id, mode) do
    with true <- Digest.valid_sha256?(work_digest),
         {:ok, %{"frame_id" => ^frame_id} = work} <- get(connection, work_digest),
         {:ok, %{"artifact_digest" => ^artifact_digest}} <- result(connection, work_digest),
         {:ok, %{"manifest" => manifest}} <- BindingStore.get(connection, work["binding_digest"]),
         true <- manifest["profileId"] == profile_id and manifest["transferMode"] == mode do
      {:ok, work["binding_digest"]}
    else
      _ -> {:error, :qualification_intent_mismatch}
    end
  end

  defp accept_in_transaction(owner, frame_id, binding_digest, master_digest, recipe_digest) do
    with {:ok, %{"digest" => ^binding_digest, "status" => "admitted"} = binding} <-
           BindingStore.active(owner, frame_id),
         :ok <- master_exists(owner, master_digest),
         :ok <- matching_recipe(owner, recipe_digest, master_digest, binding["manifest"]),
         {:ok, identity} <- Identity.work(binding_digest, master_digest, recipe_digest) do
      insert_work(owner, frame_id, identity)
    else
      :not_found -> {:error, :qualification_not_active}
      {:ok, _} -> {:error, :qualification_changed}
      error -> error
    end
  end

  defp master_exists(owner, digest) do
    case Exqlite.query!(
           owner,
           """
           SELECT m.digest FROM masters m JOIN objects o ON o.digest = m.digest
           WHERE m.digest = ? AND m.removed_at_ms IS NULL AND o.storage_state = 'active'
           """,
           [digest]
         ).rows do
      [[^digest]] -> :ok
      [] -> {:error, :master_missing}
    end
  end

  defp matching_recipe(owner, digest, master_digest, binding) do
    recipe =
      Exqlite.query!(owner, "SELECT kind, canonical_json FROM recipes WHERE hash = ?", [digest]).rows

    sources =
      Exqlite.query!(
        owner,
        "SELECT source_digest FROM recipe_sources WHERE recipe_hash = ? ORDER BY ordinal",
        [digest]
      ).rows

    case recipe do
      [["composition", json]] ->
        parameters = Jason.decode!(json)

        if sources == [[master_digest]] and
             parameters["profileId"] == binding["profileId"] and
             parameters["rendererRevision"] == binding["rendererAlgorithmRevision"] and
             parameters["rendererBuildDigest"] == binding["rendererBuildDigest"],
           do: :ok,
           else: {:error, :qualification_recipe_mismatch}

      _ ->
        {:error, :composition_recipe_missing}
    end
  end

  defp insert_work(owner, frame_id, identity) do
    document = identity.document

    inserted =
      Exqlite.query!(
        owner,
        """
        INSERT INTO qualified_work(
          digest, binding_digest, frame_id, master_digest, recipe_digest,
          manifest_json, accepted_at_ms
        ) VALUES (?, ?, ?, ?, ?, ?, ?)
        ON CONFLICT(digest) DO NOTHING RETURNING digest
        """,
        [
          identity.digest,
          document["bindingDigest"],
          frame_id,
          document["masterDigest"],
          document["recipeDigest"],
          identity.canonical_json,
          now_ms()
        ]
      )

    case inserted.rows do
      [[_]] ->
        DiagnosticsStore.record_audit(owner, "qualification.work_accepted", identity.digest, %{})
        {:ok, identity.digest}

      [] ->
        {:ok, identity.digest}
    end
  end

  defp record_result_in_transaction(owner, work_digest, artifact_digest) do
    with {:ok, work} <- fetch_work(owner, work_digest),
         {:ok, artifact} <- matching_artifact(owner, artifact_digest, work),
         {:ok, identity} <-
           Identity.result(
             work_digest,
             artifact_digest,
             artifact["byte_count"],
             artifact["media_type"]
           ) do
      insert_result(owner, identity)
    end
  end

  defp fetch_work(owner, digest) do
    case get(owner, digest) do
      {:ok, work} -> {:ok, work}
      :not_found -> {:error, :qualified_work_missing}
    end
  end

  defp matching_artifact(owner, digest, work) do
    binding = BindingStore.get(owner, work["binding_digest"])

    with {:ok, %{"manifest" => manifest}} <- binding,
         [[bytes, media]] <-
           Exqlite.query!(
             owner,
             """
             SELECT o.byte_count, o.media_type
             FROM artifact_recipe_links a JOIN objects o ON o.digest = a.artifact_digest
             WHERE a.artifact_digest = ? AND a.master_digest = ? AND a.recipe_hash = ?
               AND a.profile_id = ? AND a.renderer_revision = ?
               AND o.storage_state = 'active'
             """,
             [
               digest,
               work["master_digest"],
               work["recipe_digest"],
               manifest["profileId"],
               manifest["rendererAlgorithmRevision"]
             ]
           ).rows do
      {:ok, %{"byte_count" => bytes, "media_type" => media}}
    else
      _ -> {:error, :qualification_artifact_mismatch}
    end
  end

  defp insert_result(owner, identity) do
    document = identity.document

    inserted =
      Exqlite.query!(
        owner,
        """
        INSERT INTO qualified_results(
          digest, work_digest, artifact_digest, manifest_json, created_at_ms
        ) VALUES (?, ?, ?, ?, ?)
        ON CONFLICT(work_digest) DO NOTHING RETURNING digest
        """,
        [
          identity.digest,
          document["workDigest"],
          document["artifactDigest"],
          identity.canonical_json,
          now_ms()
        ]
      )

    case inserted.rows do
      [[_]] ->
        DiagnosticsStore.record_audit(
          owner,
          "qualification.result_recorded",
          identity.digest,
          %{}
        )

        {:ok, identity.digest}

      [] ->
        existing_result(owner, document["workDigest"], identity.digest)
    end
  end

  defp existing_result(owner, work_digest, digest) do
    case result(owner, work_digest) do
      {:ok, %{"digest" => ^digest}} -> {:ok, digest}
      _ -> {:error, :qualification_result_conflict}
    end
  end

  defp transact(connection, function) do
    connection
    |> Writer.transaction(function)
    |> Writer.unwrap()
  end

  defp valid_frame?(value),
    do: is_binary(value) and byte_size(value) in 1..128 and String.valid?(value)

  defp now_ms, do: System.os_time(:millisecond)
end
