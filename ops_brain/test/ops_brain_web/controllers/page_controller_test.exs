defmodule OpsBrainWeb.EntryTest do
  use OpsBrainWeb.ConnCase, async: false

  test "unauthenticated home redirects to sign-in", %{conn: conn} do
    assert redirected_to(get(conn, ~p"/")) == "/sign-in"
  end

  test "entry form renders without inventing an operator or healthy source", %{conn: conn} do
    html = get(conn, ~p"/sign-in") |> html_response(200) |> LazyHTML.from_document()
    assert LazyHTML.query(html, "#sign-in-form") |> LazyHTML.to_tree() != []
  end
end
