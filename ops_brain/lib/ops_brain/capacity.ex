defmodule OpsBrain.Capacity do
  @moduledoc """
  Conditional gauge forecast v1, not an outage prediction. Times are nonnegative
  epoch seconds; usage/threshold units must match. Policies use atom keys.

  Callers must identify a stable series and operating segment, changing the
  segment on resize, restart, cleanup or limit changes. Unreported changes and
  unknown auto-growth ceilings cannot be inferred from a usage gauge alone.

  Forecasts require at least five samples, nondecreasing usage, and meaningful
  growth in the latest interval and at least 75% of intervals AND elapsed time.
  Supporting interval rates must be within a factor of two of the overall rate;
  an isolated jump (even with tiny positive increments elsewhere) is not a trend.
  These conservative heuristics are not a calibrated prediction model.
  """

  @positive_policy_fields [
    :freshness_seconds,
    :max_gap_seconds,
    :min_history_seconds,
    :effective_threshold,
    :warning_horizon_seconds
  ]

  def evaluate(samples, policy, now) do
    cond do
      not valid_policy?(policy) ->
        unknown("missing/invalid policy or unverified effective limits/units")

      not nonnegative_number?(now) ->
        unknown("invalid evaluation time")

      true ->
        case known_samples(samples, now, []) do
          {:ok, known} -> evaluate_known(Enum.sort_by(known, & &1.time), policy, now)
          :error -> unknown("missing/invalid samples or timestamps")
        end
    end
  rescue
    ArithmeticError -> unknown("numeric range exceeded")
  end

  defp valid_policy?(p) when is_map(p) do
    Map.get(p, :unit) == "bytes" and Map.get(p, :limits_verified) == true and
      Enum.all?(@positive_policy_fields, fn key ->
        nonnegative_number?(Map.get(p, key)) and Map.get(p, key) > 0
      end) and nonnegative_number?(Map.get(p, :min_growth_bytes_per_second))
  end

  defp valid_policy?(_), do: false

  # BEAM does not represent IEEE NaN/infinity as ordinary floats. Reject their
  # textual/atom forms, negatives, and integers outside the finite float range.
  defp nonnegative_number?(n),
    do: is_number(n) and n >= 0 and n <= 1.7976931348623157e308

  defp identity?(id) when is_binary(id), do: String.valid?(id) and String.trim(id) != ""
  defp identity?(id) when is_atom(id), do: id not in [nil, true, false]
  defp identity?(id) when is_integer(id), do: id >= 0
  defp identity?(_), do: false

  # First apply knowledge time, then validate payloads. Future evidence must not
  # affect even the unknown reason returned for an earlier evaluation.
  defp known_samples([], _now, acc), do: {:ok, acc}

  defp known_samples([s | rest], now, acc) when is_map(s) do
    cond do
      not nonnegative_number?(Map.get(s, :time)) or
          not nonnegative_number?(Map.get(s, :received_at)) ->
        :error

      s.time > now or s.received_at > now ->
        known_samples(rest, now, acc)

      Map.get(s, :unit) != "bytes" or not nonnegative_number?(Map.get(s, :value)) or
        not identity?(Map.get(s, :series)) or not identity?(Map.get(s, :segment)) ->
        :error

      true ->
        known_samples(rest, now, [s | acc])
    end
  end

  defp known_samples(_, _now, _acc), do: :error

  defp evaluate_known(known, p, now) do
    cond do
      length(known) < 5 ->
        unknown("insufficient history")

      now - List.last(known).time > p.freshness_seconds ->
        unknown("stale samples")

      Enum.any?(known, &(&1.segment != hd(known).segment)) ->
        unknown("resize/restart/cleanup segment changed")

      Enum.any?(known, &(&1.series != hd(known).series)) ->
        unknown("series identity changed")

      true ->
        trend(known, p)
    end
  end

  defp trend(samples, p) do
    pairs = Enum.zip(samples, tl(samples))
    first = hd(samples)
    latest = List.last(samples)
    duration = latest.time - first.time

    invalid =
      Enum.any?(pairs, fn {a, b} ->
        b.time <= a.time or b.time - a.time > p.max_gap_seconds or b.value < a.value
      end)

    if invalid or duration < p.min_history_seconds do
      unknown("unstable/reset/irregular segment or insufficient history")
    else
      growth = (latest.value - first.value) / duration
      headroom = p.effective_threshold - latest.value

      cond do
        headroom <= 0 ->
          # This is an observed threshold breach, not a forecast requiring growth.
          %{
            condition: "critical",
            seconds_to_threshold: 0,
            reason: "effective threshold already reached",
            version: 1
          }

        growth <= p.min_growth_bytes_per_second or
            not sustained?(pairs, growth, duration, p.min_growth_bytes_per_second) ->
          unknown("no meaningful sustained positive growth")

        true ->
          seconds = headroom / growth

          %{
            condition: if(seconds <= p.warning_horizon_seconds, do: "warning", else: "normal"),
            seconds_to_threshold: seconds,
            growth_bytes_per_second: growth,
            current_usage: latest.value,
            effective_threshold: p.effective_threshold,
            window_start: first.time,
            window_end: latest.time,
            reason:
              "conditional estimate only while observed growth and effective limit remain stable",
            version: 1
          }
      end
    end
  end

  defp sustained?(pairs, growth, duration, minimum) do
    intervals =
      Enum.map(pairs, fn {a, b} ->
        elapsed = b.time - a.time
        rate = (b.value - a.value) / elapsed
        {elapsed, rate > minimum and rate / growth >= 0.5 and rate / growth <= 2.0}
      end)

    supporting = Enum.filter(intervals, fn {_, supported} -> supported end)
    supported_duration = Enum.reduce(supporting, 0, fn {elapsed, _}, sum -> sum + elapsed end)

    elem(List.last(intervals), 1) and
      length(supporting) * 4 >= length(intervals) * 3 and
      supported_duration / duration >= 0.75
  end

  defp unknown(reason),
    do: %{condition: "unknown", seconds_to_threshold: nil, reason: reason, version: 1}

  @doc "Replays each evaluation using only samples whose event and receipt times are <= that time."
  def backtest(samples, policy, times) do
    Enum.map(times, fn now -> %{at: now, result: evaluate(samples, policy, now)} end)
  end
end
