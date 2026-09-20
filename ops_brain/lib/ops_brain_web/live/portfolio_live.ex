defmodule OpsBrainWeb.PortfolioLive do
  use OpsBrainWeb, :live_view
  alias OpsBrain.{Accounts, Demo, Issues, Services, Tenancy, Workspace}

  @impl true
  def mount(_params, _session, socket), do: {:ok, socket}

  @impl true
  def handle_params(_params, _uri, socket), do: load(socket)

  @impl true
  def handle_event("refresh", _params, socket), do: load(socket)

  defp load(socket) do
    token = socket.assigns.session_token

    with {:ok, scope} <- Workspace.resolve(token),
         {:ok, data} <- Tenancy.overview(scope),
         {:ok, services} <- Services.overview(scope),
         {:ok, findings} <- Issues.list(scope),
         {:ok, manifest} <- demo_manifest(scope) do
      environments =
        for {key, label} <- [
              {"dev", "Development"},
              {"staging", "Staging"},
              {"prod", "Production"}
            ] do
          %{
            key: key,
            label: label,
            configured: Enum.any?(data.environments, &(to_string(&1.name) == key)),
            targets: Enum.count(services, &(&1["environment"] == key))
          }
        end

      {:noreply,
       assign(socket,
         current_scope: scope,
         company: data.company,
         workspace_error: nil,
         environments: environments,
         source_count: length(data.sources),
         target_count: length(services),
         finding_count: length(findings),
         manifest: manifest
       )}
    else
      {:error, reason} ->
        if Accounts.operator_for_session(token) do
          {:noreply, assign(socket, current_scope: nil, company: nil, workspace_error: reason)}
        else
          {:noreply, redirect(socket, to: ~p"/sign-in")}
        end
    end
  end

  defp demo_manifest(scope) do
    if Demo.company?(scope.company_id), do: Demo.summary(scope), else: {:ok, nil}
  end

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app
      flash={@flash}
      current_scope={@current_scope}
      title="Home"
      company={@company && @company.name}
    >
      <UI.page_header
        eyebrow="YOUR COMMAND CENTER"
        title="A clearer view of operations."
        description="One workspace. Three environments. The evidence that connects it all."
      >
        <:actions>
          <button class="btn" id="refresh" phx-click="refresh" phx-disable-with="Refreshing…"><.icon name="hero-arrow-path" />Refresh</button>
        </:actions>
      </UI.page_header>
      <div class="portfolio-intro">
        <div>
          <p class="eyebrow">CONTEXT, NOT MORE NOISE</p><h2>Every signal. The right context.</h2><p>
            Follow the thread from a deployment to a symptom. Bring your services, observations, and investigation evidence into one clear picture.
          </p>
        </div><div class="intro-art" aria-hidden="true"><UI.brand_logo /></div>
      </div>
      <%= if @workspace_error do %>
        <section id="workspace-unavailable" class="panel">
          <UI.empty
            title="Your workspace needs attention"
            description="An administrator must configure this deployment’s workspace and grant your operator access. No company is selected automatically when membership is ambiguous."
          />
          <p class="panel-note">
            Set OPS_BRAIN_WORKSPACE_COMPANY_ID to the approved company UUID. No data from another workspace is shown.
          </p>
        </section>
      <% else %>
        <div id="home-workspace" data-company-id={@company.id}>
          <div class="stats-grid" id="home-stats">
            <UI.stat
              label="Mapped targets"
              value={@target_count}
              hint="Up to 100 retained service identities"
              icon="hero-server-stack"
            />
            <UI.stat
              label="Source identities"
              value={@source_count}
              hint="Configured identities, not connection claims"
              icon="hero-signal"
            />
            <UI.stat
              label="Retained findings"
              value={@finding_count}
              hint="Up to 100 · all local review states"
              icon="hero-magnifying-glass"
            />
            <UI.stat
              label={if @manifest, do: "Simulated pods", else: "Environments"}
              value={
                if @manifest,
                  do: @manifest["counts"]["Pod"],
                  else: Enum.count(@environments, & &1.configured)
              }
              hint={
                if @manifest,
                  do: "Offline snapshots · not live resources",
                  else: "Configured identities · not runtime health"
              }
              icon="hero-square-3-stack-3d"
            />
          </div>
          <div class="section-heading">
            <div>
              <h2>Your environments</h2><p>
                From development to production, without switching workspaces.
              </p>
            </div>
            <span class="section-count">ONE WORKSPACE / THREE ENVIRONMENTS</span>
          </div>
          <div class="home-environments" id="home-environments">
            <.link
              :for={env <- @environments}
              id={"home-environment-#{env.key}"}
              class="home-environment"
              navigate={~p"/companies/#{@company.id}/services?environment=#{env.key}"}
            >
              <div class="home-environment-top">
                <span class="env-icon"><.icon name="hero-server-stack" /></span><span class="env-code">{env.key}</span><.icon name="hero-arrow-right" />
              </div>
              <h3>{env.label}</h3>
              <p><strong>{env.targets}</strong> mapped targets in the retained set</p>
              <span class="home-environment-note">{cond do
                not env.configured -> "Environment identity not configured"
                env.targets == 0 -> "No mapped targets yet · condition unknown"
                true -> "Inspect observations · health not inferred"
              end}</span>
            </.link>
          </div>
          <section :if={OpsBrain.Demo.company?(@company.id)} class="panel home-demo" id="home-demo">
            <div class="panel-heading">
              <div>
                <p class="eyebrow">YOUR OFFLINE SANDBOX</p><h2>Explore the connected picture.</h2><p :if={
                  @manifest
                }>
                  {@manifest["counts"]["Cluster"]} simulated clusters · {@manifest["counts"][
                    "Namespace"
                  ]} namespaces · {@manifest["counts"]["Database"]} database identities
                </p><p :if={!@manifest}>
                  Demo snapshot unavailable or expired. Reseed explicitly to refresh it.
                </p>
              </div>
              <.link
                id="home-explore"
                class="btn btn-primary"
                navigate={~p"/companies/#{@company.id}/demo"}
              >Explore resources <.icon name="hero-arrow-right" /></.link>
            </div>
            <div class="panel-body">
              <p>
                Start with <strong>Checkout latency</strong>
                in Investigations. Connect a rollout, readiness failures, latency, and database pressure — then inspect the counterevidence.
              </p><.link
                id="home-investigate"
                class="text-link"
                navigate={~p"/companies/#{@company.id}/investigations"}
              >Follow the evidence <.icon name="hero-arrow-right" /></.link>
            </div>
          </section>
          <div class="section-heading">
            <div>
              <h2>Explore your operations</h2><p>
                No company selection. Go straight to the evidence.
              </p>
            </div>
          </div>
          <div class="module-grid">
            <.link
              :for={{key, label, path, icon, description} <- UI.areas()}
              :if={key != :show}
              navigate={"/companies/#{@company.id}#{path}"}
              class="module-card"
            ><.icon name={icon} /><div>
              <h3>{label}</h3><p>{description}</p>
            </div><.icon name="hero-arrow-right" /></.link>
          </div>
          <div id="coverage-not-configured" class="notice">
            <.icon name="hero-information-circle" /><p>
              <strong>Evidence first.</strong>
              Counts describe retained records, not measured health. Missing evidence is unknown. Inspect Source health for actual coverage and freshness.
            </p>
          </div>
        </div>
      <% end %>
    </Layouts.app>
    """
  end
end
