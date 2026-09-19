defmodule OpsBrain.Accounts.Operator do
  use Ecto.Schema
  @primary_key {:id, :binary_id, autogenerate: true}
  schema "operators" do
    field :name, :string
    field :enabled, :boolean, default: true
    timestamps(type: :utc_datetime_usec)
  end
end
