defmodule OpsBrain.Tenancy.Membership do
  use Ecto.Schema
  @primary_key false
  schema "memberships" do
    field :company_id, :binary_id, primary_key: true
    field :operator_id, :binary_id, primary_key: true
  end
end
