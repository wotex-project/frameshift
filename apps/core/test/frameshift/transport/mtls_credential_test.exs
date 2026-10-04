defmodule Frameshift.Transport.MTLSCredentialTest do
  @moduledoc false

  use ExUnit.Case, async: true

  alias Frameshift.Transport.MTLSCredential

  @pin "sha256:" <> String.duplicate("a", 64)

  test "IPv6 origins preserve URI authority syntax and the exact transport port" do
    for {origin, normalized, host, port} <- [
          {"https://[::1]:443/", "https://[::1]", "::1", 443},
          {"https://[FD00::A]:8443", "https://[fd00::a]:8443", "fd00::a", 8443},
          {"https://FRAME.local:443/", "https://frame.local", "frame.local", 443},
          {"https://192.168.1.2:8443", "https://192.168.1.2:8443", "192.168.1.2", 8443}
        ] do
      assert {:ok, credential} = MTLSCredential.new(origin, @pin, <<1>>, {:rsa, :fixture})
      assert credential.origin == normalized
      assert credential.host == host
      assert credential.port == port
      assert {:ok, uri} = URI.new(credential.origin <> "/.well-known/wot")
      assert uri.host == host
      assert uri.port == port
    end
  end

  test "accepts an OTP-compatible non-exportable signer without exposing it in inspection" do
    owner = self()

    signer = fn message, digest, options ->
      send(owner, {:sign_called, message, digest, options})
      <<1, 2, 3>>
    end

    key = %{algorithm: :rsa, sign_fun: signer}

    assert {:ok, credential} =
             MTLSCredential.new("https://frame.local", @pin, <<4, 5, 6>>, key)

    assert credential.client_private_key.algorithm == :rsa
    assert is_function(credential.client_private_key.sign_fun, 3)

    assert :public_key.sign("handshake", :sha256, key) == <<1, 2, 3>>
    assert_receive {:sign_called, "handshake", :sha256, []}

    assert credential.server_spki_sha256 ==
             Base.decode16!(String.duplicate("a", 64), case: :lower)

    refute inspect(credential) =~ inspect(key)
    refute inspect(credential) =~ inspect(<<4, 5, 6>>)

    assert {:error, :invalid_client_private_key} =
             MTLSCredential.new("https://frame.local", @pin, <<4, 5, 6>>, %{
               algorithm: :rsa,
               sign_fun: fn _ -> <<1>> end
             })
  end
end
