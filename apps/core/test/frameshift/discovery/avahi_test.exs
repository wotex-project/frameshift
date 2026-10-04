defmodule Frameshift.Discovery.AvahiTest do
  @moduledoc false

  use ExUnit.Case, async: true

  alias Frameshift.CLI
  alias Frameshift.Discovery.Avahi

  @txt ~s("v=0" "id=paper-frame-00001" "td=/.well-known/wot" "scheme=https" "pair=1")
  @base ";eth0;IPv4;opaque-node;_frameshift._tcp;local"

  test "resolved introductions join to pairing arguments without gaining authority or leaking route metadata" do
    assert {:ok, result} = Avahi.parse_snapshot("+" <> @base <> "\n" <> row())
    assert result["authority"] == "introduction"
    assert result["omittedCount"] == 0
    assert [frame] = result["frames"]

    assert frame == %{
             "deviceId" => "paper-frame-00001",
             "origin" => "https://192.168.1.2:8443",
             "thingPath" => "/.well-known/wot",
             "pairMode" => true
           }

    reference = "linux-pem-v1:" <> String.duplicate("a", 64)

    assert {:ok, {:command, request}} =
             CLI.parse([
               "pair",
               frame["deviceId"],
               frame["origin"],
               reference,
               "--id",
               "retained"
             ])

    assert request["discoveredId"] == frame["deviceId"]
    refute Map.has_key?(request, "bootstrap")
    refute RFC8785.encode!(result) =~ "opaque-node"
    refute RFC8785.encode!(result) =~ "eth0"
    refute RFC8785.encode!(result) =~ "frame.local"
  end

  test "service add, re-resolution, invalid updates and removals cannot retain stale candidates" do
    assert {:ok, %{"frames" => []}} = Avahi.parse_snapshot("+" <> @base <> "\n")
    assert {:ok, %{"frames" => []}} = Avahi.parse_snapshot(row() <> "-" <> @base <> "\n")
    assert {:ok, %{"frames" => []}} = Avahi.parse_snapshot(row() <> "+" <> @base <> "\n")

    assert {:ok, %{"frames" => [], "omittedCount" => 1}} =
             Avahi.parse_snapshot(
               row() <> row(%{txt: String.replace(@txt, "pair=1", "owner=private")})
             )

    assert {:ok, %{"frames" => [%{"pairMode" => false}]}} =
             Avahi.parse_snapshot(row() <> row(%{txt: String.replace(@txt, "pair=1", "pair=0")}))
  end

  test "dual family and interfaces coalesce only when the entire introduction identity agrees" do
    v6 = row(%{family: "IPv6", address: "fd00::a"})
    assert {:ok, %{"frames" => [frame], "omittedCount" => 0}} = Avahi.parse_snapshot(v6 <> row())
    assert frame["origin"] == "https://192.168.1.2:8443"

    assert {:ok, %{"frames" => [frame]}} = Avahi.parse_snapshot(v6 <> v6)
    assert frame["origin"] == "https://[fd00::a]:8443"

    assert {:ok, %{"frames" => [frame]}} =
             Avahi.parse_snapshot(row(%{interface: "eth1", address: "10.1.2.3"}) <> row())

    assert frame["origin"] == "https://10.1.2.3:8443"

    for change <- [
          %{name: "another-instance"},
          %{host: "other.local"},
          %{port: "443"},
          %{txt: String.replace(@txt, "pair=1", "pair=0")}
        ] do
      # A separate service key must exist for ambiguity to be observable.
      conflicting = change |> Map.put(:interface, "eth1") |> row()

      assert {:ok, %{"frames" => [], "omittedCount" => 2}} =
               Avahi.parse_snapshot(row() <> conflicting)
    end

    distinct = row(%{name: "another-instance", txt: String.replace(@txt, "paper", "photo")})
    assert {:ok, %{"frames" => frames}} = Avahi.parse_snapshot(distinct <> row())
    assert Enum.map(frames, & &1["deviceId"]) == ["paper-frame-00001", "photo-frame-00001"]
  end

  test "DNS label and quoted TXT escapes cannot erase duplicates or smuggle metadata" do
    escaped = @txt |> String.replace("v=0", ~S(v=\048)) |> String.replace("id=", ~S(i\100=))

    assert {:ok, %{"frames" => [_]}} =
             Avahi.parse_snapshot(row(%{name: ~S(opaque\045node), txt: escaped}))

    for txt <- [
          @txt <> ~s( "id=another-frame-0001"),
          @txt <> ~s( "owner=private;room name"),
          String.replace(@txt, "pair=1", ~S(pair=\049\000)),
          String.replace(@txt, "pair=1", ~S(pair=\")),
          String.replace(@txt, "pair=1", ~S(pair=\\)),
          String.replace(@txt, "pair=1", ~S(pair=\999)),
          String.replace(@txt, "pair=1", ~S(pair=\x)),
          @txt <> " unfinished",
          String.replace(@txt, "scheme=https", "scheme=http"),
          String.replace(@txt, "/.well-known/wot", "https://evil.local/private")
        ] do
      assert {:ok, %{"frames" => [], "omittedCount" => 1}} =
               Avahi.parse_snapshot(row(%{txt: txt}))
    end
  end

  test "unusable public, multicast, loopback, scoped and mapped addresses remain omitted" do
    for {family, address} <- [
          {"IPv4", "127.0.0.1"},
          {"IPv4", "8.8.8.8"},
          {"IPv4", "224.0.0.251"},
          {"IPv4", "0.0.0.0"},
          {"IPv6", "::1"},
          {"IPv6", "fe80::1"},
          {"IPv6", "fe80::1%eth0"},
          {"IPv6", "ff02::fb"},
          {"IPv6", "2001:db8::1"},
          {"IPv6", "::ffff:192.168.1.2"},
          {"IPv6", "192.168.1.2"},
          {"IPv4", "fd00::a"}
        ] do
      assert {:ok, %{"frames" => [], "omittedCount" => 1}} =
               Avahi.parse_snapshot(row(%{family: family, address: address}))
    end

    for address <- ["10.1.2.3", "172.16.1.2", "172.31.2.3", "192.168.1.2", "169.254.2.3"] do
      assert {:ok, %{"frames" => [_]}} = Avahi.parse_snapshot(row(%{address: address}))
    end

    for change <- [
          %{host: "evil.example"},
          %{host: "frame.local.."},
          %{host: "-frame.local"},
          %{port: "0"},
          %{port: "65536"},
          %{port: "0443"},
          %{name: ~S(owner\032room)},
          %{domain: "example"}
        ] do
      assert {:ok, %{"frames" => [], "omittedCount" => 1}} = Avahi.parse_snapshot(row(change))
    end
  end

  test "broken structure or bounded event, line, output and active-service ceilings refuse the complete snapshot" do
    assert {:ok, %{"frames" => []}} = Avahi.parse_snapshot("")

    for bytes <- [
          row() <> "partial",
          "\n",
          row() <> "\n",
          <<255, 10>>,
          "garbage\n",
          String.duplicate("x", 65_536) <> "\n",
          String.duplicate("x", 4_097) <> "\n",
          String.duplicate("-" <> @base <> "\n", 513)
        ] do
      assert {:error, :invalid_discovery_snapshot} = Avahi.parse_snapshot(bytes)
    end

    active =
      Enum.map_join(
        1..64,
        &row(%{
          name: "node-#{&1}",
          txt:
            String.replace(
              @txt,
              "paper-frame-00001",
              "paper-frame-#{String.pad_leading(to_string(&1), 5, "0")}"
            )
        })
      )

    assert {:ok, %{"frames" => frames}} = Avahi.parse_snapshot(active)
    assert length(frames) == 64

    assert {:error, :invalid_discovery_snapshot} =
             Avahi.parse_snapshot(active <> row(%{name: "overflow"}))
  end

  defp row(changes \\ %{}) do
    fields =
      Map.merge(
        %{
          interface: "eth0",
          family: "IPv4",
          name: "opaque-node",
          domain: "local",
          host: "FRAME.local.",
          address: "192.168.1.2",
          port: "8443",
          txt: @txt
        },
        changes
      )

    "=;#{fields.interface};#{fields.family};#{fields.name};_frameshift._tcp;#{fields.domain};#{fields.host};#{fields.address};#{fields.port};#{fields.txt}\n"
  end
end
