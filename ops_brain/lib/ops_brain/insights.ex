defmodule OpsBrain.Insights do
  @moduledoc """
  One-place operational picture: what needs attention now, what is trending
  towards failure, and everything known about one service when troubleshooting.

  Reads are scoped and bounded like every other page. Analysis functions are
  pure so they can be tested without a database. Predictions are simple,
  explainable heuristics (recent vs baseline rate, linear time-to-full,
  failure streaks), never guarantees.
  """
  alias OpsBrain.{Issues, Services, Store, Tenancy}
  alias OpsBrain.Insights.Sources

  @failed ~w(failed)
  @degraded ~w(partiallySucceeded canceled)
  # Explicit non-completed pipeline statuses: never a completed outcome, even
  # when a residual result string is present.
  @non_completed ~w(notStarted inProgress postponed cancelling)
  @closed_statuses ~w(closed resolved locally_closed)
  # Older than this, a usage history cannot support a current growth claim.
  @stale_hours 6

  # Prediction thresholds: defaults are preserved exactly; every value is
  # overridable through `config :ops_brain, OpsBrain.Insights` and validated.
  @default_thresholds %{
    storage: %{
      warn_pct: 85,
      crit_pct: 95,
      warn_hours: 72,
      crit_hours: 24,
      abnormal_factor: 3,
      recent_window_hours: 6,
      min_abnormal_rate_gib_h: 0.25
    },
    pipelines: %{window: 10, streak_critical: 2, last5_critical: 3}
  }

  @doc """
  Effective prediction thresholds: `config :ops_brain, OpsBrain.Insights` merged over
  the defaults — storage: warn_pct 85, crit_pct 95, warn_hours 72, crit_hours 24,
  abnormal_factor 3, recent_window_hours 6, min_abnormal_rate_gib_h 0.25; pipelines:
  window 10, streak_critical 2, last5_critical 3. Overrides may be maps or keyword
  lists with atom or string keys; missing, non-numeric or out-of-range values fall
  back to that key's default and unknown keys are ignored.
  """
  def thresholds do
    configured = Application.get_env(:ops_brain, __MODULE__, %{})

    Map.new(@default_thresholds, fn {group, defaults} ->
      {group, merge_thresholds(defaults, config_group(configured, group))}
    end)
  end

  # Top-level config may be a map (atom or string keys) or a keyword list;
  # anything else is treated as no overrides rather than raising.
  defp config_group(configured, group) when is_map(configured),
    do: Map.get(configured, group) || Map.get(configured, to_string(group))

  defp config_group(configured, group) when is_atom(group) and is_list(configured) do
    Enum.find_value(configured, fn
      {k, v} when k == group -> v
      _ -> nil
    end)
  end

  defp config_group(_, _), do: nil

  defp merge_thresholds(defaults, overrides) do
    Map.new(defaults, fn {key, default} ->
      value = override_value(overrides, key)
      {key, if(threshold_valid?(key, value), do: value, else: default)}
    end)
  end

  defp override_value(overrides, key) when is_map(overrides),
    do: overrides[key] || overrides[to_string(key)]

  defp override_value(overrides, key) when is_atom(key) and is_list(overrides) do
    Enum.find_value(overrides, fn
      {k, v} when k == key -> v
      _ -> nil
    end)
  end

  defp override_value(_, _), do: nil

  defp threshold_valid?(key, value), do: is_number(value) and within_bounds?(key, value)

  defp within_bounds?(key, v) do
    case key do
      :warn_pct -> v > 0 and v <= 100
      :crit_pct -> v > 0 and v <= 100
      :warn_hours -> v > 0
      :crit_hours -> v > 0
      :abnormal_factor -> v > 1
      :recent_window_hours -> v > 0
      :min_abnormal_rate_gib_h -> v >= 0
      :window -> is_integer(v) and v > 0
      :streak_critical -> is_integer(v) and v >= 1
      :last5_critical -> is_integer(v) and v >= 1
    end
  end

  # ---------------------------------------------------------------------------
  # Reads
  # ---------------------------------------------------------------------------

  @doc "Everything the command center renders, read under one authorized scope."
  def command(scope, now \\ Store.now()), do: command(scope, "", now)

  @doc """
  Everything the command center renders for one environment selection, read
  under one authorized scope. "prod"/"staging"/"dev" narrows services and
  their windows, runtime resources, capacity evaluations (in SQL, before the
  record limit), the series behind storage/saturation risks and the
  deployment runs behind pipeline health — which is recomputed from the
  filtered runs, never filtered after aggregation. "" keeps every record.
  Unmapped provenance — CI-only runs, name-only mappings, unmapped
  evaluations and findings — is never assigned the selected environment; it
  appears only under All.
  """
  def command(scope, environment, now) do
    with {:ok, groups} <- Issues.list(scope),
         {:ok, services} <- Services.overview(scope, environment),
         {:ok, windows} <- Services.windows(scope, environment),
         {:ok, sources} <- Services.sources(scope, now),
         {:ok, evaluations} <- Services.capacity_evaluations(scope, environment, now),
         {:ok, {runs, resources, series, count_series, memory_series}} <-
           command_rows(scope, now, environment) do
      services_by_id = Map.new(services, &{&1["id"], &1})

      # Finding provenance resolves against the FULL authorized identity set,
      # never the environment-filtered one, so an ambiguous legacy scope
      # cannot be assigned to whichever environment the viewer selected.
      {:ok, provenance} =
        Tenancy.with_scope(scope, fn ->
          Map.new(Sources.service_instances(), &{&1["id"], &1})
        end)

      # Kubernetes cursors attribute each object's environment in Elixir;
      # that is the one bounded read where the selection cannot precede the
      # cap, so it is applied to the attributed objects instead.
      resources = environment_field(resources, environment)

      pipelines = pipeline_health(runs)
      storage = storage_risks(series, services_by_id)

      counts =
        count_risks(count_series, services_by_id) ++ memory_risks(memory_series, services_by_id)

      blind_spots = blind_spots(sources)

      attention =
        attention(groups, windows, services_by_id, resources, pipelines, evaluations, provenance)
        |> environment_attention(environment)

      {:ok,
       %{
         attention: attention,
         pipelines: pipelines,
         storage: storage,
         saturation: counts,
         blind_spots: blind_spots,
         services: services,
         counts: %{
           critical: Enum.count(attention, &(&1.level == "critical")),
           warning: Enum.count(attention, &(&1.level == "warning")),
           predicted:
             Enum.count(storage, &(&1.level in ["warning", "critical"])) +
               Enum.count(counts, &(&1.level in ["warning", "critical"])) +
               Enum.count(pipelines, &(&1.level in ["warning", "critical"])),
           blind: length(blind_spots)
         }
       }}
    end
  end

  # Every read applies the environment selection in SQL before its bound:
  # services and windows (Services.overview/windows), capacity evaluations
  # (Services.capacity_evaluations), the storage/count/memory series
  # (Sources.*_series) and the deployment runs behind pipeline health
  # (command_pipeline_rows). Unmapped records keep their unknown provenance —
  # they are never assigned the selected environment and appear only under
  # All.
  defp command_rows(scope, now, environment) do
    Tenancy.with_scope(scope, fn ->
      {command_pipeline_rows(now, environment), Sources.resources(now, nil),
       Sources.storage_series(now, nil, environment), Sources.count_series(now, nil, environment),
       Sources.memory_series(now, nil, environment)}
    end)
  end

  defp environment_field(records, ""), do: records

  defp environment_field(records, environment),
    do: Enum.filter(records, &(&1["environment"] == environment))

  # Pipeline attention items are built from environment-filtered runs, so
  # under a selection they carry that environment; every other item keeps its
  # own real environment, and unmapped items never inherit one.
  defp environment_attention(attention, ""), do: attention

  defp environment_attention(attention, environment) do
    attention
    |> Enum.map(fn
      %{kind: "Pipeline"} = item -> %{item | environment: environment}
      item -> item
    end)
    |> Enum.filter(&(&1.environment == environment))
  end

  @doc "All context for one service in one environment."
  def service(scope, service_key, environment, now \\ Store.now()) do
    with {:ok, services} <- Services.overview(scope),
         %{} = instance <-
           Enum.find(
             services,
             &(&1["service_key"] == service_key and &1["environment"] == environment)
           ) ||
             {:error, :not_found},
         {:ok, groups} <- Issues.list(scope),
         {:ok, windows} <- Services.windows(scope),
         {:ok, sources} <- Services.sources(scope, now),
         {:ok, rows} <- service_rows(scope, instance, service_key, now) do
      windows = Enum.filter(windows, &(&1["service_id"] == instance["id"]))
      metric = Enum.find(windows, &(&1["kind"] == "metric"))
      capacity = Enum.find(windows, &(&1["kind"] == "capacity"))
      cluster = cluster(instance["target"])
      scope_marker = "/#{service_key}"

      findings =
        groups
        |> Enum.filter(fn g ->
          prediction_target = g["data"]["prediction_target"]

          cond do
            is_map(prediction_target) ->
              # worker-created predictions match by exact instance/environment
              prediction_target["service_instance_id"] == instance["id"] and
                prediction_target["environment"] == environment

            Map.has_key?(g["data"], "prediction_target") ->
              # explicitly unscoped prediction (CI-only): never on a service page
              false

            true ->
              scope_text = get_in(g, ["data", "scope"]) || ""

              String.ends_with?(scope_text, scope_marker) and
                String.contains?(scope_text, cluster)
          end
        end)
        |> Enum.map(fn g -> Map.put(g, "correlation", rows.correlations[g["id"]]) end)

      storage =
        case storage_risks(rows.storage, %{instance["id"] => instance}) do
          [risk | _] -> risk
          [] -> nil
        end

      pipelines = pipeline_health(rows.runs)
      resources = rows.resources

      counts =
        count_risks(rows.counts, %{instance["id"] => instance}) ++
          memory_risks(rows.memory, %{instance["id"] => instance})

      {:ok,
       %{
         instance: instance,
         cluster: cluster,
         condition: (metric || capacity || %{})["data"]["condition"] || "unknown",
         metric: metric && metric["data"],
         storage: storage,
         saturation: counts,
         findings: findings,
         pipeline: List.first(pipelines),
         runs: rows.runs,
         resources: resources,
         database: rows.database,
         timeline: timeline(rows.runs, findings, resources),
         coverage: coverage(sources, cluster),
         checks: checks(findings, resources, storage, pipelines, metric, rows.database, counts)
       }}
    end
  end

  defp service_rows(scope, instance, service_key, now) do
    cluster = cluster(instance["target"])

    Tenancy.with_scope(scope, fn ->
      resources =
        now
        |> resource_rows(service_key)
        |> Enum.filter(&matches_instance?(&1, instance))

      database_name =
        Store.one(
          "SELECT data->'storage'->>'volume' AS volume FROM observation_windows WHERE service_id=$1::text::uuid AND kind='capacity' LIMIT 1",
          [instance["id"]]
        )

      database =
        case database_name do
          %{"volume" => name} when is_binary(name) ->
            now
            |> database_rows(name)
            |> Enum.find(&(&1["cluster"] == cluster))

          _ ->
            nil
        end

      correlations =
        Store.rows(
          "SELECT data FROM evidence_items WHERE kind='correlation' AND expires_at > $1 ORDER BY occurred_at DESC LIMIT 100",
          [now]
        )
        |> Map.new(&{&1["data"]["group_id"], &1["data"]})

      %{
        runs: pipeline_rows(service_key, instance["environment"], now),
        resources: resources,
        database: database,
        correlations: correlations,
        storage: Sources.storage_series(now, instance["id"]),
        counts: Sources.count_series(now, instance["id"]),
        memory: Sources.memory_series(now, instance["id"])
      }
    end)
  end

  # Runs group under the service their deployment evidence targeted
  # (kind='deployment', matched by company, source and data.run_id, unexpired
  # and not received in the future); the run's own data.service is the
  # demo-shaped fallback and unmapped CI-only runs group under their definition
  # id. Environment comes from the deployed service instance, so troubleshoot
  # pages select it in SQL; runs without environment evidence stay unfiltered.
  # The service view filters BEFORE bounding so busy unrelated pipelines cannot
  # hide a service's history; the command view stays a bounded global read with
  # a documented deterministic per-run display cap (never applied to the
  # service query, which aggregates only the requested service and proves
  # whether any valid deployment mapping exists before using the name
  # fallback). Runs and evidence must not be received or have occurred in the
  # future; unfinished runs (finish_at NULL) are retained.
  defp pipeline_rows(nil, nil, now) do
    Store.rows(
      """
      WITH runs AS MATERIALIZED (
        SELECT * FROM pipeline_runs
        WHERE received_at <= $1 AND (finish_at IS NULL OR finish_at <= $1)
        ORDER BY finish_at DESC NULLS LAST,id DESC LIMIT 300
      )
      SELECT r.id::text,r.source_id::text,r.run_id,r.definition_id,r.status,r.result,r.finish_at,r.received_at,
        COALESCE(dep.service, r.data->>'service', 'definition ' || r.definition_id::text) AS service,
        dep.environment AS environment,
        COALESCE(dep.environments, '[]'::jsonb) AS environments,
        r.data->>'branch' AS branch,
        r.data->>'start_at' AS start_at,
        (dep.service IS NULL AND r.data->>'service' IS NULL) AS ci_only
      FROM runs r
      LEFT JOIN LATERAL (
        SELECT s.service_key AS service,
          (array_agg(env.name ORDER BY e.received_at DESC, e.id::text DESC))[1] AS environment,
          jsonb_agg(DISTINCT env.name) AS environments,
          max(e.received_at) AS latest
        FROM evidence_items e
        JOIN service_instances s ON s.id::text=e.data->>'target_id' AND s.company_id=e.company_id
        JOIN environments env ON env.id=s.environment_id AND env.company_id=s.company_id
        WHERE e.company_id=r.company_id AND e.source_id=r.source_id AND e.kind='deployment'
          AND e.data->>'run_id'=r.run_id::text AND e.expires_at > $1
          AND e.received_at <= $1 AND e.occurred_at <= $1
        GROUP BY s.service_key
        ORDER BY latest DESC, s.service_key
        LIMIT 20
      ) dep ON true
      ORDER BY r.finish_at DESC NULLS LAST,r.id DESC
      LIMIT 500
      """,
      [now]
    )
    |> Enum.map(&put_duration/1)
  end

  defp pipeline_rows(service_key, environment, now) do
    Store.rows(
      """
      SELECT r.id::text,r.source_id::text,r.run_id,r.definition_id,r.status,r.result,r.finish_at,r.received_at,
        COALESCE(dep.service, r.data->>'service', 'definition ' || r.definition_id::text) AS service,
        dep.environment AS environment,
        COALESCE(dep.environments, '[]'::jsonb) AS environments,
        r.data->>'branch' AS branch,
        r.data->>'start_at' AS start_at,
        (dep.service IS NULL AND NOT any_dep.has_mapping AND r.data->>'service' IS NULL) AS ci_only
      FROM pipeline_runs r
      LEFT JOIN LATERAL (
        SELECT s.service_key AS service,
          (array_agg(env.name ORDER BY e.received_at DESC, e.id::text DESC))[1] AS environment,
          jsonb_agg(DISTINCT env.name) AS environments
        FROM evidence_items e
        JOIN service_instances s ON s.id::text=e.data->>'target_id' AND s.company_id=e.company_id
        JOIN environments env ON env.id=s.environment_id AND env.company_id=s.company_id
        WHERE e.company_id=r.company_id AND e.source_id=r.source_id AND e.kind='deployment'
          AND e.data->>'run_id'=r.run_id::text AND e.expires_at > $3
          AND e.received_at <= $3 AND e.occurred_at <= $3
          AND s.service_key = $1
        GROUP BY s.service_key
      ) dep ON true
      LEFT JOIN LATERAL (
        SELECT EXISTS (
          SELECT 1
          FROM evidence_items e
          JOIN service_instances s ON s.id::text=e.data->>'target_id' AND s.company_id=e.company_id
          WHERE e.company_id=r.company_id AND e.source_id=r.source_id AND e.kind='deployment'
            AND e.data->>'run_id'=r.run_id::text AND e.expires_at > $3
            AND e.received_at <= $3 AND e.occurred_at <= $3
        ) AS has_mapping
      ) any_dep ON true
      WHERE r.received_at <= $3 AND (r.finish_at IS NULL OR r.finish_at <= $3)
        AND (
          dep.service = $1
          OR (NOT any_dep.has_mapping AND r.data->>'service' = $1)
        )
        AND ($2::text IS NULL OR dep.environments IS NULL
             OR dep.environments='[]'::jsonb OR dep.environments ? $2)
      ORDER BY r.finish_at DESC NULLS LAST,r.id DESC
      LIMIT 300
      """,
      [service_key, environment, now]
    )
    |> Enum.map(&put_duration/1)
  end

  # Persistence-specific run rows: unlike the command-center aggregate above,
  # each run carries its ACTUAL deployment targets (service instance id,
  # environment, service) straight from its deployment evidence, so the
  # prediction partitions never re-resolve instances by name/environment
  # guesses. Runs and evidence must not be received or have occurred in the
  # future; runs without deployment evidence carry no targets.
  defp pipeline_prediction_rows(now) do
    Store.rows(
      """
      WITH runs AS MATERIALIZED (
        SELECT * FROM pipeline_runs
        WHERE received_at <= $1 AND (finish_at IS NULL OR finish_at <= $1)
        ORDER BY finish_at DESC NULLS LAST,id DESC LIMIT 300
      )
      SELECT r.id::text,r.source_id::text,r.run_id,r.definition_id,r.status,r.result,r.finish_at,r.received_at,
        COALESCE(r.data->>'service', 'definition ' || r.definition_id::text) AS service,
        r.data->>'branch' AS branch,
        r.data->>'start_at' AS start_at,
        COALESCE(dep.targets, '[]'::jsonb) AS targets,
        (dep.targets IS NULL) AS ci_only
      FROM runs r
      LEFT JOIN LATERAL (
        SELECT jsonb_agg(DISTINCT jsonb_build_object('target_id', s.id::text, 'environment', env.name::text, 'service', s.service_key)) AS targets
        FROM evidence_items e
        JOIN service_instances s ON s.id::text=e.data->>'target_id' AND s.company_id=e.company_id
        JOIN environments env ON env.id=s.environment_id AND env.company_id=s.company_id
        WHERE e.company_id=r.company_id AND e.source_id=r.source_id AND e.kind='deployment'
          AND e.data->>'run_id'=r.run_id::text AND e.expires_at > $1
          AND e.received_at <= $1 AND e.occurred_at <= $1
      ) dep ON true
      ORDER BY r.finish_at DESC NULLS LAST,r.id DESC
      LIMIT 500
      """,
      [now]
    )
    |> Enum.map(&put_duration/1)
  end

  # Run duration from the retained start time: only a run that is actually
  # completed with a parseable start before its finish has a duration;
  # anything else (missing, malformed, in-progress or otherwise non-completed,
  # inverted) stays unknown instead of fabricated.
  defp put_duration(
         %{
           "finish_at" => %DateTime{} = finish,
           "start_at" => start_text,
           "status" => status
         } = row
       )
       when is_binary(start_text) and status not in @non_completed do
    case DateTime.from_iso8601(start_text) do
      {:ok, start, _} ->
        if DateTime.compare(finish, start) == :gt,
          do: Map.put(row, "duration_seconds", DateTime.diff(finish, start)),
          else: Map.put(row, "duration_seconds", nil)

      _ ->
        Map.put(row, "duration_seconds", nil)
    end
  end

  defp put_duration(row), do: Map.put(row, "duration_seconds", nil)

  # Kubernetes-shaped runtime objects, normalized from real cursors and demo
  # fixtures by the Sources adapter, bounded and filtered in SQL where possible.
  defp resource_rows(now, service_key), do: Sources.resources(now, service_key)

  # Environment-selected pipeline runs for the command center: the
  # deployment-evidence EXISTS filter runs INSIDE the bounded newest-first
  # window, so newer runs from other environments cannot push the selected
  # environment's runs out of the cap. A run deployed to several
  # environments participates in each of them; All keeps the shared aggregate
  # read unchanged.
  defp command_pipeline_rows(now, "") do
    pipeline_rows(nil, nil, now)
  end

  defp command_pipeline_rows(now, environment) do
    Store.rows(
      """
      WITH runs AS MATERIALIZED (
        SELECT r.* FROM pipeline_runs r
        WHERE r.received_at <= $1 AND (r.finish_at IS NULL OR r.finish_at <= $1)
          AND EXISTS (
            SELECT 1 FROM evidence_items e
            JOIN service_instances s ON s.id::text=e.data->>'target_id' AND s.company_id=e.company_id
            JOIN environments env ON env.id=s.environment_id AND env.company_id=s.company_id
            WHERE e.company_id=r.company_id AND e.source_id=r.source_id AND e.kind='deployment'
              AND e.data->>'run_id'=r.run_id::text AND e.expires_at > $1
              AND e.received_at <= $1 AND e.occurred_at <= $1
              AND env.name::text=$2
          )
        ORDER BY r.finish_at DESC NULLS LAST,r.id DESC LIMIT 300
      )
      SELECT r.id::text,r.source_id::text,r.run_id,r.definition_id,r.status,r.result,r.finish_at,r.received_at,
        COALESCE(dep.service, r.data->>'service', 'definition ' || r.definition_id::text) AS service,
        dep.environment AS environment,
        COALESCE(dep.environments, '[]'::jsonb) AS environments,
        r.data->>'branch' AS branch,
        r.data->>'start_at' AS start_at,
        (dep.service IS NULL AND r.data->>'service' IS NULL) AS ci_only
      FROM runs r
      LEFT JOIN LATERAL (
        SELECT s.service_key AS service,
          (array_agg(env.name ORDER BY e.received_at DESC, e.id::text DESC))[1] AS environment,
          jsonb_agg(DISTINCT env.name) AS environments,
          max(e.received_at) AS latest
        FROM evidence_items e
        JOIN service_instances s ON s.id::text=e.data->>'target_id' AND s.company_id=e.company_id
        JOIN environments env ON env.id=s.environment_id AND env.company_id=s.company_id
        WHERE e.company_id=r.company_id AND e.source_id=r.source_id AND e.kind='deployment'
          AND e.data->>'run_id'=r.run_id::text AND e.expires_at > $1
          AND e.received_at <= $1 AND e.occurred_at <= $1
          AND env.name::text=$2
        GROUP BY s.service_key
        ORDER BY latest DESC, s.service_key
        LIMIT 20
      ) dep ON true
      ORDER BY r.finish_at DESC NULLS LAST,r.id DESC
      LIMIT 500
      """,
      [now, environment]
    )
    |> Enum.map(&put_duration/1)
  end

  defp database_rows(now, name) do
    Store.rows(
      "SELECT data FROM evidence_items WHERE kind='demo_resource' AND expires_at > $1 AND data->>'kind'='Database' AND data->>'name'=$2 LIMIT 10",
      [now, name]
    )
    |> Enum.map(& &1["data"])
  end

  @doc """
  Critical storage, saturation and pipeline predictions for the current company
  scope, for the opt-in prediction worker. Scope-internal like the Sources
  readers: runs inside an active company scope (Tenancy.with_scope or a trusted
  SourceConfig transaction), never nested. Only level "critical" risks are
  returned, each carrying the identity (volume/service/environment or pipeline
  name) the worker needs for stable fingerprints. Unverified or mixed signals
  never reach this list because they never reach "critical".
  """
  def predictions(now) do
    services_by_id = Map.new(Sources.service_instances(), &{&1["id"], &1})

    storage =
      storage_risks(Sources.storage_series(now), services_by_id)
      |> Enum.map(&Map.put(&1, :kind, "storage"))

    saturation =
      count_risks(Sources.count_series(now), services_by_id) ++
        memory_risks(Sources.memory_series(now), services_by_id)

    saturation = Enum.map(saturation, &Map.put(&1, :kind, "saturation"))

    pipelines =
      pipeline_prediction_rows(now)
      |> pipeline_predictions(Map.values(services_by_id))

    (storage ++ saturation ++ pipelines)
    |> Enum.filter(&(&1.level == "critical"))
    |> Enum.sort_by(&{&1[:kind], &1[:volume] || &1[:name], &1[:target] || ""})
  end

  # ---------------------------------------------------------------------------
  # Pipelines: failure streaks, flakiness and duration trends
  # ---------------------------------------------------------------------------

  @flaky_changes 3
  @duration_slowdown 1.5
  @known_results ~w(succeeded failed partiallySucceeded canceled)

  @doc "Per-pipeline health from runs ordered newest first."
  def pipeline_health(runs) do
    t = thresholds().pipelines

    runs
    |> Enum.group_by(& &1["service"])
    |> Enum.map(fn {name, runs} ->
      recent =
        Enum.take(runs, t.window) |> Enum.map(&Map.put(&1, "outcome", run_outcome(&1)))

      results = Enum.map(recent, & &1["outcome"])
      streak = Enum.take_while(recent, &(&1["outcome"] == "failed")) |> length()
      failures = Enum.count(recent, &(&1["outcome"] == "failed"))
      last_five = recent |> Enum.take(5) |> Enum.count(&(&1["outcome"] == "failed"))

      prior_five =
        recent |> Enum.drop(5) |> Enum.take(5) |> Enum.count(&(&1["outcome"] == "failed"))

      last_success = Enum.find(recent, &(&1["outcome"] == "succeeded"))
      latest = hd(recent)

      flaky = result_changes(results) >= @flaky_changes
      {last5_median, prev5_median} = duration_medians(recent)
      ratio = duration_ratio(last5_median, prev5_median)

      {level, reason} =
        cond do
          streak >= t.streak_critical ->
            {"critical", "#{streak} failed runs in a row; next deploy is likely blocked"}

          last_five >= t.last5_critical ->
            {"critical", "#{last_five} of the last 5 runs failed"}

          streak > 0 and failures >= 2 ->
            {"warning", "latest run failed and it has failed before"}

          streak > 0 ->
            {"warning", "latest run failed"}

          last_five > prior_five and last_five >= 2 ->
            {"warning", "failing more often than before"}

          flaky ->
            {"warning", "flaky: alternating results"}

          latest["outcome"] in @degraded ->
            {"warning", "latest run #{latest["outcome"]}"}

          latest["outcome"] not in @known_results ->
            {"unknown", "latest run result unknown"}

          true ->
            {"ok", if(failures == 0, do: "no recent failures", else: "recovered")}
        end

      # A measured duration slowdown always surfaces — and an otherwise
      # passing pipeline is never called healthy while it slows down.
      {level, reason} =
        if ratio do
          flagged =
            "#{reason} · run durations up #{fmt_times(ratio)}x (median last 5 vs previous 5)"

          if level == "ok", do: {"warning", flagged}, else: {level, flagged}
        else
          {level, reason}
        end

      %{
        name: name,
        level: level,
        reason: reason,
        streak: streak,
        failures: failures,
        total: length(recent),
        results: results,
        last_run: hd(runs),
        last_success: last_success && last_success["finish_at"],
        ci_only: Enum.all?(runs, & &1["ci_only"]),
        flaky: flaky,
        last5_median_seconds: last5_median,
        prev5_median_seconds: prev5_median,
        duration_ratio: ratio,
        environments: group_environments(runs)
      }
    end)
    |> Enum.sort_by(&{rank(&1.level), -&1.streak, -&1.failures, &1.name})
  end

  # Persistence-specific pipeline health: partition the company's runs by their
  # actual stable target identity — (source, definition, deployment
  # environment, service instance); a run deployed to several targets
  # participates in each of them. Health is then computed per partition, so
  # prod failures never fabricate a staging finding and vice versa. The
  # command center's name-level aggregate is untouched. Runs without
  # deployment evidence (CI-only or unmapped) persist under their own
  # explicitly unscoped source+definition identity, never spread to known
  # targets.
  defp pipeline_predictions(runs, instances) do
    partitions =
      runs
      |> Enum.flat_map(fn run ->
        for {key, service} <- pipeline_keys(run), do: {key, scoped_run(run, key, service)}
      end)
      |> Enum.group_by(fn {key, _run} -> key end, fn {_key, run} -> run end)

    for {{source_id, definition_id, environment, instance_id} = _key, partition_runs} <-
          partitions,
        group <- critical_groups(partition_runs) do
      instance = instance_id && Enum.find(instances, &(&1["id"] == instance_id))

      group
      |> Map.put(:kind, "pipeline")
      |> Map.put(:source_id, source_id)
      |> Map.put(:definition_id, definition_id)
      |> Map.put(:environment, environment)
      |> Map.put(:service_instance_id, instance_id)
      |> Map.put(:target, instance && instance["target"])
    end
  end

  defp critical_groups(runs) do
    runs |> pipeline_health() |> Enum.filter(&(&1.level == "critical"))
  end

  # Each partition key is the run's ACTUAL deployment target as retained by
  # pipeline_prediction_rows/1 — never a name/environment lookup that would
  # collapse same-named instances in distinct clusters onto the first match.
  # The target's service names the partition's pipeline; runs with no targets
  # get one explicitly unscoped source+definition partition.
  defp pipeline_keys(%{"source_id" => source_id, "definition_id" => definition_id} = run) do
    case run["targets"] do
      [] ->
        [{{source_id, definition_id, nil, nil}, run["service"]}]

      targets ->
        for target <- targets do
          {{source_id, definition_id, target["environment"], target["target_id"]},
           target["service"]}
        end
    end
  end

  # A partition's runs carry the target's service and environment, so the
  # shared pipeline_health/1 groups and labels them under the real target.
  defp scoped_run(run, {_source_id, _definition_id, nil, nil}, _service), do: run

  defp scoped_run(run, {_source_id, _definition_id, environment, _instance_id}, service) do
    run
    |> Map.put("service", service)
    |> Map.put("environments", [environment])
  end

  # ---------------------------------------------------------------------------
  # Storage: low free space, abnormal growth, projected time to full
  # ---------------------------------------------------------------------------

  @doc """
  Worst-first saturation risks from normalized Sources.count_series/1 output,
  analyzed with the shared analyze_growth/3 helper in the signal's own count
  unit ("connections"). Unverified limits and mixed identities stay unknown —
  never healthy.
  """
  def count_risks(series, services_by_id) do
    series
    |> Enum.flat_map(fn entry ->
      # the unit alone never establishes semantics: only a config-classified
      # "connections" profile gets connection labels; anything else is a
      # generic count signal
      unit = if(entry["signal"] == "connections", do: "connections", else: "count")

      growth =
        analyze_growth(
          Map.take(entry, ["history", "fresh_hours", "mixed_identities"]),
          entry["limit"],
          unit
        )

      case growth do
        nil ->
          []

        g ->
          service = services_by_id[entry["service_id"]] || %{}

          [
            Map.merge(g, %{
              volume: entry["volume"],
              signal: entry["signal"],
              service: service["service_key"],
              environment: service["environment"],
              target: service["target"],
              service_instance_id: entry["service_id"],
              source_id: entry["source_id"],
              fresh_hours: entry["fresh_hours"]
            })
          ]
      end
    end)
    |> Enum.sort_by(&{rank(&1.level), &1.hours_to_full || 1.0e9})
  end

  @doc """
  Worst-first memory working-set risks from classified Sources.memory_series/1
  output, analyzed with the shared analyze_growth/3 helper in GiB (values and
  verified byte limits both converted the same way). Classified memory is
  never labeled storage; unclassified or unverified stays unknown.
  """
  def memory_risks(series, services_by_id) do
    series
    |> Enum.flat_map(fn entry ->
      # the classified bytes series converts like storage: GiB values against
      # a GiB limit, fed to the shared helper as generic value points
      series_points = %{
        "history" =>
          Enum.map(
            entry["history"],
            &%{"hours_ago" => &1["hours_ago"], "value" => &1["used_gib"]}
          ),
        "fresh_hours" => entry["fresh_hours"],
        "mixed_identities" => entry["mixed_identities"] == true
      }

      case analyze_growth(series_points, entry["size_gib"], "GiB") do
        nil ->
          []

        g ->
          service = services_by_id[entry["service_id"]] || %{}

          [
            Map.merge(g, %{
              volume: entry["volume"],
              signal: "memory_working_set",
              service: service["service_key"],
              environment: service["environment"],
              target: service["target"],
              service_instance_id: entry["service_id"],
              source_id: entry["source_id"],
              fresh_hours: entry["fresh_hours"]
            })
          ]
      end
    end)
    |> Enum.sort_by(&{rank(&1.level), &1.hours_to_full || 1.0e9})
  end

  @doc "Worst-first storage risks from normalized `Sources.storage_series/1` output."
  def storage_risks(series, services_by_id) do
    series
    |> Enum.flat_map(fn entry ->
      case storage_risk(entry, services_by_id[entry["service_id"]]) do
        nil -> []
        risk -> [risk]
      end
    end)
    |> Enum.sort_by(&{rank(&1.level), &1.hours_to_full || 1.0e9})
  end

  defp storage_risk(%{} = entry, service) do
    service = service || %{}

    case analyze_storage(entry) do
      nil ->
        nil

      analysis ->
        Map.merge(analysis, %{
          volume: entry["volume"],
          service: service["service_key"],
          environment: service["environment"],
          target: service["target"],
          service_instance_id: entry["service_id"],
          source_id: entry["source_id"],
          fresh_hours: entry["fresh_hours"]
        })
    end
  end

  defp storage_risk(_, _), do: nil

  @doc """
  Analyze `%{"size_gib", "history" => [{"hours_ago", "used_gib"}]}`.

  Storage-specific wording over the shared `analyze_growth/3` saturation
  analysis: the level, rates, abnormal-jump and unknown semantics are exactly
  the growth helper's; an unverified size keeps the pinned storage reason
  "volume size not verified" in place of the helper's generic wording.
  """
  def analyze_storage(%{"history" => history} = entry) when is_list(history) do
    series = %{
      "history" =>
        Enum.map(history, &%{"hours_ago" => &1["hours_ago"], "value" => &1["used_gib"]}),
      "fresh_hours" => entry["fresh_hours"],
      "mixed_identities" => entry["mixed_identities"] == true
    }

    case analyze_growth(series, entry["size_gib"], "GiB") do
      nil ->
        nil

      g ->
        base = %{
          level: g.level,
          used_gib: g.value,
          size_gib: g.limit,
          used_percent: g.percent,
          recent_rate: g.recent_rate,
          baseline_rate: g.baseline_rate,
          abnormal: g.abnormal,
          hours_to_full: g.hours_to_full,
          reasons: g.reasons,
          history: g.history
        }

        if g.reasons == ["verified limit unavailable"],
          do: %{base | reasons: ["volume size not verified"]},
          else: base
    end
  end

  def analyze_storage(_), do: nil

  @doc """
  Shared pure saturation analysis: `analyze_growth(series, limit, unit)`.

      series: `{"history" => [{"hours_ago" => n, "value" => n}],
                "fresh_hours" => n | nil, "mixed_identities" => true?}`
      limit:  the verified limit in the same unit as the values, or nil
      unit:   the value's unit label ("GiB", "connections", ...)

  Semantics (identical to the approved storage analysis): samples that cannot
  be attributed to one series/source identity are unknown; a missing or
  unverified limit is never healthy (level "unknown", reason "verified limit
  unavailable" — storage keeps its pinned wording); rates are claimed only
  from at least two distinct times in the recent window; a missing baseline
  claims nothing; usage older than the stale bound or a single sample
  supports no forecast, so low usage becomes "unknown", never "ok"; a
  relative drop greater than 5% resets the analyzed segment; growth is
  abnormal when the measured recent rate is at least the configured factor
  over the measured baseline. The thresholds map (Task 2.1) governs every
  comparison; the minimum abnormal rate floor applies in value units per
  hour.
  """
  def analyze_growth(%{"mixed_identities" => true}, _limit, _unit) do
    %{
      level: "unknown",
      value: nil,
      limit: nil,
      percent: nil,
      recent_rate: nil,
      baseline_rate: nil,
      abnormal: false,
      hours_to_full: nil,
      reasons: [
        "usage samples cannot be attributed to one series or source identity — no single volume history"
      ],
      history: [],
      unit: nil
    }
  end

  def analyze_growth(%{"history" => history} = _series, nil, unit) when is_list(history) do
    samples = Enum.sort_by(history, &(-&1["hours_ago"]))
    latest = List.last(samples)

    %{
      level: "unknown",
      value: latest && latest["value"],
      limit: nil,
      percent: nil,
      recent_rate: nil,
      baseline_rate: nil,
      abnormal: false,
      hours_to_full: nil,
      reasons: ["verified limit unavailable"],
      history: Enum.map(samples, & &1["value"]),
      unit: unit
    }
  end

  def analyze_growth(%{"history" => history} = series, limit, unit)
      when is_number(limit) and limit > 0 and is_list(history) do
    samples = Enum.sort_by(history, &(-&1["hours_ago"]))

    if samples == [] do
      nil
    else
      growth_samples(samples, limit, series["fresh_hours"], unit)
    end
  end

  def analyze_growth(_, _, _), do: nil

  defp growth_samples(samples, limit, fresh_hours, unit) do
    t = thresholds().storage
    {segment, reset?} = drop_segment(samples)

    base =
      if projectable?(segment, fresh_hours, t) do
        measured_analysis(segment, limit, t, unit)
      else
        unprojected_analysis(segment, limit, fresh_hours, t, unit)
      end

    # The sparkline keeps the full retained history; rates describe the segment.
    analysis = Map.put(base, :history, Enum.map(samples, & &1["value"]))

    if reset? do
      Map.update!(analysis, :reasons, &["usage dropped (cleanup/resize) — history reset" | &1])
    else
      analysis
    end
  end

  # A relative drop in the measured value greater than 5% between consecutive
  # samples marks a segment reset (cleanup or resize): only samples after the
  # LAST such drop describe the current growth regime, and the reset is
  # explained in the reasons. The drop is measured against the previous value
  # (prev > 0) — never against the configured limit.
  defp drop_segment(samples) do
    reset_index =
      samples
      |> Enum.chunk_every(2, 1, :discard)
      |> Enum.with_index()
      |> Enum.filter(fn {[prev, curr], _i} -> relative_drop?(prev, curr) end)
      |> Enum.map(fn {_pair, i} -> i + 1 end)
      |> List.last()

    case reset_index do
      nil -> {samples, false}
      index -> {Enum.drop(samples, index), true}
    end
  end

  defp relative_drop?(%{"value" => prev_used}, %{"value" => curr_used})
       when is_number(prev_used) and is_number(curr_used) and prev_used > 0,
       do: prev_used - curr_used > 0.05 * prev_used

  defp relative_drop?(_, _), do: false

  # A growth forecast needs a current-enough history and at least two
  # distinct times inside the recent window; older data or thin recent history
  # cannot support a rate claim.
  defp projectable?(samples, fresh_hours, t) do
    length(samples) >= 2 and not (is_number(fresh_hours) and fresh_hours > @stale_hours) and
      distinct_times(recent_window(samples, t.recent_window_hours)) >= 2
  end

  defp recent_window(samples, hours), do: Enum.filter(samples, &(&1["hours_ago"] <= hours))

  defp distinct_times(samples),
    do: samples |> Enum.map(& &1["hours_ago"]) |> Enum.uniq() |> length()

  # No confident forecast: observed usage stays factual (a high percentage is
  # still a warning), but thin or stale history never yields a measured
  # "normal" rate or a healthy level.
  defp unprojected_analysis(samples, limit, fresh_hours, t, unit) do
    latest = List.last(samples)
    value = latest["value"]
    pct = value / limit * 100

    level =
      cond do
        pct >= t.crit_pct -> "critical"
        pct >= t.warn_pct -> "warning"
        true -> "unknown"
      end

    reasons =
      [
        pct >= t.warn_pct && "#{round(pct)}% used, #{fmt(limit - value)} #{unit} free",
        (is_number(fresh_hours) and fresh_hours > @stale_hours) &&
          "usage history is #{fmt(fresh_hours)} h old — growth not projected",
        (length(samples) < 2 or
           distinct_times(recent_window(samples, t.recent_window_hours)) < 2) &&
          "insufficient history for a growth forecast"
      ]
      |> Enum.filter(& &1)

    %{
      level: level,
      value: value,
      limit: limit,
      percent: pct,
      recent_rate: nil,
      baseline_rate: nil,
      abnormal: false,
      hours_to_full: nil,
      reasons: if(reasons == [], do: ["growth not projected from this history"], else: reasons),
      unit: unit
    }
  end

  defp measured_analysis(samples, limit, t, unit) do
    latest = List.last(samples)
    value = latest["value"]
    recent = measured_rate(recent_window(samples, t.recent_window_hours))

    baseline =
      measured_rate(Enum.filter(samples, &(&1["hours_ago"] >= t.recent_window_hours)))

    pct = value / limit * 100
    hours = if is_number(recent) and recent > 0, do: (limit - value) / recent

    # A measured flat baseline still flags jumps; a missing baseline claims nothing.
    abnormal =
      is_number(recent) and recent > t.min_abnormal_rate_gib_h and jumped?(recent, baseline, t)

    level =
      cond do
        pct >= t.crit_pct or (is_number(hours) and hours < t.crit_hours) ->
          "critical"

        pct >= t.warn_pct or (is_number(hours) and hours < t.warn_hours) or abnormal ->
          "warning"

        is_number(baseline) ->
          "ok"

        true ->
          "unknown"
      end

    reasons =
      [
        pct >= t.warn_pct && "#{round(pct)}% used, #{fmt(limit - value)} #{unit} free",
        abnormal &&
          "growth jumped to #{fmt(recent)} #{unit}/h (baseline #{fmt(baseline)} #{unit}/h, #{growth_factor(recent, baseline)})",
        (is_number(hours) and hours < t.warn_hours) &&
          "full in ~#{fmt_hours(hours)} at the current rate"
      ]
      |> Enum.filter(& &1)

    %{
      level: level,
      value: value,
      limit: limit,
      percent: pct,
      recent_rate: recent,
      baseline_rate: baseline,
      abnormal: abnormal,
      hours_to_full: hours,
      reasons:
        cond do
          reasons != [] ->
            reasons

          is_number(baseline) ->
            ["growth within normal range"]

          true ->
            ["recent growth #{fmt(recent)} #{unit}/h measured; no baseline history to compare"]
        end,
      unit: unit
    }
  end

  # A rate is only claimed from at least two distinct times in its window.
  defp measured_rate(window) do
    if distinct_times(window) >= 2, do: slope(window), else: nil
  end

  defp jumped?(_recent, nil, _t), do: false

  defp jumped?(recent, baseline, t),
    do: baseline <= 0.01 or recent / max(baseline, 0.01) >= t.abnormal_factor

  # Least-squares (OLS) slope over the window's actual time points (values per
  # hour): every sample weighs in equally, which reduces the influence of any
  # single endpoint glitch compared with a two-point difference — though OLS
  # is not an outlier-resistant estimator. With two points it degenerates to
  # the exact endpoint rate.
  defp slope(window) do
    n = length(window)

    if n >= 2 do
      xs = Enum.map(window, &(-&1["hours_ago"]))
      ys = Enum.map(window, & &1["value"])
      x_mean = Enum.sum(xs) / n
      y_mean = Enum.sum(ys) / n

      numerator =
        xs
        |> Enum.zip_with(ys, fn x, y -> (x - x_mean) * (y - y_mean) end)
        |> Enum.sum()

      denominator = Enum.sum(Enum.map(xs, fn x -> (x - x_mean) * (x - x_mean) end))

      if denominator > 0, do: numerator / denominator, else: 0.0
    else
      0.0
    end
  end

  defp growth_factor(_recent, baseline) when baseline <= 0.01, do: "previously flat"
  defp growth_factor(recent, baseline), do: "#{round(recent / baseline)}x normal"

  # Normalized completed outcome: an explicit non-completed status (notStarted,
  # inProgress, postponed, cancelling) is unknown even when a residual result
  # string is present; runs without a status (legacy fixtures) fall back to the
  # result alone, as documented.
  def run_outcome(%{"status" => status}) when status in @non_completed, do: "unknown"

  def run_outcome(%{"result" => result}), do: result || "unknown"

  # Deployment environments covered by the group (from deployment evidence on
  # the runs); CI-only groups have none. Predictions persist one finding per
  # environment so recovery on one target never moves another's.
  defp group_environments(runs) do
    runs
    |> Enum.flat_map(&(&1["environments"] || []))
    |> Enum.uniq()
    |> Enum.sort()
  end

  # Adjacent result changes inside the window; unfinished, unrecognized or
  # malformed results never count as a change.
  defp result_changes(results) do
    results
    |> Enum.zip(Enum.drop(results, 1))
    |> Enum.count(fn {a, b} -> a in @known_results and b in @known_results and a != b end)
  end

  # Median run duration of the last five and the previous five runs. A half
  # with fewer than two timed runs stays unknown — no fabricated medians.
  defp duration_medians(recent) do
    durations = Enum.map(recent, & &1["duration_seconds"])
    {median(Enum.take(durations, 5)), median(Enum.slice(durations, 5, 5))}
  end

  defp median(values) do
    values = values |> Enum.filter(&is_number/1) |> Enum.sort()
    n = length(values)

    cond do
      n < 2 -> nil
      rem(n, 2) == 1 -> Enum.at(values, div(n, 2))
      true -> (Enum.at(values, div(n, 2) - 1) + Enum.at(values, div(n, 2))) / 2
    end
  end

  # The trend flags when the last-five median is at least 1.5x the previous
  # five; a missing or non-positive baseline claims nothing.
  defp duration_ratio(nil, _), do: nil

  defp duration_ratio(_, nil), do: nil

  defp duration_ratio(last5, prev5) when is_number(prev5) and prev5 > 0,
    do: if(last5 / prev5 >= @duration_slowdown, do: last5 / prev5)

  defp duration_ratio(_, _), do: nil

  # ---------------------------------------------------------------------------
  # Blind spots and attention
  # ---------------------------------------------------------------------------

  def blind_spots(sources) do
    Enum.filter(sources, fn s ->
      s["freshness"] in ["stale", "not_configured_or_unavailable"] or s["error"] not in [nil, ""]
    end)
  end

  @doc "Ranked list of things that need a human now, one entry per affected target."
  def attention(
        groups,
        windows,
        services_by_id,
        resources,
        pipelines,
        evaluations \\ [],
        provenance \\ nil
      ) do
    # finding provenance resolves against the full authorized identity set;
    # other attributions use the caller's (possibly filtered) services
    provenance = provenance || services_by_id

    finding_items =
      groups
      |> Enum.reject(&(&1["status"] in @closed_statuses or &1["status"] == "quiet"))
      |> Enum.map(fn g ->
        {service, environment} = finding_target(g["data"], provenance)

        %{
          level: severity_level(g["severity"]),
          kind: "Finding",
          title: g["data"]["template"] || "Finding",
          detail: g["data"]["reason"],
          service: service,
          environment: environment,
          group_id: g["id"],
          status: g["status"],
          owner: g["owner"],
          since: g["first_seen"]
        }
      end)

    finding_targets = MapSet.new(finding_items, &{&1.service, &1.environment})

    window_items =
      windows
      |> Enum.filter(
        &(&1["kind"] == "metric" and &1["data"]["condition"] in ["critical", "warning"])
      )
      |> Enum.flat_map(fn w ->
        s = services_by_id[w["service_id"]] || %{}
        key = {s["service_key"], s["environment"]}

        if MapSet.member?(finding_targets, key),
          do: [],
          else: [
            %{
              level: w["data"]["condition"],
              kind: "Condition",
              title: "#{s["service_key"]} reported #{w["data"]["condition"]}",
              detail: w["data"]["missing"] || "Observed condition without an open finding",
              service: s["service_key"],
              environment: s["environment"],
              status: nil,
              owner: nil,
              since: w["window_start"]
            }
          ]
      end)

    runtime_items = runtime_attention(resources)

    node_items =
      resources
      |> Enum.filter(&(&1["kind"] == "Node" and &1["status"] != "Ready"))
      |> Enum.map(fn n ->
        %{
          level: "warning",
          kind: "Node",
          title: "#{n["name"]} is #{n["status"]}",
          detail: "Pods scheduled here may be evicted; check disk usage and image cache",
          service: nil,
          environment: n["environment"],
          status: nil,
          owner: nil,
          since: nil
        }
      end)

    database_items =
      resources
      |> Enum.filter(&(&1["kind"] == "Database"))
      |> Enum.flat_map(fn d ->
        details = d["details"] || %{}
        conn = details["connections"]
        max = details["max_connections"]

        if is_number(conn) and is_number(max) and max > 0 and conn / max >= 0.9,
          do: [
            %{
              level: if(conn / max >= 0.97, do: "critical", else: "warning"),
              kind: "Database",
              title: "#{d["name"]} connections #{conn}/#{max}",
              detail: "New connections will be refused once the limit is reached",
              service: nil,
              environment: d["environment"],
              status: nil,
              owner: nil,
              since: nil
            }
          ],
          else: []
      end)

    pipeline_items =
      pipelines
      |> Enum.filter(&(&1.level == "critical"))
      |> Enum.map(fn p ->
        %{
          level: "warning",
          kind: "Pipeline",
          title: "#{p.name} pipeline is failing",
          detail: p.reason,
          service: p.name,
          environment: nil,
          status: nil,
          owner: nil,
          since: p.last_run["finish_at"]
        }
      end)

    evaluation_items =
      evaluations
      |> Enum.filter(&(&1["result"]["condition"] in ["critical", "warning"]))
      |> Enum.map(fn e ->
        %{
          level: e["result"]["condition"],
          kind: "Capacity",
          title: "#{e["service_key"] || "Unmapped"} capacity #{e["result"]["condition"]}",
          detail: e["result"]["reason"],
          service: e["service_key"],
          environment: e["environment"],
          status: nil,
          owner: nil,
          since: e["occurred_at"]
        }
      end)

    (finding_items ++
       window_items ++
       database_items ++
       runtime_items ++
       evaluation_items ++
       node_items ++
       pipeline_items)
    |> Enum.sort_by(&{rank(&1.level), env_rank(&1.environment)})
  end

  # Runtime objects must belong to the selected instance: same cluster and
  # environment, and real collector objects — which carry their attributed
  # instance id — must match that very instance, so prod/staging namesakes on
  # one cluster never leak across pages.
  defp matches_instance?(r, instance) do
    r["cluster"] == cluster(instance["target"]) and
      r["environment"] in [nil, instance["environment"]] and
      r["service_id"] in [nil, instance["id"]]
  end

  # Real runtime anomalies surface as attention: unhealthy pods, warning
  # events and degraded workloads, grouped per attention scope so one incident
  # stays one item. Degraded workloads are suppressed only within the same
  # scope as already-flagged pods; nothing healthy is ever fabricated.
  defp runtime_attention(resources) do
    abnormal_pods =
      Enum.filter(
        resources,
        &(&1["kind"] == "Pod" and is_binary(&1["status"]) and
            &1["status"] not in ["Running", "Succeeded"])
      )

    pod_items =
      abnormal_pods
      |> Enum.group_by(&{attention_scope(&1), &1["status"]})
      |> Enum.map(fn {{scope, status}, pods} ->
        {service, environment, cluster} = scope_fields(scope)

        %{
          level: if(status == "OOMKilled", do: "critical", else: "warning"),
          kind: "Pod",
          title: "#{runtime_prefix(service, cluster)}: pods #{status}",
          detail: "#{length(pods)} retained pod(s) report #{status}",
          service: service,
          environment: environment,
          status: nil,
          owner: nil,
          since: nil
        }
      end)

    flagged = MapSet.new(abnormal_pods, &attention_scope/1)

    event_items =
      resources
      |> Enum.filter(&(&1["kind"] == "Event" and &1["status"] == "Warning"))
      |> Enum.group_by(&{attention_scope(&1), &1["details"]["reason"]})
      |> Enum.map(fn {{scope, reason}, events} ->
        {service, environment, cluster} = scope_fields(scope)

        count =
          events |> Enum.map(& &1["details"]["count"]) |> Enum.filter(&is_number/1) |> Enum.sum()

        %{
          level: "warning",
          kind: "Event",
          title: "#{runtime_prefix(service, cluster)}: Warning events",
          detail: "#{reason || "unspecified"} ×#{count} on retained runtime objects",
          service: service,
          environment: environment,
          status: nil,
          owner: nil,
          since: nil
        }
      end)

    workload_items =
      resources
      |> Enum.filter(&(&1["kind"] in ["Deployment", "ReplicaSet"] and &1["status"] == "Degraded"))
      |> Enum.reject(&MapSet.member?(flagged, attention_scope(&1)))
      |> Enum.group_by(&attention_scope/1)
      |> Enum.map(fn {scope, workloads} ->
        {service, environment, cluster} = scope_fields(scope)

        %{
          level: "warning",
          kind: "Workload",
          title: "#{runtime_prefix(service, cluster)}: workloads degraded",
          detail:
            Enum.map_join(workloads, ", ", fn w ->
              "#{w["name"]} #{w["details"]["readyReplicas"]}/#{w["details"]["replicas"]} ready"
            end),
          service: service,
          environment: environment,
          status: nil,
          owner: nil,
          since: nil
        }
      end)

    pod_items ++ event_items ++ workload_items
  end

  # Attributed objects group per service and environment. Unattributed ones
  # group per trusted location (cluster/environment) and collector source —
  # never a global nil bucket, so unrelated sources never merge or suppress
  # each other.
  defp attention_scope(%{"service" => service} = r) when is_binary(service),
    do: {:service, service, r["environment"]}

  defp attention_scope(r),
    do: {:unattributed, r["cluster"], r["environment"], r["source_id"]}

  defp scope_fields({:service, service, environment}), do: {service, environment, nil}

  defp scope_fields({:unattributed, cluster, environment, _source}),
    do: {nil, environment, cluster}

  defp runtime_prefix(service, _cluster) when is_binary(service), do: service
  defp runtime_prefix(_, cluster) when is_binary(cluster), do: cluster
  defp runtime_prefix(_, _), do: "unmapped"

  # Finding provenance resolves against the FULL authorized identity set.
  # A worker-created prediction carries its exact structured target: the
  # instance must exist and its real environment must agree with the claim;
  # an explicit nil target (CI-only) or a disagreement stays unknown. A
  # legacy scope matches by exact cluster segment — substring inference
  # cannot resolve cluster-prefix collisions — and an ambiguous or missing
  # mapping (same cluster and key across environments) stays unknown, so
  # ambiguous findings never appear in a selected environment view.
  defp finding_target(%{"prediction_target" => %{} = target}, provenance) do
    case provenance[target["service_instance_id"]] do
      %{"environment" => env, "service_key" => service_key} ->
        if env == target["environment"], do: {service_key, env}, else: {nil, nil}

      _ ->
        {nil, nil}
    end
  end

  defp finding_target(%{"prediction_target" => _}, _provenance), do: {nil, nil}

  defp finding_target(%{"scope" => scope}, provenance) when is_binary(scope) do
    parts = String.split(scope, "/")
    service = List.last(parts)
    scope_cluster = hd(parts)

    environments =
      provenance
      |> Map.values()
      |> Enum.filter(&(&1["service_key"] == service and cluster(&1["target"]) == scope_cluster))
      |> Enum.map(& &1["environment"])
      |> Enum.uniq()

    case environments do
      [env] -> {service, env}
      _ -> {service, nil}
    end
  end

  defp finding_target(_, _provenance), do: {nil, nil}

  defp severity_level("critical"), do: "critical"
  defp severity_level(_), do: "warning"

  # ---------------------------------------------------------------------------
  # Troubleshooting helpers
  # ---------------------------------------------------------------------------

  defp timeline(runs, findings, resources) do
    run_events =
      runs
      |> Enum.take(8)
      |> Enum.map(fn r ->
        %{
          at: r["finish_at"],
          kind: "Pipeline",
          level: result_level(r["result"]),
          text: "Run ##{r["run_id"]} #{r["result"]}"
        }
      end)

    fact_events =
      Enum.flat_map(findings, fn f ->
        for t <- get_in(f, ["correlation", "timeline"]) || [] do
          %{
            at: parse_time(t["at"]),
            kind: t["kind"] |> to_string() |> String.replace("_", " "),
            level: severity_level(f["severity"]),
            text: t["summary"]
          }
        end
      end)

    k8s_events =
      resources
      |> Enum.filter(&(&1["kind"] == "Event" and &1["status"] == "Warning"))
      |> Enum.map(fn e ->
        %{
          at: parse_time(e["snapshot_at"]),
          kind: "Kubernetes event",
          level: "warning",
          text:
            "#{e["details"]["reason"]} ×#{e["details"]["count"]} on #{e["details"]["involvedObject"]}"
        }
      end)

    (run_events ++ fact_events ++ k8s_events)
    |> Enum.reject(&is_nil(&1.at))
    |> Enum.sort_by(& &1.at, {:desc, DateTime})
  end

  defp coverage(sources, cluster) do
    Enum.filter(sources, fn s ->
      String.contains?(s["name"] || "", cluster) or s["kind"] == "azure_build"
    end)
  end

  @doc "Concrete next checks derived from the signals present."
  def checks(findings, resources, storage, pipelines, metric, database, counts \\ []) do
    statuses = MapSet.new(resources, & &1["status"])
    pipeline = List.first(pipelines)
    details = (database || %{})["details"] || %{}

    [
      findings != [] and
        "Read the hypothesis and counter-evidence below before acting; confirm or rule out the recent change.",
      MapSet.member?(statuses, "OOMKilled") and
        "Pods are OOMKilled: compare container memory limit with working set; check what the latest release loads at start-up.",
      MapSet.member?(statuses, "ImagePullBackOff") and
        "Image pull fails: verify the image tag/repository path pushed by the last pipeline and the pull secret permissions.",
      MapSet.member?(statuses, "ReadinessFailed") and
        "Readiness probe failing: check the probe endpoint dependencies (DB, downstream APIs) and the config diff of the last deploy.",
      is_number(details["connections"]) and is_number(details["max_connections"]) and
        details["connections"] / max(details["max_connections"], 1) >= 0.9 and
        "Database #{database["name"]} is at #{details["connections"]}/#{details["max_connections"]} connections: check pool size × replica count.",
      storage && storage.abnormal &&
        "Storage growth is abnormal: find the largest recently grown tables/files and the job that writes them; check retention.",
      storage && storage.hours_to_full &&
        storage.hours_to_full < thresholds().storage.warn_hours &&
        "Volume projected full in ~#{fmt_hours(storage.hours_to_full)}: plan a resize or cleanup now.",
      pipeline && pipeline.level != "ok" &&
        "Pipeline: #{pipeline.reason}. Open the latest failing run before the next deploy.",
      count_saturation_suggestion(counts),
      (is_map(metric) and is_number(metric["p95_latency_ms"]) and metric["p95_latency_ms"] > 1000) &&
        "p95 latency #{metric["p95_latency_ms"]} ms: correlate with the last deploy time in the timeline.",
      metric && metric["missing"] &&
        "Telemetry gap (#{metric["missing"]}): an absence of errors here is not evidence of health."
    ]
    |> Enum.filter(&is_binary/1)
  end

  # Measured, verified-limit saturation suggests the concrete operational
  # check for its classified signal; unknown or unclassified saturation
  # claims nothing beyond what the panels already show.
  defp count_saturation_suggestion(counts) do
    connections =
      Enum.find(counts, &(&1.level in ["warning", "critical"] and &1.signal == "connections"))

    memory =
      Enum.find(
        counts,
        &(&1.level in ["warning", "critical"] and &1.signal == "memory_working_set")
      )

    cond do
      connections ->
        "Connections at #{round(connections.value)}/#{round(connections.limit)} (#{round(connections.percent)}%) on #{connections.volume}: check pool size x replica count against the verified limit."

      memory ->
        "Pod memory working set at #{round(memory.percent)}% of the verified limit on #{memory.volume}: check container memory limits and what the process retains."

      true ->
        nil
    end
  end

  # ---------------------------------------------------------------------------
  # Formatting helpers shared with the views
  # ---------------------------------------------------------------------------

  def rank("critical"), do: 0
  def rank("warning"), do: 1
  def rank("unknown"), do: 2
  def rank(_), do: 3

  defp env_rank("prod"), do: 0
  defp env_rank("staging"), do: 1
  defp env_rank(_), do: 2

  def result_level(result) when result in @failed, do: "critical"
  def result_level(result) when result in @degraded, do: "warning"
  def result_level("succeeded"), do: "ok"
  def result_level(_), do: "unknown"

  def cluster(target) when is_binary(target), do: target |> String.split("/") |> hd()
  def cluster(_), do: ""

  def fmt(n) when is_number(n), do: :erlang.float_to_binary(n * 1.0, decimals: 1)
  def fmt(_), do: "—"

  # Unknown numbers render as an explicit "unknown", never as healthy zeros.
  def fmt_size(n) when is_number(n), do: fmt(n)
  def fmt_size(_), do: "unknown"

  def fmt_percent(n) when is_number(n), do: "#{round(n)}%"
  def fmt_percent(_), do: "unknown"

  def fmt_hours(h) when is_number(h) and h < 48, do: "#{fmt(h)} h"
  def fmt_hours(h) when is_number(h), do: "#{fmt(h / 24)} days"
  def fmt_hours(_), do: "not projected"

  # Slowdown multiples keep one decimal so a 1.5x trend is not inflated to 2x.
  def fmt_times(ratio) when is_number(ratio),
    do: :erlang.float_to_binary(max(Float.round(ratio, 1), 0.1), decimals: 1)

  defp parse_time(%DateTime{} = t), do: t

  defp parse_time(t) when is_binary(t) do
    case DateTime.from_iso8601(t) do
      {:ok, dt, _} -> dt
      _ -> nil
    end
  end

  defp parse_time(_), do: nil
end
