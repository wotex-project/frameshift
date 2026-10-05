defmodule Frameshift.GenerationTest do
  @moduledoc false

  use ExUnit.Case, async: false

  require Logger

  alias Frameshift.ContentStore
  alias Frameshift.Generation
  alias Frameshift.Library
  alias Frameshift.MasterPackage

  @original <<137, "PNG\r\n", 26, 10, 1, 2, 3>>
  @rgba :binary.copy(<<16, 32, 64, 255>>, 16 * 16)

  defmodule FixtureProvider do
    @moduledoc false

    @behaviour Frameshift.Generation.Provider

    @impl true
    def id, do: "fixture-local"

    @impl true
    def preflight(context) do
      send(context.test_pid, :provider_preflight)

      if context[:available] == false do
        {:error, :not_available}
      else
        {:ok,
         %{
           provider_id: "fixture-local",
           model: "fixture-model-v1",
           model_revision: context[:model_revision] || "fixture-model-r1",
           decoder_id: "fixture-codec",
           decoder_revision: context[:decoder_revision] || "fixture-codec-v1",
           destination: :local,
           capabilities: %{"still" => true},
           disclosures: %{"costClass" => "local-compute"}
         }}
      end
    end

    @impl true
    def generate(request, context) do
      send(context.test_pid, {:provider_generate, context.secret})
      send(context.test_pid, {:source_image, request[:source_image]})

      result = %{
        bytes: <<137, "PNG\r\n", 26, 10, 1, 2, 3>>,
        canonical_rgba: context[:rgba] || :binary.copy(<<16, 32, 64, 255>>, 16 * 16),
        canonical_representation: "rgba8-srgb-straight-alpha-top-left",
        decoder_id: "fixture-codec",
        decoder_revision: context[:result_decoder_revision] || "fixture-codec-v1",
        width: 16,
        height: 16,
        media_type: context[:media_type] || "image/png",
        result_id: "fixture-result-1"
      }

      {:ok, if(context[:raw], do: Map.delete(result, :canonical_rgba), else: result)}
    end
  end

  defmodule SlowProvider do
    @moduledoc false

    @behaviour Frameshift.Generation.Provider

    @impl true
    def id, do: "slow-fixture"

    @impl true
    def preflight(_) do
      {:ok,
       %{
         provider_id: "slow-fixture",
         model: "fixture-model-v1",
         model_revision: "fixture-model-r1",
         decoder_id: "fixture-codec",
         decoder_revision: "fixture-codec-v1",
         destination: :local,
         capabilities: %{},
         disclosures: %{}
       }}
    end

    @impl true
    def generate(_, context) do
      send(context.test_pid, {:slow_provider_worker, self()})
      Process.sleep(1_000)
      {:error, :unexpected_completion}
    end
  end

  defmodule FaultProvider do
    @moduledoc false

    @behaviour Frameshift.Generation.Provider

    @impl true
    def id, do: FixtureProvider.id()

    @impl true
    def preflight(context) do
      fault(:preflight, nil, context)
      FixtureProvider.preflight(context)
    end

    @impl true
    def generate(request, context) do
      fault(:generate, request, context)
      FixtureProvider.generate(request, context)
    end

    defp fault(stage, request, %{stage: stage} = context) do
      send(context.test_pid, {:fault_callback, stage, self()})
      private = {context.secret, request}
      Logger.error("private-provider-fixture", private_provider_context: private)

      case context.fault do
        :raise -> raise inspect(private)
        :throw -> throw(private)
        :exit -> exit(private)
      end
    end

    defp fault(_, _, _), do: :ok
  end

  defmodule InvalidResponseProvider do
    @moduledoc false

    @behaviour Frameshift.Generation.Provider

    @impl true
    def id, do: FixtureProvider.id()

    @impl true
    def preflight(%{stage: :preflight} = context) do
      send(context.test_pid, :invalid_callback)
      context.response
    end

    def preflight(context), do: FixtureProvider.preflight(context)

    @impl true
    def generate(_, context) do
      send(context.test_pid, :invalid_callback)
      context.response
    end
  end

  defmodule RawLogHandler do
    @moduledoc false

    @spec log(:logger.log_event(), map()) :: :ok
    def log(event, %{config: %{pid: pid, reference: reference}}) do
      send(pid, {reference, event})
      :ok
    end
  end

  setup do
    data_dir =
      Path.join(
        System.tmp_dir!(),
        "frameshift-generation-test-#{System.unique_integer([:positive, :monotonic])}"
      )

    on_exit(fn -> File.rm_rf!(data_dir) end)
    {:ok, library} = Library.start_link(data_dir: data_dir, name: nil)
    %{library: library, data_dir: data_dir}
  end

  test "an explicit provider result is cached across restart without persisting its context", %{
    library: library,
    data_dir: data_dir
  } do
    context = %{test_pid: self(), secret: "provider-secret-value"}

    assert {:ok, generated} =
             Generation.generate(library, FixtureProvider, request(),
               provider_context: context,
               timeout_ms: 500
             )

    assert generated[:cache] == :miss
    assert_receive :provider_preflight
    assert_receive {:provider_generate, "provider-secret-value"}

    assert generated["provenance_json"] == %{
             "kind" => "ai-generation",
             "model" => "fixture-model-v1",
             "modelRevision" => "fixture-model-r1",
             "originalMediaType" => "image/png",
             "decoder" => %{"id" => "fixture-codec", "revision" => "fixture-codec-v1"},
             "provider" => "fixture-local",
             "resultId" => "fixture-result-1",
             "seed" => 7
           }

    assert generated["generation"] == %{
             "provider_result_id" => "fixture-result-1",
             "provenance" => generated["provenance_json"],
             "recipe_hash" => generated["generation_recipe_hash"]
           }

    refute inspect(generated) =~ "provider-secret-value"

    GenServer.stop(library)
    {:ok, restarted} = Library.start_link(data_dir: data_dir, name: nil)

    assert {:ok, cached} =
             Generation.generate(restarted, FixtureProvider, request(),
               provider_context: %{test_pid: self(), available: false, secret: "different"},
               timeout_ms: 500
             )

    assert cached[:cache] == :hit
    refute_receive :provider_preflight, 20
    refute_receive {:provider_generate, _secret}, 20
  end

  test "a generation result can share immutable bytes with an imported master", %{
    library: library
  } do
    assert {:ok, imported} =
             Library.import_master(
               library,
               fixture_package(),
               imported_attributes()
             )

    assert {:ok, generated} =
             Generation.generate(library, FixtureProvider, request(%{seed: 10}),
               provider_context: %{test_pid: self(), secret: "unused"},
               timeout_ms: 500
             )

    assert generated["digest"] == imported["digest"]
    assert generated["source_kind"] == "import"
    assert generated["generation"]["recipe_hash"]
    assert generated["generation"]["provider_result_id"] == "fixture-result-1"
  end

  test "edit mode records its immutable parent", %{library: library} do
    assert {:ok, parent} =
             Library.import_master(
               library,
               fixture_package(:binary.copy(<<1, 2, 3, 255>>, 16 * 16)),
               imported_attributes()
             )

    edit_request =
      request(%{
        instruction: "Make a restrained variation",
        mode: "edit",
        parent_digest: parent["digest"],
        seed: 13
      })

    assert {:ok, variant} =
             Generation.generate(library, FixtureProvider, edit_request,
               provider_context: %{test_pid: self(), secret: "unused"},
               timeout_ms: 500
             )

    assert variant["parent_digest"] == parent["digest"]
    assert variant["generation"]["recipe_hash"] == variant["generation_recipe_hash"]
    assert_receive {:source_image, %{digest: digest, original: @original, rgba: source_rgba}}
    assert digest == parent["digest"]
    assert source_rgba == :binary.copy(<<1, 2, 3, 255>>, 16 * 16)
  end

  test "generated originals and canonical pixels persist in the renderable master container", c do
    assert {:ok, master} =
             Generation.generate(c.library, FixtureProvider, request(),
               provider_context: %{test_pid: self(), secret: "unused"}
             )

    assert master["media_type"] == MasterPackage.media_type()
    assert master["orientation"] == 1
    assert master["color_profile"] == "sRGB"
    assert {:ok, stored} = Library.read_object(c.library, master["digest"])

    assert {:ok, %{original: @original, rgba: @rgba, width: 16, height: 16}} =
             MasterPackage.decode(stored["bytes"])
  end

  test "raw results, malformed canonical bytes and mismatched decoder revisions cannot create masters",
       c do
    for {context, reason} <- [
          {%{raw: true}, :invalid_result_bytes},
          {%{rgba: <<1, 2, 3>>}, :invalid_rgba},
          {%{result_decoder_revision: "another-codec"}, :decoder_mismatch}
        ] do
      assert {:error, ^reason} =
               Generation.generate(c.library, FixtureProvider, request(),
                 provider_context: Map.merge(%{test_pid: self(), secret: "unused"}, context)
               )

      assert Library.search(c.library, "") == []
    end
  end

  test "model and decoder revisions enter cache identity and preflight must match them", c do
    assert {:ok, first} =
             Generation.generate(c.library, FixtureProvider, request(),
               provider_context: %{test_pid: self(), secret: "unused"}
             )

    assert_receive {:provider_generate, _}
    changed = request(%{model_revision: "model-r2"})

    assert {:error, {:provider, {:invalid_preflight, :model_revision_mismatch}}} =
             Generation.generate(c.library, FixtureProvider, changed,
               provider_context: %{test_pid: self(), secret: "unused"}
             )

    refute_receive {:provider_generate, _}, 20

    assert {:ok, second} =
             Generation.generate(c.library, FixtureProvider, changed,
               provider_context: %{test_pid: self(), secret: "unused", model_revision: "model-r2"}
             )

    assert second[:cache] == :miss
    assert second["generation"]["recipe_hash"] != first["generation"]["recipe_hash"]
    assert second["generation"]["provenance"]["modelRevision"] == "model-r2"
    changed_decoder = request(%{decoder_revision: "decoder-r2"})

    assert {:error, {:provider, {:invalid_preflight, :decoder_mismatch}}} =
             Generation.generate(c.library, FixtureProvider, changed_decoder,
               provider_context: %{test_pid: self(), secret: "unused"}
             )
  end

  test "corrupt cache refuses without provider retry; raw and removed edit parents refuse", c do
    assert {:ok, master} =
             Generation.generate(c.library, FixtureProvider, request(),
               provider_context: %{test_pid: self(), secret: "unused"}
             )

    assert_receive :provider_preflight
    assert_receive {:provider_generate, _}
    File.write!(ContentStore.object_path(c.data_dir, master["digest"]), "corrupt cached master")

    assert {:error, :generation_master_unavailable} =
             Generation.generate(c.library, FixtureProvider, request(),
               provider_context: %{test_pid: self(), secret: "unused"}
             )

    refute_receive :provider_preflight, 20

    {:ok, raw} =
      Library.import_master(c.library, "legacy raw bytes", %{
        imported_attributes()
        | media_type: "image/png"
      })

    assert {:error, :generation_master_unavailable} =
             Generation.generate(
               c.library,
               FixtureProvider,
               request(%{mode: "edit", parent_digest: raw["digest"]}),
               provider_context: %{test_pid: self(), secret: "unused"}
             )

    refute_receive :provider_preflight, 20

    {:ok, parent} =
      Library.import_master(
        c.library,
        fixture_package(:binary.copy(<<1, 2, 3, 255>>, 16 * 16)),
        imported_attributes()
      )

    :ok = Library.remove_master(c.library, parent["digest"])

    assert {:error, :generation_master_unavailable} =
             Generation.generate(
               c.library,
               FixtureProvider,
               request(%{mode: "edit", parent_digest: parent["digest"], seed: 99}),
               provider_context: %{test_pid: self(), secret: "unused"}
             )

    refute_receive :provider_preflight, 20

    assert {:error, :invalid_request} =
             Generation.generate(
               c.library,
               FixtureProvider,
               request(%{source_image: %{rgba: @rgba}})
             )
  end

  test "preflight failure returns without generation or fallback", %{library: library} do
    context = %{test_pid: self(), available: false, secret: "unused"}

    assert {:error, {:provider, :not_available}} =
             Generation.generate(library, FixtureProvider, request(%{seed: 8}),
               provider_context: context,
               timeout_ms: 500
             )

    assert_receive :provider_preflight
    refute_receive {:provider_generate, _secret}, 20
  end

  test "provider work is terminated at its explicit deadline", %{library: library} do
    slow_request = request(%{provider_id: "slow-fixture", seed: 9})

    assert {:error, :provider_timeout} =
             Generation.generate(library, SlowProvider, slow_request,
               timeout_ms: 50,
               provider_context: %{test_pid: self()}
             )

    assert_receive {:slow_provider_worker, worker}
    refute Process.alive?(worker)
    assert Library.search(library, "") == []
  end

  test "preflight and edit callback faults cannot reach any raw Logger handler", c do
    original = "private-edit-original-fixture"
    {:ok, package} = MasterPackage.encode(original, @rgba, 16, 16)
    {:ok, parent} = Library.import_master(c.library, package, imported_attributes())
    handler = :frameshift_generation_raw_fixture
    reference = make_ref()

    :ok =
      :logger.add_handler(handler, RawLogHandler, %{
        level: :error,
        config: %{pid: self(), reference: reference}
      })

    on_exit(fn -> :logger.remove_handler(handler) end)

    for stage <- [:preflight, :generate], fault <- [:raise, :throw, :exit] do
      private_request =
        request(%{
          instruction: "private-prompt-fixture",
          mode: "edit",
          parent_digest: parent["digest"],
          seed: System.unique_integer([:positive])
        })

      assert {:error, :provider_crashed} =
               Generation.generate(c.library, FaultProvider, private_request,
                 provider_context: %{
                   test_pid: self(),
                   stage: stage,
                   fault: fault,
                   secret: "private-provider-token-fixture"
                 }
               )

      assert_receive {:fault_callback, ^stage, worker}
      refute Process.alive?(worker)
    end

    Logger.error("ordinary-generation-log-fixture")
    assert_receive {^reference, %{msg: {:string, "ordinary-generation-log-fixture"}}}
    refute_receive {^reference, _}, 30
    assert [master] = Library.search(c.library, "")
    assert master["digest"] == parent["digest"]
  end

  test "malformed callback responses return a finite refusal without exposing private terms", c do
    for stage <- [:preflight, :generate],
        response <- ["private-response-fixture", {:ok, :ignored, "private-response-fixture"}] do
      assert {:error, {:provider, :invalid_response}} =
               Generation.generate(c.library, InvalidResponseProvider, request(),
                 provider_context: %{
                   test_pid: self(),
                   stage: stage,
                   secret: "private-token-fixture",
                   response: response
                 }
               )

      assert_receive :invalid_callback
    end

    assert Library.search(c.library, "") == []
  end

  test "provider errors expose only declared finite classes", c do
    for stage <- [:preflight, :generate],
        {reason, expected} <- [
          {"private-provider-error-fixture", :failed},
          {{:quota_exhausted, "private-account-fixture"}, :failed},
          {:not_available, :not_available},
          {:authentication_failed, :authentication_failed},
          {:quota_exhausted, :quota_exhausted},
          {:refused, :refused},
          {:unsupported_model, :unsupported_model},
          {:unsupported_request, :unsupported_request},
          {:download_required, :download_required},
          {:cancelled, :cancelled},
          {:failed, :failed}
        ] do
      assert {:error, {:provider, ^expected}} =
               Generation.generate(c.library, InvalidResponseProvider, request(),
                 provider_context: %{
                   test_pid: self(),
                   stage: stage,
                   secret: "private-token-fixture",
                   response: {:error, reason}
                 }
               )

      assert_receive :invalid_callback
    end

    assert Library.search(c.library, "") == []
  end

  test "a conflicting privacy filter refuses provider work but preserves cached reads", c do
    context = %{test_pid: self(), secret: "unused"}

    assert {:ok, master} =
             Generation.generate(c.library, FixtureProvider, request(), provider_context: context)

    assert_receive :provider_preflight
    assert_receive {:provider_generate, _}
    filter = :frameshift_native_codec_privacy
    previous = List.keyfind(:logger.get_primary_config().filters, filter, 0)
    :ok = :logger.remove_primary_filter(filter)
    conflict = {fn _, _ -> :ignore end, :independent_policy}
    :ok = :logger.add_primary_filter(filter, conflict)

    on_exit(fn ->
      :logger.remove_primary_filter(filter)
      if previous, do: :logger.add_primary_filter(filter, elem(previous, 1))
    end)

    assert {:error, :provider_privacy_unavailable} =
             Generation.generate(c.library, FixtureProvider, request(%{seed: 42}),
               provider_context: context
             )

    refute_receive :provider_preflight, 20
    assert {^filter, ^conflict} = List.keyfind(:logger.get_primary_config().filters, filter, 0)

    assert {:ok, cached} =
             Generation.generate(c.library, FixtureProvider, request(), provider_context: context)

    assert cached[:cache] == :hit
    assert cached["digest"] == master["digest"]
    refute_receive :provider_preflight, 20
  end

  test "real task capacity refusal leaves Library available and recovers after a child exits",
       c do
    tasks =
      Enum.reduce_while(1..64, [], fn _, tasks ->
        case Task.Supervisor.start_child(Frameshift.TaskSupervisor, fn ->
               receive do
                 :finish -> :ok
               end
             end) do
          {:ok, task} -> {:cont, [task | tasks]}
          {:error, :max_children} -> {:halt, tasks}
        end
      end)

    on_exit(fn ->
      Enum.each(tasks, &Task.Supervisor.terminate_child(Frameshift.TaskSupervisor, &1))
    end)

    assert tasks != []

    assert {:error, :max_children} =
             Task.Supervisor.start_child(Frameshift.TaskSupervisor, fn -> :ok end)

    context = %{test_pid: self(), secret: "unused"}

    assert {:error, :provider_unavailable} =
             Generation.generate(c.library, FixtureProvider, request(), provider_context: context)

    refute_receive :provider_preflight, 20
    assert Library.search(c.library, "") == []
    :ok = Task.Supervisor.terminate_child(Frameshift.TaskSupervisor, hd(tasks))

    assert {:ok, master} =
             Generation.generate(c.library, FixtureProvider, request(), provider_context: context)

    assert master[:cache] == :miss
    assert_receive :provider_preflight
    assert_receive {:provider_generate, _}
  end

  test "provider identity, invalid requests, and motion results are rejected", %{library: library} do
    assert {:error, :provider_mismatch} =
             Generation.generate(library, FixtureProvider, request(%{provider_id: "other"}))

    assert {:error, :invalid_instruction} =
             Generation.generate(library, FixtureProvider, request(%{instruction: ""}))

    assert {:error, :invalid_mode_parent} =
             Generation.generate(library, FixtureProvider, request(%{mode: "edit", seed: 11}))

    assert {:error, :invalid_disclosure} =
             Generation.generate(
               library,
               FixtureProvider,
               request(%{
                 disclosure: %{"destination" => "cloud", "acknowledged" => false}
               })
             )

    assert {:error, :invalid_result_media_type} =
             Generation.generate(library, FixtureProvider, request(%{seed: 12}),
               provider_context: %{test_pid: self(), secret: "unused", media_type: "video/mp4"}
             )
  end

  defp request(overrides \\ %{}) do
    Map.merge(
      %{
        adapter_revision: "fixture-adapter-v1",
        application_revision: "frameshift-preview-v1",
        base_instruction: "Create one still artwork.",
        base_instruction_revision: "still-base-v1",
        disclosure: %{"destination" => "local", "acknowledged" => true},
        provider_id: "fixture-local",
        model: "fixture-model-v1",
        model_revision: "fixture-model-r1",
        decoder_id: "fixture-codec",
        decoder_revision: "fixture-codec-v1",
        instruction: "A quiet geometric still",
        negative_instruction: "",
        mode: "generate",
        parameters: %{"quality" => "preview"},
        reproducibility: "deterministic",
        seed: 7,
        target_profile_id: "test-rgb24",
        target_profile_revision: "preview-v1",
        title: "Generated Study"
      },
      overrides
    )
  end

  defp fixture_package(rgba \\ @rgba) do
    {:ok, package} = MasterPackage.encode(@original, rgba, 16, 16)
    IO.iodata_to_binary(package)
  end

  defp imported_attributes do
    %{
      title: "Imported Fixture",
      source_kind: :import,
      width: 16,
      height: 16,
      media_type: MasterPackage.media_type(),
      color_profile: "sRGB",
      provenance: %{"kind" => "local-import"}
    }
  end
end
