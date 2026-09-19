defmodule OpsBrain.Accounts.Token do
  use Ecto.Schema
  @primary_key {:token_hash, :binary, autogenerate: false, redact: true}
  schema "operator_tokens" do
    field :operator_id, :binary_id
    field :context, :string
    field :expires_at, :utc_datetime_usec
  end
end
