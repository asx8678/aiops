defmodule OpsBrain.Repo.Migrations.AddOccurrenceEvidenceRevisions do
  use Ecto.Migration

  @moduledoc """
  R06: separate a logical occurrence from immutable evidence revisions. The
  occurrence keeps its identity and current pointer; every improvement or
  reclassification is retained as an append-only link so provenance survives.
  """

  def up do
    alter table(:failure_occurrences) do
      add :evidence_revision, :integer, null: false, default: 1
      add :fingerprint, :string
      add :parser_version, :integer
    end

    create table(:occurrence_evidence, primary_key: false) do
      add :id, :uuid, primary_key: true
      add :company_id, :uuid, null: false
      add :source_id, :uuid, null: false
      add :occurrence_id, :uuid, null: false
      add :group_id, :uuid, null: false
      add :evidence_id, :uuid, null: false
      add :revision, :integer, null: false
      add :fingerprint, :string, null: false
      add :parser_version, :integer, null: false
      add :reason, :string, null: false
      add :inserted_at, :utc_datetime_usec, null: false
    end

    create unique_index(:occurrence_evidence, [:company_id, :occurrence_id, :revision])
    create unique_index(:occurrence_evidence, [:company_id, :id])
    create unique_index(:failure_occurrences, [:company_id, :source_id, :id])
    create unique_index(:evidence_items, [:company_id, :source_id, :id])

    execute "ALTER TABLE occurrence_evidence ADD CONSTRAINT occurrence_evidence_occurrence_scope FOREIGN KEY(company_id,source_id,occurrence_id) REFERENCES failure_occurrences(company_id,source_id,id) ON DELETE CASCADE"

    execute "ALTER TABLE occurrence_evidence ADD CONSTRAINT occurrence_evidence_evidence_scope FOREIGN KEY(company_id,source_id,evidence_id) REFERENCES evidence_items(company_id,source_id,id) ON DELETE CASCADE"

    execute "ALTER TABLE occurrence_evidence ADD CONSTRAINT occurrence_evidence_source_scope FOREIGN KEY(company_id,source_id) REFERENCES sources(company_id,id) ON DELETE CASCADE"

    execute "ALTER TABLE occurrence_evidence ADD CONSTRAINT occurrence_evidence_group_scope FOREIGN KEY(company_id,group_id) REFERENCES issue_groups(company_id,id) ON DELETE CASCADE"

    # DDL locks and the migration transaction prevent concurrent access while
    # the owner backfills all tenants; FORCE is restored before commit.
    execute "ALTER TABLE failure_occurrences NO FORCE ROW LEVEL SECURITY"
    execute "ALTER TABLE issue_groups NO FORCE ROW LEVEL SECURITY"

    execute "ALTER TABLE occurrence_evidence ENABLE ROW LEVEL SECURITY"

    execute "CREATE POLICY company_scope ON occurrence_evidence USING(company_id=NULLIF(current_setting('ops_brain.company_id',true),'')::uuid) WITH CHECK(company_id=NULLIF(current_setting('ops_brain.company_id',true),'')::uuid)"

    execute """
    UPDATE failure_occurrences f SET fingerprint=g.fingerprint, parser_version=g.parser_version
    FROM issue_groups g
    WHERE g.id=f.group_id AND g.company_id=f.company_id AND f.fingerprint IS NULL
    """

    execute """
    INSERT INTO occurrence_evidence(id,company_id,source_id,occurrence_id,evidence_id,revision,fingerprint,parser_version,reason,inserted_at,group_id)
    SELECT gen_random_uuid(), f.company_id, f.source_id, f.id, f.evidence_id, 1,
           COALESCE(f.fingerprint,g.fingerprint), COALESCE(f.parser_version,g.parser_version),
           'backfilled', (now() AT TIME ZONE 'UTC'), f.group_id
    FROM failure_occurrences f JOIN issue_groups g ON g.id=f.group_id AND g.company_id=f.company_id
    """

    execute "ALTER TABLE failure_occurrences FORCE ROW LEVEL SECURITY"
    execute "ALTER TABLE issue_groups FORCE ROW LEVEL SECURITY"
    execute "ALTER TABLE occurrence_evidence FORCE ROW LEVEL SECURITY"
  end

  def down do
    drop table(:occurrence_evidence)
    drop unique_index(:failure_occurrences, [:company_id, :source_id, :id])
    drop unique_index(:evidence_items, [:company_id, :source_id, :id])

    alter table(:failure_occurrences) do
      remove :evidence_revision
      remove :fingerprint
      remove :parser_version
    end
  end
end
