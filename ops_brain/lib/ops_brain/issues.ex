defmodule OpsBrain.Issues do
  @moduledoc "Local notices: separate fingerprint identities and event-time bounded episodes. No upstream actions."
  alias OpsBrain.{Repo, Store, Tenancy, Lifecycle, Redactor}

  # One logical occurrence per operation/attempt/window. Improved evidence is an
  # append-only revision pointing at the occurrence, not a second occurrence.
  def record(c, key, evidence_id, fp, identity, now) do
    event_at =
      case Lifecycle.event_time(Map.get(identity, :occurred_at), now) do
        {:error, reason} -> Repo.rollback(reason)
        at -> at
      end

    observed = Map.get(identity, :severity) || "warning"

    # Serialize even the absent-row case before reading the occurrence.
    Repo.query!("SELECT pg_advisory_xact_lock(hashtextextended($1,0))", [
      "occurrence:" <> c.company_id <> ":" <> c.id <> ":" <> key
    ])

    existing =
      Store.one(
        "SELECT id::text,group_id::text,evidence_id::text,evidence_revision,fingerprint,parser_version FROM failure_occurrences WHERE source_id=$1::text::uuid AND occurrence_key=$2 FOR UPDATE",
        [c.id, key]
      )

    lock_fingerprints(existing, fp.fingerprint)

    if existing == nil do
      create_occurrence(c, key, evidence_id, fp, event_at, observed, identity, now)
    else
      improve_occurrence(c, existing, evidence_id, fp, event_at, observed, identity, now)
    end
  end

  defp lock_fingerprints(nil, fingerprint), do: lock(fingerprint)

  defp lock_fingerprints(existing, fingerprint) do
    [existing["fingerprint"], fingerprint]
    |> Enum.reject(&is_nil/1)
    |> Enum.uniq()
    |> Enum.sort()
    |> Enum.each(&lock/1)
  end

  defp lock(fingerprint),
    do: Repo.query!("SELECT pg_advisory_xact_lock(hashtextextended($1,0))", [fingerprint])

  defp create_occurrence(c, key, evidence_id, fp, event_at, observed, identity, now) do
    ensure_fingerprint(c, fp)
    group_id = upsert_group(c, fp, event_at, observed, identity)

    occurrence_id = Ecto.UUID.generate()

    Repo.query!(
      "INSERT INTO failure_occurrences(id,company_id,source_id,occurrence_key,group_id,evidence_id,run_id,attempt,occurred_at,evidence_revision,fingerprint,parser_version) VALUES($1::text::uuid,$2::text::uuid,$3::text::uuid,$4,$5::text::uuid,$6::text::uuid,$7,$8,$9,1,$10,$11)",
      [
        occurrence_id,
        c.company_id,
        c.id,
        key,
        group_id,
        evidence_id,
        identity[:run_id],
        identity[:attempt],
        event_at,
        fp.fingerprint,
        fp.parser_version
      ]
    )

    insert_link(c, occurrence_id, evidence_id, 1, fp, "initial", now)
    finish_record(c, group_id, now, nil)
    group_id
  end

  defp improve_occurrence(c, occ, evidence_id, fp, event_at, observed, identity, now) do
    same_fingerprint = occ["fingerprint"] == fp.fingerprint
    same_evidence = occ["evidence_id"] == evidence_id
    revision = occ["evidence_revision"] + 1

    cond do
      (same_evidence and same_fingerprint and occ["parser_version"] == fp.parser_version) or
          linked?(occ["id"], evidence_id, fp) ->
        # Repeated identical evidence: no new revision, no duplicate count.
        occ["group_id"]

      stale_evidence?(occ["evidence_id"], evidence_id) ->
        Repo.query!(
          "UPDATE failure_occurrences SET evidence_revision=$2 WHERE id=$1::text::uuid",
          [occ["id"], revision]
        )

        insert_link(
          c,
          occ["id"],
          evidence_id,
          revision,
          fp,
          "stale_ignored",
          now
        )

        occ["group_id"]

      same_fingerprint ->
        touch_group(c, occ["group_id"], event_at, observed)

        Repo.query!(
          "UPDATE failure_occurrences SET evidence_id=$2::text::uuid,evidence_revision=$3,occurred_at=LEAST(occurred_at,$4),parser_version=$5 WHERE id=$1::text::uuid",
          [occ["id"], evidence_id, revision, event_at, fp.parser_version]
        )

        insert_link(c, occ["id"], evidence_id, revision, fp, "improved_evidence", now)
        finish_record(c, occ["group_id"], now, nil)
        occ["group_id"]

      true ->
        # Classification change: move the occurrence to the correct group and
        # keep the original as history. Counters derive from group_id, so moving
        # cannot double count. Reviewer state on the old group is preserved.
        ensure_fingerprint(c, fp)
        group_id = upsert_group(c, fp, event_at, observed, identity)

        Repo.query!(
          "UPDATE failure_occurrences SET group_id=$2::text::uuid,evidence_id=$3::text::uuid,evidence_revision=$4,fingerprint=$5,parser_version=$6,occurred_at=LEAST(occurred_at,$7) WHERE id=$1::text::uuid",
          [
            occ["id"],
            group_id,
            evidence_id,
            revision,
            fp.fingerprint,
            fp.parser_version,
            event_at
          ]
        )

        insert_link(c, occ["id"], evidence_id, revision, fp, "reclassified", now)
        finish_record(c, group_id, now, occ["group_id"])
        group_id
    end
  end

  defp linked?(occurrence_id, evidence_id, fp) do
    Store.one(
      "SELECT id FROM occurrence_evidence WHERE occurrence_id=$1::text::uuid AND evidence_id=$2::text::uuid AND fingerprint=$3 AND parser_version=$4",
      [occurrence_id, evidence_id, fp.fingerprint, fp.parser_version]
    ) != nil
  end

  defp stale_evidence?(current_id, candidate_id) do
    current =
      Store.one("SELECT received_at FROM evidence_items WHERE id=$1::text::uuid", [current_id])

    candidate =
      Store.one("SELECT received_at FROM evidence_items WHERE id=$1::text::uuid", [candidate_id])

    current != nil and candidate != nil and
      DateTime.compare(candidate["received_at"], current["received_at"]) == :lt
  end

  defp ensure_fingerprint(c, fp) do
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
  end

  defp find_group(c, fingerprint, event_at) do
    Store.one(
      "SELECT id::text,severity FROM issue_groups WHERE fingerprint=$1 AND company_id=$2::text::uuid AND status NOT IN ('recovered','closed_by_reviewer') AND last_seen >= $3 AND first_seen <= $4 ORDER BY last_seen DESC,id DESC LIMIT 1 FOR UPDATE",
      [
        fingerprint,
        c.company_id,
        Lifecycle.episode_floor(event_at),
        DateTime.add(event_at, Lifecycle.episode_gap_seconds())
      ]
    )
  end

  defp upsert_group(c, fp, event_at, observed, identity) do
    case find_group(c, fp.fingerprint, event_at) do
      %{"id" => id, "severity" => severity} ->
        Repo.query!(
          "UPDATE issue_groups SET first_seen=LEAST(first_seen,$2),last_seen=GREATEST(last_seen,$2),severity=$3,revision=revision+1 WHERE id=$1::text::uuid",
          [id, event_at, Lifecycle.escalate(severity, observed)]
        )

        id

      nil ->
        id = Ecto.UUID.generate()

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
          [id, c.company_id, c.id, fp.fingerprint, fp.parser_version, event_at, observed, data]
        )

        id
    end
  end

  defp touch_group(c, id, event_at, observed) do
    group =
      Store.one(
        "SELECT severity FROM issue_groups WHERE id=$1::text::uuid AND company_id=$2::text::uuid FOR UPDATE",
        [id, c.company_id]
      )

    if group do
      Repo.query!(
        "UPDATE issue_groups SET first_seen=LEAST(first_seen,$2),last_seen=GREATEST(last_seen,$2),severity=$3,revision=revision+1 WHERE id=$1::text::uuid AND company_id=$4::text::uuid",
        [id, event_at, Lifecycle.escalate(group["severity"], observed), c.company_id]
      )
    end
  end

  defp insert_link(c, occurrence_id, evidence_id, revision, fp, reason, now) do
    Repo.query!(
      "INSERT INTO occurrence_evidence(id,company_id,source_id,occurrence_id,evidence_id,revision,fingerprint,parser_version,reason,inserted_at,group_id) VALUES($1::text::uuid,$2::text::uuid,$3::text::uuid,$4::text::uuid,$5::text::uuid,$6,$7,$8,$9,$10,(SELECT group_id FROM failure_occurrences WHERE id=$4::text::uuid))",
      [
        Ecto.UUID.generate(),
        c.company_id,
        c.id,
        occurrence_id,
        evidence_id,
        revision,
        fp.fingerprint,
        fp.parser_version,
        reason,
        now
      ]
    )
  end

  defp finish_record(c, group_id, now, old_group) do
    %{source_id: c.id, group_id: group_id} |> OpsBrain.InvestigationWorker.new() |> Oban.insert!()
    OpsBrain.Notifications.prepare(c, group_id, now)

    if is_binary(old_group) and old_group != group_id do
      Repo.query!(
        "UPDATE issue_groups SET revision=revision+1,data=data || '{\"classification_revised\":true}'::jsonb WHERE id=$1::text::uuid",
        [old_group]
      )

      if Store.one("SELECT id FROM failure_occurrences WHERE group_id=$1::text::uuid LIMIT 1", [
           old_group
         ]) do
        OpsBrain.Notifications.prepare(c, old_group, now)
      else
        Repo.query!(
          "UPDATE notification_outbox SET status='coalesced',updated_at=$2 WHERE group_id=$1::text::uuid AND status='pending'",
          [old_group, now]
        )
      end
    end
  end

  def list(scope) do
    Tenancy.with_scope(scope, fn ->
      # Limit groups before counting. Exact counts still read retained occurrences
      # of those groups; they do not aggregate the entire tenant's history.
      Store.rows("""
      WITH page AS MATERIALIZED (
        SELECT * FROM issue_groups ORDER BY last_seen DESC, id DESC LIMIT 100
      )
      SELECT g.id::text,g.source_id::text,g.first_seen,g.last_seen,g.status,g.owner,g.severity,g.snoozed_until,g.data,g.revision,
        counts.occurrences,counts.distinct_runs,counts.distinct_attempts
      FROM page g CROSS JOIN LATERAL (
        SELECT count(*)::integer AS occurrences,count(DISTINCT f.run_id)::integer AS distinct_runs,
          count(DISTINCT (f.run_id,f.attempt)) FILTER(WHERE f.run_id IS NOT NULL)::integer AS distinct_attempts
        FROM failure_occurrences f WHERE f.group_id=g.id AND f.company_id=g.company_id
      ) counts ORDER BY g.last_seen DESC, g.id DESC
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
            "SELECT e.id::text,e.kind,e.occurred_at,e.received_at,e.expires_at,CASE WHEN e.expires_at > $2 THEN e.data ELSE '{\"status\":\"expired\"}'::jsonb END AS data FROM evidence_items e WHERE (e.kind='correlation' AND e.data->>'group_id'=$1) OR e.id::text=(SELECT data->>'recovery_evidence_id' FROM issue_groups WHERE id=$1::text::uuid) ORDER BY e.received_at DESC LIMIT 5",
            [id, now]
          )
      end)
    else
      _ -> {:error, :not_found}
    end
  end

  @doc "Append-only evidence revision history for the occurrences in a group."
  def revisions(scope, id, now \\ Store.now()) do
    with {:ok, _} <- Ecto.UUID.cast(id) do
      Tenancy.with_scope(scope, fn ->
        Store.rows(
          "SELECT e.id::text,e.kind,e.occurred_at,e.received_at,e.expires_at,CASE WHEN e.expires_at > $2 THEN e.data ELSE '{\"status\":\"expired\"}'::jsonb END AS data,oe.revision,oe.reason,oe.fingerprint,oe.parser_version,oe.group_id::text,(oe.evidence_id=f.evidence_id AND oe.fingerprint=f.fingerprint AND oe.parser_version=f.parser_version) AS current FROM occurrence_evidence oe JOIN failure_occurrences f ON f.id=oe.occurrence_id AND f.company_id=oe.company_id JOIN evidence_items e ON e.id=oe.evidence_id AND e.company_id=oe.company_id WHERE (f.group_id=$1::text::uuid OR oe.group_id=$1::text::uuid) ORDER BY oe.revision DESC LIMIT 50",
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

  def review(scope, id, action, opts \\ [])

  def review(scope, id, action, owner) when is_binary(owner) or is_nil(owner),
    do: review_impl(scope, id, action, owner: owner)

  def review(scope, id, action, opts) when is_list(opts),
    do: review_impl(scope, id, action, opts)

  def assign(scope, id, owner) do
    with {:ok, _} <- Ecto.UUID.cast(id),
         {:ok, cleaned} <- validate_assign_owner(owner) do
      Tenancy.with_scope(scope, fn ->
        Store.one(
          "UPDATE issue_groups SET owner=$2,revision=revision+1 WHERE id=$1::text::uuid RETURNING id::text,owner",
          [id, cleaned]
        )
      end)
    else
      _ -> {:error, :invalid_owner}
    end
  end

  def unassign(scope, id) do
    with {:ok, _} <- Ecto.UUID.cast(id) do
      Tenancy.with_scope(scope, fn ->
        Store.one(
          "UPDATE issue_groups SET owner=NULL,revision=revision+1 WHERE id=$1::text::uuid RETURNING id::text,owner",
          [id]
        )
      end)
    else
      _ -> {:error, :not_found}
    end
  end

  defp review_impl(scope, id, action, opts) do
    owner = Keyword.get(opts, :owner)

    with {:ok, _} <- Ecto.UUID.cast(id),
         {:ok, action} <- Lifecycle.review_status(action),
         {:ok, owner} <- validate_review_owner(owner) do
      result =
        Tenancy.with_scope(scope, fn ->
          current =
            Store.one(
              "SELECT id::text,status FROM issue_groups WHERE id=$1::text::uuid FOR UPDATE",
              [id]
            )

          cond do
            current == nil ->
              nil

            match?({:error, _}, Lifecycle.review_status(current["status"], action)) ->
              {:error, :invalid_transition}

            true ->
              Store.one(
                "UPDATE issue_groups SET status=$2,owner=COALESCE($3,owner),revision=revision+1 WHERE id=$1::text::uuid RETURNING id::text,status,owner",
                [id, action, owner]
              )
          end
        end)

      case result do
        {:ok, {:error, reason}} -> {:error, reason}
        other -> other
      end
    else
      _ -> {:error, :invalid_review}
    end
  end

  defp validate_review_owner(nil), do: {:ok, nil}

  defp validate_review_owner(owner) when is_binary(owner) and byte_size(owner) <= 100,
    do: {:ok, Redactor.clean(owner, 100)}

  defp validate_review_owner(_), do: {:error, :invalid_owner}

  defp validate_assign_owner(owner) when is_binary(owner) and byte_size(owner) in 1..100,
    do: {:ok, Redactor.clean(owner, 100)}

  defp validate_assign_owner(_), do: {:error, :invalid_owner}
end
