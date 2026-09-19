# Pure tests: do not load test_helper.exs or start OpsBrain/Repo.
# mise exec elixir@1.20.4-otp-27 erlang@27.3.4.16 -- elixir \
#   -r lib/ops_brain/capacity.ex -e 'ExUnit.start(); Code.require_file("test/ops_brain/capacity_acceptance_test.exs")'
Code.require_file("../../scripts/capacity_backtest.exs", __DIR__)

defmodule OpsBrain.CapacityAcceptanceTest do
  use ExUnit.Case, async: true
  alias OpsBrain.{Capacity, CapacitySyntheticBacktest}

  defp policy, do: %{CapacitySyntheticBacktest.policy() | warning_horizon_seconds: 1000}

  defp history do
    for i <- 0..5 do
      %{
        time: i * 60,
        received_at: i * 60,
        value: 100 + i * 60,
        unit: "bytes",
        series: "storage-a",
        segment: "stable"
      }
    end
  end

  defp values(values) do
    Enum.zip_with(history(), values, fn sample, value -> %{sample | value: value} end)
  end

  defp assert_unknown(samples, p \\ policy(), now \\ 300) do
    assert %{condition: "unknown", seconds_to_threshold: nil, version: 1, reason: reason} =
             Capacity.evaluate(samples, p, now)

    assert is_binary(reason) and reason != ""
  end

  test "public APIs retain the existing conditional estimate and replay shape" do
    assert function_exported?(Capacity, :evaluate, 3)
    assert function_exported?(Capacity, :backtest, 3)

    assert %{
             condition: "warning",
             seconds_to_threshold: 600.0,
             growth_bytes_per_second: 1.0,
             version: 1
           } =
             result = Capacity.evaluate(history(), policy(), 300)

    assert result.current_usage == 400
    assert result.effective_threshold == 1000
    assert {result.window_start, result.window_end} == {0, 300}
    assert result.reason =~ "conditional"

    assert [%{at: 60, result: %{condition: "unknown"}}, %{at: 300, result: ^result}] =
             Capacity.backtest(history(), policy(), [60, 300])

    assert Capacity.backtest(history(), policy(), []) == []
  end

  test "every required policy field must be present and valid" do
    for key <- Map.keys(policy()) do
      assert_unknown(history(), Map.delete(policy(), key))

      for value <- [nil, false, "NaN", :nan, "Infinity", "100", -1, [], %{}] do
        assert_unknown(history(), Map.put(policy(), key, value))
      end
    end

    for p <- [nil, false, [], Map.to_list(policy()), 1, "policy", %URI{}, %{}] do
      assert_unknown(history(), p)
    end

    for key <- [
          :freshness_seconds,
          :max_gap_seconds,
          :min_history_seconds,
          :effective_threshold,
          :warning_horizon_seconds
        ] do
      assert_unknown(history(), Map.put(policy(), key, 0))
    end

    assert_unknown(history(), %{policy() | unit: "GB"})
    assert_unknown(history(), %{policy() | limits_verified: "true"})

    assert %{condition: "warning"} =
             Capacity.evaluate(history(), %{policy() | min_growth_bytes_per_second: 0}, 300)
  end

  test "missing and malformed sample containers never raise" do
    for samples <- [
          nil,
          false,
          1,
          "samples",
          %{},
          %URI{},
          [],
          [nil],
          [1],
          [hd(history()) | :invalid_tail]
        ] do
      assert_unknown(samples)
    end
  end

  test "each required sample field is required even with adequate other samples" do
    for key <- [:time, :received_at, :value, :unit, :series, :segment] do
      assert_unknown(List.update_at(history(), 2, &Map.delete(&1, key)))
    end

    assert_unknown(List.replace_at(history(), 2, %URI{}))
  end

  test "nonnumeric, NaN, infinity, negative and unrepresentable measurements are unknown" do
    for key <- [:value, :time, :received_at],
        value <- [
          nil,
          true,
          false,
          "NaN",
          :nan,
          "Infinity",
          :infinity,
          "2.5",
          -1,
          -0.1,
          [],
          %{},
          Integer.pow(10, 400)
        ] do
      assert_unknown(List.update_at(history(), 2, &Map.put(&1, key, value)))
    end

    assert_unknown(List.update_at(history(), 2, &%{&1 | unit: "GB"}))
    assert_unknown(history(), %{policy() | effective_threshold: Integer.pow(10, 400)})
  end

  test "invalid evaluation clocks produce unknown including during replay" do
    for now <- [nil, false, "NaN", -1, %{}, Integer.pow(10, 400)] do
      assert_unknown(history(), policy(), now)
      assert [%{result: %{condition: "unknown"}}] = Capacity.backtest(history(), policy(), [now])
    end

    assert [%{result: %{condition: "unknown"}}] = Capacity.backtest(nil, nil, [300])
  end

  test "overflowing otherwise numeric arithmetic is unknown rather than an exception" do
    samples =
      for i <- 0..4 do
        %{hd(history()) | time: i * 1.0e-308, received_at: 0, value: i * 1.0e307}
      end

    p = %{policy() | min_history_seconds: 1.0e-309, effective_threshold: 1.0e308}
    assert_unknown(samples, p, 1)
  end

  test "identities must be explicit, nonempty and stable" do
    for key <- [:series, :segment], value <- [nil, "", "  ", <<255>>, false, true, [], %{}] do
      assert_unknown(Enum.map(history(), &Map.put(&1, key, value)))
    end

    for key <- [:series, :segment] do
      assert_unknown(List.update_at(history(), 5, &Map.put(&1, key, "changed")))
      assert_unknown(Enum.map(history(), &Map.delete(&1, key)))
    end
  end

  test "flat, declining, cleanup and negligible growth are not deadlines" do
    for v <- [
          [100, 100, 100, 100, 100, 100],
          [600, 500, 400, 300, 200, 100],
          [100, 160, 220, 100, 160, 220],
          [100, 101, 102, 103, 104, 105],
          [100, 106, 112, 118, 124, 130]
        ] do
      assert_unknown(values(v))
    end
  end

  test "a jump at any position, even with tiny positive increments, is not sustained growth" do
    for jump_at <- 1..5, increment <- [0, 1] do
      v = for i <- 0..5, do: 100 + i * increment + if(i >= jump_at, do: 600, else: 0)
      assert_unknown(values(v))
    end
  end

  test "growth must persist in the most recent interval" do
    assert_unknown(values([100, 160, 220, 280, 340, 340]))
    assert_unknown(values([100, 160, 220, 280, 280, 280]))
  end

  test "small rate variation and one internal pause are allowed" do
    for v <- [[100, 148, 220, 274, 340, 400], [100, 160, 160, 220, 280, 340]] do
      assert %{condition: "warning"} = Capacity.evaluate(values(v), policy(), 300)
    end
  end

  test "support must cover elapsed time as well as sample count" do
    times = [0, 100, 160, 220, 280, 340]

    samples =
      Enum.zip_with(values([100, 100, 160, 220, 280, 340]), times, fn sample, time ->
        %{sample | time: time, received_at: time}
      end)

    assert_unknown(samples, %{policy() | max_gap_seconds: 100}, 340)
  end

  test "too few, too short and stale histories remain unknown at precise boundaries" do
    assert_unknown(Enum.take(history(), 4))
    assert_unknown(history(), %{policy() | min_history_seconds: 301})
    assert_unknown(history(), policy(), 421)
    assert %{condition: "warning"} = Capacity.evaluate(history(), policy(), 420)
    assert %{condition: "warning"} = Capacity.evaluate(Enum.take(history(), 5), policy(), 240)
  end

  test "duplicate timestamps and excessive gaps are unknown; sorting is deterministic" do
    assert_unknown(history() ++ [List.last(history())])
    assert_unknown(history(), %{policy() | max_gap_seconds: 59})

    assert Capacity.evaluate(Enum.reverse(history()), policy(), 300) ==
             Capacity.evaluate(history(), policy(), 300)
  end

  test "bounded uneven cadence uses elapsed seconds, not sample index" do
    samples =
      for t <- [0, 30, 90, 150, 210, 270],
          do: %{hd(history()) | time: t, received_at: t, value: 100 + t}

    assert %{condition: "warning", growth_bytes_per_second: 1.0, seconds_to_threshold: 630.0} =
             Capacity.evaluate(samples, policy(), 270)
  end

  test "warning horizon is inclusive; crossing is an observation, not a negative deadline" do
    assert %{condition: "warning"} =
             Capacity.evaluate(history(), %{policy() | warning_horizon_seconds: 600}, 300)

    assert %{condition: "normal"} =
             Capacity.evaluate(history(), %{policy() | warning_horizon_seconds: 599}, 300)

    for threshold <- [400, 399] do
      assert %{condition: "critical", seconds_to_threshold: 0} =
               Capacity.evaluate(history(), %{policy() | effective_threshold: threshold}, 300)
    end

    # Flat above threshold is an observed breach, not a manufactured forecast.
    assert %{condition: "critical", seconds_to_threshold: 0} =
             Capacity.evaluate(values([1000, 1000, 1000, 1000, 1000, 1000]), policy(), 300)
  end

  test "event and receipt clocks independently prevent future leakage, including invalid payloads" do
    baseline = Capacity.evaluate(history(), policy(), 300)

    for {event, receipt} <- [{301, 300}, {300, 301}, {301, 301}, {0, 500}] do
      future = %{
        hd(history())
        | time: event,
          received_at: receipt,
          value: "NaN",
          series: nil,
          segment: "resized"
      }

      assert Capacity.evaluate(history() ++ [future], policy(), 300) == baseline
    end

    late_reset = %{hd(history()) | time: 270, received_at: 301, segment: "resized"}
    assert Capacity.evaluate(history() ++ [late_reset], policy(), 300) == baseline
    assert_unknown(history() ++ [late_reset], policy(), 301)
  end

  test "every synthetic replay matches an independently truncated known prefix" do
    for scenario <- CapacitySyntheticBacktest.scenarios(),
        row <- Capacity.backtest(scenario.samples, scenario.policy, scenario.times) do
      prefix = Enum.filter(scenario.samples, &(&1.time <= row.at and &1.received_at <= row.at))
      assert row.result == Capacity.evaluate(prefix, scenario.policy, row.at)
    end
  end

  test "synthetic truth supplies actual crossings, including one beyond the warning horizon" do
    scenarios = CapacitySyntheticBacktest.scenarios()
    report = CapacitySyntheticBacktest.score(scenarios)

    for row <- report.rows do
      expected =
        case row.scenario do
          "steady crossing" -> 900
          "crossing with unavailable evidence" -> 900
          "crossing beyond horizon" -> 4500
          _ -> nil
        end

      assert row.crossing_at == expected
    end

    assert report.basis =~ "not real calibration"
    assert report.evaluations == 18
    assert report.scored == 18
    assert report.positive_opportunities == 4
    assert report.negative_opportunities == 14
    assert report.useful_warnings == 2
    assert report.false_warnings == 1
    assert report.missed_crossings == 2
    assert report.unknown == 10
    assert_in_delta report.warning_precision, 2 / 3, 1.0e-9
    assert report.crossing_recall == 0.5
    assert_in_delta report.false_warning_rate, 1 / 14, 1.0e-9
    assert report.mean_useful_lead_seconds == 450.0
  end

  test "changing withheld truth changes scoring but cannot change detector output" do
    scenario = hd(CapacitySyntheticBacktest.scenarios())
    stopped_truth = Enum.map(scenario.truth, &%{&1 | value: min(&1.value, 400)})
    before = CapacitySyntheticBacktest.score([scenario])
    after_stop = CapacitySyntheticBacktest.score([%{scenario | truth: stopped_truth}])
    assert Enum.map(before.rows, & &1.result) == Enum.map(after_stop.rows, & &1.result)
    assert before.useful_warnings == 2
    assert after_stop.useful_warnings == 0
    assert after_stop.false_warnings == 2
  end

  test "scorer excludes incomplete horizons and post-crossing evaluations; empty rates are nil" do
    scenario = hd(CapacitySyntheticBacktest.scenarios())
    report = CapacitySyntheticBacktest.score([%{scenario | times: [900, 4800]}])
    assert report.excluded == 2
    assert report.scored == 0
    assert report.warning_precision == nil
    assert report.crossing_recall == nil
    assert report.false_warning_rate == nil
    assert report.mean_useful_lead_seconds == nil
    assert CapacitySyntheticBacktest.score([]).evaluations == 0
  end
end
