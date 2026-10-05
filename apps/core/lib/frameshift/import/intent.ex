defmodule Frameshift.Import.Intent do
  @moduledoc """
  Admits the source intent shared by the Linux upload service and CLI.

  `validate/1` requires exactly the six original-import fields. Text is valid
  NFC UTF-8 with finite byte limits; the filename is metadata, never a service
  path. Original bytes are bounded at 128 MiB and identified by their exact
  lowercase SHA-256. Caller pixels, geometry, actor and codec fields refuse.

  ## Identity and authority

  `identity/1` hashes the complete admitted RFC 8785 intent, including command
  ID and kind. The server freezes its own codec context separately. Updating
  that codec cannot change an earlier command's replay identity. This module
  performs no IO and grants no authority: the Unix boundary supplies the kernel
  actor, the upload owner verifies bytes, and the Library retains the result.
  """

  alias Frameshift.Digest

  @keys ~w(kind id title originalFilename sourceByteCount sourceDigest)
  @maximum_source_bytes 128 * 1024 * 1024

  @doc "Validates one exact bounded source intent before staging or receipt lookup."
  @spec validate(term()) :: :ok | {:error, :invalid_import_intent}
  def validate(%{"kind" => "importOriginal", "sourceByteCount" => count} = intent)
      when is_integer(count) and count in 1..@maximum_source_bytes do
    valid =
      Enum.sort(Map.keys(intent)) == Enum.sort(@keys) and command_id?(intent["id"]) and
        text?(intent["title"], 256) and text?(intent["originalFilename"], 255) and
        not String.contains?(intent["originalFilename"], "/") and
        Digest.valid_sha256?(intent["sourceDigest"])

    if valid, do: :ok, else: {:error, :invalid_import_intent}
  end

  def validate(_), do: {:error, :invalid_import_intent}

  @doc "Returns the canonical digest without adding server-derived codec or actor facts."
  @spec identity(term()) :: {:ok, String.t()} | {:error, :invalid_import_intent}
  def identity(intent) do
    with :ok <- validate(intent),
         {:ok, canonical} <- RFC8785.encode(intent) do
      {:ok, Digest.sha256(canonical)}
    else
      _ -> {:error, :invalid_import_intent}
    end
  end

  @doc "Checks a retained command ID's UTF-8 and byte bounds."
  @spec command_id?(term()) :: boolean()
  def command_id?(id) when is_binary(id) and byte_size(id) in 1..64, do: String.valid?(id)
  def command_id?(_), do: false

  defp text?(text, maximum) when is_binary(text) and byte_size(text) in 1..maximum//1 do
    String.valid?(text) and String.normalize(text, :nfc) == text and String.trim(text) != "" and
      not Regex.match?(~r/[\x{0000}-\x{001F}\x{007F}-\x{009F}]/u, text)
  end

  defp text?(_, _), do: false
end
