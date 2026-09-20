defmodule OpsBrainWeb.Telemetry do
  use Supervisor
  import Telemetry.Metrics

  def start_link(arg) do
    Supervisor.start_link(__MODULE__, arg, name: __MODULE__)
  end

  @impl true
  def init(_arg) do
    OpsBrain.OperationalMetrics.attach()

    children =
      [
        {:telemetry_poller, measurements: periodic_measurements(), period: 10_000}
      ] ++ reporter_children()

    Supervisor.init(children, strategy: :one_for_one)
  end

  def metrics do
    [
      summary("phoenix.endpoint.start.system_time", unit: {:native, :millisecond}),
      summary("phoenix.endpoint.stop.duration", unit: {:native, :millisecond}),
      summary("phoenix.router_dispatch.start.system_time",
        tags: [:route],
        unit: {:native, :millisecond}
      ),
      summary("phoenix.router_dispatch.exception.duration",
        tags: [:route],
        unit: {:native, :millisecond}
      ),
      summary("phoenix.router_dispatch.stop.duration",
        tags: [:route],
        unit: {:native, :millisecond}
      ),
      summary("phoenix.socket_connected.duration", unit: {:native, :millisecond}),
      sum("phoenix.socket_drain.count"),
      summary("phoenix.channel_joined.duration", unit: {:native, :millisecond}),
      summary("phoenix.channel_handled_in.duration",
        tags: [:event],
        unit: {:native, :millisecond}
      ),
      summary("ops_brain.repo.query.total_time",
        unit: {:native, :millisecond},
        description: "The sum of the other measurements"
      ),
      summary("ops_brain.repo.query.decode_time", unit: {:native, :millisecond}),
      summary("ops_brain.repo.query.query_time", unit: {:native, :millisecond}),
      summary("ops_brain.repo.query.queue_time", unit: {:native, :millisecond}),
      summary("ops_brain.repo.query.idle_time", unit: {:native, :millisecond}),

      # Internal application observability (bounded dimensions only).
      last_value("ops_brain.health.queued_jobs"),
      last_value("ops_brain.health.oldest_job_seconds"),
      last_value("ops_brain.health.database_bytes"),
      counter("ops_brain.job.stop.count", tags: [:queue, :state]),
      counter("ops_brain.job.exception.count", tags: [:queue]),
      sum("ops_brain.orphan.rescue.rescued"),
      sum("ops_brain.orphan.rescue.discarded"),
      counter("ops_brain.health.unavailable.count"),
      sum("ops_brain.maintenance.directory.expired_tokens"),
      sum("ops_brain.maintenance.directory.expired_attempts"),
      sum("ops_brain.maintenance.directory.terminal_jobs"),
      last_value("ops_brain.maintenance.backlog.jobs"),
      last_value("ops_brain.maintenance.backlog.oldest_seconds"),
      summary("vm.memory.total", unit: {:byte, :kilobyte}),
      summary("vm.total_run_queue_lengths.total"),
      summary("vm.total_run_queue_lengths.cpu"),
      summary("vm.total_run_queue_lengths.io")
    ]
  end

  # ConsoleReporter prints ALL event metadata. Never subscribe it to raw
  # Phoenix, Repo or Oban events (those may contain credentials and job args).
  def export_metrics do
    Enum.filter(metrics(), fn metric ->
      metric.event_name in [
        [:ops_brain, :health],
        [:ops_brain, :health, :unavailable],
        [:ops_brain, :job, :stop],
        [:ops_brain, :job, :exception],
        [:ops_brain, :orphan, :rescue],
        [:ops_brain, :maintenance, :backlog],
        [:ops_brain, :maintenance, :directory]
      ]
    end)
  end

  defp reporter_children do
    if Application.get_env(:ops_brain, :metrics_console, false),
      do: [{Telemetry.Metrics.ConsoleReporter, metrics: export_metrics()}],
      else: []
  end

  defp periodic_measurements do
    [
      {OpsBrain.Health, :measure, []},
      {OpsBrain.OperationalMetrics, :measure, []}
    ]
  end
end
