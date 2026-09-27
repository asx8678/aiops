defmodule OpsBrain.Insights.Sources do
  @moduledoc """
  Adapters that normalize retained collector data into the shapes
  `OpsBrain.Insights` analyzes, so the command center and troubleshoot pages
  read one normalized shape per signal no matter which collector stored it.

  Scope-internal like the other bounded row readers in `Insights`
  (`pipeline_rows/1`, `resource_rows/2`): every function must be called
  inside `Tenancy.with_scope/2` and never opens (or nests) its own scope.
  Queries are bounded and filtered in SQL, and malformed samples are dropped
  instead of crashing the page.

  Runtime objects (`resources/2`) are normalized from real
  `kubernetes_cursors` and demo `evidence_items` into one shape. Service
  attribution is evidence-driven only: the trusted `service_id` binding pins
  the environment and cluster for Deployment-name matches, and objects resolve
  through explicit name matches, owner UID chains (Pod→ReplicaSet→
  Deployment) and event target UIDs. Unresolved, ambiguous or foreign
  references stay unattributed rather than defaulting to the bound service, and
  cursors whose scope, freshness or coverage state is not current are never
  trusted.

  Identity rules: a series is built only from samples that share one
  `(source, series digest)` identity and carry a binary digest. A
  service/profile group that received samples from more than one identity
  (several vector series, a series digest change, or two sources scraping the
  same profile), or whose samples are not attributable (missing/non-binary
  digest), is conservatively marked `"mixed_identities" => true` with no
  numeric history, so `Insights` renders it as unknown instead of splicing a
  fabricated trajectory. A volume limit is trusted only from the source config
  of that same identity when it matches company, bound service and exact
  profile version with a verified bytes `capacity_policy`; one source's
  verified limit is never lent to another source's samples.
  """

  alias OpsBrain.{SourceConfig, Store}

  @gib 1_073_741_824.0
  @window_hours 24
  @prometheus_limit 2000
  @demo_limit 500

  @doc """
  One normalized storage series per volume, newest history point `hours_ago: 0`.

      %{"volume" => name, "service_id" => uuid,
        "size_gib" => number | nil,
        "history" => [%{"hours_ago" => n, "used_gib" => n}],
        "fresh_hours" => number | nil,
        "mixed_identities" => true}          # only when samples cannot be attributed

  `hours_ago` is relative to the newest retained sample (so the newest point
  is always 0); `fresh_hours` is that sample's age relative to `now`, kept
  separately so stale histories cannot masquerade as current measurements.

  Real `kind='prometheus'` windows with `data.unit == "bytes"` from the last
  24 hours are grouped per service/profile and downsampled to the last sample
  of each hour, converted from bytes to GiB; future-dated, negative or
  non-numeric samples are ignored. A group whose samples span more than one
  `(source, series)` identity, or whose samples lack a binary series digest,
  is emitted with `"mixed_identities" => true`, empty history and no trusted
  limit. Demo-shaped `kind='capacity'` windows
  carrying `data.storage` pass through unchanged (their `fresh_hours` is 0:
  an offline snapshot's history is relative to its own window, and the
  scripted demo output must not decay into staleness). Duplicate volumes keep
  only the freshest series, real history winning over demo. The volume is
  named after the profile id; a missing, unverified or identity-mismatched
  limit stays `nil`.
  """
  def storage_series(now, service_id \\ nil, environment \\ "")

  def storage_series(now, service_id, environment) do
    # demo snapshots carry their service instance, so the selection applies
    # to them by the same identity join — in SQL before the demo cap; only
    # unmapped snapshots stay outside selected views
    (prometheus_series(now, service_id, environment) ++ demo_series(service_id, environment))
    |> dedupe()
    |> Enum.reject(&(&1[:signal] == "memory_working_set"))
    |> Enum.map(&series_entry/1)
    |> Enum.sort_by(&{&1["volume"], &1["service_id"]})
  end

  # Real collector series: Prometheus byte windows grouped per service and
  # profile (one volume per profile), downsampled to one point per hour. An
  # environment selection is applied in SQL before the bounded read, so newer
  # windows from other environments cannot push the selected environment's
  # history out of the cap.
  defp prometheus_series(now, service_id, environment) do
    since = DateTime.add(now, -@window_hours, :hour)

    rows =
      Store.rows(
        """
        SELECT id::text,company_id::text,source_id::text,service_id::text,profile,window_end,data
        FROM observation_windows
        WHERE kind='prometheus' AND data->>'unit'='bytes' AND service_id IS NOT NULL
          AND window_end > $1 AND window_end <= $2 AND received_at <= $2
          AND ($3::text IS NULL OR service_id=$3::text::uuid)
          AND ($4::text='' OR service_id IN (
            SELECT si.id FROM service_instances si
            JOIN environments en ON en.id=si.environment_id AND en.company_id=si.company_id
            WHERE en.name::text=$4
          ))
        ORDER BY window_end DESC,received_at DESC,id DESC
        LIMIT #{@prometheus_limit}
        """,
        [since, now, service_id, environment]
      )

    now_unix = DateTime.to_unix(now)
    cutoff = now_unix - @window_hours * 3600

    rows
    |> Enum.flat_map(&prometheus_samples(&1, now_unix, cutoff))
    |> Enum.group_by(&{&1.service_id, &1.profile})
    |> Enum.map(fn {{service_id, profile}, samples} ->
      prometheus_entry(service_id, profile, samples, now_unix)
    end)
  end

  # One entry per service/profile. A single (source, series) identity with a
  # binary digest yields a coherent history; anything else is emitted as an
  # unattributable unknown.
  defp prometheus_entry(service_id, profile, samples, now_unix) do
    newest = Enum.max_by(samples, & &1.timestamp).timestamp
    trusted = samples |> Enum.map(&{&1.company_id, &1.source_id}) |> Enum.uniq()

    base = %{
      real: true,
      service_id: service_id,
      volume: profile_volume(profile),
      latest: newest,
      mixed_identities: false,
      source_id: hd(samples).source_id,
      signal: classified_signal(trusted, service_id, profile)
    }

    identities = samples |> Enum.map(&{&1.source_id, &1.series}) |> Enum.uniq()

    # Samples without a binary digest are never coalesced into one supposedly
    # valid identity: unattributable samples yield an unknown, not a forecast.
    if length(identities) > 1 or not Enum.all?(samples, &is_binary(&1.series)) do
      Map.merge(base, %{
        size_gib: nil,
        history: [],
        fresh_hours: nil,
        mixed_identities: true
      })
    else
      [{source_id, _series}] = identities
      company_id = hd(samples).company_id

      Map.merge(base, %{
        size_gib: verified_size_gib(company_id, source_id, service_id, profile),
        history: downsample(samples, newest),
        fresh_hours: Float.round((now_unix - newest) / 3600, 2)
      })
    end
  end

  # One point per hour bucket, relative to the newest sample (its bucket is
  # always 0); within a bucket the last sample wins. Oldest point first.
  defp downsample(samples, newest) do
    samples
    |> Enum.group_by(&trunc((newest - &1.timestamp) / 3600))
    |> Enum.map(fn {hours_ago, bucket} ->
      last = Enum.max_by(bucket, & &1.timestamp)

      %{"hours_ago" => hours_ago, "used_gib" => last.value / @gib}
    end)
    |> Enum.sort_by(& &1["hours_ago"], :desc)
  end

  # Only well-formed, non-future samples inside the 24 h window feed a series;
  # the series digest is kept so identities are never silently merged.
  defp prometheus_samples(row, now_unix, cutoff) do
    case row["data"]["samples"] do
      samples when is_list(samples) ->
        for s <- samples,
            is_map(s),
            is_number(s["value"]),
            is_number(s["timestamp"]),
            s["value"] >= 0,
            s["timestamp"] >= cutoff,
            s["timestamp"] <= now_unix do
          %{
            company_id: row["company_id"],
            source_id: row["source_id"],
            service_id: row["service_id"],
            profile: row["profile"],
            series: s["series"],
            timestamp: s["timestamp"],
            value: s["value"]
          }
        end

      _ ->
        []
    end
  end

  # The limit is trusted only from the source config of the identity that
  # produced these samples when it matches company, bound service and exact
  # profile version with a verified bytes policy. Limits are never resolved
  # across sources: a verified source cannot lend its threshold to another
  # source's samples.
  defp verified_size_gib(company_id, source_id, service_id, profile) do
    with {:ok, c} <- SourceConfig.fetch(source_id),
         true <- c[:company_id] == company_id,
         true <- c[:service_id] == service_id,
         true <- profile_key(c[:profile]) == profile,
         %{:unit => "bytes", :limits_verified => true, :effective_threshold => threshold} <-
           get_in(c, [:profile, :capacity_policy]),
         true <- is_number(threshold) and threshold > 0 do
      threshold / @gib
    else
      _ -> nil
    end
  end

  defp profile_key(%{id: id, version: version}) when is_binary(id) and is_integer(version),
    do: "#{id}:v#{version}"

  defp profile_key(_), do: nil

  # Window profiles are "<profile id>:v<version>"; volumes are named after the
  # profile id, without introducing a new optional config key.
  defp profile_volume(profile) when is_binary(profile) do
    case Regex.run(~r/^(.*):v[0-9]+$/, profile) do
      [_, id] -> id
      _ -> profile
    end
  end

  defp profile_volume(_), do: nil

  @doc """
  Memory working-set series from bytes profiles explicitly classified as
  "memory_working_set" in the trusted source config. Values convert bytes to
  GiB (the verified bytes capacity_policy limit converts the same way);
  classified profiles are excluded from the storage series so a memory gauge
  is never double-labeled as a volume. Unclassified bytes profiles remain
  storage. Scope-internal like the other reads.
  """
  def memory_series(now, service_id \\ nil, environment \\ "")

  def memory_series(now, service_id, environment) do
    prometheus_series(now, service_id, environment)
    |> Enum.filter(&(&1[:signal] == "memory_working_set"))
    |> dedupe()
    |> Enum.map(&series_entry/1)
    |> Enum.sort_by(&{&1["volume"], &1["service_id"]})
  end

  @doc """
  Count-signal saturation series (e.g. database connections) from real
  Prometheus count profiles: `kind='prometheus'` windows with
  `data.unit == "count"` from the last 24 hours, grouped per service and
  profile, downsampled to the last sample of each hour (no unit conversion —
  values are raw counts) with the newest sample at `hours_ago: 0`. The
  verified limit comes only from the identity-matching source config's
  `capacity_policy` with `unit: "count"`, `limits_verified: true`
  and a positive `effective_threshold` in the same count unit; anything
  else keeps `"limit" => nil` so the analysis stays unknown — never
  healthy. Scope-internal like the storage reads; mixed series/source
  identities stay unattributable.
  """
  def count_series(now, service_id \\ nil, environment \\ "")

  def count_series(now, service_id, environment) do
    (prometheus_count_series(now, service_id, environment) ++ [])
    |> dedupe()
    |> Enum.map(&count_entry/1)
    |> Enum.sort_by(&{&1["volume"], &1["service_id"]})
  end

  defp prometheus_count_series(now, service_id, environment) do
    since = DateTime.add(now, -@window_hours, :hour)

    rows =
      Store.rows(
        """
        SELECT id::text,company_id::text,source_id::text,service_id::text,profile,window_end,data
        FROM observation_windows
        WHERE kind='prometheus' AND data->>'unit'='count' AND service_id IS NOT NULL
          AND window_end > $1 AND window_end <= $2 AND received_at <= $2
          AND ($3::text IS NULL OR service_id=$3::text::uuid)
          AND ($4::text='' OR service_id IN (
            SELECT si.id FROM service_instances si
            JOIN environments en ON en.id=si.environment_id AND en.company_id=si.company_id
            WHERE en.name::text=$4
          ))
        ORDER BY window_end DESC,received_at DESC,id DESC
        LIMIT #{@prometheus_limit}
        """,
        [since, now, service_id, environment]
      )

    now_unix = DateTime.to_unix(now)
    cutoff = now_unix - @window_hours * 3600

    rows
    |> Enum.flat_map(&prometheus_samples(&1, now_unix, cutoff))
    |> Enum.group_by(&{&1.service_id, &1.profile})
    |> Enum.map(fn {{service_id, profile}, samples} ->
      count_group(service_id, profile, samples, now_unix)
    end)
  end

  defp count_group(service_id, profile, samples, now_unix) do
    newest = Enum.max_by(samples, & &1.timestamp).timestamp
    trusted = samples |> Enum.map(&{&1.company_id, &1.source_id}) |> Enum.uniq()

    base = %{
      real: true,
      service_id: service_id,
      volume: profile_volume(profile),
      latest: newest,
      source_id: hd(samples).source_id,
      signal: classified_signal(trusted, service_id, profile)
    }

    identities = samples |> Enum.map(&{&1.source_id, &1.series}) |> Enum.uniq()

    # Samples without a binary digest are never coalesced into one supposedly
    # valid identity; identities disagreeing on the classification are
    # equally unattributable — never routed by row order.
    if conflicting_signal?(trusted, service_id, profile) or length(identities) > 1 or
         not Enum.all?(samples, &is_binary(&1.series)) do
      Map.merge(base, %{limit: nil, history: [], fresh_hours: nil, mixed_identities: true})
    else
      [{source_id, _series}] = identities
      company_id = hd(samples).company_id

      Map.merge(base, %{
        limit: verified_count_limit(company_id, source_id, service_id, profile),
        history: count_downsample(samples, newest),
        fresh_hours: Float.round((now_unix - newest) / 3600, 2),
        mixed_identities: false
      })
    end
  end

  # Trusted signal classification from the identity-matched source config: the
  # unit alone never establishes semantics, and profile names are never
  # parsed for meaning. When several trusted identities contribute to one
  # group and disagree on the classification, no signal is assigned — the
  # group is unattributable rather than routed by arbitrary row order.
  defp classified_signal(trusted, service_id, profile) do
    trusted
    |> Enum.flat_map(fn {company_id, source_id} ->
      case signal_from_config(company_id, source_id, service_id, profile) do
        nil -> []
        signal -> [signal]
      end
    end)
    |> Enum.uniq()
    |> case do
      [signal] -> signal
      _ -> nil
    end
  end

  # A disagreement between contributing identities (one calls the profile
  # connections, another memory_working_set) is a conflict, never an order
  # decision.
  defp conflicting_signal?(trusted, service_id, profile) do
    classifications =
      trusted
      |> Enum.flat_map(fn {company_id, source_id} ->
        case signal_from_config(company_id, source_id, service_id, profile) do
          nil -> []
          signal -> [signal]
        end
      end)
      |> Enum.uniq()

    length(classifications) > 1
  end

  defp signal_from_config(company_id, source_id, service_id, profile) do
    with {:ok, c} <- SourceConfig.fetch(source_id),
         true <- c[:company_id] == company_id,
         true <- c[:service_id] == service_id,
         true <- profile_key(c[:profile]) == profile,
         signal when signal in ~w(connections memory_working_set) <-
           c[:profile][:saturation_signal] do
      signal
    else
      _ -> nil
    end
  end

  # The count limit is trusted only when the identity-matching source config's
  # capacity_policy is explicitly a verified COUNT policy; a verified bytes
  # policy or an unverified one never lends a limit.
  defp verified_count_limit(company_id, source_id, service_id, profile) do
    with {:ok, c} <- SourceConfig.fetch(source_id),
         true <- c[:company_id] == company_id,
         true <- c[:service_id] == service_id,
         true <- profile_key(c[:profile]) == profile,
         %{:unit => "count", :limits_verified => true, :effective_threshold => threshold} <-
           get_in(c, [:profile, :capacity_policy]),
         true <- is_number(threshold) and threshold > 0 do
      threshold
    else
      _ -> nil
    end
  end

  # One point per hour bucket, relative to the newest sample (its bucket is
  # always 0); within a bucket the last sample wins. Raw counts — no unit
  # conversion — because the limit is a count too.
  defp count_downsample(samples, newest) do
    samples
    |> Enum.group_by(&trunc((newest - &1.timestamp) / 3600))
    |> Enum.map(fn {hours_ago, bucket} ->
      last = Enum.max_by(bucket, & &1.timestamp)
      %{"hours_ago" => hours_ago, "value" => last.value}
    end)
    |> Enum.sort_by(& &1["hours_ago"], :desc)
  end

  defp count_entry(entry) do
    %{
      "volume" => entry.volume,
      "service_id" => entry.service_id,
      "source_id" => Map.get(entry, :source_id),
      "limit" => entry.limit,
      "history" => entry.history,
      "fresh_hours" => entry.fresh_hours,
      "signal" => entry.signal
    }
    |> then(fn base ->
      if entry.mixed_identities, do: Map.put(base, "mixed_identities", true), else: base
    end)
  end

  # Demo-shaped series: the offline dataset seeds capacity windows carrying a
  # ready-made hourly history in data.storage. No time filter: demo windows are
  # static snapshots, so the newest window per volume is used as-is.
  defp demo_series(service_id, environment) do
    Store.rows(
      """
      SELECT id::text,service_id::text,profile,window_end,received_at,revision,data
      FROM observation_windows
      WHERE kind='capacity' AND data ? 'storage' AND service_id IS NOT NULL
        AND ($1::text IS NULL OR service_id=$1::text::uuid)
        AND ($2::text='' OR service_id IN (
          SELECT si.id FROM service_instances si
          JOIN environments en ON en.id=si.environment_id AND en.company_id=si.company_id
          WHERE en.name::text=$2
        ))
      ORDER BY window_end DESC,received_at DESC,revision DESC,id DESC
      LIMIT #{@demo_limit}
      """,
      [service_id, environment]
    )
    |> Enum.flat_map(fn
      %{"data" => %{"storage" => storage}} = row when is_map(storage) ->
        demo_entry(storage, row)

      _ ->
        []
    end)
  end

  defp demo_entry(storage, row) do
    history = normalize_history(storage["history"])

    if is_binary(storage["volume"]) and history != [] do
      [
        %{
          real: false,
          service_id: row["service_id"],
          volume: storage["volume"],
          latest: window_end_unix(row),
          size_gib: demo_size(storage["size_gib"]),
          history: history,
          # The demo snapshot's history is relative to its own window; keeping
          # it current preserves the scripted demo output instead of letting a
          # long-running demo decay into synthetic "staleness".
          fresh_hours: 0.0,
          mixed_identities: false
        }
      ]
    else
      []
    end
  end

  # The scripted demo declares its volume size; anything malformed is unknown.
  defp demo_size(size) when is_number(size) and size > 0, do: size
  defp demo_size(_), do: nil

  defp window_end_unix(%{"window_end" => %DateTime{} = window_end}),
    do: DateTime.to_unix(window_end)

  defp window_end_unix(_), do: 0

  # Keep only well-formed points, oldest first (newest hours_ago last).
  defp normalize_history(history) when is_list(history) do
    history
    |> Enum.filter(&valid_point?/1)
    |> Enum.sort_by(& &1["hours_ago"], :desc)
  end

  defp normalize_history(_), do: []

  defp valid_point?(point) do
    is_map(point) and is_number(point["hours_ago"]) and is_number(point["used_gib"]) and
      point["used_gib"] >= 0
  end

  # One series per volume and service: real history wins over demo, and the
  # freshest series wins when a volume was re-seeded or superseded.
  defp dedupe(entries) do
    entries
    |> Enum.sort_by(&{&1.real, &1.latest, &1.volume}, :desc)
    |> Enum.reduce(%{}, fn entry, acc ->
      Map.put_new(acc, {entry.service_id, entry.volume}, entry)
    end)
    |> Map.values()
  end

  defp series_entry(%{mixed_identities: true} = entry) do
    entry
    |> Map.put(:mixed_identities, false)
    |> series_entry()
    |> Map.put("mixed_identities", true)
  end

  defp series_entry(entry) do
    %{
      "volume" => entry.volume,
      "service_id" => entry.service_id,
      "source_id" => Map.get(entry, :source_id),
      "size_gib" => entry.size_gib,
      "history" => entry.history,
      "fresh_hours" => entry.fresh_hours
    }
  end

  # ---------------------------------------------------------------------------
  # Runtime objects: real kubernetes cursors + demo evidence, one shape
  # ---------------------------------------------------------------------------

  @cursor_limit 40

  @doc """
  Normalized runtime objects for the command center (`service_key == nil`) or
  one service's troubleshoot view, from real `kubernetes_cursors` and demo
  `evidence_items` (`kind='demo_resource'`).

  Real objects come only from cursors whose trusted source config still
  matches kind and company, the stored scope digest
  (endpoint/namespace/approved IPs/credential), whose last successful
  observation (`observed_at`) is neither in the future nor older than the
  collector's freshness bound (interval x resources x 3), and whose inventory
  is complete without gap or error — anything else is omitted rather than
  rendered as health. Service attribution: the trusted `service_id` binding
  pins the environment and cluster; Deployments are matched by name to a
  service instance in that scope, Pods follow the owner UID chain
  Pod->ReplicaSet->Deployment, and Events map via `target_uid`. Unresolved,
  ambiguous or foreign references stay unattributed (never guessed, never
  silently re-attributed to the bound service), and without a bound instance
  no location is inferred. Known limitation: collectors configured for pods only —
  or objects without a resolvable owner chain — remain unattributed and surface
  in command attention without a service link.
  """
  def resources(now, service_key \\ nil)

  def resources(now, service_key) do
    real = kubernetes_resources(now, service_key)
    real ++ reject_shadowed(demo_resources(now, service_key), real)
  end

  defp kubernetes_resources(now, service_key) do
    now_unix = DateTime.to_unix(now)

    rows =
      Store.rows(
        """
        SELECT source_id::text,company_id::text,resource,updated_at,data
        FROM kubernetes_cursors
        ORDER BY updated_at DESC
        LIMIT #{@cursor_limit}
        """,
        []
      )

    instances = service_instances()
    by_id = Map.new(instances, &{&1["id"], &1})
    by_key = Enum.group_by(instances, & &1["service_key"])

    rows
    |> Enum.group_by(& &1["source_id"])
    |> Enum.flat_map(fn {source_id, cursor_rows} ->
      cursor_resources(source_id, cursor_rows, now_unix, service_key, by_id, by_key)
    end)
  end

  # One source's objects: only current cursors for configured resources feed the
  # inventory, then every object is attributed and normalized. Without a usable
  # trusted config nothing is shown for that source.
  defp cursor_resources(source_id, cursor_rows, now_unix, service_key, by_id, by_key) do
    with {:ok, c} <- SourceConfig.fetch(source_id),
         true <- c[:kind] == "kubernetes",
         true <- c[:company_id] == company_id_of(cursor_rows),
         configured = c[:resources],
         true <- is_list(configured) do
      objects =
        cursor_rows
        |> Enum.flat_map(fn row ->
          if row["resource"] in configured and
               current_cursor?(c, configured, row["data"], now_unix) do
            [usable_objects(row["data"])]
          else
            []
          end
        end)
        |> Enum.reduce(%{}, &Map.merge/2)

      if objects == %{} do
        []
      else
        ctx = %{
          objects: objects,
          by_key: by_key,
          bound: by_id[c[:service_id]],
          namespace: c[:namespace],
          source_id: source_id
        }

        normalized = normalize_objects(objects, ctx)

        if service_key do
          Enum.filter(normalized, &(&1["service"] == service_key))
        else
          # The command center consumes node/database health and abnormal
          # runtime signals; healthy objects stay out of its bounded read.
          Enum.filter(normalized, fn r ->
            r["kind"] in ["Node", "Database"] or
              (r["kind"] == "Pod" and
                 r["status"] not in ["Running", "Succeeded"]) or
              (r["kind"] == "Event" and r["status"] == "Warning") or
              (r["kind"] in ["Deployment", "ReplicaSet"] and r["status"] == "Degraded")
          end)
        end
      end
    else
      _ -> []
    end
  end

  # Collector semantics: the scope digest pins endpoint/namespace/IPs/credential,
  # observed_at marks the last successful observation (never in the future),
  # gap/error flag holes in the stream, and partial inventories are incomplete
  # snapshots. Only complete, current cursors can show runtime state.
  defp current_cursor?(c, configured, data, now_unix)
       when is_map(data) do
    data["scope"] == cursor_scope(c) and data["gap"] != true and data["error"] in [nil, ""] and
      data["coverage"] == "complete" and is_integer(data["observed_at"]) and
      data["observed_at"] <= now_unix and
      now_unix - data["observed_at"] <= c[:interval_seconds] * max(length(configured), 1) * 3
  end

  defp current_cursor?(_, _, _, _), do: false

  defp cursor_scope(c),
    do: Store.digest({c[:endpoint], c[:namespace], c[:approved_ips], c[:credential_env]})

  defp usable_objects(data) do
    case data["objects"] do
      objects when is_map(objects) -> objects
      _ -> %{}
    end
  end

  @doc """
  Bounded service/environment index for attribution (id, service_key, target,
  environment). Scope-internal like the series readers: call inside an active
  company scope, never nested.
  """
  def service_instances do
    Store.rows("""
    SELECT s.id::text,s.service_key,s.target,e.name AS environment
    FROM service_instances s
    JOIN environments e ON e.id=s.environment_id AND e.company_id=s.company_id
    ORDER BY s.service_key,e.name LIMIT 100
    """)
  end

  defp normalize_objects(objects, ctx) do
    objects
    |> Enum.map(fn {_uid, obj} -> normalize_object(obj, ctx) end)
    |> Enum.filter(& &1)
  end

  defp normalize_object(%{"kind" => "Pod"} = obj, ctx) do
    containers = obj["containers"] || []

    restarts =
      containers
      |> Enum.map(&if(is_map(&1) and is_integer(&1["restarts"]), do: &1["restarts"], else: 0))
      |> Enum.sum()

    entry(
      "Pod",
      obj["uid"],
      obj["name"],
      pod_status(containers, obj),
      pod_instance(obj, ctx),
      ctx,
      %{"restartCount" => restarts}
    )
  end

  defp normalize_object(%{"kind" => kind} = obj, ctx)
       when kind in ["Deployment", "ReplicaSet"] do
    entry(
      kind,
      obj["uid"],
      obj["name"],
      workload_status(obj),
      chain_instance(kind, obj, ctx),
      ctx,
      %{"replicas" => obj["replicas"], "readyReplicas" => obj["ready_replicas"]}
    )
  end

  defp normalize_object(%{"kind" => "Event"} = obj, ctx) do
    entry(
      "Event",
      obj["uid"],
      obj["name"],
      obj["type"],
      event_instance(obj, ctx),
      ctx,
      %{"reason" => obj["reason"], "count" => obj["count"]}
    )
  end

  defp normalize_object(_, _), do: nil

  # Pod status: the first restarted container's termination reason (e.g.
  # OOMKilled), else Running when ready, else the reported phase, else NotReady.
  defp pod_status(containers, obj) do
    reason =
      Enum.find_value(containers, fn c ->
        if is_map(c) and is_integer(c["restarts"]) and c["restarts"] > 0 and
             is_binary(get_in(c, ["termination", "reason"])) and
             get_in(c, ["termination", "reason"]) != "" do
          get_in(c, ["termination", "reason"])
        end
      end)

    phase = obj["phase"]

    cond do
      reason != nil -> reason
      obj["ready"] == true -> "Running"
      # A reported Running phase with explicit not-ready containers is not health.
      phase == "Running" -> "NotReady"
      is_binary(phase) and phase != "" -> phase
      true -> "NotReady"
    end
  end

  # Replica counts are facts from the collector; missing counts claim nothing.
  defp workload_status(obj) do
    case {obj["replicas"], obj["ready_replicas"]} do
      {replicas, ready} when is_integer(replicas) and is_integer(ready) ->
        if ready == replicas, do: "Available", else: "Degraded"

      _ ->
        "Unknown"
    end
  end

  # Service attribution is evidence-driven only: the trusted binding pins the
  # environment and cluster for name matching. A foreign Deployment name (no
  # instance matches) stays unattributed instead of silently becoming a
  # bound-service object.
  defp deployment_instance(name, ctx) when is_binary(name) do
    case name_candidates(name, ctx) do
      [one] -> one
      _ -> nil
    end
  end

  defp deployment_instance(_, _), do: nil

  # Without a bound instance there is no trusted location context: never
  # infer one from whichever candidate happens to be unique.
  defp name_candidates(name, ctx) do
    if is_map(ctx.bound) do
      ctx.by_key[name]
      |> List.wrap()
      |> Enum.filter(fn i ->
        i["environment"] == ctx.bound["environment"] and
          cluster(i["target"]) == cluster(ctx.bound["target"])
      end)
    else
      []
    end
  end

  defp chain_instance("Deployment", obj, ctx), do: deployment_instance(obj["name"], ctx)

  # Owner and target chains resolve strictly: a missing or ambiguous parent,
  # or an unresolvable event target, leaves the object unattributed rather
  # than re-attributing it to the bound service (its real owner may simply
  # not be retained).
  defp chain_instance("ReplicaSet", obj, ctx) do
    case owner_object(obj, "Deployment", ctx) do
      %{"kind" => "Deployment"} = dep -> deployment_instance(dep["name"], ctx)
      _ -> nil
    end
  end

  defp pod_instance(obj, ctx) do
    case owner_object(obj, "ReplicaSet", ctx) do
      %{"kind" => "ReplicaSet"} = rs -> chain_instance("ReplicaSet", rs, ctx)
      _ -> owner_deployment_instance(obj, ctx)
    end
  end

  defp owner_deployment_instance(obj, ctx) do
    case owner_object(obj, "Deployment", ctx) do
      %{"kind" => "Deployment"} = dep -> deployment_instance(dep["name"], ctx)
      _ -> nil
    end
  end

  defp event_instance(obj, ctx) do
    case ctx.objects[obj["target_uid"]] do
      %{"kind" => "Pod"} = pod -> pod_instance(pod, ctx)
      %{"kind" => "ReplicaSet"} = rs -> chain_instance("ReplicaSet", rs, ctx)
      %{"kind" => "Deployment"} = dep -> deployment_instance(dep["name"], ctx)
      _ -> nil
    end
  end

  # Follow exactly one owner of the given kind; ambiguous references resolve
  # to nothing.
  defp owner_object(obj, kind, ctx) do
    owners =
      obj["owners"]
      |> List.wrap()
      |> Enum.filter(&is_map/1)
      |> Enum.filter(&(&1["kind"] == kind))

    case owners do
      [%{"uid" => uid}] -> ctx.objects[uid]
      _ -> nil
    end
  end

  # Unattributed objects keep the trusted binding's cluster/environment as
  # their location (without claiming a service); uid and source identity are
  # retained so independent objects are never conflated downstream.
  defp entry(kind, uid, name, status, instance, ctx, details) do
    located = instance || ctx.bound

    %{
      "kind" => kind,
      "uid" => uid,
      "name" => name,
      "cluster" => located && cluster(located["target"]),
      "environment" => located && located["environment"],
      "namespace" => ctx.namespace,
      "status" => status,
      "service" => instance && instance["service_key"],
      "service_id" => instance && instance["id"],
      "source_id" => ctx.source_id,
      "details" => details
    }
  end

  defp company_id_of([row | _]), do: row["company_id"]
  defp company_id_of([]), do: nil

  defp cluster(target) when is_binary(target), do: target |> String.split("/") |> hd()
  defp cluster(_), do: ""

  # Demo adapter: the offline dataset seeds evidence_items (kind='demo_resource')
  # already in the normalized shape. Kept byte-for-byte with the previous
  # Insights reads so the scripted demo output is unchanged.
  defp demo_resources(now, nil) do
    Store.rows(
      """
      SELECT data FROM evidence_items
      WHERE kind='demo_resource' AND expires_at > $1
        AND (data->>'kind' IN ('Node','Database')
          OR (data->>'kind'='Pod' AND data->>'status' NOT IN ('Running','Succeeded'))
          OR (data->>'kind'='Event' AND data->>'status'='Warning')
          OR (data->>'kind' IN ('Deployment','ReplicaSet') AND data->>'status'='Degraded'))
      ORDER BY data->>'cluster',data->>'name' LIMIT 500
      """,
      [now]
    )
    |> Enum.map(&demo_service(&1["data"]))
  end

  defp demo_resources(now, service_key) do
    Store.rows(
      """
      SELECT data FROM evidence_items
      WHERE kind='demo_resource' AND expires_at > $1
        AND (data->'details'->'labels'->>'app.kubernetes.io/name'=$2
          OR data->'details'->>'involvedObject'=$2
          OR (data->>'kind'='Service' AND data->>'name'=$2))
      ORDER BY data->>'kind',data->>'name' LIMIT 200
      """,
      [now, service_key]
    )
    |> Enum.map(&demo_service(&1["data"]))
  end

  # Demo fixtures declare their service through the workload label or the
  # event's involved object; materialize it so attention can link them.
  defp demo_service(%{} = data) do
    service =
      get_in(data, ["details", "labels", "app.kubernetes.io/name"]) ||
        get_in(data, ["details", "involvedObject"])

    if is_binary(service), do: Map.put(data, "service", service), else: data
  end

  # Real objects are never collapsed against each other: distinct sources,
  # environments and UIDs are distinct observations, even with identical display
  # names. Demo fixtures step aside only for a real object with the same
  # explicitly scoped identity (kind/name/cluster/environment/namespace).
  # Linear over the bounded read via a map set.
  defp reject_shadowed(demo, real) do
    real_ids =
      MapSet.new(real, fn r ->
        {r["kind"], r["name"], r["cluster"], r["environment"], r["namespace"]}
      end)

    Enum.reject(demo, fn d ->
      MapSet.member?(
        real_ids,
        {d["kind"], d["name"], d["cluster"], d["environment"], d["namespace"]}
      )
    end)
  end
end
