defmodule FrameshiftPlatform.DependencyBoundaryTest do
  @moduledoc false

  use ExUnit.Case, async: true

  alias FrameshiftPlatform.AtomFilterFixture, as: AtomFilter
  require Ash.Query

  test "locked Ash filters unsafe atom attributes without interning caller strings" do
    record =
      AtomFilter |> Ash.Changeset.for_create(:create, %{value: :fixture_value}) |> Ash.create!()

    assert [%{id: id}] = AtomFilter |> Ash.Query.filter(value == "fixture_value") |> Ash.read!()
    assert id == record.id

    for _ <- 1..100 do
      input = "frameshift_uninterned_filter_#{System.unique_integer([:positive])}"
      assert [] = AtomFilter |> Ash.Query.filter(value == ^input) |> Ash.read!()
      assert_raise ArgumentError, fn -> String.to_existing_atom(input) end
    end
  end

  test "locked Gun refuses CRLF before dispatching a request" do
    for header <- ["x-test", "cookie"], value <- ["a\rb", "a\nb", "a\r\nx: injected"] do
      assert_raise ErlangError, fn -> :gun.get(self(), "/", [{header, value}]) end
    end

    refute_receive {:"$gen_cast", _}
    assert :ignore == :cow_cookie.parse_set_cookie("a=b\r\nx: injected")
  end

  test "BAML native parser loads with the runtime's Rustler build dependency" do
    types = BamlElixir.Native.parse_baml(Application.app_dir(:beamlens, "priv/baml_src"))
    assert Map.has_key?(types, :functions)
    assert Map.has_key?(types, :classes)
  end

  test "the configured vault authenticates ciphertext and has no CTR fallback" do
    config = Application.fetch_env!(:refpath, Refpath.Security.Vault)

    assert [aes_gcm: {Cloak.Ciphers.AES.GCM, options}] = config[:ciphers]
    assert byte_size(options[:key]) == 32
    assert options[:iv_length] == 12
    start_supervised!(Refpath.Security.Vault)

    plaintext = "role=user "
    assert {:ok, ciphertext} = Refpath.Security.Vault.encrypt(plaintext)
    assert {:ok, ^plaintext} = Refpath.Security.Vault.decrypt(ciphertext)

    # Reproduce the advisory's chosen-plaintext forgery against the real cipher.
    body_offset = byte_size(ciphertext) - byte_size(plaintext)
    <<header::binary-size(^body_offset), body::binary>> = ciphertext
    forged = header <> :crypto.exor(body, :crypto.exor(plaintext, "role=admin"))
    assert {:ok, :error} = Refpath.Security.Vault.decrypt(forged)

    # GCM's IV and authentication tag must also resist single-bit changes.
    tag_size = byte_size(Cloak.Tags.Encoder.encode(options[:tag]))

    for offset <- tag_size..(byte_size(ciphertext) - 1) do
      <<prefix::binary-size(^offset), byte, suffix::binary>> = ciphertext
      changed = prefix <> <<Bitwise.bxor(byte, 1)>> <> suffix
      assert {:ok, :error} = Refpath.Security.Vault.decrypt(changed)
    end

    # Even a matching key tag cannot enable a legacy cipher through this vault.
    ctr_options = [key: options[:key], tag: options[:tag]]
    assert {:ok, ctr} = Cloak.Ciphers.AES.CTR.encrypt(plaintext, ctr_options)
    refute match?({:ok, ^plaintext}, Refpath.Security.Vault.decrypt(ctr))
  end
end
