defmodule Frameshift.NativeCodecTest do
  @moduledoc false

  use ExUnit.Case, async: false

  import ExUnit.CaptureLog

  require Logger

  alias Frameshift.Digest
  alias Frameshift.Library
  alias Frameshift.MasterPackage
  alias Frameshift.NativeCodec
  alias Frameshift.Renderer

  @codec_directory Path.expand("../../../../codec", __DIR__)
  @codec Path.join(@codec_directory, "target/release/frameshift-codec")
  @fixture Path.expand("../fixtures/native-codec-worker.c", __DIR__)
  @renderer_directory Path.expand("../../../../renderer", __DIR__)
  @renderer Path.join(@renderer_directory, "zig-out/bin/frameshift-raster")

  setup_all do
    for {command, arguments, directory} <- [
          {"cargo", ["build", "--locked", "--offline", "--release"], @codec_directory},
          {"zig", ["build", "-Doptimize=ReleaseSafe"], @renderer_directory}
        ] do
      {output, status} = System.cmd(command, arguments, cd: directory, stderr_to_stdout: true)
      assert status == 0, output
    end

    directory =
      Path.join(System.tmp_dir!(), "codec-fixtures-#{System.unique_integer([:positive])}")

    File.mkdir!(directory)
    File.chmod!(directory, 0o700)
    worker = Path.join(directory, "worker")
    bad_revision = Path.join(directory, "bad-revision")

    for {path, options} <- [{worker, []}, {bad_revision, ["-DBAD_REVISION"]}] do
      {output, status} =
        System.cmd(
          "cc",
          ["-std=c99", "-Wall", "-Wextra", "-Werror", @fixture, "-o", path] ++ options,
          stderr_to_stdout: true
        )

      assert status == 0, output
      File.chmod!(path, 0o500)
    end

    on_exit(fn -> File.rm_rf!(directory) end)
    %{worker: worker, bad_revision: bad_revision}
  end

  setup do
    Process.flag(:trap_exit, true)
    # Each test owns this exact lease. Fault fixtures explicitly await native
    # death before removing retained unknown custody.
    custody = Path.join(System.tmp_dir!(), "frameshift-codec-custody")
    refute File.exists?(custody), "unexpected codec custody must be inspected"
    %{custody: custody}
  end

  test "real PNG normalization joins immutable SQLite/object custody and the Zig renderer" do
    codec = start_supervised!({NativeCodec, path: @codec, name: nil})
    digest = NativeCodec.build_digest(codec)
    original = png()
    assert {:ok, normalized} = NativeCodec.normalize(codec, original, digest)
    assert normalized.codec_digest == Digest.sha256(File.read!(@codec))
    assert normalized.codec_revision == NativeCodec.revision()
    assert normalized.width == 2
    assert normalized.height == 1
    assert normalized.rgba == <<255, 0, 0, 255, 0, 255, 0, 128>>
    assert normalized.color_interpretation == "assumed-srgb"
    assert normalized.source_color_digest == nil

    assert {:ok, encoded} = MasterPackage.encode(original, normalized.rgba, 2, 1)
    package = IO.iodata_to_binary(encoded)
    assert {:ok, %{original: ^original}} = MasterPackage.decode(package)

    directory =
      Path.join(System.tmp_dir!(), "codec-library-#{System.unique_integer([:positive])}")

    on_exit(fn -> File.rm_rf!(directory) end)
    library = start_supervised!({Library, name: nil, data_dir: directory})

    attributes = %{
      title: "Native source",
      source_kind: :import,
      media_type: MasterPackage.media_type(),
      width: 2,
      height: 1,
      color_profile: "sRGB",
      orientation: 1,
      provenance: %{"codecRevision" => normalized.codec_revision, "codecDigest" => digest}
    }

    assert {:ok, master} = Library.import_master(library, package, attributes)
    assert master["digest"] == Digest.sha256(package)
    assert {:ok, %{placement: :existing}} = Library.import_master(library, package, attributes)
    assert {:ok, %{"bytes" => ^package}} = Library.read_object(library, master["digest"])
    assert {:ok, saved} = Library.get_master(library, master["digest"])
    assert saved["provenance_json"] == attributes.provenance

    renderer = start_supervised!({Renderer, path: @renderer, name: nil})

    assert {:ok, %{bytes: <<255, 0, 0, 0, 128, 0>>}} =
             Renderer.render(renderer, %{
               source_width: 2,
               source_height: 1,
               crop_x: 0,
               crop_y: 0,
               crop_width: 2,
               crop_height: 1,
               target_width: 2,
               target_height: 1,
               background: {0, 0, 0},
               output_format: :rgb24,
               resize_filter: :nearest,
               dither_mode: :none,
               palette: [],
               rgba: normalized.rgba
             })

    assert {:error, :codec_unsupported} = NativeCodec.normalize(codec, <<255, 216, 255>>, digest)

    assert {:error, :codec_malformed} =
             NativeCodec.normalize(codec, binary_part(original, 0, 20), digest)

    assert {:ok, ^normalized} = NativeCodec.normalize(codec, original, digest)
  end

  test "only a staged protected executable determines work", %{worker: worker, custody: custody} do
    configured = Path.join(Path.dirname(worker), "configured")
    File.cp!(worker, configured)
    File.chmod!(configured, 0o500)
    codec = start_supervised!({NativeCodec, path: configured, name: nil})
    digest = NativeCodec.build_digest(codec)
    assert File.lstat!(Path.join(custody, "worker")).mode |> Bitwise.band(0o7777) == 0o500
    File.rm!(configured)
    File.write!(configured, "replacement must not execute")
    File.chmod!(configured, 0o700)

    assert {:error, :codec_build_mismatch} =
             NativeCodec.normalize(codec, "V", Digest.sha256("other"))

    assert {:error, :invalid_codec_deadline} =
             NativeCodec.normalize(codec, "V", digest, deadline_ms: 0)

    assert {:error, :invalid_codec_source} = NativeCodec.normalize(codec, <<>>, digest)

    assert {:ok, %{rgba: <<12, 34, 56, 255>>, codec_digest: ^digest}} =
             NativeCodec.normalize(codec, "V", digest)

    :ok = stop_supervised(NativeCodec)
    refute File.exists?(custody)
  end

  test "caller environment and stderr never reach admitted fixture work", %{worker: worker} do
    previous = System.get_env("FRAMESHIFT_CODEC_FIXTURE_SECRET")
    System.put_env("FRAMESHIFT_CODEC_FIXTURE_SECRET", "private provider fixture")

    on_exit(fn ->
      if previous,
        do: System.put_env("FRAMESHIFT_CODEC_FIXTURE_SECRET", previous),
        else: System.delete_env("FRAMESHIFT_CODEC_FIXTURE_SECRET")
    end)

    codec = start_supervised!({NativeCodec, path: worker, name: nil})
    assert {:ok, _} = NativeCodec.normalize(codec, "V", NativeCodec.build_digest(codec))
  end

  test "revision, pixels, trailing output and nonzero exits refuse finitely", %{
    worker: worker,
    bad_revision: bad_revision
  } do
    codec = start_supervised!({NativeCodec, path: bad_revision, name: nil})

    assert {:error, :codec_revision_mismatch} =
             NativeCodec.normalize(codec, "V", NativeCodec.build_digest(codec))

    :ok = stop_supervised(NativeCodec)
    codec = start_supervised!({NativeCodec, path: worker, name: nil}, id: :valid_codec)
    digest = NativeCodec.build_digest(codec)

    for {source, reason} <- [
          {"A", :invalid_codec_pixels},
          {"M", :invalid_codec_header},
          {"T", :invalid_codec_pixels},
          {"F", :codec_unsupported},
          {"G", :invalid_codec_header},
          {"E", :codec_worker_exit},
          {"Q", :codec_worker_exit}
        ] do
      assert {:error, ^reason} = NativeCodec.normalize(codec, source, digest)
      assert {:ok, _} = NativeCodec.normalize(codec, "V", digest)
    end
  end

  test "deadline retains the occupied slot until actual exit even with stalled IO control", %{
    worker: worker
  } do
    codec = start_supervised!({NativeCodec, path: worker, name: nil})
    digest = NativeCodec.build_digest(codec)
    caller = Task.async(fn -> NativeCodec.normalize(codec, "S", digest, deadline_ms: 500) end)
    {native, pid} = await_decode(codec)
    :ok = :sys.suspend(native.pid)

    try do
      assert {:error, :codec_timeout} = Task.await(caller, 2_000)
      assert {:error, :codec_busy} = NativeCodec.normalize(codec, "V", digest)
      assert NativeCodec.build_digest(codec) == digest
      assert os_alive?(pid)
    after
      :sys.resume(native.pid)
    end

    assert eventually(fn -> :sys.get_state(codec).pending == nil end)
    refute os_alive?(pid)
    assert {:ok, _} = NativeCodec.normalize(codec, "V", digest)
  end

  test "stdin backpressure is interrupted by the absolute deadline", %{worker: worker} do
    codec = start_supervised!({NativeCodec, path: worker, name: nil})
    digest = NativeCodec.build_digest(codec)
    source = "B" <> :binary.copy("x", 2 * 1024 * 1024)
    caller = Task.async(fn -> NativeCodec.normalize(codec, source, digest, deadline_ms: 500) end)
    {_, pid} = await_decode(codec)
    assert {:error, :codec_timeout} = Task.await(caller, 2_000)
    assert eventually(fn -> :sys.get_state(codec).pending == nil end)
    refute os_alive?(pid)
    assert {:ok, _} = NativeCodec.normalize(codec, "V", digest)
  end

  test "normal shutdown awaits native death before deleting executable custody", %{
    worker: worker,
    custody: custody
  } do
    codec = start_supervised!({NativeCodec, path: worker, name: nil})
    digest = NativeCodec.build_digest(codec)

    caller =
      Task.async(fn ->
        try do
          NativeCodec.normalize(codec, "S", digest)
        catch
          :exit, _ -> :owner_stopped
        end
      end)

    {_, pid} = await_decode(codec)
    :ok = stop_supervised(NativeCodec)
    assert :owner_stopped = Task.await(caller)
    refute os_alive?(pid)
    refute File.exists?(custody)
  end

  test "abrupt owner death requests native termination and preserves the replacement fence", %{
    worker: worker,
    custody: custody
  } do
    codec = start_supervised!({NativeCodec, path: worker, name: nil}, restart: :temporary)
    digest = NativeCodec.build_digest(codec)

    caller =
      Task.async(fn ->
        try do
          NativeCodec.normalize(codec, "S", digest)
        catch
          :exit, _ -> :owner_stopped
        end
      end)

    {_, pid} = await_decode(codec)
    Process.exit(codec, :kill)
    assert :owner_stopped = Task.await(caller)
    assert eventually(fn -> not os_alive?(pid) end)
    assert {:error, :codec_custody_exists} = NativeCodec.start_link(path: worker, name: nil)
    assert File.regular?(Path.join(custody, "worker"))
    File.rm_rf!(custody)
  end

  test "lost task custody refuses future work and preserves bytes", %{
    worker: worker,
    custody: custody
  } do
    codec = start_supervised!({NativeCodec, path: worker, name: nil})
    digest = NativeCodec.build_digest(codec)
    caller = Task.async(fn -> NativeCodec.normalize(codec, "S", digest) end)
    {_, pid} = await_decode(codec)
    Process.exit(:sys.get_state(codec).pending.task.pid, :kill)
    assert {:error, :codec_custody_unknown} = Task.await(caller)
    assert {:error, :codec_custody_unknown} = NativeCodec.normalize(codec, "V", digest)
    assert eventually(fn -> not os_alive?(pid) end)
    :ok = stop_supervised(NativeCodec)
    assert File.regular?(Path.join(custody, "worker"))
    File.rm_rf!(custody)
  end

  test "upstream crash reports suppress pending original bytes and raw failure context", %{
    worker: worker,
    custody: custody
  } do
    codec = start_supervised!({NativeCodec, path: worker, name: nil})
    digest = NativeCodec.build_digest(codec)
    secret = "original-image-private-fixture"
    source = "B" <> secret <> :binary.copy("x", 2 * 1024 * 1024)

    logs =
      capture_log(fn ->
        caller = Task.async(fn -> NativeCodec.normalize(codec, source, digest) end)
        {native, pid} = await_decode(codec)

        assert eventually(fn ->
                 case Process.info(:sys.get_state(codec).pending.task.pid, :current_function) do
                   {:current_function, {:gen, :do_call, _}} -> true
                   _ -> false
                 end
               end)

        GenServer.stop(native.pid, {:fixture_fault, secret})
        assert {:error, :codec_custody_unknown} = Task.await(caller)
        assert eventually(fn -> not os_alive?(pid) end)
        Logger.error("unrelated-operational-fixture")
      end)

    refute logs =~ secret
    refute logs =~ "fixture_fault"
    assert logs =~ "unrelated-operational-fixture"
    :ok = stop_supervised(NativeCodec)
    File.rm_rf!(custody)
  end

  test "unsafe paths and preexisting custody preserve every conflicting inode", %{
    worker: worker,
    custody: custody
  } do
    symlink = Path.join(Path.dirname(worker), "linked")
    File.ln_s!(worker, symlink)
    assert {:error, :unsafe_codec_executable} = NativeCodec.start_link(path: symlink, name: nil)
    refute File.exists?(custody)
    File.chmod!(worker, 0o522)
    assert {:error, :unsafe_codec_executable} = NativeCodec.start_link(path: worker, name: nil)
    File.chmod!(worker, 0o500)
    assert {:error, :unsafe_codec_executable} = NativeCodec.start_link(path: nil, name: nil)
    File.mkdir!(custody)
    marker = Path.join(custody, "unknown")
    File.write!(marker, "preserved")
    assert {:error, :codec_custody_exists} = NativeCodec.start_link(path: worker, name: nil)
    assert File.read!(marker) == "preserved"
    File.rm_rf!(custody)
  end

  test "unavailable task admission returns a finite refusal without crashing the owner", %{
    worker: worker
  } do
    codec =
      start_supervised!(
        {NativeCodec, path: worker, name: nil, task_supervisor: :absent_codec_tasks}
      )

    assert {:error, :codec_worker_unavailable} =
             NativeCodec.normalize(codec, "V", NativeCodec.build_digest(codec))

    assert Process.alive?(codec)
    assert :sys.get_state(codec).pending == nil
  end

  test "a conflicting privacy filter refuses without rewriting logging or creating custody", %{
    worker: worker,
    custody: custody
  } do
    filter = :frameshift_native_codec_privacy
    previous = List.keyfind(:logger.get_primary_config().filters, filter, 0)
    :logger.remove_primary_filter(filter)
    conflict = {fn _, _ -> :ignore end, :unrelated_configuration}
    :ok = :logger.add_primary_filter(filter, conflict)

    on_exit(fn ->
      :logger.remove_primary_filter(filter)
      if previous, do: :logger.add_primary_filter(filter, elem(previous, 1))
    end)

    assert {:error, :codec_log_privacy_unavailable} =
             NativeCodec.start_link(path: worker, name: nil)

    assert {^filter, ^conflict} = List.keyfind(:logger.get_primary_config().filters, filter, 0)
    refute File.exists?(custody)
  end

  defp await_decode(codec) do
    assert eventually(fn ->
             case :sys.get_state(codec).pending do
               %{process: %{pid: pid}, operation: :decode} ->
                 Process.alive?(pid)

               _ ->
                 false
             end
           end)

    native = :sys.get_state(codec).pending.process
    assert {:ok, pid} = Exile.Process.os_pid(native)
    {native, pid}
  end

  defp os_alive?(pid) do
    {_, status} = System.cmd("/bin/kill", ["-0", Integer.to_string(pid)], stderr_to_stdout: true)
    status == 0
  end

  defp eventually(function, attempts \\ 150)
  defp eventually(_, 0), do: false

  defp eventually(function, attempts) do
    if function.(),
      do: true,
      else:
        (
          Process.sleep(10)
          eventually(function, attempts - 1)
        )
  end

  defp png do
    <<137, "PNG\r\n", 26, 10>> <>
      chunk("IHDR", <<2::32, 1::32, 8, 6, 0, 0, 0>>) <>
      chunk("IDAT", :zlib.compress(<<0, 255, 0, 0, 255, 0, 255, 0, 128>>)) <>
      chunk("IEND", <<>>)
  end

  defp chunk(type, bytes),
    do: <<byte_size(bytes)::32, type::binary, bytes::binary, :erlang.crc32(type <> bytes)::32>>
end
