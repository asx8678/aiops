defmodule OpsBrain.OperationalMetrics do
  @moduledoc """
  Bounded operational telemetry for this monitoring application itself.

  Metrics carry only bounded dimensions (queue, result class). Never tenant IDs,
  source/run IDs, fingerprints, URLs, errors, log text or job arguments. This is
  application observability, not monitored-service health.
  """

  alias OpsBrain.Repo

  @handler_id "ops-brain-operational-metrics"
  @events [[:oban, :job, :stop], [:oban, :job, :exception], [:oban, :plugin, :stop]]
  @queues ~w(collect enrich delivery maintenance)
  @states ~w(success failure snoozed discard cancelled)a

  @doc "Attach Oban handlers exactly once (idempotent)."
  def attach do
    :telemetry.detach(@handler_id)
    :telemetry.attach_many(@handler_id, @events, &__MODULE__.handle_event/4, nil)
    :ok
  end

  def handle_event([:oban, :job, :stop], measurements, meta, _config) do
    :telemetry.execute(
      [:ops_brain, :job, :stop],
      %{count: 1, duration: Map.get(measurements, :duration, 0)},
      %{queue: queue(meta), state: state(meta)}
    )
  end

  def handle_event([:oban, :job, :exception], measurements, meta, _config) do
    :telemetry.execute(
      [:ops_brain, :job, :exception],
      %{count: 1, duration: Map.get(measurements, :duration, 0)},
      %{queue: queue(meta)}
    )
  end

  def handle_event(
        [:oban, :plugin, :stop],
        _measurements,
        %{plugin: Oban.Lifeline} = meta,
        _config
      ) do
    rescued = length(Map.get(meta, :rescued_jobs, []))
    discarded = length(Map.get(meta, :discarded_jobs, []))

    :telemetry.execute(
      [:ops_brain, :orphan, :rescue],
      %{
        rescued: rescued,
        discarded: discarded
      },
      %{}
    )
  end

  def handle_event(_event, _measurements, _meta, _config), do: :ok

  @doc "Periodic non-tenant gauges; query errors emit an unavailable signal."
  def measure do
    case Repo.query(
           "SELECT count(*)::bigint, COALESCE(EXTRACT(EPOCH FROM (now()-MIN(COALESCE(completed_at,discarded_at,cancelled_at,attempted_at,inserted_at))))::float8,0) FROM oban_jobs WHERE state IN ('completed','discarded','cancelled') AND COALESCE(completed_at,discarded_at,cancelled_at,attempted_at,inserted_at) < now()-interval '30 days'"
         ) do
      {:ok, %{rows: [[jobs, age]]}} ->
        :telemetry.execute(
          [:ops_brain, :maintenance, :backlog],
          %{
            jobs: jobs,
            oldest_seconds: max(age, 0)
          },
          %{}
        )

      _ ->
        :telemetry.execute([:ops_brain, :health, :unavailable], %{count: 1}, %{})
    end
  end

  defp queue(meta) do
    case Map.get(meta, :queue) do
      q when q in @queues -> q
      _ -> :unknown
    end
  end

  defp state(meta) do
    case Map.get(meta, :state) do
      s when s in @states -> s
      _ -> :unknown
    end
  end
end
