defmodule OpsBrainWeb.ConnCase do
  use ExUnit.CaseTemplate

  using do
    quote do
      @endpoint OpsBrainWeb.Endpoint
      use OpsBrainWeb, :verified_routes
      import Plug.Conn
      import Phoenix.ConnTest
      import Phoenix.LiveViewTest
      import OpsBrain.Fixtures
    end
  end

  setup do
    OpsBrain.Fixtures.clean!()
    {:ok, conn: Phoenix.ConnTest.build_conn()}
  end
end
