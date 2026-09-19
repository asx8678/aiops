defmodule OpsBrain.Tenancy.Company do
  use Ecto.Schema
  @primary_key {:id, :binary_id, autogenerate: true}
  schema "companies" do
    field :name, :string
    field :slug, :string
    timestamps(type: :utc_datetime_usec)
  end
end
