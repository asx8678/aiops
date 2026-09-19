defmodule OpsBrain.Health do
  @moduledoc "Internal monitoring aggregates; never exposes job arguments, errors or company data on operator pages."
  def measure do
    case OpsBrain.Repo.query(
           "SELECT count(*)::bigint, COALESCE(EXTRACT(EPOCH FROM (now()-min(scheduled_at))),0)::float8, pg_database_size(current_database()) FROM oban_jobs WHERE state IN ('available','scheduled','retryable') AND scheduled_at <= now()"
         ) do
      {:ok, %{rows: [[count, age, size]]}} ->
        :telemetry.execute(
          [:ops_brain, :health],
          %{queued_jobs: count, oldest_job_seconds: max(age, 0), database_bytes: size},
          %{}
        )

      {:error, _} ->
        :telemetry.execute([:ops_brain, :health, :unavailable], %{count: 1}, %{})
    end
  end
end
