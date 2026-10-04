defmodule FrameshiftPlatform.Catalog.RecordEvent do
  @moduledoc """
  Joins catalog creation to durable audit attribution and bounded telemetry.

  Configure the Ash change with `kind: :source` or `kind: :profile`.
  Its after-action hook records the corresponding event through
  `FrameshiftPlatform.Access.AuditEvent`, preserving the action's actor and new
  subject UUID. Audit errors propagate back to the originating create transaction.

  ## Outcome reporting

  The after-transaction hook emits one catalog stop event with only a count and
  fixed `:ok`/`:error` outcome. It returns the original result unchanged and does
  not retain source content, actor IDs or profile digests in metric labels.
  Telemetry measures action outcomes; it is not a durable audit ledger.
  """

  use Ash.Resource.Change
  alias FrameshiftPlatform.Access.AuditEvent

  @impl true
  def change(changeset, opts, context) do
    kind = Keyword.fetch!(opts, :kind)

    changeset
    |> Ash.Changeset.after_action(fn _, record -> record_event(record, kind, context.actor) end)
    |> Ash.Changeset.after_transaction(fn _, result -> emit_outcome(kind, result) end)
  end

  defp record_event(source, kind, actor) do
    event = if kind == :source, do: :source_recorded, else: :profile_recorded

    case Ash.create(AuditEvent, %{event: event, subject_id: source.id},
           action: :record,
           actor: actor
         ) do
      {:ok, _} -> {:ok, source}
      {:error, error} -> {:error, error}
    end
  end

  defp emit_outcome(kind, result) do
    outcome = if match?({:ok, _}, result), do: :ok, else: :error

    :telemetry.execute([:frameshift_platform, :catalog, kind, :stop], %{count: 1}, %{
      outcome: outcome
    })

    result
  end
end
