defmodule OpsBrainWeb.OperationsLiveTest do
  use OpsBrainWeb.ConnCase, async: false
  import Phoenix.LiveViewTest
  import OpsBrain.Fixtures

  setup do
    OpsBrain.Fixtures.clean!()
    fixture()
  end

  test "all operations routes enforce company and current membership", f do
    conn = Plug.Test.init_test_session(build_conn(), %{operator_token: f.token_a})

    for area <- ~w(pipelines services investigations capacity source-health) do
      assert {:ok, view, _} = live(conn, "/companies/#{f.a.id}/#{area}")
      assert has_element?(view, "#coverage-disclaimer")
      assert {:error, {:redirect, %{to: "/sign-in"}}} = live(conn, "/companies/#{f.b.id}/#{area}")
    end

    assert {:ok, view, _} = live(conn, "/companies/#{f.a.id}/investigations")

    OpsBrain.TestAdminRepo.query!("DELETE FROM memberships WHERE operator_id=$1::text::uuid", [
      f.alice.id
    ])

    render_click(view, "refresh", %{})
    assert_redirect(view, "/sign-in")
  end
end
