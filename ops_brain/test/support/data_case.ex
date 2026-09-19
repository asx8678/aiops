defmodule OpsBrain.DataCase do
  use ExUnit.CaseTemplate

  using do
    quote do
      alias OpsBrain.{Accounts, Repo, Tenancy, TestAdminRepo}
      import Ecto.Query
      import OpsBrain.Fixtures
    end
  end

  setup do
    OpsBrain.Fixtures.clean!()
    :ok
  end
end
