defmodule Frameshift.Library do
  @moduledoc """
  Serializes native library metadata and immutable content relationships.

  The GenServer owns the SQLite connection and data root. Public operations
  import masters, register canonical recipes and rendered artifacts, retain
  source lineage, manage labels/search/pins and apply recoverable removal.
  Callers receive records and verified bytes, never the writable connection.

  ## Using the owner

  Start with `start_link/1` and a private `:data_dir`; a `:name` of `nil` allows
  an explicitly addressed isolated instance. Pass that server to library APIs
  when operating outside the application-owned default. Storage changes run
  through `Frameshift.Library.Writer`; payload placement is delegated to
  `Frameshift.ContentStore` and startup reconciles interrupted file moves.

  Paired-frame custody, qualification/work records, command receipts, outboxes
  and playlists use this same writer so reference protection and state changes
  share authoritative transactions. Exact revisions and acknowledgements govern
  delivery: desired bytes are distinct from current and previous-known-good art.

  ## Maintenance and diagnostics

  New master/artifact bytes are admitted under the durable registered-object
  budget before placement. Trash remains accounted; lowering the limit preserves
  existing bytes and permits read/restore while refusing additional objects.

  Removal preserves protected/recoverable objects rather than deleting referenced
  content. Backup creation serializes changes for its full copy; offline restore
  requires the stopped-library maintenance path. Bounded audit/metric projections
  remain read-only and omit private credentials and source paths. Database errors
  return through the storage boundary; programming faults are not fabricated as
  successful writes. The web platform owns a separate database and lifecycle.
  """

  use GenServer

  alias Frameshift.ContentStore
  alias Frameshift.Delivery.Transition
  alias Frameshift.Diagnostics.Store, as: DiagnosticsStore
  alias Frameshift.Digest
  alias Frameshift.FrameRegistry
  alias Frameshift.Library.Backup
  alias Frameshift.Library.Identity
  alias Frameshift.Library.Metadata
  alias Frameshift.Library.Migrations
  alias Frameshift.Library.Storage
  alias Frameshift.Library.Writer
  alias Frameshift.Playlist.Store, as: PlaylistStore
  alias Frameshift.Protocol.Schema
  alias Frameshift.Qualification.Store, as: QualificationStore
  alias Frameshift.Qualification.WorkStore

  @type server :: GenServer.server()
  @type digest :: String.t()
  @maximum_read_bytes 128 * 1024 * 1024

  @frame_roles ["desired", "current", "previous-known-good", "queued", "playlist"]

  defmodule State do
    @moduledoc """
    Keeps the private SQLite connection and content root for one library owner.

    Both fields are required and remain inside `Frameshift.Library` callbacks.
    Public library calls return metadata, verified bytes or bounded projections,
    never this writable connection. Transaction helpers receive it only while
    executing under the same serialized owner.

    ## Restart and storage

    The content root names durable filesystem custody, while the connection is a
    process-lifetime handle reopened during startup. Passing this struct to IPC,
    the web platform or another writer would violate ownership; callers select
    the library server rather than constructing replacement state.
    """

    @type t :: %__MODULE__{connection: term(), data_dir: String.t()}

    @enforce_keys [:connection, :data_dir]
    defstruct [:connection, :data_dir]
  end

  @doc "Starts the single SQLite owner in the configured data directory."
  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(options) do
    case Keyword.get(options, :name, __MODULE__) do
      nil -> GenServer.start_link(__MODULE__, options)
      name -> GenServer.start_link(__MODULE__, options, name: name)
    end
  end

  @doc "Stores an immutable master and its metadata, deduplicated by content digest."
  @spec import_master(server(), iodata(), map()) :: {:ok, map()} | {:error, term()}
  def import_master(server \\ __MODULE__, bytes, attributes) do
    GenServer.call(server, {:import_master, bytes, attributes}, :infinity)
  end

  @doc "Records a canonical recipe identity and its source lineage."
  @spec register_recipe(server(), :generation | :composition, map(), [digest()]) ::
          {:ok, digest()} | {:error, term()}
  def register_recipe(server \\ __MODULE__, kind, parameters, source_digests \\ []) do
    GenServer.call(server, {:register_recipe, kind, parameters, source_digests})
  end

  @doc "Adds a generated variant linked to its parent and generation recipe."
  @spec add_generated_variant(server(), iodata(), map(), digest(), digest()) ::
          {:ok, map()} | {:error, term()}
  def add_generated_variant(
        server \\ __MODULE__,
        bytes,
        attributes,
        parent_digest,
        generation_recipe_hash
      ) do
    GenServer.call(
      server,
      {:add_generated_variant, bytes, attributes, parent_digest, generation_recipe_hash},
      :infinity
    )
  end

  @doc "Adds generated bytes as a master associated with a recipe."
  @spec add_generated_master(server(), iodata(), map(), digest()) ::
          {:ok, map()} | {:error, term()}
  def add_generated_master(server \\ __MODULE__, bytes, attributes, generation_recipe_hash) do
    GenServer.call(
      server,
      {:add_generated_master, bytes, attributes, generation_recipe_hash},
      :infinity
    )
  end

  @doc "Looks up a completed generation by canonical recipe digest."
  @spec cached_generation(server(), digest()) :: {:ok, map()} | :not_found
  def cached_generation(server \\ __MODULE__, recipe_hash) do
    GenServer.call(server, {:cached_generation, recipe_hash})
  end

  @doc "Stores rendered artifact bytes with their recipe and target profile identity."
  @spec register_artifact(server(), iodata(), map()) :: {:ok, map()} | {:error, term()}
  def register_artifact(server \\ __MODULE__, bytes, attributes) do
    GenServer.call(server, {:register_artifact, bytes, attributes}, :infinity)
  end

  @doc "Finds an artifact only when recipe, profile, and renderer revision all match."
  @spec cached_artifact(server(), digest(), String.t(), String.t()) :: {:ok, map()} | :not_found
  def cached_artifact(server \\ __MODULE__, recipe_hash, profile_id, renderer_revision) do
    GenServer.call(server, {:cached_artifact, recipe_hash, profile_id, renderer_revision})
  end

  @doc "Attaches a searchable label with explicit provenance and optional confidence."
  @spec add_label(server(), digest(), String.t(), atom(), number() | nil, String.t() | nil) ::
          :ok | {:error, term()}
  def add_label(
        server \\ __MODULE__,
        digest,
        label,
        provenance,
        confidence \\ nil,
        revision \\ nil
      ) do
    GenServer.call(server, {:add_label, digest, label, provenance, confidence, revision})
  end

  @doc """
  Searches active masters with literal text and intersecting read-only facets.

  Options include `:pinned` (boolean), `:source_kind` (`"import"` or `"generated"`)
  and `:frame_id` (retained master/artifact custody). `:limit` is capped at 100;
  ordering remains pinned-first, then title and digest. Removed masters are
  excluded even when references retain their bytes. Invalid facets return no
  matches; the native product boundary returns an explicit request refusal.
  """
  @spec search(server(), String.t(), keyword()) :: [map()]
  def search(server \\ __MODULE__, query, options \\ []) do
    GenServer.call(server, {:search, query, options})
  end

  @doc "Rebuilds the derived title and label index under the single writer."
  @spec rebuild_search_index(server()) :: :ok | {:error, term()}
  def rebuild_search_index(server \\ __MODULE__),
    do: GenServer.call(server, :rebuild_search_index, :infinity)

  @doc "Exports one consistent database and object snapshot to an absent directory."
  @spec create_backup(server(), String.t()) :: :ok | {:error, term()}
  def create_backup(server \\ __MODULE__, destination),
    do: GenServer.call(server, {:create_backup, destination}, :infinity)

  @doc "Lists active pinned masters in stable pin order, with an explicit caller bound."
  @spec list_pinned_masters(server(), pos_integer()) :: [map()]
  def list_pinned_masters(server \\ __MODULE__, limit) do
    GenServer.call(server, {:list_pinned_masters, limit})
  end

  @doc "Reads a durable local setting by key."
  @spec get_setting(server(), String.t()) :: {:ok, String.t()} | :not_found | {:error, term()}
  def get_setting(server \\ __MODULE__, key), do: GenServer.call(server, {:get_setting, key})

  @doc "Replaces a durable local setting."
  @spec put_setting(server(), String.t(), String.t()) :: :ok | {:error, term()}
  def put_setting(server \\ __MODULE__, key, value) do
    GenServer.call(server, {:put_setting, key, value})
  end

  @doc "Reads the durable object-byte budget and registered active/trash accounting."
  @spec storage(server()) :: {:ok, map()} | {:error, term()}
  def storage(server \\ __MODULE__), do: GenServer.call(server, :storage)

  @doc "Changes a byte budget under its observed configuration revision without deleting content."
  @spec update_storage(server(), String.t(), pos_integer()) :: {:ok, map()} | {:error, term()}
  def update_storage(server \\ __MODULE__, expected_revision, byte_limit),
    do: GenServer.call(server, {:update_storage, expected_revision, byte_limit})

  @doc "Claims a command identity before mutation, distinguishing replay from an unresolved claim."
  @spec claim_command(server(), String.t(), digest()) ::
          {:ok, :execute | :pending | {:replay, :ok | {:error, String.t()}}}
          | {:error, term()}
  def claim_command(server \\ __MODULE__, command_id, command_hash) do
    GenServer.call(server, {:claim_command, command_id, command_hash})
  end

  @doc "Persists the terminal outcome for a previously claimed command."
  @spec complete_command(server(), String.t(), digest(), :ok | {:error, atom()}) ::
          :ok | {:error, term()}
  def complete_command(server \\ __MODULE__, command_id, command_hash, outcome) do
    GenServer.call(server, {:complete_command, command_id, command_hash, outcome})
  end

  @doc "Admits and stores a frame Thing Description with an opaque credential reference and server pin."
  @spec register_paired_frame(server(), binary(), String.t(), String.t()) ::
          {:ok, map()} | {:error, term()}
  def register_paired_frame(
        server \\ __MODULE__,
        td_source,
        credential_ref,
        server_spki_fingerprint
      ) do
    GenServer.call(
      server,
      {:register_paired_frame, td_source, credential_ref, server_spki_fingerprint}
    )
  end

  @doc "Lists paired frames for target selection without exposing private key material."
  @spec list_paired_frames(server()) :: [map()]
  def list_paired_frames(server \\ __MODULE__), do: GenServer.call(server, :list_paired_frames)

  @doc "Returns the durable record for one paired frame."
  @spec get_paired_frame(server(), String.t()) :: {:ok, map()} | :not_found
  def get_paired_frame(server \\ __MODULE__, frame_id) do
    GenServer.call(server, {:get_paired_frame, frame_id})
  end

  @doc "Resolves one paired frame by its pinned SPKI, rejecting duplicate identities."
  @spec get_paired_frame_by_spki(server(), String.t()) ::
          {:ok, map()} | :not_found | {:error, :ambiguous_frame_identity}
  def get_paired_frame_by_spki(server \\ __MODULE__, fingerprint) do
    GenServer.call(server, {:get_paired_frame_by_spki, fingerprint})
  end

  @doc "Forgets a paired frame record and its durable library references."
  @spec forget_paired_frame(server(), String.t()) :: :ok | {:error, term()}
  def forget_paired_frame(server \\ __MODULE__, frame_id) do
    GenServer.call(server, {:forget_paired_frame, frame_id})
  end

  @doc "Registers a reusable qualification candidate for an exact paired frame contract."
  @spec register_qualification(server(), map()) :: {:ok, digest()} | {:error, term()}
  def register_qualification(server \\ __MODULE__, manifest) do
    GenServer.call(server, {:register_qualification, manifest})
  end

  @doc "Admits a candidate against a bounded software conformance record."
  @spec admit_qualification(server(), digest(), map()) :: :ok | {:error, term()}
  def admit_qualification(server \\ __MODULE__, digest, evidence) do
    GenServer.call(server, {:admit_qualification, digest, evidence})
  end

  @doc "Selects one admitted binding for future work on a frame."
  @spec activate_qualification(server(), String.t(), digest()) :: :ok | {:error, term()}
  def activate_qualification(server \\ __MODULE__, frame_id, digest) do
    GenServer.call(server, {:activate_qualification, frame_id, digest})
  end

  @doc "Atomically selects admitted bindings for a bounded cohort of frames."
  @spec activate_qualification_cohort(server(), [{String.t(), digest()}]) ::
          :ok | {:error, term()}
  def activate_qualification_cohort(server \\ __MODULE__, selections) do
    GenServer.call(server, {:activate_qualification_cohort, selections})
  end

  @doc "Reads one durable qualification, including its admission status."
  @spec get_qualification(server(), digest()) :: {:ok, map()} | :not_found
  def get_qualification(server \\ __MODULE__, digest) do
    GenServer.call(server, {:get_qualification, digest})
  end

  @doc "Reads the selected qualification for future work on one frame."
  @spec active_qualification(server(), String.t()) :: {:ok, map()} | :not_found
  def active_qualification(server \\ __MODULE__, frame_id) do
    GenServer.call(server, {:active_qualification, frame_id})
  end

  @doc "Accepts one immutable render work identity under the current binding."
  @spec accept_qualified_work(server(), String.t(), digest(), digest(), digest()) ::
          {:ok, digest()} | {:error, term()}
  def accept_qualified_work(
        server \\ __MODULE__,
        frame_id,
        binding_digest,
        master_digest,
        recipe_digest
      ) do
    GenServer.call(
      server,
      {:accept_qualified_work, frame_id, binding_digest, master_digest, recipe_digest}
    )
  end

  @doc "Reads accepted work without consulting the current active binding."
  @spec get_qualified_work(server(), digest()) :: {:ok, map()} | :not_found
  def get_qualified_work(server \\ __MODULE__, digest) do
    GenServer.call(server, {:get_qualified_work, digest})
  end

  @doc "Attaches one exact rendered artifact to accepted qualified work."
  @spec record_qualified_result(server(), digest(), digest()) ::
          {:ok, digest()} | {:error, term()}
  def record_qualified_result(server \\ __MODULE__, work_digest, artifact_digest) do
    GenServer.call(server, {:record_qualified_result, work_digest, artifact_digest})
  end

  @doc "Reads an immutable result without reselecting a binding."
  @spec qualified_result(server(), digest()) :: {:ok, map()} | :not_found
  def qualified_result(server \\ __MODULE__, work_digest) do
    GenServer.call(server, {:qualified_result, work_digest})
  end

  @doc "Pins an active master so library collection cannot remove it."
  @spec pin(server(), digest()) :: :ok | {:error, term()}
  def pin(server \\ __MODULE__, digest), do: GenServer.call(server, {:pin, digest})

  @doc "Removes a master's user pin while retaining other protective references."
  @spec unpin(server(), digest()) :: :ok | {:error, term()}
  def unpin(server \\ __MODULE__, digest), do: GenServer.call(server, {:unpin, digest})

  @doc "Hides a master from the active library while preserving pins and protected bytes."
  @spec remove_master(server(), digest()) :: :ok | {:error, term()}
  def remove_master(server \\ __MODULE__, digest),
    do: GenServer.call(server, {:remove_master, digest})

  @doc "Restores a removed master from the recoverable trash area."
  @spec restore_master(server(), digest(), String.t() | nil) :: :ok | {:error, term()}
  def restore_master(server \\ __MODULE__, digest, command_id \\ nil),
    do: GenServer.call(server, {:restore_master, digest, command_id})

  @doc "Protects bytes referenced by a frame's desired, current, or fallback role."
  @spec protect_frame_asset(server(), String.t(), String.t(), digest()) :: :ok | {:error, term()}
  def protect_frame_asset(server \\ __MODULE__, frame_id, role, digest) do
    GenServer.call(server, {:protect_frame_asset, frame_id, role, digest})
  end

  @doc "Releases one frame role reference after a safe state transition."
  @spec release_frame_asset(server(), String.t(), String.t(), digest()) :: :ok
  def release_frame_asset(server \\ __MODULE__, frame_id, role, digest) do
    GenServer.call(server, {:release_frame_asset, frame_id, role, digest})
  end

  @doc "Moves unreferenced removed objects to recoverable trash without destroying bytes."
  @spec collect_removed(server()) :: {:ok, [digest()]}
  def collect_removed(server \\ __MODULE__),
    do: GenServer.call(server, :collect_removed, :infinity)

  @doc "Returns master metadata, including removed state, without reading its content bytes."
  @spec get_master(server(), digest()) :: {:ok, map()} | :not_found
  def get_master(server \\ __MODULE__, digest), do: GenServer.call(server, {:get_master, digest})

  @doc "Reads bounded editable metadata and its exact revision without source paths."
  @spec metadata(server(), digest()) :: {:ok, map()} | {:error, atom()}
  def metadata(server \\ __MODULE__, digest), do: GenServer.call(server, {:metadata, digest})

  @doc "Atomically edits a title and local labels under an expected metadata revision."
  @spec update_metadata(server(), digest(), map()) :: {:ok, map()} | {:error, term()}
  def update_metadata(server \\ __MODULE__, digest, command),
    do: GenServer.call(server, {:update_metadata, digest, command})

  @doc "Reads an active master's bounded native analysis archive without interpreting vectors."
  @spec analysis(server(), digest()) :: {:ok, map()} | {:error, atom()}
  def analysis(server \\ __MODULE__, digest), do: GenServer.call(server, {:analysis, digest})

  @doc "Lists sixteen active masters awaiting the selected native observation cohort."
  @spec analysis_pending(server(), String.t()) :: {:ok, map()} | {:error, atom()}
  def analysis_pending(server \\ __MODULE__, cohort),
    do: GenServer.call(server, {:analysis_pending, cohort})

  @doc "Replaces Vision observations and their archive against an exact metadata revision."
  @spec record_vision(server(), digest(), map()) :: {:ok, map()} | {:error, term()}
  def record_vision(server \\ __MODULE__, digest, command),
    do: GenServer.call(server, {:record_vision, digest, command})

  @doc "Lists 50 removed masters and retention reasons using an exclusive digest cursor."
  @spec recovery_page(server(), digest() | nil) :: {:ok, map()} | {:error, atom()}
  def recovery_page(server \\ __MODULE__, after_id \\ nil),
    do: GenServer.call(server, {:recovery_page, after_id})

  @doc "Reads and verifies a content object under an explicit byte ceiling."
  @spec read_object(server(), digest(), pos_integer()) ::
          {:ok, map()} | :not_found | {:error, term()}
  def read_object(server \\ __MODULE__, digest, maximum_bytes \\ @maximum_read_bytes) do
    GenServer.call(server, {:read_object, digest, maximum_bytes}, :infinity)
  end

  @doc "Supersedes a sleeping frame's pending delivery with the latest artifact."
  @spec queue_outbox(
          server(),
          String.t(),
          digest(),
          String.t(),
          digest() | nil,
          String.t() | nil,
          digest() | nil
        ) ::
          {:ok, map()} | {:error, term()}
  def queue_outbox(
        server \\ __MODULE__,
        frame_id,
        digest,
        profile_id,
        playlist_revision \\ nil,
        command_id \\ nil,
        work_digest \\ nil
      ) do
    GenServer.call(
      server,
      {:queue_outbox, frame_id, digest, profile_id, playlist_revision, command_id, work_digest}
    )
  end

  @doc "Returns the current pull manifest for a frame, if any."
  @spec outbox_manifest(server(), String.t()) :: {:ok, map()} | :empty
  def outbox_manifest(server \\ __MODULE__, frame_id) do
    GenServer.call(server, {:outbox_manifest, frame_id})
  end

  @doc "Queues a complete pre-rendered still playlist and its outbox manifest atomically."
  @spec queue_playlist(server(), String.t(), String.t(), map(), [map()], String.t() | nil, term()) ::
          {:ok, map()} | {:error, term()}
  def queue_playlist(
        server \\ __MODULE__,
        frame_id,
        profile_id,
        playlist,
        entries,
        command_id \\ nil,
        interval_choice \\ nil
      ) do
    GenServer.call(
      server,
      {:queue_playlist, frame_id, profile_id, playlist, entries, command_id, interval_choice},
      :infinity
    )
  end

  @doc "Queues the exact saved suspended cycle, refusing stale revision or newer delivery intent."
  @spec resume_playlist(server(), String.t(), digest(), String.t() | nil) ::
          {:ok, map()} | {:error, term()}
  def resume_playlist(server \\ __MODULE__, frame_id, revision, command_id \\ nil) do
    GenServer.call(server, {:resume_playlist, frame_id, revision, command_id}, :infinity)
  end

  @doc "Reads the interval preference committed with the last successful queue for this frame."
  @spec frame_playlist_interval(server(), String.t()) :: map() | nil
  def frame_playlist_interval(server \\ __MODULE__, frame_id) do
    GenServer.call(server, {:frame_playlist_interval, frame_id})
  end

  @doc "Returns the exact current pending playlist for a paired outbox caller."
  @spec outbox_playlist(server(), String.t(), String.t()) :: {:ok, binary()} | :not_found
  def outbox_playlist(server \\ __MODULE__, frame_id, revision) do
    GenServer.call(server, {:outbox_playlist, frame_id, revision})
  end

  @doc "Checks whether the current pending playlist authorizes a cached artifact pull."
  @spec outbox_playlist_asset?(server(), String.t(), String.t()) :: boolean()
  def outbox_playlist_asset?(server \\ __MODULE__, frame_id, digest) do
    GenServer.call(server, {:outbox_playlist_asset?, frame_id, digest})
  end

  @doc "Returns pending, active, or suspended loop status for one paired frame."
  @spec frame_playlist_status(server(), String.t()) :: map() | nil
  def frame_playlist_status(server \\ __MODULE__, frame_id) do
    GenServer.call(server, {:frame_playlist_status, frame_id})
  end

  @doc "Returns the selected loop's source masters for the local library view."
  @spec frame_playlist_members(server(), String.t()) :: map() | nil
  def frame_playlist_members(server \\ __MODULE__, frame_id) do
    GenServer.call(server, {:frame_playlist_members, frame_id})
  end

  @doc "Checks a frame acknowledgement and advances retained references only on a match."
  @spec acknowledge_outbox(server(), String.t(), map()) ::
          :ok | {:ok, :pending} | {:error, term()}
  def acknowledge_outbox(server \\ __MODULE__, frame_id, acknowledgement) do
    GenServer.call(server, {:acknowledge_outbox, frame_id, acknowledgement})
  end

  @doc "Records a push delivery before network I/O and protects its desired artifact."
  @spec begin_direct_delivery(
          server(),
          String.t(),
          digest(),
          String.t(),
          String.t(),
          digest() | nil
        ) ::
          {:ok, map()} | {:error, term()}
  def begin_direct_delivery(
        server \\ __MODULE__,
        frame_id,
        digest,
        profile_id,
        request_id,
        work_digest \\ nil
      ) do
    GenServer.call(
      server,
      {:begin_direct_delivery, frame_id, digest, profile_id, request_id, work_digest}
    )
  end

  @doc "Returns the latest durable push intent, including an unresolved attempt after restart."
  @spec direct_delivery(server(), String.t()) :: {:ok, map()} | :not_found
  def direct_delivery(server \\ __MODULE__, frame_id) do
    GenServer.call(server, {:direct_delivery, frame_id})
  end

  @doc "Reads host-only qualification custody for pending and confirmed frame roles."
  @spec delivery_custody(server(), String.t()) :: map() | {:error, :invalid_frame}
  def delivery_custody(server \\ __MODULE__, frame_id) do
    GenServer.call(server, {:delivery_custody, frame_id})
  end

  @doc "Records a correlated push or reconciliation attempt through the single writer."
  @spec record_direct_attempt(
          server(),
          String.t(),
          String.t(),
          String.t(),
          :push | :reconcile,
          :started | :displayed | :pending | :failed
        ) :: :ok | {:error, term()}
  def record_direct_attempt(server, frame_id, request_id, attempt_id, mode, phase) do
    GenServer.call(
      server,
      {:record_direct_attempt, frame_id, request_id, attempt_id, mode, phase}
    )
  end

  @doc "Commits a confirmed display or preserves a pending push intent for reconciliation."
  @spec finish_direct_delivery(
          server(),
          String.t(),
          pos_integer(),
          String.t(),
          digest(),
          :displayed | :pending
        ) ::
          :ok | {:ok, :pending} | {:error, term()}
  def finish_direct_delivery(
        server \\ __MODULE__,
        frame_id,
        revision,
        request_id,
        digest,
        outcome
      ) do
    finish_direct_delivery(server, frame_id, revision, request_id, digest, outcome, nil)
  end

  @doc "Commits display confirmation with its specific network attempt ID."
  @spec finish_direct_delivery(
          server(),
          String.t(),
          pos_integer(),
          String.t(),
          digest(),
          :displayed | :pending,
          String.t() | nil
        ) :: :ok | {:ok, :pending} | {:error, term()}
  def finish_direct_delivery(server, frame_id, revision, request_id, digest, outcome, attempt_id) do
    if valid_attempt_id?(attempt_id) do
      GenServer.call(
        server,
        {:finish_direct_delivery, frame_id, revision, request_id, digest, outcome, attempt_id}
      )
    else
      {:error, :invalid_direct_delivery}
    end
  end

  @doc "Reads one descending redacted audit page from the authoritative store."
  @spec audit_page(server(), non_neg_integer() | nil, pos_integer()) ::
          map() | {:error, term()}
  def audit_page(server \\ __MODULE__, cursor \\ nil, limit \\ 50) do
    GenServer.call(server, {:audit_page, cursor, limit})
  end

  @doc "Reads one descending page of committed metric rollups."
  @spec metric_page(server(), non_neg_integer() | nil, pos_integer()) ::
          map() | {:error, term()}
  def metric_page(server \\ __MODULE__, cursor \\ nil, limit \\ 50) do
    GenServer.call(server, {:metric_page, cursor, limit})
  end

  @doc "Returns identifier-free authoritative health gauges."
  @spec diagnostics_health(server()) :: map()
  def diagnostics_health(server \\ __MODULE__) do
    GenServer.call(server, :diagnostics_health)
  end

  @doc "Commits one bounded batch of telemetry rollups through the single writer."
  @spec write_metric_rollups(server(), [map()]) :: :ok | {:error, term()}
  def write_metric_rollups(server \\ __MODULE__, rows) do
    GenServer.call(server, {:write_metric_rollups, rows}, 30_000)
  end

  @impl true
  def init(options) do
    data_dir = options |> Keyword.fetch!(:data_dir) |> Path.expand()

    with :ok <- ContentStore.prepare(data_dir),
         {:ok, connection} <-
           Exqlite.start_link(
             database: Path.join(data_dir, "metadata.sqlite"),
             journal_mode: :wal,
             synchronous: :full,
             foreign_keys: :on,
             default_transaction_mode: :immediate,
             busy_timeout: 2_000
           ),
         :ok <- Migrations.run(connection),
         :ok <- reconcile_objects(connection, data_dir) do
      {:ok, %State{connection: connection, data_dir: data_dir}}
    end
  end

  @impl true
  def terminate(_, %State{connection: connection}) do
    if Process.alive?(connection), do: GenServer.stop(connection)
    :ok
  end

  @impl true
  def handle_call({:import_master, bytes, attributes}, _, state) do
    {:reply, import_master_record(state, bytes, attributes, nil, nil), state}
  end

  def handle_call(
        {:add_generated_variant, bytes, attributes, parent_digest, recipe_hash},
        _,
        state
      ) do
    attributes = Map.put(attributes, :source_kind, :generated)
    {:reply, import_master_record(state, bytes, attributes, parent_digest, recipe_hash), state}
  end

  def handle_call({:add_generated_master, bytes, attributes, recipe_hash}, _, state) do
    attributes = Map.put(attributes, :source_kind, :generated)
    {:reply, import_master_record(state, bytes, attributes, nil, recipe_hash), state}
  end

  def handle_call({:cached_generation, recipe_hash}, _, state) do
    {:reply, cached_generation_record(state, recipe_hash), state}
  end

  def handle_call({:register_recipe, kind, parameters, source_digests}, _, state) do
    {:reply, do_register_recipe(state, kind, parameters, source_digests), state}
  end

  def handle_call({:register_artifact, bytes, attributes}, _, state) do
    {:reply, do_register_artifact(state, bytes, attributes), state}
  end

  def handle_call({:cached_artifact, recipe_hash, profile_id, renderer_revision}, _, state) do
    result =
      query_one(
        state.connection,
        """
        SELECT o.digest, o.byte_count, o.media_type, a.master_digest, a.recipe_hash,
               a.profile_id, a.renderer_revision
        FROM artifact_recipe_links a
        JOIN objects o ON o.digest = a.artifact_digest
        WHERE a.recipe_hash = ? AND a.profile_id = ? AND a.renderer_revision = ?
        """,
        [recipe_hash, profile_id, renderer_revision]
      )

    {:reply, result, state}
  end

  def handle_call({:add_label, digest, label, provenance, confidence, revision}, _, state) do
    result = Metadata.add_label(state.connection, digest, label, provenance, confidence, revision)
    {:reply, result, state}
  end

  def handle_call({:metadata, digest}, _, state),
    do: {:reply, Metadata.read(state.connection, digest), state}

  def handle_call({:update_metadata, digest, command}, _, state),
    do: {:reply, Metadata.update(state.connection, digest, command), state}

  def handle_call({:analysis, digest}, _, state),
    do: {:reply, Metadata.analysis(state.connection, digest), state}

  def handle_call({:analysis_pending, cohort}, _, state),
    do: {:reply, Metadata.analysis_pending(state.connection, cohort), state}

  def handle_call({:record_vision, digest, command}, _, state),
    do: {:reply, Metadata.record_vision(state.connection, digest, command), state}

  def handle_call({:recovery_page, after_id}, _, state),
    do: {:reply, Metadata.recovery_page(state.connection, after_id), state}

  def handle_call({:search, query, options}, _, state) do
    {:reply, search_records(state, query, options), state}
  end

  def handle_call(:rebuild_search_index, _, state) do
    result = transaction(state.connection, &Migrations.rebuild_search/1)

    reply =
      case result do
        {:ok, :ok} -> :ok
        {:error, reason} -> {:error, reason}
      end

    {:reply, reply, state}
  end

  def handle_call({:create_backup, destination}, _, state) do
    {:reply, Backup.create(state.connection, state.data_dir, destination), state}
  end

  def handle_call({:list_pinned_masters, limit}, _, state)
      when is_integer(limit) and limit in 1..10_000 do
    sql = """
    SELECT m.digest FROM pins p JOIN masters m ON m.digest = p.object_digest
    WHERE m.removed_at_ms IS NULL
    ORDER BY p.pinned_at_ms, m.digest LIMIT ?
    """

    masters =
      state.connection
      |> Exqlite.query!(sql, [limit])
      |> Map.fetch!(:rows)
      |> Enum.map(fn [digest] ->
        {:ok, master} = get_master_record(state, digest)
        master
      end)

    {:reply, masters, state}
  end

  def handle_call({:list_pinned_masters, _}, _, state), do: {:reply, [], state}

  def handle_call({:get_setting, key}, _, state) do
    {:reply, get_setting_record(state, key), state}
  end

  def handle_call({:put_setting, key, value}, _, state) do
    {:reply, put_setting_record(state, key, value), state}
  end

  def handle_call(:storage, _, state), do: {:reply, Storage.read(state.connection), state}

  def handle_call({:update_storage, revision, limit}, _, state),
    do: {:reply, Storage.update(state.connection, revision, limit), state}

  def handle_call({:claim_command, command_id, command_hash}, _, state) do
    {:reply, claim_command_record(state, command_id, command_hash), state}
  end

  def handle_call({:complete_command, command_id, command_hash, outcome}, _, state) do
    {:reply, complete_command_record(state, command_id, command_hash, outcome), state}
  end

  def handle_call(
        {:register_paired_frame, td_source, credential_ref, server_spki_fingerprint},
        _,
        state
      ) do
    result =
      with {:ok, frame} <-
             FrameRegistry.admit(td_source, credential_ref, server_spki_fingerprint) do
        admit_paired_frame(state, frame)
      end

    {:reply, result, state}
  end

  def handle_call(:list_paired_frames, _, state) do
    {:reply, list_paired_frame_records(state), state}
  end

  def handle_call({:get_paired_frame, frame_id}, _, state) do
    {:reply, get_paired_frame_record(state, frame_id), state}
  end

  def handle_call({:get_paired_frame_by_spki, fingerprint}, _, state) do
    {:reply, get_paired_frame_by_spki_record(state, fingerprint), state}
  end

  def handle_call({:forget_paired_frame, frame_id}, _, state) do
    {:reply, forget_paired_frame_record(state, frame_id), state}
  end

  def handle_call({:register_qualification, manifest}, _, state) do
    qualification_reply(
      state,
      :candidate,
      QualificationStore.register(state.connection, manifest)
    )
  end

  def handle_call({:admit_qualification, digest, evidence}, _, state) do
    qualification_reply(
      state,
      :admission,
      QualificationStore.admit(state.connection, digest, evidence)
    )
  end

  def handle_call({:activate_qualification, frame_id, digest}, _, state) do
    qualification_reply(
      state,
      :activation,
      QualificationStore.activate(state.connection, frame_id, digest)
    )
  end

  def handle_call({:activate_qualification_cohort, selections}, _, state) do
    qualification_reply(
      state,
      :cohort,
      QualificationStore.activate_cohort(state.connection, selections)
    )
  end

  def handle_call({:get_qualification, digest}, _, state) do
    {:reply, QualificationStore.get(state.connection, digest), state}
  end

  def handle_call({:active_qualification, frame_id}, _, state) do
    {:reply, QualificationStore.active(state.connection, frame_id), state}
  end

  def handle_call(
        {:accept_qualified_work, frame_id, binding_digest, master_digest, recipe_digest},
        _,
        state
      ) do
    reply =
      WorkStore.accept(state.connection, frame_id, binding_digest, master_digest, recipe_digest)

    qualification_reply(state, :work, reply)
  end

  def handle_call({:get_qualified_work, digest}, _, state) do
    {:reply, WorkStore.get(state.connection, digest), state}
  end

  def handle_call({:record_qualified_result, work_digest, artifact_digest}, _, state) do
    qualification_reply(
      state,
      :result,
      WorkStore.record_result(state.connection, work_digest, artifact_digest)
    )
  end

  def handle_call({:qualified_result, work_digest}, _, state) do
    {:reply, WorkStore.result(state.connection, work_digest), state}
  end

  def handle_call({:pin, digest}, _, state) do
    result =
      write_existing_object(state, digest, fn ->
        execute(
          state.connection,
          "INSERT INTO pins(object_digest, pinned_at_ms) VALUES (?, ?) ON CONFLICT DO NOTHING",
          [digest, now_ms()]
        )
      end)

    {:reply, result, state}
  end

  def handle_call({:unpin, digest}, _, state) do
    execute(state.connection, "DELETE FROM pins WHERE object_digest = ?", [digest])
    {:reply, :ok, state}
  end

  def handle_call({:remove_master, digest}, _, state) do
    result =
      write_existing_master(state, digest, fn ->
        execute(state.connection, "UPDATE masters SET removed_at_ms = ? WHERE digest = ?", [
          now_ms(),
          digest
        ])
      end)

    {:reply, result, state}
  end

  def handle_call({:restore_master, digest, command_id}, _, state) do
    result = restore_master_record(state, digest, command_id)
    {:reply, result, state}
  end

  def handle_call({:protect_frame_asset, frame_id, role, digest}, _, state) do
    result = protect_frame_asset_record(state, frame_id, role, digest)
    {:reply, result, state}
  end

  def handle_call({:release_frame_asset, frame_id, role, digest}, _, state) do
    execute(
      state.connection,
      "DELETE FROM frame_asset_refs WHERE frame_id = ? AND role = ? AND object_digest = ?",
      [frame_id, role, digest]
    )

    {:reply, :ok, state}
  end

  def handle_call(:collect_removed, _, state) do
    {:reply, collect_removed_records(state), state}
  end

  def handle_call({:get_master, digest}, _, state) do
    {:reply, get_master_record(state, digest), state}
  end

  def handle_call({:read_object, digest, maximum_bytes}, _, state) do
    {:reply, read_object_record(state, digest, maximum_bytes), state}
  end

  def handle_call(
        {:queue_outbox, frame_id, digest, profile_id, playlist_revision, command_id, work_digest},
        _,
        state
      ) do
    result =
      queue_outbox_record(
        state,
        frame_id,
        digest,
        profile_id,
        playlist_revision,
        command_id,
        work_digest
      )

    if match?({:ok, _manifest}, result) do
      :telemetry.execute(
        [:frameshift, :delivery, :intent],
        %{count: 1},
        %{mode: :pull}
      )
    end

    {:reply, result, state}
  end

  def handle_call({:outbox_manifest, frame_id}, _, state) do
    {:reply, outbox_manifest_record(state, frame_id), state}
  end

  def handle_call(
        {:queue_playlist, frame_id, profile_id, playlist, entries, command_id, interval_choice},
        _,
        state
      ) do
    result =
      case get_paired_frame_record(state, frame_id) do
        {:ok, frame} ->
          PlaylistStore.queue(
            state.connection,
            frame,
            profile_id,
            playlist,
            entries,
            command_id,
            interval_choice
          )

        :not_found ->
          {:error, :frame_not_paired}
      end

    {:reply, result, state}
  end

  def handle_call({:resume_playlist, frame_id, revision, command_id}, _, state) do
    result =
      case get_paired_frame_record(state, frame_id) do
        {:ok, frame} -> PlaylistStore.resume(state.connection, frame, revision, command_id)
        :not_found -> {:error, :frame_not_paired}
      end

    {:reply, result, state}
  end

  def handle_call({:frame_playlist_interval, frame_id}, _, state) do
    result =
      case get_paired_frame_record(state, frame_id) do
        {:ok, frame} -> PlaylistStore.interval(state.connection, frame)
        :not_found -> nil
      end

    {:reply, result, state}
  end

  def handle_call({:outbox_playlist, frame_id, revision}, _, state) do
    {:reply, PlaylistStore.pending_body(state.connection, frame_id, revision), state}
  end

  def handle_call({:outbox_playlist_asset?, frame_id, digest}, _, state) do
    {:reply, PlaylistStore.pending_asset?(state.connection, frame_id, digest), state}
  end

  def handle_call({:frame_playlist_status, frame_id}, _, state) do
    {:reply, PlaylistStore.status(state.connection, frame_id), state}
  end

  def handle_call({:frame_playlist_members, frame_id}, _, state) do
    {:reply, PlaylistStore.members(state.connection, frame_id), state}
  end

  def handle_call({:acknowledge_outbox, frame_id, acknowledgement}, _, state) do
    queued_at_ms =
      case query_one(
             state.connection,
             "SELECT queued_at_ms FROM frame_outboxes WHERE frame_id = ?",
             [
               frame_id
             ]
           ) do
        {:ok, row} -> row["queued_at_ms"]
        :not_found -> nil
      end

    result = acknowledge_outbox_record(state, frame_id, acknowledgement)
    if result == :ok, do: emit_delivery_confirmation(:pull, queued_at_ms)
    {:reply, result, state}
  end

  def handle_call(
        {:begin_direct_delivery, frame_id, digest, profile_id, request_id, work_digest},
        _,
        state
      ) do
    previous = direct_delivery_record(state, frame_id)

    result =
      begin_direct_delivery_record(state, frame_id, digest, profile_id, request_id, work_digest)

    if match?({:ok, _delivery}, result) and
         not match?({:ok, %{"request_id" => ^request_id}}, previous) do
      :telemetry.execute(
        [:frameshift, :delivery, :intent],
        %{count: 1},
        %{mode: :push}
      )
    end

    {:reply, result, state}
  end

  def handle_call({:direct_delivery, frame_id}, _, state) do
    {:reply, direct_delivery_record(state, frame_id), state}
  end

  def handle_call({:delivery_custody, frame_id}, _, state) do
    {:reply, delivery_custody_record(state, frame_id), state}
  end

  def handle_call(
        {:record_direct_attempt, frame_id, request_id, attempt_id, mode, phase},
        _,
        state
      ) do
    result = record_direct_attempt_record(state, frame_id, request_id, attempt_id, mode, phase)
    {:reply, result, state}
  end

  def handle_call(
        {:finish_direct_delivery, frame_id, revision, request_id, digest, outcome, attempt_id},
        _,
        state
      ) do
    previous = direct_delivery_record(state, frame_id)

    result =
      finish_direct_delivery_record(
        state,
        frame_id,
        revision,
        request_id,
        digest,
        outcome,
        attempt_id
      )

    if result == :ok and
         match?({:ok, %{"status" => "pending", "request_id" => ^request_id}}, previous) do
      {:ok, delivery} = previous
      emit_delivery_confirmation(:push, delivery["updated_at_ms"])
    end

    {:reply, result, state}
  end

  def handle_call({:audit_page, cursor, limit}, _, state) do
    {:reply, DiagnosticsStore.audit_page(state.connection, cursor, limit), state}
  end

  def handle_call({:metric_page, cursor, limit}, _, state) do
    {:reply, DiagnosticsStore.metric_page(state.connection, cursor, limit), state}
  end

  def handle_call(:diagnostics_health, _, state) do
    {:reply, DiagnosticsStore.health(state.connection), state}
  end

  def handle_call({:write_metric_rollups, rows}, _, state) do
    reply =
      with :ok <- DiagnosticsStore.validate_rollups(rows) do
        persist_metric_rollups(state.connection, rows)
      end

    {:reply, reply, state}
  end

  defp persist_metric_rollups(connection, rows) do
    case Exqlite.transaction(
           connection,
           fn owner -> DiagnosticsStore.merge_rollups(owner, rows, now_ms()) end,
           mode: :immediate
         ) do
      {:ok, :ok} -> :ok
      {:error, reason} -> {:error, reason}
    end
  end

  defp import_master_record(state, bytes, attributes, parent_digest, recipe_hash) do
    with :ok <- Identity.validate_master(attributes, parent_digest, recipe_hash),
         :ok <- validate_parent_recipe(state, parent_digest, recipe_hash),
         :not_found <- existing_generation(state, recipe_hash),
         :ok <- Storage.admit(state.connection, bytes),
         {:ok, digest, byte_count, placement} <- ContentStore.put(state.data_dir, bytes) do
      insert_master(state, digest, byte_count, attributes, parent_digest, recipe_hash, placement)
    else
      {:cached, master} -> {:ok, Map.put(master, :placement, :existing)}
      error -> error
    end
  rescue
    error in Exqlite.Error -> {:error, {:database, error.message}}
  end

  defp existing_generation(_, nil), do: :not_found

  defp existing_generation(state, recipe_hash) do
    case cached_generation_record(state, recipe_hash) do
      {:ok, master} -> {:cached, master}
      :not_found -> :not_found
    end
  end

  defp validate_parent_recipe(_, nil, nil), do: :ok

  defp validate_parent_recipe(state, nil, recipe_hash) do
    with true <- Digest.valid_sha256?(recipe_hash),
         {:ok, %{"kind" => "generation"}} <-
           query_one(state.connection, "SELECT kind FROM recipes WHERE hash = ?", [recipe_hash]) do
      :ok
    else
      false -> {:error, :invalid_digest}
      :not_found -> {:error, :parent_or_recipe_missing}
      {:ok, _} -> {:error, :not_generation_recipe}
    end
  end

  defp validate_parent_recipe(state, parent_digest, recipe_hash) do
    with true <- Digest.valid_sha256?(parent_digest),
         true <- Digest.valid_sha256?(recipe_hash),
         {:ok, _} <- get_master_record(state, parent_digest),
         {:ok, %{"kind" => "generation"}} <-
           query_one(state.connection, "SELECT kind FROM recipes WHERE hash = ?", [recipe_hash]) do
      :ok
    else
      false -> {:error, :invalid_digest}
      :not_found -> {:error, :parent_or_recipe_missing}
      {:ok, _} -> {:error, :not_generation_recipe}
    end
  end

  defp insert_master(
         state,
         digest,
         byte_count,
         attributes,
         parent_digest,
         recipe_hash,
         placement
       ) do
    now = now_ms()
    provenance_json = RFC8785.encode!(attributes.provenance)
    source_kind = Atom.to_string(attributes.source_kind)
    orientation = Map.get(attributes, :orientation, 1)
    color_profile = Map.get(attributes, :color_profile)

    transaction(state.connection, fn connection ->
      Exqlite.query!(
        connection,
        """
        INSERT INTO objects(digest, byte_count, media_type, storage_state, created_at_ms)
        VALUES (?, ?, ?, 'active', ?)
        ON CONFLICT(digest) DO UPDATE SET storage_state = 'active', trashed_at_ms = NULL
        """,
        [digest, byte_count, attributes.media_type, now]
      )

      Exqlite.query!(
        connection,
        """
        INSERT INTO masters(
          digest, title, source_kind, width, height, color_profile, orientation,
          provenance_json, parent_digest, generation_recipe_hash, removed_at_ms
        ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, NULL)
        ON CONFLICT(digest) DO UPDATE SET removed_at_ms = NULL
        """,
        [
          digest,
          attributes.title,
          source_kind,
          attributes.width,
          attributes.height,
          color_profile,
          orientation,
          provenance_json,
          parent_digest,
          recipe_hash
        ]
      )

      if recipe_hash do
        Exqlite.query!(
          connection,
          """
          INSERT INTO generation_results(
            recipe_hash, master_digest, provider_result_id, provenance_json, created_at_ms
          ) VALUES (?, ?, ?, ?, ?)
          ON CONFLICT(recipe_hash) DO UPDATE SET
            master_digest = excluded.master_digest,
            provider_result_id = excluded.provider_result_id,
            provenance_json = excluded.provenance_json,
            created_at_ms = excluded.created_at_ms
          """,
          [
            recipe_hash,
            digest,
            Map.get(attributes.provenance, "resultId"),
            provenance_json,
            now
          ]
        )
      end

      DiagnosticsStore.record_audit(connection, "master.imported", digest, %{
        "sourceKind" => source_kind
      })

      :ok
    end)
    |> case do
      {:ok, :ok} -> inserted_master_record(state, digest, recipe_hash, placement)
      {:error, %Exqlite.Error{message: message}} -> {:error, {:database, message}}
      {:error, reason} -> {:error, reason}
    end
  end

  defp inserted_master_record(state, digest, nil, placement) do
    with {:ok, master} <- get_master_record(state, digest),
         do: {:ok, Map.put(master, :placement, placement)}
  end

  defp inserted_master_record(state, _, recipe_hash, placement) do
    with {:ok, master} <- cached_generation_record(state, recipe_hash),
         do: {:ok, Map.put(master, :placement, placement)}
  end

  defp do_register_recipe(state, kind, parameters, source_digests) do
    with :ok <- Identity.validate_recipe_input(kind, parameters, source_digests),
         :ok <- validate_recipe_sources(state, source_digests),
         {:ok, hash, kind_string, canonical_json} <-
           Identity.recipe_identity(kind, parameters, source_digests) do
      result = insert_recipe_transaction(state, hash, kind_string, canonical_json, source_digests)

      case result do
        {:ok, ^hash} -> {:ok, hash}
        {:error, %Exqlite.Error{message: message}} -> {:error, {:database, message}}
        {:error, reason} -> {:error, reason}
      end
    else
      {:error, reason} -> {:error, reason}
    end
  end

  defp insert_recipe_transaction(state, hash, kind, canonical_json, source_digests) do
    transaction(state.connection, fn connection ->
      Exqlite.query!(
        connection,
        "INSERT INTO recipes(hash, kind, canonical_json, created_at_ms) VALUES (?, ?, ?, ?) ON CONFLICT DO NOTHING",
        [hash, kind, canonical_json, now_ms()]
      )

      source_digests
      |> Enum.with_index()
      |> Enum.each(fn {source_digest, ordinal} ->
        Exqlite.query!(
          connection,
          "INSERT INTO recipe_sources(recipe_hash, source_digest, ordinal) VALUES (?, ?, ?) ON CONFLICT DO NOTHING",
          [hash, source_digest, ordinal]
        )
      end)

      DiagnosticsStore.record_audit(connection, "recipe.registered", hash, %{"kind" => kind})
      hash
    end)
  end

  defp validate_recipe_sources(state, source_digests) do
    if Enum.all?(source_digests, fn digest ->
         match?({:ok, _master}, get_master_record(state, digest))
       end) do
      :ok
    else
      {:error, :source_missing}
    end
  end

  defp do_register_artifact(state, bytes, attributes) when is_map(attributes) do
    required = ~w(master_digest recipe_hash profile_id renderer_revision media_type)a
    missing = Enum.reject(required, &Map.has_key?(attributes, &1))

    if missing == [],
      do: fetch_or_insert_artifact(state, bytes, attributes),
      else: {:error, {:missing_fields, missing}}
  end

  defp do_register_artifact(_, _, _), do: {:error, :invalid_attributes}

  defp fetch_or_insert_artifact(state, bytes, attributes) do
    case cached_artifact_record(
           state,
           attributes.recipe_hash,
           attributes.profile_id,
           attributes.renderer_revision
         ) do
      {:ok, artifact} ->
        cached_artifact_result(artifact, attributes.master_digest, attributes.media_type)

      :not_found ->
        insert_artifact(state, bytes, attributes)
    end
  end

  defp cached_artifact_result(
         %{"master_digest" => master_digest, "media_type" => media_type} = artifact,
         master_digest,
         media_type
       ),
       do: {:ok, Map.put(artifact, :cache, :hit)}

  defp cached_artifact_result(_, _, _), do: {:error, :cache_identity_conflict}

  defp insert_artifact(state, bytes, attributes) do
    with {:ok, _} <- get_master_record(state, attributes.master_digest),
         {:ok, _} <-
           query_one(state.connection, "SELECT hash FROM recipes WHERE hash = ?", [
             attributes.recipe_hash
           ]),
         :ok <- Storage.admit(state.connection, bytes),
         {:ok, digest, byte_count, placement} <- ContentStore.put(state.data_dir, bytes),
         :ok <- ensure_artifact_media_type(state, digest, attributes.media_type) do
      result =
        transaction(state.connection, fn connection ->
          Exqlite.query!(
            connection,
            """
            INSERT INTO objects(digest, byte_count, media_type, storage_state, created_at_ms)
            VALUES (?, ?, ?, 'active', ?)
            ON CONFLICT(digest) DO UPDATE SET storage_state = 'active', trashed_at_ms = NULL
            """,
            [digest, byte_count, attributes.media_type, now_ms()]
          )

          Exqlite.query!(
            connection,
            """
            INSERT INTO artifacts(digest, master_digest, recipe_hash, profile_id, renderer_revision)
            VALUES (?, ?, ?, ?, ?)
            ON CONFLICT(digest) DO NOTHING
            """,
            [
              digest,
              attributes.master_digest,
              attributes.recipe_hash,
              attributes.profile_id,
              attributes.renderer_revision
            ]
          )

          Exqlite.query!(
            connection,
            """
            INSERT INTO artifact_recipe_links(
              recipe_hash, profile_id, renderer_revision, master_digest, artifact_digest
            ) VALUES (?, ?, ?, ?, ?)
            """,
            [
              attributes.recipe_hash,
              attributes.profile_id,
              attributes.renderer_revision,
              attributes.master_digest,
              digest
            ]
          )

          DiagnosticsStore.record_audit(connection, "artifact.registered", digest, %{
            "profileId" => attributes.profile_id
          })

          :ok
        end)

      case result do
        {:ok, :ok} ->
          {:ok, artifact} =
            cached_artifact_record(
              state,
              attributes.recipe_hash,
              attributes.profile_id,
              attributes.renderer_revision
            )

          {:ok, artifact |> Map.put(:cache, :miss) |> Map.put(:placement, placement)}

        {:error, %Exqlite.Error{message: message}} ->
          {:error, {:database, message}}

        {:error, reason} ->
          {:error, reason}
      end
    else
      :not_found -> {:error, :master_or_recipe_missing}
      {:error, reason} -> {:error, reason}
    end
  end

  defp ensure_artifact_media_type(state, digest, media_type) do
    case query_one(state.connection, "SELECT media_type FROM objects WHERE digest = ?", [digest]) do
      {:ok, %{"media_type" => ^media_type}} -> :ok
      {:ok, _} -> {:error, :artifact_media_type_conflict}
      :not_found -> :ok
    end
  end

  defp cached_artifact_record(state, recipe_hash, profile_id, renderer_revision) do
    query_one(
      state.connection,
      """
      SELECT o.digest, o.byte_count, o.media_type, a.master_digest, a.recipe_hash,
             a.profile_id, a.renderer_revision
      FROM artifact_recipe_links a
      JOIN objects o ON o.digest = a.artifact_digest
      WHERE a.recipe_hash = ? AND a.profile_id = ? AND a.renderer_revision = ?
      """,
      [recipe_hash, profile_id, renderer_revision]
    )
  end

  defp search_records(state, query, options) do
    limit = options |> Keyword.get(:limit, 50) |> min(100) |> max(1)

    with true <- valid_search_options?(options),
         {:ok, match} <- search_match(query) do
      query_search(state, match, options, limit)
    else
      _ -> []
    end
  end

  defp valid_search_options?(options) do
    is_boolean(Keyword.get(options, :pinned, false)) and
      Keyword.get(options, :source_kind) in [nil, "import", "generated"] and
      valid_search_frame?(Keyword.get(options, :frame_id))
  end

  defp valid_search_frame?(nil), do: true
  defp valid_search_frame?(frame) when is_binary(frame), do: byte_size(frame) in 1..128
  defp valid_search_frame?(_), do: false

  defp search_match(query) when is_binary(query) and byte_size(query) <= 512 do
    trimmed = String.trim(query)

    cond do
      trimmed == "" -> {:ok, nil}
      true -> search_prefixes(trimmed)
    end
  end

  defp search_match(_), do: :invalid

  defp search_prefixes(query) do
    terms =
      ~r/[\p{L}\p{N}\p{M}]+/u
      |> Regex.scan(query)
      |> Enum.map(fn [term] -> term end)

    cond do
      terms == [] or length(terms) > 8 -> :invalid
      Enum.any?(terms, &(String.length(&1) > 32)) -> :invalid
      true -> {:ok, Enum.map_join(terms, " AND ", &~s("#{&1}"*))}
    end
  end

  defp query_search(state, match, options, limit) do
    join = if match, do: "JOIN master_search ON master_search.rowid = m.rowid", else: ""
    filter = if match, do: "AND master_search MATCH ?", else: ""

    pin_filter =
      if Keyword.get(options, :pinned, false), do: "AND p.object_digest IS NOT NULL", else: ""

    source = Keyword.get(options, :source_kind)
    frame = Keyword.get(options, :frame_id)
    parameters = if(match, do: [match], else: []) ++ [source, source, frame, frame, limit]

    sql = """
    SELECT DISTINCT m.digest, m.title, m.source_kind, m.width, m.height,
           m.color_profile, m.orientation, m.provenance_json, m.parent_digest,
           m.generation_recipe_hash, (p.object_digest IS NOT NULL) AS pinned,
           (
             SELECT fo.frame_id
             FROM frame_outboxes fo
             JOIN artifacts a ON a.digest = fo.desired_digest
             WHERE a.master_digest = m.digest
             ORDER BY fo.queued_at_ms DESC, fo.frame_id
             LIMIT 1
           ) AS queued_target_id
    FROM masters m
    #{join}
    LEFT JOIN pins p ON p.object_digest = m.digest
    WHERE m.removed_at_ms IS NULL
      #{filter}
      #{pin_filter}
      AND (? IS NULL OR m.source_kind = ?)
      AND (? IS NULL OR EXISTS (
        SELECT 1 FROM frame_asset_refs refs
        WHERE refs.frame_id = ? AND (
          refs.object_digest = m.digest OR EXISTS (
            SELECT 1 FROM artifact_recipe_links links
            WHERE links.master_digest = m.digest AND links.artifact_digest = refs.object_digest
          )
        )
      ))
    ORDER BY pinned DESC, m.title COLLATE NOCASE, m.digest
    LIMIT ?
    """

    state.connection
    |> Exqlite.query!(sql, parameters)
    |> rows_to_maps()
    |> Enum.map(&decode_master_row/1)
  end

  defp get_setting_record(state, key) when is_binary(key) and byte_size(key) in 1..64 do
    case query_one(state.connection, "SELECT value FROM app_settings WHERE key = ?", [key]) do
      {:ok, %{"value" => value}} -> {:ok, value}
      :not_found -> :not_found
    end
  end

  defp get_setting_record(_, _), do: {:error, :invalid_setting}

  defp put_setting_record(state, key, value)
       when is_binary(key) and byte_size(key) in 1..64 and is_binary(value) and
              byte_size(value) <= 4_096 do
    execute(
      state.connection,
      """
      INSERT INTO app_settings(key, value, updated_at_ms) VALUES (?, ?, ?)
      ON CONFLICT(key) DO UPDATE SET value = excluded.value, updated_at_ms = excluded.updated_at_ms
      """,
      [key, value, now_ms()]
    )
  end

  defp put_setting_record(_, _, _), do: {:error, :invalid_setting}

  defp claim_command_record(state, command_id, command_hash)
       when is_binary(command_id) and byte_size(command_id) in 1..64 and
              is_binary(command_hash) do
    if Digest.valid_sha256?(command_hash) do
      result =
        transaction(state.connection, &insert_command_claim(&1, command_id, command_hash))

      case result do
        {:ok, :execute} -> {:ok, :execute}
        {:ok, :existing} -> existing_command_receipt(state, command_id, command_hash)
        {:error, reason} -> {:error, reason}
      end
    else
      {:error, :invalid_command_hash}
    end
  rescue
    error in Exqlite.Error -> {:error, {:database, error.message}}
  end

  defp claim_command_record(_, _, _),
    do: {:error, :invalid_command_receipt}

  defp insert_command_claim(connection, command_id, command_hash) do
    inserted =
      Exqlite.query!(
        connection,
        """
        INSERT INTO command_receipts(
          command_id, command_hash, status, error_code, created_at_ms, completed_at_ms
        ) VALUES (?, ?, 'pending', NULL, ?, NULL)
        ON CONFLICT(command_id) DO NOTHING
        RETURNING command_id
        """,
        [command_id, command_hash, now_ms()]
      )

    case inserted.rows do
      [[^command_id]] ->
        DiagnosticsStore.record_audit(connection, "command.claimed", nil, %{
          "commandId" => command_id
        })

        :execute

      [] ->
        :existing
    end
  end

  defp existing_command_receipt(state, command_id, command_hash) do
    case query_one(
           state.connection,
           "SELECT command_hash, status, error_code FROM command_receipts WHERE command_id = ?",
           [command_id]
         ) do
      {:ok, %{"command_hash" => ^command_hash, "status" => "pending"}} ->
        {:ok, :pending}

      {:ok, %{"command_hash" => ^command_hash, "status" => "succeeded"}} ->
        {:ok, {:replay, :ok}}

      {:ok,
       %{
         "command_hash" => ^command_hash,
         "status" => "failed",
         "error_code" => error_code
       }}
      when is_binary(error_code) ->
        {:ok, {:replay, {:error, error_code}}}

      {:ok, _} ->
        {:error, :command_id_conflict}

      :not_found ->
        {:error, :command_receipt_missing}
    end
  end

  defp complete_command_record(state, command_id, command_hash, outcome)
       when is_binary(command_id) and byte_size(command_id) in 1..64 and
              is_binary(command_hash) do
    with true <- Digest.valid_sha256?(command_hash),
         {:ok, status, error_code} <- encode_command_outcome(outcome) do
      result =
        transaction(
          state.connection,
          &complete_pending_receipt(&1, command_id, command_hash, status, error_code)
        )

      case result do
        {:ok, :updated} ->
          :ok

        {:ok, :existing} ->
          validate_completed_receipt(state, command_id, command_hash, status, error_code)

        {:error, reason} ->
          {:error, reason}
      end
    else
      false -> {:error, :invalid_command_hash}
      {:error, reason} -> {:error, reason}
    end
  rescue
    error in Exqlite.Error -> {:error, {:database, error.message}}
  end

  defp complete_command_record(_, _, _, _),
    do: {:error, :invalid_command_receipt}

  defp complete_pending_receipt(connection, command_id, command_hash, status, error_code) do
    updated =
      Exqlite.query!(
        connection,
        """
        UPDATE command_receipts
        SET status = ?, error_code = ?, completed_at_ms = ?
        WHERE command_id = ? AND command_hash = ? AND status = 'pending'
        RETURNING command_id
        """,
        [status, error_code, now_ms(), command_id, command_hash]
      )

    case updated.rows do
      [[^command_id]] ->
        DiagnosticsStore.record_audit(connection, "command.completed", nil, %{
          "commandId" => command_id,
          "kind" => status
        })

        :updated

      [] ->
        :existing
    end
  end

  defp encode_command_outcome(:ok), do: {:ok, "succeeded", nil}

  defp encode_command_outcome({:error, code}) when is_atom(code) and not is_nil(code) do
    encoded = Atom.to_string(code)

    if byte_size(encoded) in 1..64 and String.match?(encoded, ~r/^[a-z0-9_]+$/),
      do: {:ok, "failed", encoded},
      else: {:error, :invalid_command_outcome}
  end

  defp encode_command_outcome(_), do: {:error, :invalid_command_outcome}

  defp validate_completed_receipt(state, command_id, command_hash, status, error_code) do
    case query_one(
           state.connection,
           """
           SELECT command_hash, status, error_code
           FROM command_receipts
           WHERE command_id = ?
           """,
           [command_id]
         ) do
      {:ok,
       %{
         "command_hash" => ^command_hash,
         "status" => ^status,
         "error_code" => ^error_code
       }} ->
        :ok

      {:ok, %{"command_hash" => ^command_hash, "status" => "pending"}} ->
        {:error, :command_completion_failed}

      {:ok, _} ->
        {:error, :command_id_conflict}

      :not_found ->
        {:error, :command_receipt_missing}
    end
  end

  defp admit_paired_frame(state, frame) do
    existing =
      case get_paired_frame_record(state, frame.frame_id) do
        {:ok, record} -> record
        :not_found -> nil
      end

    pin_owner = get_paired_frame_by_spki_record(state, frame.server_spki_fingerprint)

    thing_owner =
      query_one(state.connection, "SELECT frame_id FROM paired_frames WHERE thing_id = ?", [
        frame.thing_id
      ])

    case FrameRegistry.admission_decision(frame, existing, pin_owner, thing_owner) do
      :insert -> insert_paired_frame(state, frame)
      :reuse -> {:ok, existing}
      {:error, reason} -> {:error, reason}
    end
  end

  defp insert_paired_frame(state, frame) do
    now = now_ms()

    result =
      transaction(state.connection, fn connection ->
        Exqlite.query!(
          connection,
          """
          INSERT INTO paired_frames(
            frame_id, thing_id, title, medium, td_json, capabilities_json,
            credential_ref, server_spki_fingerprint, connection_state,
            paired_at_ms, updated_at_ms
          ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, 'waitingForContact', ?, ?)
          """,
          [
            frame.frame_id,
            frame.thing_id,
            frame.title,
            frame.medium,
            frame.td_json,
            frame.capabilities_json,
            frame.credential_ref,
            frame.server_spki_fingerprint,
            now,
            now
          ]
        )

        DiagnosticsStore.record_audit(connection, "frame.paired", nil, %{
          "frameId" => frame.frame_id,
          "thingId" => frame.thing_id
        })

        frame.frame_id
      end)

    case result do
      {:ok, frame_id} -> get_paired_frame_record(state, frame_id)
      {:error, %Exqlite.Error{message: message}} -> {:error, {:database, message}}
      {:error, reason} -> {:error, reason}
    end
  end

  defp list_paired_frame_records(state) do
    state.connection
    |> Exqlite.query!("""
    SELECT frame_id, thing_id, title, medium, capabilities_json, connection_state
    FROM paired_frames
    ORDER BY title COLLATE NOCASE, frame_id
    """)
    |> rows_to_maps()
    |> Enum.map(&decode_frame_record/1)
  end

  defp get_paired_frame_record(state, frame_id)
       when is_binary(frame_id) and byte_size(frame_id) in 1..128 do
    case query_one(
           state.connection,
           """
           SELECT frame_id, thing_id, title, medium, td_json, capabilities_json,
                  credential_ref, server_spki_fingerprint, connection_state,
                  paired_at_ms, updated_at_ms
           FROM paired_frames
           WHERE frame_id = ?
           """,
           [frame_id]
         ) do
      {:ok, frame} -> {:ok, decode_frame_record(frame)}
      :not_found -> :not_found
    end
  end

  defp get_paired_frame_record(_, _), do: :not_found

  defp get_paired_frame_by_spki_record(state, "sha256:" <> hex = fingerprint)
       when byte_size(hex) == 64 do
    if Digest.valid_sha256?(fingerprint) do
      rows =
        state.connection
        |> Exqlite.query!(
          "SELECT frame_id FROM paired_frames WHERE server_spki_fingerprint = ? LIMIT 2",
          [fingerprint]
        )
        |> rows_to_maps()

      case rows do
        [%{"frame_id" => frame_id}] -> get_paired_frame_record(state, frame_id)
        [] -> :not_found
        [_, _] -> {:error, :ambiguous_frame_identity}
      end
    else
      :not_found
    end
  end

  defp get_paired_frame_by_spki_record(_, _), do: :not_found

  defp forget_paired_frame_record(state, frame_id)
       when is_binary(frame_id) and byte_size(frame_id) in 1..128 do
    case get_paired_frame_record(state, frame_id) do
      {:ok, _} -> forget_existing_frame(state, frame_id)
      :not_found -> {:error, :not_found}
    end
  end

  defp forget_paired_frame_record(_, _), do: {:error, :invalid_frame}

  defp forget_existing_frame(state, frame_id) do
    result =
      transaction(state.connection, fn connection ->
        Exqlite.query!(connection, "DELETE FROM frame_outboxes WHERE frame_id = ?", [frame_id])

        Exqlite.query!(connection, "DELETE FROM frame_outbox_revisions WHERE frame_id = ?", [
          frame_id
        ])

        Exqlite.query!(connection, "DELETE FROM frame_asset_refs WHERE frame_id = ?", [frame_id])
        Exqlite.query!(connection, "DELETE FROM paired_frames WHERE frame_id = ?", [frame_id])

        Exqlite.query!(
          connection,
          "DELETE FROM app_settings WHERE key = 'frame.selected' AND value = ?",
          [frame_id]
        )

        Exqlite.query!(connection, "DELETE FROM app_settings WHERE key = ?", [
          "playlist.interval." <> frame_id
        ])

        DiagnosticsStore.record_audit(connection, "frame.forgotten", nil, %{"frameId" => frame_id})

        :ok
      end)

    case result do
      {:ok, :ok} -> :ok
      {:error, %Exqlite.Error{message: message}} -> {:error, {:database, message}}
      {:error, reason} -> {:error, reason}
    end
  end

  defp decode_frame_record(frame) do
    {capabilities_json, frame} = Map.pop!(frame, "capabilities_json")
    Map.put(frame, "capabilities", JSON.decode!(capabilities_json))
  end

  defp restore_master_record(state, digest, command_id) do
    with true <- Digest.valid_sha256?(digest),
         {:ok, %{"storage_state" => storage_state}} <-
           query_one(
             state.connection,
             "SELECT o.storage_state FROM masters m JOIN objects o ON o.digest = m.digest WHERE m.digest = ?",
             [digest]
           ),
         :ok <- ContentStore.reconcile(state.data_dir, digest, storage_state),
         :ok <- ContentStore.verify(state.data_dir, digest, storage_state),
         :ok <- maybe_restore_file(state, digest, storage_state),
         :ok <- ContentStore.verify(state.data_dir, digest, "active") do
      result =
        transaction(state.connection, fn connection ->
          Exqlite.query!(connection, "UPDATE masters SET removed_at_ms = NULL WHERE digest = ?", [
            digest
          ])

          Exqlite.query!(
            connection,
            "UPDATE objects SET storage_state = 'active', trashed_at_ms = NULL WHERE digest = ?",
            [digest]
          )

          DiagnosticsStore.record_audit(connection, "master.restored", digest, %{
            "commandId" => command_id
          })

          :ok
        end)
        |> Writer.unwrap()

      if match?({:error, _}, result),
        do: ContentStore.reconcile(state.data_dir, digest, storage_state)

      result
    else
      false -> {:error, :invalid_digest}
      :not_found -> {:error, :not_found}
      {:error, reason} -> {:error, reason}
    end
  end

  defp maybe_restore_file(_, _, "active"), do: :ok

  defp maybe_restore_file(state, digest, "trash"),
    do: ContentStore.restore(state.data_dir, digest)

  defp protect_frame_asset_record(state, frame_id, role, digest)
       when is_binary(frame_id) and frame_id != "" and role in @frame_roles do
    write_existing_object(state, digest, fn ->
      execute(
        state.connection,
        "INSERT INTO frame_asset_refs(frame_id, role, object_digest) VALUES (?, ?, ?) ON CONFLICT DO NOTHING",
        [frame_id, role, digest]
      )
    end)
  end

  defp protect_frame_asset_record(_, _, _, _),
    do: {:error, :invalid_frame_reference}

  defp collect_removed_records(state) do
    candidates =
      state.connection
      |> Exqlite.query!("""
      SELECT m.digest
      FROM masters m
      JOIN objects o ON o.digest = m.digest
      WHERE m.removed_at_ms IS NOT NULL
        AND o.storage_state = 'active'
        AND NOT EXISTS (SELECT 1 FROM pins p WHERE p.object_digest = m.digest)
        AND NOT EXISTS (SELECT 1 FROM frame_asset_refs f WHERE f.object_digest = m.digest)
        AND NOT EXISTS (SELECT 1 FROM artifact_recipe_links a WHERE a.master_digest = m.digest)
        AND NOT EXISTS (SELECT 1 FROM recipe_sources r WHERE r.source_digest = m.digest)
      ORDER BY m.digest
      """)
      |> Map.fetch!(:rows)
      |> Enum.map(&hd/1)

    collected =
      Enum.reduce(candidates, [], fn digest, moved ->
        case ContentStore.move_to_trash(state.data_dir, digest) do
          :ok ->
            :ok =
              execute(
                state.connection,
                "UPDATE objects SET storage_state = 'trash', trashed_at_ms = ? WHERE digest = ?",
                [now_ms(), digest]
              )

            [digest | moved]

          {:error, _} ->
            moved
        end
      end)

    {:ok, Enum.reverse(collected)}
  end

  defp get_master_record(state, digest) do
    case query_one(
           state.connection,
           """
           SELECT m.digest, m.title, m.source_kind, m.width, m.height,
                  m.color_profile, m.orientation, m.provenance_json, m.parent_digest,
                  m.generation_recipe_hash, m.removed_at_ms, o.media_type, o.storage_state,
                  (p.object_digest IS NOT NULL) AS pinned
           FROM masters m
           JOIN objects o ON o.digest = m.digest
           LEFT JOIN pins p ON p.object_digest = m.digest
           WHERE m.digest = ?
           """,
           [digest]
         ) do
      {:ok, master} -> {:ok, decode_master_row(master)}
      :not_found -> :not_found
    end
  end

  defp read_object_record(state, digest, maximum_bytes)
       when is_integer(maximum_bytes) and maximum_bytes > 0 do
    case query_one(
           state.connection,
           "SELECT digest, byte_count, media_type, storage_state FROM objects WHERE digest = ?",
           [digest]
         ) do
      {:ok, %{"storage_state" => "active", "byte_count" => byte_count} = object}
      when byte_count <= maximum_bytes ->
        case ContentStore.read(state.data_dir, digest, maximum_bytes) do
          {:ok, bytes} -> {:ok, Map.put(object, "bytes", bytes)}
          {:error, reason} -> {:error, reason}
        end

      {:ok, %{"storage_state" => "active"}} ->
        {:error, :object_too_large}

      {:ok, _} ->
        {:error, :object_in_trash}

      :not_found ->
        :not_found
    end
  end

  defp read_object_record(_, _, _), do: {:error, :invalid_read}

  defp cached_generation_record(state, recipe_hash) do
    case query_one(
           state.connection,
           """
           SELECT gr.master_digest AS digest, gr.provider_result_id,
                  gr.provenance_json AS generation_provenance_json
           FROM generation_results gr
           JOIN masters m ON m.digest = gr.master_digest
           WHERE gr.recipe_hash = ? AND m.removed_at_ms IS NULL
           """,
           [recipe_hash]
         ) do
      {:ok, generation} -> generation_master_record(state, recipe_hash, generation)
      :not_found -> :not_found
    end
  end

  defp generation_master_record(
         state,
         recipe_hash,
         %{
           "digest" => digest,
           "provider_result_id" => provider_result_id,
           "generation_provenance_json" => provenance_json
         }
       ) do
    with {:ok, master} <- get_master_record(state, digest) do
      generation = %{
        "recipe_hash" => recipe_hash,
        "provider_result_id" => provider_result_id,
        "provenance" => JSON.decode!(provenance_json)
      }

      {:ok, Map.put(master, "generation", generation)}
    end
  end

  defp queue_outbox_record(
         state,
         frame_id,
         digest,
         profile_id,
         playlist_revision,
         command_id,
         work_digest
       )
       when is_binary(frame_id) and frame_id != "" and is_binary(profile_id) do
    with true <- Digest.valid_sha256?(digest),
         true <- playlist_revision == nil or Digest.valid_sha256?(playlist_revision),
         true <- is_nil(command_id) or (is_binary(command_id) and byte_size(command_id) in 1..64),
         :ok <-
           Schema.validate("outbox-manifest", %{
             "revision" => 1,
             "desiredAsset" => digest,
             "artifactProfile" => profile_id,
             "playlistRevision" => playlist_revision
           }),
         :ok <- require_artifact_profile(state, digest, profile_id),
         {:ok, qualification_digest} <-
           WorkStore.delivery_binding(
             state.connection,
             work_digest,
             frame_id,
             digest,
             profile_id,
             "pull"
           ) do
      result =
        transaction(state.connection, fn connection ->
          PlaylistStore.cancel_pending(connection, frame_id)
          revision = next_outbox_revision(connection, frame_id)

          Exqlite.query!(
            connection,
            "DELETE FROM frame_asset_refs WHERE frame_id = ? AND role = 'queued'",
            [frame_id]
          )

          Exqlite.query!(
            connection,
            """
            INSERT INTO frame_outboxes(
              frame_id, revision, desired_digest, profile_id, playlist_revision, queued_at_ms,
              command_id, work_digest, qualification_digest
            ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)
            ON CONFLICT(frame_id) DO UPDATE SET
              revision = excluded.revision,
              desired_digest = excluded.desired_digest,
              profile_id = excluded.profile_id,
              playlist_revision = excluded.playlist_revision,
              queued_at_ms = excluded.queued_at_ms,
              command_id = excluded.command_id,
              work_digest = excluded.work_digest,
              qualification_digest = excluded.qualification_digest
            """,
            [
              frame_id,
              revision,
              digest,
              profile_id,
              playlist_revision,
              now_ms(),
              command_id,
              work_digest,
              qualification_digest
            ]
          )

          Exqlite.query!(
            connection,
            """
            INSERT INTO frame_asset_refs(
              frame_id, role, object_digest, work_digest, qualification_digest
            ) VALUES (?, 'queued', ?, ?, ?)
            """,
            [frame_id, digest, work_digest, qualification_digest]
          )

          DiagnosticsStore.record_audit(connection, "outbox.queued", digest, %{
            "frameId" => frame_id,
            "revision" => revision,
            "commandId" => command_id
          })

          revision
        end)

      case result do
        {:ok, _} -> outbox_manifest_record(state, frame_id)
        {:error, %Exqlite.Error{message: message}} -> {:error, {:database, message}}
        {:error, reason} -> {:error, reason}
      end
    else
      false -> {:error, :invalid_digest}
      {:error, %JSV.ValidationError{}} -> {:error, :invalid_outbox}
      {:error, reason} -> {:error, reason}
    end
  end

  defp queue_outbox_record(
         _,
         _,
         _,
         _,
         _,
         _,
         _
       ),
       do: {:error, :invalid_outbox}

  defp next_outbox_revision(connection, frame_id) do
    connection
    |> Exqlite.query!(
      """
      INSERT INTO frame_outbox_revisions(frame_id, revision)
      VALUES (?, 1)
      ON CONFLICT(frame_id) DO UPDATE SET revision = revision + 1
      RETURNING revision
      """,
      [frame_id]
    )
    |> Map.fetch!(:rows)
    |> then(fn [[revision]] -> revision end)
  end

  defp outbox_manifest_record(state, frame_id) do
    case query_one(
           state.connection,
           """
           SELECT revision, desired_digest, profile_id, playlist_revision
           FROM frame_outboxes
           WHERE frame_id = ?
           """,
           [frame_id]
         ) do
      {:ok, row} ->
        {:ok,
         %{
           "revision" => row["revision"],
           "desiredAsset" => row["desired_digest"],
           "artifactProfile" => row["profile_id"],
           "playlistRevision" => row["playlist_revision"]
         }}

      :not_found ->
        :empty
    end
  end

  defp acknowledge_outbox_record(state, frame_id, acknowledgement) when is_binary(frame_id) do
    with :ok <- Schema.validate("outbox-ack", acknowledgement),
         {:ok, manifest} <- outbox_manifest_record(state, frame_id) do
      case Transition.pull_confirmation(manifest, acknowledgement) do
        :commit -> commit_outbox_acknowledgement(state, frame_id, manifest)
        :pending -> {:ok, :pending}
        {:error, reason} -> {:error, reason}
      end
    else
      :empty -> {:error, :outbox_empty}
      {:error, %JSV.ValidationError{}} -> {:error, :invalid_acknowledgement}
      {:error, reason} -> {:error, reason}
    end
  end

  defp acknowledge_outbox_record(_, _, _),
    do: {:error, :invalid_acknowledgement}

  defp commit_outbox_acknowledgement(state, frame_id, manifest) do
    digest = manifest["desiredAsset"]

    with :ok <- require_pending_playlist(state.connection, frame_id, manifest) do
      do_commit_outbox_acknowledgement(state, frame_id, manifest, digest)
    end
  end

  defp require_pending_playlist(_, _, %{"playlistRevision" => nil}), do: :ok

  defp require_pending_playlist(connection, frame_id, %{"playlistRevision" => revision}) do
    case PlaylistStore.pending_body(connection, frame_id, revision) do
      {:ok, _} -> :ok
      :not_found -> {:error, :playlist_missing}
    end
  end

  defp do_commit_outbox_acknowledgement(state, frame_id, manifest, digest) do
    result =
      transaction(state.connection, fn connection ->
        {:ok, custody} =
          query_one(
            connection,
            """
            SELECT command_id, work_digest, qualification_digest
            FROM frame_outboxes WHERE frame_id = ?
            """,
            [frame_id]
          )

        Exqlite.query!(
          connection,
          "DELETE FROM frame_asset_refs WHERE frame_id = ? AND role = 'previous-known-good'",
          [frame_id]
        )

        Exqlite.query!(
          connection,
          """
          INSERT INTO frame_asset_refs(
            frame_id, role, object_digest, work_digest, qualification_digest
          )
          SELECT frame_id, 'previous-known-good', object_digest,
                 work_digest, qualification_digest
          FROM frame_asset_refs
          WHERE frame_id = ? AND role = 'current'
          """,
          [frame_id]
        )

        Exqlite.query!(
          connection,
          "DELETE FROM frame_asset_refs WHERE frame_id = ? AND role IN ('current', 'queued')",
          [frame_id]
        )

        Exqlite.query!(
          connection,
          """
          INSERT INTO frame_asset_refs(
            frame_id, role, object_digest, work_digest, qualification_digest
          ) VALUES (?, 'current', ?, ?, ?)
          """,
          [frame_id, digest, custody["work_digest"], custody["qualification_digest"]]
        )

        if manifest["playlistRevision"] do
          :ok = PlaylistStore.confirm(connection, frame_id, manifest["playlistRevision"])
        else
          :ok = PlaylistStore.suspend(connection, frame_id)
        end

        Exqlite.query!(connection, "DELETE FROM frame_outboxes WHERE frame_id = ?", [frame_id])

        DiagnosticsStore.record_audit(connection, "outbox.acknowledged", digest, %{
          "frameId" => frame_id,
          "commandId" => custody["command_id"]
        })

        :ok
      end)

    case result do
      {:ok, :ok} -> :ok
      {:error, %Exqlite.Error{message: message}} -> {:error, {:database, message}}
      {:error, reason} -> {:error, reason}
    end
  end

  defp begin_direct_delivery_record(state, frame_id, digest, profile_id, request_id, work_digest) do
    with :ok <- validate_direct_intent(frame_id, digest, profile_id, request_id),
         {:ok, frame} <- get_paired_frame_record(state, frame_id),
         :ok <- require_push_mode(frame),
         :ok <- require_artifact_profile(state, digest, profile_id),
         {:ok, qualification_digest} <-
           direct_delivery_binding(state, work_digest, frame_id, digest, profile_id, request_id) do
      begin_or_replay_direct_delivery(
        state,
        frame_id,
        digest,
        profile_id,
        request_id,
        work_digest,
        qualification_digest
      )
    else
      :not_found -> {:error, :frame_not_paired}
      {:error, reason} -> {:error, reason}
    end
  end

  defp direct_delivery_binding(state, work_digest, frame_id, digest, profile_id, request_id) do
    case WorkStore.delivery_binding(
           state.connection,
           work_digest,
           frame_id,
           digest,
           profile_id,
           "push"
         ) do
      {:error, :qualification_required} ->
        legacy_direct_replay(state, frame_id, digest, profile_id, request_id)

      result ->
        result
    end
  end

  defp legacy_direct_replay(state, frame_id, digest, profile_id, request_id) do
    case direct_delivery_record(state, frame_id) do
      {:ok,
       %{"work_digest" => nil, "qualification_digest" => nil, "status" => "pending"} =
           delivery} ->
        case Transition.direct_request(to_direct_intent(delivery), digest, profile_id, request_id) do
          {:reuse, _} -> {:ok, nil}
          _ -> {:error, :qualification_required}
        end

      _ ->
        {:error, :qualification_required}
    end
  end

  defp validate_direct_intent(frame_id, digest, profile_id, request_id) do
    if is_binary(frame_id) and byte_size(frame_id) in 1..128 and
         Digest.valid_sha256?(digest) and is_binary(profile_id) and
         byte_size(profile_id) in 1..256 and is_binary(request_id) and
         byte_size(request_id) in 1..64 do
      :ok
    else
      {:error, :invalid_direct_delivery}
    end
  end

  defp require_push_mode(%{"capabilities" => %{"transferModes" => modes}}) do
    if "push" in modes, do: :ok, else: {:error, :compatible_binding_unavailable}
  end

  defp require_artifact_profile(state, digest, profile_id) do
    case query_one(
           state.connection,
           "SELECT 1 AS present FROM artifact_recipe_links WHERE artifact_digest = ? AND profile_id = ? LIMIT 1",
           [digest, profile_id]
         ) do
      {:ok, _} ->
        :ok

      :not_found ->
        case query_one(state.connection, "SELECT 1 AS present FROM artifacts WHERE digest = ?", [
               digest
             ]) do
          {:ok, _} -> {:error, :unsupported_profile}
          :not_found -> {:error, :artifact_missing}
        end
    end
  end

  defp begin_or_replay_direct_delivery(
         state,
         frame_id,
         digest,
         profile_id,
         request_id,
         work_digest,
         qualification_digest
       ) do
    case direct_delivery_record(state, frame_id) do
      {:ok, delivery} ->
        case Transition.direct_request(to_direct_intent(delivery), digest, profile_id, request_id) do
          {:reuse, _} ->
            reuse_direct_delivery(delivery, work_digest)

          :insert ->
            insert_direct_delivery(
              state,
              frame_id,
              digest,
              profile_id,
              request_id,
              work_digest,
              qualification_digest
            )

          {:error, reason} ->
            {:error, reason}
        end

      :not_found ->
        insert_direct_delivery(
          state,
          frame_id,
          digest,
          profile_id,
          request_id,
          work_digest,
          qualification_digest
        )
    end
  end

  defp reuse_direct_delivery(%{"work_digest" => work_digest} = delivery, work_digest),
    do: {:ok, delivery}

  defp reuse_direct_delivery(_, _), do: {:error, :qualification_intent_conflict}

  defp insert_direct_delivery(
         state,
         frame_id,
         digest,
         profile_id,
         request_id,
         work_digest,
         qualification_digest
       ) do
    result =
      transaction(state.connection, fn connection ->
        Exqlite.query!(
          connection,
          "DELETE FROM frame_asset_refs WHERE frame_id = ? AND role = 'desired'",
          [frame_id]
        )

        Exqlite.query!(
          connection,
          """
          INSERT INTO frame_asset_refs(
            frame_id, role, object_digest, work_digest, qualification_digest
          ) VALUES (?, 'desired', ?, ?, ?)
          """,
          [frame_id, digest, work_digest, qualification_digest]
        )

        Exqlite.query!(
          connection,
          """
          INSERT INTO frame_direct_deliveries(
            frame_id, revision, desired_digest, profile_id, request_id, status, updated_at_ms,
            work_digest, qualification_digest
          ) VALUES (?, 1, ?, ?, ?, 'pending', ?, ?, ?)
          ON CONFLICT(frame_id) DO UPDATE SET
            revision = revision + 1,
            desired_digest = excluded.desired_digest,
            profile_id = excluded.profile_id,
            request_id = excluded.request_id,
            status = 'pending',
            updated_at_ms = excluded.updated_at_ms,
            work_digest = excluded.work_digest,
            qualification_digest = excluded.qualification_digest
          """,
          [frame_id, digest, profile_id, request_id, now_ms(), work_digest, qualification_digest]
        )

        DiagnosticsStore.record_audit(connection, "direct.desired", digest, %{
          "frameId" => frame_id,
          "requestId" => request_id
        })

        :ok
      end)

    case result do
      {:ok, :ok} -> direct_delivery_record(state, frame_id)
      {:error, %Exqlite.Error{message: message}} -> {:error, {:database, message}}
      {:error, reason} -> {:error, reason}
    end
  end

  defp direct_delivery_record(state, frame_id) when is_binary(frame_id) do
    query_one(
      state.connection,
      """
      SELECT frame_id, revision, desired_digest, profile_id, request_id, status, updated_at_ms,
             work_digest, qualification_digest
      FROM frame_direct_deliveries WHERE frame_id = ?
      """,
      [frame_id]
    )
  end

  defp direct_delivery_record(_, _), do: :not_found

  defp delivery_custody_record(state, frame_id)
       when is_binary(frame_id) and byte_size(frame_id) in 1..128 do
    state.connection
    |> Exqlite.query!(
      """
      SELECT role, object_digest, work_digest, qualification_digest
      FROM frame_asset_refs
      WHERE frame_id = ? AND role IN ('queued', 'desired', 'current', 'previous-known-good')
      ORDER BY role, object_digest
      """,
      [frame_id]
    )
    |> rows_to_maps()
    |> Enum.group_by(& &1["role"], fn row ->
      %{
        "artifact_digest" => row["object_digest"],
        "work_digest" => row["work_digest"],
        "qualification_digest" => row["qualification_digest"],
        "status" => if(row["work_digest"], do: "qualified", else: "legacy_unqualified")
      }
    end)
  end

  defp delivery_custody_record(_, _), do: {:error, :invalid_frame}

  defp record_direct_attempt_record(state, frame_id, request_id, attempt_id, mode, phase)
       when mode in [:push, :reconcile] and
              phase in [:started, :displayed, :pending, :unknown, :failed] and
              is_binary(request_id) and byte_size(request_id) in 1..64 and
              is_binary(attempt_id) and byte_size(attempt_id) == 32 do
    if valid_attempt_id?(attempt_id) do
      persist_direct_attempt(state, frame_id, request_id, attempt_id, mode, phase)
    else
      {:error, :invalid_direct_attempt}
    end
  end

  defp record_direct_attempt_record(_, _, _, _, _, _), do: {:error, :invalid_direct_attempt}

  defp valid_attempt_id?(nil), do: true

  defp valid_attempt_id?(value) when is_binary(value) and byte_size(value) == 32,
    do: String.match?(value, ~r/\A[0-9a-f]{32}\z/)

  defp valid_attempt_id?(_), do: false

  defp persist_direct_attempt(state, frame_id, request_id, attempt_id, mode, phase) do
    with {:ok, %{"request_id" => ^request_id}} <- direct_delivery_record(state, frame_id),
         :ok <- require_pending_attempt(state, frame_id, phase),
         :ok <- require_started_attempt(state.connection, request_id, attempt_id, mode, phase) do
      persist_direct_attempt_audit(state.connection, request_id, attempt_id, mode, phase)
    else
      :not_found -> {:error, :direct_delivery_missing}
      {:ok, _} -> {:error, :direct_delivery_conflict}
      {:error, reason} -> {:error, reason}
    end
  end

  defp persist_direct_attempt_audit(connection, request_id, attempt_id, mode, phase) do
    operation =
      if phase == :started, do: "direct.attempt.started", else: "direct.attempt.completed"

    result =
      transaction(connection, fn writer ->
        DiagnosticsStore.record_audit(writer, operation, nil, %{
          "requestId" => request_id,
          "attemptId" => attempt_id,
          "kind" => Atom.to_string(mode),
          "outcome" => Atom.to_string(phase)
        })
      end)

    case result do
      {:ok, :ok} -> :ok
      {:error, reason} -> {:error, reason}
    end
  end

  defp require_pending_attempt(state, frame_id, :started) do
    case direct_delivery_record(state, frame_id) do
      {:ok, %{"status" => "pending"}} -> :ok
      _ -> {:error, :direct_delivery_conflict}
    end
  end

  defp require_pending_attempt(_, _, _), do: :ok

  defp require_started_attempt(_, _, _, _, :started), do: :ok

  defp require_started_attempt(connection, request_id, attempt_id, mode, _) do
    case query_one(
           connection,
           """
           SELECT detail_json FROM audit_entries
           WHERE operation = 'direct.attempt.started' AND correlation_id = ? AND attempt_id = ?
           LIMIT 1
           """,
           [Digest.sha256(request_id), attempt_id]
         ) do
      {:ok, %{"detail_json" => details}} -> matching_started_attempt(details, mode)
      :not_found -> {:error, :unknown_direct_attempt}
    end
  end

  defp matching_started_attempt(details, mode) do
    case Jason.decode(details) do
      {:ok, %{"kind" => kind, "outcome" => "started"}} ->
        if kind in ~w(push reconcile) and (mode == :any or kind == Atom.to_string(mode)),
          do: :ok,
          else: {:error, :unknown_direct_attempt}

      _ ->
        {:error, :unknown_direct_attempt}
    end
  end

  defp finish_direct_delivery_record(
         state,
         frame_id,
         revision,
         request_id,
         digest,
         outcome,
         attempt_id
       )
       when outcome in [:displayed, :pending] and
              (is_nil(attempt_id) or (is_binary(attempt_id) and byte_size(attempt_id) == 32)) do
    with {:ok, delivery} <- direct_delivery_record(state, frame_id) do
      case Transition.direct_confirmation(
             to_direct_intent(delivery),
             revision,
             request_id,
             digest,
             outcome
           ) do
        :commit ->
          commit_confirmed_attempt(state, delivery, request_id, attempt_id)

        :already ->
          :ok

        :pending ->
          {:ok, :pending}

        {:error, reason} ->
          {:error, reason}
      end
    else
      :not_found -> {:error, :direct_delivery_missing}
    end
  end

  defp finish_direct_delivery_record(
         _,
         _,
         _,
         _,
         _,
         _,
         _
       ),
       do: {:error, :invalid_direct_delivery}

  defp require_confirmation_attempt(_, _, nil), do: :ok

  defp require_confirmation_attempt(connection, request_id, attempt_id),
    do: require_started_attempt(connection, request_id, attempt_id, :any, :displayed)

  defp commit_confirmed_attempt(state, delivery, request_id, attempt_id) do
    with :ok <- require_confirmation_attempt(state.connection, request_id, attempt_id) do
      finish_matching_direct_delivery(state, delivery, :displayed, attempt_id)
    end
  end

  defp finish_matching_direct_delivery(state, delivery, :displayed, attempt_id) do
    frame_id = delivery["frame_id"]
    digest = delivery["desired_digest"]

    result =
      transaction(state.connection, fn connection ->
        Exqlite.query!(
          connection,
          "DELETE FROM frame_asset_refs WHERE frame_id = ? AND role = 'previous-known-good'",
          [frame_id]
        )

        Exqlite.query!(
          connection,
          """
          INSERT INTO frame_asset_refs(
            frame_id, role, object_digest, work_digest, qualification_digest
          )
          SELECT frame_id, 'previous-known-good', object_digest,
                 work_digest, qualification_digest
          FROM frame_asset_refs WHERE frame_id = ? AND role = 'current'
          """,
          [frame_id]
        )

        Exqlite.query!(
          connection,
          "DELETE FROM frame_asset_refs WHERE frame_id = ? AND role IN ('current', 'desired')",
          [frame_id]
        )

        Exqlite.query!(
          connection,
          """
          INSERT INTO frame_asset_refs(
            frame_id, role, object_digest, work_digest, qualification_digest
          ) VALUES (?, 'current', ?, ?, ?)
          """,
          [frame_id, digest, delivery["work_digest"], delivery["qualification_digest"]]
        )

        Exqlite.query!(
          connection,
          "UPDATE frame_direct_deliveries SET status = 'displayed', updated_at_ms = ? WHERE frame_id = ?",
          [now_ms(), frame_id]
        )

        Exqlite.query!(
          connection,
          "UPDATE paired_frames SET connection_state = 'displayed', updated_at_ms = ? WHERE frame_id = ?",
          [now_ms(), frame_id]
        )

        DiagnosticsStore.record_audit(connection, "direct.displayed", digest, %{
          "frameId" => frame_id,
          "requestId" => delivery["request_id"],
          "attemptId" => attempt_id
        })

        :ok
      end)

    case result do
      {:ok, :ok} -> :ok
      {:error, %Exqlite.Error{message: message}} -> {:error, {:database, message}}
      {:error, reason} -> {:error, reason}
    end
  end

  defp to_direct_intent(delivery) do
    %{
      request_id: delivery["request_id"],
      desired_digest: delivery["desired_digest"],
      profile_id: delivery["profile_id"],
      status: delivery["status"],
      revision: delivery["revision"]
    }
  end

  defp decode_master_row(row) do
    row
    |> Map.update("provenance_json", %{}, &JSON.decode!/1)
    |> Map.update("pinned", false, &(&1 == 1))
  end

  defp write_existing_master(state, digest, function) do
    case get_master_record(state, digest) do
      {:ok, _} -> function.()
      :not_found -> {:error, :not_found}
    end
  end

  defp write_existing_object(state, digest, function) do
    case query_one(state.connection, "SELECT digest FROM objects WHERE digest = ?", [digest]) do
      {:ok, _} -> function.()
      :not_found -> {:error, :not_found}
    end
  end

  defp execute(connection, sql, parameters) do
    case Exqlite.query(connection, sql, parameters) do
      {:ok, _} -> :ok
      {:error, %Exqlite.Error{message: message}} -> {:error, {:database, message}}
      {:error, reason} -> {:error, reason}
    end
  end

  defp transaction(connection, function), do: Writer.transaction(connection, function)

  defp emit_delivery_confirmation(mode, started_at_ms) when is_integer(started_at_ms) do
    :telemetry.execute(
      [:frameshift, :delivery, :confirmed],
      %{duration_ms: max(0, now_ms() - started_at_ms)},
      %{mode: mode}
    )
  end

  defp emit_delivery_confirmation(_, _), do: :ok

  defp query_one(connection, sql, parameters) do
    case connection |> Exqlite.query!(sql, parameters) |> rows_to_maps() do
      [row] -> {:ok, row}
      [] -> :not_found
    end
  end

  defp rows_to_maps(%Exqlite.Result{columns: columns, rows: rows}) do
    Enum.map(rows, &Map.new(Enum.zip(columns, &1)))
  end

  defp reconcile_objects(connection, data_dir) do
    connection
    |> Exqlite.query!("SELECT digest, storage_state FROM objects ORDER BY digest")
    |> Map.fetch!(:rows)
    |> Enum.reduce_while(:ok, fn [digest, storage_state], :ok ->
      case ContentStore.reconcile(data_dir, digest, storage_state) do
        :ok -> {:cont, :ok}
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
  end

  defp qualification_reply(state, stage, result) do
    outcome = if match?({:error, _}, result), do: :refused, else: :succeeded

    :telemetry.execute(
      [:frameshift, :qualification, :decision],
      %{count: 1},
      %{stage: stage, outcome: outcome}
    )

    {:reply, result, state}
  end

  defp now_ms, do: System.os_time(:millisecond)
end
