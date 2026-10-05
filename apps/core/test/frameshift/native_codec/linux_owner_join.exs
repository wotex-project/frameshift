Code.prepend_paths(
  Path.wildcard("/src/_build/test/lib/*/ebin")
  |> Enum.reject(&(Path.basename(Path.dirname(&1)) == "exile"))
)

Code.prepend_path("/opt/exile/ebin")
{:ok, _} = Application.ensure_all_started(:exile)
ExUnit.start()
Code.require_file(Path.join(__DIR__, "protocol_test.exs"))

defmodule Frameshift.NativeCodec.LinuxOwnerJoin do
  @moduledoc false

  use ExUnit.Case, async: false

  import ExUnit.CaptureLog

  require Logger

  alias Frameshift.Digest
  alias Frameshift.MasterPackage
  alias Frameshift.NativeCodec

  setup_all do
    start_supervised!({Task.Supervisor, name: Frameshift.TaskSupervisor, max_children: 64})
    :ok
  end

  setup do
    Process.flag(:trap_exit, true)
    assert :os.type() == {:unix, :linux}
    assert System.version() == "1.20.4"
    assert String.trim(File.read!("/usr/local/lib/erlang/releases/29/OTP_VERSION")) == "29.1.1"
    assert to_string(Application.spec(:exile, :vsn)) == "0.15.0"
    assert File.lstat!(System.tmp_dir!()).uid == 65_534
    custody = Path.join(System.tmp_dir!(), "frameshift-codec-custody")
    refute File.exists?(custody)
    %{custody: custody}
  end

  test "fresh Linux NIF/helper normalizes exact PNG bytes into a repeatable canonical package" do
    codec = start_supervised!({NativeCodec, path: "/usr/local/bin/frameshift-codec", name: nil})
    digest = NativeCodec.build_digest(codec)
    original = png()
    assert digest == Digest.sha256(File.read!("/usr/local/bin/frameshift-codec"))
    assert {:ok, result} = NativeCodec.normalize(codec, original, digest)
    assert result.rgba == <<255, 0, 0, 255, 0, 255, 0, 128>>
    assert result.width == 2 and result.height == 1
    assert result.codec_revision == NativeCodec.revision()

    assert {:ok, package} =
             MasterPackage.encode(original, result.rgba, result.width, result.height)

    encoded = IO.iodata_to_binary(package)
    assert {:ok, %{original: ^original, rgba: rgba}} = MasterPackage.decode(encoded)
    assert rgba == result.rgba
    assert {:ok, ^result} = NativeCodec.normalize(codec, original, digest)
    assert {:error, :codec_unsupported} = NativeCodec.normalize(codec, <<255, 216, 255>>, digest)

    assert {:error, :codec_malformed} =
             NativeCodec.normalize(codec, binary_part(original, 0, 20), digest)
  end

  test "blocked native reads and writes terminate before accepting fresh work" do
    codec = start_supervised!({NativeCodec, path: "/usr/local/bin/codec-fixture", name: nil})
    digest = NativeCodec.build_digest(codec)

    for source <- ["S", "B" <> :binary.copy("x", 2 * 1024 * 1024)] do
      caller =
        Task.async(fn -> NativeCodec.normalize(codec, source, digest, deadline_ms: 500) end)

      {_, pid} = await_decode(codec)
      assert {:error, :codec_timeout} = Task.await(caller, 2_000)
      assert eventually(fn -> :sys.get_state(codec).pending == nil end)
      refute os_alive?(pid)
      assert {:ok, _} = NativeCodec.normalize(codec, "V", digest)
    end
  end

  test "shutdown acknowledges native termination and releases only known custody", %{
    custody: custody
  } do
    codec = start_supervised!({NativeCodec, path: "/usr/local/bin/codec-fixture", name: nil})
    caller = Task.async(fn -> normalize_until_stop(codec) end)
    {_, pid} = await_decode(codec)
    :ok = stop_supervised(NativeCodec)
    assert :owner_stopped = Task.await(caller)
    refute os_alive?(pid)
    refute File.exists?(custody)
  end

  test "abrupt owner death fences replacement and preserves its staged bytes", %{custody: custody} do
    codec =
      start_supervised!({NativeCodec, path: "/usr/local/bin/codec-fixture", name: nil},
        restart: :temporary
      )

    caller = Task.async(fn -> normalize_until_stop(codec) end)
    {_, pid} = await_decode(codec)
    Process.exit(codec, :kill)
    assert :owner_stopped = Task.await(caller)
    assert eventually(fn -> not os_alive?(pid) end)

    assert {:error, :codec_custody_exists} =
             NativeCodec.start_link(path: "/usr/local/bin/codec-fixture", name: nil)

    assert File.regular?(Path.join(custody, "worker"))
    File.rm_rf!(custody)
  end

  test "Linux upstream faults do not log queued originals or raw failure text", %{
    custody: custody
  } do
    codec = start_supervised!({NativeCodec, path: "/usr/local/bin/codec-fixture", name: nil})
    digest = NativeCodec.build_digest(codec)
    secret = "linux-original-private-fixture"
    source = "B" <> secret <> :binary.copy("x", 2 * 1024 * 1024)

    logs =
      capture_log(fn ->
        caller = Task.async(fn -> NativeCodec.normalize(codec, source, digest) end)
        {native, pid} = await_decode(codec)
        GenServer.stop(native.pid, {:fixture_fault, secret})
        assert {:error, :codec_custody_unknown} = Task.await(caller)
        assert eventually(fn -> not os_alive?(pid) end)
        Logger.error("linux-unrelated-operational-fixture")
      end)

    refute logs =~ secret
    refute logs =~ "fixture_fault"
    assert logs =~ "linux-unrelated-operational-fixture"
    :ok = stop_supervised(NativeCodec)
    File.rm_rf!(custody)
  end

  defp normalize_until_stop(codec) do
    NativeCodec.normalize(codec, "S", NativeCodec.build_digest(codec))
  catch
    :exit, _ -> :owner_stopped
  end

  defp await_decode(codec) do
    assert eventually(fn ->
             case :sys.get_state(codec).pending do
               %{process: %{pid: pid}, operation: :decode} -> Process.alive?(pid)
               _ -> false
             end
           end)

    native = :sys.get_state(codec).pending.process
    assert {:ok, pid} = Exile.Process.os_pid(native)
    {native, pid}
  end

  defp os_alive?(pid) do
    File.dir?("/proc/#{pid}")
  end

  defp eventually(function, attempts \\ 200)
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
