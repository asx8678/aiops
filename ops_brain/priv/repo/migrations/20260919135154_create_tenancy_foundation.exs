defmodule OpsBrain.Repo.Migrations.CreateTenancyFoundation do
  use Ecto.Migration

  def up do
    create table(:operators, primary_key: false) do
      add :id, :uuid, primary_key: true
      add :name, :string, null: false
      add :enabled, :boolean, null: false, default: true
      timestamps(type: :utc_datetime_usec)
    end

    create unique_index(:operators, [:name])

    create table(:companies, primary_key: false) do
      add :id, :uuid, primary_key: true
      add :name, :string, null: false
      add :slug, :string, null: false
      timestamps(type: :utc_datetime_usec)
    end

    create unique_index(:companies, [:slug])

    create table(:memberships, primary_key: false) do
      add :operator_id, references(:operators, type: :uuid, on_delete: :delete_all),
        primary_key: true

      add :company_id, references(:companies, type: :uuid, on_delete: :delete_all),
        primary_key: true
    end

    create table(:operator_tokens, primary_key: false) do
      add :token_hash, :binary, primary_key: true
      add :operator_id, references(:operators, type: :uuid, on_delete: :delete_all), null: false
      add :context, :string, null: false
      add :expires_at, :utc_datetime_usec, null: false
    end

    create constraint(:operator_tokens, :token_context, check: "context IN ('login', 'session')")
    create index(:operator_tokens, [:operator_id])

    create table(:environments, primary_key: false) do
      add :id, :uuid, primary_key: true
      add :company_id, references(:companies, type: :uuid, on_delete: :delete_all), null: false
      add :name, :string, null: false
      timestamps(type: :utc_datetime_usec)
    end

    create unique_index(:environments, [:company_id, :id])
    create unique_index(:environments, [:company_id, :name])

    create constraint(:environments, :environment_name,
             check: "name IN ('dev', 'staging', 'prod')"
           )

    create table(:sources, primary_key: false) do
      add :id, :uuid, primary_key: true
      add :company_id, references(:companies, type: :uuid, on_delete: :delete_all), null: false
      # Optional mapping: CI sources may span several environments or have no target.
      add :environment_id, :uuid
      add :name, :string, null: false
      add :kind, :string, null: false, default: "azure_build"
      timestamps(type: :utc_datetime_usec)
    end

    create unique_index(:sources, [:company_id, :id])
    create unique_index(:sources, [:company_id, :name])
    create constraint(:sources, :source_kind, check: "kind = 'azure_build'")

    execute """
    ALTER TABLE sources ADD CONSTRAINT sources_company_environment_fkey
    FOREIGN KEY (company_id, environment_id) REFERENCES environments(company_id, id)
    """

    for table <- ~w(environments sources) do
      execute "ALTER TABLE #{table} ENABLE ROW LEVEL SECURITY"
      execute "ALTER TABLE #{table} FORCE ROW LEVEL SECURITY"

      execute """
      CREATE POLICY company_scope ON #{table}
      USING (company_id = NULLIF(current_setting('ops_brain.company_id', true), '')::uuid)
      WITH CHECK (company_id = NULLIF(current_setting('ops_brain.company_id', true), '')::uuid)
      """
    end

    Oban.Migration.up(version: 14)
  end

  def down do
    Oban.Migration.down(version: 1)
    drop table(:sources)
    drop table(:environments)
    drop table(:operator_tokens)
    drop table(:memberships)
    drop table(:companies)
    drop table(:operators)
  end
end
