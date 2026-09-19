defmodule OpsBrain.Recovery do
  @moduledoc "Recovery needs comparable successful evidence, never elapsed quiet time or stale inputs."
  alias OpsBrain.{Store, Repo, Evidence, Notifications, Fingerprints}

  def pipeline(c, run, now) do
    groups =
      Store.rows(
        """
        SELECT DISTINCT g.id::text FROM issue_groups g JOIN failure_occurrences f ON f.group_id=g.id AND f.company_id=g.company_id
        WHERE g.source_id=$1::text::uuid AND f.run_id=$2 AND g.status NOT IN ('closed_by_reviewer','recovered')
          AND NOT EXISTS(SELECT 1 FROM failure_occurrences x LEFT JOIN pipeline_runs p ON p.company_id=x.company_id AND p.source_id=x.source_id AND p.run_id=x.run_id
           WHERE x.group_id=g.id AND (p.result IS DISTINCT FROM 'succeeded' OR p.status IS DISTINCT FROM 'completed'))
        """,
        [c.id, run["run_id"]]
      )

    for g <- groups do
      evidence =
        Evidence.save(
          c,
          "recovery:#{g["id"]}:#{Store.digest(run)}",
          "pipeline_recovery",
          %{
            "run" => run,
            "basis" =>
              "all affected run projections now succeeded; recovered delivery outcome, not runtime health"
          },
          Store.parse(run["finish_at"]) || now,
          now
        )

      recover(c, g["id"], evidence, now)
    end
  end

  def window(c, profile, service, start, finish, evidence, now) do
    previous =
      Store.one(
        "SELECT id FROM observation_windows WHERE source_id=$1::text::uuid AND profile=$2 AND window_end=$3 AND data->>'condition'='normal' AND data->>'coverage'='complete'",
        [c.id, profile, start]
      )

    if previous != nil and DateTime.diff(now, finish) in 0..120 do
      fp =
        Fingerprints.identify(
          c.company_id,
          service,
          profile,
          "#{c.kind} profile #{profile} sustained configured threshold breach"
        )

      groups =
        Store.rows(
          "SELECT id::text FROM issue_groups WHERE source_id=$1::text::uuid AND fingerprint=$2 AND last_seen <= $3 AND status NOT IN ('closed_by_reviewer','recovered')",
          [c.id, fp.fingerprint, DateTime.add(start, -60)]
        )

      for g <- groups, do: recover(c, g["id"], evidence, now)
    end
  end

  defp recover(c, id, evidence, now) do
    Repo.query!(
      "UPDATE issue_groups SET status='recovered',revision=revision+1,data=data || jsonb_build_object('recovery_evidence_id',$2::text) WHERE id=$1::text::uuid",
      [id, evidence]
    )

    Notifications.prepare(c, id, now)
  end
end
