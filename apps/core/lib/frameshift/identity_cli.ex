defmodule Frameshift.IdentityCLI do
  @moduledoc """
  Imports one explicit protected Linux host identity through a clean offline VM.

  The release's `bin/frameshift-identity` invokes `main/1`. `import` requires the
  configured canonical service UID, matching nonroot kernel identity and an
  existing private credential directory. It reads one bounded closed PEM from
  stdin, then delegates proof, exclusive staging and no-replacement publication
  to `Frameshift.Transport.ProtectedFileInstaller`. Neither the host application
  nor SQLite, IPC, key issuance or physical pairing starts here.

  ## Output and recovery

  Canonical JSON contains only version, the opaque certificate-bound reference
  and `created`/`existing` status. Same verified identity replays without changing
  its file. Input/conflict errors exit 2; usage/configuration/framing errors exit
  64; unavailable custody or pre-publication I/O exits 69. Uncertain new-name
  publication exits 75 with that reference and `unknown` status, preserving key
  bytes for inspection. No raw error, PEM, private key or directory is printed.

  This is a service-account maintenance boundary, separate from actor-bound
  artwork command receipts. Repeating the same PEM cannot replace a final name.
  Help/version require no credential input or environment. Administrator key
  issuance/encrypted backup and installed service provisioning remain separate.
  """

  alias Frameshift.CLIInput
  alias Frameshift.Transport.{ProtectedFile, ProtectedFileInstaller}

  @usage """
  usage: frameshift-identity import
         frameshift-identity --help | --version
  Run as the configured nonroot service UID with FRAMESHIFT_SERVICE_UID and
  FRAMESHIFT_CREDENTIAL_DIRECTORY; pipe one bounded certificate/key PEM into closed stdin.
  Existing identity files are never replaced. Key issuance and encrypted backup are separate.
  """

  @doc "Prints one finite offline maintenance result and exits without starting the host."
  @spec main([String.t()]) :: no_return()
  def main(args) do
    {status, output, error} = run(args)
    IO.write(output)
    IO.write(:stderr, error)
    System.halt(status)
  end

  @doc "Runs the exact import/help/version command, returning status, stdout and finite stderr."
  @spec run([String.t()], IO.device()) :: {non_neg_integer(), String.t(), String.t()}
  def run(args, input \\ :stdio)
  def run(["--help"], _), do: {0, @usage, ""}

  def run(["--version"], _) do
    Application.load(:frameshift_core)
    {0, "frameshift-identity #{Application.spec(:frameshift_core, :vsn)}\n", ""}
  end

  def run(["import"], input) do
    with {:ok, config} <- configuration(),
         {:ok, bytes} <- CLIInput.read(input, 131_072) do
      result(ProtectedFileInstaller.install(bytes, config))
    else
      {:error, error} when error in [:invalid_input, :invalid_configuration] -> {64, "", @usage}
      _ -> {69, "", "frameshift-identity: credential custody unavailable\n"}
    end
  end

  def run(_, _), do: {64, "", @usage}

  defp configuration do
    with value when is_binary(value) and byte_size(value) in 1..10 <-
           System.get_env("FRAMESHIFT_SERVICE_UID"),
         {uid, ""} when uid in 1..4_294_967_294 <- Integer.parse(value),
         true <- value == Integer.to_string(uid) do
      case ProtectedFile.configure(System.get_env("FRAMESHIFT_CREDENTIAL_DIRECTORY")) do
        {:ok, %{uid: ^uid} = config} -> {:ok, config}
        _ -> {:error, :credential_custody_unavailable}
      end
    else
      _ -> {:error, :invalid_configuration}
    end
  end

  defp result({:ok, reference, status}), do: {0, json(reference, status), ""}

  defp result({:error, :credential_outcome_unknown, reference}),
    do:
      {75, json(reference, :unknown),
       "frameshift-identity: uncertain installation; inspect retained identity\n"}

  defp result({:error, error})
       when error in [:invalid_protected_credential, :credential_conflict],
       do: {2, "", "frameshift-identity: invalid identity or existing credential conflict\n"}

  defp result(_), do: {69, "", "frameshift-identity: credential installation unavailable\n"}

  defp json(reference, status),
    do:
      RFC8785.encode!(%{
        "version" => 1,
        "credentialRef" => reference,
        "status" => Atom.to_string(status)
      }) <> "\n"
end
