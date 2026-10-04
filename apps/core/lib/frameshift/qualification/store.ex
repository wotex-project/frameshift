defmodule Frameshift.Qualification.Store do
  @moduledoc """
  Persists candidate, admitted and active render/transfer bindings.

  `register/2` checks canonical binding identity, executable software contract and
  matching paired frame/profile before retaining a candidate. `admit/3` adds exact
  bounded software evidence; `activate/3` selects an admitted binding for new work
  on its frame. Those are separate transitions, never implicit promotion.

  ## Atomic selection

  `activate_cohort/2` validates and promotes an exact set in one transaction;
  a failure leaves every active pointer unchanged. `get/2` and `active/2` read
  candidate/current records without returning a writable connection to callers.
  Existing accepted work keeps its original binding when active selection changes.

  This module is invoked through `Frameshift.Library` and shares its writer and
  audit transaction. It qualifies the recorded software binding scope, not the
  frame's physical installation. Unsupported revisions, mismatched frame/profile
  custody and missing admission evidence refuse before activation.
  """

  alias Frameshift.Diagnostics.Store, as: DiagnosticsStore
  alias Frameshift.Digest
  alias Frameshift.Library.Writer
  alias Frameshift.Qualification.Contract
  alias Frameshift.Qualification.Identity
  alias Frameshift.Qualification.Profile

  @doc "Stores one validated candidate without silently admitting or activating it."
  @spec register(pid(), map()) :: {:ok, String.t()} | {:error, term()}
  def register(connection, document) do
    with {:ok, identity} <- Identity.binding(document),
         :ok <- Contract.validate(document),
         :ok <- matching_frame_profile(connection, document) do
      transact(connection, &insert_candidate(&1, identity))
    end
  end

  @doc "Admits a candidate with an exact bounded software conformance record."
  @spec admit(pid(), String.t(), map()) :: :ok | {:error, term()}
  def admit(connection, digest, evidence) do
    with true <- Digest.valid_sha256?(digest),
         {:ok, canonical_evidence} <- Identity.software_evidence(evidence),
         {:ok, binding} <- get(connection, digest),
         :ok <- Contract.validate(binding["manifest"]),
         :ok <- matching_frame_profile(connection, binding["manifest"]) do
      admission_transition(connection, binding, canonical_evidence)
    else
      false -> {:error, :invalid_qualification}
      :not_found -> {:error, :qualification_missing}
      error -> error
    end
  end

  @doc "Activates an admitted binding for new work on its exact frame."
  @spec activate(pid(), String.t(), String.t()) :: :ok | {:error, term()}
  def activate(connection, frame_id, digest) do
    with true <- is_binary(frame_id) and byte_size(frame_id) in 1..128,
         true <- Digest.valid_sha256?(digest),
         {:ok, %{"frame_id" => ^frame_id, "status" => "admitted"} = binding} <-
           get(connection, digest),
         :ok <- Contract.validate(binding["manifest"]),
         :ok <- matching_frame_profile(connection, binding["manifest"]) do
      transact(connection, &activate_binding(&1, frame_id, digest))
    else
      false -> {:error, :invalid_qualification}
      :not_found -> {:error, :qualification_missing}
      {:ok, _} -> {:error, :qualification_not_admitted}
      error -> error
    end
  end

  @doc "Promotes an exact admitted cohort in one transaction, or leaves every pointer unchanged."
  @spec activate_cohort(pid(), term()) :: :ok | {:error, term()}
  def activate_cohort(connection, selections)
      when is_list(selections) and length(selections) in 1..64 do
    with :ok <- validate_cohort_shape(selections),
         :ok <- unique_cohort_frames(selections),
         :ok <- validate_cohort_bindings(connection, selections) do
      transact(connection, &activate_cohort_bindings(&1, selections))
    end
  end

  def activate_cohort(_, _), do: {:error, :invalid_qualification_cohort}

  defp activate_cohort_bindings(owner, selections) do
    Enum.each(selections, fn {frame_id, digest} ->
      activate_binding(owner, frame_id, digest)
    end)

    :ok
  end

  defp validate_cohort_shape(selections) do
    if Enum.all?(selections, fn
         {frame_id, digest} ->
           is_binary(frame_id) and byte_size(frame_id) in 1..128 and
             Digest.valid_sha256?(digest)

         _ ->
           false
       end),
       do: :ok,
       else: {:error, :invalid_qualification_cohort}
  end

  defp unique_cohort_frames(selections) do
    frame_ids = Enum.map(selections, &elem(&1, 0))

    if length(frame_ids) == MapSet.size(MapSet.new(frame_ids)),
      do: :ok,
      else: {:error, :duplicate_qualification_frame}
  end

  defp validate_cohort_bindings(connection, selections) do
    Enum.reduce_while(selections, :ok, &validate_cohort_binding(connection, &1, &2))
  end

  defp validate_cohort_binding(connection, {frame_id, digest}, :ok) do
    case get(connection, digest) do
      {:ok, %{"frame_id" => ^frame_id, "status" => "admitted"} = binding} ->
        binding
        |> validate_active_binding(connection)
        |> continue_or_halt()

      {:ok, %{"frame_id" => ^frame_id}} ->
        {:halt, {:error, :qualification_not_admitted}}

      {:ok, _} ->
        {:halt, {:error, :qualification_frame_mismatch}}

      :not_found ->
        {:halt, {:error, :qualification_missing}}
    end
  end

  defp validate_active_binding(binding, connection) do
    with :ok <- Contract.validate(binding["manifest"]),
         do: matching_frame_profile(connection, binding["manifest"])
  end

  defp continue_or_halt(:ok), do: {:cont, :ok}
  defp continue_or_halt(error), do: {:halt, error}

  @doc "Returns one candidate/admitted binding without exposing the database owner."
  @spec get(pid(), String.t()) :: {:ok, map()} | :not_found
  def get(connection, digest) when is_binary(digest) do
    case Exqlite.query!(
           connection,
           """
           SELECT digest, frame_id, profile_id, manifest_json, status,
                  evidence_json, created_at_ms, admitted_at_ms
           FROM qualified_bindings WHERE digest = ?
           """,
           [digest]
         ).rows do
      [
        [
          digest,
          frame_id,
          profile_id,
          manifest_json,
          status,
          evidence_json,
          created_at,
          admitted_at
        ]
      ] ->
        {:ok,
         %{
           "digest" => digest,
           "frame_id" => frame_id,
           "profile_id" => profile_id,
           "manifest" => Jason.decode!(manifest_json),
           "status" => status,
           "evidence" => if(evidence_json, do: Jason.decode!(evidence_json), else: nil),
           "created_at_ms" => created_at,
           "admitted_at_ms" => admitted_at
         }}

      [] ->
        :not_found
    end
  end

  def get(_, _), do: :not_found

  @doc "Returns the active admitted binding for new work on one frame."
  @spec active(pid(), String.t()) :: {:ok, map()} | :not_found
  def active(connection, frame_id) when is_binary(frame_id) do
    case Exqlite.query!(
           connection,
           "SELECT binding_digest FROM active_qualifications WHERE frame_id = ?",
           [frame_id]
         ).rows do
      [[digest]] -> get(connection, digest)
      [] -> :not_found
    end
  end

  def active(_, _), do: :not_found

  defp insert_candidate(owner, identity) do
    document = identity.document

    inserted =
      Exqlite.query!(
        owner,
        """
        INSERT INTO qualified_bindings(
          digest, frame_id, profile_id, manifest_json, status, created_at_ms
        ) VALUES (?, ?, ?, ?, 'candidate', ?)
        ON CONFLICT(digest) DO NOTHING RETURNING digest
        """,
        [
          identity.digest,
          document["frameId"],
          document["profileId"],
          identity.canonical_json,
          now_ms()
        ]
      )

    case inserted.rows do
      [[_]] ->
        DiagnosticsStore.record_audit(owner, "qualification.candidate", identity.digest, %{})
        {:ok, identity.digest}

      [] ->
        existing_candidate(owner, identity)
    end
  end

  defp activate_binding(owner, frame_id, digest) do
    case active(owner, frame_id) do
      {:ok, %{"digest" => ^digest}} ->
        :ok

      _ ->
        Exqlite.query!(
          owner,
          """
          INSERT INTO active_qualifications(frame_id, binding_digest, activated_at_ms)
          VALUES (?, ?, ?)
          ON CONFLICT(frame_id) DO UPDATE SET
            binding_digest = excluded.binding_digest,
            activated_at_ms = excluded.activated_at_ms
          """,
          [frame_id, digest, now_ms()]
        )

        DiagnosticsStore.record_audit(owner, "qualification.activated", digest, %{})
        :ok
    end
  end

  defp matching_frame_profile(connection, document) do
    case Exqlite.query!(
           connection,
           "SELECT td_json, capabilities_json FROM paired_frames WHERE frame_id = ?",
           [document["frameId"]]
         ).rows do
      [[td_json, capabilities_json]] ->
        capabilities = Jason.decode!(capabilities_json)

        with true <- document["thingDescriptionDigest"] == Digest.sha256(td_json),
             true <- document["transferMode"] in capabilities["transferModes"],
             {:ok, profile_digest} <- Profile.digest(capabilities, document["profileId"]),
             true <- document["profileDigest"] == profile_digest,
             {:ok, binding_digest} <-
               Profile.binding_digest(
                 td_json,
                 document["transferMode"],
                 document["connectorRevision"]
               ),
             true <- document["bindingDigest"] == binding_digest do
          :ok
        else
          _ -> {:error, :qualification_frame_mismatch}
        end

      [] ->
        {:error, :frame_not_paired}
    end
  end

  defp existing_candidate(connection, identity) do
    case Exqlite.query!(
           connection,
           "SELECT manifest_json FROM qualified_bindings WHERE digest = ?",
           [identity.digest]
         ).rows do
      [[canonical_json]] when canonical_json == identity.canonical_json -> {:ok, identity.digest}
      _ -> {:error, :qualification_identity_conflict}
    end
  end

  defp admission_transition(_, %{"status" => "admitted", "evidence" => evidence}, canonical)
       when is_map(evidence) do
    if RFC8785.encode!(evidence) == canonical,
      do: :ok,
      else: {:error, :qualification_evidence_conflict}
  end

  defp admission_transition(connection, %{"status" => "candidate", "digest" => digest}, canonical) do
    transact(connection, fn owner ->
      Exqlite.query!(
        owner,
        """
        UPDATE qualified_bindings
        SET status = 'admitted', evidence_json = ?, admitted_at_ms = ?
        WHERE digest = ? AND status = 'candidate'
        """,
        [canonical, now_ms(), digest]
      )

      DiagnosticsStore.record_audit(owner, "qualification.admitted", digest, %{})
      :ok
    end)
  end

  defp admission_transition(_, _, _), do: {:error, :qualification_not_candidate}

  defp transact(connection, function) do
    connection
    |> Writer.transaction(function)
    |> Writer.unwrap()
  end

  defp now_ms, do: System.os_time(:millisecond)
end
