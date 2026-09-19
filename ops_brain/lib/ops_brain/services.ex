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

  def overview(scope) do
    Tenancy.with_scope(scope, fn ->
      Store.rows(
        "SELECT s.id::text,s.service_key,s.target,e.name AS environment, s.source_id::text FROM service_instances s JOIN environments e ON e.id=s.environment_id AND e.company_id=s.company_id ORDER BY s.service_key,e.name LIMIT 100"
      )
    end)
  end

  def windows(scope) do
    Tenancy.with_scope(scope, fn ->
      Store.rows(
        "SELECT id::text,service_id::text,kind,profile,window_start,window_end,received_at,revision,data FROM observation_windows ORDER BY window_end DESC LIMIT 100"
      )
    end)
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
