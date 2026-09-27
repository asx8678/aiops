defmodule OpsBrain.PredictionWorker do
  @moduledoc """
  Opt-in persistence of critical storage, saturation and pipeline predictions
  as findings, so Investigations can surface and notify them like any other
  signal. Disabled by default behind :prediction_enabled (the switch must be
  the literal true). Reads run under one valid trusted config of the company
  (the deterministic smallest valid id, only to establish the company RLS
  scope — the carrier is documented and never the recorded origin); each
  prediction is then persisted inside the SourceConfig transaction of the
  source that actually produced it, so evidence, retention and notification
  policy follow real provenance. A risk that is no longer critical is simply
  not recorded — a recovered prediction stops refreshing last_seen.
  """
  use Oban.Worker,
    queue: :maintenance,
    max_attempts: 3,
    unique: [
      period: 300,
      fields: [:worker],
      states: [:available, :scheduled, :executing, :retryable]
    ]

  alias OpsBrain.{Evidence, Fingerprints, Insights, Issues, SourceConfig, Store}

  @impl Oban.Worker
  def timeout(_job), do: :timer.minutes(5)

  @impl Oban.Worker
  def perform(%Oban.Job{args: args}) when map_size(args) == 0 do
    if enabled?(), do: run(), else: :discard
  end

  def perform(_), do: :discard

  # The switch must be the literal true: malformed truthy values ("false",
  # 0, 1, "true") fail closed.
  def enabled?, do: Application.get_env(:ops_brain, :prediction_enabled) == true

  @doc """
  One prediction pass per configured company. Returns :disabled unless the
  switch is literally true; unexpected persistence failures surface as
  {:error, reasons} for Oban retry, while absent or invalid trusted configs
  skip only that company.
  """
  def run(now \\ Store.now()) do
    if enabled?() do
      run_pass(now)
    else
      :disabled
    end
  end

  defp run_pass(now) do
    configs =
      SourceConfig.all()
      |> Map.values()
      |> Enum.group_by(& &1.company_id)

    {skipped, errors} =
      Enum.flat_map_reduce(configs, [], fn {_company_id, company_configs}, errs ->
        case read_company(company_configs, now) do
          {:ok, predictions} ->
            Enum.flat_map_reduce(predictions, errs, &persist_reduce(&1, &2, now))

          {:skip, :no_valid_config} ->
            # no trusted config can scope this company: fail closed
            {[:skipped_company], errs}

          {:error, reason} ->
            {[:failed_company], [reason | errs]}
        end
      end)

    if errors == [] do
      :ok
    else
      {:error, {:prediction_persistence, Enum.reverse(errors), skipped}}
    end
  end

  # Reads need a company scope; any valid trusted config provides it. The
  # smallest valid id keeps reads deterministic — it is a carrier, never the
  # recorded origin (each prediction records under its own contributing
  # source, see persist_reduce).
  defp read_company(company_configs, now) do
    company_configs
    |> Enum.sort_by(& &1.id)
    |> Enum.find_value({:skip, :no_valid_config}, fn c ->
      case SourceConfig.fetch(c.id) do
        {:ok, _} -> {:ok, c}
        _ -> nil
      end
    end)
    |> case do
      {:ok, carrier} ->
        case SourceConfig.transaction(carrier.id, fn _carrier ->
               Insights.predictions(now)
             end) do
          {:ok, predictions} -> {:ok, predictions}
          {:error, :source_disabled_or_invalid} -> {:skip, :no_valid_config}
          {:error, reason} -> {:error, reason}
        end

      other ->
        other
    end
  end

  defp persist_reduce(prediction, errors, now) do
    source_id = prediction_source(prediction)

    cond do
      source_id == nil ->
        # no contributing collector source (demo-shaped or unattributable
        # data): never guess an origin
        {[:skipped_unattributed], errors}

      true ->
        case SourceConfig.transaction(source_id, fn c ->
               record(c, prediction, now)
             end) do
          {:ok, _} -> {[:ok], errors}
          {:error, :source_disabled_or_invalid} -> {[:skipped_disabled], errors}
          {:error, reason} -> {[:failed], [reason | errors]}
        end
    end
  end

  # The source that actually produced the prediction's inputs: the identity's
  # collector for storage/saturation, the newest run's source for pipelines.
  defp prediction_source(%{kind: kind} = p) when kind in ["storage", "saturation"],
    do: p.source_id

  defp prediction_source(%{kind: "pipeline"} = p), do: p.source_id

  defp record(c, %{kind: "storage"} = p, now) do
    identity = {:storage, p.source_id, p.service_instance_id, p.environment, p.volume}

    fp =
      Fingerprints.identify(
        c.company_id,
        identity,
        "prediction",
        "prediction:storage:#{p.volume} on #{p.target}"
      )

    data = %{
      "detector" => "insights_forecast",
      "version" => 1,
      "kind" => "storage",
      "volume" => p.volume,
      "service" => p.service,
      "environment" => p.environment,
      "target" => p.target,
      "service_instance_id" => p.service_instance_id,
      "prediction_target" => prediction_target(p),
      "level" => p.level,
      "reasons" => p.reasons,
      "hours_to_full" => p.hours_to_full,
      "recent_rate" => p.recent_rate,
      "baseline_rate" => p.baseline_rate,
      "size_gib" => p.size_gib,
      "used_gib" => p.used_gib,
      "used_percent" => p.used_percent,
      "fresh_hours" => p.fresh_hours,
      "as_of" => Store.iso(now),
      "basis" => "conditional linear forecast from retained history; not an outage time"
    }

    evidence =
      Evidence.save(
        c,
        "prediction:storage:#{p.volume}:#{p.target}:#{Store.iso(now)}:#{Store.digest(data)}",
        "prediction",
        data,
        now,
        now
      )

    Issues.record(
      c,
      occurrence_key("storage", identity, now, data),
      evidence,
      fp,
      record_identity(now, p.target, prediction_target(p)),
      now
    )
  end

  defp record(c, %{kind: "saturation"} = p, now) do
    identity =
      {:saturation, p.source_id, p.service_instance_id, p.environment, p.volume, p.signal}

    fp =
      Fingerprints.identify(
        c.company_id,
        identity,
        "prediction",
        "prediction:saturation:#{p.volume}:#{p.signal} on #{p.target}"
      )

    data = %{
      "detector" => "insights_forecast",
      "version" => 1,
      "kind" => "saturation",
      "signal" => p.signal,
      "unit" => p.unit,
      "volume" => p.volume,
      "service" => p.service,
      "environment" => p.environment,
      "target" => p.target,
      "level" => p.level,
      "reasons" => p.reasons,
      "value" => p.value,
      "limit" => p.limit,
      "percent" => p.percent,
      "hours_to_full" => p.hours_to_full,
      "recent_rate" => p.recent_rate,
      "fresh_hours" => p.fresh_hours,
      "service_instance_id" => p.service_instance_id,
      "prediction_target" => prediction_target(p),
      "as_of" => Store.iso(now),
      "basis" => "conditional growth forecast from retained count samples; not an outage time"
    }

    evidence =
      Evidence.save(
        c,
        "prediction:saturation:#{Store.digest(identity)}:#{Store.iso(now)}:#{Store.digest(data)}",
        "prediction",
        data,
        now,
        now
      )

    Issues.record(
      c,
      occurrence_key("saturation", identity, now, data),
      evidence,
      fp,
      record_identity(now, p.target, prediction_target(p)),
      now
    )
  end

  defp record(c, %{kind: "pipeline"} = p, now) do
    identity = {:pipeline, p.source_id, p.definition_id, p.environment, p.service_instance_id}

    scope_text =
      if(p.environment,
        do: "prediction:pipeline:#{p.name} (definition #{p.definition_id}, #{p.environment})",
        else: "prediction:pipeline:#{p.name} (definition #{p.definition_id}, CI-only)"
      )

    fp = Fingerprints.identify(c.company_id, identity, "prediction", scope_text)

    data = %{
      "detector" => "insights_forecast",
      "version" => 1,
      "kind" => "pipeline",
      "pipeline" => p.name,
      "environment" => p.environment,
      "environments" => p.environments,
      "level" => p.level,
      "reason" => p.reason,
      "streak" => p.streak,
      "failures" => p.failures,
      "total" => p.total,
      "flaky" => p.flaky,
      "ci_only" => p.ci_only,
      "source_id" => p.source_id,
      "definition_id" => p.definition_id,
      "service_instance_id" => p.service_instance_id,
      "prediction_target" => prediction_target(p),
      "as_of" => Store.iso(now),
      "basis" => "failure streaks and flakiness from retained runs; not a runtime incident"
    }

    evidence =
      Evidence.save(
        c,
        "prediction:pipeline:#{Store.digest(identity)}:#{Store.iso(now)}:#{Store.digest(data)}",
        "prediction",
        data,
        now,
        now
      )

    # CI-only groups carry an explicit nil target: company-wide, never on a
    # service page
    Issues.record(
      c,
      occurrence_key("pipeline", identity, now, data),
      evidence,
      fp,
      record_identity(now, p.target, prediction_target(p)),
      now
    )
  end

  # Fingerprints stay on target identity so an open episode still coalesces.
  # The occurrence is the evaluation itself: a later clock or payload is a new
  # occurrence, and Issues.find_group — not a constant key — decides closure
  # and the episode gap. Replaying the same clock and payload reuses the key,
  # so Issues.record stays idempotent. Evidence keys are unchanged.
  defp occurrence_key(kind, identity, now, data) do
    "prediction:#{kind}:#{Store.digest(identity)}:#{Store.iso(now)}:#{Store.digest(data)}"
  end

  # Structured target identity persisted with every prediction finding, so the
  # Troubleshoot pages match findings by exact instance/environment instead of
  # scope substrings; nil for explicitly unscoped (CI-only) predictions.
  defp prediction_target(p) do
    if p.service_instance_id do
      %{
        "service_instance_id" => p.service_instance_id,
        "environment" => p.environment,
        "target" => p.target
      }
    else
      nil
    end
  end

  # The scope carries the explicit target (cluster/namespace/service) so the
  # finding appears on its own Troubleshoot page's filter.
  defp record_identity(now, scope, prediction_target) do
    %{
      occurred_at: now,
      severity: "critical",
      scope: scope,
      prediction_target: prediction_target,
      count_basis: "distinct forecast evaluations; conditional estimate"
    }
  end
end
