Code.prepend_paths(Path.wildcard("/src/_build/test/lib/*/ebin"))
[path, ready] = System.argv()
alias Frameshift.LocalIPC.SocketDirectory
{:ok, 65_534} = SocketDirectory.prepare_group(path, 50)
{:ok, listener} = :gen_tcp.listen(0, [:binary, packet: 4, active: false, ifaddr: {:local, path}])
:ok = SocketDirectory.restrict_group_socket(path, 50, 65_534)
File.write!(ready, "ready")

for mode <- [:refusal, :mismatch, :duplicate, :oversized, :truncated, :deadline, :hostile] do
  {:ok, socket} = :gen_tcp.accept(listener, 10_000)
  {:ok, payload} = :gen_tcp.recv(socket, 0, 1_000)
  request = RFC8785.decode!(payload)
  :ok = :inet.setopts(socket, packet: 0)
  id = RFC8785.encode!(request["requestId"])

  bytes =
    case mode do
      :refusal ->
        RFC8785.encode!(%{
          "version" => 1,
          "requestId" => request["requestId"],
          "ok" => false,
          "error" => %{"code" => "command_id_conflict"}
        })

      :mismatch ->
        ~s({"version":1,"requestId":"another","ok":true,"snapshot":{}})

      :duplicate ->
        ~s({"version":1,"requestId":#{id},"ok":false,"ok":true,"snapshot":{}})

      :hostile ->
        ~s({"version":1,"requestId":#{id},"ok":true,"snapshot":{"integer":9007199254740993}})

      _ ->
        nil
    end

  case mode do
    :oversized ->
      :gen_tcp.send(socket, <<1_048_577::unsigned-big-32>>)

    mode when mode in [:truncated, :deadline] ->
      :gen_tcp.send(socket, <<100::unsigned-big-32, "{">>)
      if mode == :deadline, do: Process.sleep(250)

    _ ->
      :gen_tcp.send(socket, <<byte_size(bytes)::unsigned-big-32, bytes::binary>>)
  end

  :gen_tcp.close(socket)
end

:gen_tcp.close(listener)
File.rm!(path)
File.rm_rf!(Path.dirname(path))
