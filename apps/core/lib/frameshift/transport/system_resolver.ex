defmodule Frameshift.Transport.SystemResolver do
  @moduledoc """
  Returns resolved IPv4 and IPv6 addresses for an advertised frame host.

  `resolve/2` accepts a binary hostname and gathers address-family results without
  opening a frame connection. Invalid destinations or failed resolution return
  an explicit error rather than an invented loopback or fallback address.

  ## Consumer policy

  The resolver supplies candidates, not network authorization.
  `Frameshift.Transport.HTTPClient` admits every returned address against its
  configured local-network policy before connecting; one acceptable answer does
  not excuse another forbidden address. Resolution does not authenticate the
  host or establish the TLS pin, which belongs to the transport credential.
  """

  @spec resolve(String.t(), term()) :: {:ok, [:inet.ip_address()]} | {:error, atom()}
  def resolve(host, _) when is_binary(host) do
    case :inet.parse_address(String.to_charlist(host)) do
      {:ok, address} -> {:ok, [address]}
      {:error, :einval} -> resolve_name(host)
    end
  end

  def resolve(_, _), do: {:error, :invalid_destination}

  defp resolve_name(host) do
    name = String.to_charlist(host)

    addresses =
      [:inet6, :inet]
      |> Enum.flat_map(fn family ->
        case :inet.getaddrs(name, family) do
          {:ok, resolved} -> resolved
          {:error, _} -> []
        end
      end)
      |> Enum.uniq()

    if addresses == [], do: {:error, :unresolved_destination}, else: {:ok, addresses}
  end
end
