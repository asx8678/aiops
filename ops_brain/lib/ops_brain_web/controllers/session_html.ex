defmodule OpsBrainWeb.SessionHTML do
  use OpsBrainWeb, :html

  def new(assigns) do
    assigns =
      assigns
      |> Map.put(:form, to_form(%{"token" => ""}, as: :login))
      |> Map.put(:oidc_available, OpsBrain.OIDC.Config.available?())

    ~H"""
    <Layouts.app flash={@flash} authenticated={false}>
      <section class="auth-story">
        <a href="/" class="brand" aria-label="Constellation home"><span class="brand-mark"><UI.brand_logo /></span><span class="brand-wordmark">Constellation<small>OPERATIONS CONSOLE</small></span></a><div class="auth-story-content">
          <p class="eyebrow">YOUR OPERATIONS, IN FOCUS</p><h1>
            Less noise.<br /><span>More understanding.</span>
          </h1><p>
            Bring delivery, service observations, and investigation evidence into one clear view. Without changing a thing upstream.
          </p><div class="auth-diagram" aria-hidden="true">
            <div class="auth-node"><.icon name="hero-signal" /><small>Observe</small></div><.icon name="hero-arrow-right" /><div class="auth-node">
              <.icon name="hero-square-3-stack-3d" /><small>Connect</small>
            </div><.icon name="hero-arrow-right" /><div class="auth-node">
              <.icon name="hero-magnifying-glass" /><small>Understand</small>
            </div>
          </div>
        </div><p class="auth-story-foot">
          <.icon name="hero-shield-check" />Read-only sources. Evidence-first decisions.
        </p>
      </section>
      <section class="auth-form-side" aria-labelledby="sign-in-title">
        <div class="auth-card">
          <div class="auth-symbol"><.icon name="hero-lock-closed" /></div><p class="eyebrow">
            OPERATOR ACCESS
          </p><h2 id="sign-in-title">Welcome to Constellation.</h2><p class="auth-description">
            Sign in to your authorized workspaces with a single-use access token from your administrator.
          </p><p :if={@failed} id="sign-in-error" class="auth-error" role="alert">
            Invalid or expired access token. Request a new token from your administrator and try again.
          </p><.form
            :if={@oidc_available}
            for={to_form(%{})}
            action={~p"/auth/oidc"}
            id="oidc-sign-in-form"
          >
            <button id="oidc-sign-in" class="btn btn-primary" type="submit">Sign in with approved identity provider
            <.icon name="hero-arrow-right" /></button>
          </.form><div :if={@oidc_available} class="auth-divider">or use an access token</div><.form
            for={@form}
            action={~p"/sign-in"}
            id="sign-in-form"
          >
            <.input
              field={@form[:token]}
              type="password"
              label="Access token"
              placeholder="Paste your single-use token"
              required
              maxlength="43"
              autocomplete="off"
              spellcheck="false"
              aria-describedby="token-help"
            /><button class="btn btn-primary" type="submit">Enter workspace
            <.icon name="hero-arrow-right" /></button>
          </.form><p id="token-help" class="auth-help">
            Tokens expire after 15 minutes and can be used once.<br />Your authenticated session lasts up to 8 hours.
          </p><div class="auth-divider">PRIVATE BY DESIGN</div><p class="auth-help">
            No public registration or default accounts.<br />Access is limited to your approved company memberships.
          </p>
        </div><p class="auth-footer">Constellation · Read-only operations console</p>
      </section>
    </Layouts.app>
    """
  end
end
