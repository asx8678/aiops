defmodule OpsBrain.Repo.Migrations.AddReplayAndWorkloadCursors do
  use Ecto.Migration

  def up do
    create table(:observation_revisions, primary_key: false) do
      add :id, :uuid, primary_key: true
      add :company_id, :uuid, null: false
      add :source_id, :uuid, null: false
      add :window_id, :uuid, null: false
      add :service_id, :uuid
      add :profile, :text, null: false
      add :kind, :text, null: false
      add :window_start, :utc_datetime_usec, null: false
      add :window_end, :utc_datetime_usec, null: false
      add :received_at, :utc_datetime_usec, null: false
      add :revision, :integer, null: false
      add :detector_version, :integer, null: false, default: 1
      add :data, :map, null: false
      add :policy, :map, null: false
    end

    create unique_index(:observation_revisions, [:company_id, :window_id, :revision])
    create index(:observation_revisions, [:company_id, :source_id, :received_at, :id])

    create constraint(:observation_revisions, :revision_bounds,
             check:
               "revision > 0 AND window_end > window_start AND octet_length(data::text) <= 65536 AND octet_length(policy::text) <= 16384"
           )

    # No FK to the mutable window: retention may delete a projection before replay history.
    execute "ALTER TABLE observation_revisions ADD CONSTRAINT revision_service_scope FOREIGN KEY(company_id,service_id) REFERENCES service_instances(company_id,id)"

    create table(:kubernetes_cursors, primary_key: false) do
      add :company_id, :uuid, null: false
      add :source_id, :uuid, primary_key: true
      add :resource, :text, primary_key: true
      add :revision, :bigint, null: false, default: 1
      add :updated_at, :utc_datetime_usec, null: false
      add :data, :map, null: false
    end

    create constraint(:kubernetes_cursors, :cursor_bound,
             check:
               "resource IN ('pods','deployments','replicasets','events') AND octet_length(data::text) <= 524288"
           )

    for table <- ~w(observation_revisions kubernetes_cursors) do
      execute "ALTER TABLE #{table} ADD CONSTRAINT #{table}_source_scope FOREIGN KEY(company_id,source_id) REFERENCES sources(company_id,id) ON DELETE CASCADE"
      execute "ALTER TABLE #{table} ENABLE ROW LEVEL SECURITY"
      execute "ALTER TABLE #{table} FORCE ROW LEVEL SECURITY"

      execute "CREATE POLICY company_scope ON #{table} USING(company_id=NULLIF(current_setting('ops_brain.company_id',true),'')::uuid) WITH CHECK(company_id=NULLIF(current_setting('ops_brain.company_id',true),'')::uuid)"
    end
  end

  def down do
    drop table(:kubernetes_cursors)
    drop table(:observation_revisions)
  end
end
