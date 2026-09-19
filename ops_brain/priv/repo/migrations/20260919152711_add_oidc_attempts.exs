defmodule OpsBrain.Repo.Migrations.AddOidcAttempts do
  use Ecto.Migration

  def change do
    create table(:oidc_attempts, primary_key: false) do
      add :state_hash, :binary, primary_key: true
      add :expires_at, :bigint, null: false
    end

    create index(:oidc_attempts, [:expires_at])
  end
end
