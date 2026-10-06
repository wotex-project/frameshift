defmodule FrameshiftRelease.Trust do
  @moduledoc """
  Authenticates release metadata with an independently pinned public SPKI.

  `public_key/1` admits one unencrypted Ed25519 PEM `PUBLIC KEY` block under the
  `release-public-spki-v1` profile. It returns the raw public key, canonical DER
  and SHA-256 fingerprint. `verify/4` checks that independently supplied
  fingerprint and a 64-byte detached signature over the original complete
  metadata message, at most 64 KiB. It never substitutes a hash or re-encodes JSON.

  ## Ownership and limits

  Callers obtain bytes through `FrameshiftRelease.Input`; this module owns no
  pathname reads, private signing inputs, publication or mutable output. Only
  ASCII whitespace around/within one canonical-base64 public SPKI is accepted.
  Private/certificate/other PEM types, extra blocks, changed DER identity and
  mismatched trust refuse with fixed atoms. The fingerprint covers all 44 DER
  bytes, independently of Sparkle's raw 32-byte key identity.

  This boundary qualifies metadata signatures, not whole-archive Sparkle
  signatures, production key custody, installed update or certificate trust.
  """

  @prefix Base.decode16!("302A300506032B6570032100")
  @pem ~r/\A[ \t\r\n]*-----BEGIN PUBLIC KEY-----\r?\n([A-Za-z0-9+\/= \t\r\n]+)-----END PUBLIC KEY-----[ \t\r\n]*\z/

  @doc "Admits exactly one canonical public Ed25519 SPKI and returns its identity."
  @spec public_key(binary()) :: {:ok, map()} | {:error, :invalid_public_key}
  def public_key(pem) when is_binary(pem) and byte_size(pem) in 1..16384 do
    with true <- String.valid?(pem),
         [_, body] <- Regex.run(@pem, pem),
         encoded = String.replace(body, ~r/[ \t\r\n]/, ""),
         {:ok, der} <- Base.decode64(encoded),
         true <- Base.encode64(der) == encoded,
         <<@prefix, public::binary-size(32)>> <- der do
      {:ok, %{public: public, spki: der, fingerprint: digest(der)}}
    else
      _ -> {:error, :invalid_public_key}
    end
  end

  def public_key(_), do: {:error, :invalid_public_key}

  @doc "Verifies original bounded metadata under the independent SPKI fingerprint."
  @spec verify(binary(), binary(), binary(), String.t()) :: :ok | {:error, atom()}
  def verify(message, signature, pem, fingerprint)
      when is_binary(message) and byte_size(message) in 1..65536 and
             is_binary(signature) and byte_size(signature) == 64 and is_binary(fingerprint) do
    with true <- Regex.match?(~r/\A[0-9a-f]{64}\z/, fingerprint),
         {:ok, key} <- public_key(pem),
         true <- key.fingerprint == fingerprint,
         true <- :crypto.verify(:eddsa, :none, message, signature, [key.public, :ed25519]) do
      :ok
    else
      _ -> {:error, :signature_refused}
    end
  rescue
    _ -> {:error, :signature_refused}
  end

  def verify(_, _, _, _), do: {:error, :signature_refused}

  defp digest(bytes), do: Base.encode16(:crypto.hash(:sha256, bytes), case: :lower)
end
