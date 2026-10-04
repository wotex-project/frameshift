defmodule Frameshift.Protocol.Schema do
  @moduledoc """
  Validates control documents against the embedded Frame Protocol schemas.

  The module loads canonical Draft 2020-12 schema files at compile time and
  precompiles validators. `names/0`, `raw/1` and `compiled/1` expose the admitted
  schema set; `validate/2` checks an already decoded value and returns explicit
  unknown-schema or validation failures.

  ## Admission order

  Use `Frameshift.Protocol.JSON` for untrusted bytes so size, nesting and duplicate
  key checks happen before schema validation. References resolve only through
  `Frameshift.Protocol.SchemaResolver`; release validation performs no runtime
  network fetch and a document cannot install its own schema.

  Wotex owns W3C Thing Description and Thing Model admission.
  The local `thing-description` schema adds only the Frameshift capability and
  affordance overlay; `Frameshift.Protocol.Thing` combines those responsibilities.
  A schema-valid state document is still an observation whose authenticated origin
  and revision must be checked by the delivery or pairing owner.
  """

  @schema_names ~w(
    capabilities
    common
    desired
    outbox-ack
    outbox-manifest
    pairing-bootstrap
    pairing-request
    pairing-response
    playlist
    problem
    state
    thing-description
  )

  @schema_dir Path.expand("../../../../../protocol/schemas", __DIR__)

  for name <- @schema_names do
    @external_resource Path.join(@schema_dir, "#{name}.schema.json")
  end

  @schemas Map.new(@schema_names, fn name ->
             path = Path.join(@schema_dir, "#{name}.schema.json")
             {name, path |> File.read!() |> JSON.decode!()}
           end)

  @type schema_name :: String.t()

  @doc "Lists the embedded Frame Protocol schema names."
  @spec names() :: [schema_name()]
  def names, do: @schema_names

  @doc "Returns an embedded schema as data, without a network fetch."
  @spec raw(schema_name()) :: {:ok, map()} | :error
  def raw(name), do: Map.fetch(@schemas, name)

  @doc "Validates a decoded document against a named embedded schema."
  @spec validate(schema_name(), term()) :: :ok | {:error, term()}
  def validate(name, document) do
    with {:ok, root} <- compiled(name),
         {:ok, _} <- JSV.validate(document, root),
         :ok <- validate_semantics(name, document) do
      :ok
    end
  end

  defp validate_semantics("capabilities", %{"refresh" => refresh}),
    do: Frameshift.DisplayTiming.validate_refresh(refresh)

  defp validate_semantics(_, _), do: :ok

  @doc "Returns the precompiled schema used by protocol admission."
  @spec compiled(schema_name()) :: {:ok, JSV.Root.t()} | {:error, term()}
  def compiled(name) do
    cache_key = {__MODULE__, name}

    case :persistent_term.get(cache_key, :not_found) do
      :not_found -> compile_and_cache(cache_key, name)
      root -> {:ok, root}
    end
  end

  defp compile_and_cache(_, name) when name not in @schema_names,
    do: {:error, :unknown_schema}

  defp compile_and_cache(cache_key, name) do
    with {:ok, schema} <- raw(name),
         {:ok, root} <-
           JSV.build(schema,
             formats: true,
             resolver: {Frameshift.Protocol.SchemaResolver, @schemas}
           ) do
      :persistent_term.put(cache_key, root)
      {:ok, root}
    else
      :error -> {:error, :unknown_schema}
      {:error, reason} -> {:error, reason}
    end
  end
end
