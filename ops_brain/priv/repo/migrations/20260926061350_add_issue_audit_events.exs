defmodule OpsBrain.Repo.Migrations.AddIssueAuditEvents do
  use Ecto.Migration

  def up do
    create unique_index(:issue_groups, [:company_id, :source_id, :id],
             name: :issue_groups_audit_scope
           )

    create table(:issue_audit_events, primary_key: false) do
      add :id, :uuid, primary_key: true
      add :company_id, :uuid, null: false
      add :source_id, :uuid, null: false
      add :group_id, :uuid, null: false
      add :actor_id, references(:operators, type: :uuid, on_delete: :restrict), null: false
      add :actor_name, :text, null: false
      add :action, :string, null: false
      add :before_revision, :integer, null: false
      add :after_revision, :integer, null: false
      add :before_state, :map, null: false
      add :after_state, :map, null: false
      add :inserted_at, :utc_datetime_usec, null: false
    end

    create unique_index(:issue_audit_events, [:company_id, :group_id, :after_revision])

    create constraint(:issue_audit_events, :audit_action,
             check: "action IN ('assign','unassign','review','snooze')"
           )

    create constraint(:issue_audit_events, :audit_revision_step,
             check: "before_revision > 0 AND after_revision = before_revision + 1"
           )

    create constraint(:issue_audit_events, :audit_payload_bounds,
             check: """
             octet_length(actor_name) <= 100
             AND jsonb_typeof(before_state) = 'object' AND jsonb_typeof(after_state) = 'object'
             AND octet_length(before_state::text) <= 2048 AND octet_length(after_state::text) <= 2048
             AND before_state ?& ARRAY['status','owner','snoozed_until']
             AND after_state ?& ARRAY['status','owner','snoozed_until']
             AND before_state - ARRAY['status','owner','snoozed_until'] = '{}'::jsonb
             AND after_state - ARRAY['status','owner','snoozed_until'] = '{}'::jsonb
             """
           )

    execute "ALTER TABLE issue_audit_events ADD CONSTRAINT audit_group_scope FOREIGN KEY(company_id,source_id,group_id) REFERENCES issue_groups(company_id,source_id,id) ON DELETE CASCADE"

    execute "ALTER TABLE issue_audit_events ADD CONSTRAINT audit_source_scope FOREIGN KEY(company_id,source_id) REFERENCES sources(company_id,id) ON DELETE CASCADE"

    execute "ALTER TABLE issue_audit_events ENABLE ROW LEVEL SECURITY"
    execute "ALTER TABLE issue_audit_events FORCE ROW LEVEL SECURITY"

    execute "CREATE POLICY company_scope ON issue_audit_events USING(company_id=NULLIF(current_setting('ops_brain.company_id',true),'')::uuid) WITH CHECK(company_id=NULLIF(current_setting('ops_brain.company_id',true),'')::uuid)"
  end

  def down do
    drop table(:issue_audit_events)

    drop unique_index(:issue_groups, [:company_id, :source_id, :id],
           name: :issue_groups_audit_scope
         )
  end
end
