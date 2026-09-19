defmodule OpsBrainWeb.SessionHTML do
  use OpsBrainWeb, :html

  def new(assigns) do
    assigns =
      assigns
      |> Map.put(:form, to_form(%{"token" => ""}, as: :login))
      |> Map.put(:oidc_available, OpsBrain.OIDC.Config.available?())

    ~H"""
    <Layouts.app flash={@flash}>
      <h1>Operator sign in</h1>
      <p>
        Use a single-use access token supplied by your authorized administrator. No public registration or default accounts.
      </p>
      <p :if={@failed} id="sign-in-error" role="alert">Invalid or expired access token.</p>
      <.form :if={@oidc_available} for={to_form(%{})} action={~p"/auth/oidc"} id="oidc-sign-in-form">
        <button id="oidc-sign-in" type="submit">Sign in with approved identity provider</button>
      </.form>
      <.form for={@form} action={~p"/sign-in"} id="sign-in-form">
        <.input
          field={@form[:token]}
          type="password"
          label="Access token"
          required
          maxlength="43"
          autocomplete="off"
        />
        <button type="submit">Sign in</button>
      </.form>
    </Layouts.app>
    """
  end
end
