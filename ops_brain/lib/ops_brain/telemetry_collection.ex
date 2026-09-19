defmodule OpsBrain.TelemetryCollection do
  @moduledoc "Fixed, revisable metric/log windows and persisted detector outputs; no rolling sums."
  alias OpsBrain.{SourceConfig, Store, Repo, Evidence, Fingerprints, Issues}

  def tick(id, now \\ Store.now()) do
    with {:ok, c} <- SourceConfig.fetch(id), {:ok, {fence, finish}} <- claim(id, now) do
      start = DateTime.add(finish, -60)

      response =
        case c.kind do
          "prometheus" -> OpsBrain.Metrics.collect(c, finish)
          "loki" -> OpsBrain.Logs.collect(c, start, finish)
          "kubernetes" -> OpsBrain.Kubernetes.reconcile(c, now, fence)
        end

      SourceConfig.transaction(id, fn trusted ->
        s =
          Store.one(
            "SELECT fence,lease_until FROM collection_states WHERE source_id=$1::text::uuid FOR UPDATE",
            [id]
          )

        if s["fence"] != fence or DateTime.compare(s["lease_until"], Store.now()) == :lt,
          do: Repo.rollback(:stale_lease)

        case response do
          {:ok, data} ->
            data =
              if c.kind == "kubernetes" and is_list(c[:resources]),
                do: OpsBrain.WorkloadCollection.persist(trusted, data, now, fence),
                else: data

            stored = persist(trusted, start, finish, data, now)

            Repo.query!(
              "UPDATE collection_states SET lease_until=NULL,next_at=$2,last_success_at=CASE WHEN $6::text IS NULL THEN $3 ELSE last_success_at END,completed_at=GREATEST(completed_at,$4),coverage=$5,error=$6 WHERE source_id=$1::text::uuid",
              [
                id,
                DateTime.add(now, c.interval_seconds),
                now,
                finish,
                stored["coverage"] || "partial",
                data["source_error"]
              ]
            )

          {:error, reason} ->
            Repo.query!(
              "UPDATE collection_states SET lease_until=NULL,next_at=$2,coverage='partial',error=$3 WHERE source_id=$1::text::uuid",
              [id, DateTime.add(now, c.interval_seconds), to_string(reason)]
            )
        end
      end)
    else
      {:error, :busy} -> {:snooze, 30}
      error -> error
    end
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

      Repo.query!(
        "UPDATE collection_states SET fence=fence+1,lease_until=$2,requests=requests+1 WHERE source_id=$1::text::uuid",
        [id, DateTime.add(now, 45)]
      )

      closed = DateTime.from_unix!(div(DateTime.to_unix(now), 60) * 60)

      finish =
        cond do
          c.kind == "kubernetes" ->
            closed

          s["completed_at"] == nil ->
            closed

          DateTime.compare(s["completed_at"], closed) == :lt ->
            Enum.min_by([DateTime.add(s["completed_at"], 60), closed], &DateTime.to_unix/1)

          true ->
            DateTime.add(closed, -60)
        end

      # New closed windows always take priority. Reconcile the prior one only when caught up.
      {s["fence"] + 1, finish}
    end)
  end

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
      # Require a second disjoint breached window; a revised sample is not persistence.
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
      # One membership per signature/window, with explicit sample basis; never a total signature count.
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
