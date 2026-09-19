defmodule OpsBrain.Repo do
  use Ecto.Repo,
    otp_app: :ops_brain,
    adapter: Ecto.Adapters.Postgres
end
