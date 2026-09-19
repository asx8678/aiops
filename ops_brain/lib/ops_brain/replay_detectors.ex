defmodule OpsBrain.Replay.Detectors do
  @moduledoc "Pure version-1 replay adapters over retained, sanitized inputs; never collectors."
  alias OpsBrain.{Capacity, Correlation, Fingerprints, Metrics, Store}

  @policy_keys ~w(unit limits_verified freshness_seconds max_gap_seconds min_history_seconds effective_threshold warning_horizon_seconds min_growth_bytes_per_second)a
  @sample_keys ~w(time received_at value unit series segment)a
  @fact_keys ~w(company_id environment_id target_id evidence_id occurred_at received_at)a

  def evaluate(row, occurred_before, received_before, now) do
    data = row["data"]

    cond do
      not is_map(data) ->
        unavailable(:missing_inputs)

      data["expired"] == true or row["retention_expired"] == true ->
        unavailable(:expired)

      row["expires_at"] && DateTime.compare(row["expires_at"], now) != :gt ->
        unavailable(:expired)

      data["evidence_truncated"] == true ->
        unavailable(:missing_inputs)

      row["kind"] not in [
        "prometheus",
        "loki",
        "kubernetes",
        "capacity_evaluation",
        "pipeline_task",
        "correlation"
      ] ->
        unavailable(:unsupported_kind)

      row["detector_version"] == nil ->
        unavailable(:missing_inputs)

      row["detector_version"] != 1 ->
        unavailable(:unsupported_version)

      true ->
        dispatch(row, occurred_before, received_before)
    end
  rescue
    # Retained legacy/malformed payloads must not turn into successful empty results.
    _ in [
      ArgumentError,
      KeyError,
      BadMapError,
      FunctionClauseError,
      ArithmeticError,
      Protocol.UndefinedError
    ] ->
      unavailable(:missing_inputs)
  end

  defp dispatch(
         %{"kind" => "prometheus", "data" => d, "policy" => %{"semantics" => "ratio"} = p},
         occurred,
         _
       ) do
    with numerators when is_list(numerators) and length(numerators) <= 100 <- d["numerators"],
         denominators when is_list(denominators) and length(denominators) <= 100 <-
           d["denominators"],
         true <-
           Enum.all?(
             numerators ++ denominators,
             &(is_map(&1) and is_binary(&1["series"]) and is_number(&1["value"]))
           ),
         minimum when is_number(minimum) and minimum > 0 <- p["minimum_traffic"],
         :ok <- known_samples(numerators ++ denominators, occurred) do
      case if(Metrics.aligned?(numerators, denominators),
             do: Metrics.ratio(numerators, denominators, minimum),
             else: {:error, :unaligned_timestamps}
           ) do
        {:ok, value} ->
          ok(%{
            condition: Metrics.condition([%{"value" => value}], %{threshold: p["threshold"]}),
            ratio: value,
            coverage: "complete",
            count_basis: "sum of matching numerators / sum of matching denominators"
          })

        {:error, reason} ->
          ok(%{condition: "unknown", coverage: "partial", missing: to_string(reason)})
      end
    else
      _ -> unavailable(:missing_inputs)
    end
  end

  defp dispatch(%{"kind" => "prometheus", "data" => d, "policy" => p}, occurred, _) do
    with samples when is_list(samples) and length(samples) <= 100 <- d["samples"],
         true <- Enum.all?(samples, &(is_map(&1) and is_number(&1["value"]))),
         threshold when is_number(threshold) <- p["threshold"],
         :ok <- known_samples(samples, occurred) do
      ok(%{
        condition: Metrics.condition(samples, %{threshold: threshold}),
        coverage: d["coverage"]
      })
    else
      _ -> unavailable(:missing_inputs)
    end
  end

  defp dispatch(%{"kind" => "loki", "data" => d, "policy" => p} = row, _, _) do
    with count when is_number(count) and count >= 0 <- d["count"],
         true <- is_map(p),
         minimum when is_number(minimum) <- Map.get(p, "minimum_count", 10),
         samples when is_list(samples) and length(samples) <= 200 <- d["samples"],
         true <- Enum.all?(samples, &(is_map(&1) and is_binary(&1["message"]))) do
      signatures =
        samples
        |> Enum.group_by(&Fingerprints.normalize(&1["message"]))
        |> Enum.take(20)
        |> Enum.sort_by(&elem(&1, 0))
        |> Enum.map(fn {text, entries} ->
          %{
            fingerprint:
              Fingerprints.identify(row["company_id"], row["service_id"], "loki", text),
            sample_count: length(entries),
            count_basis: "observed in bounded sample; exact fingerprint total unknown"
          }
        end)

      ok(%{
        condition: if(count >= minimum, do: "watch", else: "normal"),
        count: count,
        signatures: signatures,
        sample_coverage: d["sample_coverage"]
      })
    else
      _ -> unavailable(:missing_inputs)
    end
  end

  defp dispatch(%{"kind" => "kubernetes", "data" => d}, _, _) do
    with changes when is_list(changes) and length(changes) <= 2000 <- d["changes"],
         true <- Enum.all?(changes, &is_map/1) do
      ok(%{
        condition:
          if(d["initial_snapshot"] == true,
            do: "unknown",
            else: OpsBrain.Workloads.condition(changes)
          ),
        changes: changes,
        initial_snapshot: d["initial_snapshot"],
        resources: d["resources"],
        inventory_counts: d["inventory_counts"],
        gap: d["gap"],
        coverage: d["coverage"],
        basis:
          "retained workload transitions; not raw watch reprocessing or deployment-success inference"
      })
    else
      _ -> unavailable(:missing_inputs)
    end
  end

  defp dispatch(%{"kind" => "pipeline_task", "data" => d} = row, _, _) do
    with issues when is_list(issues) and length(issues) <= 10 <- d["issues"],
         true <- Enum.all?(issues, &is_binary/1),
         tool when is_binary(tool) <- d["tool"] do
      text = Enum.join(issues, "\n")
      text = if text == "", do: d["snippet"] || "Unclassified failed operation", else: text
      ok(Fingerprints.identify(row["company_id"], {row["source_id"], "CI-only"}, tool, text))
    else
      _ -> unavailable(:missing_inputs)
    end
  end

  defp dispatch(%{"kind" => "capacity_evaluation", "data" => d}, occurred, received) do
    with 1 <- d["version"],
         samples when is_list(samples) and length(samples) <= 60 <- d["input_samples"],
         true <-
           Enum.all?(
             samples,
             &(is_map(&1) and is_number(&1["time"]) and is_number(&1["received_at"]))
           ),
         policy when is_map(policy) <- d["policy"],
         %DateTime{} = at <- Store.parse(d["as_of"]),
         true <- DateTime.compare(at, received) != :gt do
      samples = Enum.map(samples, &keys(&1, @sample_keys))
      event = DateTime.to_unix(occurred)
      receipt = DateTime.to_unix(received)
      known = Enum.filter(samples, &(&1.time <= event and &1.received_at <= receipt))
      ok(Capacity.evaluate(known, keys(policy, @policy_keys), DateTime.to_unix(at)))
    else
      n when is_integer(n) and n != 1 -> unavailable(:unsupported_version)
      _ -> unavailable(:missing_inputs)
    end
  end

  defp dispatch(%{"kind" => "correlation", "data" => d}, occurred, received) do
    # Historical correlation rows contain output only. Never infer their missing inputs.
    with 1 <- d["version"],
         symptom when is_map(symptom) <- d["symptom"],
         changes when is_list(changes) and length(changes) <= 20 <- d["changes"],
         topology when is_list(topology) and length(topology) <= 100 <- d["topology"] do
      correlate(
        keys(symptom, @fact_keys),
        Enum.map(changes, &keys(&1, @fact_keys)),
        Enum.map(topology, fn [a, b] -> {a, b} end),
        occurred,
        received
      )
    else
      n when is_integer(n) and n != 1 -> unavailable(:unsupported_version)
      _ -> unavailable(:missing_inputs)
    end
  end

  defp dispatch(_, _, _), do: unavailable(:unsupported_kind)

  def correlate(symptom, changes, topology, occurred, received) do
    event = DateTime.to_unix(occurred)
    receipt = DateTime.to_unix(received)

    if symptom.occurred_at <= event and symptom.received_at <= receipt do
      known = Enum.filter(changes, &(&1.occurred_at <= event and &1.received_at <= receipt))
      ok(Correlation.evaluate(symptom, known, topology, receipt))
    else
      unavailable(:not_known)
    end
  end

  defp known_samples(samples, occurred) do
    cutoff = DateTime.to_unix(occurred)

    if Enum.all?(samples, &(is_number(&1["timestamp"]) and &1["timestamp"] <= cutoff)),
      do: :ok,
      else: :unknown_temporal_inputs
  end

  # Fixed allowlists: persisted strings never create runtime atoms.
  defp keys(map, allowed), do: Map.new(allowed, &{&1, Map.get(map, Atom.to_string(&1))})
  defp ok(result), do: %{status: :ok, detector_version: 1, result: result}
  defp unavailable(reason), do: %{status: reason, exact: false}
end
