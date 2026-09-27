defmodule OpsBrain.Services do
  @moduledoc "Explicit service/environment/source/target identity; no inference from CI names."
  alias OpsBrain.{Tenancy, Store}

  def create(scope, attrs) do
    with {:ok, _} <- Ecto.UUID.cast(attrs[:source_id]),
         {:ok, _} <- Ecto.UUID.cast(attrs[:environment_id]),
         true <- is_binary(attrs[:service_key]) and byte_size(attrs.service_key) in 1..100,
         true <- is_binary(attrs[:target]) and byte_size(attrs.target) in 1..200 do
      Tenancy.with_scope(scope, fn ->
        Store.one(
          "INSERT INTO service_instances(id,company_id,source_id,environment_id,service_key,target) VALUES($1::text::uuid,$2::text::uuid,$3::text::uuid,$4::text::uuid,$5,$6) RETURNING id::text",
          [
            Ecto.UUID.generate(),
            scope.company_id,
            attrs.source_id,
            attrs.environment_id,
            attrs.service_key,
            attrs.target
          ]
        )
      end)
    else
      _ -> {:error, :invalid_identity}
    end
  rescue
    _ in Postgrex.Error -> {:error, :invalid_relationship}
  end

  # An environment selection is applied in SQL before the bounded read, so
  # services from other environments cannot occupy the cap. "prod"/"staging"/
  # "dev" select; "" keeps every record.
  def overview(scope, environment \\ "") do
    Tenancy.with_scope(scope, fn ->
      Store.rows(
        "SELECT s.id::text,s.service_key,s.target,e.name AS environment, s.source_id::text FROM service_instances s JOIN environments e ON e.id=s.environment_id AND e.company_id=s.company_id WHERE ($1::text='' OR e.name::text=$1) ORDER BY s.service_key,e.name LIMIT 100",
        [environment]
      )
    end)
  end

  def windows(scope, environment \\ "") do
    Tenancy.with_scope(scope, fn ->
      Store.rows(
        "SELECT id::text,service_id::text,kind,profile,window_start,window_end,received_at,revision,data FROM observation_windows WHERE ($1::text='' OR service_id IN (SELECT si.id FROM service_instances si JOIN environments en ON en.id=si.environment_id AND en.company_id=si.company_id WHERE en.name::text=$1)) ORDER BY window_end DESC LIMIT 100",
        [environment]
      )
    end)
  end

  @doc "Unexpired stored capacity results. Environment selection precedes the bounded page."
  def capacity_evaluations(scope, environment \\ "", now \\ Store.now()) do
    if environment in ["", "dev", "staging", "prod"] do
      Tenancy.with_scope(scope, fn ->
        Store.rows(
          """
          SELECT e.id::text,e.source_id::text,e.occurred_at,e.received_at,e.expires_at,e.data,
            e.data->>'profile' AS profile,s.id::text AS service_id,s.service_key,s.target,
            env.name AS environment
          FROM evidence_items e
          LEFT JOIN observation_windows w ON w.company_id=e.company_id AND w.source_id=e.source_id
            AND NOT (e.data ? 'service_id') AND NOT (e.data ? 'target_id')
            AND w.id::text=e.data->'input_window_ids'->>0 AND w.profile=e.data->>'profile'
          LEFT JOIN service_instances s ON s.company_id=e.company_id
            AND s.id::text=COALESCE(e.data->>'service_id',e.data->>'target_id',w.service_id::text)
          LEFT JOIN environments env ON env.company_id=s.company_id AND env.id=s.environment_id
          WHERE e.kind='capacity_evaluation' AND e.expires_at > $1 AND NOT (e.data ? 'expired')
            AND ($2::text='' OR env.name::text=$2)
          ORDER BY e.occurred_at DESC,e.received_at DESC,e.id DESC LIMIT 100
          """,
          [now, environment]
        )
        |> Enum.map(fn row ->
          result =
            case row["data"]["result"] do
              %{"condition" => condition} = result
              when condition in ["normal", "warning", "critical", "unknown"] ->
                result

              _ ->
                %{
                  "condition" => "unknown",
                  "reason" => "Retained evidence has no structured capacity evaluation"
                }
            end

          Map.put(row, "result", result)
        end)
      end)
    else
      {:error, :invalid_environment}
    end
  end

  def sources(scope, now \\ Store.now()) do
    Tenancy.with_scope(scope, fn ->
      Store.rows(
        "SELECT s.id::text,s.name,s.kind,c.coverage,c.error,c.last_success_at,c.completed_at,b.requests,b.bytes,b.errors FROM sources s LEFT JOIN collection_states c ON c.source_id=s.id AND c.company_id=s.company_id LEFT JOIN source_budgets b ON b.source_id=s.id AND b.company_id=s.company_id ORDER BY s.name LIMIT 100"
      )
      |> Enum.map(fn r ->
        fresh =
          case r["last_success_at"] do
            nil ->
              "not_configured_or_unavailable"

            t ->
              if DateTime.diff(now, t) > 300 or
                   (r["completed_at"] != nil and DateTime.diff(now, r["completed_at"]) > 300),
                 do: "stale",
                 else: r["coverage"]
          end

        Map.put(r, "freshness", fresh)
      end)
    end)
  end
end
