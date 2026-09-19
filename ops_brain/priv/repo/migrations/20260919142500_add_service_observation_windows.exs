defmodule OpsBrain.Repo.Migrations.AddServiceObservationWindows do
  use Ecto.Migration

  def up do
    create table(:service_instances, primary_key: false) do
      add :id, :uuid, primary_key: true
      add :company_id, :uuid, null: false
      add :source_id, :uuid, null: false
      add :environment_id, :uuid, null: false
      add :service_key, :string, null: false
      add :target, :string, null: false
    end

    create unique_index(:service_instances, [:company_id, :id])

    create unique_index(
             :service_instances,
             [:company_id, :service_key, :environment_id, :source_id, :target],
             name: :service_identity
           )

    execute "ALTER TABLE service_instances ADD CONSTRAINT service_environment_scope FOREIGN KEY(company_id,environment_id) REFERENCES environments(company_id,id)"

    create table(:observation_windows, primary_key: false) do
      add :id, :uuid, primary_key: true
      add :company_id, :uuid, null: false
      add :source_id, :uuid, null: false
      add :service_id, :uuid
      add :profile, :string, null: false
      add :kind, :string, null: false
      add :window_start, :utc_datetime_usec, null: false
      add :window_end, :utc_datetime_usec, null: false
      add :received_at, :utc_datetime_usec, null: false
      add :revision, :integer, null: false, default: 1
      add :data, :map, null: false
    end

    create unique_index(
             :observation_windows,
             [:company_id, :source_id, :profile, :window_start, :window_end],
             name: :fixed_window_identity
           )

    create index(:observation_windows, [:company_id, :received_at])

    execute "ALTER TABLE observation_windows ADD CONSTRAINT window_service_scope FOREIGN KEY(company_id,service_id) REFERENCES service_instances(company_id,id)"

    create constraint(:observation_windows, :window_order,
             check: "window_end > window_start AND octet_length(data::text) <= 65536"
           )

    create table(:source_budgets, primary_key: false) do
      add :company_id, :uuid, null: false
      add :source_id, :uuid, primary_key: true
      add :next_at, :utc_datetime_usec, null: false
      add :requests, :bigint, null: false, default: 0
      add :bytes, :bigint, null: false, default: 0
      add :errors, :bigint, null: false, default: 0
      add :period_start, :utc_datetime_usec
      add :period_requests, :integer, null: false, default: 0
      add :in_flight_until, :utc_datetime_usec
    end

    for table <- ~w(service_instances observation_windows source_budgets) do
      execute "ALTER TABLE #{table} ADD CONSTRAINT #{table}_source_scope FOREIGN KEY(company_id,source_id) REFERENCES sources(company_id,id) ON DELETE CASCADE"
      execute "ALTER TABLE #{table} ENABLE ROW LEVEL SECURITY"
      execute "ALTER TABLE #{table} FORCE ROW LEVEL SECURITY"

      execute "CREATE POLICY company_scope ON #{table} USING(company_id=NULLIF(current_setting('ops_brain.company_id',true),'')::uuid) WITH CHECK(company_id=NULLIF(current_setting('ops_brain.company_id',true),'')::uuid)"
    end
  end

  def down do
    drop table(:source_budgets)
    drop table(:observation_windows)
    drop table(:service_instances)
  end
end
