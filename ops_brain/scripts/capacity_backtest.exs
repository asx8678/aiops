defmodule OpsBrain.CapacitySyntheticBacktest do
  @moduledoc """
  Offline synthetic sanity check, NOT real calibration. Truth is a fully observed
  synthetic trajectory, separate from receipt-delayed detector evidence. The
  label is its first actual sampled threshold crossing, never the forecast ETA.

  Score pre-crossing evaluations with a complete future horizon only. A useful
  warning precedes a crossing within the policy horizon; a false warning has no
  crossing in that horizon. Unknown results count as missed positive opportunities
  and are also reported separately, so abstention cannot inflate usefulness.
  Rates are per evaluation, not per incident; overlapping windows are correlated.

  Run without Mix, application startup, test_helper, DB, network or notifications:
    mise exec elixir@1.20.4-otp-27 erlang@27.3.4.16 -- elixir \
      -r lib/ops_brain/capacity.ex scripts/capacity_backtest.exs --run
  """

  alias OpsBrain.Capacity

  def policy do
    %{
      unit: "bytes",
      limits_verified: true,
      freshness_seconds: 120,
      max_gap_seconds: 60,
      min_history_seconds: 240,
      effective_threshold: 1000,
      min_growth_bytes_per_second: 0.1,
      warning_horizon_seconds: 600
    }
  end

  def scenarios do
    for {name, value, delay} <- [
          {"steady crossing", fn t -> 100 + t end, 0},
          {"crossing beyond horizon", fn t -> 100 + t / 5 end, 0},
          {"flat", fn _ -> 100 end, 0},
          {"isolated jump", fn t -> if t < 240, do: 100, else: 900 end, 0},
          {"growth stops after warning", fn t -> 100 + min(t, 300) end, 0},
          {"crossing with unavailable evidence", fn t -> 100 + t end, 1000}
        ] do
      truth = for t <- 0..4800//60, do: %{time: t, value: value.(t)}

      samples =
        Enum.map(truth, fn point ->
          Map.merge(point, %{
            received_at: point.time + delay,
            unit: "bytes",
            series: "synthetic-storage",
            segment: "stable"
          })
        end)

      %{name: name, samples: samples, truth: truth, policy: policy(), times: [240, 300, 600]}
    end
  end

  def score(scenarios) do
    rows = Enum.flat_map(scenarios, &score_scenario/1)
    scored = Enum.filter(rows, & &1.scorable)
    positives = Enum.count(scored, & &1.expected_crossing)
    negatives = length(scored) - positives
    warnings = Enum.count(scored, &(&1.result.condition == "warning"))
    useful = Enum.filter(scored, &(&1.result.condition == "warning" and &1.expected_crossing))
    false_warnings = warnings - length(useful)

    %{
      basis: "synthetic only; per-evaluation, not real calibration",
      evaluations: length(rows),
      scored: length(scored),
      excluded: length(rows) - length(scored),
      positive_opportunities: positives,
      negative_opportunities: negatives,
      warnings: warnings,
      useful_warnings: length(useful),
      false_warnings: false_warnings,
      missed_crossings: positives - length(useful),
      unknown: Enum.count(scored, &(&1.result.condition == "unknown")),
      warning_precision: ratio(length(useful), warnings),
      crossing_recall: ratio(length(useful), positives),
      false_warning_rate: ratio(false_warnings, negatives),
      mean_useful_lead_seconds:
        ratio(
          Enum.reduce(useful, 0, fn row, sum -> sum + row.crossing_at - row.at end),
          length(useful)
        ),
      rows: rows
    }
  end

  defp score_scenario(scenario) do
    truth = Enum.sort_by(scenario.truth, & &1.time)
    crossing = Enum.find(truth, &(&1.value >= scenario.policy.effective_threshold))
    crossing_at = if crossing, do: crossing.time

    # Replay receives no truth labels; labels are attached only after evaluation.
    scenario.samples
    |> Capacity.backtest(scenario.policy, scenario.times)
    |> Enum.map(fn row ->
      horizon_end = row.at + scenario.policy.warning_horizon_seconds

      scorable =
        truth != [] and hd(truth).time <= row.at and List.last(truth).time >= horizon_end and
          (is_nil(crossing_at) or crossing_at > row.at)

      Map.merge(row, %{
        scenario: scenario.name,
        crossing_at: crossing_at,
        scorable: scorable,
        expected_crossing: scorable and not is_nil(crossing_at) and crossing_at <= horizon_end
      })
    end)
  end

  defp ratio(_, 0), do: nil
  defp ratio(n, d), do: n / d
end

if System.argv() == ["--run"] do
  OpsBrain.CapacitySyntheticBacktest.scenarios()
  |> OpsBrain.CapacitySyntheticBacktest.score()
  |> Map.delete(:rows)
  |> IO.inspect(label: "Offline synthetic backtest (not real calibration)", pretty: true)
end
