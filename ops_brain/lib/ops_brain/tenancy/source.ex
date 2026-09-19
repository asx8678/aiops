defmodule OpsBrain.Tenancy.Source do
  use Ecto.Schema
  import Ecto.Changeset
  @primary_key {:id, :binary_id, autogenerate: true}
  schema "sources" do
    field :company_id, :binary_id
    field :environment_id, :binary_id
    field :name, :string

    field :kind, Ecto.Enum,
      values: [:azure_build, :prometheus, :loki, :kubernetes],
      default: :azure_build

    timestamps(type: :utc_datetime_usec)
  end

  def changeset(source, attrs) do
    source
    |> cast(attrs, [:name, :kind, :environment_id])
    |> validate_required([:name, :company_id, :kind])
    |> validate_length(:name, min: 1, max: 100)
    |> unique_constraint([:company_id, :name])
    |> foreign_key_constraint(:environment_id, name: :sources_company_environment_fkey)
    |> check_constraint(:kind, name: :source_kind)
  end
end
