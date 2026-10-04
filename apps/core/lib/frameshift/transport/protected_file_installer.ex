defmodule Frameshift.Transport.ProtectedFileInstaller do
  @moduledoc """
  Installs an explicit Linux PEM identity without replacing existing custody.

  `install/2` re-admits an existing service-owned `0700` directory under the
  actual nonroot kernel UID. The resolver validates bounded PEM and proves key
  agreement before any write. The certificate DER digest supplies the opaque
  installation identity; existing valid custody replays without modifying it,
  while malformed, symlinked or unsafe final names remain untouched.

  ## Publication and uncertainty

  A random exclusive private stage receives mode `0400` before PEM bytes, then
  file sync and close. A hard link publishes only an absent certificate-bound
  name, including concurrent imports. New publication requires staging cleanup,
  a real parent-directory sync and final resolver readback. Existing verified
  custody is read-only replay. Failure after publication
  returns the reference with `:credential_outcome_unknown`, preserving installed
  bytes for explicit inspection. Pre-publication failures cannot install an
  active identity. Interrupted private stages are never credential references.

  This helper generates no keys, changes no existing permissions and performs no
  pairing, rotation, encrypted backup or application startup. It trusts managed
  ancestors/root/service owner as the resolver does; checks are not descriptor-
  relative protection against them. Syscall acceptance is separate from exact
  filesystem power-loss, systemd/TPM and installed-release qualification.
  """

  alias Frameshift.Transport.ProtectedFile

  @type result ::
          {:ok, String.t(), :created | :existing}
          | {:error, atom()}
          | {:error, :credential_outcome_unknown, String.t()}

  @doc "Installs fully validated transient PEM under rechecked custody, with no overwrite option."
  @spec install(binary(), map()) :: result()
  def install(bytes, %{directory: directory, uid: uid} = config) do
    with {:ok, %{uid: ^uid}} <- ProtectedFile.configure(directory),
         {:ok, "linux-pem-v1:" <> hex = reference} <- ProtectedFile.identify(bytes) do
      target = Path.join(directory, hex <> ".pem")

      case File.lstat(target) do
        {:error, :enoent} -> stage(bytes, target, reference, config)
        {:ok, _} -> existing(reference, config)
        _ -> {:error, :credential_installation_unavailable}
      end
    else
      {:error, :invalid_protected_credential} -> {:error, :invalid_protected_credential}
      _ -> {:error, :credential_custody_unavailable}
    end
  rescue
    _ -> {:error, :credential_installation_unavailable}
  catch
    _, _ -> {:error, :credential_installation_unavailable}
  end

  def install(_, _), do: {:error, :credential_custody_unavailable}

  defp existing(reference, config) do
    case ProtectedFile.resolve(reference, config) do
      {:ok, _} -> {:ok, reference, :existing}
      _ -> {:error, :credential_conflict}
    end
  end

  defp stage(bytes, target, reference, config) do
    name = ".identity-" <> Base.encode16(:crypto.strong_rand_bytes(16), case: :lower) <> ".pem"
    temporary = Path.join(config.directory, name)

    case File.open(temporary, [:write, :binary, :raw, :exclusive]) do
      {:ok, file} ->
        try do
          with :ok <- write(file, temporary, bytes),
               {:ok, %{uid: uid}} when uid == config.uid <-
                 ProtectedFile.configure(config.directory) do
            case File.ln(temporary, target) do
              :ok -> published(temporary, reference, config)
              {:error, :eexist} -> existing(reference, config)
              _ -> {:error, :credential_installation_unavailable}
            end
          else
            _ -> {:error, :credential_installation_unavailable}
          end
        after
          File.rm(temporary)
        end

      _ ->
        {:error, :credential_installation_unavailable}
    end
  end

  defp write(file, path, bytes) do
    result =
      try do
        with :ok <- File.chmod(path, 0o400),
             :ok <- :file.write(file, bytes),
             :ok <- :file.sync(file) do
          :ok
        else
          _ -> {:error, :credential_installation_unavailable}
        end
      rescue
        _ -> {:error, :credential_installation_unavailable}
      catch
        _, _ -> {:error, :credential_installation_unavailable}
      end

    case {result, File.close(file)} do
      {:ok, :ok} -> :ok
      _ -> {:error, :credential_installation_unavailable}
    end
  end

  defp published(temporary, reference, config) do
    with :ok <- File.rm(temporary),
         :ok <- sync_directory(config.directory),
         {:ok, _} <- ProtectedFile.resolve(reference, config) do
      {:ok, reference, :created}
    else
      _ -> {:error, :credential_outcome_unknown, reference}
    end
  rescue
    _ -> {:error, :credential_outcome_unknown, reference}
  catch
    _, _ -> {:error, :credential_outcome_unknown, reference}
  end

  defp sync_directory(path) do
    with {:ok, directory} <- :file.open(String.to_charlist(path), [:read, :raw, :directory]) do
      try do
        :file.sync(directory)
      after
        :file.close(directory)
      end
    end
  end
end
