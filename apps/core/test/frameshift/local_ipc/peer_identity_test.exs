defmodule Frameshift.LocalIPC.PeerIdentityTest do
  @moduledoc false

  use ExUnit.Case, async: true

  alias Frameshift.LocalIPC.PeerIdentity

  test "native credential decoder admits exact account and process bounds including root peers" do
    for {pid, uid, gid} <- [
          {1, 0, 0},
          {2_147_483_647, 4_294_967_294, 4_294_967_294},
          {1_234, 1, 50}
        ] do
      bytes = <<pid::native-signed-32, uid::native-unsigned-32, gid::native-unsigned-32>>

      assert {:ok, %{pid: ^pid, uid: ^uid, gid: ^gid}} =
               PeerIdentity.decode_linux_credentials(bytes)
    end
  end

  test "missing, truncated, oversized, negative PID and sentinel account credentials refuse" do
    for bytes <- [
          nil,
          "",
          <<0::native-signed-32, 1::native-unsigned-32, 1::native-unsigned-32>>,
          <<-1::native-signed-32, 1::native-unsigned-32, 1::native-unsigned-32>>,
          <<1::native-signed-32, 4_294_967_295::native-unsigned-32, 1::native-unsigned-32>>,
          <<1::native-signed-32, 1::native-unsigned-32, 4_294_967_295::native-unsigned-32>>,
          :binary.copy(<<1>>, 11),
          :binary.copy(<<1>>, 13)
        ] do
      assert {:error, :invalid_peer_credential} = PeerIdentity.decode_linux_credentials(bytes)
    end
  end
end
