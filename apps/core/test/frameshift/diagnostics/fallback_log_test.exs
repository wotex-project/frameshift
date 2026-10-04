defmodule Frameshift.Diagnostics.FallbackLogTest do
  @moduledoc false

  use ExUnit.Case, async: false

  import ExUnit.CaptureLog

  require Logger

  alias Frameshift.Diagnostics.FallbackLog

  @handler :frameshift_fallback_fixture

  setup do
    root =
      Path.join(
        System.tmp_dir!(),
        "frameshift-fallback-log-#{System.unique_integer([:positive, :monotonic])}"
      )

    File.mkdir_p!(root)

    on_exit(fn ->
      :logger.remove_handler(@handler)
      File.rm_rf!(root)
    end)

    %{root: root}
  end

  test "prepares a private directory and restricts an existing regular log", %{root: root} do
    path = Path.join(root, "diagnostics/core-fallback.log")
    assert :ok = FallbackLog.prepare(path)
    assert Bitwise.band(File.lstat!(Path.dirname(path)).mode, 0o077) == 0

    File.write!(path, "prior sanitized record")
    File.chmod!(path, 0o666)
    assert :ok = FallbackLog.prepare(path)
    assert Bitwise.band(File.lstat!(path).mode, 0o777) == 0o600
  end

  test "refuses a symlinked diagnostics directory without changing its target", %{root: root} do
    target = Path.join(root, "target")
    File.mkdir_p!(target)
    File.chmod!(target, 0o755)
    File.ln_s!(target, Path.join(root, "diagnostics"))

    assert {:error, :unsafe_fallback_log} =
             FallbackLog.prepare(Path.join(root, "diagnostics/core-fallback.log"))

    assert Bitwise.band(File.lstat!(target).mode, 0o777) == 0o755
  end

  test "refuses a symlinked log without changing its target", %{root: root} do
    directory = Path.join(root, "diagnostics")
    File.mkdir_p!(directory)
    target = Path.join(root, "unrelated")
    File.write!(target, "keep")
    File.ln_s!(target, Path.join(directory, "core-fallback.log"))

    assert {:error, :unsafe_fallback_log} =
             FallbackLog.prepare(Path.join(directory, "core-fallback.log"))

    assert File.read!(target) == "keep"
  end

  test "refuses a non-regular log target", %{root: root} do
    path = Path.join(root, "diagnostics/core-fallback.log")
    File.mkdir_p!(path)
    assert {:error, :unsafe_fallback_log} = FallbackLog.prepare(path)
  end

  test "refuses unsafe archives before installing a handler", %{root: root} do
    path = Path.join(root, "diagnostics/core-fallback.log")
    File.mkdir_p!(Path.dirname(path))
    target = Path.join(root, "unrelated")
    File.write!(target, "keep")
    File.chmod!(target, 0o644)
    File.ln_s!(target, path <> ".2")

    assert {:error, :unsafe_fallback_log} = FallbackLog.install(path, @handler)
    refute FallbackLog.status(@handler)["available"]
    assert File.read!(target) == "keep"
    assert Bitwise.band(File.stat!(target).mode, 0o777) == 0o644
  end

  test "installation is exact, private and idempotent; conflicts preserve the existing sink", c do
    path = Path.join(c.root, "diagnostics/core-fallback.log")
    assert :ok = FallbackLog.install(path, @handler)
    assert :ok = FallbackLog.install(path, @handler)
    assert Bitwise.band(File.stat!(path).mode, 0o777) == 0o600

    assert %{
             "available" => true,
             "state" => "configured",
             "rotationBytes" => 2_097_152,
             "archiveCount" => 3,
             "maximumFiles" => 4,
             "lossFreeSinceMs" => nil
           } = FallbackLog.status(@handler)

    other_path = Path.join(c.root, "other/core.log")
    assert {:error, :fallback_log_conflict} = FallbackLog.install(other_path, @handler)
    refute File.exists?(Path.dirname(other_path))

    assert {:ok, %{config: %{file: file, sync_mode_qlen: 256, drop_mode_qlen: 256}}} =
             :logger.get_handler_config(@handler)

    assert file == String.to_charlist(path)
    assert :ok = :logger.update_handler_config(@handler, :level, :warning)
    refute FallbackLog.status(@handler)["available"]
    assert {:error, :fallback_log_conflict} = FallbackLog.install(path, @handler)
    assert {:ok, %{level: :warning}} = :logger.get_handler_config(@handler)
    assert :ok = :logger.remove_handler(@handler)
    assert FallbackLog.status(@handler)["state"] == "unavailable"
  end

  test "real OTP rotation retains three archives and only sanitized critical records", c do
    path = Path.join(c.root, "diagnostics/core-fallback.log")
    assert :ok = FallbackLog.install(path, @handler)

    # Reduced byte threshold exercises the same OTP rotation implementation;
    # production limits are checked separately, not inferred from this fixture.
    assert :ok =
             :logger.update_handler_config(@handler, :config, %{
               max_no_bytes: 1_024,
               burst_limit_enable: false
             })

    capture_log(fn ->
      Logger.warning("warning must not enter the critical fallback")

      for batch <- 1..8 do
        for record <- 1..16 do
          Logger.error("secret-token /private/artwork.png", %{
            frameshift_event: :delivery_attempt,
            frameshift_outcome: :unknown,
            request_id: "fixture-#{batch}-#{record}",
            attempt_id: String.duplicate("a", 32),
            duration_ms: 100,
            credential: "private-credential"
          })
        end

        assert :ok = :logger_std_h.filesync(@handler)
      end
    end)

    assert :ok = :logger.remove_handler(@handler)
    files = Path.wildcard(path <> "*")
    assert Enum.sort(files) == Enum.sort([path, path <> ".0", path <> ".1", path <> ".2"])
    assert Bitwise.band(File.stat!(Path.dirname(path)).mode, 0o777) == 0o700

    for file <- files do
      bytes = File.read!(file)
      assert byte_size(bytes) <= 1_024 + 512
      refute bytes =~ "secret-token"
      refute bytes =~ "/private/"
      refute bytes =~ "private-credential"
      refute bytes =~ "warning must"

      for line <- String.split(bytes, "\n", trim: true) do
        assert "FSLOG|" <> json = line

        assert %{"level" => "error", "event" => "delivery_attempt", "outcome" => "unknown"} =
                 Jason.decode!(json)
      end
    end
  end
end
