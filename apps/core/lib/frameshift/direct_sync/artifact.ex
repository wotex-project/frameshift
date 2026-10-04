defmodule Frameshift.DirectSync.Artifact do
  @moduledoc """
  Carries verified immutable artifact bytes for a direct synchronization attempt.

  `new/4` accepts nonempty bytes, their exact SHA-256 digest, profile ID and media
  type. It verifies the content address, bounds metadata strings and derives the
  byte count. Invalid metadata or a mismatched digest returns `:invalid_artifact`
  before Form selection or credential resolution.

  ## Artifact scope

  The struct's inspection includes metadata but omits artwork bytes. Construction
  does not prove that a receiver supports the media type/profile or has enough
  storage; `Frameshift.DirectSync` checks the selected target and applicable
  transfer limits. `Frameshift.DirectDelivery` obtains registered durable artwork
  and owns pending intent, while this value remains immutable call input.
  """

  alias Frameshift.Digest

  @derive {Inspect, only: [:digest, :profile_id, :media_type, :byte_count]}
  @enforce_keys [:bytes, :digest, :profile_id, :media_type, :byte_count]
  defstruct @enforce_keys

  @type t :: %__MODULE__{
          bytes: binary(),
          digest: String.t(),
          profile_id: String.t(),
          media_type: String.t(),
          byte_count: pos_integer()
        }

  @doc "Constructs a bounded, content addressed artifact for direct frame delivery."
  @spec new(binary(), String.t(), String.t(), String.t()) ::
          {:ok, t()} | {:error, :invalid_artifact}
  def new(bytes, digest, profile_id, media_type)
      when is_binary(bytes) and byte_size(bytes) > 0 and is_binary(digest) and
             is_binary(profile_id) and is_binary(media_type) do
    if byte_size(profile_id) in 1..256 and byte_size(media_type) in 1..128 and
         Digest.valid_sha256?(digest) and Digest.sha256(bytes) == digest do
      {:ok,
       %__MODULE__{
         bytes: bytes,
         digest: digest,
         profile_id: profile_id,
         media_type: media_type,
         byte_count: byte_size(bytes)
       }}
    else
      {:error, :invalid_artifact}
    end
  end

  def new(_, _, _, _), do: {:error, :invalid_artifact}
end
