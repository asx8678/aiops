defmodule OpsBrainWeb.Layouts do
  use OpsBrainWeb, :html
  embed_templates "layouts/*"

  attr :flash, :map, required: true
  attr :current_scope, :map, default: nil
  attr :active, :atom, default: :portfolio
  attr :title, :string, default: "Home"
  attr :company, :string, default: nil
  attr :authenticated, :boolean, default: true
  attr :live_refresh, :boolean, default: false
  slot :inner_block, required: true

  def app(assigns) do
    ~H"""
    <div :if={@authenticated} class="app-shell">
      <aside class="sidebar" aria-label="Workspace navigation">
        <.link navigate={~p"/"} class="brand" aria-label="Constellation home"><span class="brand-mark"><UI.brand_logo /></span><span class="brand-wordmark">Constellation<small>OPERATIONS CONSOLE</small></span></.link>
        <div class="workspace-identity" id="workspace-identity">
          <span class="workspace-avatar">{if @company, do: UI.initial(@company), else: "C"}</span><span><strong>{@company ||
            "Operations workspace"}</strong><small>Single workspace · scoped access</small></span>
        </div>
        <div class="workspace-environments" aria-label="Deployment environments">
          <span>dev</span><span>staging</span><span>prod</span>
        </div>
        <nav class="primary-nav" aria-label="Main navigation">
          <span class="nav-label">WORKSPACE</span>
          <.link
            navigate={~p"/"}
            class={["nav-item", @active == :portfolio && "is-active"]}
            aria-current={@active == :portfolio && "page"}
          ><.icon name="hero-squares-2x2" />Home</.link>
          <.link
            :if={@current_scope && OpsBrain.Demo.company?(@current_scope.company_id)}
            navigate={~p"/companies/#{@current_scope.company_id}/demo"}
            class={["nav-item", @active == :demo && "is-active"]}
            aria-current={@active == :demo && "page"}
          ><.icon name="hero-square-3-stack-3d" />Demo explorer</.link>
          <%= for {key, label, path, icon, _} <- UI.areas() do %>
            <.link
              :if={@current_scope}
              navigate={"/companies/#{@current_scope.company_id}#{path}"}
              class={["nav-item", @active == key && "is-active"]}
              aria-current={@active == key && "page"}
            ><.icon name={icon} />{label}<span :if={@active == key} class="nav-active-dot"></span></.link>
            <span
              :if={!@current_scope}
              class="nav-item nav-unavailable"
              title="Workspace unavailable; contact your administrator"
            ><.icon name={icon} />{label}</span>
          <% end %>
        </nav>
        <div class="sidebar-bottom">
          <div class="safety-note">
            <.icon name="hero-shield-check" /><strong>Observe. Understand.</strong><p>
              Read-only sources. Your infrastructure stays in your control.
            </p>
          </div><.link
            :if={!UI.dev_auto_login?()}
            href={~p"/sign-out"}
            method="delete"
            class="nav-item"
            id="sign-out"
          ><.icon name="hero-arrow-right-on-rectangle" />Sign out</.link><div class="sidebar-version">
            CONSTELLATION <span>v2.0</span>
          </div>
        </div>
      </aside>
      <div class="workspace-main">
        <header class="topbar">
          <div class="breadcrumbs">
            <.icon name="hero-squares-2x2" /><.link navigate={~p"/"}>Workspace</.link><span class="breadcrumb-divider">/</span><span>{@title}</span>
          </div><div class="topbar-meta">
            <.link
              :if={!UI.dev_auto_login?()}
              href={~p"/sign-out"}
              method="delete"
              class="topbar-sign-out"
              aria-label="Sign out"
              title="Sign out"
            ><.icon name="hero-arrow-right-on-rectangle" /></.link>
            <span class="read-only"><.icon name="hero-lock-closed" />Read-only sources</span><span
              :if={UI.dev_auto_login?()}
              class="dev-flag"
              id="dev-auto-login"
              title="Local development: login is skipped for the configured operator"
            >LOCAL · NO LOGIN</span><span
              :if={!UI.dev_auto_login?()}
              class="operator-avatar"
              title="Authenticated operator"
            >OP</span>
          </div>
        </header>
        <div class="connection-banner" role="status">
          Connection interrupted. Displayed data may be out of date. Reconnecting…
        </div>
        <main id="main-content" class="page-content" tabindex="-1">
          <div
            :if={@current_scope && OpsBrain.Demo.company?(@current_scope.company_id)}
            id="demo-banner"
            class="demo-banner"
            role="note"
          >
            <.icon name="hero-information-circle" /><div>
              <strong>SYNTHETIC DEMO · OFFLINE</strong><p>
                All resources, metrics, connection states, and findings in this workspace are fictional snapshots. No real systems are connected. Local review changes affect this demo only.
              </p>
            </div><.link navigate={~p"/companies/#{@current_scope.company_id}/demo"}>Explore dataset
            <.icon name="hero-arrow-right" /></.link>
          </div>
          {render_slot(@inner_block)}
        </main>
        <footer class="page-footer">
          <span>Evidence first. Unknown is never healthy.</span><span
            :if={@live_refresh}
            class="refresh-indicator"
          ><span class="status-dot"></span>View refreshes every 10s</span><span :if={!@live_refresh}>Scoped workspace access</span>
        </footer>
      </div>
    </div>
    <main :if={!@authenticated} id="main-content" class="auth-shell" tabindex="-1">
      {render_slot(@inner_block)}
    </main>
    <.flash_group flash={@flash} />
    """
  end

  attr :flash, :map, required: true

  def flash_group(assigns) do
    ~H"""
    <div id="flash-group" aria-live="polite">
      <.flash kind={:info} flash={@flash} /><.flash kind={:error} flash={@flash} />
    </div>
    """
  end
end
