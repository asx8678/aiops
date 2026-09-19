defmodule OpsBrainWeb.OIDCHTML do
  use OpsBrainWeb, :html

  def complete(assigns) do
    ~H"""
    <Layouts.app flash={@flash}>
      <h1>Operator signed in</h1>
      <p><.link id="oidc-continue" href={~p"/"}>Continue to Ops Brain</.link></p>
    </Layouts.app>
    """
  end
end
