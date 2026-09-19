defmodule OpsBrain.InvestigationWorker do
  use Oban.Worker,
    queue: :enrich,
    max_attempts: 3,
    unique: [period: 60, fields: [:worker, :args], states: [:available, :scheduled, :retryable]]

  alias OpsBrain.{SourceConfig, Store, Evidence, Correlation}

  def perform(%Oban.Job{args: %{"source_id" => source, "group_id" => id}}) do
    case SourceConfig.transaction(source, fn c -> evaluate(c, id, Store.now()) end) do
      {:ok, _} -> :ok
      _ -> :discard
    end
  end

  def evaluate(c, id, now) do
    group =
      Store.one(
        "SELECT id::text,first_seen,data FROM issue_groups WHERE id=$1::text::uuid AND source_id=$2::text::uuid",
        [id, c.id]
      )

    if group do
      service =
        Store.one(
          "SELECT id::text,environment_id::text FROM service_instances WHERE id::text=$1",
          [group["data"]["scope"]]
        )

      symptom =
        Store.one(
          "SELECT f.evidence_id::text,e.received_at FROM failure_occurrences f JOIN evidence_items e ON e.id=f.evidence_id AND e.company_id=f.company_id WHERE f.group_id=$1::text::uuid AND e.expires_at > $2 AND e.received_at <= $2 ORDER BY f.occurred_at LIMIT 1",
          [id, now]
        )

      if service && symptom do
        changes =
          Store.rows(
            "SELECT id::text,occurred_at,received_at,data FROM evidence_items WHERE kind='deployment' AND data->>'target_id'=$1 AND received_at <= $2 AND expires_at > $2 AND occurred_at >= $3 ORDER BY occurred_at DESC LIMIT 20",
            [service["id"], now, DateTime.add(group["first_seen"], -3600)]
          )

        fact = %{
          company_id: c.company_id,
          environment_id: service["environment_id"],
          target_id: service["id"],
          occurred_at: DateTime.to_unix(group["first_seen"]),
          evidence_id: symptom["evidence_id"],
          received_at: DateTime.to_unix(symptom["received_at"])
        }

        inputs =
          Enum.map(changes, fn change ->
            %{
              company_id: c.company_id,
              environment_id: change["data"]["environment_id"],
              target_id: change["data"]["target_id"],
              occurred_at: DateTime.to_unix(change["occurred_at"]),
              received_at: DateTime.to_unix(change["received_at"]),
              evidence_id: change["id"]
            }
          end)

        result = Correlation.evaluate(fact, inputs, [], DateTime.to_unix(now))

        data = %{
          "group_id" => id,
          "result" => result,
          "evaluated_at" => Store.iso(now),
          "version" => 1,
          "symptom" => fact,
          "changes" => inputs,
          "topology" => []
        }

        Evidence.save(
          c,
          "correlation:#{id}:#{Store.digest({result, fact, inputs})}",
          "correlation",
          data,
          now,
          now
        )

        result
      else
        :unresolved_target
      end
    else
      :not_found
    end
  end
end
