defmodule Frameshift.Digest do
  @moduledoc """
  Creates and validates the SHA-256 identity spelling used by Frameshift.

  `sha256/1` hashes content bytes or iodata and returns `sha256:` followed by
  64 lowercase hexadecimal characters. `valid_sha256?/1` checks that exact
  spelling and returns `false` for other values. `hex!/1` extracts the hex suffix
  from an already admitted identifier; validate untrusted input before calling it.

  ## Identity scope

  A digest identifies exact bytes, not their source authenticity, permissions or
  physical compatibility. Canonical recipe/document owners choose what bytes
  are hashed; this module does not normalize JSON or add domain separation.

  ## Examples

      iex> Frameshift.Digest.valid_sha256?(Frameshift.Digest.sha256("artwork"))
      true
      iex> Frameshift.Digest.valid_sha256?("SHA256:abc")
      false
  """

  @sha256_pattern ~r/^sha256:[0-9a-f]{64}$/

  @doc "Hashes content bytes into the lowercase `sha256:` identifier used on disk and on wire."
  @spec sha256(iodata()) :: String.t()
  def sha256(bytes) do
    "sha256:" <> (:crypto.hash(:sha256, bytes) |> Base.encode16(case: :lower))
  end

  @doc "Checks the exact lowercase protocol spelling of a SHA-256 digest."
  @spec valid_sha256?(term()) :: boolean()
  def valid_sha256?(digest) when is_binary(digest), do: Regex.match?(@sha256_pattern, digest)
  def valid_sha256?(_), do: false

  @doc "Extracts the 64 hexadecimal characters from an already validated digest."
  @spec hex!(String.t()) :: String.t()
  def hex!("sha256:" <> hex) when byte_size(hex) == 64, do: hex
end
