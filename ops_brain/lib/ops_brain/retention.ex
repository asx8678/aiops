defmodule OpsBrain.Retention do
  @moduledoc "Bounded source-local cleanup with live-dependency guards. No directory/identity privileges."
  alias OpsBrain.{SourceConfig, Repo, Store}
  @closed "('recovered','closed_by_reviewer')"
  @terminal "('delivered','rejected','ambiguous','retry_exhausted','coalesced')"

  @doc "One bounded pass. Repeat while more? is true; protected dependencies may remain indefinitely."
  def sweep(id, now \\ Store.now(), batch_size \\ 100)

  def sweep(id, %DateTime{} = now, batch_size)
      when is_integer(batch_size) and batch_size in 1..500 do
    SourceConfig.transaction(id, fn c ->
      # Use transaction-local time limits as well as row bounds. A timeout rolls back the pass.
      Repo.query!("SET LOCAL lock_timeout = '1s'")
      Repo.query!("SET LOCAL statement_timeout = '5s'")
      cutoff = DateTime.add(now, -c.retention_days, :day)
      params = [id, now, cutoff, batch_size]

      if busy?(id, now) do
        %{status: :deferred_live_work, more?: false}
      else
        outbox =
          delete(
            "notification_outbox",
            """
            t.updated_at < $3 AND t.status IN #{@terminal}
            AND NOT EXISTS (SELECT 1 FROM oban_jobs j WHERE j.args->>'id'=t.id::text
              AND j.state NOT IN ('completed','discarded','cancelled'))
            """,
            params
          )

        expired =
          Repo.query!(
            """
            WITH candidates AS MATERIALIZED (SELECT e.id FROM evidence_items e WHERE e.source_id=$1::text::uuid
              AND e.expires_at <= $2 AND e.received_at < $3 AND NOT(e.data ? 'expired')
              AND #{unreferenced_evidence("e")}
              ORDER BY e.received_at,e.id LIMIT $4 FOR UPDATE OF e SKIP LOCKED)
            UPDATE evidence_items SET data='{"expired":true,"reason":"retention"}'::jsonb
            WHERE id IN (SELECT id FROM candidates)
            """,
            params
          ).num_rows

        # A revision can be needed even after the current mutable window has changed.
        revisions =
          delete(
            "observation_revisions",
            """
            t.received_at < $3 AND #{unreferenced_window("t.window_id")}
            AND NOT EXISTS (SELECT 1 FROM collection_states s WHERE s.source_id=t.source_id
              AND s.window_start IS NOT NULL AND t.window_end >= s.window_start
              AND t.window_start <= s.window_end)
            """,
            params
          )

        windows =
          delete(
            "observation_windows",
            """
            t.received_at < $3 AND #{unreferenced_window("t.id")}
            AND NOT EXISTS (SELECT 1 FROM observation_revisions r
              WHERE r.company_id=t.company_id AND r.window_id=t.id)
            AND NOT EXISTS (SELECT 1 FROM collection_states s WHERE s.source_id=t.source_id
              AND ((s.window_start IS NOT NULL AND t.window_end >= s.window_start AND t.window_start <= s.window_end)
                OR t.window_end >= s.completed_at - interval '1 minute'))
            AND NOT (t.kind='kubernetes' AND t.id=(SELECT w.id FROM observation_windows w
              WHERE w.source_id=t.source_id ORDER BY w.received_at DESC,w.id DESC LIMIT 1))
            """,
            params
          )

        snapshots =
          delete(
            "run_snapshots",
            """
            t.received_at < $3 AND EXISTS (SELECT 1 FROM pipeline_runs r
              WHERE r.company_id=t.company_id AND r.id=t.run_id AND r.status='completed'
              AND r.received_at < $3
              AND NOT EXISTS (SELECT 1 FROM collection_states s WHERE s.source_id=r.source_id
                AND (r.run_id=ANY(s.reconcile_ids) OR
                  (s.window_start IS NOT NULL AND r.finish_at BETWEEN s.window_start AND s.window_end)))
              AND NOT EXISTS (SELECT 1 FROM failure_occurrences f JOIN issue_groups g
                ON g.company_id=f.company_id AND g.id=f.group_id
                WHERE f.source_id=r.source_id AND f.run_id=r.run_id
                  AND (g.status NOT IN #{@closed} OR #{pending_group("g.id")})))
            """,
            params
          )

        occurrences =
          delete(
            "failure_occurrences",
            """
            t.occurred_at < $3 AND EXISTS (SELECT 1 FROM issue_groups g
              WHERE g.company_id=t.company_id AND g.id=t.group_id AND g.last_seen < $3
                AND g.status IN #{@closed} AND NOT #{pending_group("g.id")})
            AND EXISTS (SELECT 1 FROM evidence_items e WHERE e.company_id=t.company_id
              AND e.id=t.evidence_id AND e.expires_at <= $2)
            """,
            params
          )

        groups =
          delete(
            "issue_groups",
            """
            t.last_seen < $3 AND t.status IN #{@closed}
            AND NOT EXISTS (SELECT 1 FROM failure_occurrences f WHERE f.company_id=t.company_id AND f.group_id=t.id)
            AND NOT EXISTS (SELECT 1 FROM notification_outbox o WHERE o.company_id=t.company_id AND o.group_id=t.id)
            AND NOT EXISTS (SELECT 1 FROM evidence_items e WHERE e.company_id=t.company_id
              AND e.data->>'group_id'=t.id::text AND e.expires_at > $2)
            """,
            params
          )

        fingerprints =
          Repo.query!(
            """
            WITH candidates AS MATERIALIZED (
              SELECT t.company_id,t.fingerprint FROM error_fingerprints t
              WHERE t.source_id=$1::text::uuid AND $2::timestamp IS NOT NULL AND $3::timestamp IS NOT NULL
                AND NOT EXISTS (SELECT 1 FROM issue_groups g
                  WHERE g.company_id=t.company_id AND g.fingerprint=t.fingerprint)
              ORDER BY t.fingerprint LIMIT $4 FOR UPDATE OF t SKIP LOCKED)
            DELETE FROM error_fingerprints WHERE (company_id,fingerprint) IN (SELECT company_id,fingerprint FROM candidates)
            """,
            params
          ).num_rows

        # Identity tombstones have a second retention period; live relationships still win.
        tombstones =
          delete(
            "evidence_items",
            """
              t.data ? 'expired' AND t.expires_at < $3 AND t.received_at < $3
              AND NOT EXISTS (SELECT 1 FROM failure_occurrences f WHERE f.company_id=t.company_id AND f.evidence_id=t.id)
              AND NOT EXISTS (SELECT 1 FROM observation_revisions r WHERE r.company_id=t.company_id AND r.source_id=t.source_id
                AND t.evidence_key = 'window:' || r.window_id::text || ':' || r.revision::text)
              AND #{unreferenced_evidence("t")}
            """,
            params
          )

        runs =
          delete(
            "pipeline_runs",
            """
              t.status='completed' AND t.received_at < $3 AND t.finish_at < $3
              AND NOT EXISTS (SELECT 1 FROM run_snapshots r WHERE r.company_id=t.company_id AND r.run_id=t.id)
              AND NOT EXISTS (SELECT 1 FROM failure_occurrences f WHERE f.source_id=t.source_id AND f.run_id=t.run_id)
              AND NOT EXISTS (SELECT 1 FROM collection_states s WHERE s.source_id=t.source_id
                AND (t.run_id=ANY(s.reconcile_ids) OR (s.window_start IS NOT NULL AND t.finish_at BETWEEN s.window_start AND s.window_end)))
              AND NOT EXISTS (SELECT 1 FROM oban_jobs j WHERE j.args->>'source_id'=t.source_id::text
                AND j.args->>'run_id'=t.run_id::text AND j.state NOT IN ('completed','discarded','cancelled'))
            """,
            params
          )

        counts = %{
          tombstones_deleted: tombstones,
          runs_deleted: runs,
          evidence_expired: expired,
          revisions_deleted: revisions,
          windows_deleted: windows,
          snapshots_deleted: snapshots,
          outbox_deleted: outbox,
          occurrences_deleted: occurrences,
          groups_deleted: groups,
          fingerprints_deleted: fingerprints
        }

        Map.merge(counts, %{
          status: :ok,
          more?: Enum.any?(counts, fn {_, n} -> n == batch_size end)
        })
      end
    end)
  end

  def sweep(_, _, _), do: {:error, :invalid_retention_arguments}

  # All identifiers and predicates below are private constants, never caller SQL.
  defp delete(table, predicate, params) do
    # Immutable revision rows have no UPDATE privilege (required by FOR UPDATE).
    # Materialized bounded selection is sufficient: concurrent deletion is idempotent.
    locking = if table == "observation_revisions", do: "", else: "FOR UPDATE OF t SKIP LOCKED"

    Repo.query!(
      """
      WITH candidates AS MATERIALIZED (SELECT t.id FROM #{table} t
        WHERE t.source_id=$1::text::uuid AND $2::timestamp IS NOT NULL AND $3::timestamp IS NOT NULL
          AND (#{predicate}) ORDER BY t.id LIMIT $4 #{locking})
      DELETE FROM #{table} WHERE id IN (SELECT id FROM candidates)
      """,
      params
    ).num_rows
  end

  defp pending_group(group) do
    """
    EXISTS (SELECT 1 FROM notification_outbox o WHERE o.group_id=#{group}
      AND o.status NOT IN #{@terminal})
    """
  end

  defp unreferenced_evidence(e) do
    """
    NOT EXISTS (SELECT 1 FROM failure_occurrences f JOIN issue_groups g
      ON g.company_id=f.company_id AND g.id=f.group_id
      WHERE f.company_id=#{e}.company_id AND f.evidence_id=#{e}.id
        AND (g.status NOT IN #{@closed} OR #{pending_group("g.id")}))
    AND NOT EXISTS (SELECT 1 FROM evidence_items c WHERE c.company_id=#{e}.company_id
      AND c.kind='correlation' AND c.expires_at > $2 AND (
        c.data->'result'->'candidates' @> jsonb_build_array(jsonb_build_object('change_evidence_id',#{e}.id::text))
        OR c.data->'result'->'candidates' @> jsonb_build_array(jsonb_build_object('symptom_evidence_id',#{e}.id::text))))
    """
  end

  defp unreferenced_window(window) do
    """
    NOT EXISTS (SELECT 1 FROM evidence_items e WHERE e.company_id=t.company_id AND e.source_id=t.source_id
      AND (e.expires_at > $2 OR NOT (#{unreferenced_evidence("e")}))
      AND (e.data->'input_window_ids' @> jsonb_build_array(#{window}::text)
        OR e.data->>'window_id'=#{window}::text
        OR e.evidence_key LIKE 'window:' || #{window}::text || ':%'))
    """
  end

  defp busy?(id, now) do
    Store.one(
      """
      SELECT 1 AS busy WHERE EXISTS (SELECT 1 FROM collection_states WHERE source_id=$1::text::uuid AND lease_until > $2)
      OR EXISTS (SELECT 1 FROM source_budgets WHERE source_id=$1::text::uuid AND in_flight_until > $2)
      OR EXISTS (SELECT 1 FROM oban_jobs WHERE args->>'source_id'=$1
        AND worker <> 'OpsBrain.MaintenanceWorker' AND state NOT IN ('completed','discarded','cancelled'))
      """,
      [id, now]
    ) != nil
  end
end
