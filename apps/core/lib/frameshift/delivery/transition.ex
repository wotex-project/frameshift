defmodule Frameshift.Delivery.Transition do
  @moduledoc """
  Decides delivery transitions without performing storage or network I/O.

  `direct_request/4` chooses insertion, reuse or conflict for an existing push
  intent. `direct_confirmation/5` checks that the pending intent and observed
  artifact/profile identity match. `pull_confirmation/2` compares an outbox
  acknowledgement with the exact manifest revision and expected display result.

  ## Applying a decision

  The library's SQLite transaction owner reads authoritative records, invokes
  these pure rules and commits any resulting reference rotation. An accepted
  transport exchange alone cannot advance current or previous-known-good state.
  A mismatch or unresolved result retains the pending custody for reconciliation.

  Keeping decisions separate from I/O lets independent fixtures exercise stale
  revisions, duplicate requests and wrong digests without a live frame. Those
  fixtures establish transition semantics, not physical display completion.
  """

  @type direct_intent :: %{
          required(:request_id) => String.t(),
          required(:desired_digest) => String.t(),
          required(:profile_id) => String.t(),
          required(:status) => String.t(),
          optional(:revision) => pos_integer()
        }

  @doc "Chooses whether a push request reuses, conflicts with, or creates an intent."
  @spec direct_request(direct_intent() | nil, String.t(), String.t(), String.t()) ::
          :insert | {:reuse, direct_intent()} | {:error, atom()}
  def direct_request(nil, _, _, _), do: :insert

  def direct_request(existing, digest, profile_id, request_id) do
    cond do
      existing.request_id == request_id and existing.desired_digest == digest and
          existing.profile_id == profile_id ->
        {:reuse, existing}

      existing.request_id == request_id ->
        {:error, :request_id_conflict}

      existing.status == "pending" ->
        {:error, :direct_delivery_pending}

      true ->
        :insert
    end
  end

  @doc "Permits current-state activation only for the exact pending push intent."
  @spec direct_confirmation(
          direct_intent(),
          pos_integer(),
          String.t(),
          String.t(),
          :displayed | :pending
        ) :: :commit | :already | :pending | {:error, atom()}
  def direct_confirmation(
        %{
          revision: intent_revision,
          request_id: intent_request_id,
          desired_digest: intent_digest,
          status: intent_status
        },
        revision,
        request_id,
        digest,
        outcome
      )
      when outcome in [:displayed, :pending] do
    case :frameshift_decisions.direct_confirmation(
           intent_revision,
           intent_request_id,
           intent_digest,
           intent_status,
           revision,
           request_id,
           digest,
           Atom.to_string(outcome)
         ) do
      {:ok, :commit} -> :commit
      {:ok, :already} -> :already
      {:ok, :still_pending} -> :pending
      {:error, :conflict} -> {:error, :direct_delivery_conflict}
      {:error, :invalid_input} -> {:error, :invalid_direct_delivery}
    end
  end

  def direct_confirmation(_, _, _, _, _),
    do: {:error, :invalid_direct_delivery}

  @doc "Checks a pull acknowledgement against the one current manifest."
  @spec pull_confirmation(map(), map()) :: :commit | :pending | {:error, atom()}
  def pull_confirmation(manifest, acknowledgement)
      when is_map(manifest) and is_map(acknowledgement) do
    case :frameshift_decisions.pull_confirmation(
           manifest["revision"],
           manifest["desiredAsset"],
           acknowledgement["manifestRevision"],
           acknowledgement["currentAsset"],
           acknowledgement["storage"],
           acknowledgement["refresh"]
         ) do
      {:ok, :commit} -> :commit
      {:ok, :still_pending} -> :pending
      {:error, :conflict} -> {:error, :outbox_revision_conflict}
      {:error, :storage_not_verified} -> {:error, :storage_not_verified}
      {:error, :current_asset_mismatch} -> {:error, :current_asset_mismatch}
      {:error, :invalid_input} -> {:error, :invalid_acknowledgement}
    end
  end

  def pull_confirmation(_, _), do: {:error, :invalid_acknowledgement}
end
