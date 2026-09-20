defmodule OpsBrain.Collection do
  @moduledoc "One bounded outbound read per durable job. HTTP never runs inside a transaction. Leases are fenced."
  alias OpsBrain.{SourceConfig, Store, Repo, AzureBuild, Transport}

  # Historical reconciliation is a durable backlog (run IDs re-fetched by id).
  # It is drained one step at a time, alternating with current discovery, so a
  # long backlog can never block new-run polling. The backlog is bounded; when
  # it is full, coverage is reported partial rather than silently dropping.
  @max_reconcile 100

  def tick(source_id, now \\ Store.now()) do
    with {:ok, c} <- SourceConfig.fetch(source_id),
         {:ok, {:claimed, state}} <- claim(source_id, now) do
      response =
        case state["mode"] do
          mode when mode in ["recent", "reconcile"] ->
            case state["reconcile_ids"] do
              [id | _] -> AzureBuild.run(c, id)
              [] -> AzureBuild.list(c, state)
            end

          _ ->
            AzureBuild.list(c, state)
        end

      case response do
        {:ok, r} -> accept(c, state, r, Store.now())
        {:error, reason} -> fail(c, state, reason, Store.now(), 60)
      end
    else
      {:ok, :busy} -> {:snooze, 30}
      error -> error
    end
  end

  def claim(id, now) do
    SourceConfig.transaction(id, fn c ->
      Repo.query!(
        "INSERT INTO collection_states(company_id,source_id) VALUES ($1::text::uuid,$2::text::uuid) ON CONFLICT DO NOTHING",
        [c.company_id, c.id]
      )

      s =
        Store.one("SELECT * FROM collection_states WHERE source_id=$1::text::uuid FOR UPDATE", [
          id
        ])

      if future?(s["lease_until"], now) or future?(s["next_at"], now) do
        :busy
      else
        start =
          s["window_start"] ||
            DateTime.add(
              s["completed_at"] || DateTime.add(now, -3600),
              -min(120, div(c.max_window_seconds, 4))
            )

        finish =
          s["window_end"] ||
            Enum.min_by([now, DateTime.add(start, c.max_window_seconds)], &DateTime.to_unix/1)

        state =
          Store.one(
            """
            UPDATE collection_states SET fence=fence+1,lease_until=$2,window_start=$3,window_end=$4,coverage='partial'
            WHERE source_id=$1::text::uuid RETURNING *
            """,
            [id, DateTime.add(now, 45), start, finish]
          )

        {:claimed, state}
      end
    end)
  end

  defp future?(nil, _), do: false
  defp future?(t, now), do: DateTime.compare(t, now) == :gt

  defp accept(c, state, r, now) do
    delay = max(c.interval_seconds, Transport.retry_seconds(r.headers, now))

    decoded =
      if state["mode"] in ["recent", "reconcile"] and r.status == 200 do
        with {:ok, raw} <- Jason.decode(r.body),
             {:ok, normalized} <- AzureBuild.normalize(c, raw),
             true <- normalized["run_id"] == hd(state["reconcile_ids"]) do
          {:ok, [normalized], nil}
        else
          _ -> {:error, :invalid_run}
        end
      else
        AzureBuild.decode(c, r)
      end

    case decoded do
      {:ok, runs, token} ->
        cond do
          token != nil and token == state["cursor"] ->
            fail(c, state, :repeated_cursor, now, delay)

          true ->
            persist(c, state, runs, token, r.bytes, now, delay)
        end

      {:error, _} ->
        fail(
          c,
          state,
          if(r.status in [401, 403], do: :access_denied, else: :invalid_or_unavailable_response),
          now,
          delay
        )
    end
  end

  def persist(c, state, runs, token, bytes, now, delay) do
    SourceConfig.transaction(c.id, fn trusted ->
      current = fenced!(trusted, state, now)
      Enum.each(runs, &put_run(trusted, &1, now))

      {mode, ids, coverage, checkpoint, start, finish, pages} =
        transition(trusted, current, token, now)

      Repo.query!(
        """
        UPDATE collection_states SET cursor=$2,mode=$3,reconcile_ids=$4,coverage=$5,completed_at=$6,
        window_start=$7,window_end=$8,pages=$9,lease_until=NULL,next_at=$10,last_success_at=$11,
        error=NULL,requests=requests+1,bytes=bytes+$12 WHERE source_id=$1::text::uuid
        """,
        [
          trusted.id,
          token,
          mode,
          ids,
          coverage,
          checkpoint,
          start,
          finish,
          pages,
          DateTime.add(now, delay),
          now,
          bytes
        ]
      )

      :persisted
    end)
  end

  defp transition(c, s, token, _now) do
    if token do
      {s["mode"], s["reconcile_ids"], "partial", s["completed_at"], s["window_start"],
       s["window_end"], s["pages"] + 1}
    else
      case s["mode"] do
        "completed" ->
          {"active", s["reconcile_ids"], "complete", s["window_end"], s["window_start"],
           s["window_end"], 0}

        "active" ->
          ids =
            Store.rows(
              "SELECT run_id FROM pipeline_runs WHERE source_id=$1::text::uuid ORDER BY received_at DESC,run_id DESC LIMIT 100",
              [c.id]
            )
            |> Enum.map(& &1["run_id"])

          backlog = if s["reconcile_ids"] == [], do: ids, else: s["reconcile_ids"]

          if backlog == [],
            do: {"completed", [], "complete", s["completed_at"], nil, nil, 0},
            else:
              {"reconcile", backlog,
               if(length(backlog) >= @max_reconcile, do: "partial", else: "complete"),
               s["completed_at"], nil, nil, 0}

        mode when mode in ["recent", "reconcile"] ->
          # Exactly one reconciliation per phase; current discovery gets the next
          # tick, so a large backlog is drained between discovery polls.
          rest = tl(s["reconcile_ids"])

          {"completed", rest, if(rest == [], do: "complete", else: "partial"), s["completed_at"],
           nil, nil, 0}
      end
    end
  end

  defp put_run(c, r, now) do
    old =
      Store.one(
        "SELECT id::text,data,revision FROM pipeline_runs WHERE company_id=$1::text::uuid AND source_id=$2::text::uuid AND project_id=$3::text::uuid AND run_id=$4",
        [c.company_id, c.id, c.project_id, r["run_id"]]
      )

    if old == nil or old["data"] != r do
      id = if old, do: old["id"], else: Ecto.UUID.generate()
      revision = if old, do: old["revision"] + 1, else: 1

      Repo.query!(
        """
        INSERT INTO pipeline_runs(id,company_id,source_id,project_id,run_id,definition_id,status,result,finish_at,received_at,revision,data)
        VALUES ($1::text::uuid,$2::text::uuid,$3::text::uuid,$4::text::uuid,$5,$6,$7,$8,$9,$10,$11,$12)
        ON CONFLICT(company_id,source_id,project_id,run_id) DO UPDATE SET status=EXCLUDED.status,result=EXCLUDED.result,finish_at=EXCLUDED.finish_at,received_at=EXCLUDED.received_at,revision=EXCLUDED.revision,data=EXCLUDED.data
        """,
        [
          id,
          c.company_id,
          c.id,
          c.project_id,
          r["run_id"],
          r["definition_id"],
          r["status"],
          r["result"],
          Store.parse(r["finish_at"]),
          now,
          revision,
          r
        ]
      )

      Repo.query!(
        "INSERT INTO run_snapshots(id,company_id,source_id,run_id,digest,received_at,data) VALUES($1::text::uuid,$2::text::uuid,$3::text::uuid,$4::text::uuid,$5,$6,$7)",
        [Ecto.UUID.generate(), c.company_id, c.id, id, Store.digest({r, revision}), now, r]
      )

      if r["result"] == "succeeded", do: OpsBrain.Recovery.pipeline(c, r, now)

      if r["result"] in ["failed", "partiallySucceeded"] or
           (r["status"] == "completed" and Map.get(c, :stage_targets, []) != []) do
        pending =
          Store.one(
            "SELECT count(*)::integer AS n FROM oban_jobs WHERE worker='OpsBrain.EvidenceWorker' AND args->>'source_id'=$1 AND state IN ('available','scheduled','executing','retryable')",
            [c.id]
          )["n"]

        if pending < 100 do
          %{source_id: c.id, run_id: r["run_id"], revision: revision}
          |> OpsBrain.EvidenceWorker.new()
          |> Oban.insert!()
        else
          OpsBrain.Evidence.unavailable(c, r["run_id"], :enrichment_queue_budget_exhausted, now)
        end
      end
    end
  end

  defp fenced!(c, s, now) do
    current =
      Store.one("SELECT * FROM collection_states WHERE source_id=$1::text::uuid FOR UPDATE", [
        c.id
      ])

    if current == nil or current["fence"] != s["fence"] or
         not future?(current["lease_until"], now),
       do: Repo.rollback(:stale_lease)

    current
  end

  defp fail(c, s, reason, now, delay) do
    # Yield to discovery without discarding failed historical work. Rotate the
    # ID to the tail for another bounded attempt; errors remain visibly partial.
    {mode, ids, coverage} =
      cond do
        s["mode"] in ["recent", "reconcile"] ->
          ids = s["reconcile_ids"]
          rotated = if ids == [], do: [], else: tl(ids) ++ [hd(ids)]
          {"completed", rotated, "partial"}

        true ->
          {s["mode"], s["reconcile_ids"], "partial"}
      end

    result =
      SourceConfig.transaction(c.id, fn trusted ->
        fenced!(trusted, s, now)

        Repo.query!(
          "UPDATE collection_states SET lease_until=NULL,next_at=$2,error=$3,coverage=$4,mode=$5,reconcile_ids=$6,requests=requests+1 WHERE source_id=$1::text::uuid",
          [c.id, DateTime.add(now, max(30, delay)), Atom.to_string(reason), coverage, mode, ids]
        )

        :recorded
      end)

    case result do
      {:ok, :recorded} -> {:source_failure, reason}
      {:error, _} = error -> error
    end
  end

  def summary(scope, source_id) do
    OpsBrain.Tenancy.with_scope(scope, fn ->
      state =
        Store.one(
          "SELECT coverage,error,completed_at,last_success_at,requests,bytes FROM collection_states WHERE source_id=$1::text::uuid",
          [source_id]
        )

      counts =
        Store.rows(
          "SELECT result,count(*)::integer AS count FROM pipeline_runs WHERE source_id=$1::text::uuid AND status='completed' GROUP BY result",
          [source_id]
        )

      %{
        coverage: state,
        counts: counts,
        count_basis: "distinct retained run projections; not task/signature counts",
        failure_rate: nil
      }
    end)
  end
end
