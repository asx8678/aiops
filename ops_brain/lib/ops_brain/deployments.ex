defmodule OpsBrain.Deployments do
  @moduledoc "Explicit stage-to-target reported deployment attempts; never inferred from build success."
  alias OpsBrain.{Store, Evidence}

  def persist(c, run, body, now) do
    with mappings when is_list(mappings) <- Map.get(c, :stage_targets, []),
         true <- length(mappings) <= 20,
         {:ok, %{"records" => records}} <- Jason.decode(body),
         true <- is_list(records) and length(records) <= 500 do
      for mapping <- mappings,
          record <- records,
          record["type"] == "Stage" and record["identifier"] == mapping["stage_identifier"] and
            record["state"] == "completed" do
        service =
          Store.one(
            "SELECT id::text,environment_id::text FROM service_instances WHERE id=$1::text::uuid",
            [mapping["service_id"]]
          )

        if service do
          data = %{
            "run_id" => run,
            "record_id" => record["id"],
            "attempt" => record["attempt"] || 1,
            "reported_result" => record["result"],
            "target_id" => service["id"],
            "environment_id" => service["environment_id"],
            "basis" =>
              "explicit configured deployment-stage mapping; reported, not runtime-confirmed"
          }

          Evidence.save(
            c,
            "deployment:#{run}:#{record["id"]}:#{data["attempt"]}:#{Store.digest(data)}",
            "deployment",
            data,
            Store.parse(record["finishTime"]) || now,
            now
          )

          groups =
            Store.rows(
              "SELECT id::text,source_id::text FROM issue_groups WHERE data->>'scope'=$1 AND status NOT IN ('closed_by_reviewer','recovered') ORDER BY last_seen DESC LIMIT 100",
              [service["id"]]
            )

          for g <- groups do
            %{source_id: g["source_id"], group_id: g["id"]}
            |> OpsBrain.InvestigationWorker.new()
            |> Oban.insert!()
          end
        end
      end
    else
      _ -> :unavailable
    end
  end
end
