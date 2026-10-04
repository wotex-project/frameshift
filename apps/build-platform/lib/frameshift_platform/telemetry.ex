defmodule FrameshiftPlatform.Telemetry do
  @moduledoc """
  Defines versioned platform metrics with fixed units and finite dimensions.

  `metrics/0` declares catalog outcomes, endpoint responses, transport exceptions,
  Repo timings and periodic VM/collector gauges. HTTP tags reduce paths and status
  codes to finite route/outcome sets; catalog tags reduce outcomes to fixed atoms.
  Raw URLs, source digests, actor IDs and request contents are never label values.

  ## Measurement meaning

  Duration distributions convert native time to seconds using fixed buckets and
  reject observations above one day. HTTP counters describe prepared responses,
  not proof of transmission; catalog counters describe transaction outcomes,
  not durable audit totals. Collector timestamps expose gauge freshness.

  `FrameshiftPlatform.Telemetry.Reporter` owns aggregation and scrape lifecycle.
  Changing event semantics, units or dimensions needs a catalog revision and
  updated fixtures; application code should emit the documented events.
  """

  import Telemetry.Metrics

  @http [:frameshift_platform, :endpoint, :stop]
  @repo [:frameshift_platform, :repo, :query]
  @sample [:frameshift_platform, :collector, :sample]
  @buckets [0.001, 0.005, 0.01, 0.05, 0.1, 0.5, 1, 5]

  @spec metrics() :: [Telemetry.Metrics.t()]
  def metrics do
    [
      counter("frameshift_platform.catalog.source.total",
        event_name: [:frameshift_platform, :catalog, :source, :stop],
        description: "Source action outcomes after transaction; not a durable audit count.",
        tags: [:outcome],
        tag_values: &catalog_tags/1
      ),
      counter("frameshift_platform.catalog.profile.total",
        event_name: [:frameshift_platform, :catalog, :profile, :stop],
        description: "Profile action outcomes after transaction; not a durable audit count.",
        tags: [:outcome],
        tag_values: &catalog_tags/1
      ),
      counter("frameshift_platform.http.responses.total",
        event_name: @http,
        description: "Responses prepared by the endpoint, before transmission.",
        tags: [:route, :outcome],
        tag_values: &http_tags/1
      ),
      duration("http.duration.seconds", @http, :duration,
        tags: [:route, :outcome],
        tag_values: &http_tags/1
      ),
      counter("frameshift_platform.http.transport.exceptions.total",
        event_name: [:bandit, :request, :exception],
        description: "Bandit exceptions for this endpoint, independent of prepared responses.",
        keep: &owned_request?/1,
        tags: [:route],
        tag_values: &http_tags/1
      ),
      duration("database.duration.seconds", @repo, :total_time),
      duration("database.queue.seconds", @repo, :queue_time),
      gauge("vm.memory.bytes", :memory_bytes, :byte),
      gauge("vm.processes", :processes, :unit),
      gauge("vm.run.queue", :run_queue, :unit),
      gauge("collector.started.seconds", :started_seconds, :second),
      gauge("collector.sampled.seconds", :sampled_seconds, :second)
    ]
  end

  @spec catalog_tags(map()) :: map()
  def catalog_tags(%{outcome: outcome}) when outcome in [:ok, :error], do: %{outcome: outcome}
  def catalog_tags(_), do: %{outcome: :other}

  @spec http_tags(map()) :: map()
  def http_tags(%{conn: %Plug.Conn{} = conn}) do
    %{route: route(conn.request_path), outcome: outcome(conn.status)}
  end

  def http_tags(_), do: %{route: :other, outcome: :other}

  @spec owned_request?(map()) :: boolean()
  def owned_request?(%{plug: {FrameshiftPlatformWeb.Endpoint, _}}), do: true
  def owned_request?(_), do: false

  defp route("/api/sources"), do: :sources
  defp route("/api/profiles"), do: :profiles
  defp route("/api/profiles/" <> _), do: :profiles
  defp route("/api/health"), do: :health
  defp route("/ops/metrics"), do: :metrics
  defp route("/"), do: :page
  defp route(_), do: :other

  defp outcome(status) when status in 200..399, do: :success
  defp outcome(status) when status in 400..499, do: :client_error
  defp outcome(status) when status in 500..599, do: :server_error
  defp outcome(_), do: :other

  defp duration(suffix, event, measurement, opts \\ []) do
    distribution(
      "frameshift_platform." <> suffix,
      [
        event_name: event,
        description:
          "Elapsed seconds for the documented event; maximum accepted duration one day.",
        measurement: measurement,
        unit: {:native, :second},
        reporter_options: [buckets: @buckets, maximum: 86_400, native_measurement: measurement]
      ] ++ opts
    )
  end

  defp gauge(suffix, measurement, unit) do
    last_value("frameshift_platform." <> suffix,
      event_name: @sample,
      measurement: measurement,
      unit: unit,
      description: "Latest collector sample; see collector_sampled_seconds for freshness."
    )
  end
end
