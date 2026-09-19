defmodule OpsBrain.Tenancy.Environment do
  use Ecto.Schema
  import Ecto.Changeset
  @primary_key {:id, :binary_id, autogenerate: true}
  schema "environments" do
    field :company_id, :binary_id
    field :name, Ecto.Enum, values: [:dev, :staging, :prod]
    timestamps(type: :utc_datetime_usec)
  end

  def changeset(environment, attrs) do
    environment
    |> cast(attrs, [:name])
    |> validate_required([:name, :company_id])
    |> unique_constraint([:company_id, :name])
    |> check_constraint(:name, name: :environment_name)
  end
end
