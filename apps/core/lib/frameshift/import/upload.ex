defmodule Frameshift.Import.Upload do
  @moduledoc """
  Coordinates two private original-byte uploads and one owned native codec.

  Start with a protected `:codec_path`, the existing Library and bounded task
  supervisor. Startup failure leaves import unavailable while the host's Library
  and diagnostics continue. Each public call requires the kernel actor supplied
  by the Linux IPC boundary; these writer-side APIs do not authenticate callers.
  A random token binds one actor, canonical source intent and frozen codec build.

  ## Intake and finish

  `begin_upload/3` checks the durable actor/hash receipt before allocating bytes.
  An exact active begin returns its acknowledged offset. `append/5` accepts only
  canonical padded base64, strictly ordered 1–6144-byte chunks and the admitted
  total. Idle and absolute intake deadlines never release a finishing task.
  `finish/3` seals and verifies originals, invokes the pinned codec and admits
  its immutable package through the sole Library writer. Decoder metadata alone
  supplies dimensions, media, orientation and source-color provenance.

  Completed receipts replay without another decode or restoration. Pending
  receipts remain unknown. No lost reply, codec refusal or stage is retried
  automatically. `cancel/3` removes only known intake/failed custody; it cannot
  undo an admitted finish. Status recovery reads the Library independently.

  ## Failure and recovery

  Abrupt owner/task death or unknown custody retains the replacement fence.
  Normal shutdown waits briefly for actual task completion and stops the linked
  codec; unresolved work retains its files. A replacement refuses abandoned
  custody rather than adopting or deleting it. Operator recovery requires the
  complete service/native process to be stopped. Stages, tokens and source bytes
  are redacted from OTP status/crash reports and never persisted in receipts.
  Installed filesystem, service and memory limits require separate evidence.
  """

  use GenServer

  alias Frameshift.Import.Intent
  alias Frameshift.Import.Stage
  alias Frameshift.Library
  alias Frameshift.MasterPackage
  alias Frameshift.NativeCodec

  @idle_ms 30_000
  @absolute_ms 600_000
  @maximum_leases 2
  @token_pattern ~r/\A[0-9a-f]{64}\z/

  @type server :: GenServer.server()

  @doc "Starts an upload owner whose admission failure does not stop the Library."
  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(options) do
    case Keyword.get(options, :name, __MODULE__) do
      nil -> GenServer.start_link(__MODULE__, options)
      name -> GenServer.start_link(__MODULE__, options, name: name)
    end
  end

  @doc "Observes replay or allocates one exclusive actor-bound upload."
  @spec begin_upload(server(), map(), non_neg_integer()) :: {:ok, map()} | {:error, term()}
  def begin_upload(server, intent, actor), do: GenServer.call(server, {:begin, intent, actor})

  @doc "Appends one bounded chunk only at the previously acknowledged offset."
  @spec append(server(), String.t(), non_neg_integer(), String.t(), non_neg_integer()) ::
          {:ok, map()} | {:error, atom()}
  def append(server, token, offset, bytes, actor),
    do: GenServer.call(server, {:append, token, offset, bytes, actor})

  @doc "Explicitly finishes one complete source; caller timeout does not cancel its effects."
  @spec finish(server(), String.t(), non_neg_integer()) :: {:ok, map()} | {:error, term()}
  def finish(server, token, actor), do: GenServer.call(server, {:finish, token, actor}, 35_000)

  @doc "Discards known pre-effect intake while refusing active or uncertain finishes."
  @spec cancel(server(), String.t(), non_neg_integer()) :: {:ok, map()} | {:error, atom()}
  def cancel(server, token, actor), do: GenServer.call(server, {:cancel, token, actor})

  @impl true
  def init(options) do
    Process.flag(:trap_exit, true)

    state = %{
      library: Keyword.get(options, :library, Library),
      tasks: Keyword.get(options, :task_supervisor, Frameshift.TaskSupervisor),
      directory: nil,
      codec: nil,
      digest: nil,
      leases: %{},
      unavailable: true,
      unknown: false
    }

    case Stage.prepare() do
      {:ok, directory} -> {:ok, start_codec(%{state | directory: directory}, options)}
      {:error, _} -> {:ok, state}
    end
  end

  defp start_codec(state, options) do
    options = [name: nil, path: Keyword.get(options, :codec_path), task_supervisor: state.tasks]

    case NativeCodec.start_link(options) do
      {:ok, codec} ->
        %{state | codec: codec, digest: NativeCodec.build_digest(codec), unavailable: false}

      {:error, _} ->
        state
    end
  end

  @impl true
  def handle_call({:begin, intent, actor}, _, state) do
    state = expire_intake(state)

    with :ok <- validate_actor(actor),
         {:ok, hash} <- Intent.identity(intent),
         :not_found <- Library.command_receipt_as(state.library, intent["id"], actor, hash) do
      begin_new(state, intent, hash, actor)
    else
      {:ok, receipt} -> {:reply, replay(receipt), state}
      {:error, reason} -> {:reply, {:error, reason}, state}
    end
  catch
    _, _ -> {:reply, {:error, :import_unavailable}, state}
  end

  def handle_call({:append, token, offset, encoded, actor}, _, state) do
    state = expire_intake(state)

    with {:ok, lease} <- lookup(state, token, actor),
         :ok <- intake(lease),
         {:ok, bytes} <- decode_chunk(encoded),
         :ok <- chunk_offset(lease, offset, bytes),
         {:ok, stage} <- Stage.append(lease.stage, bytes) do
      lease = %{lease | stage: stage, touched: now()}
      {:reply, {:ok, projection(token, lease)}, put_lease(state, token, lease)}
    else
      {:error, :import_stage_unavailable} -> fail_stage(state, token)
      {:error, reason} -> {:reply, {:error, reason}, state}
    end
  end

  def handle_call({:finish, token, actor}, from, state) do
    state = expire_intake(state)

    with {:ok, lease} <- lookup(state, token, actor),
         :ok <- intake(lease),
         true <- lease.stage.offset == lease.intent["sourceByteCount"] do
      start_finish(state, token, lease, from)
    else
      false -> {:reply, {:error, :import_incomplete}, state}
      {:error, reason} -> {:reply, {:error, reason}, state}
    end
  end

  def handle_call({:cancel, token, actor}, _, state) do
    with {:ok, lease} <- lookup(state, token, actor),
         :ok <- cancellable(lease),
         :ok <- Stage.discard(lease.stage) do
      {:reply, {:ok, %{"status" => "cancelled"}}, drop_lease(state, token)}
    else
      {:error, reason} -> {:reply, {:error, reason}, state}
    end
  end

  @impl true
  def handle_info({reference, {result, custody}}, state) when is_reference(reference) do
    case task_lease(state, reference) do
      {token, lease} ->
        Process.demonitor(reference, [:flush])
        GenServer.reply(lease.from, result)
        {:noreply, finish_result(state, token, lease, custody)}

      nil ->
        {:noreply, state}
    end
  end

  def handle_info({:DOWN, reference, :process, _, _}, state) do
    case task_lease(state, reference) do
      {token, lease} ->
        GenServer.reply(lease.from, {:error, :command_outcome_unknown})
        lease = %{lease | phase: :unknown, task: nil, from: nil}
        {:noreply, %{put_lease(state, token, lease) | unavailable: true, unknown: true}}

      nil ->
        {:noreply, state}
    end
  end

  def handle_info({:expire, token}, state) do
    case Map.get(state.leases, token) do
      %{phase: phase} when phase in [:intake, :failed] ->
        state = expire_intake(state)
        if Map.has_key?(state.leases, token), do: schedule_expiry(token, state.leases[token])
        {:noreply, state}

      _ ->
        {:noreply, state}
    end
  end

  def handle_info({:EXIT, codec, _}, %{codec: codec} = state),
    do: {:noreply, %{state | codec: nil, unavailable: true, unknown: true}}

  def handle_info(_, state), do: {:noreply, state}

  @impl true
  def terminate(_, state) do
    resolved = Enum.all?(state.leases, fn {_, lease} -> resolved?(lease) end)
    codec_stopped = stop_codec(state.codec)

    if resolved and codec_stopped and not state.unknown and state.directory do
      Enum.each(state.leases, fn {_, lease} -> Stage.discard(lease.stage) end)
      Stage.release(state.directory)
    end

    :ok
  end

  @impl true
  def format_status(status) do
    status
    |> Map.put(:message, :redacted)
    |> Map.put(:log, [:redacted])
    |> Map.put(:state, :redacted)
    |> Map.put(:reason, :import_owner_failure)
  end

  defp begin_new(state, intent, hash, actor) do
    case Enum.find(state.leases, fn {_, lease} -> lease.intent["id"] == intent["id"] end) do
      {token, %{hash: ^hash, actor: ^actor} = lease} ->
        {:reply, active_projection(token, lease), state}

      {_, _} ->
        {:reply, {:error, :command_id_conflict}, state}

      nil ->
        allocate(state, intent, hash, actor)
    end
  end

  defp allocate(%{unavailable: true} = state, _, _, _),
    do: {:reply, {:error, :import_unavailable}, state}

  defp allocate(state, _, _, _) when map_size(state.leases) >= @maximum_leases,
    do: {:reply, {:error, :import_busy}, state}

  defp allocate(state, intent, hash, actor) do
    case Stage.create(state.directory) do
      {:ok, stage} ->
        token = Base.encode16(:crypto.strong_rand_bytes(32), case: :lower)

        lease = %{
          stage: stage,
          intent: intent,
          hash: hash,
          actor: actor,
          digest: state.digest,
          phase: :intake,
          created: now(),
          touched: now(),
          task: nil,
          from: nil
        }

        schedule_expiry(token, lease)
        {:reply, {:ok, projection(token, lease)}, put_lease(state, token, lease)}

      {:error, _} ->
        {:reply, {:error, :import_unavailable}, %{state | unavailable: true, unknown: true}}
    end
  end

  defp start_finish(state, token, lease, from) do
    context = Map.take(state, [:library, :codec])

    task =
      Task.Supervisor.async_nolink(state.tasks, fn ->
        NativeCodec.LogPrivacy.mark_current()
        finish_import(context, lease)
      end)

    lease = %{lease | phase: :finishing, task: task, from: from}
    {:noreply, put_lease(state, token, lease)}
  rescue
    _ -> {:reply, {:error, :import_unavailable}, state}
  catch
    _, _ -> {:reply, {:error, :import_unavailable}, state}
  end

  defp finish_import(state, lease) do
    with {:ok, original} <-
           Stage.seal(lease.stage, lease.intent["sourceByteCount"], lease.intent["sourceDigest"]),
         {:ok, normalized} <- NativeCodec.normalize(state.codec, original, lease.digest),
         {:ok, package} <-
           MasterPackage.encode(original, normalized.rgba, normalized.width, normalized.height) do
      result =
        Library.import_master_command_as(
          state.library,
          package,
          attributes(lease, normalized),
          lease.intent["id"],
          lease.hash,
          lease.actor
        )

      {result, :complete}
    else
      {:error, reason}
      when reason in [
             :codec_custody_unknown,
             :codec_worker_unavailable,
             :import_stage_unavailable
           ] ->
        {{:error, reason}, :unknown}

      {:error, reason} ->
        {{:error, reason}, :retryable}
    end
  rescue
    _ -> {{:error, :command_outcome_unknown}, :unknown}
  catch
    _, _ -> {{:error, :command_outcome_unknown}, :unknown}
  end

  defp attributes(lease, normalized) do
    %{
      title: lease.intent["title"],
      source_kind: :import,
      width: normalized.width,
      height: normalized.height,
      media_type: MasterPackage.media_type(),
      orientation: 1,
      color_profile: "sRGB",
      provenance: %{
        "kind" => "local-import",
        "originalFilename" => lease.intent["originalFilename"],
        "originalMediaType" => normalized.original_media_type,
        "originalOrientation" => normalized.original_orientation,
        "sourceDigest" => lease.intent["sourceDigest"],
        "colorInterpretation" => normalized.color_interpretation,
        "sourceColorDigest" => normalized.source_color_digest,
        "codecRevision" => normalized.codec_revision,
        "codecDigest" => normalized.codec_digest
      }
    }
  end

  defp finish_result(state, token, lease, :complete) do
    case Stage.discard(lease.stage) do
      :ok -> drop_lease(state, token)
      _ -> unknown_lease(state, token, lease)
    end
  end

  defp finish_result(state, token, lease, :retryable) do
    lease = %{lease | phase: :intake, task: nil, from: nil, touched: now()}
    schedule_expiry(token, lease)
    put_lease(state, token, lease)
  end

  defp finish_result(state, token, lease, :unknown), do: unknown_lease(state, token, lease)

  defp unknown_lease(state, token, lease),
    do: %{
      put_lease(state, token, %{lease | phase: :unknown, task: nil, from: nil})
      | unavailable: true,
        unknown: true
    }

  defp fail_stage(state, token) do
    lease = %{state.leases[token] | phase: :failed}
    {:reply, {:error, :import_stage_unavailable}, put_lease(state, token, lease)}
  end

  defp lookup(state, token, actor) do
    with :ok <- validate_actor(actor),
         true <- is_binary(token) and Regex.match?(@token_pattern, token),
         %{actor: ^actor} = lease <- Map.get(state.leases, token) do
      {:ok, lease}
    else
      _ -> {:error, :invalid_upload_token}
    end
  end

  defp intake(%{phase: :intake}), do: :ok
  defp intake(%{phase: :failed}), do: {:error, :import_stage_unavailable}
  defp intake(%{phase: :unknown}), do: {:error, :command_outcome_unknown}
  defp intake(_), do: {:error, :import_busy}

  defp cancellable(%{phase: phase}) when phase in [:intake, :failed], do: :ok
  defp cancellable(%{phase: :unknown}), do: {:error, :command_outcome_unknown}
  defp cancellable(_), do: {:error, :import_busy}

  defp decode_chunk(encoded) when is_binary(encoded) and byte_size(encoded) in 4..8_192 do
    with {:ok, bytes} <- Base.decode64(encoded),
         true <- byte_size(bytes) in 1..6_144 and Base.encode64(bytes) == encoded do
      {:ok, bytes}
    else
      _ -> {:error, :invalid_import_chunk}
    end
  end

  defp decode_chunk(_), do: {:error, :invalid_import_chunk}

  defp chunk_offset(lease, offset, bytes) do
    if is_integer(offset) and offset == lease.stage.offset and
         offset + byte_size(bytes) <= lease.intent["sourceByteCount"],
       do: :ok,
       else: {:error, :invalid_import_offset}
  end

  defp validate_actor(actor) when is_integer(actor) and actor in 0..4_294_967_294, do: :ok
  defp validate_actor(_), do: {:error, :invalid_import_actor}

  defp replay(%{"status" => "pending"}), do: {:error, :command_outcome_unknown}
  defp replay(%{"status" => "failed", "errorCode" => code}), do: {:error, code}

  defp replay(%{"status" => "succeeded", "importedItemID" => digest} = receipt)
       when is_binary(digest), do: {:ok, receipt}

  defp replay(_), do: {:error, :command_id_conflict}

  defp active_projection(token, %{phase: :intake} = lease), do: {:ok, projection(token, lease)}
  defp active_projection(_, lease), do: intake(lease)

  defp projection(token, lease),
    do: %{"status" => "uploading", "uploadToken" => token, "offset" => lease.stage.offset}

  defp put_lease(state, token, lease), do: %{state | leases: Map.put(state.leases, token, lease)}
  defp drop_lease(state, token), do: %{state | leases: Map.delete(state.leases, token)}

  defp task_lease(state, reference),
    do: Enum.find(state.leases, fn {_, lease} -> lease.task && lease.task.ref == reference end)

  defp expire_intake(state) do
    Enum.reduce(state.leases, state, fn {token, lease}, current ->
      if lease.phase in [:intake, :failed] and expired?(lease),
        do: expire_lease(current, token, lease),
        else: current
    end)
  end

  defp expire_lease(state, token, lease) do
    case Stage.discard(lease.stage) do
      :ok -> drop_lease(state, token)
      _ -> unknown_lease(state, token, lease)
    end
  end

  defp expired?(lease),
    do: now() - lease.touched >= @idle_ms or now() - lease.created >= @absolute_ms

  defp schedule_expiry(token, lease),
    do:
      Process.send_after(
        self(),
        {:expire, token},
        max(1, min(@idle_ms - (now() - lease.touched), @absolute_ms - (now() - lease.created)))
      )

  defp now, do: System.monotonic_time(:millisecond)

  defp resolved?(%{phase: :unknown}), do: false
  defp resolved?(%{task: nil}), do: true

  defp resolved?(%{task: task}),
    do: match?({:ok, {_, custody}} when custody != :unknown, Task.yield(task, 1_000))

  defp stop_codec(nil), do: true

  defp stop_codec(codec) do
    GenServer.stop(codec, :normal, 2_000)
    true
  catch
    _, _ -> false
  end
end
