defmodule FrameshiftRelease.Verifier do
  @moduledoc """
  Joins retained input custody, pinned signatures and exact local artifact facts.

  `verify_signature/5` reads manifest, signature, public SPKI and independently
  protected fingerprint under `FrameshiftRelease.Input`, then authenticates the
  original message through `FrameshiftRelease.Trust`. It returns the semantic
  `FrameshiftRelease.Manifest` only after every owned worker's closing check and
  actual exit. This signature-only call establishes no local/public archive claim.

  `verify_release/6` additionally streams every named archive and compares exact
  length and SHA-256 while holding the admitted metadata descriptors. The final
  artifact-directory identity must match its original device/inode/mode/owner.

  ## Bounds and refusal

  Metadata retains its existing 64 KiB/64-byte/16 KiB limits and trust grammar.
  One monotonic job covers every nested worker; the default is 60 seconds for
  signatures and 15 minutes for local archives, at most 8 GiB each. `:budget_ms`
  can tighten that job; `:worker` selects an explicitly qualified tool build.
  Fixed errors reveal no private input. Failure never writes files, repairs
  custody, signs, downloads, publishes or promotes late work.

  Public URL readback, portable receipt/replay consumers and installed/product
  acceptance retain separate requirements. A verified local manifest grants no
  publication authority or proof that an installer works.
  """

  alias FrameshiftRelease.{Input, Manifest, Trust}

  @doc "Authenticates exact retained metadata without reading installer archives."
  @spec verify_signature(String.t(), String.t(), String.t(), String.t(), keyword()) ::
          {:ok, map()} | {:error, atom()}
  def verify_signature(manifest, signature, public, trust, options \\ []) do
    authenticate(manifest, signature, public, trust, options, 60_000, fn value, _ ->
      {:ok, value}
    end)
  end

  @doc "Authenticates metadata and streams every exact local installer archive."
  @spec verify_release(String.t(), String.t(), String.t(), String.t(), String.t(), keyword()) ::
          {:ok, map()} | {:error, atom()}
  def verify_release(manifest, signature, public, directory, trust, options \\ []) do
    authenticate(manifest, signature, public, trust, options, 900_000, fn admitted, job ->
      before = directory_identity!(directory)

      Enum.each(admitted["artifacts"], fn artifact ->
        with {:ok, facts} <-
               Input.hash(Path.join(directory, artifact["file"]), input_options(job)),
             true <- facts.bytes == artifact["bytes"] and facts.sha256 == artifact["sha256"] do
          :ok
        else
          _ -> throw(:artifact_refused)
        end
      end)

      if directory_identity!(directory) != before, do: throw(:input_refused)
      {:ok, admitted}
    end)
  end

  defp authenticate(manifest, signature, public, trust, options, default, consumer) do
    milliseconds = Keyword.get(options, :budget_ms, default)

    if not (is_integer(milliseconds) and milliseconds in 1..900_000 and
              Enum.all?(Keyword.keys(options), &(&1 in [:budget_ms, :worker]))),
       do: throw(:invalid_bounds)

    job = {System.monotonic_time(:millisecond) + milliseconds, options}

    file(trust, [minimum: 64, maximum: 65, protected_trust: true], job, fn fingerprint ->
      fingerprint = fingerprint!(fingerprint)

      file(manifest, [minimum: 2, maximum: 65536], job, fn bytes ->
        with {:ok, admitted} <- Manifest.parse(bytes) do
          file(signature, [minimum: 64, maximum: 64], job, fn signed ->
            file(public, [maximum: 16384], job, fn pem ->
              with :ok <- Trust.verify(bytes, signed, pem, fingerprint),
                   do: consumer.(admitted, job)
            end)
          end)
        end
      end)
    end)
  rescue
    _ -> {:error, :input_refused}
  catch
    error when is_atom(error) -> {:error, error}
    _ -> {:error, :input_refused}
  end

  defp file(path, bounds, job, consumer) do
    case Input.with_input(path, Keyword.merge(input_options(job), bounds), consumer) do
      {:ok, result} -> result
      error -> error
    end
  end

  defp input_options({deadline, options}) do
    remaining = deadline - System.monotonic_time(:millisecond)
    if remaining <= 0, do: throw(:deadline)
    Keyword.put(options, :budget_ms, remaining)
  end

  defp fingerprint!(bytes) do
    if Regex.match?(~r/\A[0-9a-f]{64}\n?\z/, bytes),
      do: binary_part(bytes, 0, 64),
      else: throw(:invalid_trust)
  end

  defp directory_identity!(path) do
    case File.lstat(path, time: :posix) do
      {:ok, %{type: :directory} = stat} ->
        Map.take(stat, [:major_device, :minor_device, :inode, :mode, :uid, :gid])

      _ ->
        throw(:artifact_refused)
    end
  end
end
