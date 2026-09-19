defmodule OpsBrain.Repo.Migrations.AddEvidenceAndIssues do
  use Ecto.Migration

  def up do
    create table(:evidence_items, primary_key: false) do
      add :id, :uuid, primary_key: true
      add :company_id, :uuid, null: false
      add :source_id, :uuid, null: false
      add :evidence_key, :text, null: false
      add :kind, :string, null: false
      add :occurred_at, :utc_datetime_usec, null: false
      add :received_at, :utc_datetime_usec, null: false
      add :expires_at, :utc_datetime_usec, null: false
      add :data, :map, null: false
    end

    create unique_index(:evidence_items, [:company_id, :source_id, :evidence_key])
    create unique_index(:evidence_items, [:company_id, :id])

    create table(:error_fingerprints, primary_key: false) do
      add :company_id, :uuid, primary_key: true
      add :fingerprint, :string, primary_key: true
      add :source_id, :uuid, null: false
      add :parser_version, :integer, null: false
      add :data, :map, null: false
    end

    create table(:issue_groups, primary_key: false) do
      add :id, :uuid, primary_key: true
      add :company_id, :uuid, null: false
      add :source_id, :uuid, null: false
      add :fingerprint, :string, null: false
      add :parser_version, :integer, null: false
      add :first_seen, :utc_datetime_usec, null: false
      add :last_seen, :utc_datetime_usec, null: false
      add :severity, :string, null: false
      add :status, :string, null: false, default: "new"
      add :owner, :string
      add :snoozed_until, :utc_datetime_usec
      add :revision, :integer, null: false, default: 1
      add :data, :map, null: false
    end

    create unique_index(:issue_groups, [:company_id, :id])
    create index(:issue_groups, [:company_id, :fingerprint, :last_seen])

    execute "ALTER TABLE issue_groups ADD CONSTRAINT group_fingerprint_scope FOREIGN KEY(company_id,fingerprint) REFERENCES error_fingerprints(company_id,fingerprint)"

    create constraint(:issue_groups, :local_status,
             check:
               "status IN ('new','active','locally_acknowledged','quiet','recovered','closed_by_reviewer')"
           )

    create table(:failure_occurrences, primary_key: false) do
      add :id, :uuid, primary_key: true
      add :company_id, :uuid, null: false
      add :source_id, :uuid, null: false
      add :occurrence_key, :text, null: false
      add :group_id, :uuid, null: false
      add :evidence_id, :uuid, null: false
      add :run_id, :bigint
      add :attempt, :integer
      add :occurred_at, :utc_datetime_usec, null: false
    end

    create unique_index(:failure_occurrences, [:company_id, :source_id, :occurrence_key])

    execute "ALTER TABLE failure_occurrences ADD CONSTRAINT occurrence_group_scope FOREIGN KEY(company_id,group_id) REFERENCES issue_groups(company_id,id) ON DELETE CASCADE"

    execute "ALTER TABLE failure_occurrences ADD CONSTRAINT occurrence_evidence_scope FOREIGN KEY(company_id,evidence_id) REFERENCES evidence_items(company_id,id) ON DELETE CASCADE"

    for table <- ~w(evidence_items error_fingerprints issue_groups failure_occurrences) do
      execute "ALTER TABLE #{table} ADD CONSTRAINT #{table}_source_scope FOREIGN KEY(company_id,source_id) REFERENCES sources(company_id,id) ON DELETE CASCADE"
      execute "ALTER TABLE #{table} ENABLE ROW LEVEL SECURITY"
      execute "ALTER TABLE #{table} FORCE ROW LEVEL SECURITY"

      execute "CREATE POLICY company_scope ON #{table} USING(company_id=NULLIF(current_setting('ops_brain.company_id',true),'')::uuid) WITH CHECK(company_id=NULLIF(current_setting('ops_brain.company_id',true),'')::uuid)"
    end

    create constraint(:evidence_items, :bounded_evidence,
             check: "octet_length(data::text) <= 32768"
           )
  end

  def down do
    drop table(:failure_occurrences)
    drop table(:issue_groups)
    drop table(:error_fingerprints)
    drop table(:evidence_items)
  end
end
