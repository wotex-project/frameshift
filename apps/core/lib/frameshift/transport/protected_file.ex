defmodule Frameshift.Transport.ProtectedFile do
  @moduledoc """
  Resolves an opaque Linux host identity from operator-provisioned private PEM.

  `configure/1` admits the final service-owned `0700` directory using the actual
  nonroot kernel UID. `resolve/2` maps only `linux-pem-v1:HEX` to `HEX.pem`, where
  HEX identifies the complete DER certificate. No command or stored reference
  supplies an arbitrary filesystem path. Files must be owned regular inodes,
  `0400` or `0600`, and no larger than 128 KiB. Bounded descriptor readback and
  final inode checks refuse changed, symlinked, missing or unsafe custody.

  ## Identity and lifetime

  `decode/2` admits a certificate and unencrypted RSA or named-curve ECDSA key,
  including PKCS#8, verifies the certificate identity and a key-possession proof,
  and returns transient OTP TLS material. The existing transport still owns
  exact audience, frame pin, TLS validity and pairing checks. Resolved private
  keys never belong in SQLite, recipes, command receipts, logs or CLI output.
  Errors are finite atoms and omit paths and decode exceptions.

  `identify/1` derives only the certificate-bound reference from fully validated
  PEM, including the same possession proof. The offline installer uses this
  pure boundary; filesystem admission and no-replacement publication belong to
  `Frameshift.Transport.ProtectedFileInstaller`, not the resolver.

  PEM custody is exportable. This resolver creates no keys and does not rotate
  or restore an identity automatically. Operator key backup is separate from
  artwork backup; missing material leaves delivery pending. Final inode checks
  do not protect against root or the service owner replacing managed ancestors.
  Systemd root/ACL credential mounts require their own policy and qualification;
  this private-file adapter does not infer custody from an environment variable.
  """

  @behaviour Frameshift.Transport.CredentialResolver

  alias Frameshift.Digest
  alias Frameshift.LocalIPC.SocketDirectory

  require Record

  Record.defrecordp(
    :certificate,
    :OTPCertificate,
    Record.extract(:OTPCertificate, from_lib: "public_key/include/public_key.hrl")
  )

  Record.defrecordp(
    :tbs,
    :OTPTBSCertificate,
    Record.extract(:OTPTBSCertificate, from_lib: "public_key/include/public_key.hrl")
  )

  Record.defrecordp(
    :ec_key,
    :ECPrivateKey,
    Record.extract(:ECPrivateKey, from_lib: "public_key/include/public_key.hrl")
  )

  Record.defrecordp(
    :rsa_key,
    :RSAPrivateKey,
    Record.extract(:RSAPrivateKey, from_lib: "public_key/include/public_key.hrl")
  )

  @maximum_bytes 131_072
  @curves [{1, 2, 840, 10_045, 3, 1, 7}, {1, 3, 132, 0, 34}, {1, 3, 132, 0, 35}]

  @doc "Admits existing operator custody without creating directories or changing permissions."
  @spec configure(String.t()) :: {:ok, map()} | {:error, atom()}
  def configure(directory) do
    with :ok <- directory_path(directory),
         {:ok, uid} <- SocketDirectory.service_uid(),
         {:ok, _} <- private_directory(directory, uid) do
      {:ok, %{directory: directory, uid: uid}}
    else
      _ -> {:error, :credential_custody_unavailable}
    end
  end

  @impl true
  @doc "Resolves a certificate-bound reference only under the configured service directory."
  @spec resolve(String.t(), map()) ::
          {:ok, Frameshift.Transport.CredentialResolver.identity()} | {:error, atom()}
  def resolve(reference, %{directory: directory, uid: expected}) do
    with {:ok, hex} <- reference_hex(reference),
         {:ok, %{uid: ^expected}} <- configure(directory),
         {:ok, bytes} <- read_pem(Path.join(directory, hex <> ".pem"), expected),
         {:ok, _} <- private_directory(directory, expected) do
      decode(reference, bytes)
    else
      _ -> {:error, :credential_custody_unavailable}
    end
  rescue
    _ -> {:error, :credential_custody_unavailable}
  catch
    _, _ -> {:error, :credential_custody_unavailable}
  end

  def resolve(_, _), do: {:error, :credential_custody_unavailable}

  @doc "Derives a reference only after bounded PEM grammar and certificate/key proof pass."
  @spec identify(binary()) :: {:ok, String.t()} | {:error, :invalid_protected_credential}
  def identify(bytes) when is_binary(bytes) and byte_size(bytes) in 1..@maximum_bytes do
    with [{:Certificate, der, :not_encrypted}, _] <- :public_key.pem_decode(bytes),
         true <- byte_size(der) in 1..65_536,
         reference = "linux-pem-v1:" <> Digest.hex!(Digest.sha256(der)),
         {:ok, _} <- decode(reference, bytes) do
      {:ok, reference}
    else
      _ -> {:error, :invalid_protected_credential}
    end
  rescue
    _ -> {:error, :invalid_protected_credential}
  catch
    _, _ -> {:error, :invalid_protected_credential}
  end

  def identify(_), do: {:error, :invalid_protected_credential}

  @doc "Decodes bounded PEM and proves key agreement; it does not admit filesystem custody."
  @spec decode(String.t(), binary()) ::
          {:ok, Frameshift.Transport.CredentialResolver.identity()} | {:error, atom()}
  def decode(reference, bytes) when is_binary(bytes) and byte_size(bytes) in 1..@maximum_bytes do
    with {:ok, hex} <- reference_hex(reference),
         true <- String.valid?(bytes),
         [{:Certificate, der, :not_encrypted}, {type, _, :not_encrypted} = entry] = entries <-
           :public_key.pem_decode(bytes),
         true <- byte_size(der) in 1..65_536 and Digest.hex!(Digest.sha256(der)) == hex,
         true <- type in [:RSAPrivateKey, :ECPrivateKey, :PrivateKeyInfo],
         true <- compact(bytes) == compact(:public_key.pem_encode(entries)),
         key <- :public_key.pem_entry_decode(entry),
         :ok <- admitted_key(key),
         public <- certificate_public_key(der),
         proof = "frameshift-linux-pem-v1:" <> hex,
         signature <- :public_key.sign(proof, :sha256, key),
         true <- :public_key.verify(proof, :sha256, signature, public) do
      {:ok,
       %{certificate: der, private_key: {elem(key, 0), :public_key.der_encode(elem(key, 0), key)}}}
    else
      _ -> {:error, :invalid_protected_credential}
    end
  rescue
    _ -> {:error, :invalid_protected_credential}
  catch
    _, _ -> {:error, :invalid_protected_credential}
  end

  def decode(_, _), do: {:error, :invalid_protected_credential}

  defp certificate_public_key(der) do
    spki =
      der
      |> :public_key.pkix_decode_cert(:otp)
      |> certificate(:tbsCertificate)
      |> tbs(:subjectPublicKeyInfo)

    :public_key.pem_entry_decode(
      {:SubjectPublicKeyInfo, :public_key.pkix_encode(:OTPSubjectPublicKeyInfo, spki, :otp),
       :not_encrypted}
    )
  end

  defp admitted_key(
         rsa_key(modulus: modulus, publicExponent: exponent, otherPrimeInfos: :asn1_NOVALUE) = key
       )
       when modulus >= Bitwise.bsl(1, 2047) and modulus < Bitwise.bsl(1, 8192) and
              exponent in 3..4_294_967_295 and rem(exponent, 2) == 1 do
    if key
       |> Tuple.to_list()
       |> Enum.slice(4, 6)
       |> Enum.all?(&(is_integer(&1) and &1 > 0 and &1 < modulus)),
       do: :ok,
       else: {:error, :unsupported_key}
  end

  defp admitted_key(ec_key(parameters: {:namedCurve, curve})) when curve in @curves, do: :ok
  defp admitted_key(_), do: {:error, :unsupported_key}

  defp compact(bytes), do: String.replace(bytes, ~r/[ \t\r\n]/, "")

  defp reference_hex("linux-pem-v1:" <> hex) when byte_size(hex) == 64 do
    if Digest.valid_sha256?("sha256:" <> hex), do: {:ok, hex}, else: {:error, :invalid_reference}
  end

  defp reference_hex(_), do: {:error, :invalid_reference}

  defp directory_path(path) when is_binary(path) and byte_size(path) in 1..4_096 do
    if String.valid?(path) and not String.contains?(path, <<0>>) and Path.type(path) == :absolute,
      do: :ok,
      else: {:error, :invalid_directory}
  end

  defp directory_path(_), do: {:error, :invalid_directory}

  defp private_directory(path, uid) do
    with {:ok, %File.Stat{type: :directory, uid: ^uid, mode: mode} = stat} <- File.lstat(path),
         true <- Bitwise.band(mode, 0o7777) == 0o700 do
      {:ok, stat}
    else
      _ -> {:error, :unsafe_directory}
    end
  end

  defp read_pem(path, uid) do
    with {:ok, before} <- File.lstat(path),
         :ok <- private_file(before, uid),
         {:ok, file} <- File.open(path, [:read, :binary, :raw]) do
      try do
        with {:ok, record} <- :file.read_file_info(file),
             true <- same_file?(File.Stat.from_record(record), before),
             bytes when is_binary(bytes) <- :file.read(file, @maximum_bytes + 1) |> read_bytes(),
             true <- byte_size(bytes) == before.size,
             {:ok, after_read} <- :file.read_file_info(file),
             {:ok, final} <- File.lstat(path),
             true <-
               same_file?(File.Stat.from_record(after_read), before) and same_file?(final, before) do
          {:ok, bytes}
        else
          _ -> {:error, :changed_file}
        end
      after
        File.close(file)
      end
    end
  end

  defp read_bytes({:ok, bytes}), do: bytes
  defp read_bytes(_), do: nil

  defp same_file?(left, right), do: Map.delete(left, :atime) == Map.delete(right, :atime)

  defp private_file(%File.Stat{type: :regular, uid: uid, mode: mode, size: size}, uid)
       when size in 1..@maximum_bytes do
    if Bitwise.band(mode, 0o7777) in [0o400, 0o600], do: :ok, else: {:error, :unsafe_file}
  end

  defp private_file(_, _), do: {:error, :unsafe_file}
end
