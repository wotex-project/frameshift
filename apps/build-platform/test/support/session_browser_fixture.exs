alias FrameshiftPlatform.Access.Authentication
alias FrameshiftPlatform.Repo
alias FrameshiftPlatformWeb.Endpoint

state_path = System.fetch_env!("FRAMESHIFT_SESSION_BROWSER_STATE")
endpoint_config = Application.fetch_env!(:frameshift_platform, Endpoint)

Application.put_env(
  :frameshift_platform,
  Endpoint,
  Keyword.merge(endpoint_config, server: true, http: [ip: {127, 0, 0, 1}, port: 0])
)

Mix.Task.run("ecto.create", ["--quiet"])
Mix.Task.run("ecto.migrate", ["--quiet"])
{:ok, _} = Application.ensure_all_started(:frameshift_platform)
Ecto.Adapters.SQL.Sandbox.mode(Repo, :manual)
owner = Ecto.Adapters.SQL.Sandbox.start_owner!(Repo, shared: true)

{:ok, %{profiles: 3, sources: 5}} =
  FrameshiftPlatform.Catalog.SeedImport.run(
    Path.expand("../../../../data/physical", __DIR__),
    %FrameshiftPlatform.Access.Actor{id: Ecto.UUID.generate(), role: :catalog_editor}
  )

{:ok, {_, port}} = Endpoint.server_info(:http)
origin = "http://127.0.0.1:#{port}"

updated =
  Application.fetch_env!(:frameshift_platform, Endpoint) |> Keyword.put(:check_origin, [origin])

Application.put_env(:frameshift_platform, Endpoint, updated)
Endpoint.config_change([{Endpoint, updated}], [])
email = "browser-fixture@example.com"
password = "frameshift-browser-fixture-password-20261005"

{:ok, _} =
  Authentication.register(%{email: email, password: password, password_confirmation: password})

publish = fn sequence ->
  temporary = state_path <> ".next"

  File.write!(
    temporary,
    Jason.encode!(%{origin: origin, email: email, password: password, sequence: sequence})
  )

  File.chmod!(temporary, 0o600)
  File.rename!(temporary, state_path)
end

publish.(0)

try do
  Enum.reduce_while(IO.stream(:stdio, :line), 0, fn command, sequence ->
    next = sequence + 1

    case String.trim(command) do
      "down" -> Repo.query!("ALTER TABLE platform_tokens RENAME TO unavailable_tokens", [])
      "restore" -> Repo.query!("ALTER TABLE unavailable_tokens RENAME TO platform_tokens", [])
      "stop" -> :ok
      _ -> raise "invalid fixture operation"
    end

    publish.(next)

    if String.trim(command) == "stop", do: {:halt, next}, else: {:cont, next}
  end)
after
  Ecto.Adapters.SQL.Sandbox.stop_owner(owner)
  Application.stop(:frameshift_platform)
end
