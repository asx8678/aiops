defmodule OpsBrain.Repo.Migrations.AddSourceRetentionPolicyColumns do
  use Ecto.Migration

  @moduledoc """
  R10: persist a retention-policy snapshot on the durable source identity so
  maintenance no longer depends on an enabled, present configuration entry.
  A removed source keeps its known policy; an unknown historical policy stays
  explicitly unknown and is never guessed.
  """

  def up do
    alter table(:sources) do
      add :retention_days, :integer
      add :retention_policy_version, :integer, null: false, default: 1
      add :retired_at, :utc_datetime_usec
    end

    create constraint(:sources, :retention_days_bounds,
             check: "retention_days IS NULL OR retention_days BETWEEN 1 AND 90"
           )
  end

  def down do
    drop constraint(:sources, :retention_days_bounds)

    alter table(:sources) do
      remove :retention_days
      remove :retention_policy_version
      remove :retired_at
    end
  end
end
