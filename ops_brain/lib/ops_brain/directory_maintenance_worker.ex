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

  alias OpsBrain.{Repo, Store}

  def perform(%Oban.Job{args: args}) when map_size(args) == 0 do
    if Application.get_env(:ops_brain, :maintenance_enabled, false), do: run(), else: :discard
  end

  def perform(_), do: :discard

  defp run do
    case sweep(Store.now()) do
      {:ok, _} -> :ok
      _ -> {:error, :maintenance_failed}
    end
  end

  def sweep(%DateTime{} = now, limit \\ 100) when is_integer(limit) and limit in 1..500 do
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
          [DateTime.add(now, -30, :day), limit]
        ).num_rows

      %{expired_tokens: tokens, expired_attempts: attempts, terminal_jobs: jobs}
    end)
  end
end
