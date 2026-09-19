defmodule OpsBrain.Budgets do
  @moduledoc "Shared source rate/concurrency admission. No transaction spans HTTP."
  alias OpsBrain.{SourceConfig, Store, Repo}

  def reserve(id, now) do
    SourceConfig.transaction(id, fn c ->
      Repo.query!(
        "INSERT INTO source_budgets(company_id,source_id,next_at,period_start) VALUES($1::text::uuid,$2::text::uuid,$3,$3) ON CONFLICT DO NOTHING",
        [c.company_id, id, now]
      )

      s =
        Store.one("SELECT * FROM source_budgets WHERE source_id=$1::text::uuid FOR UPDATE", [id])

      reset = s["period_start"] == nil or DateTime.diff(now, s["period_start"]) >= 60
      count = if reset, do: 0, else: s["period_requests"]

      if DateTime.compare(s["next_at"], now) == :gt or
           (not is_nil(s["in_flight_until"]) and
              DateTime.compare(s["in_flight_until"], now) == :gt) or
           count >= Map.get(c, :requests_per_minute, 6) do
        Repo.rollback(:source_budget_exhausted)
      end

      reservation = Ecto.UUID.generate()

      Repo.query!(
        "UPDATE source_budgets SET period_start=$2,period_requests=$3,requests=requests+1,in_flight_until=$4,reservation=$5::text::uuid WHERE source_id=$1::text::uuid",
        [
          id,
          if(reset, do: now, else: s["period_start"]),
          count + 1,
          DateTime.add(now, 20),
          reservation
        ]
      )

      {:reserved, reservation}
    end)
  end

  def finish(id, reservation, response, now) do
    SourceConfig.transaction(id, fn _ ->
      {bytes, delay, error} =
        case response do
          {:ok, r} ->
            {r.bytes, OpsBrain.Transport.retry_seconds(r.headers, now),
             if(r.status in 200..299, do: 0, else: 1)}

          _ ->
            {0, 30, 1}
        end

      Repo.query!(
        "UPDATE source_budgets SET bytes=bytes+$2,errors=errors+$3,next_at=GREATEST(next_at,$4),in_flight_until=NULL,reservation=NULL WHERE source_id=$1::text::uuid AND reservation=$5::text::uuid",
        [id, bytes, error, DateTime.add(now, delay), reservation]
      )
    end)

    response
  end
end
