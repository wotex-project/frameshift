defmodule FrameshiftRelease.CLI do
  @moduledoc """
  Dispatches explicit local release-verification commands with fixed refusals.

  `main/1` accepts `verify` with manifest, detached signature, public SPKI,
  artifact directory and independently protected trust file, or
  `verify-signature` with the same inputs except the artifact directory. It
  delegates to `FrameshiftRelease.Verifier`; no input is inferred from a checkout,
  downloaded release, private key, credential store or application process.

  ## Results and custody

  Success prints a bounded version/count observation and exits zero. Signature
  observations say only declared artifacts; full local observations require every
  streamed archive. Neither command performs public URL readback, signing,
  publication, output replacement or installed acceptance. Usage exits 64 and
  refusal exits 1 with fixed text containing no input path, bytes or crypto term.

  Build this tool and its Zig worker in the same checkout for the execution OS.
  The default worker location is embedded by `FrameshiftRelease.Input`;
  `--worker ABSOLUTE_TOOL` explicitly selects a separately qualified native
  build, including portable escript execution on another tested OS. This tool
  is not an installed application.
  Workers retain their exact ports through closing checks and actual exit;
  external termination cannot turn uncertain custody into accepted results.
  """

  alias FrameshiftRelease.Verifier

  @doc "Runs one bounded explicit command; all failure output is fixed and non-secret."
  @spec main([String.t()]) :: no_return() | :ok
  def main(arguments) do
    case arguments do
      ["--worker", worker | command] -> dispatch(command, worker: worker)
      command -> dispatch(command, [])
    end
  rescue
    _ -> refused()
  catch
    _ -> refused()
  end

  defp dispatch(arguments, options) do
    case arguments do
      ["verify", manifest, signature, public, directory, trust] ->
        result(
          Verifier.verify_release(manifest, signature, public, directory, trust, options),
          :local
        )

      ["verify-signature", manifest, signature, public, trust] ->
        result(Verifier.verify_signature(manifest, signature, public, trust, options), :signature)

      _ ->
        IO.puts(
          :stderr,
          "usage: frameshift-release verify MANIFEST SIGNATURE PUBLIC_KEY ARTIFACT_DIR TRUST_FILE\n       frameshift-release verify-signature MANIFEST SIGNATURE PUBLIC_KEY TRUST_FILE"
        )

        System.halt(64)
    end
  end

  defp result({:ok, manifest}, :local),
    do:
      IO.puts("verified #{manifest["version"]}: #{length(manifest["artifacts"])} exact artifacts")

  defp result({:ok, manifest}, :signature),
    do:
      IO.puts(
        "verified signature #{manifest["version"]}: #{length(manifest["artifacts"])} declared artifacts"
      )

  defp result(_, _), do: refused()

  defp refused do
    IO.puts(:stderr, "release verification refused: invalid input, trust or custody")
    System.halt(1)
  end
end
