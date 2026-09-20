defmodule OpsBrain.OperationalMetricsTest do
  use ExUnit.Case, async: false
  alias OpsBrain.OperationalMetrics

  setup do
    OperationalMetrics.attach()
    OperationalMetrics.attach()
    handler = "metrics-test-#{System.unique_integer([:positive])}"

    :telemetry.attach_many(
      handler,
      [
        [:ops_brain, :job, :stop],
        [:ops_brain, :job, :exception],
        [:ops_brain, :orphan, :rescue],
        [:ops_brain, :maintenance, :backlog]
      ],
      &__MODULE__.capture/4,
      self()
    )

    on_exit(fn -> :telemetry.detach(handler) end)
    :ok
  end

  def capture(event, measurements, meta, pid), do: send(pid, {event, measurements, meta})

  test "real Oban metadata maps to bounded dimensions without secrets" do
    meta = %{
      queue: "collect",
      state: :success,
      args: %{token: "SECRET_CANARY"},
      job: %Oban.Job{args: %{"secret" => "SECRET_CANARY"}}
    }

    :telemetry.execute([:oban, :job, :stop], %{duration: 5}, meta)
    assert_receive {[:ops_brain, :job, :stop], %{count: 1, duration: 5}, tags}
    assert tags == %{queue: "collect", state: :success}
    refute_receive {[:ops_brain, :job, :stop], _, _}

    :telemetry.execute(
      [:oban, :job, :exception],
      %{duration: 2},
      Map.put(meta, :error, "SECRET_CANARY")
    )

    assert_receive {[:ops_brain, :job, :exception], %{count: 1}, %{queue: "collect"}}
    :telemetry.execute([:oban, :job, :stop], %{}, %{queue: "unbounded", state: :weird})
    assert_receive {[:ops_brain, :job, :stop], _, %{queue: :unknown, state: :unknown}}
  end

  test "only Lifeline emits rescue counts, not raw jobs" do
    :telemetry.execute([:oban, :plugin, :stop], %{}, %{
      plugin: Oban.Lifeline,
      rescued_jobs: [%{id: 1}, %{id: 2}],
      discarded_jobs: [%{id: 3}]
    })

    assert_receive {[:ops_brain, :orphan, :rescue], %{rescued: 2, discarded: 1}, %{}}
    :telemetry.execute([:oban, :plugin, :stop], %{}, %{plugin: Oban.Plugins.Pruner})
    refute_receive {[:ops_brain, :orphan, :rescue], _, _}
  end

  test "reporter exports sanitized events, never raw metadata" do
    {:ok, device} = StringIO.open("")
    # StringIO is linked to this test process and exits with it.

    start_supervised!(
      {Telemetry.Metrics.ConsoleReporter,
       metrics: OpsBrainWeb.Telemetry.export_metrics(), device: device}
    )

    :telemetry.execute([:oban, :job, :stop], %{duration: 5}, %{
      queue: "delivery",
      state: :success,
      args: %{token: "SECRET_CANARY"}
    })

    :telemetry.execute([:ops_brain, :repo, :query], %{total_time: 1}, %{params: ["SECRET_CANARY"]})

    :telemetry.execute([:phoenix, :endpoint, :stop], %{duration: 1}, %{conn: "SECRET_CANARY"})
    {_, output} = StringIO.contents(device)
    assert output =~ "ops_brain.job.stop"
    assert output =~ "delivery"
    refute output =~ "SECRET_CANARY"
  end

  test "reporter opt-in is wired into supervision" do
    previous = Application.get_env(:ops_brain, :metrics_console, false)
    on_exit(fn -> Application.put_env(:ops_brain, :metrics_console, previous) end)
    Application.put_env(:ops_brain, :metrics_console, true)
    assert {:ok, {_, children}} = OpsBrainWeb.Telemetry.init([])
    assert Enum.any?(children, &(&1.id == Telemetry.Metrics.ConsoleReporter))
    Application.put_env(:ops_brain, :metrics_console, false)
    assert {:ok, {_, children}} = OpsBrainWeb.Telemetry.init([])
    refute Enum.any?(children, &(&1.id == Telemetry.Metrics.ConsoleReporter))
  end

  test "backlog gauge reaches registered handlers" do
    OperationalMetrics.measure()
    assert_receive {[:ops_brain, :maintenance, :backlog], %{jobs: jobs, oldest_seconds: age}, %{}}
    assert jobs >= 0 and age >= 0
  end
end
