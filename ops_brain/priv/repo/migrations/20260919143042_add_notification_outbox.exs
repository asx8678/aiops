defmodule OpsBrain.Repo.Migrations.AddNotificationOutbox do
  use Ecto.Migration

  def up do
    create table(:notification_outbox, primary_key: false) do
      add :id, :uuid, primary_key: true
      add :company_id, :uuid, null: false
      add :source_id, :uuid, null: false
      add :group_id, :uuid, null: false
      add :revision, :integer, null: false
      add :destination, :string, null: false
      add :status, :string, null: false, default: "pending"
      add :attempts, :integer, null: false, default: 0
      add :next_at, :utc_datetime_usec, null: false
      add :updated_at, :utc_datetime_usec, null: false
    end

    create unique_index(:notification_outbox, [:company_id, :group_id, :revision, :destination],
             name: :delivery_identity
           )

    execute "ALTER TABLE notification_outbox ADD CONSTRAINT delivery_source_scope FOREIGN KEY(company_id,source_id) REFERENCES sources(company_id,id) ON DELETE CASCADE"

    execute "ALTER TABLE notification_outbox ADD CONSTRAINT delivery_group_scope FOREIGN KEY(company_id,group_id) REFERENCES issue_groups(company_id,id) ON DELETE CASCADE"

    execute "ALTER TABLE notification_outbox ENABLE ROW LEVEL SECURITY"
    execute "ALTER TABLE notification_outbox FORCE ROW LEVEL SECURITY"

    execute "CREATE POLICY company_scope ON notification_outbox USING(company_id=NULLIF(current_setting('ops_brain.company_id',true),'')::uuid) WITH CHECK(company_id=NULLIF(current_setting('ops_brain.company_id',true),'')::uuid)"
  end

  def down, do: drop(table(:notification_outbox))
end
