defmodule OpsBrain.DirectoryMaintenanceWorker do
  @moduledoc "Bounded expiry of authentication attempts/tokens and terminal global work metadata. No identity or membership administration."
  use Oban.Worker,
    queue: :maintenance,
    max_attempts: 3,
    unique: [
      period: 300,
      fields: [:worker],
      states: [:available, :scheduled, :executing, :retryable]
    ]

  @impl Oban.Worker
  def timeout(_job), do: 300_000

  alias OpsBrain.{Repo, Store}

  @batch 100
  @max_batches 5
  @terminal_age_days 30

  @impl Oban.Worker
  def perform(%Oban.Job{args: args}) when map_size(args) == 0 do
    if Application.get_env(:ops_brain, :maintenance_enabled, false), do: run(), else: :discard
  end

  def perform(_), do: :discard

  defp run do
    now = Store.now()

    case batches(now, @max_batches, %{expired_tokens: 0, expired_attempts: 0, terminal_jobs: 0}) do
      {:ok, counts, more?} ->
        :telemetry.execute(
          [:ops_brain, :maintenance, :directory],
          Map.put(counts, :oldest_job_age_seconds, oldest_terminal_job_age(now)),
          %{}
        )

        if more?, do: {:snooze, 5}, else: :ok

      _ ->
        {:error, :maintenance_failed}
    end
  end

  defp batches(_now, remaining, acc) when remaining <= 0, do: {:ok, acc, true}

  defp batches(now, remaining, acc) do
    case sweep(now, @batch) do
      {:ok, counts} ->
        acc = Map.merge(acc, counts, fn _k, a, b -> a + b end)

        full? =
          counts.expired_tokens == @batch or counts.expired_attempts == @batch or
            counts.terminal_jobs == @batch

        if full? and remaining > 1,
          do: batches(now, remaining - 1, acc),
          else: {:ok, acc, full?}

      _ ->
        {:error, :maintenance_failed}
    end
  end

  defp oldest_terminal_job_age(now) do
    Store.one(
      "SELECT COALESCE(EXTRACT(EPOCH FROM ($1 - MIN(COALESCE(completed_at,discarded_at,cancelled_at,attempted_at,inserted_at))))::bigint,0) AS age FROM oban_jobs WHERE state IN ('completed','discarded','cancelled')",
      [now]
    )["age"]
  end

  def sweep(%DateTime{} = now, limit \\ @batch) when is_integer(limit) and limit in 1..500 do
    Repo.transaction(fn ->
      Repo.query!("SET LOCAL lock_timeout='1s'")
      Repo.query!("SET LOCAL statement_timeout='5s'")

      tokens =
        Repo.query!(
          """
          WITH rows AS MATERIALIZED (SELECT token_hash FROM operator_tokens WHERE expires_at <= $1 ORDER BY expires_at LIMIT $2)
          DELETE FROM operator_tokens WHERE token_hash IN (SELECT token_hash FROM rows)
          """,
          [now, limit]
        ).num_rows

      attempts =
        Repo.query!(
          """
          WITH rows AS MATERIALIZED (SELECT state_hash FROM oidc_attempts WHERE expires_at <= $1 ORDER BY expires_at LIMIT $2)
          DELETE FROM oidc_attempts WHERE state_hash IN (SELECT state_hash FROM rows)
          """,
          [DateTime.to_unix(now), limit]
        ).num_rows

      jobs =
        Repo.query!(
          """
          WITH rows AS MATERIALIZED (SELECT id FROM oban_jobs WHERE state IN ('completed','discarded','cancelled')
            AND COALESCE(completed_at,discarded_at,cancelled_at,attempted_at,inserted_at) < $1
            ORDER BY id LIMIT $2 FOR UPDATE SKIP LOCKED)
          DELETE FROM oban_jobs WHERE id IN (SELECT id FROM rows)
          """,
          [DateTime.add(now, -@terminal_age_days, :day), limit]
        ).num_rows

      %{expired_tokens: tokens, expired_attempts: attempts, terminal_jobs: jobs}
    end)
  end
end
