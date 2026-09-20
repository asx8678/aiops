defmodule OpsBrain.TelemetryCollection do
  @moduledoc "Fixed, revisable metric/log windows and persisted detector outputs; no rolling sums."
  alias OpsBrain.{SourceConfig, Store, Repo, Evidence, Fingerprints, Issues}

  # Backfill advances contiguously from the durable checkpoint, up to this many
  # one-minute windows per tick. When it cannot keep up, coverage is reported as
  # catching_up and the next attempt is requeued after five seconds (subject to the
  # shared source request budget) instead of pretending the gap is complete.
  @catchup_batch 1

  def tick(id, now \\ Store.now()) do
    with {:ok, c} <- SourceConfig.fetch(id),
         {:ok, {:claimed, fence, windows}} <- claim(id, now) do
      run_windows(c, id, fence, windows, now)
    else
      {:error, :busy} -> {:snooze, 30}
      error -> error
    end
  end

  defp run_windows(c, id, fence, windows, now) do
    result =
      Enum.reduce_while(windows, {:ok, nil}, fn {start, finish}, _acc ->
        case collect(c, start, finish, now, fence) do
          {:ok, data} ->
            case persist_window(id, c, fence, start, finish, data, now) do
              {:ok, stored} -> {:cont, {:ok, stored}}
              {:error, reason} -> {:halt, {:error, reason}}
            end

          {:error, reason} ->
            {:halt, {:error, reason}}
        end
      end)

    case result do
      {:ok, stored} ->
        case finish_state(c, id, fence, now, nil) do
          {:ok, :catching_up} -> {:snooze, 5}
          {:ok, :finished} -> {:ok, stored}
          error -> error
        end

      {:error, reason} ->
        case finish_state(c, id, fence, now, to_string(reason)) do
          {:ok, _} -> {:ok, {:error, :invalid_or_unavailable_response}}
          error -> error
        end
    end
  end

  defp collect(%{kind: "kubernetes"} = c, _start, _finish, now, fence),
    do: OpsBrain.Kubernetes.reconcile(c, now, fence)

  defp collect(%{kind: "prometheus"} = c, _start, finish, _now, _fence),
    do: OpsBrain.Metrics.collect(c, finish)

  defp collect(%{kind: "loki"} = c, start, finish, _now, _fence),
    do: OpsBrain.Logs.collect(c, start, finish)

  defp persist_window(id, c, fence, start, finish, data, now) do
    result =
      SourceConfig.transaction(id, fn trusted ->
        s =
          Store.one(
            "SELECT fence,lease_until FROM collection_states WHERE source_id=$1::text::uuid FOR UPDATE",
            [id]
          )

        if s["fence"] != fence or DateTime.compare(s["lease_until"], Store.now()) == :lt,
          do: Repo.rollback(:stale_lease)

        data =
          if c.kind == "kubernetes" and is_list(c[:resources]),
            do: OpsBrain.WorkloadCollection.persist(trusted, data, now, fence),
            else: data

        stored = persist(trusted, start, finish, data, now)

        error =
          data["source_error"] ||
            if(c.kind != "kubernetes" and stored["coverage"] != "complete",
              do: "incomplete_observation",
              else: nil
            )

        Repo.query!(
          """
          UPDATE collection_states SET
          last_success_at=CASE WHEN $4::text IS NULL THEN $2 ELSE last_success_at END,
          completed_at=CASE WHEN $4::text IS NULL THEN GREATEST(COALESCE(completed_at,$3),$3) ELSE completed_at END,
          coverage=$5,error=$4,requests=requests+1 WHERE source_id=$1::text::uuid
          """,
          [id, now, finish, error, stored["coverage"] || "partial"]
        )

        if error,
          do: {:error, error},
          else: {:ok, stored}
      end)

    case result do
      {:ok, {:ok, stored}} -> {:ok, stored}
      {:ok, {:error, reason}} -> {:error, reason}
      other -> other
    end
  end

  defp finish_state(c, id, fence, now, error) do
    SourceConfig.transaction(id, fn _ ->
      s =
        Store.one(
          "SELECT fence,lease_until,completed_at,coverage FROM collection_states WHERE source_id=$1::text::uuid FOR UPDATE",
          [id]
        )

      if s["fence"] != fence or is_nil(s["lease_until"]) or
           DateTime.compare(s["lease_until"], Store.now()) != :gt,
         do: Repo.rollback(:stale_lease)

      closed = closed_minute(now)

      coverage =
        cond do
          error != nil -> "partial"
          s["coverage"] in ["partial", "capped_or_saturated", "not_configured"] -> s["coverage"]
          s["completed_at"] == nil -> "partial"
          DateTime.compare(s["completed_at"], closed) == :lt -> "catching_up"
          true -> "complete"
        end

      delay =
        cond do
          error != nil -> max(c.interval_seconds, 30)
          coverage == "complete" -> c.interval_seconds
          c.kind == "kubernetes" -> c.interval_seconds
          true -> 5
        end

      Repo.query!(
        "UPDATE collection_states SET lease_until=NULL,next_at=$2,coverage=$3,error=$4 WHERE source_id=$1::text::uuid",
        [id, DateTime.add(now, delay), coverage, error]
      )

      if coverage == "catching_up", do: :catching_up, else: :finished
    end)
  end

  defp claim(id, now) do
    SourceConfig.transaction(id, fn c ->
      Repo.query!(
        "INSERT INTO collection_states(company_id,source_id) VALUES($1::text::uuid,$2::text::uuid) ON CONFLICT DO NOTHING",
        [c.company_id, id]
      )

      s =
        Store.one("SELECT * FROM collection_states WHERE source_id=$1::text::uuid FOR UPDATE", [
          id
        ])

      if Enum.any?([s["next_at"], s["lease_until"]], &(&1 && DateTime.compare(&1, now) == :gt)),
        do: Repo.rollback(:busy)

      fence = s["fence"] + 1

      Repo.query!(
        "UPDATE collection_states SET fence=$2,lease_until=$3,requests=requests+1 WHERE source_id=$1::text::uuid",
        [id, fence, DateTime.add(now, 45)]
      )

      {:claimed, fence, windows_for(c, s, now)}
    end)
  end

  defp windows_for(%{kind: "kubernetes"}, _s, now) do
    closed = closed_minute(now)
    [{DateTime.add(closed, -60), closed}]
  end

  defp windows_for(_c, s, now) do
    closed = closed_minute(now)

    start =
      case s["completed_at"] do
        nil -> DateTime.add(closed, -60)
        completed -> completed
      end

    contiguous(start, closed)
  end

  defp contiguous(start, closed) do
    windows =
      Stream.unfold(start, fn s ->
        if DateTime.compare(s, closed) == :lt do
          f = DateTime.add(s, 60)
          {{s, f}, f}
        else
          nil
        end
      end)
      |> Enum.take(@catchup_batch)

    case windows do
      [] -> [{DateTime.add(closed, -120), DateTime.add(closed, -60)}]
      _ -> windows
    end
  end

  defp closed_minute(now), do: DateTime.from_unix!(div(DateTime.to_unix(now), 60) * 60)

  def persist(c, start, finish, data, now) do
    data =
      if byte_size(Jason.encode!(data)) > 60_000 do
        %{
          "coverage" => "partial",
          "condition" => "unknown",
          "missing" => "observation storage byte budget exceeded; full input not retained",
          "count" => data["count"],
          "sample_count_returned" => length(data["samples"] || [])
        }
      else
        data
      end

    profile = c[:profile] || %{id: "workload", version: 1}
    service = c[:service_id]

    if service &&
         Store.one(
           "SELECT id FROM service_instances WHERE id=$1::text::uuid AND source_id=$2::text::uuid",
           [service, c.id]
         ) == nil,
       do: Repo.rollback(:unresolved_service)

    key = "#{profile.id}:v#{profile.version}"

    row =
      Store.one(
        """
        INSERT INTO observation_windows(id,company_id,source_id,service_id,profile,kind,window_start,window_end,received_at,data)
        VALUES($1::text::uuid,$2::text::uuid,$3::text::uuid,$4::text::uuid,$5,$6,$7,$8,$9,$10)
        ON CONFLICT(company_id,source_id,profile,window_start,window_end) DO UPDATE SET
        data=EXCLUDED.data,received_at=EXCLUDED.received_at,revision=observation_windows.revision+CASE WHEN observation_windows.data=EXCLUDED.data THEN 0 ELSE 1 END
        RETURNING id::text,revision
        """,
        [Ecto.UUID.generate(), c.company_id, c.id, service, key, c.kind, start, finish, now, data]
      )

    Repo.query!(
      """
      INSERT INTO observation_revisions(id,company_id,source_id,window_id,service_id,profile,kind,window_start,window_end,received_at,revision,data,policy)
      VALUES($1::text::uuid,$2::text::uuid,$3::text::uuid,$4::text::uuid,$5::text::uuid,$6,$7,$8,$9,$10,$11,$12,$13)
      ON CONFLICT(company_id,window_id,revision) DO NOTHING
      """,
      [
        Ecto.UUID.generate(),
        c.company_id,
        c.id,
        row["id"],
        service,
        key,
        c.kind,
        start,
        finish,
        now,
        row["revision"],
        data,
        c[:profile] || %{}
      ]
    )

    evidence =
      Evidence.save(c, "window:#{row["id"]}:#{row["revision"]}", c.kind, data, finish, now)

    if service && data["condition"] in ["warning", "critical", "watch"] do
      prior =
        Store.one(
          "SELECT id FROM observation_windows WHERE source_id=$1::text::uuid AND profile=$2 AND window_end=$3 AND data->>'condition' IN ('warning','critical','watch')",
          [c.id, key, start]
        )

      if prior do
        text = "#{c.kind} profile #{key} sustained configured threshold breach"
        fp = Fingerprints.identify(c.company_id, service, key, text)

        Issues.record(
          c,
          "window:#{row["id"]}",
          evidence,
          fp,
          %{
            occurred_at: finish,
            count_basis: "distinct breached fixed windows; not error line count",
            scope: service
          },
          now
        )
      end
    end

    if c.kind == "kubernetes" and service do
      for change <- data["changes"] || [],
          change["oom"] == true or is_integer(change["restart_delta"]) or
            change["type"] == "Warning" do
        description =
          cond do
            change["oom"] == true -> "Observed OOMKilled termination with a new restart"
            change["type"] == "Warning" -> "Kubernetes Warning event: #{change["reason"]}"
            true -> "Observed container restart increment"
          end

        fp = Fingerprints.identify(c.company_id, service, change["kind"] || "Pod", description)
        key = "workload:#{Store.digest(change)}"
        observed = Evidence.save(c, key, "workload_transition", change, finish, now)

        Issues.record(
          c,
          key,
          observed,
          fp,
          %{
            occurred_at: finish,
            scope: service,
            severity: if(change["oom"] == true, do: "critical", else: "warning"),
            count_basis: "distinct observed workload transitions; deltas retained in evidence"
          },
          now
        )
      end
    end

    if c.kind == "loki" and service do
      (data["samples"] || [])
      |> Enum.group_by(&Fingerprints.normalize(&1["message"]))
      |> Enum.take(20)
      |> Enum.each(fn {template, samples} ->
        fp = Fingerprints.identify(c.company_id, service, "loki", template)

        sample_evidence =
          Evidence.save(
            c,
            "sample:#{row["id"]}:#{row["revision"]}:#{fp.fingerprint}",
            "log_sample",
            %{
              "message" => template,
              "sample_count" => length(samples),
              "backend_total" => data["count"],
              "count_basis" => "observed in bounded sample; exact fingerprint total unknown",
              "window_id" => row["id"],
              "revision" => row["revision"]
            },
            finish,
            now
          )

        Issues.record(
          c,
          "sample:#{row["id"]}:#{fp.fingerprint}",
          sample_evidence,
          fp,
          %{
            occurred_at: finish,
            scope: service,
            count_basis: "distinct windows containing sampled signature; NOT log entry total"
          },
          now
        )
      end)
    end

    if data["condition"] == "normal" and data["coverage"] == "complete" and service do
      OpsBrain.Recovery.window(c, key, service, start, finish, evidence, now)
    end

    if c.kind == "prometheus", do: OpsBrain.Evaluations.capacity(c, finish, now)
    Map.put(row, "coverage", data["coverage"] || "partial")
  end
end
