defmodule OpsBrain.Issues do
  @moduledoc "Local notices: separate fingerprint identities and time-bounded episodes. No upstream actions."
  alias OpsBrain.{Repo, Store, Tenancy}

  def record(c, key, evidence_id, fp, identity, now) do
    # Source-scoped transaction serializes episode selection across concurrent enrichers.
    Repo.query!("SELECT pg_advisory_xact_lock(hashtextextended($1,0))", [
      c.company_id <> fp.fingerprint
    ])

    duplicate =
      Store.one(
        "SELECT id FROM failure_occurrences WHERE source_id=$1::text::uuid AND occurrence_key=$2",
        [c.id, key]
      )

    if duplicate == nil do
      Repo.query!(
        "INSERT INTO error_fingerprints(company_id,source_id,fingerprint,parser_version,data) VALUES($1::text::uuid,$2::text::uuid,$3,$4,$5) ON CONFLICT DO NOTHING",
        [
          c.company_id,
          c.id,
          fp.fingerprint,
          fp.parser_version,
          Map.new(fp, fn {k, v} -> {Atom.to_string(k), v} end)
        ]
      )

      group =
        Store.one(
          "SELECT id::text FROM issue_groups WHERE fingerprint=$1 AND company_id=$2::text::uuid AND status NOT IN ('recovered','closed_by_reviewer') AND last_seen >= $3 ORDER BY last_seen DESC LIMIT 1 FOR UPDATE",
          [fp.fingerprint, c.company_id, DateTime.add(now, -3600)]
        )

      id = if group, do: group["id"], else: Ecto.UUID.generate()

      if group do
        Repo.query!(
          "UPDATE issue_groups SET last_seen=GREATEST(last_seen,$2),revision=revision+1 WHERE id=$1::text::uuid",
          [id, identity.occurred_at]
        )
      else
        data = %{
          "classification" => fp.classification,
          "template" => fp.template,
          "reason" => fp.reason,
          "missing" => "No confirmed root cause or runtime impact; investigate source evidence",
          "count_basis" => Map.get(identity, :count_basis, "classified failed operation"),
          "scope" => Map.get(identity, :scope, "CI-only / unresolved")
        }

        Repo.query!(
          "INSERT INTO issue_groups(id,company_id,source_id,fingerprint,parser_version,first_seen,last_seen,severity,data) VALUES($1::text::uuid,$2::text::uuid,$3::text::uuid,$4,$5,$6,$6,$7,$8)",
          [
            id,
            c.company_id,
            c.id,
            fp.fingerprint,
            fp.parser_version,
            identity.occurred_at,
            Map.get(identity, :severity, "warning"),
            data
          ]
        )
      end

      Repo.query!(
        "INSERT INTO failure_occurrences(id,company_id,source_id,occurrence_key,group_id,evidence_id,run_id,attempt,occurred_at) VALUES($1::text::uuid,$2::text::uuid,$3::text::uuid,$4,$5::text::uuid,$6::text::uuid,$7,$8,$9)",
        [
          Ecto.UUID.generate(),
          c.company_id,
          c.id,
          key,
          id,
          evidence_id,
          identity[:run_id],
          identity[:attempt],
          identity.occurred_at
        ]
      )

      %{source_id: c.id, group_id: id} |> OpsBrain.InvestigationWorker.new() |> Oban.insert!()
      OpsBrain.Notifications.prepare(c, id, now)
      id
    end
  end

  def list(scope) do
    Tenancy.with_scope(scope, fn ->
      Store.rows("""
      SELECT g.id::text,g.source_id::text,g.first_seen,g.last_seen,g.status,g.owner,g.severity,g.data,g.revision,
       count(f.id)::integer AS occurrences,count(DISTINCT f.run_id)::integer AS distinct_runs,
       count(DISTINCT (f.run_id,f.attempt)) FILTER(WHERE f.run_id IS NOT NULL)::integer AS distinct_attempts
      FROM issue_groups g LEFT JOIN failure_occurrences f ON f.group_id=g.id AND f.company_id=g.company_id
      GROUP BY g.id ORDER BY g.last_seen DESC LIMIT 100
      """)
    end)
  end

  def evidence(scope, id, now \\ Store.now()) do
    with {:ok, _} <- Ecto.UUID.cast(id) do
      Tenancy.with_scope(scope, fn ->
        Store.rows(
          "SELECT e.id::text,e.kind,e.occurred_at,e.received_at,e.expires_at,CASE WHEN e.expires_at > $2 THEN e.data ELSE '{\"status\":\"expired\"}'::jsonb END AS data FROM evidence_items e JOIN failure_occurrences f ON f.evidence_id=e.id AND f.company_id=e.company_id WHERE f.group_id=$1::text::uuid ORDER BY e.received_at DESC LIMIT 20",
          [id, now]
        ) ++
          Store.rows(
            "SELECT e.id::text,e.kind,e.occurred_at,e.received_at,e.expires_at,CASE WHEN e.expires_at > $2 THEN e.data ELSE '{\"status\":\"expired\"}'::jsonb END AS data FROM evidence_items e WHERE e.kind='correlation' AND e.data->>'group_id'=$1 ORDER BY e.received_at DESC LIMIT 5",
            [id, now]
          )
      end)
    else
      _ -> {:error, :not_found}
    end
  end

  def snooze(scope, id, until, now \\ Store.now()) do
    with {:ok, _} <- Ecto.UUID.cast(id),
         true <- match?(%DateTime{}, until),
         true <- DateTime.diff(until, now) in 1..604_800 do
      Tenancy.with_scope(scope, fn ->
        Store.one(
          "UPDATE issue_groups SET snoozed_until=$2 WHERE id=$1::text::uuid RETURNING id::text,snoozed_until",
          [id, until]
        )
      end)
    else
      _ -> {:error, :invalid_snooze}
    end
  end

  def review(scope, id, action, owner \\ nil) do
    with {:ok, _} <- Ecto.UUID.cast(id),
         true <- action in ["locally_acknowledged", "active", "quiet", "closed_by_reviewer"],
         true <- owner == nil or (is_binary(owner) and byte_size(owner) <= 100) do
      Tenancy.with_scope(scope, fn ->
        Store.one(
          "UPDATE issue_groups SET status=$2,owner=$3 WHERE id=$1::text::uuid RETURNING id::text,status",
          [id, action, if(owner, do: OpsBrain.Redactor.clean(owner, 100))]
        )
      end)
    else
      _ -> {:error, :invalid_review}
    end
  end
end
