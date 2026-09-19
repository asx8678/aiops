defmodule OpsBrain.Metrics do
  @moduledoc "Bounded Prometheus instant queries; reviewed names/units/semantics are configuration, not inferred."
  alias OpsBrain.Transport

  def collect(%{profile: %{semantics: "ratio"} = p} = c, now) do
    with true <- p[:reviewed] == true and p[:unit] == "ratio",
         true <- is_number(p[:minimum_traffic]) and p.minimum_traffic > 0,
         {:ok, n} <- ratio_query(c, p.numerator_query, now),
         {:ok, d} <- ratio_query(c, p.denominator_query, now) do
      case if(aligned?(n, d),
             do: ratio(n, d, p.minimum_traffic),
             else: {:error, :unaligned_timestamps}
           ) do
        {:ok, value} ->
          samples = [
            %{
              "series" => OpsBrain.Store.digest(Enum.sort(Enum.map(d, & &1["series"]))),
              "value" => value,
              # The aggregate is only as fresh as its oldest operand, not this collection.
              "timestamp" => Enum.min(Enum.map(n ++ d, & &1["timestamp"]))
            }
          ]

          {:ok,
           %{
             "samples" => samples,
             "unit" => "ratio",
             "profile_version" => p.version,
             "numerators" => n,
             "denominators" => d,
             "coverage" => "complete",
             "condition" => condition(samples, p),
             "count_basis" => "sum of matching numerators / sum of matching denominators"
           }}

        {:error, reason} ->
          {:ok,
           %{
             "samples" => [],
             "unit" => "ratio",
             "coverage" => "partial",
             "condition" => "unknown",
             "missing" => to_string(reason),
             "numerators" => n,
             "denominators" => d
           }}
      end
    else
      _ -> {:error, :invalid_profile_or_metric_response}
    end
  end

  def collect(c, now) do
    p = c.profile

    with true <- p[:reviewed] == true and p[:unit] in ["bytes", "ratio", "seconds", "count"],
         true <- p[:semantics] == "gauge",
         true <- is_binary(p[:query]),
         {:ok, %{status: 200, body: body}} <-
           Transport.get(c, "/api/v1/query", [
             {"query", p.query},
             {"time", DateTime.to_unix(now)},
             {"timeout", "5s"}
           ]),
         {:ok, data} <- decode(body, now, p[:freshness_seconds] || 120) do
      {:ok,
       %{
         "samples" => data,
         "unit" => p.unit,
         "profile_version" => p.version,
         "capacity_segment" => p[:capacity_segment],
         "coverage" => if(data == [], do: "partial", else: "complete"),
         "condition" => condition(data, p),
         "missing" => if(data == [], do: "no series", else: nil)
       }}
    else
      _ -> {:error, :invalid_profile_or_metric_response}
    end
  end

  def decode(body, now, freshness), do: decode(body, now, freshness, false)

  def decode(body, now, freshness, match_ratio_labels) do
    with true <- is_integer(freshness) and freshness in 1..3600,
         {:ok,
          %{"status" => "success", "data" => %{"resultType" => "vector", "result" => rows}} =
            response} <- Jason.decode(body),
         true <- is_list(rows) and length(rows) <= 100,
         true <- Map.get(response, "warnings", []) == [] do
      values =
        Enum.map(rows, fn r ->
          with true <- is_map(r),
               [ts, text] when is_number(ts) and is_binary(text) <- r["value"],
               {n, ""} <- Float.parse(text),
               true <- n == n and abs(n) < 1.0e300,
               true <- ts <= DateTime.to_unix(now) + 5 and DateTime.to_unix(now) - ts <= freshness,
               labels when is_map(labels) <- r["metric"] do
            labels = if match_ratio_labels, do: Map.delete(labels, "__name__"), else: labels
            {:ok, %{"series" => OpsBrain.Store.digest(labels), "timestamp" => ts, "value" => n}}
          else
            _ -> {:error, :stale_or_invalid_sample}
          end
        end)

      if Enum.all?(values, &match?({:ok, _}, &1)),
        do: {:ok, Enum.map(values, &elem(&1, 1))},
        else: {:error, :stale_or_invalid_sample}
    else
      _ -> {:error, :partial_or_invalid_response}
    end
  end

  defp ratio_query(c, query, now) do
    with {:ok, %{status: 200, body: body}} <-
           Transport.get(c, "/api/v1/query", [
             {"query", query},
             {"time", DateTime.to_unix(now)},
             {"timeout", "5s"}
           ]),
         {:ok, rows} <- decode(body, now, c.profile[:freshness_seconds] || 120, true) do
      {:ok, rows}
    end
  end

  def condition([], _), do: "unknown"

  def condition(samples, %{threshold: threshold}) when is_number(threshold) do
    if Enum.any?(samples, &(&1["value"] >= threshold)), do: "warning", else: "normal"
  end

  def condition(_, _), do: "unknown"

  @doc "Paired backend samples must share actual sampling times (five-second tolerance)."
  def aligned?(n, d) do
    by_series = Map.new(d, &{&1["series"], &1["timestamp"]})

    Enum.all?(n, fn s ->
      a = s["timestamp"]
      b = by_series[s["series"]]
      is_number(a) and is_number(b) and abs(a - b) <= 5
    end)
  end

  def ratio(numerators, denominators, min_traffic) do
    # Inputs must be aligned counts/rates over the SAME interval and label set.
    ns = Map.new(numerators, &{&1["series"], &1["value"]})
    ds = Map.new(denominators, &{&1["series"], &1["value"]})
    total = Enum.sum(Map.values(ds))

    if map_size(ns) == length(numerators) and map_size(ds) == length(denominators) and
         Enum.sort(Map.keys(ns)) == Enum.sort(Map.keys(ds)) and total >= min_traffic and total > 0 and
         Enum.all?(ns, fn {k, n} -> n >= 0 and n <= ds[k] end) do
      {:ok, Enum.sum(Map.values(ns)) / total}
    else
      {:error, :insufficient_or_mismatched_traffic}
    end
  end
end
