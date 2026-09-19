defmodule OpsBrain.Repo.Migrations.AddDurableCollection do
  use Ecto.Migration

  def up do
    drop constraint(:sources, :source_kind)

    create constraint(:sources, :source_kind,
             check: "kind IN ('azure_build','prometheus','loki','kubernetes')"
           )

    create table(:collection_states, primary_key: false) do
      add :company_id, references(:companies, type: :uuid, on_delete: :delete_all), null: false
      add :source_id, :uuid, primary_key: true
      add :fence, :bigint, default: 0, null: false
      add :lease_until, :utc_datetime_usec
      add :next_at, :utc_datetime_usec
      add :completed_at, :utc_datetime_usec
      add :window_start, :utc_datetime_usec
      add :window_end, :utc_datetime_usec
      add :cursor, :text
      add :pages, :integer, default: 0, null: false
      add :coverage, :string, default: "not_configured", null: false
      add :error, :string
      add :mode, :string, default: "completed", null: false
      add :reconcile_ids, {:array, :bigint}, default: [], null: false
      add :requests, :bigint, default: 0, null: false
      add :bytes, :bigint, default: 0, null: false
      add :last_success_at, :utc_datetime_usec
    end

    create table(:pipeline_runs, primary_key: false) do
      add :id, :uuid, primary_key: true
      add :company_id, references(:companies, type: :uuid, on_delete: :delete_all), null: false
      add :source_id, :uuid, null: false
      add :project_id, :uuid, null: false
      add :run_id, :bigint, null: false
      add :definition_id, :bigint, null: false
      add :status, :string, null: false
      add :result, :string
      add :finish_at, :utc_datetime_usec
      add :received_at, :utc_datetime_usec, null: false
      add :revision, :integer, default: 1, null: false
      add :data, :map, default: %{}, null: false
    end

    create unique_index(:pipeline_runs, [:company_id, :source_id, :project_id, :run_id])
    create index(:pipeline_runs, [:company_id, :source_id, :finish_at])
    create unique_index(:pipeline_runs, [:company_id, :id])

    create table(:run_snapshots, primary_key: false) do
      add :id, :uuid, primary_key: true
      add :company_id, references(:companies, type: :uuid, on_delete: :delete_all), null: false
      add :source_id, :uuid, null: false
      add :run_id, :uuid, null: false
      add :digest, :string, null: false
      add :received_at, :utc_datetime_usec, null: false
      add :data, :map, null: false
    end

    create unique_index(:run_snapshots, [:company_id, :run_id, :digest])

    execute "ALTER TABLE run_snapshots ADD CONSTRAINT snapshot_run_scope FOREIGN KEY (company_id,run_id) REFERENCES pipeline_runs(company_id,id) ON DELETE CASCADE"

    for table <- ~w(collection_states pipeline_runs run_snapshots) do
      execute "ALTER TABLE #{table} ADD CONSTRAINT #{table}_source_scope FOREIGN KEY (company_id,source_id) REFERENCES sources(company_id,id) ON DELETE CASCADE"
      execute "ALTER TABLE #{table} ENABLE ROW LEVEL SECURITY"
      execute "ALTER TABLE #{table} FORCE ROW LEVEL SECURITY"

      execute "CREATE POLICY company_scope ON #{table} USING (company_id = NULLIF(current_setting('ops_brain.company_id',true),'')::uuid) WITH CHECK (company_id = NULLIF(current_setting('ops_brain.company_id',true),'')::uuid)"
    end
  end

  def down do
    drop table(:run_snapshots)
    drop table(:pipeline_runs)
    drop table(:collection_states)
    # Existing non-Build sources must be removed explicitly before narrowing the schema.
    drop constraint(:sources, :source_kind)
    create constraint(:sources, :source_kind, check: "kind = 'azure_build'")
  end
end
