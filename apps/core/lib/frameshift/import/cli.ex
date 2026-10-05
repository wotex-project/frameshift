defmodule Frameshift.Import.CLI do
  @moduledoc """
  Streams a verified caller original through the authenticated Linux import IPC.

  `execute/3` receives explicit service policy and parsed file/title/command ID
  arguments from `Frameshift.CLI`. The caller descriptor supplies source length,
  digest and filename; only canonical intent and bounded base64 chunks enter the
  socket. A default title is the filename without its extension. Explicit titles
  and metadata must pass the same intent rules as the service.

  ## Recovery and output

  One explicit begin may observe an existing upload offset or exact durable
  result. Each chunk is sent once; a lost acknowledgement stops intake without
  an automatic retry or cancellation. After all bytes are acknowledged, the
  complete source is reverified before one explicit finish. A lost finish reply
  retains the command ID for `import-status`; it never invents another intent.
  Intermediate tokens, paths and bytes are not printed. The main CLI formats
  only the final validated envelope and its finite status.

  This client does not start the host, codec or metadata database. Kernel service
  identity and final socket custody are rechecked by `Frameshift.LocalIPC.Client`
  for every exchange, including chunks and status recovery in another VM.
  """

  alias Frameshift.Import.Intent
  alias Frameshift.Import.Source
  alias Frameshift.LocalIPC.Client

  @doc "Performs one explicit bounded original import without retrying uncertain exchanges."
  @spec execute(String.t(), keyword(), map()) :: {:ok, map()} | {:error, atom()}
  def execute(socket, policy, parameters) do
    Source.with_source(parameters["file"], fn source ->
      intent = %{
        "kind" => "importOriginal",
        "id" => parameters["id"],
        "title" => parameters["title"] || Path.rootname(source.filename),
        "originalFilename" => source.filename,
        "sourceByteCount" => source.count,
        "sourceDigest" => source.digest
      }

      with :ok <- Intent.validate(intent),
           {:ok, %{"ok" => true, "import" => %{"status" => "uploading"} = upload}} <-
             exchange(socket, policy, "importBegin", %{"intent" => intent}) do
        stream(socket, policy, source, upload["uploadToken"], upload["offset"])
      else
        result -> result
      end
    end)
  end

  defp stream(socket, policy, source, token, offset) do
    case Source.read_chunk(source, offset) do
      :eof ->
        with :ok <- Source.verify(source),
             do: exchange(socket, policy, "importFinish", %{"uploadToken" => token})

      {:ok, bytes} ->
        fields = %{"uploadToken" => token, "offset" => offset, "bytes" => Base.encode64(bytes)}

        with {:ok, %{"ok" => true, "import" => %{"offset" => next}}} <-
               exchange(socket, policy, "importChunk", fields) do
          stream(socket, policy, source, token, next)
        else
          result -> result
        end

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp exchange(socket, policy, operation, fields) do
    request =
      Map.merge(fields, %{
        "version" => 1,
        "requestId" => Base.encode16(:crypto.strong_rand_bytes(16), case: :lower),
        "operation" => operation,
        "auth" => "peer"
      })

    Client.exchange(socket, request, :command, policy)
  end
end
