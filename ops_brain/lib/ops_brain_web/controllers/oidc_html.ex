defmodule OpsBrainWeb.OIDCHTML do
  use OpsBrainWeb, :html

  def complete(assigns) do
    ~H"""
    <Layouts.app flash={@flash} authenticated={false}>
      <section class="auth-story">
        <a href="/" class="brand" aria-label="Constellation home"><span class="brand-mark"><UI.brand_logo /></span><span class="brand-wordmark">Constellation<small>OPERATIONS CONSOLE</small></span></a><div class="auth-story-content">
          <p class="eyebrow">YOUR OPERATIONS, IN FOCUS</p><h1>
            Your workspace.<br /><span>A clearer perspective.</span>
          </h1><p>
            Explore the evidence in your authorized companies. Every view respects your access boundary.
          </p>
        </div><p class="auth-story-foot">
          <.icon name="hero-shield-check" />Read-only sources. Evidence-first decisions.
        </p>
      </section>
      <section class="auth-form-side">
        <div class="auth-card">
          <div class="auth-symbol"><.icon name="hero-shield-check" /></div><h2>You’re signed in.</h2><p class="auth-description">
            Your authorized workspaces are ready.
          </p><.link id="oidc-continue" href={~p"/"} class="btn btn-primary">Continue to Constellation
          <.icon name="hero-arrow-right" /></.link>
        </div>
      </section>
    </Layouts.app>
    """
  end
end
