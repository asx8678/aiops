defmodule OpsBrain.Repo.Migrations.AddOperationsReadIndexes do
  use Ecto.Migration

  def change do
    create index(:issue_groups, [:company_id, :last_seen, :id])
    create index(:failure_occurrences, [:company_id, :group_id, :run_id, :attempt])
    create index(:pipeline_runs, [:company_id, :received_at, :id])
    create index(:notification_outbox, [:company_id, :group_id, :updated_at, :id])

    create index(:evidence_items, [:company_id, :source_id, "(data->>'run_id')", :received_at],
             name: :deployment_run_read_index,
             where: "kind = 'deployment'"
           )
  end
end
