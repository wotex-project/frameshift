defmodule Frameshift.Transport.CredentialResolver do
  @moduledoc """
  Defines transient resolution of an opaque paired-frame credential reference.

  Implement `c:resolve/2` to return a public certificate and OTP-compatible private
  key, signer callback or supported key handle, or an explicit error. The context
  may contain local process configuration; neither it nor resolved key material
  belongs in library recipes, Thing Descriptions, UI commands or audit responses.

  ## Native identity ownership

  macOS implementations use Keychain-backed access and keep non-exportable keys
  in the owning Apple process. `Frameshift.Transport.KeychainBroker` provides the
  local certificate/signing bridge; callers resolve immediately before TLS I/O.
  The stored reference is opaque custody metadata, not a serializable credential
  or permission to contact arbitrary origins. Transport audience/pin checks apply
  separately through `Frameshift.Transport.MTLSCredential`.
  """

  @type identity :: %{certificate: binary(), private_key: term()}

  @doc "Resolves one opaque Keychain reference without persisting credential material."
  @callback resolve(String.t(), term()) :: {:ok, identity()} | {:error, atom()}
end
