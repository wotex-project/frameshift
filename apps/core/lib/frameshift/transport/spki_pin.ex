defmodule Frameshift.Transport.SPKIPin do
  @moduledoc """
  Derives and verifies frame identity from X.509 public-key information.

  `fingerprint/1` hashes the SubjectPublicKeyInfo of a decoded certificate;
  `fingerprint_der/1` admits bounded DER bytes and returns the protocol SHA-256
  spelling. The identity follows the public key, not a certificate's presentation
  fields or filename. Malformed certificate input returns an error.

  ## TLS use

  The verification callback compares the established peer's key with the expected
  pin while TLS proves possession. Explicitly handled self-signed/unknown-CA path
  conditions do not bypass that pin; unrelated certificate failures remain errors.
  The outbox also uses the same calculation to resolve a verified caller to one
  paired frame.

  Hashing a certificate alone is not authentication. Callers must supply the peer
  certificate from the TLS connection, never JSON/header fields, and separately
  check the exact interaction audience and durable paired custody.
  """

  require Record

  Record.defrecordp(
    :otp_certificate,
    Record.extract(:OTPCertificate, from_lib: "public_key/include/public_key.hrl")
  )

  Record.defrecordp(
    :otp_tbs_certificate,
    Record.extract(:OTPTBSCertificate, from_lib: "public_key/include/public_key.hrl")
  )

  @accepted_path_failures [:unknown_ca, :selfsigned_peer, :hostname_check_failed]

  @doc "Hashes the public-key information in an already decoded X.509 certificate."
  @spec fingerprint(tuple()) :: {:ok, binary()} | {:error, :invalid_certificate}
  def fingerprint(certificate) when is_tuple(certificate) do
    public_key_info =
      certificate
      |> otp_certificate(:tbsCertificate)
      |> otp_tbs_certificate(:subjectPublicKeyInfo)

    encoded = :public_key.pkix_encode(:OTPSubjectPublicKeyInfo, public_key_info, :otp)
    {:ok, :crypto.hash(:sha256, encoded)}
  rescue
    _ -> {:error, :invalid_certificate}
  catch
    _, _ -> {:error, :invalid_certificate}
  end

  def fingerprint(_), do: {:error, :invalid_certificate}

  @doc "Derives a protocol-formatted SPKI pin from a DER peer certificate."
  @spec fingerprint_der(binary()) :: {:ok, String.t()} | {:error, :invalid_certificate}
  def fingerprint_der(der) when is_binary(der) and byte_size(der) in 1..65_536 do
    with certificate <- :public_key.pkix_decode_cert(der, :otp),
         {:ok, digest} <- fingerprint(certificate) do
      {:ok, "sha256:" <> Base.encode16(digest, case: :lower)}
    end
  rescue
    _ -> {:error, :invalid_certificate}
  catch
    _, _ -> {:error, :invalid_certificate}
  end

  def fingerprint_der(_), do: {:error, :invalid_certificate}

  @doc false
  @spec verify(tuple(), term(), map()) ::
          {:valid, map()} | {:unknown, map()} | {:fail, term()}
  def verify(_, {:bad_cert, reason}, state) when reason in @accepted_path_failures,
    do: {:valid, state}

  def verify(_, {:bad_cert, reason}, _), do: {:fail, {:bad_cert, reason}}
  def verify(_, {:extension, _}, state), do: {:unknown, state}
  def verify(_, :valid, state), do: {:valid, state}

  def verify(certificate, :valid_peer, %{expected: expected} = state) do
    case fingerprint(certificate) do
      {:ok, ^expected} -> {:valid, Map.put(state, :matched, true)}
      {:ok, _} -> {:fail, :server_spki_mismatch}
      {:error, _} -> {:fail, :invalid_peer_certificate}
    end
  end

  def verify(_, _, state), do: {:unknown, state}
end
