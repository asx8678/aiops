defmodule OpsBrain.Evaluations do
  @moduledoc "Persist deterministic results with selected input identities and explicit missing prerequisites."
  alias OpsBrain.{Store, Evidence, Capacity, Fingerprints, Issues}

  def capacity(c, finish, now) do
    policy = get_in(c, [:profile, :capacity_policy])

    if policy && c[:service_id] do
      rows =
        Store.rows(
          "SELECT id::text,window_end,received_at,data FROM observation_windows WHERE source_id=$1::text::uuid AND kind='prometheus' AND window_end <= $2 AND received_at <= $3 ORDER BY window_end DESC LIMIT 60",
          [c.id, finish, now]
        )
        |> Enum.reverse()

      samples =
        Enum.flat_map(rows, fn r ->
          case r["data"]["samples"] do
            [s] ->
              [
                %{
                  time: DateTime.to_unix(r["window_end"]),
                  received_at: DateTime.to_unix(r["received_at"]),
                  value: s["value"],
                  unit: r["data"]["unit"],
                  series: s["series"],
                  segment: r["data"]["capacity_segment"]
                }
              ]

            _ ->
              []
          end
        end)

      result = Capacity.evaluate(samples, policy, DateTime.to_unix(now))

      data = %{
        "detector" => "storage_headroom",
        "version" => 1,
        "result" => result,
        "input_window_ids" => Enum.map(rows, & &1["id"]),
        "input_samples" => samples,
        "policy" => policy,
        "as_of" => Store.iso(now)
      }

      evidence =
        Evidence.save(
          c,
          "capacity:#{Store.iso(finish)}:#{Store.digest(data)}",
          "capacity_evaluation",
          data,
          finish,
          now
        )

      if result.condition in ["warning", "critical"] do
        fp =
          Fingerprints.identify(
            c.company_id,
            c.service_id,
            "storage_headroom_v1",
            "Conditional storage threshold estimate"
          )

        Issues.record(
          c,
          "capacity:#{Store.iso(finish)}",
          evidence,
          fp,
          %{
            occurred_at: finish,
            severity: result.condition,
            scope: c.service_id,
            count_basis: "distinct evaluation windows; conditional estimate"
          },
          now
        )
      end

      result
    end
  end

  def correlate(scope, symptom_id, change_ids, topology, now) do
    if length(change_ids) <= 20 do
      OpsBrain.Tenancy.with_scope(scope, fn ->
        ids = [symptom_id | change_ids]

        rows =
          Store.rows(
            "SELECT id::text,source_id::text,kind,occurred_at,received_at,expires_at,data FROM evidence_items WHERE id::text=ANY($1) AND received_at <= $2 AND expires_at > $2",
            [ids, now]
          )

        symptom = Enum.find(rows, &(&1["id"] == symptom_id))

        if symptom && symptom["data"]["target_id"] && symptom["data"]["environment_id"] do
          fact = fn e ->
            %{
              company_id: scope.company_id,
              environment_id: e["data"]["environment_id"],
              target_id: e["data"]["target_id"],
              evidence_id: e["id"],
              occurred_at: DateTime.to_unix(e["occurred_at"]),
              received_at: DateTime.to_unix(e["received_at"])
            }
          end

          changes =
            Enum.filter(rows, &(&1["id"] in change_ids and &1["kind"] == "deployment"))
            |> Enum.map(fact)

          # Topology must be provided by trusted configuration, not a browser event.
          OpsBrain.Correlation.evaluate(fact.(symptom), changes, topology, DateTime.to_unix(now))
        else
          %{
            condition: "unknown",
            missing: "Explicit deployment/target/environment evidence unavailable"
          }
        end
      end)
    else
      {:error, :input_limit}
    end
  end
end
