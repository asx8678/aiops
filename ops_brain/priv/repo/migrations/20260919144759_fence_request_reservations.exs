defmodule OpsBrain.Repo.Migrations.FenceRequestReservations do
  use Ecto.Migration

  def change do
    alter table(:source_budgets) do
      add :reservation, :uuid
    end
  end
end
