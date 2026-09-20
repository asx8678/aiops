defmodule OpsBrainWeb.CompanyLive do
  use OpsBrainWeb, :live_view
  alias OpsBrain.Tenancy

  @impl true
  def mount(_params, _session, socket), do: {:ok, socket}

  @impl true
  def handle_params(params, _uri, socket) do
    socket = assign(socket, :source_id, params["id"])
    load(socket)
  end

  @impl true
  def handle_event("refresh", _params, socket), do: load(socket)

  defp load(socket) do
    scope = socket.assigns.current_scope

    with {:ok, data} <- Tenancy.overview(scope),
         {:ok, selected} <- selected_source(scope, socket.assigns.source_id) do
      {:noreply,
       socket
       |> assign(:company, data.company)
       |> assign(:selected_source, selected)
       |> assign(:environments, data.environments)
       |> assign(:empty_sources?, data.sources == [])
       |> assign(:source_count, length(data.sources))
       |> stream(:sources, data.sources, reset: true)}
    else
      {:error, :not_found} -> {:noreply, redirect(socket, to: ~p"/companies/#{scope.company_id}")}
      _ -> {:noreply, redirect(socket, to: ~p"/sign-in")}
    end
  end

  defp selected_source(_, nil), do: {:ok, nil}
  defp selected_source(scope, id), do: Tenancy.get_source(scope, id)

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app
      flash={@flash}
      current_scope={@current_scope}
      active={:show}
      title="Configuration"
      company={@company.name}
    >
      <UI.page_header
        eyebrow="WORKSPACE CONFIGURATION"
        title={@company.name}
        description="Your operational workspace. Explicit identities, clear boundaries, and evidence you can inspect."
      >
        <:actions>
          <button class="btn" id="refresh" phx-click="refresh" phx-disable-with="Refreshing…"><.icon name="hero-arrow-path" />Refresh</button><.link
            class="btn btn-primary"
            navigate={~p"/companies/#{@company.id}/source-health"}
          ><.icon name="hero-signal" />Source health</.link>
        </:actions>
      </UI.page_header>
      <section :if={OpsBrain.Demo.company?(@company.id)} class="panel" id="demo-entry">
        <div class="panel-heading">
          <div>
            <h2>Your offline infrastructure sandbox is ready</h2><p>
              Browse clusters, pods, namespaces and databases, then connect the dots in Investigations.
            </p>
          </div><.link class="btn btn-primary" navigate={~p"/companies/#{@company.id}/demo"}>Open demo explorer
          <.icon name="hero-arrow-right" /></.link>
        </div>
      </section>
      <div class="stats-grid" id="overview-stats">
        <UI.stat
          label="Environment identities"
          value={length(@environments)}
          hint="Explicitly configured environments"
          icon="hero-server-stack"
        /><UI.stat
          label="Source identities"
          value={@source_count}
          hint="Up to 100 identities shown"
          icon="hero-signal"
        /><UI.stat
          label="Runtime condition"
          value="Unknown"
          hint="Inspect stored service observations"
          icon="hero-chart-bar"
        /><UI.stat
          label="Source access"
          value="Read-only"
          hint="No changes to your infrastructure"
          icon="hero-shield-check"
        />
      </div>
      <div id="company-coverage" class="notice">
        <.icon name="hero-information-circle" /><p>
          <strong>Overall condition: unknown.</strong>
          Identities are not health checks. Coverage is limited to explicitly configured checks; inspect Services and Sources for stored results.
        </p>
      </div>
      <div class="dashboard-grid">
        <section class="panel" aria-labelledby="environments-heading">
          <div class="panel-heading">
            <div>
              <h2 id="environments-heading">Environment coverage</h2><p>
                Configured identities, not a runtime health assessment
              </p>
            </div><UI.badge value="unknown" label="Not evaluated here" />
          </div><div id="environments" class="environment-grid">
            <article
              :for={environment <- @environments}
              id={"environment-#{environment.id}"}
              class="environment-card"
            >
              <div class="env-icon"><.icon name="hero-server-stack" /></div><h3>
                {environment.name}
              </h3><UI.badge value="unknown" /><p>
                Identity only. Explicit service evidence is required.
              </p>
            </article>
          </div><p :if={@environments == []} class="compact-empty">
            No configured environment identities.
          </p><div class="panel-note">An environment name never establishes production health.</div>
        </section>
        <section class="panel">
          <div class="panel-heading">
            <div>
              <h2>Establish your coverage</h2><p>A deliberate path from identity to evidence</p>
            </div><.icon name="hero-shield-check" />
          </div><div class="panel-body">
            <ol class="checklist">
              <li>
                <strong>Define the boundaries</strong><p>
                  Confirm company, environment, and service identities.
                </p>
              </li><li>
                <strong>Approve read-only sources</strong><p>
                  Your administrator configures endpoints, permissions, and budgets.
                </p>
              </li><li>
                <strong>Inspect collected evidence</strong><p>
                  Check freshness and missing inputs before drawing conclusions.
                </p>
              </li>
            </ol>
          </div>
        </section>
      </div>
      <div class="section-heading">
        <div>
          <h2>Explore your operations</h2><p>
            Follow the evidence across each part of your workspace.
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
      <section class="panel">
        <div class="panel-heading">
          <div>
            <h2>Source directory</h2><p>Identity metadata · up to 100 sources</p>
          </div><.link class="text-link" navigate={~p"/companies/#{@company.id}/source-health"}>Inspect coverage
          <.icon name="hero-arrow-right" /></.link>
        </div><div :if={@empty_sources?} id="no-sources">
          <UI.empty
            title="No sources configured yet"
            description="An administrator must approve a source and its collection scope. Nothing is monitored just because this workspace exists."
          />
        </div><div id="sources" phx-update="stream">
          <article :for={{dom_id, source} <- @streams.sources} id={dom_id} class="source-row">
            <div class="source-row-main">
              <.icon name="hero-signal" /><div>
                <strong>{source.name}</strong><small>{source.kind} · identity metadata</small>
              </div>
            </div><.link class="text-link" patch={~p"/companies/#{@company.id}/sources/#{source.id}"}>Details
            <.icon name="hero-arrow-right" /></.link>
          </article>
        </div><details class="inline-help" id="source-setup-guide">
          <summary>How do I connect a source?</summary><p>
            Source setup is deployment-managed, not a browser action. Ask an authorized administrator to create the source identity, map its service and environment, and supply an approved configuration file and secret references. The repository’s
            <code>ops_brain/docs/ONBOARDING.md</code>
            explains the workflow. Collection and external delivery remain off until separately approved. Classic releases are unsupported.
          </p>
        </details>
      </section>
      <section :if={@selected_source} id="selected-source" class="panel">
        <div class="panel-heading">
          <h2>{@selected_source.name}</h2><.link
            patch={~p"/companies/#{@company.id}"}
            class="btn"
            aria-label="Close source details"
          ><.icon name="hero-x-mark" />Close</.link>
        </div><div class="panel-body">
          <UI.badge value="identity" label="Source identity" /><dl class="source-detail">
            <dt>Source type</dt><dd>{@selected_source.kind}</dd><dt>Environment mapping</dt><dd>
              {if is_nil(@selected_source.environment_id),
                do: "Unresolved / CI-only, not production",
                else: "Explicit identity mapping; not verified runtime health"}
            </dd>
          </dl><p class="muted tiny">
            Endpoint, credential reference and collection budgets require separately approved deployment configuration.
          </p><.link class="btn" navigate={~p"/companies/#{@company.id}/source-health"}>View actual source coverage
          <.icon name="hero-arrow-right" /></.link>
        </div>
      </section>
    </Layouts.app>
    """
  end
end
