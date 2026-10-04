defmodule Frameshift.Transport.ProtectedFileTest do
  @moduledoc false

  use ExUnit.Case, async: true

  alias Frameshift.Digest
  alias Frameshift.Transport.ProtectedFile

  setup_all do
    data =
      :public_key.pkix_test_data(%{
        root: [key: {:rsa, 2048, 65_537}],
        intermediates: [],
        peer: [key: {:rsa, 2048, 65_537}]
      })

    certificate = Keyword.fetch!(data, :cert)
    key = Keyword.fetch!(data, :key)
    reference = "linux-pem-v1:" <> Digest.hex!(Digest.sha256(certificate))

    pem =
      :public_key.pem_encode([
        {:Certificate, certificate, :not_encrypted},
        {elem(key, 0), elem(key, 1), :not_encrypted}
      ])

    %{pem: pem, reference: reference, certificate: certificate, key: key}
  end

  test "bounded PEM resolves the certificate identity and proves private/public key agreement",
       c do
    assert {:ok, identity} = ProtectedFile.decode(c.reference, c.pem)
    assert {:ok, reference} = ProtectedFile.identify(c.pem)
    assert reference == c.reference
    assert identity.certificate == c.certificate
    assert identity.private_key == c.key
    assert {:ok, ^identity} = ProtectedFile.decode(c.reference, " \n" <> c.pem <> "\t")
    {type, der} = c.key
    wrapped = :public_key.der_encode(:PrivateKeyInfo, :public_key.der_decode(type, der))

    pem =
      :public_key.pem_encode([
        {:Certificate, c.certificate, :not_encrypted},
        {:PrivateKeyInfo, wrapped, :not_encrypted}
      ])

    assert {:ok, ^identity} = ProtectedFile.decode(c.reference, pem)
  end

  test "reference derivation requires the complete valid proof, not just a certificate header",
       c do
    [cert, key] = :public_key.pem_decode(c.pem)
    wrong = :public_key.generate_key({:rsa, 2048, 65_537})

    mismatched =
      :public_key.pem_encode([
        cert,
        {:RSAPrivateKey, :public_key.der_encode(:RSAPrivateKey, wrong), :not_encrypted}
      ])

    for bytes <- [
          nil,
          "",
          <<255>>,
          "junk" <> c.pem,
          :public_key.pem_encode([cert]),
          :public_key.pem_encode([cert, key, cert]),
          mismatched,
          String.duplicate("x", 131_073)
        ] do
      assert {:error, :invalid_protected_credential} = ProtectedFile.identify(bytes)
    end
  end

  test "unsupported RSA size and EC curve refuse before returning TLS key material", c do
    decoded = :public_key.der_decode(elem(c.key, 0), elem(c.key, 1))

    for modulus <- [1, Bitwise.bsl(1, 8192)] do
      der = :public_key.der_encode(:RSAPrivateKey, put_elem(decoded, 2, modulus))

      pem =
        :public_key.pem_encode([
          {:Certificate, c.certificate, :not_encrypted},
          {:RSAPrivateKey, der, :not_encrypted}
        ])

      assert {:error, :invalid_protected_credential} = ProtectedFile.decode(c.reference, pem)
    end

    data =
      :public_key.pkix_test_data(%{
        root: [key: {:namedCurve, :secp256k1}],
        intermediates: [],
        peer: [key: {:namedCurve, :secp256k1}]
      })

    certificate = Keyword.fetch!(data, :cert)
    {type, key} = Keyword.fetch!(data, :key)

    pem =
      :public_key.pem_encode([
        {:Certificate, certificate, :not_encrypted},
        {type, key, :not_encrypted}
      ])

    reference = "linux-pem-v1:" <> Digest.hex!(Digest.sha256(certificate))
    assert {:error, :invalid_protected_credential} = ProtectedFile.decode(reference, pem)
  end

  test "missing, forged, encrypted, duplicate and non-PEM material never returns an identity",
       c do
    entries = :public_key.pem_decode(c.pem)
    [cert, key] = entries
    wrong_key = :public_key.generate_key({:rsa, 2048, 65_537})

    mismatch =
      :public_key.pem_encode([
        cert,
        {:RSAPrivateKey, :public_key.der_encode(:RSAPrivateKey, wrong_key), :not_encrypted}
      ])

    for {reference, pem} <- [
          {c.reference, "junk" <> c.pem},
          {c.reference, :public_key.pem_encode([cert, key, cert])},
          {c.reference, :public_key.pem_encode([key, cert])},
          {c.reference, mismatch},
          {c.reference,
           "-----BEGIN ENCRYPTED PRIVATE KEY-----\nAQID\n-----END ENCRYPTED PRIVATE KEY-----\n"},
          {c.reference, String.duplicate("x", 131_073)},
          {"linux-pem-v1:" <> String.duplicate("0", 64), c.pem},
          {"linux-pem-v1:../../private", c.pem},
          {String.upcase(c.reference), c.pem},
          {c.reference, <<255>>},
          {nil, c.pem}
        ] do
      assert {:error, :invalid_protected_credential} = ProtectedFile.decode(reference, pem)
    end

    assert {:error, :credential_custody_unavailable} = ProtectedFile.resolve(c.reference, %{})
    assert {:error, :credential_custody_unavailable} = ProtectedFile.configure("relative")
  end

  test "named-curve ECDSA keys in PKCS#8 join the same proof and OTP key representation" do
    for curve <- [:secp256r1, :secp384r1, :secp521r1] do
      key = {:namedCurve, curve}
      data = :public_key.pkix_test_data(%{root: [key: key], intermediates: [], peer: [key: key]})
      certificate = Keyword.fetch!(data, :cert)
      {type, der} = Keyword.fetch!(data, :key)
      decoded = :public_key.der_decode(type, der)
      wrapped = :public_key.der_encode(:PrivateKeyInfo, decoded)

      pem =
        :public_key.pem_encode([
          {:Certificate, certificate, :not_encrypted},
          {:PrivateKeyInfo, wrapped, :not_encrypted}
        ])

      reference = "linux-pem-v1:" <> Digest.hex!(Digest.sha256(certificate))
      assert {:ok, identity} = ProtectedFile.decode(reference, pem)
      assert identity.certificate == certificate
      assert elem(identity.private_key, 0) == :ECPrivateKey
    end
  end
end
